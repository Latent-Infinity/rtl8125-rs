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
 *
 * Hard cap: 400 LOC. Enforced by ci/check_cshim_loc_caps.sh.
 */

#include "netdev_bridge_internal.h"

#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
#include <linux/ip.h>
#include <linux/ipv6.h>
#include <linux/netdevice.h>
#include <linux/skbuff.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <net/ip6_checksum.h>

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
 * (r8169_main.c:4395).
 */
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
			 * in software and submit a fully-checksummed frame.
			 */
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
		 * its default; the stack will either retry SW or drop.
		 */
		skb_checksum_none_assert(skb);
		return;
	}
	/* Per r8169 rtl8169_rx_csum: only TCP (PID0) or UDP (PID1) — not
	 * both, not neither — indicate a verified L4 checksum.
	 */
	if (pid == R8125_RX_PID0 || pid == R8125_RX_PID1)
		skb->ip_summed = CHECKSUM_UNNECESSARY;
	else
		skb_checksum_none_assert(skb);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_rx_csum_set);

void r8125_bridge_account_tx(struct net_device *ndev, unsigned int bytes)
{
	/* Per-CPU tx_packets/tx_bytes via Candidate G's
	 * NETDEV_PCPU_STAT_TSTATS setup at bridge_alloc. r8169 uses the
	 * same helper at rtl8169_tx_handler (r8169_main.c:4769).
	 */
	dev_sw_netstats_tx_add(ndev, 1, bytes);
}
EXPORT_SYMBOL_GPL(r8125_bridge_account_tx);

/* ── Scatter-gather + TSO (M4-perf phase 2, task 49) ─────────────────── */

/* TX descriptor opts1 bits used only by the TSO path. Same prefix
 * scheme as the CSUM opts2 bits above. Realtek vendor + r8169 agree
 * on these values (r8125_n.c GiantSendv4/v6 vs rtl_tx_desc_bit_1
 * TD1_GTSENV4/V6).
 */
#define R8125_TD1_GTSENV6	BIT(25)
#define R8125_TD1_GTSENV4	BIT(26)
#define R8125_GTTCPHO_SHIFT	18
#define R8125_GTTCPHO_MAX	0x7fU
#define R8125_TD1_MSS_SHIFT	18	/* opts2 MSS position (11 bits) */

unsigned int r8125_bridge_skb_nr_frags(struct sk_buff *skb)
{
	return (unsigned int)skb_shinfo(skb)->nr_frags;
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_nr_frags);

int r8125_bridge_skb_data_dma_map(struct device *dev, struct sk_buff *skb,
				  dma_addr_t *out_handle, unsigned int *out_len)
{
	struct net_device *ndev = skb->dev;
	struct r8125_bridge *b = ndev ? netdev_priv(ndev) : NULL;
	unsigned int len = skb_headlen(skb);
	dma_addr_t h;

	h = dma_map_single(dev, skb->data, len, DMA_TO_DEVICE);
	if (b)
		this_cpu_inc(*b->tx_received);
	if (dma_mapping_error(dev, h))
		return -EIO;
	*out_handle = h;
	*out_len = len;
	return 0;
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_data_dma_map);

void r8125_bridge_skb_dma_unmap_frag_tx(struct device *dev, dma_addr_t handle,
					size_t len)
{
	dma_unmap_page(dev, handle, len, DMA_TO_DEVICE);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_dma_unmap_frag_tx);

int r8125_bridge_skb_frag_dma_map(struct device *dev, struct sk_buff *skb,
				  unsigned int frag_idx,
				  dma_addr_t *out_handle, unsigned int *out_len)
{
	const skb_frag_t *frag;
	unsigned int len;
	dma_addr_t h;

	if (frag_idx >= skb_shinfo(skb)->nr_frags)
		return -EINVAL;
	frag = &skb_shinfo(skb)->frags[frag_idx];
	len = skb_frag_size(frag);
	h = skb_frag_dma_map(dev, frag, 0, len, DMA_TO_DEVICE);
	if (dma_mapping_error(dev, h))
		return -EIO;
	*out_handle = h;
	*out_len = len;
	return 0;
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_frag_dma_map);

bool r8125_bridge_skb_tso_setup(struct sk_buff *skb,
				u32 *opts1_bits, u32 *opts2_bits)
{
	struct skb_shared_info *shinfo = skb_shinfo(skb);
	unsigned int mss = shinfo->gso_size;
	unsigned int trans_off;

	*opts1_bits = 0;
	*opts2_bits = 0;

	if (mss == 0)
		return false;

	trans_off = skb_transport_offset(skb);
	if (trans_off > R8125_GTTCPHO_MAX)
		return false;	/* header too far in; chip can't reach it */

	if (shinfo->gso_type & SKB_GSO_TCPV4) {
		*opts1_bits |= R8125_TD1_GTSENV4;
	} else if (shinfo->gso_type & SKB_GSO_TCPV6) {
		/* Prep pseudo-header CSUM for chip-segmented v6 frames. */
		if (skb_cow_head(skb, 0))
			return false;
		tcp_v6_gso_csum_prep(skb);
		*opts1_bits |= R8125_TD1_GTSENV6;
	} else {
		/* Other GSO types (UDP frag, GRE, etc.) — chip can't TSO,
		 * the kernel will fall back to software segmentation.
		 */
		return false;
	}

	*opts1_bits |= (u32)trans_off << R8125_GTTCPHO_SHIFT;
	*opts2_bits |= (u32)mss << R8125_TD1_MSS_SHIFT;
	return true;
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_tso_setup);

void r8125_bridge_skb_consume_tx(struct net_device *ndev, struct sk_buff *skb)
{
	struct r8125_bridge *b = ndev ? netdev_priv(ndev) : NULL;

	/* Account BEFORE napi_consume_skb — once consumed the pointer is
	 * stale. The byte count comes from skb->len (the full logical-
	 * packet size including all paged frags), not from any single
	 * descriptor's LEN field (chip clears those on completion).
	 */
	if (b)
		this_cpu_inc(*b->tx_consumed);
	if (ndev)
		r8125_bridge_account_tx(ndev, skb->len);
	napi_consume_skb(skb, 1);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_consume_tx);
