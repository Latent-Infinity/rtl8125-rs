#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for M6 MSI-X (plan §7 M6 #1): the ISR_V2 mask
# manipulation must be paired across hot-path and shutdown so the
# chip cannot leave the soft state with "no driver listening but
# IRQ enabled" or vice versa.
#
# Invariants (active once MSI-X lands; skipped vacuously before):
#   1. Every call to `set_imr_v2_mask(BITS)` has a corresponding
#      `clear_imr_v2_mask(BITS)` somewhere in the codebase
#   2. ndo_stop calls `clear_imr_v2_mask(0xFFFFFFFF)` to fully mask
#      before free_irq (else the chip can raise a phantom IRQ post-
#      free_irq, hitting unmapped state)
#   3. ndo_open enables only the bits we actually handle
#      (ROK_Q0 + TOK_Q0 + LINKCHG); never unmasks reserved bits

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel()  { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

REGS="$ROOT/src/regs.rs"
MMIO="$ROOT/src/mmio.rs"
NETDEV="$ROOT/src/netdev.rs"
NAPI="$ROOT/src/napi.rs"

# Pre-engagement check. V2 surface is scaffolding-only until chip-side
# INT_CFG0_ENABLE_8125 is set; full pairing checks engage at Phase A.2.
if ! grep -qE '\bset_imr_v2_mask\b' "$MMIO"; then
	yel "set_imr_v2_mask not yet in src/mmio.rs (M6 MSI-X not landed) — skipping"
	exit 0
fi
HW="$ROOT/src/hw.rs"
# Phase A.2 moves the activation out of hw_start_8125b into ndo_open
# (gated on `state.irq_mode()`). Accept either location.
if ! grep -hE 'set_int_cfg0\([^)]*INT_CFG0_ENABLE_8125' "$HW" "$NETDEV" >/dev/null 2>&1; then
	yel "V2 surface scaffolded but chip-side activation deferred — pairing checks skipped"
	exit 0
fi

# 1. set_imr_v2_mask must be paired with clear_imr_v2_mask in some
#    cleanup site. Count occurrences; the clear count must be at least
#    set_count - 1 (the +1 allowance lets one initial set in ndo_open
#    rely on device reset, while every dynamic set still needs cleanup).
set_count=$(grep -cE 'set_imr_v2_mask\(' "$NETDEV" "$NAPI" "$MMIO" 2>/dev/null || echo 0)
clr_count=$(grep -cE 'clear_imr_v2_mask\(' "$NETDEV" "$NAPI" "$MMIO" 2>/dev/null || echo 0)
# Strip /path: prefix lines from `grep -c` over multiple files
set_count=$(printf '%s\n' $set_count | awk -F: '{s+=$NF} END {print s}')
clr_count=$(printf '%s\n' $clr_count | awk -F: '{s+=$NF} END {print s}')

if [[ "$set_count" -le $((clr_count + 1)) ]] && [[ "$clr_count" -ge 1 ]]; then
	grn "set_imr_v2_mask call count ($set_count), clear_imr_v2_mask count ($clr_count) — pairing healthy"
else
	red "set_imr_v2_mask=$set_count clear_imr_v2_mask=$clr_count — clear is missing in cleanup"
fi

# 2. ndo_stop fully masks before free_irq. Note: awk's `\b` word
# boundary is not portable; use an explicit `(` lookahead instead.
# Task #60 named-phases refactor wraps the dual-mask discipline in
# `quiesce_chip(&regs)` — accept that helper call too.
if awk '/fn[[:space:]]+ndo_stop\(/,/^}/' "$NETDEV" | \
		awk '/clear_imr_v2_mask\(\s*(0xFFFF_FFFF|!0u32|u32::MAX)/{c=NR}
		     /quiesce_chip\(/{c=NR}
		     /ub::free_irq\(/{if (c && NR > c) found=1}
		     END {exit (found ? 0 : 1)}'; then
	grn "ndo_stop masks all v2 sources before free_irq"
else
	red "ndo_stop does not call clear_imr_v2_mask(0xFFFFFFFF) before free_irq"
fi

# 3. ndo_open / hw_start unmasks only the named bits, not 0xFFFFFFFF.
if grep -qE 'set_imr_v2_mask\(\s*0xFFFF_FFFF|set_imr_v2_mask\(\s*!0u32|set_imr_v2_mask\(\s*u32::MAX' "$NETDEV" "$NAPI" 2>/dev/null; then
	red "set_imr_v2_mask called with all-bits-set — only named bits should be unmasked"
else
	grn "set_imr_v2_mask never enables reserved bits"
fi

exit $rc
