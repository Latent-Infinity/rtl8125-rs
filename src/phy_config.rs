// SPDX-License-Identifier: GPL-2.0
//! RTL8125B PHY errata configuration table (the register tunes mainline applies
//! in `rtl8125b_hw_phy_config`).
//!
//! The stock realtek phylib driver that binds our integrated PHY applies none of
//! these, so without them the analog/EEE/link errata the vendor prescribes are
//! missing. This module is the **declarative, kernel-free** source of truth for
//! the sequence (host-tested with `rustc --test`); the kernel-coupled applier in
//! `crate::phy` walks it and performs each register access through the phylib
//! paged/MMD accessors (which own PHY paging) via the unsafe boundary.
//!
//! Every entry targets the PHY (paged MDIO or MMD VEND2) — none is a MAC-OCP
//! write — so the whole table is pure data and trivially testable. The MCU
//! firmware patch that `rtl8125b_hw_phy_config` applies *before* this sequence is
//! handled separately (`crate::phy_fw`).
#![allow(dead_code)]

/// MDIO MMD device address for the Realtek vendor register block (`MDIO_MMD_VEND2`).
pub(crate) const MDIO_MMD_VEND2: u16 = 7;

/// One step of the PHY errata sequence, named after the mainline helper it
/// mirrors so the table reads 1:1 against `r8169_phy_config.c`.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum PhyOp {
    /// `phy_modify_paged(page, reg, mask, set)`.
    ModifyPaged {
        page: u16,
        reg: u16,
        mask: u16,
        set: u16,
    },
    /// `r8168g_phy_param`: on page 0x0a43, write reg 0x13 = `parm`, then modify
    /// reg 0x14 (mask/val).
    GParam { parm: u16, mask: u16, val: u16 },
    /// `rtl8125_phy_param`: on MMD VEND2, write reg 0xb87c = `parm`, then modify
    /// reg 0xb87e (mask/val).
    MmdParam { parm: u16, mask: u16, val: u16 },
}

/// `rtl8125b_hw_phy_config` errata sequence for MAC_VER_63, in apply order.
/// (The leading `r8169_apply_firmware` step is `crate::phy_fw`, applied before
/// this table.)
pub(crate) const HW_PHY_CONFIG: [PhyOp; 26] = [
    // rtl8168g_enable_gphy_10m
    PhyOp::ModifyPaged {
        page: 0x0a44,
        reg: 0x11,
        mask: 0x0000,
        set: 1 << 11,
    },
    PhyOp::ModifyPaged {
        page: 0x0ac4,
        reg: 0x13,
        mask: 0x00f0,
        set: 0x0090,
    },
    PhyOp::ModifyPaged {
        page: 0x0ad3,
        reg: 0x10,
        mask: 0x0003,
        set: 0x0001,
    },
    PhyOp::MmdParam {
        parm: 0x80f5,
        mask: 0xffff,
        val: 0x760e,
    },
    PhyOp::MmdParam {
        parm: 0x8107,
        mask: 0xffff,
        val: 0x360e,
    },
    PhyOp::MmdParam {
        parm: 0x8551,
        mask: 0xff00,
        val: 0x0800,
    },
    PhyOp::ModifyPaged {
        page: 0x0bf0,
        reg: 0x10,
        mask: 0xe000,
        set: 0xa000,
    },
    PhyOp::ModifyPaged {
        page: 0x0bf4,
        reg: 0x13,
        mask: 0x0f00,
        set: 0x0300,
    },
    PhyOp::GParam {
        parm: 0x8044,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x804a,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x8050,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x8056,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x805c,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x8062,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x8068,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x806e,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x8074,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::GParam {
        parm: 0x807a,
        mask: 0xffff,
        val: 0x2417,
    },
    PhyOp::ModifyPaged {
        page: 0x0a4c,
        reg: 0x15,
        mask: 0x0000,
        set: 0x0040,
    },
    PhyOp::ModifyPaged {
        page: 0x0bf8,
        reg: 0x12,
        mask: 0xe000,
        set: 0xa000,
    },
    // rtl8125_legacy_force_mode
    PhyOp::ModifyPaged {
        page: 0x0a5b,
        reg: 0x12,
        mask: 1 << 15,
        set: 0x0000,
    },
    // rtl8168g_disable_aldps
    PhyOp::ModifyPaged {
        page: 0x0a43,
        reg: 0x10,
        mask: 1 << 2,
        set: 0x0000,
    },
    // rtl8125_config_eee_phy -> rtl8168g_config_eee_phy
    PhyOp::ModifyPaged {
        page: 0x0a43,
        reg: 0x11,
        mask: 0x0000,
        set: 1 << 4,
    },
    // rtl8125_common_config_eee_phy
    PhyOp::ModifyPaged {
        page: 0x0a6d,
        reg: 0x14,
        mask: 0x0010,
        set: 0x0000,
    },
    PhyOp::ModifyPaged {
        page: 0x0a42,
        reg: 0x14,
        mask: 0x0080,
        set: 0x0000,
    },
    PhyOp::ModifyPaged {
        page: 0x0a4a,
        reg: 0x11,
        mask: 0x0200,
        set: 0x0000,
    },
];

/// A primitive PHY register access the applier performs through a phylib
/// accessor. The expansion from [`PhyOp`] to these is pure so it can be
/// host-tested without a device.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum PhyPrimitive {
    /// `phy_modify_paged(page, reg, mask, set)`.
    ModifyPaged {
        page: u16,
        reg: u16,
        mask: u16,
        set: u16,
    },
    /// `phy_write_paged(page, reg, val)`.
    WritePaged { page: u16, reg: u16, val: u16 },
    /// `phy_write_mmd(devad, reg, val)`.
    WriteMmd { devad: u16, reg: u16, val: u16 },
    /// `phy_modify_mmd(devad, reg, mask, set)`.
    ModifyMmd {
        devad: u16,
        reg: u16,
        mask: u16,
        set: u16,
    },
}

/// Expand one errata op into the ordered phylib-accessor primitives that
/// implement it (mirrors `r8168g_phy_param` / `rtl8125_phy_param`). Pure; calls
/// `emit` once per primitive in order.
#[inline]
pub(crate) fn expand<F: FnMut(PhyPrimitive)>(op: PhyOp, mut emit: F) {
    match op {
        PhyOp::ModifyPaged {
            page,
            reg,
            mask,
            set,
        } => emit(PhyPrimitive::ModifyPaged {
            page,
            reg,
            mask,
            set,
        }),
        PhyOp::GParam { parm, mask, val } => {
            emit(PhyPrimitive::WritePaged {
                page: 0x0a43,
                reg: 0x13,
                val: parm,
            });
            emit(PhyPrimitive::ModifyPaged {
                page: 0x0a43,
                reg: 0x14,
                mask,
                set: val,
            });
        }
        PhyOp::MmdParam { parm, mask, val } => {
            emit(PhyPrimitive::WriteMmd {
                devad: MDIO_MMD_VEND2,
                reg: 0xb87c,
                val: parm,
            });
            emit(PhyPrimitive::ModifyMmd {
                devad: MDIO_MMD_VEND2,
                reg: 0xb87e,
                mask,
                set: val,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn collect(op: PhyOp) -> Vec<PhyPrimitive> {
        let mut v = Vec::new();
        expand(op, |p| v.push(p));
        v
    }

    #[test]
    fn table_has_expected_shape() {
        assert_eq!(HW_PHY_CONFIG.len(), 26);
        // 10 GParam entries, all val 0x2417, parms 0x8044..0x807a step 6.
        let gparams: Vec<_> = HW_PHY_CONFIG
            .iter()
            .filter_map(|o| match o {
                PhyOp::GParam { parm, val, .. } => Some((*parm, *val)),
                _ => None,
            })
            .collect();
        assert_eq!(gparams.len(), 10);
        for (i, (parm, val)) in gparams.iter().enumerate() {
            assert_eq!(*parm, 0x8044 + (i as u16) * 6);
            assert_eq!(*val, 0x2417);
        }
        // 3 MMD params with the exact vendor values.
        let mmd: Vec<_> = HW_PHY_CONFIG
            .iter()
            .filter_map(|o| match o {
                PhyOp::MmdParam { parm, mask, val } => Some((*parm, *mask, *val)),
                _ => None,
            })
            .collect();
        assert_eq!(
            mmd,
            [
                (0x80f5, 0xffff, 0x760e),
                (0x8107, 0xffff, 0x360e),
                (0x8551, 0xff00, 0x0800)
            ]
        );
        // First op is enable_gphy_10m (page 0x0a44, reg 0x11, set BIT(11)).
        assert_eq!(
            HW_PHY_CONFIG[0],
            PhyOp::ModifyPaged {
                page: 0x0a44,
                reg: 0x11,
                mask: 0,
                set: 0x0800
            }
        );
    }

    #[test]
    fn expand_modify_paged_is_passthrough() {
        assert_eq!(
            collect(PhyOp::ModifyPaged {
                page: 0xbf0,
                reg: 0x10,
                mask: 0xe000,
                set: 0xa000
            }),
            [PhyPrimitive::ModifyPaged {
                page: 0xbf0,
                reg: 0x10,
                mask: 0xe000,
                set: 0xa000
            }]
        );
    }

    #[test]
    fn expand_gparam_writes_0x13_then_modifies_0x14_on_page_0a43() {
        assert_eq!(
            collect(PhyOp::GParam {
                parm: 0x8044,
                mask: 0xffff,
                val: 0x2417
            }),
            [
                PhyPrimitive::WritePaged {
                    page: 0x0a43,
                    reg: 0x13,
                    val: 0x8044
                },
                PhyPrimitive::ModifyPaged {
                    page: 0x0a43,
                    reg: 0x14,
                    mask: 0xffff,
                    set: 0x2417
                },
            ]
        );
    }

    #[test]
    fn expand_mmdparam_writes_0xb87c_then_modifies_0xb87e_on_vend2() {
        assert_eq!(
            collect(PhyOp::MmdParam {
                parm: 0x8551,
                mask: 0xff00,
                val: 0x0800
            }),
            [
                PhyPrimitive::WriteMmd {
                    devad: 7,
                    reg: 0xb87c,
                    val: 0x8551
                },
                PhyPrimitive::ModifyMmd {
                    devad: 7,
                    reg: 0xb87e,
                    mask: 0xff00,
                    set: 0x0800
                },
            ]
        );
    }
}
