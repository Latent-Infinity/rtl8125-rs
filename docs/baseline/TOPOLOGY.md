# RTL8125 physical test topology (plan §7 M0b)

Captured 2026-05-25 on the validated MS-A2 (`ms-a2-controller`).

## Cabling

**Direct cable between two ports on the same MS-A2 chassis**, no switch:

    host I226-V (enp4s0, 0000:04:00.0)
            │
            │   one Cat6/6a Ethernet cable
            │
    host RTL8125 (0000:03:00.0) ─→ VFIO passthrough ─→ guest enp5s0 (0000:05:00.0)

The host's I226-V (`enp4s0`) IS the peer for the guest's RTL8125. Because
both NICs sit on the same physical chassis, the link partner of each is
unambiguous and there is no intermediate switch / DHCP server / mDNS
participant. L2 isolation (plan §8.1.6) is satisfied by construction —
host management is on Wi-Fi (`wlp6s0`, 192.168.68.x) and the 10.0.0.0/24
test subnet on enp4s0/enp5s0 is private to this loop.

## IP plan

- Host  `enp4s0` : **10.0.0.1/24** (static, runtime `ip addr add`).
- Guest `enp5s0` : **10.0.0.2/24** (static, runtime `ip addr add`).
- No gateway; same subnet, direct delivery.
- No DHCP server. M4 DHCP-lease test will run dnsmasq on enp4s0 when needed.

## Peer (host I226-V `enp4s0`)

| Field | Value |
|---|---|
| NIC model         | Intel I226-V (PCI ID `0000:04:00.0`) |
| OS / kernel       | Ubuntu 26.04 host, stock `7.0.0-15-generic` |
| Driver            | `igc`, version `7.0.0-15-generic`, firmware `2017:888d` |
| MAC               | `38:05:25:36:a6:32` |
| Negotiated link   | **2500 Mb/s Full-Duplex**, flow-control RX/TX (autoneg) |
| Port type         | Twisted Pair (RJ45) |
| EEE (802.3az)     | **disabled** locally; remote (RTL8125) advertises 100/1000/2500-baseT EEE |
| MTU (baselines)   | tested at 1500 and 9000 |

## DUT (guest RTL8125B `enp5s0`)

| Field | Value |
|---|---|
| NIC model         | Realtek RTL8125B (XID `0x641`, rev `0x05`) |
| Guest PCI addr    | `0000:05:00.0` (passed through from host `0000:03:00.0` via VFIO) |
| Guest OS / kernel | Ubuntu 26.04 guest, custom debug+Rust `7.0.0 #2` (KASAN, lockdep, kmemleak, DMA_API_DEBUG, CONFIG_RUST) |
| Driver (baseline) | `r8169`, version `7.0.0`, firmware `rtl8125b-2_0.0.2 07/13/20` |
| MAC               | `38:05:25:36:a6:31` |
| Negotiated link   | **2500 Mb/s Full-Duplex**, EEE enabled-but-inactive, no pause-frame negotiation |
| MTU (baselines)   | tested at 1500 and 9000 |

## L2 isolation — plan §8.1.6 / M1 board row 10

- ✅ RTL8125 is NOT on the host's mgmt / k8s domain (mgmt = Wi-Fi
  `wlp6s0` on 192.168.68.x; k3s uses `wlp6s0` exclusively).
- ✅ enp4s0 / enp5s0 are on a private `10.0.0.0/24` segment with no
  other participants.
- ✅ tcpdump on enp4s0 sees ONLY 10.0.0.x traffic (verified during
  baseline runs; no leaked main-LAN multicast).

## Peer-side packet capture — plan §7 M0b deliverable

Trivially satisfied: `tcpdump -i enp4s0` on the **host** sees every byte
the guest sends or receives. The reproducible capture procedure:

    # On host:
    sudo tcpdump -i enp4s0 -nn -s 96 -c 2000 \
        -w docs/baseline/iperf3/m0b_peer_capture.pcap \
        host 10.0.0.2 and tcp
    # Concurrently on host (or any source), run iperf3 client.
    iperf3 -c 10.0.0.2 -t 3 -i 0 -J > /tmp/iperf3_run.json

Captured evidence: `docs/baseline/iperf3/m0b_peer_capture.pcap` (193 KB,
2000 packets headers-only — full TCP 3-way handshake + TSO-segment data
visible with `tcpdump -nn -r`).

## r8169 iperf3 baselines — plan §7 M0b deliverable

10-second runs, default streams, captured to
`docs/baseline/iperf3/iperf3_r8169_<dir>_<proto>_<mtu>.json`.

| Test                                       | Tx Gb/s | Rx Gb/s | Notes |
|---|---:|---:|---|
| TCP 1500 MTU  host→guest (RTL8125 RX)      |   2.348 |   2.326 | 0 retrans |
| TCP 1500 MTU  guest→host (RTL8125 TX)      |   2.331 |   2.328 | 0 retrans |
| TCP 9000 MTU  host→guest                    |   2.475 |   2.473 | 0 retrans (TSO @ MSS 8960) |
| TCP 9000 MTU  guest→host                    |   2.377 |   2.374 | 0 retrans |
| UDP 1500 MTU  host→guest                    |   2.380 |   2.379 | 0 lost |
| UDP 1500 MTU  guest→host                    |   0.895 |   0.895 | 0 lost — **see note below** |
| UDP 9000 MTU  host→guest                    |   2.290 |   2.157 | ~6 % loss at the guest RX (KASAN/debug kernel can't keep up at ~31 K pps from line-rate I226-V) |
| UDP 9000 MTU  guest→host                    |   2.296 |   2.296 | 0 lost |

### Note on UDP 1500 guest→host asymmetry

At 1500-byte MTU, 2.5 Gb/s of UDP is ~215 K packets/sec; without TSO each
packet costs one `sendmsg()` syscall plus the KASAN-instrumented kernel
TX path on a 6-vCPU guest. Single core saturates around 77 K pps in this
environment, giving 0.895 Gb/s. This is a **debug-guest software**
bottleneck, NOT an RTL8125 limitation — TCP at the same MTU runs at
line-rate (2.33 Gb/s) because GSO/TSO amortizes the syscall cost. The
asymmetry is a real-and-recorded baseline of the test rig; it isn't a
target for the r8125_rust M4 work to "fix".

### Why UDP 9000 host→guest shows RX < Tx

I226-V transmits ~31 K pps of 9000-MTU UDP. Guest RX path under
KASAN drops a fraction because the receive-side socket buffer
backlogs faster than `recvmsg` drains. Same root cause (debug guest
overhead), same not-RTL8125-fault.

## Test rig CPU note

Iperf3 server/client run on the same physical CPU as the QEMU/KVM
process. With 16C/32T (Ryzen 9 9955HX) there is no contention at 2.5 Gb/s,
but anyone reproducing M0b should record their CPU count + governor
state. For these baselines: `performance` governor, no CPU pinning, no
NUMA tuning.

## Files

- `docs/baseline/TOPOLOGY.md` — this document.
- `docs/baseline/iperf3/iperf3_r8169_*.json` — raw iperf3 JSON for each test.
- `docs/baseline/iperf3/m0b_peer_capture.pcap` — peer-side TCP capture.
- `docs/baseline/iperf3/m0b_peer_capture_iperf3.json` — the iperf3 run that
  generated the captured traffic.
