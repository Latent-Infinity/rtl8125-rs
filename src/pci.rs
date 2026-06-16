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
//!    exercise the probe-error recovery path.
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
//! Drop, never bypass it — that's how "failed reset is recoverable" is
//! enforced (other drivers rebind cleanly).

use kernel::{
    device::Core, devres::Devres, error::code::ENODEV, pci, prelude::*, sync::aref::ARef,
};

use core::sync::atomic::{AtomicBool, AtomicPtr, AtomicU8, AtomicUsize};

use crate::hw;
use crate::mmio::{self, Regs};
use crate::netdev::{IrqMode, NetdevHandle, NetdevState};
use crate::pm;
use crate::regs;
use crate::ring;
use crate::unsafe_boundary;

/// Realtek's PCI Vendor ID is exposed as [`pci::Vendor::REALTEK`] (0x10EC);
/// the device ID for the entire RTL8125 family is `0x8125`.
const RTL8125_DEVICE_ID: u32 = 0x8125;

/// MMIO BAR index — BAR2 is the 64-bit, 64 KiB MAC register region per the
/// captured `lspci -vv` on the validated MS-A2 unit. BAR0 is the legacy I/O
/// alias; BAR4 is the MSI-X table — neither is what we want to map.
const R8125_MMIO_BAR: u32 = 2;

/// Per-device-ID payload. There is no per-ID dispatch — the per-revision
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
/// Historical: 2026-05-25 the first full net_device cut crashed with a KASAN
/// slab-UAF in `rust_stop+0x80` because this struct previously listed `_netdev`
/// last, with a doc comment that wrongly claimed Rust drops fields in
/// reverse. See `src/netdev.rs` FULL_OPS comment block.
///
/// - `_netdev` — RAII for the registered net_device + boxed NetdevState.
///   `unbind` calls `shutdown` while the BAR is mapped; Drop is the
///   idempotent fallback and always frees the KBox.
/// - `_bar` — [`Devres`]-owned MMIO mapping; on drop calls `iounmap` +
///   `pci_release_region`.
/// - `tx_ring`, `rx_ring` — cold DMA descriptor rings (`RING_LEN + 1`
///   each, +1 tail canary). On drop, `dma_free_coherent` runs.
/// - `pdev` — [`ARef`] keeps the underlying `struct pci_dev` alive for
///   the whole bound period. Drops last.
///
/// No explicit `PinnedDrop` impl — that would be an `unsafe impl`, which
/// the crate-root `#![deny(unsafe_code)]` rejects. The safe `unbind` hook plus
/// field-level Drop handle teardown; this has been verified under
/// kmemleak + lockdep + KASAN.
#[pin_data]
pub(crate) struct R8125Driver {
    /// net_device — must drop FIRST. See struct-level docs.
    _netdev: NetdevHandle,
    #[pin]
    _bar: Devres<pci::Bar<{ mmio::R8125_MMIO_LEN }>>,
    tx_ring: ring::TxRing,
    // One DMA RX ring per (compile-time) RX queue. Only `active_rx_queues()` of
    // them are populated + posted at runtime; the rest stay idle until a future
    // `rss_queues` opt-in activates more. Held here so the DMA stays mapped for
    // the driver's lifetime; `NetdevState.rx_queues[i]` keeps a pointer into
    // `rx_rings[i]`.
    rx_rings: [ring::RxRing; crate::netdev::RX_QUEUE_COUNT],
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

    /// System-sleep suspend (wired via the kernel-Rust PCI adapter's dev_pm_ops,
    /// extended for PM support). Quiesce the device through the cshim; the PCI
    /// core saves config space + sets the D-state around this. No-op if the
    /// interface was down. See docs/PM_GAP.md.
    ///
    /// Gated on the `r8125_pci_pm` cfg (Makefile `PCI_PM=1`): the
    /// `pci::Driver::suspend`/`resume` trait hooks only exist on a kernel
    /// carrying the kernel-Rust PCI PM extension
    /// (kernel-patches/0001-rust-pci-add-pm-callbacks.patch). On a stock kernel
    /// the trait has no such methods, so this impl must be compiled out to keep
    /// the driver buildable upstream. Validated on 7.0.0-kasan, 2026-06-13.
    #[cfg(r8125_pci_pm)]
    fn suspend(_dev: &pci::Device<Core>, this: Pin<&Self>) -> Result {
        unsafe_boundary::bridge_pm_suspend(this._netdev.ndev());
        Ok(())
    }

    /// System-sleep resume: re-initialise the device through the cshim if it was
    /// up before suspend (config space + D0 already restored by the PCI core).
    /// See [`suspend`](Self::suspend) for the `r8125_pci_pm` cfg rationale.
    #[cfg(r8125_pci_pm)]
    fn resume(_dev: &pci::Device<Core>, this: Pin<&Self>) -> Result {
        unsafe_boundary::bridge_pm_resume(this._netdev.ndev())
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

            // Enable memory decoding before claiming the BAR mapping.
            pdev.enable_device_mem()?;

            // Set 64-bit DMA mask BEFORE any coherent allocation. Wraps
            // the kernel-Rust `unsafe fn dma_set_mask_and_coherent`; the
            // SAFETY contract lives in `unsafe_boundary::set_64bit_dma_mask`.
            unsafe_boundary::set_64bit_dma_mask(pdev)?;

            // Reset-timeout failure-injection knob. Read once at probe entry
            // so the value is consistent through the BAR-mapping + reset flow
            // inside the init scope below.
            let inject_timeout = *crate::module_parameters::inject_reset_timeout.value() != 0;

            Ok(try_pin_init!(Self {
                _bar <- pdev.iomap_region_sized::<{ mmio::R8125_MMIO_LEN }>(
                    R8125_MMIO_BAR,
                    c"r8125_rust",
                ),
                _: {
                    // Field init order matters: `_bar` is now initialized; we
                    // can take a temporary `&pci::Bar` through `Devres::access`
                    // and drive the register-layer work. If any step here
                    // returns `Err`, the in-flight init drops `_bar`'s Devres
                    // → `iounmap` + `pci_release_region`, and the device is
                    // left in a state where r8169 can rebind cleanly.
                    let bar = _bar.access(pdev.as_ref())?;
                    let regs = Regs::new(bar);

                    let info = hw::identify(&regs).ok_or_else(|| {
                        let xid = hw::xid_from_tx_config(regs.tx_config());
                        dev_err!(
                            pdev,
                            "unknown RTL8125 sub-revision: XID=0x{:03x} — refusing to bind (no silent fallback)\n",
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
                tx_ring: ring::TxRing::new(pdev.as_ref())?,
                // One RX ring per RX queue. `?` propagates an allocation failure
                // from any queue. RX_QUEUE_COUNT is small (4) so an explicit
                // array keeps the fallible init readable; the assert pins the
                // element count to the const so a bump forces updating this site.
                rx_rings: {
                    const _: () = assert!(crate::netdev::RX_QUEUE_COUNT == 4);
                    [
                        ring::RxRing::new(pdev.as_ref())?,
                        ring::RxRing::new(pdev.as_ref())?,
                        ring::RxRing::new(pdev.as_ref())?,
                        ring::RxRing::new(pdev.as_ref())?,
                    ]
                },
                _: {
                    // Cold-ring sanity.
                    tx_ring.verify_canaries()?;
                    for r in rx_rings.iter() {
                        r.verify_canaries()?;
                    }
                    dev_info!(
                        pdev,
                        "DMA rings allocated: TX dma=0x{:016x} RX[0] dma=0x{:016x} x{} queues ({} descriptors each, +1 tail canary)\n",
                        tx_ring.dma_handle(),
                        rx_rings[0].dma_handle(),
                        crate::netdev::RX_QUEUE_COUNT,
                        ring::RING_LEN
                    );
                },
                // Read real MAC from IDR0..IDR5; build a
                // `Box<NetdevState>` that captures stable pointers to BAR
                // and ring descriptors + an RX buffer pool; pass it as the
                // cshim cookie. The NetdevHandle reclaims the Box on drop.
                _netdev: {
                    let bar = _bar.access(pdev.as_ref())?;
                    let regs = Regs::new(bar);
                    let mac = regs.mac_address();
                    let bar_ptr = bar as *const pci::Bar<{ mmio::R8125_MMIO_LEN }>;

                    // Default flag set prefers MSI-X → MSI → INTx (kernel's
                    // built-in order in `pci_alloc_irq_vectors`). The
                    // `intx_only` module param short-circuits to legacy
                    // INTx for regression testing. We detect which type the
                    // kernel actually gave us by retrying with INTx-only on
                    // any MSI/MSI-X allocation failure.
                    let intx_only =
                        *crate::module_parameters::intx_only.value() != 0;
                    // V2 surface escape hatch: 0=off (legacy single-vector),
                    // 1=auto (try V2 then fall back, default), 2=on (require
                    // V2). `intx_only` still wins (forces INTx outright).
                    let irq_v2 = *crate::module_parameters::irq_v2.value();
                    let (irq_mode, use_v2) = if intx_only {
                        unsafe_boundary::alloc_one_irq_vector(
                            pdev,
                            pci::IrqTypes::default()
                                .with(pci::IrqType::Intx),
                        )?;
                        (IrqMode::Intx, false)
                    } else {
                        let msix_only =
                            pci::IrqTypes::default().with(pci::IrqType::MsiX);
                        // RTL8125B V2 routes source bit N to MSI-X table entry
                        // N. TX Q0 is entry 16 and LINKCHG is entry 21, so the
                        // V2 surface is valid only after an exact 22-vector
                        // MSI-X allocation. The `irq_v2` knob gates the
                        // attempt: off (0) skips V2 and goes straight to the
                        // proven single-vector legacy ISR/IMR surface; on (2)
                        // fails probe if the 22-vector surface is unavailable.
                        // See UDP_TX_WEDGE.md.
                        let want_v2 = irq_v2 != 0;
                        if want_v2
                            && unsafe_boundary::alloc_irq_vectors(
                                pdev,
                                regs::V2_MIN_MSIX_VECTORS_8125B,
                                regs::V2_MIN_MSIX_VECTORS_8125B,
                                msix_only,
                            )
                            .is_ok()
                        {
                            (IrqMode::Msi, true)
                        } else if irq_v2 == 2 {
                            // on: V2 explicitly required but the 22-vector
                            // MSI-X surface is unavailable — refuse to load
                            // rather than silently downgrade to legacy.
                            dev_err!(
                                pdev,
                                "RTL8125 irq_v2=on but 22-vector MSI-X V2 unavailable; not loading\n"
                            );
                            Err::<(IrqMode, bool), kernel::error::Error>(
                                kernel::error::code::EINVAL,
                            )?
                        } else if unsafe_boundary::alloc_one_irq_vector(pdev, msix_only).is_ok() {
                            (IrqMode::Msi, false)
                        } else {
                            match unsafe_boundary::alloc_one_irq_vector(
                                pdev,
                                pci::IrqTypes::default().with(pci::IrqType::Msi),
                            ) {
                                Ok(()) => (IrqMode::Msi, false),
                                Err(_) => {
                                    unsafe_boundary::alloc_one_irq_vector(
                                        pdev,
                                        pci::IrqTypes::default()
                                            .with(pci::IrqType::Intx),
                                    )?;
                                    (IrqMode::Intx, false)
                                }
                            }
                        }
                    };
                    // Per-RX-queue IRQ numbers. V2 maps RX queue i to MSI-X
                    // entry i (0..N-1); the single-vector / INTx fallback uses
                    // only entry 0 (the combined interrupt). Fetch all RX
                    // vectors under V2 even if only some are activated at open —
                    // the unused ones are simply never `request_irq`'d.
                    let mut rx_irq_nums = [0u32; crate::netdev::RX_QUEUE_COUNT];
                    rx_irq_nums[0] =
                        unsafe_boundary::pci_irq_vector(pdev, regs::V2_RX_Q0_VECTOR)?;
                    if use_v2 {
                        for (i, slot) in rx_irq_nums.iter_mut().enumerate().skip(1) {
                            *slot = unsafe_boundary::pci_irq_vector(pdev, i as u32)?;
                        }
                    }
                    let tx_irq_num = if use_v2 {
                        unsafe_boundary::pci_irq_vector(pdev, regs::V2_TX_Q0_VECTOR)?
                    } else {
                        0
                    };
                    let link_irq_num = if use_v2 {
                        unsafe_boundary::pci_irq_vector(pdev, regs::V2_LINK_VECTOR)?
                    } else {
                        0
                    };
                    let irq_num = rx_irq_nums[0];
                    dev_info!(
                        pdev,
                        "RTL8125 IRQ allocated: rx0 IRQ {} tx0 IRQ {} link IRQ {} (mode={:?}, use_v2={}){}\n",
                        irq_num,
                        tx_irq_num,
                        link_irq_num,
                        irq_mode,
                        use_v2,
                        if intx_only { ", forced by intx_only" } else { "" }
                    );

                    // IRQ affinity policy.
                    //
                    // The `irq_pin_cpu` module param selects:
                    //   255  → auto: SPREAD the active vectors across distinct
                    //          CPUs, fanning out from the chip's NUMA-local
                    //          first-online CPU (host-tested
                    //          `layout::irq_affinity_cpu`). Each queue's DMA
                    //          then stays on one per-CPU IOVA cache, fixing
                    //          multi-queue `tx_dropped_error` from IOVA rcache
                    //          contention. Single-queue collapses to the
                    //          one NUMA-local CPU (unchanged behaviour).
                    //   254  → skip; leave to irqbalance.
                    //   0..253 → explicit CPU index; pins every vector there.
                    //
                    // Default is 255 (auto). Operator can override via module
                    // param OR per-IRQ `/proc/irq/N/smp_affinity`. Best-effort:
                    // kernel rejection (e.g. offline CPU) is logged and we
                    // proceed — driver still works.
                    let pin_policy =
                        *crate::module_parameters::irq_pin_cpu.value();
                    // Resolve the auto-spread fan-out base + width once. base<0
                    // (no online CPU on node) and ncpus==0 both degrade to CPU 0
                    // via `irq_affinity_cpu`'s defensive path.
                    let (spread_base, spread_ncpus) = if pin_policy == 255 {
                        let base = unsafe_boundary::bridge_node_base_cpu(
                            unsafe_boundary::pci_dev_raw(pdev),
                        );
                        let ncpus =
                            unsafe_boundary::bridge_num_online_cpus() as usize;
                        (if base < 0 { 0usize } else { base as usize }, ncpus)
                    } else {
                        (0usize, 0usize)
                    };
                    let mut pin_idx = 0usize;
                    let mut pin_irq = |label: &str, irq: u32| {
                        if pin_policy == 254 {
                            dev_info!(
                                pdev,
                                "RTL8125 {} IRQ {} affinity hint skipped (irq_pin_cpu=254)\n",
                                label,
                                irq
                            );
                            return;
                        }
                        let chosen_cpu = if pin_policy == 255 {
                            let cpu = crate::layout::irq_affinity_cpu(
                                pin_idx,
                                spread_base,
                                spread_ncpus,
                            ) as core::ffi::c_int;
                            pin_idx += 1;
                            cpu
                        } else {
                            core::ffi::c_int::from(pin_policy)
                        };
                        let pin_rc =
                            unsafe_boundary::bridge_irq_pin_cpu(irq, chosen_cpu);
                        if pin_rc == 0 {
                            dev_info!(
                                pdev,
                                "RTL8125 {} IRQ {} affinity set to CPU {} (policy={})\n",
                                label, irq, chosen_cpu, pin_policy
                            );
                        } else {
                            dev_info!(
                                pdev,
                                "RTL8125 {} IRQ {} affinity failed: rc={} cpu={} policy={} (driver still functional)\n",
                                label, irq, pin_rc, chosen_cpu, pin_policy
                            );
                        }
                    };
                    // Pin EVERY allocated vector (all RX queues, then tx0, then
                    // link) to its own CPU, not just the currently-active count.
                    // ethtool set_channels can raise the active RX-queue count at
                    // runtime; pinning all of them up front means a newly-activated
                    // queue already has its dedicated-CPU affinity (the B6.5
                    // per-CPU IOVA-locality fix must hold for every queue the
                    // device can ever activate). Deterministic indices: rx_i→i,
                    // tx0→RX_QUEUE_COUNT, link→RX_QUEUE_COUNT+1. Idle (unrequested)
                    // vectors are pinned but never fire.
                    pin_irq("rx0", irq_num);
                    if use_v2 {
                        for &rx_irq in rx_irq_nums.iter().skip(1) {
                            pin_irq("rx", rx_irq);
                        }
                        pin_irq("tx0", tx_irq_num);
                        pin_irq("link", link_irq_num);
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
                    // fix). Each substruct (`TxRingState`, `RxQueueState`,
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
                            debug_counters: AtomicBool::new(false),
                            bql_enabled: AtomicBool::new(false),
                            rx_hash_enabled: AtomicBool::new(false),
                            requested_rx_queues: AtomicUsize::new(0),
                            rss_key_custom: AtomicBool::new(false),
                            rss_key <- pin_init::init_array_from_fn(|_| AtomicU8::new(0)),
                            rss_indir_custom: AtomicBool::new(false),
                            rss_indir <- pin_init::init_array_from_fn(|_| AtomicU8::new(0)),
                            tx <- crate::netdev::TxRingState::new(
                                tx_ring.desc_ptr_mut(),
                                tx_ring.dma_handle(),
                            ),
                            rx_queues <- pin_init::init_array_from_fn(|i| {
                                crate::netdev::RxQueueState::new(
                                    rx_rings[i].desc_ptr_mut(),
                                    rx_rings[i].dma_handle(),
                                    // RXHASH requires the 32-byte V3
                                    // descriptor layout to expose RSSResult.
                                    // Fixed at probe (no per-packet switching).
                                    // The `rx_legacy_desc=1` rollback knob
                                    // forces the legacy 16-byte path (and
                                    // disables RXHASH).
                                    if *crate::module_parameters::rx_legacy_desc.value() != 0 {
                                        crate::ring::RxDescFormat::Legacy
                                    } else {
                                        crate::ring::RxDescFormat::V3
                                    },
                                )
                            }),
                            irq <- crate::netdev::IrqState::new(
                                rx_irq_nums,
                                tx_irq_num,
                                link_irq_num,
                                irq_mode,
                                use_v2,
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
