// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_rx_pool.c — zero-copy RX via page_pool + per-MTU buffer
 *                          sizing for the r8125_rust path (M6 sub-feature
 *                          #2; RX optimization Candidates B + #3).
 *
 * History / why this shape:
 *
 *   v1 used one big `CoherentAllocation` for 256 slots (512 KiB
 *   contiguous) — didn't scale to jumbo.
 *   v2 switched to per-slot `alloc_pages` + `dma_map_page` (streaming
 *   DMA) and copied each frame into a fresh `napi_alloc_skb` linear skb.
 *   That copy is the per-packet hot-path cost: at MTU 1500 line rate the
 *   memcpy dominates, and under KASAN every copied byte is shadow-checked.
 *
 *   v3 (this file) is the upstream-shaped design: a `page_pool` owns the
 *   RX buffers, and the receive path hands the *received page itself* to
 *   the stack via `napi_build_skb` (zero copy) with `skb_mark_for_recycle`
 *   so the page returns to the pool when the stack frees the skb. The
 *   slot is refilled from the pool with a fresh page (alloc-before-consume
 *   so a refill failure drops the frame but never starves the ring).
 *
 *   Buffers are sized per-MTU (RX Candidate #3): a 1500-MTU frame gets an
 *   order-0 (4 KiB) page, not a 16 KiB jumbo page. This is not only a
 *   memory win — `build_skb` sets skb->truesize to the whole buffer, and a
 *   16 KiB truesize for a 1.5 KiB frame would throttle TCP receive-memory
 *   accounting and *regress* throughput. Per-MTU sizing keeps truesize
 *   proportional to the frame.
 *
 *   The geometry (page order, headroom, the device-writable `max_len`, and
 *   the total buffer size) is computed once at pool-create from the current
 *   `dev->mtu` and cached in `struct r8125_bridge`. `max_len` (capped to
 *   the 14-bit descriptor LEN field) is returned to Rust so the same value
 *   drives BOTH the per-descriptor LEN and the chip's `RxMaxSize`
 *   register — the "never let the chip write more than the buffer holds"
 *   rule.
 *
 * Hard cap: 320 LOC. Enforced by ci/check_cshim_loc_caps.sh. Raised from
 * 200 for the page_pool create/destroy + zero-copy refill super-call; the
 * file still owns exactly one concern (the RX buffer lifecycle + the RX
 * streaming-DMA syncs), which is why it stays one translation unit.
 */

#include "netdev_bridge_internal.h"

#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/if_vlan.h>
#include <linux/mm.h>
#include <linux/prefetch.h>
#include <linux/skbuff.h>
#include <linux/swab.h>

#include <net/page_pool/helpers.h>
#include <net/page_pool/types.h>

/*
 * RX headroom reserved in front of every frame. NET_SKB_PAD is the
 * stack's conventional head-padding (room for pushing tunnel/L2 headers,
 * and the same value napi_alloc_skb would reserve), so giving the stack
 * the same headroom keeps the zero-copy path behaviourally identical to
 * the previous copy path from the stack's point of view.
 */
#define R8125_RX_HEADROOM	NET_SKB_PAD

/* 14-bit descriptor LEN / RxMaxSize ceiling (DESC_LEN_MASK on the Rust side). */
#define R8125_RX_DESC_MAX	0x3FFF
#define R8125_RX_VLAN_TAG	BIT(16)
#define R8125_RX_VLAN_MASK	0xffffU

/*
 * Compute the per-MTU RX buffer geometry and stash it in the bridge.
 *
 *   max_len   — bytes the device may DMA into the buffer = the largest
 *               frame we accept (MTU + L2/VLAN/FCS), capped to the 14-bit
 *               descriptor field. Drives both the descriptor LEN and the
 *               chip RxMaxSize register (set by the Rust caller).
 *   headroom  — reserved in front of the frame (see above).
 *   offset    — where the device DMAs into the page (== headroom).
 *   buf_total — full page size (PAGE_SIZE << order). build_skb uses this
 *               as the frag size; skb_shared_info lives at its end, so the
 *               order is chosen so headroom + max_len + shinfo all fit.
 */
static void r8125_bridge_rx_geometry(struct r8125_bridge *b, unsigned int mtu)
{
	unsigned int frame_max = mtu + VLAN_ETH_HLEN + ETH_FCS_LEN;
	size_t data_room = SKB_DATA_ALIGN(R8125_RX_HEADROOM + frame_max);
	size_t buf_total = data_room +
			   SKB_DATA_ALIGN(sizeof(struct skb_shared_info));
	unsigned int order = get_order(buf_total);

	b->rx_headroom = R8125_RX_HEADROOM;
	b->rx_offset = R8125_RX_HEADROOM;
	b->rx_max_len = min_t(unsigned int, frame_max, R8125_RX_DESC_MAX);
	b->rx_buf_total = (size_t)PAGE_SIZE << order;
	b->rx_order = order;
}

/*
 * `r8125_bridge_rx_pool_create` — build the page_pool sized for the
 *                                 current MTU and cache its geometry.
 *
 * On success returns 0 and writes the per-descriptor / RxMaxSize buffer
 * length to *out_buf_len. On failure returns a negative errno and leaves
 * `b->page_pool` NULL. Idempotent against a double-create only in the
 * sense that the caller (Rust ndo_open) never does so; we WARN otherwise.
 */
int r8125_bridge_rx_pool_create(struct net_device *ndev, unsigned int ring_len,
				u32 *out_buf_len)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct page_pool_params pp = { 0 };
	struct page_pool *pool;

	if (WARN_ON(b->page_pool))
		return -EBUSY;

	r8125_bridge_rx_geometry(b, READ_ONCE(ndev->mtu));

	pp.order = b->rx_order;
	pp.flags = PP_FLAG_DMA_MAP | PP_FLAG_DMA_SYNC_DEV;
	/* Zero-copy RX can have up to one ring worth of pages posted to the
	 * device while another burst is still returning from the stack via skb
	 * recycle. A 2x recycle cache smooths small-frame bursts without
	 * preallocating pages; it only sizes page_pool's ptr_ring.
	 */
	pp.pool_size = ring_len * 2;
	pp.nid = dev_to_node(&b->pdev->dev);
	pp.dev = &b->pdev->dev;
	pp.napi = &b->napi;
	pp.dma_dir = DMA_FROM_DEVICE;
	pp.offset = b->rx_offset;
	pp.max_len = b->rx_max_len;

	pool = page_pool_create(&pp);
	if (IS_ERR(pool))
		return PTR_ERR(pool);

	b->page_pool = pool;
	*out_buf_len = b->rx_max_len;
	return 0;
}

/*
 * `r8125_bridge_rx_pool_destroy` — tear down the pool after all slots
 *                                  have been freed (page_pool_destroy
 *                                  requires every page returned first;
 *                                  the Rust caller frees all slots via
 *                                  r8125_bridge_rx_free before calling).
 * Idempotent against a NULL pool (ndo_open rollback before create).
 */
void r8125_bridge_rx_pool_destroy(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (!b->page_pool)
		return;
	page_pool_destroy(b->page_pool);
	b->page_pool = NULL;
}

/*
 * `r8125_bridge_rx_alloc` — pull one buffer from the pool for a slot.
 *
 * Writes the CPU base of the page to *out_cpu (build_skb operates on the
 * page base; the frame lands at base + offset) and the device-visible DMA
 * address (page DMA base + offset) to *out_dma — the latter is what goes
 * into the descriptor `addr`. Returns -ENOMEM on pool exhaustion. The
 * pool maps + syncs-for-device the page on alloc (PP_FLAG_DMA_*), so the
 * buffer is immediately safe to hand to the chip.
 */
int r8125_bridge_rx_alloc(struct net_device *ndev, void **out_cpu,
			  dma_addr_t *out_dma)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct page *page;

	page = page_pool_dev_alloc_pages(b->page_pool);
	if (!page)
		return -ENOMEM;

	*out_cpu = page_address(page);
	*out_dma = page_pool_get_dma_addr(page) + b->rx_offset;
	return 0;
}

/*
 * `r8125_bridge_rx_free` — return one slot's page to the pool.
 *
 * `cpu` is the page base previously returned by r8125_bridge_rx_alloc;
 * `virt_to_head_page` recovers the struct page. Idempotent against a NULL
 * `cpu` (the empty-slot sentinel on ndo_open rollback). Used only on the
 * teardown / rollback path (not from NAPI), so `allow_direct == false`.
 */
void r8125_bridge_rx_free(struct net_device *ndev, void *cpu)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (!cpu || !b->page_pool)
		return;
	page_pool_put_full_page(b->page_pool, virt_to_head_page(cpu), false);
}

/*
 * `r8125_bridge_rx_one_packet` — zero-copy RX super-call with refill.
 *
 * Alloc-before-consume: grab a fresh page for the slot FIRST. If that
 * fails we drop the frame and keep the just-received buffer in the slot
 * (the ring never starves), re-syncing it for the device. Otherwise we
 * hand the received page to the stack via napi_build_skb +
 * skb_mark_for_recycle (no copy — the page returns to the pool when the
 * stack frees the skb) and install the fresh page into the slot.
 *
 * Outputs the slot's new (cpu, dma) so the Rust NAPI caller updates its
 * shadow and re-posts the descriptor with the refilled address. On the
 * drop path the outputs equal the inputs (slot unchanged).
 *
 * Callable only from NAPI poll context (napi_build_skb + direct recycle).
 */
void r8125_bridge_rx_one_packet(struct net_device *ndev, dma_addr_t dma,
				const void *buf, size_t len, u32 desc_opts1,
				u32 desc_opts2, u64 hash_info, void **new_cpu,
				dma_addr_t *new_dma)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct page *newpage;
	struct sk_buff *skb;
	struct device *dev = &b->pdev->dev;
	const bool hash_valid = (hash_info >> 63) & 1ULL;
	const bool hash_l4 = (hash_info >> 62) & 1ULL;
	const u32 hash_value = (u32)(hash_info & 0xFFFFFFFFULL);

	newpage = page_pool_dev_alloc_pages(b->page_pool);
	if (unlikely(!newpage)) {
		/* Refill failed — drop, keep the old buffer in the slot. */
		this_cpu_inc(*b->rx_dropped_error);
		dma_sync_single_for_device(dev, dma, len, DMA_FROM_DEVICE);
		*new_cpu = (void *)buf;
		*new_dma = dma;
		return;
	}

	page_pool_dma_sync_for_cpu(b->page_pool, virt_to_head_page(buf), 0, len);
	prefetch(buf + b->rx_offset);

	skb = napi_build_skb((void *)buf, b->rx_buf_total);
	if (unlikely(!skb)) {
		/* skb alloc failed: recycle page to pool (NAPI context) and install fresh one. */
		this_cpu_inc(*b->rx_dropped_error);
		page_pool_put_page(b->page_pool, virt_to_head_page(buf), len, true);
	} else {
		skb_mark_for_recycle(skb);
		skb_reserve(skb, b->rx_offset);
		__skb_put(skb, len);
		skb->protocol = eth_type_trans(skb, ndev);
		if (hash_valid) {
			if (hash_l4) {
				skb_set_hash(skb, hash_value, PKT_HASH_TYPE_L4);
				this_cpu_inc(*b->rx_hash_l4);
			} else {
				skb_set_hash(skb, hash_value, PKT_HASH_TYPE_L3);
				this_cpu_inc(*b->rx_hash_l3);
			}
		} else {
			this_cpu_inc(*b->rx_hash_missing);
		}
		r8125_bridge_skb_rx_csum_set(skb, desc_opts1);
		if (desc_opts2 & R8125_RX_VLAN_TAG)
			__vlan_hwaccel_put_tag(skb, htons(ETH_P_8021Q),
						  swab16(desc_opts2 &
							 R8125_RX_VLAN_MASK));
		this_cpu_inc(*b->rx_handed_to_stack);
		dev_sw_netstats_rx_add(ndev, len);
		napi_gro_receive(&b->napi, skb);
	}

	*new_cpu = page_address(newpage);
	*new_dma = page_pool_get_dma_addr(newpage) + b->rx_offset;
}

MODULE_LICENSE("GPL v2");
