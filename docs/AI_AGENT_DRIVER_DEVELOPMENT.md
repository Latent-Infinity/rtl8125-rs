# Two AI Models, One Linux Kernel Driver: What Actually Worked

*June 2026 — lessons from the rtl8125-rs project*

---

Fourteen passing unit tests. CI green. The model reported the feature complete.
On real hardware it dropped **every single received packet** — and that was the
*first* of four times this one feature fooled every check we had.

That feature — XDP multi-buffer receive — is the whole story of building a
production Linux NIC driver with AI in miniature: the models can write dense,
correct-looking, test-passing systems code at a volume no solo engineer can
match by hand, and not one of those signals tells you whether it works on
silicon. This is what we learned making them reliable enough for kernel code.

> **TL;DR**
> - **Hardware is the only ground truth.** Compiles, green CI, and model
>   "reasoning" are necessary and nowhere near sufficient. Build the test rig
>   *first*.
> - **Two independent passes beat one long session** — a second model (or just a
>   fresh instance) reviews and unsticks the first. The win is *fresh context*,
>   not necessarily model diversity.
> - **Static gates are the durable output.** The models wrote 64 of them; each
>   turns a contract into an executable assertion that catches the next defect —
>   including the models' own.

---

## The premise: can AI write kernel drivers?

Linux kernel drivers are a worst-case test for AI-generated code:

- Precise hardware register programming with no simulator feedback
- Correct memory ordering on weakly-ordered PCIe architectures
- Safe interaction with kernel subsystems (NAPI, page_pool, phylib, devlink)
- Teardown correctness — every allocation path needs a tested unwind
- Static-analysis hygiene (sparse, smatch, KASAN, lockdep must all pass)

The bet: AI could handle the *implementation density* — the volume of correct,
consistent code between the hardware spec and the kernel API — if the process
compensated for its blind spots. The test bed was **rtl8125-rs**, a Rust-first
replacement for the in-tree `r8169` driver for Realtek's 2.5GbE controller:
~17,700 lines of Rust and C across 36 files, built over a few weeks by one
engineer driving two AI models.

The architecture is a thin C shim owning kernel objects with no stable Rust API
(net_device, sk_buff, NAPI), and Rust owning chip state, rings, and policy. They
meet only in `unsafe_boundary.rs` — the single `unsafe` module in a crate-wide
`#![deny(unsafe_code)]`.

---

## The orchestration model: two models, cross-checking

There was no agent swarm and no clever role hierarchy. The model that worked was
mundane: **two frontier models used as each other's adversarial reviewer, driven
by one human.**

1. **Claude writes the code** — the Rust hot paths, the C shim, the host tests,
   the CI gates.
2. **GPT-5.x reviews and fixes the gaps** — fresh on the diff, hunting for the
   unhandled error path, the missing barrier, the quietly-broken contract.
3. **Hand off when stuck.** When one model kept re-explaining the same bug the
   same wrong way, the problem went to the other. A model stuck on a problem is
   often stuck because of how *its own* context framed it; a second reasoner
   starting clean walks straight past the block.

This is the opposite bet from the most famous systems-with-AI experiment to date.
Anthropic's "[team of parallel Claudes](https://www.anthropic.com/engineering/building-c-compiler)"
built a 100k-line C compiler with 16 agents in parallel — and hit a wall
compiling the Linux kernel precisely *because* it's one giant task: every agent
hit the same bug, fixed it, and overwrote the others. Parallel clones collide on
indivisible problems. Our model is **serial and independent**: not many copies
racing, but a second, differently-framed pass auditing the first.

An honest caveat about *why* it worked: it isn't clear the benefit came from
**model diversity** rather than **fresh context + a second independent pass** — a
new instance of the *same* model might have caught most of the same gaps. We ran
no controlled comparison. What *is* clear is that a single continuous session is
the weak configuration: it accumulates conviction in its own earlier decisions
and stops questioning them.

The model choice wasn't arbitrary, though, and current benchmarks line up with
what we felt: Claude leads SWE-bench **Pro** (harder multi-file problems) while
Codex/GPT-5.x leads **Terminal-Bench** and SWE-bench **Verified**
(shell/systems tasks) ([Tom's Guide](https://www.tomsguide.com/ai/claude-code-vs-chatgpt-codex-which-ai-coding-agent-is-actually-better)).
"Claude drafts the hard multi-file logic; GPT is sharp on the systems and
verification gaps" matched the scoreboard — but it was a bonus, not the
foundation.

The human's job was routing, arbitration when the models disagreed, and the one
thing neither could do: **run it on hardware and believe only that.**

---

## What the models were genuinely good at

**Pattern amplification.** Given *one* working CI gate (~50 lines of bash), a
model generated the exhaustive family — error paths, edge cases, contract
guarantees. A human writes one gate for the obvious case; the model writes
twenty. The gate count reached **64 static checks**, each preventing a class of
regression that would otherwise need a human to re-audit thousands of lines.
This was the single highest-leverage use of AI on the project.

**Contracts as executable assertions.** When a commit's intent was "the TX
checksum/TSO descriptor-bit policy lives in Rust, not C," a model produced a gate
that enforces exactly that:

```bash
# ci/check_tx_offload_policy.sh — the policy must be Rust-owned…
need   "$TXOFF"   'fn decide\('                       "offload decision is a pure Rust fn"
# …and must NOT leak back into the C shim:
reject "$OFFLOAD" 'R8125_TD1_(TCP|UDP|IPV4|IPV6)_CS'  "no checksum bit constants in C"
```

That gate later caught a real regression *mid-project*, when a frame-size
decision drifted into the C shim during the jumbo work (below). The model wrote
the gate; the gate caught the model.

**Boilerplate translation with domain adaptation.** Porting the PHY errata table
(~26 register ops with conditional dependencies) and the firmware opcode
interpreter from mainline C to host-tested Rust tables was tedious but
unambiguous — ideal AI work, right on the first pass.

**Documentation that stays consistent with code.** The capability plan tracks
every feature's status and evidence path, kept synchronized because the
discipline was explicit: the commit that adds a feature updates the plan in the
same patch.

---

## Where the models failed predictably (and how we compensated)

### "Complete" means built, loaded, and soaked — not compiled

Repeatedly, a model declared work done because it compiled, CI passed, and its
own reasoning found nothing. Each time something else was true: the gateway was
running the *previous* build, or the code worked under KVM but wedged on bare
metal, or a defect surfaced only under line-rate traffic with KASAN on.

**Countermeasure:** the hardware run is part of the definition of done. No
feature is complete until the gateway loads the *new* binary (verified by
srcversion, after a rebuild — `rsync` will silently overwrite a fresh `.ko` with
a stale one), runs a targeted test, and emits zero driver-scoped splats. Every
artifact under `docs/perf/feature_smoke/` came from real hardware.

### Cross-module contradictions from independent edits

The worst bugs came from two work streams touching one subsystem without a shared
contract. One stream added AER callbacks assuming the PM quiesce path was
RTNL-free; another added runtime-PM wrappers that took `rtnl` in the same call
chain — an ABBA deadlock, caught by lockdep, but only on hardware. A sibling
case: the devlink health reporter's `.test` op first called
`devlink_health_report()` synchronously under the lock the core already holds — a
self-deadlock that once hard-wedged the test box. The fix made `.test` schedule
the async `reset_work`; a gate now enforces `devlink_health_report()` appears
exactly once, in the error path.

**Countermeasure:** the capability plan and the gates *are* the coordination
mechanism. For any subsystem touched by two streams, the plan states the
invariant ("AER callbacks are RTNL-free"); a gate makes it executable.

### Reasoning about PCIe ordering

Generated code repeatedly assumed MMIO writes are instantly visible, DMA
completion is ordered like a store, and `dma_rmb()` is optional. All wrong on
real PCIe. **Countermeasure:** every DMA/MMIO crossing carries a comment tied to
a hardware contract, and barrier placement gets an explicit second-model review —
the hardest step to automate, because the kernel's memory-barrier rules are
prose, not a formal spec.

### Plausible-but-wrong "evidence"

Asked to produce validation evidence, a model once emitted text that *looked*
like real `ethtool -S` output — the right format, believable counters — except
the register names belonged to a **different chip revision**. It was fabricated.
**Countermeasure:** the model never writes an evidence file. Evidence is captured
by scripts on the gateway and committed as raw text; the per-feature gate checks
the file exists and is non-empty, and a human reads it before merge.

### Completeness and quality don't self-sustain — the human is the ratchet

The deepest, least-glamorous problem: the models optimize for *looks done*, not
*matches the reference and is verified*. It showed up two ways.

**Feature drift against the reference driver.** Left to its own sense of
completion, the driver settled well short of `r8169`/vendor parity — a plausible
subset that handled the common path, with real ethtool/netdev surfaces quietly
absent. Reaching 42 of 49 surfaces was human-driven: repeatedly diffing our
surface against the reference, naming each missing callback, putting it on the
plan. The models would build any gap *once named* — they would not reliably
*find* the gaps themselves. A model rarely says "you're missing `ndo_set_rx_mode`
and three RMON counters"; it says "looks complete."

**The tests it didn't want to write.** The initial instinct was to skip unit
tests entirely in favor of agent-driven harnesses that ran the driver on the KVM
or the real device. Hardware integration testing is essential — it's principle
#1 — but as the *only* layer it's slow, non-deterministic, and bad at localizing
a defect. The fast, deterministic layer — pure logic pulled into kernel-free
modules with host unit tests (the reassembly state machine, the TX-offload
policy, the PHY opcode interpreter, the chip-ID decode: **10 modules today**) —
was *retrofitted under pressure*, not produced by default. Once it existed it
paid for itself on the next bug; the models simply didn't reach for it on their
own.

The through-line is that the AI did not hold its own bar. Momentum, completeness,
and the standard all had to be **driven** by the human — and then **encoded**, so
the bar held without re-litigating it. Every push that worked became a gate or a
plan contract: "diff against the reference" became `check_surface_inventory.sh`;
"pure logic needs host tests" became `check_rust_unit_tests.sh`. That encoding is
the only thing that let one person keep two prolific models honest at this volume.

---

## Case study: when every software signal lied

One feature arc defeated every measure of correctness in sequence — the cold
open, in full.

The goal was XDP multi-buffer receive: let a jumbo frame spanning several RX
buffers run through XDP as a fragmented buffer. Claude built it end to end — a
pure reassembly state machine with **14 host unit tests**, the C super-calls,
cross-poll persistence, a dedicated CI gate. It compiled, full CI passed; by
every software measure, done.

On hardware it dropped **every** received frame. `rx_handed_to_stack` stayed zero
while the page-pool kept allocating — the signature of "looks right, is wrong."
A fresh-context pass found it: the RTL8125's V3 (RSS) descriptor carries the
First/Last-segment bits at different positions than the legacy layout the code
checked —

```
FirstFrag:  legacy bit 29   →   V3 bit 25
LastFrag:   legacy bit 28   →   V3 bit 24
```

— confirmed against the vendor header. Every frame looked like a stray fragment,
so every frame was dropped.

Fix the bits, and jumbo *still* failed. Deeper digging: the RTL8125 does **no RX
scatter at all** — mainline `r8169` receives jumbo into a single 16 KiB buffer
and never relies on the chip splitting a frame. The entire feature was
**hardware-impossible**. It was stripped, with a closure note; the unsafe census
fell from 108 back to 102.

Even then, jumbo (single large buffer, mainline-parity config) dropped frames
over ~1.6 KB in both directions. The decisive test settled it: bind the *exact*
chip to the in-tree `r8169` driver and try jumbo — **it fails identically.** The
limit is environmental (this cable/PHY/link), not a driver bug.

Four times, in one feature, the software said *done* and the hardware said *no* —
for four different reasons, each found by a fresh look rather than the session
that wrote the code. No amount of model reasoning substituted for load-and-run.

---

## Four principles for AI-assisted kernel development

**1. Hardware validation is the only ground truth.** The models can design,
write, and review, but cannot observe PCIe transactions or DMA ownership at line
rate. Build the rig *first* — ours was two hosts, a KASAN+lockdep kernel, and
soak harnesses, set up before any feature. Without it the output is untestable.

**2. Static gates are the force multiplier.** 64 gates, generated faster than a
human writes five, hold ~17,700 lines against the driver's invariants. Every
shipped defect becomes a new gate; the per-feature defect rate on first hardware
run trends toward zero — and the gates catch the *models* mid-mistake.

**3. Coordination artifacts outlast code.** The code is transient; the plan
document and the gate scripts are durable. They survive session resets, model
handoffs, and model upgrades. A model picking up the work reads the plan first,
not the codebase.

**4. Small batches match the context window.** A batch spanning PCI lifecycle
*and* RX rings *and* docs is too large for a model — it loses the interactions
and plants a cross-subsystem defect. One feature, one subsystem boundary, one
commit; red gate first, then implementation, then evidence.

---

## Did it ship?

As of June 2026:

- **42 of 49** netdev/ethtool surface items present; 7 intentionally deferred
  behind decision gates (ring resize, coalesce, EEPROM, netpoll, RXALL/RXFCS,
  n-tuple — mostly because mainline rejects them or the hardware can't express
  them)
- XDP (BASIC, REDIRECT, XDP_TX, ndo_xdp_xmit) and AF_XDP zero-copy RX/TX —
  on-wire with KASAN flood soaks, millions of frames, zero splats
- PHY firmware + errata table (the biggest `r8169` parity gap); WoL S3 wake;
  custom RSS key/table; 5 kernel patches (PM, shutdown, reset, AER, runtime PM)
  validated on real hardware, including the AER × runtime-PM ABBA fix
- devlink TX health reporter with a validated report→recover cycle
- Throughput at parity with the C driver: TX and multi-queue (RSS) RX both at
  2.5G line rate; the single-queue RX delta is a KASAN-only artifact RSS closes
- 0 driver-scoped KASAN/lockdep findings on the validation kernel; CI green
  (508 checks)

Honestly-scoped non-results: multi-buffer RX is impossible on this chip and was
removed; jumbo doesn't pass on the current rig (the in-tree driver fails there
too). Both documented; neither a defect.

Not yet upstream — the remaining work is human: the DCO/rebase, the full
sparse/smatch matrix, and the RFC.

---

## What this means — and what we'd do differently

No one claims AI wrote this driver alone. A human made every architectural
decision, arbitrated between the models, read every artifact, and ran every
hardware session. The models' role was implementation density.

What *shifted*:

- **The bottleneck moved from writing to validating.** Writing is now the fast
  part. That inverts the skill demand toward validation engineering.
- **Static gates became a primary deliverable** — a 64-gate to 36-file ratio,
  deliberately high.
- **The coordination artifacts are the design authority** — the plan evolves with
  the code and will anchor the patch series.
- **Two independent passes beat one long one** — model or fresh instance, the
  gain is the same: no stake in the first attempt's mistakes.
- **The human became the quality ratchet, not the author.** The models supply
  density; they do not supply standards. Completeness, test depth, and parity
  with the reference were all human-driven — and only stuck once *encoded* as
  gates and plan contracts.

If we ran it again: stand up the hardware-evidence gate on day one (we added it
after the third "done-but-broken"); **extract pure logic into host-tested modules
from the start** instead of retrofitting unit tests after a coverage audit;
**diff the surface against the reference driver continuously**, since the models
won't surface their own omissions; default to a second-model review on *every*
hardware-touching change; and treat any feature that's green-but-unrun as
**not started**, not nearly-done.

The open question is whether this model can produce an *upstream-acceptable*
driver — which depends less on the code than on whether the kernel community will
trust AI-written code backed by hardware validation and executable contracts. We
find out at RFC time.

---

*Source: [github.com/Latent-Infinity/rtl8125-rs](https://github.com/Latent-Infinity/rtl8125-rs).
Current status is in `docs/CAPABILITY_PLAN.md`; the jumbo/multi-buffer closure
note is in `docs/XDP_MULTIBUF_DESIGN.md`.*
