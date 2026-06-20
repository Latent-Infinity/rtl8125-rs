// SPDX-License-Identifier: GPL-2.0
//! TX hardware-offload descriptor-bit POLICY (checksum-v2 + TSO), in Rust.
//!
//! Per RUST_STANDARDS.md "chip policy and descriptor logic belong in Rust": the
//! C shim (`netdev_bridge_offload.c`) only does the skb introspection and the
//! kernel side effects that need kernel APIs (reading ip_summed / gso_type /
//! transport offset / VLAN, the UDP/PTP pad quirk, `skb_cow_head`,
//! `tcp_v6_gso_csum_prep`, `__skb_put_padto`, `skb_checksum_help`). It gathers
//! the protocol FACTS into [`Facts`], calls [`r8125_tx_offload_decide`], and then
//! applies the returned [`Decision`] (the descriptor opts1/opts2 bits + which
//! side effect to run). All the chip-specific bit values, field shifts and field
//! limits live here and are host-tested by value.
//!
//! Bit layout cross-checked against upstream `r8169_main.c`
//! (`enum rtl_tx_desc_bit_1`) and the Realtek vendor `r8125_n.c` — they agree.
//! The historically-bitten case (the 11-bit MSS field overflow) is pinned by the
//! `mss`/`transport_offset` limit checks + tests below.

// ---- chip descriptor-bit policy (opts2 checksum-v2 bits) --------------------
const TD1_IPV6_CS: u32 = 1 << 28;
const TD1_IPV4_CS: u32 = 1 << 29;
const TD1_TCP_CS: u32 = 1 << 30;
const TD1_UDP_CS: u32 = 1 << 31;
const TCPHO_SHIFT: u32 = 18;
const TCPHO_MAX: u32 = 0x3ff;
const TX_VLAN_TAG: u32 = 1 << 17;

// ---- chip descriptor-bit policy (TSO / giant-send) --------------------------
const TD1_GTSENV6: u32 = 1 << 25;
const TD1_GTSENV4: u32 = 1 << 26;
const GTTCPHO_SHIFT: u32 = 18;
const GTTCPHO_MAX: u32 = 0x7f;
const MSS_SHIFT: u32 = 18; // opts2 MSS field (11 bits)
const MSS_MAX: u32 = 0x7ff;

/// Minimum Ethernet frame for the short-frame pad decision.
const ETH_ZLEN: u32 = 60;
/// Standard Ethernet data MTU. Jumbo MTU can produce TCP MSS values that exceed
/// the RTL8125B descriptor field; disable affected offloads above this value.
const ETH_DATA_LEN: u32 = 1500;

// ---- Facts flag bits (filled by the C shim) --------------------------------
/// `skb->ip_summed == CHECKSUM_PARTIAL`.
pub(crate) const F_CSUM_PARTIAL: u32 = 1 << 0;
/// `skb_shinfo(skb)->gso_size != 0`.
pub(crate) const F_IS_GSO: u32 = 1 << 1;
/// `gso_type & SKB_GSO_TCPV4`.
pub(crate) const F_GSO_TCPV4: u32 = 1 << 2;
/// `gso_type & SKB_GSO_TCPV6`.
pub(crate) const F_GSO_TCPV6: u32 = 1 << 3;
/// `skb_vlan_tag_present(skb)`.
pub(crate) const F_VLAN: u32 = 1 << 4;

/// L3 protocol (from `vlan_get_protocol`): 4 = IPv4, 6 = IPv6, 0 = other.
const L3_V4: u32 = 4;
const L3_V6: u32 = 6;
/// L4 protocol: 6 = TCP, 17 = UDP, 0/other = neither (IPPROTO_*).
const L4_TCP: u32 = 6;
const L4_UDP: u32 = 17;

// ---- Decision actions -------------------------------------------------------
/// No HW offload; C pads to `padto` if non-zero, writes `opts2` (VLAN only).
pub(crate) const ACT_NOOFFLOAD: u32 = 0;
/// HW checksum; C writes `opts1`/`opts2`, no pad.
pub(crate) const ACT_CSUM: u32 = 1;
/// HW TSO; C runs v6 csum-prep if `D_NEED_V6_CSUM_PREP`, writes `opts1`/`opts2`.
pub(crate) const ACT_TSO: u32 = 2;
/// Software checksum; C pads to `padto` then `skb_checksum_help`, writes `opts2`.
pub(crate) const ACT_SWFALLBACK: u32 = 3;
/// Drop (chip cannot offload this GSO frame); C returns -EIO.
pub(crate) const ACT_DROP: u32 = 4;

/// Decision flag: the TSO frame needs `skb_cow_head` + `tcp_v6_gso_csum_prep`.
pub(crate) const D_NEED_V6_CSUM_PREP: u32 = 1 << 0;

/// Protocol facts gathered by the C shim. All-`u32` for a padding-free C ABI
/// (matches `struct r8125_tx_offload_facts` in `netdev_bridge_internal.h`).
#[repr(C)]
#[derive(Copy, Clone)]
pub(crate) struct Facts {
    pub(crate) flags: u32,
    pub(crate) len: u32,
    pub(crate) l3: u32,
    pub(crate) l4: u32,
    pub(crate) transport_offset: u32,
    pub(crate) mss: u32,
    /// UDP/PTP pad quirk length the C shim computed (0 unless it applies).
    pub(crate) udp_quirk_padto: u32,
    /// Raw `skb_vlan_tag_get` value (byte-swapped here, not in C).
    pub(crate) vlan_tag: u32,
}

/// Descriptor-bit decision returned to the C shim (matches
/// `struct r8125_tx_offload_decision`).
#[repr(C)]
#[derive(Copy, Clone)]
pub(crate) struct Decision {
    pub(crate) action: u32,
    pub(crate) opts1: u32,
    pub(crate) opts2: u32,
    pub(crate) padto: u32,
    pub(crate) flags: u32,
}

impl Decision {
    const fn new(action: u32, opts1: u32, opts2: u32, padto: u32, flags: u32) -> Self {
        Self {
            action,
            opts1,
            opts2,
            padto,
            flags,
        }
    }
}

/// VLAN opts2 contribution: the tag bit + the byte-swapped 16-bit tag (the
/// `swab16` the C shim used to do inline).
fn vlan_opts(f: &Facts) -> u32 {
    if f.flags & F_VLAN != 0 {
        TX_VLAN_TAG | u32::from((f.vlan_tag as u16).swap_bytes())
    } else {
        0
    }
}

/// Decide the TX offload descriptor bits + the side effect the C shim must run.
/// Pure: a faithful port of the old C `r8125_bridge_skb_tx_offload_prepare`
/// policy, with the skb side effects lifted out to the caller.
pub(crate) fn decide(f: &Facts) -> Decision {
    let vlan = vlan_opts(f);

    // ---- GSO / TSO path -----------------------------------------------------
    if f.flags & F_IS_GSO != 0 {
        // mss==0 or a transport header the chip can't reach => can't TSO; the
        // old code returned -EIO (drop) for these, not a software fallback.
        if f.mss == 0 || f.mss > MSS_MAX || f.transport_offset > GTTCPHO_MAX {
            return Decision::new(ACT_DROP, 0, 0, 0, 0);
        }
        let (gtsen, need_v6) = if f.flags & F_GSO_TCPV4 != 0 {
            (TD1_GTSENV4, 0)
        } else if f.flags & F_GSO_TCPV6 != 0 {
            (TD1_GTSENV6, D_NEED_V6_CSUM_PREP)
        } else {
            // Non-TCP GSO (UDP frag, GRE, ...): chip can't TSO it.
            return Decision::new(ACT_DROP, 0, 0, 0, 0);
        };
        let opts1 = gtsen | (f.transport_offset << GTTCPHO_SHIFT);
        let opts2 = (f.mss << MSS_SHIFT) | vlan;
        return Decision::new(ACT_TSO, opts1, opts2, 0, need_v6);
    }

    // ---- checksum / non-GSO path -------------------------------------------
    let padto0 = if f.len < ETH_ZLEN { ETH_ZLEN } else { 0 };

    // Not a HW-checksum frame: maybe pad, no csum bits.
    if f.flags & F_CSUM_PARTIAL == 0 {
        return Decision::new(ACT_NOOFFLOAD, 0, vlan, padto0, 0);
    }

    let (mut opts2, proto) = match f.l3 {
        L3_V4 => (TD1_IPV4_CS, f.l4),
        L3_V6 => (TD1_IPV6_CS, f.l4),
        _ => return Decision::new(ACT_SWFALLBACK, 0, vlan, padto0, 0),
    };

    // Transport header too far in for the csum-v2 TCPHO field.
    if f.transport_offset > TCPHO_MAX {
        return Decision::new(ACT_SWFALLBACK, 0, vlan, padto0, 0);
    }

    let padto = match proto {
        L4_TCP => {
            // A short TCP frame needing a pad can't use HW csum (the pad would
            // be added after the chip computed the csum) -> software fallback.
            if padto0 != 0 {
                return Decision::new(ACT_SWFALLBACK, 0, vlan, padto0, 0);
            }
            opts2 |= TD1_TCP_CS;
            0
        }
        L4_UDP => {
            let p = core::cmp::max(padto0, f.udp_quirk_padto);
            if p != 0 {
                return Decision::new(ACT_SWFALLBACK, 0, vlan, p, 0);
            }
            opts2 |= TD1_UDP_CS;
            0
        }
        _ => return Decision::new(ACT_SWFALLBACK, 0, vlan, padto0, 0),
    };
    let _ = padto;

    opts2 |= f.transport_offset << TCPHO_SHIFT;
    opts2 |= vlan;
    Decision::new(ACT_CSUM, 0, opts2, 0, 0)
}

/// Per-skb feature veto for offloads whose descriptor fields cannot encode this
/// packet. The C shim supplies the current kernel feature mask plus the kernel's
/// `NETIF_F_ALL_TSO` / `NETIF_F_CSUM_MASK` values; the RTL8125-specific decision
/// (which skb facts overflow the chip fields) stays here with the TX descriptor
/// policy and its host tests.
pub(crate) fn features_check(
    f: &Facts,
    mut features: u64,
    all_tso_mask: u64,
    csum_mask: u64,
) -> u64 {
    if f.flags & F_IS_GSO != 0 && f.transport_offset > GTTCPHO_MAX {
        features &= !all_tso_mask;
    } else if f.flags & F_CSUM_PARTIAL != 0 && (f.len < ETH_ZLEN || f.transport_offset > TCPHO_MAX)
    {
        features &= !csum_mask;
    }
    features
}

/// Feature mask repair for MTU-dependent descriptor limits. At jumbo MTU the
/// TCP MSS can exceed the RTL8125B 11-bit MSS field, so TSO and TX checksum
/// offloads are disabled and the stack segments/checksums in software.
pub(crate) fn fix_features(mtu: u32, mut features: u64, all_tso_mask: u64, csum_mask: u64) -> u64 {
    if mtu > ETH_DATA_LEN {
        features &= !all_tso_mask;
        features &= !csum_mask;
    }
    features
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts() -> Facts {
        Facts {
            flags: 0,
            len: 1500,
            l3: 0,
            l4: 0,
            transport_offset: 34,
            mss: 0,
            udp_quirk_padto: 0,
            vlan_tag: 0,
        }
    }

    #[test]
    fn plain_frame_no_offload() {
        let d = decide(&facts());
        assert_eq!(d.action, ACT_NOOFFLOAD);
        assert_eq!(d.opts2, 0);
        assert_eq!(d.padto, 0);
    }

    #[test]
    fn short_frame_pads() {
        let mut f = facts();
        f.len = 40;
        let d = decide(&f);
        assert_eq!(d.action, ACT_NOOFFLOAD);
        assert_eq!(d.padto, ETH_ZLEN);
    }

    #[test]
    fn ipv4_tcp_csum() {
        let mut f = facts();
        f.flags = F_CSUM_PARTIAL;
        f.l3 = L3_V4;
        f.l4 = L4_TCP;
        f.transport_offset = 34;
        let d = decide(&f);
        assert_eq!(d.action, ACT_CSUM);
        assert_eq!(d.opts2 & TD1_IPV4_CS, TD1_IPV4_CS);
        assert_eq!(d.opts2 & TD1_TCP_CS, TD1_TCP_CS);
        assert_eq!(d.opts2 >> TCPHO_SHIFT & 0x3ff, 34);
    }

    #[test]
    fn ipv6_udp_csum() {
        let mut f = facts();
        f.flags = F_CSUM_PARTIAL;
        f.l3 = L3_V6;
        f.l4 = L4_UDP;
        f.transport_offset = 54;
        let d = decide(&f);
        assert_eq!(d.action, ACT_CSUM);
        assert_eq!(d.opts2 & TD1_IPV6_CS, TD1_IPV6_CS);
        assert_eq!(d.opts2 & TD1_UDP_CS, TD1_UDP_CS);
    }

    #[test]
    fn transport_offset_too_far_falls_back() {
        let mut f = facts();
        f.flags = F_CSUM_PARTIAL;
        f.l3 = L3_V4;
        f.l4 = L4_TCP;
        f.transport_offset = TCPHO_MAX + 1;
        let d = decide(&f);
        assert_eq!(d.action, ACT_SWFALLBACK);
        assert_eq!(d.opts2, 0); // no csum bits, VLAN only (none here)
    }

    #[test]
    fn non_ip_l3_falls_back() {
        let mut f = facts();
        f.flags = F_CSUM_PARTIAL;
        f.l3 = 0; // not IP/IPv6
        let d = decide(&f);
        assert_eq!(d.action, ACT_SWFALLBACK);
    }

    #[test]
    fn short_tcp_csum_falls_back_to_sw() {
        let mut f = facts();
        f.flags = F_CSUM_PARTIAL;
        f.l3 = L3_V4;
        f.l4 = L4_TCP;
        f.len = 40; // padto = ETH_ZLEN -> TCP can't HW csum
        let d = decide(&f);
        assert_eq!(d.action, ACT_SWFALLBACK);
        assert_eq!(d.padto, ETH_ZLEN);
    }

    #[test]
    fn udp_quirk_padto_forces_sw() {
        let mut f = facts();
        f.flags = F_CSUM_PARTIAL;
        f.l3 = L3_V4;
        f.l4 = L4_UDP;
        f.len = 100; // padto0 = 0
        f.udp_quirk_padto = 110; // quirk forces a pad -> sw fallback
        let d = decide(&f);
        assert_eq!(d.action, ACT_SWFALLBACK);
        assert_eq!(d.padto, 110);
    }

    #[test]
    fn tso_ipv4() {
        let mut f = facts();
        f.flags = F_IS_GSO | F_GSO_TCPV4;
        f.mss = 1448;
        f.transport_offset = 34;
        let d = decide(&f);
        assert_eq!(d.action, ACT_TSO);
        assert_eq!(d.opts1 & TD1_GTSENV4, TD1_GTSENV4);
        assert_eq!(d.opts1 >> GTTCPHO_SHIFT & 0x7f, 34);
        assert_eq!(d.opts2 >> MSS_SHIFT & 0x7ff, 1448);
        assert_eq!(d.flags & D_NEED_V6_CSUM_PREP, 0);
    }

    #[test]
    fn tso_ipv6_needs_csum_prep() {
        let mut f = facts();
        f.flags = F_IS_GSO | F_GSO_TCPV6;
        f.mss = 1428;
        f.transport_offset = 54;
        let d = decide(&f);
        assert_eq!(d.action, ACT_TSO);
        assert_eq!(d.opts1 & TD1_GTSENV6, TD1_GTSENV6);
        assert_eq!(d.flags & D_NEED_V6_CSUM_PREP, D_NEED_V6_CSUM_PREP);
    }

    #[test]
    fn tso_transport_offset_too_far_drops() {
        let mut f = facts();
        f.flags = F_IS_GSO | F_GSO_TCPV4;
        f.mss = 1448;
        f.transport_offset = GTTCPHO_MAX + 1; // chip GTTCPHO field can't reach
        let d = decide(&f);
        assert_eq!(d.action, ACT_DROP);
    }

    #[test]
    fn tso_mss_too_large_drops_before_bitfield_overflow() {
        let mut f = facts();
        f.flags = F_IS_GSO | F_GSO_TCPV4;
        f.mss = MSS_MAX + 1;
        f.transport_offset = 34;
        let d = decide(&f);
        assert_eq!(d.action, ACT_DROP);
    }

    #[test]
    fn tso_non_tcp_gso_drops() {
        let mut f = facts();
        f.flags = F_IS_GSO; // neither TCPV4 nor TCPV6
        f.mss = 1448;
        f.transport_offset = 34;
        let d = decide(&f);
        assert_eq!(d.action, ACT_DROP);
    }

    #[test]
    fn vlan_tag_swab_and_bit() {
        let mut f = facts();
        f.flags = F_VLAN; // not csum, not gso
        f.vlan_tag = 0x0102;
        let d = decide(&f);
        // NOOFFLOAD with VLAN: tag bit + byte-swapped tag.
        assert_eq!(d.opts2 & TX_VLAN_TAG, TX_VLAN_TAG);
        assert_eq!(d.opts2 & 0xffff, 0x0201);
    }

    #[test]
    fn vlan_rides_on_csum() {
        let mut f = facts();
        f.flags = F_CSUM_PARTIAL | F_VLAN;
        f.l3 = L3_V4;
        f.l4 = L4_TCP;
        f.vlan_tag = 0x00aa;
        let d = decide(&f);
        assert_eq!(d.action, ACT_CSUM);
        assert_eq!(d.opts2 & TX_VLAN_TAG, TX_VLAN_TAG);
        assert_eq!(d.opts2 & TD1_TCP_CS, TD1_TCP_CS);
    }

    #[test]
    fn features_check_clears_tso_when_gso_header_offset_exceeds_chip_field() {
        let mut f = facts();
        f.flags = F_IS_GSO | F_GSO_TCPV4;
        f.transport_offset = GTTCPHO_MAX + 1;
        let all_tso = 0b0011_0000u64;
        let csum = 0b1100_0000u64;
        let out = features_check(&f, all_tso | csum | 0b1, all_tso, csum);
        assert_eq!(out & all_tso, 0);
        assert_eq!(out & csum, csum);
        assert_eq!(out & 0b1, 0b1);
    }

    #[test]
    fn features_check_clears_csum_for_short_or_far_partial_checksum() {
        let all_tso = 0b0011_0000u64;
        let csum = 0b1100_0000u64;

        let mut short = facts();
        short.flags = F_CSUM_PARTIAL;
        short.len = ETH_ZLEN - 1;
        assert_eq!(
            features_check(&short, all_tso | csum, all_tso, csum) & csum,
            0
        );

        let mut far = facts();
        far.flags = F_CSUM_PARTIAL;
        far.transport_offset = TCPHO_MAX + 1;
        assert_eq!(
            features_check(&far, all_tso | csum, all_tso, csum) & csum,
            0
        );
    }

    #[test]
    fn features_check_leaves_encodable_packets_unchanged() {
        let all_tso = 0b0011_0000u64;
        let csum = 0b1100_0000u64;
        let features = all_tso | csum | 0b101;
        assert_eq!(features_check(&facts(), features, all_tso, csum), features);
    }

    #[test]
    fn fix_features_disables_tso_and_csum_above_standard_mtu() {
        let all_tso = 0b0011_0000u64;
        let csum = 0b1100_0000u64;
        let other = 0b101u64;
        assert_eq!(
            fix_features(9000, all_tso | csum | other, all_tso, csum),
            other
        );
    }

    #[test]
    fn fix_features_keeps_standard_mtu_unchanged() {
        let all_tso = 0b0011_0000u64;
        let csum = 0b1100_0000u64;
        let features = all_tso | csum | 0b101;
        assert_eq!(
            fix_features(ETH_DATA_LEN, features, all_tso, csum),
            features
        );
    }
}
