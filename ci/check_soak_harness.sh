#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static guard for the long-running soak harnesses. These scripts are
# hardware gates, so a silent traffic generator failure must not report
# a clean driver soak.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

ACTIVE="$ROOT/ci/check_active_soak.sh"
WATCH="$ROOT/scripts/soak_watch.sh"

if bash -n "$ACTIVE" && bash -n "$WATCH"; then
	grn "soak harness scripts parse under bash"
else
	red "soak harness scripts must be valid bash"
fi

if grep -q 'IPERF_CYCLE_SECS' "$ACTIVE" \
   && grep -q 'IPERF_INTERVAL' "$ACTIVE"; then
	grn "active soak exposes iperf cycle and report intervals"
else
	red "active soak must keep the long-run iperf cycle controls"
fi

if grep -q 'IPERF_FAIL_LOG' "$ACTIVE" \
   && grep -q 'iperf_failures' "$ACTIVE" \
   && grep -q 'wait "$IPERF_PID"' "$ACTIVE"; then
	grn "active soak records iperf failures"
else
	red "active soak must fail when the iperf client exits unsuccessfully"
fi

if grep -q 'tx_received_counter' "$ACTIVE" \
   && grep -q 'tx_delta' "$ACTIVE" \
   && grep -q '"$tx_delta" -gt 0' "$ACTIVE"; then
	grn "active soak requires observed TX progress"
else
	red "active soak must not pass without tx_received progress"
fi

if grep -q '\[\[ -v "$override" \]\]' "$WATCH" \
   && grep -q 'no-config' "$WATCH"; then
	grn "soak watcher handles missing host configuration"
else
	red "soak watcher must not abort under set -u for unknown host aliases"
fi

if grep -q 'R8125_IFACE=.*R8125_PATTERN=.*bash -s' "$WATCH" \
   && grep -q 'set -uo pipefail' "$WATCH"; then
	grn "soak watcher remote probe runs under bash"
else
	red "soak watcher remote probe must run under bash, not an implicit login shell"
fi

exit "$rc"
