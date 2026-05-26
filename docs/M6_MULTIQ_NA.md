# M6 sub-feature #2 — Multi-queue / RSS: **N/A on 8125B**

**Decision (2026-05-26): skip the multi-queue work on this chip.**

The plan §7 M6 lists "Multiple TX queues + RSS" as the second M6
sub-feature. After surveying Realtek's vendor driver source for the
8125B, multi-queue is **not exposed by the hardware** on this chip
revision. This document captures the evidence and the rationale for
deferring the work.

## Evidence

`references/realtek-r8125-official/src/r8125_n.c:15054-15078` —
the per-chip queue-count switch:

```c
switch (tp->mcfg) {
    ...
case CFG_METHOD_13:        // (8125D / similar)
    tp->HwSuppNumTxQueues = 2;
    tp->HwSuppNumRxQueues = 4;
    break;
default:                   // *includes* CFG_METHOD_4/5 (8125B,
                           //  MAC_VER_63, XID 0x641 — our target)
    tp->HwSuppNumTxQueues = 1;
    tp->HwSuppNumRxQueues = 1;
    break;
}
```

The validated MS-A2 RTL8125B (XID 0x641, `RTL_GIGA_MAC_VER_63`) falls
under the default case. The chip itself reports **1 TX queue + 1 RX
queue**. Attempting to enable additional queues would either:

1. Silently no-op — the chip's queue-routing registers don't drive
   additional descriptor rings.
2. Misroute frames — without per-queue hardware support, software
   striping doesn't help (no RSS hash table to populate).

r8169 mainline (`r8169_main.c`) also runs single-queue on 8125B
(no multi-queue netif allocation path); it shares this constraint.

## What this means for the M6 gate

The plan §7 M6 lists per-feature gates that include:
- `ethtool -L` can configure queue counts
- Per-queue stats visible in `ethtool -S`
- Disabling RSS at runtime restores correctness

These gates are **vacuously satisfied** on 8125B:
- `ethtool -L` would only accept `tx 1 rx 1` (the only valid count);
  we already advertise that via `netif_alloc_etherdev_mq(1, 1)` in
  the cshim.
- Per-queue stats: we have one queue, so existing aggregate stats =
  per-queue stats.
- RSS disable: there's nothing to disable; chip-side `RSS_CTRL_8125`
  is already programmed to 0 in `hw_start_8125b` (the M4-perf
  chip-init parity work).

## Recommendation

**Do not attempt multi-queue work for 8125B.** Mark this M6
sub-feature as N/A in the close-out report. Future support for 8125D
or 8126 (different chip revs that *do* support multi-queue) would
re-open this scope under a new chip-version dispatch entry.

If the operator obtains an 8125D / 8126 / similar multi-queue stepping
later, the design for that should:

1. Add a new `ChipInfo` row in `src/hw.rs::KNOWN` with the new XID.
2. Add a per-chip-version `n_tx_queues` / `n_rx_queues` field.
3. Rework `NetdevState` to hold N rings (currently 1) — substantial.
4. Add RSS hash table programming via `RSS_KEY_8125` / `RSS_INDIR_TBL_8125`.
5. Wire `ethtool -L`/`-X` through the cshim.

This is M7+ scope on the chip-rev expansion path, not core 8125B work.
