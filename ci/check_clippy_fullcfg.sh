#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Full-cfg kernel-Rust Clippy gate (closes check_clippy.sh's blind spot).
#
# check_clippy.sh runs `make CLIPPY=1` with the DEFAULT cfgs against the host's
# installed kernel headers. That never lints the cfg-gated PCI surfaces
# (r8125_pci_pm / _shutdown / _reset / _aer / _runtime_pm) — they only compile
# against a kernel carrying kernel-patches/0001-0005, so a stock-header build
# silently skips them. This gate builds with ALL of those cfgs against such a
# patched tree, so the AER + runtime-PM + PM/shutdown/reset Rust actually gets
# linted. (This is how the 2026-06-18 batch of latent `# Safety`-on-safe-fn
# warnings was found — the default gate had reported "clean".)
#
# Tree selection: $R8125_FULL_CLIPPY_KDIR if set, else a couple of known
# locations. A tree qualifies only if its rust/kernel/pci.rs carries the patched
# trait methods (error_detected + runtime_idle). If none is found the gate SKIPs
# with a loud note (so "clippy clean" from the default gate is not mistaken for
# full coverage). Set R8125_SKIP_FULL_CLIPPY=1 to skip during fast iteration.
#
# MSRV note: a patched dev tree may pin clippy msrv below the validated toolchain
# (rustc-1.93). `incompatible_msrv` is therefore allowed here — the driver is
# only ever built with the 1.93 toolchain, so APIs stabilised above the tree's
# nominal msrv are fine in practice (see docs/VALIDATION_REPORT.md).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

[[ "${R8125_SKIP_FULL_CLIPPY:-0}" == "1" ]] && { yel "full-cfg Clippy skipped (R8125_SKIP_FULL_CLIPPY=1)"; exit 0; }

if ! command -v rustc-1.93 >/dev/null 2>&1 || [[ ! -x /usr/lib/rust-1.93/bin/clippy-driver ]]; then
	yel "rustc-1.93 / clippy-driver-1.93 not found — full-cfg Clippy skipped"
	exit 0
fi

patched() { [[ -f "$1/rust/kernel/pci.rs" ]] && grep -q 'fn error_detected' "$1/rust/kernel/pci.rs" 2>/dev/null \
	&& grep -q 'fn runtime_idle' "$1/rust/kernel/pci.rs" 2>/dev/null; }

KDIR=""
for cand in "${R8125_FULL_CLIPPY_KDIR:-}" /home/firestrand/kbuild/linux-7.0.0; do
	[[ -n "$cand" ]] && patched "$cand" && { KDIR="$cand"; break; }
done
if [[ -z "$KDIR" ]]; then
	yel "no AER/runtime-PM-patched kernel tree found — full-cfg PCI Clippy NOT run."
	yel "  The cfg-gated PCI Rust (AER / runtime-PM / PM / shutdown / reset) was"
	yel "  NOT linted. Set R8125_FULL_CLIPPY_KDIR to a tree with kernel-patches 0001-0005."
	exit 0
fi
grn "full-cfg Clippy tree: $KDIR (carries patches 0001-0005)"

cd "$ROOT"
make clean KDIR="$KDIR" >/dev/null 2>&1
LOG=$(mktemp -t clippy-fullcfg-XXXXXX.log)
trap "rm -f '$LOG'" EXIT

if ! make CLIPPY=1 KDIR="$KDIR" RUSTC=rustc-1.93 BINDGEN=bindgen \
	CLIPPY_DRIVER=/usr/lib/rust-1.93/bin/clippy-driver \
	KRUSTFLAGS="-A clippy::incompatible_msrv" \
	PCI_PM=1 SHUTDOWN=1 RESET=1 AER=1 RUNTIME_PM=1 >"$LOG" 2>&1; then
	red "full-cfg Clippy run failed (build error or hard-deny lint)"
	tail -40 "$LOG" >&2
	exit 1
fi

# Same warning detector as check_clippy.sh; exclude the benign env notes
# (objtool frame-pointer on the KASAN ctor, and the clippy "compiler differs"
# banner that the kbuild rust wrapper prints when clippy-driver != the kernel cc).
warns=$(grep -nE '^warning:|^[^:]*:[0-9]+:[0-9]+: warning:' "$LOG" \
	| grep -vEi 'compiler differs|objtool|frame pointer' || true)
if [[ -n "$warns" ]]; then
	red "full-cfg Clippy emitted warning(s) in the cfg-gated PCI code:"
	printf '%s\n' "$warns" | head -20 >&2
	exit 1
fi
grn "full-cfg Clippy clean (PM + shutdown + reset + AER + runtime-PM linted)"
exit 0
