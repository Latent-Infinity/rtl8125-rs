// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_ethtool.c - ethtool -S exposure for the disposition counters.
 *
 * The disposition counters (tx_received / tx_consumed /
 * tx_busy_exception / tx_dropped_error / rx_handed_to_stack /
 * rx_dropped_error) are the formal accounting:
 *
 *   tx_received == tx_consumed + tx_busy_exception + tx_dropped_error
 *
 * `r8125_bridge_counters_snapshot` already exposes them as a
 * kernel-internal API; this file makes them readable via
 * `ethtool -S enp5s0` so the runtime invariant check (
 * `ci/check_counter_invariant.sh`) can assert the equation after a
 * 1 GB transfer.
 *
 * Why ethtool and not debugfs: ethtool stats are the kernel-idiomatic
 * surface for per-device internal counters, are stable across kernel
 * versions, and don't need a separate filesystem mount. The whole
 * surface is ~25 LOC, kept in this file to leave netdev_bridge.c
 * within its 400-line review cap.
 *
 * Hard cap: 600 LOC. Enforced by ci/check_cshim_loc_caps.sh. Raised from 200
 * for the ethtool RSS control plane (get/set_rxfh, get_channels, get_rxnfc),
 * then to 340 for the phylib link control plane, then 400 for pause/ring params
 * and nway_reset, then 440 for EEE + msglevel, then 520 for the standardized
 * IEEE 802.3 stats (eth-mac / eth-ctrl / pause), then 560 for Wake-on-LAN, then 600 for the ethtool -d register dump.
 */

#include "netdev_bridge_internal.h"

#include <linux/ethtool.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <net/page_pool/helpers.h>
#include <net/page_pool/types.h>

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
	/* PHY MCU firmware version (set by Rust after a successful apply; empty
	 * if no firmware was loaded).
	 */
	if (b->fw_version[0])
		strscpy(info->fw_version, b->fw_version, sizeof(info->fw_version));
}

/*
 * Order MUST match `bridge_ethtool_stats[]` ordering below: the kernel
 * reads strings via .get_strings(ETH_SS_STATS), then values via
 * .get_ethtool_stats() in the same order. The invariant check
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
	if (sset != ETH_SS_STATS)
		return -EOPNOTSUPP;
	/* Driver disposition counters + the page_pool allocator stats (the latter
	 * surfaced via the standard page_pool ethtool helpers, not a private API).
	 */
	return BRIDGE_ETHTOOL_NSTATS + page_pool_ethtool_stats_get_count();
}

static void bridge_get_strings(struct net_device *ndev, u32 sset, u8 *data)
{
	if (sset != ETH_SS_STATS)
		return;
	memcpy(data, bridge_ethtool_strings, sizeof(bridge_ethtool_strings));
	data += sizeof(bridge_ethtool_strings);
	page_pool_ethtool_stats_get_strings(data);
}

static void bridge_get_ethtool_stats(struct net_device *ndev,
				     struct ethtool_stats *stats, u64 *data)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_counters c;
	struct page_pool_stats pp = {};
	unsigned int i;

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

	/* Append the page_pool allocator stats, summed across the active RX
	 * queues' pools (NULL while a queue is down). page_pool_get_stats
	 * accumulates into `pp`.
	 */
	for (i = 0; i < R8125_BRIDGE_RX_QUEUE_COUNT; i++)
		if (b->rxq[i].page_pool)
			page_pool_get_stats(b->rxq[i].page_pool, &pp);
	page_pool_ethtool_stats_get(&data[BRIDGE_ETHTOOL_NSTATS], &pp);
}

u32 r8125_bridge_rxfh_indir_default(u32 index, u32 n_rx_rings)
{
	return ethtool_rxfh_indir_default(index, n_rx_rings);
}

/*
 * RSS control plane. The chip uses Toeplitz hashing with the boot-stable
 * system key and the kernel DEFAULT indirection spread for the active RX-queue
 * count (`ethtool_rxfh_indir_default`, bucket i -> queue i % active_rx_queues) —
 * exactly what `apply_rss_programming` writes to hardware. `get_rxfh` therefore
 * reports that same default spread (NOT a hardcoded all-zero table), so
 * `ethtool -x` matches the programmed state for any queue count. `set_rxfh`
 * supports only that default: it validates the table through the host-tested
 * Rust validator and then accepts it only if it equals the default spread,
 * rejecting a custom table (-EOPNOTSUPP) rather than silently no-op'ing — a
 * custom hash key/table is a documented follow-up. The active count is changed
 * via `ethtool -L` (set_channels), which reprograms the default for the new
 * count. ethtool ops run under RTNL, serialized against open/stop.
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
	struct r8125_bridge *b = netdev_priv(ndev);
	u32 i;

	/* Report the SAME default spread that apply_rss_programming wrote for the
	 * active queue count, so `ethtool -x` matches hardware (was: all-zero,
	 * which lied once >1 queue was active).
	 */
	if (rxfh->indir)
		for (i = 0; i < R8125_RSS_INDIR_SIZE; i++)
			rxfh->indir[i] =
				r8125_bridge_rxfh_indir_default(i, b->active_rx_queues);
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
		u32 i;
		/* First reject entries that don't map to an owned queue (-EINVAL,
		 * host-tested validator).
		 */
		int rc = b->ops.rss_indir_check(b->priv, rxfh->indir,
						R8125_RSS_INDIR_SIZE,
						b->active_rx_queues);
		if (rc)
			return rc;
		/* Only the kernel default spread is supported. Accept an echo of
		 * the default; reject a custom (valid-but-different) table with
		 * -EOPNOTSUPP rather than silently no-op'ing — the hardware always
		 * runs the default for the active queue count. Custom indirection
		 * is a documented follow-up.
		 */
		for (i = 0; i < R8125_RSS_INDIR_SIZE; i++)
			if (rxfh->indir[i] !=
			    r8125_bridge_rxfh_indir_default(i, b->active_rx_queues))
				return -EOPNOTSUPP;
	}
	/* A custom hash key is likewise unsupported; accept only an echo of the
	 * current (boot-stable) key, reject a real change.
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

/*
 * `ethtool -L` set_channels. We expose dedicated RX channels (1..max) and a
 * single fixed TX queue, so reject combined/tx/other changes and pass the
 * requested RX count to Rust, which validates it (owned queues + V3/V2
 * prerequisites) and stores the runtime override. On acceptance a running
 * device is reconfigured (stop+open) so the new count takes effect immediately;
 * if it is down the override applies at the next open. Runs under RTNL.
 */
static int bridge_set_channels(struct net_device *ndev,
			       struct ethtool_channels *ch)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc;

	if (ch->combined_count != 0 || ch->tx_count != 1 || ch->other_count != 0)
		return -EINVAL;

	rc = b->ops.set_channels(b->priv, ch->rx_count);
	if (rc)
		return rc;

	if (netif_running(ndev)) {
		rc = r8125_bridge_reopen(ndev);
	} else {
		/* Down: mirror the validated count into the C cache now (same
		 * helper as open) so get_channels/-l/-x aren't stale until open.
		 */
		r8125_bridge_set_active_rx_queues(ndev, ch->rx_count);
	}
	return rc;
}

/*
 * Link settings + autoneg reset. The integrated PHY is owned by phylib (attached
 * via phy_connect_direct, which sets ndev->phydev), so these delegate straight
 * to the phylib helpers — we do NOT reimplement Realtek PHY logic here. phylib
 * itself returns -ENODEV when no PHY is attached; the explicit guard documents
 * that contract at the boundary. Runs under RTNL.
 */
static int bridge_get_link_ksettings(struct net_device *ndev,
				     struct ethtool_link_ksettings *cmd)
{
	if (!ndev->phydev)
		return -ENODEV;
	return phy_ethtool_get_link_ksettings(ndev, cmd);
}

static int bridge_set_link_ksettings(struct net_device *ndev,
				     const struct ethtool_link_ksettings *cmd)
{
	if (!ndev->phydev)
		return -ENODEV;
	return phy_ethtool_set_link_ksettings(ndev, cmd);
}

static int bridge_nway_reset(struct net_device *ndev)
{
	if (!ndev->phydev)
		return -ENODEV;
	return phy_ethtool_nway_reset(ndev);
}

/*
 * Pause (flow control) parameters. The PHY advertises pause capability and
 * phylib owns the MAC<->PHY pause negotiation, so delegate straight to it.
 * get is void (phylib fills zeros when no PHY); set returns -ENODEV without one.
 */
static void bridge_get_pauseparam(struct net_device *ndev,
				  struct ethtool_pauseparam *pause)
{
	struct phy_device *phydev = ndev->phydev;
	bool tx = false, rx = false;

	if (!phydev)
		return;
	pause->autoneg = phydev->autoneg;
	phy_get_pause(phydev, &tx, &rx);
	pause->tx_pause = tx;
	pause->rx_pause = rx;
}

static int bridge_set_pauseparam(struct net_device *ndev,
				 struct ethtool_pauseparam *pause)
{
	struct phy_device *phydev = ndev->phydev;

	if (!phydev)
		return -ENODEV;
	if (!phy_validate_pause(phydev, pause))
		return -EINVAL;
	phy_set_asym_pause(phydev, pause->rx_pause, pause->tx_pause);
	return 0;
}

/*
 * Ring parameters. Report the fixed descriptor ring depth (R8125_BRIDGE_RING_LEN
 * == Rust ring::RING_LEN). Resize is intentionally not implemented for the first
 * RFC, so no .set_ringparam is wired and `ethtool -G` returns -EOPNOTSUPP — a
 * clean unsupported, never a silent no-op (live resize needs RX page-pool / NAPI
 * / DMA-ring / BQL rollback tests we have not landed).
 */
static void bridge_get_ringparam(struct net_device *ndev,
				 struct ethtool_ringparam *ring,
				 struct kernel_ethtool_ringparam *kring,
				 struct netlink_ext_ack *extack)
{
	ring->rx_max_pending = R8125_BRIDGE_RING_LEN;
	ring->tx_max_pending = R8125_BRIDGE_RING_LEN;
	ring->rx_pending = R8125_BRIDGE_RING_LEN;
	ring->tx_pending = R8125_BRIDGE_RING_LEN;
}

/*
 * Energy-Efficient Ethernet. The integrated PHY owns EEE negotiation, so
 * delegate straight to phylib (same pattern as pauseparam). phylib returns
 * -ENODEV when no PHY is attached; the explicit guard documents the contract.
 * Runs under RTNL.
 */
static int bridge_get_eee(struct net_device *ndev, struct ethtool_keee *data)
{
	if (!ndev->phydev)
		return -ENODEV;
	return phy_ethtool_get_eee(ndev->phydev, data);
}

static int bridge_set_eee(struct net_device *ndev, struct ethtool_keee *data)
{
	if (!ndev->phydev)
		return -ENODEV;
	return phy_ethtool_set_eee(ndev->phydev, data);
}

/*
 * Standardized IEEE 802.3 statistics, mapped from the hardware tally block
 * (the same DMA dump ndo_get_stats64 uses). Field mapping ported from
 * rtl8169_get_eth_{mac,ctrl}_stats / get_pause_stats. RTL8125B always has the
 * extended counter block, so the 64/32-bit extended fields are used directly.
 * A dump failure (no buffer / timeout) leaves the ethtool struct's defaults.
 */
static bool bridge_tally_refresh(struct r8125_bridge *b)
{
	return b->tally_vaddr && !b->ops.tally_dump(b->priv, b->tally_dma);
}

static void bridge_get_pause_stats(struct net_device *ndev,
				   struct ethtool_pause_stats *stats)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (!bridge_tally_refresh(b))
		return;
	stats->tx_pause_frames = le32_to_cpu(b->tally_vaddr->tx_pause_on);
	stats->rx_pause_frames = le32_to_cpu(b->tally_vaddr->rx_pause_on);
}

static void bridge_get_eth_mac_stats(struct net_device *ndev,
				     struct ethtool_eth_mac_stats *s)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_tally *t = b->tally_vaddr;

	if (!bridge_tally_refresh(b))
		return;
	s->FramesTransmittedOK		 = le64_to_cpu(t->tx_packets);
	s->SingleCollisionFrames	 = le32_to_cpu(t->tx_one_collision);
	s->MultipleCollisionFrames	 = le32_to_cpu(t->tx_multi_collision);
	s->FramesReceivedOK		 = le64_to_cpu(t->rx_packets);
	s->FramesLostDueToIntMACXmitError = le64_to_cpu(t->tx_errors);
	s->BroadcastFramesReceivedOK	 = le64_to_cpu(t->rx_broadcast);
	s->AlignmentErrors		 = le32_to_cpu(t->align_errors32);
	s->OctetsTransmittedOK		 = le64_to_cpu(t->tx_octets);
	s->LateCollisions		 = le32_to_cpu(t->tx_late_collision);
	s->FramesAbortedDueToXSColls	 = le32_to_cpu(t->tx_aborted32);
	s->OctetsReceivedOK		 = le64_to_cpu(t->rx_octets);
	s->FramesLostDueToIntMACRcvError = le32_to_cpu(t->rx_mac_error);
	s->MulticastFramesXmittedOK	 = le64_to_cpu(t->tx_multicast64);
	s->BroadcastFramesXmittedOK	 = le64_to_cpu(t->tx_broadcast64);
	s->MulticastFramesReceivedOK	 = le64_to_cpu(t->rx_multicast64);
	s->FrameTooLongErrors		 = le32_to_cpu(t->rx_frame_too_long);
}

static void bridge_get_eth_ctrl_stats(struct net_device *ndev,
				      struct ethtool_eth_ctrl_stats *stats)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (!bridge_tally_refresh(b))
		return;
	stats->UnsupportedOpcodesReceived =
		le32_to_cpu(b->tally_vaddr->rx_unknown_opcode);
}

/*
 * Register dump for `ethtool -d`. Mirrors rtl8169_get_regs: a fixed 256-byte
 * window of the MAC register space, read as 64 dwords through the Rust boundary
 * (which owns the BAR). Read-only; intended for debugging.
 */
#define R8125_REGS_DUMP_LEN 256

static int bridge_get_regs_len(struct net_device *ndev)
{
	return R8125_REGS_DUMP_LEN;
}

static void bridge_get_regs(struct net_device *ndev, struct ethtool_regs *regs,
			    void *p)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	u32 *dw = p;
	int i;

	regs->version = 0;
	for (i = 0; i < R8125_REGS_DUMP_LEN; i += 4)
		*dw++ = b->ops.read_reg(b->priv, i);
}

/*
 * Wake-on-LAN. Supports the magic packet plus unicast/broadcast/multicast wake
 * frames (WAKE_PHY link-change is not wired — Config3.LinkUp is reserved on
 * RTL8125B). get_wol reports the chip's current arm state; set_wol rejects
 * unsupported WAKE_* bits, programs the chip via Rust, and mirrors the armed
 * state into the PCI device's wakeup-enable so the PM core arms PME on suspend.
 * Runs under RTNL.
 */
#define R8125_WAKE_SUPPORTED (WAKE_MAGIC | WAKE_UCAST | WAKE_BCAST | WAKE_MCAST)

static void bridge_get_wol(struct net_device *ndev, struct ethtool_wolinfo *wol)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	wol->supported = R8125_WAKE_SUPPORTED;
	wol->wolopts = b->ops.get_wol(b->priv);
}

static int bridge_set_wol(struct net_device *ndev, struct ethtool_wolinfo *wol)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (wol->wolopts & ~R8125_WAKE_SUPPORTED)
		return -EINVAL;

	b->ops.set_wol(b->priv, wol->wolopts);

	if (ndev->dev.parent)
		device_set_wakeup_enable(ndev->dev.parent, !!wol->wolopts);

	return 0;
}

/* ethtool -s msglvl / message-level knob (netif_msg_* bitmask). */
static u32 bridge_get_msglevel(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	return b->msg_enable;
}

static void bridge_set_msglevel(struct net_device *ndev, u32 level)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	b->msg_enable = level;
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
	.set_channels		= bridge_set_channels,
	.get_rx_ring_count	= bridge_get_rx_ring_count,
	.get_link_ksettings	= bridge_get_link_ksettings,
	.set_link_ksettings	= bridge_set_link_ksettings,
	.nway_reset		= bridge_nway_reset,
	.get_pauseparam		= bridge_get_pauseparam,
	.set_pauseparam		= bridge_set_pauseparam,
	.get_ringparam		= bridge_get_ringparam,
	.get_eee		= bridge_get_eee,
	.set_eee		= bridge_set_eee,
	.get_msglevel		= bridge_get_msglevel,
	.set_msglevel		= bridge_set_msglevel,
	.get_ts_info		= ethtool_op_get_ts_info,
	.get_pause_stats	= bridge_get_pause_stats,
	.get_eth_mac_stats	= bridge_get_eth_mac_stats,
	.get_eth_ctrl_stats	= bridge_get_eth_ctrl_stats,
	.get_wol		= bridge_get_wol,
	.set_wol		= bridge_set_wol,
	.get_regs_len		= bridge_get_regs_len,
	.get_regs		= bridge_get_regs,
};
