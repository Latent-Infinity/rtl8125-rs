#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static guard for the native-XDP contract. XDP program lifetime is easy to get
# subtly wrong: ndo_bpf owns the program reference under RTNL while NAPI can run
# the program concurrently. Pin the RCU publication/read pattern and the honest
# xdp_features advertisement so future edits fail mechanically.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XDP_C="$ROOT/src/netdev_bridge_xdp.c"
INT_H="$ROOT/src/netdev_bridge_internal.h"
NETDEV_C="$ROOT/src/netdev_bridge.c"
NAPI_RS="$ROOT/src/napi.rs"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

need() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -- "$needle" "$file"; then grn "$desc"
  else red "$desc missing (${file#$ROOT/}: $needle)"
  fi
}

reject() {
  local file="$1" needle="$2" desc="$3"
  if grep -qF -- "$needle" "$file"; then red "$desc present (${file#$ROOT/}: $needle)"
  else grn "$desc absent"
  fi
}

need "$INT_H" "struct bpf_prog __rcu *xdp_prog;" \
  "attached XDP program is typed as an RCU pointer"
need "$XDP_C" "rcu_dereference_bh(b->xdp_prog)" \
  "NAPI XDP reader uses rcu_dereference_bh"
need "$XDP_C" "rcu_replace_pointer_rtnl(b->xdp_prog, prog)" \
  "ndo_bpf replaces the XDP program under RTNL with RCU publication"
need "$XDP_C" "bpf_prog_put(old)" \
  "ndo_bpf drops the replaced program reference"
reject "$XDP_C" "READ_ONCE(b->xdp_prog)" \
  "old plain READ_ONCE XDP program reader"
reject "$XDP_C" "xchg(&b->xdp_prog" \
  "old raw xchg XDP program replacement"

need "$NETDEV_C" ".ndo_bpf" \
  "native XDP attach callback is wired"
need "$NETDEV_C" ".ndo_xdp_xmit" \
  "redirect-target transmit callback is wired"
need "$NETDEV_C" "NETDEV_XDP_ACT_BASIC | NETDEV_XDP_ACT_REDIRECT |" \
  "xdp_features advertises BASIC and REDIRECT actions"
need "$NETDEV_C" "NETDEV_XDP_ACT_NDO_XMIT" \
  "xdp_features advertises NDO_XMIT now that ndo_xdp_xmit is implemented"
need "$XDP_C" "r8125_bridge_ndo_xdp_xmit" \
  "ndo_xdp_xmit implementation present (redirect-target side)"
need "$XDP_C" "flags & ~XDP_XMIT_FLAGS_MASK" \
  "ndo_xdp_xmit rejects unknown xmit flags"
need "$XDP_C" "xdp_frame_has_frags(frame)" \
  "ndo_xdp_xmit producer rejects non-linear frames until SG is advertised"
need "$XDP_C" "while (i < n)" \
  "ndo_xdp_xmit partial failure walks the unconsumed tail"
need "$XDP_C" "xdp_return_frame(frames[i++])" \
  "ndo_xdp_xmit returns unconsumed tail frames on partial failure"
need "$NAPI_RS" "TxSlotKind::Xdp" \
  "TX reaper has explicit XDP frame disposition"
need "$NAPI_RS" "ub::xdp_return_frame" \
  "TX reaper returns XDP_TX frames through xdp_return_frame"

exit "$rc"
