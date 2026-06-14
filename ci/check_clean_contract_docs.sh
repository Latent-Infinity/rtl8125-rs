#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Guard against comments that describe an outdated implementation stage
# or a future interrupt mode as current behavior. These checks are intentionally
# narrow: they catch stale phrases that previously contradicted the
# implementation without trying to lint prose in general.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

scan_files=(
	"$ROOT/src/r8125_rust_main.rs"
	"$ROOT/src/README.md"
	"$ROOT/src/pci.rs"
	"$ROOT/src/pm.rs"
	"$ROOT/src/netdev.rs"
	"$ROOT/src/netdev_bridge.h"
	"$ROOT/src/netdev_bridge.c"
	"$ROOT/src/netdev_bridge_rx_pool.c"
)

if grep -nE \
	'no net_device registration|M2, in progress|Still no `?net_device`?|M4-without-peer|M4-full packet-path development|M4 accepts the standard Ethernet MTU only|M4 baseline|jumbo support lands|type-state refactor queued|Census baseline: 43|`r8125_rust\.rs` \| crate root|Default 0 \(use the V2|helper picks V2 vs legacy|IRQ requested via pci::Device::request_irq|NetdevState::ocp_base|rx_slot_cpu|rx_slot_dma|tx_desc / tx_dma|bar_ptr`, `tx_desc`|post-`dma_unmap_single`|via `skb_put_data` in|manual tail/len bump|docs/perf/r8169_comparison\.md|dispostion|deferred to M4 cshim|Both pieces land at \*\*M4\*\*|plan §7 M2 gate' \
	"${scan_files[@]}" >/tmp/r8125_clean_contract_docs.$$ 2>/dev/null; then
	cat /tmp/r8125_clean_contract_docs.$$
	red "stale implementation-contract prose found"
else
	grn "source-level contracts avoid known stale implementation-stage / IRQ-mode phrases"
fi
rm -f /tmp/r8125_clean_contract_docs.$$

exit "$rc"
