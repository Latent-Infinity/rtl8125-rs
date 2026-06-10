# M6 sub-feature #2 — Multi-queue / RSS

> **SUPERSEDED (2026-06-09). The original "N/A on 8125B" decision below was
> WRONG and is retained only for history.** The validated RTL8125B (XID 0x641,
> MAC_VER_63) **does** support 4 RX queues + RSS, and the driver now implements
> and hardware-validates full multi-queue RSS (Track B). See
> `docs/RSS_RXHASH_IMPLEMENTATION_PLAN.md`, `docs/perf/rss_multiqueue_20260609/`,
> and `docs/perf/cvr_sweep_20260609/`.

## Correction — what the original analysis got wrong

The 2026-05-26 note concluded multi-queue was unsupported by reading the vendor
per-chip queue-count switch and assuming `CFG_METHOD_4/5` (8125B) fell into the
`default: HwSuppNumRxQueues = 1` case. That reading was incorrect for this
stepping: the validated 8125B reports **`HwSuppNumRxQueues = 4`** and
`HwSuppIndirTblEntries = 128`, and the V2/MSI-X interrupt surface (22 vectors)
drives the per-queue rings. Confirmed empirically on hardware, not from
source-reading:

- RX spreads across all 4 RX-queue IRQs under an IP-diverse pktgen flood
  (~1.78M pps, 0 faults).
- `ethtool -l` reports 4 RX queues; `ethtool -L rx {1,2,4}` reconfigures them at
  runtime; `ethtool -x` shows the 128-entry indirection table.
- `rss_queues=4` runs at line rate (2.36 Gbit gateway / 2.32 Gbit KVM), 0
  `tx_dropped_error`, at-or-better than the vendor C r8125(RSS) driver across the
  runtime-validation sweep.

## Current state (replaces the original "vacuously satisfied" gates)

- **`ethtool -L`** changes the active RX-queue count (1/2/4) via a stop+open
  reconfigure; invalid counts (3, >max, combined/tx) are rejected.
- **`ethtool -X`/`-x`** program/read the RSS key + indirection table.
- **RSS disable**: the default `rss_queues=0` keeps the proven single-queue RFC
  path (RSS_CTRL cleared); multi-queue is a validated operator opt-in.
- TX remains a single ring (reaped by queue 0); the V2 TX-completion vector is
  entry 16 (see `docs/M6_MSIX_DESIGN.md`).

## Why the default stays single-queue

Multi-queue is opt-in (`rss_queues`), not the default: at 2.5 GbE one core +
RXHASH→RPS already absorbs realistic line-rate traffic, and the measured
multi-queue capacity gain only materializes for >2M pps small-packet RX from
many peers (multi-client server/LB). The gateway/LB deployment is that case, so
the feature is implemented and validated — but the RFC single-queue path is
unchanged. Evidence: `docs/perf/DRIVER_GAP_LEDGER.md` (Track B closeout).

---

_Original 2026-05-26 note (incorrect — kept for history):_ the per-chip switch
in `references/realtek-r8125-official/src/r8125_n.c` was read as placing
CFG_METHOD_4/5 in the single-queue default case; this was mistaken for the
validated XID 0x641 stepping, which reports 4 RX queues. Future 8125D/8126
steppings would extend the queue count further under their own chip-version
dispatch.
