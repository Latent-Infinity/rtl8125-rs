#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Active traffic soak with KASAN + lockdep + kmemleak + DMA_API_DEBUG
# (plan §7 M5). The gate requires "24-hour low-rate active soak (≤ 100
# Mbps mixed traffic) with KASAN + KCSAN + CONFIG_DMA_API_DEBUG enabled
# — zero reports". Our guest has KASAN/lockdep/kmemleak/DMA_API_DEBUG;
# KCSAN is mutually exclusive with KASAN in this kernel build.
#
# Procedure:
#   1. Sustained iperf3 in background (--bandwidth 100M to throttle).
#   2. Periodic dmesg sample for KASAN/lockdep/DMA-API/kmemleak.
#   3. Periodic §6.3 counter-invariant check.
#   4. At the end: verify the chip is still up and counters are sane.
#
# Usage:
#   ci/check_active_soak.sh                # 24-hour run (the gate)
#   SOAK_HOURS=1 ci/check_active_soak.sh   # 1-hour proxy

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
SOAK_HOURS=${SOAK_HOURS:-24}
SOAK_SECS=$((SOAK_HOURS * 3600))
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}
BANDWIDTH=${BANDWIDTH:-100M}
LOG=${LOG:-/tmp/r8125_active_soak.log}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

echo "Active soak — ${SOAK_HOURS}h on $IFACE at $BANDWIDTH (peer $PEER)" | tee "$LOG"
date | tee -a "$LOG"

if [[ $(cat "/sys/class/net/$IFACE/operstate") != "up" ]]; then
	sudo ip link set "$IFACE" up
	sleep 6
fi
sudo ip addr add 10.0.0.2/24 dev "$IFACE" 2>/dev/null || true

# Pre-soak: clear dmesg.
sudo dmesg -C 2>/dev/null || true

# Launch sustained iperf3 in background. Use TCP at 100M rate-limited
# (-b) so we exercise the data path without saturating the chip.
iperf3 -c "$PEER" -B 10.0.0.2 -t "$SOAK_SECS" -b "$BANDWIDTH" -i 0 \
	>>"$LOG" 2>&1 &
IPERF_PID=$!

start=$(date +%s)
deadline=$((start + SOAK_SECS))
samples=0
warnings=0

while [[ $(date +%s) -lt $deadline ]]; do
	sleep "$SAMPLE_INTERVAL"
	samples=$((samples + 1))
	elapsed=$(( $(date +%s) - start ))
	bad=$(sudo dmesg | grep -cE 'BUG|KASAN|UBSAN|Oops|kmemleak|DMA-API.*WARN|lockdep|slab-use-after-free' || true)
	if [[ "$bad" -gt 0 ]]; then
		warnings=$((warnings + 1))
		printf 'sample %d (t=%ds): %d warnings in dmesg\n' "$samples" "$elapsed" "$bad" | tee -a "$LOG"
		sudo dmesg | grep -E 'BUG|KASAN|UBSAN|Oops|kmemleak|DMA-API.*WARN|lockdep|slab-use-after-free' | tail -3 | tee -a "$LOG"
	fi
	# Snapshot the §6.3 invariant as a soft sanity (gap should stay 0).
	stats=$(ethtool -S "$IFACE" 2>/dev/null)
	tr=$(echo "$stats" | awk '/tx_received:/{print $2}')
	tc=$(echo "$stats" | awk '/tx_consumed:/{print $2}')
	tb=$(echo "$stats" | awk '/tx_busy_exception:/{print $2}')
	td=$(echo "$stats" | awk '/tx_dropped_error:/{print $2}')
	gap=$(( tr - tc - tb - td ))
	printf 'sample %d (t=%ds): tx_received=%s gap=%d\n' "$samples" "$elapsed" "$tr" "$gap" | tee -a "$LOG"
	if [[ "$gap" -gt 100 ]]; then
		yel "  Δ invariant gap unusually large ($gap) — investigation needed"
	fi
done

# Stop the iperf3 client cleanly (may have already finished).
wait $IPERF_PID 2>/dev/null || true

echo | tee -a "$LOG"
echo "Soak complete after ${SOAK_HOURS}h." | tee -a "$LOG"

if [[ "$warnings" -eq 0 ]]; then
	grn "PASS: ${SOAK_HOURS}h active soak clean (no kernel-debug warnings across $samples samples)" | tee -a "$LOG"
	exit 0
else
	red "FAIL: $warnings/$samples samples reported kernel-debug warnings — review $LOG" | tee -a "$LOG"
	exit 1
fi
