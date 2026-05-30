#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RX skb-build hot-path contract.
#
# `r8125_bridge_rx_one_packet` runs once per received packet from NAPI poll.
# It must perform streaming-DMA syncs, use the NAPI-local skb allocator, and
# use kernel skb helpers rather than open-coding sk_buff internals.

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

if grep -q 'dma_sync_single_for_cpu(d, dma, len, DMA_FROM_DEVICE)' <<<"$body" \
   && grep -q 'dma_sync_single_for_device(d, dma, R8125_RX_JUMBO_BUF_SIZE' <<<"$body"; then
	grn "RX super-call keeps streaming-DMA CPU/device ownership syncs"
else
	red "RX super-call must sync for CPU before copy and for device before return"
fi

if grep -q 'napi_alloc_skb(&b->napi' <<<"$body"; then
	grn "RX super-call uses NAPI-local allocator"
else
	red "RX super-call must use napi_alloc_skb(&b->napi, ...)"
fi

if grep -q 'prefetch(buf)' <<<"$body"; then
	grn "RX super-call prefetches the freshly-DMAed buffer"
else
	red "RX super-call should prefetch(buf) before the linear copy"
fi

if grep -q '__skb_put_data(skb, buf, len)' <<<"$body"; then
	grn "RX super-call uses kernel helper for unchecked copy/tail update"
else
	red "RX super-call must use __skb_put_data(skb, buf, len)"
fi

if grep -q 'netdev_alloc_skb' <<<"$body"; then
	red "RX super-call regressed to netdev_alloc_skb"
else
	grn "RX super-call avoids netdev_alloc_skb slow path"
fi

if grep -qE 'skb->(tail|len)[[:space:]]*[+]?=' <<<"$body"; then
	red "RX super-call mutates skb tail/len directly"
else
	grn "RX super-call avoids direct skb tail/len mutation"
fi

cpu_line=$(grep -n 'dma_sync_single_for_cpu' <<<"$body" | head -n1 | cut -d: -f1)
alloc_line=$(grep -n 'napi_alloc_skb(&b->napi' <<<"$body" | head -n1 | cut -d: -f1)
copy_line=$(grep -n '__skb_put_data(skb, buf, len)' <<<"$body" | head -n1 | cut -d: -f1)
csum_line=$(grep -n 'r8125_bridge_skb_rx_csum_set' <<<"$body" | head -n1 | cut -d: -f1)
gro_line=$(grep -n 'napi_gro_receive(&b->napi, skb)' <<<"$body" | head -n1 | cut -d: -f1)
device_line=$(grep -n 'dma_sync_single_for_device' <<<"$body" | tail -n1 | cut -d: -f1)
if [[ -n "$cpu_line" && -n "$alloc_line" && -n "$copy_line" && -n "$csum_line" && -n "$gro_line" && -n "$device_line" ]] \
   && (( cpu_line < alloc_line && alloc_line < copy_line && copy_line < csum_line && csum_line < gro_line && gro_line < device_line )); then
	grn "RX super-call preserves sync/build/csum/GRO/device-sync order"
else
	red "RX super-call order must be sync_for_cpu -> alloc/copy -> csum -> GRO -> sync_for_device"
fi

if grep -q 'rx_dropped_error' <<<"$body" \
   && grep -q 'return;' <<<"$body"; then
	grn "RX super-call accounts allocation failure before returning"
else
	red "RX super-call must account skb allocation failure before returning"
fi

process_rx_body=$(
	awk '
		/^fn process_rx_completions\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$napi_rs"
)
if grep -q 'ub::bridge_rx_one_packet(' <<<"$process_rx_body"; then
	grn "NAPI RX poll calls bridge_rx_one_packet super-call"
else
	red "NAPI RX poll must call ub::bridge_rx_one_packet - see RX_OPTIMIZATION_CANDIDATES.md §B"
fi

exit "$rc"
