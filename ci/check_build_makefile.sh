#!/usr/bin/env bash
# Static checks for the out-of-tree module build wrapper. The real proof is
# `make`; these guards keep the warning-free/BTF path from regressing silently.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
ok(){ printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
bad(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }

MAKEFILE=Makefile

grep -q 'CC      := x86_64-linux-gnu-gcc' "$MAKEFILE" \
  && grep -q 'ifeq ($(origin CC),default)' "$MAKEFILE" \
  && ok "Makefile defaults to kernel-recorded GCC triplet without blocking overrides" \
  || bad "Makefile must avoid Kbuild compiler mismatch warning while preserving explicit CC overrides"

grep -q 'CONFIG_DEBUG_INFO_BTF_MODULES= modules' "$MAKEFILE" \
  && grep -q 'scripts/gen-btf.sh' "$MAKEFILE" \
  && grep -q -- '--btf_base "$(BTF_BASE)"' "$MAKEFILE" \
  && ok "Makefile uses explicit post-link BTF generation for external module" \
  || bad "Makefile must avoid Kbuild's missing-vmlinux BTF skip and run gen-btf.sh explicitly"

grep -q 'PAHOLE_FLAGS ?= --lang_exclude=Rust' "$MAKEFILE" \
  && ok "pahole excludes Rust DWARF units for module BTF" \
  || bad "pahole must exclude Rust DWARF units until its Rust tag support is usable here"

exit $fail
