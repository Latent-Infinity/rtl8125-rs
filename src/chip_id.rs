// SPDX-License-Identifier: GPL-2.0
//! Pure chip identification: XID decode + the dispatch-table match.
//!
//! Kernel-free on purpose so the device-acceptance gate ("no silent fallback")
//! is host-tested standalone via `rustc --test`. The MMIO read of `TxConfig`
//! and the `pci::Driver::probe` glue stay in [`crate::hw`], which calls
//! [`match_chip`]/[`xid_from_tx_config`] and pins `XID_SHIFT`/`XID_MASK`/the
//! jumbo cap to the canonical `regs::` values with compile-time asserts.

/// XID extraction shift/mask (r8169 `rtl8169_get_chip_version` formula:
/// `xid = (TxConfig >> XID_SHIFT) & XID_MASK`). Pinned to `regs::` in `hw.rs`.
pub(crate) const XID_SHIFT: u32 = 20;
pub(crate) const XID_MASK: u32 = 0xfcf;

/// MAC version, named to track r8169's `RTL_GIGA_MAC_VER_*`. Only the
/// validated sub-revision is listed; adding a variant is the supported (and
/// strictly-reviewed) way to claim a new chip.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum MacVersion {
    /// RTL8125B (XID 0x641 / `RTL_GIGA_MAC_VER_63`).
    Rtl8125B,
}

/// One dispatch-table row. `(xid & mask) == val` decides the match, exactly the
/// r8169 predicate.
#[derive(Copy, Clone)]
pub(crate) struct ChipInfo {
    pub(crate) mask: u32,
    pub(crate) val: u32,
    pub(crate) mac_version: MacVersion,
    pub(crate) name: &'static str,
    /// Per-revision jumbo cap (advertised max). Pinned to `regs::JUMBO_9K_BYTES`.
    #[allow(dead_code)]
    pub(crate) max_mtu: usize,
}

/// Advertised jumbo cap for RTL8125B. Pinned to `regs::JUMBO_9K_BYTES` in `hw.rs`.
const RTL8125B_MAX_MTU: usize = 9000;

/// Known-chip dispatch table — the validated entry only. Adding a row is the
/// supported way to support a new RTL8125 sub-revision.
pub(crate) const KNOWN: &[ChipInfo] = &[ChipInfo {
    mask: 0x7cf,
    val: 0x641,
    mac_version: MacVersion::Rtl8125B,
    name: "RTL8125B",
    max_mtu: RTL8125B_MAX_MTU,
}];

/// Extract the XID from a raw `TxConfig` value.
pub(crate) fn xid_from_tx_config(tx_config: u32) -> u32 {
    (tx_config >> XID_SHIFT) & XID_MASK
}

/// Match a decoded XID against [`KNOWN`]. `Some(info)` for a supported chip,
/// `None` otherwise (probe turns `None` into `-ENODEV`).
pub(crate) fn match_chip(xid: u32) -> Option<&'static ChipInfo> {
    KNOWN.iter().find(|info| (xid & info.mask) == info.val)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn xid_decode_formula() {
        // RTL8125B XID 0x641 sitting in the TxConfig XID field.
        assert_eq!(xid_from_tx_config(0x641 << XID_SHIFT), 0x641);
        // Bits outside XID_MASK are dropped: 0x7ff -> 0x7cf (& 0xfcf).
        assert_eq!(xid_from_tx_config(0x7ff << XID_SHIFT), 0x7ff & XID_MASK);
        // Bits below the XID field are ignored.
        assert_eq!(xid_from_tx_config((0x641 << XID_SHIFT) | 0xfffff), 0x641);
    }

    #[test]
    fn accepts_the_validated_chip() {
        let info = match_chip(0x641).expect("0x641 is RTL8125B");
        assert_eq!(info.mac_version, MacVersion::Rtl8125B);
        assert_eq!(info.name, "RTL8125B");
    }

    #[test]
    fn masked_match_dont_care_vs_significant_bits() {
        // The table mask 0x7cf clears bits 4, 5, 11 — those are "don't care".
        assert!(match_chip(0x641 | 0x010).is_some()); // bit 4: don't care
        assert!(match_chip(0x641 | 0x020).is_some()); // bit 5: don't care
                                                      // A bit that IS in the mask (e.g. 0x008) is significant: setting it fails.
        assert!(match_chip(0x641 | 0x008).is_none());
    }

    #[test]
    fn rejects_neighbors_no_silent_fallback() {
        // A one-bit-off XID inside the mask must NOT match (no silent fallback).
        assert!(match_chip(0x640).is_none());
        assert!(match_chip(0x643).is_none());
        assert!(match_chip(0x741).is_none()); // 0x741 & 0x7cf = 0x741 != 0x641
        assert!(match_chip(0x000).is_none());
        assert!(match_chip(0xfff).is_none());
    }

    #[test]
    fn end_to_end_unknown_chip_is_rejected() {
        // A plausible-but-unsupported XID decoded from TxConfig -> None.
        let bogus = match_chip(xid_from_tx_config(0x500 << XID_SHIFT));
        assert!(bogus.is_none());
    }
}
