#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RX skb-build hot-path contract.
#
# `r8125_bridge_skb_build_rx` runs once per received packet from NAPI poll.
# It must use the NAPI-local skb allocator and kernel skb helpers rather than
# open-coding sk_buff internals. The helper keeps the code fast without making
# this C shim depend on avoidable layout details.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

bridge="$ROOT/src/netdev_bridge.c"
body=$(
	awk '
		/^struct sk_buff \*r8125_bridge_skb_build_rx\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$bridge"
)

if [[ -z "$body" ]]; then
	red "r8125_bridge_skb_build_rx body not found"
	exit "$rc"
fi

if grep -q 'napi_alloc_skb(&b->napi' <<<"$body"; then
	grn "RX skb build uses NAPI-local allocator"
else
	red "RX skb build must use napi_alloc_skb(&b->napi, ...)"
fi

if grep -q 'prefetch(buf)' <<<"$body"; then
	grn "RX skb build prefetches the freshly-DMAed buffer"
else
	red "RX skb build should prefetch(buf) before the linear copy"
fi

if grep -q '__skb_put_data(skb, buf, len)' <<<"$body"; then
	grn "RX skb build uses kernel helper for unchecked copy/tail update"
else
	red "RX skb build must use __skb_put_data(skb, buf, len)"
fi

if grep -q 'netdev_alloc_skb' <<<"$body"; then
	red "RX skb build regressed to netdev_alloc_skb"
else
	grn "RX skb build avoids netdev_alloc_skb slow path"
fi

if grep -qE 'skb->(tail|len)[[:space:]]*[+]?=' <<<"$body"; then
	red "RX skb build mutates skb tail/len directly"
else
	grn "RX skb build avoids direct skb tail/len mutation"
fi

exit "$rc"
