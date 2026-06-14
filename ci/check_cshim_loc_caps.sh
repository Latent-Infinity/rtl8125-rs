#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate: every cshim translation unit declares a `Hard cap: N LOC`
# line in its file header. This gate parses that line and asserts the
# file's actual line count is at or below it.
#
# Why a per-file cap matters:
#
#   1. The cshim is the only audited C in the project — the unsafe
#      surface our Rust crate trusts. Reviewer attention scales
#      poorly above ~400 LOC per translation unit.
#   2. The cshim is a *bounded* set of net-
#      device-side wrappers, not a place where chip logic accretes.
#      File size growing past its declared cap is the canary for
#      that drift.
#   3. The maintainer consultation cites cshim symbol + LOC
#      totals (docs/PRE_RFC_DOSSIER.md). Keeping each file inside
#      its documented cap means those totals stay honest.
#
# Parsing rule: grab the first integer on any line that contains
# `Hard cap:` (so both "Hard cap: 400 LOC" and "Hard cap: ≤ 400 LOC
# including comments" and "Hard cap: this file stays under 200 LOC"
# all parse to the same cap). Failing to find a cap line is itself a
# FAIL — a new cshim file must opt into the contract.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

shopt -s nullglob
files=("$ROOT"/src/netdev_bridge*.c)
if [[ ${#files[@]} -eq 0 ]]; then
	yel "no cshim translation units found — skipping"
	exit 0
fi

for f in "${files[@]}"; do
	rel="${f#"$ROOT"/}"
	# First "Hard cap:" line; grab the first run of digits on it.
	cap_line=$(grep -m1 'Hard cap:' "$f" 2>/dev/null || true)
	if [[ -z "$cap_line" ]]; then
		red "$rel — missing 'Hard cap: N LOC' marker in header"
		continue
	fi
	cap=$(printf '%s\n' "$cap_line" | grep -oE '[0-9]+' | head -n1)
	if [[ -z "$cap" ]]; then
		red "$rel — 'Hard cap:' line has no integer: $cap_line"
		continue
	fi
	actual=$(wc -l < "$f")
	if (( actual <= cap )); then
		grn "$rel ($actual / $cap LOC)"
	else
		red "$rel exceeds documented cap: $actual > $cap"
	fi
done

exit "$rc"
