// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge.c — minimal C bridge for the r8125_rust driver.
 *
 * Implements the contract in netdev_bridge.h. The actual driver logic
 * (PCI, MMIO, descriptor rings, hardware programming, NAPI poll body)
 * lives in Rust; this file's only job is the kernel-facing surface that
 * has no stable Rust API today: net_device + net_device_ops + NAPI +
 * sk_buff plumbing.
 *
 * Hard cap: 1380 LOC including comments. Raised from 1360 for reviewed
 * AER/runtime-PM failure handling: permanent-failure AER is detach-only (so a
 * later unregister cannot double-disable NAPI) and pm_runtime_get_sync failures
 * unwind with pm_runtime_put_noidle before any MMIO. Raised from 1220 for the
 * runtime-PM
 * surface (ndo_open/stop entry wrappers that bracket the stack open/close with
 * pm_runtime get/put, the runtime idle/suspend/resume helpers that autosuspend a
 * closed interface, and the probe/unbind usage-ref enable/disable). Previously
 * raised from 1200 for the PCIe AER error_detected teardown helper
 * (r8125_bridge_pm_error_detach: detach + full balanced stop, reused across
 * recovered channel states, re-init deferred to the shared pm_resume).
 * Previously raised from 1110 for the AF_XDP
 * zero-copy surgical per-queue RX reconfigure (r8125_bridge_xsk_reconfig_queue:
 * swap one queue's RX pool with the chip RX engine briefly off, no full
 * stop+open / link-down), including failure rollback to the previous pool, on
 * top of r8125_bridge_xsk_pool_setup + r8125_bridge_rxq_is_zc (which still use
 * the static ndo_open/ndo_stop for the multi-queue fallback).
 * The per-CPU netstats, IRQ-affinity,
 * and TX-queue-len additions plus the per-MTU zero-copy RX path fit after dead
 * RX helpers moved out; queue-id plumbing and the multi-queue NAPI lifecycle
 * helpers raised the cap from 540, then 615. Raised to 700 for the upstream
 * robustness features: random-MAC fallback for an invalid hardware MAC, the
 * ndo_tx_timeout watchdog + deferred reset_work recovery, and ndo_get_stats64
 * surfacing the drop counters. Raised to 760 for ndo_set_rx_mode, then 800 for
 * the hardware tally-dump path, then 820 for the system-sleep PM
 * detach/reattach helpers (r8125_bridge_pm_suspend / _resume, reached only via
 * the r8125_pci_pm-gated Rust callbacks), then 880 for the per-skb
 * ndo_features_check offload veto and phy_do_ioctl_running wiring, then 910 for
 * the live ndo_set_mac_address RAR reprogram + tally CounterReset, then 960 for
 * the netdev-genl per-queue statistics (netdev_stat_ops), then 1010 for the WoL
 * suspend arming branch + the IRQ affinity-hint clear helper, then 1030 for the
 * PHY LED class-device register/unregister wiring.
 * See cshim/README.md.
 *
 * Every ndo callback below is a thin delegation to the Rust vtable.
 * Kernel object setup stays here; packet-side counter increments live
 * next to the skb operations they account for.
 */

#include "netdev_bridge_internal.h"

#include <linux/atomic.h>
#include <linux/cpumask.h>
#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
#include <linux/interrupt.h>
#include <linux/phy.h>
#include <linux/pm_runtime.h>
#include <linux/rtnetlink.h>
#include <linux/skbuff.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <net/netdev_queues.h>
#include <net/xdp_sock_drv.h>
#include <asm/barrier.h>

/*
 * TX-descriptor transport-offset limits for the checksum-v2 engine (RTL8125B
 * is MAC_VER_63 = csum v2). Ported from r8169 GTTCPHO_MAX / TCPHO_MAX: a TCP
 * header offset beyond these cannot be encoded in the descriptor, so
 * ndo_features_check drops TSO / checksum offload for such skbs and lets the
 * stack do it in software.
 */
#define R8125_GTTCPHO_MAX	0x7f
#define R8125_TCPHO_MAX		0x3ff

/*
 * Raised from 64 (r8169 default) to 128: at MTU-1500 line rate (~166k pps)
 * the Rust RX poll is more per-packet-expensive than r8169's C path, so a
 * deeper per-poll drain reduces re-arm churn and ring-overrun drops. Eval
 * lever #1 (RX batching); measured on the KASAN KVM where the cost is
 * amplified.
 */
#define BRIDGE_NAPI_WEIGHT	128

/* ── ndo callbacks — each is a thin delegation to Rust ───────────────── */

static unsigned int bridge_feature_flags(netdev_features_t features)
{
	unsigned int flags = 0;

	if (features & NETIF_F_RXCSUM)
		flags |= R8125_BRIDGE_FEATURE_RXCSUM;
	if (features & NETIF_F_HW_VLAN_CTAG_RX)
		flags |= R8125_BRIDGE_FEATURE_RXVLAN;
	if (features & NETIF_F_RXHASH)
		flags |= R8125_BRIDGE_FEATURE_RXHASH;

	return flags;
}

/*
 * NAPI lifecycle helpers. Every RX queue's NAPI is created/enabled/deleted
 * together; idle queues beyond the runtime active count are simply never
 * scheduled (no IRQ routes to them). One loop, one place — so adding queues
 * cannot leave a site behind operating on rxq[0] only.
 */
static void bridge_napi_enable_all(struct r8125_bridge *b)
{
	unsigned int i;

	for (i = 0; i < R8125_BRIDGE_RX_QUEUE_COUNT; i++)
		napi_enable(&b->rxq[i].napi);
}

static void bridge_napi_disable_all(struct r8125_bridge *b)
{
	unsigned int i;

	for (i = 0; i < R8125_BRIDGE_RX_QUEUE_COUNT; i++)
		napi_disable(&b->rxq[i].napi);
}

static void bridge_napi_del_all(struct r8125_bridge *b)
{
	unsigned int i;

	for (i = 0; i < R8125_BRIDGE_RX_QUEUE_COUNT; i++)
		netif_napi_del(&b->rxq[i].napi);
}

static int bridge_ndo_open(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc;

	bridge_napi_enable_all(b);
	rc = b->ops.open(b->priv, bridge_feature_flags(ndev->features));
	if (rc) {
		bridge_napi_disable_all(b);
		return rc;
	}
	/* Zero the on-die tally counters now that RX is enabled, so the extended
	 * statistics (octets, collisions, pause frames) accumulate from a clean
	 * per-session baseline. Non-fatal: stats are best-effort.
	 */
	if (b->tally_vaddr)
		b->ops.tally_reset(b->priv, b->tally_dma);
	/* Rust open() performs the hardware bring-up and decides when the
	 * TX queue is ready. Carrier follows the PHY link-state callback.
	 */
	return 0;
}

static int bridge_ndo_stop(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	netif_tx_disable(ndev);
	bridge_napi_disable_all(b);
	b->ops.stop(b->priv);
	return 0;
}

/*
 * ndo_open / ndo_stop entry wrappers — the netdev_ops-registered entry points.
 * They exist ONLY to bracket the stack-initiated open/close with the runtime-PM
 * get/put (resume a runtime-suspended device before touching MMIO; release the
 * reference + arm the idle check after a close). The brackets are gated on
 * b->runtime_pm, set only on a RUNTIME_PM=1 build — so on the default build they
 * compile to a bare call and behaviour is byte-identical.
 *
 * Crucially the brackets live HERE, not in bridge_ndo_open/stop: those are also
 * called by the PM / reset / AER resume paths (bridge_pm_resume etc.), and
 * pm_runtime_get_sync() from inside a runtime_resume callback would deadlock.
 * Only the stack entry (via netdev_ops) goes through these wrappers; every
 * internal re-open keeps calling bridge_ndo_open/stop directly, bracket-free.
 *
 * pm_runtime_get_sync may run our runtime_resume (rtnl-free: it only attaches),
 * so taking it here while the stack holds RTNL is safe.
 */
static int bridge_ndo_open_entry(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int pmrc;
	int rc;

	if (b->runtime_pm) {
		pmrc = pm_runtime_get_sync(&b->pdev->dev);
		if (pmrc < 0) {
			pm_runtime_put_noidle(&b->pdev->dev);
			return pmrc;
		}
	}
	rc = bridge_ndo_open(ndev);
	if (b->runtime_pm)
		pm_runtime_put_sync(&b->pdev->dev);
	return rc;
}

static int bridge_ndo_stop_entry(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int pmrc;
	int rc;

	if (b->runtime_pm) {
		pmrc = pm_runtime_get_sync(&b->pdev->dev);
		if (pmrc < 0) {
			pm_runtime_put_noidle(&b->pdev->dev);
			return pmrc;
		}
	}
	rc = bridge_ndo_stop(ndev);
	/* The matching put arms the idle check: with the interface now closed,
	 * runtime_idle allows the autosuspend (interface-up vetoes it).
	 */
	if (b->runtime_pm)
		pm_runtime_put_sync(&b->pdev->dev);
	return rc;
}

static netdev_tx_t bridge_ndo_start_xmit(struct sk_buff *skb,
					 struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* All counter side-effects happen inside the Rust path via
	 * the skb helpers below — bridge_ndo_start_xmit itself is a pure
	 * delegation.
	 */
	return (netdev_tx_t)b->ops.xmit(b->priv, skb);
}

static int bridge_ndo_change_mtu(struct net_device *ndev, int new_mtu)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc = b->ops.change_mtu(b->priv, new_mtu);

	if (!rc) {
		ndev->mtu = new_mtu;
		/* RTL8125B's TSO MSS field is 11 bits (`TD1_MSS_SHIFT 18`,
		 * mask `0x7ff` = 2047 max). At MTU > 1500 the TCP MSS would
		 * overflow that field and the chip would segment with the
		 * low 11 bits of the requested MSS — visible as iperf3 going
		 * to 0 bps while ping still works (the bisection that
		 * surfaced this on 2026-05-28). r8169 mainline solves it the
		 * same way: drop NETIF_F_ALL_TSO + NETIF_F_CSUM at jumbo via
		 * `ndo_fix_features`. We trigger the renegotiation here so
		 * `bridge_ndo_fix_features` runs against the new MTU.
		 */
		netdev_update_features(ndev);
	}
	return rc;
}

/*
 * `bridge_ndo_fix_features` — RTL8125B feature mask vs MTU rule, ported
 * from `rtl8169_fix_features` in `r8169_main.c:1799`. Without this,
 * jumbo MTU + TSO produces frames whose MSS field wraps in the TX
 * descriptor's 11-bit slot, and the chip silently emits malformed
 * segments. Same workaround applies to HW CSUM at jumbo on MAC_VER
 * > 06. RTL8125B is MAC_VER_63, so both bits trip.
 */
static netdev_features_t bridge_ndo_fix_features(struct net_device *ndev,
						  netdev_features_t features)
{
	if (ndev->mtu > ETH_DATA_LEN) {
		features &= ~NETIF_F_ALL_TSO;
		features &= ~NETIF_F_CSUM_MASK;
	}
	return features;
}

/*
 * `ndo_features_check` — per-skb offload veto, ported from
 * `rtl8169_features_check`. RTL8125B uses the checksum-v2 engine, whose TX
 * descriptor encodes the transport-header offset in a limited field. For a GSO
 * skb whose TCP header sits beyond GTTCPHO_MAX, or a CHECKSUM_PARTIAL skb whose
 * header sits beyond TCPHO_MAX (or a runt < ETH_ZLEN), the chip would emit
 * malformed segments, so strip the offending offload and let the stack handle
 * it. fix_features (MTU rule) handles the jumbo case separately.
 */
static netdev_features_t bridge_ndo_features_check(struct sk_buff *skb,
						   struct net_device *ndev,
						   netdev_features_t features)
{
	if (skb_is_gso(skb)) {
		if (skb_transport_offset(skb) > R8125_GTTCPHO_MAX)
			features &= ~NETIF_F_ALL_TSO;
	} else if (skb->ip_summed == CHECKSUM_PARTIAL) {
		if (skb->len < ETH_ZLEN)
			features &= ~NETIF_F_CSUM_MASK;
		if (skb_transport_offset(skb) > R8125_TCPHO_MAX)
			features &= ~NETIF_F_CSUM_MASK;
	}

	return vlan_features_check(skb, features);
}

/*
 * ndo_set_mac_address. eth_mac_addr validates + stores the new address in
 * ndev->dev_addr; if the interface is running we must also reprogram the chip's
 * RX unicast filter (RAR) immediately, otherwise the hardware keeps filtering on
 * the old address until the next open. Mirrors mainline rtl_set_mac_address.
 * Runs under RTNL.
 */
static int bridge_ndo_set_mac_address(struct net_device *ndev, void *p)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc = eth_mac_addr(ndev, p);

	if (rc)
		return rc;
	if (netif_running(ndev))
		b->ops.set_mac_filter(b->priv);
	return 0;
}

static int bridge_ndo_set_features(struct net_device *ndev,
				   netdev_features_t features)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (!netif_running(ndev))
		return 0;

	return b->ops.set_features(b->priv, bridge_feature_flags(features));
}

/* NAPI poll wrapper: same delegation pattern. */
static int bridge_napi_poll(struct napi_struct *napi, int budget)
{
	struct r8125_bridge_rx_queue *rxq =
		container_of(napi, struct r8125_bridge_rx_queue, napi);
	struct r8125_bridge *b = rxq->bridge;

	return b->ops.poll(b->priv, rxq->queue_id, budget);
}

/*
 * Deferred chip reset. ndo_tx_timeout fires in the netdev-watchdog timer
 * (atomic) context where we cannot sleep, so it only schedules this work, which
 * does the real recovery (full stop+open via r8125_bridge_reopen) under RTNL.
 */
static void bridge_reset_work(struct work_struct *work)
{
	struct r8125_bridge *b = container_of(work, struct r8125_bridge, reset_work);
	struct net_device *ndev = b->ndev;

	netdev_warn(ndev, "recovering link after TX watchdog timeout\n");
	if (b->devlink) {
		/* Record the error via devlink-health; the reporter auto-recovers
		 * through its .recover op (RTNL + r8125_bridge_reopen). One source of
		 * recovery, observable via `devlink health show`.
		 */
		r8125_bridge_devlink_report_tx_timeout(b->devlink);
		return;
	}
	/* No devlink instance — recover directly (same reopen). */
	rtnl_lock();
	if (netif_running(ndev))
		r8125_bridge_reopen(ndev);
	rtnl_unlock();
}

/*
 * TX watchdog. The stack calls this when a TX queue has not made progress for
 * dev->watchdog_timeo. Schedule a reset rather than reset inline (atomic
 * context). Without this a wedged TX ring would never recover on its own.
 */
static void bridge_ndo_tx_timeout(struct net_device *ndev, unsigned int txqueue)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	netdev_warn(ndev, "TX watchdog timeout on queue %u; scheduling reset\n",
		    txqueue);
	schedule_work(&b->reset_work);
}

/*
 * ndo_get_stats64. The core maintains rx/tx packets+bytes in per-CPU tstats
 * (NETDEV_PCPU_STAT_TSTATS); fold the disposition drop counters into
 * the standard rx_dropped/tx_dropped so `ip -s link` / SNMP see them too, not
 * only `ethtool -S`. Also folds chip tally error counters when the hardware dump
 * succeeds.
 */
static void bridge_ndo_get_stats64(struct net_device *ndev,
				   struct rtnl_link_stats64 *stats)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_counters c;

	dev_get_tstats64(ndev, stats);
	r8125_bridge_counters_snapshot(ndev, &c);
	stats->rx_dropped += c.rx_dropped_error;
	stats->tx_dropped += c.tx_dropped_error;

	/* Hardware tally: dump the on-die counters and fold the error totals the
	 * software disposition counters can't see (RX FIFO-overflow misses,
	 * chip-level rx/tx errors). tally_dump returns 0 on success.
	 */
	if (b->tally_vaddr && !b->ops.tally_dump(b->priv, b->tally_dma)) {
		u32 rx_missed;

		/* The chip has just DMA-written the coherent tally buffer. The MMIO
		 * completion poll tells us the dump finished; pair it with a DMA read
		 * barrier before consuming the buffer contents on weakly ordered CPUs.
		 */
		dma_rmb();
		rx_missed = le16_to_cpu(b->tally_vaddr->rx_missed);
		stats->rx_missed_errors += rx_missed;
		stats->rx_errors += le32_to_cpu(b->tally_vaddr->rx_errors);
		stats->tx_errors += le64_to_cpu(b->tally_vaddr->tx_errors);
	}
}

/*
 * ndo_set_rx_mode — compute the RX accept filter + 64-bit multicast hash from
 * the netdev flags and mc list, then hand them to Rust to program RCR + MAR.
 * Mirrors the vendor rtl8125_hw_set_rx_packet_filter (ether_crc>>26 hash). The
 * multicast hash words are passed in natural order; Rust applies the hardware
 * byte/word swap. Falls back to allmulti past R8125_MC_HASH_MAX groups.
 */
static void bridge_ndo_set_rx_mode(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	unsigned int accept;
	u32 mc0 = 0, mc1 = 0;

	if (ndev->flags & IFF_PROMISC) {
		accept = R8125_RX_ACCEPT_BROADCAST | R8125_RX_ACCEPT_MULTICAST |
			 R8125_RX_ACCEPT_MYPHYS | R8125_RX_ACCEPT_ALLPHYS;
		mc0 = mc1 = 0xffffffff;
	} else if ((ndev->flags & IFF_ALLMULTI) ||
		   netdev_mc_count(ndev) > R8125_MC_HASH_MAX) {
		accept = R8125_RX_ACCEPT_BROADCAST | R8125_RX_ACCEPT_MULTICAST |
			 R8125_RX_ACCEPT_MYPHYS;
		mc0 = mc1 = 0xffffffff;
	} else {
		struct netdev_hw_addr *ha;

		accept = R8125_RX_ACCEPT_BROADCAST | R8125_RX_ACCEPT_MYPHYS;
		netdev_for_each_mc_addr(ha, ndev) {
			int bit = ether_crc(ETH_ALEN, ha->addr) >> 26; /* 0..63 */

			if (bit < 32)
				mc0 |= 1u << bit;
			else
				mc1 |= 1u << (bit - 32);
			accept |= R8125_RX_ACCEPT_MULTICAST;
		}
	}

	b->ops.set_rx_mode(b->priv, accept, mc0, mc1);
}

/*
 * Per-queue statistics for the netdev-genl qstats API (netdev_stat_ops). The
 * device totals come from dev_sw_netstats (ndo_get_stats64); here we report the
 * same packets/bytes split per RX queue and for the single TX queue, so the
 * base + per-queue sum matches the device total. base_stats are zero — the queue
 * set is fixed, so no traffic is attributed outside a live queue. Only packets +
 * bytes are tracked; the other fields stay at their ~0 "unset" init.
 */
static void bridge_get_queue_stats_rx(struct net_device *ndev, int idx,
				      struct netdev_queue_stats_rx *stats)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q = &b->rxq[idx];

	stats->packets = READ_ONCE(q->rx_packets);
	stats->bytes = READ_ONCE(q->rx_bytes);
}

static void bridge_get_queue_stats_tx(struct net_device *ndev, int idx,
				      struct netdev_queue_stats_tx *stats)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	stats->packets = READ_ONCE(b->tx_packets);
	stats->bytes = READ_ONCE(b->tx_bytes);
}

static void bridge_get_base_stats(struct net_device *ndev,
				  struct netdev_queue_stats_rx *rx,
				  struct netdev_queue_stats_tx *tx)
{
	rx->packets = 0;
	rx->bytes = 0;
	tx->packets = 0;
	tx->bytes = 0;
}

static const struct netdev_stat_ops bridge_stat_ops = {
	.get_queue_stats_rx	= bridge_get_queue_stats_rx,
	.get_queue_stats_tx	= bridge_get_queue_stats_tx,
	.get_base_stats		= bridge_get_base_stats,
};

static const struct net_device_ops bridge_ops = {
	.ndo_open		= bridge_ndo_open_entry,
	.ndo_stop		= bridge_ndo_stop_entry,
	.ndo_start_xmit		= bridge_ndo_start_xmit,
	.ndo_change_mtu		= bridge_ndo_change_mtu,
	.ndo_fix_features	= bridge_ndo_fix_features,
	.ndo_features_check	= bridge_ndo_features_check,
	.ndo_set_features	= bridge_ndo_set_features,
	.ndo_eth_ioctl		= phy_do_ioctl_running,
	.ndo_set_mac_address	= bridge_ndo_set_mac_address,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_tx_timeout		= bridge_ndo_tx_timeout,
	.ndo_get_stats64	= bridge_ndo_get_stats64,
	.ndo_set_rx_mode	= bridge_ndo_set_rx_mode,
	.ndo_bpf		= r8125_bridge_ndo_bpf,
	.ndo_xdp_xmit		= r8125_bridge_ndo_xdp_xmit,
	.ndo_xsk_wakeup		= r8125_bridge_xsk_wakeup,
};

/* ── Lifecycle ─────────────────────────────────────────────────────── */

struct net_device *r8125_bridge_alloc(struct pci_dev *pdev, void *priv,
				      const struct r8125_bridge_ops *ops,
				      const unsigned char mac[ETH_ALEN])
{
	struct net_device *ndev;
	struct r8125_bridge *b;
	unsigned int i;

	/* Allocate with RX_QUEUE_COUNT hardware RX queues (1 TX) so the stack can
	 * track up to that many RX queues (RPS sysfs, real_num_rx_queues). The
	 * runtime active count starts at 1 and is raised at ndo_open when an
	 * rss_queues opt-in activates more.
	 */
	ndev = alloc_etherdev_mqs(sizeof(*b), 1, R8125_BRIDGE_RX_QUEUE_COUNT);
	if (!ndev)
		return NULL;
	netif_set_real_num_rx_queues(ndev, 1);

	SET_NETDEV_DEV(ndev, &pdev->dev);
	ndev->netdev_ops = &bridge_ops;
	ndev->ethtool_ops = &r8125_bridge_ethtool_ops;
	ndev->stat_ops = &bridge_stat_ops;
	ndev->needs_free_netdev = false; /* we free explicitly */
	/* The chip repopulates IDR0..IDR5 from on-chip storage after reset, but a
	 * fresh/uninitialised chip (or one left zeroed by a prior reset) can hand
	 * back an all-zero or otherwise invalid address. The stack refuses to bring
	 * up an interface with an invalid MAC (EADDRNOTAVAIL on `ip link set up`),
	 * so fall back to a random address like r8169 does, rather than registering
	 * an unusable device.
	 */
	if (is_valid_ether_addr(mac)) {
		eth_hw_addr_set(ndev, mac);
	} else {
		eth_hw_addr_random(ndev);
		dev_warn(&pdev->dev,
			 "invalid hardware MAC %pM; using random %pM\n",
			 mac, ndev->dev_addr);
	}

	/* Jumbo support up to 9000 bytes. RX slot geometry now
	 * comes from per-MTU sizing in netdev_bridge_rx_pool.c, and `ndo_open`
	 * creates a new page_pool sized for the current MTU.
	 * We keep the 9000 MTU cap (industry-common) unless operators opt
	 * in to the chip's 16380 limit after validation.
	 */
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = 9000;

	/* The unicast filter is reprogrammed live by ndo_set_mac_address, so the
	 * stack may change the address while the interface is up.
	 */
	ndev->priv_flags |= IFF_LIVE_ADDR_CHANGE;

	/* Arm the TX watchdog so a wedged TX queue is detected and recovered
	 * (bridge_ndo_tx_timeout -> reset_work -> r8125_bridge_reopen).
	 */
	ndev->watchdog_timeo = 5 * HZ;

	/* Per-CPU netstats (RX_OPTIMIZATION_CANDIDATES.md §G).
	 * With `NETDEV_PCPU_STAT_TSTATS` the kernel uses
	 * `dev_get_tstats64` to sum per-CPU rx_packets/rx_bytes/
	 * tx_packets/tx_bytes; the hot path calls
	 * `dev_sw_netstats_{rx,tx}_add` which is a single per-CPU
	 * INC + ADD instead of a shared-cache-line WRITE_ONCE pair.
	 * Same idiom r8169 uses (`r8169_main.c:5828`). Eliminates the
	 * `ndev->stats.{rx,tx}_packets` cache-line contention.
	 */
	ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS;

	/* Drop the default 1000-deep TX queue to 256
	 * (RX_OPTIMIZATION_CANDIDATES.md §M). At 2.35 Gbps line rate a
	 * 1000-packet backlog is ~3.4 ms of bufferbloat — bad for the
	 * heterogeneous-load-balancer tail-latency goal. 256 caps the
	 * worst-case TX queueing delay at ~870 us while still leaving
	 * room for short bursts. r8169 keeps 1000 as kernel default;
	 * we deliberately diverge for latency.
	 */
	ndev->tx_queue_len = 256;

	/* HW offload feature advertisement. opts bits + skb-side setup
	 * are in netdev_bridge_offload.c (csum + TSO encoders), and the
	 * driver advertises the matching kernel-side capability flags
	 * here so the stack actually exercises the offload paths.
	 *
	 * TSO segment cap = 10. The chip's LSO engine reliably handles up
	 * to 11 MSS-segments per super-skb; 12+ stalls the TX queue.
	 * r8169 mainline + Realtek vendor both publish 64; that is wrong
	 * for this chip. Line rate (2.35 Gbps) is reached at ~8 segments
	 * so the cap is not a throughput bottleneck. Full bisection log
	 * + counter-evidence: docs/RTL8125B_TSO_NOTES.md.
	 */
	ndev->hw_features = NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM |
			    NETIF_F_RXCSUM | NETIF_F_SG |
			    NETIF_F_TSO | NETIF_F_TSO6 |
			    NETIF_F_HW_VLAN_CTAG_TX |
			    NETIF_F_HW_VLAN_CTAG_RX |
			    NETIF_F_RXHASH;
	ndev->features = ndev->hw_features;
	/* The driver mandates a 64-bit DMA mask at probe (set_64bit_dma_mask,
	 * probe fails otherwise), so the device can DMA to high memory. Advertise
	 * it like mainline r8169; it is a fixed capability, not user-toggleable, so
	 * it lives in features (not hw_features).
	 */
	ndev->features |= NETIF_F_HIGHDMA;
	/* XDP: BASIC (attach + XDP_PASS/DROP/TX/ABORTED), REDIRECT, NDO_XMIT
	 * (the redirect-target transmit side, ndo_xdp_xmit) and XSK_ZEROCOPY are all
	 * implemented (netdev_bridge_xdp.c + netdev_bridge_xsk.c). XDP_TX/NDO_XMIT
	 * enqueue on the Rust TX ring via ops.xdp_xmit_one; REDIRECT goes through
	 * xdp_do_redirect + a once-per-poll xdp_do_flush; XSK_ZEROCOPY binds a umem
	 * pool per queue (ndo_bpf XDP_SETUP_XSK_POOL + ndo_xsk_wakeup). The advertised
	 * set is exactly what works; BASIC|REDIRECT also unlocks copy-mode AF_XDP.
	 */
	ndev->xdp_features = NETDEV_XDP_ACT_BASIC | NETDEV_XDP_ACT_REDIRECT |
			     NETDEV_XDP_ACT_NDO_XMIT | NETDEV_XDP_ACT_XSK_ZEROCOPY;
	ndev->vlan_features = NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM |
			      NETIF_F_SG | NETIF_F_TSO | NETIF_F_TSO6;

	netif_set_tso_max_size(ndev, 64000);
	netif_set_tso_max_segs(ndev, 10);

	b = netdev_priv(ndev);
	b->ndev = ndev;
	b->pdev = pdev;
	b->priv = priv;
	b->ops = *ops;
	/* Runtime active count starts at the single-queue default; an rss_queues
	 * opt-in raises it. All MAX NAPI instances are created regardless.
	 */
	b->active_rx_queues = 1;
	b->msg_enable = netif_msg_init(-1, NETIF_MSG_DRV | NETIF_MSG_PROBE |
					   NETIF_MSG_LINK | NETIF_MSG_IFUP |
					   NETIF_MSG_IFDOWN);
	INIT_WORK(&b->reset_work, bridge_reset_work);

	if (r8125_bridge_counters_alloc(b)) {
		free_netdev(ndev);
		return NULL;
	}

	/* Coherent buffer for the hardware tally-counter dump. Non-fatal: if it
	 * fails, ndo_get_stats64 simply skips the hardware error counters.
	 */
	b->tally_vaddr = dma_alloc_coherent(&pdev->dev, sizeof(*b->tally_vaddr),
					    &b->tally_dma, GFP_KERNEL);

	for (i = 0; i < R8125_BRIDGE_RX_QUEUE_COUNT; i++) {
		b->rxq[i].bridge = b;
		b->rxq[i].queue_id = i;
		netif_napi_add_weight(ndev, &b->rxq[i].napi, bridge_napi_poll,
				      BRIDGE_NAPI_WEIGHT);
	}
	return ndev;
}

static void bridge_tally_free(struct r8125_bridge *b)
{
	if (b->tally_vaddr)
		dma_free_coherent(&b->pdev->dev, sizeof(*b->tally_vaddr),
				  b->tally_vaddr, b->tally_dma);
	b->tally_vaddr = NULL;
}

void r8125_bridge_free(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	cancel_work_sync(&b->reset_work);
	bridge_tally_free(b);
	bridge_napi_del_all(b);
	r8125_bridge_counters_free(b);
	free_netdev(ndev);
}

int r8125_bridge_register(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc = register_netdev(ndev);

	if (rc)
		return rc;
	/* Register the PHY LED class devices now that ndev->dev exists. Best-effort
	 * (mirrors mainline): a NULL result just means no LED sysfs surface.
	 */
	b->leds = r8125_bridge_init_leds(ndev);
	/* devlink instance + TX health reporter (best-effort; NULL on failure or a
	 * kernel without CONFIG_NET_DEVLINK keeps the direct-reopen recovery).
	 */
	b->devlink = r8125_bridge_devlink_init(ndev);
	return 0;
}

void r8125_bridge_unregister_and_free(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* Remove the LED class devices (children of ndev->dev) before the netdev
	 * goes away.
	 */
	r8125_bridge_remove_leds(b->leds);
	b->leds = NULL;

	/* Tear down the devlink instance (independent of the netdev). */
	r8125_bridge_devlink_remove(b->devlink);
	b->devlink = NULL;

	/* Order: unregister_netdev synchronously runs ndo_stop (which calls
	 * phy_stop + phy_disconnect — severing the phy_device from the
	 * netdev). Only THEN is it safe to unregister the mdiobus, which
	 * removes the phy_device from the bus and frees it. mdiobus_free
	 * must happen before free_netdev because the bridge struct holds
	 * the mii_bus pointer.
	 */
	unregister_netdev(ndev);
	/* After unregister no watchdog can schedule reset_work; flush any in
	 * flight before freeing. Called without RTNL held, so the work's
	 * rtnl_lock cannot deadlock us.
	 */
	cancel_work_sync(&b->reset_work);
	if (b->mii_bus) {
		mdiobus_unregister(b->mii_bus);
		mdiobus_free(b->mii_bus);
		b->mii_bus = NULL;
		b->phydev = NULL;
	}
	bridge_tally_free(b);
	bridge_napi_del_all(b);
	r8125_bridge_counters_free(b);
	free_netdev(ndev);
}

/*
 * `r8125_bridge_irq_pin_cpu` — IRQ CPU affinity hint
 * (RX_OPTIMIZATION_CANDIDATES.md §L).
 *
 * Suggest to the kernel + `irqbalance` that this MSI-X vector
 * should be serviced on a specific CPU. Reduces tail latency from
 * softirq cross-CPU migration AND keeps the per-CPU NAPI page-frag
 * cache warm (helps the `napi_alloc_skb` fast path).
 *
 * The kernel-internal hint can be overridden by an explicit
 * `/proc/irq/N/smp_affinity` write or by `irqbalance` if it
 * deliberately ignores hints — both are operator choices we
 * respect. We just provide a sensible default.
 *
 * `irq_set_affinity_and_hint` returns 0 on success; on failure we
 * log and proceed (no fatal). The hint MUST be cleared (see
 * `r8125_bridge_irq_clear_hint`) before `free_irq`, which WARNs
 * (kernel/irq/manage.c `WARN_ON_ONCE(desc->affinity_hint)`) if a hint
 * is still attached.
 */
int r8125_bridge_irq_pin_cpu(unsigned int irq, int cpu)
{
	if (cpu < 0 || cpu >= nr_cpu_ids || !cpu_online(cpu))
		return -EINVAL;
	/* `cpumask_of(cpu)` returns a `const struct cpumask *` from the
	 * kernel's pre-allocated per-CPU table — no stack-frame growth
	 * (an inline `struct cpumask` would push us past
	 * `-Wframe-larger-than=1024` on `NR_CPUS=8192` builds).
	 */
	return irq_set_affinity_and_hint(irq, cpumask_of(cpu));
}

/*
 * Drop any IRQ affinity hint set by `r8125_bridge_irq_pin_cpu` before
 * `free_irq`. free_irq WARNs if a hint is still attached; clearing it is a
 * no-op when none was set, so the teardown path can call this unconditionally
 * for every vector it is about to free.
 */
void r8125_bridge_irq_clear_hint(unsigned int irq)
{
	irq_update_affinity_hint(irq, NULL);
}

/*
 * `r8125_bridge_num_online_cpus` / `r8125_bridge_node_base_cpu` — multi-queue
 * affinity spread inputs.
 *
 * The Rust side's host-tested `layout::irq_affinity_cpu(index, base, ncpus)`
 * decides which CPU each MSI-X vector pins to so the active vectors fan out
 * across distinct per-CPU IOVA caches (see that function's docs and the gateway
 * multi-queue DMA-contention finding). These two helpers feed it the kernel
 * facts it can't read directly: the count of online CPUs and the PCI-local
 * NUMA-node first-online CPU (the fan-out base). The actual pin still goes
 * through `r8125_bridge_irq_pin_cpu`, which validates `cpu_online` and falls
 * back gracefully if the computed CPU is offline.
 */
unsigned int r8125_bridge_num_online_cpus(void)
{
	return num_online_cpus();
}

int r8125_bridge_node_base_cpu(struct pci_dev *pdev)
{
	int node = dev_to_node(&pdev->dev);
	int cpu;

	if (node == NUMA_NO_NODE)
		cpu = cpumask_first(cpu_online_mask);
	else
		cpu = cpumask_first_and(cpumask_of_node(node), cpu_online_mask);
	if (cpu >= nr_cpu_ids)
		return -EINVAL;
	return cpu;
}

void r8125_bridge_dma_rmb(void)
{
	dma_rmb();
}

/*
 * `r8125_bridge_dma_wmb` — sister to `_dma_rmb`. Issue a write-side DMA
 * barrier before publishing a descriptor with the DescOwn bit set
 * (TX xmit path) and before re-posting an RX descriptor to the chip
 * (NAPI poll path). On x86 (TSO) this expands to `sfence`; on ARM/
 * RISC-V it's a real `dmb ishst`. Pairs with the chip's view of the
 * DMA-coherent descriptor ring: without it, the chip could read
 * `opts1` (with OWN set) before the matching `addr` / `opts2` stores
 * are visible to the bus. r8169 uses `dma_wmb()` at the same point
 * (r8169_main.c:4189 + :4636).
 *
 * Cost on x86: one `sfence` per call — measurable only in micro-
 * benchmarks; invisible at line rate.
 */
void r8125_bridge_dma_wmb(void)
{
	dma_wmb();
}

/* ── Flow-control + NAPI helpers ────────────────────────────────────── */

void r8125_bridge_tx_stop_queue(struct net_device *ndev)
{
	netif_tx_stop_queue(netdev_get_tx_queue(ndev, 0));
}

void r8125_bridge_tx_wake_queue(struct net_device *ndev)
{
	netif_tx_wake_queue(netdev_get_tx_queue(ndev, 0));
}

/*
 * netdev_xmit_more() batching hint: true when the qdisc has more packets
 * queued behind this one in the current xmit burst. Lets ndo_start_xmit defer
 * the TX doorbell to the last packet of a burst (xmit_more == false) so one
 * MMIO write amortizes a batch — the same optimization r8169 uses in
 * rtl8169_start_xmit. Pure read of the net core's per-CPU xmit state; it is a
 * batching hint only and is independent of BQL, so it is MSI-safe.
 */
bool r8125_bridge_netdev_xmit_more(void)
{
	return netdev_xmit_more();
}

/*
 * Fill `len` bytes of `key` with the system RSS Toeplitz key via
 * netdev_rss_key_fill (a boot-stable, randomly-seeded key shared across
 * NICs). Used by the single-queue RXHASH path so the key is not a hardcoded
 * constant baked into the driver (predictable hashes across all units).
 */
void r8125_bridge_rss_key_fill(u8 *key, u32 len)
{
	netdev_rss_key_fill(key, len);
}

void r8125_bridge_napi_schedule(struct net_device *ndev, unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (WARN_ON_ONCE(queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT))
		return;
	napi_schedule(&b->rxq[queue_id].napi);
}

void r8125_bridge_napi_complete_done(struct net_device *ndev,
				     unsigned int queue_id, int work_done)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (WARN_ON_ONCE(queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT))
		return;
	napi_complete_done(&b->rxq[queue_id].napi, work_done);
}

/* Set the runtime active RX queue count. Reported by ethtool
 * get_channels / get_rx_ring_count and pushed to the stack via
 * netif_set_real_num_rx_queues (RPS sysfs). Called by Rust ndo_open under RTNL
 * with the netdev down. Clamped to [1, R8125_BRIDGE_RX_QUEUE_COUNT].
 */
/* Copy the netdev's current dev_addr out so the Rust open path can program it
 * into the chip RX filter (rar_set). dev_addr is whatever the alloc path settled
 * on: the chip MAC, or a random fallback for an invalid one.
 */
void r8125_bridge_dev_addr(struct net_device *ndev, unsigned char out[ETH_ALEN])
{
	memcpy(out, ndev->dev_addr, ETH_ALEN);
}

void r8125_bridge_set_active_rx_queues(struct net_device *ndev, unsigned int n)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (n < 1)
		n = 1;
	if (n > R8125_BRIDGE_RX_QUEUE_COUNT)
		n = R8125_BRIDGE_RX_QUEUE_COUNT;
	b->active_rx_queues = n;
	WARN_ON_ONCE(netif_set_real_num_rx_queues(ndev, n));
}

/*
 * Reconfigure a running netdev for ethtool set_channels: a full stop + open so
 * the Rust open path re-reads the (now-overridden) RX-queue count and re-wires
 * IRQs/NAPI/RSS for it. Same down/up the kernel runs on `ip link set down/up`;
 * called under RTNL. On open failure the netdev is left down and the errno is
 * propagated (ethtool reports it).
 */
int r8125_bridge_reopen(struct net_device *ndev)
{
	bridge_ndo_stop(ndev);
	return bridge_ndo_open(ndev);
}

/* True when an AF_XDP umem pool is bound to this RX queue (zero-copy). Read by
 * the Rust RX path (allocate / pre-post / poll refill) to take the ZC branch.
 */
bool r8125_bridge_rxq_is_zc(struct net_device *ndev, unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT)
		return false;
	return b->rxq[queue_id].xsk_pool != NULL;
}

/*
 * Live per-queue RX reconfigure for an AF_XDP bind/unbind: swap ONE queue's RX
 * pool (page_pool <-> umem) WITHOUT a full device stop+open. The full reopen
 * re-applies the PHY firmware + renegotiates (~4s link-down) and races the ZC
 * cold-start bootstrap; this instead (igc_xdp_enable_pool pattern) disables NAPI,
 * has the Rust side briefly turn the chip RX engine off (TX/PHY/IRQ stay up, so
 * the LINK NEVER DROPS), frees+rebuilds just this queue's ring, and re-enables.
 * The q->xsk_pool toggle happens BETWEEN rx_quiesce (frees the old buffers with
 * the old pool type) and rx_restore (builds the new pool), so each phase uses the
 * matching allocator/freer. On restore failure it rolls back to the previous pool
 * before re-enabling NAPI. Only valid for queue 0 in the single-active-queue case
 * (the global RX-engine toggle would disturb other queues' heads); the
 * multi-queue caller falls back to a full reopen.
 */
static int r8125_bridge_xsk_reconfig_queue(struct net_device *ndev,
					   struct r8125_bridge_rx_queue *q,
					   struct xsk_buff_pool *new_pool,
					   unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct xsk_buff_pool *old_pool = q->xsk_pool;
	int rc;
	int rollback_rc;

	/* Surgical = touch ONLY this queue's NAPI (not bridge_napi_*_all). The
	 * caller gates this path on the single-active-queue case, but scoping to
	 * &q->napi keeps it correct if that ever relaxes: other queues' RX is not
	 * disturbed by a single-queue pool swap.
	 */
	napi_disable(&q->napi);
	b->ops.rx_quiesce(b->priv, queue_id);	/* RX engine off + free old pool */
	q->xsk_pool = new_pool;			/* toggle between free and build */
	rc = b->ops.rx_restore(b->priv, queue_id);	/* build new pool + RX on */
	if (rc) {
		q->xsk_pool = old_pool;
		rollback_rc = b->ops.rx_restore(b->priv, queue_id);
		if (rollback_rc)
			netdev_err(ndev,
				   "AF_XDP queue %u restore failed (%d), rollback failed (%d)\n",
				   queue_id, rc, rollback_rc);
	}
	napi_enable(&q->napi);
	return rc;
}

/*
 * XDP_SETUP_XSK_POOL (ndo_bpf): bind or unbind an AF_XDP umem pool to one RX
 * queue for zero-copy. DMA-maps/unmaps the umem and swaps the queue's RX pool.
 * On a running single-queue device this uses the surgical per-queue reconfigure
 * above (no link-down); multi-queue falls back to a full stop+open. The umem
 * fill ring is empty at bind, so the ZC restore posts 0 RX buffers; we then
 * advertise RX need-wakeup so userspace's first recvfrom/poll issues
 * ndo_xsk_wakeup, which posts the buffers synchronously (xsk_kick). When the
 * netdev is down, only the bound flag (+ DMA map) changes; the next ndo_open
 * builds the pool for it. Runs under RTNL (ndo_bpf contract).
 */
int r8125_bridge_xsk_pool_setup(struct net_device *ndev,
				struct xsk_buff_pool *pool, unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q;
	bool running = netif_running(ndev);
	bool live;
	int rc;

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT)
		return -EINVAL;
	if (running && queue_id >= b->active_rx_queues)
		return -EINVAL;
	q = &b->rxq[queue_id];
	live = running && b->active_rx_queues == 1 && queue_id == 0;

	if (pool) {
		if (q->xsk_pool)
			return -EBUSY;
		rc = xsk_pool_dma_map(pool, &b->pdev->dev, 0);
		if (rc)
			return rc;
		if (live) {
			rc = r8125_bridge_xsk_reconfig_queue(ndev, q, pool, queue_id);
		} else if (running) {
			bridge_ndo_stop(ndev);
			q->xsk_pool = pool;
			rc = bridge_ndo_open(ndev);
			if (rc) {
				int rollback_rc;

				q->xsk_pool = NULL;
				rollback_rc = bridge_ndo_open(ndev);
				if (rollback_rc)
					netdev_err(ndev,
						   "AF_XDP bind failed (%d), page-pool rollback failed (%d)\n",
						   rc, rollback_rc);
			}
		} else {
			q->xsk_pool = pool;	/* next ndo_open builds the umem pool */
			rc = 0;
		}
		if (rc) {
			q->xsk_pool = NULL;
			xsk_pool_dma_unmap(pool, 0);
			return rc;
		}
		/* Cold start: fill ring empty -> 0 buffers posted. Ask userspace to
		 * kick us (ndo_xsk_wakeup -> xsk_kick) once it has populated it.
		 */
		if (running)
			r8125_bridge_xsk_set_rx_wakeup(ndev, queue_id, true);
		return 0;
	}

	/* Unbind. */
	if (!q->xsk_pool)
		return 0;
	pool = q->xsk_pool;
	if (live) {
		rc = r8125_bridge_xsk_reconfig_queue(ndev, q, NULL, queue_id);
	} else if (running) {
		bridge_ndo_stop(ndev);	/* frees ZC buffers; q->xsk_pool still set */
		q->xsk_pool = NULL;
		rc = bridge_ndo_open(ndev);	/* recreates the page_pool */
		if (rc) {
			int rollback_rc;

			q->xsk_pool = pool;
			rollback_rc = bridge_ndo_open(ndev);
			if (rollback_rc)
				netdev_err(ndev,
					   "AF_XDP unbind failed (%d), xsk rollback failed (%d)\n",
					   rc, rollback_rc);
		}
	} else {
		q->xsk_pool = NULL;
		rc = 0;
	}
	if (!rc)
		xsk_pool_dma_unmap(pool, 0);
	return rc;
}

/*
 * System-sleep PM. Called from the Rust pci::Driver suspend/resume callbacks
 * (which the kernel-Rust PCI adapter now wires into dev_pm_ops). The PCI core
 * saves/restores config space and handles the D-state around these; we only
 * quiesce/re-init the device. RTNL is NOT held by the PM core, so take it here
 * (bridge_ndo_open/stop run under RTNL). netif_device_detach/attach hide the
 * device from the stack across the sleep. Only act if the interface was up.
 */
void r8125_bridge_pm_suspend(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	rtnl_lock();
	if (netif_running(ndev)) {
		u32 wol = b->ops.get_wol(b->priv);

		netif_device_detach(ndev);
		if (wol) {
			/*
			 * Wake-on-LAN keep-alive path. A full stop powers the PHY
			 * down (phy_stop) — no magic packet could then reach the
			 * wake detector, which is why the earlier attempts woke
			 * only on the RTC safety net. So do a LIGHT quiesce: stop
			 * NAPI but leave the rings, IRQ, RX engine, and (critically)
			 * the PHY powered. wol_suspend_arm then applies the r8169
			 * __rtl8169_set_wol recipe: chip WoL + PME bits, RX accept,
			 * and PMCH NO_PLL_DOWN so the internal PHY stays alive in D3.
			 * The PCI core enters D3 with PME (device_may_wakeup was set
			 * by set_wol).
			 */
			bridge_napi_disable_all(b);
			b->ops.wol_suspend_arm(b->priv, wol);
			b->wol_suspended = true;
		} else {
			bridge_ndo_stop(ndev);
			b->wol_suspended = false;
		}
	}
	rtnl_unlock();
}

int r8125_bridge_pm_resume(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc = 0;

	rtnl_lock();
	if (netif_running(ndev)) {
		if (b->wol_suspended) {
			/*
			 * The WoL keep-alive suspend left NAPI disabled but the
			 * rings/IRQ/PHY intact; D3 reset the chip's operational
			 * state. Re-balance NAPI, then do a full stop+reopen to
			 * cleanly tear the stale state down and re-init at full
			 * speed (a fresh phy_connect restores the link).
			 */
			b->wol_suspended = false;
			bridge_napi_enable_all(b);
			bridge_ndo_stop(ndev);
		}
		rc = bridge_ndo_open(ndev);
		/* Only re-expose the device to the stack if re-init succeeded;
		 * a failed reopen must surface as a resume error, not a silently
		 * reattached dead interface.
		 */
		if (rc == 0)
			netif_device_attach(ndev);
	}
	rtnl_unlock();
	return rc;
}

/*
 * Runtime PM (autosuspend). Reached only via the r8125_pci_runtime_pm-gated Rust
 * callbacks. Policy: autosuspend ONLY while the interface is administratively
 * DOWN (closed). runtime_idle vetoes (-EBUSY) whenever the interface is up, so
 * the suspend/resume callbacks only ever run on a closed device — they need no
 * RTNL and touch no rings (the close already quiesced the hardware); the PCI
 * core handles the D-state + config save/restore. This deliberately forgoes the
 * (riskier) suspend-while-up-on-link-down optimisation in favour of a path with
 * no RTNL / ring-manipulation hazards.
 */
int r8125_bridge_runtime_idle(struct net_device *ndev)
{
	/* 0 = idle, let the core autosuspend; -EBUSY = keep active. */
	return netif_running(ndev) ? -EBUSY : 0;
}

void r8125_bridge_runtime_suspend(struct net_device *ndev)
{
	/* Closed device (idle vetoes while up): just hide it from the stack; the
	 * PCI core saves config + enters D3 (arming PME if wake is enabled).
	 */
	netif_device_detach(ndev);
}

void r8125_bridge_runtime_resume(struct net_device *ndev)
{
	/* The PCI core restored D0 + config; re-expose the (still closed) device.
	 * A subsequent ndo_open does the real bring-up. RTNL-free on purpose: this
	 * runs from the ndo_open get_sync bracket, which already holds RTNL.
	 */
	netif_device_attach(ndev);
}

/*
 * Enable runtime PM at probe end: flip the flag that activates the ndo open/stop
 * pm_runtime brackets, then drop the usage reference the PCI core took around
 * probe so the device can actually autosuspend once idle. Gated on
 * pci_dev_run_wake so we only allow autosuspend for a device that can wake from
 * D3 (PME) — mirrors r8169. Balanced by _disable at unbind.
 */
void r8125_bridge_pm_runtime_enable(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	b->runtime_pm = true;
	if (pci_dev_run_wake(b->pdev))
		pm_runtime_put_sync(&b->pdev->dev);
}

void r8125_bridge_pm_runtime_disable(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* Re-take the reference dropped in _enable so unbind/remove runs against a
	 * resumed, runtime-PM-quiescent device (balances the probe-end put). The
	 * PCI core has already pm_runtime_get_sync'd the device before remove.
	 */
	if (b->runtime_pm && pci_dev_run_wake(b->pdev))
		pm_runtime_get_noresume(&b->pdev->dev);
}

/*
 * PCIe AER error_detected teardown. Reached only via the r8125_pci_aer-gated Rust
 * error_detected callback. A non-fatal (Normal) channel keeps working and is left
 * untouched (the Rust side skips this call entirely). For a Frozen / unknown
 * channel, hide the device from the stack and, if it was up, do the same full
 * balanced stop as a normal close; the matching r8125_bridge_pm_error_resume
 * re-opens it. For a permanent failure, detach only: the AER core returns
 * Disconnect and may not call resume, so final teardown belongs to remove.
 *
 * RTNL-FREE on purpose: the AER core invokes error_detected from pci_walk_bus
 * while holding pci_bus_sem, and the runtime-PM D-state path takes pci_bus_sem
 * under RTNL — so taking RTNL here would create an ABBA cycle (caught by
 * lockdep). Mirrors igb's rtnl-free io_error_detected, which likewise calls its
 * down() path without RTNL; the AER recovery is serialised by the PCI core.
 */
void r8125_bridge_pm_error_detach(struct net_device *ndev, bool full_stop)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	netif_device_detach(ndev);
	/* Mark recoverable teardowns, not permanent-failure detach-only. This still
	 * covers the Frozen-while-interface-DOWN case (full_stop=true, but no
	 * bridge_ndo_stop) so error_resume re-attaches the closed device without a
	 * spurious reopen. It deliberately leaves permanent failure unmarked: the
	 * AER core returns Disconnect there, and remove owns final teardown.
	 */
	b->aer_torn_down = full_stop;
	if (full_stop && netif_running(ndev))
		bridge_ndo_stop(ndev);
}

/*
 * PCIe AER resume. Reached via the r8125_pci_aer-gated Rust resume callback,
 * which the core calls (under pci_bus_sem) for every recovered channel. Re-open
 * ONLY if error_detected actually tore the device down (Frozen path); for a
 * non-fatal channel there is nothing to restore. RTNL-free for the same reason
 * as the teardown. Returns 0 or a negative re-open errno.
 */
int r8125_bridge_pm_error_resume(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc = 0;

	if (b->aer_torn_down) {
		if (netif_running(ndev))
			rc = bridge_ndo_open(ndev);
		if (rc == 0)
			netif_device_attach(ndev);
		b->aer_torn_down = false;
	}
	return rc;
}

void r8125_bridge_carrier_on(struct net_device *ndev)
{
	netif_carrier_on(ndev);
}

void r8125_bridge_carrier_off(struct net_device *ndev)
{
	netif_carrier_off(ndev);
}

void r8125_bridge_tx_disable(struct net_device *ndev)
{
	netif_tx_disable(ndev);
}

/* ── sk_buff helpers + counter side-effects ────────────────────────── */

void r8125_bridge_skb_dma_unmap_tx(struct device *dev, dma_addr_t handle,
				   size_t len)
{
	dma_unmap_single(dev, handle, len, DMA_TO_DEVICE);
}

void r8125_bridge_skb_free_error(struct sk_buff *skb)
{
	struct net_device *ndev = skb->dev;
	struct r8125_bridge *b = ndev ? netdev_priv(ndev) : NULL;

	if (b)
		this_cpu_inc(*b->tx_dropped_error);
	dev_kfree_skb_any(skb);
}

void r8125_bridge_tx_busy_exception(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	this_cpu_inc(*b->tx_busy_exception);
}

/*
 * ndo_change_mtu support. With per-MTU zero-copy RX buffers, a change while
 * the interface is up must re-create the RX pool at the new size — a full
 * stop/open cycle. `r8125_bridge_netif_running` lets the Rust side decide
 * whether that cycle is needed.
 */
bool r8125_bridge_netif_running(struct net_device *ndev)
{
	return netif_running(ndev);
}

/*
 * Re-open the device at a new MTU, bracketing the Rust stop/open with the
 * same napi_disable/enable + netif_tx_disable discipline as
 * bridge_ndo_open / bridge_ndo_stop. Doing the napi lifecycle here (not in
 * Rust) keeps it in one place and avoids destroying the RX page_pool while
 * its NAPI is still active (the page_pool_disable_direct_recycling race
 * assertion). The new MTU is published before ops.open so the pool sizes to
 * it. Returns 0 or a negative errno from ops.open.
 */
int r8125_bridge_reopen_for_mtu(struct net_device *ndev, int new_mtu)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc;
	int old_mtu;

	if (unlikely(!ndev))
		return -EINVAL;

	old_mtu = ndev->mtu;
	if (old_mtu == new_mtu)
		return 0;

	netif_tx_disable(ndev);
	bridge_napi_disable_all(b);
	b->ops.stop(b->priv);

	WRITE_ONCE(ndev->mtu, new_mtu);
	bridge_napi_enable_all(b);
	rc = b->ops.open(b->priv, bridge_feature_flags(ndev->features));
	if (!rc)
		return 0;

	/* Roll back to previous MTU before returning failure so callers
	 * observe a stable state even if `ndo_change_mtu` rejects the
	 * requested value.
	 */
	WRITE_ONCE(ndev->mtu, old_mtu);
	bridge_napi_disable_all(b);
	return rc;
}

/* r8125_bridge_counters_snapshot lives in netdev_bridge_counters.c. */

MODULE_LICENSE("GPL v2");
