#!/usr/bin/env bash
# unbind_vfio.sh — reverse bind_vfio.sh: clear driver_override, return the
# RTL8125 to r8169 (plan §8.2). Run after the guest is shut down.
set -euo pipefail
PCI="0000:03:00.0"
[[ $(id -u) -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }

if [[ -e "/sys/bus/pci/devices/$PCI/driver" ]]; then
  echo "$PCI" > "/sys/bus/pci/devices/$PCI/driver/unbind"
fi
# Clear the per-device override so normal matching (r8169) resumes.
echo "" > "/sys/bus/pci/devices/$PCI/driver_override"
echo "$PCI" > /sys/bus/pci/drivers_probe
modprobe r8169 2>/dev/null || true

DRV="$(basename "$(readlink -f "/sys/bus/pci/devices/$PCI/driver" 2>/dev/null)" 2>/dev/null || echo none)"
lspci -nnk -s "$PCI"
[[ "$DRV" == "r8169" ]] && echo "OK: returned to r8169" || echo "NOTE: driver=$DRV (rebind may need: echo $PCI > /sys/bus/pci/drivers/r8169/bind)"
