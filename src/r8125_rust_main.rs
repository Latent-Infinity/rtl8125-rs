// SPDX-License-Identifier: GPL-2.0
//! r8125_rust — Rust driver for the Realtek RTL8125 family.
//!
//! Single composite kernel module for VID `0x10EC` / DID `0x8125`.
//! Validated chip: RTL8125B (XID 0x641 / `RTL_GIGA_MAC_VER_63`). Other
//! XIDs return `-ENODEV` from probe (no silent fallback to a generic
//! handler).
//!
//! ## Architecture
//!
//! Rust-side modules (this crate):
//!
//! - [`pci`] — [`pci::Driver`](kernel::pci::Driver) impl, device-id
//!   table, probe / unbind orchestration.
//! - [`regs`] — curated register offsets and bitfield constants.
//! - [`mmio`] — typed [`Regs`](mmio::Regs) wrapper around `pci::Bar`.
//!   The only module outside `unsafe_boundary` that touches MMIO.
//! - [`hw`] — per-revision XID → `ChipInfo` dispatch, the r8169-port
//!   `hw_start_8125b` chip-init sequence, and the reset path.
//! - [`netdev`] — `NetdevState`, `ndo_open`/`stop`/`start_xmit`, and
//!   the raw IRQ handler. The TX hot path lives here.
//! - [`napi`] — NAPI poll: RX delivery (build skb + `napi_gro_receive`),
//!   TX completion reaping, queue stop/wake hysteresis
//!   (`RUST_STANDARDS.md §15.2`).
//! - [`ring`] — descriptor layout + ring index newtypes.
//! - [`skb`] — type-state `TxSkb<S>` mirroring the SKB lifecycle.
//! - [`dma`], [`phy`], [`pm`] — DMA pool, PHY OCP / C45 MDIO helpers,
//!   ASPM capability accessor.
//! - [`unsafe_boundary`] — the single permitted home for `unsafe`.
//!   Holds every `extern "C"` declaration, every `unsafe impl`, and
//!   every `// SAFETY:` block. CI (`ci/check_unsafe_allowlist.sh`)
//!   refuses `#![allow(unsafe_code)]` in any other file.
//!
//! C-side cshim (`src/netdev_bridge*.c`): covers the `net_device` +
//! NAPI + `sk_buff` + `mii_bus` + `ethtool_ops` surface that
//! kernel-Rust has not yet abstracted (see `docs/PREP.md`
//! for the upstream gap inventory). Contract:
//! `src/netdev_bridge.h::r8125_bridge_ops`.
//!
//! ## Discipline
//!
//! - Crate root carries `#![deny(unsafe_code)]`.
//! - Module parameters: `inject_reset_timeout` (probe failure-injection
//!   test gate), `force_aspm` (test-only ASPM-on soak; DO NOT set in
//!   production), `intx_only` (MSI/MSI-X rollback), interrupt coalesce
//!   timers for validation, and `aspm_force_off` (operator-visible ASPM-off
//!   intent until host-side ASPM control is exposed). See
//!   `docs/RTL8125B_TSO_NOTES.md`.
//!
//! ## Filename note (kbuild requirement)
//!
//! For a composite Rust + C kbuild module, the Rust crate root cannot
//! share its name with the composite `.ko` — kbuild's circular-dep
//! check silently drops the Rust object from the link. The crate root
//! is `r8125_rust_main.rs`; the composite is `r8125_rust.ko`. Same
//! pattern as `samples/rust/rust_print` (`rust_print_main.rs` +
//! `rust_print_events.c` → `rust_print.ko`).
//!
//! Development history, design rationale, and bisection logs live in
//! `docs/` — see `docs/RTL8125_Rust_Driver_Implementation_Plan.md`,
//! `docs/RTL8125B_TSO_NOTES.md`.
#![deny(unsafe_code)]
#![allow(clippy::unnecessary_safety_comment)]

mod dma;
mod hw;
mod layout;
mod mmio;
mod napi;
mod netdev;
mod pci;
mod phy;
mod phy_config;
mod phy_fw;
mod pm;
mod regs;
mod ring;
mod rss;
mod skb;
mod unsafe_boundary;

// `authors` accepts a list of "Name <email>" strings. Before posting to
// netdev the human author must replace this out-of-tree project identity
// with the responsible maintainer identity; see docs/COMMIT_POLICY.md.
kernel::module_pci_driver! {
    type: pci::R8125Driver,
    name: "r8125_rust",
    authors: ["rtl8125-rs maintainers"],
    description: "Rust driver for the Realtek RTL8125 2.5G Ethernet controller",
    license: "GPL v2",
    params: {
        // Deliberate failure-injection knob for the
        // "failed reset path is recoverable" gate. When non-zero, the
        // reset code suppresses the `CmdReset` write so the poll loop
        // always times out, and probe returns `-EIO`. Default 0 (off).
        //
        // Bool isn't yet a supported module-param type in
        // `kernel::module_param`; `u8` with the convention 0=off / non-zero=on
        // is the documented workaround.
        inject_reset_timeout: u8 {
            default: 0,
            description: "Force the reset poll to time out (testing only)",
        },
        // ASPM-soak knob: when non-zero, hw_start_8125b skips the
        // Config5 ASPM_en clear so the PCIe link can enter L1.x during
        // idle. Required to exercise the historical RTL8125 L1.x
        // lockup gate.
        //
        // Default 0 (ASPM disabled — matches r8169
        // rtl_hw_aspm_clkreq_enable(false) and keeps TSO reliable per
        // docs/RTL8125B_TSO_NOTES.md). DO NOT set this in production:
        // TSO retransmits return when ASPM is on.
        force_aspm: u8 {
            default: 0,
            description: "Leave ASPM enabled (test-only, breaks TSO)",
        },
        // MSI-X rollback knob.
        // Default 0 lets probe call `pci_alloc_irq_vectors` with the
        // MSI-X → MSI → INTx preference chain, then enable
        // `INT_CFG0_ENABLE_8125` so the chip routes IRQs through the
        // ISR_V2 register window. Non-zero forces probe to allocate
        // an INTx vector only and leaves the legacy IMR/ISR window
        // authoritative — used to A/B-test MSI-X vs INTx perf and as
        // an escape hatch if MSI-X regresses on a deployment target.
        intx_only: u8 {
            default: 0,
            description: "Force legacy INTx ISR/IMR register layout (test rollback)",
        },
        // V2 MSI-X interrupt surface selection (escape hatch for the
        // historically wedge-prone per-queue ISR). The V2 surface needs an
        // exact 22-vector MSI-X allocation (TX Q0 = entry 16, LINKCHG = 21);
        // see docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md.
        //   0 → off:  never enable V2 — allocate a single MSI/MSI-X vector and
        //             use the proven legacy combined ISR/IMR surface
        //             (use_v2=false). The MSI-delivery escape hatch that does
        //             NOT drop all the way to INTx like `intx_only=1`.
        //   1 → auto: try the 22-vector V2 surface, fall back to the
        //             single-vector legacy surface, then INTx (default — the
        //             current behavior).
        //   2 → on:   require V2 — fail probe if the 22-vector MSI-X surface
        //             cannot be allocated (strict validation / CI only).
        // `intx_only=1` still wins over this knob (forces INTx outright).
        irq_v2: u8 {
            default: 1,
            description: "V2 MSI-X surface: 0=off (legacy MSI), 1=auto (default), 2=on (require V2)",
        },
        // Operator escape hatch for any future ASPM regression.
        // When non-zero, probe logs an informational dmesg line so
        // the operator can confirm the intent reached the driver.
        // Chip-side ASPM is already disabled by default via the
        // `force_aspm=0` Config5 clear path (see src/hw.rs
        // `hw_start_8125b_unlocked`); this param reserves the name
        // for a future host-side `LnkCtl` disable when the
        // `pci_disable_link_state` binding is added.
        aspm_force_off: u8 {
            default: 0,
            description: "Reserve operator intent for ASPM force-off (chip-side already off by default)",
        },
        // IRQ affinity policy with PCI-local default.
        // Conventions (u8 because `kernel::module_param` doesn't yet
        // expose signed types):
        //   255  → auto: pick first online CPU on the chip's NUMA node
        //          (default, latency-aligned)
        //   254  → don't pin; leave to irqbalance
        //   0..253 → explicit CPU index; must be online
        // See `docs/RX_OPTIMIZATION_CANDIDATES.md` §"#4".
        irq_pin_cpu: u8 {
            default: 255,
            description: "IRQ affinity policy: 255=auto (PCI-local), 254=skip, 0..253=explicit CPU index",
        },
        // RTL8125 INT_MITI sweep knobs for the C-vs-Rust regression campaign.
        // These are raw RTL8125 timer units, not ethtool usecs. The timer table
        // is programmed for both the legacy ISR/IMR surface and the V2 surface;
        // on RTL8125B the older 0xE2 `IntrMitigate` address is FIFO status, not
        // the interrupt-moderation control path.
        // Defaults are candidate values from docs/perf/cvr_20260604_fixed:
        //   RX 0x08: below the over-moderating 0x10 value that capped
        //            64/128B RX pps.
        //   TX 0x10: non-zero TX completion moderation for MSI sweeps,
        //            where BQL is disabled by the safe default.
        // The upstreamable user API for this should eventually be ethtool
        // coalesce; these module params are for validation and rollback.
        rx_coalesce_timer: u16 {
            default: crate::regs::RX_COALESCE_TIMER_8125B_DEFAULT,
            description: "Raw RTL8125 INT_MITI RX timer for validation",
        },
        tx_coalesce_timer: u16 {
            default: crate::regs::TX_COALESCE_TIMER_8125B_DEFAULT,
            description: "Raw RTL8125 INT_MITI TX timer for validation",
        },
        // BQL (byte queue limits) activation gate. netdev_sent_queue() in the
        // xmit path was isolated as unsafe on the one-vector V2/MSI-X surface
        // (2026-06-05, docs/perf/bql_20260605/) while it works over INTx and
        // recaptures the loaded-latency parity with r8169. The default driver
        // now uses MSI delivery with the legacy ISR surface, but BQL still
        // stays INTx-only until the MSI path is separately revalidated.
        //   0 → off:        never call netdev_sent/completed_queue.
        //   1 → intx_only:  active only with INTx delivery (default — safe;
        //                   latency fix applies over INTx).
        //   2 → force:      always active (for isolation testing only;
        //                   keep test-only until MSI delivery is validated).
        bql_mode: u8 {
            default: 1,
            description: "BQL activation: 0=off, 1=intx_only (safe default), 2=force (test only)",
        },
        // Driver-owned TX byte-budget throttle (the MSI-safe latency path —
        // test 5, docs/BQL_RETRY_PLAN.md). When non-zero, xmit stops the txq
        // once in-flight TX bytes exceed this budget and the reaper wakes it
        // when they fall back below half (minimum 1 byte) — bounding TX ring
        // residency so fq_codel protects latency under a bulk flow, WITHOUT
        // calling netdev_sent_queue (which breaks MSI-X delivery on this chip).
        // Works on BOTH IRQ surfaces (uses only netif_tx_stop/wake_queue, which
        // the ring-full path already uses safely over MSI). 0 disables it.
        // Default 131072 (~128 KiB ≈ 0.45 ms at 2.5 Gbps) — a starting point;
        // tune in docs/perf for the latency/throughput knee.
        tx_byte_budget: u32 {
            default: 131072,
            description: "Driver TX in-flight byte budget for latency (0=off; MSI-safe BQL alternative)",
        },
        // Hot-path debug counters (`xmit_calls`, `irq_fires`, `napi_polls`,
        // `tx_doorbells`) are useful for doorbell-ratio validation, but their
        // atomic RMWs are visible in small-frame PPS tests. Keep them opt-in.
        debug_counters: u8 {
            default: 0,
            description: "Enable hot-path debug counters in ndo_stop log (0=off, 1=on)",
        },
        // Legacy RX descriptor escape hatch. Default 0 uses the V3 (32-byte)
        // RX descriptor path that carries the RXHASH metadata. Non-zero forces
        // the legacy 16-byte descriptor layout (the path validated through the
        // earlier test matrices/soaks) and disables RXHASH (legacy descriptors have no
        // hash field) — a rollback knob if the V3 path regresses on a target.
        rx_legacy_desc: u8 {
            default: 0,
            description: "Force legacy 16-byte RX descriptors + disable RXHASH (rollback; 0=V3 default)",
        },
        // Hardware RSS queue-count request. Default 0 leaves hardware queue
        // distribution off and preserves the reviewed single-queue RXHASH
        // path. Value 1 is a register-programming validation mode that still
        // maps every bucket to queue 0. Multi-queue values must be exactly
        // representable in the RTL8125 log2(queue_count) fields (2 or 4 for
        // this bridge). Unsupported values fail ndo_open instead of silently
        // misprogramming the hardware.
        rss_queues: u8 {
            default: 0,
            description: "Hardware RSS queue request: 0=off, 1=single-queue validation, 2/4=multi-queue",
        },
    },
}
