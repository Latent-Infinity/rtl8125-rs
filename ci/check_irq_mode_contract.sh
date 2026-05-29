#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# IRQ-mode contract gate (M6 #1 Phase A.2).
#
# `IrqMode` is the single source of truth for whether the driver uses
# legacy INTx registers or the ISR_V2 / IMR_V2 surface. This script keeps
# the probe-selected mode, request_irq flags, chip-side V2 activation, IRQ
# handler, and NAPI re-arm path from drifting apart.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

PCI="$ROOT/src/pci.rs"
NETDEV="$ROOT/src/netdev.rs"
NAPI="$ROOT/src/napi.rs"
UB="$ROOT/src/unsafe_boundary.rs"
REGS="$ROOT/src/regs.rs"

if grep -qE 'enum[[:space:]]+IrqMode' "$NETDEV" &&
   grep -qE 'Intx[[:space:]]*=' "$NETDEV" &&
   grep -qE 'Msi[[:space:]]*=' "$NETDEV" &&
   # Task #59 split: AtomicU8 mode field lives on `IrqState` as `mode`
   # (was `irq_mode` on flat `NetdevState`). Accept either.
   grep -qE '(irq_mode|mode):[[:space:]]*AtomicU8' "$NETDEV" &&
   grep -qE 'fn[[:space:]]+irq_mode\(&self\)[[:space:]]*->[[:space:]]*IrqMode' "$NETDEV"; then
	grn "NetdevState stores a probe-selected IrqMode"
else
	red "NetdevState is missing the IrqMode enum, AtomicU8 field, or accessor"
fi

# Probe wires `AtomicU8::new(mode as u8)` for IrqMode storage. After #59
# that call lives inside `IrqState::new(num, mode)` in netdev.rs rather
# than directly in pci.rs; accept either location plus the substruct
# construction in probe.
if (grep -qE 'AtomicU8::new\(irq_mode[[:space:]]+as[[:space:]]+u8\)' "$PCI" \
    || grep -qE 'AtomicU8::new\(mode[[:space:]]+as[[:space:]]+u8\)' "$NETDEV") &&
   grep -qE 'IrqType::MsiX' "$PCI" &&
   grep -qE 'IrqType::Msi' "$PCI" &&
   grep -qE 'IrqType::Intx' "$PCI" &&
   grep -qE 'pci_irq_vector\(pdev,[[:space:]]*0\)' "$PCI"; then
	grn "probe allocates MSI/MSI-X with INTx fallback and stores IrqMode"
else
	red "probe does not allocate/store IRQ mode with MSI/MSI-X plus INTx fallback"
fi

if grep -qE 'request_irq\([^,]+,[^,]+,[^,]+,[[:space:]]*irq_flags\)' "$NETDEV" &&
   awk '/let irq_flags = match state\.irq_mode\(\)/,/};/' "$NETDEV" | \
		grep -qE 'IrqMode::Intx[[:space:]]*=>[[:space:]]*ub::IRQF_SHARED' &&
   awk '/let irq_flags = match state\.irq_mode\(\)/,/};/' "$NETDEV" | \
		grep -qE 'IrqMode::Msi[[:space:]]*=>[[:space:]]*0'; then
	grn "request_irq flags are mode-specific (INTx shared, MSI unshared)"
else
	red "request_irq flags are not derived from IrqMode"
fi

if awk '/if state\.irq_mode\(\) != IrqMode::Intx/,/^    }/' "$NETDEV" | \
		grep -qE 'set_int_cfg0\(regs::INT_CFG0_ENABLE_8125\)'; then
	grn "INT_CFG0_ENABLE_8125 is gated off for INTx fallback"
else
	red "INT_CFG0_ENABLE_8125 is not guarded by IrqMode::Intx fallback"
fi

handler=$(awk '/fn raw_irq_handler/,/^}/' "$NETDEV")
if echo "$handler" | grep -qE 'IrqMode::Intx[[:space:]]*=>[[:space:]]*regs\.isr\(\)' &&
   echo "$handler" | grep -qE 'IrqMode::Msi[[:space:]]*=>[[:space:]]*regs\.isr_v2\(\)' &&
   echo "$handler" | grep -qE 'regs\.ack_isr\(status\)' &&
   echo "$handler" | grep -qE 'regs\.set_imr\(0\)' &&
   echo "$handler" | grep -qE 'regs\.ack_isr_v2\(status\)' &&
   echo "$handler" | grep -qE 'regs\.clear_imr_v2_mask\(0xFFFF_FFFF\)'; then
	grn "raw IRQ handler reads, acks, and masks the IrqMode-selected surface"
else
	red "raw IRQ handler does not fully branch on IrqMode"
fi

rearm=$(awk '/fn rearm_irq_baseline/,/^}/' "$NAPI")
if echo "$rearm" | grep -qE 'IrqMode::Intx[[:space:]]*=>.*set_imr\(regs::INTR_M4_BASELINE\)' &&
   echo "$rearm" | grep -qE 'IrqMode::Msi[[:space:]]*=>.*set_imr_v2_mask\(regs::INTR_V2_M4_BASELINE\)'; then
	grn "NAPI re-arm uses the IrqMode-selected interrupt mask"
else
	red "NAPI re-arm does not branch on IrqMode"
fi

if grep -qE 'pub\(crate\)[[:space:]]+const[[:space:]]+INT_CFG0_ENABLE_8125:[[:space:]]*u8[[:space:]]*=[[:space:]]*0x01;' "$REGS"; then
	grn "INT_CFG0_ENABLE_8125 uses the reviewed BIT(0) value"
else
	red "INT_CFG0_ENABLE_8125 must stay at BIT(0) (0x01)"
fi

request_irq_body=$(awk '/fn[[:space:]]+request_irq\(/,/^}/' "$UB")
if grep -qE 'pub\(crate\)[[:space:]]+const[[:space:]]+IRQF_SHARED' "$UB" &&
   echo "$request_irq_body" | grep -qE 'flags:[[:space:]]*usize' &&
   echo "$request_irq_body" | grep -qE 'request_threaded_irq' &&
   echo "$request_irq_body" | grep -qE '^[[:space:]]*flags,'; then
	grn "unsafe boundary exposes request_irq flags explicitly"
else
	red "unsafe boundary must keep request_irq flags explicit"
fi

exit "$rc"
