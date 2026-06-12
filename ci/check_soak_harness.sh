#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static guard for the long-running soak harnesses. These scripts are
# hardware gates, so a silent traffic generator failure must not report
# a clean driver soak.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

ACTIVE="$ROOT/ci/check_active_soak.sh"
WATCH="$ROOT/scripts/soak_watch.sh"
PERF="$ROOT/scripts/perf_characterize.sh"
BYTE_BUDGET="$ROOT/scripts/gateway_tx_byte_budget_sweep.sh"
HW_OFFLOAD="$ROOT/scripts/gateway_hw_offload_validate.sh"
KASAN_SOAK="$ROOT/scripts/gateway_kasan_soak.sh"
CAMPAIGN="$ROOT/scripts/gateway_kasan_soak_campaign.sh"
KVM_SOAK="$ROOT/scripts/kvm_kasan_soak.sh"
KVM_CAMPAIGN="$ROOT/scripts/kvm_kasan_soak_campaign.sh"

if bash -n "$ACTIVE" && bash -n "$WATCH" && bash -n "$PERF" \
   && bash -n "$BYTE_BUDGET" && bash -n "$HW_OFFLOAD" \
   && bash -n "$KASAN_SOAK" && bash -n "$CAMPAIGN" \
   && bash -n "$KVM_SOAK" && bash -n "$KVM_CAMPAIGN"; then
	grn "soak/perf harness scripts parse under bash"
else
	red "soak/perf harness scripts must be valid bash"
fi

# Hardened KASAN soak: strict pass criteria must be present (a wedge/leak must
# FAIL, not silently pass). These guard the harness against regressing to a
# tx_delta>0-style trivial pass.
if grep -q 'STALL' "$KASAN_SOAK" \
   && grep -q 'kmemleak' "$KASAN_SOAK" \
   && grep -q 'HW_ERR_GROWTH' "$KASAN_SOAK" \
   && grep -q 'LOW_TPUT' "$KASAN_SOAK" \
   && grep -q 'timeseries.csv' "$KASAN_SOAK"; then
	grn "KASAN soak enforces stall + kmemleak + hw-error + throughput-floor and emits a CSV"
else
	red "KASAN soak must gate on stall/kmemleak/hw-error/throughput-floor and emit a time-series CSV"
fi

# tx_dropped/rx_dropped (drops) must NOT auto-fail — they grow legitimately on
# the link-flap churn and queue-stop; only TRUE error counters fail the soak.
if grep -q 'recorded but never fail' "$KASAN_SOAK" \
   && grep -q 'for j in 0 2 3 4 5' "$KASAN_SOAK"; then
	grn "KASAN soak separates true hw errors (fail) from policy drops (record only)"
else
	red "KASAN soak must not fail on tx_dropped/rx_dropped (link-flap/queue-stop drops)"
fi

# Campaign covers the upstream default + all valid multi-queue RSS sizes.
if grep -q 'run_phase 0' "$CAMPAIGN" \
   && grep -q 'run_phase 2' "$CAMPAIGN" \
   && grep -q 'run_phase 4' "$CAMPAIGN"; then
	grn "soak campaign covers rss_queues 0 (default) + 2 + 4 (all valid sizes)"
else
	red "soak campaign must cover rss_queues 0, 2, and 4"
fi

if grep -q 'IPERF_CYCLE_SECS' "$ACTIVE" \
   && grep -q 'IPERF_INTERVAL' "$ACTIVE"; then
	grn "active soak exposes iperf cycle and report intervals"
else
	red "active soak must keep the long-run iperf cycle controls"
fi

if grep -q 'IPERF_FAIL_LOG' "$ACTIVE" \
   && grep -q 'iperf_failures' "$ACTIVE" \
   && grep -q 'wait "$IPERF_PID"' "$ACTIVE"; then
	grn "active soak records iperf failures"
else
	red "active soak must fail when the iperf client exits unsuccessfully"
fi

if grep -q 'tx_received_counter' "$ACTIVE" \
   && grep -q 'tx_delta' "$ACTIVE" \
   && grep -q '"$tx_delta" -gt 0' "$ACTIVE"; then
	grn "active soak requires observed TX progress"
else
	red "active soak must not pass without tx_received progress"
fi

if grep -q '\[\[ -v "$override" \]\]' "$WATCH" \
   && grep -q 'no-config' "$WATCH"; then
	grn "soak watcher handles missing host configuration"
else
	red "soak watcher must not abort under set -u for unknown host aliases"
fi

if grep -q 'R8125_IFACE=.*R8125_PATTERN=.*bash -s' "$WATCH" \
   && grep -q 'set -uo pipefail' "$WATCH"; then
	grn "soak watcher remote probe runs under bash"
else
	red "soak watcher remote probe must run under bash, not an implicit login shell"
fi

if grep -q 'UDP_G2H_1500_STREAMS=.*:-10' "$PERF" \
   && grep -q 'UDP_G2H_1500_BITRATE=.*:-250M' "$PERF" \
   && grep -q 'udp_args_for' "$PERF" \
   && grep -q 'UDP_ARGS+=(-P "$UDP_G2H_1500_STREAMS")' "$PERF"; then
	grn "perf harness keeps KVM UDP g2h MTU1500 parallel-stream shape"
else
	red "perf harness must keep KVM-safe UDP g2h MTU1500 parallel-stream shape"
fi

if grep -q 'TX_BYTE_BUDGETS=' "$BYTE_BUDGET" \
   && grep -q 'tx_byte_budget="$budget"' "$BYTE_BUDGET" \
   && grep -q 'PPS_FRAMES=' "$BYTE_BUDGET" \
   && grep -q 'tx_doorbells' "$BYTE_BUDGET" \
   && grep -q 'doorbell_ratio' "$BYTE_BUDGET"; then
	grn "gateway tx_byte_budget sweep varies the module param and records PPS + doorbell ratio"
else
	red "gateway tx_byte_budget sweep must vary tx_byte_budget and record PPS + doorbell ratio"
fi

if grep -q 'tx-vlan-offload' "$HW_OFFLOAD" \
   && grep -q 'rx-vlan-offload' "$HW_OFFLOAD" \
   && grep -q 'receive-hashing' "$HW_OFFLOAD" \
   && grep -q 'ethtool -x' "$HW_OFFLOAD" \
   && grep -q 'ip link add link' "$HW_OFFLOAD" \
   && grep -q 'LABEL=c_r8169' "$HW_OFFLOAD" \
   && grep -q 'LABEL=rust' "$HW_OFFLOAD"; then
	grn "gateway HW-offload harness records VLAN/RXHASH state and C-vs-Rust comparable runs"
else
	red "gateway HW-offload harness must validate VLAN and RSS/RXHASH state for C-vs-Rust comparison"
fi

exit "$rc"
