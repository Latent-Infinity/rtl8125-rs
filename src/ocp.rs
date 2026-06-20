// SPDX-License-Identifier: GPL-2.0
//! Pure OCP / MDIO address + command-word arithmetic (8125 family).
//!
//! The MMIO accessors in `crate::mmio` do the register I/O; the *address math*
//! — the MII page-adjust and the OCP command-word packing — is pure and lives
//! here so the non-obvious non-standard-page register adjust is host-tested by
//! value. `mmio.rs` pins `OCPAR_FLAG` / `OCP_STD_PHY_BASE` to the canonical
//! `regs::` values and routes all four OCP accessors through these helpers
//! (also de-duplicating the packing that was repeated across MAC-OCP and
//! GPHY-OCP).

/// OCP "go" flag in the command word (also the read-complete poll bit).
pub(crate) const OCPAR_FLAG: u32 = 0x8000_0000;
/// Standard PHY page base: MII register `n` lives at `OCP_STD_PHY_BASE + n*2`.
pub(crate) const OCP_STD_PHY_BASE: u32 = 0xA400;

/// MII register -> OCP address. On a NON-standard page, r8169 (`r8168g_mdio_*`)
/// subtracts 0x10 from registers >= 0x10 before scaling; the standard page (and
/// registers below 0x10 on any page) are used as-is. Then `base + reg*2`.
pub(crate) fn mdio_ocp_addr(ocp_base: u32, reg: u8) -> u32 {
    let reg_adj = if ocp_base != OCP_STD_PHY_BASE && reg >= 0x10 {
        reg - 0x10
    } else {
        reg
    };
    ocp_base + u32::from(reg_adj) * 2
}

/// OCP WRITE command word: flag | (addr << 15) | data. Shared by MAC-OCP and
/// GPHY-OCP writes. `addr & 0xFFFF` keeps the shift within 32 bits.
pub(crate) fn ocp_write_cmd(addr: u32, data: u16) -> u32 {
    OCPAR_FLAG | ((addr & 0xFFFF) << 15) | u32::from(data)
}

/// OCP READ command word: (addr << 15), no flag/data. Shared by MAC/GPHY reads.
pub(crate) fn ocp_read_cmd(addr: u32) -> u32 {
    (addr & 0xFFFF) << 15
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn standard_page_is_not_adjusted() {
        // base == OCP_STD_PHY_BASE: every reg used as-is, scaled by 2.
        assert_eq!(mdio_ocp_addr(OCP_STD_PHY_BASE, 0x00), 0xA400);
        assert_eq!(mdio_ocp_addr(OCP_STD_PHY_BASE, 0x0F), 0xA400 + 0x0F * 2);
        assert_eq!(mdio_ocp_addr(OCP_STD_PHY_BASE, 0x10), 0xA400 + 0x10 * 2);
        assert_eq!(mdio_ocp_addr(OCP_STD_PHY_BASE, 0x1F), 0xA400 + 0x1F * 2);
    }

    #[test]
    fn non_standard_page_adjusts_high_regs() {
        let base = 0xA000;
        // reg >= 0x10 -> subtract 0x10 then scale.
        assert_eq!(mdio_ocp_addr(base, 0x10), base); // (0x10-0x10)*2 = 0
        assert_eq!(mdio_ocp_addr(base, 0x12), base + 0x02 * 2);
        assert_eq!(mdio_ocp_addr(base, 0x1F), base + 0x0F * 2);
        // reg < 0x10 is NOT adjusted even on a non-standard page.
        assert_eq!(mdio_ocp_addr(base, 0x00), base);
        assert_eq!(mdio_ocp_addr(base, 0x0F), base + 0x0F * 2);
    }

    #[test]
    fn write_cmd_packs_flag_addr_data() {
        let cmd = ocp_write_cmd(0xA420, 0x1234);
        assert_ne!(cmd & OCPAR_FLAG, 0, "write sets the go flag");
        assert_eq!(cmd & 0xFFFF, 0x1234, "data in the low 16 bits");
        assert_eq!((cmd >> 15) & 0xFFFF, 0xA420, "addr in the addr field");
    }

    #[test]
    fn read_cmd_has_no_flag_or_data() {
        let cmd = ocp_read_cmd(0xA420);
        assert_eq!(cmd & OCPAR_FLAG, 0, "read does not set the go flag");
        assert_eq!(cmd & 0xFFFF, 0, "no data on a read command");
        assert_eq!((cmd >> 15) & 0xFFFF, 0xA420, "addr in the addr field");
    }

    #[test]
    fn addr_field_never_overflows_u32() {
        // Max 16-bit addr shifted left 15 must stay below the flag bit.
        assert!(ocp_read_cmd(0xFFFF) < OCPAR_FLAG);
    }
}
