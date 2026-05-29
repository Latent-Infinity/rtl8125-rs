// SPDX-License-Identifier: GPL-2.0
//! r8125_rust — Rust driver for the Realtek RTL8125 family.
//!
//! Single composite kernel module for VID `0x10EC` / DID `0x8125`.
//! Validated chip: RTL8125B (XID 0x641 / `RTL_GIGA_MAC_VER_63`). Other
//! XIDs return `-ENODEV` from probe (no silent fallback to a generic
//! handler).
//!
//! ## Architecture (plan §6.1)
//!
//! Rust-side modules (this crate):
//!
//! - [`pci`] — [`pci::Driver`](kernel::pci::Driver) impl, device-id
//!   table, probe / unbind orchestration.
//! - [`regs`] — curated register offsets and bitfield constants.
//! - [`mmio`] — typed [`Regs`](mmio::Regs) wrapper around `pci::Bar`.
//!   The only module outside `unsafe_boundary` that touches MMIO
//!   (plan §6.2).
//! - [`hw`] — per-revision XID → `ChipInfo` dispatch, the r8169-port
//!   `hw_start_8125b` chip-init sequence, and the reset path.
//! - [`netdev`] — `NetdevState`, `ndo_open`/`stop`/`start_xmit`, and
//!   the raw IRQ handler. The TX hot path lives here.
//! - [`napi`] — NAPI poll: RX delivery (build skb + `napi_gro_receive`),
//!   TX completion reaping, queue stop/wake hysteresis
//!   (`RUST_STANDARDS.md §15.2`).
//! - [`ring`] — descriptor layout + ring index newtypes.
//! - [`skb`] — type-state `TxSkb<S>` mirroring the plan §6.3 lifecycle.
//! - [`dma`], [`phy`], [`pm`] — DMA pool, PHY OCP / C45 MDIO helpers,
//!   ASPM capability accessor.
//! - [`unsafe_boundary`] — the single permitted home for `unsafe`.
//!   Holds every `extern "C"` declaration, every `unsafe impl`, and
//!   every `// SAFETY:` block. CI (`ci/check_unsafe_allowlist.sh`)
//!   refuses `#![allow(unsafe_code)]` in any other file.
//!
//! C-side cshim (`src/netdev_bridge*.c`): covers the `net_device` +
//! NAPI + `sk_buff` + `mii_bus` + `ethtool_ops` surface that
//! kernel-Rust has not yet abstracted (plan §5.2; see `docs/M7_PREP.md`
//! for the upstream gap inventory). Contract:
//! `src/netdev_bridge.h::r8125_bridge_ops`.
//!
//! ## Discipline
//!
//! - Crate root carries `#![deny(unsafe_code)]` (plan §6.2).
//! - Module parameters: `inject_reset_timeout` (probe failure-injection
//!   test gate), `force_aspm` (test-only ASPM-on soak; DO NOT set in
//!   production), `intx_only` (MSI/MSI-X rollback), and `aspm_force_off`
//!   (operator-visible ASPM-off intent until host-side ASPM control is
//!   exposed). See `docs/RTL8125B_TSO_NOTES.md`.
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
//! Milestone history, design rationale, and bisection logs live in
//! `docs/` — see `docs/RTL8125_Rust_Driver_Implementation_Plan.md`,
//! `docs/M5_CLOSEOUT.md`, `docs/RTL8125B_TSO_NOTES.md`.
#![deny(unsafe_code)]
#![allow(clippy::unnecessary_safety_comment)]

mod dma;
mod hw;
mod mmio;
mod napi;
mod netdev;
mod pci;
mod phy;
mod pm;
mod regs;
mod ring;
mod skb;
mod unsafe_boundary;

kernel::module_pci_driver! {
    type: pci::R8125Driver,
    name: "r8125_rust",
    authors: ["rtl8125-rs"],
    description: "Rust driver for the Realtek RTL8125",
    license: "GPL v2",
    params: {
        // Deliberate failure-injection knob for the plan §7 M2
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
        // M5 ASPM-soak knob: when non-zero, hw_start_8125b skips the
        // Config5 ASPM_en clear so the PCIe link can enter L1.x during
        // idle. Required to exercise the historical RTL8125 L1.x
        // lockup gate (plan §7 M5).
        //
        // Default 0 (ASPM disabled — matches r8169
        // rtl_hw_aspm_clkreq_enable(false) and keeps TSO reliable per
        // docs/RTL8125B_TSO_NOTES.md). DO NOT set this in production:
        // TSO retransmits return when ASPM is on.
        force_aspm: u8 {
            default: 0,
            description: "Leave ASPM enabled (test-only, breaks TSO)",
        },
        // M6 sub-feature #1 rollback knob (Phase A.2 — ACTIVE).
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
    },
}
