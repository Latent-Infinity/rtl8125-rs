// SPDX-License-Identifier: GPL-2.0
//! NAPI poll body — plan §7 M4.

use core::ffi::c_int;
use core::ptr;
use core::sync::atomic::Ordering;

use crate::netdev::{NetdevState, RX_BUF_LEN};
use crate::regs;
use crate::ring::{Descriptor, RING_LEN};
#[allow(clippy::unsafe_removed_from_name)]
use crate::unsafe_boundary as ub;

/// Called from the cshim's `bridge_napi_poll` (which itself is the kernel's
/// NAPI poll callback). `budget` bounds how many RX frames may pass to the
/// stack in this round; we also reap as many TX completions as available.
///
/// Returns `work_done` in `[0, budget]`. If `work_done < budget`, we call
/// `bridge_napi_complete_done` so the kernel re-arms IRQs at its end, and
/// we re-arm our `IMR` bits at ours.
pub(crate) fn poll(state: &NetdevState, budget: c_int) -> c_int {
    crate::netdev::note_napi_poll();
    let budget_u = if budget < 0 { 0 } else { budget as usize };
    let mut work_done = 0usize;

    // ── RX completion path ───────────────────────────────────────────────
    let mut rx_tail = state.rx_tail.inner.load(Ordering::Acquire);
    while work_done < budget_u {
        let desc = ub::desc_read(state.rx_desc, rx_tail);
        // Hardware sets OWN; if still set, this slot isn't filled yet — stop.
        if desc.opts1 & regs::DESC_OWN != 0 {
            break;
        }
        // Lower 14 bits of opts1 are the RX frame length (incl. CRC; chip
        // typically strips CRC — same convention as r8169). Cap at the
        // buffer size for safety.
        let len = (desc.opts1 & regs::DESC_LEN_MASK) as usize;
        let len = core::cmp::min(len, RX_BUF_LEN);

        let ndev = state.ndev.load(Ordering::Acquire);
        if len > 0 {
            // Build skb (cshim copies). Counter `rx_handed_to_stack++` happens
            // inside `bridge_skb_deliver_rx`.
            let buf_ptr = ub::rx_buf_ptr(&state.rx_bufs, rx_tail);
            let skb = ub::skb_build_rx(ndev, buf_ptr, len);
            if !skb.is_null() {
                // M4-perf: ask the chip-side opts1 if HW verified the L4
                // checksum, set skb->ip_summed accordingly. Saves the
                // kernel from re-computing on every RX packet.
                ub::skb_rx_csum_set(skb, desc.opts1);
                let napi = ub::bridge_napi(ndev);
                ub::skb_deliver_rx(napi, skb);
                // M4-perf: bump netdev stats so `ip -s link` reflects
                // real traffic. `len` is the chip's reported frame size.
                ub::bridge_account_rx(ndev, len as u32);
            } else {
                // No skb exists to free, but the §6.3 disposition counter
                // still needs to record the RX allocation failure.
                ub::rx_drop_error(ndev);
            }
        }

        // Re-post the descriptor: same DMA address, OWN bit set, len = buf.
        let dma = state.rx_bufs.dma_handle() + (rx_tail as u64) * (RX_BUF_LEN as u64);
        let mut opts1 = regs::DESC_OWN | (RX_BUF_LEN as u32 & regs::DESC_LEN_MASK);
        if rx_tail == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        ub::desc_write(
            state.rx_desc,
            rx_tail,
            Descriptor {
                opts1,
                opts2: 0,
                addr: dma,
            },
        );

        rx_tail = (rx_tail + 1) % RING_LEN;
        work_done += 1;
    }
    state.rx_tail.inner.store(rx_tail, Ordering::Release);

    // ── TX completion reaper ─────────────────────────────────────────────
    // Walk TX from tail; for each descriptor whose OWN bit hardware cleared,
    // unmap + napi_consume_skb the matching shadow slot.
    let mut tx_tail = state.tx_tail.inner.load(Ordering::Acquire);
    let tx_head = state.tx_head.inner.load(Ordering::Acquire);
    let mut reaped = 0usize;
    while tx_tail != tx_head {
        let slot = tx_tail % RING_LEN;
        let desc = ub::desc_read(state.tx_desc, slot);
        if desc.opts1 & regs::DESC_OWN != 0 {
            // Hardware still owns this slot — stop here.
            break;
        }
        // M4-perf phase 2 (SG): every descriptor in a logical packet has
        // its own DMA mapping that must be unmapped here. The skb pointer
        // is in the LastFrag slot only; intermediate frags get null.
        let map_addr = state.tx_shadow_dma[slot].load(Ordering::Acquire);
        let map_len = state.tx_shadow_len[slot].load(Ordering::Acquire) as usize;
        if map_len > 0 {
            if state.tx_shadow_is_frag[slot].swap(false, Ordering::AcqRel) {
                ub::skb_dma_unmap_frag_tx(&state.pdev, map_addr, map_len);
            } else {
                ub::skb_dma_unmap_tx(&state.pdev, map_addr, map_len);
            }
            // Mark slot's mapping as consumed so a follow-on read can't
            // see stale state if the shadow is reused before the next
            // xmit overwrites it.
            state.tx_shadow_len[slot].store(0, Ordering::Release);
        }
        let skb = state.tx_shadow[slot].swap(ptr::null_mut(), Ordering::AcqRel);
        if !skb.is_null() {
            // LastFrag of a logical packet — drain stats from skb->len
            // (the kernel-side total including all paged frags) and
            // hand the skb back to NAPI for recycling. The DMA unmap
            // for THIS slot already happened above; for SG packets the
            // intermediate slots' unmaps happened in earlier loop iters.
            ub::skb_consume_tx(state.ndev.load(Ordering::Acquire), skb);
        }
        // Clear the descriptor (preserve EOR if last slot).
        let mut opts1 = 0u32;
        if slot == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        ub::desc_write(
            state.tx_desc,
            slot,
            Descriptor {
                opts1,
                opts2: 0,
                addr: 0,
            },
        );
        tx_tail = tx_tail.wrapping_add(1);
        reaped += 1;
    }
    if reaped > 0 {
        state.tx_tail.inner.store(tx_tail, Ordering::Release);
        // Wake the kernel TX path in case xmit had stopped the queue.
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::bridge_tx_wake_queue(ndev);
    }

    let work_done = work_done as c_int;
    if work_done < budget {
        // Tell NAPI we're done; kernel re-enables IRQs at its end. We
        // re-arm our IMR so the next event triggers an IRQ.
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::bridge_napi_complete_done(ndev, work_done);
        state.regs().set_imr(regs::INTR_M4_BASELINE);
    }
    work_done
}
