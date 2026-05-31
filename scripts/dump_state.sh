#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# dump_state.sh — single-command field-debug snapshot for r8125_rust.
#
# Tier 3a of docs/POST_SOAK_PLAN.md. Run during or right after an
# incident. Captures everything an off-box reviewer would want to
# look at, into a single timestamped tarball.
#
# What gets captured:
#   - dmesg from the last hour (filtered to r8125_rust / link / BUG / WARN)
#   - full ethtool snapshot: -i (drvinfo), -k (features), -S (§6.3 + chip counters)
#   - /proc/interrupts (r8125_rust filter)
#   - lspci -vv for chip + upstream bridge (ASPM state)
#   - ip -s link show <iface>
#   - operstate + carrier + speed snapshot
#   - module loaded state + parameters (intx_only, aspm_force_off, force_aspm)
#   - kernel version + module version
#   - any /sys/kernel/debug/r8125_rust/* if it exists
#
# Usage:
#   sudo scripts/dump_state.sh                       # default iface enp5s0
#   IFACE=enp7s0 BDF=0000:07:00.0 sudo scripts/dump_state.sh
#   sudo scripts/dump_state.sh /tmp/my_capture       # explicit output path
#
# Output: a single .tar.gz with all the above + a README.txt naming
# the capture context. Path printed at the end.

set -uo pipefail

IFACE=${IFACE:-enp5s0}
BDF=${BDF:-0000:05:00.0}
SINCE=${SINCE:-1 hour ago}
OUT_PATH=${1:-/tmp/r8125_dump_$(date +%Y%m%d_%H%M%S).tar.gz}
WORK=$(mktemp -d /tmp/r8125_dump.XXXXXX)

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

cd "$WORK"

# --- 0. README context ---
cat > README.txt <<EOF
r8125_rust state dump
=====================
captured: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
hostname: $(hostname)
kernel  : $(uname -r)
iface   : $IFACE
bdf     : $BDF
since   : $SINCE

Files in this archive:
  dmesg.log            kernel log filtered to r8125_rust + link + BUG/WARN
  ethtool_drvinfo.txt  driver version / firmware
  ethtool_features.txt offload feature state
  ethtool_stats.txt    §6.3 counters + chip-internal stats
  interrupts.txt       /proc/interrupts (r8125_rust filter)
  lspci_chip.txt       lspci -vv for the chip
  lspci_bridge.txt     lspci -vv for upstream PCIe bridge (ASPM)
  iplink.txt           ip -s link show
  sysfs_iface.txt      operstate + carrier + speed + MTU
  module.txt           lsmod + module parameters
  debugfs/             contents of /sys/kernel/debug/r8125_rust/ if present
  six_three_gap.txt    §6.3 invariant gap calculation
EOF

# --- 1. dmesg ---
sudo dmesg --since "$SINCE" 2>/dev/null \
	| grep -E 'r8125_rust|enp.*Link|BUG|WARN|panic|oops|stack guard' \
	> dmesg.log 2>&1 || true

# --- 2. ethtool ---
sudo ethtool -i "$IFACE" > ethtool_drvinfo.txt 2>&1 || true
sudo ethtool -k "$IFACE" > ethtool_features.txt 2>&1 || true
sudo ethtool -S "$IFACE" > ethtool_stats.txt 2>&1 || true

# --- 3. interrupts ---
{
	head -1 /proc/interrupts
	grep -E 'r8125_rust|^[[:space:]]+[0-9]+:' /proc/interrupts | grep r8125_rust
} > interrupts.txt 2>&1 || true

# --- 4. lspci ---
sudo lspci -vv -s "$BDF" > lspci_chip.txt 2>&1 || true
# Walk one level up for the bridge — typical pattern 0000:00:NN.M
bridge_bdf=$(lspci -PP -s "$BDF" 2>/dev/null | awk '{print $1}' | sed 's:/.*$::' || true)
if [[ -n "${bridge_bdf:-}" && "$bridge_bdf" != "$BDF" ]]; then
	sudo lspci -vv -s "$bridge_bdf" > lspci_bridge.txt 2>&1 || true
else
	echo "(could not determine upstream bridge BDF)" > lspci_bridge.txt
fi

# --- 5. ip link ---
ip -s link show "$IFACE" > iplink.txt 2>&1 || true

# --- 6. sysfs ---
{
	echo "operstate: $(cat /sys/class/net/$IFACE/operstate 2>/dev/null)"
	echo "carrier:   $(cat /sys/class/net/$IFACE/carrier 2>/dev/null)"
	echo "speed:     $(cat /sys/class/net/$IFACE/speed 2>/dev/null) Mb/s"
	echo "duplex:    $(cat /sys/class/net/$IFACE/duplex 2>/dev/null)"
	echo "mtu:       $(cat /sys/class/net/$IFACE/mtu 2>/dev/null)"
	echo "address:   $(cat /sys/class/net/$IFACE/address 2>/dev/null)"
} > sysfs_iface.txt 2>&1

# --- 7. module ---
{
	echo "==== lsmod r8125_rust ===="
	lsmod | grep -E '^Module|r8125_rust' || echo "(module not loaded)"
	echo
	echo "==== /sys/module/r8125_rust/parameters ===="
	if [[ -d /sys/module/r8125_rust/parameters ]]; then
		for p in /sys/module/r8125_rust/parameters/*; do
			printf '%-22s = %s\n' "$(basename "$p")" "$(cat "$p" 2>/dev/null)"
		done
	else
		echo "(module not loaded)"
	fi
	echo
	echo "==== modinfo r8125_rust ===="
	modinfo r8125_rust 2>&1 | head -20 || true
} > module.txt

# --- 8. debugfs (if any) ---
if [[ -d /sys/kernel/debug/r8125_rust ]]; then
	mkdir -p debugfs
	sudo cp -r /sys/kernel/debug/r8125_rust/. debugfs/ 2>/dev/null || true
fi

# --- 9. §6.3 invariant gap ---
sudo ethtool -S "$IFACE" 2>/dev/null | awk '
	/tx_received/        {tr=$2}
	/tx_consumed/        {tc=$2}
	/tx_busy_exception/  {tb=$2}
	/tx_dropped_error/   {td=$2}
	/rx_handed_to_stack/ {rh=$2}
	/rx_dropped_error/   {rd=$2}
	END {
		gap = tr - tc - tb - td
		printf "tx_received       = %s\n", tr
		printf "tx_consumed       = %s\n", tc
		printf "tx_busy_exception = %s\n", tb
		printf "tx_dropped_error  = %s\n", td
		printf "rx_handed_to_stack= %s\n", rh
		printf "rx_dropped_error  = %s\n", rd
		printf "\n§6.3 invariant gap = tx_received - tx_consumed - tx_busy_exception - tx_dropped_error = %d\n", gap
		if (gap < 0)
			print "** NEGATIVE GAP — this is a real bug, file with this dump **"
		else if (gap > 256)
			print "** large transient gap; capture a 2nd dump 5 s later to confirm settles **"
		else
			print "** gap in expected range (<=256, in-flight at snapshot moment) **"
	}
' > six_three_gap.txt 2>&1

# --- 10. archive ---
mkdir -p "$(dirname "$OUT_PATH")"
tar czf "$OUT_PATH" -C "$WORK" .
size=$(du -h "$OUT_PATH" | cut -f1)

echo "Capture written: $OUT_PATH ($size)"
echo
echo "Quick summary:"
grep -E 'tx_received|§6.3' six_three_gap.txt | head -3
echo
echo "To attach to a bug report, just upload $OUT_PATH."
