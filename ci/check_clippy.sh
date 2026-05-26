#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Kernel-Rust Clippy gate (RUST_STANDARDS.md §18, plan §6.1/§11).
#
# Runs `make CLIPPY=1` and fails on any clippy/rustc warning. This is
# the in-tree kernel-build Clippy — NOT `cargo clippy` (the project
# has no Cargo.toml and Cargo cannot build kernel modules).
#
# The kernel build's CLIPPY=1 swaps `RUSTC` for `clippy-driver` for the
# Rust translation unit (the composite-module's `*_main.o` step). Any
# clippy lint emits a `warning: ...` line; this script fails on the
# first one.
#
# Toolchain requirement: the validated kernel-Rust dev toolchain
# (rustc-1.93 + clippy-driver-1.93 + bindgen 0.72.1 — see
# docs/VALIDATION_REPORT.md). On hosts without that toolchain this
# script is skipped, not failed.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel()  { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

# Skip cleanly if the validated toolchain isn't installed.
if ! command -v rustc-1.93 >/dev/null 2>&1; then
	yel "rustc-1.93 not found — Clippy gate skipped (host lacks validated toolchain)"
	exit 0
fi
if [[ ! -x /usr/lib/rust-1.93/bin/clippy-driver ]]; then
	yel "clippy-driver-1.93 not found — Clippy gate skipped"
	exit 0
fi

# Force a clean Clippy run — partial-build caches can hide previously-
# emitted warnings. `make clean` removes only this driver's outputs.
cd "$ROOT"
make clean >/dev/null 2>&1

# Capture stderr+stdout. Kbuild prints all rustc/clippy diagnostics to
# stderr; we merge for grepping. Drop ANSI escapes if the terminal added
# them.
LOG=$(mktemp -t clippy-check-XXXXXX.log)
trap "rm -f '$LOG'" EXIT

if ! make CLIPPY=1 >"$LOG" 2>&1; then
	red "kernel-build Clippy run failed (build error or hard-deny lint)"
	tail -50 "$LOG" >&2
	exit 1
fi

# Any `warning: ` line from rustc/clippy is a §18 violation. Kbuild itself
# does not emit `warning:`-prefixed lines for build progress, only the
# Rust frontend does — so a grep is reliable. We exclude kbuild's own
# `make[1]: warning:` (subshell warnings) and the BTF tool's optional
# "WARN:" / "warning -" formats which use different prefixes.
warn_count=$(grep -cE '^warning:|^[^:]*:[0-9]+:[0-9]+: warning:' "$LOG" || true)
if [[ "$warn_count" -gt 0 ]]; then
	red "kernel-build Clippy emitted $warn_count warning(s) — §18 violation"
	grep -nE '^warning:|^[^:]*:[0-9]+:[0-9]+: warning:' "$LOG" | head -20 >&2
	exit 1
fi

grn "kernel-build Clippy clean (no warnings)"
exit 0
