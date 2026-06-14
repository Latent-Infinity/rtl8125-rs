#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Transferability: [netdev]
#
# Latency-aligned discipline gate.
#
# Three tuning knobs (documented in
# `docs/RX_OPTIMIZATION_CANDIDATES.md`) trade ~nothing of value for
# real tail-latency improvements at MTU 1500 line rate. They sit in
# unrelated parts of the cshim, so a future refactor could easily
# remove one without noticing. This gate ensures they stay in tree.
#
#   - per-CPU TSTATS: `ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS`
#       at `bridge_alloc`, plus `dev_sw_netstats_rx_add` / `_tx_add`
#       in the RX super-call (`netdev_bridge_rx_pool.c`) and TX
#       accounting (`netdev_bridge_offload.c`).
#   - IRQ affinity hint: `r8125_bridge_irq_pin_cpu` exists and is
#       called from Rust probe with a non-negative CPU index.
#   - tx_queue_len: `ndev->tx_queue_len = 256` at `bridge_alloc`.
#
# Skipped vacuously if `src/netdev_bridge.c` is missing.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

BRIDGE_C="$ROOT/src/netdev_bridge.c"
RX_POOL_C="$ROOT/src/netdev_bridge_rx_pool.c"
OFFLOAD_C="$ROOT/src/netdev_bridge_offload.c"
PCI_RS="$ROOT/src/pci.rs"
UB_RS="$ROOT/src/unsafe_boundary.rs"

if [[ ! -f "$BRIDGE_C" ]]; then
	yel "$BRIDGE_C missing — skipping"
	exit 0
fi

# ── per-CPU TSTATS ───────────────────────────────────────────────
if grep -qE 'ndev->pcpu_stat_type[[:space:]]*=[[:space:]]*NETDEV_PCPU_STAT_TSTATS' "$BRIDGE_C"; then
	grn "TSTATS: ndev->pcpu_stat_type set to NETDEV_PCPU_STAT_TSTATS"
else
	red "TSTATS: bridge_alloc must set ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS"
fi
if grep -q 'dev_sw_netstats_rx_add' "$RX_POOL_C" 2>/dev/null; then
	grn "TSTATS: RX super-call uses dev_sw_netstats_rx_add"
else
	red "TSTATS: bridge_rx_one_packet must call dev_sw_netstats_rx_add(ndev, len)"
fi
if grep -q 'dev_sw_netstats_tx_add' "$OFFLOAD_C" 2>/dev/null; then
	grn "TSTATS: TX accounting uses dev_sw_netstats_tx_add"
else
	red "TSTATS: r8125_bridge_account_tx must use dev_sw_netstats_tx_add"
fi
# the old shared-cache-line pattern must NOT come back
if grep -qE 'WRITE_ONCE\(ndev->stats\.(rx|tx)_packets' "$BRIDGE_C" "$RX_POOL_C" "$OFFLOAD_C" 2>/dev/null; then
	red "TSTATS: WRITE_ONCE(ndev->stats.{rx,tx}_packets, ...) regression — use dev_sw_netstats_{rx,tx}_add"
else
	grn "TSTATS: no WRITE_ONCE(ndev->stats.{rx,tx}_packets) regressions"
fi

# ── IRQ affinity hint ───────────────────────────────────────────
if grep -q 'r8125_bridge_irq_pin_cpu' "$BRIDGE_C"; then
	grn "affinity: r8125_bridge_irq_pin_cpu cshim helper defined"
else
	red "affinity: cshim must define r8125_bridge_irq_pin_cpu(unsigned int irq, int cpu)"
fi
if grep -q 'cpumask_of(cpu)' "$BRIDGE_C"; then
	grn "affinity: helper uses cpumask_of() (no stack-frame growth)"
else
	red "affinity: r8125_bridge_irq_pin_cpu must use cpumask_of(cpu) — building a struct cpumask on stack blows -Wframe-larger-than=1024"
fi
if grep -q 'irq_set_affinity_and_hint' "$BRIDGE_C"; then
	grn "affinity: helper calls irq_set_affinity_and_hint"
else
	red "affinity: helper must call irq_set_affinity_and_hint (the modern API)"
fi
# Multiline-tolerant: just confirm the safe wrapper is called somewhere in
# pci.rs (the only file that should pin the IRQ). The exact argument form
# may span multiple lines for rustfmt.
if grep -qE '::(bridge_irq_pin_cpu|bridge_irq_pin_auto)' "$PCI_RS"; then
	grn "affinity: pci.rs probe calls IRQ pin helper (explicit or auto)"
else
	red "affinity: src/pci.rs probe must call unsafe_boundary::bridge_irq_pin_{cpu,auto}"
fi
# irq_pin_cpu module param with PCI-local default
if grep -qE 'irq_pin_cpu:\s*u8' "$ROOT/src/r8125_rust_main.rs"; then
	grn "affinity: irq_pin_cpu module param declared"
else
	red "affinity: r8125_rust_main.rs must declare irq_pin_cpu: u8 module param"
fi
# multi-queue: the auto policy now SPREADS active vectors across distinct CPUs
# (host-tested layout::irq_affinity_cpu) instead of pinning all to one
# NUMA-local CPU — the fix for multi-queue TX DMA-map drops from per-CPU
# IOVA rcache churn. The cshim provides the fan-out base + width.
if grep -q 'r8125_bridge_node_base_cpu' "$BRIDGE_C" &&
	grep -q 'r8125_bridge_num_online_cpus' "$BRIDGE_C"; then
	grn "multi-queue: cshim defines affinity-spread inputs (node_base_cpu + num_online_cpus)"
else
	red "multi-queue: cshim must define r8125_bridge_node_base_cpu + r8125_bridge_num_online_cpus"
fi
if grep -q 'irq_affinity_cpu' "$PCI_RS"; then
	grn "multi-queue: pci.rs spreads vectors via host-tested layout::irq_affinity_cpu"
else
	red "multi-queue: pci.rs auto-pin must fan out via crate::layout::irq_affinity_cpu"
fi
if grep -q 'cpumask_of_node\|NUMA_NO_NODE' "$BRIDGE_C"; then
	grn "affinity: auto-pick base respects NUMA topology"
else
	red "affinity: auto-pick base must use cpumask_of_node(dev_to_node(pdev->dev))"
fi

# ── tx_queue_len ───────────────────────────────────────────────
if grep -qE 'ndev->tx_queue_len[[:space:]]*=[[:space:]]*256' "$BRIDGE_C"; then
	grn "tx_queue_len: ndev->tx_queue_len = 256 (bufferbloat capped at ~870us @ 2.35 Gbps)"
else
	red "tx_queue_len: bridge_alloc must set ndev->tx_queue_len = 256 (kernel default 1000 is bufferbloat)"
fi

exit "$rc"
