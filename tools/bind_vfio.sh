#!/usr/bin/env bash
# bind_vfio.sh — bind the RTL8125 to vfio-pci for guest passthrough (plan §8.2).
#
# DESTRUCTIVE: this unbinds the live RTL8125 from r8169 and removes its netdev
# from the host. Safe ONLY because host management is on a *different* NIC.
# This script is NOT run during non-destructive M0; it is committed so the
# destructive M0 step is reproducible (plan §15 item 12).
#
# Uses driver_override (per-device) NOT new_id (plan §8.2: new_id matches by
# VID/DID and would capture *every* Realtek 10ec:8125 on the box).
set -euo pipefail

PCI="0000:03:00.0"            # RTL8125 on this MS-A2 (validated; plan's 07:00.0 was an example)
WANT="vfio-pci"

[[ $(id -u) -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }

# --- Guard: refuse if host management could be riding this device ----------
IFACE="$(ls "/sys/bus/pci/devices/$PCI/net" 2>/dev/null | head -1 || true)"
if [[ -n "$IFACE" ]]; then
  if ip route get 1.1.1.1 2>/dev/null | grep -q " dev $IFACE "; then
    echo "REFUSING: default route is via $IFACE ($PCI). Move host mgmt to the"
    echo "I226-V/X710 first (plan §1.2, §8.1). Validation finding 3."
    exit 2
  fi
fi

# --- Isolation re-check (plan §8.1.4 / §16 Q2) -----------------------------
GRP="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/iommu_group")")"
N="$(ls "/sys/kernel/iommu_groups/$GRP/devices/" | wc -l)"
if [[ "$N" -ne 1 ]]; then
  echo "WARNING: IOMMU group $GRP has $N devices — NOT isolation-safe without"
  echo "pcie_acs_override (then host memory is unprotected; plan §8.2 negative gate)."
  read -rp "Continue anyway (test-only)? [y/N] " a; [[ "$a" == y ]] || exit 3
fi

modprobe vfio-pci 2>/dev/null || true
echo "RTL8125 $PCI (group $GRP): binding to $WANT via driver_override"

if [[ -e "/sys/bus/pci/devices/$PCI/driver" ]]; then
  echo "$PCI" > "/sys/bus/pci/devices/$PCI/driver/unbind"
fi
echo "$WANT"   > "/sys/bus/pci/devices/$PCI/driver_override"
echo "$PCI"    > /sys/bus/pci/drivers_probe

DRV="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null)" 2>/dev/null || echo none)"
lspci -nnk -s "$PCI"
[[ "$DRV" == "$WANT" ]] && echo "OK: bound to $WANT" || { echo "FAIL: driver=$DRV"; exit 4; }
