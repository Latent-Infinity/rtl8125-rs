// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_rx_pool.c — per-slot streaming-DMA RX-buffer helpers
 *                          for the r8125_rust jumbo path (M6 sub-feature #2,
 *                          plan §7 M6).
 *
 * The earlier 2 KiB coherent-ring design used one
 * `CoherentAllocation<RxBuffer>` for 256 slots. That is 512 KiB of
 * contiguous DMA-coherent memory and doesn't scale to jumbo: 256 × 16 KiB
 * = 4 MiB contiguous is an order-10 allocation and reliably fails on
 * fragmented systems. r8169 mainline avoids the problem by using
 * `alloc_pages` per slot with `dma_map_page` (streaming DMA). We follow
 * the same pattern.
 *
 * Each call to `r8125_bridge_rx_alloc_jumbo` returns one 16 KiB-aligned
 * page chunk (`R8125_RX_PAGE_ORDER = 2`, so 4 × PAGE_SIZE on x86)
 * dma-mapped FROM_DEVICE. Rust holds the CPU pointer + DMA handle in its
 * `RxSlot` shadow; the caller frees the pair via
 * `r8125_bridge_rx_free_jumbo`. The NAPI RX super-call below performs
 * the streaming-DMA ownership transitions (`dma_sync_single_for_cpu`
 * before copying bytes, `dma_sync_single_for_device` before the slot is
 * re-posted). On cache-coherent archs (x86, x86_64 with IOMMU off) the
 * sync calls are no-ops, but keeping them in the source makes the
 * discipline visible and lets the same code work on ARM/RISC-V.
 *
 * Hard cap: 200 LOC. Enforced by ci/check_cshim_loc_caps.sh. The RX
 * super-call lives here because it owns the RX streaming-DMA syncs.
 */

#include "netdev_bridge_internal.h"

#include <linux/dma-mapping.h>
#include <linux/etherdevice.h>
#include <linux/gfp.h>
#include <linux/mm.h>
#include <linux/prefetch.h>
#include <linux/skbuff.h>

/*
 * `R8125_RX_PAGE_ORDER` covers `JUMBO_16K_BYTES = 16384`. Must equal
 * `get_order(JUMBO_16K_BYTES)` — on every architecture with a 4 KiB
 * PAGE_SIZE that's `2` (4 pages); on archs with larger pages the order
 * drops accordingly, but we don't target those today.
 *
 * Kept in sync with `JUMBO_16K_BYTES` in `src/regs.rs` by the static CI
 * gate `ci/check_jumbo_mtu_chip.sh`: any change here forces the same
 * change there. The compile-time check below catches one direction of
 * drift (allocating less than the chip's MTU).
 */
#define R8125_RX_JUMBO_BUF_SIZE	16384
#define R8125_RX_PAGE_ORDER	2

/*
 * `r8125_bridge_rx_alloc_jumbo` — allocate one jumbo-sized RX slot's
 *                                 page chunk + streaming DMA mapping.
 *
 * On success returns 0 and writes:
 *   *out_cpu := page_address(page) (the kernel virtual address — the
 *               linear-map alias, since `alloc_pages` returns lowmem
 *               pages on x86_64 and the kernel-Rust DMA layer never
 *               hands us highmem)
 *   *out_dma := dma_map_page(...) result (DMA_FROM_DEVICE)
 *
 * On failure returns a negative errno (`-ENOMEM` for alloc failure,
 * `-EIO` for the DMA mapping). On any failure path, partially-acquired
 * resources are released before return so the caller does NOT need to
 * call `free` on a failed slot.
 *
 * `dev` is the parent `struct device` (i.e. `&pdev->dev`); the kernel
 * uses it to pick the right IOMMU + cache-flush policy.
 */
int r8125_bridge_rx_alloc_jumbo(struct device *dev, void **out_cpu,
				 dma_addr_t *out_dma)
{
	struct page *page;
	dma_addr_t dma;

	page = alloc_pages(GFP_KERNEL, R8125_RX_PAGE_ORDER);
	if (!page)
		return -ENOMEM;

	dma = dma_map_page(dev, page, 0, R8125_RX_JUMBO_BUF_SIZE,
			   DMA_FROM_DEVICE);
	if (dma_mapping_error(dev, dma)) {
		__free_pages(page, R8125_RX_PAGE_ORDER);
		return -EIO;
	}

	*out_cpu = page_address(page);
	*out_dma = dma;
	return 0;
}

/*
 * `r8125_bridge_rx_free_jumbo` — release one slot acquired via
 *                                `r8125_bridge_rx_alloc_jumbo`.
 *
 * `dma_unmap_page` must come BEFORE `__free_pages` — unmapping
 * synchronises the chip's view and tears down any IOMMU mapping that
 * still references the physical page. `virt_to_page(cpu)` recovers the
 * `struct page *` from the linear-map address (only safe because we
 * stored a lowmem virtual address — see the comment in
 * `r8125_bridge_rx_alloc_jumbo`).
 *
 * Idempotent against a `(NULL, 0)` slot — the caller may pass a slot
 * that was never allocated (e.g. an `ndo_open` failure path freeing
 * partially-allocated state). Both NULL `cpu` and the implicit
 * `dma == 0` short-circuit the free.
 */
void r8125_bridge_rx_free_jumbo(struct device *dev, void *cpu, dma_addr_t dma)
{
	if (!cpu)
		return;
	dma_unmap_page(dev, dma, R8125_RX_JUMBO_BUF_SIZE, DMA_FROM_DEVICE);
	__free_pages(virt_to_page(cpu), R8125_RX_PAGE_ORDER);
}

/*
 * `r8125_bridge_rx_one_packet` — RX super-call (Candidate B of
 *                                docs/RX_OPTIMIZATION_CANDIDATES.md).
 *
 * Collapses the five previous FFI crossings per RX packet
 * (sync_for_cpu → skb_build_rx → skb_rx_csum_set → skb_deliver_rx →
 * sync_for_device) into a single C function. At MTU 1500 line rate
 * (~166 K pps) this saves ~660 K boundary crossings/second.
 *
 * Same idiomatic shape r8169_main.c `rtl_rx` uses inline; the
 * difference is that we expose it as one FFI entry point to the Rust
 * NAPI poll caller. If skb allocation fails, this function
 * bumps the §6.3 `rx_dropped_error` counter and still returns the
 * DMA slot to device ownership before returning.
 *
 * Callable only from NAPI poll context (uses `napi_alloc_skb`).
 */
void r8125_bridge_rx_one_packet(struct net_device *ndev,
				dma_addr_t dma, const void *buf,
				size_t len, u32 desc_opts1)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct device *d = &b->pdev->dev;
	struct sk_buff *skb;
	unsigned int rx_len;

	dma_sync_single_for_cpu(d, dma, len, DMA_FROM_DEVICE);

	skb = napi_alloc_skb(&b->napi, len + NET_IP_ALIGN);
	if (unlikely(!skb)) {
		this_cpu_inc(*b->rx_dropped_error);
		dma_sync_single_for_device(d, dma, R8125_RX_JUMBO_BUF_SIZE,
					   DMA_FROM_DEVICE);
		return;
	}
	skb_reserve(skb, NET_IP_ALIGN);
	prefetch(buf);
	__skb_put_data(skb, buf, len);
	skb->protocol = eth_type_trans(skb, ndev);
	r8125_bridge_skb_rx_csum_set(skb, desc_opts1);

	rx_len = skb->len;
	this_cpu_inc(*b->rx_handed_to_stack);
	/* Per-CPU rx_packets/rx_bytes via Candidate G's
	 * NETDEV_PCPU_STAT_TSTATS setup at bridge_alloc.
	 */
	dev_sw_netstats_rx_add(ndev, rx_len);
	napi_gro_receive(&b->napi, skb);

	dma_sync_single_for_device(d, dma, R8125_RX_JUMBO_BUF_SIZE,
				   DMA_FROM_DEVICE);
}

MODULE_LICENSE("GPL v2");
