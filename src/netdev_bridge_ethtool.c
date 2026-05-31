// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_ethtool.c — ethtool -S exposure for the §6.3 counters.
 *
 * The §6.3 disposition counters (tx_received / tx_consumed /
 * tx_busy_exception / tx_dropped_error / rx_handed_to_stack /
 * rx_dropped_error) are the formal accounting that the plan requires:
 *
 *   tx_received == tx_consumed + tx_busy_exception + tx_dropped_error
 *
 * `r8125_bridge_counters_snapshot` already exposes them as a
 * kernel-internal API; this file makes them readable via
 * `ethtool -S enp5s0` so the runtime invariant check (
 * `ci/check_counter_invariant.sh`) can assert the equation after a
 * 1 GB transfer per plan §6.3 / §15 M4 close-out.
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
#include <linux/jiffies.h>
#include <linux/netdevice.h>

/* DIAG-TEMP (2026-05-31): hand-rolled FFI to the Rust-side diag snapshot.
 * Layout MUST match `DiagSnapshot` in src/netdev.rs. Remove with the rest
 * of the DIAG-TEMP set once the KVM stall is fixed. */
struct r8125_diag_snapshot {
	u64 last_irq_jiffies;
	u64 last_napi_jiffies;
	u64 last_rx_packet_jiffies;
	u64 last_tx_complete_jiffies;
	u64 last_xmit_jiffies;
	u64 napi_polls_empty;
	u64 rx_completions_seen;
	u64 tx_packets_reaped;
};
extern void r8125_rust_diag_snapshot(struct r8125_diag_snapshot *out);

static u64 diag_ms_ago(u64 then, u64 now)
{
	if (!then || time_after64(then, now))
		return 0;
	return jiffies64_to_msecs(now - then);
}

/* Order MUST match `bridge_ethtool_stats[]` ordering below — the kernel
 * reads strings via .get_strings(ETH_SS_STATS), then values via
 * .get_ethtool_stats() in the same order. The §6.3 invariant check
 * relies on these names. */
static const char bridge_ethtool_strings[][ETH_GSTRING_LEN] = {
	"tx_received",        /* ndo_start_xmit calls that reached DMA-map */
	"tx_consumed",        /* successful TX completions (napi_consume_skb) */
	"tx_busy_exception",  /* NETDEV_TX_BUSY (ring full, queue stop) */
	"tx_dropped_error",   /* drop before DMA (CSUM help fail, hdr too far) */
	"rx_handed_to_stack", /* napi_gro_receive successful */
	"rx_dropped_error",   /* RX skb-build or chip-error drops */
	/* DIAG-TEMP (2026-05-31): KVM-stall-hunt instrumentation. Remove with
	 * the rest of the DIAG-TEMP set once the stall is fixed. */
	"diag_last_irq_ms_ago",
	"diag_last_napi_ms_ago",
	"diag_last_rx_pkt_ms_ago",
	"diag_last_tx_done_ms_ago",
	"diag_last_xmit_ms_ago",
	"diag_napi_polls_empty",
	"diag_rx_completions_seen",
	"diag_tx_packets_reaped",
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
	/* DIAG-TEMP (2026-05-31). */
	struct r8125_diag_snapshot d;
	u64 now;

	r8125_bridge_counters_snapshot(ndev, &c);
	/* Order matches `bridge_ethtool_strings` above. */
	data[0] = c.tx_received;
	data[1] = c.tx_consumed;
	data[2] = c.tx_busy_exception;
	data[3] = c.tx_dropped_error;
	data[4] = c.rx_handed_to_stack;
	data[5] = c.rx_dropped_error;

	/* DIAG-TEMP (2026-05-31). */
	r8125_rust_diag_snapshot(&d);
	now = get_jiffies_64();
	data[6]  = diag_ms_ago(d.last_irq_jiffies, now);
	data[7]  = diag_ms_ago(d.last_napi_jiffies, now);
	data[8]  = diag_ms_ago(d.last_rx_packet_jiffies, now);
	data[9]  = diag_ms_ago(d.last_tx_complete_jiffies, now);
	data[10] = diag_ms_ago(d.last_xmit_jiffies, now);
	data[11] = d.napi_polls_empty;
	data[12] = d.rx_completions_seen;
	data[13] = d.tx_packets_reaped;
}

const struct ethtool_ops r8125_bridge_ethtool_ops = {
	.get_sset_count		= bridge_get_sset_count,
	.get_strings		= bridge_get_strings,
	.get_ethtool_stats	= bridge_get_ethtool_stats,
	.get_link		= ethtool_op_get_link,
};
