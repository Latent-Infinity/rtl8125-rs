# Gateway baseline — pre-M6 reference

**Captured 2026-05-28** before any M6 implementation work starts.
This is the floor M6 features must equal or exceed.

## Environment

| Item | Value |
|---|---|
| Box | Minisforum MS-A2 — "Gateway" (bare metal) |
| CPU | AMD Ryzen 9 9955HX (Zen 5, 16C/32T) |
| Distro | Ubuntu 26.04 LTS |
| Kernel | `7.0.0-15-generic` (stock distro, `CONFIG_RUST=y`, **no KASAN/lockdep/kmemleak**) |
| Driver | `r8125_rust` built from commit @ 2026-05-28 (M5 close-out state — TSO + SG + HW CSUM, NAPI hysteresis, percpu §6.3 counters) |
| Driver MSI mode | legacy INTx (IRQ 46) |
| Chip | Realtek RTL8125B, XID 0x641, rev 0x05 |
| Topology | netns-isolated same-machine cross-cable: `enp3s0` (RTL8125B) ↔ `enp4s0` (I226-V, peer netns) |
| Link | 2.5 Gbps, full-duplex, flow control rx/tx, Cat6 ~30 cm |
| Other offload | TSO/TSO6 on (max_segs=10, max_size=64000); SG on; CSUM on |
| ASPM state | **L1 enabled** on both bridge (`00:03.1`) and endpoint (`03:00.0`) — verified post-BIOS update |

## lspci ASPM snapshot

```
endpoint 03:00.0:
  LnkCap:  Port #0, Speed 5GT/s, Width x1, ASPM L0s L1, Exit Latency L0s unlimited, L1 <64us
  LnkCtl:  ASPM L1 Enabled; RCB 64 bytes, LnkDisable- CommClk+
  LnkSta:  Speed 5GT/s, Width x1
  L1SubCap: PCI-PM_L1.2+ PCI-PM_L1.1+ ASPM_L1.2+ ASPM_L1.1+ L1_PM_Substates+

bridge 00:03.1:
  LnkCap:  Port #4, Speed 32GT/s, Width x1, ASPM L1, Exit Latency L1 <64us
  LnkCtl:  ASPM L1 Enabled; RCB 64 bytes, LnkDisable- CommClk+
```

## Throughput (single-stream TCP, MTU 1500)

| Direction | Throughput | Retransmits | Run length |
|---|---:|---:|---:|
| g→g (rtl8125 driver → I226-V peer, **outbound TSO**) | **2.36 Gbits/sec** | 0 | 10 s |
| g→g reverse (peer → driver, RX path) | (not yet measured — pending) | — | — |

**Reference for context**: r8169 mainline reference on the same chip
under Controller-KVM: 2.33 Gbps. Gateway's 2.36 is slightly higher
because no KASAN debug overhead.

## §6.3 counter-invariant correctness

Across a 1 GB transfer:

| Counter | Delta |
|---|---:|
| `tx_received` | 74 179 |
| `tx_consumed` | 74 179 |
| `tx_busy_exception` | 0 |
| `tx_dropped_error` | 0 |
| `rx_handed_to_stack` | 30 242 |
| `rx_dropped_error` | 0 |
| **Invariant gap** | **0** ✓ |

## Pending measurements (will fill in as M6 lands)

These are placeholder rows for the M6 `*_before_after.md` to copy:

| Metric | Pre-M6 (this file) | Plan |
|---|---:|---|
| Median throughput (Gbps) | 2.36 (TX) | re-measure under each M6 sub-feature |
| p99 latency (ms) under 100 Mbps load | TBD | capture before any M6 changes for valid Δ |
| CPU per Gbps (% sys+soft) | TBD | run with `mpstat -P ALL` parallel to iperf3 |
| Small-packet rate (kpps, UDP 64 B) | TBD | `iperf3 -u -l 64 -b 1G` |

## Notes / caveats

1. **Stock kernel — no KASAN/lockdep/kmemleak.** Performance is honest; correctness coverage is reduced. The §6.3 invariant runtime gate still verifies accounting correctness, but UAF-class bugs that would `WARN` on the debug kernel could hang silently here (see task #58 — bare-metal rmmod-while-active-traffic hang).
2. **ASPM L1 is enabled** for this measurement window. Pre-M6 throughput at 2.36 Gbps under ASPM L1 is encouraging — it suggests L1 entry/exit isn't impacting single-stream throughput at this rate. If a later measurement shows degradation, suspect L1 first.
3. **The Controller-KVM iperf3 baseline (2.35 Gbps, 0 retransmits, 60 s sustained) and Gateway's 2.36 Gbps result are within noise.** This is good evidence that the KVM/VFIO/KASAN-debug environment isn't masking a bug that bare metal would expose at the TCP-throughput level (though it could still mask correctness bugs — see point 1).

## How to reproduce

```bash
ssh gateway 'bash -c "
    # Set up netns (idempotent)
    sudo nmcli dev set enp3s0 managed no
    sudo nmcli dev set enp4s0 managed no
    sudo ip netns del peer 2>/dev/null || true
    sudo ip netns add peer
    sudo ip link set enp4s0 netns peer
    sudo ip netns exec peer ip link set lo up
    sudo ip netns exec peer ip link set enp4s0 up
    sudo ip netns exec peer ip addr add 10.0.0.1/24 dev enp4s0
    sudo ip link set enp3s0 up
    sudo ip addr add 10.0.0.2/24 dev enp3s0
    sleep 5
    # Start iperf3 in peer netns, client in default
    sudo ip netns exec peer iperf3 -s -B 10.0.0.1 -D
    sleep 2
    iperf3 -c 10.0.0.1 -B 10.0.0.2 -t 10 -i 5
    sudo pkill iperf3
"'
```
