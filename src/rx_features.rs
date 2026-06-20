// SPDX-License-Identifier: GPL-2.0
//! Pure RX feature-flag -> register-bit mapping (RXCSUM / RXVLAN / RXHASH).
//!
//! Maps the C<->Rust feature bitmask (mirrors `R8125_BRIDGE_FEATURE_*` in the
//! cshim header) onto the chip's RxConfig VLAN-strip bits and the CPlusCmd
//! RX-checksum bit. Kernel-free so the `ndo_set_features` toggle logic is
//! host-tested; `netdev.rs` pins the register values to `regs::` and supplies
//! the compile-time RXHASH gate.

/// C<->Rust feature bits (mirror `R8125_BRIDGE_FEATURE_*` in netdev_bridge.h).
pub(crate) const BRIDGE_FEATURE_RXCSUM: u32 = 0x0000_0001;
pub(crate) const BRIDGE_FEATURE_RXVLAN: u32 = 0x0000_0002;
pub(crate) const BRIDGE_FEATURE_RXHASH: u32 = 0x0000_0004;

/// RxConfig VLAN-strip bits (inner|outer); pinned to `regs::RX_VLAN_8125`.
pub(crate) const RX_VLAN_8125: u32 = (1 << 22) | (1 << 23);
/// CPlusCmd RX-checksum bit; pinned to `regs::CPLUSCMD_RX_CHKSUM`.
pub(crate) const CPLUSCMD_RX_CHKSUM: u16 = 0x0020;

/// RxConfig with the VLAN-strip bits set/cleared per the RXVLAN feature flag,
/// preserving every other bit in `base`.
pub(crate) fn rx_feature_rcr(base: u32, feature_flags: u32) -> u32 {
    if feature_flags & BRIDGE_FEATURE_RXVLAN != 0 {
        base | RX_VLAN_8125
    } else {
        base & !RX_VLAN_8125
    }
}

/// CPlusCmd RX-checksum bit per the RXCSUM feature flag.
pub(crate) fn rx_feature_cpluscmd(feature_flags: u32) -> u16 {
    if feature_flags & BRIDGE_FEATURE_RXCSUM != 0 {
        CPLUSCMD_RX_CHKSUM
    } else {
        0
    }
}

/// RXHASH is on iff the compile-time `gate` AND the runtime feature flag are set.
/// `gate` is `netdev::RXHASH_FEATURE_GATE`, kept there so the build-time switch
/// stays with the rest of the netdev feature wiring.
pub(crate) fn rxhash_enabled(gate: bool, feature_flags: u32) -> bool {
    gate && (feature_flags & BRIDGE_FEATURE_RXHASH != 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rcr_sets_and_clears_vlan_strip() {
        // off base -> sets both strip bits.
        assert_eq!(rx_feature_rcr(0, BRIDGE_FEATURE_RXVLAN), RX_VLAN_8125);
        // preserves unrelated base bits; clears the strip bits when off.
        let base = 0x0000_00ff | RX_VLAN_8125;
        assert_eq!(rx_feature_rcr(base, 0), 0x0000_00ff);
        assert_eq!(rx_feature_rcr(base, BRIDGE_FEATURE_RXVLAN), base);
        // a different feature flag does not touch the VLAN bits.
        assert_eq!(rx_feature_rcr(0, BRIDGE_FEATURE_RXCSUM), 0);
    }

    #[test]
    fn cpluscmd_csum_bit_gated_by_flag() {
        assert_eq!(
            rx_feature_cpluscmd(BRIDGE_FEATURE_RXCSUM),
            CPLUSCMD_RX_CHKSUM
        );
        assert_eq!(rx_feature_cpluscmd(0), 0);
        assert_eq!(rx_feature_cpluscmd(BRIDGE_FEATURE_RXVLAN), 0);
    }

    #[test]
    fn rxhash_needs_both_gate_and_flag() {
        assert!(rxhash_enabled(true, BRIDGE_FEATURE_RXHASH));
        assert!(!rxhash_enabled(false, BRIDGE_FEATURE_RXHASH)); // gate off
        assert!(!rxhash_enabled(true, 0)); // flag off
        assert!(!rxhash_enabled(true, BRIDGE_FEATURE_RXCSUM)); // wrong flag
    }
}
