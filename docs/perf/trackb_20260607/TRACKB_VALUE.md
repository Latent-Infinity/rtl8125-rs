# Track B (hardware RSS / multi-queue) value experiment — 2026-06-07

**Question.** With Track A shipped (single RX queue + RXHASH → software RPS), does
hardware multi-queue RSS (Track B) buy enough to justify its complexity on this
NIC/host? Measured by trying to provoke RX-CPU/IRQ saturation under CPU
contention and comparing against the **vendor Realtek r8125 driver built with
RSS** (the real "Track B in C", not mainline r8169 which lacks it).

## Rig

- Gateway: AMD Ryzen 9 9955HX, **16 cores / 32 threads**, 2.5GbE.
- DUT `enp3s0` (RTL8125B) in netns `dut`; peer `enp4s0` (**Intel igc**, 4 TX
  channels) in netns `peer`; cabled loopback. Generator: `iperf3 -u -b 0 -l 64
  -R -P 10` (peer sends, DUT receives ~2M pps of 64-byte frames).
- Drivers: Rust `r8125_rust` (V3+RXHASH, single queue, single MSI vector);
  vendor `r8125` v9.016.01-NAPI-RSS built `ENABLE_RSS_SUPPORT=y` → **4 RX queues**
  (HwSuppNumRxQueues=4), 32 MSI-X vectors, `receive-hashing on`.
- **Mechanism (per the CPU-contention idea):** pin the NIC IRQ/NAPI to a CPU,
  then run a pinned CPU-bound "application" (`app_bench`, counts Mops/s) to
  recreate app-vs-NIC contention. App retention = app Mops/s under RX flood ÷
  solo Mops/s. Harness: `experiment_v2.sh`; raw mpstat + iperf JSON in `raw/`.

## Results (64-byte RX flood, 10s; app solo ≈ 4735 Mops/s)

| Config | RX pps (P2) | app retention | per-run spread | note |
|---|---|---|---|---|
| Rust single, RPS off, **app ON rx-cpu** | ~1.6M | **1%** | — | app annihilated by NAPI softirq |
| Rust single, RPS off, **app OFF rx-cpu** | ~1.5M | **100%** | — | collision fixed by IRQ placement alone |
| Rust + **RPS**, app ON rx-cpu | ~2.35M | **82% (median)** | 82 / 87 / **1** | **bimodal** — 1 of 3 runs collapsed |
| Vendor **RSS (4q)**, app cpu8 | ~1.97M | **94% (median)** | 89 / 94 / 95 + 92 | consistent every run |
| Vendor RSS (4q), app cpu20 | ~1.96M | 94% | — | consistent |

## Findings

1. **Capacity is not the differentiator at 2.5GbE.** Both drivers top out
   ~2.0M pps (64B) — that is the **generator/iperf ceiling, not a DUT CPU
   ceiling**. Rust+RPS actually delivered *more* pps than vendor 4-queue
   (~2.35M vs ~1.97M). Hardware RSS's core benefit — scaling RX across cores
   beyond one core's NAPI capacity — is unreachable here: 2.5GbE small-packet
   line rate (~2M pps achievable) already fits within one modern core + RPS.

2. **Single-queue concentration risk is real but cheaply mitigated.** With no
   steering and the app on the one RX cpu, the app gets **1%** of its CPU (NAPI
   softirq preempts userspace). But it is fully recovered by either (a) moving
   the app off that cpu (→100%) or (b) enabling RPS (→82% median). Note RPS does
   not protect the app by moving the *poll* — it moves the downstream stack to
   idle cpus, freeing the IRQ cpu.

3. **Track B's genuine edge is determinism.** Vendor 4-queue held **89–95%**
   every run; Rust+RPS was **bimodal** (82–87% twice, **1% collapse once**).
   Hardware RSS spreads across queues/cpus regardless of software-RPS hash
   distribution and scheduler feedback. Worth ~0–13pp app retention plus removal
   of the tail-risk collapse — modest, not transformative.

## Verdict: **defer Track B; its payoff does not materialize at 2.5GbE.**

Software RPS — enabled by the RXHASH already shipping in Track A — matches or
beats hardware 4-queue RSS on raw RX pps at this link speed, and the
single-queue coexistence penalty is largely solved by RPS + basic IRQ placement.
The only measured Track B advantage is consistency (no bimodal collapse) worth a
modest app-retention margin.

**Cheaper win to chase first:** root-cause the **Rust+RPS bimodal collapse**
(1 of 3 runs behaved as if RPS disengaged — cpu8 saturated at ~93% soft even at
lower offered pps). If that collapse is common in real workloads it is a Track A
robustness bug, fixable far more cheaply than full hardware RSS.

**Revisit Track B only if:** targeting higher line rates (10G+), a many-core RX
spread requirement emerges, or the RPS collapse proves unfixable in software.

## RPS Collapse Follow-Up

The apparent Rust+RPS collapse is **not reproduced under verified RPS state**.
The original `experiment_v2.sh` run was under-instrumented:

- It passed `RPS=1`, which writes `rx-0/rps_cpus=00000001` (CPU0), despite the
  prose describing steering to idle CPUs.
- It did not record the effective `rps_cpus`, IRQ affinity after writes,
  `receive-hashing`, `rx_hash_*` deltas, or softnet drops for the collapsed run.
- The raw `mpstat` proves only that CPU8 stayed near 93-99% softirq in the bad
  run; it does not prove whether RPS was misconfigured, not applied, or missing
  hashes.

Follow-up diagnostic:

- Harness: `scripts/rps_collapse_diagnose.sh`
- Artifact: `docs/perf/rps_collapse_fe00_20260607/`
- Setup: active IRQ 68 pinned to CPU8; `rx-0/rps_cpus=0000fe00` (CPUs 9-15);
  app pinned to CPU8; five 10s reps of 64B UDP RX flood.
- Result: **5/5 `ok`**, P2 app retention **75-83%**, P2 RX **2.28-2.39 Mpps**,
  `rx_hash_l4` advanced every run, `rx_hash_missing=0`,
  `rx_hash_disabled=0`, and softnet drops were 0 in the intended-mask run.

Conclusion: Track A's RXHASH path is not currently implicated. Treat the old
1% row as an invalid/inconclusive RPS-control-plane outlier unless it reproduces
under the diagnostic harness with effective RPS mask and hash counters captured.

## Caveats

- **Generator-bound (~2.0M pps).** iperf3 over the igc peer could not push past
  ~2M pps of 64B frames, so the true RX *ceiling* of neither driver was reached;
  the capacity comparison is "neither saturates," not "equal ceilings." A
  kernel-space generator (pktgen) would be needed to probe higher, but pktgen is
  not netns-aware on this rig.
- Vendor `active_rx_vec` detection read 0 because the vendor driver busy-polls
  under sustained load (few hardware IRQs); it therefore ran on its **default**
  queue affinity. That is also how it runs in production. One vendor cpu still
  hit ~99% soft (10 flows do not spread evenly across 4 queues), but never the
  app's cpu.
- 10s windows, 1–4 reps. Large effects (1% vs 82% vs 100%) are robust; the
  82%-vs-94% margin is within run-to-run noise.
