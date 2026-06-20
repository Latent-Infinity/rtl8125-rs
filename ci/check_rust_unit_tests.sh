#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Runnable host unit tests for the driver's PURE logic (kernel-free modules).
#
# Unlike the static grep gates (which check code *shape*), these compile the
# kernel-free `crate::layout` math standalone with `rustc --test` and actually
# EXECUTE the assertions - descriptor stride/offset math, V3 hash
# classification, and RSS register packing are verified by value. The
# 2026-06-06 RX-stall regression was exactly a stride/offset bug this catches.
#
# Skips cleanly (exit 0) when rustc is absent so CI without the toolchain is not
# blocked; the kernel build / guest CI still compiles these modules.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

if ! command -v rustc >/dev/null 2>&1; then
	printf '\033[1;33mSKIP\033[0m rustc not found - host unit tests deferred to CI\n'
	exit 0
fi

# Kernel-free, host-testable modules. Each MUST carry #[cfg(test)] tests and
# pass `rustc --test`. Add new pure modules here as they are extracted.
MODULES=("src/layout.rs" "src/led.rs" "src/phy_config.rs" "src/phy_fw.rs" "src/rss.rs" "src/aer.rs" "src/chip_id.rs" "src/tx_offload.rs" "src/ocp.rs" "src/rx_features.rs")
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for m in "${MODULES[@]}"; do
	name="$(basename "$m" .rs)"
	if ! grep -q '#\[cfg(test)\]' "$ROOT/$m"; then
		red "$m is listed as host-testable but has no #[cfg(test)] tests"
		continue
	fi
	bin="$TMP/$name"
	if ! rustc --test --edition 2021 -O "$ROOT/$m" -o "$bin" 2>"$TMP/$name.build"; then
		red "$m failed to compile as a host test"
		sed 's/^/    /' "$TMP/$name.build"
		continue
	fi
	out="$("$bin" 2>&1)"
	passed=$(grep -oE '[0-9]+ passed' <<<"$out" | grep -oE '[0-9]+' | head -1)
	if grep -qE '^test result: ok\.' <<<"$out" && [[ "${passed:-0}" -gt 0 ]]; then
		grn "$m host unit tests: ${passed} passed"
	else
		red "$m host unit tests FAILED (or zero tests ran)"
		sed 's/^/    /' <<<"$out"
	fi
done

exit "$rc"
