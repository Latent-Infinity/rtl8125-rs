// SPDX-License-Identifier: GPL-2.0
//! Per-revision chip identification + reset sequence (plan §3.1, §7 M2).
//!
//! ## Identification
//!
//! Mirrors r8169's `rtl8169_get_chip_version`:
//! `xid = (TxConfig >> 20) & 0xfcf`, then table-matched by
//! `(xid & mask) == val`. M2 hard-codes a one-entry table (RTL8125B XID
//! 0x641 = `RTL_GIGA_MAC_VER_63`) — the only chip on the validated MS-A2.
//! Other XIDs return `None`, and `pci::Driver::probe` turns that into
//! `-ENODEV`. **No silent fallback** (plan §7 M2 gate).
//!
//! ## Reset
//!
//! Mirrors r8169's `rtl_hw_reset`: write `CmdReset` (bit 4) to `ChipCmd`
//! (0x37), then poll up to 100 × 100 µs (10 ms total) for the bit to clear.
//! If the poll times out, the BAR mapping (via `Devres<Bar>`) and the PCI
//! device reference (via `ARef<pci::Device>`) drop on the error path,
//! leaving the hardware in a state where another driver (r8169) can rebind
//! cleanly — the plan §7 M2 "failed reset path is recoverable" requirement.
//!
//! The `inject_timeout` argument is the module-parameter-driven failure
//! injection knob; when true the `set_chip_cmd` write is suppressed so the
//! poll always times out. Used to exercise the failure path end-to-end.

use kernel::error::code::EIO;
use kernel::prelude::*;
use kernel::time::{delay::udelay, Delta};

use crate::mmio::Regs;
use crate::regs;

/// MAC version naming kept aligned with r8169's `RTL_GIGA_MAC_VER_*` enum so
/// future cross-references stay obvious. Only the variants this driver
/// actually supports are listed; expanding the list is the supported way to
/// add a new sub-revision (and gets the strictest review per plan §9).
#[derive(Copy, Clone, Debug)]
pub(crate) enum MacVersion {
    /// RTL8125B (XID 0x641 / `RTL_GIGA_MAC_VER_63` in r8169).
    Rtl8125B,
}

/// One row of the chip dispatch table. `(xid & mask) == val` decides the
/// match, exactly the predicate r8169 uses.
#[derive(Copy, Clone)]
pub(crate) struct ChipInfo {
    pub(crate) mask: u32,
    pub(crate) val: u32,
    pub(crate) mac_version: MacVersion,
    pub(crate) name: &'static str,
}

/// Known-chip dispatch table — M2 carries only the validated entry. Adding
/// a row here is the supported way to support a new RTL8125 sub-revision.
pub(crate) const KNOWN: &[ChipInfo] = &[
    ChipInfo {
        mask: 0x7cf,
        val: 0x641,
        mac_version: MacVersion::Rtl8125B,
        name: "RTL8125B",
    },
];

/// Extract the XID from a raw `TxConfig` value (the r8169 formula).
pub(crate) fn xid_from_tx_config(tx_config: u32) -> u32 {
    (tx_config >> regs::XID_SHIFT) & regs::XID_MASK
}

/// Identify the chip from the current `TxConfig` value. Returns `Some(info)`
/// on a match against [`KNOWN`], `None` for an XID the driver does not
/// claim support for.
pub(crate) fn identify(regs: &Regs<'_>) -> Option<&'static ChipInfo> {
    let xid = xid_from_tx_config(regs.tx_config());
    KNOWN.iter().find(|info| (xid & info.mask) == info.val)
}

/// MAC OCP poll: wait for register 0xE00E bit 13 to clear. Mirrors r8169
/// `rtl_mac_ocp_e00e_cond` — 1000 iterations × 10 µs = 10 ms total.
fn wait_mac_ocp_e00e_clear(regs: &Regs<'_>) -> Result<()> {
    let step = Delta::from_micros(10);
    for _ in 0..1000 {
        if regs.mac_ocp_read(0xE00E) & (1 << 13) == 0 {
            return Ok(());
        }
        udelay(step);
    }
    Err(EIO)
}

/// Port of r8169 `rtl_hw_start_8125_common` specialized for MAC_VER_63
/// (RTL8125B). This is the minimum MAC OCP / MMIO init sequence required
/// for the 8125B's TX and RX engines to actually move packets — without
/// it, ChipCmd RX|TX enable appears to take effect but the engines are
/// silent. We deliberately skip the optional pieces (RSS, PCIe state
/// transitions, ASPM clkreq tuning) — those become M5 work.
///
/// Sequence in source-of-truth order so cross-referencing with r8169 is
/// trivial. Every line is a direct port from r8169_main.c
/// `rtl_hw_start_8125_common` (line ~3855) with VER_63-specific branches.
pub(crate) fn hw_start_8125b(regs: &Regs<'_>) -> Result<()> {
    // Config1 (8-bit at 0x52): clear bit 4 — "PM enable" override per r8169.
    let cfg1 = regs.config1();
    regs.set_config1(cfg1 & !0x10);

    // r8168_mac_ocp_modify(0xd40a, 0x0010, 0x0000) — disable UPS
    regs.mac_ocp_modify(0xD40A, 0x0010, 0x0000);

    regs.mac_ocp_write(0xC140, 0xFFFF);
    regs.mac_ocp_write(0xC142, 0xFFFF);

    regs.mac_ocp_modify(0xD3E2, 0x0FFF, 0x03A9);
    regs.mac_ocp_modify(0xD3E4, 0x00FF, 0x0000);
    regs.mac_ocp_modify(0xE860, 0x0000, 0x0080);

    // Critical for our 16-byte (legacy r8169) TX descriptors.
    regs.mac_ocp_modify(
        regs::MAC_OCP_NEW_TX_DESC,
        regs::MAC_OCP_NEW_TX_DESC_BIT0,
        0,
    );

    // VER_63 specific tuning.
    regs.mac_ocp_modify(0xE614, 0x0700, 0x0200);
    regs.mac_ocp_modify(0xE63E, 0x0C30, 0x0000);
    regs.mac_ocp_modify(0xC0B4, 0x0000, 0x000C);
    regs.mac_ocp_modify(0xEB6A, 0x00FF, 0x0033);
    regs.mac_ocp_modify(0xEB50, 0x03E0, 0x0040);
    regs.mac_ocp_modify(0xE056, 0x00F0, 0x0000);
    regs.mac_ocp_modify(0xE040, 0x1000, 0x0000);
    regs.mac_ocp_modify(0xEA1C, 0x0003, 0x0001);
    regs.mac_ocp_modify(0xEA1C, 0x0004, 0x0000);
    regs.mac_ocp_modify(0xE0C0, 0x4F0F, 0x4403);
    regs.mac_ocp_modify(0xE052, 0x0080, 0x0068);
    regs.mac_ocp_modify(0xD430, 0x0FFF, 0x047F);
    regs.mac_ocp_modify(0xEA1C, 0x0004, 0x0000);

    // Toggle 0xEB54 bit 0 (1 µs hold).
    regs.mac_ocp_modify(0xEB54, 0x0000, 0x0001);
    udelay(Delta::from_micros(1));
    regs.mac_ocp_modify(0xEB54, 0x0001, 0x0000);

    // Clear bits 4-5 of MMIO 0x1880 (16-bit).
    let val_1880 = regs.read_u16_at(0x1880);
    regs.write_u16_at(0x1880, val_1880 & !0x0030);

    // Final MAC OCP write + wait for chip to settle.
    regs.mac_ocp_write(0xE098, 0xC302);
    wait_mac_ocp_e00e_clear(regs)?;

    // rtl_disable_rxdvgate — RX_DV signal from PHY now reaches the MAC.
    let misc = regs.misc();
    regs.set_misc(misc & !regs::MISC_RXDV_GATED_EN);

    Ok(())
}

/// Hardware reset — mirrors r8169 `rtl_hw_reset`. Writes `CmdReset` to
/// `ChipCmd` and polls 100 × 100 µs for the bit to clear. If
/// `inject_timeout` is true, the early-exit check is suppressed so the poll
/// always times out (deliberate failure injection for the plan §7 M2 "failed
/// reset path is recoverable" gate).
pub(crate) fn reset(regs: &Regs<'_>, inject_timeout: bool) -> Result<()> {
    // Trigger the reset normally either way — skipping the write would make
    // the poll succeed immediately (the bit was never set) and silently mask
    // the failure-injection path. Instead, suppress the early-exit check so
    // the poll runs all 100 iterations and we return `EIO`. This exercises
    // the full 10 ms wait path that real hardware-wedged behavior would.
    regs.set_chip_cmd(regs::CMD_RESET);
    let step = Delta::from_micros(100);
    for _ in 0..100 {
        if !inject_timeout && (regs.chip_cmd() & regs::CMD_RESET) == 0 {
            return Ok(());
        }
        udelay(step);
    }
    Err(EIO)
}
