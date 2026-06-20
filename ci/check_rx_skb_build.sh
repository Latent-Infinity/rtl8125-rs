#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RX zero-copy hot-path contract.
#
# `r8125_bridge_rx_one_packet` runs once per received packet from NAPI poll.
# Since the page_pool rewrite it must hand the received page to the stack
# WITHOUT copying (napi_build_skb + skb_mark_for_recycle), refill the slot
# alloc-before-consume from the pool, and keep the streaming-DMA CPU sync
# before it touches the frame. It must NOT regress to the old copy path
# (napi_alloc_skb + skb_copy_to_linear_data).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

napi_rs="$ROOT/src/napi.rs"
bridge="$ROOT/src/netdev_bridge_rx_pool.c"
body=$(
	awk '
		/^void r8125_bridge_rx_one_packet\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$bridge"
)

if [[ -z "$body" ]]; then
	red "r8125_bridge_rx_one_packet body not found"
	exit "$rc"
fi

# 1. Zero-copy delivery: napi_build_skb + recycle, NOT a linear copy.
if grep -q 'napi_build_skb(' <<<"$body"; then
	grn "RX super-call hands the page to the stack via napi_build_skb (zero copy)"
else
	red "RX super-call must use napi_build_skb for zero-copy delivery"
fi
if grep -q 'skb_mark_for_recycle(skb)' <<<"$body"; then
	grn "RX super-call marks the skb for page_pool recycle"
else
	red "RX super-call must skb_mark_for_recycle(skb) so the page returns to the pool"
fi
if grep -qE 'skb_copy_to_linear_data|__skb_put_data|napi_alloc_skb' <<<"$body"; then
	red "RX super-call regressed to the copy path (napi_alloc_skb / skb_copy_to_linear_data)"
else
	grn "RX super-call avoids the per-packet copy"
fi

# 2. Alloc-before-consume refill: a fresh page is pulled from the pool, and
#    a refill failure drops the frame (never starves the ring).
if grep -q 'page_pool_dev_alloc_pages(q->page_pool)' <<<"$body"; then
	grn "RX super-call refills the slot from the page_pool"
else
	red "RX super-call must refill the slot via page_pool_dev_alloc_pages"
fi

# 3. Streaming-DMA CPU sync before the CPU reads the frame.
if grep -q 'dma_sync_single_for_cpu(d, dma, len, DMA_FROM_DEVICE)' <<<"$body" \
   || grep -q 'page_pool_dma_sync_for_cpu(' <<<"$body"; then
	grn "RX super-call syncs for CPU before reading the frame"
else
	red "RX super-call must dma_sync_single_for_cpu before touching the frame"
fi

# 4. No direct sk_buff internals mutation.
if grep -qE 'skb->(tail|len)[[:space:]]*[+]?=' <<<"$body"; then
	red "RX super-call mutates skb tail/len directly"
else
	grn "RX super-call avoids direct skb tail/len mutation"
fi

# 5. Hot-path order. The finalize (csum + GRO) is factored into the shared
#    r8125_bridge_rx_finish_skb helper (used by BOTH the single-buffer super-call
#    and the multi-buffer reassembly path), so check the order across both: in the
#    super-call body, refill-alloc -> sync_for_cpu -> build_skb ->
#    mark_for_recycle -> finish_skb; and in the helper, csum -> GRO.
alloc_line=$(grep -n 'page_pool_dev_alloc_pages(q->page_pool)' <<<"$body" | head -n1 | cut -d: -f1)
cpu_line=$(grep -nE 'dma_sync_single_for_cpu|page_pool_dma_sync_for_cpu' <<<"$body" | head -n1 | cut -d: -f1)
build_line=$(grep -n 'napi_build_skb(' <<<"$body" | head -n1 | cut -d: -f1)
recycle_line=$(grep -n 'skb_mark_for_recycle(skb)' <<<"$body" | head -n1 | cut -d: -f1)
finish_line=$(grep -n 'r8125_bridge_rx_finish_skb(' <<<"$body" | head -n1 | cut -d: -f1)
if [[ -n "$alloc_line" && -n "$cpu_line" && -n "$build_line" && -n "$recycle_line" && -n "$finish_line" ]] \
   && (( alloc_line < cpu_line && cpu_line < build_line && build_line < recycle_line && recycle_line < finish_line )); then
	grn "RX super-call preserves refill/sync/build/recycle/finalize order"
else
	red "RX super-call order must be alloc-refill -> sync_for_cpu -> build_skb -> mark_for_recycle -> finish_skb"
fi

# 5b. The shared finalize helper orders csum before GRO.
finish_body=$(
	awk '
		/^(static )?void r8125_bridge_rx_finish_skb\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$bridge"
)
fcsum_line=$(grep -n 'r8125_bridge_skb_rx_csum_set' <<<"$finish_body" | head -n1 | cut -d: -f1)
fgro_line=$(grep -n 'napi_gro_receive(&q->napi, skb)' <<<"$finish_body" | head -n1 | cut -d: -f1)
if [[ -n "$fcsum_line" && -n "$fgro_line" ]] && (( fcsum_line < fgro_line )); then
	grn "RX finalize helper sets csum before GRO"
else
	red "RX finalize helper (r8125_bridge_rx_finish_skb) must set csum before napi_gro_receive"
fi

# 6. Allocation failure is accounted before returning.
if grep -q 'rx_dropped_error' <<<"$body" \
   && grep -q 'return;' <<<"$body"; then
	grn "RX super-call accounts refill failure before returning"
else
	red "RX super-call must account refill/skb failure before returning"
fi

# ── NAPI poll side ────────────────────────────────────────────────────────
process_rx_body=$(
	awk '
		/^fn process_rx_completions\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$napi_rs"
)

own_line=$(awk '/DESC_OWN/ && /opts1/ { print NR; exit }' <<<"$process_rx_body")
rmb_line=$(grep -n 'ub::dma_rmb()' <<<"$process_rx_body" | head -n1 | cut -d: -f1)
len_line=$(grep -n 'let len = (desc.opts1 & regs::DESC_LEN_MASK)' <<<"$process_rx_body" | head -n1 | cut -d: -f1)
if [[ -z "$len_line" ]]; then
	len_line=$(grep -n 'let len = completion.len' <<<"$process_rx_body" | head -n1 | cut -d: -f1)
fi
if [[ -z "$len_line" ]]; then
	len_line=$(grep -n 'let len = desc.len' <<<"$process_rx_body" | head -n1 | cut -d: -f1)
fi
if [[ -n "$own_line" && -n "$rmb_line" && -n "$len_line" ]] \
   && (( own_line < rmb_line && rmb_line < len_line )); then
	grn "NAPI RX poll orders descriptor reads behind dma_rmb after OWN clears"
else
	red "NAPI RX poll must call ub::dma_rmb() after OWN clears and before descriptor field reads"
fi

if grep -q 'ub::bridge_rx_one_packet(' <<<"$process_rx_body"; then
	grn "NAPI RX poll calls bridge_rx_one_packet super-call"
else
	red "NAPI RX poll must call ub::bridge_rx_one_packet - see RX_OPTIMIZATION_CANDIDATES.md"
fi

# The poll must install the refilled buffer the super-call returns, or the
# next wrap reads a page now owned by the stack (use-after-handoff).
if echo "$process_rx_body" | awk '
	/(set_rx_slot|set_slot)\(.*RxSlot/ { found = 1; exit }
	/(set_rx_slot|set_slot)\(/ { in_call = 1 }
	in_call && /RxSlot/ { found = 1; exit }
	in_call && /^\s*\)/ { in_call = 0 }
	END { exit (found ? 0 : 1) }
'; then
	grn "NAPI RX poll installs the refilled buffer into the slot shadow"
else
	red "NAPI RX poll must set the queue slot with the refilled (cpu, dma) from the super-call"
fi

exit "$rc"
