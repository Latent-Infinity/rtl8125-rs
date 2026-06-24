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
- Upstream-maintainer confidence on shim strategy remains dependent on netdev feedback path (`PREP.md`).
- Sparse/smatch runs are pending on analyzer-equipped hosts for CI completeness.
- Formal DCO rebase clean still required before upstream submission.

## Reuse plan for next project

Use this file as the canonical exception log:

- Every time a regression occurs, add a short entry: symptom, root cause, commit/fix, gate added.
- If a fix cannot be fully enforced by static checks, create a dedicated harness for it.
- Re-run the lessons check at each milestone before merging any hot-path work.

## 2026-06-07 — RXHASH/V3, UDP-TX, and process lessons

- **V2/MSI-X needs ≥22 vectors on RTL8125B; otherwise use the legacy combined
  ISR.** The V2 per-queue surface routes each source to MSI-X entry == its bit
  position (RX Q0→0, **TX Q0→16**, LINKCHG→21). Enabling V2 with one vector
  delivered RX but silently dropped TX completions → unidirectional UDP TX
  wedged at ~94–182 packets. Vendor requires `R8125_MIN_MSIX_VEC_8125B=22`.
  Fix: legacy ISR over the single MSI vector (`use_v2=false`). Gate evidence:
  `docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md`.
- **RX descriptor stride must be a single source of truth.** The A1 V3 work
  read the ring as a typed `*mut RxDescriptor` (32B) while the chip + repost
  used the legacy 16B stride → reaper misaligned after slot 0, RX stalled at 18
  packets. Fix routes all RX descriptor access through one stride
  (`format.descriptor_len()` / `RxParse`); enforced by `check_rx_desc_stride.sh`.
- **A phase is not "complete" until built AND run on hardware.** Twice (A1, A3)
  code was marked complete while the gateway still ran the previous binary; the
  defects only surfaced when the audit forced a sync+build+run. Make the
  gateway run part of the definition of done.
- **Distinguish benchmark artifacts from regressions.** The "UDP RX regression"
  on the V3 default was over-line-rate spillover (`-b 2400M` > 2.35 Gbps line
  rate), identical on legacy and V3, 0% at ≤ line rate. The 64B-RX "−22.7%"
  matrix cell was sampling noise (CPU-bound at ~2M pps, ±25% swing); with 8
  `-P10` samples rust's median (2.20M) ≥ C (1.84M). Re-sample noisy cells
  before calling them regressions.
- **The Controller-KVM can't validate single-flow UDP TX** — iperf3 UDP pacing
  on `kvm-clock` wedges both drivers; use the Gateway for UDP-TX/latency/IRQ
  work.
- **Don't re-measure an unchanged baseline every run.** The C driver is fixed;
  the bench now pins a C reference and runs rust-only (`RUN_C=0`) unless the
  kernel/rig changes (~2× faster matrices).

## 2026-06-11 — upstream-review misses: make "obvious" details executable

- **Readback must match programmed state, not just be plausible.** We initially
  programmed multi-queue RSS with the kernel default indirection spread, while
  `get_rxfh` still reported the old all-zero single-queue table. The code ran,
  but `ethtool -x` lied about hardware state. New rule: every control-plane
  setter/programmer needs a readback audit row: "what writes hardware?" and
  "what does the user-facing query report immediately after?" The CI gate must
  assert the same source of truth is used on both sides.
- **Validate both running and down administrative states.** `ethtool -L` was
  correct on a running interface because stop/open refreshed the C-side active
  queue cache, but the down-interface path could have accepted a new count while
  `ethtool -l/-x` still reported the old one until the next open. New rule:
  any netdev reconfiguration op must be reviewed in both states:
  `ip link set up; change; query` and `ip link set down; change; query; up; query`.
  If one path updates cached state through a side effect, the other path must
  update that cache explicitly or share the same helper.
- **A static gate must cover the entire contract, not just the original
  milestone.** `check_rss_ethtool.sh` checked the B5-era RSS surface, but after
  `set_channels` was added the gate still did not assert that the op was wired
  or that the down-interface cache update existed. New rule: when a feature
  grows, update the gate's description and failure conditions in the same patch;
  comments saying "full surface" are stale unless the grep/test set proves it.
- **Evidence parsers are production code.** A sweep parser recorded the literal
  string `receiver` in the retransmit column, and single samples of bursty TCP
  retransmits created false "C beats Rust" alarms. New rule: benchmark harnesses
  need unit-testable pure helpers for parsing/statistics, schema checks that
  reject non-numeric metric columns, and enough samples to report median/min/max
  plus spike-rate for bursty metrics.
- **Prefer unsupported over silent no-op.** `set_rxfh` originally validated an
  indirection table but did not store or program it, which could make a valid
  custom table look accepted while hardware kept the default spread. New rule:
  until a setter is fully implemented, accept only exact echoes of the current
  supported state and return `-EOPNOTSUPP` for valid-but-unsupported changes.
- **Docs must be audited as claims, not prose.** Stale wording like
  `rss_queues` "default 1" survived after the actual default was `0/off`.
  New rule: before upstream-review or soak signoff, run a claim audit over docs:
  defaults, supported values, completed/deferred status, evidence paths, and
  any "no scenario/no metric" statements must match code and raw artifacts.

## 2026-06-20 — PCI lifecycle, AER, runtime PM, and subsystem lessons

### AER: verdict policy determines stability

- **CanRecover over NeedReset for Normal-channel AER, or you get a reset storm.**
  The RTL8125B's only reset method is secondary-bus reset; a bus reset on this
  device generates an Uncorrectable PCIe AER (UnsupReq). Issuing NeedReset from
  `error_detected(Normal)` caused: slot_reset → bus reset → AER → error_detected
  → NeedReset → ad infinitum (observed live, verified with 3× resets before the
  fix). Fix: only `Frozen` → NeedReset; `Normal` → CanRecover (matches igb
  pattern). Implication: for any device whose only reset path is bus reset, AER
  verdict policy must account for the chip emitting an error on every reset.
  Commits: `8fdf38d`, `5ad27ad`.
- **AER callbacks must be RTNL-free.** AER runs under `pci_bus_sem`; taking
  rtnl inside an AER callback deadlocks against the runtime-PM D-state path
  (which takes rtnl → pci_bus_sem). This ABBA lockdep violation was caught
  early and fixed by marking all AER callbacks RTNL-free. The runtime-PM
  `ndo_open`/`ndo_stop` entry wrappers exist specifically to avoid re-entering
  the PM callbacks from AER context. Gate: `ci/check_aer.sh` enforces rtnl-free
  statically.

### Runtime PM: simpler model beats clever model

- **Closed-interface autosuspend, not per-TX get/put.** The original sketch
  used per-packet `pm_runtime_get/put_sync`, which adds cost and hazard.
  Instead, `runtime_idle` vetoes (`-EBUSY`) whenever `netif_running`, so
  runtime suspend/resume only run on a closed interface — they detach/attach
  the netdev device (no rings, no RTNL) and let the PCI core handle D-state.
  This eliminates per-packet overhead AND the rtnl/ring hazard in one design
  choice. Commits: `8fdf38d`. Evidence: `docs/perf/feature_smoke/runtime_pm.txt`.
- **ndo open/stop must use dedicated _entry wrappers.** The `bridge_ndo_open`
  and `bridge_ndo_stop` functions are reused by PM/reset/AER resume paths.
  Wrapping them with `pm_runtime_get/put_sync` would deadlock when called from
  inside a runtime callback — the `get_sync` would wait on itself. Fix:
  dedicated `r8125_bridge_ndo_open_entry` / `r8125_bridge_ndo_stop_entry`
  that bracket the real open/stop with PM get/put. Gate:
  `ci/check_runtime_pm.sh` pins these invariants.

### WoL deep-S3: keep the PHY alive, not just armed

- **The gap was never about WoL registers — it was that the PHY goes dark in
  D3.** Mainline r8169 applies `PMCH | D3HOT|D3COLD_NO_PLL_DOWN` to keep the
  chip PLL (hence the internal PHY) powered across D3. Without this, magic
  packets reach a powered-down PHY that cannot detect them. The fix is a WoL-
  aware suspend branch: light quiesce (napi_disable only — NOT ndo_stop /
  phy_stop / free_irq), write WoL arming registers including Config1/Config2
  PME bits, set PMCH PLL keep-alive, and resume with full stop+reopen to clear
  D3-reset chip state. Commits: `0ffca33`. Evidence:
  `docs/perf/feature_smoke/wol_wake_s3_external_sender.txt`.
- **IRQ affinity hint must be cleared before free_irq.** The KASAN kernel
  WARNed on every `ndo_stop` because `irq_update_affinity_hint` was not NULL-ed
  before IRQ teardown. Fix: clear hint to NULL before free_irq (also fixed the
  rtcwake path). This is a general kernel lifecycle rule irrespective of WoL.

### XSK zero-copy: surgical queue swap beats link bounce

- **Per-queue RX reconfigure is deterministic; full stop+open is not.**
  The first AF_XDP bind used full ndo_stop/ndo_open: the link dropped for ~4s,
  and 1/3 binds delivered 771k frames vs 0 — a timing-dependent race. The fix
  (igc_xdp_enable_pool pattern) swaps just the bound queue's RX pool with the
  chip RX engine briefly off via `rust_rx_quiesce`/`rust_rx_quiesce_restore` —
  TX/PHY/IRQ untouched, link never drops, bootstrap is deterministic. For
  multi-queue, a full reopen fallback remains but the single-queue path (the
  common gateway case) is surgical. Commits: `5ad27ad`. Evidence:
  `docs/perf/feature_smoke/afxdp_zerocopy.txt`.
- **AF_XDP cold-start needs synchronous kick + need-wakeup.** The bind path
  posts umem buffers via `ndo_xsk_wakeup` → `rust_xsk_kick` →
  `napi::zc_refill_locked` (serialised by per-queue `xsk_lock`). Without this
  deterministic bootstrap, the first NAPI poll finds an empty RX ring.

### Jumbo: PCIe readrq and pause are coupled

- **Jumbo frames need pcie_set_readrq(4096) to avoid PCIe completion timeout.**
  The chip's jumbo RX writes large buffers over PCIe; the default 128B readrq
  causes the chip to stall waiting for completion credits. Raising to 4096
  matches mainline r8169's `rtl_jumbo_config`. Commits: `3fc9709`.
- **IEEE 802.3x pause frames deadlock in jumbo mode.** A jumbo frame occupying
  the RX buffer blocks pause frame processing, causing head-of-line blocking
  for all traffic. Disabling pause in jumbo mode (matching mainline behavior)
  avoids this. The two changes together (readrq + pause disable) are the
  minimal `rtl_jumbo_config` equivalent.
- **New rule: any PCIe DMA size tuning needs both direction's view.** Raising
  readrq is not "bigger is better" — it affects completion buffer utilisation,
  arbitration, and parity with the write request size. Check both read and
  write request boundaries when changing either.

### TX offload policy belongs in Rust

- **NDO feature negotiation was inline C #ifdef chains — now it is a
  Rust-owned `ChipLimits` struct.** Moving `bridge_ndo_fix_features` and
  `bridge_ndo_features_check` from r8169-port C into `src/tx_offload.rs`
  made the offload policy testable (host unit tests), auditable (single
  source for per-chip limits), and freed the C shim of complex feature-mask
  logic. The C side now just delegates to `rust_ndo_fix_features` /
  `rust_ndo_features_check`. Commits: `3fc9709`.
- **New rule: if policy logic lives in C #defines long enough to need a
  comment explaining it, it belongs in Rust.** The Rust side has `#[cfg(test)]`,
  compile-time `const _: assert!()`, and type safety that C preprocessor
  macros do not.

### PHY firmware: the kernel FIRMWARE API is safe to use from Rust

- **`kernel::firmware::Firmware` provides a safe binding for
  `request_firmware` — no new cshim or unsafe needed.** The firmware blob
  (rtl8125b-2.fw, ~800 ops) is fully validated into a bounded operation list
  before any PHY write: opcode decode, branch bounds, malformed-blob rejection,
  max-op limits, checksum and version fields. The dual-target interpreter
  (MAC-OCP via `mac_ocp_write` ↔ PHY MDIO via `r8168g_mdio_write` semantics)
  is host-tested as pure Rust. Post-apply: reset page base, poll BMCR.
  `MODULE_FIRMWARE` + `ethtool -i` exposes version. Commits: `cb4d749`.
  Evidence: `docs/perf/feature_smoke/phy_firmware.txt`.
- **Firmware-absent is not a fatal error.** The driver falls back to errata-
  only operation when the firmware blob is missing (matches r8169 behavior).
  This is not just a convenience — it means a distribution that omits the
  firmware blobs still gets a working driver.

### Capability plan as coordination mechanism

- **After multiple concurrent feature streams (W1 PHY, W2 PCI, W3 LEDs/RSS,
  W4 XDP/XSK), a single plan document tracking per-feature status + evidence
  paths + deferred/done markers prevented cross-stream confusion.** Without
  it, the AER and XSK streams would have made conflicting assumptions about
  the PM quiesce contract, and the feature-inventory CI gate would have been
  the only signal — too late. Commits: `64a2a2e`.
- **New rule: when 2+ independent work streams touch the same subsystem
  (PCI PM, NAPI lifecycle, ring ownership), a shared plan document must be
  the single source of truth for the contract between them.** Each stream
  updates the plan before merging. The plan is not documentation — it is a
  coordination artifact.

### Evidence-driven development

- **Every feature in the June 11-20 period landed with:** `ci/run_checks.sh`
  clean, host unit tests for pure-logic modules, a hardware smoke artifact in
  `docs/perf/feature_smoke/`, and a CI gate that would fail if the feature
  regressed. The rule "the gateway run is part of the definition of done" —
  established June 7 after two phases were "complete" while still running old
  binaries — became non-negotiable.
- **Static gates expanded from 12 to ~45 scripts**, covering: AER, runtime PM,
  WoL suspend, XSK, XDP contract, cshim LOC caps, unsafe census, TX disposition,
  TX offload policy, LED hardware register isolation, and more. Every gate
  tests a specific invariant that a future commit could break. If an invariant
  is important enough to write in a commit message, it needs a gate.

### AI agent collaboration patterns (this project)

This section captures what worked and what did not when building the driver
with AI agents as primary contributors.

- **AI excels at pattern recognition and exhaustive CI generation.** Given one
  working check script, the AI could generate 20 variants covering error paths,
  edge cases, and contract guarantees that a human would stop writing after 5.
- **AI-generated code requires a hardware run to validate — always.** Three
  separate times the AI declared work "complete" based on code analysis + build
  passing, while the gateway still ran stale binaries or a subtle ordering
  defect existed that only on-wire behavior revealed. The "gateway run is done"
  rule exists because of this pattern.
- **The Sisyphus orchestration model (parallel explore → plan → delegate →
  verify) scaled across 4 concurrent workstreams.** Without the
  `explore`/`librarian`/`oracle` agent decomposition, a single monolithic AI
  session would have been too long, lost context, and introduced more defects.
  The key was: exploration agents discover patterns, the architect decides,
  specialist implementers execute, and a separate verification pass validates
  before merge.
- **AI works best on "smallest implementation" batches that fit in a single
  context window.** The CAPABILITY_PLAN.md batch contract ("reviewable on its
  own") emerged from the AI's context-length limits as much as from human review
  needs. A batch that touches PM, rings, IRQ, and docs in one commit is too
  large for an AI to hold all the interactions correctly.
- **AI-generated static gates are the highest-leverage artifact.** Each shell
  gate script is ~30-100 lines of bash that prevent an entire class of
  regression. The AI can generate these faster than a human can describe them,
  and they collectively enforce thousands of lines of Rust/C against the
  contract. This is the force multiplier of AI-driven kernel development.
- **Hardware validation evidence is the only ground truth.** AI can design,
  write, and review code, but it cannot run it on PCIe hardware. Every claim
  in CAPABILITY_PLAN.md about "working" features is backed by a raw evidence
  artifact captured from the gateway. Without the gateway, the AI would
  confidently ship code that wedges the TX path in edge cases it cannot
  simulate.
