#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for jumbo frames. Verifies that
# once max_mtu is bumped beyond ETH_DATA_LEN, the chip-side
# RxMaxSize register is sized accordingly. Without this pairing the
# chip would silently truncate frames at the smaller of (RxMaxSize,
# advertised MTU).
#
# Also checks the per-revision rollback path: a ChipInfo field for
# max_mtu so non-jumbo chip revs can disable advertising.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel()  { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

BRIDGE="$ROOT/src/netdev_bridge.c"
HW="$ROOT/src/hw.rs"
REGS="$ROOT/src/regs.rs"

# Read the bridge's max_mtu setting; if still ETH_DATA_LEN, jumbo
# not landed — skip cleanly.
if grep -qE 'ndev->max_mtu\s*=\s*ETH_DATA_LEN' "$BRIDGE"; then
	yel "max_mtu still ETH_DATA_LEN — jumbo not yet advertised"
	exit 0
fi

# 1. JUMBO_*_BYTES constants must be defined in src/regs.rs (or a
#    dedicated module) so review can see the chip cap.
if ! grep -qE '\bJUMBO_(9K|16K)_BYTES\b|\bR8169_RX_BUF_SIZE\b' "$REGS" "$HW" 2>/dev/null; then
	red "missing JUMBO_9K_BYTES / JUMBO_16K_BYTES constant for jumbo size"
else
	grn "jumbo size constant defined"
fi

# 2. hw_start_8125b sets RxMaxSize to a jumbo-sized value when jumbo
#    is enabled. We do NOT enforce the exact value (the design allows
#    either always-16K like r8169 or dynamic-sized); just that it's
#    not still ETH_DATA_LEN.
if awk '/fn hw_start_8125b/,/^}/' "$HW" | grep -qE 'set_rx_max_size\s*\(\s*(regs::)?(JUMBO|R8169_RX_BUF_SIZE|RX_MAX_SIZE_JUMBO|0x4000|16384)'; then
	grn "hw_start_8125b sets RxMaxSize to a jumbo-sized value"
else
	red "hw_start_8125b RxMaxSize not aligned with jumbo-bumped max_mtu"
fi

# 3. Per-revision rollback path. ChipInfo should grow a max_mtu field
#    so a future non-jumbo chip-rev row can disable advertising
#    without code surgery. grep can't match across newlines portably,
#    so awk the struct body and scan for the field.
if awk '/pub\(crate\) struct ChipInfo/,/^}/' "$HW" 2>/dev/null | \
		grep -qE 'max_mtu\s*:'; then
	grn "ChipInfo carries per-revision max_mtu field"
else
	# Soft: this might be tracked elsewhere or not yet refactored.
	yel "ChipInfo has no max_mtu field — consider adding for per-rev rollback"
fi

exit $rc
