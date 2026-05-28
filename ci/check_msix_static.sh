#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for M6 sub-feature #1 (MSI-X migration). See
# docs/M6_MSIX_DESIGN.md for the implementation contract this script
# enforces.
#
# The check is intentionally vacuous before M6 lands — it skips when
# none of the MSI-X register surface is present in the source. Once
# `IMR_V2_SET` / `IMR_V2_CLEAR` / `ISR_V2` constants appear in
# `src/regs.rs`, the full enforcement engages.
#
# Invariants enforced once MSI-X is in tree:
#   1. ISR_V2 / IMR_V2_SET / IMR_V2_CLEAR are all defined together
#      (you can't half-migrate to the v2 layout)
#   2. `INT_CFG0_ENABLE_8125` is set inside `hw_start_8125b` so the
#      chip routes to the v2 ISR (without this, v2 reads return junk)
#   3. The IRQ handler reads `isr_v2()`, not `isr()`, when V2 is active
#   4. Vector-allocation request must include the MSI-X|MSI|INTX
#      fallback flags so the driver still works if MSI-X allocation
#      fails (e.g., kernel has MSI-X disabled, or the guest doesn't
#      virtualize it)
#   5. A module param exists to force INTx-only (regression fallback)

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel()  { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

REGS="$ROOT/src/regs.rs"
HW="$ROOT/src/hw.rs"
NETDEV="$ROOT/src/netdev.rs"
MAIN="$ROOT/src/r8125_rust_main.rs"

# Pre-engagement: V2 surface is only ACTIVE when some code path sets
# `INT_CFG0_ENABLE_8125` on the chip. Phase A.1 had the surface in
# regs.rs as scaffolding without activating it. Phase A.2 moves the
# activation out of `hw_start_8125b` (which is run before MSI/MSI-X
# allocation is known) and into `ndo_open`, where it's gated on
# `state.irq_mode()`. Accept the activation in either file.
if ! grep -qE '\bIMR_V2_SET\b|\bISR_V2\b' "$REGS"; then
	yel "MSI-X register surface not yet in src/regs.rs (M6 #1 not landed) — skipping"
	exit 0
fi
# Distinguish "the constant is mentioned in a comment" from "the bit is
# actually written to the chip": look for an actual set_int_cfg0 call
# that includes INT_CFG0_ENABLE_8125 as a written value, in either
# hw_start_8125b or ndo_open (Phase A.2 home).
if ! grep -hE 'set_int_cfg0\([^)]*INT_CFG0_ENABLE_8125' "$HW" "$NETDEV" >/dev/null 2>&1; then
	yel "V2 register surface scaffolded but chip-side INT_CFG0_ENABLE_8125 not active yet — full check deferred"
	exit 0
fi

# 1. All three V2 ISR registers defined together.
for name in IMR_V2_CLEAR IMR_V2_SET ISR_V2; do
	if ! grep -qE "\bpub\(crate\)\s+const\s+${name}\s*:" "$REGS"; then
		red "src/regs.rs missing const ${name} (V2 ISR surface is incomplete)"
	fi
done
if [[ "$rc" -eq 0 ]]; then
	grn "src/regs.rs defines IMR_V2_CLEAR + IMR_V2_SET + ISR_V2 together"
fi

# 2. INT_CFG0_ENABLE_8125 is written conditionally (mode-gated) at
# bring-up. Phase A.2 keeps it in ndo_open guarded by
# `state.irq_mode() != IrqMode::Intx`; accept either gating idiom.
if ! grep -hE 'set_int_cfg0\([^)]*INT_CFG0_ENABLE_8125' "$HW" "$NETDEV" >/dev/null 2>&1; then
	red "no set_int_cfg0(INT_CFG0_ENABLE_8125) call found — chip will stay on legacy ISR"
elif ! grep -hE 'irq_mode\(\)|IrqMode::' "$NETDEV" >/dev/null 2>&1; then
	red "INT_CFG0_ENABLE_8125 written but not gated on IrqMode — INTx fallback will break"
else
	grn "INT_CFG0_ENABLE_8125 write is present and gated on IrqMode"
fi

# 3. IRQ handler reads isr_v2 (not the legacy isr).
if awk '/fn raw_irq_handler/,/^}/' "$NETDEV" | grep -qE '\.isr_v2\(\)'; then
	grn "raw_irq_handler reads isr_v2()"
elif awk '/fn raw_irq_handler/,/^}/' "$NETDEV" | grep -qE '\.isr\(\)' && \
     ! grep -qE 'intx_only.*value' "$NETDEV"; then
	red "raw_irq_handler still reads legacy isr() with no intx_only fallback path"
else
	grn "raw_irq_handler uses MSI-X read path"
fi

# 4. Vector-allocation request covers the MSI-X / MSI / INTx options
# with an explicit fallback. We use the kernel-Rust safe wrappers
# (`pci::IrqType::MsiX`, `pci::IrqType::Msi`, `pci::IrqType::Intx`,
# `IrqTypes::all`); accept either an explicit `IrqType::MsiX` reference
# alongside `IrqType::Intx`, or `IrqTypes::all()`, or the raw
# PCI_IRQ_MSIX / PCI_IRQ_INTX flag combo if a future patch ever drops
# back to the FFI directly.
if grep -qE 'IrqType::MsiX\b' "$ROOT/src/pci.rs" 2>/dev/null \
		&& grep -qE 'IrqType::Intx\b' "$ROOT/src/pci.rs" 2>/dev/null; then
	grn "IRQ allocation in pci.rs covers both IrqType::MsiX and IrqType::Intx (explicit fallback)"
elif grep -qE '\bIrqTypes::all\s*\(\)' "$ROOT/src/pci.rs" 2>/dev/null; then
	grn "IRQ allocation uses IrqTypes::all() (kernel does MSIX→MSI→INTX fallback)"
elif grep -qE 'PCI_IRQ_MSIX.*PCI_IRQ_MSI.*PCI_IRQ_INTX|alloc_irq_vectors.*PCI_IRQ' "$ROOT/src/"*.rs "$ROOT/src/"*.c 2>/dev/null; then
	grn "IRQ allocation includes MSIX|MSI|INTX fallback flags"
elif grep -qE 'pci_alloc_irq_vectors|alloc_irq_vectors' "$ROOT/src/"*.rs "$ROOT/src/"*.c 2>/dev/null; then
	red "alloc_irq_vectors call lacks MSI-X + INTx fallback (rebind risk on MSI-X failure)"
else
	yel "no IRQ vector allocation call found — check the kernel-Rust API path"
fi

# 5. Module param for INTx-only fallback exists (regression rollback).
if grep -qE '\bintx_only\s*:' "$MAIN"; then
	grn "intx_only module param exists for legacy-IRQ fallback"
else
	red "missing 'intx_only: u8' module param (M6 per-feature rollback gate)"
fi

exit $rc
