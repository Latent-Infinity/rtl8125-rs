#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# check_checkpatch.sh - run scripts/checkpatch.pl against the cshim TUs.
#
# A clean checkpatch run is the kernel community's minimum style bar
# for netdev submissions (see docs/UPSTREAM_REVIEW.md). This gate runs
# it locally so regressions get caught at PR-review time, not by the
# netdev maintainer.
#
# Skips cleanly when no kernel headers tree is installed (so the gate
# stays portable across CI hosts that don't carry the kernel toolchain).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

CHECKPATCH=""
for hdrs in "/usr/src/linux-headers-$(uname -r)" /usr/src/linux-headers-*/; do
	if [[ -r "$hdrs/scripts/checkpatch.pl" ]]; then
		CHECKPATCH="$hdrs/scripts/checkpatch.pl"
		break
	fi
done

if [[ -z "$CHECKPATCH" ]]; then
	yel "SKIP checkpatch: no kernel-headers checkpatch.pl found"
	exit 0
fi

OUT="$(mktemp -t r8125-checkpatch.XXXXXX)"
trap 'rm -f "$OUT"' EXIT

CSHIM=(
	"$ROOT/src/netdev_bridge.c"
	"$ROOT/src/netdev_bridge.h"
	"$ROOT/src/netdev_bridge_offload.c"
	"$ROOT/src/netdev_bridge_counters.c"
	"$ROOT/src/netdev_bridge_ethtool.c"
	"$ROOT/src/netdev_bridge_phy.c"
	"$ROOT/src/netdev_bridge_rx_pool.c"
	"$ROOT/src/netdev_bridge_internal.h"
)

bad=0
for f in "${CSHIM[@]}"; do
	if [[ ! -f "$f" ]]; then
		red "FAIL missing cshim file: $f"
		bad=$((bad + 1))
		continue
	fi
	if ! perl "$CHECKPATCH" --no-tree --terse --no-summary --file "$f" >"$OUT" 2>&1; then
		# Non-zero exit means warnings or errors. Capture and tally.
		count=$(wc -l < "$OUT")
		(( count > 0 )) || count=1
		bad=$((bad + count))
		red "FAIL $f: $count warnings/errors"
		head -5 "$OUT" | sed 's/^/    /'
	fi
done

if (( bad == 0 )); then
	grn "PASS checkpatch clean on cshim (${#CSHIM[@]} files)"
	exit 0
else
	red "FAIL checkpatch reported $bad warnings/errors total"
	exit 1
fi
