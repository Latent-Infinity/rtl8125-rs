#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# PCI runtime-PM (autosuspend) contract (W2.4).
#
# Policy: autosuspend ONLY while the interface is administratively down. The
# runtime_idle callback vetoes (EBUSY) whenever netif_running, so the
# suspend/resume callbacks run only on a closed device and stay RTNL-free / do no
# ring work (the close already quiesced the HW; the PCI core does the D-state).
# Pin three invariants so a refactor can't reintroduce the deadlock/wedge hazards:
#   1. the ndo open/stop pm_runtime brackets live in dedicated *_entry wrappers
#      (registered in netdev_ops), NOT in bridge_ndo_open/stop — those are reused
#      by the PM/reset/AER resume paths, where pm_runtime_get_sync would deadlock;
#   2. the brackets are flag-gated (b->runtime_pm) so the default build is
#      byte-identical;
#   3. runtime_idle keys off netif_running (no suspend-while-up).
# Gated on r8125_pci_runtime_pm (RUNTIME_PM=1), needs an extended kernel (0005).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
need() { grep -qE -- "$2" "$1" && grn "$3" || red "$3 (missing in ${1#"$ROOT"/}: $2)"; }

PCI_RS="$ROOT/src/pci.rs"
UB="$ROOT/src/unsafe_boundary.rs"
BRIDGE_C="$ROOT/src/netdev_bridge.c"
HDR="$ROOT/src/netdev_bridge.h"
INT_H="$ROOT/src/netdev_bridge_internal.h"
MK="$ROOT/Makefile"
PATCHER="$ROOT/tools/patch_pci_runtime_pm.py"
PATCH="$ROOT/kernel-patches/0005-rust-pci-add-runtime-pm-callbacks.patch"

# 1. Brackets live in the *_entry wrappers and netdev_ops points at THEM (not the
#    bare open/stop reused by the resume paths) — the anti-deadlock invariant.
need "$BRIDGE_C" 'bridge_ndo_open_entry' "ndo_open entry wrapper exists"
need "$BRIDGE_C" 'bridge_ndo_stop_entry' "ndo_stop entry wrapper exists"
need "$BRIDGE_C" '\.ndo_open\s*=\s*bridge_ndo_open_entry' "netdev_ops registers the open entry wrapper"
need "$BRIDGE_C" '\.ndo_stop\s*=\s*bridge_ndo_stop_entry' "netdev_ops registers the stop entry wrapper"
need "$BRIDGE_C" 'pm_runtime_get_sync' "entry wrapper resumes before touching MMIO"
need "$BRIDGE_C" 'pm_runtime_put_sync' "entry wrapper releases + arms the idle check"
need "$BRIDGE_C" 'pm_runtime_put_noidle' "entry wrapper unwinds a failed pm_runtime_get_sync"

# 2. Brackets are flag-gated so the default build is byte-identical.
need "$INT_H" 'bool runtime_pm' "runtime_pm bracket flag on the bridge struct"
need "$BRIDGE_C" 'if \(b->runtime_pm\)' "brackets are gated on the runtime_pm flag"

# 3. Idle keys off netif_running; suspend/resume only detach/attach (no rings).
need "$BRIDGE_C" 'netif_running\(ndev\) \? -EBUSY : 0' "runtime_idle vetoes while the interface is up"
need "$BRIDGE_C" 'void r8125_bridge_runtime_suspend' "runtime_suspend helper present"
need "$BRIDGE_C" 'void r8125_bridge_runtime_resume' "runtime_resume helper present"
need "$BRIDGE_C" 'pci_dev_run_wake' "autosuspend gated on run-wake capability"
need "$BRIDGE_C" 'pm_runtime_put_sync' "probe-end drops the core usage ref to enable autosuspend"

# 4. Rust callbacks are thin cfg-gated delegations + lifecycle wiring.
need "$PCI_RS" 'fn runtime_idle' "runtime_idle callback present"
need "$PCI_RS" 'fn runtime_suspend' "runtime_suspend callback present"
need "$PCI_RS" 'fn runtime_resume' "runtime_resume callback present"
need "$PCI_RS" 'bridge_pm_runtime_enable' "probe enables runtime PM"
need "$PCI_RS" 'bridge_pm_runtime_disable' "unbind disables runtime PM"
need "$UB" 'fn bridge_runtime_idle' "runtime_idle wrapper in unsafe_boundary"
need "$HDR" 'r8125_bridge_pm_runtime_enable' "runtime enable declared in the header"

# 5. Build knob + kernel patch artifacts.
need "$MK" 'cfg=r8125_pci_runtime_pm' "Makefile RUNTIME_PM=1 knob maps to the cfg"
[ -x "$PATCHER" ] && grn "kernel pci.rs runtime-PM patcher present + executable" \
  || red "tools/patch_pci_runtime_pm.py missing or not executable"
[ -f "$PATCH" ] && grn "kernel-patches/0005 artifact present" \
  || red "kernel-patches/0005-rust-pci-add-runtime-pm-callbacks.patch missing"

exit "$rc"
