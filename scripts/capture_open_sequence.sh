#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# capture_open_sequence.sh — capture r8125_rust open-path evidence after reload.
#
# Typical usage:
#   sudo bash scripts/capture_open_sequence.sh \
#     /home/operator/rtl8125-rs/src/r8125_rust.ko enp5s0 192.168.50.1
#
# Env overrides:
#   IFACE=ethX, BDF=0000:05:00.0, PEER=ip, MODULE=/path/to/ko, OUT=/tmp/...txt

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KMOD=${1:-${MODULE:-"$ROOT/src/r8125_rust.ko"}}
IFACE=${2:-${IFACE:-enp5s0}}
PEER=${3:-${PEER:-192.168.1.1}}
OUT=${OUT:-"/tmp/r8125_open_capture_$(date +%Y%m%d_%H%M%S).txt"}
BDF=${BDF:-0000:05:00.0}
KICK_TRAFFIC=${KICK_TRAFFIC:-1}

{
  echo "==== capture start $(date -u +'%Y-%m-%dT%H:%M:%SZ') ===="
  echo "MODULE: $KMOD"
  echo "IFACE:  $IFACE"
  echo "PEER:   $PEER"
  echo "BDF:    $BDF"
  echo

  echo "== pre-messages =="
  echo "dmesg pre:"
  sudo dmesg -T
  echo

  echo "== module/device reset =="
  sudo rmmod r8125_rust 2>/dev/null || true
  sudo modprobe -r r8169 2>/dev/null || true
  sudo modprobe -r realtek 2>/dev/null || true
  sleep 1
  if lsmod | grep -q '^r8125_rust'; then
    echo "ERROR: r8125_rust still loaded after unload attempt" >&2
    exit 1
  fi

  echo "== reload =="
  sudo insmod "$KMOD"
  sleep 2

  echo "== post-load /proc/interrupts="
  cat /proc/interrupts | grep -E 'r8125_rust|^[[:space:]]*[0-9]+:' || true

  echo "== ensure interface state =="
  ip link set "$IFACE" down || true
  ip link set "$IFACE" up
  sleep 2

  echo "== open-path dmesg snapshot =="
  sudo dmesg --since "2 minutes ago" | grep -E 'r8125_rust|enp.*Link|mode=|IRQ allocated|ndo_open complete|BUG|WARN|WARN_ON|oops|ERR|failed' | tail -200

  if [[ "$KICK_TRAFFIC" == "1" ]]; then
    echo "== traffic probe =="
    ping -I "$IFACE" -c 5 -W 2 "$PEER" || true
  fi

  echo "== final open-state capture =="
  sudo dmesg --since "2 minutes ago" | grep -E 'r8125_rust|enp.*Link|IRQ|BUG|WARN|WARN_ON|oops|ERR|failed' | tail -300
  echo "== /proc/interrupts =="
  cat /proc/interrupts | grep -E 'r8125_rust|^[[:space:]]*[0-9]+:' || true
  echo "== ip -s link =="
  ip -s link show "$IFACE" || true
  echo "== ethtool -S =="
  ethtool -S "$IFACE" || true
  echo "== irq affinity =="
  irq_line=$(grep -m1 'r8125_rust' /proc/interrupts || true)
  if [[ -n "$irq_line" ]]; then
    irq_num=$(echo "$irq_line" | awk -F: '{gsub(/^[[:space:]]+/, "", $1); print $1}')
    if [[ -n "$irq_num" && -d "/proc/irq/$irq_num" ]]; then
      echo "IRQ vector: $irq_num"
      if [[ -f "/proc/irq/$irq_num/smp_affinity" ]]; then
        echo -n "smp_affinity: "
        cat "/proc/irq/$irq_num/smp_affinity"
      elif [[ -f "/proc/irq/$irq_num/smp_affinity_list" ]]; then
        echo -n "smp_affinity_list: "
        cat "/proc/irq/$irq_num/smp_affinity_list"
      else
        echo "(no affinity file found)"
      fi
    else
      echo "(irq number not found in proc tree)"
    fi
  else
    echo "(r8125_rust line not present yet)"
  fi

  echo "==== done $(date -u +'%Y-%m-%dT%H:%M:%SZ') ===="
} | tee "$OUT"

echo "Capture file: $OUT"
