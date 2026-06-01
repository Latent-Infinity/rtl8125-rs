// SPDX-License-Identifier: GPL-2.0
//! The single permitted home for `unsafe` in this crate (plan §6.2).
//!
//! Crate root carries `#![deny(unsafe_code)]`; this module locally lifts that
//! by `#![allow(unsafe_code)]`. CI (`ci/check_unsafe_allowlist.sh`) refuses
//! any other file that locally allows `unsafe_code` unless it is named in
//! `.unsafe-allowlist` — and this is the only entry there.
//!
//! Every block carries a `// SAFETY:` comment that states (plan §6.2):
//!  - which hardware or C-side invariant is being relied on;
//!  - who currently owns the memory (CPU vs. device);
//!  - what ordering / barrier requirement applies;
//!  - why use-after-free is impossible;
//!  - why ring overrun is impossible.
//!
//! AI-generated patches that touch this file get the strictest human review.
//!
//! ## M2 status
//!
//! Empty — the kernel `pci`, `io::mem`, `devres`, and `time::delay` APIs
//! covered every M2 register-layer need in safe Rust.
//!
//! ## M3 status
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

use core::ffi::{c_int, c_void};
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
use crate::ring::Descriptor;

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
/// Other §6.2 facets:
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

// The task #58 stack-overflow fix uses `KBox::init` with
// `init_array_from_fn` to populate the giant 256-slot atomic arrays in
// `NetdevState` directly on the heap. No `Zeroable` impl is needed for
// our atomic types because `init_array_from_fn` constructs each element
// from a closure-returned value via the `impl<T> Init<T> for T` blanket
// (any value is its own one-shot initializer). See `pci.rs::probe`.

// ───────────────────────────────────────────────────────────────────────
// M4 — Rust ↔ C bridge FFI declarations + safe wrappers
//
// The C side lives in `src/netdev_bridge*.c`; the contract is in
// `src/netdev_bridge.h`. Everything here is mechanical glue:
//   - the function-pointer table the Rust side hands to the C bridge
//     (`BridgeOps` — `#[repr(C)]` matches `struct r8125_bridge_ops`),
//   - `extern "C"` declarations for the cshim entry points,
//   - safe Rust wrappers each with a `// SAFETY:` block per §6.2.
// ───────────────────────────────────────────────────────────────────────

/// Rust mirror of `struct r8125_bridge_ops` — same layout, same ABI.
/// Allow non-CamelCase only for the `priv` field name parity is moot:
/// we use `BridgeOps` in Rust and don't need to name the parameter.
#[repr(C)]
pub(crate) struct BridgeOps {
    pub open: extern "C" fn(cookie: *mut c_void) -> c_int,
    pub stop: extern "C" fn(cookie: *mut c_void),
    pub xmit: extern "C" fn(cookie: *mut c_void, skb: *mut bindings::sk_buff) -> c_int,
    pub poll: extern "C" fn(cookie: *mut c_void, budget: c_int) -> c_int,
    pub change_mtu: extern "C" fn(cookie: *mut c_void, new_mtu: c_int) -> c_int,
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

    fn r8125_bridge_napi_schedule(ndev: *mut bindings::net_device);
    fn r8125_bridge_napi_complete_done(ndev: *mut bindings::net_device, work_done: c_int);
    fn r8125_bridge_irq_pin_cpu(irq: u32, cpu: c_int) -> c_int;
    fn r8125_bridge_irq_pin_auto(
        pdev: *mut bindings::pci_dev,
        irq: u32,
        out_cpu: *mut c_int,
    ) -> c_int;
    fn r8125_bridge_dma_rmb();
    fn r8125_bridge_dma_wmb();
    fn r8125_bridge_tx_stop_queue(ndev: *mut bindings::net_device);
    fn r8125_bridge_tx_wake_queue(ndev: *mut bindings::net_device);
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

    // ── HW checksum offload + stats (M4-perf, task 48) ──────────────────
    fn r8125_bridge_skb_tx_csum_opts(skb: *mut bindings::sk_buff) -> u32;

    // ── Scatter-gather + TSO (M4-perf phase 2, task 49) ─────────────────
    fn r8125_bridge_skb_nr_frags(skb: *mut bindings::sk_buff) -> u32;
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
    fn r8125_bridge_skb_tso_setup(
        skb: *mut bindings::sk_buff,
        out_opts1: *mut u32,
        out_opts2: *mut u32,
    ) -> bool;
    fn r8125_bridge_skb_consume_tx(
        ndev: *mut bindings::net_device,
        skb: *mut bindings::sk_buff,
    );

    // ── PHY plumbing (M4-traffic) ────────────────────────────────────────
    fn r8125_bridge_phy_register(
        ndev: *mut bindings::net_device,
        ops: *const BridgeMdioOps,
    ) -> c_int;
    fn r8125_bridge_phy_connect_and_reset(ndev: *mut bindings::net_device) -> c_int;
    fn r8125_bridge_phy_kick_state_machine(ndev: *mut bindings::net_device) -> c_int;
    fn r8125_bridge_phy_stop(ndev: *mut bindings::net_device);

    // ── Jumbo RX-pool (M6 #2) — per-slot streaming-DMA pages ───────────
    fn r8125_bridge_rx_alloc_jumbo(
        dev: *mut bindings::device,
        out_cpu: *mut *mut c_void,
        out_dma: *mut bindings::dma_addr_t,
    ) -> c_int;
    fn r8125_bridge_rx_free_jumbo(
        dev: *mut bindings::device,
        cpu: *mut c_void,
        dma: bindings::dma_addr_t,
    );

    // RX super-call (Candidate B, RX_OPTIMIZATION_CANDIDATES.md §B).
    // Collapses 5 per-packet FFI crossings into 1. On allocation
    // failure, the cshim bumps rx_dropped_error and re-syncs for device.
    fn r8125_bridge_rx_one_packet(
        ndev: *mut bindings::net_device,
        dma: bindings::dma_addr_t,
        buf: *const core::ffi::c_void,
        len: usize,
        desc_opts1: u32,
    );
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
    pub write_c45: extern "C" fn(
        priv_: *mut c_void,
        devad: c_int,
        phyreg: c_int,
        val: u16,
    ) -> c_int,
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

// ── Safe wrappers — M4-full hot path ──────────────────────────────────────

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
fn pci_dev_raw_from_aref(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
) -> *mut bindings::pci_dev {
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

// ── PCI IRQ vector allocation (M6 #1 Phase A.2) ──────────────────────────
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

// ── Jumbo RX-pool safe wrappers (M6 #2) ──────────────────────────────────
//
// Each `RxSlot` holds one streaming-DMA-mapped 16 KiB page chunk from
// `r8125_bridge_rx_alloc_jumbo`. The pool's lifecycle is ndo_open
// (allocate per slot) → ndo_stop (free per slot); see
// `src/netdev_bridge_rx_pool.c` for the discipline.

/// Allocate one jumbo-sized RX slot. Returns `(cpu, dma)` on success.
///
/// # SAFETY contract
///
/// `pdev` is alive (ARef holds the refcount). The cshim's
/// `r8125_bridge_rx_alloc_jumbo` allocates one 16 KiB page chunk + DMA
/// maps it `FROM_DEVICE`; on failure no resource is leaked. The caller
/// MUST eventually balance every successful alloc with `rx_free_jumbo`.
pub(crate) fn rx_alloc_jumbo(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
) -> Result<(*mut c_void, bindings::dma_addr_t)> {
    let dev = bridge_dma_device(pdev);
    let mut cpu: *mut c_void = core::ptr::null_mut();
    let mut dma: bindings::dma_addr_t = 0;
    // SAFETY: see fn-level contract; out-pointers are stack locals,
    // valid for the duration of the call.
    let rc = unsafe {
        r8125_bridge_rx_alloc_jumbo(
            dev,
            core::ptr::from_mut(&mut cpu),
            core::ptr::from_mut(&mut dma),
        )
    };
    to_result(rc)?;
    Ok((cpu, dma))
}

/// Release one slot acquired via `rx_alloc_jumbo`. Idempotent against
/// a null `cpu` pointer (the cshim short-circuits) so the rollback
/// path in `ndo_open` can call this on partially-acquired state.
pub(crate) fn rx_free_jumbo(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    cpu: *mut c_void,
    dma: bindings::dma_addr_t,
) {
    let dev = bridge_dma_device(pdev);
    // SAFETY: `cpu`/`dma` are either both null (no-op) or the values
    // returned from a prior `rx_alloc_jumbo` on the same `pdev`.
    unsafe { r8125_bridge_rx_free_jumbo(dev, cpu, dma) };
}

/// RX super-call: sync_for_cpu + skb build + csum set + napi_gro_receive +
/// sync_for_device, all inside one cshim function. Saves 4 FFI crossings
/// per RX packet vs the previous Rust-side chain. See
/// `docs/RX_OPTIMIZATION_CANDIDATES.md` §B.
///
/// # SAFETY: `ndev` is the registered net_device (lifetime via
/// `NetdevHandle`); `dma` came from a prior `rx_alloc_jumbo`; `buf`
/// is the slot's CPU-side virtual address from the same allocation;
/// `len` ≤ chip-reported frame length, ≤ `JUMBO_16K_BYTES`.
/// Callable only from NAPI poll context.
pub(crate) fn bridge_rx_one_packet(
    ndev: *mut bindings::net_device,
    dma: bindings::dma_addr_t,
    buf: *const core::ffi::c_void,
    len: usize,
    desc_opts1: u32,
) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_rx_one_packet(ndev, dma, buf, len, desc_opts1) };
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
pub(crate) fn desc_publish_own(ring: *mut Descriptor, idx: usize, value: Descriptor) {
    // SAFETY: caller guarantees idx < N+1 of the ring this pointer indexes.
    // These are descriptor-ring volatile writes, not MMIO. `dma_wmb()` is the
    // device-ordering boundary between the non-OWN fields and the OWN publish.
    unsafe {
        let desc = ring.add(idx);
        core::ptr::addr_of_mut!((*desc).addr).write_volatile(value.addr);
        core::ptr::addr_of_mut!((*desc).opts2).write_volatile(value.opts2);
        dma_wmb();
        core::ptr::addr_of_mut!((*desc).opts1).write_volatile(value.opts1);
    }
}

// `rx_buf_ptr` was removed alongside the M6 #2 jumbo refactor. NAPI now
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

pub(crate) fn bridge_napi_schedule(ndev: *mut bindings::net_device) {
    // SAFETY: ndev is alive (registered until NetdevHandle drops).
    unsafe { r8125_bridge_napi_schedule(ndev) };
}

pub(crate) fn bridge_napi_complete_done(ndev: *mut bindings::net_device, work_done: c_int) {
    // SAFETY: as above; called from NAPI poll context which guarantees the
    // napi_struct is valid.
    unsafe { r8125_bridge_napi_complete_done(ndev, work_done) };
}

/// Suggest IRQ CPU affinity for the chip's MSI-X / MSI / INTx vector.
/// Latency-aligned default (Candidate L of
/// `docs/RX_OPTIMIZATION_CANDIDATES.md`). Best-effort: the kernel may
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

/// Pick the first online CPU on `pdev`'s NUMA node and pin `irq`
/// there. Returns `(rc, cpu)` — `rc == 0` means success and `cpu`
/// is the CPU that was actually chosen (useful for the dmesg log).
/// Candidate #4 of `docs/RX_OPTIMIZATION_CANDIDATES.md`.
///
/// # SAFETY: as `bridge_irq_pin_cpu` plus: `pdev` must be a live
/// `pci_dev` (the caller is probe-time, so probe's
/// `pci::Device<Bound>` guarantees this).
pub(crate) fn bridge_irq_pin_auto(
    pdev: *mut bindings::pci_dev,
    irq: u32,
) -> (c_int, c_int) {
    let mut cpu_chosen: c_int = -1;
    // SAFETY: see fn-level contract.
    let rc = unsafe { r8125_bridge_irq_pin_auto(pdev, irq, &mut cpu_chosen) };
    (rc, cpu_chosen)
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
/// see Candidate #1 of `docs/RX_OPTIMIZATION_CANDIDATES.md`.
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

pub(crate) fn bridge_tx_disable(ndev: *mut bindings::net_device) {
    // SAFETY: ndev alive.
    unsafe { r8125_bridge_tx_disable(ndev) };
}

pub(crate) fn bridge_carrier_off(ndev: *mut bindings::net_device) {
    // SAFETY: ndev alive.
    unsafe { r8125_bridge_carrier_off(ndev) };
}

fn bridge_dma_device(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
) -> *mut bindings::device {
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
///   ensuring `cookie` outlives the net_device (M4-skeleton passes
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

/// `dev_kfree_skb_any` via the cshim — plan §6.3 (c) "drop_with_error"
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

// ── HW checksum offload + stats safe wrappers (M4-perf, task 48) ────────

/// Returns the `opts2` bits to OR into the TX descriptor for HW CSUM,
/// or 0 to leave the descriptor unannotated (kernel did SW CSUM, or no
/// CSUM requested). For short UDP frames hitting the chip errata, the
/// cshim falls back to `skb_checksum_help` internally and returns 0. If
/// that software fallback fails, it returns [`crate::regs::TX_CSUM_OPTS_DROP`]
/// and the caller must drop the skb before DMA mapping.
///
/// # SAFETY: `skb` is the kernel-allocated buffer we just received from
/// ndo_start_xmit — alive and exclusively owned by the driver right now.
pub(crate) fn skb_tx_csum_opts(skb: *mut bindings::sk_buff) -> u32 {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_skb_tx_csum_opts(skb) }
}

// ── Scatter-gather + TSO safe wrappers (M4-perf phase 2, task 49) ───────

/// Number of paged fragments in `skb` (0 if linear-only). The Rust TX
/// path uses this to decide how many descriptors to post.
///
/// # SAFETY: `skb` is the kernel-allocated buffer just received from
/// ndo_start_xmit — alive and driver-owned at this moment.
pub(crate) fn skb_nr_frags(skb: *mut bindings::sk_buff) -> u32 {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_skb_nr_frags(skb) }
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
) {
    // SAFETY: see fn-level contract.
    unsafe { r8125_bridge_skb_consume_tx(ndev, skb) };
}

/// TSO descriptor-bit setup. Returns `Some((opts1_bits, opts2_bits))`
/// if the skb is a TCPv4/v6 GSO super-skb, `None` otherwise (caller
/// uses plain CSUM bits instead).
///
/// # SAFETY: `skb` is the kernel-allocated buffer just received from
/// ndo_start_xmit. The C side may mutate `skb` (calls `skb_cow_head`
/// + `tcp_v6_gso_csum_prep` for IPv6 TSO), but only on skbs the driver
///
/// owns exclusively.
pub(crate) fn skb_tso_setup(skb: *mut bindings::sk_buff) -> Option<(u32, u32)> {
    let mut opts1 = 0u32;
    let mut opts2 = 0u32;
    // SAFETY: see fn-level contract.
    let active = unsafe {
        r8125_bridge_skb_tso_setup(
            skb,
            core::ptr::from_mut(&mut opts1),
            core::ptr::from_mut(&mut opts2),
        )
    };
    if active {
        Some((opts1, opts2))
    } else {
        None
    }
}

// ── PHY plumbing safe wrappers (M4-traffic) ──────────────────────────────

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
pub(crate) fn bridge_phy_connect_and_reset(
    ndev: *mut bindings::net_device,
) -> Result<()> {
    // SAFETY: see fn-level contract.
    let rc = unsafe { r8125_bridge_phy_connect_and_reset(ndev) };
    to_result(rc)
}

/// Step 2 of PHY bring-up (LAST in ndo_open, AFTER ChipCmd + IMR):
/// kicks the PHY state machine and starts autoneg.
///
/// # SAFETY: same as `bridge_phy_connect_and_reset`; must have been
/// called first.
pub(crate) fn bridge_phy_kick_state_machine(
    ndev: *mut bindings::net_device,
) -> Result<()> {
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
pub(crate) extern "C" fn r8125_rust_mdio_read(
    cookie: *mut c_void,
    phyreg: c_int,
) -> c_int {
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
