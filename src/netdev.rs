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
use core::sync::atomic::{AtomicPtr, AtomicU32, AtomicUsize, Ordering};
// AtomicU32 also serves the new NetdevState::ocp_base field below.

/// Cache-line padded wrapper. Per `docs/RUST_STANDARDS.md` §15.2, atomics
/// mutated from independent contexts (here: `tx_head` from xmit, `tx_tail`
/// + `rx_tail` from NAPI poll) must not share a cache line — false sharing
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
use kernel::dma::CoherentAllocation;
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

/// RX buffer size — single Ethernet frame at 1500 MTU plus generous slack.
/// `RxBuffer` is what we hand to hardware; descriptors carry the DMA addr
/// of one of these slots and the buffer length.
pub(crate) const RX_BUF_LEN: usize = 2048;

#[repr(C, align(64))]
#[derive(Copy, Clone)]
pub(crate) struct RxBuffer {
    pub(crate) data: [u8; RX_BUF_LEN],
}

// Compile-time check: 2048 * 256 = 512 KiB total RX-pool footprint.
const _: () = assert!(core::mem::size_of::<RxBuffer>() == RX_BUF_LEN);

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
    pub(crate) ndev: AtomicPtr<bindings::net_device>,

    /// IRQ number (`pdev->irq`). Captured at probe; passed to
    /// `request_irq`/`free_irq`.
    pub(crate) irq_num: u32,

    /// DMA + CPU pointers for the TX descriptor ring (N + 1 slots; slot N
    /// is the tail canary from M3).
    pub(crate) tx_desc: *mut Descriptor,
    pub(crate) tx_dma: u64,

    /// Same for the RX descriptor ring.
    pub(crate) rx_desc: *mut Descriptor,
    pub(crate) rx_dma: u64,

    /// Coherent RX buffer pool. Slot `i`'s buffer is at
    /// `rx_bufs.dma_handle() + i * RX_BUF_LEN`. CPU access through
    /// `unsafe_boundary::rx_buf_slice(...)`.
    pub(crate) rx_bufs: CoherentAllocation<RxBuffer>,

    /// One AtomicPtr per TX slot — non-null while the slot owns the skb.
    /// `xmit` stores; NAPI poll reaper consumes via `bridge_skb_complete_tx`.
    pub(crate) tx_shadow: [AtomicPtr<bindings::sk_buff>; RING_LEN],

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
    // populates those at alloc). At M4-baseline max_mtu is ETH_DATA_LEN:
    // RX_BUF_LEN=2048 covers 1500-MTU directly; M5 jumbo support will
    // require enlarging the pool or going page-fragment.
    0
}

pub(crate) const M4_FULL_OPS: BridgeOps = BridgeOps {
    open: rust_open,
    stop: rust_stop,
    xmit: rust_xmit,
    poll: rust_poll,
    change_mtu: rust_change_mtu,
};

// M4-full hot-path. The 2026-05-25 KASAN UAF in `rust_stop` was a
// drop-order bug in `pci.rs::R8125Driver` (struct fields drop in
// declaration order, NOT reverse — the doc comment there said the
// wrong thing). With `_netdev` now first in the declaration, it drops
// first: `bridge_unregister_and_free` → kernel `ndo_stop` → Rust
// `rust_stop` reads `bar_ptr` / `tx_desc` / `rx_desc` while `_bar` /
// `tx_ring` / `rx_ring` are still mapped. After Drop returns, the
// remaining fields free their resources in declaration order.
//
// Cache-padding (RUST_STANDARDS.md §15.2) was applied to tx_head /
// tx_tail / rx_tail in the same pass — they're now `CachePadded
// <AtomicUsize>` so xmit (mutating tx_head) and NAPI poll (mutating
// tx_tail + rx_tail) don't false-share a single 64-byte line.
//
// Stub vtable retained as a load-test fallback if M4-full ever needs
// to be sidelined again. Flip `ACTIVE_OPS` to point at it for the
// no-traffic insmod/rmmod regression.
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
    regs.set_rx_max_size(regs::RX_MAX_SIZE_DEFAULT);
    regs.set_rcr(regs::RCR_M4_BASELINE);
    regs.set_cpluscmd(regs::CPLUSCMD_RX_CHKSUM);

    // Pre-post every RX descriptor with its slot's DMA address + OWN bit.
    // The last (hardware-visible) slot also gets the EOR marker so the
    // chip wraps RxHead back to index 0.
    for i in 0..RING_LEN {
        let dma = state.rx_bufs.dma_handle()
            + (i as u64) * (RX_BUF_LEN as u64);
        let mut opts1 = regs::DESC_OWN | (RX_BUF_LEN as u32 & regs::DESC_LEN_MASK);
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

    // Wire the IRQ (legacy INTx, shared). Uses raw bindings::request_threaded_irq
    // because the new kernel-Rust pci::Device::request_irq returns a pin-init
    // type that's awkward to store in a non-pin NetdevState. The unsafe call
    // is wrapped in `ub::request_irq` with a SAFETY block.
    let cookie_ptr = state as *const NetdevState as *mut c_void;
    ub::request_irq(state.irq_num, raw_irq_handler, cookie_ptr)?;

    // PHY step 1 — connect + soft reset + resume. On the 8125B's
    // integrated MAC/PHY, genphy_soft_reset writes BMCR_RESET which
    // ALSO clears MAC-side state (ChipCmd). Running it BEFORE the MAC
    // OCP init + ChipCmd write is critical, or our ChipCmd RX|TX bits
    // get wiped out by the PHY reset. Matches r8169 ordering at
    // rtl8169_up (phy_init_hw → phy_resume → rtl8169_init_phy run before
    // rtl_reset_work → rtl_hw_start).
    let ndev = state.ndev.load(Ordering::Acquire);
    if let Err(e) = ub::bridge_phy_connect_and_reset(ndev) {
        ub::free_irq(state.irq_num, state as *const NetdevState as *mut c_void);
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
    crate::hw::hw_start_8125b(&regs)?;

    // Enable RX + TX in the chip command register FIRST. Per r8169 the
    // IMR write must come last (after ChipCmd RX|TX enable).
    regs.set_chip_cmd(regs::CMD_RX_ENB | regs::CMD_TX_ENB);

    // Unmask IRQ sources LAST — mirrors r8169 `rtl_irq_enable`.
    regs.set_imr(regs::INTR_M4_BASELINE);

    // PHY step 2 — kick the state machine LAST. Per r8169 ordering this
    // runs after ChipCmd RX|TX enable + IMR programming. Carrier flips
    // on automatically inside `bridge_phylink_handler` when the PHY
    // reports link-up; the unconditional carrier_on we used at M4-
    // skeleton is dropped.
    if let Err(e) = ub::bridge_phy_kick_state_machine(ndev) {
        // Roll back: disable chip + free IRQ so a follow-up open can retry.
        regs.set_imr(0);
        regs.set_chip_cmd(0);
        ub::bridge_phy_stop(ndev);
        ub::free_irq(state.irq_num, state as *const NetdevState as *mut c_void);
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
    regs.set_imr(0);
    regs.set_chip_cmd(0);
    regs.ack_isr(0xFFFF_FFFF);

    // Release the IRQ (kernel synchronises).
    ub::free_irq(state.irq_num, state as *const NetdevState as *mut c_void);

    // Reap any in-flight TX skbs the hardware never completed (some may be
    // OWN-set at the device side; we drop them safely).
    for slot in state.tx_shadow.iter() {
        let skb = slot.swap(ptr::null_mut(), Ordering::AcqRel);
        if !skb.is_null() {
            ub::skb_free_error(skb);
        }
    }

    // Zero the descriptor rings so a subsequent open starts fresh.
    for i in 0..RING_LEN {
        ub::desc_write(state.tx_desc, i, Descriptor::default());
        ub::desc_write(state.rx_desc, i, Descriptor::default());
    }
}

// ── ndo_start_xmit ────────────────────────────────────────────────────────

fn ndo_start_xmit(state: &NetdevState, skb: *mut bindings::sk_buff) -> c_int {
    let n = XMIT_CALLS.fetch_add(1, Ordering::Relaxed);
    if n < 3 {
        pr_info!("r8125_rust xmit#{}: about to map+post\n", n);
    }
    // Reserve a TX slot at tx_head. If the ring is (nearly) full, stop the
    // queue and return BUSY as the §6.3-counted exception.
    let head = state.tx_head.inner.load(Ordering::Relaxed);
    let tail = state.tx_tail.inner.load(Ordering::Acquire);
    let in_flight = head.wrapping_sub(tail);
    if in_flight >= RING_LEN - 1 {
        let ndev = state.ndev.load(Ordering::Acquire);
        ub::bridge_tx_stop_queue(ndev);
        // The skb was NOT mapped / NOT stored — kernel retains ownership.
        // Count this rare §6.3 exception explicitly.
        ub::tx_busy_exception(ndev);
        return NETDEV_TX_BUSY;
    }

    // Map DMA; on failure, free + drop.
    let mut dma_handle: bindings::dma_addr_t = 0;
    let mut len: usize = 0;
    if ub::skb_dma_map_tx(&state.pdev, skb, &mut dma_handle, &mut len).is_err() {
        ub::skb_free_error(skb);
        return NETDEV_TX_OK;
    }
    if len > regs::RX_MAX_SIZE_DEFAULT as usize {
        ub::skb_dma_unmap_tx(&state.pdev, dma_handle, len);
        ub::skb_free_error(skb);
        return NETDEV_TX_OK;
    }

    let slot = head % RING_LEN;
    let is_last = slot == RING_LEN - 1;
    let mut opts1 =
        regs::DESC_OWN | regs::DESC_TX_FS | regs::DESC_TX_LS | (len as u32 & regs::DESC_LEN_MASK);
    if is_last {
        opts1 |= regs::DESC_EOR;
    }

    // Store skb pointer in the shadow BEFORE flipping OWN — so a reaper
    // running concurrently sees the slot owned before it sees OWN clear.
    state.tx_shadow[slot].store(skb, Ordering::Release);
    ub::desc_write(
        state.tx_desc,
        slot,
        Descriptor {
            opts1,
            opts2: 0,
            addr: dma_handle,
        },
    );

    state.tx_head.inner.store(head.wrapping_add(1), Ordering::Release);
    state.regs().tx_poll();

    NETDEV_TX_OK
}

// ── Raw IRQ handler ───────────────────────────────────────────────────────

extern "C" fn raw_irq_handler(_irq: c_int, dev_id: *mut c_void) -> bindings::irqreturn_t {
    let state = state_from(dev_id);
    let regs = state.regs();
    let status = regs.isr();
    if status == 0 || status == 0xFFFF_FFFF {
        return bindings::irqreturn_IRQ_NONE as bindings::irqreturn_t;
    }
    note_irq_fire();
    // Ack everything we saw, mask further IRQs, hand off to NAPI.
    regs.ack_isr(status);
    regs.set_imr(0);
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
        let ndev = match ub::bridge_alloc(pdev, cookie as *mut c_void, &ACTIVE_OPS, mac) {
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
