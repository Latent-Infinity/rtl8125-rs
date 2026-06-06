#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for the BQL retry path. It checks that sent/completed accounting
# is paired, gated by one predicate, and avoids the old netdev_reset_queue
# bootstrap stall.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETDEV="$ROOT/src/netdev.rs"
NAPI="$ROOT/src/napi.rs"
SKB="$ROOT/src/skb.rs"
UB="$ROOT/src/unsafe_boundary.rs"
HDR="$ROOT/src/netdev_bridge.h"
OFFLOAD="$ROOT/src/netdev_bridge_offload.c"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

grep -q 'fn select_bql_active(state: &NetdevState) -> bool' "$NETDEV" \
	&& grep -q 'module_parameters::bql_mode' "$NETDEV" \
	&& grep -q 'pub(crate) fn bql_active(state: &NetdevState) -> bool' "$NETDEV" \
	&& grep -q 'state.bql_enabled.load(Ordering::Acquire)' "$NETDEV" \
	&& grn "open snapshots bql_mode and hot paths read bql_active" \
	|| red "BQL must snapshot bql_mode at open and gate hot paths through bql_active"

grep -q 'let bql_enabled = select_bql_active(state);' "$NETDEV" \
	&& grep -q 'state.bql_enabled.store(bql_enabled, Ordering::Release)' "$NETDEV" \
	&& grep -q 'ub::dql_seed_min_limit(ndev)' "$NETDEV" \
	&& grn "ndo_open seeds BQL only after snapshotting bql_enabled" \
	|| red "ndo_open must snapshot bql_enabled and seed under that gate"

grep -q 'skb.wire_len()' "$NETDEV" \
	&& grep -q 'let xmit_more = ub::netdev_xmit_more();' "$NETDEV" \
	&& grep -q 'ub::netdev_sent_queue(ndev, wire_len, xmit_more)' "$NETDEV" \
	&& grep -q 'let should_doorbell_for_batch = if bql_enabled' "$NETDEV" \
	&& grn "xmit captures skb length and lets __netdev_sent_queue decide BQL doorbells" \
	|| red "xmit must pair BQL sent accounting with the xmit_more doorbell decision"

grep -q 'completed_bytes += skb.consume_tx(ndev);' "$NAPI" \
	&& grep -q 'ub::netdev_completed_queue(ndev, completed_pkts, completed_bytes)' "$NAPI" \
	&& grn "NAPI batches completed BQL bytes from consumed skbs" \
	|| red "NAPI TX reap must batch completed BQL bytes and packets"

grep -q 'crate::netdev::bql_active(state)' "$NAPI" \
	&& grn "completion side uses the same bql_active predicate" \
	|| red "completion side must use netdev::bql_active to avoid imbalance"

grep -q 'reap_inflight_tx_shadow(state)' "$NETDEV" \
	&& grep -q 'bql_bytes += skb.wire_len();' "$NETDEV" \
	&& grep -q 'ub::netdev_completed_queue(ndev, bql_pkts, bql_bytes)' "$NETDEV" \
	&& grn "stop teardown balances BQL-sent in-flight skbs" \
	|| red "stop teardown must complete BQL bytes for sent skbs it frees"

grep -q 'pub(crate) fn consume_tx(self, ndev: .*-> usize' "$SKB" \
	&& grep -q 'pub(crate) fn wire_len(&self) -> usize' "$SKB" \
	&& grn "DriverOwnedSkb exposes length only through TX ownership methods" \
	|| red "BQL byte accounting must stay behind DriverOwnedSkb methods"

for sym in \
	r8125_bridge_skb_len \
	r8125_bridge_dql_seed_min_limit \
	r8125_bridge_netdev_sent_queue \
	r8125_bridge_netdev_completed_queue
do
	grep -q "$sym" "$UB" && grep -q "$sym" "$HDR" && grep -q "$sym" "$OFFLOAD" \
		|| red "missing BQL cshim/unsafe-boundary symbol: $sym"
done
[[ $rc -eq 0 ]] && grn "BQL cshim symbols are declared, wrapped, and defined"

if grep -R -nE '\b(netdev_reset_queue|netdev_tx_reset_queue|netdev_tx_reset_subqueue)[[:space:]]*\(' "$ROOT/src" \
	| grep -vE ':[[:space:]]*(//|/\*|\*)' >/dev/null; then
	red "BQL retry must not call netdev_reset_queue/reset_subqueue"
else
	grn "BQL retry avoids netdev_reset_queue bootstrap stall"
fi

grep -q 'netdev_queue_set_dql_min_limit(txq, seed)' "$OFFLOAD" \
	&& grep -q 'txq->dql.limit < seed' "$OFFLOAD" \
	&& grn "BQL seed uses the netdev min-limit helper plus explicit bootstrap floor" \
	|| red "BQL seed must set min_limit and the initial limit floor"

grep -q '__netdev_sent_queue(ndev, bytes, xmit_more)' "$OFFLOAD" \
	&& grep -q 'bool r8125_bridge_netdev_sent_queue' "$HDR" \
	&& grn "BQL sent wrapper uses the r8169-style __netdev_sent_queue helper" \
	|| red "BQL sent wrapper must return the __netdev_sent_queue doorbell decision"

exit "$rc"
