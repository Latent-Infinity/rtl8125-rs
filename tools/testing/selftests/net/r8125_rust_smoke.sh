#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# Minimal r8125_rust netdev smoke test for upstream selftest review.
#
# Usage:
#   KO=./src/r8125_rust.ko tools/testing/selftests/net/r8125_rust_smoke.sh
#   MODULE=r8125_rust DRIVER=r8125_rust tools/testing/selftests/net/r8125_rust_smoke.sh

MODULE="${MODULE:-r8125_rust}"
DRIVER="${DRIVER:-$MODULE}"
KO="${KO:-}"
KSFT_SKIP=4
test_num=1
loaded_by_test=0
unloaded=0

echo "TAP version 13"

skip_all()
{
	echo "1..0 # SKIP $*"
	exit "$KSFT_SKIP"
}

ok()
{
	echo "ok $test_num - $*"
	test_num=$((test_num + 1))
}

not_ok()
{
	echo "not ok $test_num - $*"
	test_num=$((test_num + 1))
	exit 1
}

module_loaded()
{
	grep -q "^$MODULE " /proc/modules
}

find_rtl8125_device()
{
	for dev in /sys/bus/pci/devices/*; do
		[ -r "$dev/vendor" ] || continue
		[ -r "$dev/device" ] || continue
		[ "$(cat "$dev/vendor")" = "0x10ec" ] || continue
		[ "$(cat "$dev/device")" = "0x8125" ] || continue
		return 0
	done
	return 1
}

find_driver_iface()
{
	for net in /sys/bus/pci/drivers/"$DRIVER"/*/net/*; do
		[ -e "$net" ] || continue
		basename "$net"
		return 0
	done
	return 1
}

cleanup()
{
	if [ "$loaded_by_test" -eq 1 ] && [ "$unloaded" -eq 0 ]; then
		rmmod "$MODULE" >/dev/null 2>&1 || true
	fi
}
trap cleanup EXIT INT TERM

[ "$(id -u)" -eq 0 ] || skip_all "must run as root"
command -v ip >/dev/null 2>&1 || skip_all "iproute2 is unavailable"
find_rtl8125_device || skip_all "no Realtek 10ec:8125 PCI function present"

echo "1..4"

if module_loaded; then
	ok "$MODULE already loaded"
else
	if [ -n "$KO" ]; then
		[ -r "$KO" ] || not_ok "KO=$KO is not readable"
		insmod "$KO" || not_ok "insmod $KO"
	elif [ -r "./src/$MODULE.ko" ]; then
		insmod "./src/$MODULE.ko" || not_ok "insmod ./src/$MODULE.ko"
	else
		modprobe "$MODULE" || not_ok "modprobe $MODULE"
	fi
	module_loaded || not_ok "$MODULE visible in /proc/modules"
	loaded_by_test=1
	ok "$MODULE loaded"
fi

# The netdev can appear as eth0 and then be renamed (eth0 -> enpXsY) by
# udev shortly after probe. Re-resolve the name and retry so a rename in
# flight doesn't fail the test on a stale name.
IFACE=""
for _ in 1 2 3 4 5; do
	IFACE="$(find_driver_iface || true)"
	[ -n "$IFACE" ] && ip link show dev "$IFACE" >/dev/null 2>&1 && break
	sleep 1
done
[ -n "$IFACE" ] || not_ok "$DRIVER bound netdev appears"
ok "$DRIVER bound netdev appears: $IFACE"

ip link show dev "$IFACE" >/dev/null 2>&1 || not_ok "ip link show dev $IFACE"
ok "ip link show dev $IFACE"

if [ "$loaded_by_test" -eq 1 ]; then
	rmmod "$MODULE" || not_ok "rmmod $MODULE"
	unloaded=1
	ok "rmmod $MODULE"
else
	echo "ok $test_num - rmmod $MODULE # SKIP module was loaded before test"
	test_num=$((test_num + 1))
fi

exit 0
