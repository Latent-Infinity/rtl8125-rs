#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# devlink health-reporter contract (W4.7).
#
# A devlink instance + a "tx" health reporter surface the existing TX-watchdog
# recovery (ndo_tx_timeout -> reset_work -> r8125_bridge_reopen) through the
# standard devlink-health API. The recovery POLICY stays in the bridge; the cshim
# only wires the kernel devlink objects. Pin that split + the lifecycle, and guard
# against the self-deadlock that bit us once: devlink-health invokes .recover (and
# .test) with the reporter lock HELD, so devlink_health_report() — which re-takes
# that lock — must be called ONLY from the error path (reset_work, no lock held),
# never from inside a reporter op.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
need() { grep -qE -- "$2" "$1" && grn "$3" || red "$3 (missing in ${1#"$ROOT"/}: $2)"; }

DL="$ROOT/src/netdev_bridge_devlink.c"
NETDEV_C="$ROOT/src/netdev_bridge.c"

# 1. devlink instance + reporter lifecycle (alloc/create before register).
need "$DL" 'devlink_alloc\(' "devlink instance allocated"
need "$DL" 'devlink_health_reporter_create\(' "tx health reporter created"
need "$DL" 'devlink_register\(' "devlink instance registered"
need "$DL" 'devlink_health_reporter_destroy\(' "reporter destroyed at teardown"
need "$DL" 'devlink_free\(' "devlink instance freed at teardown"

# 2. The reporter's recover delegates to the existing chip reopen (policy in the
#    bridge), under RTNL.
need "$DL" '\.recover\s*=' "reporter has a .recover op"
need "$DL" 'r8125_bridge_reopen\(' "recover reuses the bridge reopen"
need "$DL" 'rtnl_lock\(\)' "recover takes RTNL"

# A .test op makes the reporter exercisable (devlink health test). It MUST be
# lock-safe: schedule the async reset_work (which reports from process context),
# never call devlink_health_report() synchronously under the held reporter lock.
need "$DL" '\.test\s*=' "reporter has a .test op (devlink health test)"
need "$DL" 'schedule_work\(&b->reset_work\)' ".test schedules async reset_work (no report under the reporter lock)"

# 3. The error is reported from reset_work (process context), and the report path
#    auto-recovers via the reporter.
need "$NETDEV_C" 'r8125_bridge_devlink_report_tx_timeout\(b->devlink' "reset_work reports TX timeout to devlink"
need "$NETDEV_C" 'b->devlink = r8125_bridge_devlink_init\(ndev\)' "devlink registered at netdev register"
need "$NETDEV_C" 'r8125_bridge_devlink_remove\(b->devlink\)' "devlink removed at unregister"

# 4. Self-deadlock guard: devlink_health_report() may appear ONLY once (in
#    r8125_bridge_devlink_report_tx_timeout). Calling it from .recover/.test
#    re-takes the held reporter lock -> recursive deadlock.
n="$(grep -c 'devlink_health_report(' "$DL")"
if [ "$n" = "1" ]; then
	grn "devlink_health_report() called exactly once (error path only, no reporter-op recursion)"
else
	red "devlink_health_report() appears $n times in ${DL#"$ROOT"/} (must be 1; calling it from a reporter op self-deadlocks)"
fi

exit "$rc"
