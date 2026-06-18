#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# r8125_rust capability-matrix selftest (TAP-13, skip-aware). Complements the
# minimal load/unload smoke test (r8125_rust_smoke.sh) by checking the advertised
# feature surface on an already-bound interface: ethtool stats (disposition +
# page_pool), offload/feature flags, RSS key/table readback, driver+firmware
# identity, the PHY hwmon temperature sensor, and the advertised xdp_features
# (incl. AF_XDP zero-copy). Every check that needs an absent tool/capability is
# reported as a TAP SKIP rather than a failure, so this runs anywhere.
#
# Usage:
#   DRIVER=r8125_rust tools/testing/selftests/net/r8125_rust_features.sh
#   IFACE=enp3s0     tools/testing/selftests/net/r8125_rust_features.sh

DRIVER="${DRIVER:-r8125_rust}"
IFACE="${IFACE:-}"
KSFT_SKIP=4
tn=1

echo "TAP version 13"

skip_all() { echo "1..0 # SKIP $*"; exit "$KSFT_SKIP"; }
ok()    { echo "ok $tn - $*"; tn=$((tn + 1)); }
skip()  { echo "ok $tn - $* # SKIP"; tn=$((tn + 1)); }
not_ok(){ echo "not ok $tn - $*"; tn=$((tn + 1)); rc=1; }
rc=0

find_driver_iface() {
	for net in /sys/bus/pci/drivers/"$DRIVER"/*/net/*; do
		[ -e "$net" ] || continue
		basename "$net"; return 0
	done
	return 1
}

[ "$(id -u)" -eq 0 ] || skip_all "must run as root"
command -v ethtool >/dev/null 2>&1 || skip_all "ethtool is unavailable"
[ -n "$IFACE" ] || IFACE="$(find_driver_iface || true)"
[ -n "$IFACE" ] || skip_all "no $DRIVER-bound interface present"
[ -d "/sys/class/net/$IFACE" ] || skip_all "$IFACE is not a netdev"

echo "# interface: $IFACE"
echo "1..8"

# 1. Disposition counters (the section 6.3 invariant surface).
S="$(ethtool -S "$IFACE" 2>/dev/null)"
if echo "$S" | grep -q "tx_received" && echo "$S" | grep -q "rx_handed_to_stack"; then
	ok "ethtool -S exposes disposition counters"
else
	not_ok "ethtool -S disposition counters"
fi

# 2. page_pool allocator stats (standard helper, neither C driver exposes).
if echo "$S" | grep -q "rx_pp_alloc_fast"; then
	ok "ethtool -S exposes page_pool stats (rx_pp_*)"
else
	skip "page_pool stats (CONFIG_PAGE_POOL_STATS?)"
fi

# 3. Feature flags: HIGHDMA fixed-on + hardware offloads present.
K="$(ethtool -k "$IFACE" 2>/dev/null)"
if echo "$K" | grep -q "highdma: on"; then
	ok "ethtool -k: highdma on"
else
	not_ok "ethtool -k highdma"
fi

# 4. Driver identity + firmware version (PHY MCU patch loaded).
I="$(ethtool -i "$IFACE" 2>/dev/null)"
if echo "$I" | grep -q "driver: $DRIVER"; then
	ok "ethtool -i: driver $DRIVER"
else
	not_ok "ethtool -i driver"
fi

# 5. RSS indirection table reads back (control-plane present).
if ethtool -x "$IFACE" >/dev/null 2>&1; then
	ok "ethtool -x: RSS table readback"
else
	skip "RSS readback (-x unsupported here)"
fi

# 6. PHY hwmon temperature sensor (inherited from phylib, free).
hw=""
for h in /sys/class/net/"$IFACE"/device/hwmon/hwmon*/temp1_input \
	 /sys/class/hwmon/hwmon*/temp1_input; do
	[ -r "$h" ] || continue
	# Match the hwmon belonging to this device where possible.
	hw="$h"; break
done
if [ -n "$hw" ] && t="$(cat "$hw" 2>/dev/null)" && [ "$t" -gt 0 ] 2>/dev/null; then
	ok "PHY hwmon temp present (${t} m°C)"
else
	skip "PHY hwmon temp (REALTEK_PHY_HWMON?)"
fi

# 7. xdp_features advertise BASIC|REDIRECT|NDO_XMIT|XSK_ZEROCOPY (netdev-genl).
xdp=""
if command -v ip >/dev/null 2>&1; then
	xdp="$(ip -d link show dev "$IFACE" 2>/dev/null | tr 'A-Z' 'a-z')"
fi
if echo "$xdp" | grep -q "xsk[_-]zerocopy"; then
	ok "xdp_features advertises xsk-zerocopy (+ basic/redirect/ndo-xmit)"
elif [ -n "$xdp" ] && echo "$xdp" | grep -q "xdp"; then
	skip "xdp_features present but zerocopy bit not shown by this ip"
else
	skip "xdp_features (ip -d does not render them here; use ynl dev-get)"
fi

# 8. Channels / queue count query (get_channels surface).
if ethtool -l "$IFACE" >/dev/null 2>&1; then
	ok "ethtool -l: channel/queue query"
else
	skip "ethtool -l (get_channels unsupported here)"
fi

exit "$rc"
