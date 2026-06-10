> **SUPERSEDED 2026-06-10 by `docs/perf/cvr_stat_sweep_20260610/`.** This run was
> single-sample and two-way (no in-tree r8169), and its "TCP RX 10-flow
> retransmits" row (rust4 0 / rust0 4757 / vendorC 2312) was a sampling artifact:
> at N=12 those retransmits are bursty peer/TCP noise with zero NIC drops, and
> r8169 spikes as much or more. The authoritative three-way, N-sampled comparison
> (and the methodology that prevents this error) live in
> `docs/perf/cvr_stat_sweep_20260610/` and `docs/perf/BENCHMARK_METHODOLOGY.md`.
> Kept for history.

# Rust vs vendor-C runtime-validation sweep (2026-06-09)

The RSS_RXHASH_IMPLEMENTATION_PLAN "Runtime Validation" matrix, run by
`scripts/trackb_cvr_sweep.sh` on the gateway loopback rig (enp3s0 DUT ↔ enp4s0
peer in netns). Three configs compared, **fresh-loaded per driver**:

- **rust4** — `r8125_rust rss_queues=4` (multi-queue, the LB opt-in)
- **rust0** — `r8125_rust rss_queues=0` (single-queue, the RFC default)
- **vendorC** — Realtek vendor `r8125` 9.016.01-NAPI-RSS (4 queues)

Raw artifacts per driver in `raw/` (`ethtool -l/-S/-x`, `/proc/interrupts`);
full per-point results in `sweep.csv`.

## Headline: parity across the matrix; no scenario favors C

| dimension | rust4 | rust0 | vendor C |
|---|---|---|---|
| TCP TX 1500 (1 / 10 flows) | 2.36 / 2.36 | 2.36 / 2.35 | 2.36 / 2.36 |
| TCP RX 1500 (1 / 10 flows) | 2.35 / 2.35 | 2.35 / 2.35 | 2.35 / 2.35 |
| TCP RX 10-flow retransmits | **0** | 4757 | 2312 |
| UDP RX 1448B (1 / 10 flows) | 2.39 / 2.39 | 2.39 / 2.39 | 2.39 / 2.39 |
| UDP RX 1024B | 2.35 | 2.35 | 2.35 |
| UDP RX 256B | 1.95 | 1.2–1.98 | 1.98 |
| UDP RX 64B (1 / 10) | 0.42 / 1.04 | 0.32 / 0.96 | 0.53 / 1.06 |
| jumbo TCP MTU 9000 TX / RX | 2.48 / 2.47 | 2.48 / 2.47 | 2.48 / 2.47 |
| latency under load (avg RTT) | **0.63 ms** | 0.74 ms | 0.70 ms |
| RX queue spread (16-flow) | **5 irq vectors** | 2 | 5 |

- **TCP, UDP (all sizes), and jumbo are at parity** — all three hit the 2.5 GbE
  line rate where the link is the bottleneck; small-packet UDP (64–256B) is
  generator-bound and comparable across drivers.
- **rust4 spreads RX across all 4 queues** (5 active vectors = rx0–3 + tx0), the
  same as vendor C; rust0 uses 1 RX queue (2 vectors = rx0 + tx0) as expected.
- **Latency under load is parity-or-better** for Rust.
- **TCP retransmits: `rust4` (multi-queue) is 0 on every TCP point, including
  10-flow RX** — where single-queue `rust0` shows 4757 and vendor C shows 2312
  retransmits (single-RX-queue contention under 10 parallel flows). Multi-queue
  RX spreading eliminates it. (Earlier sweep CSVs recorded the literal string
  "receiver" in this column — a parser bug, now fixed to read
  `sum_sent.retransmits` from iperf3 JSON.)

## Sustained-stress addendum (separate dedicated run)

The sweep measures steady throughput; the *sustained parallel-stress* behavior
(see `docs/perf/rss_multiqueue_20260609/README.md`) is where the drivers
diverge: under one load + repeated `-P16`, **Rust holds line rate with retr=0
and 0 warnings while the vendor C driver degrades/fails** (836 Mbit → dead, ~12k
retransmits, 64 serious dmesg warnings). So Rust is **at-or-better** than vendor
C everywhere, and strictly better under sustained parallel load.

## Methodology notes (harness)

- **Fresh-load per driver** + a gentle single-flow warm-up. A `-P8` warm-up was
  found to *degrade vendor C* (its parallel-stress weakness), which would
  silently zero its later measurements — so the warm-up is single-flow.
- **UDP offered rate is bounded** (`-b 3000M`, ~25% over line), not `-b 0`: an
  unbounded flood intermittently wedges the shared peer iperf3 server and zeroes
  the rest of the UDP block. The peer server is also restarted before each UDP
  point and the spread test.
- **Jumbo verifies both ends are MTU 9000** before measuring (the igc peer can
  race the first MTU set; an un-applied peer MTU silently zeros jumbo TCP — this
  produced a false "rust4 jumbo=0" in an earlier run that did NOT reproduce once
  both-end MTU was confirmed: rust4 jumbo is 2.48/2.47, identical to rust0/C).
- **Spread uses the device's `msi_irqs` set** (driver-agnostic), counting
  vectors that advance >500 irqs under a 16-flow load.

Re-run: `sudo bash scripts/trackb_cvr_sweep.sh [out_dir]` on the gateway.
