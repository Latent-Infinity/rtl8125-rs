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

# Pre-engagement: is MSI-X in tree yet?
if ! grep -qE '\bIMR_V2_SET\b|\bISR_V2\b' "$REGS"; then
	yel "MSI-X register surface not yet in src/regs.rs (M6 #1 not landed) — skipping"
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

# 2. INT_CFG0_ENABLE_8125 set in hw_start_8125b.
if ! awk '/fn hw_start_8125b/,/^}/' "$HW" 2>/dev/null | \
		grep -qE 'INT_CFG0_ENABLE_8125|set_int_cfg0\s*\([^)]*\|\s*regs::INT_CFG0_ENABLE_8125'; then
	red "hw_start_8125b does not set INT_CFG0_ENABLE_8125 — chip will stay on legacy ISR"
else
	grn "hw_start_8125b activates v2 ISR via INT_CFG0_ENABLE_8125"
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

# 4. Vector-allocation request includes fallback flags. We don't know
#    yet whether kernel-Rust pci will expose this directly or whether
#    we'll need to wrap pci_alloc_irq_vectors via cshim. Accept either
#    "pci_alloc_irq_vectors" with the fallback flags listed, or an
#    explicit Rust API that documents fallback intent.
if grep -qE 'PCI_IRQ_MSIX.*PCI_IRQ_MSI.*PCI_IRQ_INTX|alloc_irq_vectors.*PCI_IRQ' "$ROOT/src/"*.rs "$ROOT/src/"*.c 2>/dev/null; then
	grn "IRQ allocation includes MSIX|MSI|INTX fallback flags"
elif grep -qE 'pci_alloc_irq_vectors' "$ROOT/src/"*.rs "$ROOT/src/"*.c 2>/dev/null; then
	red "pci_alloc_irq_vectors call lacks the MSIX|MSI|INTX fallback flag set"
else
	# Not yet calling the new API — but MSI-X registers are defined.
	# Either we're mid-implementation or using a kernel-Rust wrapper
	# that hides the flags. Soft check.
	yel "no explicit pci_alloc_irq_vectors call found — check the kernel-Rust API path"
fi

# 5. Module param for INTx-only fallback exists (regression rollback).
if grep -qE '\bintx_only\s*:' "$MAIN"; then
	grn "intx_only module param exists for legacy-IRQ fallback"
else
	red "missing 'intx_only: u8' module param (M6 per-feature rollback gate)"
fi

exit $rc
