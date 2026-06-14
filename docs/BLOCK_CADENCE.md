# `kernel::block` review cadence — calibration for M7

**Status (2026-05-29):** desk-research for M7 outbound-blocker #3 (see
[`PRE_RFC_DOSSIER.md`](PRE_RFC_DOSSIER.md) reading-list
checklist). Goal: extract from the `kernel::block` + `rnull` patch
history what a `kernel::net::*` series would realistically cost, so
the M7 dossier's Q2 (driver-first vs abstractions-first) is grounded
in observed cadence rather than guess.

## Why `kernel::block`

The dossier names it directly as the closest analogue. Among
mainline-landed Rust subsystems, `block::` is the most recent
large-surface area (DMA + queue + request lifecycle + bio) shipped
together with a real example user, and the maintainer process
discussion around it is the best-documented test-case for "can the
abstractions-first path work."

## Timeline

| Date | Event | Notes |
|---|---|---|
| 2023-03-02 | LSF/MM/BPF topic proposed | `[LSF/MM/BPF TOPIC] blk_mq rust bindings`, Hindborg → block@vger.kernel.org. Public floor-raising before any code. |
| 2023-05-03 | **RFC v1: 11 patches** | `[RFC PATCH 00/11] Rust null block driver`, Andreas Hindborg (Samsung) + Wedson Almeida Filho. Cover: radix tree + page alloc + `block::mq` + `bio` + module_params macro + spinlock padding + ForeignOwnable + the null driver + lock-irqsave. Posted to rust-for-linux + LKML in parallel. |
| 2023–2024 | Iteration | Multiple revisions visible on patchew + spinics; intermediate versions less individually citable but the v1→v2 jump is dramatic. |
| 2024-05-21 | **v2: 3 patches** | `[PATCH v2 0/3] Rust block device driver API and null block driver`. Series collapsed from 11 → 3 — most of the original v1 patches either landed individually as prerequisite series, or were carved out. Suggests the multi-prerequisite v1 wasn't a single-merge proposal but a "look at all the pieces" RFC. |
| 2024-06-01 | v3 | `Re: [PATCH v3 1/3] rust: block: introduce kernel::block::mq module` — reviewer responses visible. |
| 2024-08 | **Merged in v6.11-rc1** | Base abstractions + `rnull` stub merged *together* in a single window. Axboe applied. |
| 2025-03-27 | LWN process discussion | Axboe (block maintainer) reports the Rust integration "added almost no overhead at all"; fixes "often arrive before he's aware of problems." Conditional positive: he warns this model may not scale across all subsystems. |
| 2025-07-08 | Follow-up cleanup v2 | `[PATCH v2 12/14] rust: block: mq: fix spelling in a safety comment` — ongoing maintenance pattern visible. |
| 2026-02-16 | **"Complete" series: 79 patches** | `[PATCH 00/79] block: rnull: complete the rust null block driver` — 18 months *after* first merge, the long-tail work to take rnull from stub to feature-complete is still landing. New abstractions (`blk_mq_queue_map`, block queue feature flags) shipping in this wave. |

## Key calibration numbers

| Metric | Value | Implication |
|---|---|---|
| RFC → first merge | **~15 months** (May 2023 → Aug 2024) | Even for a "small simple" driver. |
| RFC → "complete" | **~33 months and counting** (May 2023 → Feb 2026 ongoing) | Abstractions are an ongoing maintenance commitment, not a one-shot. |
| Original contributors on RFC | **2** (Hindborg + Almeida Filho) | Solo author probably could not sustain the cadence over this timeline. The 2023 net_device stall (Tomonori solo) is consistent. |
| Patches in RFC vs first-merge series | **11 → 3** | The "lots of prerequisites stacked in one cover letter" shape doesn't reach merge — prerequisites land as their own series and the driver series shrinks to driver-only. |
| Patches in long-tail | **79** | After the stub lands, the real work begins. |
| Maintainer overhead reported | **"almost no overhead"** by block subsystem maintainer | Conditional on the pattern being executed well. |

## Patch-stack shape — what actually merged together

Per the v6.11-rc1 merge, "base abstractions" and the `rnull` stub
shipped in **the same merge window**, applied by Axboe to the block
tree. This is the precedent for our M7 Q2 framing: it is acceptable
for abstractions and the first real user to land together, not
sequentially.

Important nuance: the **prerequisites** (radix tree, page-alloc
helpers, ForeignOwnable, cache-line-padded spinlock, irqsave-aware
lock helper, module_params integer macro) did NOT land in the same
series. They were carved out and landed independently through their
respective trees over the ~15-month gap. Only after that scaffolding
was in place did the block-side series shrink to "block abstractions
+ driver = 3 patches" and merge cleanly.

**Implication for our cshim → rust/kernel/net/ path**: any Rust
prerequisite we depend on that isn't yet upstream (e.g., a richer
`pin_init` pattern, an `ARef`-style reference type, a percpu-aware
counter helper) would need to be carved out and land separately
*before* the netdev abstractions series itself can merge. The
maintainer cost of that pre-staging dominates the visible timeline.

## Design pivots across revisions

Public sources name the following pivots between RFC v1 and merge:

1. **`Folio` → `Page`** for memory backing. Folio was preferred
   upstream but the abstraction shape worked better against Page;
   the broader kernel-wide Folio conversion accommodated.
2. **`GenDisk` adopted typestate pattern**. Original RFC didn't
   encode the build/register/unregister phases at the type level;
   reviewer pressure forced the typestate split.
3. **`ARef` for request lifetime tracking**. Original RFC used
   reference counting through different mechanism; ARef became the
   accepted way to express "this handle outlives the queue."
4. **Pin-based `QueueData` references**. Aligned the queue handle
   with the pin_init / `pin_init!` pattern used elsewhere in
   kernel-Rust.

None of these were technical errors in v1 — they were
shape-mismatches with conventions that emerged or solidified during
the review window. **The cost wasn't bugs; it was alignment with a
moving target.**

## Maintainer-process signal (from LWN 1015409, Mar 2025)

Direct quotes / paraphrases worth carrying forward:

- **Jens Axboe (block maintainer)**: "Accepting Rust code in the
  block subsystem has added almost no overhead at all." When issues
  arise, "fixes often arrive before he's even aware of problems."
- **Cautionary qualifier from Axboe**: "This model may not scale as
  Rust adoption increases across subsystems."
- **David Hildenbrand**: concerned about "C interface changes
  rippling through unmaintained Rust code across separate trees."
- **Liam Howlett**: "merged changes breaking Rust code could
  disrupt CI builds and regression bisection" — "this will not
  scale."
- **Ted Ts'o**: needs "explicit expectations around testing and
  handling build breaks."

What this means for our M7 dossier: the block subsystem is the **most
positive** case study, and even there the maintainers' verbal
endorsement is "no overhead *so far*, but I'm worried about scale."
A netdev-Rust series will land into that same anxiety. Our Q3 (what
minimum surface area would make an RTL8125 driver RFC reviewable on
its own) is sharpened by this: maintainers want SMALL surface area,
not bottom-up rebuilds of subsystem state.

## What this calibrates for our M7 dossier

| Dossier claim | Refinement after this audit |
|---|---|
| "~950 LOC of new `rust/kernel/net/` content sketch" | **Verified plausible.** `kernel::block`'s shipped surface is in similar size class. |
| "Single series with rtl8125_rust as example user" (Q2 option) | **Precedented.** block::base + rnull stub shipped together in 6.11-rc1. |
| "6-12 months of patch iteration" (PREP.md §exit-b estimate) | **Was conservative; revise to 12-18+ months.** Real data: 15 months RFC → first merge for the simpler block case. Net is larger. |
| "Solo-author propensity to stall" (RUST_NETDEV_LANDSCAPE.md inferred from Tomonori 2023) | **Strongly supported.** block:: had Hindborg + Almeida Filho on the RFC; Tomonori was solo and stalled. |
| "Prerequisites in same series" (implicit assumption in our 4-trait sketch) | **Wrong.** Prerequisites carve out and land separately. The "single series with example user" pattern only works AFTER prerequisites are upstream. Our sketch would shrink from 5 traits → "the netdev-specific subset that doesn't already exist," with the rest landing as standalone series first. |

## Recommended dossier patches (not yet applied)

- §"What we'd want…" — qualify the "~950 LOC" estimate by noting
  that prerequisites carve out, so the visible single-series
  surface is smaller than the total Rust netdev abstraction work.
- §"Decision criteria" — add a row: "Are abstractions
  contributors plural?" — Yes-weighted toward (b), No-weighted
  toward (c). Solo-author paths stall.
- Reading-list checklist — mark #3 done with citation to this file.

## Cross-references

- [`PRE_RFC_DOSSIER.md`](PRE_RFC_DOSSIER.md) — outbound
  consultation this calibrates.
- [`RUST_NETDEV_LANDSCAPE.md`](RUST_NETDEV_LANDSCAPE.md) —
  in-flight netdev-Rust survey (no active series).
- [`PREP.md`](PREP.md) — three-exit decision matrix.
- LWN: [#930792](https://lwn.net/Articles/930792/) (RFC announcement),
  [#1015409](https://lwn.net/Articles/1015409/) (process discussion +
  Axboe perspective).
- lore: [RFC v1](https://lore.kernel.org/rust-for-linux/20230503090708.2524310-1-nmi@metaspace.dk/),
  [LSF/MM/BPF topic](https://lore.kernel.org/all/87y1ofj5tt.fsf@metaspace.dk/).
- LKML: [v2 series](https://patchew.org/linux/20240521140323.2960069-1-nmi@metaspace.dk/),
  [Feb 2026 "complete" 79-patch series](https://lkml.org/lkml/2026/2/16/127).
- `rust.docs.kernel.org/next/kernel/block/` — live mainline surface.
