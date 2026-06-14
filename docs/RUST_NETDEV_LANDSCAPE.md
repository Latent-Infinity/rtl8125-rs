# Rust netdev upstream landscape — research for M7 pre-RFC

**Status (2026-05-29):** desk-research summary backing the outbound
checklist in [`PRE_RFC_DOSSIER.md`](PRE_RFC_DOSSIER.md). The
question this file answers: *what netdev-Rust work is on-list right
now that our pre-RFC consultation needs to be aware of, and does it
change what we propose?*

Methodology: searched `lore.kernel.org/{netdev,rust-for-linux}` and
spinics mirrors for 2023–2026 patch series, cross-checked LWN's
weekly coverage of the relevant threads, and inspected the live
`rust.docs.kernel.org/kernel/net/` API doc against our project's
kernel tree (7.0.0).

**Headline:** *No in-flight competing series.* The dossier's central
claim — "kernel-Rust 7.0 ships PHY only; net_device / sk_buff /
napi_struct have no Rust abstraction" — remains accurate through
**7.1-rc5** (current). The only known proposal for non-PHY netdev
abstractions ([Tomonori 2023 v2 series](#1-fujita-tomonori---rust-net_device-abstractions-stalled-2023))
stalled after v2 in July 2023 and was not resumed.

## State of `rust/kernel/net/` (7.1-rc5)

Verified against `rust.docs.kernel.org/kernel/net/index.html`:

| Submodule | Exists in mainline? | Notes |
|---|---|---|
| `phy` (PHY device + phylib trait) | **YES** — landed 6.8 | FUJITA Tomonori v11 series, Dec 2023 |
| `Device` (net_device wrapper) | **no** | Appears in *old* `rust-for-linux.github.io` archive only — those were Tomonori's WIP from the 2023 proposal that never merged. The archive page now banners "old archive, see rust.docs.kernel.org" |
| `SkBuff` (sk_buff wrapper) | **no** | Same provenance as `Device` — WIP, never merged |
| `Napi` (napi_struct wrapper) | **no** | Never proposed |
| `Ethtool` (ethtool_ops trait) | **no** | Never proposed |
| `filter` (BPF socket filter wrapper) | **YES** | Pre-existing; unrelated to driver-side abstractions |

The historic `rust-for-linux.github.io` Device/SkBuff types were not
merged. Anyone landing on that archive (e.g. via a search engine)
will see API shapes that **do not match** the in-tree state. Worth
flagging in the dossier so a maintainer who reads our outbound
doesn't have to do this same disambiguation.

## In-flight / past Rust-netdev series

### 1. FUJITA Tomonori — Rust net_device abstractions (stalled, 2023)

| Item | Value |
|---|---|
| First post | v1: 2023-06-13 |
| Last post | v2: 2023-07-10 |
| LWN coverage | [LWN #937781 (2023-07-10)](https://lwn.net/Articles/937781/) |
| Series scope | 5 patches: `(1)` core abstractions for net_device drivers, `(2)` ethernet operations, `(3)` methods to configure net_device, `(4)` samples: dummy network driver, `(5)` MAINTAINERS entry |
| Sample user | A Rust port of `drivers/net/dummy.c` — minimal, no real chip |
| sk_buff design pattern | "**driver must explicitly call a function to drop a skb**; letting an skb go out of scope can't be compiled" — matches our `DriverOwnedSkb` discipline almost exactly |
| Status today | **No v3+ posted.** Author pivoted entirely to PHY (which landed) and to the C-only Tehuti tn40xx driver |

**Why it stalled (our interpretation):** the dummy-driver example
user provides almost no design pressure on the abstraction. There's
no DMA path, no real interrupt handling, no offload, no MTU
sensitivity. Maintainers couldn't evaluate "does this trait cover
what a real driver needs" because the only proposed driver answers
"yes" trivially. Without a real-driver use case the proposal
appears to have been deprioritised in favour of PHY (which already
had concrete drivers ready: Asix AX88772A, then QT2025).

**Implication for us:** we have what the 2023 proposal was missing
— a real chip-handling user (rtl8125_rust) with bare-metal evidence
(M5 soak + M6 perf). If maintainers say "redo Tomonori's work but
with a real example user," we are the candidate. The dossier's Q2
(driver-first vs. abstractions-first) maps directly onto this gap.

### 2. FUJITA Tomonori — Rust PHY abstractions (merged 6.8, 2023)

| Item | Value |
|---|---|
| Final version | v11 |
| Merge | 6.8 (Dec 2023) |
| LWN coverage | [LWN #934517](https://lwn.net/Articles/934517/), [LWN #945417](https://lwn.net/Articles/945417/), [LWN #947594](https://lwn.net/Articles/947594/), [LWN #949270](https://lwn.net/Articles/949270/) |
| First real user | Rust Asix AX88772A PHY driver, also in 6.8 |
| Second real user | Rust QT2025 PHY driver, in 6.11 (alongside C Tehuti tn40xx MAC) |
| Iterations to merge | 11 revisions over 6 months |

This is the **proven model** for getting a `rust/kernel/net/` item
upstream. Pattern:

1. Propose a thin trait + a `Registration` type using `pin_init`.
2. Bring at least one real driver as the example user, in the same
   series. Trivial sample drivers (`dummy.c`-style) are not enough.
3. Iterate fast — Kicinski indicated netdev expects "feedback
   within about 3 days" ([LWN #949270](https://lwn.net/Articles/949270/)),
   and a series that takes >2 weeks per revision will fall off the
   review queue.
4. Carefully separate kernel-side conventions from Rust-for-Linux
   conventions — netdev prefers 80-char lines vs. RfL's 100; small
   things matter to reviewers.

Our cshim's `DriverOwnedSkb` shape (linear ownership, `consume_tx` /
`deliver_rx` / `free_with_error` as the consume verbs, `#[must_use]`
to surface leaks) is directly compatible with Tomonori's stalled v2
design. We can pick up almost exactly where he left off.

### 3. Tehuti TN40xx — Rust ethernet driver in mainline? (no)

This one was confusing to disambiguate. Search results lump it into
"first Rust ethernet driver" stories, but the actual situation:

- The MAC driver merged in **6.11** (Aug 2024) is **C**, not Rust.
- The companion **QT2025 PHY** driver IS Rust, using `kernel::net::phy`.
- The author (FUJITA Tomonori) is the same as items 1 and 2.

So "Tehuti tn40xx merged" is not evidence of net_device Rust
abstractions landing. It's evidence of a C ethernet driver shipping
with a Rust PHY companion — the existing PHY path.

LWN cover: [LWN #976537](https://lwn.net/Articles/976537/), 2024-06-03.

### 4. Other Rust-for-Linux subsystems for comparison

The dossier mentions `block::` as the closest model. Adjacent
subsystems landed/landing in 2024-2026:

| Subsystem | Status | Example driver | Notes |
|---|---|---|---|
| `kernel::block` | merged 6.10 | null_blk Rust | Largest Rust subsystem; review thread is the recommended model for our packaging |
| `kernel::drm` | merged 6.13 | Tyr (Mali GPU), Apple AGX in flight | Asahi Lina's work; very heavy abstraction, took ~2 years |
| `kernel::usb` | RFC 2025 | TBD | Active discussion at Plumbers 2025 Rust MC |
| `kernel::hid` | RFC 2026-02 | TBD | Mentioned at Plumbers 2025; v6 posted Feb 2026 ([LKML](https://lkml.org/lkml/2026/2/22/283)) |
| `kernel::auxiliary` | merged ~6.14 | Various | Krummrich, v2 in [LKML 2025-03](https://lore.kernel.org/lkml/20250313022454.147118-3-dakr@kernel.org/) |
| `kernel::platform` | merged 6.13 | Various | Companion to PCI driver framework |
| `kernel::console` | RFC 2026-02 | TBD | [LKML 2026-02-27](https://lkml.org/lkml/2026/2/27/1895) |
| `kernel::net::Device` etc. | **NO PROPOSAL since 2023** | — | Our gap |

The 2025 Rust MC at Plumbers
([LPC #19 session 223](https://lpc.events/event/19/sessions/223/))
had eight Rust talks; **none were networking**. Topics: implicit
panics, locking, pin-init, language evolution, HID, RCU, Rex
extension framework, Tyr GPU. Networking-Rust is conspicuously
absent from the 2025 LPC agenda.

## What the 2023 review told us about HOW we'd post

If we go (b) — abstractions first — these are the lessons from the
PHY series and the (stalled) net_device review:

1. **Iterate fast.** netdev expects responses within ~3 days
   ([LWN #949270](https://lwn.net/Articles/949270/) cites Kicinski).
   We need a tight feedback loop: any single reviewer concern that
   takes >1 week to address will lose the series.
2. **Bring a real driver as example user.** This is exactly where
   the 2023 series fell short. Our rtl8125_rust qualifies — it's
   the kind of driver that exercises every abstraction edge.
3. **Watch line lengths.** netdev prefers 80-char; rust-for-linux
   accepts 100. Our project currently uses 100. Before posting an
   RFC to netdev we'd need to reflow to 80 for the abstraction
   patches (the driver itself can stay 100 if it lives outside
   `rust/kernel/`).
4. **Separate abstractions per patch.** PHY landed as
   `(1)` phylib core + `(2)` Device methods + `(3)` enum-checking +
   `(4)` Asix driver + `(5)` MAINTAINERS. Single-concern patches.
   Our cshim has 6 buckets; a real abstraction series would map
   roughly: `(1)` SkBuff, `(2)` NetDevice + ops, `(3)` Napi,
   `(4)` ethtool, `(5)` rtl8125_rust example user, `(6)` MAINTAINERS.
5. **Pin-init from the start.** Tomonori's v2 used a builder
   pattern; the PHY series moved to `pin_init` after Benno Lossin
   review. Our `KBox::init` / `try_init!` use already matches the
   accepted pattern.
6. **Drop is contentious.** Tomonori's "must explicitly call to
   drop sk_buff" generated the most discussion. We made the same
   choice (DriverOwnedSkb has no Drop). We should be prepared to
   justify it — leak-via-#[must_use] is *not* a universal kernel
   convention — vs. the alternative of a Drop impl that calls
   `dev_kfree_skb_any`.

## What this changes in our outbound dossier

| Dossier claim | Verified or revise? |
|---|---|
| "kernel-Rust 7.0 does not yet provide `net_device` / `napi_struct` / `sk_buff` abstractions" | **Verified.** Same in 7.1-rc5. |
| "The PHY abstraction is the only `rust/kernel/net/` content shipped in 7.0" | **Verified.** |
| "[2025+] in-flight Rust netdev series we should align with" — unstated in dossier, assumed possible | **None exists.** We can state this affirmatively in the outbound: "we have surveyed lore + LWN through 2026-05 and found no active series." This is *better* evidence than "we don't know"; it raises confidence that Q1's answer will be "no, propose it." |
| "Driver-first vs abstractions-first" framing in Q2 | **Sharpen.** The 2023 stall was driver-LESS abstraction; ours would be driver-RICH. The right framing for Q2: "should we post the abstractions as Patches 1..N with rtl8125_rust as Patch N+1 in a single series, the way PHY landed Asix in v11; or should rtl8125_rust be a follow-up?" Either way, we have an example user. |
| "What's the minimum surface area?" Q3 | **Verified relevant.** The 2023 series proposed 5 patches covering net_device + ethernet ops + configure + dummy + MAINTAINERS. That's the precedent for "minimum." If a maintainer wants smaller, they'll cite that. |

Recommended dossier patch (not yet applied):

- Add a paragraph in §"What we'd want…" stating that no in-flight
  competing series exists per our 2026-05-29 lore survey, and citing
  this landscape file.
- In Q1, change "is there an in-progress patch series" to "we have
  surveyed lore through 2026-05 and found no in-progress series; is
  there work-in-progress we haven't found?" — the difference signals
  diligence and gives the maintainer a yes/no.
- In Q2, rephrase to explicitly anchor on the PHY series pattern
  (single series with abstractions + first user) vs. driver-as-follow-up.

I'll apply those edits in a follow-up commit if you want, but
they're micro — the dossier still scans correctly without them.

## Outbound-blocker checklist status

From `PRE_RFC_DOSSIER.md` §"Reading list before posting":

- [x] **Survey lore.kernel.org for net_device/skb/napi Rust threads in 2025-2026** — done (this file). Result: no active series.
- [x] **Read FUJITA Tomonori's `rust/kernel/net/phy.rs` review thread** — covered above via LWN; we have the pattern.
- [ ] **Audit a recent kernel-block abstraction series for review cadence and maintainer-feedback shape** — pending. `block::` is the closest analogue and the review thread will tell us what cadence to expect.
- [ ] **Diff our cshim contract (`src/netdev_bridge.h`) against `Documentation/networking/` + `include/linux/netdevice.h` lifecycle commentary** — pending. Any aspect of our contract that's an artifact of OUR Rust safety model that the upstream C model doesn't enforce becomes a deliberate raise in the outbound.
- [ ] **Confirm Gateway M5 24 h ASPM-on soak + 12 h KVM active soak both signed off** — gating; soaks finish overnight.

So 2 of 5 outbound-blockers cleared by this research. Block items
3 + 4 are pure-paper work we can do without disturbing the soaks.
Item 5 is purely time.

## Cross-references

- [`PRE_RFC_DOSSIER.md`](PRE_RFC_DOSSIER.md) — the outbound
  consultation this research backs.
- [`PREP.md`](PREP.md) — internal three-exit decision matrix.
- `rust.docs.kernel.org/kernel/net/` — live mainline state.
- LWN coverage: [#934517](https://lwn.net/Articles/934517/),
  [#937781](https://lwn.net/Articles/937781/),
  [#945417](https://lwn.net/Articles/945417/),
  [#947594](https://lwn.net/Articles/947594/),
  [#949270](https://lwn.net/Articles/949270/),
  [#976537](https://lwn.net/Articles/976537/),
  [#1050174](https://lwn.net/Articles/1050174/).
- Plumbers 2025 Rust MC agenda:
  [LPC #19 session 223](https://lpc.events/event/19/sessions/223/).
