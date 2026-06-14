#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Unified driver for the ASPM idle gate. Runs two 24-hour soaks
# back-to-back:
#
#   1. force_aspm=0 (production) — chip idle WITHOUT ASPM L1.x.
#      Validates that the driver survives 24h idle with the
#      conservative TSO-safe ASPM-off config.
#   2. force_aspm=1 (test-only) — chip idle WITH ASPM L1.x enabled.
#      Exercises the historical L1.x lockup gate. NOT a production
#      configuration; module reload required.
#
# If phase 1 fails, phase 2 is NOT launched. The chip is in some
# unrecoverable state and forcing more PM transitions would mask
# the bug.
#
# This script is designed to run as a long-lived systemd transient
# unit. Total wall-clock: ~48 hours.
#
# Usage:
#   sudo systemd-run --unit=r8125-aspm-both \
#       --working-directory=/tmp/r8125_rust_build \
#       --setenv=BUILD_V2_DIR=/tmp/r8125_rust_build_v2 \
#       -- bash ci/check_aspm_both_soaks.sh
#
# Monitor:
#   sudo journalctl -u r8125-aspm-both -f
#   tail -f /tmp/r8125_aspm_both.log

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
BDF=${BDF:-0000:05:00.0}
BUILD_DIR=${BUILD_DIR:-/tmp/r8125_rust_build}
BUILD_V2_DIR=${BUILD_V2_DIR:-/tmp/r8125_rust_build_v2}
SOAK_HOURS=${SOAK_HOURS:-24}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}
LOG=${LOG:-/tmp/r8125_aspm_both.log}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }

echo "==== Phase 1: force_aspm=0 (driver default; ASPM off) ====" | tee "$LOG"
date | tee -a "$LOG"

SOAK_HOURS="$SOAK_HOURS" SAMPLE_INTERVAL="$SAMPLE_INTERVAL" \
	IFACE="$IFACE" PEER="$PEER" LOCAL_IP="$LOCAL_IP" LOCAL_PREFIX="$LOCAL_PREFIX" \
	LOG=/tmp/r8125_aspm_soak.log \
	bash "$BUILD_DIR/ci/check_aspm_idle_soak.sh"
EXIT1=$?

echo "Phase 1 exit: $EXIT1" | tee -a "$LOG"

if [[ "$EXIT1" -ne 0 ]]; then
	red "Phase 1 FAILED — NOT starting phase 2" | tee -a "$LOG"
	tail -30 /tmp/r8125_aspm_soak.log | tee -a "$LOG"
	exit "$EXIT1"
fi

grn "Phase 1 PASSED" | tee -a "$LOG"

echo | tee -a "$LOG"
echo "==== Phase 2: force_aspm=1 (test-only; ASPM L1.x enabled) ====" | tee -a "$LOG"
date | tee -a "$LOG"

if [[ ! -f "$BUILD_V2_DIR/src/r8125_rust.ko" ]]; then
	red "Phase 2 ABORTED — $BUILD_V2_DIR/src/r8125_rust.ko not present" | tee -a "$LOG"
	exit 1
fi

SOAK_HOURS="$SOAK_HOURS" SAMPLE_INTERVAL="$SAMPLE_INTERVAL" \
	IFACE="$IFACE" PEER="$PEER" LOCAL_IP="$LOCAL_IP" LOCAL_PREFIX="$LOCAL_PREFIX" \
	BDF="$BDF" BUILD_DIR="$BUILD_V2_DIR" \
	LOG=/tmp/r8125_aspm_on_soak.log \
	bash "$BUILD_V2_DIR/ci/check_aspm_on_idle_soak.sh"
EXIT2=$?

echo "Phase 2 exit: $EXIT2" | tee -a "$LOG"

if [[ "$EXIT2" -eq 0 ]]; then
	grn "BOTH PHASES PASSED — ASPM idle gate cleared" | tee -a "$LOG"
else
	red "Phase 2 FAILED — chip cannot survive 24h ASPM-on idle" | tee -a "$LOG"
	red "  This indicates the historical L1.x lockup is still present" | tee -a "$LOG"
fi

exit "$EXIT2"
