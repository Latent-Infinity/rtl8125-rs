// SPDX-License-Identifier: GPL-2.0
//! NAPI poll body — plan §7 M4 (initial), §7 M5 (hardening).
//!
//! ## NAPI contract this body must satisfy (plan §7 M5)
//!
//! 1. **`budget == 0`** is an explicit "TX cleanup only" call:
//!    the kernel uses it to drain TX completions without consuming RX
//!    quota. We MUST NOT run the RX loop, MUST NOT call any
//!    skb-build/page-pool/XDP API, and MUST NOT call
//!    `napi_complete_done`. We may still run the TX reaper.
//! 2. **Exactly-budget consumed** (`work_done == budget`): return
//!    `budget` *without* calling `napi_complete_done`. The kernel
//!    re-polls us so we keep IRQs masked. Returning `work_done <
//!    budget` is the only path that calls `napi_complete_done` (and
//!    only that path re-arms our IMR).
//! 3. **IRQ-masking discipline**: the IRQ handler masked our IMR
//!    before scheduling NAPI; we re-arm it ONLY when we call
//!    `napi_complete_done` (case 2 above's negation), so IRQs stay
//!    masked across the entire scheduled poll cycle.
//! 4. **Queue stop/wake**: ring indices are updated BEFORE we touch
//!    `netif_tx_wake_queue` (or `_stop_queue` in xmit). Wake only
//!    fires when free slots cross the start-threshold (hysteresis)
//!    so we don't ping-pong with the producer.
//! 5. **TX completion exactly once**: each slot's skb pointer is
//!    consumed via `AtomicPtr::swap(null)` — the swap returns the
//!    prior value atomically, so a concurrent caller would observe
//!    `null` and skip the consume.
//!
//! `ci/check_napi_contract.sh` enforces these invariants statically.

use core::ffi::c_int;
use core::ptr;
use core::sync::atomic::Ordering;

use crate::netdev::{IrqMode, NetdevState, RX_BUF_LEN};
use crate::regs;
use crate::ring::{Descriptor, RING_LEN};
#[allow(clippy::unsafe_removed_from_name)]
use crate::unsafe_boundary as ub;

/// Re-arm the chip's interrupt sources to the baseline mask. Branches on
/// the probe-chosen [`IrqMode`]:
///
///   * `Intx` → write `INTR_M4_BASELINE` to legacy `IMR` (0x38).
///   * `Msi`  → write `INTR_V2_M4_BASELINE` to `IMR_V2_SET` (0x0D0C);
///     bits in this register are unmask-set semantics, so the same write
///     re-arms after each NAPI cycle without first clearing.
///
/// Centralized here so the three call sites (ndo_open initial unmask,
/// the IRQ handler tail, and napi_complete_done) read the same surface
/// choice — keeping the IMR/IMR_V2 selection in one place keeps the
/// invariant from drifting as the V2 surface gets used elsewhere.
pub(crate) fn rearm_irq_baseline(state: &NetdevState) {
    match state.irq_mode() {
        IrqMode::Intx => state.regs().set_imr(regs::INTR_M4_BASELINE),
        IrqMode::Msi => state.regs().set_imr_v2_mask(regs::INTR_V2_M4_BASELINE),
    }
}

/// Wake the TX queue only when at least this many descriptors are free.
/// **Must pair** with [`netdev::TX_STOP_THRS`](crate::netdev) (= 32) —
/// stop when free slots drop below STOP_THRS, wake only when they
/// climb back past START_THRS. Without hysteresis the queue oscillates
/// between stopped and woken on every reaped descriptor. 2× the stop
/// threshold matches r8169's `R8169_TX_START_THRS = 2 *
/// R8169_TX_STOP_THRS` discipline. When changing this, also revisit
/// `netdev::TX_STOP_THRS` — they're a paired tuning surface.
///
/// Related policy knobs in the cshim (`src/netdev_bridge.c`):
/// `BRIDGE_NAPI_WEIGHT`, `netif_set_tso_max_segs`, `netif_set_tso_max_size`.
pub(crate) const TX_START_THRS: usize = 64;

/// Called from the cshim's `bridge_napi_poll` (which is the kernel's NAPI
/// poll callback). `budget` bounds how many RX frames may pass to the
/// stack in this round; we also reap as many TX completions as available.
///
/// Returns `work_done` in `[0, budget]`. See the module docstring for
/// the §6.3 / §7-M5 contract this function must satisfy.
pub(crate) fn poll(state: &NetdevState, budget: c_int) -> c_int {
    crate::netdev::note_napi_poll();
    // `budget == 0` is the explicit "TX-cleanup only" path (plan §7 M5).
    // The kernel uses it during netpoll / netconsole and during certain
    // shutdown sequences. We skip the RX loop entirely (no skb-build,
    // no GRO, no page-pool touches) and DO NOT call napi_complete_done
    // at the bottom — the `work_done < budget` check naturally fails
    // because budget is 0 and work_done starts at 0.
    let budget_u = if budget <= 0 { 0 } else { budget as usize };
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
        // Update tx_tail BEFORE waking the queue — kernel xmit code re-
        // reads tx_tail (indirectly through `in_flight`) to decide whether
        // to start posting again. Stale tail with woken queue means an
        // immediate NETDEV_TX_BUSY.
        state.tx_tail.inner.store(tx_tail, Ordering::Release);
        let in_flight = tx_head.wrapping_sub(tx_tail);
        let free = RING_LEN - in_flight;
        // Wake only when we've drained past the start threshold. This is
        // the wake-side half of the hysteresis (xmit stops the queue at
        // `TX_STOP_THRS`); without it we'd thrash kernel queue state on
        // every single reaped descriptor.
        if free > TX_START_THRS {
            let ndev = state.ndev.load(Ordering::Acquire);
            ub::bridge_tx_wake_queue(ndev);
        }
    }

    let work_done = work_done as c_int;
    if work_done < budget {
        // See module docstring for the §7 M5 contract: `budget == 0`
        // falls through this branch (0 < 0 is false) so we don't
        // call complete_done in the TX-cleanup-only path.
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::bridge_napi_complete_done(ndev, work_done);
        rearm_irq_baseline(state);
    }
    // If `work_done == budget`, return without complete_done so the
    // kernel re-polls us — IRQs stay masked across the re-poll.
    work_done
}
