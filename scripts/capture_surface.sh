#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Phase 0 evidence-surface capture for docs/UPSTREAM_GAP_CLOSURE_PLAN.md.
#
# Captures the read-only netdev/ethtool surface of an interface so the baseline
# (which surfaces respond, and how) is frozen before gap-closure work begins and
# can be diffed after each feature lands. READ-ONLY: safe to run against a live
# soak interface (it only queries; it never loads/configures the driver).
#
# Usage:  capture_surface.sh <out_dir> <iface> [cmd-prefix ...]
#   local NIC:      capture_surface.sh /tmp/surf enp4s0
#   gateway DUT:    capture_surface.sh /tmp/surf enp3s0 ssh gateway sudo ip netns exec dut
#   KVM guest DUT:  capture_surface.sh /tmp/surf enp5s0 ssh rtl8125-guest sudo
#
# (The dedicated clean load/open/traffic/unload capture is a separate hardware
# step run when the rig is free; this script is the query half it reuses.)

set -uo pipefail
OUT="${1:?out_dir}"; IFACE="${2:?iface}"; shift 2; PFX=("$@")
mkdir -p "$OUT"
run(){ "${PFX[@]}" "$@"; }

# ethtool surfaces — each file shows whether the op is implemented (data vs
# "Operation not supported"), which is exactly the gap inventory in evidence form.
run ethtool -i "$IFACE"  > "$OUT/ethtool_i_drvinfo.txt"      2>&1
run ethtool    "$IFACE"  > "$OUT/ethtool_link_ksettings.txt" 2>&1
run ethtool -k "$IFACE"  > "$OUT/ethtool_k_features.txt"     2>&1
run ethtool -S "$IFACE"  > "$OUT/ethtool_S_stats.txt"        2>&1
run ethtool -l "$IFACE"  > "$OUT/ethtool_l_channels.txt"     2>&1
run ethtool -x "$IFACE"  > "$OUT/ethtool_x_rxfh.txt"         2>&1
run ethtool -a "$IFACE"  > "$OUT/ethtool_a_pause.txt"        2>&1
run ethtool -c "$IFACE"  > "$OUT/ethtool_c_coalesce.txt"     2>&1
run ethtool -g "$IFACE"  > "$OUT/ethtool_g_ring.txt"         2>&1
run ethtool --show-eee     "$IFACE" > "$OUT/ethtool_eee.txt"   2>&1
run ethtool --show-time-stamping "$IFACE" > "$OUT/ethtool_tsinfo.txt" 2>&1
run ethtool -P "$IFACE"  > "$OUT/ethtool_P_permaddr.txt"     2>&1
run ip -s -s link show "$IFACE" > "$OUT/ip_s_link.txt"       2>&1

{
  echo "# evidence-surface capture"
  echo "iface: $IFACE   prefix: ${PFX[*]:-(local)}"
  echo "captured: $(date -u +%FT%TZ 2>/dev/null || echo n/a)"
  echo
  echo "## op responsiveness (Operation not supported => gap)"
  for f in ethtool_link_ksettings ethtool_a_pause ethtool_c_coalesce ethtool_g_ring ethtool_eee ethtool_tsinfo; do
    state=present; grep -qi 'Operation not supported\|no stats available\|not supported' "$OUT/$f.txt" 2>/dev/null && state="NOT SUPPORTED"
    printf "  %-26s %s\n" "$f" "$state"
  done
} > "$OUT/SUMMARY.txt"
cat "$OUT/SUMMARY.txt"
echo "(captured -> $OUT)"
