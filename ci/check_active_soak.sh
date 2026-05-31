#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Active traffic soak with KASAN + lockdep + kmemleak + DMA_API_DEBUG
# (plan section 7 M5). The gate requires "24-hour low-rate active soak (<= 100
# Mbps mixed traffic) with KASAN + KCSAN + CONFIG_DMA_API_DEBUG enabled
# - zero reports". Our guest has KASAN/lockdep/kmemleak/DMA_API_DEBUG;
# KCSAN is mutually exclusive with KASAN in this kernel build.
#
# Procedure:
#   1. Sustained iperf3 in background (--bandwidth 100M to throttle).
#   2. Periodic dmesg sample for KASAN/lockdep/DMA-API/kmemleak.
#   3. Periodic section 6.3 counter-invariant check.
#   4. At the end: verify the chip is still up and counters are sane.
#
# Usage:
#   ci/check_active_soak.sh                # 24-hour run (the gate)
#   SOAK_HOURS=1 ci/check_active_soak.sh   # 1-hour proxy

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
SOAK_HOURS=${SOAK_HOURS:-24}
SOAK_SECS=$((SOAK_HOURS * 3600))
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}
BANDWIDTH=${BANDWIDTH:-100M}
LOG=${LOG:-/tmp/r8125_active_soak.log}
IPERF_FAIL_LOG=$(mktemp -t r8125_active_soak_iperf.XXXXXX) || exit 1
trap 'rm -f "$IPERF_FAIL_LOG"' EXIT
# When non-zero, restart the iperf3 client every IPERF_CYCLE_SECS to
# work around iperf3's pacing-loop wedge under long durations on slow
# event delivery (KVM + KASAN). Default 0 = single long iperf3 run,
# matching the historical Gateway-tested behaviour. Set to 3600 (1h)
# on KVM where the iperf3-not-our-driver stall reproduces.
IPERF_CYCLE_SECS=${IPERF_CYCLE_SECS:-0}
# Interval the iperf3 client reports at. `0` (the prior default) ran
# silently and was implicated in the wedge - keep at 30s by default.
IPERF_INTERVAL=${IPERF_INTERVAL:-30}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

tx_received_counter() {
	ethtool -S "$IFACE" 2>/dev/null |
		awk '/tx_received:/{print $2; found=1} END { if (!found) print 0 }'
}

echo "Active soak - ${SOAK_HOURS}h on $IFACE at $BANDWIDTH (peer $PEER)" | tee "$LOG"
date | tee -a "$LOG"

if [[ $(cat "/sys/class/net/$IFACE/operstate") != "up" ]]; then
	sudo ip link set "$IFACE" up
	sleep 6
fi
sudo ip addr add "$LOCAL_IP/$LOCAL_PREFIX" dev "$IFACE" 2>/dev/null || true

# Pre-soak: clear dmesg.
sudo dmesg -C 2>/dev/null || true

# Launch sustained iperf3 in background. Use TCP at 100M rate-limited
# (-b) so we exercise the data path without saturating the chip.
#
# Two shapes:
#   * IPERF_CYCLE_SECS=0 (default): one long-running iperf3 client.
#     The historical Gateway-validated shape.
#   * IPERF_CYCLE_SECS>0: respawn loop. Each iperf3 invocation runs for
#     min(IPERF_CYCLE_SECS, remaining-soak-time), exits, the loop
#     immediately starts another. Defeats long-duration iperf3 pacing
#     bugs (KVM-observed; see docs/RX_OPTIMIZATION_CANDIDATES.md note).
#     Driver state is NOT touched - TCP teardown + reconnect only.
start=$(date +%s)
deadline=$((start + SOAK_SECS))
samples=0
warnings=0
tx_start=$(tx_received_counter)

if (( IPERF_CYCLE_SECS > 0 )); then
	iperf_cycle_runner() {
		local end=$1
		while [[ $(date +%s) -lt $end ]]; do
			local remaining=$(( end - $(date +%s) ))
			local this_run=$(( remaining < IPERF_CYCLE_SECS ? remaining : IPERF_CYCLE_SECS ))
			(( this_run < 5 )) && break
			echo "[$(date -u +'%H:%M:%S')] iperf3 cycle: ${this_run}s" >>"$LOG"
			if ! iperf3 -c "$PEER" -B "$LOCAL_IP" -t "$this_run" -b "$BANDWIDTH" \
				-i "$IPERF_INTERVAL" >>"$LOG" 2>&1; then
				echo "iperf3 cycle failed at $(date -u +'%H:%M:%S')" >>"$IPERF_FAIL_LOG"
			fi
			# Brief settle so the host-side iperf3 service sees the FIN
			# and frees its single-test slot before the next connect.
			sleep 2
		done
	}
	iperf_cycle_runner "$deadline" &
	IPERF_PID=$!
else
	iperf3 -c "$PEER" -B "$LOCAL_IP" -t "$SOAK_SECS" -b "$BANDWIDTH" \
		-i "$IPERF_INTERVAL" >>"$LOG" 2>&1 &
	IPERF_PID=$!
fi

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
	# Snapshot the section 6.3 invariant as a soft sanity (gap should stay 0).
	stats=$(ethtool -S "$IFACE" 2>/dev/null)
	tr=$(echo "$stats" | awk '/tx_received:/{print $2}')
	tc=$(echo "$stats" | awk '/tx_consumed:/{print $2}')
	tb=$(echo "$stats" | awk '/tx_busy_exception:/{print $2}')
	td=$(echo "$stats" | awk '/tx_dropped_error:/{print $2}')
	tr=${tr:-0}
	tc=${tc:-0}
	tb=${tb:-0}
	td=${td:-0}
	gap=$(( tr - tc - tb - td ))
	printf 'sample %d (t=%ds): tx_received=%s gap=%d\n' "$samples" "$elapsed" "$tr" "$gap" | tee -a "$LOG"
	if [[ "$gap" -gt 100 ]]; then
		yel "  delta invariant gap unusually large ($gap) - investigation needed"
	fi
done

# Stop the iperf3 client cleanly (may have already finished).
IPERF_RC=0
wait "$IPERF_PID" 2>/dev/null || IPERF_RC=$?
if (( IPERF_RC != 0 )); then
	echo "iperf3 runner exited rc=$IPERF_RC" >>"$IPERF_FAIL_LOG"
fi

echo | tee -a "$LOG"
echo "Soak complete after ${SOAK_HOURS}h." | tee -a "$LOG"

tx_end=$(tx_received_counter)
tx_delta=$((tx_end - tx_start))
if (( tx_delta < 0 )); then
	tx_delta=0
fi
iperf_failures=0
if [[ -s "$IPERF_FAIL_LOG" ]]; then
	iperf_failures=$(wc -l < "$IPERF_FAIL_LOG")
	tee -a "$LOG" < "$IPERF_FAIL_LOG"
fi

if [[ "$warnings" -eq 0 && "$iperf_failures" -eq 0 && "$tx_delta" -gt 0 ]]; then
	grn "PASS: ${SOAK_HOURS}h active soak clean (tx_received +$tx_delta, no kernel-debug warnings across $samples samples)" | tee -a "$LOG"
	exit 0
else
	red "FAIL: warnings=$warnings/$samples iperf_failures=$iperf_failures tx_delta=$tx_delta - review $LOG" | tee -a "$LOG"
	exit 1
fi
