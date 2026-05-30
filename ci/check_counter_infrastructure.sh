#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for plan §6.3 — the disposition-counter infrastructure
# (mechanical, no hardware needed). The matching runtime test that
# asserts the actual invariant lives in `ci/check_counter_invariant.sh`
# and runs on a guest with the chip; this script enforces that the
# pieces it depends on stay in tree.
#
# Six §6.3 counters: tx_received, tx_consumed, tx_busy_exception,
# tx_dropped_error, rx_handed_to_stack, rx_dropped_error.
#
# We check, for each:
#   1. it appears as a u64 field in struct r8125_bridge (storage)
#   2. it has at least one this_cpu_inc increment site in the cshim sources
#   3. it's read out via r8125_bridge_counters_snapshot
#   4. it's exposed by ethtool -S via r8125_bridge_ethtool_strings
#
# Also checks the invariant equation is asserted in r8125_bridge.h
# documentation so future readers can find it.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

COUNTERS=(tx_received tx_consumed tx_busy_exception tx_dropped_error
          rx_handed_to_stack rx_dropped_error)

INTERNAL="$ROOT/src/netdev_bridge_internal.h"
BRIDGE_C="$ROOT/src/netdev_bridge.c"
OFFLOAD_C="$ROOT/src/netdev_bridge_offload.c"
ETHTOOL_C="$ROOT/src/netdev_bridge_ethtool.c"
COUNTERS_C="$ROOT/src/netdev_bridge_counters.c"
BRIDGE_H="$ROOT/src/netdev_bridge.h"
# `rx_handed_to_stack` and `rx_dropped_error` increment sites moved
# into `r8125_bridge_rx_one_packet` (Candidate B,
# RX_OPTIMIZATION_CANDIDATES.md §B) on 2026-05-30 — search the
# RX-pool TU too.
RX_POOL_C="$ROOT/src/netdev_bridge_rx_pool.c"

for c in "${COUNTERS[@]}"; do
	# 1. struct field present as percpu pointer (post-#45 storage shape).
	if ! grep -qE "^\s*u64\s+__percpu\s+\*$c;" "$INTERNAL"; then
		red "missing 'u64 __percpu *$c;' field in struct r8125_bridge ($INTERNAL)"
		continue
	fi
	# 2. at least one this_cpu_inc increment site in any of the bridge .c TUs
	if ! grep -qE "this_cpu_inc\(\*b->$c\)" "$BRIDGE_C" "$OFFLOAD_C" "$RX_POOL_C"; then
		red "no this_cpu_inc(*b->$c) increment site found"
		continue
	fi
	# 3. counter exposed by snapshot function via bridge_counter_sum
	if ! grep -qE "out->$c\s*=\s*bridge_counter_sum\(b->$c\)" "$COUNTERS_C"; then
		red "$c not summed into r8125_bridge_counters in snapshot"
		continue
	fi
	# 4. counter exposed by ethtool -S
	if ! grep -qE "\"$c\"" "$ETHTOOL_C"; then
		red "$c not advertised via ethtool -S (missing from bridge_ethtool_strings)"
		continue
	fi
	grn "§6.3 counter $c: percpu field + this_cpu_inc + sum-snapshot + ethtool"
done

# bridge_counter_sum must walk all possible CPUs so the snapshot reflects
# every increment, not just the calling CPU's slot. Use awk to scan the
# function body — single-line greps miss multi-line C control flow.
if awk '/static u64 bridge_counter_sum/,/^}/' "$COUNTERS_C" | \
	grep -qE "for_each_possible_cpu"; then
	grn "bridge_counter_sum walks all possible CPUs"
else
	red "bridge_counter_sum does not iterate for_each_possible_cpu"
fi

# Lifecycle helpers must exist and call free_percpu for each counter.
if grep -qE "^int\s+r8125_bridge_counters_alloc\(" "$COUNTERS_C" && \
   grep -qE "^void\s+r8125_bridge_counters_free\(" "$COUNTERS_C"; then
	grn "percpu lifecycle helpers r8125_bridge_counters_alloc/free defined"
else
	red "missing r8125_bridge_counters_alloc/free lifecycle helpers"
fi
free_count=$(awk '/^void r8125_bridge_counters_free/,/^}/' "$COUNTERS_C" | \
	grep -cE "free_percpu\(b->")
if [[ "$free_count" -lt 6 ]]; then
	red "r8125_bridge_counters_free calls free_percpu only $free_count times (expected 6)"
else
	grn "r8125_bridge_counters_free releases all 6 percpu counters"
fi
# Lifecycle helpers must be wired into both alloc + both free paths.
if grep -q "r8125_bridge_counters_alloc(" "$BRIDGE_C" && \
   [[ "$(grep -c 'r8125_bridge_counters_free(' "$BRIDGE_C")" -ge 2 ]]; then
	grn "counters_alloc + counters_free wired into bridge lifecycle"
else
	red "counters_alloc/free not wired into r8125_bridge_alloc + both free paths"
fi

# Cross-check: the ethtool string table length matches the counter count
nstrings=$(awk '/bridge_ethtool_strings\[\]\[ETH_GSTRING_LEN\]/,/^};/' "$ETHTOOL_C" | grep -c '^\s*"')
if [[ "$nstrings" -ne "${#COUNTERS[@]}" ]]; then
	red "bridge_ethtool_strings has $nstrings entries; expected ${#COUNTERS[@]} (one per §6.3 counter)"
else
	grn "ethtool string table has all ${#COUNTERS[@]} §6.3 counters"
fi

# The §6.3 invariant equation must be documented somewhere reviewers will find it.
if grep -qE "tx_received\s*==\s*tx_consumed\s*\+\s*tx_busy_exception\s*\+\s*tx_dropped_error" \
		"$BRIDGE_H" "$BRIDGE_C" "$ETHTOOL_C"; then
	grn "§6.3 invariant equation appears in the bridge sources"
else
	red "§6.3 invariant equation not documented in bridge sources"
fi

# The runtime check script must exist and be executable.
if [[ -x "$ROOT/ci/check_counter_invariant.sh" ]]; then
	grn "runtime invariant check ci/check_counter_invariant.sh is executable"
else
	red "ci/check_counter_invariant.sh missing or not executable"
fi

exit $rc
