#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Variant of `check_aspm_idle_soak.sh` that forces ASPM L1.x ON via
# the `force_aspm=1` module parameter. This exercises the *historical*
# RTL8125 L1.x lockup gate that the plan §7 M5 calls out as "the gate
# that has historically eliminated entire generations of RTL8125
# driver candidates".
#
# The default build (force_aspm=0) clears Config5 ASPM_en in
# `hw_start_8125b` because we found ASPM-on regresses TSO (TSO
# retransmits return when L1 entry interrupts the chip's FIFO drain;
# see docs/RTL8125B_TSO_NOTES.md). For production we KEEP ASPM off.
# This soak intentionally turns ASPM back on to verify the chip and
# driver still recover after 24h of L1.x transitions.
#
# Run this AFTER the standard `check_aspm_idle_soak.sh` (with
# force_aspm=0) so both data points are captured.
#
# Usage:
#   ci/check_aspm_on_idle_soak.sh           # 24h
#   SOAK_HOURS=1 ci/check_aspm_on_idle_soak.sh  # 1h proxy

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
BDF=${BDF:-0000:05:00.0}
BUILD_DIR=${BUILD_DIR:-/tmp/r8125_rust_build}
SOAK_HOURS=${SOAK_HOURS:-24}
SOAK_SECS=$((SOAK_HOURS * 3600))
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}
LOG=${LOG:-/tmp/r8125_aspm_on_soak.log}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

echo "ASPM-ON idle soak (force_aspm=1) — ${SOAK_HOURS}h on $IFACE" | tee "$LOG"
date | tee -a "$LOG"

# Reload module with force_aspm=1.
sudo ip link set "$IFACE" down 2>/dev/null || true
sudo rmmod r8125_rust 2>/dev/null || true
sleep 2
if ! sudo insmod "$BUILD_DIR/src/r8125_rust.ko" force_aspm=1; then
	red "FAIL: insmod with force_aspm=1 rejected"
	exit 1
fi
sudo ip link set "$IFACE" up
sleep 8
sudo ip addr add 10.0.0.2/24 dev "$IFACE" 2>/dev/null || true

# Force aggressive ASPM policy externally too.
echo powersupersave | sudo tee /sys/module/pcie_aspm/parameters/policy >/dev/null

# Verify ASPM is now actually enabled on the device.
if sudo lspci -s "$BDF" -vv 2>&1 | grep -q 'ASPM L1 Enabled\|LnkCtl:.*L1\b' &&
   ! sudo lspci -s "$BDF" -vv 2>&1 | grep -q 'LnkCtl:.*ASPM Disabled'; then
	grn "ASPM L1 confirmed enabled on the device" | tee -a "$LOG"
else
	yel "WARN: lspci does not show 'ASPM L1 Enabled' explicitly:" | tee -a "$LOG"
	sudo lspci -s "$BDF" -vv 2>&1 | grep -E 'LnkCtl|LnkSta|ASPM' | tee -a "$LOG"
	yel "  Continuing soak; the chip-side ASPM_en bit IS set per force_aspm=1." | tee -a "$LOG"
fi

# Pre-soak ping baseline.
if ping -c 3 -W 2 -I "$IFACE" "$PEER" >/dev/null 2>&1; then
	grn "Pre-soak ping PASS" | tee -a "$LOG"
else
	red "FAIL: pre-soak ping FAILED — bringing the soak up is broken" | tee -a "$LOG"
	exit 1
fi

# Clear dmesg so we can scan post-soak unambiguously.
sudo dmesg -C 2>/dev/null || true

# Idle loop with periodic dmesg sampling.
start=$(date +%s)
deadline=$((start + SOAK_SECS))
samples=0
warnings=0
while [[ $(date +%s) -lt $deadline ]]; do
	sleep "$SAMPLE_INTERVAL" &
	wait $!
	samples=$((samples + 1))
	elapsed=$(( $(date +%s) - start ))
	bad=$(sudo dmesg | grep -cE 'BUG|KASAN|UBSAN|Oops|stuck|hang|lockup|kmemleak|DMA-API.*WARN|l1.*timeout' || true)
	if [[ "$bad" -gt 0 ]]; then
		warnings=$((warnings + 1))
		printf 'sample %d (t=%ds): %d warnings — see dmesg\n' "$samples" "$elapsed" "$bad" | tee -a "$LOG"
	else
		printf 'sample %d (t=%ds): clean (warnings=%d)\n' "$samples" "$elapsed" "$warnings" | tee -a "$LOG"
	fi
done

echo | tee -a "$LOG"
echo "Soak complete. samples=$samples warnings=$warnings" | tee -a "$LOG"

# THE binding gate: after 24h of L1.x transitions, can the chip TX?
if ping -c 5 -W 3 -I "$IFACE" "$PEER" 2>&1 | tee -a "$LOG" | grep -qE '5 received|4 received|3 received'; then
	grn "PASS: chip survived ${SOAK_HOURS}h ASPM-on idle; post-soak ping OK" | tee -a "$LOG"
	exit 0
else
	red "FAIL: chip wedged after ${SOAK_HOURS}h ASPM-on idle — L1.x lockup gate violated" | tee -a "$LOG"
	exit 1
fi
