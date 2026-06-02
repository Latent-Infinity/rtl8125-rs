#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# The r8125_bridge_* cshim helpers are module-private entry points used by
# the Rust object linked into the same .ko. They must not be exported into
# the global kernel symbol namespace unless an upstream reviewer asks for a
# real inter-module API.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

# Use grep (always present); rg is not installed everywhere and a missing
# binary would silently pass this gate.
hits="$(grep -rnE 'EXPORT_SYMBOL(_GPL)?\([[:space:]]*r8125_bridge_' "$ROOT/src" || true)"
if [[ -n "$hits" ]]; then
	red "module-private r8125_bridge_* helpers leaked via EXPORT_SYMBOL"
	printf '%s\n' "$hits" >&2
	exit 1
fi

grn "no r8125_bridge_* helpers exported to the global kernel symbol table"
exit 0
