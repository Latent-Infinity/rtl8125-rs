#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Full-RSS prerequisite: the C/Rust bridge must be queue-aware. queue_id is
# threaded through NAPI poll, RX page-pool lifecycle, and RX packet delivery.
# B6.1 foundation: the driver allocates RX_QUEUE_COUNT(=4) DMA rings + NAPI
# instances, but the RUNTIME active count is clamped by
# `layout::active_rx_queues` (1 unless an rss_queues opt-in raises it once the
# per-vector IRQ + RSS-spread increments land).

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

BRIDGE="$ROOT/src/netdev_bridge.c"
HEADER="$ROOT/src/netdev_bridge.h"
INTERNAL="$ROOT/src/netdev_bridge_internal.h"
RX_POOL="$ROOT/src/netdev_bridge_rx_pool.c"
NETDEV="$ROOT/src/netdev.rs"
NAPI="$ROOT/src/napi.rs"
UB="$ROOT/src/unsafe_boundary.rs"
REGS="$ROOT/src/regs.rs"
MMIO="$ROOT/src/mmio.rs"

if grep -Fq 'struct r8125_bridge_rx_queue' "$INTERNAL" &&
   grep -Fq 'struct napi_struct napi' "$INTERNAL" &&
   grep -Fq 'struct page_pool *page_pool' "$INTERNAL" &&
   grep -Fq 'unsigned int queue_id' "$INTERNAL" &&
   grep -Fq 'rxq[R8125_BRIDGE_RX_QUEUE_COUNT]' "$INTERNAL"; then
	grn "bridge owns NAPI/page_pool through a queue object"
else
	red "bridge must own NAPI/page_pool through r8125_bridge_rx_queue"
fi

if grep -Fq 'int (*poll)(void *priv, unsigned int queue_id, int budget)' "$HEADER" &&
   grep -Fq 'pub poll: extern "C" fn(cookie: *mut c_void, queue_id: u32, budget: c_int)' "$UB" &&
   grep -Fq 'extern "C" fn rust_poll(cookie: *mut c_void, queue_id: u32, budget: c_int)' "$NETDEV" &&
   grep -Fq 'pub(crate) fn poll(state: &NetdevState, queue_id: u32, budget: c_int)' "$NAPI"; then
	grn "poll vtable carries queue_id through C and Rust"
else
	red "poll vtable must carry queue_id through header, unsafe boundary, netdev, and NAPI"
fi

if grep -Fq 'container_of(napi, struct r8125_bridge_rx_queue, napi)' "$BRIDGE" &&
   grep -Fq 'ops.poll(b->priv, rxq->queue_id, budget)' "$BRIDGE"; then
	grn "C NAPI wrapper derives queue_id from the queue object"
else
	red "bridge_napi_poll must derive queue_id from r8125_bridge_rx_queue"
fi

if grep -Fq 'r8125_bridge_rx_pool_create(struct net_device *ndev, unsigned int queue_id' "$RX_POOL" &&
   grep -Fq 'r8125_bridge_rx_alloc(struct net_device *ndev, unsigned int queue_id' "$RX_POOL" &&
   grep -Fq 'r8125_bridge_rx_free(struct net_device *ndev, unsigned int queue_id' "$RX_POOL" &&
   grep -Fq 'r8125_bridge_rx_one_packet(struct net_device *ndev, unsigned int queue_id' "$RX_POOL" &&
   grep -Fq 'r8125_bridge_rxq(b, queue_id)' "$RX_POOL"; then
	grn "RX page-pool lifecycle and RX delivery are queue-id aware"
else
	red "RX page-pool lifecycle and RX delivery must accept queue_id"
fi

if grep -Fq 'pub(crate) const RX_QUEUE_COUNT: usize = 4;' "$NETDEV" &&
   grep -Fq 'crate::layout::active_rx_queues(' "$NETDEV" &&
   grep -Fq 'for queue_id in 0..active_rx_queues(state)' "$NETDEV" &&
   grep -Fq 'ub::rx_pool_create(ndev, queue_id, RING_LEN)' "$NETDEV" &&
   grep -Fq 'ub::rx_alloc(ndev, queue_id)' "$NETDEV" &&
   grep -Fq 'ub::rx_free(ndev, queue_id, slot.cpu)' "$NETDEV" &&
   grep -Fq 'ub::rx_pool_destroy(ndev, queue_id)' "$NETDEV"; then
	grn "B6.1: RX_QUEUE_COUNT=4 foundation; runtime active count clamped via layout::active_rx_queues, open/stop queue-indexed"
else
	red "B6.1 foundation must set RX_QUEUE_COUNT=4 and drive setup loops by active_rx_queues()"
fi

PCI="$ROOT/src/pci.rs"
if grep -Fq 'rx_rings: [ring::RxRing; crate::netdev::RX_QUEUE_COUNT]' "$PCI" &&
   grep -Fq 'rx_rings[i].desc_ptr_mut()' "$PCI" &&
   grep -Fq 'unsigned int active_rx_queues;' "$INTERNAL" &&
   grep -Fq '#define R8125_BRIDGE_RX_QUEUE_COUNT	4' "$INTERNAL"; then
	grn "probe allocates one DMA RX ring per queue; C bridge sizes 4 queues with a runtime active count"
else
	red "probe must allocate an RX ring per queue and C must expose active_rx_queues with COUNT=4"
fi

if grep -Fq 'ub::bridge_rx_one_packet(' "$NAPI" &&
   grep -Fq 'queue_id,' "$NAPI" &&
   grep -Fq 'ub::bridge_napi_complete_done(ndev, queue_id, work_done)' "$NAPI"; then
	grn "NAPI RX delivery and complete_done use queue_id"
else
	red "NAPI must pass queue_id to RX delivery and complete_done"
fi

if grep -Fq 'pub(crate) rx_queues: [RxQueueState; RX_QUEUE_COUNT]' "$NETDEV" &&
   grep -Fq 'pub(crate) struct RxQueueState' "$NETDEV" &&
   grep -Fq 'pub(crate) fn rx_queue(&self, queue_id: u32) -> Option<&RxQueueState>' "$NETDEV" &&
   grep -Fq 'state.rx_queue(queue_id)' "$NAPI"; then
	grn "Rust RX hot path resolves queue_id into the RxQueueState array"
else
	red "Rust RX hot path must resolve queue_id into rx_queues[]"
fi

if grep -Fq 'RDSAR_Q1_LOW_8125' "$REGS" &&
   grep -Fq 'pub(crate) fn set_rx_ring_base_queue(&self, queue_id: usize, addr: u64)' "$MMIO" &&
   grep -Fq 'RDSAR_Q1_LOW_8125 + (queue_id - 1) * 8' "$MMIO"; then
	grn "future RX queue base programming uses vendor RDSAR_Q1 layout"
else
	red "multi-ring RSS scaffold must define the vendor RX queue base register layout"
fi

exit "$rc"
