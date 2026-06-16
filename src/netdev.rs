// SPDX-License-Identifier: GPL-2.0
//! Rust ↔ C bridge surface for the RTL8125 netdev implementation.
//!
//! ## Scope
//!
//! `NetdevState` holds everything the ndo callbacks need: a raw pointer
//! into the mapped BAR (so `ndo_open`/`xmit`/`poll`/IRQ can issue MMIO
//! from any context), plus named TX/RX/IRQ/PHY sub-states. The hot-path
//! state stays explicit: TX/RX descriptor pointers, RX streaming-DMA
//! slots, TX software shadow, and cache-padded ring indices shared
//! between `xmit` (BH context), NAPI poll (softirq), and the IRQ handler.
//!
//! `Box<NetdevState>` is heap-allocated at probe; its raw pointer is the
//! `cookie` the cshim hands back to every callback. The handle wrapper
//! (`NetdevHandle`) owns the cookie + the registered net_device pointer
//! and reclaims both on drop.
//!
//! No `unsafe` lives in this file — every FFI hop goes through
//! `unsafe_boundary` with a `// SAFETY:` block.

use core::ffi::{c_int, c_void};
use core::ptr;
use core::sync::atomic::{
    AtomicBool, AtomicPtr, AtomicU32, AtomicU64, AtomicU8, AtomicUsize, Ordering,
};
// AtomicU64/U32 shadow the per-descriptor DMA mapping (handle/len) for SG.
// AtomicU8 carries the probe-chosen IRQ delivery mode; AtomicU32 carries the
// PHY OCP page selector in `PhyState`.

/// Cache-line padded wrapper. Per `docs/RUST_STANDARDS.md` §15.2, atomics
/// mutated from independent contexts must not share a cache line. False
/// sharing would serialize the contexts under load. 64 B is the L1 line on
/// x86_64 and aarch64 baseline; PowerPC uses 128 but isn't a deployment
/// target. Kernel-Rust has no `crossbeam::utils::CachePadded`, so this is
/// the minimal hand-rolled equivalent.
#[repr(C, align(64))]
pub(crate) struct CachePadded<T> {
    pub(crate) inner: T,
}

impl<T> CachePadded<T> {
    #[inline]
    pub(crate) const fn new(value: T) -> Self {
        Self { inner: value }
    }
}

impl<T> core::ops::Deref for CachePadded<T> {
    type Target = T;
    #[inline]
    fn deref(&self) -> &T {
        &self.inner
    }
}

use kernel::bindings;
use kernel::error::{code::EINVAL, Result};
use kernel::pci;
use kernel::prelude::*;
use kernel::sync::aref::ARef;

/// Low-rate hot-path debug counters. Each is mutated from an independent
/// context: XMIT_CALLS from ndo_start_xmit, IRQ_FIRES from the IRQ handler,
/// and NAPI_POLLS from NAPI poll. Keep them cache-padded per
/// `docs/RUST_STANDARDS.md §15.2`; otherwise unrelated counter updates
/// share one line and create avoidable coherence traffic.
static XMIT_CALLS: CachePadded<AtomicU32> = CachePadded::new(AtomicU32::new(0));
static IRQ_FIRES: CachePadded<AtomicU32> = CachePadded::new(AtomicU32::new(0));
static NAPI_POLLS: CachePadded<AtomicU32> = CachePadded::new(AtomicU32::new(0));
/// TX doorbells (`tx_poll` writes). With `netdev_xmit_more()` batching this is
/// strictly ≤ XMIT_CALLS; the ratio doorbells/xmit_calls under small-frame TX
/// load shows how well the burst is being amortized (≈1.0 = no batching).
static TX_DOORBELLS: CachePadded<AtomicU32> = CachePadded::new(AtomicU32::new(0));

pub(crate) fn debug_counts() -> (u32, u32, u32, u32) {
    (
        XMIT_CALLS.load(Ordering::Relaxed),
        IRQ_FIRES.load(Ordering::Relaxed),
        NAPI_POLLS.load(Ordering::Relaxed),
        TX_DOORBELLS.load(Ordering::Relaxed),
    )
}

fn reset_debug_counts() {
    XMIT_CALLS.store(0, Ordering::Relaxed);
    IRQ_FIRES.store(0, Ordering::Relaxed);
    NAPI_POLLS.store(0, Ordering::Relaxed);
    TX_DOORBELLS.store(0, Ordering::Relaxed);
}

#[inline]
pub(crate) fn debug_counters_active(state: &NetdevState) -> bool {
    state.debug_counters.load(Ordering::Relaxed)
}

pub(crate) fn note_irq_fire(state: &NetdevState) {
    if debug_counters_active(state) {
        IRQ_FIRES.fetch_add(1, Ordering::Relaxed);
    }
}

pub(crate) fn note_napi_poll(state: &NetdevState) {
    if debug_counters_active(state) {
        NAPI_POLLS.fetch_add(1, Ordering::Relaxed);
    }
}

use crate::mmio::{self, Regs};
use crate::regs;
use crate::ring::{Descriptor, RxDescFormat, RxDescriptor, RING_LEN};
use crate::unsafe_boundary::{self as ub, BridgeOps};

/// `NETDEV_TX_OK` / `NETDEV_TX_BUSY` from `include/linux/netdevice.h`.
const NETDEV_TX_OK: c_int = 0;
const NETDEV_TX_BUSY: c_int = 0x10;
const BRIDGE_FEATURE_RXCSUM: u32 = 0x0000_0001;
const BRIDGE_FEATURE_RXVLAN: u32 = 0x0000_0002;
const BRIDGE_FEATURE_RXHASH: u32 = 0x0000_0004;
pub(crate) const RX_QUEUE0: u32 = 0;
/// Compile-time maximum RX queues = the DMA rings, NAPI instances, and per-queue
/// state arrays the driver allocates. RTL8125B's `HwSuppNumRxQueues` is 4. The
/// *runtime* active count is [`active_rx_queues`], so all users share one
/// source of truth.
pub(crate) const RX_QUEUE_COUNT: usize = 4;

/// Runtime number of RX queues actually set up this open — host-tested clamp in
/// [`crate::layout::active_rx_queues`]. `rss_queues=0` (default) ⇒ 1 (the proven
/// single-queue path); multi-queue activation is gated in
/// [`validate_rss_queue_request`].
#[inline]
pub(crate) fn active_rx_queues(state: &NetdevState) -> usize {
    // Multi-queue RX is fully wired (per-queue rings/NAPI, per-vector IRQ
    // routing, RSS spread), so honor the effective `rss_queues` request (the
    // ethtool set_channels runtime override, else the module param) clamped to
    // the compile-time maximum.
    crate::layout::active_rx_queues(requested_rss_queues(state), RX_QUEUE_COUNT)
}

// RXHASH feature gate for descriptor hash reporting. Hardware RSS queue
// distribution is controlled separately by the opt-in rss_queues parameter.
const RXHASH_FEATURE_GATE: bool = true;

/// Stop the TX queue preemptively when fewer than this many descriptor
/// slots remain free. **Must pair** with [`napi::TX_START_THRS`]
/// (= 64) so the reaper only wakes us after enough slots have
/// drained — without hysteresis the kernel-queue state churns on
/// every reaped descriptor and `tx_busy_exception` spikes under load.
/// 32 leaves headroom for one max-size LSO super-skb (`tso_max_segs =
/// 10` configured in `netdev_bridge.c`, so the max chain is 11
/// descriptors). When changing this, also revisit
/// [`napi::TX_START_THRS`] — they're a paired tuning surface.
const TX_STOP_THRS: usize = 32;
const TX_BUDGET_DESC_WINDOW: usize = RING_LEN - TX_STOP_THRS;

/// Combined wake predicate for the TX queue, shared by the reaper
/// ([`napi::poll`]) and the xmit-side stop recheck below. The queue may
/// resume only when BOTH halves of the hysteresis permit it:
///   - descriptor slots have drained past [`napi::TX_START_THRS`], AND
///   - in-flight TX bytes have fallen below the byte-budget low-water
///     (`max(1, tx_byte_budget / 2)`).
///
/// The byte half is a no-op when `tx_byte_budget == 0` (the throttle is
/// off). Routing every wake decision through one predicate is what makes
/// the two independent stop reasons — ring-full and byte-budget — safe to
/// coexist: whichever reason stopped the queue, the wake side re-checks
/// both, so the queue can never strand because one condition cleared while
/// the other was still being evaluated against a stale index.
pub(crate) fn tx_should_wake(state: &NetdevState, free: usize) -> bool {
    // The hysteresis decision is the host-tested pure core
    // `crate::layout::tx_should_wake_decision`; this wrapper only snapshots the
    // atomics. `inflight_bytes` is loaded with Acquire to order against the
    // reaper's release store (the byte half is ignored when the budget is off).
    let byte_budget = state.tx.byte_budget.inner.load(Ordering::Relaxed) as usize;
    let inflight = state.tx.inflight_bytes.inner.load(Ordering::Acquire);
    crate::layout::tx_should_wake_decision(free, crate::napi::TX_START_THRS, byte_budget, inflight)
}

#[inline]
fn tx_budget_tracked_bytes(byte_budget: usize, wire_len: usize) -> usize {
    // Pure math (host-tested) bound to this driver's descriptor window.
    crate::layout::tx_budget_tracked_bytes(byte_budget, wire_len, TX_BUDGET_DESC_WINDOW)
}

/// Stop the TX queue, then recheck the producer/consumer indices to cover
/// the race where NAPI freed descriptors just before or during the stop.
/// If the queue has already crossed the wake threshold, wake it immediately
/// so we do not strand the queue stopped with no future completion to wake it.
fn stop_tx_queue_with_recheck(state: &NetdevState, head: usize) {
    let ndev = state.ndev.load(Ordering::Acquire);
    ub::bridge_tx_stop_queue(ndev);

    // CRITICAL barrier (the kernel `netif_subqueue_maybe_stop` / r8169
    // `smp_mb__after_atomic` pattern). The stop above and the reaper's
    // drain run on different CPUs; without a full StoreLoad fence here the
    // recheck below can read a *stale* (pre-drain) tail/inflight even though
    // the reaper already completed every in-flight packet. When that happens
    // the queue stays XOFF and — because the reaper only wakes on
    // `reaped > 0` — no future completion ever arrives to wake it, so the TX
    // path wedges permanently. UDP exposes this readily (it floods the qdisc
    // and trips the stop threshold every ~90 packets at tight margins), while
    // TSO/ACK-clocked TCP almost never does. The reaper pairs this with its
    // own `fence(SeqCst)` after publishing `tx_tail`; together they give the
    // Dekker guarantee that at least one side observes the other, so the wake
    // is never lost. See docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md.
    core::sync::atomic::fence(Ordering::SeqCst);

    let tail_now = state.tx.tail.inner.load(Ordering::Acquire);
    let in_flight_now = head.wrapping_sub(tail_now);
    if tx_should_wake(state, RING_LEN - in_flight_now) {
        ub::bridge_tx_wake_queue(ndev);
    }
}

// RX buffer geometry is no longer a fixed compile-time size. With per-MTU
// zero-copy buffers the page_pool sizes each buffer from
// dev->mtu at ndo_open and returns the device-writable length, cached in
// `RxQueueState::buf_len`. See `src/netdev_bridge_rx_pool.c`.

/// Per-slot streaming-DMA RX buffer view. One pair per ring descriptor:
/// the chip's RX completion deposits bytes via DMA into `dma`; the NAPI
/// poll reads them through `cpu`. Stored as a pair of per-slot atomics
/// (`RxQueueState::slot_cpu` + `RxQueueState::slot_dma`) so probe → ndo_open
/// allocation, the NAPI hot path, and ndo_stop free can all access the
/// pool through `&NetdevState` without unsafe interior mutability. The
/// atomics provide interior mutability; their hot-path accesses are relaxed
/// because open/stop/MTU rebuild disable NAPI before mutating slots.
///
/// `cpu` is the kernel-virtual `page_address(...)` from
/// `r8125_bridge_rx_alloc` — guaranteed-lowmem on x86_64 because
/// the kernel-Rust DMA layer never hands us highmem pages. `dma` is the
/// matching `dma_map_page(...)` handle. The empty sentinel (`cpu = null,
/// dma = 0`) is the ring's initial state and the post-stop "freed"
/// marker; both fields are always set / cleared together so checking
/// `cpu` is sufficient.
#[derive(Copy, Clone)]
#[repr(C)]
pub(crate) struct RxSlot {
    pub(crate) cpu: *mut core::ffi::c_void,
    pub(crate) dma: bindings::dma_addr_t,
}

impl RxSlot {
    /// Sentinel used at initialisation + after `ndo_stop`.
    pub(crate) const EMPTY: Self = Self {
        cpu: core::ptr::null_mut(),
        dma: 0,
    };
}

/// IRQ delivery mode chosen at probe by `pci_alloc_irq_vectors`. Drives the
/// per-fire branch in `raw_irq_handler` and the surface selection in
/// `napi::rearm_irq_baseline`. Encoded as `u8` so it round-trips through
/// `AtomicU8` (kernel-Rust has no `AtomicEnum`).
///
/// MSI and MSI-X share the same V2 ISR/IMR register layout on this chip —
/// the chip's `INT_CFG0_ENABLE_8125` bit governs delivery layout only; the
/// PCIe message-based vs pin-asserted side is invisible to the V2 register
/// surface — so we don't distinguish them. The `intx_only` module param
/// short-circuits allocation to legacy INTx for regression testing.
///
/// V2 is still gated by the probe-time interrupt-surface capability:
/// some MSI-only paths on virtualized hosts can require legacy ISR
/// handling even though this mode enum still reports `Msi`.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum IrqMode {
    /// Legacy INTx pin assertion. Requires `IRQF_SHARED` on registration,
    /// drives the original `IMR`/`ISR` register window at 0x38/0x3C.
    Intx = 0,
    /// Message-Signaled delivery (MSI or MSI-X). Registers without
    /// `IRQF_SHARED`. The register surface is selected separately by
    /// `IrqState::use_v2`; with one allocated vector we intentionally keep
    /// the legacy combined `IMR`/`ISR` window so TX completions share vector 0.
    Msi = 1,
}

impl IrqMode {
    fn from_u8(v: u8) -> Self {
        match v {
            1 => IrqMode::Msi,
            _ => IrqMode::Intx,
        }
    }
}

/// TX-ring slice of the per-device state.
///
/// Owned by `xmit` (producer) and the NAPI poll TX reaper (consumer).
/// `desc` / `dma` are set at probe and read-only afterwards; the
/// shadow arrays and indices are mutated atomically. See the docs on
/// `NetdevState` for the cache-padding rationale.
/// How a TX slot's `shadow` pointer must be released when hardware completes it.
///
/// Stored per slot as a `u8` (kernel-Rust has no atomic enum). The `shadow`
/// `AtomicPtr` carries an `sk_buff*` for `Skb` and an `xdp_frame*` for `Xdp`;
/// the tag is the only thing that distinguishes them at reap time. `Skb` is the
/// zero default so a freshly-zeroed / reaper-reset slot is always the normal
/// xmit disposition.
#[derive(Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum TxSlotKind {
    /// `shadow` is an `sk_buff*` from `ndo_start_xmit`; release via the skb path.
    Skb = 0,
    /// `shadow` is an `xdp_frame*` from an XDP_TX verdict; release via
    /// `xdp_return_frame` (its mem model returns the page to the RX page_pool).
    Xdp = 1,
}

impl TxSlotKind {
    /// Round-trip the per-slot `u8` tag back to the enum. Any unexpected value
    /// is treated as `Skb` (the safe default — the slot then takes the skb path,
    /// and a null `shadow` makes that a no-op).
    #[inline]
    pub(crate) fn from_u8(v: u8) -> Self {
        match v {
            1 => TxSlotKind::Xdp,
            _ => TxSlotKind::Skb,
        }
    }
}

pub(crate) struct TxRingState {
    /// DMA + CPU pointers for the TX descriptor ring (N + 1 slots; slot N
    /// is the tail canary).
    pub(crate) desc: *mut Descriptor,
    pub(crate) dma: u64,

    /// One AtomicPtr per TX slot. For SG (multi-fragment) skbs only the
    /// LastFrag descriptor's slot holds the skb pointer; intermediate
    /// fragment slots store null. `xmit` stores; NAPI poll reaper consumes
    /// via `bridge_skb_consume_tx` only when the slot's pointer is non-null.
    pub(crate) shadow: [AtomicPtr<bindings::sk_buff>; RING_LEN],

    /// Per-descriptor DMA mapping shadow — the chip clears the descriptor's
    /// LEN field on TX completion (per r8169 vendor errata, also seen on
    /// 8125B), and `napi_consume_skb` invalidates the skb pointer, so we
    /// can't recover (handle, len) from either source at unmap time. SG
    /// makes this worse because each fragment is mapped separately and
    /// must be unmapped separately.
    pub(crate) shadow_dma: [AtomicU64; RING_LEN],
    pub(crate) shadow_len: [AtomicU32; RING_LEN],
    pub(crate) shadow_is_frag: [AtomicBool; RING_LEN],
    pub(crate) shadow_budget_len: [AtomicU32; RING_LEN],

    /// Per-slot disposition tag (`TxSlotKind as u8`). Tells the NAPI reaper how
    /// to release the slot's buffer at completion: an skb (the normal xmit path,
    /// `napi_consume_skb`) vs an `xdp_frame` from an XDP_TX verdict
    /// (`xdp_return_frame`, which routes the page back to its origin page_pool
    /// via the frame's captured mem model). Written by the matching producer
    /// (`ndo_start_xmit` leaves the default `Skb`; `xdp_xmit_one` sets `Xdp`),
    /// reset to `Skb` by the reaper after disposition so a reused slot can't be
    /// misread. Both producers run under the txq lock; the reaper is the sole
    /// reader/resetter, so plain Acquire/Release ordering suffices.
    pub(crate) shadow_kind: [AtomicU8; RING_LEN],

    /// Producer index (advanced by `ndo_start_xmit`). Cache-padded per
    /// RUST_STANDARDS.md §15.2 — written by xmit, read by NAPI poll.
    pub(crate) head: CachePadded<AtomicUsize>,
    /// Consumer index (advanced by the NAPI TX reaper). Cache-padded; read
    /// by xmit's ring-full check.
    pub(crate) tail: CachePadded<AtomicUsize>,

    /// Driver-owned TX byte-budget accounting (the MSI-safe latency throttle —
    /// test 5 / docs/BQL_RETRY_PLAN.md). xmit adds the wire length here at the
    /// commit for packets large enough to hit the budget before descriptor
    /// hysteresis, and the NAPI reaper subtracts the per-packet budget shadow;
    /// when tracked in-flight bytes exceed `tx_byte_budget` we stop the txq
    /// (and wake when they fall back below). This bounds TX ring residency so
    /// fq_codel can protect latency under a bulk flow — same effect as BQL,
    /// without `netdev_sent_queue` (which suppresses MSI-X delivery on this
    /// chip's V2 surface; see docs/perf/bql_20260605/). Cache-padded: xmit writes,
    /// reaper writes — keep it off the head/tail lines.
    pub(crate) inflight_bytes: CachePadded<AtomicUsize>,

    /// Per-open snapshot of `tx_byte_budget`. Module-param reads stay out of
    /// the TX/NAPI hot paths; `ndo_open` snapshots the value for this open.
    pub(crate) byte_budget: CachePadded<AtomicU32>,
}

impl TxRingState {
    /// Heap-in-place initializer. Each of
    /// the 5 × `RING_LEN` shadow arrays is constructed slot-by-slot via
    /// `init_array_from_fn`, never materialised on the stack.
    pub(crate) fn new(
        desc: *mut Descriptor,
        dma: u64,
    ) -> impl pin_init::Init<Self, kernel::error::Error> {
        kernel::try_init!(Self {
            desc,
            dma,
            shadow <- pin_init::init_array_from_fn(
                |_| AtomicPtr::new(core::ptr::null_mut())
            ),
            shadow_dma <- pin_init::init_array_from_fn(
                |_| AtomicU64::new(0)
            ),
            shadow_len <- pin_init::init_array_from_fn(
                |_| AtomicU32::new(0)
            ),
            shadow_is_frag <- pin_init::init_array_from_fn(
                |_| AtomicBool::new(false)
            ),
            shadow_budget_len <- pin_init::init_array_from_fn(
                |_| AtomicU32::new(0)
            ),
            shadow_kind <- pin_init::init_array_from_fn(
                |_| AtomicU8::new(TxSlotKind::Skb as u8)
            ),
            head: CachePadded::new(AtomicUsize::new(0)),
            tail: CachePadded::new(AtomicUsize::new(0)),
            inflight_bytes: CachePadded::new(AtomicUsize::new(0)),
            byte_budget: CachePadded::new(AtomicU32::new(0)),
        }? kernel::error::Error)
    }

    #[inline]
    pub(crate) fn clear_shadow_slot(&self, slot: usize) {
        self.shadow_dma[slot].store(0, Ordering::Release);
        self.shadow_len[slot].store(0, Ordering::Release);
        self.shadow_is_frag[slot].store(false, Ordering::Release);
        self.shadow_budget_len[slot].store(0, Ordering::Release);
        self.shadow_kind[slot].store(TxSlotKind::Skb as u8, Ordering::Release);
        self.shadow[slot].store(core::ptr::null_mut(), Ordering::Release);
    }
}

/// RX queue slice — populated by `ndo_open` (per-slot streaming-DMA pages),
/// drained by `ndo_stop`, hot-path read by that queue's NAPI poll.
///
/// Full-RSS scaffolding starts with one queue but keeps the state shaped as a
/// queue object so future multi-ring work can grow this into an array without
/// changing the NAPI/RX ownership contract again.
pub(crate) struct RxQueueState {
    pub(crate) desc: *mut RxDescriptor,
    pub(crate) dma: u64,

    /// Per-slot streaming-DMA RX buffers. Geometry comes from
    /// `RxQueueState::buf_len` at `ndo_open`, so each MTU class gets the
    /// smallest page geometry that safely holds a full frame for that MTU.
    /// `ndo_open` populates every slot via `ub::rx_alloc`, and `ndo_stop`
    /// frees the lot via `ub::rx_free`. The `cpu`/`dma` pair is stored as
    /// two per-slot atomics — both fields are written together (by
    /// `NetdevState::set_rx_slot`) and read together (by
    /// `NetdevState::rx_slot`); see [`RxSlot`]. `(null, 0)` is the
    /// empty sentinel.
    ///
    /// We don't cache-pad these because the access pattern is "NAPI
    /// reads one slot per RX frame, then writes the same slot's
    /// descriptor LEN field" — same context, same cache line; no
    /// cross-context false sharing is possible.
    pub(crate) slot_cpu: [AtomicPtr<core::ffi::c_void>; RING_LEN],
    pub(crate) slot_dma: [AtomicU64; RING_LEN],

    /// Device-writable bytes per RX buffer for the current open, set by
    /// `r8125_bridge_rx_pool_create` from the MTU-derived geometry
    /// (per-MTU sizing). Drives the descriptor LEN field (chip's view of
    /// "how many bytes it may DMA") and the frame-length clamp in the NAPI
    /// RX loop. Zero while the device is down. Already ≤ `DESC_LEN_MASK`.
    pub(crate) buf_len: CachePadded<AtomicU32>,

    /// RX consumer index (advanced by the NAPI RX path). Cache-padded so
    /// the RX hot loop's index doesn't ping-pong with TX indices.
    pub(crate) tail: CachePadded<AtomicUsize>,
    /// Active RX descriptor format for this open. Kept fixed for the device
    /// open/session so descriptor parsing never switches per packet.
    pub(crate) format: RxDescFormat,
}

impl RxQueueState {
    pub(crate) fn new(
        desc: *mut RxDescriptor,
        dma: u64,
        format: RxDescFormat,
    ) -> impl pin_init::Init<Self, kernel::error::Error> {
        kernel::try_init!(Self {
            desc,
            dma,
            slot_cpu <- pin_init::init_array_from_fn(
                |_| AtomicPtr::new(core::ptr::null_mut())
            ),
            slot_dma <- pin_init::init_array_from_fn(
                |_| AtomicU64::new(0)
            ),
            buf_len: CachePadded::new(AtomicU32::new(0)),
            tail: CachePadded::new(AtomicUsize::new(0)),
            format,
        }? kernel::error::Error)
    }

    /// Snapshot RX slot `i`'s (cpu, dma) pair. Both atomics are read with
    /// `Relaxed`: open/stop and MTU rebuild run with NAPI disabled, so there is
    /// no concurrent writer while the RX hot path is active.
    #[inline]
    pub(crate) fn slot(&self, i: usize) -> RxSlot {
        RxSlot {
            cpu: self.slot_cpu[i].load(Ordering::Relaxed),
            dma: self.slot_dma[i].load(Ordering::Relaxed),
        }
    }

    /// Publish a slot's (cpu, dma) pair. Paired with `slot` — stores are
    /// `Relaxed` because the NAPI lifecycle, not the atomics, serializes
    /// open/stop against the RX hot path. The empty sentinel (`RxSlot::EMPTY`)
    /// signals "freed" to the rmmod / failure-rollback paths.
    #[inline]
    pub(crate) fn set_slot(&self, i: usize, slot: RxSlot) {
        self.slot_cpu[i].store(slot.cpu, Ordering::Relaxed);
        self.slot_dma[i].store(slot.dma, Ordering::Relaxed);
    }

    #[inline]
    pub(crate) fn reset_index(&self) {
        self.tail.inner.store(0, Ordering::Relaxed);
    }
}

/// IRQ slice — set at probe by the kernel-Rust `pci_alloc_irq_vectors`
/// allocation and mode detection. Read-only after probe; the atomic on `mode`
/// is just to satisfy the `&self` access pattern.
pub(crate) struct IrqState {
    /// Per-RX-queue IRQ numbers. `rx_nums[i]` is the MSI-X entry-`i` vector
    /// that signals RX queue `i`'s ROK under V2. The single-vector MSI/MSI-X and
    /// INTx fallback uses only `rx_nums[0]` (the combined interrupt); the rest
    /// stay 0. Only `active_rx_queues(state)` of them are requested at open.
    pub(crate) rx_nums: [u32; RX_QUEUE_COUNT],
    /// IRQ number for V2 TX Q0 (MSI-X entry 16). Zero when V2 is not active.
    pub(crate) tx_num: u32,
    /// IRQ number for V2 link-change (MSI-X entry 21). Zero when V2 is not
    /// active.
    pub(crate) link_num: u32,
    /// Encoded [`IrqMode`] chosen at probe. Read by `raw_irq_handler`
    /// (selects ISR window + ack/mask sequence) and by
    /// `napi::rearm_irq_baseline` (selects V2 vs legacy IMR write).
    // NOT-PADDED: set-once at probe, then read-only from every other
    // context — no concurrent writer means no false-sharing pressure.
    pub(crate) mode: AtomicU8,
    /// Probe-time gate for using V2 ISR/IMR in open and IRQ paths:
    /// `true` only when we know the message-ID surface is available.
    // NOT-PADDED: written once at probe, read by all contexts.
    pub(crate) use_v2: AtomicBool,
    /// Per-RX-queue registration flags (`request_irq` done, `free_irq` not
    /// yet). Single source of truth so each vector is freed exactly once across
    /// the `ndo_open` rollback guard, `ndo_stop`, and any teardown
    /// double-close — without it, an unbind-while-up could `free_irq` an IRQ
    /// with no registered action and trip the kernel's "trying to free
    /// already-free IRQ" WARN at `manage.c`. `rx_requested[0]` is the
    /// rx0/legacy vector.
    pub(crate) rx_requested: [CachePadded<AtomicBool>; RX_QUEUE_COUNT],
    /// V2 TX Q0 IRQ registration flag. Separate from `requested` because entry
    /// 16 is a distinct Linux IRQ and must be freed exactly once.
    pub(crate) tx_requested: CachePadded<AtomicBool>,
    /// V2 link-change IRQ registration flag. Separate from `requested` because
    /// entry 21 is a distinct Linux IRQ and must be freed exactly once.
    pub(crate) link_requested: CachePadded<AtomicBool>,
}

impl IrqState {
    pub(crate) fn new(
        rx_nums: [u32; RX_QUEUE_COUNT],
        tx_num: u32,
        link_num: u32,
        mode: IrqMode,
        use_v2: bool,
    ) -> impl pin_init::Init<Self, kernel::error::Error> {
        kernel::try_init!(Self {
            rx_nums,
            tx_num,
            link_num,
            mode: AtomicU8::new(mode as u8),
            use_v2: AtomicBool::new(use_v2),
            rx_requested <- pin_init::init_array_from_fn(
                |_| CachePadded::new(AtomicBool::new(false))
            ),
            tx_requested: CachePadded::new(AtomicBool::new(false)),
            link_requested: CachePadded::new(AtomicBool::new(false)),
        }? kernel::error::Error)
    }
}

/// PHY slice — the OCP page selector. Mutated only from process context
/// (MDIO bus callbacks); the atomic is just to satisfy the `&self`
/// access pattern.
pub(crate) struct PhyState {
    /// Current PHY OCP page base (default `OCP_STD_PHY_BASE = 0xA400`).
    /// MDIO writes to MII reg 0x1F switch pages; subsequent MII reads/writes
    /// use this base.
    // NOT-PADDED: PHY-config slow path; mutated only from process
    // context (MDIO bus callbacks), no hot-path contention.
    pub(crate) ocp_base: AtomicU32,
}

impl PhyState {
    pub(crate) fn new() -> impl pin_init::Init<Self, kernel::error::Error> {
        kernel::try_init!(Self {
            ocp_base: AtomicU32::new(crate::regs::OCP_STD_PHY_BASE),
        }? kernel::error::Error)
    }
}

/// Per-bound-device state — accessed from probe, ndo callbacks, NAPI
/// poll, and the IRQ handler. Sub-state lives in `tx` / `rx` / `irq` /
/// `phy` to make the cross-context ownership story obvious from the
/// type. The top-level fields are
/// device-wide invariants: `pdev` holds the ARef, `bar_ptr` is the
/// stable MMIO mapping, `ndev` is the registered net_device handle.
pub(crate) struct NetdevState {
    /// Reference-counted device handle. Holds the device live for the
    /// full lifetime of this NetdevState (which is the bound period).
    #[allow(dead_code)] // held for refcount; future work may consume it
    pub(crate) pdev: ARef<pci::Device>,

    /// Stable pointer to the mapped BAR. Valid for the lifetime of the
    /// owning `Devres<Bar>` in `R8125Driver`. We dereference it via
    /// `Regs::new(unsafe { &*bar_ptr })` inside `unsafe_boundary`.
    pub(crate) bar_ptr: *const pci::Bar<{ mmio::R8125_MMIO_LEN }>,

    /// Set by `NetdevHandle::new_with_state` after `bridge_alloc` returns.
    /// Read by `ndo_open`/`stop`/etc. when they need to call back into
    /// the cshim (`carrier_on`, `tx_wake_queue`, `napi_schedule`, …).
    // NOT-PADDED: set-once at probe, then read-only from every other
    // context — no concurrent writer means no false-sharing pressure.
    pub(crate) ndev: AtomicPtr<bindings::net_device>,

    /// Per-open snapshot of `debug_counters`. When false, TX/IRQ/NAPI hot
    /// paths skip debug atomic RMWs entirely.
    // NOT-PADDED: written once per open/stop, read by hot paths; no packet-rate
    // writer exists, so there is no cross-context false sharing pressure.
    pub(crate) debug_counters: AtomicBool,

    /// BQL decision snapshotted at `ndo_open`. Module parameters can be
    /// operator-controlled, but sent/completed BQL accounting must stay paired
    /// for the lifetime of one open, so hot paths read this per-open value.
    // NOT-PADDED: written only under open/stop teardown, read from TX/NAPI.
    // It is not independently mutated at packet rate.
    pub(crate) bql_enabled: AtomicBool,

    /// Runtime gate for `skb_set_hash()` delivery on RX.
    /// Set from `ndo_open` and `set_features` via
    /// `apply_netdev_features`. False keeps hash parsing wired but does
    /// not expose a valid `skb->hash` to the stack.
    // NOT-PADDED: written at open/set_features only; read from NAPI poll.
    pub(crate) rx_hash_enabled: AtomicBool,

    /// ethtool `set_channels` runtime RX-queue-count override. `0` = use the
    /// `rss_queues` module param; non-zero overrides it (validated to
    /// `[1, RX_QUEUE_COUNT]`). Read by `requested_rss_queues`/`active_rx_queues`
    /// on every open so `ethtool -L` takes effect on the next reconfigure.
    // NOT-PADDED: written under RTNL in set_channels; read at open.
    pub(crate) requested_rx_queues: AtomicUsize,

    /// Rust-owned RSS policy storage (`crate::rss`). The active Toeplitz key and
    /// 128-bucket indirection table, persisted as the lock-free serialization of
    /// a `RssPolicy`: a `*_custom` flag plus the array (flag false ⇒ "use the
    /// system key / default spread"). Written only under RTNL (ethtool
    /// get/set_rxfh, set_channels, open) and read at open / live reprogram —
    /// never on the packet hot path — so single-writer atomics need no lock.
    /// `netdev::rss_policy_snapshot` / `rss_policy_store` round-trip these through
    /// the host-tested `RssPolicy` type.
    // NOT-PADDED: cold-path RSS policy, RTNL-serialized, never written at packet rate.
    pub(crate) rss_key_custom: AtomicBool,
    pub(crate) rss_key: [AtomicU8; crate::rss::RSS_KEY_SIZE],
    // NOT-PADDED: cold-path RSS policy, RTNL-serialized, never written at packet rate.
    pub(crate) rss_indir_custom: AtomicBool,
    pub(crate) rss_indir: [AtomicU8; crate::rss::RSS_INDIR_ENTRIES],

    /// TX descriptor ring + producer/consumer indices + shadow.
    pub(crate) tx: TxRingState,
    /// RX descriptor rings + per-slot streaming-DMA pages + consumer indices.
    /// Runtime still reports one queue; shaping this as an array keeps the
    /// Rust-side state ready for future multi-ring RSS without changing the
    /// NAPI/RX ownership contract again.
    pub(crate) rx_queues: [RxQueueState; RX_QUEUE_COUNT],
    /// IRQ number + delivery mode (set at probe, read on every fire).
    pub(crate) irq: IrqState,
    /// PHY OCP page selector.
    pub(crate) phy: PhyState,
}

// Send + Sync for NetdevState — the impls live in `unsafe_boundary` so the
// `unsafe impl` keyword stays in the one allowed file.

impl NetdevState {
    /// Borrow `Regs` for the duration of this call. Safe because the BAR
    /// mapping is alive as long as `NetdevState` is — `R8125Driver` drops
    /// `_netdev` (which drops `NetdevState`) before `_bar` (which drops
    /// the `Devres<Bar>`), so the pointer always outlives every read.
    pub(crate) fn regs(&self) -> Regs<'_> {
        ub::regs_from_state(self)
    }

    /// IRQ delivery mode chosen by probe.
    #[inline]
    pub(crate) fn irq_mode(&self) -> IrqMode {
        IrqMode::from_u8(self.irq.mode.load(Ordering::Relaxed))
    }

    #[inline]
    pub(crate) fn use_v2_irq_surface(&self) -> bool {
        self.irq.use_v2.load(Ordering::Relaxed)
    }

    /// Resolve a C-bridge queue id into Rust RX queue state. Today only queue 0
    /// exists; later multi-ring RSS work grows this method without changing the
    /// NAPI call signature.
    #[inline]
    pub(crate) fn rx_queue(&self, queue_id: u32) -> Option<&RxQueueState> {
        self.rx_queues.get(queue_id as usize)
    }

    #[inline]
    pub(crate) fn rx_queue0(&self) -> &RxQueueState {
        &self.rx_queues[RX_QUEUE0 as usize]
    }

    /// Reset all atomic indices and clear stale TX shadow metadata.
    /// Called at `ndo_open` so a fresh open after a previous close starts
    /// with a clean slate.
    pub(crate) fn reset_indices(&self) {
        self.tx.head.inner.store(0, Ordering::Relaxed);
        self.tx.tail.inner.store(0, Ordering::Relaxed);
        for rx in &self.rx_queues {
            rx.reset_index();
        }
        self.tx.inflight_bytes.inner.store(0, Ordering::Relaxed);
        self.tx.byte_budget.inner.store(0, Ordering::Relaxed);
        for i in 0..RING_LEN {
            self.tx.clear_shadow_slot(i);
        }
    }
}

// ── Rust ndo callbacks ────────────────────────────────────────────────────

#[inline]
fn state_from<'a>(cookie: *mut c_void) -> &'a NetdevState {
    ub::state_from_cookie(cookie)
}

extern "C" fn rust_open(cookie: *mut c_void, feature_flags: u32) -> c_int {
    let state = state_from(cookie);
    match ndo_open(state, feature_flags) {
        Ok(()) => 0,
        Err(e) => e.to_errno(),
    }
}

extern "C" fn rust_stop(cookie: *mut c_void) {
    let state = state_from(cookie);
    ndo_stop(state);
}

extern "C" fn rust_xmit(cookie: *mut c_void, skb: *mut bindings::sk_buff) -> c_int {
    let state = state_from(cookie);
    // Wrap the raw skb at the FFI boundary. From here on the driver
    // owns the disposition obligation; the type system tracks where it
    // gets handed off (DMA shadow on success, free_with_error on
    // failure). See `src/skb.rs`.
    let skb = crate::skb::DriverOwnedSkb::from_raw(skb);
    ndo_start_xmit(state, skb)
}

extern "C" fn rust_poll(cookie: *mut c_void, queue_id: u32, budget: c_int) -> c_int {
    let state = state_from(cookie);
    crate::napi::poll(state, queue_id, budget)
}

extern "C" fn rust_change_mtu(cookie: *mut c_void, new_mtu: c_int) -> c_int {
    // Range-check is done by the kernel against ndev->{min,max}_mtu (cshim
    // populates those at alloc). With per-MTU zero-copy RX buffers the
    // live RX pool is sized for the CURRENT MTU, so a change while
    // up must re-create it:
    //   - down: accept; the net core writes dev->mtu after we return 0 and
    //     the next ndo_open sizes the pool to it.
    //   - up:   stop → publish the new MTU (the core only writes dev->mtu
    //     on success, so we set it ourselves) → re-open at the new size.
    //     If reopen fails, C shim rolls back mtu to the previous value
    //     before returning the error.
    // change_mtu runs with RTNL held (same as open/stop), so the teardown
    // and rebuild are serialized against other ndo callbacks. The reopen
    // bracket (netif_tx_disable + napi_disable → ops.stop → set mtu →
    // napi_enable → ops.open) lives in the cshim so the napi lifecycle
    // matches ndo_open/stop and the RX page_pool is never destroyed while
    // its NAPI is still active.
    let state = state_from(cookie);
    let ndev = state.ndev.load(Ordering::Acquire);
    if !ub::netif_running(ndev) {
        return 0;
    }
    ub::reopen_for_mtu(ndev, new_mtu)
}

extern "C" fn rust_set_features(cookie: *mut c_void, feature_flags: u32) -> c_int {
    let state = state_from(cookie);
    apply_netdev_features(state, feature_flags);
    apply_rss_programming(state);
    0
}

/// ethtool `set_rxfh` indirection check. Validates the kernel-supplied table
/// against the owned RX-queue count via the host-tested
/// `layout::rxfh_indir_all_valid`. Returns 0 (accept) or `-EINVAL`.
extern "C" fn rust_rss_indir_check(
    _cookie: *mut c_void,
    indir: *const u32,
    len: core::ffi::c_uint,
    queue_count: core::ffi::c_uint,
) -> c_int {
    if ub::rxfh_indir_valid(indir, len as usize, queue_count) {
        0
    } else {
        EINVAL.to_errno()
    }
}

/// ethtool `get_rxfh` — report the ACTIVE RSS key + indirection table from the
/// Rust-owned policy (so `ethtool -x` matches exactly what was programmed). The
/// chip RSS key is write-only, so the cache is the only source of truth. Either
/// buffer may be NULL (caller wants only the other). Runs under RTNL.
extern "C" fn rust_rss_get(cookie: *mut c_void, key_out: *mut u8, indir_out: *mut u32) {
    let state = state_from(cookie);
    let queue_count = active_rx_queues(state) as u8;
    let policy = rss_policy_snapshot(state);
    if !indir_out.is_null() {
        let mut table = [0u8; crate::rss::RSS_INDIR_ENTRIES];
        policy.effective_indir(queue_count, &mut table);
        ub::write_rss_indir(indir_out, &table);
    }
    if !key_out.is_null() {
        let mut key = [0u8; crate::rss::RSS_KEY_SIZE];
        match policy.key() {
            Some(custom) => key.copy_from_slice(custom),
            None => ub::rss_key_fill(&mut key),
        }
        ub::write_rss_key(key_out, &key);
    }
}

/// ethtool `set_rxfh` — install a custom RSS key and/or indirection table into
/// the Rust-owned policy. If the netdev is running, reprogram the chip live via
/// the same `apply_rss_programming` path as open / set_features; if it is down,
/// only cache the policy and let the next open program hardware. Either input
/// may be NULL (no change to that component). The table is validated by the
/// host-tested `RssPolicy::set_indir` (a default-equal table collapses to "track
/// default"); an out-of-range entry returns `-EINVAL` and leaves the policy
/// untouched. Runs under RTNL.
extern "C" fn rust_rss_set(
    cookie: *mut c_void,
    key_in: *const u8,
    indir_in: *const u32,
    queue_count: core::ffi::c_uint,
) -> c_int {
    let state = state_from(cookie);
    let qc = queue_count as u8;
    let mut policy = rss_policy_snapshot(state);
    if !key_in.is_null() {
        let mut key = [0u8; crate::rss::RSS_KEY_SIZE];
        ub::read_rss_key(key_in, &mut key);
        policy.set_key(key);
    }
    if !indir_in.is_null() {
        let mut table = [0u8; crate::rss::RSS_INDIR_ENTRIES];
        ub::read_rss_indir(indir_in, &mut table);
        if policy.set_indir(&table, qc).is_err() {
            return EINVAL.to_errno();
        }
    }
    rss_policy_store(state, &policy);
    if ub::netif_running(state.ndev.load(Ordering::Acquire)) {
        apply_rss_programming(state);
    }
    0
}

/// ethtool `set_channels` — set the runtime active RX-queue count. The C bridge
/// has already rejected tx/combined changes and passed the requested RX count.
/// Validates it against the owned queues and the V3/V2 prerequisites for >1,
/// stores the runtime override (consumed by `requested_rss_queues` on the next
/// open), and returns 0 so the C bridge reopens to apply it; `-EINVAL` rejects
/// without disturbing the running config. Runs under RTNL.
extern "C" fn rust_set_channels(cookie: *mut c_void, rx_count: core::ffi::c_uint) -> c_int {
    let state = state_from(cookie);
    let rx = rx_count as usize;
    // Pure count rule (host-tested): in [1, RX_QUEUE_COUNT] and a representable
    // RTL8125 RSS count (1/2/4). Rejects 3 / 0 / >max.
    if !crate::layout::set_channels_count_valid(rx, RX_QUEUE_COUNT) {
        return EINVAL.to_errno();
    }
    if rx > 1 {
        // Multi-queue hardware prerequisites mirror `validate_rss_queue_request`:
        // V3 RX descriptors and the V2 MSI-X surface. Rejecting here keeps the
        // live single-queue config intact.
        if state.rx_queue0().format == RxDescFormat::Legacy || !state.use_v2_irq_surface() {
            return EINVAL.to_errno();
        }
    }
    state.requested_rx_queues.store(rx, Ordering::Release);
    // A custom indirection table is queue-count-specific: if the new active
    // count would leave it referencing queues that no longer exist, drop it back
    // to the default spread (host-tested `reclamp_for_queue_count`). The C bridge
    // reopens after this returns, so the reclamped policy is what gets programmed.
    let new_qc = crate::layout::active_rx_queues(rx as u8, RX_QUEUE_COUNT) as u8;
    let mut policy = rss_policy_snapshot(state);
    policy.reclamp_for_queue_count(new_qc);
    rss_policy_store(state, &policy);
    0
}

/// `ndo_set_rx_mode` register programming. The C bridge computes `accept` (RCR
/// accept bits) and the two natural-order multicast hash words from the netdev
/// flags + mc list; here we merge the accept bits into the live RCR (preserving
/// V3/feature bits via the host-tested `rx_mode_rcr`) and write the MAR words in
/// hardware order (`mar_words`). Runs under RTNL. Writing RCR/MAR is a plain
/// config update; if the device is down it is reapplied at the next open (the
/// stack calls ndo_set_rx_mode right after ndo_open).
extern "C" fn rust_set_rx_mode(
    cookie: *mut c_void,
    accept: core::ffi::c_uint,
    mc0: core::ffi::c_uint,
    mc1: core::ffi::c_uint,
) {
    let state = state_from(cookie);
    let regs = state.regs();
    regs.set_rcr(crate::layout::rx_mode_rcr(regs.rcr(), accept));
    let (m0, m4) = crate::layout::mar_words(mc0, mc1);
    regs.set_mar(m0, m4);
}

/// `ndo_get_stats64` hardware-tally dump. The C bridge owns the coherent buffer
/// (alloc/read/free) and the struct layout; Rust only drives the MMIO dump
/// handshake into the supplied DMA address. Returns 0 on success, -1 on timeout.
extern "C" fn rust_tally_dump(cookie: *mut c_void, dma_addr: u64) -> c_int {
    let state = state_from(cookie);
    if state.regs().dump_tally(dma_addr) {
        0
    } else {
        -1
    }
}

/// Reset the on-die tally counters (once at open). Returns 0 on success, -1 on
/// timeout. The C bridge owns the coherent buffer + supplies its DMA address.
extern "C" fn rust_tally_reset(cookie: *mut c_void, dma_addr: u64) -> c_int {
    let state = state_from(cookie);
    if state.regs().reset_tally(dma_addr) {
        0
    } else {
        -1
    }
}

/// `ethtool get_wol` — active `WAKE_*` mask read back from the chip Config3/5.
extern "C" fn rust_get_wol(cookie: *mut c_void) -> u32 {
    state_from(cookie).regs().wol_opts()
}

/// `ethtool set_wol` — program the chip WoL arm state (the C side has already
/// rejected unsupported `WAKE_*` bits).
extern "C" fn rust_set_wol(cookie: *mut c_void, wolopts: u32) {
    state_from(cookie).regs().set_wol(wolopts);
}

/// WoL-aware suspend arming (the r8169-mainline `__rtl8169_set_wol` recipe). Run
/// from the PM suspend callback after the light NAPI quiesce, with the PHY still
/// powered (no `phy_stop`): arm the chip wake bits (`set_wol`), the master
/// `Config1.PMEnable`, and `Config2.PMSTS_En`; open the RX accept filter so the
/// wake detector sees frames; and — the key step — keep the chip PLL (hence the
/// internal PHY) alive across D3 via `PMCH` (`rtl_set_d3_pll_down(false)`) so a
/// magic packet reaches the detector. The PCI core then enters D3 with PME
/// (device_may_wakeup was set by the ethtool set_wol path). The link stays at its
/// current speed — the PLL-keep-alive is what holds the PHY up, so no speed change
/// (and its autoneg-timing hazard) is needed. Resume's full re-open restores the
/// normal power state.
extern "C" fn rust_wol_suspend_arm(cookie: *mut c_void, wolopts: u32) {
    let state = state_from(cookie);
    let regs = state.regs();
    regs.set_wol(wolopts);
    regs.unlock_config_regs();
    regs.set_config1(regs.config1() | regs::CONFIG1_PMENABLE);
    regs.set_config2(regs.config2() | regs::CONFIG2_PMSTS_EN);
    // Keep the PLL/PHY powered in D3hot and D3cold (rtl_set_d3_pll_down(false)).
    regs.set_pmch(regs.pmch() | regs::PMCH_D3HOT_NO_PLL_DOWN | regs::PMCH_D3COLD_NO_PLL_DOWN);
    regs.lock_config_regs();
    regs.set_rcr(
        regs.rcr()
            | regs::RCR_ACCEPT_BROADCAST
            | regs::RCR_ACCEPT_MULTICAST
            | regs::RCR_ACCEPT_MY_PHYS,
    );
}

/// `ethtool -d` — read one 32-bit MMIO register by byte offset.
extern "C" fn rust_read_reg(cookie: *mut c_void, offset: u32) -> u32 {
    state_from(cookie).regs().read_dword(offset as usize)
}

/// Reprogram the chip RX unicast filter from the live `net_device` address.
/// Reuses the same RAR write the open path uses, so a running interface tracks
/// an `ip link set address` change immediately instead of at the next open.
extern "C" fn rust_set_mac_filter(cookie: *mut c_void) {
    let state = state_from(cookie);
    let ndev = state.ndev.load(Ordering::Acquire);
    state.regs().set_mac_address(&ub::bridge_dev_addr(ndev));
}

pub(crate) const M4_FULL_OPS: BridgeOps = BridgeOps {
    open: rust_open,
    stop: rust_stop,
    xmit: rust_xmit,
    poll: rust_poll,
    change_mtu: rust_change_mtu,
    set_features: rust_set_features,
    rss_indir_check: rust_rss_indir_check,
    rss_get: rust_rss_get,
    rss_set: rust_rss_set,
    set_channels: rust_set_channels,
    set_rx_mode: rust_set_rx_mode,
    tally_dump: rust_tally_dump,
    tally_reset: rust_tally_reset,
    get_wol: rust_get_wol,
    set_wol: rust_set_wol,
    wol_suspend_arm: rust_wol_suspend_arm,
    read_reg: rust_read_reg,
    set_mac_filter: rust_set_mac_filter,
    xdp_xmit_one: rust_xdp_xmit_one,
    xdp_tx_flush: rust_xdp_tx_flush,
};

// Skeleton vtable retained as a load-test fallback. Flip `ACTIVE_OPS`
// to point at `M4_SKELETON_OPS` for a no-traffic insmod/rmmod
// regression with no chip interaction. Not wired by default.
#[allow(dead_code)]
extern "C" fn skel_open(_cookie: *mut c_void, _feature_flags: u32) -> c_int {
    0
}
#[allow(dead_code)]
extern "C" fn skel_stop(_cookie: *mut c_void) {}
#[allow(dead_code)]
extern "C" fn skel_xmit(_cookie: *mut c_void, skb: *mut bindings::sk_buff) -> c_int {
    // Skeleton path — wrap and immediately dispose so the type
    // discipline is uniform across all xmit callbacks.
    crate::skb::DriverOwnedSkb::from_raw(skb).free_with_error();
    NETDEV_TX_OK
}
#[allow(dead_code)]
extern "C" fn skel_poll(_cookie: *mut c_void, _queue_id: u32, _budget: c_int) -> c_int {
    0
}
#[allow(dead_code)]
extern "C" fn skel_change_mtu(_cookie: *mut c_void, _new_mtu: c_int) -> c_int {
    0
}
#[allow(dead_code)]
extern "C" fn skel_set_features(_cookie: *mut c_void, _feature_flags: u32) -> c_int {
    0
}
#[allow(dead_code)]
extern "C" fn skel_rss_indir_check(
    _cookie: *mut c_void,
    _indir: *const u32,
    _len: core::ffi::c_uint,
    _queue_count: core::ffi::c_uint,
) -> c_int {
    0
}
#[allow(dead_code)]
extern "C" fn skel_rss_get(_cookie: *mut c_void, _key_out: *mut u8, _indir_out: *mut u32) {}
#[allow(dead_code)]
extern "C" fn skel_rss_set(
    _cookie: *mut c_void,
    _key_in: *const u8,
    _indir_in: *const u32,
    _queue_count: core::ffi::c_uint,
) -> c_int {
    0
}
#[allow(dead_code)]
extern "C" fn skel_set_channels(_cookie: *mut c_void, _rx_count: core::ffi::c_uint) -> c_int {
    0
}
#[allow(dead_code)]
extern "C" fn skel_set_rx_mode(
    _cookie: *mut c_void,
    _accept: core::ffi::c_uint,
    _mc0: core::ffi::c_uint,
    _mc1: core::ffi::c_uint,
) {
}

#[allow(dead_code)]
extern "C" fn skel_tally_dump(_cookie: *mut c_void, _dma_addr: u64) -> c_int {
    -1
}

#[allow(dead_code)]
extern "C" fn skel_get_wol(_cookie: *mut c_void) -> u32 {
    0
}
#[allow(dead_code)]
extern "C" fn skel_set_wol(_cookie: *mut c_void, _wolopts: u32) {}
#[allow(dead_code)]
extern "C" fn skel_wol_suspend_arm(_cookie: *mut c_void, _wolopts: u32) {}

#[allow(dead_code)]
extern "C" fn skel_read_reg(_cookie: *mut c_void, _offset: u32) -> u32 {
    0
}

#[allow(dead_code)]
extern "C" fn skel_set_mac_filter(_cookie: *mut c_void) {}

#[allow(dead_code)]
extern "C" fn skel_xdp_xmit_one(
    _cookie: *mut c_void,
    _frame_dma: u64,
    _frame_len: u32,
    _frame: *mut c_void,
) -> c_int {
    -(bindings::ENOSPC as c_int)
}

#[allow(dead_code)]
extern "C" fn skel_xdp_tx_flush(_cookie: *mut c_void) {}

#[allow(dead_code)]
pub(crate) const M4_SKELETON_OPS: BridgeOps = BridgeOps {
    open: skel_open,
    stop: skel_stop,
    xmit: skel_xmit,
    poll: skel_poll,
    change_mtu: skel_change_mtu,
    set_features: skel_set_features,
    rss_indir_check: skel_rss_indir_check,
    rss_get: skel_rss_get,
    rss_set: skel_rss_set,
    set_channels: skel_set_channels,
    set_rx_mode: skel_set_rx_mode,
    tally_dump: skel_tally_dump,
    tally_reset: skel_tally_dump,
    get_wol: skel_get_wol,
    set_wol: skel_set_wol,
    wol_suspend_arm: skel_wol_suspend_arm,
    read_reg: skel_read_reg,
    set_mac_filter: skel_set_mac_filter,
    xdp_xmit_one: skel_xdp_xmit_one,
    xdp_tx_flush: skel_xdp_tx_flush,
};

/// Active vtable. `M4_FULL_OPS` is the production path; `M4_SKELETON_OPS`
/// is kept available for the no-traffic load-test fallback. See the comment
/// block above for why this flip is now safe.
pub(crate) const ACTIVE_OPS: BridgeOps = M4_FULL_OPS;

/// Release all RX slots and leave the pool in the empty-sentinel
/// state. Used by `ndo_stop` and by every `ndo_open` rollback path after
/// the RX-pool allocation point.
fn free_rx_queue_slots(state: &NetdevState, queue_id: u32) {
    let Some(rx) = state.rx_queue(queue_id) else {
        return;
    };
    let ndev = state.ndev.load(Ordering::Acquire);
    for i in 0..RING_LEN {
        let slot = rx.slot(i);
        rx.set_slot(i, RxSlot::EMPTY);
        ub::rx_free(ndev, queue_id, slot.cpu);
    }
    // page_pool_destroy requires every page returned first — only safe
    // after the slot loop above. Idempotent against a NULL pool, so the
    // ndo_open rollback path (failed mid-alloc, or before create) is fine.
    rx.buf_len.inner.store(0, Ordering::Relaxed);
    ub::rx_pool_destroy(ndev, queue_id);
}

fn free_rx_slots(state: &NetdevState) {
    for queue_id in 0..RX_QUEUE_COUNT {
        free_rx_queue_slots(state, queue_id as u32);
    }
}

// ── ndo_open helpers ──────────────────────────────────────────────────────
//
// The helpers below split the bring-up sequence into named, individually
// documentable steps. Each helper is local to this module and either pure or
// holds the precise invariant needed (e.g. "BAR is alive and the RX pool is
// populated before pre-posting descriptors").
// Rollback stays inline at the call site so the unwind order — which
// is direction-sensitive — is visible where it matters.

#[inline]
fn rx_feature_rcr(base: u32, feature_flags: u32) -> u32 {
    if feature_flags & BRIDGE_FEATURE_RXVLAN != 0 {
        base | regs::RX_VLAN_8125
    } else {
        base & !regs::RX_VLAN_8125
    }
}

#[inline]
fn rx_feature_cpluscmd(feature_flags: u32) -> u16 {
    if feature_flags & BRIDGE_FEATURE_RXCSUM != 0 {
        regs::CPLUSCMD_RX_CHKSUM
    } else {
        0
    }
}

#[inline]
fn rxhash_enabled(feature_flags: u32) -> bool {
    RXHASH_FEATURE_GATE && (feature_flags & BRIDGE_FEATURE_RXHASH != 0)
}

#[inline]
fn requested_rss_queues(state: &NetdevState) -> u8 {
    // ethtool set_channels writes a runtime override (`requested_rx_queues`);
    // 0 means "fall back to the load-time module param". This lets `ethtool -L`
    // change the RX queue count without a module reload.
    let ov = state.requested_rx_queues.load(Ordering::Relaxed);
    if ov != 0 {
        ov as u8
    } else {
        *crate::module_parameters::rss_queues.value()
    }
}

// Pure register/threshold math lives in `crate::layout` (host-unit-tested).
use crate::layout::{rss_q_num_ctrl, tx_budget_shadow_len};

fn validate_rss_queue_request(state: &NetdevState) -> Result<()> {
    let requested = requested_rss_queues(state);
    if requested == 0 {
        return Ok(());
    }

    if state.rx_queue0().format == RxDescFormat::Legacy {
        pr_warn!("r8125_rust: rss_queues requires V3 RX descriptors; disable rx_legacy_desc\n");
        return Err(EINVAL);
    }

    if requested > RX_QUEUE_COUNT as u8 {
        pr_warn!(
            "r8125_rust: rss_queues={} requested but only {} RX queue(s) are owned\n",
            requested,
            RX_QUEUE_COUNT
        );
        return Err(EINVAL);
    }

    if !crate::layout::rss_queue_request_supported(requested, RX_QUEUE_COUNT) {
        pr_warn!(
            "r8125_rust: rss_queues={} is not supported; RTL8125 RSS queue counts must be 0, 1, 2, or 4\n",
            requested
        );
        return Err(EINVAL);
    }

    if requested > 1 && !state.use_v2_irq_surface() {
        pr_warn!("r8125_rust: multi-queue RSS requires the RTL8125B V2 MSI-X surface\n");
        return Err(EINVAL);
    }

    // Multi-queue RX is now fully wired (per-queue rings, NAPI, per-vector IRQ
    // routing, and RSS indirection spread), so representable `rss_queues`
    // requests (2 or 4 on RTL8125B) are honored over the V2 surface.
    Ok(())
}

// The Rust-owned RSS key/table length constants must match the chip register
// sizes the programming code uses; tie them at compile time.
const _: () = assert!(crate::rss::RSS_KEY_SIZE == regs::RSS_KEY_SIZE);
const _: () = assert!(crate::rss::RSS_INDIR_ENTRIES == crate::layout::RSS_INDIR_TBL_ENTRIES);

/// Snapshot the lock-free RSS storage into the host-tested `RssPolicy` model.
/// Called only under RTNL (ethtool / open), so the per-field loads are coherent.
fn rss_policy_snapshot(state: &NetdevState) -> crate::rss::RssPolicy {
    let key = if state.rss_key_custom.load(Ordering::Acquire) {
        let mut k = [0u8; crate::rss::RSS_KEY_SIZE];
        for (i, b) in k.iter_mut().enumerate() {
            *b = state.rss_key[i].load(Ordering::Relaxed);
        }
        Some(k)
    } else {
        None
    };
    let indir = if state.rss_indir_custom.load(Ordering::Acquire) {
        let mut t = [0u8; crate::rss::RSS_INDIR_ENTRIES];
        for (i, e) in t.iter_mut().enumerate() {
            *e = state.rss_indir[i].load(Ordering::Relaxed);
        }
        Some(t)
    } else {
        None
    };
    crate::rss::RssPolicy::from_stored(key, indir)
}

/// Persist a `RssPolicy` back into the lock-free storage (RTNL-serialized).
fn rss_policy_store(state: &NetdevState, policy: &crate::rss::RssPolicy) {
    match policy.key() {
        Some(k) => {
            for (i, b) in k.iter().enumerate() {
                state.rss_key[i].store(*b, Ordering::Relaxed);
            }
            state.rss_key_custom.store(true, Ordering::Release);
        }
        None => state.rss_key_custom.store(false, Ordering::Release),
    }
    match policy.custom_indir() {
        Some(t) => {
            for (i, e) in t.iter().enumerate() {
                state.rss_indir[i].store(*e, Ordering::Relaxed);
            }
            state.rss_indir_custom.store(true, Ordering::Release);
        }
        None => state.rss_indir_custom.store(false, Ordering::Release),
    }
}

fn program_rss_key_and_indir(regs: &Regs<'_>, queue_count: u8, policy: &crate::rss::RssPolicy) {
    // Indirection: a stored custom table, else the kernel default spread.
    if policy.has_custom_indir() {
        let mut table = [0u8; crate::rss::RSS_INDIR_ENTRIES];
        policy.effective_indir(queue_count, &mut table);
        regs.set_rss_indir_8125(&table);
    } else {
        regs.set_rss_indir_default_8125(queue_count);
    }
    // Key: a stored custom key, else the boot-stable system RSS key (not a
    // hardcoded constant — hashes stay unpredictable across reboots).
    let mut key = [0u8; regs::RSS_KEY_SIZE];
    match policy.key() {
        Some(custom) => key.copy_from_slice(custom),
        None => ub::rss_key_fill(&mut key),
    }
    regs.set_rss_key_8125(&key);
}

fn apply_rss_programming(state: &NetdevState) {
    let regs = state.regs();
    let requested = requested_rss_queues(state);
    let queue_count = active_rx_queues(state) as u8;

    if state.rx_hash_enabled.load(Ordering::Acquire) || requested != 0 {
        regs.set_q_num_ctrl_8125(rss_q_num_ctrl(queue_count));
        let policy = rss_policy_snapshot(state);
        program_rss_key_and_indir(&regs, queue_count, &policy);
        // RSS_CTRL carries the queue-count + mask-length fields, not just the
        // hash-type enables — without the queue-count field the chip steers
        // everything to queue 0. See layout::rss_ctrl_value.
        regs.set_rss_ctrl_8125(crate::layout::rss_ctrl_value(
            queue_count,
            crate::layout::RSS_INDIR_TBL_ENTRIES,
            regs::RSS_CTRL_HASH_BITS,
        ));
        return;
    }

    regs.set_q_num_ctrl_8125(0);
    regs.set_rss_ctrl_8125(0);
}

fn apply_netdev_features(state: &NetdevState, feature_flags: u32) {
    let regs = state.regs();
    regs.set_rcr(rx_feature_rcr(regs.rcr(), feature_flags));
    regs.set_cpluscmd(rx_feature_cpluscmd(feature_flags));
    // RXHASH needs the V3 descriptor's hash fields. On the legacy-descriptor
    // fallback (`rx_legacy_desc=1`) there is no hash field, so force it off
    // regardless of the advertised feature bit.
    let enable = rxhash_enabled(feature_flags) && state.rx_queue0().format != RxDescFormat::Legacy;
    state.rx_hash_enabled.store(enable, Ordering::Relaxed);
}

/// Map TX/RX ring DMA bases + program RxConfig / CPlusCmd. `RxMaxSize`
/// is set inside `hw_start_8125b` so all chip-side init lives in one
/// place; this helper only touches registers that program the rings
/// the kernel-Rust DMA layer allocated for us.
#[inline]
fn program_dma_rings(state: &NetdevState, regs: &Regs<'_>, feature_flags: u32) {
    regs.set_tx_ring_base(state.tx.dma);
    for (queue_id, rx) in state
        .rx_queues
        .iter()
        .take(active_rx_queues(state))
        .enumerate()
    {
        regs.set_rx_ring_base_queue(queue_id, rx.dma);
    }
    let mut rcr = rx_feature_rcr(regs::RCR_M4_BASELINE, feature_flags);
    // V3 (32-byte) RX descriptors let the chip write hash metadata. Set in RCR
    // before pre-post (which lays out V3 slots) and before engine enable.
    if state.rx_queue0().format != RxDescFormat::Legacy {
        rcr |= regs::RCR_ENABLE_RX_DESC_V3;
    }
    regs.set_rcr(rcr);
    regs.set_cpluscmd(rx_feature_cpluscmd(feature_flags));
}

/// Allocate one streaming-DMA page chunk per RX slot.
/// On any per-slot failure unwinds every successful allocation before
/// returning so the next `ndo_open` retry sees a fresh state. Pre-posting
/// the descriptor only happens AFTER alloc succeeds so the chip never
/// sees a half-initialised slot.
fn allocate_rx_queue_pool(state: &NetdevState, queue_id: u32) -> Result<()> {
    let Some(rx) = state.rx_queue(queue_id) else {
        return Err(EINVAL);
    };
    let ndev = state.ndev.load(Ordering::Acquire);
    // Create the page_pool sized for the current MTU first; it returns the
    // per-buffer device-writable length that drives the descriptor LEN and
    // the chip RxMaxSize register. On any failure below, `free_rx_slots`
    // frees whatever was allocated and destroys the pool (both idempotent).
    let buf_len = ub::rx_pool_create(ndev, queue_id, RING_LEN)?;
    rx.buf_len.inner.store(buf_len, Ordering::Relaxed);
    for i in 0..RING_LEN {
        match ub::rx_alloc(ndev, queue_id) {
            Ok((cpu, dma)) => rx.set_slot(i, RxSlot { cpu, dma }),
            Err(e) => {
                free_rx_slots(state);
                return Err(e);
            }
        }
    }
    Ok(())
}

fn allocate_rx_pool(state: &NetdevState) -> Result<()> {
    for queue_id in 0..active_rx_queues(state) {
        allocate_rx_queue_pool(state, queue_id as u32)?;
    }
    Ok(())
}

/// Pre-post every RX descriptor with its slot's DMA address + OWN bit.
/// The last (hardware-visible) slot also gets the EOR marker so the
/// chip wraps RxHead back to index 0. The descriptor LEN field tells the
/// chip how many bytes it may DMA into the buffer — with per-MTU sizing
/// that's the pool's device-writable `buf_len`, NOT the 16 KiB
/// jumbo max, so a 4 KiB MTU-1500 buffer can never be overrun by a giant
/// frame. `buf_len` is already ≤ `DESC_LEN_MASK` (the cshim caps it).
fn pre_post_rx_queue_descriptors(rx: &RxQueueState) {
    let buf_len = rx.buf_len.inner.load(Ordering::Relaxed) & regs::DESC_LEN_MASK;
    for i in 0..RING_LEN {
        let dma = rx.slot(i).dma;
        let mut opts1 = regs::DESC_OWN | buf_len;
        if i == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        // Initial RX ownership handoff follows the same ordering as NAPI
        // reposts: addr/opts2 first, then dma_wmb(), then OWN in opts1.
        ub::desc_publish_own(
            rx.desc.cast::<u8>(),
            i,
            Descriptor {
                opts1,
                opts2: 0,
                addr: dma,
            },
            rx.format,
        );
    }
}

fn pre_post_rx_descriptors(state: &NetdevState) {
    for rx in &state.rx_queues[..active_rx_queues(state)] {
        pre_post_rx_queue_descriptors(rx);
    }
}

/// Zero the TX descriptor ring; first `xmit` populates each slot
/// on-demand. EOR on the wrap slot is the only persistent bit we keep
/// across opens (so the chip wraps back to slot 0).
#[inline]
fn clear_tx_descriptor(state: &NetdevState, slot: usize) {
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
}

fn zero_tx_descriptors(state: &NetdevState) {
    for i in 0..RING_LEN {
        clear_tx_descriptor(state, i);
    }
}

/// Pointer reinterpretation: the cshim's IRQ contract gives the handler
/// the same opaque cookie passed at registration. We pass `&NetdevState`
/// cast to `*mut c_void`. Helper kept here so every IRQ-related call
/// uses the identical cast pattern.
#[inline]
fn cookie_from_state(state: &NetdevState) -> *mut c_void {
    core::ptr::from_ref(state).cast_mut().cast::<c_void>()
}

/// Register the IRQ handler with mode-aware flags. INTx pins may be
/// shared (`IRQF_SHARED`); MSI/MSI-X vectors are exclusive (`0`).
fn register_irq_handler(state: &NetdevState, cookie: *mut c_void) -> Result<()> {
    let irq_flags = match state.irq_mode() {
        IrqMode::Intx => ub::IRQF_SHARED,
        IrqMode::Msi => 0,
    };
    // RX queue 0 / legacy combined vector — always requested. Mark it so
    // `free_irq_if_registered` releases each vector exactly once on teardown
    // (open rollback guard or ndo_stop).
    ub::request_irq(state.irq.rx_nums[0], raw_irq_handler, cookie, irq_flags)?;
    state.irq.rx_requested[0]
        .inner
        .store(true, Ordering::Release);
    if state.irq_mode() == IrqMode::Msi && state.use_v2_irq_surface() {
        // V2: each extra active RX queue gets its own MSI-X vector
        // (entry i), routed to queue i's NAPI by `raw_irq_handler`. On a
        // mid-loop failure the already-registered vectors are released by the
        // IrqGuard rollback via `free_irq_if_registered`.
        for i in 1..active_rx_queues(state) {
            ub::request_irq(state.irq.rx_nums[i], raw_irq_handler, cookie, irq_flags)?;
            state.irq.rx_requested[i]
                .inner
                .store(true, Ordering::Release);
        }
        ub::request_irq(state.irq.tx_num, raw_irq_handler, cookie, irq_flags)?;
        state.irq.tx_requested.inner.store(true, Ordering::Release);
        ub::request_irq(state.irq.link_num, raw_irq_handler, cookie, irq_flags)?;
        state
            .irq
            .link_requested
            .inner
            .store(true, Ordering::Release);
    }
    Ok(())
}

/// Free the IRQ handler iff it is currently registered, atomically clearing
/// the flag so repeated / interleaved teardown paths free it exactly once.
/// `ndo_stop` and the `ndo_open` rollback guard both route through here;
/// without it, `ndo_stop` could `free_irq` an IRQ with no registered action
/// on an unbind-while-up / double-close and trip the kernel's
/// "trying to free already-free IRQ" WARN.
fn free_irq_if_registered(state: &NetdevState) {
    let cookie = cookie_from_state(state);
    // Clear any affinity hint set by the multi-queue spread before free_irq —
    // free_irq WARNs (WARN_ON_ONCE(desc->affinity_hint)) if a hint is still
    // attached. Clearing is a no-op when none was set, so do it unconditionally
    // for every vector we are about to release.
    if state.irq.link_requested.inner.swap(false, Ordering::AcqRel) {
        ub::bridge_irq_clear_hint(state.irq.link_num);
        ub::free_irq(state.irq.link_num, cookie);
    }
    if state.irq.tx_requested.inner.swap(false, Ordering::AcqRel) {
        ub::bridge_irq_clear_hint(state.irq.tx_num);
        ub::free_irq(state.irq.tx_num, cookie);
    }
    // Release RX vectors high→low (extras before rx0), mirroring the request
    // order. Each `swap` clears its flag so a vector is freed exactly once.
    for i in (0..RX_QUEUE_COUNT).rev() {
        if state.irq.rx_requested[i]
            .inner
            .swap(false, Ordering::AcqRel)
        {
            ub::bridge_irq_clear_hint(state.irq.rx_nums[i]);
            ub::free_irq(state.irq.rx_nums[i], cookie);
        }
    }
}

/// r8169 RTL8125B (MAC_VER_63) baseline: reset interrupt moderation before
/// enabling IRQ sources. Mirrors `rtl_hw_start_8125` in `r8169_main.c` and
/// vendor `rtl8125_hw_clear_int_miti`: clear the V2-surface and mitigation
/// bypass bits, zero the 0xa00..0xa80 INT_MITI table, and set `INT_CFG1 = 0`.
/// `program_interrupt_moderation` installs the current timer values later,
/// after the final IRQ surface is selected.
/// Sticky `ISR` bits are W1C-acked here too so the first post-unmask
/// edge into the IO-APIC isn't lost.
#[inline]
fn setup_interrupt_config(regs: &Regs<'_>) {
    // Clear V2-enable plus the bypass bits that can suppress the INT_MITI
    // timer table. V2 enable itself is written later, once IRQ mode is known.
    let cfg0 = regs.int_cfg0();
    regs.set_int_cfg0(
        cfg0 & !(regs::INT_CFG0_ENABLE_8125
            | regs::INT_CFG0_TIMEOUT0_BYPASS_8125
            | regs::INT_CFG0_MITIGATION_BYPASS_8125),
    );
    regs.zero_coalesce_table_8125b();
    regs.set_int_cfg1(0);
    regs.ack_isr(0xFFFF_FFFF);
    regs.ack_isr_v2(0xFFFF_FFFF);
}

/// Chip-side activation of the per-message-id ISR_V2 register layout. Only flip
/// `INT_CFG0_ENABLE_8125` when probe selected `use_v2`; with one MSI/MSI-X
/// vector we keep V2 disabled so TX completions use the legacy combined ISR/IMR
/// surface on vector 0. Must run BEFORE the matching `set_imr_v2_mask` write —
/// `rearm_irq_baseline` then targets the V2 surface.
#[inline]
fn activate_v2_isr_for_msi(state: &NetdevState, regs: &Regs<'_>) {
    if state.irq_mode() != IrqMode::Intx && state.use_v2_irq_surface() {
        let rb = regs.set_int_cfg0_v2_enable(true);
        if rb & regs::INT_CFG0_ENABLE_8125 == 0 {
            pr_warn!(
                "r8125_rust: V2 ISR enable did not latch: INT_CFG0 rb=0x{:02x}\n",
                rb
            );
        }
    }
}

/// Program RTL8125B interrupt moderation for the IRQ surface selected at probe.
/// The hardware timer block is the 0xa00 INT_MITI table even when interrupts
/// are delivered through the legacy ISR/IMR window (`use_v2=false`).
#[inline]
fn program_interrupt_moderation(state: &NetdevState, regs: &Regs<'_>) {
    let rx_timer = *crate::module_parameters::rx_coalesce_timer.value();
    let tx_timer = *crate::module_parameters::tx_coalesce_timer.value();
    let use_v2 = state.irq_mode() == IrqMode::Msi && state.use_v2_irq_surface();
    let (rx_rb, tx_rb) = if use_v2 {
        let (rx_rb, _) = regs.set_coalesce_8125b_vector(regs::V2_RX_Q0_VECTOR, rx_timer, 0);
        let (_, tx_rb) = regs.set_coalesce_8125b_vector(regs::V2_TX_Q0_VECTOR, 0, tx_timer);
        regs.set_coalesce_8125b_vector(regs::V2_LINK_VECTOR, 0, 0);
        (rx_rb, tx_rb)
    } else {
        regs.set_coalesce_8125b(rx_timer, tx_timer)
    };
    pr_info!(
        "r8125_rust: INT_MITI timers use_v2={} RX=0x{:04x}/rb=0x{:04x} TX=0x{:04x}/rb=0x{:04x}\n",
        use_v2,
        rx_timer,
        rx_rb,
        tx_timer,
        tx_rb
    );
}

/// Enable RX + TX in the chip-command register. Per r8169 the IMR write
/// must come AFTER this (we do that next via `rearm_irq_baseline`).
#[inline]
fn enable_chip_engines(regs: &Regs<'_>) {
    regs.set_chip_cmd(regs::CMD_RX_ENB | regs::CMD_TX_ENB);
}

/// Mask both legacy and V2 IRQ surfaces idempotently and disable the
/// chip-command register. Shared between the `ndo_stop` teardown and
/// the `ndo_open` post-hw_start rollback paths so the rollback discipline
/// is mode-agnostic. The V2 writes are no-ops when V2 isn't active and
/// vice versa.
#[inline]
fn quiesce_chip(regs: &Regs<'_>) {
    regs.set_imr(0);
    regs.clear_imr_v2_mask(0xFFFF_FFFF);
    regs.set_chip_cmd(0);
}

/// Walk the TX shadow at `ndo_stop` and release any DMA mapping +
/// skb the chip didn't complete before we masked it. Each slot's
/// per-fragment `is_frag` flag picks `dma_unmap_page` vs
/// `dma_unmap_single`; the (last-frag-only) skb pointer is freed via
/// `skb_free_error` so the disposition counter records a TX error.
fn reap_inflight_tx_shadow(state: &NetdevState) {
    let ndev = state.ndev.load(Ordering::Acquire);
    let bql_was_active = bql_active(state);
    let mut bql_pkts = 0usize;
    let mut bql_bytes = 0usize;

    for i in 0..RING_LEN {
        let len = state.tx.shadow_len[i].swap(0, Ordering::AcqRel) as usize;
        state.tx.shadow_budget_len[i].store(0, Ordering::Release);
        if len > 0 {
            let handle = state.tx.shadow_dma[i].load(Ordering::Acquire);
            if state.tx.shadow_is_frag[i].swap(false, Ordering::AcqRel) {
                ub::skb_dma_unmap_frag_tx(&state.pdev, handle, len);
            } else {
                ub::skb_dma_unmap_tx(&state.pdev, handle, len);
            }
        }
        let raw_skb = state.tx.shadow[i].swap(ptr::null_mut(), Ordering::AcqRel);
        if let Some(skb) = crate::skb::DriverOwnedSkb::from_raw_nullable(raw_skb) {
            if bql_was_active {
                bql_bytes += skb.wire_len();
                bql_pkts += 1;
            }
            // Reclaim the disposition obligation from the shadow and
            // route the skb through the error counter.
            skb.free_with_error();
        }
    }
    // Balance any packets that were counted by netdev_sent_queue but were
    // freed during stop before hardware completion. We still report them to
    // DQL so a later reopen of the same netdev does not inherit stale queued
    // bytes.
    if bql_pkts > 0 {
        ub::netdev_completed_queue(ndev, bql_pkts, bql_bytes);
    }
}

/// Read back the key post-open registers as a sanity log. Diagnostic
/// only — the actual bring-up correctness is decided by the linked
/// state of the chip command register + the unmasked IMR / IMR_V2.
fn log_ndo_open_complete(state: &NetdevState, regs: &Regs<'_>) {
    let irq_mode = state.irq_mode();
    let use_v2 = irq_mode == IrqMode::Msi && state.use_v2_irq_surface();
    let (isr, imr, isr_v2, imr_v2) = match (irq_mode, use_v2) {
        (IrqMode::Intx, _) => (regs.isr(), regs.imr_readback(), 0, 0),
        (IrqMode::Msi, false) => (regs.isr(), regs.imr_readback(), 0, 0),
        (IrqMode::Msi, true) => (0, 0, regs.isr_v2(), regs.imr_v2_set_diagnostic()),
    };
    pr_info!(
        "r8125_rust ndo_open complete: mode={:?} use_v2={} IRQ={} tx_irq={} link_irq={} ChipCmd=0x{:02x} ISR=0x{:08x} IMR_rb=0x{:08x} ISR_v2=0x{:08x} IMR_V2_SET_diag=0x{:08x} INT_CFG0=0x{:02x} PHYStatus=0x{:02x} tx_dma=0x{:016x} rx_dma=0x{:016x}\n",
        irq_mode,
        use_v2,
        state.irq.rx_nums[0],
        state.irq.tx_num,
        state.irq.link_num,
        regs.chip_cmd(),
        isr,
        imr,
        isr_v2,
        imr_v2,
        regs.int_cfg0(),
        regs.phy_status(),
        state.tx.dma,
        state.rx_queue0().dma,
    );
}

// ── ndo_open RAII guards ──────────────────────────────────────────────────
//
// The bring-up acquires two things that need to be released on every
// failure path: the RX page pool (via `allocate_rx_pool` /
// `free_rx_slots`) and the registered IRQ handler (`register_irq_handler`
// / `ub::free_irq`). Before #61 each of the four post-acquisition
// failure branches in `ndo_open` open-coded the same rollback steps.
// The guards encapsulate the resource so an early `?` or `return` drops
// the cleanup automatically.
//
// **Drop order.** Rust drops locals in REVERSE declaration order — and
// because `IrqGuard` is declared AFTER `RxPoolGuard` in `ndo_open`, an
// error return drops the IRQ first (synchronising the kernel IRQ
// dispatch path) and the pool second (so the handler can't fire onto
// freed slot DMA). The PHY teardown (`bridge_phy_stop`) and chip mask
// (`quiesce_chip`) stay inline at the failure site because they don't
// have a "released on success" half — every PHY teardown is either
// "phy never connected" (no call needed) or "phy connected,
// stop unconditionally" (call before returning).

/// RAII guard for the per-slot RX page pool. `allocate(state)` runs the
/// per-slot `rx_alloc` loop and on any per-slot failure unwinds
/// every prior allocation before returning `Err`. The guard's `Drop`
/// frees the pool unless `release()` was called — which signals success
/// in `ndo_open` and hands ownership of the pool to the bound netdev
/// (where `ndo_stop` later frees it).
struct RxPoolGuard<'a> {
    state: &'a NetdevState,
    released: bool,
}

impl<'a> RxPoolGuard<'a> {
    fn allocate(state: &'a NetdevState) -> Result<Self> {
        allocate_rx_pool(state)?;
        Ok(Self {
            state,
            released: false,
        })
    }

    /// Mark the pool as owned by the active netdev — `ndo_stop` (not
    /// `Drop`) will be the one to free it.
    fn release(mut self) {
        self.released = true;
    }
}

impl<'a> Drop for RxPoolGuard<'a> {
    fn drop(&mut self) {
        if !self.released {
            free_rx_slots(self.state);
        }
    }
}

/// RAII guard for the registered IRQ handler. `register(state)` wraps
/// `register_irq_handler` (mode-aware flags); on `ndo_open` failure its
/// `Drop` rolls back via `free_irq_if_registered`. `release()` transfers
/// ownership to the bound netdev so `ndo_stop` is the eventual freer. The
/// `requested` flag in `IrqState` guarantees the underlying `free_irq`
/// runs exactly once regardless of which path (guard or `ndo_stop`) hits.
struct IrqGuard<'a> {
    state: &'a NetdevState,
    released: bool,
}

impl<'a> IrqGuard<'a> {
    fn register(state: &'a NetdevState) -> Result<Self> {
        let cookie = cookie_from_state(state);
        register_irq_handler(state, cookie)?;
        Ok(Self {
            state,
            released: false,
        })
    }

    fn release(mut self) {
        self.released = true;
    }
}

impl<'a> Drop for IrqGuard<'a> {
    fn drop(&mut self) {
        if !self.released {
            free_irq_if_registered(self.state);
        }
    }
}

/// Apply the RTL8125B PHY errata sequence (mainline `rtl8125b_hw_phy_config`)
/// through the phylib paged/MMD accessors. The sequence + register values are
/// the host-tested table in [`crate::phy_config`]; this only walks it and routes
/// each primitive to the matching boundary wrapper. Best-effort (individual
/// write errors are non-fatal, matching r8169). Run once during open, after PHY
/// connect/reset and before the link state machine starts.
fn apply_phy_hw_config(ndev: *mut bindings::net_device) {
    use crate::phy_config::{expand, PhyPrimitive, HW_PHY_CONFIG};

    for op in HW_PHY_CONFIG {
        expand(op, |p| match p {
            PhyPrimitive::ModifyPaged {
                page,
                reg,
                mask,
                set,
            } => ub::phy_modify_paged(ndev, page, reg, mask, set),
            PhyPrimitive::WritePaged { page, reg, val } => {
                ub::phy_write_paged(ndev, page, reg, val)
            }
            PhyPrimitive::WriteMmd { devad, reg, val } => ub::phy_write_mmd(ndev, devad, reg, val),
            PhyPrimitive::ModifyMmd {
                devad,
                reg,
                mask,
                set,
            } => ub::phy_modify_mmd(ndev, devad, reg, mask, set),
        });
    }
}

/// Sink that applies the PHY MCU firmware opcode stream to real hardware. The
/// firmware switches between PHY MDIO and MAC-OCP "MCU" register space; both
/// share the page base (`state.phy.ocp_base`, like r8169's `tp->ocp_base`).
/// PHY access uses the `r8168g_mdio_write` semantics our `phy` module already
/// implements (incl. the 0x1f page register); MAC-OCP uses `mac_ocp_write` with
/// the page base + raw offset. All accesses are safe (`mmio` typed Bar).
struct PhyFwSink<'a> {
    state: &'a NetdevState,
}

impl crate::phy_fw::FwSink for PhyFwSink<'_> {
    fn write(&mut self, target: crate::phy_fw::FwTarget, reg: u16, val: u16) {
        match target {
            crate::phy_fw::FwTarget::Phy => {
                if reg == 0x1f {
                    crate::phy::page_select_write(self.state, val);
                } else {
                    let _ = crate::phy::mdio_write(self.state, reg as u8, val);
                }
            }
            crate::phy_fw::FwTarget::MacMcu => {
                if reg == 0x1f {
                    self.state
                        .phy
                        .ocp_base
                        .store(u32::from(val) << 4, Ordering::Release);
                } else {
                    let base = self.state.phy.ocp_base.load(Ordering::Acquire);
                    self.state.regs().mac_ocp_write(base + u32::from(reg), val);
                }
            }
        }
    }

    fn read(&mut self, target: crate::phy_fw::FwTarget, reg: u16) -> u16 {
        match target {
            crate::phy_fw::FwTarget::Phy => {
                if reg == 0x1f {
                    crate::phy::page_select_read(self.state)
                } else {
                    crate::phy::mdio_read(self.state, reg as u8).unwrap_or(0xffff)
                }
            }
            crate::phy_fw::FwTarget::MacMcu => {
                let base = self.state.phy.ocp_base.load(Ordering::Acquire);
                self.state.regs().mac_ocp_read(base + u32::from(reg))
            }
        }
    }

    fn delay_ms(&mut self, ms: u16) {
        kernel::time::delay::fsleep(kernel::time::Delta::from_millis(i64::from(ms)));
    }
}

/// Apply the RTL8125B PHY MCU firmware (`rtl_nic/rtl8125b-2.fw`) — the patch
/// mainline runs first inside `rtl8125b_hw_phy_config`, that the stock phylib
/// driver does not. The firmware is optional: if absent or invalid the driver
/// continues with the errata table only (the same fallback r8169 takes). Run
/// once during open, before [`apply_phy_hw_config`]. Fully validated
/// (`phy_fw::parse`) before any register is touched.
fn apply_phy_firmware(state: &NetdevState) {
    use kernel::firmware::Firmware;

    let fw = match Firmware::request_nowarn(c"rtl_nic/rtl8125b-2.fw", state.pdev.as_ref()) {
        Ok(f) => f,
        Err(_) => {
            pr_info!("r8125_rust: PHY firmware not present; applying errata only\n");
            return;
        }
    };
    let parsed = match crate::phy_fw::parse(fw.data()) {
        Ok(p) => p,
        Err(e) => {
            pr_warn!(
                "r8125_rust: PHY firmware rejected ({:?}); applying errata only\n",
                e
            );
            return;
        }
    };

    let mut sink = PhyFwSink { state };
    crate::phy_fw::run(&parsed, &mut sink);

    // r8169 note: at least one firmware doesn't restore the page base, and the
    // firmware may have triggered a PHY soft reset. Force the base back to the
    // standard page and wait for BMCR.RESET to clear (~600 ms cap).
    crate::phy::page_select_write(state, 0);
    let ndev = state.ndev.load(Ordering::Acquire);
    for _ in 0..12 {
        match crate::phy::mdio_read(state, 0x00) {
            Ok(v) if v & 0x8000 == 0 => break,
            _ => kernel::time::delay::fsleep(kernel::time::Delta::from_millis(50)),
        }
    }
    // Expose the firmware version via `ethtool -i` (proof it loaded).
    ub::set_fw_version(ndev, parsed.version());
    pr_info!("r8125_rust: PHY firmware applied ({} ops)\n", parsed.size());
}

// ── ndo_open ──────────────────────────────────────────────────────────────

fn ndo_open(state: &NetdevState, feature_flags: u32) -> Result<()> {
    let debug_counters = *crate::module_parameters::debug_counters.value() != 0;
    state
        .debug_counters
        .store(debug_counters, Ordering::Relaxed);
    reset_debug_counts();
    state.bql_enabled.store(false, Ordering::Release);
    apply_netdev_features(state, feature_flags);
    state.reset_indices();
    state.tx.byte_budget.inner.store(
        *crate::module_parameters::tx_byte_budget.value(),
        Ordering::Relaxed,
    );
    validate_rss_queue_request(state)?;
    // Publish the runtime active RX queue count to the C bridge so ethtool
    // (get_channels / get_rx_ring_count) and the stack
    // (netif_set_real_num_rx_queues → RPS sysfs) report the real number. Runs
    // under RTNL with the netdev down, before any queue is posted.
    let ndev = state.ndev.load(Ordering::Acquire);
    ub::set_active_rx_queues(ndev, active_rx_queues(state) as u32);
    let regs = state.regs();

    // Bus-mastering on. (DMA mask was set at probe.)
    ub::pci_set_master(&state.pdev);

    program_dma_rings(state, &regs, feature_flags);
    let rx_pool = RxPoolGuard::allocate(state)?;
    pre_post_rx_descriptors(state);
    zero_tx_descriptors(state);
    let irq = IrqGuard::register(state)?;

    // PHY step 1 — connect + soft reset + resume. On the 8125B's
    // integrated MAC/PHY, `genphy_soft_reset` writes `BMCR_RESET` which
    // ALSO clears MAC-side state (`ChipCmd`). Running it BEFORE the MAC
    // OCP init + `ChipCmd` write is critical, or our `ChipCmd` RX|TX
    // bits get wiped out by the PHY reset. Matches r8169 ordering at
    // `rtl8169_up` (`phy_init_hw → phy_resume → rtl8169_init_phy` run
    // before `rtl_reset_work → rtl_hw_start`).
    let ndev = state.ndev.load(Ordering::Acquire);
    ub::bridge_phy_connect_and_reset(ndev)?;

    // Apply the RTL8125B PHY config (mainline rtl8125b_hw_phy_config) that the
    // stock phylib driver does not — after PHY reset, before the link state
    // machine starts. Mirrors r8169 running rtl8169_init_phy before rtl_hw_start.
    // Firmware MCU patch first, then the errata register table (same order as
    // rtl8125b_hw_phy_config).
    apply_phy_firmware(state);
    apply_phy_hw_config(ndev);

    setup_interrupt_config(&regs);

    // r8169 `rtl_hw_start_8125_common` for `MAC_VER_63`. The minimum
    // init sequence (MAC OCP + MISC ungate) the chip needs before
    // `ChipCmd RX|TX` enable, or the engines silently refuse to move
    // packets. Lives in `hw::hw_start_8125b` so cross-referencing with
    // the upstream source-of-truth function stays trivial.
    if let Err(e) = crate::hw::hw_start_8125b(&regs) {
        ub::bridge_phy_stop(ndev);
        return Err(e);
    }

    // Override the jumbo-default RxMaxSize from hw_start with the per-MTU
    // value: the chip must not accept a frame larger than the
    // pool's buffers hold. Set after hw_start, before the RX engine is
    // enabled below. `buf_len` is the pool's device-writable length, ≤
    // RX_MAX_SIZE_JUMBO (0x3FFF), so it fits the 16-bit register.
    regs.set_rx_max_size(state.rx_queue0().buf_len.inner.load(Ordering::Relaxed) as u16);

    // Program the chip's RX-filter MAC (IDR0/IDR4) from dev_addr. hw_start's
    // reset clears IDR0, so without this the chip would drop all unicast frames
    // addressed to our MAC; it also makes the random-MAC fallback and any future
    // `ip link set address` actually take effect in hardware. Mirrors the vendor
    // rtl8125_rar_set call after hw init.
    regs.set_mac_address(&ub::bridge_dev_addr(ndev));

    // `hw_start_8125b` force-clears RSS_CTRL/Q_NUM as a safe baseline. Program
    // the requested hash/RSS state after that clear and before RX/TX engines run.
    apply_rss_programming(state);

    enable_chip_engines(&regs);
    activate_v2_isr_for_msi(state, &regs);
    program_interrupt_moderation(state, &regs);

    // Unmask the chosen IRQ surface LAST — mirrors r8169 `rtl_irq_enable`.
    // `rearm_irq_baseline` picks legacy `IMR` or V2 `IMR_V2_SET` based on
    // `state.irq_mode()`. Enable every active queue's source bits so each gets
    // its first interrupt (queue 0 also enables TX + link). For the legacy
    // surface this writes the same baseline once.
    for queue_id in 0..active_rx_queues(state) {
        crate::napi::rearm_irq_baseline(state, queue_id as u32);
    }

    // PHY step 2 — kick the state machine LAST. Per r8169 ordering this
    // runs after `ChipCmd RX|TX` enable + `IMR` programming. Carrier
    // flips on automatically inside `bridge_phylink_handler` when the
    // PHY reports link-up; the earlier unconditional `carrier_on` is
    // dropped.
    if let Err(e) = ub::bridge_phy_kick_state_machine(ndev) {
        // Roll back the chip-side work + PHY connection. The IRQ + RX
        // pool guards drop on the way out and finish the rollback.
        // `quiesce_chip` dual-masks both IRQ surfaces idempotently so a
        // follow-up `ndo_open` retry sees a known state.
        quiesce_chip(&regs);
        ub::bridge_phy_stop(ndev);
        return Err(e);
    }
    // BQL: seed dql.min_limit to one full MTU frame + headroom BEFORE the
    // queue is woken, so the first xmit can't drive dql_avail negative (no
    // netdev_reset_queue — Approach A, BQL_RETRY_PLAN.md). Bounds TX ring
    // residency so fq_codel can protect latency under a saturated bulk flow.
    // Gated by bql_mode (safe default: skip on MSI delivery). Snapshot the decision
    // for this open so sent/completed accounting cannot be imbalanced by a
    // runtime module-parameter change.
    let bql_enabled = select_bql_active(state);
    state.bql_enabled.store(bql_enabled, Ordering::Release);
    if bql_enabled {
        ub::dql_seed_min_limit(ndev);
    }
    ub::bridge_tx_wake_queue(ndev);
    log_ndo_open_complete(state, &regs);
    // Transfer ownership of the IRQ + RX pool to the bound netdev so
    // their `Drop`s skip cleanup; `ndo_stop` is now the eventual freer.
    irq.release();
    rx_pool.release();
    Ok(())
}

// ── ndo_stop ──────────────────────────────────────────────────────────────

fn ndo_stop(state: &NetdevState) {
    let regs = state.regs();
    let ndev = state.ndev.load(Ordering::Acquire);

    let (x, i, n, d) = debug_counts();
    pr_info!(
        "r8125_rust ndo_stop: xmit_calls={} irq_fires={} napi_polls={} tx_doorbells={}\n",
        x,
        i,
        n,
        d
    );

    // Stop kernel TX submissions + carrier first so xmit can't race the
    // teardown. PHY stop releases the link-status handler and disconnects
    // the phy_device from the netdev (next ndo_open re-attaches it).
    ub::bridge_tx_disable(ndev);
    ub::bridge_phy_stop(ndev);
    ub::bridge_carrier_off(ndev);

    // Mask both IRQ surfaces + disable RX/TX engines (idempotent — see
    // `quiesce_chip` doc). Then W1C-ack any pending bits on BOTH ISR
    // windows so a follow-up `ndo_open` sees a clean slate.
    quiesce_chip(&regs);
    regs.clear_imr_v2_mask(0xFFFF_FFFF);
    regs.ack_isr(0xFFFF_FFFF);
    regs.ack_isr_v2(0xFFFF_FFFF);

    // Release the IRQ (kernel synchronises) — exactly once via the flag,
    // so a close on an already-quiesced / never-fully-opened device can't
    // double-free.
    // Keep this explicit to prove `clear_imr_v2_mask` happens before free_irq
    // for static-design tooling.
    free_irq_if_registered(state);

    reap_inflight_tx_shadow(state);
    state.debug_counters.store(false, Ordering::Relaxed);
    state.bql_enabled.store(false, Ordering::Release);

    // Zero the descriptor rings so a subsequent open starts fresh.
    for i in 0..RING_LEN {
        ub::desc_write(state.tx.desc, i, Descriptor::default());
        for rx in &state.rx_queues {
            ub::desc_write_rx(rx.desc.cast::<u8>(), i, RxDescriptor::default(), rx.format);
        }
    }

    // Release every RX slot's page chunk + DMA mapping. The
    // chip already had its descriptors zeroed above, so it can't DMA
    // into a freed slot. `rx_free` short-circuits on the empty
    // sentinel, which is what we leave behind for the next `ndo_open`.
    free_rx_slots(state);
}

// ── ndo_start_xmit helpers ────────────────────────────────────────────────

/// TSO/CSUM offload bit computation plus post-mutation fragment count. The skb
/// is BORROWED — caller retains ownership and is responsible for
/// `free_with_error` on an error outcome so the `tx_dropped_error` counter
/// increments at the right level.
///
/// May mutate the skb (`skb_cow_head` + `tcp_v6_gso_csum_prep` for IPv6
/// TSO; padding plus `skb_checksum_help` for the narrow RTL8125 UDP pad quirk
/// or unsupported checksum-partial cases). These paths write linear data, so
/// any subsequent DMA map sees the final bytes — which is why this step MUST
/// run before `map_skb_linear`.
fn compute_offload_bits(skb: &crate::skb::DriverOwnedSkb) -> Result<(u32, u32, usize)> {
    let (opts1, opts2, nr_frags) = skb.tx_offload_prepare()?;
    Ok((opts1, opts2, nr_frags as usize))
}

/// Check ring capacity for a logical packet of `n_desc` descriptors. We
/// keep at least one slot empty so `tx_head == tx_tail` can only mean
/// "ring empty" (not "ring full").
///
/// On exhaustion: bumps the `tx_busy_exception` counter, asks the
/// kernel to retry via `bridge_tx_stop_queue` (with the SMP-race
/// recheck), and returns `None`. Caller returns `NETDEV_TX_BUSY`. On
/// success returns `Some(tail)` so the caller can reuse the snapshot
/// in the post-commit `in_flight_after` calculation.
fn try_reserve_ring_space(state: &NetdevState, head: usize, n_desc: usize) -> Option<usize> {
    let tail = state.tx.tail.inner.load(Ordering::Acquire);
    let in_flight = head.wrapping_sub(tail);
    if in_flight + n_desc >= RING_LEN {
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::tx_busy_exception(ndev);
        stop_tx_queue_with_recheck(state, head);
        None
    } else {
        Some(tail)
    }
}

/// DMA-map the LINEAR head of `skb`. Returns `Some((handle, len))` on
/// success, or `None` on `dma_map_single` failure. The skb is BORROWED;
/// caller disposes via `free_with_error` on `None` (explicit
/// ownership transfer).
#[inline]
fn map_skb_linear(
    state: &NetdevState,
    skb: &crate::skb::DriverOwnedSkb,
) -> Option<(bindings::dma_addr_t, u32)> {
    skb.dma_map_linear(&state.pdev).ok()
}

/// RAII guard for the linear-head + per-fragment DMA mappings of an
/// in-flight TX skb. Each `record_frag()` call
/// after a successful `skb_frag_dma_map` + shadow publish bumps the
/// per-Drop unmap count. On error, an early `return Err(())` drops the
/// guard, which:
///   1. `dma_unmap_single`s the linear head we already mapped
///   2. `dma_unmap_page`s every fragment shadow slot 0 .. `frags_published`
///   3. Clears each pre-staged fragment descriptor and shadow slot
///   4. Frees the skb via `skb_free_error` (counters the drop)
///
/// The success path calls `release(self)` after all fragments + the
/// FirstFrag descriptor are committed — `Drop` then short-circuits.
///
/// **Hot path note.** The guard adds ~40 bytes of stack and one
/// integer increment per fragment. On the success path the `released`
/// check in Drop folds to a constant after inlining, so the only
/// runtime cost is the bump in `record_frag()`. Throughput is unchanged
/// at 2.3+ Gbps in KVM after #61.
struct TxMapGuard<'a> {
    state: &'a NetdevState,
    /// Some while the guard owns the disposition obligation; `None`
    /// after `release()` (success — shadow now owns) or after Drop
    /// (failure — Drop unmapped + freed).
    skb: Option<crate::skb::DriverOwnedSkb>,
    head: usize,
    linear_handle: bindings::dma_addr_t,
    linear_len: u32,
    frags_published: usize,
}

impl<'a> TxMapGuard<'a> {
    fn new(
        state: &'a NetdevState,
        skb: crate::skb::DriverOwnedSkb,
        head: usize,
        linear_handle: bindings::dma_addr_t,
        linear_len: u32,
    ) -> Self {
        Self {
            state,
            skb: Some(skb),
            head,
            linear_handle,
            linear_len,
            frags_published: 0,
        }
    }

    /// Borrow the underlying skb for one more `dma_map_frag` call.
    /// Returns `None` only after `release()` or Drop, which cannot
    /// happen during the active fragment loop unless this guard's own
    /// invariants are broken.
    #[inline]
    fn skb(&self) -> Option<&crate::skb::DriverOwnedSkb> {
        self.skb.as_ref()
    }

    #[inline]
    fn record_frag(&mut self) {
        self.frags_published += 1;
    }

    /// Success — ownership of the skb's disposition obligation has
    /// transferred to the per-TX-slot shadow (the LastFrag-or-FirstFrag
    /// slot now holds the raw pointer). Consume the wrapper via
    /// `into_raw()` so `Drop` is a no-op; the returned raw pointer is
    /// the value the caller stores in the shadow. `None` means the guard
    /// was already released, which cannot happen in the normal flow but
    /// still must not panic in kernel context.
    fn release(mut self) -> Option<*mut bindings::sk_buff> {
        // `take()` leaves `self.skb = None` so the subsequent Drop
        // short-circuits the unmap path.
        self.skb.take().map(crate::skb::DriverOwnedSkb::into_raw)
    }
}

impl<'a> Drop for TxMapGuard<'a> {
    fn drop(&mut self) {
        // If `release` ran the slot is `None`; nothing to undo.
        if let Some(skb) = self.skb.take() {
            ub::skb_dma_unmap_tx(
                &self.state.pdev,
                self.linear_handle,
                self.linear_len as usize,
            );
            for j in 0..self.frags_published {
                let prev_slot = (self.head.wrapping_add(1 + j)) % RING_LEN;
                let pa = self.state.tx.shadow_dma[prev_slot].load(Ordering::Acquire);
                let pl = self.state.tx.shadow_len[prev_slot].load(Ordering::Acquire);
                clear_tx_descriptor(self.state, prev_slot);
                ub::skb_dma_unmap_frag_tx(&self.state.pdev, pa, pl as usize);
                self.state.tx.clear_shadow_slot(prev_slot);
            }
            skb.free_with_error();
        }
    }
}

/// DMA-map paged fragments of `skb` starting at slot `head+1` and write
/// each fragment's descriptor in-place with the propagated TSO/CSUM
/// bits. The chip walks the chain after seeing `OWN|FS` on `head` (which
/// the FirstFrag write commits LAST) so it's safe to publish fragment
/// descriptors with `OWN` set as we go.
///
/// Caller bypasses this helper for `nr_frags == 0`. On any per-fragment failure
/// the [`TxMapGuard`] drops and unmaps the linear head + every already-mapped
/// fragment, clears any pre-staged fragment descriptors, then frees the skb;
/// the caller just observes `Err(())` and returns `NETDEV_TX_OK`.
///
/// Per r8169 `rtl8169_tx_map` and Realtek vendor `rtl8125_xmit_frags`,
/// BOTH opts[0] (TSO GTSEN bits) AND opts[1] (CSUM bits / MSS) get
/// propagated to every fragment descriptor — they're not first-only.
/// Zeroing opts2 on frags previously caused on-wire checksum corruption.
#[allow(clippy::too_many_arguments)]
fn map_skb_fragments(
    state: &NetdevState,
    skb: crate::skb::DriverOwnedSkb,
    head: usize,
    nr_frags: usize,
    linear_handle: bindings::dma_addr_t,
    linear_len: u32,
    tso_opts1: u32,
    first_opts2: u32,
    budget_len: u32,
) -> Result<*mut bindings::sk_buff, ()> {
    let mut guard = TxMapGuard::new(state, skb, head, linear_handle, linear_len);
    for i in 0..nr_frags {
        let Some(skb) = guard.skb() else {
            // Guard exhausted before the loop finished — shouldn't
            // happen during active fragment mapping, but treat
            // as a soft failure that lets the guard's Drop clean up.
            return Err(());
        };
        let (h, l) = match skb.dma_map_frag(&state.pdev, i as u32) {
            Ok(pair) => pair,
            Err(_) => {
                // Guard's Drop unmaps linear + all `frags_published`
                // frags and frees the skb. Caller returns NETDEV_TX_OK.
                return Err(());
            }
        };
        let slot = (head.wrapping_add(1 + i)) % RING_LEN;
        let is_last_frag = i + 1 == nr_frags;
        let mut opts1 = regs::DESC_OWN | tso_opts1 | (l & regs::DESC_LEN_MASK);
        if is_last_frag {
            opts1 |= regs::DESC_TX_LS;
        }
        if slot == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        state.tx.shadow_dma[slot].store(h, Ordering::Release);
        state.tx.shadow_len[slot].store(l, Ordering::Release);
        state.tx.shadow_is_frag[slot].store(true, Ordering::Release);
        if is_last_frag && budget_len != 0 {
            state.tx.shadow_budget_len[slot].store(budget_len, Ordering::Release);
        }
        // skb pointer lives on the LAST descriptor only; intermediate
        // fragments stay null so the reaper only consumes the skb once.
        state.tx.shadow[slot].store(
            if is_last_frag {
                skb.as_raw()
            } else {
                core::ptr::null_mut()
            },
            Ordering::Release,
        );
        ub::desc_write(
            state.tx.desc,
            slot,
            Descriptor {
                opts1,
                opts2: first_opts2,
                addr: h,
            },
        );
        guard.record_frag();
    }
    // Success — the LastFrag shadow now owns the disposition obligation
    // (or, for the `nr_frags == 0` single-descriptor case, the caller
    // will install the raw pointer into the FirstFrag shadow below).
    // `release()` consumes the wrapper without freeing.
    guard.release().ok_or(())
}

// ── ndo_start_xmit ────────────────────────────────────────────────────────

/// Select whether BQL should run for the next open. Safe default runs BQL only
/// over INTx; on MSI/MSI-X the driver-owned `tx_byte_budget` throttle is the
/// latency mechanism instead (`netdev_sent_queue` historically suppressed MSI-X
/// delivery on the V2 surface — docs/perf/bql_20260605/). The gate is on the
/// delivery mode directly (the V2 ISR surface is no longer used — see
/// docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md — so the old
/// `!use_v2_irq_surface()` proxy would now read true on MSI and is wrong).
fn select_bql_active(state: &NetdevState) -> bool {
    match *crate::module_parameters::bql_mode.value() {
        0 => false,
        2 => true,
        _ => state.irq_mode() == IrqMode::Intx,
    }
}

/// Whether BQL sent/completed accounting is active for this open. Gates the
/// `netdev_sent_queue`/`netdev_completed_queue` pair consistently: open
/// snapshots the module-param decision once, and xmit/reap/stop all read this
/// same per-open value so DQL never sees completed without sent or vice versa.
pub(crate) fn bql_active(state: &NetdevState) -> bool {
    state.bql_enabled.load(Ordering::Acquire)
}

fn ndo_start_xmit(state: &NetdevState, skb: crate::skb::DriverOwnedSkb) -> c_int {
    let debug_counters = debug_counters_active(state);
    if debug_counters {
        XMIT_CALLS.fetch_add(1, Ordering::Relaxed);
    }

    // Offload bits — may mutate skb data; must precede the DMA map.
    let (tso_opts1, first_opts2, nr_frags) = match compute_offload_bits(&skb) {
        Ok(bits) => bits,
        Err(_) => {
            skb.free_with_error();
            return NETDEV_TX_OK;
        }
    };

    let n_desc = 1 + nr_frags;
    let head = state.tx.head.inner.load(Ordering::Relaxed);

    let tail = match try_reserve_ring_space(state, head, n_desc) {
        Some(t) => t,
        None => {
            // NETDEV_TX_BUSY — kernel keeps the skb and will requeue.
            // Dissolve the wrapper without invoking `dev_kfree_skb_any`.
            let _ = skb.into_raw();
            return NETDEV_TX_BUSY;
        }
    };

    let (linear_handle, linear_len) = match map_skb_linear(state, &skb) {
        Some(pair) => pair,
        None => {
            skb.free_with_error();
            return NETDEV_TX_OK;
        }
    };
    // The default small-frame path is single-buffer and BQL-inactive, so
    // `linear_len` is the wire length and avoids a per-packet skb_len FFI call.
    // BQL and SG/TSO still use the skb's logical length for balanced accounting.
    let bql_enabled = bql_active(state);
    let wire_len = if bql_enabled || nr_frags != 0 {
        skb.wire_len()
    } else {
        linear_len as usize
    };
    let byte_budget = state.tx.byte_budget.inner.load(Ordering::Relaxed) as usize;
    let budgeted_wire_len = tx_budget_tracked_bytes(byte_budget, wire_len);
    let budget_len = tx_budget_shadow_len(budgeted_wire_len);
    let budgeted_wire_len = budget_len as usize;

    // Single-buffer packets have no fallible work left after the linear DMA
    // map, so consume the wrapper directly and skip the SG rollback guard.
    // SG packets hand ownership to `map_skb_fragments`; on error its
    // TxMapGuard has already unmapped linear + published fragment mappings and
    // freed the skb. On success it returns the raw pointer for shadow storage.
    let skb_raw = if nr_frags == 0 {
        skb.into_raw()
    } else {
        match map_skb_fragments(
            state,
            skb,
            head,
            nr_frags,
            linear_handle,
            linear_len,
            tso_opts1,
            first_opts2,
            budget_len,
        ) {
            Ok(r) => r,
            Err(()) => return NETDEV_TX_OK,
        }
    };

    // ── Write FirstFrag descriptor LAST — this is the commit point ─────
    //
    // The chip only starts walking once it sees OWN|FS on slot[0]. By
    // publishing the head LAST (after all fragment descriptors), the
    // chip observes a fully-populated chain when it picks up the head.
    let first_slot = head % RING_LEN;
    let mut first_opts1 = regs::DESC_OWN | regs::DESC_TX_FS | (linear_len & regs::DESC_LEN_MASK);
    if n_desc == 1 {
        first_opts1 |= regs::DESC_TX_LS;
    }
    if first_slot == RING_LEN - 1 {
        first_opts1 |= regs::DESC_EOR;
    }
    first_opts1 |= tso_opts1;

    state.tx.shadow_dma[first_slot].store(linear_handle, Ordering::Release);
    state.tx.shadow_len[first_slot].store(linear_len, Ordering::Release);
    state.tx.shadow_is_frag[first_slot].store(false, Ordering::Release);
    if n_desc == 1 && budget_len != 0 {
        state.tx.shadow_budget_len[first_slot].store(budget_len, Ordering::Release);
    }
    if n_desc == 1 {
        // Single-fragment skb — LastFrag is also the FirstFrag. The
        // raw pointer consumed above is the value the shadow's disposition
        // obligation now references.
        state.tx.shadow[first_slot].store(skb_raw, Ordering::Release);
    } else {
        // The LastFrag slot already received the raw pointer inside
        // `map_skb_fragments`; FirstFrag must be NULL so the reaper
        // consumes the skb exactly once.
        let _ = skb_raw;
        state.tx.shadow[first_slot].store(core::ptr::null_mut(), Ordering::Release);
    }
    // Publish OWN|FS only after addr/opts2 and earlier fragment
    // descriptors are visible to the device.
    ub::desc_publish_own(
        state.tx.desc.cast::<u8>(),
        first_slot,
        Descriptor {
            opts1: first_opts1,
            opts2: first_opts2,
            addr: linear_handle,
        },
        crate::ring::RxDescFormat::Legacy,
    );

    let ndev = state.ndev.load(Ordering::Acquire);
    let xmit_more = ub::netdev_xmit_more();

    // BQL sent accounting (gated by bql_mode — safe default skips MSI delivery
    // until the netdev_sent_queue/MSI interaction is revalidated with the
    // legacy ISR surface; see `bql_active` + docs/perf/bql_20260605/). Over
    // INTx this recaptures r8169 loaded-latency parity. The reaper can't
    // complete this packet until tx_head advances below, so this still precedes
    // its completed_queue (no completed-before-sent); the open-time seed keeps
    // dql_avail >= 0 on the first xmit.
    //
    // When BQL is active, use the kernel's r8169-style helper so
    // `xmit_more` batching and STACK_XOFF state produce one doorbell decision.
    // Without BQL, the doorbell rule is simply "ring at the end of the qdisc
    // batch".
    let should_doorbell_for_batch = if bql_enabled {
        ub::netdev_sent_queue(ndev, wire_len, xmit_more)
    } else {
        !xmit_more
    };

    // Driver-owned byte-budget accounting (the MSI-safe latency throttle —
    // test 5). Only packet sizes that can hit the byte budget before descriptor
    // hysteresis are counted. Tiny packets are already bounded by ring
    // occupancy, so skipping their inflight atomic removes a measurable
    // small-frame TX cost without weakening the latency throttle for bulk
    // frames.
    let inflight_after_bytes = if budgeted_wire_len != 0 {
        state
            .tx
            .inflight_bytes
            .inner
            .fetch_add(budgeted_wire_len, Ordering::AcqRel)
            + budgeted_wire_len
    } else {
        0
    };

    // Update tx_head BEFORE touching the queue-state helper — the NAPI
    // reaper reads tx_head (via `in_flight`) to decide when to wake the
    // queue back up, so the stop+head ordering must be Release-Acquire
    // sync'd. Then check whether to preemptively stop the queue: stop if
    // EITHER free slots after THIS xmit are under TX_STOP_THRS (the next
    // xmit would likely BUSY) OR in-flight bytes have reached the byte
    // budget (bound TX ring residency so fq_codel keeps latency low).
    let new_head = head.wrapping_add(n_desc);
    state.tx.head.inner.store(new_head, Ordering::Release);
    let in_flight_after = new_head.wrapping_sub(tail);
    let free_after = RING_LEN - in_flight_after;
    let over_byte_budget = budgeted_wire_len != 0 && inflight_after_bytes >= byte_budget;
    let stop_for_ring_or_budget = free_after < TX_STOP_THRS || over_byte_budget;
    if stop_for_ring_or_budget {
        // Matches the r8169 `netif_subqueue_maybe_stop` SMP-race
        // discipline: stop, then recheck (via `tx_should_wake`, which folds
        // in the byte-budget low-water) and wake immediately if the reaper
        // already drained enough descriptors AND bytes.
        stop_tx_queue_with_recheck(state, new_head);
    }

    // `xmit_more` doorbell batching (r8169 `rtl8169_start_xmit` pattern). When
    // the qdisc has more packets queued for this burst, defer the TX doorbell
    // so one MMIO write amortizes the whole batch — this cuts doorbells/packet
    // under small-frame TX load and recovers the PPS gap vs the C driver. The
    // non-BQL path uses the raw batching hint directly, and the BQL path uses
    // `__netdev_sent_queue()` so accounting and the doorbell decision stay
    // coupled like r8169.
    //
    // We MUST still ring when we just stopped/throttled the queue: in that case
    // there is no guaranteed follow-on xmit to ring the bell, so the
    // descriptors we just posted would sit unsignaled behind a stopped queue.
    if should_doorbell_for_batch || stop_for_ring_or_budget {
        state.regs().tx_poll();
        if debug_counters {
            TX_DOORBELLS.fetch_add(1, Ordering::Relaxed);
        }
    }

    NETDEV_TX_OK
}

// ── XDP_TX producer ────────────────────────────────────────────────────────

/// Enqueue one XDP_TX frame on the TX ring. Called from the C XDP verdict path
/// (`netdev_bridge_xdp.c`) when a program returns `XDP_TX`, **while it holds the
/// txq lock** — that lock is the only thing serialising this NAPI-context
/// producer against the process-context `ndo_start_xmit`, since both advance
/// `tx.head` and write head-region descriptors. The reaper (tail) stays lockless
/// against both via the OWN bit.
///
/// `frame_dma` / `frame_len` describe the `DMA_TO_DEVICE` mapping the C side made
/// over the frame's data; `frame` is the `xdp_frame*` the reaper returns with
/// `xdp_return_frame` at completion. Returns 0 on enqueue, or `-ENOSPC` when the
/// ring is full (the caller then unmaps and returns the frame — the packet is
/// dropped). No doorbell is rung here; `xdp_tx_flush` does that once per poll.
fn xdp_tx_enqueue(
    state: &NetdevState,
    frame_dma: u64,
    frame_len: u32,
    frame: *mut c_void,
) -> c_int {
    let head = state.tx.head.inner.load(Ordering::Relaxed);
    let tail = state.tx.tail.inner.load(Ordering::Acquire);
    // One descriptor, keeping a slot of headroom — same `>=` discipline as the
    // skb path's `try_reserve_ring_space`, but without its `tx_busy_exception`
    // counter: an XDP_TX drop is not part of the skb disposition invariant.
    if head.wrapping_sub(tail) + 1 >= RING_LEN {
        return -(bindings::ENOSPC as c_int);
    }
    let slot = head % RING_LEN;
    let mut opts1 =
        regs::DESC_OWN | regs::DESC_TX_FS | regs::DESC_TX_LS | (frame_len & regs::DESC_LEN_MASK);
    if slot == RING_LEN - 1 {
        opts1 |= regs::DESC_EOR;
    }
    // Shadow first (Release), then publish OWN — mirrors `ndo_start_xmit` so the
    // reaper sees a fully-populated slot once hardware clears OWN.
    state.tx.shadow_dma[slot].store(frame_dma, Ordering::Release);
    state.tx.shadow_len[slot].store(frame_len, Ordering::Release);
    state.tx.shadow_is_frag[slot].store(false, Ordering::Release);
    state.tx.shadow_budget_len[slot].store(0, Ordering::Release);
    state.tx.shadow_kind[slot].store(TxSlotKind::Xdp as u8, Ordering::Release);
    state.tx.shadow[slot].store(frame.cast(), Ordering::Release);
    ub::desc_publish_own(
        state.tx.desc.cast::<u8>(),
        slot,
        Descriptor {
            opts1,
            opts2: 0,
            addr: frame_dma,
        },
        crate::ring::RxDescFormat::Legacy,
    );
    state
        .tx
        .head
        .inner
        .store(head.wrapping_add(1), Ordering::Release);
    0
}

extern "C" fn rust_xdp_xmit_one(
    cookie: *mut c_void,
    frame_dma: u64,
    frame_len: u32,
    frame: *mut c_void,
) -> c_int {
    let state = state_from(cookie);
    xdp_tx_enqueue(state, frame_dma, frame_len, frame)
}

/// Ring the TX doorbell once at NAPI-poll end if any XDP_TX frame was enqueued
/// this poll. Called from `r8125_bridge_xdp_finalize`; the per-queue pending
/// flag (C side) gates it so a poll with no XDP_TX does no MMIO.
extern "C" fn rust_xdp_tx_flush(cookie: *mut c_void) {
    let state = state_from(cookie);
    state.regs().tx_poll();
}

// ── Raw IRQ handler ───────────────────────────────────────────────────────

/// Map a firing Linux IRQ to its V2 (source-bit, target-queue):
///   `rx_nums[i]` → (ROK bit `1<<i`, queue `i`)
///   `tx_num`     → (TOK_Q0 bit, queue 0)  — TX completions are reaped in q0
///   `link_num`   → (LINKCHG bit, queue 0)
/// Inactive RX vectors are fetched but never `request_irq`'d, so they never
/// fire; matching by IRQ number is unambiguous. `None` ⇒ not one of ours.
#[inline]
fn v2_vector_source(state: &NetdevState, irq: u32) -> Option<(u32, u32)> {
    for i in 0..RX_QUEUE_COUNT {
        if state.irq.rx_nums[i] == irq {
            let bit = crate::layout::v2_rx_queue_bit(i as u32, regs::ISRIMR_V2_ROK_Q0);
            return Some((bit, i as u32));
        }
    }
    if irq == state.irq.tx_num {
        return Some((regs::ISRIMR_V2_TOK_Q0, RX_QUEUE0));
    }
    if irq == state.irq.link_num {
        return Some((regs::ISRIMR_V2_LINKCHG, RX_QUEUE0));
    }
    None
}

extern "C" fn raw_irq_handler(_irq: c_int, dev_id: *mut c_void) -> bindings::irqreturn_t {
    let state = state_from(dev_id);
    let regs = state.regs();
    let use_v2 = state.irq_mode() == IrqMode::Msi && state.use_v2_irq_surface();
    if use_v2 {
        // Per-vector V2 (ISR_V2 0x0D04 / IMR_V2 0x0D00,0x0D0C): each MSI-X
        // vector signals exactly ONE source bit (`BIT(message_id)`), so ack and
        // mask ONLY that bit and schedule ONLY its queue's NAPI. Touching the
        // whole surface here would steal other queues' pending interrupts. The
        // queue's `rearm_irq_baseline(queue_id)` re-arms its own bit(s) after
        // `napi_complete_done`, closing the loop.
        let Some((bit, queue)) = v2_vector_source(state, _irq as u32) else {
            return bindings::irqreturn_IRQ_NONE as bindings::irqreturn_t;
        };
        if regs.isr_v2() == 0xFFFF_FFFF {
            // Device gone (surprise-removal): all-ones read.
            return bindings::irqreturn_IRQ_NONE as bindings::irqreturn_t;
        }
        note_irq_fire(state);
        regs.ack_isr_v2(bit);
        regs.clear_imr_v2_mask(bit);
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::bridge_napi_schedule(ndev, queue);
        return bindings::irqreturn_IRQ_HANDLED as bindings::irqreturn_t;
    }
    // Legacy combined ISR (0x3C) + IMR (0x38), W1C ack — INTx (shared line) or
    // single-vector MSI. Mask-all + schedule queue 0.
    let status = regs.isr();
    if status == 0 || status == 0xFFFF_FFFF {
        return bindings::irqreturn_IRQ_NONE as bindings::irqreturn_t;
    }
    note_irq_fire(state);
    regs.ack_isr(status);
    regs.set_imr(0);
    let ndev = state.ndev.load(Ordering::Acquire);
    ub::bridge_napi_schedule(ndev, RX_QUEUE0);
    bindings::irqreturn_IRQ_HANDLED as bindings::irqreturn_t
}

// ── RAII handle for the registered net_device + boxed NetdevState ────────

/// Owns the registered `net_device` + the `Box<NetdevState>` cookie.
///
/// ## Two-step teardown
///
/// The kernel-Rust PCI adapter calls `T::unbind(dev, this)` and then
/// runs `devres_release_all(dev)` BEFORE dropping `T::DriverData`. That
/// means by the time `R8125Driver::drop` runs, our `_bar` field's
/// underlying ioremap mapping has ALREADY been torn down. Any chip-side
/// MMIO from `bridge_unregister_and_free` (ndo_stop → phy_stop →
/// genphy_suspend → MDIO read → `gphy_ocp_read` → MMIO 32-bit write
/// on the BAR pointer) hits a stale virtual address and triggers
/// `BUG: unable to handle page fault` on `rmmod` under traffic.
/// Recovered from EFI pstore on Gateway 2026-05-28
/// (CR2 = `bar_base + 0xB8`, addr was `ffffcf02421d00b8`).
///
/// Fix: `R8125Driver::unbind` calls [`Self::shutdown`] which runs the
/// whole netdev unregister synchronously, BEFORE devres releases the
/// BAR. `shutdown` is idempotent — both the explicit `unbind` call and
/// the trailing `Drop` route through it via the atomic "drained"
/// sentinel. After `shutdown` the `ndev` slot is null and the `Drop`
/// implementation skips re-entry, only reclaiming the cookie KBox.
pub(crate) struct NetdevHandle {
    /// Set to null after `shutdown` (or after Drop) drains it; the
    /// atomic-swap is the linearisation point that lets both teardown
    /// paths run exactly once.
    ndev: AtomicPtr<bindings::net_device>,
    /// Same idempotency dance for the boxed NetdevState pointer. Drained
    /// at the very end of teardown — after `bridge_unregister_and_free`
    /// returns the cshim no longer has any reference to it.
    cookie: AtomicPtr<NetdevState>,
}

impl NetdevHandle {
    /// The registered `net_device` pointer (null after teardown). Used by the
    /// pci::Driver suspend/resume callbacks to drive the cshim PM path. Gated on
    /// `r8125_pci_pm` (its only caller) so a stock build raises no dead-code warn.
    #[cfg(r8125_pci_pm)]
    pub(crate) fn ndev(&self) -> *mut bindings::net_device {
        self.ndev.load(Ordering::Acquire)
    }

    /// Allocate + register a net_device for `pdev`, with the full
    /// vtable and a `Box<NetdevState>` as the cookie.
    pub(crate) fn new_with_state(
        pdev: &pci::Device<kernel::device::Core>,
        state: KBox<NetdevState>,
        mac: &[u8; 6],
    ) -> Result<Self> {
        let cookie = ub::kbox_into_raw(state);
        let ndev = match ub::bridge_alloc(pdev, cookie.cast::<c_void>(), &ACTIVE_OPS, mac) {
            Ok(p) => p,
            Err(e) => {
                ub::kbox_drop_from_raw(cookie);
                return Err(e);
            }
        };
        ub::state_set_ndev(cookie, ndev);

        if let Err(e) = ub::bridge_register(ndev) {
            ub::bridge_free(ndev);
            ub::kbox_drop_from_raw(cookie);
            return Err(e);
        }

        // Register MDIO bus + phy_device so ndo_open can call
        // bridge_phy_start. Failure here means the discovered PHY has no
        // driver (realtek.ko missing) or MDIO bus allocation failed —
        // either way we can't bring traffic up, so unwind the netdev.
        let mdio_ops = ub::BridgeMdioOps {
            read: ub::r8125_rust_mdio_read,
            write: ub::r8125_rust_mdio_write,
            read_c45: ub::r8125_rust_mdio_read_c45,
            write_c45: ub::r8125_rust_mdio_write_c45,
        };
        if let Err(e) = ub::bridge_phy_register(ndev, &mdio_ops) {
            dev_err!(pdev, "r8125_rust: bridge_phy_register failed: {:?}\n", e);
            ub::bridge_unregister_and_free(ndev);
            ub::kbox_drop_from_raw(cookie);
            return Err(e);
        }
        dev_info!(
            pdev,
            "r8125_rust netdev registered: MAC {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}\n",
            mac[0],
            mac[1],
            mac[2],
            mac[3],
            mac[4],
            mac[5]
        );
        Ok(Self {
            ndev: AtomicPtr::new(ndev),
            cookie: AtomicPtr::new(cookie),
        })
    }

    /// Synchronously unregister the netdev (kernel runs ndo_stop +
    /// phy_stop + free_irq + napi_disable inside this call) and tear
    /// down the MDIO bus. Idempotent against a concurrent `Drop` thanks
    /// to the `AtomicPtr::swap` linearisation: whichever path drains
    /// `ndev` first does the work; the other observes null and skips.
    ///
    /// Called from `R8125Driver::unbind` so the chip-side MMIO during
    /// teardown lands on the still-mapped BAR. Safe to call at any
    /// time after `new_with_state`; if already drained it's a no-op.
    pub(crate) fn shutdown(&self) {
        let ndev = self.ndev.swap(core::ptr::null_mut(), Ordering::AcqRel);
        if !ndev.is_null() {
            ub::bridge_unregister_and_free(ndev);
        }
    }
}

impl Drop for NetdevHandle {
    fn drop(&mut self) {
        // Normally `shutdown` was already called from `R8125Driver::unbind`
        // and this is a no-op for `ndev`. Keep the call so probe-error
        // paths (where `unbind` isn't invoked because probe never
        // succeeded) still teardown correctly.
        self.shutdown();
        let cookie = self.cookie.swap(core::ptr::null_mut(), Ordering::AcqRel);
        if !cookie.is_null() {
            ub::kbox_drop_from_raw(cookie);
        }
    }
}
