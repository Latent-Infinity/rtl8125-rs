#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Cache-padding convention check (RUST_STANDARDS.md §15.2 / §18 TODO).
#
# Atomics that are mutated from independent execution contexts (xmit
# BH-context vs NAPI softirq vs IRQ handler) must not share a cache
# line — false sharing serialises the contexts. The convention in this
# crate is to wrap any such atomic in `CachePadded<...>`. Arrays of
# atomics (the per-slot TX-shadow ring) are deliberately not padded —
# they're indexed by slot, and slots used together (xmit head vs
# reaper tail) are typically far apart in the 256-slot ring.
#
# This script scans `struct NetdevState` (the only cross-context state
# in the driver today) and enforces the rule:
#
#   Any non-array `Atomic*` field must either:
#     - be wrapped in `CachePadded<...>`, OR
#     - have a `// NOT-PADDED:` annotation on the preceding line
#       documenting why padding is unnecessary
#
# Adding more cross-context structs in the future: extend `STRUCTS`
# below and the regex coverage will follow.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

# (file, struct-name) pairs to scan.
STRUCTS=(
	"src/netdev.rs|NetdevState"
)

for entry in "${STRUCTS[@]}"; do
	file="${entry%%|*}"
	name="${entry##*|}"
	full="$ROOT/$file"

	if [[ ! -f "$full" ]]; then
		red "$file not found"
		continue
	fi

	# Extract the body between `pub(crate) struct $name {` and the
	# closing `}` at column 1. `awk` keeps line numbers so the error
	# message can point back into the source.
	body=$(awk -v target="struct ${name} {" '
		$0 ~ target { in_body=1; start=NR; next }
		in_body && /^\}/ { exit }
		in_body { printf "%d:%s\n", NR, $0 }
	' "$full")

	if [[ -z "$body" ]]; then
		red "could not find struct $name in $file"
		continue
	fi

	violations=0
	# Keep a sliding window of recent non-blank lines so a multi-line
	# preceding comment block can carry the `// NOT-PADDED:` annotation
	# without forcing the marker onto the immediately-prior line.
	declare -a recent=()
	while IFS= read -r line; do
		lineno="${line%%:*}"
		content="${line#*:}"
		# Detect non-array AtomicXxx field declarations:
		#   foo: AtomicU64,
		#   pub(crate) bar: AtomicPtr<...>,
		# but NOT:
		#   foo: [AtomicU64; N],   (array — slot-indexed, deliberate)
		#   foo: CachePadded<AtomicU64>,  (already padded)
		if echo "$content" | grep -qE ':\s*Atomic[A-Za-z0-9_]+(<[^>]*>)?\s*,'; then
			# Walk back through recent lines looking for a `NOT-PADDED`
			# annotation. We stop at the first non-comment line because
			# the annotation must belong to THIS field's doc/comment block.
			annotated=0
			for prev in "${recent[@]}"; do
				if echo "$prev" | grep -qE '//\s*NOT-PADDED:'; then
					annotated=1
					break
				fi
				# Bail out if we leave the field's comment block.
				echo "$prev" | grep -qE '^\s*(//|///|#\[)' || break
			done
			if [[ "$annotated" -eq 1 ]]; then
				recent=()
				continue
			fi
			red "$file:$lineno  unpadded atomic in $name (wrap in CachePadded or add a '// NOT-PADDED:' annotation):"
			printf '       %s\n' "$content" >&2
			violations=$((violations + 1))
		fi
		# Push line onto front of recent[] (so [0] = immediately prior).
		if [[ -n "${content// /}" ]]; then
			recent=("$content" "${recent[@]}")
			# Cap the window at 8 lines — annotations should be close.
			if [[ ${#recent[@]} -gt 8 ]]; then
				unset 'recent[8]'
			fi
		fi
	done <<< "$body"

	if [[ "$violations" -eq 0 ]]; then
		grn "$name in $file: all non-array atomics are CachePadded or annotated"
	fi
done

exit $rc
