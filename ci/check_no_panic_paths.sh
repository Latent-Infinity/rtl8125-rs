#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Driver paths must not use panic-style exits. Kernel driver errors need to
# return errno, unwind via RAII guards, or be caught by compile-time layout
# assertions. This gate allows only `const _: () = assert!(...)` layout checks:
# those fail the build rather than panicking at runtime.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

patterns='unwrap[[:space:]]*\(|expect[[:space:]]*\(|panic!|unreachable!|todo!|debug_assert!'

hits=$(grep -RInE "$patterns" "$ROOT/src" --include='*.rs' 2>/dev/null || true)
if [[ -n "$hits" ]]; then
	red "panic-style Rust exits found in driver source"
	printf '%s\n' "$hits"
else
	grn "driver Rust sources avoid unwrap/expect/panic/todo/debug_assert exits"
fi

assert_hits=$(
	grep -RInE '(^|[^[:alnum:]_])assert![[:space:]]*\(' "$ROOT/src" --include='*.rs' 2>/dev/null \
		| grep -vE '^[^:]+:[0-9]+:[[:space:]]*const _:[[:space:]]*\(\)[[:space:]]*=[[:space:]]*assert!' \
		|| true
)
if [[ -n "$assert_hits" ]]; then
	red "runtime assert! found in driver source"
	printf '%s\n' "$assert_hits"
else
	grn "driver Rust sources only use assert! for compile-time layout checks"
fi

exit "$rc"
