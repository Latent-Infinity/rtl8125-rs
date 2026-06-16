// SPDX-License-Identifier: GPL-2.0
//! The single permitted home for `unsafe` in this crate.
//!
//! Crate root carries `#![deny(unsafe_code)]`; this module locally lifts that
//! by `#![allow(unsafe_code)]`. CI (`ci/check_unsafe_allowlist.sh`) refuses
//! any other file that locally allows `unsafe_code` unless it is named in
//! `.unsafe-allowlist` — and this is the only entry there.
//!
//! Every block carries a `// SAFETY:` comment that states:
//!  - which hardware or C-side invariant is being relied on;
//!  - who currently owns the memory (CPU vs. device);
//!  - what ordering / barrier requirement applies;
//!  - why use-after-free is impossible;
//!  - why ring overrun is impossible.
//!
//! AI-generated patches that touch this file get the strictest human review.
//!
//! ## Register-layer status
//!
//! Empty — the kernel `pci`, `io::mem`, `devres`, and `time::delay` APIs
//! covered every register-layer need in safe Rust.
//!
//! ## DMA-layer status
//!
//! Three residents land here:
//!  - [`set_64bit_dma_mask`] wraps the unsafe `dma_set_mask_and_coherent`
//!    on `pci::Device`.
//!  - `unsafe impl AsBytes for ring::Descriptor` and
//!    `unsafe impl FromBytes for ring::Descriptor` — required by
//!    [`kernel::dma::CoherentAllocation<T>`]; both traits are unsafe
//!    (proving a type is plain-old-data is an obligation the compiler can't
//!    verify on its own).
#![allow(unsafe_code)]
#![allow(non_camel_case_types)]

use core::ffi::{c_int, c_uint, c_void};
use core::ptr::NonNull;
use core::sync::atomic::Ordering;

use kernel::bindings;
use kernel::device;
use kernel::dma::DmaMask;
// `kernel::dma::Device` is implemented for `pci::Device<Core>` (see
// `pci.rs::474`); bring it into scope so `pdev.dma_set_mask_and_coherent`
// resolves below. The alias keeps the name from shadowing `pci::Device`.
use kernel::dma::Device as _;
use kernel::error::{to_result, Result};
use kernel::pci;
use kernel::prelude::*;
use kernel::transmute::{AsBytes, FromBytes};
use kernel::types::Opaque;

use crate::netdev::{NetdevHandle, NetdevState};
use crate::ring::{
    Descriptor, RxCompletion, RxDescFormat, RxDescLegacy, RxDescV3, RxDescV4, RxDescriptor, RxParse,
};

/// Configure 64-bit DMA addressing on `pdev` and its coherent allocator.
/// Wraps the kernel-Rust `unsafe fn dma_set_mask_and_coherent`.
///
/// # SAFETY contract
///
/// The kernel Rust API marks `dma_set_mask_and_coherent` `unsafe` with a
/// single requirement: **no concurrent DMA allocation / mapping calls on
/// the same device.** We are called from `pci::Driver::probe` (single-
/// threaded for a given device — the PCI core serializes probe / remove
/// per device) and **before** any `CoherentAllocation::alloc_coherent`, so
/// the contract holds.
///
/// Other safety facets:
///  - **Hardware invariant**: the RTL8125 is a PCIe device whose BAR2 and
///    descriptor DMAs both fit in any addr range ≤ 64 bits; a 64-bit mask
///    is always a superset of what the device needs.
///  - **Ownership**: this call configures the IOMMU / bus-master shape; no
///    CPU-side or device-side memory changes hands.
///  - **Ordering**: must precede any `alloc_coherent` for the device, which
///    is exactly the call ordering in `pci.rs::probe`.
///  - **No use-after-free**: `pdev` is a borrowed reference; the underlying
///    `struct pci_dev` outlives the call by the type invariants of
///    `pci::Device<Core>`.
///  - **No ring overrun**: this call does not touch any descriptor ring.
pub(crate) fn set_64bit_dma_mask(pdev: &pci::Device<kernel::device::Core>) -> Result<()> {
    let mask = DmaMask::new::<64>();
    // SAFETY: see the doc comment above. Called from single-threaded probe,
    // before any DMA allocation; passes a 64-bit mask which the RTL8125
    // supports per the PCIe baseline.
    unsafe { pdev.dma_set_mask_and_coherent(mask) }
}

// ── Plain-old-data marker traits for the hardware descriptor ──────────────

// SAFETY: `Descriptor` is `#[repr(C)]` with three integer fields
// (`u32 opts1`, `u32 opts2`, `u64 addr`). Every bit pattern is a valid
// `Descriptor` value — there are no padding bytes (16-byte struct = 4+4+8)
// and no invariants beyond the fields themselves. Therefore reading any
// 16-byte chunk of DMA-coherent memory back as `Descriptor` is safe, and
// `AsBytes`'s "the trait promises bit-pattern compatibility with raw bytes"
// obligation holds trivially.
unsafe impl AsBytes for Descriptor {}

// SAFETY: as above for `AsBytes` — `Descriptor` has no uninitialized
// portions (no padding, no `MaybeUninit` fields), so reconstructing one
// from arbitrary bytes cannot create undefined behaviour. The hardware-
// written fields (`opts1`, `opts2`) and the DMA address (`addr`) are all
// fully defined for any bit pattern the device can produce.
unsafe impl FromBytes for Descriptor {}

// SAFETY: `RxDescLegacy`, `RxDescV3`, `RxDescV4`, and `RxDescriptor` are
// `#[repr(C)]`/`#[repr(C, align(8))]` POD layouts with no pointer fields.
// All bit patterns that fit the target byte width are admissible from DMA
// sources, so broad `AsBytes`/`FromBytes` is sound for coherent allocation
// and descriptor replay.
// SAFETY: as above for `AsBytes`; `FromBytes` is symmetric for these POD types.
unsafe impl AsBytes for RxDescriptor {}
// SAFETY: as above for `RxDescriptor`; reconstructed `RxDescriptor` values are
// valid for any 32-byte bit pattern.
unsafe impl FromBytes for RxDescriptor {}

// SAFETY: no padding or invalid invariants; `RxDescLegacy` mirrors the
// 16-byte DMA descriptor for this chip family and is safe to round-trip
// from any concrete bit pattern.
unsafe impl AsBytes for RxDescLegacy {}
// SAFETY: as above for `RxDescLegacy`.
unsafe impl FromBytes for RxDescLegacy {}

// SAFETY: `RxDescV3` is a 32-byte POD layout with only integer fields.
// There are no ownership or pointer invariants, so arbitrary firmware bits
// are valid to copy into this storage type.
unsafe impl AsBytes for RxDescV3 {}
// SAFETY: as above for `RxDescV3`.
unsafe impl FromBytes for RxDescV3 {}

// SAFETY: `RxDescV4` is a 16-byte POD layout with only integer fields.
// There are no ownership or pointer invariants, so arbitrary firmware bits
// are valid to copy into this storage type.
unsafe impl AsBytes for RxDescV4 {}
// SAFETY: as above for `RxDescV4`.
unsafe impl FromBytes for RxDescV4 {}

// The task #58 stack-overflow fix uses `KBox::init` with
// `init_array_from_fn` to populate the giant 256-slot atomic arrays in
// `NetdevState` directly on the heap. No `Zeroable` impl is needed for
// our atomic types because `init_array_from_fn` constructs each element
// from a closure-returned value via the `impl<T> Init<T> for T` blanket
// (any value is its own one-shot initializer). See `pci.rs::probe`.

// ───────────────────────────────────────────────────────────────────────
// Rust ↔ C bridge FFI declarations + safe wrappers
//
// The C side lives in `src/netdev_bridge*.c`; the contract is in
// `src/netdev_bridge.h`. Everything here is mechanical glue:
//   - the function-pointer table the Rust side hands to the C bridge
//     (`BridgeOps` — `#[repr(C)]` matches `struct r8125_bridge_ops`),
//   - `extern "C"` declarations for the cshim entry points,
//   - safe Rust wrappers each with a `// SAFETY:` block.
// ───────────────────────────────────────────────────────────────────────

/// Rust mirror of `struct r8125_bridge_ops` — same layout, same ABI.
/// Allow non-CamelCase only for the `priv` field name parity is moot:
/// we use `BridgeOps` in Rust and don't need to name the parameter.
#[repr(C)]
pub(crate) struct BridgeOps {
    pub open: extern "C" fn(cookie: *mut c_void, feature_flags: u32) -> c_int,
    pub stop: extern "C" fn(cookie: *mut c_void),
    pub xmit: extern "C" fn(cookie: *mut c_void, skb: *mut bindings::sk_buff) -> c_int,
    pub poll: extern "C" fn(cookie: *mut c_void, queue_id: u32, budget: c_int) -> c_int,
    pub change_mtu: extern "C" fn(cookie: *mut c_void, new_mtu: c_int) -> c_int,
    pub set_features: extern "C" fn(cookie: *mut c_void, feature_flags: u32) -> c_int,
    /// ethtool `set_rxfh` indirection validation. Returns 0 if every entry
    /// maps to a runtime-active RX queue, `-EINVAL` otherwise. `indir`/`len`
    /// come straight from the kernel `ethtool_rxfh_param`; `queue_count` is the
    /// C bridge's active queue count.
    pub rss_indir_check: extern "C" fn(
        cookie: *mut c_void,
        indir: *const u32,
        len: c_uint,
        queue_count: c_uint,
    ) -> c_int,
    /// ethtool `get_rxfh` — fill the caller's key (40 bytes) and/or indirection
    /// table (128 `u32` entries) from the Rust-owned RSS policy. Either pointer
    /// may be NULL. The chip RSS key is write-only, so this cache is the source
    /// of truth for what `ethtool -x` reports.
    pub rss_get: extern "C" fn(cookie: *mut c_void, key_out: *mut u8, indir_out: *mut u32),
    /// ethtool `set_rxfh` — install a custom key and/or indirection table into the
    /// Rust policy and reprogram the chip live. Either input may be NULL.
    /// `queue_count` is the active RX-queue count. Returns 0 or `-EINVAL`.
    pub rss_set: extern "C" fn(
        cookie: *mut c_void,
        key_in: *const u8,
        indir_in: *const u32,
        queue_count: c_uint,
    ) -> c_int,
    /// ethtool `set_channels` — set the runtime active RX-queue count. The C
    /// bridge validates tx/combined and reconfigures (stop+open) to apply.
    /// Returns 0 (accepted) or `-EINVAL`.
    pub set_channels: extern "C" fn(cookie: *mut c_void, rx_count: c_uint) -> c_int,
    /// `ndo_set_rx_mode` — program the RX accept filter + multicast hash. The C
    /// bridge computes `accept` (RCR accept bits) and the two natural-order
    /// multicast hash words from `ndev->flags` + the mc list; Rust merges the
    /// accept bits into the live RCR and writes MAR0/MAR4.
    pub set_rx_mode: extern "C" fn(cookie: *mut c_void, accept: c_uint, mc0: c_uint, mc1: c_uint),
    /// `ndo_get_stats64` hardware-tally dump. The C bridge owns the coherent
    /// buffer and passes its DMA address; Rust drives the MMIO dump handshake
    /// and returns 0 on success, -1 on timeout. C then reads the dumped struct.
    pub tally_dump: extern "C" fn(cookie: *mut c_void, dma_addr: u64) -> c_int,
    /// Reset the on-die tally counters (issued once at open for a clean
    /// per-session baseline). Same DMA-address handshake as `tally_dump`.
    pub tally_reset: extern "C" fn(cookie: *mut c_void, dma_addr: u64) -> c_int,
    /// `ethtool get_wol` — active `WAKE_*` mask read back from the chip.
    pub get_wol: extern "C" fn(cookie: *mut c_void) -> u32,
    /// `ethtool set_wol` — program the chip WoL arm state. `wolopts` is
    /// pre-validated by the C side (only supported `WAKE_*` bits).
    pub set_wol: extern "C" fn(cookie: *mut c_void, wolopts: u32),
    /// WoL-aware suspend arming, called from the PM suspend callback after the
    /// light NAPI-only quiesce: arms the chip WoL + PME, opens the RX accept
    /// filter, and keeps the internal PHY powered in D3 via PMCH NO_PLL_DOWN.
    pub wol_suspend_arm: extern "C" fn(cookie: *mut c_void, wolopts: u32),
    /// `ethtool -d` register dump — read one 32-bit MMIO register by byte
    /// offset. The C side loops to fill its own buffer (no raw buffer crosses
    /// the boundary).
    pub read_reg: extern "C" fn(cookie: *mut c_void, offset: u32) -> u32,
    /// Reprogram the chip's RX unicast filter (RAR) from the current
    /// `net_device` address. Called on a live `ndo_set_mac_address` while the
    /// interface is running so the hardware filter tracks the new address
    /// without waiting for the next open.
    pub set_mac_filter: extern "C" fn(cookie: *mut c_void),
    /// XDP_TX producer — enqueue one already-`DMA_TO_DEVICE`-mapped `xdp_frame`
    /// on the TX ring. Called from the C XDP verdict path under the txq lock.
    /// `frame` is the `xdp_frame*` the reaper returns via `xdp_return_frame`.
    /// Returns 0 on enqueue, `-ENOSPC` if the ring is full.
    pub xdp_xmit_one: extern "C" fn(
        cookie: *mut c_void,
        frame_dma: u64,
        frame_len: u32,
        frame: *mut c_void,
    ) -> c_int,
    /// Ring the TX doorbell once at NAPI-poll end if any XDP_TX frame was
    /// enqueued this poll. Called from `r8125_bridge_xdp_finalize`.
    pub xdp_tx_flush: extern "C" fn(cookie: *mut c_void),
}

// Bindgen emits `pci_dev` / `net_device` / `sk_buff` as opaque
// zero-sized structs (no fields). rustc's `improper_ctypes` lint flags
// them as not-FFI-safe even though they are exactly opaque-pointer
// types on the C side. The lint is correct in general; for these
// specific bindgen-emitted opaque structs it is a false positive.
#[allow(improper_ctypes)]
extern "C" {
    fn r8125_bridge_alloc(
        pdev: *mut bindings::pci_dev,
        cookie: *mut c_void,
        ops: *const BridgeOps,
        mac: *const u8,
    ) -> *mut bindings::net_device;
    fn r8125_bridge_free(ndev: *mut bindings::net_device);
    fn r8125_bridge_register(ndev: *mut bindings::net_device) -> c_int;
    fn r8125_bridge_unregister_and_free(ndev: *mut bindings::net_device);
    fn r8125_bridge_skb_free_error(skb: *mut bindings::sk_buff);

    fn r8125_bridge_napi_schedule(ndev: *mut bindings::net_device, queue_id: c_uint);
    fn r8125_bridge_napi_complete_done(
        ndev: *mut bindings::net_device,
        queue_id: c_uint,
        work_done: c_int,
    );
    fn r8125_bridge_set_active_rx_queues(ndev: *mut bindings::net_device, n: c_uint);
    fn r8125_bridge_dev_addr(ndev: *mut bindings::net_device, out: *mut u8);
    #[cfg(r8125_pci_pm)]
    fn r8125_bridge_pm_suspend(ndev: *mut bindings::net_device);
    #[cfg(r8125_pci_pm)]
    fn r8125_bridge_pm_resume(ndev: *mut bindings::net_device) -> c_int;
    fn r8125_bridge_irq_pin_cpu(irq: u32, cpu: c_int) -> c_int;
    fn r8125_bridge_irq_clear_hint(irq: u32);
    fn r8125_bridge_num_online_cpus() -> c_uint;
    fn r8125_bridge_node_base_cpu(pdev: *mut bindings::pci_dev) -> c_int;
    fn r8125_bridge_dma_rmb();
    fn r8125_bridge_dma_wmb();
    fn r8125_bridge_tx_stop_queue(ndev: *mut bindings::net_device);
    fn r8125_bridge_tx_wake_queue(ndev: *mut bindings::net_device);
    fn r8125_bridge_netdev_xmit_more() -> bool;
    fn r8125_bridge_rss_key_fill(key: *mut u8, len: u32);
    fn r8125_bridge_rxfh_indir_default(index: u32, n_rx_rings: u32) -> u32;
    fn r8125_bridge_tx_disable(ndev: *mut bindings::net_device);
    fn r8125_bridge_carrier_off(ndev: *mut bindings::net_device);

    fn r8125_bridge_skb_dma_unmap_tx(
        dev: *mut bindings::device,
        handle: bindings::dma_addr_t,
        len: usize,
    );
    fn r8125_bridge_skb_dma_unmap_frag_tx(
        dev: *mut bindings::device,
        handle: bindings::dma_addr_t,
        len: usize,
    );
    fn r8125_bridge_tx_busy_exception(ndev: *mut bindings::net_device);

    // ── Scatter-gather + TSO (task 49) ──────────────────────────────────
    fn r8125_bridge_skb_data_dma_map(
        dev: *mut bindings::device,
        skb: *mut bindings::sk_buff,
        out_handle: *mut bindings::dma_addr_t,
        out_len: *mut u32,
    ) -> c_int;
    fn r8125_bridge_skb_frag_dma_map(
        dev: *mut bindings::device,
        skb: *mut bindings::sk_buff,
        frag_idx: u32,
        out_handle: *mut bindings::dma_addr_t,
        out_len: *mut u32,
    ) -> c_int;
    fn r8125_bridge_skb_tx_offload_prepare(
        skb: *mut bindings::sk_buff,
        out_opts1: *mut u32,
        out_opts2: *mut u32,
        out_nr_frags: *mut u32,
    ) -> c_int;
    fn r8125_bridge_skb_consume_tx(
        ndev: *mut bindings::net_device,
        skb: *mut bindings::sk_buff,
    ) -> c_uint;
    fn r8125_bridge_skb_len(skb: *const bindings::sk_buff) -> c_uint;
    fn r8125_bridge_dql_seed_min_limit(ndev: *mut bindings::net_device);
    fn r8125_bridge_netdev_sent_queue(
        ndev: *mut bindings::net_device,
        bytes: c_uint,
        xmit_more: bool,
    ) -> bool;
    fn r8125_bridge_netdev_completed_queue(
        ndev: *mut bindings::net_device,
        pkts: c_uint,
        bytes: c_uint,
    );

    // ── PHY plumbing ─────────────────────────────────────────────────────
    fn r8125_bridge_phy_register(
        ndev: *mut bindings::net_device,
        ops: *const BridgeMdioOps,
    ) -> c_int;
    fn r8125_bridge_phy_connect_and_reset(ndev: *mut bindings::net_device) -> c_int;
    fn r8125_bridge_phy_kick_state_machine(ndev: *mut bindings::net_device) -> c_int;
    fn r8125_bridge_phy_stop(ndev: *mut bindings::net_device);
    fn r8125_bridge_phy_modify_paged(
        ndev: *mut bindings::net_device,
        page: u16,
        reg: u16,
        mask: u16,
        set: u16,
    );
    fn r8125_bridge_phy_write_paged(ndev: *mut bindings::net_device, page: u16, reg: u16, val: u16);
    fn r8125_bridge_phy_write_mmd(ndev: *mut bindings::net_device, devad: u16, reg: u16, val: u16);
    fn r8125_bridge_phy_modify_mmd(
        ndev: *mut bindings::net_device,
        devad: u16,
        reg: u16,
        mask: u16,
        set: u16,
    );
    fn r8125_bridge_set_fw_version(ndev: *mut bindings::net_device, ver: *const u8);

    // ── Zero-copy RX — page_pool + per-MTU buffers ─────────────────────
    // The pool is created per ndo_open sized for dev->mtu; `out_buf_len`
    // is the device-writable bytes per buffer (drives descriptor LEN +
    // RxMaxSize). Destroy happens after every slot is freed.
    fn r8125_bridge_rx_pool_create(
        ndev: *mut bindings::net_device,
        queue_id: c_uint,
        ring_len: c_uint,
        out_buf_len: *mut u32,
    ) -> c_int;
    fn r8125_bridge_rx_pool_destroy(ndev: *mut bindings::net_device, queue_id: c_uint);
    fn r8125_bridge_xdp_finalize(ndev: *mut bindings::net_device, queue_id: c_uint);
    fn r8125_bridge_xdp_return_frame(frame: *mut c_void);
    fn r8125_bridge_rx_alloc(
        ndev: *mut bindings::net_device,
        queue_id: c_uint,
        out_cpu: *mut *mut c_void,
        out_dma: *mut bindings::dma_addr_t,
    ) -> c_int;
    fn r8125_bridge_rx_free(ndev: *mut bindings::net_device, queue_id: c_uint, cpu: *mut c_void);

    // RX super-call: zero-copy napi_build_skb +
    // page-pool recycle, with alloc-before-consume refill. Outputs the
    // slot's refilled (cpu, dma) so the caller updates its shadow and
    // re-posts the descriptor. On drop the outputs equal the inputs.
    fn r8125_bridge_rx_one_packet(
        ndev: *mut bindings::net_device,
        queue_id: c_uint,
        dma: bindings::dma_addr_t,
        buf: *const core::ffi::c_void,
        len: usize,
        desc_opts1: u32,
        desc_opts2: u32,
        hash_info: u64,
        new_cpu: *mut *mut c_void,
        new_dma: *mut bindings::dma_addr_t,
    );

    // ndo_change_mtu accessors (per-MTU RX needs a stop/open on a live
    // MTU change; see `netdev::rust_change_mtu`). The reopen bracket lives
    // in C so the napi_disable/enable discipline matches ndo_open/stop.
    fn r8125_bridge_netif_running(ndev: *mut bindings::net_device) -> bool;
    fn r8125_bridge_reopen_for_mtu(ndev: *mut bindings::net_device, new_mtu: c_int) -> c_int;
}

/// Rust mirror of `struct r8125_bridge_mdio_ops` — four function pointers
/// the C MDIO bus uses to call back into Rust for PHY register access.
/// The C22 pair drives standard MII regs 0..31; the C45 pair drives MMD
/// access (only `MDIO_MMD_VEND2 + regnum > MDIO_STAT2` reaches the chip).
#[repr(C)]
pub(crate) struct BridgeMdioOps {
    pub read: extern "C" fn(priv_: *mut c_void, phyreg: c_int) -> c_int,
    pub write: extern "C" fn(priv_: *mut c_void, phyreg: c_int, val: u16) -> c_int,
    pub read_c45: extern "C" fn(priv_: *mut c_void, devad: c_int, phyreg: c_int) -> c_int,
    pub write_c45:
        extern "C" fn(priv_: *mut c_void, devad: c_int, phyreg: c_int, val: u16) -> c_int,
}

// SAFETY: `NetdevHandle` wraps a raw `*mut bindings::net_device` from
// the cshim's `r8125_bridge_alloc`. The underlying `net_device` is a
// kernel object whose lifetime is managed by register/unregister; the
// kernel net stack is thread-safe by design (RTNL + queue locks), so
// moving the handle between threads is sound. No memory is transferred
// by Send; no ring overrun is possible.
unsafe impl Send for NetdevHandle {}

// SAFETY: `NetdevState` holds raw pointers (`bar_ptr`, `tx.desc`,
// `rx.desc`) into kernel-owned mappings whose lifetimes outlive
// NetdevState (BAR is pinned via Devres in R8125Driver, descriptor
// rings are owned by `Ring<{ RING_LEN }>` fields in R8125Driver that
// drop after NetdevState). Cross-context fields (head/tail/shadow,
// per-slot rx cpu/dma) are atomics. Static fields are read-only after
// probe. The per-slot RX page chunks are owned by `ndo_open` and
// freed by `ndo_stop`; both run with RTNL held so there's no
// allocator-side race. NAPI is the only context that mutates
// `rx.tail` / `tx.tail`; xmit is the only one that mutates `tx.head`.
// Sharing across threads is therefore safe.
unsafe impl Send for NetdevState {}
// SAFETY: same reasoning as the `Send` impl above; all cross-context
// mutation goes through atomics, RTNL-held slow paths, or
// device-owned coherent memory.
unsafe impl Sync for NetdevState {}

// ── Safe wrappers — hot path ──────────────────────────────────────────────

/// Enable bus-mastering. Kernel API method is safe but lives on
/// `pci::Device<Core>` only; we re-expose it from a `&ARef<pci::Device>`
/// for `ndo_open`'s convenience.
pub(crate) fn pci_set_master(_pdev: &kernel::sync::aref::ARef<pci::Device>) {
    // ARef<pci::Device> derefs to pci::Device<Normal>; set_master needs Core.
    let raw = pci_dev_raw_from_aref(_pdev);
    // SAFETY: The bound pci_dev is alive (ARef keeps a refcount); pci_set_master
    // takes a *mut pci_dev and is sound to call any time the device exists.
    unsafe { bindings::pci_set_master(raw) };
}

/// Raw `*mut pci_dev` from an `ARef<pci::Device>` (same layout argument as
/// `pci_dev_raw` above — `pci::Device` is repr(transparent) over Opaque).
fn pci_dev_raw_from_aref(pdev: &kernel::sync::aref::ARef<pci::Device>) -> *mut bindings::pci_dev {
    let p: &pci::Device = pdev;
    let opaque: &Opaque<bindings::pci_dev> =
        // SAFETY: same repr-transparent argument as `pci_dev_raw`.
        unsafe { &*core::ptr::from_ref(p).cast::<Opaque<bindings::pci_dev>>() };
    opaque.get()
}

/// `request_threaded_irq(handler=fn, thread_fn=NULL, flags, name, cookie)`.
///
/// `flags` is selected by the caller based on the IRQ delivery mode:
///   - INTx → `IRQF_SHARED` (the pin is potentially shared with other
///     functions on the PCIe bus / motherboard).
///   - MSI / MSI-X → 0 (message-signaled vectors are per-device and
///     cannot be shared; `IRQF_SHARED` would be rejected by the kernel).
pub(crate) fn request_irq(
    irq: u32,
    handler: unsafe extern "C" fn(c_int, *mut c_void) -> bindings::irqreturn_t,
    cookie: *mut c_void,
    flags: usize,
) -> Result<()> {
    // SAFETY: handler is a fixed Rust extern "C" fn; cookie outlives the IRQ
    // registration (NetdevState lives until NetdevHandle drops, which only
    // happens after ndo_stop has free_irq'd). Flag selection is the caller's
    // responsibility (Intx vs MSI/MSI-X — see `IrqMode` in `netdev.rs`).
    let rc = unsafe {
        bindings::request_threaded_irq(
            irq,
            Some(handler),
            None,
            flags,
            c"r8125_rust".as_ptr().cast::<u8>(),
            cookie,
        )
    };
    to_result(rc)
}

/// `IRQF_SHARED` from `include/linux/interrupt.h` — re-exported so the
/// non-FFI call sites in `netdev::ndo_open` don't have to touch
/// `bindings::*` directly.
pub(crate) const IRQF_SHARED: usize = bindings::IRQF_SHARED as usize;

// ── PCI IRQ vector allocation ────────────────────────────────────────────
//
// Kernel-Rust ships safe `pci::Device<Bound>::alloc_irq_vectors` that
// internally registers the allocation with `devres` so
// `pci_free_irq_vectors` fires automatically at device unbind. We use it
// from probe; the returned `IrqVector<'a>` range can be dropped after we
// extract the IRQ number because the devres handle (not the range) owns
// the lifetime.

/// Allocate exactly one IRQ vector for `pdev`. Tries the types in
/// `irq_types` in the kernel's preferred order (MSI-X → MSI → INTx when
/// `IrqTypes::all()` is passed). Devres handles `pci_free_irq_vectors`
/// at device unbind.
///
/// Returns `Ok(())` on success; we discard the `IrqVector` range because
/// the chip only consumes one vector (queue 0) and we look up its kernel
/// IRQ number separately via [`pci_irq_vector`].
pub(crate) fn alloc_one_irq_vector(
    pdev: &pci::Device<kernel::device::Core>,
    irq_types: pci::IrqTypes,
) -> Result<()> {
    pdev.alloc_irq_vectors(1, 1, irq_types).map(|_range| ())
}

/// Allocate an exact IRQ-vector range for `pdev`.
///
/// RTL8125B ISR version 2 maps interrupt source bits directly to MSI-X table
/// entries. TX Q0 is entry 16 and LINKCHG is entry 21, so callers must allocate
/// at least 22 vectors before enabling V2.
pub(crate) fn alloc_irq_vectors(
    pdev: &pci::Device<kernel::device::Core>,
    min_vecs: u32,
    max_vecs: u32,
    irq_types: pci::IrqTypes,
) -> Result<()> {
    pdev.alloc_irq_vectors(min_vecs, max_vecs, irq_types)
        .map(|_range| ())
}

/// `pci_irq_vector(pdev, index)` — fetch the kernel IRQ number for the
/// vector at `index`. Returns a `u32` rather than an `IrqVector` because
/// the call sites pass the number into `request_threaded_irq`, which
/// takes a bare `u32`.
///
/// # SAFETY
///
/// Must be called AFTER a successful `pci_alloc_irq_vectors` for `pdev`.
/// The caller guarantees that — at probe time we do the allocation
/// immediately before this call in the same probe function body.
pub(crate) fn pci_irq_vector<Ctx: device::DeviceContext>(
    pdev: &pci::Device<Ctx>,
    index: u32,
) -> Result<u32> {
    let raw = pci_dev_raw(pdev);
    // SAFETY: see fn-level contract; `raw` is valid for the lifetime of
    // `pdev` (an `&pci::Device<Ctx>` borrow).
    let rc = unsafe { bindings::pci_irq_vector(raw, index) };
    if rc < 0 {
        Err(kernel::error::Error::from_errno(rc))
    } else {
        Ok(rc as u32)
    }
}

// ── Zero-copy RX-pool safe wrappers ──────────────────────────────────────
//
// A `page_pool` owns every RX buffer. Each `RxSlot` holds one page's CPU
// base + device-visible DMA address pulled from the pool. The pool's
// lifecycle is ndo_open (create + allocate per slot) → ndo_stop (free per
// slot + destroy); see `src/netdev_bridge_rx_pool.c` for the discipline.

/// Create the RX page_pool sized for the netdev's current MTU. Returns
/// the device-writable bytes per buffer (drives the descriptor LEN field
/// and the chip's RxMaxSize register).
///
/// # SAFETY contract
///
/// `ndev` is the registered net_device; called once per ndo_open with no
/// pool currently live (the cshim WARNs on a double-create). Must be
/// balanced by `rx_pool_destroy` after all slots are freed.
pub(crate) fn rx_pool_create(
    ndev: *mut bindings::net_device,
    queue_id: u32,
    ring_len: usize,
) -> Result<u32> {
    let mut buf_len: u32 = 0;
    // SAFETY: see fn-level contract; out-pointer is a stack local.
    let rc = unsafe {
        r8125_bridge_rx_pool_create(
            ndev,
            queue_id as c_uint,
            ring_len as c_uint,
            core::ptr::from_mut(&mut buf_len),
        )
    };
    to_result(rc)?;
    Ok(buf_len)
}

/// Destroy the RX page_pool. Idempotent against a NULL pool (ndo_open
/// rollback before create). Every slot MUST already be freed via
/// `rx_free` — page_pool_destroy requires all pages returned first.
pub(crate) fn rx_pool_destroy(ndev: *mut bindings::net_device, queue_id: u32) {
    // SAFETY: `ndev` is the registered net_device; the cshim no-ops on a
    // NULL pool.
    unsafe { r8125_bridge_rx_pool_destroy(ndev, queue_id as c_uint) };
}

/// Pull one buffer from the pool for a slot. Returns `(cpu, dma)`.
///
/// # SAFETY contract
///
/// The pool was created by `rx_pool_create` and is live. Each successful
/// alloc must eventually be balanced by `rx_free` (teardown) or handed to
/// the stack via the recycle path in `bridge_rx_one_packet`.
pub(crate) fn rx_alloc(
    ndev: *mut bindings::net_device,
    queue_id: u32,
) -> Result<(*mut c_void, bindings::dma_addr_t)> {
    let mut cpu: *mut c_void = core::ptr::null_mut();
    let mut dma: bindings::dma_addr_t = 0;
    // SAFETY: see fn-level contract; out-pointers are stack locals.
    let rc = unsafe {
        r8125_bridge_rx_alloc(
            ndev,
            queue_id as c_uint,
            core::ptr::from_mut(&mut cpu),
            core::ptr::from_mut(&mut dma),
        )
    };
    to_result(rc)?;
    Ok((cpu, dma))
}

/// Return one slot's page to the pool. Idempotent against a null `cpu`
/// (the empty-slot sentinel) so the ndo_open rollback path can call it on
/// partially-allocated state.
pub(crate) fn rx_free(ndev: *mut bindings::net_device, queue_id: u32, cpu: *mut c_void) {
    // SAFETY: `cpu` is either null (no-op) or a page base from a prior
    // `rx_alloc` on the same pool.
    unsafe { r8125_bridge_rx_free(ndev, queue_id as c_uint, cpu) };
}

/// RX super-call: zero-copy `napi_build_skb` + page-pool recycle +
/// alloc-before-consume refill, all inside one cshim function. Returns the
/// slot's refilled `(cpu, dma)`; on a refill-failure drop they equal the
/// inputs. See `docs/RX_OPTIMIZATION_CANDIDATES.md` §B and the per-MTU
/// rationale in `src/netdev_bridge_rx_pool.c`.
///
/// # SAFETY: `ndev` is the registered net_device (lifetime via
/// `NetdevHandle`); `dma`/`buf` came from a prior `rx_alloc` on the live
/// pool; `len` ≤ chip-reported frame length, ≤ the pool's `max_len`.
/// Callable only from NAPI poll context.
#[allow(clippy::too_many_arguments)]
pub(crate) fn bridge_rx_one_packet(
    ndev: *mut bindings::net_device,
    queue_id: u32,
    dma: bindings::dma_addr_t,
    buf: *const core::ffi::c_void,
    len: usize,
    desc_opts1: u32,
    desc_opts2: u32,
    hash_info: u64,
) -> (*mut c_void, bindings::dma_addr_t) {
    let mut new_cpu = buf.cast_mut();
    let mut new_dma: bindings::dma_addr_t = dma;
    // SAFETY: see fn-level contract; out-pointers are stack locals.
    unsafe {
        r8125_bridge_rx_one_packet(
            ndev,
            queue_id as c_uint,
            dma,
            buf,
            len,
            desc_opts1,
            desc_opts2,
            hash_info,
            core::ptr::from_mut(&mut new_cpu),
            core::ptr::from_mut(&mut new_dma),
        )
    };
    (new_cpu, new_dma)
}

/// Flush the XDP redirect bulk queue once at the end of a NAPI poll (no-op if no
/// frame was redirected this poll). Cheap to call unconditionally.
///
/// # SAFETY: `ndev` is the registered net_device; `queue_id` is bounds-checked
/// by the cshim. Called from NAPI poll context.
pub(crate) fn bridge_xdp_finalize(ndev: *mut bindings::net_device, queue_id: u32) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_xdp_finalize(ndev, queue_id as c_uint) };
}

/// Return an `xdp_frame` to its origin page_pool at TX completion (the reaper's
/// XDP_TX disposition). Wraps the kernel `xdp_return_frame`, which uses the
/// frame's captured mem model to route the page back to the RX page_pool.
///
/// # SAFETY: `frame` is the exact `xdp_frame*` a prior `xdp_xmit_one` stored in
/// the TX shadow and has not yet been returned; it is returned exactly once.
pub(crate) fn xdp_return_frame(frame: *mut c_void) {
    // SAFETY: see fn-level contract — single-owner, returned once.
    unsafe { r8125_bridge_xdp_return_frame(frame) };
}

/// `netif_running(ndev)` — is the interface administratively up? Used by
/// `ndo_change_mtu` to decide whether a live RX-pool resize is needed.
///
/// # SAFETY: `ndev` is the registered net_device.
pub(crate) fn netif_running(ndev: *mut bindings::net_device) -> bool {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_netif_running(ndev) }
}

/// Re-open the device at `new_mtu` (live MTU change), bracketing the Rust
/// stop/open with the C-side napi_disable/enable discipline so the RX
/// page_pool is never destroyed while its NAPI is active. Returns the
/// kernel errno (0 on success, negative on a failed re-open).
///
/// # SAFETY: `ndev` is the registered net_device, the interface is up
/// (caller checked `netif_running`), and `new_mtu` was range-checked by the
/// net core. Runs with RTNL held (ndo_change_mtu context).
pub(crate) fn reopen_for_mtu(ndev: *mut bindings::net_device, new_mtu: c_int) -> c_int {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_reopen_for_mtu(ndev, new_mtu) }
}

// ── NetdevState pointer-juggling helpers (keep unsafe in this file) ──────

/// Reinterpret the cshim `cookie` pointer as `&NetdevState`.
///
/// # SAFETY contract (caller-side discipline)
///
/// `cookie` must have been produced by `kbox_into_raw(KBox<NetdevState>)`
/// for a NetdevState that is still alive — i.e. the matching netdev has
/// not yet been `unregister_and_free`'d. The cshim guarantees this for
/// every ndo callback dispatch.
pub(crate) fn state_from_cookie<'a>(cookie: *mut c_void) -> &'a NetdevState {
    // SAFETY: see fn doc.
    unsafe { &*(cookie as *const NetdevState) }
}

/// `KBox::into_raw` — moves ownership of `state` into a raw pointer.
pub(crate) fn kbox_into_raw(state: KBox<NetdevState>) -> *mut NetdevState {
    KBox::into_raw(state)
}

/// `KBox::from_raw` + drop. Reclaims a NetdevState previously passed to
/// `kbox_into_raw`. Must be called exactly once per `kbox_into_raw`.
///
/// # SAFETY: the pointer must have been produced by `kbox_into_raw` and
/// not consumed since. The cshim no longer references it after
/// `bridge_unregister_and_free` returns.
pub(crate) fn kbox_drop_from_raw(p: *mut NetdevState) {
    // SAFETY: see fn doc.
    drop(unsafe { KBox::from_raw(p) });
}

/// Store the registered net_device pointer in NetdevState — needed once,
/// between `bridge_alloc` and `bridge_register`, so callbacks can find ndev.
///
/// # SAFETY: `p` must be the cookie just returned from `kbox_into_raw`
/// (not yet consumed by `kbox_drop_from_raw`).
pub(crate) fn state_set_ndev(p: *mut NetdevState, ndev: *mut bindings::net_device) {
    // SAFETY: see fn doc.
    unsafe { (*p).ndev.store(ndev, Ordering::Release) };
}

/// Borrow `Regs` for the lifetime of a `&NetdevState`.
///
/// # SAFETY: NetdevState's invariant says `bar_ptr` outlives the
/// NetdevState (R8125Driver drops `_netdev` before `_bar`).
pub(crate) fn regs_from_state(state: &NetdevState) -> crate::mmio::Regs<'_> {
    // SAFETY: see fn doc.
    let bar = unsafe { &*state.bar_ptr };
    crate::mmio::Regs::new(bar)
}

/// Release the IRQ. `cookie` must be the same pointer that was passed to
/// `request_irq` (the kernel matches on it for shared IRQs).
pub(crate) fn free_irq(irq: u32, cookie: *mut c_void) {
    // SAFETY: kernel cleans up the registration; safe regardless of caller
    // context (RTNL held during ndo_stop).
    unsafe {
        bindings::free_irq(irq, cookie);
    }
}

/// Read one hardware descriptor from `ring[idx]` (volatile).
pub(crate) fn desc_read(ring: *mut Descriptor, idx: usize) -> Descriptor {
    // SAFETY: caller guarantees idx < N+1 of the ring this pointer indexes.
    // Volatile to discipline against compiler reordering across the
    // OWN-bit handshake.
    unsafe { core::ptr::read_volatile(ring.add(idx)) }
}

/// Write one hardware descriptor at `ring[idx]` (volatile, whole-struct).
///
/// Use only when the descriptor is not being published to the device with
/// `DESC_OWN` as the synchronization point. For OWN-set TX heads and RX
/// reposts, use [`desc_publish_own`] so `addr`/`opts2` become visible before
/// `opts1` hands ownership to the chip.
pub(crate) fn desc_write(ring: *mut Descriptor, idx: usize, value: Descriptor) {
    // SAFETY: as `desc_read`. The volatile pairs with the device's MMIO
    // read of the descriptor after we kick TX (or after hardware re-reads
    // an OWN-set RX slot).
    unsafe {
        core::ptr::write_volatile(ring.add(idx), value);
    }
}

/// Publish an OWN-set descriptor with r8169-style DMA ordering.
///
/// Writes `addr` and `opts2`, issues `dma_wmb()`, then writes `opts1`.
/// The final `opts1` write is the ownership transfer: on weakly ordered
/// systems the chip must not observe `DESC_OWN` before the matching DMA
/// address and secondary options are visible.
pub(crate) fn desc_publish_own(ring: *mut u8, idx: usize, value: Descriptor, format: RxDescFormat) {
    // SAFETY: caller guarantees idx < N+1 of the ring this pointer indexes.
    // These are descriptor-ring volatile writes, not MMIO. `dma_wmb()` is the
    // device-ordering boundary between the non-OWN fields and the OWN publish.
    unsafe {
        let stride = format.descriptor_len();
        let slot = ring.add(idx * stride);
        let (addr_off, opts2_off, opts1_off) = RxDescriptor::publish_offsets(format);
        core::ptr::write_volatile(slot.add(addr_off).cast::<u64>(), value.addr);
        core::ptr::write_volatile(slot.add(opts2_off).cast::<u32>(), value.opts2);
        dma_wmb();
        core::ptr::write_volatile(slot.add(opts1_off).cast::<u32>(), value.opts1);
    }
}

// ── RX descriptor helpers ──────────────────────────────────────────────────

/// Read ONLY the `opts1`/OWN word for the cheap pre-`dma_rmb()` ownership
/// check, using the precomputed [`RxParse`] offsets (no full descriptor fetch,
/// no per-packet format match).
///
/// CRITICAL: the stride is `parse.stride` (= `RxDescFormat::descriptor_len()`,
/// set once in `RxParse::new`) — the same stride the chip uses and the same one
/// [`desc_publish_own`] / [`desc_write_rx`] write at. A mismatched stride
/// silently misaligns the reaper and wedges RX (validated 2026-06-06: RX stalled
/// at 18 packets). `ci/check_rx_desc_stride.sh` enforces the single source.
#[inline]
pub(crate) fn rx_read_opts1(ring: *mut u8, idx: usize, parse: &RxParse) -> u32 {
    // SAFETY: idx < N of the ring; opts1_off lies within the `stride`-byte slot,
    // and the RxDescriptor storage (32B) is >= any format's stride.
    unsafe {
        core::ptr::read_volatile(ring.add(idx * parse.stride + parse.opts1_off).cast::<u32>())
    }
}

/// Read a full RX completion using the precomputed [`RxParse`] byte offsets:
/// one descriptor fetch, no per-packet `match RxDescFormat`. Call AFTER
/// `dma_rmb()` so the device's OWN-clear publish is visible.
#[inline]
pub(crate) fn rx_read_completion(ring: *mut u8, idx: usize, parse: &RxParse) -> RxCompletion {
    // SAFETY: as `rx_read_opts1` — every offset (opts1/opts2 and, for V3, the
    // RSSResult/HeaderInfo pair in `hash_off`) is within the `stride`-byte slot,
    // and the 32B RxDescriptor storage covers it for both legacy and V3.
    unsafe {
        let slot = ring.add(idx * parse.stride);
        let opts1 = core::ptr::read_volatile(slot.add(parse.opts1_off).cast::<u32>());
        let opts2 = core::ptr::read_volatile(slot.add(parse.opts2_off).cast::<u32>());
        let rss_hash = match parse.hash_off {
            Some((rss_off, hdr_off)) => {
                let rss_result = core::ptr::read_volatile(slot.add(rss_off).cast::<u32>());
                let header_info = core::ptr::read_volatile(slot.add(hdr_off).cast::<u16>());
                crate::ring::rx_hash_from_v3(rss_result, header_info)
            }
            None => None,
        };
        RxCompletion {
            len: (opts1 & crate::regs::DESC_LEN_MASK) as usize,
            opts1,
            opts2,
            rss_hash,
        }
    }
}

/// Write one RX descriptor slot (volatile) at the format stride. Use only when
/// the descriptor is not currently being OWN-published to the device.
pub(crate) fn desc_write_rx(ring: *mut u8, idx: usize, value: RxDescriptor, format: RxDescFormat) {
    // SAFETY: as `desc_read_rx`; used by stop/rollback paths where the device
    // is quiesced and slot contents are inert. Same `descriptor_len()` stride.
    unsafe {
        let stride = format.descriptor_len();
        let slot = ring.add(idx * stride);
        let slot_u64 = slot.cast::<u64>();
        let nwords = stride / 8;
        let mut w = 0;
        while w < nwords {
            core::ptr::write_volatile(slot_u64.add(w), value.words[w]);
            w += 1;
        }
    }
}

// `rx_buf_ptr` was removed alongside the jumbo refactor. NAPI now
// reads `state.rx_slot(i).cpu` directly — see `src/netdev.rs::RxSlot`.

// ── sk_buff helpers — safe wrappers, counters live inside the cshim ──────

pub(crate) fn skb_dma_unmap_tx(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    handle: bindings::dma_addr_t,
    len: usize,
) {
    let dev = bridge_dma_device(pdev);
    // SAFETY: handle/len came from a prior successful skb_data_dma_map.
    unsafe { r8125_bridge_skb_dma_unmap_tx(dev, handle, len) };
}

pub(crate) fn skb_dma_unmap_frag_tx(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    handle: bindings::dma_addr_t,
    len: usize,
) {
    let dev = bridge_dma_device(pdev);
    // SAFETY: handle/len came from a prior successful skb_frag_dma_map.
    unsafe { r8125_bridge_skb_dma_unmap_frag_tx(dev, handle, len) };
}

pub(crate) fn tx_busy_exception(ndev: *mut bindings::net_device) {
    // SAFETY: ndev is alive and registered while ndo_start_xmit runs.
    unsafe { r8125_bridge_tx_busy_exception(ndev) };
}

// ── NAPI / queue / carrier helpers ────────────────────────────────────────

pub(crate) fn bridge_napi_schedule(ndev: *mut bindings::net_device, queue_id: u32) {
    // SAFETY: ndev is alive (registered until NetdevHandle drops).
    unsafe { r8125_bridge_napi_schedule(ndev, queue_id as c_uint) };
}

pub(crate) fn bridge_napi_complete_done(
    ndev: *mut bindings::net_device,
    queue_id: u32,
    work_done: c_int,
) {
    // SAFETY: as above; called from NAPI poll context which guarantees the
    // napi_struct is valid.
    unsafe { r8125_bridge_napi_complete_done(ndev, queue_id as c_uint, work_done) };
}

/// Publish the runtime active RX queue count to the C bridge. The cshim clamps
/// it and calls `netif_set_real_num_rx_queues`.
///
/// # SAFETY: `ndev` is the registered net_device; called from `ndo_open` under
/// RTNL with the netdev down.
pub(crate) fn set_active_rx_queues(ndev: *mut bindings::net_device, n: u32) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_set_active_rx_queues(ndev, n as c_uint) };
}

/// Read the netdev's current `dev_addr` (6 bytes) so the open path can program
/// it into the chip RX filter.
///
/// # SAFETY: `ndev` is the registered net_device; the C side copies exactly
/// `ETH_ALEN` (6) bytes into `out`, which is a 6-byte stack array here.
pub(crate) fn bridge_dev_addr(ndev: *mut bindings::net_device) -> [u8; 6] {
    let mut out = [0u8; 6];
    // SAFETY: see fn-level contract; `out` is 6 bytes, matching ETH_ALEN.
    unsafe { r8125_bridge_dev_addr(ndev, out.as_mut_ptr()) };
    out
}

/// System-sleep suspend: detach + quiesce the device if it was up. The cshim
/// takes RTNL and the PCI core handles config save + D-state.
///
/// Gated on the `r8125_pci_pm` cfg — only reachable from the PM callbacks that
/// require the kernel-Rust PCI PM extension (see `pci.rs`). Compiled out on a
/// stock kernel so it raises no dead-code warning there.
///
/// # SAFETY: `ndev` is the registered net_device (or null after teardown; the
/// cshim no-ops on a down/detached device). Called from the PM callback while
/// the device is still bound.
#[cfg(r8125_pci_pm)]
pub(crate) fn bridge_pm_suspend(ndev: *mut bindings::net_device) {
    if ndev.is_null() {
        return;
    }
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_pm_suspend(ndev) };
}

/// System-sleep resume: re-init + attach the device if it was up before suspend.
/// Propagates a failed reopen as an error so the PM core sees the failure (the
/// cshim leaves the device detached in that case rather than reattaching a dead
/// interface).
///
/// # SAFETY: see [`bridge_pm_suspend`].
#[cfg(r8125_pci_pm)]
pub(crate) fn bridge_pm_resume(ndev: *mut bindings::net_device) -> Result {
    if ndev.is_null() {
        return Ok(());
    }
    // SAFETY: see fn-level contract.
    to_result(unsafe { r8125_bridge_pm_resume(ndev) })
}

/// Suggest IRQ CPU affinity for the chip's MSI-X / MSI / INTx vector.
/// Latency-aligned default (see `docs/RX_OPTIMIZATION_CANDIDATES.md`).
/// Best-effort: the kernel may
/// override the hint via `/proc/irq/N/smp_affinity` or `irqbalance`
/// policy. Returns the kernel errno (0 on success).
///
/// # SAFETY: trivial — calling kernel `irq_set_affinity_and_hint` via
/// a cshim wrapper that builds the cpumask itself. No Rust lifetime
/// concerns.
pub(crate) fn bridge_irq_pin_cpu(irq: u32, cpu: c_int) -> c_int {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_irq_pin_cpu(irq, cpu) }
}

/// Clear any IRQ affinity hint before `free_irq` (which WARNs if one is still
/// attached). A no-op when no hint was set, so teardown calls it for every
/// vector unconditionally.
///
/// # SAFETY: trivial — wraps `irq_update_affinity_hint(irq, NULL)`; `irq` is a
/// vector this driver requested. No Rust lifetime concerns.
pub(crate) fn bridge_irq_clear_hint(irq: u32) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_irq_clear_hint(irq) };
}

/// Number of online CPUs — fan-out width for the multi-queue affinity spread
/// (`layout::irq_affinity_cpu`).
///
/// # SAFETY: trivial — wraps `num_online_cpus()`, no preconditions.
pub(crate) fn bridge_num_online_cpus() -> u32 {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_num_online_cpus() }
}

/// PCI-local NUMA-node first-online CPU — the fan-out base for the multi-queue
/// affinity spread. Returns a negative errno if no online CPU is found.
///
/// # SAFETY: as `bridge_irq_pin_auto` — `pdev` must be a live `pci_dev`
/// (probe-time `pci::Device<Bound>` guarantees this).
pub(crate) fn bridge_node_base_cpu(pdev: *mut bindings::pci_dev) -> c_int {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_node_base_cpu(pdev) }
}

/// DMA read barrier for the RX descriptor OWN-bit handoff.
///
/// # SAFETY: the C shim calls Linux `dma_rmb()`, which has no pointer or
/// ownership preconditions. The ordering contract is caller-side: call
/// after the device clears OWN and before reading other descriptor fields
/// or DMA-written bytes.
pub(crate) fn dma_rmb() {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_dma_rmb() };
}

/// DMA write barrier used by [`desc_publish_own`]. Sister to `dma_rmb` —
/// see `docs/RX_OPTIMIZATION_CANDIDATES.md`.
///
/// # SAFETY: same as `dma_rmb` — no pointer or ownership preconditions.
/// The ordering contract is caller-side: use it between the descriptor's
/// non-OWN fields and the `opts1` write that sets `DESC_OWN`.
pub(crate) fn dma_wmb() {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_dma_wmb() };
}

pub(crate) fn bridge_tx_stop_queue(ndev: *mut bindings::net_device) {
    // SAFETY: ndev alive.
    unsafe { r8125_bridge_tx_stop_queue(ndev) };
}

pub(crate) fn bridge_tx_wake_queue(ndev: *mut bindings::net_device) {
    // SAFETY: ndev alive.
    unsafe { r8125_bridge_tx_wake_queue(ndev) };
}

/// `netdev_xmit_more()` — does the qdisc have more packets queued behind this
/// one in the current xmit burst? A batching hint only: when true the driver
/// may defer the TX doorbell to the last packet of the burst (xmit_more ==
/// false) to amortize the MMIO write. Reads the net core's per-CPU xmit state;
/// it is independent of BQL, so it is MSI-safe.
///
/// # SAFETY: callable from any `ndo_start_xmit` context — it only reads the
/// per-CPU state the net core sets before invoking the driver's xmit.
pub(crate) fn netdev_xmit_more() -> bool {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_netdev_xmit_more() }
}

/// Fill `key` with the boot-stable system RSS hash key (`netdev_rss_key_fill`),
/// replacing the previously hardcoded constant key for the single-queue RXHASH
/// path. The key is generated once per boot by the net core and shared, so
/// hashes are unpredictable across reboots without being baked into the driver.
///
/// # SAFETY: `key` is a `[u8; RSS_KEY_SIZE]`, so the pointer is valid for
/// `RSS_KEY_SIZE` writable bytes — exactly the length passed to the C helper.
pub(crate) fn rss_key_fill(key: &mut [u8; crate::regs::RSS_KEY_SIZE]) {
    // SAFETY: see fn-level contract; netdev_rss_key_fill writes `len` bytes.
    unsafe { r8125_bridge_rss_key_fill(key.as_mut_ptr(), crate::regs::RSS_KEY_SIZE as u32) };
}

/// Return Linux's default RX flow-hash indirection entry. This keeps Rust's
/// hardware table programming aligned with ethtool's default mapping.
///
/// # SAFETY: pure helper; the C side just forwards to
/// `ethtool_rxfh_indir_default(index, n_rx_rings)`.
pub(crate) fn rxfh_indir_default(index: u32, n_rx_rings: u32) -> u32 {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_rxfh_indir_default(index, n_rx_rings) }
}

/// Validate a kernel-supplied ethtool RSS indirection table (`set_rxfh`):
/// every bucket must map to an owned queue. The decision is the host-tested
/// `crate::layout::rxfh_indir_all_valid`; this wrapper only views the kernel
/// buffer as a slice for the duration of the call.
///
/// # SAFETY: `ptr` points to `len` `u32` entries — the ethtool core allocated
/// `get_rxfh_indir_size()` entries before invoking `set_rxfh`, and the borrow
/// does not outlive this call.
pub(crate) fn rxfh_indir_valid(ptr: *const u32, len: usize, queue_count: u32) -> bool {
    if ptr.is_null() || len == 0 {
        // No indirection change requested ⇒ nothing to reject.
        return true;
    }
    // SAFETY: see fn-level contract; slice is read-only and call-scoped.
    let indir = unsafe { core::slice::from_raw_parts(ptr, len) };
    crate::layout::rxfh_indir_all_valid(indir, queue_count)
}

/// Copy a kernel `set_rxfh` RSS key buffer (`RSS_KEY_SIZE` bytes) into `out`.
///
/// # SAFETY: `ptr` points to at least `RSS_KEY_SIZE` readable bytes (the ethtool
/// core allocates `get_rxfh_key_size()` before invoking `set_rxfh`); the borrow
/// is call-scoped.
pub(crate) fn read_rss_key(ptr: *const u8, out: &mut [u8; crate::rss::RSS_KEY_SIZE]) {
    // SAFETY: see fn-level contract; read-only, call-scoped.
    let src = unsafe { core::slice::from_raw_parts(ptr, crate::rss::RSS_KEY_SIZE) };
    out.copy_from_slice(src);
}

/// Copy the active RSS key into a kernel `get_rxfh` key buffer.
///
/// # SAFETY: `ptr` points to at least `RSS_KEY_SIZE` writable bytes (allocated by
/// the ethtool core); the borrow is call-scoped.
pub(crate) fn write_rss_key(ptr: *mut u8, key: &[u8; crate::rss::RSS_KEY_SIZE]) {
    // SAFETY: see fn-level contract; write-only, call-scoped.
    let dst = unsafe { core::slice::from_raw_parts_mut(ptr, crate::rss::RSS_KEY_SIZE) };
    dst.copy_from_slice(key);
}

/// Read a kernel `set_rxfh` indirection table (`RSS_INDIR_ENTRIES` `u32` queue
/// ids) into `out`, narrowing each entry to `u8` (saturating, so an out-of-range
/// value stays out of range for the host-tested `RssPolicy::set_indir` to reject
/// rather than silently wrapping).
///
/// # SAFETY: `ptr` points to at least `RSS_INDIR_ENTRIES` readable `u32`s
/// (allocated by the ethtool core); the borrow is call-scoped.
pub(crate) fn read_rss_indir(ptr: *const u32, out: &mut [u8; crate::rss::RSS_INDIR_ENTRIES]) {
    // SAFETY: see fn-level contract; read-only, call-scoped.
    let src = unsafe { core::slice::from_raw_parts(ptr, crate::rss::RSS_INDIR_ENTRIES) };
    for (d, &s) in out.iter_mut().zip(src.iter()) {
        *d = s.min(u32::from(u8::MAX)) as u8;
    }
}

/// Write the active indirection table (`u8` queue ids) into a kernel `get_rxfh`
/// `u32` buffer.
///
/// # SAFETY: `ptr` points to at least `RSS_INDIR_ENTRIES` writable `u32`s
/// (allocated by the ethtool core); the borrow is call-scoped.
pub(crate) fn write_rss_indir(ptr: *mut u32, table: &[u8; crate::rss::RSS_INDIR_ENTRIES]) {
    // SAFETY: see fn-level contract; write-only, call-scoped.
    let dst = unsafe { core::slice::from_raw_parts_mut(ptr, crate::rss::RSS_INDIR_ENTRIES) };
    for (d, &s) in dst.iter_mut().zip(table.iter()) {
        *d = u32::from(s);
    }
}

pub(crate) fn bridge_tx_disable(ndev: *mut bindings::net_device) {
    // SAFETY: ndev alive.
    unsafe { r8125_bridge_tx_disable(ndev) };
}

pub(crate) fn bridge_carrier_off(ndev: *mut bindings::net_device) {
    // SAFETY: ndev alive.
    unsafe { r8125_bridge_carrier_off(ndev) };
}

fn bridge_dma_device(pdev: &kernel::sync::aref::ARef<pci::Device>) -> *mut bindings::device {
    // Use the cshim's accessor by going through ANY registered net_device
    // is awkward when we only have pdev; just build &dev from the pci_dev
    // directly. The cshim's `bridge_skb_*` helpers accept a struct device *
    // — `&pdev->dev` is what we need.
    let raw = pci_dev_raw_from_aref(pdev);
    // SAFETY: pdev is alive via ARef; offset to its embedded `struct device`.
    unsafe { core::ptr::addr_of_mut!((*raw).dev) }
}

/// Extract the raw `*mut pci_dev` from a Rust `&pci::Device<Ctx>`.
///
/// # SAFETY contract
///
/// `pci::Device<Ctx>` is `#[repr(transparent)]` over
/// `(Opaque<bindings::pci_dev>, PhantomData<Ctx>)`. `PhantomData` is
/// zero-sized so the wrapper's memory layout is identical to
/// `Opaque<bindings::pci_dev>`. The cast below reinterprets the
/// `&pci::Device<Ctx>` reference as the layout-equivalent
/// `&Opaque<bindings::pci_dev>` and then calls the documented
/// `Opaque::get()` to obtain the raw pointer. Hardware / C-side
/// invariants on `pci_dev` are upheld by the caller (the lifetime of
/// `pdev` outlives the use of the returned pointer because the C bridge
/// only retains it for the duration of the call or stores it in the
/// `r8125_bridge` private area, whose lifetime is bounded by
/// `r8125_bridge_unregister_and_free`). No memory transfer occurs; the
/// returned pointer is for read access only as far as Rust is concerned.
/// No ring overrun can occur — this call touches no descriptor ring.
pub(crate) fn pci_dev_raw<Ctx: device::DeviceContext>(
    pdev: &pci::Device<Ctx>,
) -> *mut bindings::pci_dev {
    // SAFETY: pci::Device<Ctx> is repr(transparent) over
    // Opaque<bindings::pci_dev> (PhantomData is zero-sized).
    let opaque: &Opaque<bindings::pci_dev> =
        unsafe { &*core::ptr::from_ref(pdev).cast::<Opaque<bindings::pci_dev>>() };
    opaque.get()
}

/// Allocate a net_device + bridge state via the cshim.
///
/// # SAFETY
///
/// - `pdev` is borrowed only for this call; the cshim records the raw
///   pointer in its private area but the kernel guarantees the pci_dev
///   outlives any `net_device` that names it as parent (sysfs links).
/// - `cookie` is opaque to the bridge; it is just the value passed back
///   into every vtable callback. The Rust caller is responsible for
///   ensuring `cookie` outlives the net_device (the skeleton passes
///   null because the stub callbacks do not deref it).
/// - `ops` is read once during alloc (the cshim copies the struct). The
///   function pointers inside MUST have `'static` lifetime — they refer
///   to `extern "C" fn` Rust statics in `crate::netdev`, which do.
/// - `mac` points at 6 bytes of MAC address; we pass a static array.
pub(crate) fn bridge_alloc<Ctx: device::DeviceContext>(
    pdev: &pci::Device<Ctx>,
    cookie: *mut c_void,
    ops: &BridgeOps,
    mac: &[u8; 6],
) -> Result<*mut bindings::net_device> {
    let raw = pci_dev_raw(pdev);
    // SAFETY: arguments meet the contract documented above.
    let ndev = unsafe { r8125_bridge_alloc(raw, cookie, ops, mac.as_ptr()) };
    NonNull::new(ndev).map(NonNull::as_ptr).ok_or(ENOMEM)
}

/// Free an alloc'd-but-not-registered net_device (error path).
///
/// # SAFETY
///
/// Caller must own a net_device returned by `bridge_alloc` that has NOT
/// been passed to `bridge_register`. After this call the pointer is
/// invalid; the caller must not use it again.
pub(crate) fn bridge_free(ndev: *mut bindings::net_device) {
    // SAFETY: see fn-level contract; cshim is the same module that
    // allocated the netdev.
    unsafe { r8125_bridge_free(ndev) };
}

/// Register a net_device with the kernel network stack.
///
/// # SAFETY
///
/// Caller must own a net_device returned by `bridge_alloc`. On success
/// the kernel takes a reference; the caller must arrange for an eventual
/// `bridge_unregister_and_free`.
pub(crate) fn bridge_register(ndev: *mut bindings::net_device) -> Result<()> {
    // SAFETY: see fn-level contract.
    let rc = unsafe { r8125_bridge_register(ndev) };
    to_result(rc)
}

/// Unregister + free a registered net_device. Idempotent only in that
/// the caller must call it exactly once per successful register.
///
/// # SAFETY
///
/// `ndev` must be a registered net_device returned by `bridge_alloc`.
/// After this call the pointer is invalid; the kernel reference is
/// dropped and the underlying memory freed.
pub(crate) fn bridge_unregister_and_free(ndev: *mut bindings::net_device) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_unregister_and_free(ndev) };
}

/// `dev_kfree_skb_any` via the cshim — the "drop_with_error"
/// path. Counter `tx_dropped_error` increments inside the cshim.
///
/// # SAFETY
///
/// `skb` must be a kernel-allocated `sk_buff` to which the driver holds
/// the unique reference (i.e., it was just received from ndo_start_xmit
/// or constructed by the driver). After this call the pointer is
/// invalid. No ring overrun is possible — this call touches no ring.
pub(crate) fn skb_free_error(skb: *mut bindings::sk_buff) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_skb_free_error(skb) };
}

// ── Scatter-gather + TSO safe wrappers (task 49) ────────────────────────

/// Combined TX offload prep. Fills descriptor `opts1`/`opts2` bits and returns
/// the post-mutation fragment count in one FFI crossing.
///
/// Normal TCP/UDP `CHECKSUM_PARTIAL` packets stay on hardware checksum. The C
/// shim only falls back to software checksum for unsupported protocols,
/// transport offsets the hardware cannot encode, ETH_ZLEN padding, or the
/// narrow RTL8125 UDP pad quirk also used by r8169/vendor sources.
///
/// # SAFETY: `skb` is the kernel-allocated buffer just received from
/// ndo_start_xmit. The C side may mutate `skb` (`skb_cow_head` +
/// `tcp_v6_gso_csum_prep` for IPv6 TSO, or pad/software-checksum for the
/// narrow quirk), so callers must run this before DMA mapping.
pub(crate) fn skb_tx_offload_prepare(skb: *mut bindings::sk_buff) -> Result<(u32, u32, u32)> {
    let mut opts1 = 0u32;
    let mut opts2 = 0u32;
    let mut nr_frags = 0u32;
    // SAFETY: see fn-level contract.
    let rc = unsafe {
        r8125_bridge_skb_tx_offload_prepare(
            skb,
            core::ptr::from_mut(&mut opts1),
            core::ptr::from_mut(&mut opts2),
            core::ptr::from_mut(&mut nr_frags),
        )
    };
    to_result(rc)?;
    Ok((opts1, opts2, nr_frags))
}

/// DMA-map the LINEAR head of `skb`. Returns the mapping length on
/// success or `Err(EIO)` on mapping failure.
///
/// # SAFETY: `pdev` is alive (NetdevState holds an ARef); `skb` is
/// just-received from xmit (driver-owned).
pub(crate) fn skb_data_dma_map(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    skb: *mut bindings::sk_buff,
    out_handle: &mut bindings::dma_addr_t,
    out_len: &mut u32,
) -> Result<()> {
    let dev = bridge_dma_device(pdev);
    // SAFETY: see fn-level contract.
    let rc = unsafe {
        r8125_bridge_skb_data_dma_map(
            dev,
            skb,
            core::ptr::from_mut(out_handle),
            core::ptr::from_mut(out_len),
        )
    };
    to_result(rc)
}

/// DMA-map paged fragment `frag_idx` (0..nr_frags-1) of `skb`.
///
/// # SAFETY: as `skb_data_dma_map`. `frag_idx` must be < `nr_frags`
/// — the C side validates and returns -EINVAL otherwise.
pub(crate) fn skb_frag_dma_map(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    skb: *mut bindings::sk_buff,
    frag_idx: u32,
    out_handle: &mut bindings::dma_addr_t,
    out_len: &mut u32,
) -> Result<()> {
    let dev = bridge_dma_device(pdev);
    // SAFETY: see fn-level contract.
    let rc = unsafe {
        r8125_bridge_skb_frag_dma_map(
            dev,
            skb,
            frag_idx,
            core::ptr::from_mut(out_handle),
            core::ptr::from_mut(out_len),
        )
    };
    to_result(rc)
}

/// Consume a TX-completed skb. Bumps netdev stats from `skb->len` and
/// hands the skb to NAPI for recycling. Does NOT unmap DMA — the caller
/// already did per-descriptor unmap in the SG-aware reaper loop.
///
/// # SAFETY: `ndev` is the registered net_device (alive while
/// NetdevHandle lives); `skb` was just removed from the TX shadow and is
/// driver-owned exclusively at this point.
pub(crate) fn skb_consume_tx(
    ndev: *mut bindings::net_device,
    skb: *mut bindings::sk_buff,
) -> usize {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_skb_consume_tx(ndev, skb) as usize }
}

/// Wire length (`skb->len`), read in `ndo_start_xmit` before the skb is
/// handed to the ring, for the BQL `netdev_sent_queue` at the commit point.
///
/// # SAFETY: `skb` is the driver-owned skb passed into `ndo_start_xmit`.
pub(crate) fn skb_len(skb: *const bindings::sk_buff) -> usize {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_skb_len(skb) as usize }
}

/// BQL: seed `dql.min_limit` at ndo_open (Approach A) so the first xmit
/// can't drive `dql_avail` negative (no `netdev_reset_queue`). Idempotent.
///
/// # SAFETY: `ndev` is the registered net_device; called from ndo_open with
/// the TX queue set up.
pub(crate) fn dql_seed_min_limit(ndev: *mut bindings::net_device) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_dql_seed_min_limit(ndev) };
}

/// BQL: feed `bytes` to dql at the xmit commit and return whether the TX
/// doorbell must be rung. This wraps the kernel's `__netdev_sent_queue()`,
/// which accounts batched `xmit_more` packets without setting STACK_XOFF until
/// the batch end, while still forcing a doorbell if the queue is already
/// stopped.
///
/// # SAFETY: `ndev` is the registered net_device.
pub(crate) fn netdev_sent_queue(
    ndev: *mut bindings::net_device,
    bytes: usize,
    xmit_more: bool,
) -> bool {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_netdev_sent_queue(ndev, bytes as c_uint, xmit_more) }
}

/// BQL: feed completed `(pkts, bytes)` to dql once per NAPI TX reap; balances
/// the per-packet `netdev_sent_queue` and auto-wakes the queue.
///
/// # SAFETY: `ndev` is the registered net_device.
pub(crate) fn netdev_completed_queue(ndev: *mut bindings::net_device, pkts: usize, bytes: usize) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_netdev_completed_queue(ndev, pkts as c_uint, bytes as c_uint) };
}

// ── PHY plumbing safe wrappers ───────────────────────────────────────────

/// Register the cshim's MDIO bus + phy_device for this netdev, with the
/// Rust extern "C" callbacks the bus will use for MDIO transactions.
/// Must be called after `bridge_register` succeeds.
///
/// # SAFETY
///
/// `ndev` is a registered net_device returned by `bridge_alloc`. `ops`
/// is borrowed only for the duration of the call (the cshim copies the
/// struct into its bridge state). The `fn` pointers must have `'static`
/// lifetime — they refer to `extern "C" fn` Rust items in `crate::phy`,
/// which do.
pub(crate) fn bridge_phy_register(
    ndev: *mut bindings::net_device,
    ops: &BridgeMdioOps,
) -> Result<()> {
    // SAFETY: see fn-level contract.
    let rc = unsafe { r8125_bridge_phy_register(ndev, ops) };
    to_result(rc)
}

/// Step 1 of PHY bring-up (early, BEFORE MAC OCP init + ChipCmd):
/// phy_connect_direct + phy_init_hw + genphy_soft_reset + phy_resume.
/// On the 8125B's integrated MAC/PHY, genphy_soft_reset writes BMCR_RESET
/// which clobbers ChipCmd; running this early means subsequent MAC init
/// writes stick.
///
/// # SAFETY: `ndev` must be a registered net_device for which
/// `bridge_phy_register` previously returned Ok.
pub(crate) fn bridge_phy_connect_and_reset(ndev: *mut bindings::net_device) -> Result<()> {
    // SAFETY: see fn-level contract.
    let rc = unsafe { r8125_bridge_phy_connect_and_reset(ndev) };
    to_result(rc)
}

/// Step 2 of PHY bring-up (LAST in ndo_open, AFTER ChipCmd + IMR):
/// kicks the PHY state machine and starts autoneg.
///
/// # SAFETY: same as `bridge_phy_connect_and_reset`; must have been
/// called first.
pub(crate) fn bridge_phy_kick_state_machine(ndev: *mut bindings::net_device) -> Result<()> {
    // SAFETY: see fn-level contract.
    let rc = unsafe { r8125_bridge_phy_kick_state_machine(ndev) };
    to_result(rc)
}

/// phy_stop + phy_disconnect — called from ndo_stop.
///
/// # SAFETY: as `bridge_phy_start`. Idempotent if `bridge_phy_start` was
/// never called.
pub(crate) fn bridge_phy_stop(ndev: *mut bindings::net_device) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_phy_stop(ndev) };
}

// PHY errata register access via the phylib paged/MMD accessors. Driven by the
// host-tested `crate::phy_config` table during PHY bring-up (after connect/reset,
// before phy_start). The cshim guards a null phydev; best-effort like r8169.
//
// # SAFETY (all four): `ndev` is the registered net_device; the cshim derives
// b->phydev and no-ops if absent. Called single-threaded during open before the
// PHY state machine is started.
pub(crate) fn phy_modify_paged(
    ndev: *mut bindings::net_device,
    page: u16,
    reg: u16,
    mask: u16,
    set: u16,
) {
    // SAFETY: see block contract.
    unsafe { r8125_bridge_phy_modify_paged(ndev, page, reg, mask, set) };
}

pub(crate) fn phy_write_paged(ndev: *mut bindings::net_device, page: u16, reg: u16, val: u16) {
    // SAFETY: see block contract.
    unsafe { r8125_bridge_phy_write_paged(ndev, page, reg, val) };
}

pub(crate) fn phy_write_mmd(ndev: *mut bindings::net_device, devad: u16, reg: u16, val: u16) {
    // SAFETY: see block contract.
    unsafe { r8125_bridge_phy_write_mmd(ndev, devad, reg, val) };
}

pub(crate) fn phy_modify_mmd(
    ndev: *mut bindings::net_device,
    devad: u16,
    reg: u16,
    mask: u16,
    set: u16,
) {
    // SAFETY: see block contract.
    unsafe { r8125_bridge_phy_modify_mmd(ndev, devad, reg, mask, set) };
}

/// Record the applied PHY MCU firmware version (32-byte version field) for
/// `ethtool -i`. The cshim copies exactly 32 bytes + NUL-terminates.
///
/// # SAFETY: `ndev` is the registered net_device; `ver` points to a 32-byte
/// array (the cshim reads exactly 32 bytes). Called single-threaded at open.
pub(crate) fn set_fw_version(ndev: *mut bindings::net_device, ver: &[u8; 32]) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_set_fw_version(ndev, ver.as_ptr()) };
}

#[inline]
fn errno_to_c_int(e: kernel::error::Error) -> c_int {
    e.to_errno()
}

#[inline]
fn valid_mii_reg(phyreg: c_int) -> bool {
    (0..=31).contains(&phyreg)
}

// ── MDIO callback entry points called from the C `mii_bus` ──────────────
//
// These two `extern "C"` items are passed to the cshim by function pointer
// in `BridgeMdioOps`. They live here because they translate the raw cookie
// back into `&NetdevState`.

/// MDIO read entry point — invoked by `mii_bus->read`. Returns a
/// non-negative `u16` value on success or a negative kernel errno on
/// failure. Reg 0x1F returns the current OCP page.
pub(crate) extern "C" fn r8125_rust_mdio_read(cookie: *mut c_void, phyreg: c_int) -> c_int {
    if cookie.is_null() || !valid_mii_reg(phyreg) {
        return errno_to_c_int(kernel::error::code::EINVAL);
    }
    let state = state_from_cookie(cookie);
    let reg = phyreg as u8;

    if reg == crate::regs::MII_PAGE_SELECT {
        return c_int::from(crate::phy::page_select_read(state));
    }
    match crate::phy::mdio_read(state, reg) {
        Ok(v) => c_int::from(v),
        Err(e) => errno_to_c_int(e),
    }
}

/// MDIO write entry point — invoked by `mii_bus->write`. Returns 0 on
/// success or a negative kernel errno. Writing to reg 0x1F updates the
/// current OCP page selector (no PHY hardware access).
pub(crate) extern "C" fn r8125_rust_mdio_write(
    cookie: *mut c_void,
    phyreg: c_int,
    val: u16,
) -> c_int {
    if cookie.is_null() || !valid_mii_reg(phyreg) {
        return errno_to_c_int(kernel::error::code::EINVAL);
    }
    let state = state_from_cookie(cookie);
    let reg = phyreg as u8;

    if reg == crate::regs::MII_PAGE_SELECT {
        crate::phy::page_select_write(state, val);
        return 0;
    }
    match crate::phy::mdio_write(state, reg, val) {
        Ok(()) => 0,
        Err(e) => errno_to_c_int(e),
    }
}

/// MDIO C45 read entry point — invoked by `mii_bus->read_c45`. For
/// `MDIO_MMD_VEND2` with `phyreg > MDIO_STAT2` it reads the chip's PHY
/// OCP register at `phyreg` directly (no `OCP_STD_PHY_BASE` offset —
/// `phyreg` IS the OCP address). Other combinations return 0, matching
/// r8169 `r8169_mdio_read_reg_c45`. Required so the dedicated Realtek
/// NBASE-T PHY driver's `rtl822x_hwmon_init` (clears MMD VEND2 thermal-
/// alarm bits) and `rtl822x_get_features` (reads `RTL_MDIO_PMA_SPEED`
/// for 2.5G capability) work, unblocking 2.5G negotiation.
pub(crate) extern "C" fn r8125_rust_mdio_read_c45(
    cookie: *mut c_void,
    devad: c_int,
    phyreg: c_int,
) -> c_int {
    if cookie.is_null() {
        return errno_to_c_int(kernel::error::code::EINVAL);
    }
    if devad == crate::regs::MDIO_MMD_VEND2 && phyreg > crate::regs::MDIO_STAT2 {
        let state = state_from_cookie(cookie);
        match state.regs().gphy_ocp_read(phyreg as u32) {
            Ok(v) => c_int::from(v),
            Err(e) => errno_to_c_int(e),
        }
    } else {
        0
    }
}

/// MDIO C45 write entry point — `mii_bus->write_c45`. Same routing as
/// `r8125_rust_mdio_read_c45`: only `MDIO_MMD_VEND2 + phyreg > MDIO_STAT2`
/// reaches the chip (direct OCP write at `phyreg`). Other combinations
/// return `-ENODEV`, matching r8169.
pub(crate) extern "C" fn r8125_rust_mdio_write_c45(
    cookie: *mut c_void,
    devad: c_int,
    phyreg: c_int,
    val: u16,
) -> c_int {
    if cookie.is_null() {
        return errno_to_c_int(kernel::error::code::EINVAL);
    }
    if devad == crate::regs::MDIO_MMD_VEND2 && phyreg > crate::regs::MDIO_STAT2 {
        let state = state_from_cookie(cookie);
        match state.regs().gphy_ocp_write(phyreg as u32, val) {
            Ok(()) => 0,
            Err(e) => errno_to_c_int(e),
        }
    } else {
        errno_to_c_int(kernel::error::code::ENODEV)
    }
}
