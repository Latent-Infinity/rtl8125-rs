#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RTL8125B hardware-RSS programming contract. The driver may program the RSS
# key/indir/control registers for validation, but it must not distribute RX
# traffic to queues that the Rust/C bridge has not allocated and registered.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

MAIN="$ROOT/src/r8125_rust_main.rs"
NETDEV="$ROOT/src/netdev.rs"
MMIO="$ROOT/src/mmio.rs"
UB="$ROOT/src/unsafe_boundary.rs"
BRIDGE_ETHTOOL="$ROOT/src/netdev_bridge_ethtool.c"
HEADER="$ROOT/src/netdev_bridge.h"
RUN="$ROOT/ci/run_checks.sh"

if grep -q 'rss_queues: u8' "$MAIN" &&
   grep -q 'default: 0' "$MAIN" &&
   grep -q 'description: "Hardware RSS queue request: 0=off' "$MAIN"; then
	grn "hardware RSS has an explicit off-by-default module parameter"
else
	red "hardware RSS must be gated by rss_queues=0 default"
fi

if grep -q 'fn validate_rss_queue_request(state: &NetdevState) -> Result<()> ' "$NETDEV" &&
   grep -q 'requested > RX_QUEUE_COUNT as u8' "$NETDEV" &&
   grep -q 'requested > 1 && !state.use_v2_irq_surface()' "$NETDEV" &&
   grep -q 'return Err(EINVAL)' "$NETDEV"; then
	grn "hardware RSS requests are bounded by owned queues and V2 interrupt ownership"
else
	red "rss_queues must fail fast when queues/vectors are not owned"
fi

if grep -q 'fn apply_rss_programming(state: &NetdevState)' "$NETDEV" &&
   grep -q 'regs.set_q_num_ctrl_8125(rss_q_num_ctrl(queue_count))' "$NETDEV" &&
   grep -q 'regs.set_rss_ctrl_8125(regs::RSS_CTRL_HASH_BITS)' "$NETDEV" &&
   grep -q 'regs.set_rss_ctrl_8125(0)' "$NETDEV" &&
   grep -q 'apply_rss_programming(state)' "$NETDEV"; then
	grn "RSS programming is centralized and has an explicit disabled path"
else
	red "RSS key/indir/control programming must be centralized with disabled fallback"
fi

if grep -q 'pub(crate) fn set_rss_indir_default_8125(&self, queue_count: u8)' "$MMIO" &&
   grep -q 'unsafe_boundary::rxfh_indir_default' "$MMIO" &&
   grep -q 'u32::from(queue_count)' "$MMIO" &&
   grep -q 'r8125_bridge_rxfh_indir_default' "$UB" &&
   grep -q 'ethtool_rxfh_indir_default' "$BRIDGE_ETHTOOL" &&
   grep -q 'u32 r8125_bridge_rxfh_indir_default' "$HEADER"; then
	grn "RSS indirection table uses the kernel ethtool default helper"
else
	red "RSS indirection programming must use ethtool_rxfh_indir_default via cshim"
fi

if grep -q 'check_rss_hw_programming.sh' "$RUN"; then
	grn "RSS hardware programming gate is part of ci/run_checks.sh"
else
	red "ci/run_checks.sh must run the RSS hardware programming gate"
fi

exit "$rc"
