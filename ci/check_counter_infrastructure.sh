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
#   2. it has at least one WRITE_ONCE increment site in the cshim sources
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
BRIDGE_H="$ROOT/src/netdev_bridge.h"

for c in "${COUNTERS[@]}"; do
	# 1. struct field present
	if ! grep -qE "^\s*u64\s+$c;" "$INTERNAL"; then
		red "missing u64 $c; field in struct r8125_bridge ($INTERNAL)"
		continue
	fi
	# 2. at least one WRITE_ONCE increment site in either bridge .c
	if ! grep -qE "WRITE_ONCE\(b->$c\b" "$BRIDGE_C" "$OFFLOAD_C"; then
		red "no WRITE_ONCE(b->$c, ...) increment site found"
		continue
	fi
	# 3. counter exposed by snapshot function
	if ! grep -qE "out->$c\s*=\s*READ_ONCE\(b->$c\)" "$BRIDGE_C"; then
		red "$c not copied into r8125_bridge_counters in snapshot"
		continue
	fi
	# 4. counter exposed by ethtool -S
	if ! grep -qE "\"$c\"" "$ETHTOOL_C"; then
		red "$c not advertised via ethtool -S (missing from bridge_ethtool_strings)"
		continue
	fi
	grn "§6.3 counter $c: field + increment + snapshot + ethtool"
done

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
