#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Robustness-requirement contract for the netdevice path. These are standard
# defensive features every in-tree NIC driver (r8169) has; they were found
# missing in a 2026-06 pre-upstream audit and must not regress:
#   1. invalid hardware MAC -> random MAC fallback (else the iface can't be
#      brought up: EADDRNOTAVAIL on an all-zero MAC).
#   2. ndo_tx_timeout watchdog + deferred reset_work -> r8125_bridge_reopen
#      (else a wedged TX ring never recovers). Reset is deferred to a work item
#      because ndo_tx_timeout runs in atomic (timer) context.
#   3. ndo_get_stats64 folding the drop counters into the standard stats (else
#      `ip -s link` always reports 0 drops/errors).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
C="$ROOT/src/netdev_bridge.c"
H="$ROOT/src/netdev_bridge_internal.h"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

# 1. MAC fallback.
alloc_body=$(awk '/struct net_device \*r8125_bridge_alloc\(/,/^}/' "$C")
if grep -qE 'is_valid_ether_addr\(mac\)' <<<"$alloc_body" &&
	grep -qE 'eth_hw_addr_random\(ndev\)' <<<"$alloc_body" &&
	grep -qE 'eth_hw_addr_set\(ndev, mac\)' <<<"$alloc_body"; then
	grn "alloc validates the hardware MAC and falls back to a random address"
else
	red "r8125_bridge_alloc must use is_valid_ether_addr + eth_hw_addr_random fallback"
fi

# 2. TX watchdog + deferred reset.
if grep -qE '\.ndo_tx_timeout\s*=\s*bridge_ndo_tx_timeout' "$C" &&
	grep -qE 'watchdog_timeo\s*=' "$C" &&
	grep -qE 'struct work_struct reset_work' "$H" &&
	grep -qE 'INIT_WORK\(&b->reset_work' "$C" &&
	grep -qE 'schedule_work\(&b->reset_work\)' "$C" &&
	grep -qE 'cancel_work_sync\(&b->reset_work\)' "$C"; then
	grn "ndo_tx_timeout schedules a reset_work (armed watchdog_timeo, cancel on free)"
else
	red "TX watchdog must be wired: ndo_tx_timeout + watchdog_timeo + reset_work (INIT/schedule/cancel_work_sync)"
fi

# reset_work must do the real recovery under RTNL via r8125_bridge_reopen.
reset_body=$(awk '/static void bridge_reset_work\(/,/^}/' "$C")
if grep -qE 'rtnl_lock\(\)' <<<"$reset_body" &&
	grep -qE 'r8125_bridge_reopen\(ndev\)' <<<"$reset_body"; then
	grn "reset_work recovers the chip under RTNL (r8125_bridge_reopen)"
else
	red "bridge_reset_work must rtnl_lock + r8125_bridge_reopen"
fi

# 3. get_stats64 folds drop counters.
stats_body=$(awk '/static void bridge_ndo_get_stats64\(/,/^}/' "$C")
if grep -qE '\.ndo_get_stats64\s*=\s*bridge_ndo_get_stats64' "$C" &&
	grep -qE 'dev_get_tstats64\(ndev, stats\)' <<<"$stats_body" &&
	grep -qE 'rx_dropped \+= c\.rx_dropped_error' <<<"$stats_body" &&
	grep -qE 'tx_dropped \+= c\.tx_dropped_error' <<<"$stats_body"; then
	grn "ndo_get_stats64 folds rx/tx drop counters into standard stats"
else
	red "ndo_get_stats64 must call dev_get_tstats64 and fold rx/tx_dropped_error"
fi

exit "$rc"
