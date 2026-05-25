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

/// Hardware reset — mirrors r8169 `rtl_hw_reset`. Writes `CmdReset` to
/// `ChipCmd` and polls 100 × 100 µs for the bit to clear. If
/// `inject_timeout` is true, the write is suppressed so the poll always
/// times out (deliberate failure injection for the plan §7 M2 "failed
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
