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

use crate::netdev::{IrqMode, NetdevState, RxSlot};
use crate::regs;
use crate::ring::{Descriptor, RING_LEN};
#[allow(clippy::unsafe_removed_from_name)]
use crate::unsafe_boundary as ub;

// Per-descriptor RX length advertised to the chip is now per-MTU (M6 #2
// v3): the pool's device-writable `buf_len` (already ≤ `DESC_LEN_MASK`,
// the 14-bit descriptor field). It's read once per poll from
// `state.rx.buf_len` and reused for both the frame-length clamp and the
// descriptor LEN field — see `process_rx_completions`.

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
pub(crate) fn rearm_irq_baseline(state: &NetdevState) {
    match (state.irq_mode(), state.use_v2_irq_surface()) {
        (IrqMode::Msi, true) => state.regs().set_imr_v2_mask(regs::INTR_V2_M4_BASELINE),
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

/// Walk the RX descriptor ring from `state.rx.tail` while OWN-clear
/// slots remain and `work_done < budget_u`. Each frame is built into
/// an skb, hardware-CSUM annotated, handed to GRO, and the descriptor
/// re-posted with the same slot's DMA address. Returns the new
/// `work_done` count. Streaming-DMA sync is performed before
/// (`for_cpu`) and after (`for_device`) the CPU touches the slot — no-op
/// on x86 cache-coherent DMA but mandatory for ARM/RISC-V portability.
fn process_rx_completions(state: &NetdevState, budget_u: usize) -> usize {
    let mut work_done = 0usize;
    let mut rx_tail = state.rx.tail.inner.load(Ordering::Acquire);
    // Candidate F (RX_OPTIMIZATION_CANDIDATES.md §F): hoist the
    // `ndev` atomic load out of the per-packet loop. `ndev` is
    // invariant across the whole NAPI poll call — load it once.
    let ndev = state.ndev.load(Ordering::Acquire);
    // Per-MTU buffer length for this open (M6 #2 v3): drives both the
    // frame-length clamp and the descriptor LEN field. Invariant across
    // the poll, so load once. Already ≤ DESC_LEN_MASK (the cshim caps it).
    let buf_len = state.rx.buf_len.load(Ordering::Relaxed);
    let buf_desc_len = buf_len & regs::DESC_LEN_MASK;
    let buf_len = buf_len as usize;
    while work_done < budget_u {
        let desc = ub::desc_read(state.rx.desc, rx_tail);
        // Hardware sets OWN; if still set, this slot isn't filled yet — stop.
        if desc.opts1 & regs::DESC_OWN != 0 {
            break;
        }
        // Pair with the device's OWN-clear publish before reading
        // descriptor fields or the DMA buffer contents. r8169 uses
        // the same dma_rmb() barrier after DescOwn clears.
        ub::dma_rmb();
        // Lower 14 bits of opts1 are the RX frame length (incl. CRC; chip
        // typically strips CRC — same convention as r8169). Cap at the
        // buffer size for safety.
        let len = (desc.opts1 & regs::DESC_LEN_MASK) as usize;
        let len = core::cmp::min(len, buf_len);

        // Default re-post address is the slot's current DMA buffer (the
        // `len == 0` case below never consumes it, so it stays
        // device-owned and needs no refill).
        let slot_dma = state.rx.slot_dma[rx_tail].load(Ordering::Relaxed);
        let mut post_dma = slot_dma;
        if len > 0 {
            // RX super-call (RX_OPTIMIZATION_CANDIDATES.md §B + per-MTU #3):
            // zero-copy napi_build_skb + page-pool recycle, with
            // alloc-before-consume refill. The received page is handed to
            // the stack (no copy) and the slot is refilled with a fresh
            // page; the call returns the slot's new (cpu, dma). On a refill
            // failure it drops the frame and returns the old (cpu, dma)
            // unchanged. The cshim handles all §6.3 counter accounting.
            let slot_cpu = state.rx.slot_cpu[rx_tail].load(Ordering::Relaxed);
            let (new_cpu, new_dma) = ub::bridge_rx_one_packet(
                ndev,
                slot_dma,
                slot_cpu.cast_const(),
                len,
                desc.opts1,
                desc.opts2,
            );
            // Publish the refilled buffer into the slot shadow so the next
            // wrap-around reads the live page, not the one now owned by the
            // stack. (No-op store on the drop path — values are unchanged.)
            state.set_rx_slot(
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
            state.rx.desc,
            rx_tail,
            Descriptor {
                opts1,
                opts2: 0,
                addr: post_dma,
            },
        );

        rx_tail = (rx_tail + 1) % RING_LEN;
        work_done += 1;
    }
    state.rx.tail.inner.store(rx_tail, Ordering::Release);
    work_done
}

/// Walk TX from `state.tx.tail` toward `state.tx.head`; for each
/// descriptor whose OWN bit hardware cleared, unmap the matching shadow
/// DMA mapping and `napi_consume_skb` the LastFrag-slot skb. Returns
/// `(advanced_tail, head_snapshot, reaped_count)`. The caller is
/// responsible for storing the new tail and the wake-queue hysteresis —
/// keeping that in `poll` proper preserves the §7 M5 ordering check
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
    while tx_tail != tx_head {
        let slot = tx_tail % RING_LEN;
        let desc = ub::desc_read(state.tx.desc, slot);
        if desc.opts1 & regs::DESC_OWN != 0 {
            // Hardware still owns this slot — stop here.
            break;
        }
        // M4-perf phase 2 (SG): every descriptor in a logical packet has
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
        let raw_skb = state.tx.shadow[slot].swap(ptr::null_mut(), Ordering::AcqRel);
        if let Some(skb) = crate::skb::DriverOwnedSkb::from_raw_nullable(raw_skb) {
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
    (tx_tail, tx_head, reaped)
}

/// Called from the cshim's `bridge_napi_poll` (which is the kernel's NAPI
/// poll callback). `budget` bounds how many RX frames may pass to the
/// stack in this round; we also reap as many TX completions as available.
///
/// Returns `work_done` in `[0, budget]`. See the module docstring for
/// the §6.3 / §7-M5 contract this function must satisfy.
pub(crate) fn poll(state: &NetdevState, budget: c_int) -> c_int {
    crate::netdev::note_napi_poll(state);
    // `budget == 0` is the explicit "TX-cleanup only" path (plan §7 M5).
    // The kernel uses it during netpoll / netconsole and during certain
    // shutdown sequences. We skip the RX loop entirely (no skb-build,
    // no GRO, no page-pool touches) and DO NOT call napi_complete_done
    // at the bottom — the `work_done < budget` check naturally fails
    // because budget is 0 and work_done starts at 0.
    let budget_u = if budget <= 0 { 0 } else { budget as usize };

    let work_done = process_rx_completions(state, budget_u);
    let (tx_tail, tx_head, reaped) = process_tx_completions(state);
    if reaped > 0 {
        // Update tx_tail BEFORE waking the queue — kernel xmit code re-
        // reads tx_tail (indirectly through `in_flight`) to decide whether
        // to start posting again. Stale tail with woken queue means an
        // immediate NETDEV_TX_BUSY.
        state.tx.tail.inner.store(tx_tail, Ordering::Release);
        // Pair with the `fence(SeqCst)` in `stop_tx_queue_with_recheck`: this
        // full StoreLoad barrier orders the `tx_tail` publish (and the
        // inflight-bytes subtract done in `process_tx_completions` above)
        // before the wake decision, so xmit's recheck and our wake can never
        // both miss each other (Dekker). Without it the queue can wedge XOFF
        // forever under UDP TX. See netdev::stop_tx_queue_with_recheck.
        core::sync::atomic::fence(Ordering::SeqCst);
        let in_flight = tx_head.wrapping_sub(tx_tail);
        let free = RING_LEN - in_flight;
        // Wake only when we've drained past the start threshold AND in-flight
        // bytes are back under the byte-budget low-water. This is the wake-side
        // half of the hysteresis (xmit stops the queue at `TX_STOP_THRS` or at
        // the byte budget); `tx_should_wake` folds in both so we don't thrash
        // kernel queue state on every reaped descriptor, and don't re-open the
        // queue while it's still over the latency byte budget.
        if crate::netdev::tx_should_wake(state, free) {
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
