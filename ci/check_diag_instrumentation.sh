#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Transferability: [netdev]
#
# Static guard for the temporary stall-localisation ethtool surface.
# The diagnostic counters are intentionally temporary, but while present
# they must still follow the Rust unsafe-boundary and hot-path state rules.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

NETDEV="$ROOT/src/netdev.rs"
UB="$ROOT/src/unsafe_boundary.rs"
ETHTOOL="$ROOT/src/netdev_bridge_ethtool.c"
BRIDGE_C="$ROOT/src/netdev_bridge.c"
BRIDGE_H="$ROOT/src/netdev_bridge.h"
NAPI="$ROOT/src/napi.rs"

netdev_unsafe=$(
	grep -nE '\bunsafe[[:space:]]*\{' "$NETDEV" 2>/dev/null |
		grep -vE '^[0-9]+:[[:space:]]*(//|///|//!|\*)' || true
)
if ! grep -q '#\[allow(unsafe_code)\]' "$NETDEV" \
   && [[ -z "$netdev_unsafe" ]]; then
	grn "diag: netdev.rs remains safe Rust"
else
	red "diag: raw-pointer export/unsafe blocks must live in unsafe_boundary.rs, not netdev.rs"
fi

if grep -q 'extern "C" fn r8125_rust_diag_snapshot' "$UB" \
   && grep -q 'core::ptr::write(out, snap)' "$UB" \
   && ! grep -q 'extern "C" fn r8125_rust_diag_snapshot' "$NETDEV"; then
	grn "diag: C snapshot entry point lives in unsafe_boundary"
else
	red "diag: r8125_rust_diag_snapshot must be exported from unsafe_boundary only"
fi

diag_fields=(
	last_irq_jiffies
	last_napi_jiffies
	last_rx_packet_jiffies
	last_tx_complete_jiffies
	last_xmit_jiffies
	napi_polls_empty
	rx_completions_seen
	tx_packets_reaped
)
for f in "${diag_fields[@]}"; do
	if grep -q "pub(crate) $f: u64" "$NETDEV" \
	   && grep -q "u64 $f;" "$ETHTOOL"; then
		grn "diag: snapshot field $f mirrored in Rust and C"
	else
		red "diag: snapshot field $f missing from Rust or C mirror"
	fi
done

diag_statics=(
	LAST_IRQ_JIFFIES
	LAST_NAPI_JIFFIES
	LAST_RX_PACKET_JIFFIES
	LAST_TX_COMPLETE_JIFFIES
	LAST_XMIT_JIFFIES
	NAPI_POLLS_EMPTY
	RX_COMPLETIONS_SEEN
	TX_PACKETS_REAPED
)
for s in "${diag_statics[@]}"; do
	if grep -q "static $s: CachePadded<AtomicU64>" "$NETDEV"; then
		grn "diag: $s is cache padded"
	else
		red "diag: $s must be CachePadded<AtomicU64>"
	fi
done

if grep -q 'r8125_bridge_jiffies' "$BRIDGE_C" \
   && grep -q 'r8125_bridge_jiffies' "$BRIDGE_H" \
   && grep -q 'pub(crate) fn bridge_jiffies' "$UB"; then
	grn "diag: jiffies helper is declared and wrapped"
else
	red "diag: jiffies helper missing from cshim/header/unsafe_boundary"
fi

diag_strings=(
	diag_last_irq_ms_ago
	diag_last_napi_ms_ago
	diag_last_rx_pkt_ms_ago
	diag_last_tx_done_ms_ago
	diag_last_xmit_ms_ago
	diag_napi_polls_empty
	diag_rx_completions_seen
	diag_tx_packets_reaped
)
for s in "${diag_strings[@]}"; do
	if grep -q "\"$s\"" "$ETHTOOL"; then
		grn "diag: ethtool stat $s present"
	else
		red "diag: ethtool stat $s missing"
	fi
done

if grep -q 'note_rx_completion()' "$NAPI" \
   && grep -q 'note_tx_complete()' "$NAPI" \
   && grep -q 'note_napi_empty()' "$NAPI" \
   && grep -q 'note_xmit()' "$NETDEV"; then
	grn "diag: hot-path note sites present"
else
	red "diag: expected hot-path note sites are missing"
fi

exit "$rc"
