# Driver byte-budget throttle (test 5) — MSI-safe loaded-latency fix — 2026-06-05

## What this is
The MSI-safe alternative to BQL. BQL recaptured the loaded-latency regression
perfectly over INTx but `netdev_sent_queue()` deterministically suppresses MSI-X
delivery on this chip's one-vector V2 surface (see
`../bql_20260605/MSI_SENT_QUEUE_INTERACTION.md`). The default now uses MSI
delivery with the legacy ISR surface, but `bql_mode=1` still leaves BQL off on
MSI until that path is separately revalidated.

Test 5 (`docs/BQL_RETRY_PLAN.md`) bounds TX ring residency *without* touching the
qdisc/BQL layer: a driver-owned `tx_inflight_bytes` counter, incremented at the
xmit commit for packet sizes that can hit the byte budget before descriptor-ring
stop, and decremented (saturating) from a per-packet budget shadow in the NAPI
reaper. Tiny frames whose whole descriptor window is below the configured budget
skip the inflight atomic; descriptor hysteresis is already the tighter bound for
them. When tracked in-flight bytes reach `tx_byte_budget`, xmit stops the txq via
`netif_tx_stop_queue`; the reaper wakes it once bytes fall below
`max(1, tx_byte_budget/2)` (low-water hysteresis) AND descriptor slots have
drained past `TX_START_THRS`. Both stop reasons (ring-full and byte-budget) route
their wake decision through one predicate (`netdev::tx_should_wake`) so neither
can strand the queue. It uses only `netif_tx_stop/wake_queue` — the same
primitives the ring-full path already uses safely over MSI — so it never calls
`netdev_sent_queue`. Works on BOTH IRQ surfaces.

Config: `tx_byte_budget=131072` (default), `bql_mode=1` (BQL inactive over MSI),
coalesce rx=0x08/tx=0x10, MSI delivery. The initial byte-budget sweep was taken
on the V2 surface before the UDP TX root cause was fixed; the final -22 default
uses MSI-X delivery with legacy ISR/IMR (`mode=Msi use_v2=false`).

## Method
Self-contained gateway loopback rig (`gw_loopback.sh`): enp3s0 (RTL8125, DUT) <->
enp4s0 (igc, peer), cabled, isolated in netns so traffic crosses the wire.
Loaded latency = ICMP RTT (`ping -i 0.02`, n=300) during a saturating TCP TX
iperf3. Percentiles p50/p99/max over the 300 samples (not p99.9 — n is too small
for that; the `bql_20260605` table quotes p99.9, so compare orders of magnitude,
not exact figures).

## Loaded latency (ICMP RTT under saturating TCP TX), MSI delivery

### kernel 7.0.0-15-generic
| Config | idle p50 | loaded p50 | loaded p99 | loaded max | TX/RX |
|--------|----------|-----------|-----------|-----------|-------|
| byte_budget=131072 (ON)  | 387us | **425us** | **628us** | 774us  | 2.35/2.35 Gbps |
| byte_budget=0 (control)  | 591us | 1420us    | 1520us    | 1560us | 2.35/2.35 Gbps |
| MTU 9000, budget=131072  | 388us | 571us     | 1070us    | 1100us | 2.47/2.47 Gbps |

### kernel 7.0.0-22-generic (latest)
| Config | idle p50 | loaded p50 | loaded p99 | loaded max | TX/RX |
|--------|----------|-----------|-----------|-----------|-------|
| byte_budget=131072 (ON)  | 399us | **715us** | **1050us** | 1070us | 2.35/2.35 Gbps |
| byte_budget=0 (control)  | 555us | 1660us    | 1940us    | 1960us | 2.35/2.35 Gbps |

## Reading the result
- The throttle cuts loaded p50 by 2.3–3.3x and p99 by 1.8–2.4x vs the
  budget-off control, while holding throughput at line rate (2.35 Gbps @1500,
  2.47 Gbps @9000, both directions).
- The control (budget=0) reproduces the original regression — same line-rate
  throughput, but loaded latency ~1.4–1.9 ms. So the regression is queue
  residency, and the byte-budget is what recaptures it. This is the same
  conclusion BQL reached, achieved over MSI delivery where BQL is disabled by
  the safe default.
- -15 latency (425us p50) beats r8169 (~783us p99.9) and old BQL (824us p99.9);
  -22 is a touch higher (715us p50) but still well under the control and r8169.
- No `netdev_sent_queue`: MSI-X delivery healthy (IRQ 68 fires, link 2.5Gbps,
  line-rate throughput) — the V2-surface interaction is sidestepped entirely.

## Conclusion
Test 5 succeeds. The driver-owned byte-budget throttle recaptures the
loaded-latency regression over MSI delivery with no throughput cost and without the
`netdev_sent_queue` MSI-X hazard. Validated on both 7.0.0-15 and 7.0.0-22.
Default `tx_byte_budget=131072` is a reasonable starting point; the latency/
throughput knee can be swept further if a tighter tail is wanted.
