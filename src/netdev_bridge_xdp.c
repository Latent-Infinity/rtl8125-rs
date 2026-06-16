// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_xdp.c — XDP datapath glue for the r8125_rust driver.
 *
 * The kernel XDP/BPF APIs (bpf_prog_run_xdp, struct xdp_buff, xdp_do_redirect,
 * xdp_rxq_info_*) are C-only with no stable Rust binding, so the XDP verdict and
 * the xdp_rxq lifecycle live here. The RX hot loop stays in Rust; the per-packet
 * verdict is computed in r8125_bridge_xdp_run, called from rx_one_packet
 * (netdev_bridge_rx_pool.c) before the skb build. The no-program fast path is a
 * single predicted-not-taken branch (one READ_ONCE of the program pointer).
 *
 * RX read-path actions: XDP_PASS / XDP_DROP / XDP_ABORTED / XDP_REDIRECT.
 * XDP_TX converts the buffer to an xdp_frame and enqueues it on the Rust-owned
 * TX ring (ops.xdp_xmit_one) under the txq lock; the reaper returns the frame
 * via xdp_return_frame at completion. xdp_features is advertised as
 * BASIC | REDIRECT in netdev_bridge.c once this path is in place.
 *
 * Hard cap: 240 LOC. Enforced by ci/check_cshim_loc_caps.sh.
 */
#include "netdev_bridge_internal.h"

#include <linux/bpf.h>
#include <linux/bpf_trace.h>
#include <linux/dma-mapping.h>
#include <linux/filter.h>
#include <linux/rtnetlink.h>
#include <net/page_pool/helpers.h>
#include <net/xdp.h>

/*
 * XDP_TX one frame: convert the run buffer to an xdp_frame, DMA-map its data
 * TO_DEVICE, and enqueue on the Rust TX ring under the txq lock (the only thing
 * serialising this NAPI-context producer against ndo_start_xmit). On any failure
 * the frame/page is returned and the caller still refills the RX slot. Returns
 * true if the frame was enqueued (caller sets xdp_tx_pending for the doorbell).
 */
static bool r8125_bridge_xdp_tx_one(struct net_device *ndev,
				    struct r8125_bridge *b, struct xdp_buff *xdp)
{
	struct device *dev = &b->pdev->dev;
	struct xdp_frame *frame;
	struct netdev_queue *txq;
	dma_addr_t dma;
	int rc;

	frame = xdp_convert_buff_to_frame(xdp);
	if (unlikely(!frame))
		return false;
	dma = dma_map_single(dev, frame->data, frame->len, DMA_TO_DEVICE);
	if (unlikely(dma_mapping_error(dev, dma))) {
		xdp_return_frame(frame);
		return false;
	}
	txq = netdev_get_tx_queue(ndev, 0);
	__netif_tx_lock(txq, raw_smp_processor_id());
	rc = b->ops.xdp_xmit_one(b->priv, dma, frame->len, frame);
	__netif_tx_unlock(txq);
	if (rc) {
		dma_unmap_single(dev, dma, frame->len, DMA_TO_DEVICE);
		xdp_return_frame(frame);
		return false;
	}
	return true;
}

/* Reaper-side disposition for an XDP_TX frame (called from the Rust TX reaper
 * via the unsafe boundary). Returns the frame's page to its origin page_pool
 * through the frame's captured mem model.
 */
void r8125_bridge_xdp_return_frame(void *frame)
{
	xdp_return_frame((struct xdp_frame *)frame);
}

/*
 * Run the attached XDP program on one received frame.
 *   buf  — page virtual address; the frame is at buf + *off, length *len.
 *   off  — in/out headroom offset to the frame start (XDP_PASS may move it).
 *   len  — in/out frame length (XDP_PASS may adjust it).
 * Returns 0 (XDP_PASS: caller builds the skb with the updated off and len), or 1
 * (CONSUMED: the program dropped/redirected the frame and the old page has
 * already been recycled to the pool / handed to the redirect core, so the caller
 * must NOT build an skb but still refills the slot). No program -> 0 (PASS).
 */
int r8125_bridge_xdp_run(struct net_device *ndev,
			 struct r8125_bridge_rx_queue *q, void *buf,
			 unsigned int *off, unsigned int *len)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct bpf_prog *prog = rcu_dereference_bh(b->xdp_prog);
	struct xdp_buff xdp;
	u32 act;

	if (likely(!prog))
		return 0;

	xdp_init_buff(&xdp, q->rx_buf_total, &q->xdp_rxq);
	xdp_prepare_buff(&xdp, buf, *off, *len, true);

	act = bpf_prog_run_xdp(prog, &xdp);

	switch (act) {
	case XDP_PASS:
		/* The program may have moved data (bpf_xdp_adjust_head/tail). */
		*off = xdp.data - xdp.data_hard_start;
		*len = xdp.data_end - xdp.data;
		return 0;
	case XDP_REDIRECT:
		if (xdp_do_redirect(ndev, &xdp, prog) == 0) {
			q->xdp_redirect_pending = true;
			return 1;
		}
		fallthrough;	/* redirect failed -> drop */
	case XDP_DROP:
		page_pool_put_page(q->page_pool, virt_to_head_page(buf), *len,
				   true);
		return 1;
	case XDP_TX:
		/* On enqueue the page now belongs to the xdp_frame and is
		 * returned by the TX reaper; on failure xdp_tx_one already
		 * returned it. Either way the caller refills the RX slot.
		 */
		if (r8125_bridge_xdp_tx_one(ndev, b, &xdp))
			q->xdp_tx_pending = true;
		return 1;
	default:
		bpf_warn_invalid_xdp_action(ndev, prog, act);
		fallthrough;
	case XDP_ABORTED:
		trace_xdp_exception(ndev, prog, act);
		page_pool_put_page(q->page_pool, virt_to_head_page(buf), *len,
				   true);
		return 1;
	}
}

/* Flush the redirect bulk queue once at NAPI-poll end if any frame redirected. */
void r8125_bridge_xdp_finalize(struct net_device *ndev, unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q;

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT)
		return;
	q = &b->rxq[queue_id];
	if (q->xdp_redirect_pending) {
		q->xdp_redirect_pending = false;
		xdp_do_flush();
	}
	if (q->xdp_tx_pending) {
		q->xdp_tx_pending = false;
		b->ops.xdp_tx_flush(b->priv);
	}
}

/*
 * Register the per-queue xdp_rxq with the page_pool memory model. Called from
 * rx_pool_create once the pool exists; unregistered in rx_pool_destroy.
 */
int r8125_bridge_xdp_rxq_reg(struct net_device *ndev, unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q;
	int rc;

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT)
		return -EINVAL;
	q = &b->rxq[queue_id];
	rc = xdp_rxq_info_reg(&q->xdp_rxq, ndev, queue_id, q->napi.napi_id);
	if (rc)
		return rc;
	rc = xdp_rxq_info_reg_mem_model(&q->xdp_rxq, MEM_TYPE_PAGE_POOL,
					q->page_pool);
	if (rc) {
		xdp_rxq_info_unreg(&q->xdp_rxq);
		return rc;
	}
	q->xdp_rxq_registered = true;
	return 0;
}

void r8125_bridge_xdp_rxq_unreg(struct net_device *ndev, unsigned int queue_id)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_rx_queue *q;

	if (queue_id >= R8125_BRIDGE_RX_QUEUE_COUNT)
		return;
	q = &b->rxq[queue_id];
	if (q->xdp_rxq_registered) {
		xdp_rxq_info_unreg(&q->xdp_rxq);
		q->xdp_rxq_registered = false;
	}
}

/*
 * ndo_bpf XDP_SETUP_PROG: attach/detach a single device-wide program. The frame
 * always fits one (per-MTU sized) RX buffer, so single-buffer XDP works at any
 * MTU. ndo_bpf runs under RTNL; the RX hot path runs in NAPI/BH context and
 * reads with rcu_dereference_bh(). bpf_prog_put on the replaced program is
 * RCU-deferred, so a concurrent NAPI reader cannot use a freed program.
 */
static int r8125_bridge_xdp_setup(struct net_device *ndev, struct bpf_prog *prog)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct bpf_prog *old;

	old = rcu_replace_pointer_rtnl(b->xdp_prog, prog);
	if (old)
		bpf_prog_put(old);
	return 0;
}

int r8125_bridge_ndo_bpf(struct net_device *ndev, struct netdev_bpf *bpf)
{
	switch (bpf->command) {
	case XDP_SETUP_PROG:
		return r8125_bridge_xdp_setup(ndev, bpf->prog);
	default:
		return -EOPNOTSUPP;
	}
}
