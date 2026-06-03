#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Host-side contract fuzz coverage for queue math and RX length clamps.
# This is intentionally independent of kernel build tooling and keeps
# pure-Rust, non-hardware-sensitive invariants under continuous test.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="$ROOT/tools/driver_contract_fuzz"

if ! command -v cargo >/dev/null 2>&1; then
	echo "FAIL: cargo is required for host contract fuzz checks"
	exit 1
fi

cargo test --manifest-path "$CRATE_DIR/Cargo.toml" --quiet
