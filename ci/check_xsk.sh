#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# AF_XDP zero-copy datapath contract (W4.1 Stage 4).
#
# Split: the xsk kernel-API knowledge (xsk_buff_*, xsk_tx_peek_desc,
# xsk_pool_dma_map, need-wakeup) lives in the cshim (netdev_bridge_xsk.c); the
# RX producer/consumer ring discipline (fill-cursor poll) and the XskTx TX slot
# disposition are safe Rust. Pin that split so a refactor can't move ring policy
# into C or bypass the tagged TX completion, and so the advertised xdp_features
# bit stays matched to a real bind path.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
need() { grep -qE -- "$2" "$1" && grn "$3" || red "$3 (missing in ${1#"$ROOT"/}: $2)"; }
reject() { grep -qE -- "$2" "$1" && red "$3 (present in ${1#"$ROOT"/}: $2)" || grn "$3"; }

XSK_C="$ROOT/src/netdev_bridge_xsk.c"
RXPOOL_C="$ROOT/src/netdev_bridge_rx_pool.c"
BRIDGE_C="$ROOT/src/netdev_bridge.c"
XDP_C="$ROOT/src/netdev_bridge_xdp.c"
HDR="$ROOT/src/netdev_bridge.h"
UB="$ROOT/src/unsafe_boundary.rs"
NETDEV="$ROOT/src/netdev.rs"
NAPI="$ROOT/src/napi.rs"

# 1. The cshim owns the xsk kernel API (RX alloc/consume + TX drain + dma map).
need "$XSK_C" 'xsk_buff_alloc\(' "ZC RX allocates from the xsk pool"
need "$XSK_C" 'MEM_TYPE_XSK_BUFF_POOL' "ZC xdp_rxq uses the XSK memory model"
need "$XSK_C" 'xsk_tx_peek_desc\(' "ZC TX drains the xsk TX ring"
need "$XSK_C" 'xsk_tx_completed\(' "ZC TX completes back to the socket ring"
need "$BRIDGE_C" 'xsk_pool_dma_map\(' "bind DMA-maps the umem to the device"
need "$BRIDGE_C" 'xsk_pool_dma_unmap\(' "unbind DMA-unmaps the umem"

# 2. The cshim TX producer delegates the TX-ring write to Rust (ring policy in
#    Rust): it must call the vtable op, not poke the descriptor ring directly.
need "$XSK_C" 'b->ops\.xsk_xmit_one\(b->priv' "ZC TX delegates the ring write to the Rust op"

# 3. The RX ring discipline + TX slot disposition are Rust.
need "$NAPI" 'fn process_rx_completions_zc' "ZC RX producer/consumer poll is Rust"
need "$NETDEV" 'XskTx' "TX reaper has the XskTx slot disposition"
need "$NETDEV" 'fn xsk_tx_enqueue' "ZC TX enqueue (ring producer) is Rust"
need "$NETDEV" 'pub\(crate\) posted:' "ZC RX fill-cursor (posted) is tracked in Rust"

# 4. The vtable op exists on both sides and is wired in the production table.
need "$HDR" 'int \(\*xsk_xmit_one\)\(void \*priv, u64 umem_dma, u32 len, u32 queue_id\)' "xsk_xmit_one in the C vtable"
need "$UB" 'pub xsk_xmit_one:' "xsk_xmit_one in the Rust BridgeOps"
need "$NETDEV" 'xsk_xmit_one: rust_xsk_xmit_one' "xsk_xmit_one wired in M4_FULL_OPS"

# 4b. The cold-start RX bootstrap: ndo_xsk_wakeup posts buffers synchronously via
#     the xsk_kick op (an empty ring takes no RX IRQ, so scheduling NAPI alone
#     cannot bootstrap), and the refill is serialised by the per-queue try-lock.
need "$XSK_C" 'b->ops\.xsk_kick\(b->priv' "ndo_xsk_wakeup posts buffers via xsk_kick"
need "$NETDEV" 'xsk_kick: rust_xsk_kick' "xsk_kick wired in M4_FULL_OPS"
need "$NAPI" 'fn zc_refill_locked' "shared ZC refill used by poll + wakeup"
need "$NETDEV" 'fn try_xsk_lock' "ZC ring try-lock serialises poll vs wakeup refill"

# 4c. Live per-queue RX reconfigure (no full stop+open / link-down on bind): the
#     bind swaps one queue's RX pool via rx_quiesce (RX engine off + free old) /
#     rx_restore (build new + RX on), NOT bridge_ndo_stop/bridge_ndo_open.
need "$BRIDGE_C" 'b->ops\.rx_quiesce\(b->priv' "ZC bind quiesces the queue (no full stop)"
need "$BRIDGE_C" 'b->ops\.rx_restore\(b->priv' "ZC bind restores the queue (no full open)"
need "$BRIDGE_C" 'queue_id == 0' "live ZC reconfigure is restricted to queue 0"
need "$BRIDGE_C" 'rollback_rc = b->ops\.rx_restore' "live ZC reconfigure rolls back on restore failure"
need "$NETDEV" 'fn rust_rx_quiesce' "per-queue RX quiesce is Rust (chip RX off + free)"
need "$NETDEV" 'fn rust_rx_restore' "per-queue RX restore is Rust (build + RX on)"

# 5. ndo wiring: bind dispatch, wakeup, and the advertised feature bit.
need "$XDP_C" 'case XDP_SETUP_XSK_POOL' "ndo_bpf dispatches XDP_SETUP_XSK_POOL"
need "$BRIDGE_C" '\.ndo_xsk_wakeup\s*=\s*r8125_bridge_xsk_wakeup' "ndo_xsk_wakeup wired"
need "$BRIDGE_C" 'NETDEV_XDP_ACT_XSK_ZEROCOPY' "xdp_features advertises XSK_ZEROCOPY"

# 6. The page_pool RX path must branch to the ZC datapath, not duplicate it.
need "$RXPOOL_C" 'q->xsk_pool' "page_pool RX path branches on a bound xsk pool"

exit "$rc"
