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
#include <net/xdp.h>

/* The disposition counters live in per-CPU storage so the hot-path
 * `this_cpu_inc()` is a single decorated INC instruction with no cache-
 * line bouncing between TX context (xmit / process) and reaper context
 * (NAPI / softirq). `r8125_bridge_counters_snapshot` sums across CPUs for
 * the userspace `ethtool -S` surface.
 */
struct page_pool;	/* zero-copy RX buffer owner (netdev_bridge_rx_pool.c) */
struct xsk_buff_pool;	/* AF_XDP umem pool (netdev_bridge_xsk.c) */
struct xdp_buff;

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

	/* Per-queue RX stats for netdev_stat_ops (netdev-genl per-queue stats).
	 * Single-writer (this queue's NAPI); read via READ_ONCE. Incremented next
	 * to dev_sw_netstats_rx_add so the per-queue sum matches the device total.
	 */
	u64 rx_packets;
	u64 rx_bytes;

	/* XDP (netdev_bridge_xdp.c). xdp_rxq is registered with the page_pool
	 * memory model while the queue is up. xdp_redirect_pending is set by an
	 * XDP_REDIRECT during the poll and drives a single xdp_do_flush at poll
	 * end. The attached program is a single device-wide RCU pointer in
	 * struct r8125_bridge (xdp_prog), read with rcu_dereference_bh() in the
	 * NAPI hot path and replaced under RTNL by ndo_bpf.
	 */
	struct xdp_rxq_info xdp_rxq;
	bool xdp_rxq_registered;
	bool xdp_redirect_pending;

	/* AF_XDP zero-copy (netdev_bridge_xsk.c). When an xsk umem pool is bound to
	 * this queue, xsk_pool is non-NULL and the RX alloc/refill/completion path
	 * uses xsk_buff_* instead of the page_pool (the page_pool is not created for
	 * a ZC queue). NULL = normal page_pool RX. Bound/unbound only under RTNL via
	 * XDP_SETUP_XSK_POOL, which reconfigures the queue (stop+open).
	 */
	struct xsk_buff_pool *xsk_pool;
	/* Set by an XDP_TX verdict during the poll; drives a single TX doorbell
	 * (ops.xdp_tx_flush) at poll end so the posted XDP_TX descriptors are
	 * signalled to hardware exactly once per poll.
	 */
	bool xdp_tx_pending;
};

struct r8125_bridge {
	struct net_device *ndev;
	struct pci_dev *pdev;
	struct r8125_bridge_rx_queue rxq[R8125_BRIDGE_RX_QUEUE_COUNT];
	/* RX queues actually active this open (1..RX_QUEUE_COUNT). Reported by
	 * ethtool get_channels / get_rx_ring_count. Defaults to 1; the Rust side
	 * updates it when an rss_queues opt-in activates more.
	 */
	unsigned int active_rx_queues;
	void *priv;
	struct r8125_bridge_ops ops;

	struct mii_bus *mii_bus;
	struct phy_device *phydev;
	struct r8125_bridge_mdio_ops mdio_ops;
	bool phy_connected;

	/* ethtool -s msglvl: netif_msg_* bitmask. Reported by get_msglevel,
	 * updated by set_msglevel. Same model as r8169's tp->msg_enable.
	 */
	u32 msg_enable;

	/* Set by the PM suspend callback when it took the WoL keep-alive path (a
	 * light quiesce that leaves the PHY powered + the rings/IRQ intact, instead
	 * of a full stop). The resume callback uses it to do a full stop+reopen
	 * cycle (the chip was reset in D3) rather than the plain reopen. Touched
	 * only under RTNL in the PM callbacks.
	 */
	bool wol_suspended;

	/* PHY MCU firmware version string (from rtl8125b-2.fw), set by Rust after
	 * a successful firmware apply; reported via ethtool -i. NUL-terminated
	 * (33rd byte always 0). Empty if no firmware was loaded.
	 */
	char fw_version[33];

	/* Attached XDP program (NULL = none), device-wide. Replaced under RTNL in
	 * ndo_bpf with rcu_replace_pointer_rtnl(); the NAPI hot path dereferences
	 * it with rcu_dereference_bh(). One ref is held here; bpf_prog_put on the
	 * replaced program is RCU-deferred so the NAPI reader cannot use a freed
	 * program.
	 */
	struct bpf_prog __rcu *xdp_prog;

	/* Per-queue (single TX queue) TX stats for netdev_stat_ops. Single-writer
	 * (the TX-completion NAPI); read via READ_ONCE. Incremented next to
	 * dev_sw_netstats_tx_add so the per-queue value matches the device total.
	 */
	u64 tx_packets;
	u64 tx_bytes;

	/* ndo_tx_timeout runs in the netdev-watchdog timer (atomic) context, so
	 * the actual chip reset (stop+open, which sleeps) is deferred to this work
	 * item and run under RTNL. Mirrors r8169/vendor reset_work.
	 */
	struct work_struct reset_work;

	/* LED class devices for the chip's PHY LEDs (netdev_bridge_leds.c). Opaque
	 * array allocated at register, unregistered + freed at teardown; NULL if LED
	 * init failed (best-effort, like mainline). See r8125_bridge_init_leds.
	 */
	void *leds;

	/* devlink instance + TX health reporter (netdev_bridge_devlink.c). Opaque
	 * handle allocated at register, freed at teardown; NULL if devlink init
	 * failed (best-effort — the driver then uses the direct-reopen recovery).
	 */
	void *devlink;

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
 * disposition counters via `ethtool -S` so the runtime invariant check
 * (`ci/check_counter_invariant.sh`) can read them from userspace.
 */
extern const struct ethtool_ops r8125_bridge_ethtool_ops;

/* The percpu counter lifecycle helpers, defined in
 * netdev_bridge_counters.c. Called from r8125_bridge_alloc /
 * r8125_bridge_{free,unregister_and_free} only; never on a hot path.
 */
int  r8125_bridge_counters_alloc(struct r8125_bridge *b);
void r8125_bridge_counters_free(struct r8125_bridge *b);

/* PHY LED netdev-trigger offload (netdev_bridge_leds.c). init registers the LED
 * class devices (best-effort, returns NULL on failure); remove unregisters +
 * frees them. The opaque pointer is stored in r8125_bridge.leds.
 */
void *r8125_bridge_init_leds(struct net_device *ndev);
void r8125_bridge_remove_leds(void *leds);

/* devlink instance + TX health reporter (netdev_bridge_devlink.c). init allocs +
 * registers (best-effort, NULL on failure); remove tears down; report_tx_timeout
 * records a TX-watchdog error and auto-recovers via the reporter (chip reopen).
 */
void *r8125_bridge_devlink_init(struct net_device *ndev);
void r8125_bridge_devlink_remove(void *cookie);
void r8125_bridge_devlink_report_tx_timeout(void *cookie);

/* AF_XDP zero-copy (netdev_bridge_xsk.c). xsk_pool_setup binds/unbinds an xsk
 * umem pool to a queue (XDP_SETUP_XSK_POOL); the rest are the ZC datapath the
 * page_pool RX path delegates to when q->xsk_pool is set, plus ndo_xsk_wakeup.
 */
int  r8125_bridge_xsk_pool_setup(struct net_device *ndev,
				 struct xsk_buff_pool *pool, unsigned int queue_id);
bool r8125_bridge_rxq_is_zc(struct net_device *ndev, unsigned int queue_id);
int  r8125_bridge_xsk_wakeup(struct net_device *ndev, unsigned int queue_id,
			     u32 flags);
int  r8125_bridge_xsk_rxq_reg(struct net_device *ndev, unsigned int queue_id);
int  r8125_bridge_xsk_rx_alloc(struct net_device *ndev, unsigned int queue_id,
			       void **out_cpu, dma_addr_t *out_dma);
void r8125_bridge_xsk_rx_free(struct net_device *ndev, unsigned int queue_id,
			      void *cpu);
void r8125_bridge_xsk_rx_consume(struct net_device *ndev, unsigned int queue_id,
				 void *cpu, size_t len);
int  r8125_bridge_xsk_tx(struct net_device *ndev, unsigned int queue_id,
			 int budget);
void r8125_bridge_xsk_tx_completed(struct net_device *ndev, unsigned int queue_id,
				   u32 count);
void r8125_bridge_xsk_set_rx_wakeup(struct net_device *ndev, unsigned int queue_id,
				    bool need);

/* XDP datapath glue (netdev_bridge_xdp.c). xdp_run is the per-packet verdict
 * called from rx_one_packet; the rest manage the xdp_rxq lifecycle, the
 * end-of-poll redirect flush, and ndo_bpf attach/detach.
 */
int  r8125_bridge_xdp_run(struct net_device *ndev,
			  struct r8125_bridge_rx_queue *q, void *buf,
			  unsigned int *off, unsigned int *len);
void r8125_bridge_xdp_finalize(struct net_device *ndev, unsigned int queue_id);
int  r8125_bridge_xdp_rxq_reg(struct net_device *ndev, unsigned int queue_id);
void r8125_bridge_xdp_rxq_unreg(struct net_device *ndev, unsigned int queue_id);
int  r8125_bridge_ndo_bpf(struct net_device *ndev, struct netdev_bpf *bpf);
int  r8125_bridge_ndo_xdp_xmit(struct net_device *ndev, int n,
			       struct xdp_frame **frames, u32 flags);
/* Called from the Rust TX reaper (via the unsafe boundary) to return an
 * XDP_TX frame's page to its origin page_pool at TX completion.
 */
void r8125_bridge_xdp_return_frame(void *frame);

#endif /* _R8125_NETDEV_BRIDGE_INTERNAL_H */
