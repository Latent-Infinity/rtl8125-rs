/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _R8125_NETDEV_BRIDGE_INTERNAL_H
#define _R8125_NETDEV_BRIDGE_INTERNAL_H

#include "netdev_bridge.h"

#include <linux/atomic.h>
#include <linux/mdio.h>
#include <linux/mii.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/percpu.h>
#include <linux/phy.h>
#include <linux/workqueue.h>

/* §6.3 disposition counters live in per-CPU storage so the hot-path
 * `this_cpu_inc()` is a single decorated INC instruction with no cache-
 * line bouncing between TX context (xmit / process) and reaper context
 * (NAPI / softirq). See RUST_STANDARDS.md §15.2 and docs/M4_CLOSEOUT.md.
 * `r8125_bridge_counters_snapshot` sums across CPUs for the userspace
 * `ethtool -S` surface.
 */
struct page_pool;	/* zero-copy RX buffer owner (netdev_bridge_rx_pool.c) */

/* Compile-time maximum RX queues = NAPI instances + per-queue state allocated.
 * RTL8125B HwSuppNumRxQueues is 4. The RUNTIME active count lives in
 * `r8125_bridge.active_rx_queues` (1 unless rss_queues opts in); ethtool reports
 * that, while all MAX NAPI instances are created/enabled (idle ones never get
 * scheduled). Must match Rust `netdev::RX_QUEUE_COUNT`.
 */
#define R8125_BRIDGE_RX_QUEUE_COUNT	4

struct r8125_bridge_rx_queue {
	struct r8125_bridge *bridge;
	struct napi_struct napi;
	unsigned int queue_id;

	/* Zero-copy RX (netdev_bridge_rx_pool.c). The pool owns every RX
	 * buffer; the geometry below is computed once per ndo_open from
	 * dev->mtu and cached so the hot path reads it without recomputing.
	 * page_pool is NULL while the queue is down.
	 */
	struct page_pool *page_pool;
	unsigned int rx_headroom;	/* reserved in front of each frame */
	unsigned int rx_offset;		/* device DMA offset into the page  */
	unsigned int rx_max_len;		/* device-writable bytes per buffer */
	unsigned int rx_order;		/* page allocation order            */
	size_t rx_buf_total;		/* PAGE_SIZE << rx_order            */
};

struct r8125_bridge {
	struct net_device *ndev;
	struct pci_dev *pdev;
	struct r8125_bridge_rx_queue rxq[R8125_BRIDGE_RX_QUEUE_COUNT];
	/* RX queues actually active this open (1..RX_QUEUE_COUNT). Reported by
	 * ethtool get_channels / get_rx_ring_count. Defaults to 1; the Rust side
	 * updates it when an rss_queues opt-in activates more (B6.3).
	 */
	unsigned int active_rx_queues;
	void *priv;
	struct r8125_bridge_ops ops;

	struct mii_bus *mii_bus;
	struct phy_device *phydev;
	struct r8125_bridge_mdio_ops mdio_ops;
	bool phy_connected;

	/* ndo_tx_timeout runs in the netdev-watchdog timer (atomic) context, so
	 * the actual chip reset (stop+open, which sleeps) is deferred to this work
	 * item and run under RTNL. Mirrors r8169/vendor reset_work.
	 */
	struct work_struct reset_work;

	/* Coherent buffer for the hardware tally-counter dump (ndo_get_stats64).
	 * Allocated once at probe, reused per stats call, freed at teardown.
	 * tally_vaddr is NULL if the allocation failed (tally stats then skipped).
	 */
	struct r8125_tally *tally_vaddr;
	dma_addr_t tally_dma;

	u64 __percpu *tx_received;
	u64 __percpu *tx_consumed;
	u64 __percpu *tx_busy_exception;
	u64 __percpu *tx_dropped_error;
	u64 __percpu *rx_handed_to_stack;
	u64 __percpu *rx_dropped_error;
	u64 __percpu *rx_hash_l3;
	u64 __percpu *rx_hash_l4;
	u64 __percpu *rx_hash_missing;
	u64 __percpu *rx_hash_disabled;

};

/* ethtool ops table; defined in netdev_bridge_ethtool.c. Exposes the
 * §6.3 counters via `ethtool -S` so the runtime invariant check
 * (`ci/check_counter_invariant.sh`) can read them from userspace.
 */
extern const struct ethtool_ops r8125_bridge_ethtool_ops;

/* §6.3 percpu counter lifecycle helpers, defined in
 * netdev_bridge_counters.c. Called from r8125_bridge_alloc /
 * r8125_bridge_{free,unregister_and_free} only; never on a hot path.
 */
int  r8125_bridge_counters_alloc(struct r8125_bridge *b);
void r8125_bridge_counters_free(struct r8125_bridge *b);

#endif /* _R8125_NETDEV_BRIDGE_INTERNAL_H */
