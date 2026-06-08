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
 * Hard cap: 540 LOC including comments. Candidate G/L/M additions and
 * the per-MTU zero-copy RX path fit after dead RX helpers moved out;
 * Queue-id plumbing keeps this TU at the cap while still bounded.
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
#include <linux/interrupt.h>
#include <linux/skbuff.h>
#include <linux/slab.h>
#include <asm/barrier.h>

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

static int bridge_ndo_open(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int rc;

	napi_enable(&b->rxq[0].napi);
	rc = b->ops.open(b->priv, bridge_feature_flags(ndev->features));
	if (rc) {
		napi_disable(&b->rxq[0].napi);
		return rc;
	}
	/* Rust open() performs the hardware bring-up and decides when the
	 * TX queue is ready. Carrier follows the PHY link-state callback.
	 */
	return 0;
}

static int bridge_ndo_stop(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	netif_tx_disable(ndev);
	napi_disable(&b->rxq[0].napi);
	b->ops.stop(b->priv);
	return 0;
}

static netdev_tx_t bridge_ndo_start_xmit(struct sk_buff *skb,
					 struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* All §6.3 counter side-effects happen inside the Rust path via
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

static const struct net_device_ops bridge_ops = {
	.ndo_open		= bridge_ndo_open,
	.ndo_stop		= bridge_ndo_stop,
	.ndo_start_xmit		= bridge_ndo_start_xmit,
	.ndo_change_mtu		= bridge_ndo_change_mtu,
	.ndo_fix_features	= bridge_ndo_fix_features,
	.ndo_set_features	= bridge_ndo_set_features,
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
	ndev->ethtool_ops = &r8125_bridge_ethtool_ops;
	ndev->needs_free_netdev = false; /* we free explicitly */
	eth_hw_addr_set(ndev, mac);

	/* M6 #2: jumbo support up to 9000 bytes. RX slot geometry now
	 * comes from per-MTU sizing in netdev_bridge_rx_pool.c, and `ndo_open`
	 * creates a new page_pool sized for the current MTU.
	 * We keep the 9000 MTU cap (industry-common) unless operators opt
	 * in to the chip's 16380 limit after validation.
	 */
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = 9000;

	/* Candidate G (RX_OPTIMIZATION_CANDIDATES.md §G): per-CPU
	 * netstats. With `NETDEV_PCPU_STAT_TSTATS` the kernel uses
	 * `dev_get_tstats64` to sum per-CPU rx_packets/rx_bytes/
	 * tx_packets/tx_bytes; the hot path calls
	 * `dev_sw_netstats_{rx,tx}_add` which is a single per-CPU
	 * INC + ADD instead of a shared-cache-line WRITE_ONCE pair.
	 * Same idiom r8169 uses (`r8169_main.c:5828`). Eliminates the
	 * `ndev->stats.{rx,tx}_packets` cache-line contention.
	 */
	ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS;

	/* Candidate M (RX_OPTIMIZATION_CANDIDATES.md §M): drop the
	 * default 1000-deep TX queue to 256. At 2.35 Gbps line rate a
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
	ndev->vlan_features = NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM |
			      NETIF_F_SG | NETIF_F_TSO | NETIF_F_TSO6;

	netif_set_tso_max_size(ndev, 64000);
	netif_set_tso_max_segs(ndev, 10);

	b = netdev_priv(ndev);
	b->ndev = ndev;
	b->pdev = pdev;
	b->priv = priv;
	b->ops = *ops;
	b->rxq[0].bridge = b;
	b->rxq[0].queue_id = 0;

	if (r8125_bridge_counters_alloc(b)) {
		free_netdev(ndev);
		return NULL;
	}

	netif_napi_add_weight(ndev, &b->rxq[0].napi, bridge_napi_poll,
			      BRIDGE_NAPI_WEIGHT);
	return ndev;
}

void r8125_bridge_free(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	netif_napi_del(&b->rxq[0].napi);
	r8125_bridge_counters_free(b);
	free_netdev(ndev);
}

int r8125_bridge_register(struct net_device *ndev)
{
	return register_netdev(ndev);
}

void r8125_bridge_unregister_and_free(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	/* Order: unregister_netdev synchronously runs ndo_stop (which calls
	 * phy_stop + phy_disconnect — severing the phy_device from the
	 * netdev). Only THEN is it safe to unregister the mdiobus, which
	 * removes the phy_device from the bus and frees it. mdiobus_free
	 * must happen before free_netdev because the bridge struct holds
	 * the mii_bus pointer.
	 */
	unregister_netdev(ndev);
	if (b->mii_bus) {
		mdiobus_unregister(b->mii_bus);
		mdiobus_free(b->mii_bus);
		b->mii_bus = NULL;
		b->phydev = NULL;
	}
	netif_napi_del(&b->rxq[0].napi);
	r8125_bridge_counters_free(b);
	free_netdev(ndev);
}

/*
 * `r8125_bridge_irq_pin_cpu` — Candidate L
 * (RX_OPTIMIZATION_CANDIDATES.md §L).
 *
 * Suggest to the kernel + `irqbalance` that this MSI-X vector
 * should be serviced on a specific CPU. Reduces tail latency from
 * softirq cross-CPU migration AND keeps the per-CPU NAPI page-frag
 * cache warm (helps Candidate B's `napi_alloc_skb` fast path).
 *
 * The kernel-internal hint can be overridden by an explicit
 * `/proc/irq/N/smp_affinity` write or by `irqbalance` if it
 * deliberately ignores hints — both are operator choices we
 * respect. We just provide a sensible default.
 *
 * `irq_set_affinity_and_hint` returns 0 on success; on failure we
 * log and proceed (no fatal). The hint is automatically cleared by
 * the kernel when `free_irq` runs.
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
 * `r8125_bridge_irq_pin_auto` — Candidate #4 of
 * `docs/RX_OPTIMIZATION_CANDIDATES.md`.
 *
 * Pick the first online CPU on the PCI device's NUMA node and pin the
 * vector there. On boxes where the chip's IOMMU/root-complex hangs off
 * a specific NUMA node, servicing the IRQ on a CPU in the same node
 * keeps the RX-completion data on the right side of the inter-socket
 * link. On UMA boxes (most desktops, the MS-A2) every CPU is "local"
 * so this collapses to "pick the lowest-numbered online CPU." Both
 * cases are better than the previous hardcoded CPU 0 default.
 *
 * Output via `out_cpu` so the Rust side can log which CPU was chosen.
 * On failure (no online CPU on the node), returns -EINVAL and leaves
 * *out_cpu unchanged.
 */
int r8125_bridge_irq_pin_auto(struct pci_dev *pdev, unsigned int irq,
			      int *out_cpu)
{
	int node = dev_to_node(&pdev->dev);
	const struct cpumask *node_mask;
	int cpu;

	if (node == NUMA_NO_NODE) {
		/* Box doesn't know its NUMA topology; just pick CPU 0
		 * if it's online, else the first online CPU.
		 */
		cpu = cpumask_first(cpu_online_mask);
	} else {
		node_mask = cpumask_of_node(node);
		cpu = cpumask_first_and(node_mask, cpu_online_mask);
	}
	if (cpu >= nr_cpu_ids)
		return -EINVAL;
	if (out_cpu)
		*out_cpu = cpu;
	return irq_set_affinity_and_hint(irq, cpumask_of(cpu));
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

/* ── sk_buff helpers + counter side-effects (§6.3) ─────────────────── */

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
	napi_disable(&b->rxq[0].napi);
	b->ops.stop(b->priv);

	WRITE_ONCE(ndev->mtu, new_mtu);
	napi_enable(&b->rxq[0].napi);
	rc = b->ops.open(b->priv, bridge_feature_flags(ndev->features));
	if (!rc)
		return 0;

	/* Roll back to previous MTU before returning failure so callers
	 * observe a stable state even if `ndo_change_mtu` rejects the
	 * requested value.
	 */
	WRITE_ONCE(ndev->mtu, old_mtu);
	napi_disable(&b->rxq[0].napi);
	return rc;
}

/* r8125_bridge_counters_snapshot lives in netdev_bridge_counters.c. */

MODULE_LICENSE("GPL v2");
