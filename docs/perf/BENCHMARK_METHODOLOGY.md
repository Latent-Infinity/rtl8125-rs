# Driver Benchmark Methodology (C / vendor-C / Rust)

The standard for every performance comparison between this Rust driver, the
in-tree **r8169**, and the Realtek **vendor r8125** (RSS build). It exists
because the failure mode on this rig is not "Rust is slow" — it is **drawing a
driver conclusion from a measurement artifact.** Every "C beats Rust" claim we
have investigated turned out to be one of: a single sample of a bursty metric, a
parser bug, a lingering peer-server state, or a queue-count mismatch. These rules
make that class of error hard to commit.

Canonical harness: **`scripts/cvr_stat_sweep.sh`** (supersedes the single-sample
`scripts/trackb_cvr_sweep.sh`). TDD guard: **`ci/check_sweep_stats.sh`** (in
`run_checks.sh`) parses the harness and unit-tests its pure stats helper via
`bash scripts/cvr_stat_sweep.sh --selftest`.

## The ten rules

1. **Three-way, always.** Compare Rust against BOTH baselines — in-tree
   `r8169` *and* vendor `r8125` — and run Rust in both relevant configs
   (`rss_queues=0` RFC default, `rss_queues=4` LB opt-in). A two-way comparison
   hides the truth: the "in-tree" driver a maintainer cares about is r8169, and
   it is frequently *worse* than both Rust and the vendor (e.g. it spiked
   retransmits most often, and is single-queue so it loses small-packet pps).

2. **Fresh-load per driver.** Unbind, `rmmod`/`modprobe -r`, reload, rebind, wait
   for carrier. Never measure on a driver that has been running through prior
   tests — stale ring/IOVA/coalescing state produces phantom `tx_dropped_error`
   and collapse that vanishes on reload. (multiqueue-tx-iova-affinity lesson.)

3. **N samples, never one.** Throughput/latency: **N ≥ 5**. Bursty metrics
   (retransmits): **N ≥ 12**. Report **median + min + max**, not a point value.
   A single number from a bursty metric is not evidence — it is one draw from a
   wide distribution.

4. **Bursty metrics are a spike RATE, not a value.** Report retransmits as
   `spikes=k/N` over a threshold (default >100), plus the max. On this rig TCP
   retransmits burst on ~2–5 of every 12 runs for *every* driver with **zero NIC
   drops** — they are peer/TCP-stack artifacts, not driver loss. A median and a
   spike-rate together tell the honest story; a lone sample lies.

5. **Control peer/server state.** Restart the peer `iperf3 -s` before **every
   sample** (not once per block). A lingering server from a previous run injects
   phantom TX retransmit spikes that look exactly like a driver gap. (Verified
   2026-06-10: rust0 TX 10-flow went "4/5 spikes" → 0/12 with per-sample
   restart.)

6. **Corroborate with NIC counters.** A *real* driver-side loss MUST show up in
   `rx_dropped` / `rx_missed_errors` / `rx_fifo_errors` / `rx_over_errors` /
   `tx_dropped` (delta before→after each run). If the metric moves but every NIC
   counter delta is `+0`, the loss is **not in the driver** — it is the sender,
   the peer, or TCP. Do not "fix" the driver for it.

7. **Like-for-like queue counts.** Do not compare `rust0` (1 RX queue) against
   vendor C (4 queues) and call the difference a driver gap. Compare equal
   configs: `rust4` vs `vendorC` (both 4q), `rust0` vs `r8169` (both 1q). A
   queue-count mismatch is a configuration difference, not a defect.

8. **Classify the metric before claiming a winner.** Two kinds:
   - **Link-bound (parity, no winner):** at 2.5 GbE, TCP/large-UDP/jumbo
     throughput all sit at the ~2.35–2.48 Gbit line-rate ceiling for every
     driver. Nobody can "win" a saturated link — equal here is the correct,
     expected result, not a tie to be broken.
   - **Differentiating (real win axes):** latency-under-load, sustained-stress
     resilience (retransmits / dmesg faults under repeated `-P16`), and
     small-packet pps (where a single core's NAPI budget bites). These are where
     a driver can actually be better. Focus wins/regressions here.

9. **State stress severity, and don't trade retransmits for throughput.** Always
   record stress duration/rounds and the `dmesg` fault delta. A driver that
   "holds throughput" while emitting tens of thousands of retransmits has not
   won — clean throughput (line rate at retr=0) beats dirty throughput.

10. **Reproduce before you conclude — especially before changing code.** If a
    gap appears, re-measure it at high N with rules 2–6 applied *before*
    theorizing a fix. Both gaps that triggered the 2026-06-10 investigation
    (rust0 TX spikes, rust4 latency) evaporated on re-measurement. A speculative
    fix for a non-bug is how the TX try-lock regression happened — it made drops
    *worse*.

## What "Rust wins on every metric" actually means

Under these rules (see `docs/perf/cvr_stat_sweep_20260610/`): Rust is **at-or-
better than both r8169 and vendor C on every metric** — it wins the
differentiating axes (latency-under-load, sustained-stress retransmits,
small-packet multi-queue pps) and ties at the link-bound ceiling everywhere else.
No *clean, driver-attributable* metric favors either C driver once measured
honestly. (The bursty TCP-retransmit spike count is the one row where a C driver
can look lower on a given run — but it has zero NIC drops and reorders run to
run, so it is rig noise, not a driver result; see rules 4 and 6.) Every concrete
"C beats Rust" claim we have chased was a measurement artifact.

## Related

- `scripts/cvr_stat_sweep.sh` — canonical harness (`--selftest` for the stats unit test)
- `ci/check_sweep_stats.sh` — TDD guard (wired into `ci/run_checks.sh`)
- `docs/perf/cvr_stat_sweep_20260610/` — the authoritative three-way sweep evidence
- `docs/perf/DRIVER_GAP_LEDGER.md` — per-area Rust-vs-C status
- memory: `tcp-retransmit-rig-noise`, `multiqueue-tx-iova-affinity`, `trackb-value-verdict`
