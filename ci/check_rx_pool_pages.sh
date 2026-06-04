#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for the zero-copy RX page_pool lifecycle (M6 #2 v3).
# See docs/M6_JUMBO_DESIGN.md and src/netdev_bridge_rx_pool.c.
#
# The RX buffers are owned by a `page_pool`. Leak-safety now means:
#   - every page_pool_create has a matching page_pool_destroy,
#   - allocated pages either go to the stack (recycle) or back to the pool
#     (page_pool_put_full_page) — no bare alloc without a return path,
#   - ndo_stop frees all slots AND destroys the pool,
#   - ndo_open failure paths release the pool (RAII guard or manual).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel()  { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

# Engagement: zero-copy RX pool is in tree once any cshim file references
# page_pool_create, OR the per-slot shadow appears in NetdevState.
LANDED=0
if grep -qE 'page_pool_create' "$ROOT/src/"*.c 2>/dev/null; then
	LANDED=1
fi
if grep -qE 'slot_dma\s*:\s*\[' "$ROOT/src/netdev.rs" 2>/dev/null; then
	LANDED=1
fi
if [[ "$LANDED" -eq 0 ]]; then
	yel "zero-copy RX pool not yet landed — skipping"
	exit 0
fi

# 1. page_pool_create paired with page_pool_destroy.
create_count=$(grep -c 'page_pool_create' "$ROOT/src/"*.c 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
destroy_count=$(grep -c 'page_pool_destroy' "$ROOT/src/"*.c 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
if [[ "$create_count" -gt 0 ]] && [[ "$destroy_count" -gt 0 ]]; then
	grn "page_pool_create count $create_count, page_pool_destroy count $destroy_count (both nonzero)"
elif [[ "$create_count" -gt 0 ]]; then
	red "page_pool_create used but page_pool_destroy never called — pool leaks on close"
fi

# 2. Allocated pages have a return path: skb_mark_for_recycle (to the stack)
#    AND page_pool_put_full_page (teardown + drop). Both must exist.
alloc_count=$(grep -c 'page_pool_dev_alloc_pages' "$ROOT/src/"*.c 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
if [[ "$alloc_count" -gt 0 ]]; then
	if grep -qE 'skb_mark_for_recycle' "$ROOT/src/"*.c 2>/dev/null \
	   && grep -qE 'page_pool_put_full_page' "$ROOT/src/"*.c 2>/dev/null; then
		grn "RX pages return via skb_mark_for_recycle (stack) + page_pool_put_full_page (teardown/drop)"
	else
		red "page_pool_dev_alloc_pages used but missing a return path (skb_mark_for_recycle / page_pool_put_full_page)"
	fi
fi

# 3. The driver must NOT mix the bare-page allocator with page_pool — that
#    would double-own buffers. (The v2 alloc_pages/dma_map_page path is gone.)
if grep -qE '\balloc_pages\(|\bdma_map_page\(' "$ROOT/src/"*.c 2>/dev/null; then
	red "bare alloc_pages/dma_map_page present alongside page_pool — buffer ownership ambiguity"
else
	grn "RX path uses page_pool exclusively (no bare alloc_pages/dma_map_page)"
fi

# 4. Per-slot DMA shadow tracking (NAPI needs to re-post the refilled addr).
if grep -qE 'slot_dma\s*:\s*\[' "$ROOT/src/netdev.rs" 2>/dev/null; then
	grn "RX per-slot DMA shadow tracking is present"
else
	red "RX pool uses streaming DMA but no slot_dma shadow — re-post/leak risk"
fi

# 5. ndo_stop frees all slots AND destroys the pool.
stop_body=$(awk '/fn[[:space:]]+ndo_stop\(/,/^}/' "$ROOT/src/netdev.rs" 2>/dev/null)
if grep -q 'free_rx_slots(state)' <<<"$stop_body"; then
	grn "ndo_stop frees the RX pool slots (free_rx_slots also destroys the pool)"
else
	red "ndo_stop does NOT call free_rx_slots — leak on rmmod"
fi
# free_rx_slots itself must destroy the pool after the slot loop.
frs_body=$(awk '/fn[[:space:]]+free_rx_slots\(/,/^}/' "$ROOT/src/netdev.rs" 2>/dev/null)
if grep -q 'rx_pool_destroy(' <<<"$frs_body"; then
	grn "free_rx_slots destroys the page_pool after returning every slot"
else
	red "free_rx_slots must rx_pool_destroy() after freeing all slots"
fi

# 6. ndo_open post-allocation failure paths release the pool. The RxPoolGuard
#    RAII form: its Drop calls free_rx_slots (which destroys the pool), so any
#    `?`/`return Err` after RxPoolGuard::allocate unwinds automatically.
raii_ok=1
grep -qE 'struct RxPoolGuard' "$ROOT/src/netdev.rs" || raii_ok=0
grep -qE 'impl(<[^>]+>)?[[:space:]]+Drop[[:space:]]+for[[:space:]]+RxPoolGuard' "$ROOT/src/netdev.rs" || raii_ok=0
grep -q 'free_rx_slots(self.state)' "$ROOT/src/netdev.rs" || raii_ok=0
awk '/fn[[:space:]]+ndo_open\(/,/^}/' "$ROOT/src/netdev.rs" | grep -q 'RxPoolGuard::allocate' || raii_ok=0
if grep -qE 'fn[[:space:]]+free_rx_slots\(' "$ROOT/src/netdev.rs" && [[ $raii_ok -eq 1 ]]; then
	grn "ndo_open failure paths release the RX pool (RxPoolGuard RAII)"
else
	red "ndo_open has a post-RX-allocation failure path that does not release the pool"
fi

exit $rc
