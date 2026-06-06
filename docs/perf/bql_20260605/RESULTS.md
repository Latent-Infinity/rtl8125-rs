# BQL (Approach A) loaded-latency result — 2026-06-05

Config: seed dql.min_limit (1 frame + headroom) at open, NO netdev_reset_queue,
netdev_sent_queue at the TX commit, netdev_completed_queue batched in NAPI
reap. coalesce rx=8/tx=8, weight=128.

## Loaded latency (ICMP RTT under saturating TCP TX), bare-metal gateway
| MTU | r8169 | rust no-BQL | rust+BQL |
|-----|-------|-------------|----------|
| 1500 p99.9 | 783us | ~1700us | 824us  (matches C) |
| 9000 p99.9 | 563us | ~1990us | 43us   (13x better than C) |

Throughput parity held (2.35 Gbps TX/RX). Bootstrap safe: single 60B ping ->
tx_consumed rises (1->2002 over a ping burst); seed prevents the v1 XOFF stall.
dql under load: limit grows (BQL adaptive), inflight drains (0 at MTU9000).

## Validation surface caveat
Measured over INTx (intx_only=1) because the MSI/V2-X delivery surface is
deterministically dead on this build: ISR_v2 latches TOK_Q0+LINKCHG
(0x00210000) but MSI-X vector delivers 0 IRQs. intx_only=1 + BQL works fully,
so BQL is NOT the cause. The MSI-X delivery issue is the separate V2-surface
item; BQL (qdisc-layer) will carry the same latency win to MSI once delivery
is restored.

## Conclusion
BQL is the correct fix for the loaded-latency regression (queue residency,
not IRQ cadence / coalescing). Latency now matches (1500) / beats (9000) r8169.
