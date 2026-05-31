// SPDX-License-Identifier: GPL-2.0
//! PCI bring-up for the RTL8125.
//!
//! [`R8125Driver`] implements [`kernel::pci::Driver`] for
//! VID `0x10EC` / DID `0x8125`. Probe sequence:
//!
//! 1. Enable memory decoding (`pdev.enable_device_mem()`).
//! 2. Set the 64-bit DMA mask via
//!    `unsafe_boundary::set_64bit_dma_mask`.
//! 3. Map BAR2 (64 KiB MMIO MAC-register window) via [`Devres`].
//! 4. Identify the chip from `TxConfig`'s XID nibble. Refuse any
//!    XID not in `hw::KNOWN` — **no silent fallback**.
//! 5. Reset the chip (r8169-style `CmdReset` + 10 ms poll). The
//!    `inject_reset_timeout` module parameter forces a timeout to
//!    exercise the failure path required by plan §7 M2.
//! 6. Log the PCIe ASPM capabilities (read-only at probe; actual
//!    ASPM enable/disable lives in `hw::hw_start_8125b`, gated by
//!    the `force_aspm` module param).
//! 7. Allocate the TX + RX descriptor rings and the coherent RX
//!    buffer pool (256 slots × 2 KiB).
//! 8. Register the net_device via the cshim
//!    (`netdev::NetdevHandle::new_with_state`). The netdev's
//!    `ndo_open` performs full bring-up — PHY connect, MAC init,
//!    IRQ request, NAPI enable.
//!
//! ## Remove order (load-bearing)
//!
//! [`R8125Driver::unbind`] explicitly shuts the registered netdev down before
//! the PCI adapter releases devres-managed resources. This is required because
//! netdev unregister runs `ndo_stop`, and that path touches chip registers via
//! the BAR mapping owned by `_bar`.
//!
//! Field declaration order remains a fallback guard for probe-error paths:
//! Rust drops fields in declaration order (top-to-bottom), so `_netdev` is
//! declared first and its idempotent Drop runs before the Rust-owned BAR/ring
//! fields when normal `unbind` did not run.
//!
//! Devres + `ARef` handle the rest. Probe-error paths run through
//! Drop, never bypass it — that's how "failed reset is recoverable"
//! (plan §7 M2) is enforced (other drivers rebind cleanly).

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
use crate::netdev::{IrqMode, NetdevHandle, NetdevState};
use crate::pm;
use crate::ring::{self, Ring};
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
/// **Remove order matters.** Normal remove goes through
/// [`R8125Driver::unbind`], which drains `_netdev` before the PCI adapter calls
/// `devres_release_all` and revokes `_bar`'s MMIO mapping. That explicit
/// shutdown is load-bearing: unregistering the netdev runs `ndo_stop` → Rust
/// `rust_stop`, which reads `bar_ptr`, `tx.desc`, and `rx.desc`.
///
/// Field declaration order is still intentional for probe-error paths and as a
/// fallback if the adapter contract changes: Rust drops struct fields in
/// **declaration order** (top → bottom), per the Reference. `_netdev` stays
/// first so its idempotent Drop runs before `_bar` + `tx_ring` + `rx_ring`
/// when `unbind` never ran. Then `pdev` (just a refcount) last.
///
/// Historical: 2026-05-25 M4-full first cut crashed with a KASAN slab-UAF
/// in `rust_stop+0x80` because this struct previously listed `_netdev`
/// last, with a doc comment that wrongly claimed Rust drops fields in
/// reverse. See `src/netdev.rs` M4_FULL_OPS comment block.
///
/// - `_netdev` — RAII for the registered net_device + boxed NetdevState.
///   `unbind` calls `shutdown` while the BAR is mapped; Drop is the
///   idempotent fallback and always frees the KBox.
/// - `_bar` — [`Devres`]-owned MMIO mapping; on drop calls `iounmap` +
///   `pci_release_region`.
/// - `tx_ring`, `rx_ring` — M3 cold DMA descriptor rings (`RING_LEN + 1`
///   each, +1 tail canary). On drop, `dma_free_coherent` runs.
/// - `pdev` — [`ARef`] keeps the underlying `struct pci_dev` alive for
///   the whole bound period. Drops last.
///
/// No explicit `PinnedDrop` impl — that would be an `unsafe impl`, which
/// the crate-root `#![deny(unsafe_code)]` rejects. The safe `unbind` hook plus
/// field-level Drop handle teardown; M1/M2/M3/M4 gates have verified it under
/// kmemleak + lockdep + KASAN.
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

    /// Tear the registered netdev down BEFORE devres releases the BAR.
    ///
    /// Kernel-Rust's `pci::Adapter::remove_callback` runs `T::unbind`,
    /// THEN `devres_release_all`, THEN drops `T::DriverData`. The BAR
    /// mapping is owned via `Devres<pci::Bar>` and goes away at the
    /// devres phase — so by the time the field `_netdev` would drop,
    /// any chip-touching MMIO in its teardown path crashes on a
    /// stale pointer. We sidestep that by doing the netdev unregister
    /// here, while devres is still holding the BAR alive.
    ///
    /// `NetdevHandle::shutdown` is idempotent — the matching `Drop`
    /// observes the drained sentinel and skips the redundant
    /// `unregister_netdev` call.
    fn unbind(_dev: &pci::Device<Core>, this: Pin<&Self>) {
        this._netdev.shutdown();
    }

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

            // Reset-timeout failure-injection knob. Read once at probe entry
            // so the value is consistent through the BAR-mapping + reset flow
            // inside the init scope below.
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

                    hw::reset(&regs, inject_timeout).inspect_err(|_e| {
                        let cmd = regs.chip_cmd();
                        dev_err!(
                            pdev,
                            "RTL8125 reset timeout (inject={}, ChipCmd=0x{:02x} after 10ms) — releasing device for rebind\n",
                            inject_timeout,
                            cmd
                        );
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

                    // M6 #1 Phase A.2 — allocate one IRQ vector.
                    //
                    // Default flag set prefers MSI-X → MSI → INTx (kernel's
                    // built-in order in `pci_alloc_irq_vectors`). The
                    // `intx_only` module param short-circuits to legacy
                    // INTx for regression testing. We detect which type the
                    // kernel actually gave us by retrying with INTx-only on
                    // any MSI/MSI-X allocation failure (the empirical fact
                    // we discovered in Phase A.1: enabling V2 register mode
                    // without an MSI/MSI-X vector silently breaks IRQ
                    // delivery — see hw.rs Phase A.1 comment).
                    let intx_only =
                        *crate::module_parameters::intx_only.value() != 0;
                    let irq_mode = if intx_only {
                        unsafe_boundary::alloc_one_irq_vector(
                            pdev,
                            pci::IrqTypes::default()
                                .with(pci::IrqType::Intx),
                        )?;
                        IrqMode::Intx
                    } else {
                        // First try MSI-X / MSI exclusively so we can tell
                        // the kernel "no INTx fallback" — that way, on
                        // failure we know to take the legacy path.
                        let msi_set = pci::IrqTypes::default()
                            .with(pci::IrqType::MsiX)
                            .with(pci::IrqType::Msi);
                        match unsafe_boundary::alloc_one_irq_vector(
                            pdev, msi_set,
                        ) {
                            Ok(()) => IrqMode::Msi,
                            Err(_) => {
                                unsafe_boundary::alloc_one_irq_vector(
                                    pdev,
                                    pci::IrqTypes::default()
                                        .with(pci::IrqType::Intx),
                                )?;
                                IrqMode::Intx
                            }
                        }
                    };
                    let irq_num =
                        unsafe_boundary::pci_irq_vector(pdev, 0)?;
                    dev_info!(
                        pdev,
                        "RTL8125 IRQ allocated: vector#0 = IRQ {} (mode={:?}{})\n",
                        irq_num,
                        irq_mode,
                        if intx_only { ", forced by intx_only" } else { "" }
                    );

                    // Candidate L + #4 — IRQ affinity policy.
                    //
                    // The `irq_pin_cpu` module param selects:
                    //   255  → auto: pick first online CPU on the chip's
                    //          NUMA node (PCI-local). UMA hosts collapse
                    //          to lowest-numbered online CPU.
                    //   254  → skip; leave to irqbalance.
                    //   0..253 → explicit CPU index; must be online.
                    //
                    // Default is 255 (auto). Operator can override via
                    // module param OR per-IRQ `/proc/irq/N/smp_affinity`.
                    // Best-effort: kernel rejection (e.g. offline CPU)
                    // is logged and we proceed — driver still works.
                    let pin_policy =
                        *crate::module_parameters::irq_pin_cpu.value();
                    let (pin_rc, chosen_cpu) = match pin_policy {
                        255 => unsafe_boundary::bridge_irq_pin_auto(
                            unsafe_boundary::pci_dev_raw(pdev),
                            irq_num as u32,
                        ),
                        254 => {
                            dev_info!(
                                pdev,
                                "RTL8125 IRQ {} affinity hint skipped (irq_pin_cpu=254)\n",
                                irq_num
                            );
                            (0, -1)
                        }
                        n => {
                            let cpu = core::ffi::c_int::from(n);
                            (
                                unsafe_boundary::bridge_irq_pin_cpu(
                                    irq_num as u32, cpu,
                                ),
                                cpu,
                            )
                        }
                    };
                    if pin_policy != 254 {
                        if pin_rc == 0 {
                            dev_info!(
                                pdev,
                                "RTL8125 IRQ {} affinity hint set to CPU {} (policy={})\n",
                                irq_num, chosen_cpu, pin_policy
                            );
                        } else {
                            dev_info!(
                                pdev,
                                "RTL8125 IRQ {} affinity hint failed: rc={} policy={} (driver still functional)\n",
                                irq_num, pin_rc, pin_policy
                            );
                        }
                    }

                    // Tier 3c: `aspm_force_off=1` operator intent.
                    // Chip-side ASPM is already disabled by default
                    // (`force_aspm=0` clears Config5 ASPM_en in
                    // `hw_start_8125b_unlocked`). This param reserves
                    // the operator-visible name and logs intent so
                    // dmesg confirms the request reached the driver.
                    // A future patch will add a host-side
                    // `pci_disable_link_state` call once that binding
                    // exists in `kernel::pci`.
                    let aspm_force_off =
                        *crate::module_parameters::aspm_force_off.value() != 0;
                    if aspm_force_off {
                        dev_info!(
                            pdev,
                            "RTL8125 aspm_force_off=1 acknowledged (chip-side ASPM already off by default; host-side LnkCtl disable deferred)\n"
                        );
                    }

                    // Heap-in-place construction (task #58 stack-overflow
                    // fix). Each substruct (`TxRingState`, `RxRingState`,
                    // `IrqState`, `PhyState` from task #59) carries its
                    // own `new()` returning `impl Init<Self, Error>`,
                    // so `KBox::init(try_init!(NetdevState { tx <- ... }))`
                    // walks down into each child's
                    // `init_array_from_fn` for the per-slot arrays.
                    // Probe stack frame stays under 4 KiB — well within
                    // the 16 KiB x86_64 kernel stack budget.
                    let state = KBox::init(
                        kernel::try_init!(NetdevState {
                            pdev: pdev.into(),
                            bar_ptr,
                            ndev: AtomicPtr::new(core::ptr::null_mut()),
                            tx <- crate::netdev::TxRingState::new(
                                tx_ring.desc_ptr_mut(),
                                tx_ring.dma_handle(),
                            ),
                            rx <- crate::netdev::RxRingState::new(
                                rx_ring.desc_ptr_mut(),
                                rx_ring.dma_handle(),
                            ),
                            irq <- crate::netdev::IrqState::new(
                                irq_num,
                                irq_mode,
                            ),
                            phy <- crate::netdev::PhyState::new(),
                        }? kernel::error::Error),
                        GFP_KERNEL,
                    )?;
                    NetdevHandle::new_with_state(pdev, state, &mac)?
                },
                pdev: pdev.into(),
            }))
        })
    }
}
