#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# B5 ethtool RSS control-plane contract.
#
# The driver exposes RSS key/indirection/channels via ethtool. get_rxfh reports
# the ACTIVE Rust-owned policy (key + indirection table via ops.rss_get);
# set_rxfh range-checks the table (host-tested validator) and installs a CUSTOM
# key and/or table into the policy via ops.rss_set, reprogramming the chip live;
# get_channels/set_channels report and change the active RX-queue count. The C
# size macros MUST equal the Rust source of truth so the kernel buffers match
# what hardware was programmed with.

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
	grep -qE '\.set_channels\s*=\s*bridge_set_channels' "$ETH" &&
	grep -qE '\.get_rx_ring_count\s*=' "$ETH"; then
	grn "ethtool_ops exposes get/set rxfh + sizes + get/set_channels + rx_ring_count"
else
	red "ethtool_ops is missing get/set_rxfh, sizes, get_channels, set_channels, or get_rx_ring_count"
fi

# set_channels must keep the C-side active queue cache coherent even when the
# interface is down. Otherwise `ethtool -L rx 4` succeeds while down, but
# immediate `ethtool -l/-x` still reports the old queue count until the next
# open.
channels_body=$(awk '/static int bridge_set_channels\(/,/^}/' "$ETH")
if grep -qE 'netif_running\(ndev\)' <<<"$channels_body" &&
	grep -qE 'r8125_bridge_reopen\(ndev\)' <<<"$channels_body" &&
	grep -qE 'r8125_bridge_set_active_rx_queues\(ndev, ch->rx_count\)' <<<"$channels_body"; then
	grn "set_channels updates active_rx_queues immediately for down interfaces"
else
	red "set_channels must update active_rx_queues on the down-interface path"
fi

# get_rx_ring_count answers the RX-ring-count query (ethtool -x/-X precondition
# on kernels that route ETHTOOL_GRXRINGS to the dedicated op).
if grep -qE 'static u32 bridge_get_rx_ring_count' "$ETH"; then
	grn "get_rx_ring_count reports the owned RX ring count"
else
	red "get_rx_ring_count must report the RX ring count (else ethtool -x/-X fail)"
fi

# 3. get_rxfh reports the ACTIVE policy via ops.rss_get (key + indir from the
#    Rust-owned RssPolicy, not a recomputed default) + Toeplitz.
get_body=$(awk '/static int bridge_get_rxfh\(/,/^}/' "$ETH")
if grep -qE 'ops\.rss_get\(b->priv, rxfh->key, rxfh->indir\)' <<<"$get_body" &&
	grep -q 'ETH_RSS_HASH_TOP' <<<"$get_body" &&
	! grep -qE 'memset\(rxfh->indir' <<<"$get_body"; then
	grn "get_rxfh reports the active key + indir from the Rust policy (ops.rss_get) + Toeplitz"
else
	red "get_rxfh must fill key+indir from ops.rss_get (the Rust-owned policy), not a recomputed/zero table"
fi

# 4. set_rxfh rejects rss_context, range-checks indir via the Rust validator,
#    then installs the CUSTOM key/table via ops.rss_set (no -EOPNOTSUPP for a
#    valid custom table — custom RSS is now supported).
set_body=$(awk '/static int bridge_set_rxfh\(/,/^}/' "$ETH")
if grep -qE 'rss_context' <<<"$set_body" &&
	grep -qE 'ops\.rss_indir_check\(' <<<"$set_body" &&
	grep -qE 'ETH_RSS_HASH_NO_CHANGE' <<<"$set_body" &&
	grep -qE 'return b->ops\.rss_set\(b->priv, rxfh->key, rxfh->indir' <<<"$set_body"; then
	grn "set_rxfh rejects contexts, validates indir, and installs the custom key/table via ops.rss_set"
else
	red "set_rxfh must reject rss_context, validate indir, and install the custom key/table via ops.rss_set"
fi

# 5. RSS vtable ops (validate + get + set) exist on BOTH sides and are wired.
if grep -qE 'int \(\*rss_indir_check\)\(void \*priv, const u32 \*indir, unsigned int len,' "$HDR" &&
	grep -qE 'void \(\*rss_get\)\(void \*priv, u8 \*key_out, u32 \*indir_out\)' "$HDR" &&
	grep -qE 'int \(\*rss_set\)\(void \*priv, const u8 \*key_in, const u32 \*indir_in,' "$HDR" &&
	grep -qE 'pub rss_indir_check:' "$UB" &&
	grep -qE 'pub rss_get:' "$UB" &&
	grep -qE 'pub rss_set:' "$UB" &&
	grep -qE 'rss_indir_check: rust_rss_indir_check' "$NETDEV" &&
	grep -qE 'rss_get: rust_rss_get' "$NETDEV" &&
	grep -qE 'rss_set: rust_rss_set' "$NETDEV"; then
	grn "rss_indir_check/get/set vtable ops present in C struct, Rust BridgeOps, and M4_FULL_OPS"
else
	red "rss_indir_check/get/set must be declared in the C vtable, Rust BridgeOps, and wired in M4_FULL_OPS"
fi

# 5b. The Rust-owned policy module sizes match the chip register sizes.
rss_key=$(grep -oE 'RSS_KEY_SIZE: usize = [0-9]+' "$ROOT/src/rss.rs" | grep -oE '[0-9]+$' | head -1)
rss_indir=$(grep -oE 'RSS_INDIR_ENTRIES: usize = [0-9]+' "$ROOT/src/rss.rs" | grep -oE '[0-9]+$' | head -1)
if [[ "$rss_key" == "$key_rs" && "$rss_indir" == "$indir_rs" ]]; then
	grn "rss::RssPolicy sizes match the chip register sizes (key=$rss_key, indir=$rss_indir)"
else
	red "rss.rs sizes must equal regs/layout (key rss=$rss_key/regs=$key_rs indir rss=$rss_indir/layout=$indir_rs)"
fi

check_body=$(awk '/extern "C" fn rust_rss_indir_check\(/,/^}/' "$NETDEV")
if grep -qE 'ub::rxfh_indir_valid\(indir, len as usize, queue_count\)' <<<"$check_body" &&
	grep -qE 'b->active_rx_queues' "$ETH" &&
	grep -qE 'crate::layout::rxfh_indir_all_valid' "$UB"; then
	grn "rss_indir_check bounds entries by runtime active_rx_queues via host-tested validator"
else
	red "rss_indir_check must bound indirection by runtime active_rx_queues through layout::rxfh_indir_all_valid"
fi

set_rss_body=$(awk '/extern "C" fn rust_rss_set\(/,/^}/' "$NETDEV")
if grep -qE 'rss_policy_store\(state, &policy\)' <<<"$set_rss_body" &&
	grep -qE 'ub::netif_running' <<<"$set_rss_body" &&
	grep -qE 'apply_rss_programming\(state\)' <<<"$set_rss_body"; then
	grn "rss_set caches policy first and only reprograms hardware when netif_running"
else
	red "rust_rss_set must cache policy first and guard live MMIO programming with netif_running"
fi

exit "$rc"
