# Three-way statistical sweep: Rust vs in-tree r8169 vs vendor r8125 (2026-06-10)

The authoritative driver comparison, run by `scripts/cvr_stat_sweep.sh` on the
gateway loopback rig (enp3s0 DUT ↔ enp4s0 peer, both physical ports, in netns).
Follows `docs/perf/BENCHMARK_METHODOLOGY.md`: **fresh-load per driver,
N samples/point (median+min+max), retransmits as a spike-rate, peer server
restarted per sample.** Supersedes the single-sample `cvr_sweep_20260609/`.

Four configs:
- **rust4** — `r8125_rust rss_queues=4` (multi-queue LB opt-in)
- **rust0** — `r8125_rust rss_queues=0` (single-queue RFC default)
- **r8169** — mainline in-tree driver (single-queue) — *the upstream baseline*
- **vendorC** — Realtek vendor `r8125` (RSS, 4 queues)

Raw `ethtool -l/-S/-x` + `/proc/interrupts` per driver in `raw/`; full per-point
median/min/max in `sweep.csv`.

## Headline: no clean driver metric favors C

| metric (lower=better where noted) | rust4 | rust0 | r8169 | vendorC | result |
|---|---|---|---|---|---|
| TCP TX 1500 1/10 flow (Gbit) | 2.36 | 2.36 | 2.36 | 2.36 | link-bound parity |
| TCP RX 1500 1/10 flow (Gbit) | 2.35 | 2.35 | 2.35 | 2.35 | link-bound parity |
| jumbo TCP MTU9000 TX/RX (Gbit) | 2.48/2.47 | 2.48/2.47 | 2.48/2.47 | 2.48/2.47 | link-bound parity |
| UDP RX 1448B 1/10 flow (Gbit) | 2.39 | 2.39 | 2.39 | 2.39 | parity (0% loss) |
| UDP RX 64B 10-flow (Gbit) | **1.00** | 0.95 | 0.74 | 1.00 | **Rust ≥ C** (r8169 worst) |
| latency under load (med ms) ↓ | **0.61** | **0.60** | 0.69 | 0.71 | **Rust wins both** |
| sustained −P16 ×6 retransmits ↓ | **0** | **0** | 44205 | 43662 | **Rust wins big** |
| sustained −P16 worst Gbit | 2.359 | 2.359 | 2.373 | 2.374 | parity¹ |
| TCP TX 10-flow retr spikes ↓ | 0/5 | 0/5 | 0/5 | 0/5 | parity (artifact fixed) |
| TCP RX 10-flow retr spikes ↓ | 5/12 | 2/12 | 3/12 | 3/12 | bursty noise² (not driver-attributable) |
| RX queue spread (16-flow) | 5 | 2 | 1 | 5 | rust4 = vendorC |

¹ The ~0.015 Gbit edge for the C drivers under stress is within run-to-run noise
and is **dirty throughput**: they sustain it while emitting ~44k retransmits,
where Rust sustains the same line rate at **retr=0**. Clean > dirty (rule 9).

² TCP retransmits are bursty peer/TCP artifacts: spikes hit every driver on a few
of 12 runs with **zero NIC drops** (rx_dropped/missed/fifo/over all +0). The
per-run ordering is noise (rust4 happened to spike most here, 2/12–5/12 across
prior runs; r8169 spiked most in earlier runs) — it is **not** a
driver-distinguishing metric, which is why the headline is "no *clean* driver
metric favors C" rather than an absolute. See `memory: tcp-retransmit-rig-noise`.

## Where Rust genuinely wins

- **Latency under load** (bulk TCP flow + ping): Rust **0.60–0.61 ms** median vs
  r8169 0.69, vendorC 0.71. Both Rust configs beat both C drivers.
- **Sustained-stress cleanliness**: 6× back-to-back `-P16` bursts — Rust holds
  line rate with **0 retransmits and 0 dmesg faults**; both C drivers hold line
  rate too but with **~44,000 retransmits**.
- **Small-packet multi-queue pps** (64B UDP, 10 flows): rust4 ties vendorC at
  1.00 Gbit and both beat single-queue r8169's 0.74.

## Two artifacts this run put to rest

Both were earlier "C beats Rust" findings; both were measurement bugs:
- **rust0 TCP TX 10-flow "4/5 retransmit spikes"** → **0/5** once the peer iperf3
  server is restarted per sample (rule 5). It was lingering server state.
- **rust4 "0.79 ms latency"** (worse than C, from one 5-sample set) → **0.61 ms**
  median in this run (N=5, `sweep.csv`; and 0.67 ms median at N=10 in a separate
  verification run) — below both C drivers either way. A single low-N draw is not
  a result (rule 3).

## Re-run

`sudo bash scripts/cvr_stat_sweep.sh [out_dir]` on the gateway (env: `N`,
`NRETR`, `SPIKE`). `bash scripts/cvr_stat_sweep.sh --selftest` runs the stats
unit test with no hardware.
