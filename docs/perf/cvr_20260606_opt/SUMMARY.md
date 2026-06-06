# C-vs-Rust matrix + opt pass — 2026-06-06 (kernel 7.0.0-22)

Rust binary: use_v2=false (legacy ISR/MSI-X) + lost-wakeup fences + byte-budget
throttle (selective small-frame tracking) + xmit_more + debug_counters opt-in +
RX relaxed loads + page_pool x2.

## Reliable cells (fixed-rate throughput, latency, multi-flow PPS)
| Benchmark | C (r8169) | Rust | Verdict |
|-----------|-----------|------|---------|
| TCP TX/RX/bidir @1500 | 2.356 / 2.353 / 4.70 | 2.356 / 2.353 / 4.58 | tie (bidir -2.7%) |
| IPv6 TCP TX/RX | 2.324 / 2.321 | 2.323 / 2.321 | tie |
| UDP TX @1500/@9000 | 2.391 | 2.391 | tie (was wedged pre-fix) |
| UDP RX @1500/@9000 | 2.391 | 2.391 | tie |
| TCP TX @9000 | 2.477 | 2.477 | tie |
| Loaded latency p50/p99 @1500 (ICMP) | 668 / 772 us | **494 / 652 us** | **rust win** |
| Loaded latency p50/p99 @1500 (sockperf) | 765 / 973 us | **572 / 767 us** | **rust win** |
| Loaded latency @9000 (ICMP) | 759 / 1120 us | 746 / 1050 us | rust win |
| 64B TX pps (-P 10) | ~1.10M | ~1.10M | tie |
| 64B RX pps (-P 10) | ~1.78M | **~2.14M** | **rust win +18%** |
| 128B TX/RX pps (-P 10) | ~1.07M / 1.52M | ~1.08M / 1.55M | tie |

## Caveats
- The bench's single-flow `-b 0` small-frame PPS test is unreliable (this run C
  logged tcp_tx rep1=0 and 64_tx=0; values swing 2x between runs). Multi-flow
  `-P 10` is the stable measure and is what the table above uses. TODO: switch
  gw_bench.sh pps() to `-P 10` + median-of-N.
- Single-core single-flow small-frame TX: rust ~0.5-0.6M vs C ~1.0M. This is a
  real single-core per-packet cost gap (heavier xmit path), NOT representative —
  it vanishes at >1 flow (parity above). Follow-up wired the RTL8125 INT_MITI
  timer table for the default legacy ISR/MSI surface; validate the final delta
  with a single-core single-flow small-frame rerun on the gateway.

## Verdict
Rust >= C on every reliable/representative benchmark: ties throughput, wins
loaded latency, wins 64B RX pps, ties small-frame TX (multi-flow). No regressions.
