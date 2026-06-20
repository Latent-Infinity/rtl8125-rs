#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# TX-offload descriptor-bit policy boundary (H1).
#
# RUST_STANDARDS.md: "chip policy and descriptor logic belong in Rust." The TX
# checksum-v2 + TSO descriptor-bit POLICY (which CS/GTSEN bits, the TCPHO/GTTCPHO
# field shifts, the field LIMITS) lives in host-tested Rust (src/tx_offload.rs).
# The C shim (netdev_bridge_offload.c) is reduced to: gather protocol FACTS, call
# the Rust decision, and APPLY its side effects (pad / checksum_help / cow_head /
# v6 csum-prep). Pin that split so the bit policy can't drift back into C.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
need() { grep -qE -- "$2" "$1" && grn "$3" || red "$3 (missing in ${1#"$ROOT"/}: $2)"; }
reject() { grep -qE -- "$2" "$1" && red "$3 (present in ${1#"$ROOT"/}: $2)" || grn "$3"; }

TXOFF="$ROOT/src/tx_offload.rs"
OFFLOAD="$ROOT/src/netdev_bridge_offload.c"
HDR="$ROOT/src/netdev_bridge_internal.h"
UB="$ROOT/src/unsafe_boundary.rs"
UNIT="$ROOT/ci/check_rust_unit_tests.sh"

# 1. The policy + the chip bit values live in Rust, host-tested.
need "$TXOFF" 'fn decide\(' "TX offload decision is a pure Rust fn"
need "$TXOFF" 'TD1_TCP_CS|TD1_UDP_CS|TD1_IPV4_CS' "checksum-v2 bit values are Rust-owned"
need "$TXOFF" 'TD1_GTSENV4|TD1_GTSENV6' "TSO giant-send bit values are Rust-owned"
need "$TXOFF" 'GTTCPHO_MAX|TCPHO_MAX' "transport-offset field limits are Rust-owned"
need "$TXOFF" 'MSS_SHIFT' "the 11-bit MSS field shift is Rust-owned"
need "$TXOFF" 'MSS_MAX' "the 11-bit MSS field limit is Rust-owned"
need "$TXOFF" 'f\.mss > MSS_MAX' "TSO rejects MSS values that would overflow the descriptor field"
need "$TXOFF" '#\[cfg\(test\)\]' "offload policy carries host unit tests"
need "$UNIT" 'src/tx_offload.rs' "offload policy is registered in the host unit-test runner"

# 2. The C shim calls the Rust policy + only gathers facts / applies side effects.
need "$OFFLOAD" 'r8125_tx_offload_decide\(' "C calls the Rust offload decision"
need "$OFFLOAD" 'r8125_tx_offload_facts' "C gathers the protocol facts struct"
need "$UB" 'fn r8125_tx_offload_decide' "the Rust->C decision export exists in the boundary file"

# 3. The descriptor-bit POLICY must NOT have leaked back into C.
reject "$OFFLOAD" 'R8125_TD1_(TCP|UDP|IPV4|IPV6)_CS' "no checksum bit constants in C"
reject "$OFFLOAD" 'R8125_TD1_GTSENV[46]' "no TSO bit constants in C"
reject "$OFFLOAD" 'R8125_TCPHO_SHIFT|R8125_GTTCPHO_SHIFT|R8125_TD1_MSS_SHIFT' "no descriptor field shifts in C"

# 4. The FFI structs are defined on both sides (kept in sync by review + ABI).
need "$HDR" 'struct r8125_tx_offload_facts' "facts struct declared in the shared header"
need "$HDR" 'struct r8125_tx_offload_decision' "decision struct declared in the shared header"
need "$TXOFF" 'struct Facts' "facts struct defined in Rust"
need "$TXOFF" 'struct Decision' "decision struct defined in Rust"

exit "$rc"
