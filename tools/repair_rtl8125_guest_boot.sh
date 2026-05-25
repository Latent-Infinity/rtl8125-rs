#!/usr/bin/env bash
# Offline-repair the disposable RTL8125 guest boot config.
#
# This is for the state where the guest is reachable at L2/TCP but SSH sessions
# hang and virsh console is blank. It shuts the VM off, edits the disk through
# libguestfs, makes the custom 7.0.0 kernel the preferred boot target, enables
# serial console output, and starts the guest again.
set -euo pipefail

VM_NAME="${VM_NAME:-rtl8125-guest}"
KERNEL_VERSION="${KERNEL_VERSION:-7.0.0}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<EOF
Usage: sudo $0

Offline-repair the disposable RTL8125 guest boot config.

Environment:
  VM_NAME         libvirt domain name (default: rtl8125-guest)
  KERNEL_VERSION guest kernel to prefer (default: 7.0.0)

The script stops the VM, edits GRUB config through libguestfs, enables serial
console output, starts the VM again, and prints follow-up verification commands.
EOF
  exit 0
fi

log() {
  printf '\n== %s ==\n' "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0"

if ! command -v virt-customize >/dev/null 2>&1; then
  log "Installing libguestfs tools"
  apt-get update
  apt-get install -y libguestfs-tools
fi

log "Stopping $VM_NAME for offline disk repair"
if virsh --connect qemu:///system domstate "$VM_NAME" 2>/dev/null | grep -q running; then
  virsh --connect qemu:///system shutdown "$VM_NAME" || true
  for _ in $(seq 1 30); do
    if virsh --connect qemu:///system domstate "$VM_NAME" 2>/dev/null | grep -q 'shut off'; then
      break
    fi
    sleep 2
  done
fi

if ! virsh --connect qemu:///system domstate "$VM_NAME" 2>/dev/null | grep -q 'shut off'; then
  echo "Graceful shutdown did not complete; destroying disposable guest instance."
  virsh --connect qemu:///system destroy "$VM_NAME"
fi

log "Editing guest GRUB config offline"
virt-customize -d "$VM_NAME" \
  --run-command "cp /etc/default/grub /etc/default/grub.before-rtl8125-offline-repair || true" \
  --run-command "sed -i '/^GRUB_DEFAULT=/d;/^GRUB_TOP_LEVEL=/d;/^GRUB_TERMINAL=/d;/^GRUB_SERIAL_COMMAND=/d;/^GRUB_CMDLINE_LINUX=/d' /etc/default/grub" \
  --append-line "/etc/default/grub:GRUB_DEFAULT=0" \
  --append-line "/etc/default/grub:GRUB_TOP_LEVEL=/boot/vmlinuz-$KERNEL_VERSION" \
  --append-line "/etc/default/grub:GRUB_TERMINAL=\"console serial\"" \
  --append-line "/etc/default/grub:GRUB_SERIAL_COMMAND=\"serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1\"" \
  --append-line "/etc/default/grub:GRUB_CMDLINE_LINUX=\"console=tty0 console=ttyS0,115200n8\"" \
  --run-command "update-grub" \
  --run-command "grep -E '^(GRUB_DEFAULT|GRUB_TOP_LEVEL|GRUB_TERMINAL|GRUB_SERIAL_COMMAND|GRUB_CMDLINE_LINUX)=' /etc/default/grub > /root/rtl8125-grub-repair.txt" \
  --run-command "grep -E 'CONFIG_RUST=|CONFIG_KASAN=|CONFIG_KASAN_GENERIC=|CONFIG_DEBUG_LOCK_ALLOC=|CONFIG_PROVE_LOCKING=|CONFIG_DEBUG_KMEMLEAK=|CONFIG_DMA_API_DEBUG=' /boot/config-$KERNEL_VERSION > /root/rtl8125-custom-kernel-config.txt"

log "Starting $VM_NAME"
virsh --connect qemu:///system start "$VM_NAME"

log "Current VM state"
virsh --connect qemu:///system domstate "$VM_NAME"
echo
echo "Wait 30-60 seconds, then check:"
echo "  sudo virsh --connect qemu:///system domifaddr $VM_NAME"
echo "  sudo virsh --connect qemu:///system console --force $VM_NAME"
echo
echo "Expected after repair:"
echo "  uname -r"
echo "  $KERNEL_VERSION"
