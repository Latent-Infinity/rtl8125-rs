#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Transferability: [netdev]
#
# DMA barrier discipline gate.
#
# The driver crosses the device-memory boundary in two directions:
#
#   RX read   — chip clears OWN, CPU reads opts1+addr+opts2.
#               `ub::dma_rmb()` BETWEEN the OWN check and the rest of
#               the descriptor read keeps the chip's stores from being
#               reordered with the OWN clear on ARM / RISC-V.
#
#   TX/RX write — CPU writes addr+opts2 first, issues `dma_wmb()`,
#               then publishes opts1 with OWN set. The opts1 write is
#               the ownership transfer.
#
# r8169 calls dma_wmb() at the same point (r8169_main.c:4189 + :4636).
# r8169 calls dma_rmb() at the equivalent RX point (r8169_main.c:4824).
#
# This gate asserts both barriers exist at the right structural location.
# It does NOT enforce specific arch behaviour — that's the kernel's
# `<asm/barrier.h>` macros — only that the Rust call sites use the
# ordered descriptor publisher.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

BRIDGE_C="$ROOT/src/netdev_bridge.c"
BRIDGE_H="$ROOT/src/netdev_bridge.h"
UB_RS="$ROOT/src/unsafe_boundary.rs"
NAPI_RS="$ROOT/src/napi.rs"
NETDEV_RS="$ROOT/src/netdev.rs"

# ── cshim helpers exist and use the right kernel primitives ──────────────
if grep -qE 'void r8125_bridge_dma_rmb\(void\)' "$BRIDGE_C" \
   && grep -qE 'dma_rmb\(\);' "$BRIDGE_C"; then
	grn "cshim: r8125_bridge_dma_rmb calls dma_rmb()"
else
	red "cshim: r8125_bridge_dma_rmb missing or doesn't call dma_rmb()"
fi
if grep -qE 'void r8125_bridge_dma_wmb\(void\)' "$BRIDGE_C" \
   && grep -qE 'dma_wmb\(\);' "$BRIDGE_C"; then
	grn "cshim: r8125_bridge_dma_wmb calls dma_wmb()"
else
	red "cshim: r8125_bridge_dma_wmb missing or doesn't call dma_wmb()"
fi
if grep -q 'r8125_bridge_dma_wmb(void)' "$BRIDGE_H"; then
	grn "cshim: dma_wmb declared in netdev_bridge.h"
else
	red "cshim: r8125_bridge_dma_wmb missing from netdev_bridge.h"
fi

# ── Rust safe wrappers exposed at unsafe_boundary ──────────────────────
if grep -qE 'pub\(crate\) fn dma_rmb\(\)' "$UB_RS"; then
	grn "rust: ub::dma_rmb() safe wrapper"
else
	red "rust: unsafe_boundary missing dma_rmb() wrapper"
fi
if grep -qE 'pub\(crate\) fn dma_wmb\(\)' "$UB_RS"; then
	grn "rust: ub::dma_wmb() safe wrapper"
else
	red "rust: unsafe_boundary missing dma_wmb() wrapper"
fi
publish_body=$(
	awk '
		/^pub\(crate\) fn desc_publish_own\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$UB_RS"
)
addr_line=$(grep -n 'write_volatile(value.addr)' <<<"$publish_body" | head -n1 | cut -d: -f1)
opts2_line=$(grep -n 'write_volatile(value.opts2)' <<<"$publish_body" | head -n1 | cut -d: -f1)
wmb_line=$(grep -n '^[[:space:]]*dma_wmb();' <<<"$publish_body" | head -n1 | cut -d: -f1)
opts1_line=$(grep -n 'write_volatile(value.opts1)' <<<"$publish_body" | head -n1 | cut -d: -f1)
if [[ -n "$addr_line" && -n "$opts2_line" && -n "$wmb_line" && -n "$opts1_line" ]] \
   && (( addr_line < wmb_line && opts2_line < wmb_line && wmb_line < opts1_line )); then
	grn "rust: desc_publish_own orders addr/opts2 before dma_wmb before opts1"
else
	red "rust: desc_publish_own must write addr/opts2, call dma_wmb(), then write opts1"
fi

# ── RX open path: initial OWN-set pre-post also uses ordered publish ───
prepost_body=$(
	awk '
		/^fn pre_post_rx_descriptors\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$NETDEV_RS"
)
if grep -q 'ub::desc_publish_own(' <<<"$prepost_body"; then
	grn "rust: pre_post_rx_descriptors uses ordered OWN publisher"
else
	red "rust: pre_post_rx_descriptors must use ub::desc_publish_own() for initial RX OWN publish"
fi

# ── RX path: dma_rmb between OWN check and rest of descriptor ──────────
# In process_rx_completions, dma_rmb must appear between the OWN-clear
# read and the rest of the RX descriptor field access. Without the
# barrier, the field reads can be reordered on weakly-ordered archs.
rx_body=$(
	awk '
		/^fn process_rx_completions\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$NAPI_RS"
)
if grep -q 'ub::dma_rmb()' <<<"$rx_body"; then
	grn "rust: process_rx_completions calls ub::dma_rmb()"
else
	red "rust: process_rx_completions must call ub::dma_rmb() after the OWN-clear read"
fi
if grep -q 'ub::desc_publish_own(' <<<"$rx_body"; then
	grn "rust: process_rx_completions uses ordered OWN publisher for RX re-post"
else
	red "rust: process_rx_completions must use ub::desc_publish_own() for the OWN-set RX re-post"
fi

# ── TX path: dma_wmb before FirstFrag publish ─────────────────────────
xmit_body=$(
	awk '
		/^fn ndo_start_xmit\(/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}/ { exit }
	' "$NETDEV_RS"
)
if grep -q 'ub::desc_publish_own(' <<<"$xmit_body"; then
	grn "rust: ndo_start_xmit uses ordered OWN publisher for FirstFrag"
else
	red "rust: ndo_start_xmit must use ub::desc_publish_own() for the FirstFrag publish"
fi

exit "$rc"
