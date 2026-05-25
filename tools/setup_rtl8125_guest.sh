#!/usr/bin/env bash
# Create the disposable RTL8125 VFIO guest and stage/install the debug kernel.
#
# Run from the host with sudo. The script intentionally leaves the guest
# powered off after autoinstall so the operator controls the first boot/reboot.
set -euo pipefail

VM_NAME="${VM_NAME:-rtl8125-guest}"
PCI="${PCI:-0000:03:00.0}"
ISO="${ISO:-/var/lib/libvirt/boot/ubuntu-26.04-live-server-amd64.iso}"
KBUILD="${KBUILD:-/home/operator/kbuild}"
IMAGE_DEB="$KBUILD/linux-image-7.0.0_7.0.0-2_amd64.deb"
HEADERS_DEB="$KBUILD/linux-headers-7.0.0_7.0.0-2_amd64.deb"
LIBC_DEB="$KBUILD/linux-libc-dev_7.0.0-2_amd64.deb"
LIBVIRT_IMAGES="${LIBVIRT_IMAGES:-/var/lib/libvirt/images}"
VM_DISK="$LIBVIRT_IMAGES/$VM_NAME.qcow2"
SEED_ISO="$LIBVIRT_IMAGES/$VM_NAME-autoinstall-seed.iso"
DEBS_ISO="$LIBVIRT_IMAGES/$VM_NAME-kernel-debs.iso"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"

log() {
  printf '\n== %s ==\n' "$*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0"
}

require_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || return 1
}

install_host_deps() {
  local missing=()
  for cmd in virsh virt-install xorriso ip lspci; do
    require_cmd "$cmd" || missing+=("$cmd")
  done

  if ((${#missing[@]})); then
    log "Installing host virtualization dependencies"
    apt-get install -y qemu-system-x86 libvirt-daemon-system virtinst ovmf xorriso pciutils iproute2
  fi
}

start_libvirt() {
  log "Starting libvirt and default NAT network"
  systemctl enable --now libvirtd >/dev/null 2>&1 || systemctl enable --now virtqemud >/dev/null 2>&1 || true
  virsh --connect qemu:///system net-start default >/dev/null 2>&1 || true
  virsh --connect qemu:///system net-autostart default >/dev/null
  virsh --connect qemu:///system net-list --all
}

route_guard() {
  log "Checking host route safety before VFIO detach"
  local iface=""
  iface="$(ls "/sys/bus/pci/devices/$PCI/net" 2>/dev/null | head -1 || true)"

  if [[ -n "$iface" ]] && ip route get 1.1.1.1 2>/dev/null | grep -q " dev $iface "; then
    die "default route uses $iface on $PCI; move host management before VFIO detach"
  fi

  ip route get 1.1.1.1 || true
  lspci -nnk -s "$PCI"
}

make_seed_iso() {
  log "Creating autoinstall seed ISO"
  local work
  work="$(mktemp -d)"

  cat >"$work/meta-data" <<EOF
instance-id: $VM_NAME
local-hostname: $VM_NAME
EOF

  cat >"$work/user-data" <<'EOF'
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: rtl8125-guest
    username: operator
    # password: ubuntu
    password: "$6$JnSGobt37FRCi7Dg$Do3xRbLBu6n52damA.7hqLAZky9pBp1ZkkKDoDU/QjDzXqoxlJlsBJ3GIlaVgXOZ/hqOx.IQiMce7EOMX6kjb/"
  ssh:
    install-server: true
    allow-pw: true
  packages:
    - pciutils
    - ethtool
    - build-essential
  storage:
    layout:
      name: direct
  late-commands:
    - mkdir -p /mnt/rtl8125-debs /target/root/rtl8125-kernel-debs
    - mount -L RTL8125_DEBS /mnt/rtl8125-debs
    - cp /mnt/rtl8125-debs/*.deb /target/root/rtl8125-kernel-debs/
    - curtin in-target --target=/target -- dpkg -i /root/rtl8125-kernel-debs/linux-image-7.0.0_7.0.0-2_amd64.deb /root/rtl8125-kernel-debs/linux-headers-7.0.0_7.0.0-2_amd64.deb /root/rtl8125-kernel-debs/linux-libc-dev_7.0.0-2_amd64.deb
    - curtin in-target --target=/target -- update-grub
    - curtin in-target --target=/target -- bash -lc "uname -r > /root/preboot_host_kernel.txt || true"
    - bash -lc "grep -E 'CONFIG_RUST=|CONFIG_KASAN=|CONFIG_KASAN_GENERIC=|CONFIG_DEBUG_LOCK_ALLOC=|CONFIG_PROVE_LOCKING=|CONFIG_DEBUG_KMEMLEAK=|CONFIG_DMA_API_DEBUG=' /target/boot/config-7.0.0 > /target/root/guest_debug_kernel_config_check.txt"
  shutdown: poweroff
EOF

  xorriso -as mkisofs -output "$SEED_ISO" -volid cidata -joliet -rock "$work" >/dev/null
  rm -rf "$work"
  ls -lh "$SEED_ISO"
}

make_debs_iso() {
  log "Creating kernel deb ISO"
  local work
  work="$(mktemp -d)"

  cp "$IMAGE_DEB" "$HEADERS_DEB" "$LIBC_DEB" "$work/"
  xorriso -as mkisofs -output "$DEBS_ISO" -volid RTL8125_DEBS -joliet -rock "$work" >/dev/null
  rm -rf "$work"
  ls -lh "$DEBS_ISO"
}

remove_existing_guest_if_empty() {
  if virsh --connect qemu:///system dominfo "$VM_NAME" >/dev/null 2>&1; then
    die "VM '$VM_NAME' already exists; inspect/remove it manually before rerunning"
  fi

  if [[ -e "$VM_DISK" ]]; then
    die "disk already exists: $VM_DISK; inspect/remove it manually before rerunning"
  fi
}

bind_vfio() {
  log "Binding RTL8125 to vfio-pci"
  "$REPO_ROOT/tools/bind_vfio.sh"
}

create_guest() {
  log "Creating $VM_NAME with unattended Ubuntu install"
  virt-install \
    --connect qemu:///system \
    --name "$VM_NAME" \
    --memory 8192 \
    --vcpus 6 \
    --location "$ISO,kernel=casper/vmlinuz,initrd=casper/initrd" \
    --extra-args "autoinstall ds=nocloud console=ttyS0,115200n8" \
    --disk "path=$VM_DISK,size=40,bus=virtio,format=qcow2" \
    --disk "path=$SEED_ISO,device=cdrom,readonly=on" \
    --disk "path=$DEBS_ISO,device=cdrom,readonly=on" \
    --os-variant ubuntu25.10 \
    --boot uefi \
    --network network=default,model=virtio \
    --hostdev "pci_${PCI//[:.]/_}" \
    --serial pty \
    --console pty,target_type=serial \
    --graphics none \
    --noautoconsole \
    --wait -1
}

verify_guest() {
  log "Verifying host-side guest state"
  virsh --connect qemu:///system dominfo "$VM_NAME"
  virsh --connect qemu:///system domblklist "$VM_NAME"
  virsh --connect qemu:///system dumpxml "$VM_NAME" | grep -E "<hostdev|<source|<address domain='0x0000' bus='0x03' slot='0x00' function='0x0'"

  [[ -s "$VM_DISK" ]] || die "guest disk missing/empty: $VM_DISK"
  [[ -s "$SEED_ISO" ]] || die "seed ISO missing/empty: $SEED_ISO"
  [[ -s "$DEBS_ISO" ]] || die "debs ISO missing/empty: $DEBS_ISO"

  log "What to do next"
  cat <<EOF
The unattended install has finished if dominfo shows State: shut off.
Start the guest when ready:

  sudo virsh --connect qemu:///system start $VM_NAME
  sudo virsh --connect qemu:///system console $VM_NAME

Login: operator / ubuntu

Then verify inside the guest:

  uname -r
  cat /root/guest_debug_kernel_config_check.txt
  lspci -nnvv | grep -A8 -i '8125'
EOF
}

main() {
  need_root
  require_file "$ISO"
  require_file "$IMAGE_DEB"
  require_file "$HEADERS_DEB"
  require_file "$LIBC_DEB"

  install_host_deps
  start_libvirt
  route_guard
  remove_existing_guest_if_empty
  mkdir -p "$LIBVIRT_IMAGES"
  make_seed_iso
  make_debs_iso
  bind_vfio
  create_guest
  verify_guest
}

main "$@"
