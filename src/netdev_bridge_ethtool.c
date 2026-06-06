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
 * Hard cap: 200 LOC. Enforced by ci/check_cshim_loc_caps.sh.
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
}

const struct ethtool_ops r8125_bridge_ethtool_ops = {
	.get_drvinfo		= bridge_get_drvinfo,
	.get_sset_count		= bridge_get_sset_count,
	.get_strings		= bridge_get_strings,
	.get_ethtool_stats	= bridge_get_ethtool_stats,
	.get_link		= ethtool_op_get_link,
};
