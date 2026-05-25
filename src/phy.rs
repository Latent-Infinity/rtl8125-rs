// SPDX-License-Identifier: GPL-2.0
//! PHY MDIO transaction logic — the page-aware MII → OCP translation.
//!
//! Architecture: the cshim owns the kernel-side `struct mii_bus` and the
//! attached `struct phy_device`; Rust owns the BAR mapping. The two
//! `mii_bus->{read,write}` callbacks dispatch into Rust extern "C"
//! shims in `unsafe_boundary` (where `#[no_mangle]` is allowed), which
//! call the safe helpers below. This file holds the page handling and
//! the MMIO translation — no `unsafe` lives here.
//!
//! Page register (MII 0x1F) per r8169 `r8168g_mdio_write`: writing it
//! updates `NetdevState::ocp_base` instead of poking a real PHY
//! register, and subsequent MII access routes through that page.
//!
//! Plan §7 M4-traffic (PHY init blocking task 46).

use core::sync::atomic::Ordering;

use crate::netdev::NetdevState;
use crate::regs;

/// Returns the MII page-register `read` result per r8169 convention:
/// `0` when on the standard page, else `ocp_base >> 4`.
#[inline]
pub(crate) fn page_select_read(state: &NetdevState) -> u16 {
    let base = state.ocp_base.load(Ordering::Acquire);
    if base == regs::OCP_STD_PHY_BASE {
        0
    } else {
        ((base >> 4) & 0xFFFF) as u16
    }
}

/// Update the page-base from an MDIO write to MII reg 0x1F.
#[inline]
pub(crate) fn page_select_write(state: &NetdevState, val: u16) {
    let new_base = if val == 0 {
        regs::OCP_STD_PHY_BASE
    } else {
        (val as u32) << 4
    };
    state.ocp_base.store(new_base, Ordering::Release);
}

/// Generic MDIO read against the current page.
pub(crate) fn mdio_read(state: &NetdevState, reg: u8) -> kernel::error::Result<u16> {
    let base = state.ocp_base.load(Ordering::Acquire);
    state.regs().mdio_read(base, reg)
}

/// Generic MDIO write against the current page.
pub(crate) fn mdio_write(state: &NetdevState, reg: u8, val: u16) -> kernel::error::Result<()> {
    let base = state.ocp_base.load(Ordering::Acquire);
    state.regs().mdio_write(base, reg, val)
}
