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
   (grep -qE 'pci_irq_vector\([[:space:]]*pdev,[[:space:]]*0\)' "$PCI" ||
    tr '\n' ' ' < "$PCI" | grep -qE 'pci_irq_vector\([[:space:]]*pdev,[[:space:]]*regs::V2_RX_Q0_VECTOR'); then
	grn "probe allocates MSI/MSI-X with INTx fallback and stores IrqMode"
else
	red "probe does not allocate/store IRQ mode with MSI/MSI-X plus INTx fallback"
fi

# RTL8125B's V2 per-queue interrupt surface routes TX Q0 to MSI-X table entry
# 16 and link-change to entry 21. A B3-capable probe may enable V2 only after an
# exact 22-vector MSI-X allocation; every single-vector fallback must keep
# use_v2=false.
probe_irq_block=$(awk '/let \(irq_mode, use_v2\) = if intx_only/,/pr_info!/' "$PCI")
probe_irq_flat=$(printf '%s\n' "$probe_irq_block" | tr '\n' ' ')
if grep -qE 'V2_MIN_MSIX_VECTORS_8125B' "$PCI" &&
   echo "$probe_irq_flat" | grep -qE 'alloc_irq_vectors\([^)]*V2_MIN_MSIX_VECTORS_8125B[^)]*V2_MIN_MSIX_VECTORS_8125B' &&
   tr '\n' ' ' < "$PCI" | grep -qE 'pci_irq_vector\([[:space:]]*pdev,[[:space:]]*regs::V2_TX_Q0_VECTOR\)' &&
   tr '\n' ' ' < "$PCI" | grep -qE 'pci_irq_vector\([[:space:]]*pdev,[[:space:]]*regs::V2_LINK_VECTOR\)' &&
   echo "$probe_irq_block" | grep -qE 'IrqType::MsiX' &&
   echo "$probe_irq_block" | grep -qE 'IrqType::Msi' &&
   echo "$probe_irq_block" | grep -qE '\(IrqMode::Msi,[[:space:]]*true\)' &&
   echo "$probe_irq_block" | grep -qE '\(IrqMode::Msi,[[:space:]]*false\)' &&
   echo "$probe_irq_block" | grep -qE '\(IrqMode::Intx,[[:space:]]*false\)'; then
	grn "probe enables V2 only after exact 22-vector MSI-X and keeps single-vector fallback legacy"
else
	red "probe must require 22 MSI-X vectors for V2 and keep single-vector fallback use_v2=false"
fi

# irq_v2 escape hatch: the operator can disable the wedge-prone V2 surface
# without dropping all the way to INTx (`intx_only`). off (0) must skip the V2
# allocation and use the proven single-vector legacy surface; on (2) must
# hard-fail probe rather than silently downgrade.
MAIN="$ROOT/src/r8125_rust_main.rs"
if grep -qE 'irq_v2:[[:space:]]*u8' "$MAIN" &&
   grep -qE 'let irq_v2 = \*crate::module_parameters::irq_v2\.value\(\)' "$PCI" &&
   echo "$probe_irq_flat" | grep -qE 'want_v2[[:space:]]*&&' &&
   echo "$probe_irq_flat" | grep -qE 'irq_v2 == 2'; then
	grn "irq_v2 escape hatch gates the V2 surface (0=off legacy, 2=on require)"
else
	red "irq_v2 module param / probe gating for the V2 surface is missing"
fi

if grep -qE 'request_irq\([^,]+,[^,]+,[^,]+,[[:space:]]*irq_flags\)' "$NETDEV" &&
   grep -qE 'regs::V2_TX_Q0_VECTOR' "$NETDEV" &&
   grep -qE 'regs::V2_LINK_VECTOR' "$NETDEV" &&
   awk '/let irq_flags = match state\.irq_mode\(\)/,/};/' "$NETDEV" | \
		grep -qE 'IrqMode::Intx[[:space:]]*=>[[:space:]]*ub::IRQF_SHARED' &&
   awk '/let irq_flags = match state\.irq_mode\(\)/,/};/' "$NETDEV" | \
		grep -qE 'IrqMode::Msi[[:space:]]*=>[[:space:]]*0'; then
	grn "request_irq flags are mode-specific and V2 active entries are named"
else
	red "request_irq flags or fixed V2 active-vector ownership are missing"
fi

if awk '/if state\.irq_mode\(\) != IrqMode::Intx/,/^    }/' "$NETDEV" | \
		grep -Eq 'set_int_cfg0\(regs::INT_CFG0_ENABLE_8125\)|set_int_cfg0_v2_enable\(true\)'; then
	grn "INT_CFG0_ENABLE_8125 is gated off for INTx fallback"
else
	red "INT_CFG0_ENABLE_8125 is not guarded by IrqMode::Intx fallback"
fi

handler=$(awk '/fn raw_irq_handler/,/^}/' "$NETDEV")
if echo "$handler" | grep -qE 'let use_v2 = state\.irq_mode\(\) == IrqMode::Msi && state\.use_v2_irq_surface\(\)' &&
   echo "$handler" | grep -qE 'let status = if use_v2' &&
   echo "$handler" | grep -qE 'if use_v2 \{' &&
   echo "$handler" | grep -qE 'regs\.ack_isr\(status\)' &&
   echo "$handler" | grep -qE 'regs\.set_imr\(0\)' &&
   echo "$handler" | grep -qE 'regs\.ack_isr_v2\(status\)' &&
   echo "$handler" | grep -qE 'regs\.clear_imr_v2_mask\(0xFFFF_FFFF\)'; then
	grn "raw IRQ handler reads, acks, and masks the IrqMode-selected surface"
else
	red "raw IRQ handler does not fully branch on IrqMode"
fi

rearm=$(awk '/fn rearm_irq_baseline/,/^}/' "$NAPI")
if echo "$rearm" | grep -qE 'match \(state\.irq_mode\(\), state\.use_v2_irq_surface\(\)\)' &&
   echo "$rearm" | grep -qE 'IrqMode::Msi, true' &&
   echo "$rearm" | grep -qE 'set_imr_v2_mask\(regs::INTR_V2_M4_BASELINE\)' &&
   echo "$rearm" | grep -qE 'set_imr\(regs::INTR_M4_BASELINE\)'; then
	grn "NAPI re-arm uses the IrqMode-selected interrupt mask"
else
	red "NAPI re-arm does not branch on IrqMode"
fi

if grep -qE 'pub\(crate\)[[:space:]]+const[[:space:]]+INT_CFG0_ENABLE_8125:[[:space:]]*u8[[:space:]]*=[[:space:]]*0x01;' "$REGS"; then
	grn "INT_CFG0_ENABLE_8125 uses the reviewed BIT(0) value"
else
	red "INT_CFG0_ENABLE_8125 must stay at BIT(0) (0x01)"
fi

if grep -qE 'INT_CFG0_TIMEOUT0_BYPASS_8125:[[:space:]]*u8[[:space:]]*=[[:space:]]*0x02;' "$REGS" &&
   grep -qE 'INT_CFG0_MITIGATION_BYPASS_8125:[[:space:]]*u8[[:space:]]*=[[:space:]]*0x04;' "$REGS"; then
	grn "INT_CFG0 mitigation bypass bits use the reviewed RTL8125 values"
else
	red "INT_CFG0 mitigation bypass constants must stay at BIT(1)/BIT(2)"
fi

setup_irq_block=$(awk '/fn setup_interrupt_config/,/^}/' "$NETDEV")
if echo "$setup_irq_block" | grep -qE 'INT_CFG0_ENABLE_8125' &&
   echo "$setup_irq_block" | grep -qE 'INT_CFG0_TIMEOUT0_BYPASS_8125' &&
   echo "$setup_irq_block" | grep -qE 'INT_CFG0_MITIGATION_BYPASS_8125' &&
   echo "$setup_irq_block" | grep -qE 'zero_coalesce_table_8125b\(\)' &&
   echo "$setup_irq_block" | grep -qE 'set_int_cfg1\(0\)'; then
	grn "open clears V2 and mitigation-bypass bits before programming IRQ moderation"
else
	red "setup_interrupt_config must clear V2 + mitigation-bypass bits and reset INT_MITI"
fi

moderation_block=$(awk '/fn program_interrupt_moderation/,/^}/' "$NETDEV")
if grep -qE 'program_interrupt_moderation\(state,[[:space:]]*&regs\)' "$NETDEV" &&
   echo "$moderation_block" | grep -qE 'irq_mode\(\)[[:space:]]*==[[:space:]]*IrqMode::Msi[[:space:]]*&&[[:space:]]*state\.use_v2_irq_surface\(\)' &&
   echo "$moderation_block" | grep -qE 'set_coalesce_8125b\(rx_timer,[[:space:]]*tx_timer\)' &&
   echo "$moderation_block" | grep -qE 'INT_MITI timers use_v2='; then
	grn "RTL8125 INT_MITI timers are programmed for the selected IRQ surface"
else
	red "INT_MITI timers must be programmed outside the V2-only branch"
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
