#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# B5 ethtool RSS control-plane contract.
#
# The driver exposes RSS key/indirection/channels via ethtool. At the current
# N=1 runtime: get_rxfh reports the boot-stable key + all-zero indirection (what
# apply_rss_programming writes), set_rxfh validates the indirection table through
# the host-tested Rust validator and refuses a custom key, and get_channels
# reports a single RX queue. The C size macros MUST equal the Rust source of
# truth so the kernel buffers match what hardware was programmed with.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

ETH="$ROOT/src/netdev_bridge_ethtool.c"
HDR="$ROOT/src/netdev_bridge.h"
REGS="$ROOT/src/regs.rs"
LAYOUT="$ROOT/src/layout.rs"
NETDEV="$ROOT/src/netdev.rs"
UB="$ROOT/src/unsafe_boundary.rs"

# 1. C size macros equal the Rust source-of-truth constants.
key_c=$(awk '/#define R8125_RSS_KEY_SIZE[[:space:]]/{v=$3; gsub(/[^0-9]/,"",v); print v; exit}' "$HDR")
key_rs=$(grep -oE 'RSS_KEY_SIZE: usize = [0-9]+' "$REGS" | grep -oE '[0-9]+$' | head -1)
indir_c=$(awk '/#define R8125_RSS_INDIR_SIZE[[:space:]]/{v=$3; gsub(/[^0-9]/,"",v); print v; exit}' "$HDR")
indir_rs=$(grep -oE 'RSS_INDIR_TBL_ENTRIES: usize = [0-9]+' "$LAYOUT" | grep -oE '[0-9]+$' | head -1)
if [[ -n "$key_c" && "$key_c" == "$key_rs" && -n "$indir_c" && "$indir_c" == "$indir_rs" ]]; then
	grn "RSS ethtool sizes match Rust (key=$key_c, indir=$indir_c)"
else
	red "RSS ethtool size macros must equal Rust consts (key C=$key_c/rs=$key_rs indir C=$indir_c/rs=$indir_rs)"
fi

# 2. ethtool_ops wires the full B5 surface.
if grep -qE '\.get_rxfh_key_size\s*=' "$ETH" &&
	grep -qE '\.get_rxfh_indir_size\s*=' "$ETH" &&
	grep -qE '\.get_rxfh\s*=' "$ETH" &&
	grep -qE '\.set_rxfh\s*=' "$ETH" &&
	grep -qE '\.get_channels\s*=' "$ETH" &&
	grep -qE '\.get_rx_ring_count\s*=' "$ETH"; then
	grn "ethtool_ops exposes get/set rxfh + sizes + channels + rx_ring_count"
else
	red "ethtool_ops is missing get/set_rxfh, sizes, get_channels, or get_rx_ring_count"
fi

# get_rx_ring_count answers the RX-ring-count query (ethtool -x/-X precondition
# on kernels that route ETHTOOL_GRXRINGS to the dedicated op).
if grep -qE 'static u32 bridge_get_rx_ring_count' "$ETH"; then
	grn "get_rx_ring_count reports the owned RX ring count"
else
	red "get_rx_ring_count must report the RX ring count (else ethtool -x/-X fail)"
fi

# 3. get_rxfh reports the programmed key (boot key) + zero indirection + Toeplitz.
get_body=$(awk '/static int bridge_get_rxfh\(/,/^}/' "$ETH")
if grep -q 'netdev_rss_key_fill' <<<"$get_body" &&
	grep -q 'ETH_RSS_HASH_TOP' <<<"$get_body" &&
	grep -qE 'memset\(rxfh->indir' <<<"$get_body"; then
	grn "get_rxfh reports boot key + zero indirection + Toeplitz hfunc"
else
	red "get_rxfh must fill the boot key, zero the indirection table, and report Toeplitz"
fi

# 4. set_rxfh rejects rss_context, validates indirection via Rust, guards key.
set_body=$(awk '/static int bridge_set_rxfh\(/,/^}/' "$ETH")
if grep -qE 'rss_context' <<<"$set_body" &&
	grep -qE 'ops\.rss_indir_check\(' <<<"$set_body" &&
	grep -qE 'ETH_RSS_HASH_NO_CHANGE' <<<"$set_body"; then
	grn "set_rxfh rejects contexts, validates indirection via Rust, guards hfunc"
else
	red "set_rxfh must reject rss_context, validate indir via ops.rss_indir_check, and guard hfunc"
fi

# 5. vtable rss_indir_check exists on BOTH sides and Rust uses the tested validator.
if grep -qE 'int \(\*rss_indir_check\)\(void \*priv, const u32 \*indir, unsigned int len,' "$HDR" &&
	grep -qE 'pub rss_indir_check:' "$UB" &&
	grep -qE 'rss_indir_check: rust_rss_indir_check' "$NETDEV"; then
	grn "rss_indir_check vtable op present in C struct, Rust BridgeOps, and M4_FULL_OPS"
else
	red "rss_indir_check must be declared in the C vtable, Rust BridgeOps, and wired in M4_FULL_OPS"
fi

check_body=$(awk '/extern "C" fn rust_rss_indir_check\(/,/^}/' "$NETDEV")
if grep -qE 'ub::rxfh_indir_valid\(indir, len as usize, queue_count\)' <<<"$check_body" &&
	grep -qE 'b->active_rx_queues' "$ETH" &&
	grep -qE 'crate::layout::rxfh_indir_all_valid' "$UB"; then
	grn "rss_indir_check bounds entries by runtime active_rx_queues via host-tested validator"
else
	red "rss_indir_check must bound indirection by runtime active_rx_queues through layout::rxfh_indir_all_valid"
fi

exit "$rc"
