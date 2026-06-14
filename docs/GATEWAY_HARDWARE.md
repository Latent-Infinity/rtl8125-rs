# Gateway — Hardware + BIOS Reference

Companion to [`GATEWAY_SETUP.md`](GATEWAY_SETUP.md). Records the
machine-specific PCI addresses, BIOS navigation paths, and quirks
that the agent's automation depends on.

## Hardware identity (recorded 2026-05-28)

| Attribute | Value |
|---|---|
| Vendor / model | Minisforum MS-A2 |
| CPU | AMD Ryzen 9 9955HX (Zen 5, 16C/32T) |
| BIOS | AMI v02.22.0058 |
| Hostname | `ms-a2-gateway` |
| User | `firestrand` (UID matches Controller) |
| Management address | `100.125.107.46` (Tailscale; WiFi-backed) |

### PCI device map (matches Controller hardware exactly)

| BDF | Device | Linux iface | Used for |
|---|---|---|---|
| `0000:03:00.0` | Realtek RTL8125 2.5GbE [10ec:8125] rev 0x05 | `enp3s0` | **Driver under test** — kept in default netns |
| `0000:04:00.0` | Intel I226-V [8086:125c] rev 0x04 | `enp4s0` → moved to `peer` netns | Cross-traffic peer at 10.0.0.1 |
| `0000:05:00.0` | Intel X710 SFP+ [8086:1572] rev 0x02 | `enp5s0f0np0` | Unused |
| `0000:05:00.1` | Intel X710 SFP+ [8086:1572] rev 0x02 | `enp5s0f1np1` | Unused |
| `0000:06:00.0` | MediaTek MT7922 802.11ax WiFi [14c3:0616] | `wlp6s0` | Management (Tailscale rides on this) |

### Upstream PCIe bridge layout (relevant for ASPM)

| Endpoint | Upstream bridge BDF | Device# in BIOS |
|---|---|---|
| RTL8125B (`03:00.0`) | `00:03.1` | **Dev#3 / Func#1** |
| I226-V (`04:00.0`) | (different port) | Dev#3 / Func#2 |
| X710 (`05:00.x`) | (different port) | Dev#2 / Func#1 |
| MT7922 WiFi | (different port) | Dev#2 / Func#2 |
| NVMe SSDs | | Dev#1 / Func#2-4 |

The (Dev#, Func#) values come from the BIOS-side ASPM control names.
They correspond to the AMD root-complex's downstream port for each
slot.

## Network topology

```
                  ┌──────────────────────────────────────────┐
                  │   Gateway (ms-a2-gateway)                │
                  │   ─────────────────────                  │
                  │   default netns                          │
                  │   ─────────────────────                  │
                  │   wlp6s0   (WiFi, Tailscale, mgmt)       │   ← agent SSH lives here
                  │   enp3s0   (RTL8125B, driver under test) │   ← 10.0.0.2/24
                  │       │                                  │
                  │       └─────── Cat6 cable ──────┐        │
                  │                                  │       │
                  │   peer netns                     │       │
                  │   ─────────────────────          │       │
                  │   enp4s0   (I226-V, stock igc)──┘        │   ← 10.0.0.1/24
                  └──────────────────────────────────────────┘
```

**Why netns isolation**: both NICs live on the same kernel. Without
namespacing, Linux short-circuits same-subnet traffic through
loopback before it ever reaches the wire. Putting the I226-V in its
own netns forces traffic through the physical Cat6 link — which is
what we're actually testing.

## BIOS — exact path to ASPM control

**This is the operator-facing path. Once set, no need to revisit
unless the firmware is wiped.**

```
Boot → press Del → "Setup" menu
  Advanced
    └── Onboard Devices Settings
          └── PCI-E Port
                ├── ASPM Mode(Dev#1/Func#2)   ─ SSD0
                ├── ASPM Mode(Dev#1/Func#3)   ─ SSD1
                ├── ASPM Mode(Dev#1/Func#4)   ─ SSD2
                ├── ASPM Mode(Dev#2/Func#1)   ─ X710 LAN
                ├── ASPM Mode(Dev#2/Func#2)   ─ WiFi (MT7922)
                ├── ASPM Mode(Dev#3/Func#1)   ─ ★ RTL8125B ★  ← us
                └── ASPM Mode(Dev#3/Func#2)   ─ I226-V
```

Each ASPM Mode setting accepts:
`Auto | L0s And L1 Entry | L1 Entry | L0s Entry | Disabled`

For the M5 L1.x soak gate, set **ASPM Mode(Dev#3/Func#1)** to
**"L0s And L1 Entry"** (or just "L1 Entry" if you want to test L1 in
isolation).

### Top-level Advanced menu items (as shipped)

If the navigation path above isn't visible, the firmware variant may
have collapsed or renamed it. Expected siblings under **Advanced**:

1. Trusted Computing
2. CPU Configuration
3. **Onboard Devices Settings** ← the one we want
4. ACPI setting
5. Hardware Monitor
6. Network Stack Configuration
7. AMD PBS
8. AMD CBS
9. AMD Overclocking
10. Addons

Some Minisforum BIOS revisions hide advanced submenus behind
**Alt+F5** at the top menu. Try that if "Onboard Devices Settings"
doesn't show.

## How to verify the change took effect

After updating the BIOS setting and rebooting, on Gateway:

```bash
sudo lspci -s 00:03.1 -vv | grep -E "LnkCap|LnkCtl"
```

| Before (factory) | After (ASPM enabled in BIOS) |
|---|---|
| `LnkCap: ... ASPM not supported` | `LnkCap: ... ASPM L0s L1` (or `L0s` or `L1` depending on setting) |
| `LnkCtl: ASPM Disabled` | `LnkCtl: ASPM L0s L1 Enabled` (after kernel ASPM policy applies) |

If `LnkCap` still shows "not supported" after the BIOS reboot, the
setting didn't stick — re-enter BIOS and confirm.

## Driver bind procedure (kept here for quick reference)

The stock Ubuntu kernel binds `r8169` to the RTL8125B at boot. To
switch to our Rust driver:

```bash
sudo ip link set enp3s0 down 2>/dev/null || true
echo 0000:03:00.0 | sudo tee /sys/bus/pci/drivers/r8169/unbind
echo r8125_rust | sudo tee /sys/bus/pci/devices/0000:03:00.0/driver_override
sudo insmod /tmp/r8125_rust_build/src/r8125_rust.ko
# (the driver auto-binds via driver_override + alias match)
```

To revert to stock `r8169` for a fresh comparison test:

```bash
sudo rmmod r8125_rust 2>/dev/null
echo '' | sudo tee /sys/bus/pci/devices/0000:03:00.0/driver_override
echo 0000:03:00.0 | sudo tee /sys/bus/pci/drivers/r8169/bind
```

## Established baselines

| Measurement | Date | Value |
|---|---|---|
| iperf3 g→g internal cross-cable, TSO on, MTU 1500 | 2026-05-28 | 2.36 Gbits/sec, 0 retransmits |
| Stock `r8169` reference (same hardware) | (pending) | (to be captured) |

## Known quirks / not-yet-exposed

- **`/proc/config.gz` not available** — stock Ubuntu kernel doesn't
  ship it. Use `/boot/config-$(uname -r)` or `dpkg -L
  linux-headers-$(uname -r) | grep config`.
- **Stock kernel lacks KASAN/lockdep/kmemleak/DMA_API_DEBUG** —
  Gateway runs the distro `7.0.0-15-generic` with `CONFIG_RUST=y`
  but not the destructive debug knobs. Adequate for M6 work;
  insufficient for KASAN-bug catching. A custom debug kernel build
  is `GATEWAY_SETUP.md` Phase 5b (optional).
- **`force_aspm` module param** not visible in
  `/sys/module/r8125_rust/parameters/` — kernel-Rust
  `module_param` macro doesn't create the sysfs read-back files
  (it processes the insmod arg correctly but doesn't expose). The
  param IS in effect, just not introspectable from userspace. See
  `docs/HARDENING_CLOSEOUT.md` for the discovery.

## Sources (for the BIOS path above)

- [Minisforum MS-A2 BIOS Options — theDXT (2025-07)](https://thedxt.ca/2025/07/minisforum-ms-a2-bios-options/)
- [Minisforum BIOS Key: Unlock Hidden Settings — superanswer.blog](https://www.superanswer.blog/minisforum-bios-key-unlock-hidden-settings)
- [Minisforum support forum — Advanced BIOS thread](https://bbs.minisforum.com/threads/advanced-bios.2208/)
