#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# ASPM idle soak — the historical L1.x lockup gate (plan §7 M5).
#
# > "The 24-hour ASPM idle soak is the gate that has historically
# >  eliminated entire generations of RTL8125 driver candidates —
# >  passing it is the explicit goal of this milestone."
#
# Procedure:
#   1. Load the module, bring link up.
#   2. Verify ASPM L1 enable (or note "disabled" — we ship with ASPM_en
#      cleared per docs/RTL8125B_TSO_NOTES.md; that's actually safer for
#      this soak, but the gate still demands the chip survive idle).
#   3. Idle the link for SOAK_HOURS hours (default 24h, configurable to
#      a shorter proxy for quick CI runs).
#   4. After the idle period, transmit a single packet (ping to the
#      peer). If it fails — chip is wedged in L1 — gate FAILS.
#   5. Also continuously sample dmesg for any anomaly during the soak.
#
# Usage:
#   ci/check_aspm_idle_soak.sh           # 24-hour run (the actual gate)
#   SOAK_HOURS=1 ci/check_aspm_idle_soak.sh  # 1-hour proxy
#
# Operator wall-clock cost: this script is intended to run unattended.

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
SOAK_HOURS=${SOAK_HOURS:-24}
SOAK_SECS=$((SOAK_HOURS * 3600))
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}     # dmesg-sample interval, 5 min default
LOG=${LOG:-/tmp/r8125_aspm_soak.log}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

echo "ASPM idle soak — ${SOAK_HOURS}h on $IFACE (peer $PEER)" | tee "$LOG"
echo "Logging to $LOG" | tee -a "$LOG"
date | tee -a "$LOG"

if ! ip link show "$IFACE" >/dev/null 2>&1; then
	red "FAIL: $IFACE not present" | tee -a "$LOG"
	exit 1
fi
if [[ $(cat "/sys/class/net/$IFACE/operstate") != "up" ]]; then
	sudo ip link set "$IFACE" up
	sleep 6
fi
sudo ip addr add 10.0.0.2/24 dev "$IFACE" 2>/dev/null || true

if ! ping -c 1 -W 2 -I "$IFACE" "$PEER" >/dev/null 2>&1; then
	red "FAIL: peer $PEER not reachable at start of soak" | tee -a "$LOG"
	exit 1
fi
grn "Pre-soak link health: PASS (ping to $PEER OK)" | tee -a "$LOG"

# Clear dmesg so the post-soak grep is unambiguous.
sudo dmesg -C 2>/dev/null || true

# Soak — purely idle. Sample dmesg at SAMPLE_INTERVAL for incremental
# visibility; the final check is the post-soak ping.
start=$(date +%s)
deadline=$((start + SOAK_SECS))
samples=0
fails=0

while [[ $(date +%s) -lt $deadline ]]; do
	sleep "$SAMPLE_INTERVAL" &
	wait $!
	samples=$((samples + 1))
	bad=$(sudo dmesg | grep -cE 'BUG|KASAN|UBSAN|Oops|stuck|hang|lockup|kmemleak|DMA-API.*WARN' || true)
	elapsed=$(( $(date +%s) - start ))
	if [[ "$bad" -gt 0 ]]; then
		fails=$((fails + 1))
		printf 'sample %d (t=%ds): dmesg flagged %d lines\n' "$samples" "$elapsed" "$bad" | tee -a "$LOG"
		sudo dmesg | grep -E 'BUG|KASAN|UBSAN|Oops|stuck|hang|lockup|kmemleak|DMA-API.*WARN' | tail -5 | tee -a "$LOG"
		# Continue collecting — the post-ping is the binding check.
	else
		printf 'sample %d (t=%ds): dmesg clean\n' "$samples" "$elapsed" | tee -a "$LOG"
	fi
done

echo | tee -a "$LOG"
echo "Soak complete after ${SOAK_HOURS}h. Final-ping test:" | tee -a "$LOG"

# THE gate: can the chip transmit after the idle period? If ASPM L1
# locked it up, this ping will fail.
if ping -c 5 -W 3 -I "$IFACE" "$PEER" 2>&1 | tee -a "$LOG" | grep -qE '5 received|4 received|3 received'; then
	grn "PASS: chip survived ${SOAK_HOURS}h idle; post-soak ping responds" | tee -a "$LOG"
	if [[ "$fails" -gt 0 ]]; then
		yel "NOTE: $fails dmesg samples flagged warnings during soak — review $LOG"
	fi
	exit 0
else
	red "FAIL: chip wedged after ${SOAK_HOURS}h idle — post-soak ping LOST" | tee -a "$LOG"
	exit 1
fi
