// SPDX-License-Identifier: GPL-2.0
//! Rust ↔ C bridge surface — plan §7 M4-full.
//!
//! ## Scope at M4-full
//!
//! `NetdevState` holds everything the ndo callbacks need: a raw pointer
//! into the mapped BAR (so `ndo_open`/`xmit`/`poll`/IRQ can issue MMIO
//! from any context), DMA + CPU pointers for the TX/RX descriptor rings,
//! the coherent RX buffer pool, the per-TX-slot software shadow holding
//! posted skb pointers, and atomic head/tail indices shared between
//! `xmit` (BH context), NAPI poll (softirq), and the IRQ handler.
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
// AtomicU32 also serves the new NetdevState::ocp_base field below.
// AtomicU64/U32 shadow the per-descriptor DMA mapping (handle/len) for SG.
// AtomicU8 carries the (probe-time-determined) IRQ delivery mode for the
// IRQ handler + NAPI re-arm branch (M6 #1 Phase A.2).

/// Cache-line padded wrapper. Per `docs/RUST_STANDARDS.md` §15.2, atomics
/// mutated from independent contexts (here: `tx_head` from xmit, `tx_tail`
/// + `rx_tail` from NAPI poll) must not share a cache line — false sharing
///
/// would serialise the contexts under load. 64 B is the L1 line on x86_64
/// and aarch64 baseline; PowerPC uses 128 but isn't a deployment target.
/// Kernel-Rust has no `crossbeam::utils::CachePadded`, so this is the
/// minimal hand-rolled equivalent.
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
use kernel::error::Result;
use kernel::pci;
use kernel::prelude::*;
use kernel::sync::aref::ARef;

/// Counters for low-rate debug visibility into hot path. Removed (or made
/// dev_dbg!) once the path is proven.
static XMIT_CALLS: AtomicU32 = AtomicU32::new(0);
static IRQ_FIRES: AtomicU32 = AtomicU32::new(0);
static NAPI_POLLS: AtomicU32 = AtomicU32::new(0);

pub(crate) fn debug_counts() -> (u32, u32, u32) {
    (
        XMIT_CALLS.load(Ordering::Relaxed),
        IRQ_FIRES.load(Ordering::Relaxed),
        NAPI_POLLS.load(Ordering::Relaxed),
    )
}

pub(crate) fn note_irq_fire() {
    IRQ_FIRES.fetch_add(1, Ordering::Relaxed);
}

pub(crate) fn note_napi_poll() {
    NAPI_POLLS.fetch_add(1, Ordering::Relaxed);
}

use crate::mmio::{self, Regs};
use crate::regs;
use crate::ring::{Descriptor, RING_LEN};
use crate::unsafe_boundary::{self as ub, BridgeOps};

/// `NETDEV_TX_OK` / `NETDEV_TX_BUSY` from `include/linux/netdevice.h`.
const NETDEV_TX_OK: c_int = 0;
const NETDEV_TX_BUSY: c_int = 0x10;

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

/// Stop the TX queue, then recheck the producer/consumer indices to cover
/// the race where NAPI freed descriptors just before or during the stop.
/// If the queue has already crossed the wake threshold, wake it immediately
/// so we do not strand the queue stopped with no future completion to wake it.
fn stop_tx_queue_with_recheck(state: &NetdevState, head: usize) {
    let ndev = state.ndev.load(Ordering::Acquire);
    ub::bridge_tx_stop_queue(ndev);

    let tail_now = state.tx_tail.inner.load(Ordering::Acquire);
    let in_flight_now = head.wrapping_sub(tail_now);
    if RING_LEN - in_flight_now > crate::napi::TX_START_THRS {
        ub::bridge_tx_wake_queue(ndev);
    }
}

/// RX buffer size — one chip-side jumbo-capable RX slot. Sized at the
/// chip's `R8169_RX_BUF_SIZE` equivalent (`JUMBO_16K_BYTES = 16384`)
/// regardless of advertised MTU, so the chip's `RxMaxSize` threshold
/// can sit at `RX_MAX_SIZE_JUMBO` and every slot has room for the
/// largest frame the chip will ever DMA. Lower-MTU traffic just leaves
/// the tail of the buffer untouched.
///
/// Each slot is one `order-2` page chunk (16 KiB on x86) from
/// `r8125_bridge_rx_alloc_jumbo` (`src/netdev_bridge_rx_pool.c`),
/// streaming-DMA-mapped. Compile-time sanity matches the cshim's
/// `R8125_RX_JUMBO_BUF_SIZE`.
pub(crate) const RX_BUF_LEN: usize = crate::regs::JUMBO_16K_BYTES;

/// Per-slot streaming-DMA RX buffer view. One pair per ring descriptor:
/// the chip's RX completion deposits bytes via DMA into `dma`; the NAPI
/// poll reads them through `cpu`. Stored as a pair of per-slot atomics
/// (`rx_slot_cpu` + `rx_slot_dma` on `NetdevState`) so probe → ndo_open
/// allocation, the NAPI hot path, and ndo_stop free can all access the
/// pool through `&NetdevState` without unsafe interior mutability.
///
/// `cpu` is the kernel-virtual `page_address(...)` from
/// `r8125_bridge_rx_alloc_jumbo` — guaranteed-lowmem on x86_64 because
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
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
#[repr(u8)]
pub(crate) enum IrqMode {
    /// Legacy INTx pin assertion. Requires `IRQF_SHARED` on registration,
    /// drives the original `IMR`/`ISR` register window at 0x38/0x3C.
    Intx = 0,
    /// Message-Signaled (MSI or MSI-X). Registers without `IRQF_SHARED`,
    /// drives the `IMR_V2`/`ISR_V2` window at 0x0D0C/0x0D04 with
    /// `INT_CFG0_ENABLE_8125` set in the chip.
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

/// Per-bound-device state — accessed from probe, ndo callbacks, NAPI
/// poll, and the IRQ handler. All cross-context fields are atomic; the
/// non-atomic fields are read-only after probe.
pub(crate) struct NetdevState {
    /// Reference-counted device handle. Holds the device live for the
    /// full lifetime of this NetdevState (which is the bound period).
    #[allow(dead_code)] // held for refcount; future M5 work may consume it
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

    /// IRQ number from `pci_irq_vector(pdev, 0)` after `pci_alloc_irq_vectors`
    /// (M6 #1 Phase A.2). For MSI/MSI-X this is the kernel-assigned vector
    /// number; for legacy INTx fallback it equals `pdev->irq`.
    pub(crate) irq_num: u32,

    /// Encoded [`IrqMode`] chosen at probe — see the enum doc. Read by
    /// `raw_irq_handler` (selects ISR window + ack/mask sequence) and by
    /// `napi::rearm_irq_baseline` (selects V2 vs legacy IMR write).
    // NOT-PADDED: set-once at probe, then read-only from every other
    // context — no concurrent writer means no false-sharing pressure.
    pub(crate) irq_mode: AtomicU8,

    /// DMA + CPU pointers for the TX descriptor ring (N + 1 slots; slot N
    /// is the tail canary from M3).
    pub(crate) tx_desc: *mut Descriptor,
    pub(crate) tx_dma: u64,

    /// Same for the RX descriptor ring.
    pub(crate) rx_desc: *mut Descriptor,
    pub(crate) rx_dma: u64,

    /// Per-slot streaming-DMA RX buffers (M6 #2 jumbo refactor). Each
    /// slot holds one `order-2` page chunk (16 KiB on x86) mapped
    /// `FROM_DEVICE` for the lifetime of the open: `ndo_open` populates
    /// every slot via `ub::rx_alloc_jumbo`, `ndo_stop` frees the lot
    /// via `ub::rx_free_jumbo`. The `cpu`/`dma` pair is stored as two
    /// per-slot atomics — both fields are written together (by
    /// `set_rx_slot`) and read together (by `rx_slot`); see [`RxSlot`].
    /// `(null, 0)` is the empty sentinel.
    ///
    /// We don't cache-pad these because the access pattern is "NAPI
    /// reads one slot per RX frame, then writes the same slot's
    /// descriptor LEN field" — same context, same cache line; no
    /// cross-context false sharing is possible.
    pub(crate) rx_slot_cpu: [AtomicPtr<core::ffi::c_void>; RING_LEN],
    pub(crate) rx_slot_dma: [AtomicU64; RING_LEN],

    /// One AtomicPtr per TX slot. For SG (multi-fragment) skbs only the
    /// LastFrag descriptor's slot holds the skb pointer; intermediate
    /// fragment slots store null. `xmit` stores; NAPI poll reaper consumes
    /// via `bridge_skb_consume_tx` only when the slot's pointer is non-null.
    pub(crate) tx_shadow: [AtomicPtr<bindings::sk_buff>; RING_LEN],

    /// Per-descriptor DMA mapping shadow — the chip clears the descriptor's
    /// LEN field on TX completion (per r8169 vendor errata, also seen on
    /// 8125B), and `napi_consume_skb` invalidates the skb pointer, so we
    /// can't recover (handle, len) from either source at unmap time. SG
    /// makes this worse because each fragment is mapped separately and
    /// must be unmapped separately.
    pub(crate) tx_shadow_dma: [AtomicU64; RING_LEN],
    pub(crate) tx_shadow_len: [AtomicU32; RING_LEN],
    pub(crate) tx_shadow_is_frag: [AtomicBool; RING_LEN],

    /// Producer index (advanced by `ndo_start_xmit`). Cache-padded per
    /// RUST_STANDARDS.md §15.2 — written by xmit, read by NAPI poll.
    pub(crate) tx_head: CachePadded<AtomicUsize>,
    /// Consumer index (advanced by the NAPI TX reaper). Cache-padded; read
    /// by xmit's ring-full check.
    pub(crate) tx_tail: CachePadded<AtomicUsize>,
    /// RX consumer index (advanced by the NAPI RX path). Cache-padded so
    /// the RX hot loop's index doesn't ping-pong with TX indices.
    pub(crate) rx_tail: CachePadded<AtomicUsize>,

    /// Current PHY OCP page base (default `OCP_STD_PHY_BASE = 0xA400`).
    /// MDIO writes to MII reg 0x1F switch pages; subsequent MII reads/writes
    /// use this base. Single-context (process), but atomic for the &self
    /// access pattern.
    // NOT-PADDED: PHY-config slow path; mutated only from process
    // context (MDIO bus callbacks), no hot-path contention.
    pub(crate) ocp_base: AtomicU32,
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
        IrqMode::from_u8(self.irq_mode.load(Ordering::Relaxed))
    }

    /// Snapshot RX slot `i`'s (cpu, dma) pair. Both atomics are read
    /// with `Acquire` so a fresh `set_rx_slot` on the same slot from
    /// the `ndo_open`/`ndo_stop` context is observed atomically by the
    /// NAPI poll context.
    #[inline]
    pub(crate) fn rx_slot(&self, i: usize) -> RxSlot {
        RxSlot {
            cpu: self.rx_slot_cpu[i].load(Ordering::Acquire),
            dma: self.rx_slot_dma[i].load(Ordering::Acquire),
        }
    }

    /// Publish a slot's (cpu, dma) pair. Paired with `rx_slot` —
    /// stores are `Release`, so the NAPI side's `Acquire` sees the
    /// pair as a unit. The empty sentinel (`RxSlot::EMPTY`) signals
    /// "freed" to the rmmod / failure-rollback paths.
    #[inline]
    pub(crate) fn set_rx_slot(&self, i: usize, slot: RxSlot) {
        self.rx_slot_cpu[i].store(slot.cpu, Ordering::Release);
        self.rx_slot_dma[i].store(slot.dma, Ordering::Release);
    }

    /// Reset all atomic indices and clear any stale TX shadow pointers.
    /// Called at `ndo_open` so a fresh open after a previous close starts
    /// with a clean slate.
    pub(crate) fn reset_indices(&self) {
        self.tx_head.inner.store(0, Ordering::Relaxed);
        self.tx_tail.inner.store(0, Ordering::Relaxed);
        self.rx_tail.inner.store(0, Ordering::Relaxed);
        for slot in self.tx_shadow.iter() {
            slot.store(ptr::null_mut(), Ordering::Relaxed);
        }
    }
}

// ── Rust ndo callbacks ────────────────────────────────────────────────────

#[inline]
fn state_from<'a>(cookie: *mut c_void) -> &'a NetdevState {
    ub::state_from_cookie(cookie)
}

extern "C" fn rust_open(cookie: *mut c_void) -> c_int {
    let state = state_from(cookie);
    match ndo_open(state) {
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
    ndo_start_xmit(state, skb)
}

extern "C" fn rust_poll(cookie: *mut c_void, budget: c_int) -> c_int {
    let state = state_from(cookie);
    crate::napi::poll(state, budget)
}

extern "C" fn rust_change_mtu(_cookie: *mut c_void, _new_mtu: c_int) -> c_int {
    // Range-check is done by the kernel against ndev->{min,max}_mtu (cshim
    // populates those at alloc). The M6 #2 jumbo refactor sizes every
    // RX slot at `JUMBO_16K_BYTES` so any MTU in `[min_mtu, max_mtu]`
    // fits without a per-MTU re-alloc.
    0
}

pub(crate) const M4_FULL_OPS: BridgeOps = BridgeOps {
    open: rust_open,
    stop: rust_stop,
    xmit: rust_xmit,
    poll: rust_poll,
    change_mtu: rust_change_mtu,
};

// Skeleton vtable retained as a load-test fallback. Flip `ACTIVE_OPS`
// to point at `M4_SKELETON_OPS` for a no-traffic insmod/rmmod
// regression with no chip interaction. Not wired by default.
#[allow(dead_code)]
extern "C" fn skel_open(_cookie: *mut c_void) -> c_int { 0 }
#[allow(dead_code)]
extern "C" fn skel_stop(_cookie: *mut c_void) {}
#[allow(dead_code)]
extern "C" fn skel_xmit(_cookie: *mut c_void, skb: *mut bindings::sk_buff) -> c_int {
    ub::skb_free_error(skb);
    NETDEV_TX_OK
}
#[allow(dead_code)]
extern "C" fn skel_poll(_cookie: *mut c_void, _budget: c_int) -> c_int { 0 }
#[allow(dead_code)]
extern "C" fn skel_change_mtu(_cookie: *mut c_void, _new_mtu: c_int) -> c_int { 0 }

#[allow(dead_code)]
pub(crate) const M4_SKELETON_OPS: BridgeOps = BridgeOps {
    open: skel_open,
    stop: skel_stop,
    xmit: skel_xmit,
    poll: skel_poll,
    change_mtu: skel_change_mtu,
};

/// Active vtable. M4-full is the production path; M4-skeleton is kept
/// available for the no-traffic load-test fallback. See the comment
/// block above for why this flip is now safe.
pub(crate) const ACTIVE_OPS: BridgeOps = M4_FULL_OPS;

/// Release all RX jumbo slots and leave the pool in the empty-sentinel
/// state. Used by `ndo_stop` and by every `ndo_open` rollback path after
/// the M6 #2 RX-pool allocation point.
fn free_rx_slots(state: &NetdevState) {
    for i in 0..RING_LEN {
        let slot = state.rx_slot(i);
        state.set_rx_slot(i, RxSlot::EMPTY);
        ub::rx_free_jumbo(&state.pdev, slot.cpu, slot.dma);
    }
}

// ── ndo_open ──────────────────────────────────────────────────────────────

fn ndo_open(state: &NetdevState) -> Result<()> {
    state.reset_indices();
    let regs = state.regs();

    // Bus-mastering on. (DMA mask was set at probe.)
    ub::pci_set_master(&state.pdev);

    // Program TX / RX ring DMA bases. The +1 tail-canary slot is invisible
    // to hardware — it never goes past index RING_LEN-1.
    regs.set_tx_ring_base(state.tx_dma);
    regs.set_rx_ring_base(state.rx_dma);
    // RxMaxSize lives in `hw_start_8125b` so all chip-side init sits
    // in one place; the register is sized for the jumbo pool (M6 #2).
    regs.set_rcr(regs::RCR_M4_BASELINE);
    regs.set_cpluscmd(regs::CPLUSCMD_RX_CHKSUM);

    // M6 #2 — allocate one jumbo-sized streaming-DMA page chunk per RX
    // slot. On any per-slot failure unwind every successful allocation
    // before returning so the next `ndo_open` retry sees a fresh state.
    // Pre-posting the descriptor only happens after the allocation
    // succeeds so the chip can't see a half-initialised slot.
    for i in 0..RING_LEN {
        match ub::rx_alloc_jumbo(&state.pdev) {
            Ok((cpu, dma)) => state.set_rx_slot(i, RxSlot { cpu, dma }),
            Err(e) => {
                free_rx_slots(state);
                return Err(e);
            }
        }
    }

    // Pre-post every RX descriptor with its slot's DMA address + OWN bit.
    // The last (hardware-visible) slot also gets the EOR marker so the
    // chip wraps RxHead back to index 0. The descriptor LEN field is
    // 14 bits (`DESC_LEN_MASK = 0x3FFF`), so the chip-encodable max is
    // 16383 — we clamp here. The cshim's page chunk is 16384 bytes;
    // the extra byte is invisible to hardware and exists only so the
    // alloc lines up with `order = 2` page boundaries.
    for i in 0..RING_LEN {
        let dma = state.rx_slot(i).dma;
        let mut opts1 = regs::DESC_OWN | (RX_BUF_LEN as u32).min(regs::DESC_LEN_MASK);
        if i == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        ub::desc_write(
            state.rx_desc,
            i,
            Descriptor {
                opts1,
                opts2: 0,
                addr: dma,
            },
        );
    }

    // TX descriptors: zero them. The first xmit will populate.
    for i in 0..RING_LEN {
        let mut opts1 = 0u32;
        if i == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        ub::desc_write(
            state.tx_desc,
            i,
            Descriptor {
                opts1,
                opts2: 0,
                addr: 0,
            },
        );
    }

    // Wire the IRQ. Vector allocation already happened at probe time via
    // `pci_alloc_irq_vectors` (devres-managed); ndo_open just registers
    // our handler against `state.irq_num`. The flags depend on the
    // probe-chosen `IrqMode`: INTx pins are shareable, MSI/MSI-X vectors
    // are not. The unsafe FFI call is wrapped in `ub::request_irq` with
    // a SAFETY block.
    let cookie_ptr = core::ptr::from_ref(state).cast_mut().cast::<c_void>();
    let irq_flags = match state.irq_mode() {
        IrqMode::Intx => ub::IRQF_SHARED,
        IrqMode::Msi => 0,
    };
    if let Err(e) = ub::request_irq(state.irq_num, raw_irq_handler, cookie_ptr, irq_flags) {
        free_rx_slots(state);
        return Err(e);
    }

    // PHY step 1 — connect + soft reset + resume. On the 8125B's
    // integrated MAC/PHY, genphy_soft_reset writes BMCR_RESET which
    // ALSO clears MAC-side state (ChipCmd). Running it BEFORE the MAC
    // OCP init + ChipCmd write is critical, or our ChipCmd RX|TX bits
    // get wiped out by the PHY reset. Matches r8169 ordering at
    // rtl8169_up (phy_init_hw → phy_resume → rtl8169_init_phy run before
    // rtl_reset_work → rtl_hw_start).
    let ndev = state.ndev.load(Ordering::Acquire);
    if let Err(e) = ub::bridge_phy_connect_and_reset(ndev) {
        ub::free_irq(
            state.irq_num,
            core::ptr::from_ref(state).cast_mut().cast::<c_void>(),
        );
        free_rx_slots(state);
        return Err(e);
    }

    // r8169 RTL8125B (MAC_VER_63) baseline: disable interrupt coalescing
    // before enabling IRQ sources. Mirrors `rtl_hw_start_8125` in
    // r8169_main.c. Zeros INT_CFG0, the 0xa00..0xa80 coalescing table,
    // and INT_CFG1. Without this the chip may delay/suppress IRQs.
    regs.set_int_cfg0(0);
    regs.zero_coalesce_table_8125b();
    regs.set_int_cfg1(0);

    // ack any sticky ISR bits BEFORE unmasking — otherwise the first
    // edge into the IO-APIC is lost.
    regs.ack_isr(0xFFFF_FFFF);

    // r8169 `rtl_hw_start_8125_common` for MAC_VER_63. The minimum init
    // sequence (MAC OCP + MISC ungate) the chip needs before ChipCmd
    // RX|TX enable, or the engines silently refuse to move packets. Sits
    // in hw::hw_start_8125b so cross-referencing with the upstream
    // source-of-truth function stays trivial.
    if let Err(e) = crate::hw::hw_start_8125b(&regs) {
        ub::bridge_phy_stop(ndev);
        ub::free_irq(
            state.irq_num,
            core::ptr::from_ref(state).cast_mut().cast::<c_void>(),
        );
        free_rx_slots(state);
        return Err(e);
    }

    // Enable RX + TX in the chip command register FIRST. Per r8169 the
    // IMR write must come last (after ChipCmd RX|TX enable).
    regs.set_chip_cmd(regs::CMD_RX_ENB | regs::CMD_TX_ENB);

    // M6 #1 Phase A.2 — chip-side activation of the per-message-id
    // ISR_V2 register layout. Only flip `INT_CFG0_ENABLE_8125` when
    // probe actually obtained an MSI/MSI-X vector; in INTx fallback the
    // chip must keep asserting the INTx pin (see hw.rs Phase A.1
    // comment + docs/M6_MSIX_DESIGN.md for the empirical reason). The
    // V2 surface must be enabled BEFORE the matching `set_imr_v2_mask`
    // write or the first unmask would target the legacy IMR while the
    // chip is already routing through V2.
    if state.irq_mode() != IrqMode::Intx {
        regs.set_int_cfg0(regs::INT_CFG0_ENABLE_8125);
    }

    // Unmask the chosen IRQ surface LAST — mirrors r8169 `rtl_irq_enable`.
    // `rearm_irq_baseline` picks legacy `IMR` or V2 `IMR_V2_SET` based on
    // `state.irq_mode()`.
    crate::napi::rearm_irq_baseline(state);

    // PHY step 2 — kick the state machine LAST. Per r8169 ordering this
    // runs after ChipCmd RX|TX enable + IMR programming. Carrier flips
    // on automatically inside `bridge_phylink_handler` when the PHY
    // reports link-up; the unconditional carrier_on we used at M4-
    // skeleton is dropped.
    if let Err(e) = ub::bridge_phy_kick_state_machine(ndev) {
        // Roll back: mask both IRQ surfaces (idempotent — V2 write is a
        // no-op when V2 isn't active), disable chip, free IRQ. Same
        // discipline as ndo_stop: dual-mask so the rollback is
        // mode-agnostic and the next open() starts from a known state.
        regs.set_imr(0);
        regs.clear_imr_v2_mask(0xFFFF_FFFF);
        regs.set_chip_cmd(0);
        ub::bridge_phy_stop(ndev);
        ub::free_irq(
            state.irq_num,
            core::ptr::from_ref(state).cast_mut().cast::<c_void>(),
        );
        free_rx_slots(state);
        return Err(e);
    }
    ub::bridge_tx_wake_queue(ndev);

    // Read back key registers so we can confirm the writes took effect.
    let chipcmd = regs.chip_cmd();
    let isr = regs.isr();
    let imr_readback = regs.imr_readback();
    let phy_status = regs.phy_status();
    pr_info!(
        "r8125_rust ndo_open complete: IRQ={} ChipCmd=0x{:02x} ISR=0x{:08x} IMR_rb=0x{:08x} PHYStatus=0x{:02x} tx_dma=0x{:016x} rx_dma=0x{:016x}\n",
        state.irq_num,
        chipcmd,
        isr,
        imr_readback,
        phy_status,
        state.tx_dma,
        state.rx_dma
    );
    Ok(())
}

// ── ndo_stop ──────────────────────────────────────────────────────────────

fn ndo_stop(state: &NetdevState) {
    let regs = state.regs();
    let ndev = state.ndev.load(Ordering::Acquire);

    let (x, i, n) = debug_counts();
    pr_info!(
        "r8125_rust ndo_stop: xmit_calls={} irq_fires={} napi_polls={}\n",
        x, i, n
    );

    // Stop kernel TX submissions + carrier first so xmit can't race the
    // teardown. PHY stop releases the link-status handler and disconnects
    // the phy_device from the netdev (next ndo_open re-attaches it).
    ub::bridge_tx_disable(ndev);
    ub::bridge_phy_stop(ndev);
    ub::bridge_carrier_off(ndev);

    // Mask IRQs, disable RX/TX, ack any pending bits.
    //
    // We mask BOTH legacy and V2 surfaces so the M6 #1 Phase A.2
    // transition (when V2 + MSI-X land together) doesn't need to
    // edit ndo_stop. Idempotent: V2 writes are no-ops when chip is
    // in legacy mode and vice versa.
    regs.set_imr(0);
    regs.clear_imr_v2_mask(0xFFFF_FFFF);
    regs.set_chip_cmd(0);
    regs.ack_isr(0xFFFF_FFFF);
    regs.ack_isr_v2(0xFFFF_FFFF);

    // Release the IRQ (kernel synchronises).
    ub::free_irq(
        state.irq_num,
        core::ptr::from_ref(state).cast_mut().cast::<c_void>(),
    );

    // Reap any in-flight TX mappings/skbs the hardware never completed.
    for i in 0..RING_LEN {
        let len = state.tx_shadow_len[i].swap(0, Ordering::AcqRel) as usize;
        if len > 0 {
            let handle = state.tx_shadow_dma[i].load(Ordering::Acquire);
            if state.tx_shadow_is_frag[i].swap(false, Ordering::AcqRel) {
                ub::skb_dma_unmap_frag_tx(&state.pdev, handle, len);
            } else {
                ub::skb_dma_unmap_tx(&state.pdev, handle, len);
            }
        }
        let skb = state.tx_shadow[i].swap(ptr::null_mut(), Ordering::AcqRel);
        if !skb.is_null() {
            ub::skb_free_error(skb);
        }
    }

    // Zero the descriptor rings so a subsequent open starts fresh.
    for i in 0..RING_LEN {
        ub::desc_write(state.tx_desc, i, Descriptor::default());
        ub::desc_write(state.rx_desc, i, Descriptor::default());
    }

    // M6 #2 — release every RX slot's page chunk + DMA mapping. The
    // chip already had its descriptors zeroed above, so it can't DMA
    // into a freed slot. `rx_free_jumbo` short-circuits on the empty
    // sentinel, which is what we leave behind for the next `ndo_open`.
    free_rx_slots(state);
}

// ── ndo_start_xmit ────────────────────────────────────────────────────────

fn ndo_start_xmit(state: &NetdevState, skb: *mut bindings::sk_buff) -> c_int {
    XMIT_CALLS.fetch_add(1, Ordering::Relaxed);

    // ── Offload bit computation (must run BEFORE DMA mapping) ──────────
    // TSO is checked first; if active, opts1 gets GTSEN bits + transport
    // offset and opts2 gets MSS. Otherwise plain CSUM bits go in opts2.
    // The TSO setup may mutate skb (skb_cow_head + tcp_v6_gso_csum_prep
    // for IPv6); the CSUM path may call skb_checksum_help for the short-
    // UDP errata. Both write through the linear data, so any subsequent
    // DMA map sees the final bytes.
    let (tso_opts1, first_opts2) = match ub::skb_tso_setup(skb) {
        Some((o1, o2)) => (o1, o2),
        None => {
            let csum_opts2 = ub::skb_tx_csum_opts(skb);
            if csum_opts2 == regs::TX_CSUM_OPTS_DROP {
                ub::skb_free_error(skb);
                return NETDEV_TX_OK;
            }
            (0u32, csum_opts2)
        }
    };

    // ── Ring space reservation for the whole logical packet ─────────────
    // n_desc = 1 head + N paged frags. We keep at least one slot empty so
    // tx_head == tx_tail can only mean "ring empty" (not "ring full").
    let nr_frags = ub::skb_nr_frags(skb) as usize;
    let n_desc = 1 + nr_frags;
    let head = state.tx_head.inner.load(Ordering::Relaxed);
    let tail = state.tx_tail.inner.load(Ordering::Acquire);
    let in_flight = head.wrapping_sub(tail);
    if in_flight + n_desc >= RING_LEN {
        // Hard stop — ring genuinely doesn't have room. This is the
        // safety net; the preemptive stop further down should make
        // this branch rare. If we hit it we report TX_BUSY so the
        // kernel re-queues the skb without dropping it.
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::tx_busy_exception(ndev);
        stop_tx_queue_with_recheck(state, head);
        return NETDEV_TX_BUSY;
    }

    // ── Map the linear head ────────────────────────────────────────────
    let mut linear_handle: bindings::dma_addr_t = 0;
    let mut linear_len: u32 = 0;
    if ub::skb_data_dma_map(
        &state.pdev,
        skb,
        &mut linear_handle,
        &mut linear_len,
    )
    .is_err()
    {
        ub::skb_free_error(skb);
        return NETDEV_TX_OK;
    }

    // ── Map each paged fragment + write its descriptor ──────────────────
    // Fragments get OWN set up-front so the chip can walk them as soon as
    // it sees OWN on slot[0] (which we write LAST below). On failure mid-
    // way, walk back through already-mapped slots to unmap, then free.
    for i in 0..nr_frags {
        let mut h: bindings::dma_addr_t = 0;
        let mut l: u32 = 0;
        if ub::skb_frag_dma_map(&state.pdev, skb, i as u32, &mut h, &mut l).is_err() {
            // Unwind: unmap linear + the (i) frags we already mapped.
            ub::skb_dma_unmap_tx(&state.pdev, linear_handle, linear_len as usize);
            for j in 0..i {
                let prev_slot = (head.wrapping_add(1 + j)) % RING_LEN;
                let pa = state.tx_shadow_dma[prev_slot].load(Ordering::Acquire);
                let pl = state.tx_shadow_len[prev_slot].load(Ordering::Acquire);
                ub::skb_dma_unmap_frag_tx(&state.pdev, pa, pl as usize);
                state.tx_shadow_len[prev_slot].store(0, Ordering::Release);
                state.tx_shadow_is_frag[prev_slot].store(false, Ordering::Release);
                state.tx_shadow[prev_slot].store(core::ptr::null_mut(), Ordering::Release);
            }
            ub::skb_free_error(skb);
            return NETDEV_TX_OK;
        }
        let slot = (head.wrapping_add(1 + i)) % RING_LEN;
        let is_last_frag = i + 1 == nr_frags;
        // Per r8169 rtl8169_tx_map AND Realtek vendor rtl8125_xmit_frags:
        // BOTH opts[0] (TSO GTSEN bits) AND opts[1] (CSUM bits / MSS) get
        // PROPAGATED to every fragment descriptor — they're not first-
        // only. The chip walks the chain and aggregates the bits. We
        // previously zeroed opts2 on frags and that produced a wrong
        // checksum on the wire (iperf3 cookie corruption).
        let mut opts1 = regs::DESC_OWN | tso_opts1 | (l & regs::DESC_LEN_MASK);
        if is_last_frag {
            opts1 |= regs::DESC_TX_LS;
        }
        if slot == RING_LEN - 1 {
            opts1 |= regs::DESC_EOR;
        }
        state.tx_shadow_dma[slot].store(h, Ordering::Release);
        state.tx_shadow_len[slot].store(l, Ordering::Release);
        state.tx_shadow_is_frag[slot].store(true, Ordering::Release);
        // skb pointer lives on the LAST descriptor only; intermediate
        // fragments stay null so the reaper only consumes the skb once.
        state.tx_shadow[slot].store(
            if is_last_frag { skb } else { core::ptr::null_mut() },
            Ordering::Release,
        );
        ub::desc_write(
            state.tx_desc,
            slot,
            Descriptor {
                opts1,
                opts2: first_opts2, // CSUM bits / MSS propagate to all frags
                addr: h,
            },
        );
    }

    // ── Write FirstFrag descriptor LAST — this is the commit point ─────
    //
    // The chip only starts walking once it sees OWN|FS on slot[0]. By
    // writing the head LAST (after all fragment descriptors), the chip
    // observes a fully-populated chain when it picks up the head.
    // Whole-struct volatile commit (`ub::desc_write`) is sufficient on
    // x86: TSO ordering + PCIe ordering ensure the descriptor commits
    // atomically from the chip's perspective. (Two-phase commit was
    // tried and ruled out — see `docs/RTL8125B_TSO_NOTES.md`.)
    let first_slot = head % RING_LEN;
    let mut first_opts1 =
        regs::DESC_OWN | regs::DESC_TX_FS | (linear_len & regs::DESC_LEN_MASK);
    if n_desc == 1 {
        first_opts1 |= regs::DESC_TX_LS;
    }
    if first_slot == RING_LEN - 1 {
        first_opts1 |= regs::DESC_EOR;
    }
    first_opts1 |= tso_opts1;

    state.tx_shadow_dma[first_slot].store(linear_handle, Ordering::Release);
    state.tx_shadow_len[first_slot].store(linear_len, Ordering::Release);
    state.tx_shadow_is_frag[first_slot].store(false, Ordering::Release);
    if n_desc == 1 {
        // Single-fragment skb — LastFrag is also the FirstFrag.
        state.tx_shadow[first_slot].store(skb, Ordering::Release);
    } else {
        state.tx_shadow[first_slot].store(core::ptr::null_mut(), Ordering::Release);
    }
    ub::desc_write(
        state.tx_desc,
        first_slot,
        Descriptor {
            opts1: first_opts1,
            opts2: first_opts2,
            addr: linear_handle,
        },
    );

    // Update tx_head BEFORE touching the queue-state helper — the NAPI
    // reaper reads tx_head (via `in_flight`) to decide when to wake the
    // queue back up, so the stop+head ordering must be Release-Acquire
    // sync'd. Then check whether to preemptively stop the queue: if
    // free slots after THIS xmit are under TX_STOP_THRS, the next xmit
    // would likely BUSY, so we stop now and let the reaper wake us.
    let new_head = head.wrapping_add(n_desc);
    state.tx_head.inner.store(new_head, Ordering::Release);
    let in_flight_after = new_head.wrapping_sub(tail);
    let free_after = RING_LEN - in_flight_after;
    if free_after < TX_STOP_THRS {
        // Matches the r8169 `netif_subqueue_maybe_stop` SMP-race
        // discipline: stop, then recheck the consumer index and wake
        // immediately if the reaper already freed enough descriptors.
        stop_tx_queue_with_recheck(state, new_head);
    }
    state.regs().tx_poll();

    NETDEV_TX_OK
}

// ── Raw IRQ handler ───────────────────────────────────────────────────────

extern "C" fn raw_irq_handler(_irq: c_int, dev_id: *mut c_void) -> bindings::irqreturn_t {
    let state = state_from(dev_id);
    let regs = state.regs();
    // M6 #1 Phase A.2 — branch on the probe-chosen delivery mode:
    //   Intx → legacy ISR (0x3C) + IMR (0x38), W1C ack
    //   Msi  → ISR_V2 (0x0D04) + IMR_V2 (0x0D00/0x0D0C), W1C ack
    // The two windows are mutually exclusive at the chip: once
    // `INT_CFG0_ENABLE_8125` is set, the legacy ISR stops latching
    // sources (and vice versa), so each branch reads exactly one.
    let status = match state.irq_mode() {
        IrqMode::Intx => regs.isr(),
        IrqMode::Msi => regs.isr_v2(),
    };
    if status == 0 || status == 0xFFFF_FFFF {
        // 0 = not ours (or stale read after free_irq); !0 = device gone.
        // For Intx we may legitimately see 0 on a shared line; for
        // MSI/MSI-X 0 should be rare but is still benign to early-out.
        return bindings::irqreturn_IRQ_NONE as bindings::irqreturn_t;
    }
    note_irq_fire();
    // Ack everything we saw, mask further IRQs, hand off to NAPI.
    // NAPI's re-arm calls `rearm_irq_baseline` which selects the same
    // window after `napi_complete_done`, closing the loop.
    match state.irq_mode() {
        IrqMode::Intx => {
            regs.ack_isr(status);
            regs.set_imr(0);
        }
        IrqMode::Msi => {
            regs.ack_isr_v2(status);
            regs.clear_imr_v2_mask(0xFFFF_FFFF);
        }
    }
    let ndev = state.ndev.load(Ordering::Acquire);
    ub::bridge_napi_schedule(ndev);
    bindings::irqreturn_IRQ_HANDLED as bindings::irqreturn_t
}

// ── RAII handle for the registered net_device + boxed NetdevState ────────

pub(crate) struct NetdevHandle {
    ndev: *mut bindings::net_device,
    cookie: *mut NetdevState,
}

impl NetdevHandle {
    /// Allocate + register a net_device for `pdev`, with the M4-full
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

        // M4-traffic: register MDIO bus + phy_device so ndo_open can call
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
            "r8125_rust netdev registered: MAC {:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x} (M4-full)\n",
            mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]
        );
        Ok(Self { ndev, cookie })
    }
}

impl Drop for NetdevHandle {
    fn drop(&mut self) {
        // unregister first (kernel synchronises ndo_stop + IRQ release +
        // NAPI disable), then drop the boxed state.
        ub::bridge_unregister_and_free(self.ndev);
        ub::kbox_drop_from_raw(self.cookie);
    }
}
