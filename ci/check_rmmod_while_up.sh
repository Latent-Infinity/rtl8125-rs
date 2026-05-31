#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# M5 NAPI deliverable: "rmmod while interface is up either is rejected
# cleanly or quiesces hardware first — never crashes" (plan §7 M5).
#
# Strategy: stress-test by repeatedly loading the module, starting
# active TCP traffic via iperf3, and rmmod'ing while the traffic is
# still flowing. After each cycle, scan dmesg for KASAN/UBSAN/lockdep/
# Oops/BUG/UAF reports. Any single report fails the gate.
#
# Defaults to 5 cycles which is enough to surface intermittent races.
# A longer soak (CYCLES=50, ~12 min) is recommended before M5 sign-off.

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
CYCLES=${CYCLES:-5}
TRAFFIC_SECS=${TRAFFIC_SECS:-8}
RMMOD_DELAY=${RMMOD_DELAY:-3}
BUILD_DIR=${BUILD_DIR:-/tmp/r8125_rust_build}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Pre-flight: make sure the .ko exists and the peer is reachable.
if [[ ! -f "$BUILD_DIR/src/r8125_rust.ko" ]]; then
	red "FAIL: $BUILD_DIR/src/r8125_rust.ko not found — build + sync first"
	exit 1
fi
if ! ping -c 1 -W 2 "$PEER" >/dev/null 2>&1; then
	# Peer-side iperf3 server must be running on $PEER:5201; this is
	# operator setup. The peer may not be ping-able if the interface
	# is currently down (expected at start), so this is informational.
	yel "INFO: $PEER not currently ping-able (will retry inside cycles)"
fi

fail_count=0

for cycle in $(seq 1 "$CYCLES"); do
	# Cleanup any prior load.
	sudo ip link set "$IFACE" down 2>/dev/null || true
	sudo rmmod r8125_rust 2>/dev/null || true
	sudo dmesg -C 2>/dev/null || true

	# Load + bring up.
	sudo insmod "$BUILD_DIR/src/r8125_rust.ko"
	sudo ip link set "$IFACE" up
	# Wait for link auto-neg to complete.
	for _ in $(seq 1 30); do
		if [[ $(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null) == "1" ]]; then
			break
		fi
		sleep 0.5
	done
	sudo ip addr add "$LOCAL_IP/$LOCAL_PREFIX" dev "$IFACE" 2>/dev/null || true

	# Start traffic in background, rmmod mid-flight.
	(iperf3 -c "$PEER" -B "$LOCAL_IP" -t "$TRAFFIC_SECS" >/dev/null 2>&1 &)
	sleep "$RMMOD_DELAY"

	if sudo rmmod r8125_rust; then
		: # ok
	else
		red "cycle $cycle: rmmod failed (module busy or kernel error)"
		fail_count=$((fail_count + 1))
		continue
	fi
	sleep 1

	# Scan dmesg for any kernel-debug warning class.
	bad=$(sudo dmesg | grep -cE 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|lockdep|kmemleak.*unreferenced|slab-use-after-free|stack-out-of-bounds|use-after-free' || true)
	if [[ "$bad" -gt 0 ]]; then
		red "cycle $cycle: dmesg flagged $bad lines"
		sudo dmesg | grep -E 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|lockdep|kmemleak|slab-use-after-free|stack-out-of-bounds|use-after-free' | head -10
		fail_count=$((fail_count + 1))
	else
		grn "cycle $cycle: rmmod-while-up clean"
	fi
done

echo
if [[ "$fail_count" -eq 0 ]]; then
	grn "PASS: $CYCLES/$CYCLES rmmod-while-up cycles clean (no kernel-debug warnings)"
	exit 0
else
	red "FAIL: $fail_count/$CYCLES cycles tripped a kernel-debug warning"
	exit 1
fi
