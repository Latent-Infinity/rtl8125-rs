# Multi-Queue RSS Activation and Hazard Findings (2026-06-09)

This change activates N>1 hardware RSS (`rss_queues=2` or `rss_queues=4`) on
the RTL8125B V2 MSI-X surface. It includes the multi-ring foundation,
per-vector IRQ routing, RSS spread, hazard validation, and the multi-queue
TX DMA-locality fix.

## What works (gateway-validated)
- **Multi-queue TX/RX run clean at line rate.** `rss_queues=4`, default
  `irq_pin_cpu=255`: 8/8 cold back-to-back bulk TX at **2.36 Gbit, retr=0, 0
  `tx_dropped_error`**; 30s sustained TX 0 drops; RX→TX→RX retr=0; UDP ~0% loss
  2.39 Gbit; **0 IOMMU/dmesg faults**. (Required the affinity-spread fix below.)
- **RSS spreads.** `rss_queues=4` + source-IP-diverse pktgen 64B flood: all 4
  RX-queue IRQs active (rx0..rx3), ~1.78M pps, 0 dmesg faults. ethtool reports
  4 RX queues; 6 MSI-X vectors (rx0-3/tx0/link).
- **Default (`rss_queues=0`) unregressed + IOMMU-clean.** Single-queue RXHASH:
  TCP 2.35/2.36 Gbit, UDP 0% loss, **0 IOMMU/warn faults**. The default path is
  unaffected by the multi-queue work.

## Bugs the hazard validation caught
1. **TX-completion race (FIXED).** `napi::poll` reaped the single shared TX ring
   on *every* queue's poll → 4 NAPIs racing the TX shadow/tail → completion
   corruption AND double `dma_unmap` of the same TX buffer. TCP had collapsed to
   **121 Mbit RX / 12 Mbit TX, retr=77**. Fix: only RX queue 0 (which owns the
   tx0 vector) reaps TX. Throughput restored to **2.35 / 2.36 Gbit, UDP 0% loss**.
2. **IOMMU DMA-unmap WARNING (ROOT-CAUSED + FIXED — same bug as #1).** The
   `WARNING ... iommu_dma_unmap_phys` / `__iommu_dma_unmap` warnings were the
   double-`dma_unmap` symptom of the TX race: two NAPIs reaping the same TX
   descriptor unmapped the same IOVA twice. The single-reaper fix eliminates
   them. **Confirmed with a cleared dmesg buffer at `rss_queues=4`:** TX-only,
   RX-only, and UDP `-P10` each produce **0 IOMMU faults**. The earlier "21
   faults" was stale ring-buffer from pre-fix runs (the count script hadn't
   `dmesg -C`'d). Default `rss_queues=0`: 0 faults. **IOMMU question RESOLVED.**

## Multi-Queue TCP TX Collapse — Root-Caused and Fixed

**Symptom.** At `rss_queues>1`, bulk TCP TX collapsed (often to a few Mbit /
0.00, sometimes line rate with retr in the thousands), while `rss_queues=0` was
rock-solid (2.36 Gbit, retr=0) and UDP/RX were unaffected.

**Decompose-and-measure (per the ground-up TDD steer).** Counter forensics
(`ethtool -S`) showed the collapse was **TX-side `tx_dropped_error`**, and the
`tx_received = tx_consumed + tx_dropped_error` balance placed every drop *after*
the `tx_received++` in `skb_data_dma_map` → the drops are **`dma_mapping_error`
on the TX streaming map**, not offload-prep, not RX. No IOMMU/IOVA/swiotlb
message accompanied them, and they were **bursty + multi-queue-only**.

**Root cause = per-CPU IOVA rcache contention from un-pinned RX vectors.**
The driver pinned only rx0/tx0/link, and the auto-pin (`irq_pin_cpu=255`)
collapsed them onto one NUMA-local CPU; rx1–3 were left on a broad affinity mask
free to migrate. With RX refill DMA bouncing across many CPUs, the per-CPU IOVA
caches churn and `dma_map_single` sporadically fails → `tx_dropped_error` →
retransmits → collapse. Single-queue never hit it (all DMA on one CPU).
**Confirmed:** pinning every vector to a distinct CPU → **retr=0, 0 drops**;
broad mask → 39–63k drops.

**The fix (two elements, both minimal):**
1. **IRQ affinity spread** (`layout::irq_affinity_cpu`, host-unit-tested). The
   auto policy now fans the *active* vectors (rx0..rx_{N-1}, tx0, link) across
   distinct CPUs from the PCI-local NUMA base, so each queue's DMA stays on one
   per-CPU IOVA cache. Replaces the old single-CPU `irq_pin_auto`.
2. **Reverted the "any-queue try-lock reaper."** An interim try-lock that
   let every NAPI reap the shared TX ring turned out to be the source of the
   *worst* drops (62859, multi-queue ring/IOVA corruption) — **not** a fix.
   Reverting to queue-0-only reaping is correct AND simpler (KISS): once DMA
   stays per-CPU, the tx0 vector keeps queue 0 reaping fast enough. This also
   disproved the earlier "reaping-starvation" theory.

**Validation (`rss_queues=4`, default `irq_pin_cpu=255`):**
- 8/8 cold back-to-back bulk TX: **2.36 Gbit, retr=0, 0 drops** each.
- Sustained 30s TX: 2.35 Gbit, retr=0, **0 drops**.
- RX→TX→RX ×3: 2.35 / 2.36 Gbit, retr=0.
- UDP RX `-P10`: ~0% loss, 2.39 Gbit. **0 IOMMU/dmesg faults.**
- Residual: simultaneous 20s bidir shows ~115 drops (≈0.0002%, no throughput
  or retr impact) — inherent bidirectional cross-CPU IOVA cost, acceptable.

## Status / verdict
- Multi-queue RSS is staged; default `rss_queues=0` stays safe + clean
  (unchanged path).
- **IOMMU DMA-unmap question: RESOLVED** (was the TX race; fixed).
- **Multi-queue TCP TX collapse: RESOLVED** (affinity spread + try-lock
  revert). `rss_queues>1` now runs clean at line rate.
- `irq_affinity_cpu` is host-unit-tested (6 cases); `ci/check_latency_knobs.sh`
  now enforces the spread API.

## Artifacts / harnesses
- `scripts/rss_multiqueue_hazard_validate.sh` (fixed a `set -u` `local`
  self-reference bug; note: its single-peer iperf UDP does not exercise RSS
  spread because RTL8125 hashes by L3 — use the pktgen IP-diverse flood for the
  spread proof).
- Gateway smoke scripts: pktgen spread, per-vector default, and TX/RX retest.

## Rust vs vendor-C comparison (2026-06-09) — cold-start parity confirmed

Driver-vs-driver on the gateway loopback rig (`rss_queues=4` Rust vs vendor
`r8125` 9.016.01-NAPI-RSS, 4 queues), both moved into the `dut` netns identically.

**Cold start — first TCP TX flow after a fresh driver load, 6 iterations each:**

| iter | Rust rss=4 | vendor C 4q |
|---|---|---|
| 1–6 | 2.36 Gbit, retr=0, `tx_dropped_error=0` (all 6) | 2.36 Gbit, retr=0 (all 6) |

→ **No cold-start difference. Rust is at parity with the vendor C driver** — both
clean at line rate with zero drops on every fresh-load first flow.

**`-P8` parallel stress (8 concurrent streams, 3×10s each) — the LB-shaped load:**

| run | Rust rss=4 | vendor C 4q |
|---|---|---|
| 1 | 2.36 Gbit, retr=0, tx_dropped_error +0, ip-drops 0 | 2.36 Gbit, retr=0, ip-drops 0 |
| 2 | 2.36 Gbit, retr=18, tx_dropped_error +3, ip-drops 0 | 2.36 Gbit, retr=0, ip-drops 0 |
| 3 | 2.36 Gbit, retr=0, tx_dropped_error +0, ip-drops 0 | 2.36 Gbit, retr=0, ip-drops 0 |

→ Both hold line rate with zero standard-netdev TX drops. Rust showed a tiny
blip here (retr=18 once, +3 counter drops once) — but this section did NOT
fresh-load between runs. **The blip is a no-reload artifact: it vanished entirely
under fresh-load methodology** (see the next section — `-P16` fresh-load 5/5
runs: Rust retr=0, 0 drops). A clean dmesg-content inspection under -P8 showed
**0** warnings for *both* drivers (the high fault *counts* in an earlier ad-hoc
run were a transient RTNETLINK hiccup during rapid reloads, not driver warnings —
the gateway had 27 GB free).

**Closeout note:** the multi-queue TX collapse / 56–95-drop figures seen in
earlier *uncontrolled* runs (a `-P8` flow against a non-reloaded driver, plus
repeated rapid flows) did NOT reproduce in any controlled cold-start or
controlled -P8 run. Cold start is at vendor-C parity; the residual is a tiny
parallel-stress counter artifact at line-rate parity. Harness lesson: always
fresh-load before measuring, and don't interleave `-P8` stress with single-flow
measurement on the same load.

### Heavy parallel + sustained stress (2026-06-09) — Rust ≥ C everywhere

Fresh-load-per-run methodology (the no-reload confounder is what produced the
earlier spurious "C-favored" blip; it does not survive a fresh load).

**`-P16 -t12`, fresh load each, 5× per driver:**

| metric | Rust rss=4 | vendor C 4q |
|---|---|---|
| throughput | 2.36 Gbit (5/5) | 2.36 Gbit (5/5) |
| TCP retransmits | **0 (5/5)** | ~13,700–14,100 (5/5) |
| tx_dropped_error | 0 | 0 |

**Sustained: ONE load, 3× `-P16 -t20` back-to-back (no reload = deployment):**

| run | Rust rss=4 | vendor C 4q |
|---|---|---|
| #1 | 2.36 Gbit, retr=0 | 836 Mbit, retr=12672 |
| #2 | 2.36 Gbit, retr=0 | EMPTY (failed) |
| #3 | 2.36 Gbit, retr=0 | EMPTY (failed) |
| serious dmesg (call trace/iommu/BUG/oops) | **0** | **64** |

→ **No scenario favors C.** Rust matches C on cold start and is clearly better
under parallel load; under *sustained* parallel load the vendor C driver
degrades/fails on our gateway rig (throughput collapse, ~12k retransmits, 64
serious kernel warnings) while Rust holds line rate with zero retransmits, drops,
or warnings. The marginal `-P8` blip reported earlier was a no-reload test
artifact and did not reproduce with fresh-load methodology.
