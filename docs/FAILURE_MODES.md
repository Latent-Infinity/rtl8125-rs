# Failure modes — `r8125_rust` operator runbook

**Status (2026-05-29):** initial taxonomy. Updated as new failure
classes are observed in field. Pure operator doc — no runtime cost
to the driver. If you're reading this during an incident, jump
straight to the matching dmesg pattern below.

## Quick-grep cheat sheet

```bash
# What's the driver doing right now?
sudo dmesg --since "10 min ago" | grep -E 'r8125_rust|enp.*: Link'
sudo ethtool -S enp5s0 | head -10                    # §6.3 counters
cat /proc/interrupts | grep r8125_rust              # IRQ delivery
sudo lspci -vv -s 0000:05:00.0 | grep -E 'LnkSta|LnkCtl'  # ASPM state

# Single-command full snapshot (after Tier 3a)
scripts/dump_state.sh > /tmp/r8125_$(date +%s).log
```

## The §6.3 disposition-counter invariant

This equation must hold at every snapshot:

```
tx_received == tx_consumed + tx_busy_exception + tx_dropped_error
```

A persistent gap (multiple samples in a row) is **always a real
bug**. A transient gap of small N (`<=` ring depth) is just the
in-flight-at-snapshot window and self-corrects within milliseconds.

```bash
sudo ethtool -S enp5s0 | awk '
  /tx_received/      {tr=$2}
  /tx_consumed/      {tc=$2}
  /tx_busy_exception/ {tb=$2}
  /tx_dropped_error/ {td=$2}
  END { gap = tr - tc - tb - td; print "gap=" gap }
'
```

If `gap < 0`, something is double-counting on the consumed/busy/error
side. Capture the full snapshot and file a bug.

## Phase 1 — Probe-time failures (driver never becomes usable)

These prevent the network interface from appearing at all.

| dmesg pattern | Class | Likely cause | Action |
|---|---|---|---|
| `r8125_rust: pci_enable_device failed: -ENOMEM` | PCI enable OOM | low memory at boot | Reboot; if persistent, lower other memory-hungry boot consumers |
| `r8125_rust: BAR mapping failed: -EBUSY` | BAR busy | another driver bound to the chip (likely `r8169`) | `echo 0000:05:00.0 > /sys/bus/pci/devices/0000:05:00.0/driver/unbind` then `modprobe r8169 -r` then reload `r8125_rust` |
| `r8125_rust: alloc_irq_vectors returned -ENOSPC` | IRQ alloc fail | system MSI-X exhaustion (rare); falls back to INTx automatically | Look for prior `mode=Intx, forced by fallback` line below — driver should still work, just slower |
| `r8125_rust: mdiobus_register failed: -ENODEV` | MDIO bus init | chip didn't ACK reset | `lspci -vv` confirms chip is alive at all; if dead, hardware fault |
| `r8125_rust: no PHY device found at MDIO addr 0` | PHY not present | chip reset incomplete OR genuinely dead PHY | Cold-boot the box. If persistent, hardware fault |
| `r8125_rust: no PHY driver bound for phy_id 0x<id>` | PHY ID unknown | new chip stepping not in our `ChipInfo` table | File a bug with the phy_id; the chip may be 8125C / 8126 |
| `BUG: TASK stack guard page was hit` in `probe_callback` | Probe stack overflow | should be fixed in commit 8d30e0f (`KBox::init`) — if you see it, you're on an older build | Update driver |
| `r8125_rust ndo_open complete:` does NOT appear after insmod | Probe succeeded, but no one opened the device | Network management (netplan/NM/networkd) not bringing the iface up | `sudo ip link set enp5s0 up` |

## Phase 2 — Open-time failures (`ndo_open` rolls back)

The device probed fine but can't bring the link up.

| dmesg pattern | Class | Likely cause | Action |
|---|---|---|---|
| `r8125_rust: rx_alloc_jumbo failed at slot N` | RX pool partial OOM | low memory at open; less than 4 MiB contiguous available for the 256-slot pool | Restart bridge / NM and let it retry; if persistent, lower jumbo MTU or check huge-page reservations |
| `r8125_rust: request_irq returned -EBUSY` | IRQ already taken | should not happen with MSI-X (per-device) — but INTx fallback can hit | Look at `/proc/interrupts` — is another device sharing IRQ 21? |
| `r8125_rust: hw_start_8125b returned -ETIMEDOUT` | Chip reset timeout | chip didn't drop the CmdReset bit | Cold boot. If persistent, the chip-side ASPM-off path may not be running — verify probe-time logs show `force_aspm=0` (default), and as a temporary workaround try `intx_only=1` |
| `r8125_rust: PHY reset/resume failed: -ETIMEDOUT` | PHY didn't reset | typical: chip's PHY firmware not loaded by BIOS | Check BIOS update; some MS-A2 firmwares ship without the PHY EEPROM blob |
| `r8125_rust ndo_open complete:` appears, but `Link is Down` persists | Open succeeded, link won't negotiate | cable, peer config, EEE mismatch, MTU mismatch | Verify peer MTU matches; run `sudo ethtool enp5s0` — confirm "Speed: 2500Mb/s" not "Unknown!" |

## Phase 3 — Runtime failures (driver running, traffic degraded)

This is where most ops investigation happens. Counters tell the
story.

### 3a. TX-side classes

| Symptom | §6.3 counter behavior | Class | Action |
|---|---|---|---|
| Application sees write-blocking on socket | `tx_busy_exception` rising | TX ring exhaust — kernel was told to back off | Verify peer is consuming traffic; if peer is slow, this is expected. Check `tx-queue-len` (`ip link show enp5s0`) — may benefit from a higher value |
| Application sees `ENOBUFS` or `EAGAIN` on sendto() | `tx_dropped_error` rising fast | DMA map fail OR offload setup fail | `dmesg --since "1 min ago" | grep r8125_rust` for the failure reason; often points to checksum-help failure at MTU > 1500 with TSO on (re-check `ethtool -k enp5s0`) |
| Throughput drops at MTU 9000 specifically | `tx_received` flat, `tx_consumed` flat, no error | Offload-MTU mismatch — TSO didn't drop | Verify `ethtool -k enp5s0 | grep -E 'tcp-segmentation|tx-checksum'` shows `off` at MTU 9000 — if on, `ndo_fix_features` isn't firing |
| Sustained `xmit_calls` rising but `tx_received` flat | counter mismatch | The bridge is dropping skbs before the Rust xmit counter increments — likely a stop_queue race | File a bug with `ethtool -S` snapshot pre/post 1 GB transfer |

### 3b. RX-side classes

| Symptom | §6.3 counter behavior | Class | Action |
|---|---|---|---|
| Application sees zero received packets | `rx_handed_to_stack` rising; application OK | Filter / iptables / namespace issue — driver is working | `tcpdump -i enp5s0 -n -c 5` confirms packets reach the iface; iptables / nftables / firewalld is dropping them |
| Application sees zero, `rx_handed_to_stack` flat too | RX pool exhaust OR IRQ dead | Check `cat /proc/interrupts \| grep r8125_rust` — count should rise with traffic. If 0, IRQ delivery dead. If rising, RX pool exhaust (look for `rx_alloc_jumbo failed` in dmesg) |
| `rx_dropped_error` rising | RX descriptor error bit set by chip | Cable, link partner, or transient bit errors at high rate — verify with `ethtool -S | grep -E 'rx_(crc|frame|missed)_errors'` |
| Throughput < line rate, RX side, no drops | RX path underrun — NAPI re-polled but didn't fill ring | Check CPU utilization (`mpstat -P ALL 1`); softirq for IRQ 62's CPU saturated? Pin IRQ affinity if so |

### 3c. IRQ delivery classes

| Symptom | `/proc/interrupts` r8125_rust count | Class | Action |
|---|---|---|---|
| `tx_received` rising, IRQ count flat at 0 | 0 across all CPUs | MSI-X not delivering — chip-side INT_CFG0 not activated | Verify `dmesg | grep "mode="` shows `mode=Msi`; if `mode=Intx, forced by intx_only`, you set the rollback param. If `mode=Msi`, this is the M6 #1 V2/legacy mix-up bug — file a bug |
| IRQ count rising on CPU 0 but `ethtool -S` flat | rising | IRQs reaching CPU but Rust handler not making progress | Watchdog: `sudo ethtool -S | grep napi_polls` — if rising, NAPI is running but RX is empty. If flat, ISR pattern bug — file a bug |
| IRQ count rising but uneven across CPUs | rising on subset | irqbalance moved the vector | OK — IRQ affinity follows irqbalance unless you pinned it |

### 3d. Link flap

| Symptom | dmesg pattern | Action |
|---|---|---|
| `Link is Down` followed by `Link is Up` within seconds | normal cable / peer transient | No action |
| `Link is Down` persistent | cable cut, peer powered off, EEE misnegotiation | Verify cable physically. Check peer `ethtool` shows the link too. Some 2.5GbE peers misnegotiate when one side is RTL — disable EEE on both sides as a workaround |
| `Link is Up - 1000Mb/s` instead of 2500 | speed downgrade negotiation | Cable too long or cable category too low (Cat5 instead of Cat6); EEE downgrade |

### 3e. ASPM L1.x lockup (historical hazard)

| Symptom | What you see | Action |
|---|---|---|
| Driver enters idle, then 30+ seconds of zero traffic, then `BUG`/`WARN` | dmesg shows the lockup at some chip register access | This is the historical RTL8125 L1.x bug. Reload with `aspm_force_off=1` for immediate relief. Capture full state via `scripts/dump_state.sh` and file a bug — we want to know which firmware stepping is regressing |
| Throughput sustained but ping latency periodically spikes to ~5 ms | LnkCtl ASPM bit on, L1 entry/exit during idle gaps | Expected behavior — not a bug. If unacceptable for latency-critical workload, set `aspm_force_off=1` |

## Phase 4 — Teardown failures

| Symptom | dmesg pattern | Class | Action |
|---|---|---|---|
| `rmmod` hangs indefinitely | Last line is `r8125_rust ndo_stop: xmit_calls=...` with no follow-up | Pre-#58 driver — BAR-UAF or stack overflow | Hard reboot. Update to commit 8d30e0f or later |
| `rmmod` succeeds; later `insmod` fails | `pci_enable_device returned -EBUSY` | Stale PCI binding from a previous driver | `echo 0000:05:00.0 > /sys/bus/pci/devices/0000:05:00.0/driver/unbind` before `insmod` |
| `WARN_ON` from `dma-debug` at unbind | `DMA-API: Cannot find` or similar | DMA map/unmap mismatch — a real bug | Capture WARN trace + ethtool snapshot + file a bug |
| Kernel `BUG` at unbind | unspecified | UAF from one of the pre-#58 fixes regressing | Hard reboot, capture kdump, file a bug, regression-bisect |

## Counter behavior under specific stress patterns

These are the "good signs that things are working" patterns. If
you see different behavior, the driver is doing something
unexpected.

| Workload | Expected counter pattern |
|---|---|
| Idle (no traffic) | All counters flat; IRQ count slowly rising due to broadcast/multicast wake-ups |
| Sustained TCP at line rate, MTU 1500 | tx_received ≈ tx_consumed (gap < ring depth always); IRQ count ~5-8% of tx_received |
| Sustained TCP at line rate, MTU 9000 | Same shape, but rx_handed_to_stack ≈ tx_received / 6 (super-skb fan-out) |
| iperf3 reconnect storm | tx_dropped_error briefly spikes (the failing-skb path is correct) then settles to zero |
| Link toggled mid-flow | tx_dropped_error rises by the in-flight count at toggle moment; returns to flat after recovery |
| `rmmod` under active traffic | ndo_stop line appears once; final counter snapshot accessible via dmesg; no `BUG`/`WARN` |

## Quick rollback knobs

When something goes wrong in the field and you need to keep
working while we debug:

```bash
# Disable MSI-X — fall back to legacy INTx (M6 #1 rollback, full effect)
sudo modprobe r8125_rust intx_only=1

# Acknowledge ASPM force-off intent in dmesg (Tier 3c, log-only today)
# Chip-side ASPM is already disabled by default (force_aspm=0). The
# aspm_force_off=1 knob reserves the operator-visible name and logs
# "aspm_force_off=1 acknowledged" so the operator can confirm intent
# reached the driver. The host-side `pci_disable_link_state` call
# lands when the kernel-Rust binding exists; until then, this param
# does NOT change chip behavior beyond the default.
sudo modprobe r8125_rust aspm_force_off=1

# If you actually need ASPM-on (for soak testing, NOT production):
sudo modprobe r8125_rust force_aspm=1

# Both rollbacks together
sudo modprobe r8125_rust intx_only=1 aspm_force_off=1
```

After rollback works, **file a bug with the full state snapshot**
so we know what to fix. The rollback knobs are escape hatches,
not the long-term answer.

## Reporting a bug

When you hit something not in this taxonomy:

1. `scripts/dump_state.sh > /tmp/r8125_state.log` (after Tier 3a
   ships; until then collect the cheat-sheet commands manually).
2. `sudo dmesg --since "1 hour ago" | grep -E 'r8125_rust|enp|BUG|WARN' > /tmp/r8125_dmesg.log`
3. If a kernel `BUG` fired, capture `kdump` per `docs/GATEWAY_SETUP.md`.
4. File with both logs, the kernel version (`uname -r`), the
   chip stepping (`lspci -vv | grep -E 'XID|Rev'`), and what
   traffic pattern triggered it.

## Cross-references

- [`POST_SOAK_PLAN.md`](POST_SOAK_PLAN.md) — Tier 3 of which this
  is an item
- [`PATTERNS.md`](PATTERNS.md) #12 module-param rollback knobs +
  #13 soak harness + #4 §6.3 invariant
- [`CSHIM_KERNEL_DIFF.md`](CSHIM_KERNEL_DIFF.md) — kernel-C
  vs cshim contract that the failure modes here encode
- [`RTL8125_Rust_Driver_Implementation_Plan.md`](RTL8125_Rust_Driver_Implementation_Plan.md) §6.3
  the disposition-counter contract
