// SPDX-License-Identifier: GPL-2.0
/*
 * HW offload helpers for r8125_rust (M4-perf, task 48).
 *
 * Rust hot-path doesn't peek into sk_buff internals. This file holds the
 * protocol introspection: TX checksum bit selection, RX checksum result
 * reporting, and netdev->stats counter accounting. Split from
 * netdev_bridge.c so that file stays under the 400-line review cap.
 *
 * Bit layout cross-checked against BOTH upstream r8169_main.c
 * (enum rtl_tx_desc_bit_1 lines 605-620, rtl_rx_desc_bit lines 622-638)
 * AND the Realtek vendor r8125_n.c source (r8125.h lines 1878-1892).
 * The two agree.
 */

#include "netdev_bridge_internal.h"

#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/netdevice.h>
#include <linux/skbuff.h>
#include <linux/tcp.h>
#include <linux/udp.h>

/* TX descriptor opts2 bits (8125 family). */
#define R8125_TD1_IPV6_CS	BIT(28)
#define R8125_TD1_IPV4_CS	BIT(29)
#define R8125_TD1_TCP_CS	BIT(30)
#define R8125_TD1_UDP_CS	BIT(31)
#define R8125_TCPHO_SHIFT	18
#define R8125_TCPHO_MAX		0x3ffU
#define R8125_TX_CSUM_OPTS_DROP	0xffffffffU

/* RX descriptor opts1 bits. */
#define R8125_RX_PID0		BIT(17)	/* TCP if set */
#define R8125_RX_PID1		BIT(18)	/* UDP if set */
#define R8125_RX_PID_MASK	(R8125_RX_PID0 | R8125_RX_PID1)
#define R8125_RX_IPFAIL		BIT(16)
#define R8125_RX_UDPFAIL	BIT(15)
#define R8125_RX_TCPFAIL	BIT(14)
#define R8125_RX_FAIL_MASK	(R8125_RX_IPFAIL | R8125_RX_UDPFAIL | R8125_RX_TCPFAIL)

/* 8125 hardware errata: UDP frames whose transport-data portion is
 * shorter than this length get a wrong UDP checksum from the chip.
 * Upstream r8169 has the same workaround at RTL_MIN_PATCH_LEN = 47
 * (r8169_main.c:4395). */
#define R8125_MIN_UDP_PATCH_LEN	47

static bool r8125_short_udp_needs_sw_csum(struct sk_buff *skb)
{
	unsigned int trans_data_len;

	if (!skb_transport_header_was_set(skb))
		return false;
	trans_data_len = skb_tail_pointer(skb) - skb_transport_header(skb);
	return trans_data_len < R8125_MIN_UDP_PATCH_LEN;
}

u32 r8125_bridge_skb_tx_csum_opts(struct sk_buff *skb)
{
	u32 opts2 = 0;
	u8 ip_proto;

	if (skb->ip_summed != CHECKSUM_PARTIAL)
		return 0;

	switch (vlan_get_protocol(skb)) {
	case htons(ETH_P_IP):
		opts2 |= R8125_TD1_IPV4_CS;
		ip_proto = ip_hdr(skb)->protocol;
		break;
	case htons(ETH_P_IPV6):
		opts2 |= R8125_TD1_IPV6_CS;
		ip_proto = ipv6_hdr(skb)->nexthdr;
		break;
	default:
		return 0;
	}

	if (skb_transport_offset(skb) > R8125_TCPHO_MAX)
		return 0;	/* header too far in; kernel does SW csum */

	if (ip_proto == IPPROTO_TCP) {
		opts2 |= R8125_TD1_TCP_CS;
	} else if (ip_proto == IPPROTO_UDP) {
		if (r8125_short_udp_needs_sw_csum(skb)) {
			/* Chip miscomputes UDP CSUM for short transport-data
			 * frames (vendor errata). Force the kernel to do it
			 * in software and submit a fully-checksummed frame. */
			if (skb_checksum_help(skb))
				return R8125_TX_CSUM_OPTS_DROP;
			return 0;
		}
		opts2 |= R8125_TD1_UDP_CS;
	} else {
		return 0;
	}

	opts2 |= (u32)skb_transport_offset(skb) << R8125_TCPHO_SHIFT;
	return opts2;
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_tx_csum_opts);

void r8125_bridge_skb_rx_csum_set(struct sk_buff *skb, u32 desc_opts1)
{
	u32 pid = desc_opts1 & R8125_RX_PID_MASK;
	u32 fail = desc_opts1 & R8125_RX_FAIL_MASK;

	if (fail) {
		/* Chip flagged a checksum failure — leave skb->ip_summed at
		 * its default; the stack will either retry SW or drop. */
		skb_checksum_none_assert(skb);
		return;
	}
	/* Per r8169 rtl8169_rx_csum: only TCP (PID0) or UDP (PID1) — not
	 * both, not neither — indicate a verified L4 checksum. */
	if (pid == R8125_RX_PID0 || pid == R8125_RX_PID1)
		skb->ip_summed = CHECKSUM_UNNECESSARY;
	else
		skb_checksum_none_assert(skb);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_rx_csum_set);

/* netdev->stats is a `struct net_device_stats` containing u_long counters.
 * We update without an extra lock — RTNL serialises ndo_open/stop, NAPI poll
 * runs per-CPU, xmit holds the TX queue lock. The READ_ONCE/WRITE_ONCE
 * discipline matches the §6.3 counter helpers in netdev_bridge.c. M5
 * task #45 turns these into per-CPU sharded counters. */

void r8125_bridge_account_tx(struct net_device *ndev, unsigned int bytes)
{
	WRITE_ONCE(ndev->stats.tx_packets, READ_ONCE(ndev->stats.tx_packets) + 1);
	WRITE_ONCE(ndev->stats.tx_bytes,   READ_ONCE(ndev->stats.tx_bytes)   + bytes);
}
EXPORT_SYMBOL_GPL(r8125_bridge_account_tx);

void r8125_bridge_account_rx(struct net_device *ndev, unsigned int bytes)
{
	WRITE_ONCE(ndev->stats.rx_packets, READ_ONCE(ndev->stats.rx_packets) + 1);
	WRITE_ONCE(ndev->stats.rx_bytes,   READ_ONCE(ndev->stats.rx_bytes)   + bytes);
}
EXPORT_SYMBOL_GPL(r8125_bridge_account_rx);
