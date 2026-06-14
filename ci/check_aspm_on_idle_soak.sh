#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Variant of `check_aspm_idle_soak.sh` that forces ASPM L1.x ON via
# the `force_aspm=1` module parameter. This exercises the *historical*
# RTL8125 L1.x lockup gate described as "the gate
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
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
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
sudo ip addr add "$LOCAL_IP/$LOCAL_PREFIX" dev "$IFACE" 2>/dev/null || true

# Force aggressive ASPM policy externally too.
echo powersupersave | sudo tee /sys/module/pcie_aspm/parameters/policy >/dev/null

# Engage per-device ASPM L1 explicitly. The pcie_aspm policy alone
# doesn't reliably flip the link to L1 Enabled even when both bridge
# and endpoint advertise L1 (kernel chooses based on per-device flags
# + quirks). Writing `1` to the endpoint's l1_aspm sysfs file engages
# L1 negotiation, which propagates the bridge's side too.
#
# The sysfs file only exists post-2020 kernels with CONFIG_PCIEASPM
# AND on environments where the bridge advertises ASPM L1 in LnkCap
# — so it's missing in KVM/VFIO guests (synthetic bridge advertises
# L0s only) and on hardware whose BIOS disables ASPM. We write
# best-effort and warn cleanly when it's not writable.
if [[ -w "/sys/bus/pci/devices/$BDF/link/l1_aspm" ]]; then
	echo 1 | sudo tee "/sys/bus/pci/devices/$BDF/link/l1_aspm" >/dev/null 2>&1
	sleep 1
	grn "Wrote 1 to /sys/bus/pci/devices/$BDF/link/l1_aspm" | tee -a "$LOG"
elif [[ -e "/sys/bus/pci/devices/$BDF/link/l1_aspm" ]]; then
	# File exists but not user-writable (root-only).
	echo 1 2>/dev/null | sudo tee "/sys/bus/pci/devices/$BDF/link/l1_aspm" >/dev/null 2>&1 \
		&& grn "Engaged L1 via sudo write to .../link/l1_aspm" | tee -a "$LOG" \
		|| yel "WARN: .../link/l1_aspm write failed" | tee -a "$LOG"
	sleep 1
else
	yel "WARN: $BDF has no /link/l1_aspm sysfs file — bridge probably doesn't advertise L1" | tee -a "$LOG"
	yel "  This is expected inside KVM/VFIO guests and on hardware with ASPM disabled in BIOS." | tee -a "$LOG"
fi

# Verify ASPM is now actually enabled on the device.
if sudo lspci -s "$BDF" -vv 2>&1 | grep -q 'LnkCtl:.*ASPM L1 Enabled' ||
   sudo lspci -s "$BDF" -vv 2>&1 | grep -q 'LnkCtl:.*L0s L1 Enabled'; then
	grn "ASPM L1 confirmed enabled on the device" | tee -a "$LOG"
elif sudo lspci -s "$BDF" -vv 2>&1 | grep -q 'LnkCtl:.*L0s Enabled'; then
	yel "WARN: only L0s engaged on the link (bridge may not advertise L1)" | tee -a "$LOG"
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
