# M7 pre-RFC consultation dossier — Rust RTL8125 driver

**Status (2026-05-29): draft. NOT YET POSTED.** This is the artifact
we would send to `netdev@vger.kernel.org` + `rust-for-linux@vger.kernel.org`
when (a) M5 close-out is signed off, (b) M6 perf vs upstream r8125
numbers are captured on Gateway bare-metal, and (c) one of us has
read the on-list r8169 + kernel-Rust threads end-to-end so we know
what's already been said.

`docs/M7_PREP.md` is the *research* dossier — the unfiltered
inventory and three-exit analysis. **This file** is the *outbound*
dossier — the one a maintainer would actually read. It is intentionally
short, has its claims linked to evidence in the tree, and ends with
the three specific questions we want answered.

## Quick read

We have a working out-of-tree Rust kernel driver for the Realtek
RTL8125B. It is a hybrid: ~5 000 lines of Rust core + ~1 250 lines
of audited C shim ("netdev_bridge") that fills the gap where
kernel-Rust 7.0 does not yet provide `net_device` / `napi_struct`
/ `sk_buff` abstractions. The cshim is *thin in LOC but thick in
contract*: it encodes 7 invariants over the kernel C baseline
that each prevent a real bug class (see §"Our deliberate
over-enforcements" below). The driver:

- Loads cleanly on both KVM (debug+Rust kernel with KASAN + lockdep
  + kmemleak + DMA_API_DEBUG) and Gateway bare-metal (Minisforum
  MS-A2, Ubuntu 26.04 + kernel-Rust 7.0.0).
- Reaches 2.35 Gbit/s line-rate single-stream TCP at MTU 1500
  (parity with in-tree r8169 on the same chip / same wire) and
  2.47 Gbit/s at MTU 9000.
- Survives 24 h ASPM-on idle soak + 12 h active-traffic soak +
  `rmmod` while iperf3 is mid-flight (122 143 xmit calls +
  43 889 MSI-X IRQs / 5 s, no `BUG`/`WARN`/page-fault).
- Currently exports **38 cshim symbols**; 30 of them wrap
  net-side kernel C that has no Rust abstraction upstream yet.

We are asking for guidance on the upstream pathway, not posting an
RFC driver. The three questions are at the bottom of this file.

## What's already in the tree we'd link

| Artifact | What it shows | Path |
|---|---|---|
| Plan + milestones | Gating, performance targets, M0a→M7 acceptance | [`docs/RTL8125_Rust_Driver_Implementation_Plan.md`](RTL8125_Rust_Driver_Implementation_Plan.md) |
| Unsafe-boundary contract | Where `unsafe` lives, allowlist, census | [`src/unsafe_boundary.rs`](../src/unsafe_boundary.rs), [`ci/.unsafe-allowlist`](../ci/.unsafe-allowlist), [`ci/.unsafe-census`](../ci/.unsafe-census) |
| sk_buff ownership contract | §6.3 of the plan, encoded as `DriverOwnedSkb` | [`src/skb.rs`](../src/skb.rs), [§6.3](RTL8125_Rust_Driver_Implementation_Plan.md#63-sk_buff-and-dma-ownership-at-the-ffi-boundary) |
| cshim contract | The 38-symbol bridge the driver consumes | [`src/netdev_bridge.h`](../src/netdev_bridge.h) |
| M5 close-out | Soak evidence + suspend/resume + ASPM L1 | [`docs/M5_CLOSEOUT.md`](M5_CLOSEOUT.md) |
| M6 #1 MSI-X | Before/after with rollback path | [`docs/perf/m6_msix_before_after.md`](perf/m6_msix_before_after.md) |
| M6 #2 jumbo | Before/after + TSO/CSUM auto-drop | [`docs/perf/m6_jumbo_before_after.md`](perf/m6_jumbo_before_after.md) |
| CI gates | 22 static gates that catch our recurring failure modes | [`ci/run_checks.sh`](../ci/run_checks.sh) |
| Performance discipline rubric | What we hold ourselves to | [`docs/RUST_STANDARDS.md`](RUST_STANDARDS.md) |

## The cshim, in one paragraph

The cshim exposes **38 `EXPORT_SYMBOL_GPL` functions** across
six `.c` files totaling **1 252 LOC** (caps documented in each file
header):

```
netdev_bridge.c                  360 LOC  19 exports   net_device + queue control
netdev_bridge_offload.c          264 LOC  10 exports   TX DMA + CSUM/TSO encoders
netdev_bridge_phy.c              207 LOC   4 exports   mdiobus + phy_device
netdev_bridge_rx_pool.c          149 LOC   4 exports   per-slot streaming DMA RX
netdev_bridge_counters.c          96 LOC   1 export    §6.3 percpu snapshot
netdev_bridge_ethtool.c           76 LOC   0 exports   strings/stats table only
```

Each symbol is one of:

| Bucket | Count | Underlying kernel C | Rust upstream? |
|---|---:|---|---|
| `net_device` lifecycle + flow control | 12 | `alloc_etherdev`, `register_netdev`, `netif_tx_{stop,wake}_queue`, `netif_carrier_{on,off}` | **none** |
| NAPI | 3 | `napi_schedule`, `napi_complete_done`, `netif_napi_add` | **none** |
| sk_buff | 8 | `netdev_alloc_skb`, `eth_type_trans`, `napi_gro_receive`, `napi_consume_skb`, `dev_kfree_skb_any`, `dma_map_single`, `skb_frag_dma_map`, the matching `dma_unmap_*` | **none** |
| Offload encoders | 4 | TSO/CSUM descriptor bits computed from `skb->csum_*` | **n/a** (chip-specific, would not abstract) |
| PHY | 4 | `mdiobus_alloc`, `phy_attach_direct`, `genphy_soft_reset`, `phy_start`, `phy_stop` | partial via [`rust/kernel/net/phy.rs`](https://elixir.bootlin.com/linux/v7.0/source/rust/kernel/net/phy.rs) |
| Streaming-DMA RX pool | 4 | `alloc_pages`, `dma_map_page`, `dma_sync_single_for_{cpu,device}` | yes via `kernel::dma` but the per-slot policy is ours |
| Counters | 1 | percpu reader | n/a |
| ethtool | 0 exports (Rust drives the table directly) | `ethtool_ops` | **none** |

The cshim does **not** contain chip logic. Every register touch,
every reset sequence, every descriptor decode is in Rust
([`src/hw.rs`](../src/hw.rs), [`src/mmio.rs`](../src/mmio.rs),
[`src/phy.rs`](../src/phy.rs)). The cshim is *only* the
adapter layer over kernel structs that don't have Rust
abstractions yet.

## Our deliberate over-enforcements vs kernel C

The cshim is *thin in LOC but thick in contract* — that's
deliberate. The audit in
[`M7_CSHIM_KERNEL_DIFF.md`](M7_CSHIM_KERNEL_DIFF.md) identified
**7 invariants we encode that kernel C permits relaxing**. Each
one prevents a real bug class we have either experienced in this
project or seen in r8169's history:

| # | Invariant we encode | Kernel C permits | Bug class prevented |
|---|---|---|---|
| 1 | Linear sk_buff ownership via `DriverOwnedSkb` — `#[must_use]`, no `Drop`, consume verbs only | `skb_get` / `skb_unref` multi-ref | Double-free + use-after-free on shared skbs |
| 2 | §6.3 disposition-counter invariant equation `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error` | No equivalent in kernel C drivers; stats are bumped arbitrarily | Drop attribution lost; postmortems can't tell whether a missing packet was queued, busied, or errored |
| 3 | `IrqMode` enum discriminant at the type level | Polymorphic runtime `pdev->msi_enabled` check | The **M6 #1 V2/legacy-ISR mix-up** that bit us during Phase A.2 — type-discrimination prevents reading legacy ISR after the chip has switched to V2 register layout |
| 4 | `NetdevHandle::shutdown()` ordering BEFORE `devres_release_all` enforced by `pci::Driver::unbind` | Driver convention + code review | The **#58 BAR-UAF** — `bridge_phy_stop` chasing a freed ioremap address; mechanical ordering fixed a class, not just an instance |
| 5 | RAII guards (`RxPoolGuard` / `IrqGuard` / `TxMapGuard`) with `Option<T>::take()` linear ownership | `goto cleanup_n:` labels | The "forgot to cleanup an intermediate state" class — observed in `r8169`'s history, and easy to mis-write in any C driver |
| 6 | Per-file `Hard cap: N LOC` markers on every cshim TU + CI gate | Soft ~1000-LOC convention | Reviewer fatigue on oversized files; abstraction drift |
| 7 | Idempotent free guards (`if (!cpu) return;`) on partial-allocation paths | Init/cleanup-symmetry convention | The "M-of-N succeeded, freeing the rest" rollback class |

The audit also verified **five places** where kernel C demands
something we appeared to relax — and found we satisfy each by
structural property (in particular the `napi_disable` race the
NAPI docs warn about, closed by our `netif_napi_del` ordering
before `KBox<NetdevState>` drop). No real bugs surfaced.

If we propose `kernel::net::*` abstractions, items #1, #2, #3, #4
become the concrete behavioral contracts of those abstractions.
Items #5–#7 are project-discipline that any in-tree Rust driver
would adopt.

## What we'd want, if we were proposing a minimal Rust netdev surface

Sketch ordered by dependency. Numbers are rough LOC for the
abstraction itself, not including doctest / kunit harnesses.

1. **`kernel::net::SkBuff`** (~200 LOC). Owning wrapper with safe
   accessors for the fields we actually touch:
   `data`/`len`/`data_len`/`nr_frags`/`csum_*`/`gso_*`/`protocol`
   /`ip_summed`/`headlen`. `Drop` calls `dev_kfree_skb_any`.
   `into_raw` / `from_raw` thread through FFI boundaries.
   `#[must_use]` for linear ownership. Mirrors what we already
   shipped privately as
   [`DriverOwnedSkb`](../src/skb.rs); we know the contract works
   because [`ci/check_skb_ownership.sh`](../ci/check_skb_ownership.sh)
   has caught two regressions during refactors.
2. **`kernel::net::NetDevice` + `NetDeviceOps`** (~400 LOC). A
   `pin_init` trait the way `kernel::pci::Driver` is structured,
   with `open` / `stop` / `start_xmit` / `get_stats64` / `change_mtu`
   / `fix_features` callbacks. Per-CPU stats integrate via
   `pcpu_sw_netstats`. `register_netdev` / `unregister_netdev` are
   devres-managed.
3. **`kernel::net::Napi`** (~150 LOC). `napi_struct` wrapper + a
   `Poll` trait the device implements; `schedule` / `complete_done`
   on the wrapper; safe `weight` / `budget` arithmetic.
4. **`kernel::net::ethtool`** (~200 LOC). `EthtoolOps` trait,
   `EthtoolStrings` type, `get_sset_count` / `get_strings`
   /`get_ethtool_stats` with compile-time-checked counter
   strings (we already do this in our cshim by hand-counting; a
   real abstraction could generate them from a `#[derive]`).

Total proposed Rust abstraction surface: **~950 LOC** in
`rust/kernel/net/`. That would let us delete ~600 of our 1 252
cshim LOC. The remainder — **offload encoders, RX-pool policy,
chip-specific lifecycle** — would stay in Rust + small chip-side
shim, which is the same shape every C netdev driver has.

**Caveat on the ~950 LOC figure**: per the `kernel::block` case
study ([`M7_BLOCK_CADENCE.md`](M7_BLOCK_CADENCE.md)), Rust kernel
abstractions reach merge in a "prerequisites land separately, then
the subsystem-specific patches collapse to a small final series"
shape. block::'s RFC was 11 patches; the series that actually
merged was 3, because most of v1's content (radix tree, page
allocator helpers, ForeignOwnable, cache-line padding, irqsave
locks) carved out and went through other trees first. Our 4-trait
sketch would similarly shrink to "the netdev-specific subset that
doesn't already exist elsewhere" once we identify which
prerequisites are needed.

## Decision criteria we'd use to choose (a)/(b)/(c)

| Criterion | Weighted toward (a) RFC driver | Weighted toward (b) abstractions first | Weighted toward (c) OOT |
|---|---|---|---|
| Is there active maintainer-led netdev-Rust work on-list? | yes ⇒ join it | yes ⇒ contribute to it | no ⇒ default |
| Is FUJITA Tomonori's PHY work the model? | only if explicitly asked | yes, replicate that pattern | n/a |
| Does the cshim represent novel abstraction proposals? | no — gap fillers only | **yes** — promote them | no |
| Bare-metal evidence Gateway clears the historical L1.x gate? | required | strengthens but not required | not required |
| Distribution timeline matters? | no (RFC = years) | no (RFC = years) | yes (OOT = today) |
| Are abstractions-side contributors plural? | n/a | **yes ⇒ feasible** | n/a — solo-author abstractions paths stall (`kernel::block` shipped with 2 RFC co-authors and reached merge; FUJITA Tomonori's 2023 net_device series was solo and stalled at v2) |

By the M6 close-out date this matrix selects (b) unless a netdev
maintainer says otherwise. The dossier is the way we ask them.

## The three questions

If a `netdev`/`rust-for-linux` maintainer reads this dossier, the
questions we want answered are:

> **Q1.** We have surveyed `lore.kernel.org/{netdev,rust-for-linux}`
> + LWN through 2026-05 and found **no active patch series**
> proposing Rust abstractions for `net_device` / `napi_struct` /
> `sk_buff`. FUJITA Tomonori's 2023 v2 series stalled and the
> only `rust/kernel/net/` content shipped in 7.1-rc5 is `phy/`.
> Survey details in `docs/M7_RUST_NETDEV_LANDSCAPE.md`.
> Is there in-progress work we missed — anything `block::`-style
> for netdev that hasn't reached the lists yet, or that's in an
> off-list branch you'd want us to align with?

> **Q2.** Tomonori's 2023 net_device series proposed the trait
> with a `dummy.c`-port as the example user; it stalled, plausibly
> because a dummy driver provides no design pressure on the
> abstraction shape. We have a real RTL8125B driver with
> bare-metal soak + perf evidence that exercises DMA, MSI-X,
> jumbo, TSO, ASPM, and `rmmod`-under-traffic — the kinds of
> stress that catch abstraction-design issues. Do you prefer
> packaging the same way the PHY series did Asix in v11
> (single series: abstractions Patches 1..N, rtl8125_rust as
> Patch N+1), or do you want the driver posted as a separate
> follow-up series only after the abstractions land?

> **Q3.** What's the minimum surface area you'd want to see before
> an RTL8125 driver RFC would be reviewable on its own merits — i.e.
> at what point does the cshim become small enough that a driver
> RFC isn't blocked on abstraction work? We can size our work to
> hit that bar.

We are not asking for a verdict on whether the driver itself is
worth merging. We are asking which of (a)/(b)/(c) is the
upstream-acceptable contribution path, *given* (b) is the
unconstrained-cost answer and (c) is the today-default.

## Background context (skip if you already know this)

### Why a Rust RTL8125 driver

`r8169` covers the chip family, including the 8125 variant, since
upstream merged `8125` IDs around 5.x. The driver is robust but the
chip family has a long history of ASPM L1.x lockup bugs (lkml
threads under `8169` between 2019 and 2024 cover at least four
distinct flavours). That history made the 8125 line a good
candidate for a Rust rewrite where the lockup-prone power-state
transitions can be expressed as type-checked state machines.

The driver is OOT today and will remain so until the M7 decision.

### Why a cshim at all

kernel-Rust 7.0 ships `kernel::pci::Driver`, `kernel::dma`,
`kernel::devres`, `kernel::block` and a partial `kernel::net::phy`.
It does **not** ship `net_device`, `napi_struct`, `sk_buff`, or
`ethtool_ops`. We considered three options:

1. Wait. Rejected — we wanted to validate the safety hypothesis
   on actual hardware, not in theory, and 8125-class chip wrangling
   is itself interesting research.
2. Inline the unsafety. Rejected — the unsafe surface would be
   ~3× larger and impossible to audit by file inspection. Our
   current `unsafe` census is 52 items
   ([`ci/.unsafe-census`](../ci/.unsafe-census)) and every one is
   reviewed against an allowlist
   ([`ci/.unsafe-allowlist`](../ci/.unsafe-allowlist)).
3. Build a small, documented C shim that wraps **only** the
   uncovered kernel C, and reject any chip logic from creeping in.
   This is what we did. The cshim header
   ([`src/netdev_bridge.h`](../src/netdev_bridge.h)) is the
   contract.

This decision is documented in the implementation plan at
[§5.2](RTL8125_Rust_Driver_Implementation_Plan.md#52-not-mainline-stable--use-a-c-shim-plan-to-migrate)
and [§6.1](RTL8125_Rust_Driver_Implementation_Plan.md#61-module-layout).
Neither the README nor the cover letter ever claims `#![forbid(unsafe_code)]`
for the binary as a whole — we claim `#![deny(unsafe_code)]` on the
Rust crate and *count* every unsafe item we accept at the FFI
boundary. The cshim is part of that count.

### Why bare-metal Gateway numbers, not KVM

KVM with VFIO passthrough is sufficient to validate the
unsafe-boundary contract under heavy fuzzing — the synthetic upstream
PCIe bridge advertises ASPM L0s only, so the historical L1.x lockup
gate the 8125 family is known for **cannot be exercised inside the
VM**. We added a second MS-A2 ("Gateway") to the project specifically
so M5/M6 acceptance numbers come from real silicon under real ASPM
states. The dual-environment narrative is in §1.3 of the plan.

### Provenance

The driver is AI-assisted. The plan's §9 documents the agent
orchestration, and every patch with assistance is annotated
`Assisted-by:` per kernel coding-assistant policy. CI rejects
`Assisted-by:` without a human `Signed-off-by:`
([`ci/check_dco_assistedby.sh`](../ci/check_dco_assistedby.sh)).

## What we do NOT want from this consultation

- A code review of the driver (the cshim is the right starting
  point — driver internals are downstream of the abstraction
  question).
- A merge decision on the OOT crate (we're not asking).
- A patch series in your queue right now (this is pre-RFC; if
  you say "post a real series" we'll do that, but we're not
  presupposing it).

## What's next, depending on the answer

| Answer | Our next move |
|---|---|
| Q1 = "yes, see series X" | Read X, rebase our cshim onto its API, post a comment thread asking how we can help. No driver RFC yet. |
| Q1 = "no", Q2 = "post abstractions first" | Cut a `kernel::net::SkBuff` series (smallest scope, lowest-risk per-symbol audit) as an RFC. Driver RFC follows after at least one of {SkBuff, NetDevice, Napi} lands. |
| Q1 = "no", Q2 = "driver-first with example user OK" | Cut a driver RFC linking back to this dossier; ship as a series including the proposed `kernel::net::*` modules as Patch 1..N before the driver patches. |
| Q1 = "no", Q2 unanswered | Stay OOT (exit c). Reassess at next LTS kernel. |

## Reading list before posting

Owner-checklist that must complete before this dossier goes to
the mailing list:

- [x] Search `lore.kernel.org/rust-for-linux` for
      `net_device`/`skb`/`napi` in 2025–2026 and read every
      thread end-to-end. **Done 2026-05-29**, results in
      [`M7_RUST_NETDEV_LANDSCAPE.md`](M7_RUST_NETDEV_LANDSCAPE.md):
      no active series; FUJITA Tomonori's 2023 v2 net_device
      proposal stalled, and `rust/kernel/net/` in 7.1-rc5 ships
      only `phy/`. Our Q1 is well-posed.
- [ ] Read FUJITA Tomonori's `rust/kernel/net/phy.rs` review
      thread + the rust-for-linux kunit harness patterns. The
      PHY series is the model; if Q2 lands on "abstractions
      first" we replicate its packaging.
- [x] Audit a recent kernel-block abstraction series for review
      cadence and maintainer-feedback shape. block:: landed
      most recently and is the closest analogue. **Done
      2026-05-29**, results in
      [`M7_BLOCK_CADENCE.md`](M7_BLOCK_CADENCE.md): 15-month
      RFC→merge, two-author RFC, 11→3 patch-stack collapse,
      Axboe verbal endorsement, scale-anxiety from other
      subsystem maintainers. Adjusts our timeline estimate
      upward (M7_PREP §exit-b) and confirms single-series-with-
      example-user precedent.
- [x] Diff our cshim contract (`src/netdev_bridge.h`) against
      the corresponding C kernel docs (`Documentation/networking/`
      + `include/linux/netdevice.h` lifecycle commentary).
      Anything we encode that the C side doesn't enforce is a
      candidate question to raise explicitly. **Done 2026-05-29**,
      results in [`M7_CSHIM_KERNEL_DIFF.md`](M7_CSHIM_KERNEL_DIFF.md):
      7 deliberate over-enforcements identified (with rationale
      + bug-class each prevents), 5 kernel-C demands verified
      satisfied (no real bugs found). The §6.3 invariant +
      `DriverOwnedSkb` linear ownership + #58 BAR-UAF teardown
      ordering are the headline raises.
- [ ] Confirm Gateway M5 24 h ASPM-on soak + 12 h KVM active
      soak both signed off and cited inline in this file.

Until each of those is checked, this file stays in-tree as a
draft.

## Cross-references

- `docs/M7_PREP.md` — internal research dossier this file
  derives from; do not link from the outbound message but keep
  reachable for our own reviewers.
- `docs/RTL8125_Rust_Driver_Implementation_Plan.md` §7 M7 — the
  authoritative plan section.
- `docs/M5_CLOSEOUT.md` — soak sign-off, cited inline above.
- `docs/perf/m6_msix_before_after.md`,
  `docs/perf/m6_jumbo_before_after.md` — M6 #1/#2 evidence.
- [`docs/perf/r8169_comparison.md`](perf/r8169_comparison.md) — the
  direct comparison that backs "parity with r8169". Captured
  KVM-only as of 2026-05-29; Gateway re-capture is the M7-cite
  source.
