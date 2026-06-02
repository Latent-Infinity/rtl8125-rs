#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Shared Kbuild static-analyzer runner for sparse/smatch gates.
#
# The cshim is built by Kbuild alongside the Rust module, so analyzer
# coverage must use Kbuild's C=2 path rather than direct compiler calls.
# Hosts without the requested analyzer or validated Rust toolchain skip
# cleanly; hosts with them fail on any analyzer warning.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANALYZER="${1:?usage: check_kbuild_static_analyzer.sh <sparse|smatch>}"
KDIR="${KDIR:-/lib/modules/$(uname -r)/build}"
RUSTC="${RUSTC:-rustc-1.93}"
BINDGEN="${BINDGEN:-bindgen}"
CC="${CC:-x86_64-linux-gnu-gcc}"

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

case "$ANALYZER" in
sparse)
	CHECK_CMD="${SPARSE_CHECK:-sparse}"
	EXTRA_CF="${SPARSE_CF:--D__CHECK_ENDIAN__}"
	DIAG_RE='(^|[[:space:]])(warning:|error:)'
	;;
smatch)
	CHECK_CMD="${SMATCH_CHECK:-smatch -p=kernel}"
	EXTRA_CF="${SMATCH_CF:-}"
	DIAG_RE='(^|[[:space:]])(warn:|warning:|error:)'
	;;
*)
	red "unknown analyzer '$ANALYZER'"
	exit 1
	;;
esac
TOOL="${CHECK_CMD%% *}"

if [[ ! -d "$KDIR" || ! -r "$KDIR/Makefile" ]]; then
	yel "$ANALYZER: kernel build tree missing at KDIR=$KDIR"
	exit 0
fi
if ! command -v "$TOOL" >/dev/null 2>&1; then
	yel "$ANALYZER: '$TOOL' binary not found"
	exit 0
fi
if ! command -v "$RUSTC" >/dev/null 2>&1; then
	yel "$ANALYZER: $RUSTC not found; kernel-Rust module build unavailable"
	exit 0
fi
if ! command -v "$BINDGEN" >/dev/null 2>&1; then
	yel "$ANALYZER: $BINDGEN not found; kernel-Rust module build unavailable"
	exit 0
fi
if ! command -v "$CC" >/dev/null 2>&1; then
	yel "$ANALYZER: $CC not found; kernel C build unavailable"
	exit 0
fi

# Force a fresh analyzer run. Kbuild will otherwise skip unchanged objects and
# silently hide diagnostics behind stale .o files.
make -C "$KDIR" M="$ROOT/src" clean >/dev/null 2>&1 || true

LOG="$(mktemp -t "r8125-${ANALYZER}.XXXXXX.log")"
DIAGS="$(mktemp -t "r8125-${ANALYZER}-diags.XXXXXX.log")"
trap 'rm -f "$LOG" "$DIAGS"' EXIT

MAKE_ARGS=(
	-C "$KDIR"
	M="$ROOT/src"
	RUSTC="$RUSTC"
	BINDGEN="$BINDGEN"
	CC="$CC"
	C=2
	CHECK="$CHECK_CMD"
	modules
)

if [[ -n "$EXTRA_CF" ]]; then
	MAKE_ARGS+=(CF="$EXTRA_CF")
fi

if ! make "${MAKE_ARGS[@]}" >"$LOG" 2>&1; then
	red "$ANALYZER run failed"
	tail -50 "$LOG" >&2
	exit 1
fi

# Collect every analyzer diagnostic, then keep only those originating in
# OUR module sources. Dropped as non-driver noise:
#   * the benign "compiler differs from the one used to build the kernel"
#     Kbuild warning (clang-built kernel vs the gcc we check with);
#   * diagnostics from the kernel build tree itself (headers under
#     /usr/src/linux-headers... or /lib/modules/.../build), e.g. sparse/smatch
#     front-end limitations on modern `container_of()` static assertions.
# Only $ROOT/src diagnostics gate the build.
grep -nEi "$DIAG_RE" "$LOG" >"$DIAGS" || true
SRC_DIAGS="$(grep -viE 'the compiler differs from the one used to build the kernel' "$DIAGS" \
	| grep -vE '/usr/src/linux-headers|/lib/modules/[^[:space:]]+/build' || true)"

if [[ -n "$SRC_DIAGS" ]]; then
	red "$ANALYZER emitted diagnostics in module sources:"
	printf '%s\n' "$SRC_DIAGS" | head -30 >&2
	exit 1
fi

n_ignored=$(wc -l < "$DIAGS")
grn "$ANALYZER clean through Kbuild C=2 (module src/ only; ignored ${n_ignored} kernel-tree/build-noise diagnostics)"
exit 0
