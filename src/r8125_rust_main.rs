// SPDX-License-Identifier: GPL-2.0
//! r8125_rust — Rust driver for the Realtek RTL8125 (milestones M1 + M2).
//!
//! Per [`docs/RTL8125_Rust_Driver_Implementation_Plan.md`]:
//!
//! - **M1** (§7 M1, done 2026-05-23): the PCI skeleton — registers a driver
//!   for VID `0x10EC` / DID `0x8125`, maps BAR2, logs vendor/device/revision.
//! - **M2** (§7 M2, in progress): adds register/reset layer — XID-based
//!   chip identification with a per-revision dispatch table, a r8169-style
//!   reset sequence with deliberate failure-injection support, and ASPM
//!   capability read + log. Still no `net_device` registration; that is M4.
//!
//! ## Architecture (plan §6.1)
//!
//! - [`pci`] — the [`pci::Driver`](kernel::pci::Driver) implementation, the
//!   device-id table, and probe / unbind orchestration.
//! - [`regs`] — curated register offsets and bitfield constants.
//! - [`mmio`] — typed [`Regs`](mmio::Regs) wrapper around `pci::Bar`. The
//!   only module outside `unsafe_boundary` that touches MMIO (plan §6.2).
//! - [`hw`] — per-revision identification (XID → `ChipInfo`) and the reset
//!   sequence (mirrors r8169 `rtl_hw_reset`).
//! - [`pm`] — ASPM capability read + log; future home for suspend/resume.
//! - [`unsafe_boundary`] — the single permitted home for `unsafe`. Still
//!   empty as of M2: every M2 hot-path uses safe kernel-Rust wrappers
//!   (`pci::Bar::{read*, write*}`, `kernel::time::delay::udelay`,
//!   `pci::Device::config_space`).
//!
//! ## Lint discipline
//!
//! Crate root carries `#![deny(unsafe_code)]` per plan §6.2.
//!
//! ## Filename note
//!
//! For a single-language Rust OOT module the crate root `.rs` must match the
//! `obj-m` target name (`$(obj)/%.o: $(obj)/%.rs` rule). For a **composite**
//! module that combines Rust + C objects, naming the Rust component the
//! same as the composite triggers a kbuild circular-dep warning and silently
//! drops the Rust `.o` from the final link. So the crate root is
//! `r8125_rust_main.rs` and the composite is `r8125_rust.ko` — same pattern
//! `samples/rust/rust_print` uses (`rust_print_main.rs` + `rust_print_events.c`
//! → `rust_print.ko`).
#![deny(unsafe_code)]

mod dma;
mod hw;
mod mmio;
mod napi;
mod netdev;
mod pci;
mod pm;
mod regs;
mod ring;
mod skb;
mod unsafe_boundary;

kernel::module_pci_driver! {
    type: pci::R8125Driver,
    name: "r8125_rust",
    authors: ["rtl8125-rs"],
    description: "Rust driver for the Realtek RTL8125 (M4-full packet-path development)",
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
    },
}
