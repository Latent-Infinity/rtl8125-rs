#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static contract for hardware offload feature advertisement.
#
# VLAN offload is supported by the current 16-byte descriptor path:
#   - TX: opts2 carries the tag-valid bit + swapped TCI.
#   - RX: RTL8125 strips VLAN via RxConfig bits and reports the TCI in opts2.
#
# RXHASH is advertised with the V3 descriptor hash-reporting path (skb_set_hash
# + per-disposition counters). Multi-queue hardware RSS is now opt-in via
# rss_queues over the 22-vector V2 MSI-X surface; this gate only enforces that
# the RXHASH advertisement stays paired with its V3 parser + counters.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

BRIDGE="$ROOT/src/netdev_bridge.c"
HEADER="$ROOT/src/netdev_bridge.h"
NETDEV="$ROOT/src/netdev.rs"
NAPI="$ROOT/src/napi.rs"
OFFLOAD="$ROOT/src/netdev_bridge_offload.c"
RX_POOL="$ROOT/src/netdev_bridge_rx_pool.c"
REGS="$ROOT/src/regs.rs"
HW="$ROOT/src/hw.rs"
UB="$ROOT/src/unsafe_boundary.rs"

if grep -q 'NETIF_F_HW_VLAN_CTAG_TX' "$BRIDGE" &&
   grep -q 'NETIF_F_HW_VLAN_CTAG_RX' "$BRIDGE" &&
   grep -q 'NETIF_F_RXCSUM' "$BRIDGE" &&
   grep -q 'NETIF_F_TSO' "$BRIDGE" &&
   grep -q 'NETIF_F_RXHASH' "$BRIDGE"; then
	grn "netdev advertises checksum, TSO, CTAG VLAN, and RXHASH hardware features"
else
	red "netdev must advertise checksum/TSO, HW VLAN CTAG TX/RX, and RXHASH"
fi

open_feature_count=$(grep -c 'bridge_feature_flags(ndev->features)' "$BRIDGE" 2>/dev/null || true)
if grep -q '\.ndo_set_features[[:space:]]*=[[:space:]]*bridge_ndo_set_features' "$BRIDGE" &&
   [[ "$open_feature_count" -ge 2 ]] &&
   grep -q 'bridge_feature_flags(features)' "$BRIDGE"; then
	grn "open, MTU reopen, and runtime ethtool -K feature changes flow into Rust"
else
	red "open, MTU reopen, and ndo_set_features must pass effective feature flags to Rust"
fi

if grep -q 'R8125_BRIDGE_FEATURE_RXCSUM' "$HEADER" &&
   grep -q 'R8125_BRIDGE_FEATURE_RXVLAN' "$HEADER" &&
   grep -q 'R8125_BRIDGE_FEATURE_RXHASH' "$HEADER" &&
   grep -q 'BRIDGE_FEATURE_RXCSUM' "$NETDEV" &&
   grep -q 'BRIDGE_FEATURE_RXVLAN' "$NETDEV" &&
   grep -q 'BRIDGE_FEATURE_RXHASH' "$NETDEV" &&
   grep -q 'set_features: rust_set_features' "$NETDEV"; then
	grn "C/Rust feature-flag ABI mirrors RX checksum, RX VLAN, and RXHASH bits"
else
	red "C/Rust feature-flag ABI must expose RX checksum, RX VLAN, and RXHASH bits"
fi

if grep -q 'RX_VLAN_INNER_8125' "$REGS" &&
   grep -q 'RX_VLAN_OUTER_8125' "$REGS" &&
   grep -q 'RX_VLAN_8125' "$REGS" &&
   grep -q 'rx_feature_rcr' "$NETDEV" &&
   grep -q 'regs::RX_VLAN_8125' "$NETDEV" &&
   grep -q 'regs::CPLUSCMD_RX_CHKSUM' "$NETDEV"; then
	grn "Rust programs RTL8125 RxConfig VLAN strip bits and RX checksum bit"
else
	red "Rust must program RTL8125 RX VLAN via RCR and RX checksum via CPlusCmd"
fi

# TX VLAN: the C shim gathers tag presence + raw TCI (facts); the Rust offload
# policy (src/tx_offload.rs) sets the tag-valid bit + byte-swapped TCI in opts2.
TXOFF="$ROOT/src/tx_offload.rs"
if grep -q 'skb_vlan_tag_present' "$OFFLOAD" &&
   grep -q 'skb_vlan_tag_get' "$OFFLOAD" &&
   grep -q 'R8125_TXO_F_VLAN' "$OFFLOAD" &&
   grep -q 'TX_VLAN_TAG' "$TXOFF" &&
   grep -q 'swap_bytes' "$TXOFF"; then
	grn "TX VLAN tag encoding is wired into descriptor opts2 (C facts + Rust policy)"
else
	red "TX VLAN offload must encode tag-present and swapped TCI in opts2"
fi

if grep -q 'completion.opts2' "$NAPI" &&
   grep -q 'desc_opts2' "$UB" &&
   grep -q 'R8125_RX_VLAN_TAG' "$RX_POOL" &&
   grep -q '__vlan_hwaccel_put_tag' "$RX_POOL" &&
   grep -q 'swab16(desc_opts2' "$RX_POOL"; then
	grn "RX VLAN descriptor TCI is passed to the stack through hwaccel tag API"
else
	red "RX VLAN offload must pass desc opts2 TCI through __vlan_hwaccel_put_tag"
fi

if grep -q 'R8125_BRIDGE_FEATURE_RXHASH' "$BRIDGE" &&
   grep -q 'BRIDGE_FEATURE_RXHASH' "$NETDEV" &&
   grep -q 'const RXHASH_FEATURE_GATE: bool = true' "$NETDEV" &&
   grep -q 'NETIF_F_RXHASH' "$BRIDGE" &&
   grep -q 'set_rss_ctrl_8125(0)' "$HW" &&
   grep -q 'set_q_num_ctrl_8125(0)' "$HW" &&
   grep -q 'RX_HASH_INFO_ENABLED_BIT' "$NAPI" &&
   grep -q 'rx_hash_l3' "$RX_POOL" &&
   grep -q 'rx_hash_l4' "$RX_POOL" &&
   grep -q 'rx_hash_missing' "$RX_POOL" &&
   grep -q 'rx_hash_disabled' "$RX_POOL" &&
   grep -q 'skb_set_hash' "$RX_POOL" ; then
	grn "RXHASH is advertised with V3 parser, skb hash reporting, counters, and hw RSS baseline clear"
else
	red "RXHASH advertisement must stay paired with V3 parser, skb_set_hash, counters, and hw RSS baseline clear"
fi

rxhash_order=$(awk '
	/fn ndo_open\(state: &NetdevState/ { in_open=1 }
	in_open && /hw_start_8125b\(&regs\)/ { hw=NR }
	in_open && /apply_rss_programming\(state\)/ { apply=NR }
	in_open && /enable_chip_engines\(&regs\)/ { enable=NR; in_open=0 }
	END {
		if (hw && apply && enable && hw < apply && apply < enable)
			print "ok";
		else
			print "bad";
	}
' "$NETDEV")
if [[ "$rxhash_order" == "ok" ]]; then
	grn "RXHASH hash-engine programming happens after hw_start and before RX/TX enable"
else
	red "RXHASH hash-engine programming must run after hw_start_8125b and before enable_chip_engines"
fi

# NETIF_F_HIGHDMA must be advertised (the driver mandates a 64-bit DMA mask at
# probe). It is a fixed capability marker, so it belongs in features, not
# hw_features.
if grep -qE 'ndev->features \|= NETIF_F_HIGHDMA' "$ROOT/src/netdev_bridge.c"; then
	grn "NETIF_F_HIGHDMA advertised (64-bit DMA mask is mandatory at probe)"
else
	red "NETIF_F_HIGHDMA must be advertised in features (64-bit DMA mask is required)"
fi

exit "$rc"
