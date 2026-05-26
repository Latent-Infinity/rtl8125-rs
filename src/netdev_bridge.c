// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge.c — minimal C bridge for the r8125_rust driver.
 *
 * Implements the contract in netdev_bridge.h. The actual driver logic
 * (PCI, MMIO, descriptor rings, hardware programming, NAPI poll body)
 * lives in Rust; this file's only job is the kernel-facing surface that
 * has no stable Rust API today: net_device + net_device_ops + NAPI +
 * sk_buff plumbing (plan §5.2 / §5.3).
 *
 * Hard cap: ≤ 400 LOC including comments. See cshim/README.md.
 *
 * Every ndo callback below is a one-line delegation to the Rust vtable.
 * Counter increments are the only "business logic" performed here; they
 * sit next to the sk_buff helper calls so the §6.3 accounting invariant
 * stays in one file.
 */

#include "netdev_bridge_internal.h"

#include <linux/atomic.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/skbuff.h>
#include <linux/slab.h>

#define BRIDGE_NAPI_WEIGHT	64

/* ── ndo callbacks — each is a thin delegation to Rust ───────────────── */

static int bridge_ndo_open(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc;

	napi_enable(&b->napi);
	rc = b->ops.open(b->priv);
	if (rc) {
		napi_disable(&b->napi);
		return rc;
	}
	/* M4-without-peer leaves the queue stopped and the carrier off;
	 * the Rust open() decides when to wake / mark-carrier-on. */
	return 0;
}

static int bridge_ndo_stop(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	netif_tx_disable(ndev);
	napi_disable(&b->napi);
	b->ops.stop(b->priv);
	return 0;
}

static netdev_tx_t bridge_ndo_start_xmit(struct sk_buff *skb,
					 struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* All §6.3 counter side-effects happen inside the Rust path via
	 * the skb helpers below — bridge_ndo_start_xmit itself is a pure
	 * delegation. */
	return (netdev_tx_t)b->ops.xmit(b->priv, skb);
}

static int bridge_ndo_change_mtu(struct net_device *ndev, int new_mtu)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc = b->ops.change_mtu(b->priv, new_mtu);

	if (!rc)
		ndev->mtu = new_mtu;
	return rc;
}

/* NAPI poll wrapper: same delegation pattern. */
static int bridge_napi_poll(struct napi_struct *napi, int budget)
{
	struct r8125_bridge *b = container_of(napi, struct r8125_bridge, napi);

	return b->ops.poll(b->priv, budget);
}

static const struct net_device_ops bridge_ops = {
	.ndo_open		= bridge_ndo_open,
	.ndo_stop		= bridge_ndo_stop,
	.ndo_start_xmit		= bridge_ndo_start_xmit,
	.ndo_change_mtu		= bridge_ndo_change_mtu,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
};

/* ── Lifecycle ─────────────────────────────────────────────────────── */

struct net_device *r8125_bridge_alloc(struct pci_dev *pdev, void *priv,
				      const struct r8125_bridge_ops *ops,
				      const unsigned char mac[ETH_ALEN])
{
	struct net_device *ndev;
	struct r8125_bridge *b;

	ndev = alloc_etherdev(sizeof(*b));
	if (!ndev)
		return NULL;

	SET_NETDEV_DEV(ndev, &pdev->dev);
	ndev->netdev_ops = &bridge_ops;
	ndev->needs_free_netdev = false; /* we free explicitly */
	eth_hw_addr_set(ndev, mac);

	/* M4 baseline: single queue, standard MTU range. Jumbo lands with
	 * the M5 RX-buffer/page-fragment refactor. */
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = ETH_DATA_LEN;

	/* M4-perf: HW offload feature advertisement.
	 *  - NETIF_F_IP_CSUM / IPV6_CSUM: chip computes IP/TCP/UDP checksum
	 *    (task #48; opts2 bits set by r8125_bridge_skb_tx_csum_opts).
	 *  - NETIF_F_RXCSUM: chip validates incoming checksums (task #48;
	 *    r8125_bridge_skb_rx_csum_set sets skb->ip_summed when valid).
	 *  - NETIF_F_SG: kernel may hand us multi-fragment skbs that we
	 *    post as N descriptors per logical packet (task #49). Required
	 *    for TSO.
	 *  - NETIF_F_TSO / NETIF_F_TSO6: chip performs TCP segmentation —
	 *    we receive a single up-to-64K skb and the chip emits MSS-sized
	 *    frames on the wire (task #49). Bits set by
	 *    r8125_bridge_skb_tso_setup.
	 *
	 * Without these features the kernel software-segments and software-
	 * checksums everything, which caps single-stream throughput at
	 * ~1 Gbps in the KASAN-debug guest (per-packet overhead bound).
	 * With SG+TSO the chip handles ~64K logical sends in one batch.
	 *
	 * TSO chip limits — RTL8125B-specific empirical caps (see
	 * docs/RTL8125B_TSO_NOTES.md for the full bisection log):
	 *
	 *   netif_set_tso_max_segs(ndev, 10)
	 *
	 *   The chip's LSO engine reliably segments super-skbs of up to 11
	 *   MSS-worth of payload; at 12+ segments per super-skb it stalls
	 *   the TX queue and drops segments wholesale (verified by bisection
	 *   2026-05-26 across max_segs = 2..16; 11 works, 12 hangs the TX
	 *   queue, 16 produces a ~65 Mbps glide-down with ~530 retransmits
	 *   per 6-second iperf3 run). r8169 mainline and Realtek vendor
	 *   both publish 64 — that limit is wrong for this chip in practice.
	 *   We use 10 for safety margin under the measured 11-segment
	 *   threshold; line rate (2.35 Gbps in our KVM/VFIO/KASAN-debug
	 *   setup, matching the r8169 reference) is already saturated at
	 *   8 segments so the cap does not bottleneck throughput.
	 *
	 *   netif_set_tso_max_size(ndev, 64000)
	 *
	 *   Matches r8169 mainline RTL_GSO_MAX_SIZE_V2 / Realtek LSO_64K;
	 *   the segment cap above is the binding constraint, not the size. */
	ndev->hw_features = NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM |
			    NETIF_F_RXCSUM | NETIF_F_SG |
			    NETIF_F_TSO | NETIF_F_TSO6;
	ndev->features = ndev->hw_features;
	ndev->vlan_features = NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM |
			      NETIF_F_SG | NETIF_F_TSO | NETIF_F_TSO6;

	netif_set_tso_max_size(ndev, 64000);
	netif_set_tso_max_segs(ndev, 10);

	b = netdev_priv(ndev);
	b->ndev = ndev;
	b->pdev = pdev;
	b->priv = priv;
	b->ops = *ops;

	netif_napi_add_weight(ndev, &b->napi, bridge_napi_poll,
			      BRIDGE_NAPI_WEIGHT);
	return ndev;
}
EXPORT_SYMBOL_GPL(r8125_bridge_alloc);

void r8125_bridge_free(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	netif_napi_del(&b->napi);
	free_netdev(ndev);
}
EXPORT_SYMBOL_GPL(r8125_bridge_free);

int r8125_bridge_register(struct net_device *ndev)
{
	return register_netdev(ndev);
}
EXPORT_SYMBOL_GPL(r8125_bridge_register);

void r8125_bridge_unregister_and_free(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* Order: unregister_netdev synchronously runs ndo_stop (which calls
	 * phy_stop + phy_disconnect — severing the phy_device from the
	 * netdev). Only THEN is it safe to unregister the mdiobus, which
	 * removes the phy_device from the bus and frees it. mdiobus_free
	 * must happen before free_netdev because the bridge struct holds
	 * the mii_bus pointer. */
	unregister_netdev(ndev);
	if (b->mii_bus) {
		mdiobus_unregister(b->mii_bus);
		mdiobus_free(b->mii_bus);
		b->mii_bus = NULL;
		b->phydev = NULL;
	}
	netif_napi_del(&b->napi);
	free_netdev(ndev);
}
EXPORT_SYMBOL_GPL(r8125_bridge_unregister_and_free);

/* ── Flow-control + NAPI helpers ────────────────────────────────────── */

void r8125_bridge_tx_stop_queue(struct net_device *ndev)
{
	netif_tx_stop_queue(netdev_get_tx_queue(ndev, 0));
}
EXPORT_SYMBOL_GPL(r8125_bridge_tx_stop_queue);

void r8125_bridge_tx_wake_queue(struct net_device *ndev)
{
	netif_tx_wake_queue(netdev_get_tx_queue(ndev, 0));
}
EXPORT_SYMBOL_GPL(r8125_bridge_tx_wake_queue);

void r8125_bridge_napi_schedule(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	napi_schedule(&b->napi);
}
EXPORT_SYMBOL_GPL(r8125_bridge_napi_schedule);

void r8125_bridge_napi_complete_done(struct net_device *ndev, int work_done)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	napi_complete_done(&b->napi, work_done);
}
EXPORT_SYMBOL_GPL(r8125_bridge_napi_complete_done);

void r8125_bridge_carrier_on(struct net_device *ndev)
{
	netif_carrier_on(ndev);
}
EXPORT_SYMBOL_GPL(r8125_bridge_carrier_on);

void r8125_bridge_carrier_off(struct net_device *ndev)
{
	netif_carrier_off(ndev);
}
EXPORT_SYMBOL_GPL(r8125_bridge_carrier_off);

void r8125_bridge_tx_disable(struct net_device *ndev)
{
	netif_tx_disable(ndev);
}
EXPORT_SYMBOL_GPL(r8125_bridge_tx_disable);

struct napi_struct *r8125_bridge_napi(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	return &b->napi;
}
EXPORT_SYMBOL_GPL(r8125_bridge_napi);

/* ── sk_buff helpers + counter side-effects (§6.3) ─────────────────── */

void r8125_bridge_skb_dma_unmap_tx(struct device *dev, dma_addr_t handle,
				   size_t len)
{
	dma_unmap_single(dev, handle, len, DMA_TO_DEVICE);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_dma_unmap_tx);

void r8125_bridge_skb_free_error(struct sk_buff *skb)
{
	struct net_device *ndev = skb->dev;
	struct r8125_bridge *b = ndev ? netdev_priv(ndev) : NULL;

	if (b)
		WRITE_ONCE(b->tx_dropped_error,
			   READ_ONCE(b->tx_dropped_error) + 1);
	dev_kfree_skb_any(skb);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_free_error);

void r8125_bridge_tx_busy_exception(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	WRITE_ONCE(b->tx_busy_exception,
		   READ_ONCE(b->tx_busy_exception) + 1);
}
EXPORT_SYMBOL_GPL(r8125_bridge_tx_busy_exception);

struct sk_buff *r8125_bridge_skb_build_rx(struct net_device *ndev,
					  const void *buf, size_t len)
{
	struct sk_buff *skb;

	skb = netdev_alloc_skb(ndev, len + NET_IP_ALIGN);
	if (!skb)
		return NULL;
	skb_reserve(skb, NET_IP_ALIGN);
	skb_put_data(skb, buf, len);
	skb->protocol = eth_type_trans(skb, ndev);
	return skb;
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_build_rx);

void r8125_bridge_skb_deliver_rx(struct napi_struct *napi, struct sk_buff *skb)
{
	struct r8125_bridge *b = container_of(napi, struct r8125_bridge, napi);

	WRITE_ONCE(b->rx_handed_to_stack, READ_ONCE(b->rx_handed_to_stack) + 1);
	napi_gro_receive(napi, skb);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_deliver_rx);

void r8125_bridge_skb_drop_rx(struct sk_buff *skb)
{
	struct net_device *ndev = skb->dev;
	struct r8125_bridge *b = ndev ? netdev_priv(ndev) : NULL;

	if (b)
		WRITE_ONCE(b->rx_dropped_error,
			   READ_ONCE(b->rx_dropped_error) + 1);
	dev_kfree_skb_any(skb);
}
EXPORT_SYMBOL_GPL(r8125_bridge_skb_drop_rx);

void r8125_bridge_rx_drop_error(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	WRITE_ONCE(b->rx_dropped_error,
		   READ_ONCE(b->rx_dropped_error) + 1);
}
EXPORT_SYMBOL_GPL(r8125_bridge_rx_drop_error);

void r8125_bridge_counters_snapshot(struct net_device *ndev,
				    struct r8125_bridge_counters *out)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	out->tx_received       = READ_ONCE(b->tx_received);
	out->tx_consumed       = READ_ONCE(b->tx_consumed);
	out->tx_busy_exception = READ_ONCE(b->tx_busy_exception);
	out->tx_dropped_error  = READ_ONCE(b->tx_dropped_error);
	out->rx_handed_to_stack = READ_ONCE(b->rx_handed_to_stack);
	out->rx_dropped_error  = READ_ONCE(b->rx_dropped_error);
}
EXPORT_SYMBOL_GPL(r8125_bridge_counters_snapshot);

MODULE_LICENSE("GPL v2");
