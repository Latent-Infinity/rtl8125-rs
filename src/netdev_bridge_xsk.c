// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_xsk.c — AF_XDP zero-copy RX datapath for the r8125_rust driver.
 *
 * When an AF_XDP umem pool is bound to an RX queue (XDP_SETUP_XSK_POOL, wired in
 * netdev_bridge.c::r8125_bridge_xsk_pool_setup), that queue allocates RX buffers
 * from the xsk_buff_pool instead of the page_pool and its xdp_rxq uses the
 * MEM_TYPE_XSK_BUFF_POOL memory model, so an XDP_REDIRECT to the bound socket is
 * zero-copy. The page_pool RX path in netdev_bridge_rx_pool.c delegates here via
 * an `if (q->xsk_pool)` branch; the non-ZC path is unchanged. The slot "cpu"
 * stored by Rust is the `struct xdp_buff *` for a ZC queue (opaque to Rust).
 *
 * Hard cap: 280 LOC. Enforced by ci/check_cshim_loc_caps.sh. Raised from 200 for
 * the zero-copy TX drain + completion + need-wakeup management; the file still
 * owns exactly one concern (the AF_XDP datapath).
 */
#include "netdev_bridge_internal.h"

#include <linux/bpf.h>
#include <linux/bpf_trace.h>
#include <linux/filter.h>
#include <net/xdp.h>
#include <net/xdp_sock_drv.h>

/*
 * Register the per-queue xdp_rxq against the xsk pool's memory model. Called from
 * rx_pool_create for a ZC queue (instead of the page_pool registration).
 */
int r8125_bridge_xsk_rxq_reg(struct net_device *ndev, unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q = &b->rxq[queue_id];
	int rc;

	rc = xdp_rxq_info_reg(&q->xdp_rxq, ndev, queue_id, q->napi.napi_id);
	if (rc)
		return rc;
	xsk_pool_set_rxq_info(q->xsk_pool, &q->xdp_rxq);
	rc = xdp_rxq_info_reg_mem_model(&q->xdp_rxq, MEM_TYPE_XSK_BUFF_POOL,
				       q->xsk_pool);
	if (rc) {
		xdp_rxq_info_unreg(&q->xdp_rxq);
		return rc;
	}
	q->xdp_rxq_registered = true;
	/* Clamp the device-writable length to the umem frame size so the chip
	 * cannot DMA past a single umem chunk (0x3FFF = the 14-bit descriptor LEN
	 * ceiling, matching R8125_RX_DESC_MAX in netdev_bridge_rx_pool.c).
	 */
	q->rx_max_len = min_t(unsigned int,
			      xsk_pool_get_rx_frame_size(q->xsk_pool), 0x3FFFu);
	return 0;
}

/*
 * Allocate one RX buffer from the xsk pool. Stores the xdp_buff pointer as the
 * slot "cpu" (the Rust ring side treats it opaquely) and its umem DMA address as
 * the descriptor addr. Returns -ENOMEM when the fill ring is empty.
 */
int r8125_bridge_xsk_rx_alloc(struct net_device *ndev, unsigned int queue_id,
			      void **out_cpu, dma_addr_t *out_dma)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q = &b->rxq[queue_id];
	struct xdp_buff *xdp = xsk_buff_alloc(q->xsk_pool);

	if (!xdp)
		return -ENOMEM;
	*out_cpu = xdp;
	*out_dma = xsk_buff_xdp_get_dma(xdp);
	return 0;
}

/* Return one ZC slot's buffer to the xsk pool (teardown / rollback). */
void r8125_bridge_xsk_rx_free(struct net_device *ndev, unsigned int queue_id,
			      void *cpu)
{
	(void)ndev;
	(void)queue_id;
	if (cpu)
		xsk_buff_free((struct xdp_buff *)cpu);
}

/*
 * ZC RX consume. `cpu` is the received slot's xdp_buff; `len` the frame length.
 * Runs the XDP verdict and ALWAYS disposes the buffer: XDP_REDIRECT hands the
 * umem chunk to the bound socket (zero-copy); XDP_PASS / no-program copies into a
 * normal skb (the umem belongs to the socket) and frees the chunk; DROP/ABORTED
 * free it. The slot is empty afterwards — the Rust producer/consumer poll refills
 * it separately from the umem fill ring (r8125_bridge_xsk_rx_alloc). Consume-only
 * (no inline refill) because, unlike the page_pool path, an empty fill ring is
 * the normal cold-start state and the ring is topped up by the poll / xsk_wakeup.
 */
void r8125_bridge_xsk_rx_consume(struct net_device *ndev, unsigned int queue_id,
				 void *cpu, size_t len)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q = &b->rxq[queue_id];
	struct xdp_buff *xdp = cpu;
	struct bpf_prog *prog;
	struct sk_buff *skb;
	bool to_stack = true;

	xsk_buff_set_size(xdp, len);
	xsk_buff_dma_sync_for_cpu(xdp);

	prog = rcu_dereference_bh(b->xdp_prog);
	if (prog) {
		u32 act = bpf_prog_run_xdp(prog, xdp);

		switch (act) {
		case XDP_PASS:
			break;
		case XDP_REDIRECT:
			to_stack = false;
			if (xdp_do_redirect(ndev, xdp, prog) == 0)
				q->xdp_redirect_pending = true;
			else
				xsk_buff_free(xdp);
			break;
		default:
			bpf_warn_invalid_xdp_action(ndev, prog, act);
			fallthrough;
		case XDP_ABORTED:
			trace_xdp_exception(ndev, prog, act);
			fallthrough;
		case XDP_DROP:
			to_stack = false;
			xsk_buff_free(xdp);
			break;
		}
	}

	if (to_stack) {
		/* XDP_PASS / no program: copy the umem data into a normal skb (the
		 * umem belongs to the socket) and free the chunk back to the pool.
		 */
		skb = napi_alloc_skb(&q->napi, len);
		if (likely(skb)) {
			memcpy(__skb_put(skb, len), xdp->data, len);
			skb->protocol = eth_type_trans(skb, ndev);
			this_cpu_inc(*b->rx_handed_to_stack);
			dev_sw_netstats_rx_add(ndev, len);
			q->rx_packets++;
			q->rx_bytes += len;
			napi_gro_receive(&q->napi, skb);
		} else {
			this_cpu_inc(*b->rx_dropped_error);
		}
		xsk_buff_free(xdp);
	}
}

/*
 * ndo_xsk_wakeup: kick the queue's NAPI so the poll refills the RX fill ring
 * (and, once ZC TX lands, drains the xsk TX ring). Driven by the userspace
 * AF_XDP application when it needs the driver to make progress.
 */
int r8125_bridge_xsk_wakeup(struct net_device *ndev, unsigned int queue_id,
			    u32 flags)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q;

	if (!netif_running(ndev) || !netif_carrier_ok(ndev))
		return -ENETDOWN;
	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT)
		return -EINVAL;
	q = &b->rxq[queue_id];
	if (!q->xsk_pool)
		return -EINVAL;
	/* Cold-start bootstrap: with an empty RX ring the chip takes no RX IRQ, so
	 * scheduling NAPI alone never runs the poll. Post umem buffers synchronously
	 * first (serialised against the poll on the Rust side), THEN schedule NAPI to
	 * drain anything already received and to service the TX side.
	 */
	if (flags & XDP_WAKEUP_RX)
		b->ops.xsk_kick(b->priv, queue_id);
	if (!napi_if_scheduled_mark_missed(&q->napi))
		napi_schedule(&q->napi);
	return 0;
}

/*
 * AF_XDP zero-copy TX drain (NAPI poll). Pull up to `budget` descriptors from the
 * bound socket's TX ring, resolve each umem chunk's persistent DMA address, sync
 * it for the device, and enqueue it on the shared TX ring via the Rust producer
 * (tagged so the reaper completes it back to this queue's pool). `budget` is
 * bounded by the caller to the free TX-ring slots, so the producer never returns
 * -ENOSPC within the loop. Rings the doorbell once and commits the consumed xsk
 * TX-ring slots. Returns the number enqueued. Manages TX need-wakeup so a poll
 * that empties the xsk TX ring asks userspace to kick it next time.
 */
int r8125_bridge_xsk_tx(struct net_device *ndev, unsigned int queue_id, int budget)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q;
	struct xsk_buff_pool *pool;
	struct netdev_queue *txq = netdev_get_tx_queue(ndev, 0);
	struct xdp_desc desc;
	int sent = 0;
	bool drained;

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT || budget <= 0)
		return 0;
	q = &b->rxq[queue_id];
	pool = q->xsk_pool;
	if (!pool)
		return 0;

	__netif_tx_lock(txq, raw_smp_processor_id());
	while (sent < budget && xsk_tx_peek_desc(pool, &desc)) {
		dma_addr_t dma = xsk_buff_raw_get_dma(pool, desc.addr);

		xsk_buff_raw_dma_sync_for_device(pool, dma, desc.len);
		if (b->ops.xsk_xmit_one(b->priv, dma, desc.len, queue_id))
			break;	/* ring full despite the bound budget (xmit race) */
		sent++;
	}
	drained = (sent < budget);	/* xsk TX ring emptied before budget */
	if (sent) {
		xsk_tx_release(pool);
		b->ops.xdp_tx_flush(b->priv);	/* one TX doorbell for the batch */
	}
	__netif_tx_unlock(txq);

	if (xsk_uses_need_wakeup(pool)) {
		if (drained)
			xsk_set_tx_need_wakeup(pool);
		else
			xsk_clear_tx_need_wakeup(pool);
	}
	return sent;
}

/*
 * Complete `count` zero-copy TX chunks back to the bound socket's completion
 * ring. Called from the Rust TX reaper when it reaps XskTx-tagged slots for this
 * queue (batched per queue_id within one reap pass).
 */
void r8125_bridge_xsk_tx_completed(struct net_device *ndev, unsigned int queue_id,
				   u32 count)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct xsk_buff_pool *pool;

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT || !count)
		return;
	pool = b->rxq[queue_id].xsk_pool;
	if (pool)
		xsk_tx_completed(pool, count);
}

/*
 * Set or clear RX need-wakeup on the bound pool. The Rust refill path calls this
 * with need=true when the umem fill ring is exhausted (so userspace kicks the
 * driver via ndo_xsk_wakeup after replenishing it) and need=false once it has
 * posted buffers again. No-op unless the pool runs in need-wakeup mode.
 */
void r8125_bridge_xsk_set_rx_wakeup(struct net_device *ndev, unsigned int queue_id,
				    bool need)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct xsk_buff_pool *pool;

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT)
		return;
	pool = b->rxq[queue_id].xsk_pool;
	if (!pool || !xsk_uses_need_wakeup(pool))
		return;
	if (need)
		xsk_set_rx_need_wakeup(pool);
	else
		xsk_clear_rx_need_wakeup(pool);
}
