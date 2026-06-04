# Lessons learned — rtl8125-rs

This document captures practical lessons from the driver work to preserve context for the next effort and to keep future changes aligned with the project’s reliability bar.

## Why this exists

The driver has moved from research prototype to “readying for upstream review.” We now have enough evidence, regressions captured, and fixes merged that the team’s hard lessons should be turned into reusable constraints for the next Rust driver project.

## Core outcome

As of 2026-06-04, most critical classes of regressions are addressed:

- Probe-time stack overflow and teardown path hazards are fixed (`8d30e0f`).
- Descriptor ownership and ownership rollback paths are much stricter (`69bc442`).
- RX skb construction/sync paths are safer and aligned to actual DMA-visible frame length (`c8f0ef0`, `ccd7da0`).
- RX zero-copy refill ordering and pool invariants are fixed and continuously checked (`8236aed`).
- The cshim surface is cleaner and the exported symbol budget is controlled (`468d9d6`, `89e5401`, `6b74c01`).

## Standards-intent vs implementation check

The current implementation should continue to treat:

- `docs/RUST_STANDARDS.md` as the non-negotiable contract.
- `docs/UPSTREAM_REVIEW.md` as the external audience contract.
- `docs/COMMIT_POLICY.md` and `docs/FAILURE_MODES.md` as behavior and release guardrails.

Any new work should pass back into this matrix by mapping each change to one of the standards sections and adding test evidence.

## Lessons that matter

### 1) Stack safety is architecture, not cosmetics

Issue fixed: the bare-metal probe stack overflow.

- Root issue: large state was allocated on stack at probe time.
- Fix: move ownership-heavy state into heap via `KBox::init` and explicit heap lifecycle.
- Why it matters: this is not optimization; it is correctness on constrained kernel stacks.
- New rule for next drivers: avoid stack allocation of large Rust composite states in probe/remove/IRQ code; use explicit pinned heap storage plus ownership guards.

### 2) Teardown order must be encoded in ownership and explicitly tested

Issue fixed: shutdown/use-after-free risk when `remove` and Drop interacted.

- Root issue: teardown steps could run in non-deterministic order across failure branches.
- Fix: explicit `unbind` sequencing plus idempotent guards and explicit netdev-unregister-before-BAR release.
- New rule: all release paths must converge through one cleanup contract (same resource transitions in every path), and every “must be once” action must guard itself.

### 3) Descriptor ownership and rollback is a correctness boundary

Issue fixed: descriptor map/sync lifecycle and stale-state bugs under contention.

- Root issue: ownership transfer between Rust wrappers and C bridge was too loosely constrained.
- Fixes introduced in `69bc442`, `c8f0ef0`, and follow-on edits: stricter ownership wrappers, rollback helpers, and clearer descriptor-shape checks.
- New rule: every mapping/unmapping path must be mirrored in drop/abort logic and covered by a static check.

### 4) DMA + ownership ordering is not optional

Issue fixed: ordering issues around OWN bit handoff, RX sync length, and refill sequencing.

- Root issue: weakly ordered architecture safety was not fully encoded in barriers and post-processing order.
- Fixes: `dma_rmb()/dma_wmb()` checks, `desc` read ordering, and alignment of sync length to frame length.
- New rule: any boundary crossing with DMA must have both memory barrier evidence and a reviewable comment tied to hardware contract text or source cross-check.

### 5) Cross-boundary calls are real cost at line-rate

Issue observed: FFI path pressure in RX hot path reduced by batching and merging functions.

- Root issue: 5–7 per-packet cshim calls in RX processing hurt headroom, especially on bare-metal.
- Fix path: removed redundant wrappers, merged RX accounting with delivery, and prepared super-call candidates in `RX_OPTIMIZATION_CANDIDATES.md`.
- New rule: optimize boundary crossings after correctness is locked, then track with A/B perf evidence on bare metal first.

### 6) Static gates beat “manual review memory”

Issue addressed: regressions reappeared across multiple milestones when assumptions changed.

- Root issue: assumptions were being carried as comments without enforcement.
- Fix: hardening checks (`check_*` scripts), cache padding and ordering gates, and explicit ownership/disposition checks.
- New rule: if a rule is important enough to mention in docs, make it machine-enforced where feasible.

### 7) KVM-only evidence can mask physical defects

Issue observed: perf and soak behavior were not identical between KVM and bare-metal.

- Root issue: ASPM and PCIe power-state behavior is partially synthetic under VFIO/KVM.
- Fix: dual-host strategy with a real bare-metal Gateway for ASPM/idle/load edge cases.
- New rule: for NIC/driver work, every major behavior claim must include bare-metal evidence for power-management or L1/L0s-sensitive paths.

## Anti-patterns to avoid in the next effort

1. **No large stack structs in probe/open paths**: move to heap-initialized state.
2. **No “best effort” cleanup**: every RAII or Drop path must be idempotent and safe for repeated invocation.
3. **No ownership leaks across FFI boundaries**: `Skb`/DMA ownership must be represented in one domain at a time.
4. **No unreviewed exported C symbols**: every cshim export should have a purpose mapped to a Rust gap or legacy driver parity requirement.
5. **No performance claims without raw and reproducible perf evidence**.
6. **No “docs-first” without CI-first**: if it should not regress, it should fail a gate.

## What remains open (as of this cycle)

- Full kernel `pm_ops` for `suspend`/`resume` remains pending in `docs/UPSTREAM_REVIEW.md`.
- Upstream-maintainer confidence on shim strategy remains dependent on netdev feedback path (`M7_PREP.md`).
- Sparse/smatch runs are pending on analyzer-equipped hosts for CI completeness.
- Formal DCO rebase clean still required before upstream submission.

## Reuse plan for next project

Use this file as the canonical exception log:

- Every time a regression occurs, add a short entry: symptom, root cause, commit/fix, gate added.
- If a fix cannot be fully enforced by static checks, create a dedicated harness for it.
- Re-run the lessons check at each milestone before merging any hot-path work.
