#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# TX-slot disposition parity gate.
#
# A TX shadow slot can hold three kinds of payload (TxSlotKind): an `Skb`
# (freed/consumed as an sk_buff), an `Xdp` xdp_frame (returned to its page_pool
# via xdp_return_frame), or an `XskTx` umem chunk (socket-owned, null pointer).
# There are TWO reapers that release slots:
#   * the hot path  `process_tx_completions`  (src/napi.rs)
#   * the stop path `reap_inflight_tx_shadow` (src/netdev.rs)
# BOTH must dispatch on `shadow_kind` and route an `Xdp` slot through
# `xdp_return_frame` — NOT free it as an skb. A 2026-06 bug had the stop reaper
# free every non-null shadow as an skb, type-confusing an xdp_frame* (KASAN UAF)
# and leaking its page_pool page. This gate pins both reapers to the kind
# dispatch so they cannot diverge again.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

# Assert that the function body starting at $2 in file $1 contains regex $3.
need_in_fn() {
	# $1=file $2=fn-signature-regex $3=needed-regex $4=label
	awk -v want="$3" '
		$0 ~ /'"$2"'/ { f=1 }
		f && $0 ~ want { found=1 }
		f && /^}/ { f=0 }
		END { exit found?0:1 }
	' "$1" && grn "$4" || red "$4"
}

NAPI="$ROOT/src/napi.rs"
NETDEV="$ROOT/src/netdev.rs"

# Hot-path reaper dispatches on kind + returns XDP frames.
need_in_fn "$NAPI" 'fn process_tx_completions' 'shadow_kind' "hot reaper reads shadow_kind"
need_in_fn "$NAPI" 'fn process_tx_completions' 'TxSlotKind::Xdp' "hot reaper has the Xdp arm"
need_in_fn "$NAPI" 'fn process_tx_completions' 'xdp_return_frame' "hot reaper returns XDP frames to the page_pool"

# Stop-path reaper MUST do the same (this is the regression that bit us).
need_in_fn "$NETDEV" 'fn reap_inflight_tx_shadow' 'shadow_kind' "stop reaper reads shadow_kind"
need_in_fn "$NETDEV" 'fn reap_inflight_tx_shadow' 'TxSlotKind::Xdp' "stop reaper has the Xdp arm"
need_in_fn "$NETDEV" 'fn reap_inflight_tx_shadow' 'xdp_return_frame' "stop reaper returns XDP frames (no skb type-confusion)"

exit "$rc"
