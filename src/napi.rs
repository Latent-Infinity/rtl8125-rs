// SPDX-License-Identifier: GPL-2.0
//! NAPI poll body.
//!
//! ## NAPI contract this body must satisfy
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

use crate::netdev::{IrqMode, NetdevState, RxSlot};
use crate::regs;
use crate::ring::{Descriptor, RING_LEN};
#[allow(clippy::unsafe_removed_from_name)]
use crate::unsafe_boundary as ub;

// Internal hash-type encoding used for FFI until Rust/bindings expose
// Linux's skb hash-type constants in-kernel.
const RX_HASH_INFO_VALID_BIT: u64 = 1u64 << 63;
const RX_HASH_INFO_L4_BIT: u64 = 1u64 << 62;
const RX_HASH_INFO_ENABLED_BIT: u64 = 1u64 << 61;
const RX_HASH_INFO_VALUE_MASK: u64 = 0xFFFF_FFFF;

// Per-descriptor RX length advertised to the chip is now per-MTU:
// the pool's device-writable `buf_len` (already ≤ `DESC_LEN_MASK`,
// the 14-bit descriptor field). It's read once per poll from
// the selected queue's `buf_len` and reused for both the frame-length clamp
// and the descriptor LEN field — see `process_rx_completions`.

/// Re-arm the chip's interrupt sources to the baseline mask. Branches on
/// the probe-chosen [`IrqMode`]:
///
///   * `Intx` → write `INTR_M4_BASELINE` to legacy `IMR` (0x38).
///   * `Msi` with `use_v2=true` → write `INTR_V2_M4_BASELINE` to
///     `IMR_V2_SET` (0x0D0C).
///     Bits in this register are unmask-set semantics, so the same write
///     re-arms after each NAPI cycle without first clearing.
///   * `Msi` with `use_v2=false` → write legacy `IMR`; this is the default
///     one-vector MSI/MSI-X path so TX completions share vector 0.
///
/// Centralized here so the three call sites (ndo_open initial unmask,
/// the IRQ handler tail, and napi_complete_done) read the same surface
/// choice — keeping the IMR/IMR_V2 selection in one place keeps the
/// invariant from drifting as the V2 surface gets used elsewhere.
// Queue 0's per-queue V2 re-arm mask must equal the documented baseline
// (`ROK_Q0 | TOK_Q0 | LINKCHG`) — queue 0 owns RX0 + TX + link. Compile-time
// tie so the host-tested `v2_queue_rearm_mask` and the `regs` baseline can't
// drift apart.
const _: () = assert!(
    crate::layout::v2_queue_rearm_mask(
        0,
        regs::ISRIMR_V2_ROK_Q0,
        regs::ISRIMR_V2_TOK_Q0,
        regs::ISRIMR_V2_LINKCHG,
    ) == regs::INTR_V2_M4_BASELINE
);

pub(crate) fn rearm_irq_baseline(state: &NetdevState, queue_id: u32) {
    match (state.irq_mode(), state.use_v2_irq_surface()) {
        // V2: re-arm only the source bits this queue owns — its own ROK, plus
        // TX-completion + link-change for queue 0. The per-vector handler masked
        // exactly those. For queue 0 this equals INTR_V2_M4_BASELINE.
        (IrqMode::Msi, true) => state
            .regs()
            .set_imr_v2_mask(crate::layout::v2_queue_rearm_mask(
                queue_id,
                regs::ISRIMR_V2_ROK_Q0,
                regs::ISRIMR_V2_TOK_Q0,
                regs::ISRIMR_V2_LINKCHG,
            )),
        (IrqMode::Intx, _) | (IrqMode::Msi, false) => state.regs().set_imr(regs::INTR_M4_BASELINE),
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

/// Walk the selected RX queue descriptor ring from its tail while OWN-clear
/// slots remain and `work_done < budget_u`. Each frame is built into
/// an skb, hardware-CSUM annotated, handed to GRO, and the descriptor
/// re-posted with the same slot's DMA address. Returns the new
/// `work_done` count. Streaming-DMA sync is performed before
/// (`for_cpu`) and after (`for_device`) the CPU touches the slot — no-op
/// on x86 cache-coherent DMA but mandatory for ARM/RISC-V portability.
fn process_rx_completions(state: &NetdevState, queue_id: u32, budget_u: usize) -> usize {
    let Some(rx) = state.rx_queue(queue_id) else {
        return 0;
    };
    // Hoist the `ndev` atomic load out of the per-packet loop. `ndev` is
    // invariant across the whole NAPI poll call — load it once.
    let ndev = state.ndev.load(Ordering::Acquire);
    // AF_XDP zero-copy queues use a dedicated producer/consumer poll: the slot
    // buffers are umem chunks consumed by the XDP verdict and refilled from the
    // fill ring, not page_pool pages handed up via build_skb.
    if ub::bridge_rxq_is_zc(ndev, queue_id) {
        return process_rx_completions_zc(rx, queue_id, budget_u, ndev);
    }
    let mut work_done = 0usize;
    let mut rx_tail = rx.tail.inner.load(Ordering::Acquire);
    let rx_hash_enabled = state.rx_hash_enabled.load(Ordering::Relaxed);
    // Per-MTU buffer length for this open: drives both the
    // frame-length clamp and the descriptor LEN field. Invariant across
    // the poll, so load once. Already ≤ DESC_LEN_MASK (the cshim caps it).
    let buf_len = rx.buf_len.load(Ordering::Relaxed);
    let buf_desc_len = buf_len & regs::DESC_LEN_MASK;
    let buf_len = buf_len as usize;
    // Resolve the descriptor format ONCE per poll into precomputed byte offsets
    // so the hot loop has no per-packet `match RxDescFormat` and no double read.
    let parse = crate::ring::RxParse::new(rx.format);
    let rx_ring = rx.desc.cast::<u8>();
    while work_done < budget_u {
        // Cheap OWN check first (single word read, pre-barrier). If the slot is
        // still device-owned it isn't filled yet — stop.
        if ub::rx_read_opts1(rx_ring, rx_tail, &parse) & regs::DESC_OWN != 0 {
            break;
        }
        // Pair with the device's OWN-clear publish before reading the rest of
        // the descriptor or the DMA buffer. r8169 uses the same dma_rmb() after
        // DescOwn clears.
        ub::dma_rmb();
        // One full descriptor fetch, post-barrier (no per-packet format match).
        let completion = ub::rx_read_completion(rx_ring, rx_tail, &parse);
        // Lower 14 bits of opts1 are the RX frame length (incl. CRC; chip
        // typically strips CRC — same convention as r8169). Cap at the
        // buffer size for safety.
        let len = completion.len;
        let len = core::cmp::min(len, buf_len);

        // Default re-post address is the slot's current DMA buffer (the
        // `len == 0` case below never consumes it, so it stays
        // device-owned and needs no refill).
        let slot_dma = rx.slot_dma[rx_tail].load(Ordering::Relaxed);
        let mut post_dma = slot_dma;
        if len > 0 {
            // RX super-call (zero-copy + per-MTU):
            // zero-copy napi_build_skb + page-pool recycle, with
            // alloc-before-consume refill. The received page is handed to
            // the stack (no copy) and the slot is refilled with a fresh
            // page; the call returns the slot's new (cpu, dma). On a refill
            // failure it drops the frame and returns the old (cpu, dma)
            // unchanged. The cshim handles all counter accounting.
            let slot_cpu = rx.slot_cpu[rx_tail].load(Ordering::Relaxed);
            let hash_info = if !rx_hash_enabled {
                0
            } else {
                completion.rss_hash.map_or(0, |h| {
                    let is_l4 = match h.kind {
                        crate::ring::RxHashType::L3 => false,
                        crate::ring::RxHashType::L4 => true,
                    };
                    RX_HASH_INFO_ENABLED_BIT
                        | RX_HASH_INFO_VALID_BIT
                        | (u64::from(is_l4) * RX_HASH_INFO_L4_BIT)
                        | (u64::from(h.value) & RX_HASH_INFO_VALUE_MASK)
                })
            };
            let (new_cpu, new_dma) = ub::bridge_rx_one_packet(
                ndev,
                queue_id,
                slot_dma,
                slot_cpu.cast_const(),
                len,
                completion.opts1,
                completion.opts2,
                hash_info,
            );
            // Publish the refilled buffer into the slot shadow so the next
            // wrap-around reads the live page, not the one now owned by the
            // stack. (No-op store on the drop path — values are unchanged.)
            rx.set_slot(
                rx_tail,
                RxSlot {
                    cpu: new_cpu,
                    dma: new_dma,
                },
            );
            post_dma = new_dma;
        }

        // Re-post the descriptor with the (possibly refilled) DMA address.
        let mut opts1 = regs::DESC_OWN | buf_desc_len;
        if rx_tail == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        // Publish OWN only after addr/opts2 are visible to the device.
        ub::desc_publish_own(
            rx.desc.cast::<u8>(),
            rx_tail,
            crate::ring::Descriptor {
                opts1,
                opts2: 0,
                addr: post_dma,
            },
            rx.format,
        );

        rx_tail = (rx_tail + 1) % RING_LEN;
        work_done += 1;
    }
    rx.tail.inner.store(rx_tail, Ordering::Release);
    work_done
}

/// AF_XDP zero-copy RX poll (producer/consumer over the umem fill ring).
///
/// Unlike the page_pool path — which keeps every slot permanently posted and
/// refills each slot inline as it is consumed — a ZC queue tracks a posted
/// window `[tail, tail+posted)` of chip-owned umem buffers. The umem fill ring is
/// usually (partly) empty at open and is topped up here / on `ndo_xsk_wakeup`.
///
/// Two phases:
///   1. Consume — for each chip-filled slot at `tail` (OWN clear) inside the
///      posted window, run the XDP verdict via the cshim (redirect to the bound
///      socket zero-copy / copy-to-skb on PASS / drop), mark the slot empty,
///      publish a host-owned descriptor, and advance `tail` (`posted--`).
///   2. Refill — post fresh umem buffers at the far edge of the window
///      (`(tail+posted) % RING_LEN`) until the ring is full or the fill ring is
///      exhausted (then `ndo_xsk_wakeup` re-kicks the poll later).
fn process_rx_completions_zc(
    rx: &crate::netdev::RxQueueState,
    queue_id: u32,
    budget_u: usize,
    ndev: *mut kernel::bindings::net_device,
) -> usize {
    // Serialise against ndo_xsk_wakeup's synchronous refill (which runs in
    // process context, possibly on another CPU). On contention the wakeup is
    // already refilling this ring, so skip — the next poll/IRQ re-runs us.
    if !rx.try_xsk_lock() {
        return 0;
    }
    let mut work_done = 0usize;
    let mut rx_tail = rx.tail.inner.load(Ordering::Acquire);
    let mut posted = rx.posted.inner.load(Ordering::Relaxed);
    let buf_len = rx.buf_len.load(Ordering::Relaxed) as usize;
    let parse = crate::ring::RxParse::new(rx.format);
    let rx_ring = rx.desc.cast::<u8>();

    // Phase 1: consume chip-filled slots in the posted window.
    while work_done < budget_u && posted > 0 {
        if ub::rx_read_opts1(rx_ring, rx_tail, &parse) & regs::DESC_OWN != 0 {
            break; // chip still owns `tail` — nothing newly filled
        }
        ub::dma_rmb();
        let completion = ub::rx_read_completion(rx_ring, rx_tail, &parse);
        let len = core::cmp::min(completion.len, buf_len);
        let slot_cpu = rx.slot_cpu[rx_tail].load(Ordering::Relaxed);
        if !slot_cpu.is_null() {
            if len > 0 {
                ub::bridge_xsk_rx_consume(ndev, queue_id, slot_cpu, len);
            } else {
                // Zero-length completion: recycle the umem chunk, deliver nothing.
                ub::rx_free(ndev, queue_id, slot_cpu);
            }
        }
        // Slot is now empty; publish a host-owned (no buffer) descriptor so the
        // chip cannot DMA into the consumed buffer before the refill re-posts it.
        rx.set_slot(rx_tail, crate::netdev::RxSlot::EMPTY);
        let mut opts1 = 0u32;
        if rx_tail == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        ub::desc_publish_own(
            rx_ring,
            rx_tail,
            crate::ring::Descriptor {
                opts1,
                opts2: 0,
                addr: 0,
            },
            rx.format,
        );
        rx_tail = (rx_tail + 1) % RING_LEN;
        posted -= 1;
        work_done += 1;
    }
    // Publish the consumer position before the refill reads it.
    rx.tail.inner.store(rx_tail, Ordering::Release);
    rx.posted.inner.store(posted, Ordering::Relaxed);

    // Phase 2: refill the empty window from the umem fill ring (the same routine
    // ndo_xsk_wakeup uses for the cold-start kick).
    zc_refill_locked(rx, queue_id, ndev);

    rx.xsk_unlock();
    work_done
}

/// Post fresh umem buffers into the ZC RX ring's empty window
/// `[(tail + posted) ..)` until the ring is full or the umem fill ring is
/// exhausted, then advertise RX need-wakeup accordingly. The CALLER must hold the
/// queue's `xsk_lock`. This is the single refill shared by the NAPI poll and
/// `ndo_xsk_wakeup`'s synchronous cold-start kick (via `rust_xsk_kick`) — the
/// chip can take no RX IRQ with an empty ring, so the wakeup must post buffers
/// itself rather than only scheduling NAPI.
pub(crate) fn zc_refill_locked(
    rx: &crate::netdev::RxQueueState,
    queue_id: u32,
    ndev: *mut kernel::bindings::net_device,
) {
    let rx_tail = rx.tail.inner.load(Ordering::Acquire);
    let mut posted = rx.posted.inner.load(Ordering::Relaxed);
    let buf_desc_len = rx.buf_len.load(Ordering::Relaxed) & regs::DESC_LEN_MASK;
    let rx_ring = rx.desc.cast::<u8>();
    let mut fill_exhausted = false;
    while posted < RING_LEN {
        match ub::rx_alloc(ndev, queue_id) {
            Ok((cpu, dma)) => {
                let idx = (rx_tail + posted) % RING_LEN;
                rx.set_slot(idx, crate::netdev::RxSlot { cpu, dma });
                let mut opts1 = regs::DESC_OWN | buf_desc_len;
                if idx == RING_LEN - 1 {
                    opts1 |= regs::DESC_EOR;
                }
                ub::desc_publish_own(
                    rx_ring,
                    idx,
                    crate::ring::Descriptor {
                        opts1,
                        opts2: 0,
                        addr: dma,
                    },
                    rx.format,
                );
                posted += 1;
            }
            Err(_) => {
                fill_exhausted = true;
                break; // fill ring empty — userspace re-kicks after replenishing
            }
        }
    }
    rx.posted.inner.store(posted, Ordering::Relaxed);
    // Tell userspace to kick us (ndo_xsk_wakeup) once it replenishes the fill
    // ring; clear the flag while we still have buffers to post into.
    ub::bridge_xsk_set_rx_wakeup(ndev, queue_id, fill_exhausted);
}

/// Walk TX from `state.tx.tail` toward `state.tx.head`; for each
/// descriptor whose OWN bit hardware cleared, unmap the matching shadow
/// DMA mapping and `napi_consume_skb` the LastFrag-slot skb. Returns
/// `(advanced_tail, head_snapshot, reaped_count)`. The caller is
/// responsible for storing the new tail and the wake-queue hysteresis —
/// keeping that in `poll` proper preserves the ordering check
/// (`tx_tail` stored before any `bridge_tx_wake_queue`).
fn process_tx_completions(state: &NetdevState) -> (usize, usize, usize) {
    let mut tx_tail = state.tx.tail.inner.load(Ordering::Acquire);
    let tx_head = state.tx.head.inner.load(Ordering::Acquire);
    let ndev = state.ndev.load(Ordering::Acquire);
    let mut reaped = 0usize;
    // Completed logical packets (skbs = LastFrag slots), full wire bytes for
    // stats/BQL, and the subset that was tracked by the driver-owned
    // byte-budget throttle at xmit commit.
    let mut completed_pkts = 0usize;
    let mut completed_bytes = 0usize;
    let mut completed_budget_bytes = 0usize;
    // AF_XDP zero-copy TX completions, batched per RX queue id (the pool that
    // owns the umem chunk), drained to xsk_tx_completed after the reap loop.
    let mut xsk_completed = [0u32; crate::netdev::RX_QUEUE_COUNT];
    while tx_tail != tx_head {
        let slot = tx_tail % RING_LEN;
        let desc = ub::desc_read(state.tx.desc, slot);
        if desc.opts1 & regs::DESC_OWN != 0 {
            // Hardware still owns this slot — stop here.
            break;
        }
        // SG: every descriptor in a logical packet has
        // its own DMA mapping that must be unmapped here. The skb pointer
        // is in the LastFrag slot only; intermediate frags get null.
        let map_addr = state.tx.shadow_dma[slot].load(Ordering::Acquire);
        let map_len = state.tx.shadow_len[slot].load(Ordering::Acquire) as usize;
        if map_len > 0 {
            if state.tx.shadow_is_frag[slot].swap(false, Ordering::AcqRel) {
                ub::skb_dma_unmap_frag_tx(&state.pdev, map_addr, map_len);
            } else {
                ub::skb_dma_unmap_tx(&state.pdev, map_addr, map_len);
            }
            // Mark slot's mapping as consumed so a follow-on read can't
            // see stale state if the shadow is reused before the next
            // xmit overwrites it.
            state.tx.shadow_len[slot].store(0, Ordering::Release);
        }
        // Reclaim the disposition tag and the slot pointer together. The tag
        // selects how to release the pointer; reset it to `Skb` (the default)
        // so a slot reused by a later xmit can't be misread as an XDP frame.
        let kind = crate::netdev::TxSlotKind::from_u8(
            state.tx.shadow_kind[slot].swap(crate::netdev::TxSlotKind::Skb as u8, Ordering::AcqRel),
        );
        let raw = state.tx.shadow[slot].swap(ptr::null_mut(), Ordering::AcqRel);
        match kind {
            crate::netdev::TxSlotKind::Xdp => {
                // XDP_TX completion: the slot holds an `xdp_frame`, not an skb.
                // The DMA unmap already ran above (shadow_len carried the frame
                // length). Return the frame to its origin RX page_pool via the
                // mem model captured at xdp_rxq registration. XDP_TX never went
                // through `rust_xmit`, so it is deliberately absent from the skb
                // disposition invariant — no tx_consumed / BQL / byte-budget.
                if !raw.is_null() {
                    ub::xdp_return_frame(raw.cast());
                }
            }
            crate::netdev::TxSlotKind::XskTx => {
                // AF_XDP zero-copy TX completion: the descriptor addr was a umem
                // chunk owned by the socket (no skb / xdp_frame, no per-frame DMA
                // unmap — shadow_len was 0 above). Tally it against the owning
                // queue's pool; xsk_tx_completed runs once per queue after the
                // loop. Not part of the skb disposition invariant.
                let qid = state.tx.shadow_xsk_qid[slot].load(Ordering::Acquire) as usize;
                if qid < xsk_completed.len() {
                    xsk_completed[qid] += 1;
                }
            }
            crate::netdev::TxSlotKind::Skb => {
                if let Some(skb) = crate::skb::DriverOwnedSkb::from_raw_nullable(raw) {
                    // LastFrag of a logical packet — reclaim the disposition
                    // obligation from the shadow and hand the skb back to NAPI
                    // (stats drain happens inside `consume_tx`). The DMA unmap
                    // for THIS slot already happened above; for SG packets the
                    // intermediate slots' unmaps happened in earlier loop iters.
                    completed_budget_bytes +=
                        state.tx.shadow_budget_len[slot].swap(0, Ordering::AcqRel) as usize;
                    completed_bytes += skb.consume_tx(ndev);
                    completed_pkts += 1;
                }
            }
        }
        // Clear the descriptor (preserve EOR if last slot).
        let mut opts1 = 0u32;
        if slot == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        ub::desc_write(
            state.tx.desc,
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
    // Byte-budget throttle (test 5): return this batch's tracked bytes to the
    // driver-owned in-flight counter. Small packets whose full descriptor window
    // is below the budget are not tracked, so their shadow contributes zero.
    // `saturating_sub` makes the decrement underflow-proof — if the counter
    // ever drifted below the batch (it shouldn't, since xmit writes the same
    // shadow length that the reaper consumes here),
    // wrapping to usize::MAX would wedge the queue stopped forever via
    // tx_should_wake, so we floor at 0 instead.
    if completed_budget_bytes > 0 {
        let _ =
            state
                .tx
                .inflight_bytes
                .inner
                .fetch_update(Ordering::AcqRel, Ordering::Acquire, |v| {
                    Some(v.saturating_sub(completed_budget_bytes))
                });
    }
    // BQL: report the completed batch once (dql_completed + auto-wake). Gated
    // by the SAME predicate as the xmit-side netdev_sent_queue (bql_active) so
    // dql can never imbalance (completed without a matching sent). Safe default
    // skips MSI delivery; see crate::netdev::bql_active + docs/perf/bql_20260605/.
    if completed_pkts > 0 && crate::netdev::bql_active(state) {
        ub::netdev_completed_queue(ndev, completed_pkts, completed_bytes);
    }
    // Drain AF_XDP zero-copy TX completions back to each socket's completion ring.
    for (qid, &count) in xsk_completed.iter().enumerate() {
        if count > 0 {
            ub::bridge_xsk_tx_completed(ndev, qid as u32, count);
        }
    }
    (tx_tail, tx_head, reaped)
}

/// Called from the cshim's `bridge_napi_poll` (which is the kernel's NAPI
/// poll callback). `budget` bounds how many RX frames may pass to the
/// stack in this round; we also reap as many TX completions as available.
///
/// Returns `work_done` in `[0, budget]`. See the module docstring for
/// the contract this function must satisfy.
pub(crate) fn poll(state: &NetdevState, queue_id: u32, budget: c_int) -> c_int {
    crate::netdev::note_napi_poll(state);
    // `budget == 0` is the explicit "TX-cleanup only" path.
    // The kernel uses it during netpoll / netconsole and during certain
    // shutdown sequences. We skip the RX loop entirely (no skb-build,
    // no GRO, no page-pool touches) and DO NOT call napi_complete_done
    // at the bottom — the `work_done < budget` check naturally fails
    // because budget is 0 and work_done starts at 0.
    let budget_u = if budget <= 0 { 0 } else { budget as usize };

    let work_done = process_rx_completions(state, queue_id, budget_u);
    // Flush any XDP_REDIRECT'd frames once per poll (no-op if none / no prog).
    if budget_u > 0 {
        ub::bridge_xdp_finalize(state.ndev.load(Ordering::Acquire), queue_id);
    }
    // TX is a single ring owned by RX queue 0: the tx0 MSI-X vector schedules
    // queue 0's NAPI (see netdev::v2_vector_source). ONLY queue 0 reaps it —
    // letting queues 1..N also call process_tx_completions would race the shared
    // TX shadow/tail across NAPIs (corrupting completion accounting + double
    // `dma_unmap` → IOVA corruption → sporadic TX DMA-map failures, the
    // any-queue reaper race). The tx0 vector keeps queue 0 scheduled to drain
    // TX; with per-vector IRQ affinity each queue's DMA stays on one CPU so
    // reaping keeps up.
    if queue_id == crate::netdev::RX_QUEUE0 {
        let (tx_tail, tx_head, reaped) = process_tx_completions(state);
        if reaped > 0 {
            // Update tx_tail BEFORE waking the queue — kernel xmit code re-
            // reads tx_tail (indirectly through `in_flight`) to decide whether
            // to start posting again. Stale tail with woken queue means an
            // immediate NETDEV_TX_BUSY.
            state.tx.tail.inner.store(tx_tail, Ordering::Release);
            // Pair with the `fence(SeqCst)` in `stop_tx_queue_with_recheck`:
            // this full StoreLoad barrier orders the `tx_tail` publish (and the
            // inflight-bytes subtract done in `process_tx_completions` above)
            // before the wake decision, so xmit's recheck and our wake can never
            // both miss each other (Dekker). Without it the queue can wedge XOFF
            // forever under UDP TX. See netdev::stop_tx_queue_with_recheck.
            core::sync::atomic::fence(Ordering::SeqCst);
            let in_flight = tx_head.wrapping_sub(tx_tail);
            let free = RING_LEN - in_flight;
            // Wake only when we've drained past the start threshold AND in-flight
            // bytes are back under the byte-budget low-water. This is the
            // wake-side half of the hysteresis (xmit stops the queue at
            // `TX_STOP_THRS` or at the byte budget); `tx_should_wake` folds in
            // both so we don't thrash kernel queue state on every reaped
            // descriptor, and don't re-open the queue while it's still over the
            // latency byte budget.
            if crate::netdev::tx_should_wake(state, free) {
                let ndev = state.ndev.load(Ordering::Acquire);
                ub::bridge_tx_wake_queue(ndev);
            }
        }
    }

    // AF_XDP zero-copy TX: drain this queue's bound socket TX ring onto the
    // shared TX ring. Bounded by the free TX-ring slots so the C producer never
    // overflows (any residual xmit race just breaks the drain early). The TX ring
    // is reaped by queue 0, but any ZC queue may produce here under the txq lock.
    if budget_u > 0 {
        let ndev = state.ndev.load(Ordering::Acquire);
        if ub::bridge_rxq_is_zc(ndev, queue_id) {
            let head = state.tx.head.inner.load(Ordering::Acquire);
            let tail = state.tx.tail.inner.load(Ordering::Acquire);
            let in_flight = head.wrapping_sub(tail);
            let free = (RING_LEN - 1).saturating_sub(in_flight);
            let tx_budget = core::cmp::min(free, budget_u);
            if tx_budget > 0 {
                ub::bridge_xsk_tx(ndev, queue_id, tx_budget as i32);
            }
        }
    }

    let work_done = work_done as c_int;
    if work_done < budget {
        // See module docstring for the contract: `budget == 0`
        // falls through this branch (0 < 0 is false) so we don't
        // call complete_done in the TX-cleanup-only path.
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::bridge_napi_complete_done(ndev, queue_id, work_done);
        rearm_irq_baseline(state, queue_id);
    }
    // If `work_done == budget`, return without complete_done so the
    // kernel re-polls us — IRQs stay masked across the re-poll.
    work_done
}
