// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_ethtool.c - ethtool -S exposure for the section 6.3 counters.
 *
 * The section 6.3 disposition counters (tx_received / tx_consumed /
 * tx_busy_exception / tx_dropped_error / rx_handed_to_stack /
 * rx_dropped_error) are the formal accounting that the plan requires:
 *
 *   tx_received == tx_consumed + tx_busy_exception + tx_dropped_error
 *
 * `r8125_bridge_counters_snapshot` already exposes them as a
 * kernel-internal API; this file makes them readable via
 * `ethtool -S enp5s0` so the runtime invariant check (
 * `ci/check_counter_invariant.sh`) can assert the equation after a
 * 1 GB transfer per plan section 6.3 / section 15 M4 close-out.
 *
 * Why ethtool and not debugfs: ethtool stats are the kernel-idiomatic
 * surface for per-device internal counters, are stable across kernel
 * versions, and don't need a separate filesystem mount. The whole
 * surface is ~25 LOC, kept in this file to leave netdev_bridge.c
 * within its 400-line review cap.
 *
 * Hard cap: 240 LOC. Enforced by ci/check_cshim_loc_caps.sh. Raised from 200
 * for the B5 ethtool RSS control plane (get/set_rxfh, get_channels, get_rxnfc).
 */

#include "netdev_bridge_internal.h"

#include <linux/ethtool.h>
#include <linux/netdevice.h>
#include <linux/pci.h>

/*
 * Driver identity exposed via `ethtool -i <iface>`. Keep this small:
 * in-tree drivers normally avoid an independent driver version string
 * that can drift away from the kernel/module build identity.
 */
#define R8125_RUST_DRV_NAME	"r8125_rust"

static void bridge_get_drvinfo(struct net_device *ndev,
			       struct ethtool_drvinfo *info)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	strscpy(info->driver, R8125_RUST_DRV_NAME, sizeof(info->driver));
	if (b->pdev)
		strscpy(info->bus_info, pci_name(b->pdev),
			sizeof(info->bus_info));
}

/*
 * Order MUST match `bridge_ethtool_stats[]` ordering below: the kernel
 * reads strings via .get_strings(ETH_SS_STATS), then values via
 * .get_ethtool_stats() in the same order. The section 6.3 invariant check
 * relies on these names.
 *
 * Per-counter intent (also documented in
 * Documentation/networking/device_drivers/realtek/r8125_rust.rst):
 *   tx_received        ndo_start_xmit calls that reached DMA-map
 *   tx_consumed        successful TX completions (napi_consume_skb)
 *   tx_busy_exception  NETDEV_TX_BUSY (ring full, queue stop)
 *   tx_dropped_error   drop before DMA (CSUM help fail, hdr too far)
 *   rx_handed_to_stack napi_gro_receive successful
 *   rx_dropped_error   RX skb-build or chip-error drops
 *   rx_hash_l3         hashable L3 packet hash set on RX
 *   rx_hash_l4         hashable L4 packet hash set on RX
 *   rx_hash_missing    hashable frame without a valid descriptor hash
 *   rx_hash_disabled   RXHASH feature disabled while packets were delivered
 */
static const char bridge_ethtool_strings[][ETH_GSTRING_LEN] = {
	"tx_received",
	"tx_consumed",
	"tx_busy_exception",
	"tx_dropped_error",
	"rx_handed_to_stack",
	"rx_dropped_error",
	"rx_hash_l3",
	"rx_hash_l4",
	"rx_hash_missing",
	"rx_hash_disabled",
};

#define BRIDGE_ETHTOOL_NSTATS ARRAY_SIZE(bridge_ethtool_strings)

static int bridge_get_sset_count(struct net_device *ndev, int sset)
{
	return sset == ETH_SS_STATS ? BRIDGE_ETHTOOL_NSTATS : -EOPNOTSUPP;
}

static void bridge_get_strings(struct net_device *ndev, u32 sset, u8 *data)
{
	if (sset == ETH_SS_STATS)
		memcpy(data, bridge_ethtool_strings,
		       sizeof(bridge_ethtool_strings));
}

static void bridge_get_ethtool_stats(struct net_device *ndev,
				     struct ethtool_stats *stats, u64 *data)
{
	struct r8125_bridge_counters c;

	r8125_bridge_counters_snapshot(ndev, &c);
	/* Order matches `bridge_ethtool_strings` above. */
	data[0] = c.tx_received;
	data[1] = c.tx_consumed;
	data[2] = c.tx_busy_exception;
	data[3] = c.tx_dropped_error;
	data[4] = c.rx_handed_to_stack;
	data[5] = c.rx_dropped_error;
	data[6] = c.rx_hash_l3;
	data[7] = c.rx_hash_l4;
	data[8] = c.rx_hash_missing;
	data[9] = c.rx_hash_disabled;
}

u32 r8125_bridge_rxfh_indir_default(u32 index, u32 n_rx_rings)
{
	return ethtool_rxfh_indir_default(index, n_rx_rings);
}

/*
 * RSS control plane (B5). The chip uses Toeplitz hashing with the boot-stable
 * system key; at the current N=1 runtime the indirection table maps every
 * bucket to queue 0. `get_rxfh` reports exactly what `apply_rss_programming`
 * writes (same `netdev_rss_key_fill` key, all-zero table). `set_rxfh` validates
 * the indirection table through the host-tested Rust validator and rejects a
 * custom key while only one RX queue is owned. ethtool ops run under RTNL, the
 * same lock as open/stop, so changes are serialized against bring-up/teardown.
 */
static u32 bridge_get_rxfh_key_size(struct net_device *ndev)
{
	return R8125_RSS_KEY_SIZE;
}

static u32 bridge_get_rxfh_indir_size(struct net_device *ndev)
{
	return R8125_RSS_INDIR_SIZE;
}

static int bridge_get_rxfh(struct net_device *ndev,
			   struct ethtool_rxfh_param *rxfh)
{
	if (rxfh->indir)
		memset(rxfh->indir, 0, R8125_RSS_INDIR_SIZE * sizeof(u32));
	if (rxfh->key)
		netdev_rss_key_fill(rxfh->key, R8125_RSS_KEY_SIZE);
	rxfh->hfunc = ETH_RSS_HASH_TOP;
	return 0;
}

static int bridge_set_rxfh(struct net_device *ndev,
			   struct ethtool_rxfh_param *rxfh,
			   struct netlink_ext_ack *extack)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	u8 boot_key[R8125_RSS_KEY_SIZE];

	if (rxfh->rss_context)
		return -EOPNOTSUPP;
	if (rxfh->hfunc != ETH_RSS_HASH_NO_CHANGE &&
	    rxfh->hfunc != ETH_RSS_HASH_TOP)
		return -EOPNOTSUPP;
	if (rxfh->indir) {
		int rc = b->ops.rss_indir_check(b->priv, rxfh->indir,
						R8125_RSS_INDIR_SIZE,
						b->active_rx_queues);
		if (rc)
			return rc;
	}
	/* A custom hash key has no effect over a single RX queue; accept only
	 * an echo of the current (boot-stable) key, reject a real change.
	 */
	if (rxfh->key) {
		netdev_rss_key_fill(boot_key, R8125_RSS_KEY_SIZE);
		if (memcmp(rxfh->key, boot_key, R8125_RSS_KEY_SIZE))
			return -EOPNOTSUPP;
	}
	return 0;
}

static void bridge_get_channels(struct net_device *ndev,
				struct ethtool_channels *ch)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* max = hardware capability; current = runtime active RX queues. */
	ch->max_rx = R8125_BRIDGE_RX_QUEUE_COUNT;
	ch->max_tx = 1;
	ch->rx_count = b->active_rx_queues;
	ch->tx_count = 1;
}

/*
 * `ethtool -x`/`-X` first query the RX ring count (ETHTOOL_GRXRINGS); without
 * it ethtool reports "Cannot get RX ring count" and never reaches the RSS
 * table. Newer kernels route that query to the dedicated `get_rx_ring_count`
 * op rather than `get_rxnfc` (which is for the RX n-tuple classifier we do not
 * implement).
 */
static u32 bridge_get_rx_ring_count(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	return b->active_rx_queues;
}

const struct ethtool_ops r8125_bridge_ethtool_ops = {
	.get_drvinfo		= bridge_get_drvinfo,
	.get_sset_count		= bridge_get_sset_count,
	.get_strings		= bridge_get_strings,
	.get_ethtool_stats	= bridge_get_ethtool_stats,
	.get_link		= ethtool_op_get_link,
	.get_rxfh_key_size	= bridge_get_rxfh_key_size,
	.get_rxfh_indir_size	= bridge_get_rxfh_indir_size,
	.get_rxfh		= bridge_get_rxfh,
	.set_rxfh		= bridge_set_rxfh,
	.get_channels		= bridge_get_channels,
	.get_rx_ring_count	= bridge_get_rx_ring_count,
};
