#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Teardown/reprobe cycle test — the closest suspend/resume proxy we
# can build today given the kernel-Rust PCI API gap (see docs/PM_GAP.md).
#
# IMPORTANT — two chip/platform facts shape this test:
#   1. The RTL8125B does NOT advertise Function-Level Reset (lspci shows
#      `DevCap: FLReset-`, bare-metal and under VFIO alike). Its only PCIe
#      reset method is a secondary BUS reset, and because kernel-Rust
#      `pci::Driver` exposes no reset_prepare/reset_done callbacks, a raw
#      `echo 1 > .../reset` resets the function WITHOUT letting the driver
#      quiesce: phylib then polls the PHY mid-reset (MDIO -EIO -> WARNING)
#      and the link doesn't auto-recover. That is a test/abstraction
#      mismatch, not a driver fault.
#   2. The in-tree `r8169` also matches 10ec:8125 and is auto-loaded by
#      udev on `bus/rescan`, so a bare remove+rescan re-binds the device to
#      r8169, not us. We therefore pin the device to $DRIVER via
#      `driver_override` after each rescan (the procedure validated in
#      docs/HARDENING_CLOSEOUT.md).
#
# Each cycle drives the driver's own remove()->probe() cleanly:
#   1. echo 1 > /sys/bus/pci/devices/$BDF/remove   (remove(): phy_stop, free rings)
#   2. echo 1 > /sys/bus/pci/rescan                 (re-discover the function)
#   3. force-bind $DRIVER via driver_override        (beat r8169 to it)
#   4. bring the netdev up; verify link + ping
#   5. scan dmesg for KASAN/UBSAN/BUG/WARNING/lockup
#
# 10 cycles matches the spec ("10x suspend/resume cycles"). Active-traffic
# teardown is covered separately by ci/check_rmmod_while_up.sh.

set -uo pipefail

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
CYCLES=${CYCLES:-10}
BDF=${BDF:-0000:05:00.0}
DRIVER=${DRIVER:-r8125_rust}
REQUESTED_IFACE="$IFACE"

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

dev_driver() { basename "$(readlink "/sys/bus/pci/devices/$BDF/driver" 2>/dev/null)" 2>/dev/null || true; }
dev_iface()  { ls "/sys/bus/pci/devices/$BDF/net/" 2>/dev/null | head -1; }

# Pin the device to our driver (idempotent); beats r8169 on (re)bind.
force_bind_driver() {
	[[ "$(dev_driver)" == "$DRIVER" ]] && return 0
	if [[ -e "/sys/bus/pci/devices/$BDF/driver" ]]; then
		echo "$BDF" | sudo tee "/sys/bus/pci/devices/$BDF/driver/unbind" >/dev/null 2>&1 || true
	fi
	echo "$DRIVER" | sudo tee "/sys/bus/pci/devices/$BDF/driver_override" >/dev/null 2>&1 || true
	echo "$BDF"    | sudo tee /sys/bus/pci/drivers_probe              >/dev/null 2>&1 || true
	# Clear override so it isn't sticky; current binding is unaffected.
	echo ""        | sudo tee "/sys/bus/pci/devices/$BDF/driver_override" >/dev/null 2>&1 || true
}

# Sanity: device present and exposes a remove control (always available).
if [[ ! -e "/sys/bus/pci/devices/$BDF" ]]; then
	red "FAIL: PCI device $BDF not present"
	exit 1
fi
if [[ ! -e "/sys/bus/pci/devices/$BDF/remove" ]]; then
	red "FAIL: $BDF does not expose a remove control"
	exit 1
fi
if sudo lspci -vv -s "$BDF" 2>/dev/null | grep -q 'FLReset-'; then
	yel "INFO: $BDF advertises FLReset- (no FLR) — using device/remove + bus/rescan + driver_override reprobe"
fi

# Make sure we start bound to our driver with a healthy link.
force_bind_driver
sleep 1
IFACE="$(dev_iface)"; IFACE="${IFACE:-$REQUESTED_IFACE}"
sudo ip link set "$IFACE" up 2>/dev/null || true
sudo ip addr add "$LOCAL_IP/$LOCAL_PREFIX" dev "$IFACE" 2>/dev/null || true

reachable=0
for _ in $(seq 1 20); do
	if [[ "$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)" == "1" ]] && \
	   ping -c 1 -W 2 -I "$IFACE" "$PEER" >/dev/null 2>&1; then
		reachable=1
		break
	fi
	sleep 1
done
if [[ $reachable -eq 0 ]]; then
	red "FAIL: $PEER not reachable at start (driver=$(dev_driver) iface=$IFACE) — cannot run reprobe cycles"
	exit 1
fi

sudo dmesg -C 2>/dev/null || true
echo "Starting $CYCLES remove+rescan reprobe cycles on $BDF (driver $DRIVER iface $IFACE peer $PEER)"

fail_count=0
for cycle in $(seq 1 "$CYCLES"); do
	echo 1 | sudo tee "/sys/bus/pci/devices/$BDF/remove" >/dev/null
	sleep 2
	echo 1 | sudo tee "/sys/bus/pci/rescan" >/dev/null
	sleep 1

	# Beat r8169 to the bind, then wait for OUR driver + a netdev.
	bound=0
	for _ in $(seq 1 30); do
		force_bind_driver
		if [[ "$(dev_driver)" == "$DRIVER" && -n "$(dev_iface)" ]]; then
			bound=1
			break
		fi
		sleep 1
	done
	if [[ $bound -eq 0 ]]; then
		red "cycle $cycle: $DRIVER did NOT re-bind within 30s (driver=$(dev_driver))"
		fail_count=$((fail_count + 1))
		continue
	fi
	sleep 1                       # let udev finish eth0 -> enpXsY rename
	IFACE="$(dev_iface)"          # re-read the (possibly renamed) netdev
	if [[ -z "$IFACE" ]]; then
		red "cycle $cycle: $DRIVER bound but no netdev appeared under $BDF"
		fail_count=$((fail_count + 1))
		continue
	fi

	# Fresh probe brings the netdev back admin-down; bring it up + re-add IP.
	sudo ip addr add "$LOCAL_IP/$LOCAL_PREFIX" dev "$IFACE" 2>/dev/null || true
	sudo ip link set "$IFACE" up

	link_back=0
	for _ in $(seq 1 30); do
		if [[ "$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null)" == "1" ]]; then
			link_back=1
			break
		fi
		sleep 1
	done
	if [[ $link_back -eq 0 ]]; then
		red "cycle $cycle: link did NOT come back within 30s post-reprobe (iface $IFACE)"
		fail_count=$((fail_count + 1))
		continue
	fi

	if ping -c 3 -W 2 -I "$IFACE" "$PEER" >/dev/null 2>&1; then
		grn "cycle $cycle: reprobe ($DRIVER) + link back + ping OK ($IFACE)"
	else
		red "cycle $cycle: link back but ping FAILED ($IFACE)"
		fail_count=$((fail_count + 1))
	fi
done

# Post-cycle dmesg scan. The remove()->probe() path quiesces the PHY, so a
# clean run has zero warnings; WARNING/Call Trace here is a real regression.
bad=$(sudo dmesg | grep -cE 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|kmemleak|lockdep|stuck|WARNING|Call Trace' || true)
if [[ "$bad" -gt 0 ]]; then
	red "Post-cycle dmesg flagged $bad kernel-debug warnings:"
	sudo dmesg | grep -E 'BUG|KASAN|UBSAN|Oops|RIP:|UAF|DMA-API.*WARN|kmemleak|lockdep|stuck|WARNING|Call Trace' | head -10
	fail_count=$((fail_count + 1))
fi

echo
if [[ "$fail_count" -eq 0 ]]; then
	grn "PASS: $CYCLES/$CYCLES remove+rescan reprobe cycles clean — $DRIVER re-probes correctly"
	exit 0
else
	red "FAIL: $fail_count failures across $CYCLES cycles"
	exit 1
fi
