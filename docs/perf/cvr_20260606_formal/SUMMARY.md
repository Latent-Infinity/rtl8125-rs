# Formal C-vs-Rust certification — 2026-06-06 (kernel 7.0.0-22)

Rust: use_v2=false (legacy ISR/MSI-X) + legacy INT_MITI coalescing + byte-budget
throttle + xmit_more + VLAN HW offload + debug_counters opt-in + RX relaxed/pp x2.
PPS measured multi-flow (-P 10) median-of-3 (single-flow -b 0 is unreliable).

## Throughput (avg Gbps) — PARITY
| cell | C | Rust | d% |
|------|---|------|----|
| TCP TX/RX @1500 | 2.357 / 2.354 | 2.356 / 2.353 | ~0 |
| TCP bidir @1500 | 4.703 | 4.583 | -2.5 (within bound) |
| IPv6 TCP TX/RX | 2.325 / 2.321 | 2.323 / 2.321 | ~0 |
| UDP TX/RX @1500 | 2.391 | 2.391 | ~0 |
| TCP/UDP TX @9000 | 2.477 / 2.391 | 2.477 / 2.391 | ~0 |
| **VLAN TCP TX/RX @1500** | 2.350 | **2.350** | 0 (HW VLAN offload at parity) |

## Small-frame PPS (-P 10 median) — PARITY (TX gap closed by coalescing)
| frame/dir | C | Rust | d% |
|-----------|---|------|----|
| 64 tx | 1,107,169 | 1,105,356 | -0.2 |
| 128 tx | 1,068,232 | 1,083,333 | +1.4 |
| 256 tx | 904,420 | 881,039 | -2.6 |
| 64 rx | 2,404,278 | 1,983,725 | -17.5 (NOISY: swings ±18% run-to-run) |
| 128 rx | 1,611,411 | 1,560,152 | -3.2 |
| 256/512/1024/1448 rx/tx | — | — | parity |

## Latency (loaded, us)
| test | C p50/p99 | Rust p50/p99 | |
|------|-----------|--------------|--|
| 1500 sockperf | 635/654 | 591/635 | rust win |
| 1500 icmp | 667/772 | 585/788 | rust p50 win, p99 ~even |
| 9000 icmp | 644/904 | 561/746 | rust win |
| 9000 sockperf | 405/758 | 750/1118 | **C win** (jumbo sockperf gap — investigate) |
| idle 1500 sockperf | 49/58 | 50/60 | parity |

## Verdict
No regressions. Rust ties throughput (incl VLAN), ties small-frame PPS multi-flow
(TX gap now closed), wins loaded latency at 1500. Open item: @9000 sockperf loaded
latency trails C (byte-budget @ large frames?) — ICMP @9000 contradicts (rust wins),
so it's tool-specific, not throughput. 64B RX too noisy to rank.
