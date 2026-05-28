# Gateway — Bare-Metal Dev Environment Setup

**Goal:** stand up the second MS-A2 ("Gateway") as a bare-metal validation
platform for M6+ work. The current Controller box keeps its KVM-based
quick-iteration loop; Gateway runs the Rust driver directly on Linux for
the soak/perf/L1.x gates that VFIO/KVM can't honestly test.

Assumption for this runbook: the operator installs a minimal Ubuntu 26.04
LTS Server image first, logs in locally once, brings up WiFi + SSH, optionally
joins the machine to Tailscale, and then hands the machine to the agent. From
that point forward, identity checks, toolchain setup, kernel install, driver
builds, and long-running validation are agent-driven over SSH.

This runbook is the alternate to [`M0a_TO_M1_RUNBOOK.md`](M0a_TO_M1_RUNBOOK.md).
Where that doc gets the Controller's KVM guest going, this doc gets the
Gateway's bare-metal environment going. Both reference the same plan
([`RTL8125_Rust_Driver_Implementation_Plan.md`](RTL8125_Rust_Driver_Implementation_Plan.md))
and use the same validated toolchain pin.

---

## Identity

| Name | Role | OS posture | Driver target |
|---|---|---|---|
| **Controller** | dev iteration + KVM host | Ubuntu 26.04 LTS host + custom guest | RTL8125B in VFIO-passthrough guest (`0000:03:00.0` host → `0000:05:00.0` guest) |
| **Gateway** | bare-metal validation, eventual production | Ubuntu 26.04 LTS Server (after dev) | RTL8125B directly on bare metal (PCI address derived per machine) |

After M6/M7 are complete, Gateway is **wiped and reinstalled with Ubuntu
Server** for its production role (home-lab gateway / similar).

---

## Conventions

| Tag | Meaning |
|---|---|
| 🖥️ **Controller** | the current MS-A2, where we develop + run KVM iteration |
| 🦾 **Gateway** | the bare-metal MS-A2, where we run validation gates |
| 🤖 **agent** | work the AI agent does over SSH (autonomous); operator initiates only |
| 🔌 **physical** | requires touching cables, BIOS, WiFi credentials |
| ☢️ **destructive** | wipes disk or changes networking — operator-only |

**Validated toolchain pin** (same as Controller): kernel-Rust uses
**rustc 1.93.1 / LLVM 21** with `linux-lib-rust-7.0.0-15-generic`. Any
mismatch causes `error[E0463]: can't find crate for core`. Same constraint
as the Controller-KVM workflow.

---

## TL;DR ordered checklist

| # | Phase | Owner | Clears |
|---|---|---|---|
| 1 | [Minimal Ubuntu Server bootstrap](#phase-1) | ☢️ operator | OS, WiFi management, optional Tailscale, and password SSH are available |
| 2 | [Agent SSH key + passwordless sudo](#phase-2) | ☢️ operator + 🤖 agent | 🤖 agent can drive Gateway autonomously |
| 3 | [Agent-run hardware identity check](#phase-3) | 🤖 agent | Gateway is an MS-A2 with the expected NICs; PCI addresses captured |
| 4 | [Management-link hardening](#phase-4) | 🤖 agent | SSH is pinned to WiFi; Ethernet stays reserved for cross-traffic |
| 5 | [Build + install the debug+Rust kernel](#phase-5) | 🤖 agent (operator may need to enter sudo once for kernel install) | Same kernel as Controller's KVM guest; debug knobs armed |
| 6 | [Network topology: internal cross-traffic](#phase-6) | 🔌 operator + 🤖 agent | RTL8125B ↔ I226-V cable on Gateway, IP scheme |
| 7 | [Driver build + smoke test](#phase-7) | 🤖 agent | First insmod on bare metal, link up, ping passes |
| 8 | [Port the M5/M6 harnesses](#phase-8) | 🤖 agent | All `ci/check_*.sh` runnable on Gateway, baselines captured |
| 9 | [M6 validation runs](#phase-9) | 🤖 agent (long runs) | The gates VFIO/KVM couldn't honestly clear |
| 10 | [End of dev: wipe + Ubuntu Server](#phase-10) | ☢️ operator | Gateway transitions to production |

---

## Phase 1 — Minimal Ubuntu Server bootstrap {#phase-1}

☢️ operator · ~30 min · installs the minimal OS and creates the first
remote-management foothold.

Install **Ubuntu 26.04 LTS Server**, not Desktop, for the dev phase. The
server install should be as small as practical while still enabling the
MT7922 WiFi firmware and OpenSSH.

1. Install Ubuntu 26.04 LTS Server to Gateway's primary disk.
2. Create the `operator` user (or whatever username matches the
   Controller account). Use the same UID as Controller if the installer
   makes that practical.
3. Enable restricted firmware / third-party firmware during install so
   the MT7922 WiFi device works after first boot.
4. On first boot, log in locally and install the minimal bootstrap tools:
   ```bash
   sudo apt update
   sudo apt full-upgrade -y
   sudo apt install -y openssh-server vim build-essential network-manager curl
   ```
5. Bring up the MT7922 WiFi management link:
   ```bash
   nmcli dev wifi list
   nmcli dev wifi connect '<ssid>' password '<wpa-psk>'
   ```
6. Verify basic network and SSH:
   ```bash
   ip -br addr
   ping -c 3 1.1.1.1
   sudo systemctl enable --now ssh
   ```
7. From Controller, confirm password SSH works once:
   ```bash
   ssh operator@<gateway-wifi-ip> 'hostname; whoami; uname -a'
   ```

8. **Optional but recommended: join Tailscale for stable remote access.**
   This gives the agent a stable management address even if the WiFi DHCP
   lease changes or Gateway moves between networks. SSH still uses normal
   OpenSSH on port 22; it just connects to Gateway's Tailscale IP or
   MagicDNS name. Install and authenticate:
   ```bash
   curl -fsSL https://tailscale.com/install.sh | sh
   sudo tailscale up --ssh=false --hostname=gateway-rtl8125
   tailscale status
   tailscale ip -4
   ```
   Use a normal Tailscale auth flow unless the operator has a reusable
   auth key policy. Do not enable Tailscale SSH for this workflow; keep
   OpenSSH + the dedicated agent key as the audited control path. Tailscale
   is only the private network path to the SSH daemon.
9. If Tailscale is active, test from Controller:
   ```bash
   ssh operator@<gateway-tailnet-ip-or-name> 'hostname; whoami; uname -a'
   ```

**Acceptance**: Gateway is reachable from Controller by password SSH over
WiFi. If Tailscale is enabled, the same OpenSSH login also works via the
tailnet IP or MagicDNS name. Ethernet ports are not used for management.

---

## Phase 2 — Agent SSH key + passwordless sudo {#phase-2}

☢️ operator + 🤖 agent · ~10 min · allows autonomous Gateway control.

The agent drives Gateway via SSH the same way it drives the
Controller-KVM guest today (via `~/.ssh/agent/rtl8125_guest_codex`).
Mirror that pattern for Gateway.

1. On **Controller** (where the agent runs), generate a new key pair:
   ```bash
   ssh-keygen -t ed25519 -N '' -f ~/.ssh/agent/rtl8125_gateway_codex \
       -C 'agent@controller-gateway'
   ```
2. Copy the public key to Gateway using the password SSH bootstrap. Prefer
   the Tailscale IP/name if Phase 1 enabled it; otherwise use the WiFi LAN
   address:
   ```bash
   ssh-copy-id -i ~/.ssh/agent/rtl8125_gateway_codex.pub \
       operator@<gateway-tailnet-ip-or-wifi-ip>
   ```
3. Add a stable SSH alias on Controller:
   ```
   Host gateway
       HostName <gateway-tailnet-ip-or-wifi-ip>
       User operator
       IdentityFile ~/.ssh/agent/rtl8125_gateway_codex
       StrictHostKeyChecking accept-new
   ```
   If Tailscale is enabled, use the tailnet IP or MagicDNS name here. If
   not, use the WiFi LAN address and update it if DHCP changes.
4. Test keyed SSH:
   ```bash
   ssh gateway 'hostname; whoami; uname -a'
   ```
5. Enable passwordless sudo on Gateway for the `operator` user
   (matches the Controller-KVM guest):
   ```bash
   ssh gateway '
       echo "operator ALL=(ALL) NOPASSWD: ALL" | \
           sudo tee /etc/sudoers.d/99-operator-nopw
       sudo chmod 0440 /etc/sudoers.d/99-operator-nopw
       sudo visudo -c
   '
   ```
6. Test non-interactive sudo:
   ```bash
   ssh gateway 'sudo -n whoami'
   ```

**Acceptance**: `ssh gateway 'sudo -n whoami'` prints `root` without a
password prompt. The agent can now run the remaining setup phases.

---

## Phase 3 — Agent-run hardware identity check {#phase-3}

🤖 agent · ~5 min · validates Gateway is structurally identical to
Controller and records machine-specific PCI addresses.

Run from Controller:

```bash
ssh gateway '
    set -eu
    hostname
    whoami
    sudo -n true
    uname -a
    sudo lspci -nn | grep -iE "ethernet|network"
'
```

Expect rows matching Controller's hardware:

```
##:##.# Ethernet controller [0200]: Realtek Semiconductor ...
                    RTL8125 2.5GbE Controller [10ec:8125] (rev 05)
##:##.# Ethernet controller [0200]: Intel Corporation
                    Ethernet Controller I226-V [8086:125c] (rev 04)
##:##.0 Network controller [0280]: MEDIATEK Corp. MT7922 802.11ax ...
```

The PCI addresses (`##:##.#`) may differ between units; the **device IDs**
must match. The MS-A2 also ships two X710 SFP+ ports (`[8086:1572]`);
those are unused for this work and may remain DOWN.

Record Gateway's specific values in `docs/GATEWAY_HARDWARE.md`:

```markdown
# Gateway hardware

Captured: YYYY-MM-DD

| Device | PCI address | ID | Notes |
|---|---:|---|---|
| RTL8125B | `0000:??:??.?` | `[10ec:8125]` | driver target |
| I226-V | `0000:??:??.?` | `[8086:125c]` | traffic peer |
| MT7922 | `0000:??:??.?` | `[14c3:????]` | WiFi management |
```

**Acceptance**: keyed SSH works, passwordless sudo works, NIC IDs match,
and `docs/GATEWAY_HARDWARE.md` records Gateway's actual PCI addresses.

---

## Phase 4 — Management-link hardening {#phase-4}

🤖 agent · ~10 min · keeps Ethernet reserved for driver traffic.

Management traffic (SSH, rsync, apt) must stay on WiFi. The Ethernet
ports (RTL8125B + I226-V) are reserved for driver and cross-traffic
tests.

1. Verify WiFi is the local management path:
   ```bash
   ssh gateway 'ip -br addr; ip route get 1.1.1.1'
   ```
2. If Tailscale is enabled, verify tailnet reachability and record the SSH
   target address:
   ```bash
   ssh gateway 'tailscale status; tailscale ip -4'
   ```
3. Optionally pin `sshd` to the WiFi and/or Tailscale addresses by setting
   `ListenAddress <gateway-wifi-ip>` and, if enabled,
   `ListenAddress <gateway-tailnet-ip>` in `/etc/ssh/sshd_config`, then:
   ```bash
   ssh gateway 'sudo systemctl restart ssh'
   ```
4. Confirm the Ethernet links are not carrying management traffic before
   the cross-cable phase:
   ```bash
   ssh gateway 'ip -br link'
   ```

**Acceptance**: `ssh gateway hostname` returns the right hostname over
WiFi or Tailscale; Ethernet interfaces are DOWN (no carrier expected yet).

---

## Phase 5 — Build + install the debug+Rust kernel {#phase-5}

🤖 agent (operator may need to enter sudo once at kernel install) · ~45 min
build + 5 min install.

Gateway needs the **same kernel** as Controller's KVM guest:
`7.0.0-15-generic` with KASAN + lockdep + kmemleak + DMA_API_DEBUG +
CONFIG_RUST=y. Without that, the M5/M6 soak harnesses can't catch
KASAN-class bugs.

The agent does the build on Controller (or on Gateway — Controller is
faster), then deploys the `.deb` to Gateway.

1. Confirm the kernel source the Controller-KVM guest currently runs on:
   ```bash
   ssh -i ~/.ssh/agent/rtl8125_guest_codex operator@192.168.122.174 \
       'uname -a; ls /boot/vmlinuz-*'
   ```
   Note the kernel version exactly.
2. Reproduce that build from `references/ubuntu-kernel-7.0.0-15` (already
   fetched via `tools/fetch_references.sh`). The agent has the build
   recipe in `docs/M0a_TO_M1_RUNBOOK.md` Phase 2.
3. Package as `.deb` (`make bindeb-pkg`) and copy to Gateway via rsync:
   ```bash
   rsync -e "ssh -i ~/.ssh/agent/rtl8125_gateway_codex" \
       linux-image-7.0.0-15-generic_*.deb \
       linux-headers-7.0.0-15-generic_*.deb \
       linux-libc-dev_*.deb \
       operator@gateway:/tmp/
   ```
4. Install on Gateway:
   ```bash
   ssh gateway 'sudo dpkg -i /tmp/linux-*.deb'
   ```
5. Reboot Gateway into the new kernel. Confirm:
   ```bash
   ssh gateway 'uname -r'
   ssh gateway 'zcat /proc/config.gz | \
       grep -E "^CONFIG_(KASAN|LOCKDEP|KMEMLEAK|DMA_API_DEBUG|RUST)="'
   ```
6. Install kernel-Rust toolchain pieces on Gateway:
   ```bash
   ssh gateway 'sudo apt install -y rustc-1.93 bindgen \
       linux-lib-rust-7.0.0-15-generic'
   ```
   (Same set as Controller; pin must match.)

**Acceptance**: `uname -r` shows the debug+Rust kernel; debug configs
all present in `/proc/config.gz`; `rustc-1.93 --version` works.

---

## Phase 6 — Network topology: internal cross-traffic {#phase-6}

🔌 operator + 🤖 agent · ~15 min · mirrors Controller-KVM topology on bare metal.

The simplest validated topology: **same-machine cross-link inside
Gateway**. RTL8125B (running our Rust driver) ↔ I226-V (running stock
`igc`/`i225` peer). Mirrors the Controller-KVM setup where the
guest's RTL8125B talked to the host's I226-V — but without VFIO.

1. **Cable**: connect Gateway's RTL8125B RJ45 directly to Gateway's
   I226-V RJ45 with Cat6 (≥2.5 Gbps capable). The cable is internal to
   Gateway — both endpoints are NICs on the same chassis.
2. **IP scheme**: keep `10.0.0.0/24` from the Controller-KVM setup so
   automation paths don't have to change:
   - I226-V (peer): `10.0.0.1/24`
   - RTL8125B (driver-under-test): `10.0.0.2/24`
   - Operator's home/lab subnet stays on WiFi
3. **Cross-cable to Controller** (optional, for multi-machine tests):
   spare Ethernet port on Gateway ↔ Controller's I226-V or X710 if a
   second link is wanted. Use a different subnet (e.g. `10.0.1.0/24`) so
   routing stays unambiguous. **Not required for any M5/M6 gate.**
4. Configure on Gateway:
   ```bash
   # Quick test setup; productionize with netplan later
   sudo ip link set enp_i226 up
   sudo ip addr add 10.0.0.1/24 dev enp_i226
   sudo ip link set enp_rtl8125b up  # this only works once the driver is loaded
   sudo ip addr add 10.0.0.2/24 dev enp_rtl8125b
   # cross-ping
   ping -c 3 -I enp_rtl8125b 10.0.0.1
   ```
5. **No VFIO on Gateway.** Skip `tools/bind_vfio.sh` entirely. The driver
   runs natively against the chip via the kernel PCI bus, with no
   passthrough indirection.

**Acceptance**: same-machine cross-cable up + Gateway-internal ping works
between the two NIC IPs once the driver is loaded.

---

## Phase 7 — Driver build + smoke test {#phase-7}

🤖 agent · ~10 min.

1. Make sure the standard r8169 driver doesn't auto-claim the RTL8125B
   on Gateway. Either blacklist it for this device specifically, or use
   a `driver_override` (matches Controller-KVM teardown pattern):
   ```bash
   ssh gateway '
       sudo modprobe r8169  # if not already; we don'\''t blacklist globally
       echo "0000:??:??.0" | sudo tee /sys/bus/pci/drivers/r8169/unbind || true
       echo r8125_rust | sudo tee /sys/bus/pci/devices/0000:??:??.0/driver_override
   '
   ```
   Replace `0000:??:??.0` with the RTL8125B PCI address captured in
   Phase 3.
2. rsync the crate from Controller to Gateway:
   ```bash
   rsync -e "ssh -i ~/.ssh/agent/rtl8125_gateway_codex" \
       -a --delete --exclude='target/' --exclude='.git/' \
       --exclude='src/*.o' --exclude='src/*.ko' --exclude='src/*.mod*' \
       --exclude='src/*.cmd' --exclude='src/Module.symvers' \
       --exclude='src/modules.order' --exclude='src/.*.cmd' \
       ~/Projects/Rt8125-driver/rtl8125-rs/ \
       operator@gateway:/tmp/r8125_rust_build/
   ```
3. Build on Gateway:
   ```bash
   ssh gateway 'cd /tmp/r8125_rust_build && make 2>&1 | tail -5'
   ```
4. Load:
   ```bash
   ssh gateway '
       sudo insmod /tmp/r8125_rust_build/src/r8125_rust.ko
       sleep 8
       ip -br link show enp_rtl8125b
       sudo ethtool -i enp_rtl8125b | head -2
   '
   ```
5. Smoke test:
   ```bash
   ssh gateway '
       sudo ip addr add 10.0.0.2/24 dev enp_rtl8125b 2>/dev/null
       ping -c 3 -I enp_rtl8125b 10.0.0.1
   '
   ```

**Acceptance**: ping returns 3/3 with sane latency; `ethtool -i` reports
`driver: r8125_rust`.

---

## Phase 8 — Port the M5/M6 harnesses {#phase-8}

🤖 agent · ~30 min · standardize the runtime check scripts for Gateway.

All `ci/check_*.sh` runtime harnesses in the repo accept `IFACE`, `PEER`,
and `BDF` env-var overrides; they already work on any host that satisfies
the contract. Verify each on Gateway:

1. **`ci/check_counter_invariant.sh`** — 1 GB transfer + §6.3 gap=0 check
2. **`ci/check_rmmod_while_up.sh`** — module unload under traffic, 5 cycles
3. **`ci/check_packet_mutation.sh`** — 1000 malformed frames from peer
4. **`ci/check_aspm_idle_soak.sh`** — Gateway can FINALLY test this with
   a real bridge that supports ASPM L1 (the QEMU bridge on Controller-KVM
   only advertises L0s — see `docs/M5_CLOSEOUT.md`)
5. **`ci/check_aspm_on_idle_soak.sh`** — same, with `force_aspm=1`
6. **`ci/check_aspm_both_soaks.sh`** — the unified 48h wrapper
7. **`ci/check_flr_cycle.sh`** — the chip doesn't support FLR; bypass
   path is `device/remove` + `bus/rescan` with `driver_override`
8. **`ci/check_active_soak.sh`** — 24h traffic soak

Capture a Gateway baseline before any M6 code lands:

```bash
ssh gateway 'cd /tmp/r8125_rust_build && bash ci/check_counter_invariant.sh enp_rtl8125b 10.0.0.1'
ssh gateway 'cd /tmp/r8125_rust_build && bash ci/check_rmmod_while_up.sh'
ssh gateway 'cd /tmp/r8125_rust_build && bash ci/check_packet_mutation.sh'  # (peer side)
```

Record results in `docs/baseline/gateway_baseline.txt`.

---

## Phase 9 — M6 validation runs {#phase-9}

🤖 agent · long wall-clock · the gates that VFIO/KVM couldn't honestly clear.

Now that the chip has a **real PCIe bridge that advertises L1**, run the
real M5 ASPM-L1 soak:

```bash
ssh gateway '
    sudo systemd-run --unit=r8125-aspm-both-gateway \
        --working-directory=/tmp/r8125_rust_build \
        --setenv=BUILD_V2_DIR=/tmp/r8125_rust_build_v2 \
        --setenv=SOAK_HOURS=24 --setenv=IFACE=enp_rtl8125b \
        --setenv=PEER=10.0.0.1 --setenv=LOG=/tmp/r8125_aspm_both_gw.log \
        -- bash ci/check_aspm_both_soaks.sh
'
```

Monitor:
```bash
ssh gateway 'sudo systemctl status r8125-aspm-both-gateway --no-pager
              tail -20 /tmp/r8125_aspm_both_gw.log'
```

Capture `lspci -vv` on Gateway to confirm L1 actually enters during the
soak (LnkSta should show changes in ASPM state, unlike the always-L0
behavior in Controller's KVM).

Subsequent M6 work — MSI-X migration (task #53), Jumbo (task #54) — runs
the **implementation iteration on Controller's KVM** (fast, no soak time)
but **validation, perf baselines, and 24h soaks on Gateway**.

`docs/perf/` numbers per the plan §7 M6 gates come from Gateway, not the
KASAN-debug KVM guest (which has 30%+ overhead).

---

## Phase 10 — End of dev: wipe + Ubuntu Server {#phase-10}

☢️ operator · whenever M6/M7 are done.

When the driver has cleared all M5/M6 gates on Gateway and is no longer
needed for active testing:

1. Tear down systemd transient units (`systemctl stop`).
2. Snapshot all baselines + perf data to `docs/perf/`.
3. Wipe disk + install Ubuntu Server LTS for Gateway's production role.
4. Document the transition date in `docs/GATEWAY_HARDWARE.md` so the
   M6/M7 reproducibility note has a clear cutoff.

After wipe, Gateway is no longer a dev target. If the project needs
further bare-metal validation, the operator either (a) re-builds a dev
environment on Gateway (operator-time work), or (b) acquires a third
unit.

---

## What works on Gateway that doesn't on Controller-KVM

| Gate | Controller-KVM | Gateway bare-metal |
|---|---|---|
| 24h ASPM-off idle soak | ✅ | ✅ |
| 24h ASPM-on idle soak (REAL L1.x entry) | ❌ (synthetic bridge advertises L0s only) | ✅ |
| Suspend/resume via real ACPI S3 | ❌ (no PM in kernel-Rust PCI) | ⚠️ (still needs kernel-Rust PM API; FLR-substitute is closest) |
| Bare-metal perf measurements for `docs/perf/` | ❌ (KASAN-debug guest has 30%+ overhead) | ✅ |
| `cat /proc/interrupts` showing real MSI-X allocation | ❌ (VFIO IRQ remapping in the way) | ✅ |
| syzkaller without VFIO contention | ❌ | ✅ |
| Real PCIe error injection (`aer-inject`) | ❌ | ✅ |

## What stays on Controller

| Activity | Why on Controller |
|---|---|
| Hot iteration of Rust code | KVM guest reload < 30s; bare-metal needs kernel module install |
| Crash recovery via `virsh reset` | One command on Controller; bare-metal Gateway needs IPMI/power-cycle |
| Quick experimental builds | Build-and-test loop tighter |
| All static CI (`ci/run_checks.sh`) | Static checks are env-independent |

## Agent control surface (what the agent has access to)

After Phase 2 is complete, the agent on Controller can:

```bash
# Run any shell on Gateway
ssh -i ~/.ssh/agent/rtl8125_gateway_codex operator@gateway '<cmd>'

# Mirror Controller's KVM-guest pattern; same automation works
rsync -e "ssh -i ~/.ssh/agent/rtl8125_gateway_codex" -a \
    /repo operator@gateway:/tmp/r8125_rust_build/

# Load/unload driver
ssh ... 'sudo rmmod r8125_rust; sudo insmod .../r8125_rust.ko'

# Drive long-running soaks via systemd-run (survives SSH disconnect)
ssh ... 'sudo systemd-run --unit=... -- bash ci/check_*.sh'
```

The agent does NOT have console access (the WiFi-management posture).
If the kernel oopses badly enough to lose network, the operator must
power-cycle Gateway. Mitigation: KASAN-debug catches most issues before
they take down networking; bare-metal kernel-debug is no more dangerous
than the same kernel in the KVM guest, where we've already shaken out
the worst classes of bug.
