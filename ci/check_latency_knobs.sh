#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Transferability: [netdev]
#
# Latency-aligned discipline gate.
#
# Three tuning knobs (Candidates G, L, M of
# `docs/RX_OPTIMIZATION_CANDIDATES.md`) trade ~nothing of value for
# real tail-latency improvements at MTU 1500 line rate. They sit in
# unrelated parts of the cshim, so a future refactor could easily
# remove one without noticing. This gate ensures they stay in tree.
#
#   G — `ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS` at
#       `bridge_alloc`, plus `dev_sw_netstats_rx_add` / `_tx_add`
#       in the RX super-call (`netdev_bridge_rx_pool.c`) and TX
#       accounting (`netdev_bridge_offload.c`).
#   L — `r8125_bridge_irq_pin_cpu` exists and is called from
#       Rust probe with a non-negative CPU index.
#   M — `ndev->tx_queue_len = 256` at `bridge_alloc`.
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

# ── Candidate G — per-CPU TSTATS ─────────────────────────────────
if grep -qE 'ndev->pcpu_stat_type[[:space:]]*=[[:space:]]*NETDEV_PCPU_STAT_TSTATS' "$BRIDGE_C"; then
	grn "G: ndev->pcpu_stat_type set to NETDEV_PCPU_STAT_TSTATS"
else
	red "G: bridge_alloc must set ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS"
fi
if grep -q 'dev_sw_netstats_rx_add' "$RX_POOL_C" 2>/dev/null; then
	grn "G: RX super-call uses dev_sw_netstats_rx_add"
else
	red "G: bridge_rx_one_packet must call dev_sw_netstats_rx_add(ndev, len)"
fi
if grep -q 'dev_sw_netstats_tx_add' "$OFFLOAD_C" 2>/dev/null; then
	grn "G: TX accounting uses dev_sw_netstats_tx_add"
else
	red "G: r8125_bridge_account_tx must use dev_sw_netstats_tx_add"
fi
# G negative — the old shared-cache-line pattern must NOT come back
if grep -qE 'WRITE_ONCE\(ndev->stats\.(rx|tx)_packets' "$BRIDGE_C" "$RX_POOL_C" "$OFFLOAD_C" 2>/dev/null; then
	red "G: WRITE_ONCE(ndev->stats.{rx,tx}_packets, ...) regression — use dev_sw_netstats_{rx,tx}_add"
else
	grn "G: no WRITE_ONCE(ndev->stats.{rx,tx}_packets) regressions"
fi

# ── Candidate L — IRQ affinity hint ─────────────────────────────
if grep -q 'r8125_bridge_irq_pin_cpu' "$BRIDGE_C"; then
	grn "L: r8125_bridge_irq_pin_cpu cshim helper defined"
else
	red "L: cshim must define r8125_bridge_irq_pin_cpu(unsigned int irq, int cpu)"
fi
if grep -q 'cpumask_of(cpu)' "$BRIDGE_C"; then
	grn "L: helper uses cpumask_of() (no stack-frame growth)"
else
	red "L: r8125_bridge_irq_pin_cpu must use cpumask_of(cpu) — building a struct cpumask on stack blows -Wframe-larger-than=1024"
fi
if grep -q 'irq_set_affinity_and_hint' "$BRIDGE_C"; then
	grn "L: helper calls irq_set_affinity_and_hint"
else
	red "L: helper must call irq_set_affinity_and_hint (the modern API)"
fi
# Multiline-tolerant: just confirm the safe wrapper is called somewhere in
# pci.rs (the only file that should pin the IRQ). The exact argument form
# may span multiple lines for rustfmt.
if grep -qE '::(bridge_irq_pin_cpu|bridge_irq_pin_auto)' "$PCI_RS"; then
	grn "L: pci.rs probe calls IRQ pin helper (explicit or auto)"
else
	red "L: src/pci.rs probe must call unsafe_boundary::bridge_irq_pin_{cpu,auto}"
fi
# RX Opt #4: irq_pin_cpu module param with PCI-local default
if grep -qE 'irq_pin_cpu:\s*u8' "$ROOT/src/r8125_rust_main.rs"; then
	grn "#4: irq_pin_cpu module param declared"
else
	red "#4: r8125_rust_main.rs must declare irq_pin_cpu: u8 module param"
fi
# multi-queue: the auto policy now SPREADS active vectors across distinct CPUs
# (host-tested layout::irq_affinity_cpu) instead of pinning all to one
# NUMA-local CPU — the fix for multi-queue TX DMA-map drops from per-CPU
# IOVA rcache churn. The cshim provides the fan-out base + width.
if grep -q 'r8125_bridge_node_base_cpu' "$BRIDGE_C" &&
	grep -q 'r8125_bridge_num_online_cpus' "$BRIDGE_C"; then
	grn "#4/multi-queue: cshim defines affinity-spread inputs (node_base_cpu + num_online_cpus)"
else
	red "#4/multi-queue: cshim must define r8125_bridge_node_base_cpu + r8125_bridge_num_online_cpus"
fi
if grep -q 'irq_affinity_cpu' "$PCI_RS"; then
	grn "#4/multi-queue: pci.rs spreads vectors via host-tested layout::irq_affinity_cpu"
else
	red "#4/multi-queue: pci.rs auto-pin must fan out via crate::layout::irq_affinity_cpu"
fi
if grep -q 'cpumask_of_node\|NUMA_NO_NODE' "$BRIDGE_C"; then
	grn "#4: auto-pick base respects NUMA topology"
else
	red "#4: auto-pick base must use cpumask_of_node(dev_to_node(pdev->dev))"
fi

# ── Candidate M — tx_queue_len ─────────────────────────────────
if grep -qE 'ndev->tx_queue_len[[:space:]]*=[[:space:]]*256' "$BRIDGE_C"; then
	grn "M: ndev->tx_queue_len = 256 (bufferbloat capped at ~870us @ 2.35 Gbps)"
else
	red "M: bridge_alloc must set ndev->tx_queue_len = 256 (kernel default 1000 is bufferbloat)"
fi

exit "$rc"
