# KVM UDP TX characterization — r8169 reference — 2026-06-05

## Environment

- Host: Controller, peer `enp4s0` at `10.0.0.1`
- Guest: `rtl8125-guest`, kernel `7.0.0`, clocksource `kvm-clock`
- Device: RTL8125B VFIO passthrough at guest `0000:05:00.0`, iface `enp5s0`
- Driver under test for this note: in-tree `r8169`
- iperf3: 3.20, guest -> host UDP, MTU 1500, payload `-l 1448`

## Finding

The KVM/debug guest's single-stream UDP sender is the bottleneck, not the
driver. With one iperf3 UDP stream, r8169 either tops out well below line rate
or collapses when the offered rate is too high:

| Shape | Result |
|---|---:|
| `-b 100M` | 99.98 Mbps, 0% loss |
| `-b 500M` | 499.85 Mbps, 0% loss |
| `-b 1G` | 582.18 Mbps, 0% loss |
| `-b 3G` | 253.17 Mbps, 0% loss |

Parallel UDP streams remove that userspace pacing ceiling and show that the C
driver path can transmit near line rate inside the same KVM guest:

| Shape | Result |
|---|---:|
| `-b 1G -P 2` | 1.17 Gbps, 0% loss |
| `-b 1G -P 4` | 1.89 Gbps, 0.003% loss |
| `-b 250M -P 10` | 2.36 Gbps, 0% loss |

The same corrected shape also works with `r8125_rust` in the KVM guest:

| Driver | Shape | Result |
|---|---|---:|
| `r8169` | `-u -l 1448 -b 250M -P 10` | 2.36 Gbps, 0% loss |
| `r8125_rust` | `-u -l 1448 -b 250M -P 10` | 2.35 Gbps, 0% loss |

## Harness Fix

`scripts/perf_characterize.sh` now defaults the KVM-sensitive UDP guest->host
MTU-1500 case to `10x250M` (`UDP_G2H_1500_STREAMS=10`,
`UDP_G2H_1500_BITRATE=250M`). Set `UDP_G2H_1500_STREAMS=1
UDP_G2H_1500_BITRATE=3G` only when intentionally measuring the single-stream
iperf3 ceiling.

This keeps KVM useful for driver comparison without mistaking iperf3 pacing
collapse for a Realtek TX failure.
