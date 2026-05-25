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
use kernel::dma::{Device as DmaDevice, DmaMask};
use kernel::error::{to_result, Result};
use kernel::pci;
use kernel::prelude::*;
use kernel::transmute::{AsBytes, FromBytes};
use kernel::types::Opaque;

use crate::netdev::{NetdevHandle, NetdevState, RxBuffer};
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

// ───────────────────────────────────────────────────────────────────────
// M4 — Rust ↔ C bridge FFI declarations + safe wrappers
//
// The C side lives in `src/netdev_bridge.c`; the contract is in
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
    fn r8125_bridge_napi(ndev: *mut bindings::net_device) -> *mut bindings::napi_struct;
    fn r8125_bridge_tx_stop_queue(ndev: *mut bindings::net_device);
    fn r8125_bridge_tx_wake_queue(ndev: *mut bindings::net_device);
    fn r8125_bridge_tx_disable(ndev: *mut bindings::net_device);
    fn r8125_bridge_carrier_on(ndev: *mut bindings::net_device);
    fn r8125_bridge_carrier_off(ndev: *mut bindings::net_device);

    fn r8125_bridge_skb_dma_map_tx(
        dev: *mut bindings::device,
        skb: *mut bindings::sk_buff,
        out_handle: *mut bindings::dma_addr_t,
        out_len: *mut usize,
    ) -> c_int;
    fn r8125_bridge_skb_dma_unmap_tx(
        dev: *mut bindings::device,
        handle: bindings::dma_addr_t,
        len: usize,
    );
    fn r8125_bridge_skb_complete_tx(
        dev: *mut bindings::device,
        handle: bindings::dma_addr_t,
        len: usize,
        skb: *mut bindings::sk_buff,
    );
    fn r8125_bridge_tx_busy_exception(ndev: *mut bindings::net_device);
    fn r8125_bridge_skb_build_rx(
        ndev: *mut bindings::net_device,
        buf: *const c_void,
        len: usize,
    ) -> *mut bindings::sk_buff;
    fn r8125_bridge_skb_deliver_rx(
        napi: *mut bindings::napi_struct,
        skb: *mut bindings::sk_buff,
    );
    fn r8125_bridge_rx_drop_error(ndev: *mut bindings::net_device);
}

// SAFETY: `NetdevHandle` wraps a raw `*mut bindings::net_device` from
// the cshim's `r8125_bridge_alloc`. The underlying `net_device` is a
// kernel object whose lifetime is managed by register/unregister; the
// kernel net stack is thread-safe by design (RTNL + queue locks), so
// moving the handle between threads is sound. No memory is transferred
// by Send; no ring overrun is possible.
unsafe impl Send for NetdevHandle {}

// SAFETY: `NetdevState` holds raw pointers (`bar_ptr`, `tx_desc`, `rx_desc`)
// into kernel-owned mappings whose lifetimes outlive NetdevState (BAR is
// pinned via Devres in R8125Driver, descriptor rings are owned by
// CoherentAllocation fields in R8125Driver that drop after NetdevState).
// Cross-context fields (head/tail/shadow) are atomics. Static fields are
// read-only after probe. CoherentAllocation in `rx_bufs` is sound to share
// because hardware writes are serialised by the OWN-bit handshake. NAPI is
// the only context that mutates rx_tail / tx_tail; xmit is the only one
// that mutates tx_head. Sharing across threads is therefore safe.
unsafe impl Send for NetdevState {}
unsafe impl Sync for NetdevState {}

// SAFETY: `RxBuffer` is `#[repr(C, align(64))]` containing only `[u8; N]`.
// Every bit pattern is a valid RxBuffer; no uninitialized padding.
unsafe impl AsBytes for RxBuffer {}
unsafe impl FromBytes for RxBuffer {}

// ── Safe wrappers — M4-full hot path ──────────────────────────────────────

/// Enable bus-mastering. Kernel API method is safe but lives on
/// `pci::Device<Core>` only; we re-expose it from a `&ARef<pci::Device>`
/// for `ndo_open`'s convenience.
pub(crate) fn pci_set_master(_pdev: &kernel::sync::aref::ARef<pci::Device>) {
    // ARef<pci::Device> derefs to pci::Device<Normal>; set_master needs Core.
    // SAFETY: The bound pci_dev is alive (ARef keeps a refcount); pci_set_master
    // takes a *mut pci_dev and is sound to call any time the device exists.
    let raw = pci_dev_raw_from_aref(_pdev);
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
        unsafe { &*(p as *const pci::Device as *const Opaque<bindings::pci_dev>) };
    opaque.get()
}

/// `request_threaded_irq(handler=fn, thread_fn=NULL, IRQF_SHARED, name, cookie)`.
pub(crate) fn request_irq(
    irq: u32,
    handler: unsafe extern "C" fn(c_int, *mut c_void) -> bindings::irqreturn_t,
    cookie: *mut c_void,
) -> Result<()> {
    // SAFETY: handler is a fixed Rust extern "C" fn; cookie outlives the IRQ
    // registration (NetdevState lives until NetdevHandle drops, which only
    // happens after ndo_stop has free_irq'd). Shared INTx is the M4 baseline.
    let rc = unsafe {
        bindings::request_threaded_irq(
            irq,
            Some(handler),
            None,
            bindings::IRQF_SHARED as usize,
            c"r8125_rust".as_ptr() as *const u8,
            cookie,
        )
    };
    to_result(rc)
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

/// Read the IRQ number from `pci_dev->irq`.
pub(crate) fn pci_dev_irq<Ctx: device::DeviceContext>(pdev: &pci::Device<Ctx>) -> u32 {
    let raw = pci_dev_raw(pdev);
    // SAFETY: pdev is a borrowed reference to a valid pci_dev; the `irq`
    // field is a simple unsigned int populated by the kernel at probe.
    unsafe { (*raw).irq }
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

/// Write one hardware descriptor at `ring[idx]` (volatile).
pub(crate) fn desc_write(ring: *mut Descriptor, idx: usize, value: Descriptor) {
    // SAFETY: as `desc_read`. The volatile pairs with the device's MMIO
    // read of the descriptor after we kick TX (or after hardware re-reads
    // an OWN-set RX slot).
    unsafe {
        core::ptr::write_volatile(ring.add(idx), value);
    }
}

/// Pointer to RX slot `idx`'s CPU-readable buffer base. Caller must
/// dereference for `[u8; RX_BUF_LEN]` (not done here — keeps the unsafe
/// at the boundary).
pub(crate) fn rx_buf_ptr(
    bufs: &kernel::dma::CoherentAllocation<RxBuffer>,
    idx: usize,
) -> *const c_void {
    let start = bufs.start_ptr();
    // SAFETY: idx < count() guaranteed by caller (NAPI walks 0..RING_LEN).
    let slot_ptr = unsafe { start.add(idx) };
    slot_ptr as *const c_void
}

// ── sk_buff helpers — safe wrappers, counters live inside the cshim ──────

pub(crate) fn skb_dma_map_tx(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    skb: *mut bindings::sk_buff,
    out_handle: &mut bindings::dma_addr_t,
    out_len: &mut usize,
) -> Result<()> {
    // SAFETY: dev comes from pdev (alive via ARef); skb is a kernel-allocated
    // pointer we just received from ndo_start_xmit; out pointers point at
    // local stack slots.
    let dev = bridge_dma_device(pdev);
    let rc = unsafe { r8125_bridge_skb_dma_map_tx(dev, skb, out_handle as *mut _, out_len as *mut _) };
    to_result(rc)
}

pub(crate) fn skb_dma_unmap_tx(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    handle: bindings::dma_addr_t,
    len: usize,
) {
    let dev = bridge_dma_device(pdev);
    // SAFETY: handle/len came from a prior successful skb_dma_map_tx.
    unsafe { r8125_bridge_skb_dma_unmap_tx(dev, handle, len) };
}

pub(crate) fn skb_complete_tx(
    pdev: &kernel::sync::aref::ARef<pci::Device>,
    handle: bindings::dma_addr_t,
    len: usize,
    skb: *mut bindings::sk_buff,
) {
    let dev = bridge_dma_device(pdev);
    // SAFETY: skb was stored by ndo_start_xmit; handle/len from the same
    // map call. Cshim consumes via napi_consume_skb.
    unsafe { r8125_bridge_skb_complete_tx(dev, handle, len, skb) };
}

pub(crate) fn tx_busy_exception(ndev: *mut bindings::net_device) {
    // SAFETY: ndev is alive and registered while ndo_start_xmit runs.
    unsafe { r8125_bridge_tx_busy_exception(ndev) };
}

pub(crate) fn skb_build_rx(
    ndev: *mut bindings::net_device,
    buf: *const c_void,
    len: usize,
) -> *mut bindings::sk_buff {
    // SAFETY: cshim copies `len` bytes from `buf`; we guarantee
    // `buf..buf+len` is CPU-readable and `len <= RX_BUF_LEN`.
    unsafe { r8125_bridge_skb_build_rx(ndev, buf, len) }
}

pub(crate) fn skb_deliver_rx(napi: *mut bindings::napi_struct, skb: *mut bindings::sk_buff) {
    // SAFETY: napi is the bridge's napi_struct (still alive in the poll
    // call); skb was just built by skb_build_rx — driver-owned.
    unsafe { r8125_bridge_skb_deliver_rx(napi, skb) };
}

pub(crate) fn rx_drop_error(ndev: *mut bindings::net_device) {
    // SAFETY: ndev is alive and registered while NAPI poll runs.
    unsafe { r8125_bridge_rx_drop_error(ndev) };
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

pub(crate) fn bridge_napi(ndev: *mut bindings::net_device) -> *mut bindings::napi_struct {
    // SAFETY: cshim returns &napi_struct embedded in the bridge state
    // which has the same lifetime as the netdev.
    unsafe { r8125_bridge_napi(ndev) }
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

pub(crate) fn bridge_carrier_on(ndev: *mut bindings::net_device) {
    // SAFETY: ndev alive.
    unsafe { r8125_bridge_carrier_on(ndev) };
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
        unsafe { &*(pdev as *const pci::Device<Ctx> as *const Opaque<bindings::pci_dev>) };
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
