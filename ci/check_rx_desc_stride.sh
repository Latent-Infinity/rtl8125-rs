#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RX descriptor stride agreement gate.
#
# WHY THIS EXISTS (2026-06-06 regression): the RX ring is allocated as
# `RxDescriptor` (32-byte max-V3-width storage), but the chip's *actual*
# descriptor stride depends on the active format (16B legacy, 32B V3) and is
# the same stride `desc_publish_own` writes at via `format.descriptor_len()`.
# A typed `*mut RxDescriptor` indexed by `.add(idx)` strides 32B unconditionally
# - so on the legacy default the reaper read at idx*32 while the chip wrote at
# idx*16, silently misaligning RX after slot 0 (RX stalled at 18 packets, TX
# fine, no oops). The three RX descriptor accessors MUST all derive their stride
# from `format.descriptor_len()` so they can never disagree with each other or
# the hardware.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UB="$ROOT/src/unsafe_boundary.rs"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

# Writers stride directly by format.descriptor_len().
for fn in desc_write_rx desc_publish_own; do
	body=$(awk "/pub\(crate\) fn $fn\(/,/^}/" "$UB")
	if [[ -z "$body" ]]; then
		red "$fn: not found in unsafe_boundary.rs"
		continue
	fi
	if ! grep -q "format: RxDescFormat" <<<"$body"; then
		red "$fn: missing 'format: RxDescFormat' parameter (stride must be format-derived)"
	else
		grn "$fn: takes format: RxDescFormat"
	fi
	if ! grep -q "format.descriptor_len()" <<<"$body"; then
		red "$fn: does not stride by format.descriptor_len()"
	else
		grn "$fn: strides by format.descriptor_len()"
	fi
	if grep -qE "ring:\s*\*mut RxDescriptor" <<<"$body"; then
		red "$fn: takes 'ring: *mut RxDescriptor' - typed 32B stride; use *mut u8 + format"
	else
		grn "$fn: ring pointer is byte-addressed (*mut u8)"
	fi
done

# Readers stride by the precomputed RxParse, whose stride MUST be set from
# RxDescFormat::descriptor_len() in RxParse::new - the single source of truth.
# RxParse + the format math now live in the host-tested src/layout.rs (re-exported
# by src/ring.rs); the stride invariant is also covered by a runtime unit test
# (ci/check_rust_unit_tests.sh: rxparse_stride_matches_descriptor_len).
LAYOUT="$ROOT/src/layout.rs"
parse_new=$(awk '/pub\(crate\) fn new\(format: RxDescFormat\)/,/^    }/' "$LAYOUT")
if grep -q "stride: format.descriptor_len()" <<<"$parse_new"; then
	grn "RxParse::new: stride derived from format.descriptor_len()"
else
	red "RxParse::new: stride must be set from format.descriptor_len()"
fi
for fn in rx_read_opts1 rx_read_completion; do
	body=$(awk "/pub\(crate\) fn $fn\(/,/^}/" "$UB")
	if [[ -z "$body" ]]; then
		red "$fn: not found in unsafe_boundary.rs"
		continue
	fi
	if grep -q "parse.stride" <<<"$body"; then
		grn "$fn: strides by parse.stride (RxParse single source)"
	else
		red "$fn: must index by parse.stride, not a hardcoded/typed stride"
	fi
	if grep -qE "ring:\s*\*mut RxDescriptor" <<<"$body"; then
		red "$fn: takes 'ring: *mut RxDescriptor' - typed 32B stride; use *mut u8 + RxParse"
	else
		grn "$fn: ring pointer is byte-addressed (*mut u8)"
	fi
done

exit $rc
