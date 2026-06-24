# Using the r8125_rust driver

Practical instructions for building, loading, and using the `r8125_rust` driver
for the Realtek **RTL8125 / RTL8125B** 2.5 GbE controller (PCI `10EC:8125`,
validated revision RTL8125B / MAC_VER_63).

---

## Do you need a custom kernel? (read this first)

There are two tiers. Pick the lowest one that covers what you need.

| Tier | What works | Kernel requirement |
|------|-----------|--------------------|
| **A — core driver** | Link, TX/RX, checksum/TSO/VLAN offload, RSS multi-queue, XDP + AF-XDP zero-copy, devlink, LEDs, PHY hwmon, ethtool stats, WoL *arming* | A **Rust-enabled, but otherwise stock** kernel. **No source patches.** |
| **B — full PCI lifecycle** | Tier A **plus** system-sleep suspend/resume (incl. WoL wake from S3), `.shutdown`/kexec quiesce, PCIe function-level reset, AER recovery, runtime PM | Tier A kernel **plus 5 out-of-tree patches** to `rust/kernel/pci.rs` → a **custom (patched) kernel**. |

**The honest bottom line:** the driver is a Rust kernel module, so the target
kernel **must have `CONFIG_RUST=y`** and the in-tree Rust PCI/net abstractions.
Most stock *distro* kernels (Ubuntu/Fedora/Debian) do **not** enable Rust yet, so
in practice you need a Rust-enabled kernel. But that is a **config choice, not a
source patch** — if your kernel already has Rust on, the **core driver (Tier A)
loads with no kernel modifications at all**. Only Tier B's lifecycle extras
require patching the kernel.

This guide covers **Tier A** as the main path; Tier B is an appendix.

---

## 1. Prerequisites

**Hardware:** a Realtek RTL8125/RTL8125B PCIe NIC (`lspci -nn | grep 10ec:8125`).

**Target kernel — must have:**
- `CONFIG_RUST=y` (the deciding requirement)
- `CONFIG_PCI`, `CONFIG_MII`, `CONFIG_PHYLIB`, `CONFIG_REALTEK_PHY`
- Kernel build headers/tree for the *running* kernel
  (`/lib/modules/$(uname -r)/build`)

Check Rust support:
```sh
zcat /proc/config.gz 2>/dev/null | grep -E 'CONFIG_RUST=|CONFIG_REALTEK_PHY=' \
  || grep -E 'CONFIG_RUST=|CONFIG_REALTEK_PHY=' /boot/config-$(uname -r)
```
If `CONFIG_RUST` is not `y`, stop — you need a Rust-enabled kernel first (build
mainline/your distro kernel with Rust enabled, or use a kernel that ships it).

**Optional CONFIGs (only for the matching feature):**
- AF_XDP: `CONFIG_XDP_SOCKETS=y`
- devlink health reporter: `CONFIG_NET_DEVLINK=y`
- LED offload: `CONFIG_LEDS_CLASS=y` + `CONFIG_LEDS_TRIGGER_NETDEV=y`
- PHY temperature via hwmon: `CONFIG_REALTEK_PHY_HWMON=y`
- page_pool ethtool stats: `CONFIG_PAGE_POOL_STATS=y`

**Build toolchain (matched to the kernel's Rust):**
- `rustc` **matching the kernel's required version** — this tree used
  **`rustc-1.93`** (`make` defaults to `RUSTC=rustc-1.93`; do not substitute a
  newer rustup default)
- `bindgen`
- a C compiler (`gcc`)

---

## 2. Build the module

> **Important:** build the `.ko` **on (or against) the exact target kernel.** If
> the kernel has `CONFIG_DEBUG_INFO_BTF_MODULES=y`, a `.ko` built against a
> *different* kernel tree is rejected at load with
> `failed to validate module BTF: -22`. Building on the target machine avoids
> this.

From the driver source tree:
```sh
make                      # Tier A: default, stock Rust-kernel build
```
Override the kernel tree or toolchain if needed:
```sh
make KDIR=/path/to/kernel/build RUSTC=rustc-1.93 BINDGEN=bindgen
```
Output: `src/r8125_rust.ko`. Confirm it built for your kernel:
```sh
modinfo src/r8125_rust.ko | grep -E 'vermagic|srcversion|name'
```

---

## 3. Load the driver

The in-tree **`r8169`** driver also claims RTL8125 hardware, so unbind/blacklist
it first.

**One device, ad-hoc (recommended for testing):**
```sh
# find the device
lspci -nn -d 10ec:8125          # note the BDF, e.g. 0000:03:00.0

# release it from r8169 if currently bound
echo 0000:03:00.0 | sudo tee /sys/bus/pci/drivers/r8169/unbind 2>/dev/null

# load our driver (it has a PCI id-table and auto-binds 10EC:8125)
sudo insmod src/r8125_rust.ko
```

If the device doesn't auto-bind (still claimed by r8169), force it:
```sh
sudo modprobe -r r8169 2>/dev/null
sudo insmod src/r8125_rust.ko
echo 0000:03:00.0 | sudo tee /sys/bus/pci/drivers/r8125_rust/bind 2>/dev/null
```

**Make it permanent (install + blacklist r8169 for this NIC):**
```sh
sudo make modules_install            # installs r8125_rust.ko + depmod
echo 'blacklist r8169' | sudo tee /etc/modprobe.d/r8125_rust.conf
# rebuild initramfs per your distro, then reboot, or modprobe r8125_rust
```

---

## 4. Verify it's working

```sh
ethtool -i enp3s0          # driver: r8125_rust, firmware-version: rtl8125b-2_...
ip link show enp3s0        # state UP
dmesg | grep r8125_rust    # "Link is Up - 2.5Gbps/Full", PHY firmware applied
ethtool enp3s0 | grep -iE 'speed|link'   # Speed: 2500Mb/s, Link detected: yes
```
(Interface name varies; use whatever `ip link` shows for the device.)

---

## 5. Configure

**Multi-queue RSS** (recommended for routing / load-balancing — needed to reach
line-rate RX; single-queue RX is CPU-bound). Power-of-two queue counts only
(1/2/4):
```sh
# at load time:
sudo insmod src/r8125_rust.ko rss_queues=4
# or live, via ethtool:
sudo ethtool -L enp3s0 rx 4
sudo ethtool -l enp3s0          # confirm "Combined/RX: 4"
ethtool -x enp3s0               # RSS indirection table + key
```

**Useful module parameters** (`modinfo src/r8125_rust.ko` for the full list):
- `rss_queues=<0|1|2|4>` — hardware RSS queue count (0 = RSS off, single-queue fallback; 1 = single-queue validation)
- `force_aspm=<0|1>` / `aspm_force_off=<0|1>` — PCIe ASPM power tuning
- `intx_only=<0|1>` — force legacy INTx instead of MSI/MSI-X (debug)
- `irq_v2=<0|1|2>` — V2 MSI-X surface select: 0=off (legacy MSI), 1=auto (default), 2=require V2 (debug)
- `irq_pin_cpu=<n>` — pin RX IRQ affinity base CPU (multi-queue spreading)
- `debug_counters=<0|1>` — extra `ethtool -S` diagnostic counters

**Standard ethtool surfaces** that work: `-S` (stats incl. per-queue + page_pool),
`-k` (offloads), `-g` (ring sizes), `-a` (pause), `-s wol g` (arm Wake-on-LAN),
`-T` (HW timestamping), `--show-fec`/link settings, channels (`-l`/`-L`), RSS (`-x`/`-X`).

**XDP / AF_XDP:** attach a native XDP program with `ip link set dev enp3s0 xdp …`
or `bpftool`; AF_XDP zero-copy sockets bind per queue. `xdp_features` advertises
`BASIC | REDIRECT | NDO_XMIT | XSK_ZEROCOPY`.

---

## 6. Unload

```sh
sudo ip link set enp3s0 down
sudo rmmod r8125_rust
# to hand the NIC back to the stock driver:
sudo modprobe r8169 && echo 0000:03:00.0 | sudo tee /sys/bus/pci/drivers/r8169/bind
```

---

## Troubleshooting

- **`insmod: ERROR … Invalid module format` / "version magic" mismatch** — the
  `.ko` was built against a different kernel. Rebuild with
  `KDIR=/lib/modules/$(uname -r)/build`.
- **`failed to validate module BTF: -22`** — `.ko` built on a *different* tree
  than the running kernel (BTF base mismatch). Build on the **target** machine.
- **`insmod` says "Unknown symbol" / Rust symbols missing** — your kernel does
  not have `CONFIG_RUST=y` or the in-tree Rust abstractions. You need a
  Rust-enabled kernel (see §1).
- **NIC stays on `r8169`** — unbind/blacklist r8169 (see §3).
- **Link won't come up at 2.5G** — give autoneg ~10 s after `up`; check the cable
  and the link partner support 2.5GBASE-T.
- **Low single-queue RX throughput** — expected; enable RSS (§5). Multi-queue RX
  reaches line rate.
- **MSI-X issues (spurious IRQs, wedged TX)** — try `irq_v2=0` to fall back to the
  legacy single-vector MSI surface, or `intx_only=1` to force INTx (see §5).

---

## Known limitations (Tier A / default build)

- **System-sleep PM, `.shutdown`, PCIe reset, AER, runtime PM** are **not** in
  the default build — they need Tier B (see appendix). The default build *arms*
  WoL bits via `ethtool -s wol g` but cannot install the S3 suspend hook, so
  wake-from-S3 needs Tier B.
- **Jumbo frames:** `max_mtu` is 9000 (mainline-equivalent config). Jumbo
  requires a link/peer that actually carries >~1.6 KB frames; on hardware where
  the in-tree `r8169` can't do jumbo, this driver can't either — it is not a
  driver limitation. Standard 1500-MTU is fully validated.
- **Multi-buffer RX (`NETDEV_XDP_ACT_RX_SG`)** is intentionally not advertised —
  the RTL8125 has no RX scatter; jumbo uses a single large buffer, like mainline.
- Deferred ethtool surfaces (by design): ring resize, coalesce, EEPROM, netpoll,
  RXALL/RXFCS, n-tuple steering.

---

## Appendix — Tier B: the full PCI lifecycle build (custom kernel)

The system-sleep PM, shutdown, reset, AER, and runtime-PM features are gated
behind 5 out-of-tree patches that extend the kernel's Rust PCI abstraction
(`rust/kernel/pci.rs`). They are independent of this driver (any Rust PCI driver
would use them) and are documented in `kernel-patches/README.md`.

1. Apply the patches to your kernel source (order matters: 0001 → 0005), then
   rebuild and install that kernel:
   ```sh
   # in the kernel source tree, against a clean rust/kernel/pci.rs:
   patch -p0           < /path/rtl8125-rs/kernel-patches/0001-*.patch
   python3 /path/rtl8125-rs/tools/patch_pci_shutdown.py        # 0002
   python3 /path/rtl8125-rs/tools/patch_pci_reset.py           # 0003
   python3 /path/rtl8125-rs/tools/patch_pci_aer.py             # 0004
   python3 /path/rtl8125-rs/tools/patch_pci_runtime_pm.py      # 0005
   ```
2. Build the driver against that patched kernel with the matching knobs:
   ```sh
   make KDIR=/path/to/patched/kernel/build \
        PCI_PM=1 SHUTDOWN=1 RESET=1 AER=1 RUNTIME_PM=1
   ```
   Each knob is independent — enable only the features whose patch you applied
   (e.g. `make PCI_PM=1` alone for just system-sleep PM). The default `make`
   (no knobs) needs none of the patches.
</content>
