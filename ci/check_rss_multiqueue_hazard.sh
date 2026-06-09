#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static contract for the RTL8125 full-RSS hazard runtime harness.
#
# This does not claim hardware RSS is safe. It prevents the repo from losing the
# runtime proof shape required before N>1 RSS can be accepted: queue/IRQ spread,
# fragmented/small-packet integrity, TCP corruption detection, and kworker/IRQ
# runaway detection.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/rss_multiqueue_hazard_validate.sh"
PLAN="$ROOT/docs/RSS_RXHASH_IMPLEMENTATION_PLAN.md"
RUN="$ROOT/ci/run_checks.sh"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

if [[ -x "$SCRIPT" ]] && bash -n "$SCRIPT"; then
	grn "full-RSS hazard harness exists, is executable, and parses"
else
	red "scripts/rss_multiqueue_hazard_validate.sh must exist, be executable, and parse"
fi

if grep -q 'MIN_RX_QUEUES' "$SCRIPT" &&
	grep -q 'receive-hashing' "$SCRIPT" &&
	grep -q 'ethtool -x' "$SCRIPT" &&
	grep -q 'ethtool_T.txt' "$SCRIPT" &&
	grep -q 'active_rx_vectors' "$SCRIPT" &&
	grep -q '/proc/interrupts' "$SCRIPT"; then
	grn "harness refuses non-RSS state and records RSS/IRQ/timestamping state"
else
	red "harness must prove N>1 RSS state plus active RX interrupt distribution and timestamping capabilities"
fi

if grep -q 'SMALL_UDP_LEN' "$SCRIPT" &&
	grep -q 'FRAG_UDP_LEN' "$SCRIPT" &&
	grep -q 'json_out_of_order' "$SCRIPT" &&
	grep -q 'udp_loss_pct' "$SCRIPT" &&
	grep -q 'MAX_UDP_LOSS_PCT' "$SCRIPT" &&
	grep -q 'rx_dropped_error' "$SCRIPT"; then
	grn "harness covers small and fragmented UDP drops/out-of-order/driver drops"
else
	red "harness must cover small + fragmented UDP and record loss/out-of-order/rx drops"
fi

if grep -q 'run_tcp_integrity' "$SCRIPT" &&
	grep -q 'sha256sum' "$SCRIPT" &&
	grep -q 'nc -l' "$SCRIPT" &&
	grep -q 'integrity.csv' "$SCRIPT"; then
	grn "harness includes end-to-end TCP data integrity proof"
else
	red "harness must include a TCP byte-integrity transfer with SHA-256 comparison"
fi

if grep -q 'kworker' "$SCRIPT" &&
	grep -q 'KWORKER_MAX_PCPU' "$SCRIPT" &&
	grep -q 'QUIET_MAX_IRQ_DELTA' "$SCRIPT" &&
	grep -q 'quiet_irq_loop_check' "$SCRIPT" &&
	grep -q 'mpstat -P ALL' "$SCRIPT"; then
	grn "harness watches kworker CPU, quiet IRQ loops, and per-CPU softirq load"
else
	red "harness must watch kworker CPU, quiet IRQ loops, and per-CPU softirq load"
fi

if grep -q 'fault_scan' "$SCRIPT" &&
	grep -q 'DMA-API' "$SCRIPT" &&
	grep -q 'NETDEV WATCHDOG' "$SCRIPT"; then
	grn "harness captures kernel fault signatures after stress"
else
	red "harness must scan dmesg for driver/kernel fault signatures"
fi

if grep -q 'evaluate_results' "$SCRIPT" &&
	grep -q 'exit 1' "$SCRIPT" &&
	grep -q 'TCP integrity SHA-256' "$SCRIPT" &&
	grep -q 'active_rx_vectors=.*below' "$SCRIPT"; then
	grn "harness exits nonzero when captured evidence violates B6 criteria"
else
	red "harness must evaluate captured evidence and exit nonzero on B6 failures"
fi

if grep -q 'rss_multiqueue_hazard_validate.sh' "$PLAN" &&
	grep -q 'B6' "$PLAN" &&
	grep -q 'out_of_order=0' "$PLAN" &&
	grep -q 'timestamping' "$PLAN" &&
	grep -q 'kworker' "$PLAN"; then
	grn "RSS plan records B6 acceptance criteria for full-RSS hazards"
else
	red "RSS plan must document B6 full-RSS hazard acceptance criteria"
fi

if grep -q 'check_rss_multiqueue_hazard.sh' "$RUN"; then
	grn "full-RSS hazard gate is wired into ci/run_checks.sh"
else
	red "ci/run_checks.sh must run check_rss_multiqueue_hazard.sh"
fi

exit "$rc"
