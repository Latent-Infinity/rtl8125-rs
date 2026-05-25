# M0a → M1 Operator Runbook

**Goal:** take the repo from "M0a captured, M1 gated" to "M1 may begin" by
clearing every unmet criterion in [`M1_ENTRY_CRITERIA.md`](M1_ENTRY_CRITERIA.md).
This is a *do-this-then-that* runbook with copy-pasteable commands, an
acceptance check per step, and the tracker rows each step clears.

Authoritative spec: `RTL8125_Rust_Driver_Implementation_Plan.md` v3.4 (§7 M0a,
§8, §15). This runbook **operationalizes** it; if they ever disagree, the plan
wins and this file is wrong — fix it.

---

## Conventions

| Tag | Meaning |
|---|---|
| 🖥️ **build host** | the MS-A2 itself, stock `7.0.0-15-generic`, normal user + `sudo` |
| 🧪 **guest** | the VFIO guest VM (disposable; debug+Rust kernel) |
| 🔌 **physical** | requires touching cables / BIOS |
| ☢️ **destructive** | unbinds the live NIC or changes host networking — see guard notes |

**Validated facts (do not re-derive on this unit):** RTL8125 = `0000:03:00.0`,
RTL8125B XID `0x641` rev `0x05`, IOMMU **group 18 (isolated)**, Secure Boot
**on** (host), kernel-authoritative **rustc 1.93.1 / LLVM 21**.

### ⚠️ The toolchain pin (read this once, it governs everything)

The kernel build is authoritative. `7.0.0-15-generic` was built with
**rustc 1.93.1 / LLVM 21**, and `linux-lib-rust-7.0.0-15-generic` ships the
kernel crate metadata **precompiled with exactly that rustc**. `rustc` has no
stable ABI, so **anything in the build path that is not 1.93.1 will fail**
(`error[E0463]: can't find crate for core` is this failure). Do **not** use
Rust 1.95.x — that userspace version is a `rustup` default and must not be on
`PATH` for any kernel/module build. Same 1.93.1 builds both the guest kernel
and the OOT module; never mix.

---

## TL;DR ordered checklist (each line links to a phase)

| # | Phase | Where | Clears tracker rows |
|---|---|---|---|
| 1 | [Install the distro kernel-rust toolchain set](#phase-1) | 🖥️ host | 3, 4 (build) |
| 2 | [Build the debug+Rust guest kernel](#phase-2) | 🖥️ host | 18 → unblocks 5, 14 |
| 3 | [Pin host mgmt to I226-V, isolate L2](#phase-3) | 🔌 host | (precondition for 8/10) |
| 4 | [Host VFIO bind-cycle automation](#phase-4) | ☢️ host | 9 (confirm), VFIO automation |
| 5 | [Create the guest, pass through the NIC](#phase-5) | 🧪 guest | 8 |
| 6 | [Serial-console capture + deliberate panic](#phase-6) | 🧪 guest | 13 |
| 7 | [Trivial OOT Rust module load-loop in guest](#phase-7) | 🧪 guest | 4 (load), 14 |
| 8 | [Re-capture, verify, commit, declare M1 open](#phase-8) | 🖥️ host | 1, 5, all green |

Rows **2, 6, 9 (isolation), 12, 15, 16, 17** are already ✅. Rows **7, 10, 11**
are **M0b** (gate M4, *not* M1) — see the [M0b appendix](#appendix-m0b).

---

## Phase 1 — Install the distro kernel-rust toolchain set {#phase-1}

🖥️ build host · `sudo` · ~5 min · clears tracker **3** and the *build* half of **4**

> This is the "validation finding 1" fix. It is plain apt — **not** a
> self-built kernel.

```bash
sudo apt-get update
sudo apt-get install -y \
  linux-lib-rust-7.0.0-15-generic \
  rustc-1.93 rust-1.93-src rust-1.93-clippy \
  bindgen dwarves \
  linux-headers-7.0.0-15-generic \
  clang lld llvm
```

Expected versions (apt candidate, confirmed 2026-05-19): `linux-lib-rust-…`
`7.0.0-15.15`, `rustc-1.93` `1.93.1+dfsg-0ubuntu6`, `bindgen` `0.72.1`,
`dwarves`/`pahole` `1.31`, `clang`/`llvm` `21`.

**Defeat the rustup 1.95 shadow** (the capture script calls plain `rustc`):

```bash
command -v rustc; rustc --version            # must show 1.93.1
# If it shows 1.95.x, a rustup/cargo shim is shadowing /usr/bin. Either:
rustup default none 2>/dev/null || true      # if rustup is installed, OR
hash -r; export PATH=/usr/bin:$PATH          # for this shell, AND make it
                                             # stick (remove ~/.cargo/bin from
                                             # PATH in your shell rc) so the
                                             # capture script sees 1.93.1 too.
rustc --version                              # re-check: rustc 1.93.1
```

**Acceptance** — re-run the non-destructive capture and read two files:

```bash
sudo tools/capture_m0_baseline.sh
grep -A1 'rustavailable' docs/baseline/rust_toolchain.txt   # want: "Rust is available!"  exit=0
tail -3 docs/baseline/oot_rust_buildtest.txt                # want: "RESULT: .ko BUILT OK"
```

If `rustavailable` still fails on `bindgen`/`core`: confirm `bindgen --version`
works and `rustc --version` is **1.93.1** in the *same shell the script runs
in* (sudo resets PATH — use `sudo env "PATH=/usr/bin:$PATH" tools/capture_m0_baseline.sh`
if needed).

**Evidence to commit:** the regenerated `docs/baseline/rust_toolchain.txt` and
`docs/baseline/oot_rust_buildtest.txt`.

> Tracker **4** has two halves: *build* (cleared here) and *load* (cleared in
> [Phase 7](#phase-7), which needs the guest from Phases 5–6).

---

## Phase 2 — Build the debug+Rust guest kernel {#phase-2}

🖥️ build host · `sudo` for deps only · **longest step, 30–90 min** on the
16C/32T box · clears the build half of tracker **18**, unblocks **5** and **14**

> The true M1 gate (validation finding 2). Stock generic has none of
> KASAN/KCSAN/lockdep/kmemleak/DMA_API_DEBUG. The **host stays stock**; only
> this guest kernel is custom. Built with the **same 1.93.1** from Phase 1.

```bash
sudo apt-get install -y build-essential flex bison libssl-dev libelf-dev \
                        libdw-dev bc rsync kmod cpio debhelper
mkdir -p ~/kbuild && cd ~/kbuild

# Guaranteed-exact source (deb-src is enabled — see references/PROVENANCE.md).
apt-get source linux=7.0.0-15.15
cd linux-7.0.0                                  # the unpacked source tree

cp /boot/config-7.0.0-15-generic .config        # start from the running config

# Rust + the six debug instruments the M1/M3/M5 gates require:
scripts/config --enable CONFIG_RUST
scripts/config --enable CONFIG_DEBUG_KERNEL
scripts/config --enable CONFIG_KASAN --enable CONFIG_KASAN_GENERIC
scripts/config --enable CONFIG_KCSAN
scripts/config --enable CONFIG_DEBUG_LOCK_ALLOC --enable CONFIG_PROVE_LOCKING
scripts/config --enable CONFIG_DEBUG_KMEMLEAK
scripts/config --enable CONFIG_DMA_API_DEBUG
# keep MODVERSIONS, VFIO, and r8169 as in the stock config
scripts/config --module CONFIG_VFIO --module CONFIG_VFIO_PCI --module CONFIG_R8169
# disable the Ubuntu module-signing keys (lab guest; Secure Boot off in guest)
scripts/config --disable CONFIG_SYSTEM_TRUSTED_KEYS \
               --disable CONFIG_SYSTEM_REVOCATION_KEYS

make olddefconfig RUSTC=rustc-1.93

# MUST print "Rust is available!" before you spend an hour compiling:
make RUSTC=rustc-1.93 BINDGEN=bindgen rustavailable

# Build installable .debs (image + headers + libc-dev):
make -j"$(nproc)" RUSTC=rustc-1.93 BINDGEN=bindgen bindeb-pkg
ls -1 ../*.deb                                  # linux-image-…-dbg+rust*.deb etc.
```

**Acceptance:** `make … rustavailable` prints `Rust is available!`, and
`bindeb-pkg` produces `../linux-image-7.0.0*.deb` (+ headers deb). Keep the
`.config` — copy it in as evidence. On 2026-05-19 this completed as kernel
release `7.0.0` and produced:
`linux-image-7.0.0_7.0.0-2_amd64.deb`,
`linux-headers-7.0.0_7.0.0-2_amd64.deb`,
`linux-libc-dev_7.0.0-2_amd64.deb`, and
`linux-image-7.0.0-dbg_7.0.0-2_amd64.deb`.

```bash
cp .config ~/Projects/Rt8125-driver/rtl8125-rs/docs/baseline/guest_debug_rust_kernel.config
```

**Known sharp edges (flag, don't guess):**
- `KASAN` + `KCSAN` together is heavy and occasionally conflicts; if
  `olddefconfig` drops one, build them as **two guest kernels** (KASAN kernel
  for M3/soak, KCSAN kernel for the race soak) — the plan's M5 soak allows
  separate runs. Record which configs actually stuck:
  `grep -E 'KASAN|KCSAN|LOCK_ALLOC|KMEMLEAK|DMA_API_DEBUG|CONFIG_RUST=' .config`.
- If `rustavailable` fails: the kernel's `scripts/rust_is_available.sh` prints
  the exact rustc/bindgen it wants — it will be in the 1.93.x band. Do not
  "fix" it by upgrading rustc past 1.93.

**Evidence to commit:** `docs/baseline/guest_debug_rust_kernel.config`.

---

## Phase 3 — Pin host management to the I226-V, isolate L2 {#phase-3}

🔌 physical + 🖥️ host · `sudo` · ☢️ changes host networking · precondition for
Phases 4–6 (validation finding 3)

On this unit host mgmt is currently **Wi-Fi**, the I226-V is **down**, and the
box runs **Kubernetes**. Before any VFIO unbind, SSH must ride a *different*
NIC and the RTL8125 test segment must be off the k8s/host L2 domain.

1. 🔌 Plug the **I226-V** (`enp4s0`) into your management LAN. Plug the
   **RTL8125** (`enp3s0`) into an **isolated** test segment (a dedicated switch
   or a direct cable to the M0b peer) — **not** the k8s/mgmt domain.
2. Bring mgmt up on the I226-V and make it the default route (example with
   `netplan`; adapt to your network — this step is operator judgement):
   ```bash
   # /etc/netplan/99-mgmt-i226.yaml  (DHCP example)
   network: {version: 2, ethernets: {enp4s0: {dhcp4: true}}}
   ```
   ```bash
   sudo netplan apply
   ip route get 1.1.1.1            # default route MUST be via enp4s0, NOT wlp6s0/enp3s0
   ```
3. Confirm the RTL8125 carries no host route (its iface may even be down):
   ```bash
   ip route show | grep -w enp3s0 || echo "OK: no host route via RTL8125"
   ```

**Acceptance:** `ip route get 1.1.1.1` shows `dev enp4s0`. (Note:
`tools/bind_vfio.sh` has a built-in guard that *refuses* if the default route
is via the RTL8125 — this is your safety net, not a substitute for this step.)

---

## Phase 4 — Host VFIO bind-cycle automation {#phase-4}

🖥️ host · `sudo` · ☢️ destructive (uses the committed guarded scripts) ·
confirms tracker **9**, satisfies the M0a "100× bind-cycle" deliverable

```bash
# 100 cycles of r8169 → vfio-pci → r8169 using the per-device driver_override.
sudo bash -c '
for i in $(seq 1 100); do
  tools/bind_vfio.sh   >/tmp/vfio_cycle.$i.bind   2>&1 || { echo "bind FAIL @ $i";  exit 1; }
  tools/unbind_vfio.sh >/tmp/vfio_cycle.$i.unbind 2>&1 || { echo "unbind FAIL @ $i"; exit 1; }
done
echo "100 bind/unbind cycles OK"'
dmesg -T | tail -40                # expect NO new WARN/oops from the cycling
```
Leave it bound to `vfio-pci` for the guest phases:
```bash
sudo tools/bind_vfio.sh
lspci -nnk -s 0000:03:00.0         # Kernel driver in use: vfio-pci
```

**Acceptance:** "100 bind/unbind cycles OK", zero new `dmesg` WARN/oops,
`lspci -k` shows `vfio-pci`.

**Evidence to commit:** save a short summary, e.g.
`dmesg -T | tail -40 > docs/baseline/vfio_bindcycle_dmesg.txt`. *(Optional,
recommended: lift the loop above into `tools/vfio_bindcycle.sh` and commit it
so the deliverable is reproducible.)*

---

## Phase 5 — Create the guest, pass through the RTL8125 {#phase-5}

🧪 guest · `sudo` · clears tracker **8**

```bash
sudo apt-get install -y qemu-kvm libvirt-daemon-system virtinst ovmf

# Ubuntu 26.04 guest, Secure Boot OFF (lab guest — plan §13 allows this),
# file-backed serial console, RTL8125 passed through at bus 0x03.
sudo virt-install --name rtl8125-guest --memory 8192 --vcpus 6 \
  --cdrom /var/lib/libvirt/boot/ubuntu-26.04-server.iso \
  --disk size=20 --os-variant ubuntu26.04 \
  --boot uefi \
  --hostdev pci_0000_03_00_0 \
  --serial file,path=/var/log/r8125-guest-serial.log \
  --graphics none --console pty,target_type=serial
```

After the guest installs, copy in and install the Phase-2 kernel debs, then
reboot the guest into it:
```bash
# host → guest (scp/virt-copy-out, your choice), then in the GUEST:
sudo dpkg -i linux-image-7.0.0*dbg*rust*.deb linux-headers-7.0.0*dbg*rust*.deb
sudo reboot
```

**Acceptance — inside the guest:**
```bash
uname -r                                   # the debug+rust kernel
zgrep -E 'KASAN|KCSAN|LOCK_ALLOC|KMEMLEAK|DMA_API_DEBUG|CONFIG_RUST=y' /boot/config-$(uname -r)
lspci -nnvv | grep -A3 -i 8125             # guest SEES 0000:03:00.0 RTL8125B
```
The guest must boot the custom kernel **and** enumerate the RTL8125.

**Evidence to commit:** `docs/baseline/guest_lspci_rtl8125.txt` (guest
`lspci -nnvv` of the device), `docs/baseline/guest_uname_config.txt`.

---

## Phase 6 — Serial-console capture + deliberate panic test {#phase-6}

🧪 guest → 🖥️ host · clears tracker **13**

Prove a guest panic is recoverable as text on the host *before* trusting it
with driver code.

```bash
# In the GUEST (this WILL crash the guest — that's the test):
echo 1 | sudo tee /proc/sys/kernel/sysrq
echo c | sudo tee /proc/sysrq-trigger      # forced crash

# On the HOST, immediately:
tail -50 /var/log/r8125-guest-serial.log   # must contain the oops/panic trace
```

**Acceptance:** the host file `/var/log/r8125-guest-serial.log` contains
`sysrq: Trigger a crash` followed by a `Kernel panic` / call trace. Recover:
```bash
sudo virsh destroy rtl8125-guest; sudo virsh start rtl8125-guest
```

**Evidence to commit:** the captured panic excerpt →
`docs/baseline/guest_serial_panic_proof.txt`.

---

## Phase 7 — Trivial OOT Rust module load-loop in the guest {#phase-7}

🧪 guest · clears the *load* half of tracker **4** and **14**

The guest kernel now has Rust metadata. Build and cycle the trivial module
(the same probe `tools/capture_m0_baseline.sh §8` builds, now also *loaded*).

> **Prerequisites (the stock guest does NOT ship these).** Before building:
> 1. Install the guest build toolchain — `rustc-1.93`, `bindgen`,
>    `build-essential`, `dwarves` — pinned to the same versions as Phase 1.
> 2. The `linux-headers` deb ships **zero** files under `rust/`. Stage the
>    rust artifact subtree from the host build tree
>    (`~/kbuild/linux-7.0.0/rust/`) into the guest's
>    `/usr/src/linux-headers-$(uname -r)/rust/` (rsync). Without it the build
>    fails `error[E0463]: can't find crate for core`.

```bash
# In the GUEST, KDIR=/lib/modules/$(uname -r)/build
mkdir -p /tmp/oot && cd /tmp/oot
cat > hello_rust_oot.rs <<'EOF'
use kernel::prelude::*;
module! {
    type: H,
    name: "hello_rust_oot",
    authors: ["rtl8125-rs"],
    description: "Trivial OOT Rust module — M0a Phase 7 load-loop probe",
    license: "GPL",
}
struct H;
impl kernel::Module for H {
    fn init(_: &'static ThisModule) -> Result<Self> {
        pr_info!("hello_rust_oot: init\n");
        Ok(H)
    }
}
EOF
echo 'obj-m += hello_rust_oot.o' > Kbuild
# NOTE: do NOT pass LLVM=1 — the guest kernel is GCC-built (gcc 15.2.0). LLVM=1
# forces clang for the C module-glue and clang rejects GCC-only codegen flags.
make -C /lib/modules/$(uname -r)/build M=$PWD RUSTC=rustc-1.93 BINDGEN=bindgen modules

for i in $(seq 1 100); do
  sudo insmod hello_rust_oot.ko
  grep -q '^hello_rust_oot ' /proc/modules || { echo "not loaded @ $i"; break; }
  sudo rmmod hello_rust_oot
done
echo scan | sudo tee /sys/kernel/debug/kmemleak   # force a kmemleak scan
dmesg | grep -iE 'kmemleak|lockdep|BUG|WARN' | tail
```

**Acceptance:** 100 insmod/rmmod cycles, module refcount returns to 0 each
time, **zero** kmemleak/lockdep/BUG/WARN in `dmesg`.

**Evidence to commit:** `docs/baseline/guest_oot_loadloop.txt` (the loop output
+ the clean `dmesg` grep).

---

## Phase 8 — Re-capture, verify, commit, declare M1 open {#phase-8}

🖥️ host · closes tracker **1, 5**, flips the board green

```bash
sudo tools/capture_m0_baseline.sh          # row 1: dmidecode now under sudo → CPU SKU/RAM
bash ci/run_checks.sh                       # must stay green (exit 0)
```

Then, in `docs/M1_ENTRY_CRITERIA.md`, set each verified row to ✅ with its
evidence file, commit the `docs/baseline/` artifacts, and confirm:

- 3 ✅ (`rust_toolchain.txt`) · 4 ✅ (build: `oot_rust_buildtest.txt` + load:
  `guest_oot_loadloop.txt`) · 5 ✅ (`guest_debug_rust_kernel.config`) · 8 ✅
  (`guest_lspci_rtl8125.txt`) · 13 ✅ (`guest_serial_panic_proof.txt`) · 14 ✅
  · 18 ✅ · 1 ✅ (`hw_dmidecode.txt` now populated).

When **every M1 row except the M0b-only rows (7, 10, 11)** is ✅:

> **M1 begins.** Create `src/lib.rs` + `Kbuild`/`Makefile`, register the PCI
> driver for `10EC:8125`, and work the M1 gate (1000× insmod/rmmod clean under
> lockdep+kmemleak in the guest). Build everything with **RUSTC=rustc-1.93**.

---

## Appendix — M0b (gates M4, NOT M1) {#appendix-m0b}

Do **not** block M1 on this. Required only before **M4** (first packet-moving
milestone). Fills tracker rows **7, 10, 11**.

1. 🔌 Connect the RTL8125 test segment to a documented peer (direct cable or a
   dedicated switch), isolated from the k8s/mgmt domain (Phase 3 already did
   the host side).
2. Fill in **every field** of `docs/baseline/TOPOLOGY.md` (peer NIC/OS/driver/
   MTU, switch model/firmware, negotiated speed, EEE/802.3az state).
3. Capture `r8169` (and, if installed, out-of-tree `r8125`) `iperf3` baselines
   — TCP/UDP, 1500 + 9000 MTU — into `docs/baseline/` and verify a peer-side
   packet capture path works.

Acceptance: `TOPOLOGY.md` has no blank fields; baseline `iperf3` JSON +
peer-capture procedure committed. Then M4 may proceed.
