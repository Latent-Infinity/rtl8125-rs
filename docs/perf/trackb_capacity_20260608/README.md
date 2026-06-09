# Track B capacity evidence — single-queue RX ceiling vs hardware RSS (2026-06-08)

This closes the one gap the 2026-06-07 Track B value experiment
(`docs/perf/trackb_20260607/TRACKB_VALUE.md`) left open: it was **generator-bound
at ~2.0M pps** (iperf over the igc peer), so the true single-queue RX ceiling —
and therefore the capacity headroom hardware RSS would add — was unmeasured.

Here we drive the DUT with **kernel-space pktgen** (overcoming the iperf ceiling)
and pin IRQ affinity to read the RX CPU cost directly.

## Rig

- Gateway RTL8125B DUT (`enp3s0`, dut netns) ← wire ← igc peer (`enp4s0`, root
  ns, pktgen). Kernel 7.0.0-22, AMD Ryzen 9 9955HX (16c/32t).
- Generator: pktgen, 4 threads (igc has 4 TX queues), 64-byte frames,
  `clone_skb 100000`, `UDPSRC_RND` (+`IPSRC_RND` src 10.0.1.1-250 for the RSS
  run). Max offered ≈ **1.78–1.79M pps** — the igc's 64B TX ceiling.
- DUT NIC IRQs pinned to isolated CPUs; pktgen threads on CPUs 0-3. mpstat reads
  the RX CPU(s) softirq directly. Harness: `pg_ceiling.sh` /
  `pg_ceiling_vendor.sh`; raw mpstat in `raw/`.

## Results (64-byte flood, ~1.78M pps offered, 0 drops in all runs)

| Config | RX CPUs | softirq per RX CPU | extrapolated ceiling |
|---|---|---|---|
| **Rust single queue** (IRQ→1 CPU) | 1 | **87.5%** (12.3% idle) | **~2.0M pps** |
| Vendor 4-queue RSS, **single src IP** | 1 (!) | c19 **100%**, others 0% | ~1.8M (no spread) |
| Vendor 4-queue RSS, **diverse src IPs** | 4 | ~26–39% each | **~4.5M+ pps** |

## Findings

1. **A single RX queue saturates one core at ~2.0M pps** on this hardware
   (87.5% softirq at 1.78M offered). That is *below* 64-byte line rate
   (2.5GbE ≈ 3.72M pps) but *above* every large-packet rate (1500B line rate is
   only ~195k pps) and above what a single igc sender can even produce.

2. **Hardware RSS roughly doubles+ the ceiling — but only with hash diversity.**
   With diverse source IPs the 4 queues spread to ~35%/CPU ⇒ headroom to
   ~4.5M+ pps (covers 64B line rate). With a **single source-IP pair**, RSS hashed
   all UDP to one queue (L3 hashing for UDP by default) — **no spread, no benefit**.
   So RSS helps a server facing *many peers*, not a single-peer flood.

3. **Software RPS (already shipped via Track A RXHASH) partially closes the gap.**
   The 2026-06-07 data showed RPS lifting single-queue from ~1.0M to ~2.4M pps by
   spreading the stack across CPUs — also dependent on hash diversity, and with a
   run-to-run consistency wrinkle hardware RSS does not have.

## Track B go/no-go verdict

**The capacity gap is real but narrow: ~2.0M pps (single queue) → ~4.5M+ pps
(hardware RSS), realized only for high-pps small-packet RX with source-IP
diversity.**

- **Do Track B (activate N>1)** if a target deployment is a 2.5GbE
  multi-client server / load-balancer / DNS / CDN edge that genuinely sees
  **>2M pps of small packets from many sources**. There hardware RSS is the only
  thing that reaches 64B line rate and keeps any single core off the ceiling.
- **Defer Track B** for the RFC/upstream baseline and typical workloads:
  single queue + RXHASH→RPS already sustains line rate for normal packet sizes
  and ~2.4M pps small packets — more than a single 2.5GbE sender produces, and
  past the point where the link itself is the limiter for realistic traffic.

This is now an **evidence-based** decision rather than an open unknown. The
B1-B5 scaffolding (queue-aware bridge, V2 MSI-X, RSS programming, ethtool plane)
is in place and low-risk; flipping N>1 on (B6) is justified **iff** the
small-packet-many-peer workload is a stated target. No current Gateway benchmark
or project requirement names that workload, so the default remains: defer, with
the activation path ready if evidence of that workload appears.

## Caveats

- igc TX caps ~1.78M pps at 64B, so ceilings are extrapolated from CPU softirq
  (87.5% single / ~35% per-CPU quad), not driven to actual drop. Both directions
  showed **0 drops** at the offered rate; the extrapolation assumes linear
  per-packet cost, which holds across the measured range.
- Vendor busy-polls under load (few hardware IRQs); its 4 RX-queue vectors were
  pinned to CPUs 16-19 explicitly to read per-queue cost.
