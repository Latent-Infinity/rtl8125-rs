// SPDX-License-Identifier: GPL-2.0
/*
 * HW offload helpers for r8125_rust.
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
#include <linux/swab.h>
#include <linux/tcp.h>
#include <linux/udp.h>
#include <net/ip6_checksum.h>

/* TX checksum-v2 + TSO descriptor-bit POLICY moved to Rust (src/tx_offload.rs);
 * this file now only gathers protocol facts + applies the decision. The RX
 * checksum bits below stay here (read on the RX completion path).
 */

/* RX descriptor opts1 bits. */
#define R8125_RX_PID0		BIT(17)	/* TCP if set */
#define R8125_RX_PID1		BIT(18)	/* UDP if set */
#define R8125_RX_PID_MASK	(R8125_RX_PID0 | R8125_RX_PID1)
#define R8125_RX_IPFAIL		BIT(16)
#define R8125_RX_UDPFAIL	BIT(15)
#define R8125_RX_TCPFAIL	BIT(14)
#define R8125_RX_FAIL_MASK	(R8125_RX_IPFAIL | R8125_RX_UDPFAIL | R8125_RX_TCPFAIL)

/* 8125 pad quirk: r8169 and the vendor driver only patch PTP UDP event
 * frames (ports 319/320) whose transport-data portion is shorter than this
 * length, plus packets too short to contain the transport header. Normal
 * checksum-partial short UDP should stay on hardware checksum.
 */
#define R8125_MIN_UDP_PATCH_LEN	47
#define R8125_PTP_EVENT_PORT0	319
#define R8125_PTP_EVENT_PORT1	320

static unsigned int r8125_quirk_udp_padto(struct sk_buff *skb)
{
	unsigned int padto = 0;
	int trans_data_len;

	if (!skb_transport_header_was_set(skb))
		return 0;
	if (skb->len >= 128 + R8125_MIN_UDP_PATCH_LEN)
		return 0;

	trans_data_len = skb_tail_pointer(skb) - skb_transport_header(skb);
	if (trans_data_len >= offsetof(struct udphdr, len) &&
	    trans_data_len < R8125_MIN_UDP_PATCH_LEN) {
		u16 dest = ntohs(udp_hdr(skb)->dest);

		if (dest == R8125_PTP_EVENT_PORT0 ||
		    dest == R8125_PTP_EVENT_PORT1)
			padto = skb->len + R8125_MIN_UDP_PATCH_LEN -
				trans_data_len;
	}
	if (trans_data_len < (int)sizeof(struct udphdr)) {
		int pad_len = (int)sizeof(struct udphdr) - trans_data_len;

		padto = max_t(unsigned int, padto,
			      skb->len + (unsigned int)pad_len);
	}

	return padto;
}

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

void r8125_bridge_account_tx(struct net_device *ndev, unsigned int bytes)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* Per-CPU tx_packets/tx_bytes via the NETDEV_PCPU_STAT_TSTATS
	 * setup at bridge_alloc. r8169 uses the same helper at
	 * rtl8169_tx_handler (r8169_main.c:4769).
	 */
	dev_sw_netstats_tx_add(ndev, 1, bytes);
	/* Single TX queue: per-queue counters for netdev_stat_ops, single-writer
	 * (TX-completion NAPI), kept next to the device total.
	 */
	b->tx_packets++;
	b->tx_bytes += bytes;
}

/* ── Scatter-gather + TSO ────────────────────────────────────────────── */

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

void r8125_bridge_skb_dma_unmap_frag_tx(struct device *dev, dma_addr_t handle,
					size_t len)
{
	dma_unmap_page(dev, handle, len, DMA_TO_DEVICE);
}

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

/* Gather the protocol facts the Rust offload-policy needs, plus the UDP/PTP pad
 * quirk (which needs the udp header — a kernel API). Pure reads; no side effects.
 */
static struct r8125_tx_offload_facts r8125_bridge_tx_offload_facts(struct sk_buff *skb)
{
	struct skb_shared_info *shinfo = skb_shinfo(skb);
	struct r8125_tx_offload_facts f = {0};

	f.len = skb->len;
	f.transport_offset = skb_transport_offset(skb);
	if (shinfo->gso_size) {
		f.flags |= R8125_TXO_F_IS_GSO;
		f.mss = shinfo->gso_size;
		if (shinfo->gso_type & SKB_GSO_TCPV4)
			f.flags |= R8125_TXO_F_GSO_TCPV4;
		else if (shinfo->gso_type & SKB_GSO_TCPV6)
			f.flags |= R8125_TXO_F_GSO_TCPV6;
	}
	if (skb->ip_summed == CHECKSUM_PARTIAL)
		f.flags |= R8125_TXO_F_CSUM_PARTIAL;

	switch (vlan_get_protocol(skb)) {
	case htons(ETH_P_IP):
		f.l3 = 4;
		f.l4 = ip_hdr(skb)->protocol;
		break;
	case htons(ETH_P_IPV6):
		f.l3 = 6;
		f.l4 = ipv6_hdr(skb)->nexthdr;
		break;
	default:
		break;
	}
	if (f.l4 == IPPROTO_UDP)
		f.udp_quirk_padto = r8125_quirk_udp_padto(skb);
	if (skb_vlan_tag_present(skb)) {
		f.flags |= R8125_TXO_F_VLAN;
		f.vlan_tag = skb_vlan_tag_get(skb);
	}
	return f;
}

int r8125_bridge_skb_tx_offload_prepare(struct sk_buff *skb, u32 *opts1_bits,
					u32 *opts2_bits,
					unsigned int *nr_frags)
{
	struct r8125_tx_offload_facts f = r8125_bridge_tx_offload_facts(skb);
	struct r8125_tx_offload_decision d = r8125_tx_offload_decide(f);

	*opts1_bits = 0;
	*opts2_bits = 0;

	/* Apply the side effect the Rust policy chose (the bit values are already
	 * decided); any kernel-API failure becomes a TX drop (-EIO).
	 */
	switch (d.action) {
	case R8125_TXO_ACT_DROP:
		return -EIO;
	case R8125_TXO_ACT_TSO:
		if (d.flags & R8125_TXO_D_NEED_V6_CSUM_PREP) {
			if (skb_cow_head(skb, 0))
				return -EIO;
			tcp_v6_gso_csum_prep(skb);
		}
		break;
	case R8125_TXO_ACT_SWFALLBACK:
		if (d.padto && __skb_put_padto(skb, d.padto, false))
			return -EIO;
		if (skb_checksum_help(skb))
			return -EIO;
		break;
	case R8125_TXO_ACT_NOOFFLOAD:
		if (d.padto && __skb_put_padto(skb, d.padto, false))
			return -EIO;
		break;
	case R8125_TXO_ACT_CSUM:
	default:
		break;
	}

	*opts1_bits = d.opts1;
	*opts2_bits = d.opts2;
	*nr_frags = (unsigned int)skb_shinfo(skb)->nr_frags;
	return 0;
}

unsigned int r8125_bridge_skb_consume_tx(struct net_device *ndev,
					 struct sk_buff *skb)
{
	struct r8125_bridge *b = ndev ? netdev_priv(ndev) : NULL;
	/* Snapshot wire length BEFORE napi_consume_skb — once consumed the
	 * pointer is stale. skb->len is the full logical-packet size (incl.
	 * all paged frags). Returned so the NAPI reaper can batch it into
	 * netdev_completed_queue() for BQL (must balance netdev_sent_queue).
	 */
	unsigned int len = skb->len;

	if (b)
		this_cpu_inc(*b->tx_consumed);
	if (ndev)
		r8125_bridge_account_tx(ndev, len);
	napi_consume_skb(skb, 1);
	return len;
}

/* Wire length (skb->len) for the BQL sent_queue at the xmit commit. */
unsigned int r8125_bridge_skb_len(const struct sk_buff *skb)
{
	return skb->len;
}

/* ── BQL (byte queue limits) — Approach A (docs/BQL_RETRY_PLAN.md) ─────────
 * Keeps the driver TX ring shallow so the qdisc (fq_codel) can protect
 * latency-sensitive flows under a saturated bulk TX. We deliberately do NOT
 * call netdev_reset_queue() (would set dql.limit=0 → bootstrap XOFF stall);
 * instead we seed dql.min_limit at open so the first xmit can't drive
 * dql_avail negative. r8169's rtl_open never resets the queue either.
 */

/* Seed dql.min_limit to one full current-MTU frame + headroom so the very
 * first xmit keeps dql_avail >= 0. Idempotent; call once per ndo_open.
 */
void r8125_bridge_dql_seed_min_limit(struct net_device *ndev)
{
	struct netdev_queue *txq = netdev_get_tx_queue(ndev, 0);
	unsigned int seed = READ_ONCE(ndev->mtu) + VLAN_ETH_HLEN + NET_SKB_PAD;

	__netif_tx_lock_bh(txq);
	netdev_queue_set_dql_min_limit(txq, seed);
	/* There is no netdev helper for the bootstrap limit floor. Without this,
	 * dql_avail can remain negative on the first sent_queue() even though
	 * min_limit was set, reproducing the zero-limit BQL stall.
	 */
	if (txq->dql.limit < seed)
		txq->dql.limit = seed;
	__netif_tx_unlock_bh(txq);
}

/* Feed dql at the xmit commit and return whether the TX doorbell must be rung.
 * This is the r8169 pattern: __netdev_sent_queue() folds netdev_xmit_more()
 * into BQL so batched packets only defer the doorbell while the queue is not
 * already stopped.
 */
bool r8125_bridge_netdev_sent_queue(struct net_device *ndev,
				    unsigned int bytes, bool xmit_more)
{
	return __netdev_sent_queue(ndev, bytes, xmit_more);
}

/* Feed completed (pkts, bytes) once per NAPI TX reap; auto-wakes the queue. */
void r8125_bridge_netdev_completed_queue(struct net_device *ndev,
					 unsigned int pkts, unsigned int bytes)
{
	netdev_completed_queue(ndev, pkts, bytes);
}
