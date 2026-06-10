#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# TDD guard for the statistical sweep harness (scripts/cvr_stat_sweep.sh).
# A stats/parse bug — not a driver bug — produced every false "C beats Rust"
# alarm on this rig (single-sample of a bursty metric; a parser that logged the
# literal "receiver" in the retr column; a peer-restart gap that faked TX
# retransmit spikes). This check proves the harness parses and that its pure
# statistics helper is correct, so a regression there can't fabricate a gap.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$ROOT/scripts/cvr_stat_sweep.sh"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

if [[ -f "$SWEEP" ]]; then grn "scripts/cvr_stat_sweep.sh exists"; else red "scripts/cvr_stat_sweep.sh must exist"; fi
if bash -n "$SWEEP"; then grn "cvr_stat_sweep.sh parses under bash"; else red "cvr_stat_sweep.sh must parse"; fi

# The harness must restart the peer server per TCP sample (the artifact fix) and
# sample retransmits as a spike rate, not a single value.
if grep -q 'peer_restart' "$SWEEP" && awk '/^tcp\(\)/,/^}/' "$SWEEP" | grep -q 'peer_restart'; then
	grn "tcp() restarts the peer server per sample (no carry-over TX-retr artifact)"
else
	red "tcp() must restart the peer server per sample"
fi
if grep -q 'spikes=' "$SWEEP"; then
	grn "retransmits reported as a spike rate (bursty-metric honesty)"
else
	red "retransmits must be reported as a spike rate"
fi
# r8169 (the in-tree baseline) must be one of the compared drivers.
if grep -q 'r8169)' "$SWEEP"; then
	grn "in-tree r8169 is included as a comparison driver"
else
	red "the sweep must compare against in-tree r8169"
fi

# Pure-function self-test (median/min/max + spike count). No hardware needed.
if out="$(bash "$SWEEP" --selftest 2>&1)"; then
	grn "stats helper self-test passes"
	printf '%s\n' "$out" | sed 's/^/    /'
else
	red "stats helper self-test failed"
	printf '%s\n' "$out" | sed 's/^/    /'
fi

exit "$rc"
