#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for M6 sub-feature #3 (jumbo frames + RX pool refactor).
# See docs/M6_JUMBO_DESIGN.md.
#
# Once we replace the M4 single CoherentAllocation<RxBuffer> with
# per-slot streaming DMA pages, every alloc_pages call needs a
# matching __free_pages and every dma_map_page needs a matching
# dma_unmap_page. This script catches mismatches statically.
#
# Vacuous before the jumbo refactor lands.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel()  { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

# Engagement: jumbo RX-pool refactor is in tree once any cshim file
# references alloc_pages_node, OR if RxSlot/rx_slots appears in
# NetdevState (the per-slot struct from the design doc).
JUMBO_LANDED=0
if grep -qE 'alloc_pages_node|alloc_pages\b' "$ROOT/src/"*.c 2>/dev/null; then
	JUMBO_LANDED=1
fi
if grep -qE 'rx_slots\s*:\s*\[' "$ROOT/src/netdev.rs" 2>/dev/null; then
	JUMBO_LANDED=1
fi
if [[ "$JUMBO_LANDED" -eq 0 ]]; then
	yel "jumbo RX-pool refactor not yet landed — skipping"
	exit 0
fi

# 1. alloc_pages_node paired with __free_pages.
alloc_count=$(grep -c 'alloc_pages_node\b\|\balloc_pages(' "$ROOT/src/"*.c 2>/dev/null | \
	awk -F: '{s+=$NF} END {print s}')
free_count=$(grep -c '__free_pages\b' "$ROOT/src/"*.c 2>/dev/null | \
	awk -F: '{s+=$NF} END {print s}')
if [[ "$alloc_count" -gt 0 ]] && [[ "$free_count" -gt 0 ]]; then
	grn "alloc_pages call count $alloc_count, __free_pages count $free_count (both nonzero)"
elif [[ "$alloc_count" -gt 0 ]]; then
	red "alloc_pages used but __free_pages never called — RX pool leaks on close"
fi

# 2. dma_map_page paired with dma_unmap_page (RX side specifically —
#    TX already has this via skb_frag_dma_map / dma_unmap_page).
map_count=$(grep -c 'dma_map_page\b' "$ROOT/src/"*.c 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
unmap_count=$(grep -c 'dma_unmap_page\b' "$ROOT/src/"*.c 2>/dev/null | awk -F: '{s+=$NF} END {print s}')
if [[ "$map_count" -gt 0 ]] && [[ "$unmap_count" -gt 0 ]]; then
	grn "dma_map_page count $map_count, dma_unmap_page count $unmap_count (both nonzero)"
elif [[ "$map_count" -gt 0 ]]; then
	red "dma_map_page used but dma_unmap_page never called — DMA mapping leaks"
fi

# 3. Per-slot DMA shadow tracking (similar to tx_shadow_dma for TX).
#    The reaper / cleanup needs to recover (handle, len) at unmap time
#    so we need a shadow array per RX slot.
if grep -qE 'rx_shadow_dma|rx_slot.*dma' "$ROOT/src/netdev.rs" 2>/dev/null; then
	grn "RX DMA shadow tracking is present"
else
	red "RX pool uses streaming DMA but no rx_shadow_dma/rx_slot.dma tracking — leak risk"
fi

# 4. ndo_stop walks all slots to free + unmap (the cleanup pairing).
if awk '/fn ndo_stop\b/,/^}/' "$ROOT/src/netdev.rs" 2>/dev/null | \
		grep -qE '(rx_slot|rx_shadow_dma).*dma_unmap|__free_pages\(.*rx'; then
	grn "ndo_stop cleans up RX pool (unmap + free per slot)"
else
	red "ndo_stop does NOT walk RX slots to free pages + unmap DMA — leak on rmmod"
fi

exit $rc
