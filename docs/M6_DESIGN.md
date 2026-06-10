# M6 — Performance Features (design)

**Status (2026-05-26): design only**. M5 ASPM 48-hour soak chain
running on the chip; M6 implementation begins after the soak completes
and any findings are addressed.

The plan §7 M6 lists five performance sub-features to be enabled
**one at a time**, with per-feature gates applied before moving to the
next. Two of the five are already done in M4-perf, one is N/A for our
chip, leaving two real M6 sub-features:

| # | Plan §7 M6 sub-feature | Status on 8125B | Owner doc |
|---|---|---|---|
| 1 | MSI-X (replace legacy IRQ) | **scoped** | `docs/M6_MSIX_DESIGN.md` |
| 2 | Multiple RX queues + RSS | **DONE (Track B, 2026-06-09)** — 4 RX queues, RSS, ethtool -L/-x/-X; opt-in via `rss_queues` | `docs/RSS_RXHASH_IMPLEMENTATION_PLAN.md` |
| 3 | Jumbo frames (MTU 9000) | **scoped** | `docs/M6_JUMBO_DESIGN.md` |
| 4 | RX/TX checksum offload | done in M4-perf (task #48) | — |
| 5 | TSO/GSO | done in M4-perf (task #49) | — |

M6 was originally scoped as **MSI-X + jumbo** for this chip (the
multi-queue row was wrongly marked N/A — see the correction below).

## Correction: multi-queue is supported and DONE

The original "why the collapse" rationale below was **wrong**: it claimed
8125B exposes only 1 RX queue. The validated 8125B (XID 0x641) actually
reports **4 RX queues + a 128-entry RSS indirection table**, and Track B now
implements + hardware-validates full multi-queue RSS (default stays
single-queue `rss_queues=0`; multi-queue is an opt-in). See
`docs/M6_MULTIQ_NA.md` (superseded notice) and
`docs/RSS_RXHASH_IMPLEMENTATION_PLAN.md`.

CSUM and TSO landed early in M4-perf because they don't require new
chip-init beyond what M4 already needs (descriptor opts bits).

_Original (incorrect) rationale, kept for history:_ `docs/M6_MULTIQ_NA.md`
was read as confirming 8125B exposes only 1 TX + 1 RX queue — that
source-reading was mistaken for this stepping.

## Recommended sequencing

**Order is important.** MSI-X is foundational because it gives us
per-vector interrupt routing that future M6+ work (a separate
link-change vector, or per-CPU NAPI if we ever expand queues) will
depend on. Jumbo is a self-contained but substantial refactor that
shouldn't run in parallel with MSI-X migration — both touch the
interrupt + buffer-management paths and concurrent changes would
confuse bisection if a regression appears.

```
phase 1: MSI-X migration              (~80 R + 30 C + 60 CI LOC)
         ├── phase A: 1 vector, ISR_V2  ←  the minimum delta
         └── phase B: split link-change vector  (optional, defer to M6+)

phase 2: Jumbo frames                  (~250 R + 50 C + 50 CI LOC)
         ├── phase A: RxMaxSize bump (no MTU change)
         ├── phase B: RX pool → streaming DMA
         ├── phase C: max_mtu = JUMBO_9K
         └── phase D: perf measurements + ethtool toggle test

phase 3: per-feature M6 gates         (~30 LOC docs + perf numbers)
         ├── docs/perf/m6_msix_before_after.md
         ├── docs/perf/m6_jumbo_before_after.md
         └── rollback validation per chip-version dispatch
```

Total estimated work: **5-8 hot-iteration sessions** with the chip
available. Most of the cost is jumbo (RX-pool refactor + page-level
DMA management).

## Per-feature gates (plan §7 M6 — common surface)

For each of MSI-X and jumbo, before moving on we verify:

1. **Runtime disable** — operator can turn the feature off and the
   driver gracefully reverts.
   - MSI-X: module param `intx_only=1` reloads with legacy IRQ.
   - Jumbo: `ip link set enp5s0 mtu 1500` reverts to standard MTU
     and stays stable.

2. **Packet capture verifies wire correctness** — operator runs
   tcpdump on the peer, observes correct frames at the new feature.
   - MSI-X: n/a (interrupt mode invisible on wire). Verify
     `cat /proc/interrupts` shows our IRQ name + non-zero count.
   - Jumbo: `iperf3 -M 9000` from peer, tcpdump confirms 9000-byte
     wire frames.

3. **Bad-checksum injection** — chip/driver does NOT silently fix
   bad checksums when CSUM offload is on.
   - MSI-X / jumbo: n/a (covered by existing M4-perf CSUM tests).

4. **Per-revision rollback** — bad-config dispatch lets us disable
   the feature for a specific chip rev.
   - MSI-X: `ChipInfo.uses_msix: bool` field with default true.
   - Jumbo: `ChipInfo.max_mtu: u32` field with default ETH_DATA_LEN.

5. **`docs/perf/` numbers** — median throughput, p99 latency under
   load, CPU per Gbps (system + softirq), small-packet rate.
   - Capture pre/post for each feature.

6. **Throughput within 10% of out-of-tree r8125** — measured against
   `references/realtek-r8125-official` if the operator runs that
   driver on the same hardware. (We're at parity with r8169 mainline
   already.)

## Code-changes inventory (high-level)

Files that will change for M6:

| File | MSI-X | Jumbo |
|---|---|---|
| `src/regs.rs` | + ISR_V2 / IMR_V2 / INT_CFG0_ENABLE_8125 constants | + JUMBO_*_BYTES constants |
| `src/mmio.rs` | + isr_v2 / imr_v2_set / imr_v2_clear / ack_isr_v2 | + (no change) |
| `src/hw.rs` | + INT_CFG0_ENABLE_8125 set, IMR_V2_CLEAR all sources | + RxMaxSize = JUMBO_16K |
| `src/netdev.rs` | restructure IRQ handler to read ISR_V2 + dispatch | RX pool → streaming DMA |
| `src/napi.rs` | re-arm via set_imr_v2_mask not set_imr | use slot.cpu instead of rx_buf_ptr |
| `src/netdev_bridge.c` | (no change) | `ndev->max_mtu = JUMBO_9K_BYTES` |
| cshim new | (probably none) | `r8125_bridge_alloc_pages` + dma helpers |
| `src/unsafe_boundary.rs` | (no change) | + ~4 new `unsafe` wrappers |
| `Makefile` / `Kbuild` | (no change) | (no change) |

Net unsafe-census delta: **+4 to +6** in jumbo phase (page-level DMA
helpers). The unsafe budget is set by the existing
`.unsafe-allowlist` + the census check; allow some headroom or
explicitly update the budget when jumbo lands.

## Risks (cross-cutting)

- **Concurrent landing**: doing MSI-X and jumbo at the same time
  obscures bisection. **Mitigation**: land them sequentially, with
  CI green between them.
- **M5 close-out gates**: ASPM-on 24h soak (phase 2 of the running
  chain) may surface chip-state issues that affect MSI-X (the new
  V2 ISR registers are PCIe-mapped just like everything else; if
  ASPM L1.x is broken on the chip, it's broken regardless of
  interrupt mode). **Mitigation**: do not start M6 implementation
  until phase 2 of the soak chain is decisively pass or fail.
- **Out-of-tree r8125 vendor as reference**: the vendor's MSI-X
  code uses up to 32 vectors for features (DASH, etc.) we don't
  have. Cherry-picking only the 1-vector subset of vendor code is
  the right approach; document this carefully.

## What this design document does NOT cover

- **RX-perf** (page_pool, XDP, RPS/RFS) — these are M6+1 work.
- **MSI-X queue affinity setting via `irq_set_affinity_hint`** —
  meaningful only with multi-queue; deferred with multi-queue.
- **Coalesce tuning** (interrupt moderation) — covered by the
  existing `COALESCE_TABLE_8125B_*` registers, currently zeroed at
  init. Bringing this up to a useful default is M6+ tuning work,
  not a gate.
- **CPU per Gbps comparisons against software-fallback baselines** —
  the perf gate calls for these but they're cheap measurements done
  after both M6 sub-features land.

## Pre-conditions before starting M6 implementation

1. M5 ASPM soak chain (`r8125-aspm-both.service` on guest) completes
   with both phases pass. Check via:
   ```
   ssh ... 'sudo systemctl show r8125-aspm-both -p ExecMainStatus --value'
   ```
   Value `0` = both 24h phases passed → safe to start M6.
2. No regressions in the 48-static-check CI suite.
3. Current `iperf3` baseline still matches docs (2.35 Gbps TSO,
   §6.3 invariant gap=0).

Once those three boxes are checked, M6 implementation can begin with
the MSI-X phase A (single vector + ISR_V2 register migration).
