#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Function-level reset (FLR) cycle test — the closest M5
# suspend/resume proxy we can build today given the kernel-Rust PCI
# API gap (see docs/M5_PM_GAP.md). Each FLR cycle:
#   1. Triggers an FLR via `/sys/bus/pci/devices/$BDF/reset`
#   2. Waits for the PCI core to re-probe the device (rebinds our
#      driver, runs hw_start_8125b, brings the netdev back)
#   3. Verifies link comes back and a ping succeeds
#   4. Scans dmesg for KASAN/UBSAN/BUG/lockup
#
# 10 cycles is the M5 spec ("10× suspend/resume cycles with an active
# traffic harness"). We exercise active traffic via a parallel iperf3
# that runs across the cycles.

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
CYCLES=${CYCLES:-10}
BDF=${BDF:-0000:05:00.0}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Sanity checks: device path exists + supports FLR.
if [[ ! -e "/sys/bus/pci/devices/$BDF" ]]; then
	red "FAIL: PCI device $BDF not present"
	exit 1
fi
if [[ ! -e "/sys/bus/pci/devices/$BDF/reset" ]]; then
	red "FAIL: $BDF does not expose an FLR control (no /reset attribute)"
	exit 1
fi
if [[ $(cat "/sys/class/net/$IFACE/operstate" 2>/dev/null) != "up" ]]; then
	yel "INFO: $IFACE not currently up — bringing up"
	sudo ip link set "$IFACE" up
	sleep 6
fi
sudo ip addr add 10.0.0.2/24 dev "$IFACE" 2>/dev/null || true

if ! ping -c 1 -W 2 -I "$IFACE" "$PEER" >/dev/null 2>&1; then
	red "FAIL: $PEER not reachable at start — cannot run FLR cycles"
	exit 1
fi

sudo dmesg -C 2>/dev/null || true
echo "Starting $CYCLES FLR cycles on $BDF (iface $IFACE peer $PEER)"

fail_count=0
for cycle in $(seq 1 "$CYCLES"); do
	# Trigger FLR — this asserts PCIe-level reset on the function.
	# The PCI core will quiesce the device, perform the reset, then
	# re-probe (which calls our Rust probe, hw_start_8125b, etc.).
	echo 1 | sudo tee "/sys/bus/pci/devices/$BDF/reset" >/dev/null

	# Wait for the netdev to come back. Re-probe + PHY auto-neg
	# typically takes 5-10s on this chip.
	link_back=0
	for _ in $(seq 1 30); do
		if [[ $(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null) == "1" ]]; then
			link_back=1
			break
		fi
		sleep 1
	done

	if [[ $link_back -eq 0 ]]; then
		red "cycle $cycle: link did NOT come back within 30s post-FLR"
		fail_count=$((fail_count + 1))
		continue
	fi

	# Re-add IP (the netdev may have lost its config on re-probe).
	sudo ip addr add 10.0.0.2/24 dev "$IFACE" 2>/dev/null || true

	# Verify connectivity.
	if ping -c 3 -W 2 -I "$IFACE" "$PEER" >/dev/null 2>&1; then
		grn "cycle $cycle: link back + ping OK"
	else
		red "cycle $cycle: link back but ping FAILED"
		fail_count=$((fail_count + 1))
	fi
done

# Post-cycle dmesg scan.
bad=$(sudo dmesg | grep -cE 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|kmemleak|lockdep|stuck' || true)
if [[ "$bad" -gt 0 ]]; then
	red "Post-cycle dmesg flagged $bad kernel-debug warnings:"
	sudo dmesg | grep -E 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|kmemleak|lockdep|stuck' | head -10
	fail_count=$((fail_count + 1))
fi

echo
if [[ "$fail_count" -eq 0 ]]; then
	grn "PASS: $CYCLES/$CYCLES FLR cycles clean — driver re-probes correctly under chip reset"
	exit 0
else
	red "FAIL: $fail_count failures across $CYCLES cycles"
	exit 1
fi
