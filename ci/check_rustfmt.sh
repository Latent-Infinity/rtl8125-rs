#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Rust formatting gate for the kernel module sources.
#
# This project has no Cargo manifest; formatting is checked directly against
# the Rust files Kbuild compiles.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUSTFMT="${RUSTFMT:-rustfmt}"

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

if ! command -v "$RUSTFMT" >/dev/null 2>&1; then
	red "$RUSTFMT not found; install rustfmt for the validated Rust toolchain"
	exit 1
fi

if ! "$RUSTFMT" --edition 2021 --check "$ROOT"/src/*.rs; then
	red "Rust sources are not rustfmt-clean"
	exit 1
fi

grn "Rust sources are rustfmt-clean"
exit 0
