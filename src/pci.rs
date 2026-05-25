// SPDX-License-Identifier: GPL-2.0
//! PCI bring-up for the RTL8125 — plan §7 M1 + M2.
//!
//! - **M1**: registers the driver for VID `0x10EC` / DID `0x8125`, enables
//!   memory decoding, maps BAR2 (the 64 KiB MMIO MAC-register window per
//!   lspci), logs vendor/device/revision.
//! - **M2**: after the BAR is mapped, identifies the chip from `TxConfig`
//!   (refuses unknown sub-revisions — *no silent fallback*), runs the
//!   r8169-style reset sequence with timeout, and logs the PCIe ASPM
//!   capabilities. The `inject_reset_timeout` module parameter exercises
//!   the failure-injection path required by the §7 M2 gate.
//!
//! Devres + ARef handle every teardown — including on the probe error paths,
//! which the plan calls out as the "failed reset path is recoverable"
//! contract (other drivers can rebind the device cleanly).

use kernel::{
    device::Core,
    devres::Devres,
    error::code::ENODEV,
    pci,
    prelude::*,
    sync::aref::ARef,
};

use core::sync::atomic::AtomicPtr;

use crate::hw;
use crate::mmio::{self, Regs};
use crate::netdev::{NetdevHandle, NetdevState, RxBuffer};
use crate::pm;
use crate::ring::{self, Ring, RING_LEN};
use crate::unsafe_boundary;

/// Realtek's PCI Vendor ID is exposed as [`pci::Vendor::REALTEK`] (0x10EC);
/// the device ID for the entire RTL8125 family is `0x8125`.
const RTL8125_DEVICE_ID: u32 = 0x8125;

/// MMIO BAR index — BAR2 is the 64-bit, 64 KiB MAC register region per the
/// captured `lspci -vv` on the validated MS-A2 unit. BAR0 is the legacy I/O
/// alias; BAR4 is the MSI-X table — neither is what we want to map.
const R8125_MMIO_BAR: u32 = 2;

/// Per-device-ID payload. M1/M2 have no per-ID dispatch — the per-revision
/// dispatch table lives in `hw.rs` and is matched at runtime against
/// `TxConfig` XID. `IdInfo = ()` keeps the table minimal.
type IdInfo = ();

kernel::pci_device_table!(
    PCI_TABLE,
    MODULE_PCI_TABLE,
    <R8125Driver as pci::Driver>::IdInfo,
    [(
        pci::DeviceId::from_id(pci::Vendor::REALTEK, RTL8125_DEVICE_ID),
        (),
    )]
);

/// Per-device driver state.
///
/// **Drop order matters.** Rust drops struct fields in **declaration order**
/// (top → bottom), per the Reference. `_netdev` MUST be first: its Drop
/// triggers `r8125_bridge_unregister_and_free` → kernel `ndo_stop` → Rust
/// `rust_stop`, which reads `bar_ptr` / `tx_desc` / `rx_desc`. Those must
/// still be live during that callback, so `_bar` + `tx_ring` + `rx_ring`
/// have to drop AFTER `_netdev`. Then `pdev` (just a refcount) last.
///
/// Historical: 2026-05-25 M4-full first cut crashed with a KASAN slab-UAF
/// in `rust_stop+0x80` because this struct previously listed `_netdev`
/// last, with a doc comment that wrongly claimed Rust drops fields in
/// reverse. See `src/netdev.rs` M4_FULL_OPS comment block.
///
/// - `_netdev` — RAII for the registered net_device + boxed NetdevState.
///   Drop fires `r8125_bridge_unregister_and_free` (kernel synchronously
///   runs `ndo_stop`, releases IRQ, disables NAPI) then frees the KBox.
/// - `_bar` — [`Devres`]-owned MMIO mapping; on drop calls `iounmap` +
///   `pci_release_region`.
/// - `tx_ring`, `rx_ring` — M3 cold DMA descriptor rings (`RING_LEN + 1`
///   each, +1 tail canary). On drop, `dma_free_coherent` runs.
/// - `pdev` — [`ARef`] keeps the underlying `struct pci_dev` alive for
///   the whole bound period. Drops last.
///
/// No explicit `PinnedDrop` impl — that would be an `unsafe impl`, which
/// the crate-root `#![deny(unsafe_code)]` rejects. Field-level drop does
/// the teardown; M1/M2/M3/M4 gates have verified it under kmemleak +
/// lockdep + KASAN.
#[pin_data]
pub(crate) struct R8125Driver {
    /// M4 net_device — must drop FIRST. See struct-level docs.
    _netdev: NetdevHandle,
    #[pin]
    _bar: Devres<pci::Bar<{ mmio::R8125_MMIO_LEN }>>,
    tx_ring: Ring<{ ring::RING_LEN }>,
    rx_ring: Ring<{ ring::RING_LEN }>,
    pdev: ARef<pci::Device>,
}

impl pci::Driver for R8125Driver {
    type IdInfo = IdInfo;
    const ID_TABLE: pci::IdTable<Self::IdInfo> = &PCI_TABLE;

    fn probe(pdev: &pci::Device<Core>, _info: &Self::IdInfo) -> impl PinInit<Self, Error> {
        pin_init::pin_init_scope(move || {
            dev_info!(
                pdev,
                "RTL8125 probe: vendor={} device=0x{:04x} rev=0x{:02x}\n",
                pdev.vendor_id(),
                pdev.device_id(),
                pdev.revision_id()
            );

            // M1: enable memory decoding before claiming the BAR mapping.
            pdev.enable_device_mem()?;

            // M3: set 64-bit DMA mask BEFORE any coherent allocation. Wraps
            // the kernel-Rust `unsafe fn dma_set_mask_and_coherent`; the
            // SAFETY contract lives in `unsafe_boundary::set_64bit_dma_mask`.
            unsafe_boundary::set_64bit_dma_mask(pdev)?;

            // Reset-timeout failure-injection knob (plan §7 M2 gate). Read
            // once at probe entry so the value is consistent through the
            // BAR-mapping + reset flow inside the init scope below.
            let inject_timeout =
                *crate::module_parameters::inject_reset_timeout.value() != 0;

            Ok(try_pin_init!(Self {
                _bar <- pdev.iomap_region_sized::<{ mmio::R8125_MMIO_LEN }>(
                    R8125_MMIO_BAR,
                    c"r8125_rust",
                ),
                _: {
                    // Field init order matters: `_bar` is now initialized; we
                    // can take a temporary `&pci::Bar` through `Devres::access`
                    // and drive the M2 register-layer work. If any step here
                    // returns `Err`, the in-flight init drops `_bar`'s Devres
                    // → `iounmap` + `pci_release_region`, and the device is
                    // left in a state where r8169 can rebind cleanly.
                    let bar = _bar.access(pdev.as_ref())?;
                    let regs = Regs::new(bar);

                    let info = hw::identify(&regs).ok_or_else(|| {
                        let xid = hw::xid_from_tx_config(regs.tx_config());
                        dev_err!(
                            pdev,
                            "unknown RTL8125 sub-revision: XID=0x{:03x} — refusing to bind (no silent fallback, plan §7 M2)\n",
                            xid
                        );
                        ENODEV
                    })?;
                    dev_info!(
                        pdev,
                        "RTL8125 chip identified: {} (MAC version {:?})\n",
                        info.name,
                        info.mac_version
                    );

                    hw::reset(&regs, inject_timeout).map_err(|e| {
                        let cmd = regs.chip_cmd();
                        dev_err!(
                            pdev,
                            "RTL8125 reset timeout (inject={}, ChipCmd=0x{:02x} after 10ms) — releasing device for rebind\n",
                            inject_timeout,
                            cmd
                        );
                        e
                    })?;
                    dev_info!(pdev, "RTL8125 reset OK\n");

                    pm::log_aspm(pdev);
                },
                tx_ring: Ring::<{ ring::RING_LEN }>::new(pdev.as_ref())?,
                rx_ring: Ring::<{ ring::RING_LEN }>::new(pdev.as_ref())?,
                _: {
                    // M3 cold-ring sanity.
                    tx_ring.verify_canaries()?;
                    rx_ring.verify_canaries()?;
                    dev_info!(
                        pdev,
                        "DMA rings allocated: TX dma=0x{:016x} RX dma=0x{:016x} ({} descriptors each, +1 tail canary)\n",
                        tx_ring.dma_handle(),
                        rx_ring.dma_handle(),
                        ring::RING_LEN
                    );
                },
                // M4-full: read real MAC from IDR0..IDR5; build a
                // `Box<NetdevState>` that captures stable pointers to BAR
                // and ring descriptors + an RX buffer pool; pass it as the
                // cshim cookie. The NetdevHandle reclaims the Box on drop.
                _netdev: {
                    let bar = _bar.access(pdev.as_ref())?;
                    let regs = Regs::new(bar);
                    let mac = regs.mac_address();
                    let bar_ptr = bar as *const pci::Bar<{ mmio::R8125_MMIO_LEN }>;
                    let irq_num = unsafe_boundary::pci_dev_irq(pdev);
                    let rx_bufs: kernel::dma::CoherentAllocation<RxBuffer> =
                        kernel::dma::CoherentAllocation::alloc_coherent(
                            pdev.as_ref(),
                            RING_LEN,
                            GFP_KERNEL,
                        )?;

                    let state = KBox::new(
                        NetdevState {
                            pdev: pdev.into(),
                            bar_ptr,
                            ndev: AtomicPtr::new(core::ptr::null_mut()),
                            irq_num,
                            tx_desc: tx_ring.desc_ptr_mut(),
                            tx_dma: tx_ring.dma_handle(),
                            rx_desc: rx_ring.desc_ptr_mut(),
                            rx_dma: rx_ring.dma_handle(),
                            rx_bufs,
                            tx_shadow: core::array::from_fn(|_| AtomicPtr::new(core::ptr::null_mut())),
                            tx_head: crate::netdev::CachePadded::new(
                                core::sync::atomic::AtomicUsize::new(0),
                            ),
                            tx_tail: crate::netdev::CachePadded::new(
                                core::sync::atomic::AtomicUsize::new(0),
                            ),
                            rx_tail: crate::netdev::CachePadded::new(
                                core::sync::atomic::AtomicUsize::new(0),
                            ),
                            ocp_base: core::sync::atomic::AtomicU32::new(
                                crate::regs::OCP_STD_PHY_BASE,
                            ),
                        },
                        GFP_KERNEL,
                    )?;
                    NetdevHandle::new_with_state(pdev, state, &mac)?
                },
                pdev: pdev.into(),
            }))
        })
    }
}
