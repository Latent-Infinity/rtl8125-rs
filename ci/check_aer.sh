#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# PCIe AER recovery contract (W2.3).
#
# The recovery POLICY (channel-state decode, verdict mapping, ABI values) is
# pure Rust in src/aer.rs and host-tested standalone; the kernel-facing callbacks
# (error_detected / slot_reset / resume) are thin cfg-gated delegations in
# src/pci.rs that reuse the validated balanced stop/open path. Pin that split so
# a refactor can't (a) move policy into the kernel callback, (b) drop the
# host-tested ABI pin, or (c) reach the chip on a frozen channel via a path other
# than the documented teardown. Gated on the r8125_pci_aer cfg (AER=1) which
# needs an AER-extended kernel (kernel-patches/0004).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
need() { grep -qE -- "$2" "$1" && grn "$3" || red "$3 (missing in ${1#"$ROOT"/}: $2)"; }

AER_RS="$ROOT/src/aer.rs"
PCI_RS="$ROOT/src/pci.rs"
UB="$ROOT/src/unsafe_boundary.rs"
BRIDGE_C="$ROOT/src/netdev_bridge.c"
HDR="$ROOT/src/netdev_bridge.h"
MK="$ROOT/Makefile"
MAIN="$ROOT/src/r8125_rust_main.rs"
PATCHER="$ROOT/tools/patch_pci_aer.py"
PATCH="$ROOT/kernel-patches/0004-rust-pci-add-aer-callbacks.patch"
UNIT="$ROOT/ci/check_rust_unit_tests.sh"

# 1. The policy is pure, host-tested Rust (decode + verdict + ABI encode).
need "$AER_RS" 'enum ChannelState' "AER channel-state type is Rust"
need "$AER_RS" 'enum ErsResult' "AER verdict type is Rust"
need "$AER_RS" 'fn from_raw' "AER decodes the raw pci_channel_state_t"
need "$AER_RS" 'const fn to_raw' "AER encodes the raw pci_ers_result_t (const, for the ABI pin)"
need "$AER_RS" 'fn aer_policy' "AER verdict policy is one pure function"
need "$AER_RS" '#\[cfg\(test\)\]' "AER policy carries host unit tests"
need "$UNIT" 'src/aer.rs' "AER policy is registered in the host unit-test runner"

# 2. The policy module is only linked when the AER callbacks are compiled in.
if grep -Pzoq '#\[cfg\(r8125_pci_aer\)\]\s*\nmod aer;' "$MAIN" 2>/dev/null; then
	grn "aer module is gated on r8125_pci_aer"
else
	red "aer module is not gated on r8125_pci_aer (would warn dead-code on the default build)"
fi

# 3. The kernel callbacks are thin cfg-gated delegations (policy NOT duplicated).
need "$PCI_RS" '#\[cfg\(r8125_pci_aer\)\]' "AER callbacks are cfg-gated"
need "$PCI_RS" 'fn error_detected' "error_detected callback present"
need "$PCI_RS" 'fn slot_reset' "slot_reset callback present"
need "$PCI_RS" 'fn error_resume' "resume callback present (named error_resume to avoid PM-resume clash)"
need "$PCI_RS" 'crate::aer::aer_policy' "error_detected uses the pure policy (not an inline verdict)"
need "$PCI_RS" 'bridge_pm_error_detach' "error_detected quiesces via the dedicated AER teardown"
need "$PCI_RS" 'ChannelState::Normal' "error_detected skips teardown for a non-fatal channel (igb model)"
need "$PCI_RS" 'bridge_pm_error_detach\(this\._netdev\.ndev\(\), false\)' "permanent failure is detach-only (no unbalanced full stop)"
need "$PCI_RS" 'bridge_pm_error_detach\(this\._netdev\.ndev\(\), true\)' "frozen/unknown channels take the full-stop teardown"
need "$PCI_RS" 'bridge_pm_error_resume' "resume re-inits via the dedicated RTNL-free AER path"

# 3b. The AER callbacks run under pci_bus_sem (pci_walk_bus), so they MUST be
#     RTNL-free or they invert the lock order the runtime-PM D-state path takes
#     (rtnl -> pci_bus_sem) — an ABBA deadlock lockdep catches. Pin the teardown
#     + resume as rtnl_lock-free in the cshim.
reject_in_fn() {
	# $1=file $2=function-signature-regex $3=banned-regex $4=label
	awk "/$2/{f=1} f&&/$3/{print; bad=1} f&&/^}/{f=0} END{exit bad?1:0}" "$1" >/dev/null 2>&1 \
		&& grn "$4" || red "$4"
}
reject_in_fn "$BRIDGE_C" 'void r8125_bridge_pm_error_detach\(' 'rtnl_lock' "AER teardown is RTNL-free"
reject_in_fn "$BRIDGE_C" 'int r8125_bridge_pm_error_resume\(' 'rtnl_lock' "AER resume is RTNL-free"

# 4. The host-tested ABI values are pinned to the real kernel bindings.
need "$PCI_RS" 'pci_channel_io_normal == 1' "channel-state ABI pinned to bindings"
need "$PCI_RS" 'PCI_ERS_RESULT_NONE == crate::aer::ErsResult::None.to_raw' "verdict ABI pinned to bindings"

# 5. The teardown helper: full balanced stop, no WoL keep-alive branch, no chip
#    re-init (that is deferred to resume) — so frozen-channel MMIO stays bounded
#    to the standard close path.
need "$BRIDGE_C" 'void r8125_bridge_pm_error_detach' "AER teardown helper defined in the cshim"
need "$BRIDGE_C" 'netif_device_detach' "AER teardown detaches from the stack"
need "$BRIDGE_C" 'aer_torn_down = full_stop' "AER resume flag is set only for recoverable full-stop paths"
need "$HDR" 'r8125_bridge_pm_error_detach' "AER teardown declared in the header"
need "$UB" '#\[cfg\(r8125_pci_aer\)\]' "AER cshim wrapper is cfg-gated"
need "$UB" 'fn bridge_pm_error_detach' "AER teardown wrapper exists in unsafe_boundary"

# 6. Build knob + kernel patch artifacts.
need "$MK" 'cfg=r8125_pci_aer' "Makefile AER=1 knob maps to the r8125_pci_aer cfg"
[ -x "$PATCHER" ] && grn "kernel pci.rs AER patcher present + executable" \
  || red "tools/patch_pci_aer.py missing or not executable"
[ -f "$PATCH" ] && grn "kernel-patches/0004 artifact present" \
  || red "kernel-patches/0004-rust-pci-add-aer-callbacks.patch missing"

exit "$rc"
