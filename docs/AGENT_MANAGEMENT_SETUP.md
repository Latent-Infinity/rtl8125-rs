# Agent Management Setup and Recovery Plan

**Purpose:** define what the agent needs in order to manage the RTL8125 guest
development workflow without repeated manual intervention, and record the
current recovery path for the guest boot issue.

This is a review document. Do not treat it as a security policy until the
sudoers and SSH choices are explicitly approved by the human operator.

---

## Current State

Host:

- Build host: MS-A2, Ubuntu 26.04, stock host kernel `7.0.0-15-generic`.
- RTL8125 PCI function: `0000:03:00.0`.
- Host management route was observed on Wi-Fi (`wlp6s0`), not the RTL8125.
- The RTL8125 has been passed through to libvirt guest `rtl8125-guest`.
- Libvirt default NAT network is active.
- Custom KASAN/debug/Rust kernel packages were built under `/home/operator/kbuild/`.

Guest:

- VM name: `rtl8125-guest`.
- NAT address observed: `192.168.122.174`.
- Login created by autoinstall: `operator` / temporary password `ubuntu`.
- RTL8125 appeared inside the guest as `05:00.0`.
- Custom kernel packages are installed in the guest:
  - `linux-image-7.0.0_7.0.0-2_amd64.deb`
  - `linux-headers-7.0.0_7.0.0-2_amd64.deb`
  - `linux-libc-dev_7.0.0-2_amd64.deb`
- The guest still booted `7.0.0-15-generic` after the first reboot attempt.
- Manual GRUB boot of `/boot/vmlinuz-7.0.0` failed with `bad shim lock
  signature`, which means Secure Boot/shim is blocking the unsigned custom
  kernel.
- `virsh console` now reaches GRUB, but it has dropped into the `grub>` command
  shell rather than the normal menu.

Evidence already captured:

- `docs/baseline/guest_debug_rust_kernel.config`
- `docs/baseline/guest_preboot_custom_kernel_state.txt`

---

## Goal

The agent should be able to perform the recurring development loop:

1. Query host/VM state.
2. Start, stop, reset, and inspect `rtl8125-guest`.
3. Bind/unbind the RTL8125 between `r8169` and `vfio-pci`.
4. Repair guest boot configuration offline when the guest cannot boot.
5. SSH into the guest when it is online.
6. Build and load test kernel modules in the guest.
7. Copy evidence back into `docs/baseline/`.

The agent should not have broad, unrestricted root access.

---

## Required Control Paths

### 1. Host Libvirt Control

The agent needs non-interactive host control for this VM:

```bash
virsh --connect qemu:///system domstate rtl8125-guest
virsh --connect qemu:///system domifaddr rtl8125-guest
virsh --connect qemu:///system start rtl8125-guest
virsh --connect qemu:///system shutdown rtl8125-guest
virsh --connect qemu:///system reset rtl8125-guest
virsh --connect qemu:///system destroy rtl8125-guest
virsh --connect qemu:///system dumpxml rtl8125-guest
virsh --connect qemu:///system define FILE.xml
virsh --connect qemu:///system console --force rtl8125-guest
```

`console` is needed only for boot failures; normal operation should use SSH.

### 2. Host VFIO Control

The agent needs permission to run the existing guarded scripts:

```bash
sudo tools/bind_vfio.sh
sudo tools/unbind_vfio.sh
```

These scripts already include route and IOMMU-group safety checks.

### 3. Host Offline Guest Repair

The agent needs permission to run:

```bash
sudo tools/repair_rtl8125_guest_boot.sh
```

This script is intended for cases where:

- the VM boots incorrectly,
- SSH is unavailable or hangs,
- `virsh console` is blank or drops to GRUB,
- the guest disk must be repaired offline with libguestfs.

### 4. Guest SSH Control

Once the guest has booted and has network, the agent needs SSH access as:

```text
operator@192.168.122.174
```

Preferred authentication is a real SSH key, not `sshpass`. The temporary
password `ubuntu` should be removed after key auth works.

---

## Recommended One-Time Host Setup

Create a narrow sudoers file:

```bash
sudo visudo -f /etc/sudoers.d/rtl8125-agent
```

Proposed contents:

```sudoers
operator ALL=(root) NOPASSWD: /usr/bin/virsh --connect qemu\:///system *
operator ALL=(root) NOPASSWD: /usr/bin/virt-customize *
operator ALL=(root) NOPASSWD: /usr/bin/virt-install *
operator ALL=(root) NOPASSWD: /home/operator/Projects/Rt8125-driver/rtl8125-rs/tools/bind_vfio.sh
operator ALL=(root) NOPASSWD: /home/operator/Projects/Rt8125-driver/rtl8125-rs/tools/unbind_vfio.sh
operator ALL=(root) NOPASSWD: /home/operator/Projects/Rt8125-driver/rtl8125-rs/tools/repair_rtl8125_guest_boot.sh
```

Validation:

```bash
sudo -n virsh --connect qemu:///system domstate rtl8125-guest
sudo -n tools/repair_rtl8125_guest_boot.sh --help
```

---

## Recommended One-Time Guest SSH Setup

Inside the guest, install the agent public key:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
printf '%s\n' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICutl2H8YqX9RiqClpcp94D638dq0Yq7acyLKoP9cUlZ rtl8125-guest-codex' > ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
chown -R operator:operator ~/.ssh
```

Verify SSH configuration:

```bash
sudo sshd -T | grep -E 'pubkeyauthentication|authorizedkeysfile|passwordauthentication'
```

Expected:

```text
pubkeyauthentication yes
authorizedkeysfile .ssh/authorized_keys .ssh/authorized_keys2
```

From the host:

```bash
ssh -F /dev/null -i /tmp/rtl8125_guest_codex operator@192.168.122.174 'uname -r'
```

If SSH authenticates but hangs before running commands, use console/offline
repair. Do not continue driver work until the guest can execute simple SSH
commands reliably.

---

## Current Boot Recovery Task

The immediate blocker is not Rust or VFIO. It is guest firmware/GRUB/Secure
Boot:

- The custom kernel is unsigned.
- GRUB/shim reports `bad shim lock signature`.
- Therefore the guest must boot with Secure Boot disabled, using explicit
  non-secure OVMF firmware.

### Operator Recovery Commands

On the host:

```bash
sudo virsh --connect qemu:///system destroy rtl8125-guest || true

CODE=
for f in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd; do
  [ -f "$f" ] && CODE="$f" && break
done

VARS=
for f in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
  [ -f "$f" ] && VARS="$f" && break
done

echo "CODE=$CODE"
echo "VARS=$VARS"
test -n "$CODE" -a -n "$VARS"
```

Dump and patch VM XML:

```bash
sudo virsh --connect qemu:///system dumpxml --inactive rtl8125-guest > /tmp/rtl8125-guest.xml
```

Then patch `/tmp/rtl8125-guest.xml` so the `<os>` block does not use libvirt
auto firmware selection. It should contain explicit non-secure OVMF:

```xml
<os>
  <type arch='x86_64' machine='pc-q35-10.2'>hvm</type>
  <loader readonly='yes' secure='no' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
  <nvram template='/usr/share/OVMF/OVMF_VARS_4M.fd'>/var/lib/libvirt/qemu/nvram/rtl8125-guest_VARS.fd</nvram>
  <boot dev='hd'/>
</os>
```

Use the actual `CODE`, `VARS`, and `machine` values found on the host.

Define and reset NVRAM:

```bash
sudo virsh --connect qemu:///system define /tmp/rtl8125-guest.xml
sudo rm -f /var/lib/libvirt/qemu/nvram/rtl8125-guest_VARS.fd
sudo virsh --connect qemu:///system start rtl8125-guest
sudo virsh --connect qemu:///system console --force rtl8125-guest
```

If dropped at `grub>`, boot manually:

```text
set root=(hd0,gpt2)
linux /boot/vmlinuz-7.0.0 root=/dev/vda2 ro console=tty0 console=ttyS0,115200n8
initrd /boot/initrd.img-7.0.0
boot
```

Expected after boot:

```bash
uname -r
```

```text
7.0.0
```

---

## Post-Boot Verification

After the guest boots `7.0.0`, run inside the guest:

```bash
uname -a
grep -E 'CONFIG_RUST=|CONFIG_KASAN=|CONFIG_KASAN_GENERIC=|CONFIG_DEBUG_LOCK_ALLOC=|CONFIG_PROVE_LOCKING=|CONFIG_DEBUG_KMEMLEAK=|CONFIG_DMA_API_DEBUG=' /boot/config-$(uname -r)
lspci -nnk | grep -A8 -i '8125'
ls -ld /lib/modules/$(uname -r)/build
test -e /lib/modules/$(uname -r)/build/rust && echo rustdir-ok
```

Expected:

- `uname -r` is `7.0.0`.
- Config includes `CONFIG_RUST=y`, KASAN, lockdep/prove-locking, kmemleak, and
  DMA API debug.
- RTL8125 is visible in the guest.
- `/lib/modules/7.0.0/build` exists.
- The kernel build tree has Rust metadata.

Evidence to copy into the repo:

```text
docs/baseline/guest_uname_config.txt
docs/baseline/guest_lspci_rtl8125.txt
```

---

## When Agent Management Is Unlocked

Agent management is considered unlocked when all of these are true:

- `sudo -n virsh --connect qemu:///system domstate rtl8125-guest` works from
  the host.
- `sudo -n tools/bind_vfio.sh` and `sudo -n tools/unbind_vfio.sh` are allowed.
- `sudo -n tools/repair_rtl8125_guest_boot.sh` is allowed.
- The guest boots `7.0.0`.
- SSH to the guest can run `uname -r` non-interactively.
- The agent can copy guest evidence into `docs/baseline/`.

Only then should Phase 7 begin: the trivial Rust module build/load loop inside
the guest.
