# Perf characterization run — 20260529_225241

- Iface: enp5s0  (10.0.0.2/24 → 10.0.0.1:5500)
- iperf3 duration: 10s per direction
- Driver: r8125_rust (commit )
- Kernel: 7.0.0


## 2a — Bidirectional saturation @ MTU 1500

| Direction | Throughput (Gbps) | Retransmits |
|---|---:|---:|
| guest → host | 2.353 | 0 |
| host → guest | 0.000 | 0 |


## 2a — Bidirectional saturation @ MTU 9000

| Direction | Throughput (Gbps) | Retransmits |
|---|---:|---:|
| guest → host | 2.473 | 0 |
| host → guest | 0.000 | 0 |


## 2b — p99 latency under 100 Mbps load

- Ping: 1000 × ICMP, 0.05s spacing, in parallel with 100 Mbps iperf3 TCP
- RTT (min/avg/max/mdev ms): `rtt min/avg/max/mdev = 0.093/0.212/1.351/0.097 ms`
- Approx p99 proxy (max): 0.097 ms ms  *(true p99 needs sort; see raw file)*
- Loss: 0% packet loss


## 2c — Small-packet pps (UDP 64B, 1 Gbps offered)

- Achieved: 0.000 Gbps
- Estimated pps: 22
- Loss: 0 %


## 2d — Fresh capture matrix

| Proto | Dir | MTU | Throughput | Retr / Loss |
|---|---|---:|---:|---:|
| TCP | g2h | 1500 | 2.353 Gbps | 0 retr |
| TCP | h2g | 1500 | 1.203 Gbps | 0 retr |
| UDP | g2h | 1500 | 0.000 Gbps | 0 % loss |
| UDP | h2g | 1500 | 1.302 Gbps | 0.23360485202512249 % loss |
| TCP | g2h | 9000 | 2.474 Gbps | 0 retr |
| TCP | h2g | 9000 | 2.466 Gbps | 0 retr |
| UDP | g2h | 9000 | 0.000 Gbps | 0 % loss |
| UDP | h2g | 9000 | 2.174 Gbps | 4.985568338529565 % loss |

## Next steps

1. Paste the 2d table rows into `docs/perf/r8169_comparison.md`
   under §"TCP, single stream" + §"UDP, single stream" to close
   the *pending* lines.
2. Paste the 2a + 2b + 2c sections into a new §"Tier 2 expanded
   capture" of `r8169_comparison.md`.
3. Compare bidirectional rates against the unidirectional baseline
   to detect TX/RX arbitration anomalies.
4. Archive this directory (/home/firestrand/rtl8125-rs/docs/perf/captures/20260529_225241) for later comparison.
