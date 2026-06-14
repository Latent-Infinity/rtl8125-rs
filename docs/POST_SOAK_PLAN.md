# Post-soak plan — M5 close-out + M6 wrap

**Status (2026-05-29):** plan agreed during planning conversation
2026-05-29. Targets **end-of-week wrap** (2026-06-02). Both
in-flight soaks (KVM 12 h active + Gateway 24 h ASPM-on idle)
must sign off first; ETA Gateway 2026-05-30 ~03:05 UTC. After that
this plan executes.

The actual goal these tasks serve: **a stable RTL8125 driver with
good/better performance on the boxes we have, suitable as the
network substrate for heterogeneous-load-balancer work.** Upstream
contribution is a side-effect we'll pursue if cheap. We do not add
instrumentation that costs latency.

Decisions taken during the planning conversation:

1. Gateway is available for a 24 h ACTIVE-traffic soak. Tier 1b
   runs end-to-end.
2. M7 outbound dossier sends after Tier 1 signs off.
3. Tier 4 pattern extraction happens NOW, while context is fresh.
4. Budget is the full 4 working days as sketched.

## Tier 1 — Stability evidence (closes M5 properly)

| # | Work | Trigger | Owner | Est cost |
|---|---|---|---|---|
| 1a | 10× suspend/resume on Gateway | After 1b finishes | claude+harness | 30 min × 10 wall |
| 1b | 24 h active-traffic soak on Gateway bare-metal | Immediately after current 24 h idle soak ends | claude (harness) | 24 h unattended |
| 1c | 100× rmmod-under-traffic cycles on KVM | In parallel with 1b | claude (scripted) | 4–6 h |
| 1d | Cold-boot auto-load verification on Gateway | After 1a | operator | 1 h |

## Tier 2 — Perf characterization for the LB

Closes every "pending" line in `docs/perf/r8169_comparison.md`. No
new driver instrumentation; reuses iperf3 + ethtool + ping flood
that the kernel already has.

| # | Work | Trigger | Est cost |
|---|---|---|---|
| 2a | Bidirectional saturation (both directions line rate) | KVM available post-Tier-1c | 1 h |
| 2b | p99 latency under load — 1000 pings at 0.05 s + 100 Mbps iperf3, one capture per direction per MTU | KVM available | 30 min |
| 2c | Small-packet pps (`iperf3 -u -l 64 -b 1G`) | KVM available | 30 min |
| 2d | Fresh h→g + UDP captures completing `r8169_comparison.md` | KVM available | 1 h |

## Tier 3 — Operational readiness

| # | Work | Trigger | Est cost |
|---|---|---|---|
| 3a | `scripts/dump_state.sh` — single-command snapshot of dmesg + ethtool -S + /proc/interrupts + lspci -vv + ip link + ASPM | Anytime | 1 h |
| 3b | `docs/FAILURE_MODES.md` — taxonomy of error classes + dmesg patterns + what counters to check | Anytime | 2 h |
| 3c | `aspm_force_off` module param + CI gate matching `intx_only` rollback shape | Anytime | 1 h |

## Tier 4 — Pattern extraction for the next device

Capture transferable shapes WHILE context is fresh.

| # | Work | Trigger | Est cost |
|---|---|---|---|
| 4a | `docs/PATTERNS.md` — chip-agnostic vs chip-specific in this project | Anytime | 2 h |
| 4b | Soak-harness parameterization — accept iface / subnet / peer-MAC as args | Anytime | 2 h |
| 4c | CI-gates inventory — tag each gate `[generic]` vs `[rtl8125-specific]` | Anytime | 1 h |

## Tier 5 — M7 side-effect

| # | Work | Trigger | Est cost |
|---|---|---|---|
| 5a | Send outbound M7 dossier to netdev + rust-for-linux ML | After all Tier 1 signs off | 30 min + months wait |
| 5b | Monitor lore quarterly for new netdev-Rust activity | Standing | 15 min / quarter |
| 5c | Apply pending dossier patches from this turn's audits | Anytime | 30 min |

## Explicit drops / defers

These are NOT on the plan, by design:

- **Multi-queue / RSS** — hardware ceiling on 8125B per
  `MULTIQUEUE_RSS.md`. No software fix possible.
- **XDP optimization** — LB use case doesn't need it.
- **KMSAN / KCSAN extended soaks** — KASAN coverage sufficient
  for this driver's pattern.
- **DKMS packaging** — not distributing builds.
- **OOT vendor `r8125` build comparison** — was only a maintainer-
  dossier argument; not goal-relevant.
- **Multi-week soaks** — diminishing returns past 24 h active.
- **Cross-kernel-version test matrix** — until a second kernel
  target exists, hypothetical.

## Wall-clock schedule

```
2026-05-29 (today)              Planning conversation. Tier 4a/4b/4c
                                + Tier 3a/3b + Tier 5c are pure-
                                paper / pure-script and can start
                                now, in parallel with the soaks.

2026-05-30 03:05 UTC ish        Current Gateway 24 h idle soak ends.
                                Immediately kick Tier 1b (active).

2026-05-30 throughout           Tier 1b runs unattended on Gateway.
                                Tier 1c runs in parallel on KVM.
                                Continue Tier 3/4 paper work.

2026-05-31 03:05 UTC ish        Tier 1b ends. Kick Tier 1a (10×
                                suspend/resume on Gateway).

2026-05-31 throughout           Tier 2a-2d perf characterization
                                runs on KVM (Tier 1c finished by
                                now).

2026-06-01                      Tier 1d cold-boot auto-load.
                                Sign off HARDENING_CLOSEOUT.md.
                                Sign off r8169_comparison.md.
                                Tier 4c finalize.

2026-06-02 (Mon)                Tier 5a — send M7 outbound dossier.
                                Project wrap; whatever's next gets
                                a new plan.
```

Slippage budget: ±1 day for any single tier; if Gateway 1b finds a
real bug we slip further. The dossier and `aspm_force_off` work
can absorb a half-day slip without affecting the M5-close date.

## What CAN start before soaks finish (pre-2026-05-30)

Everything in this list is pure-paper or pure-script work; no
chip access needed, no risk to running soaks:

- 4a `PATTERNS.md`
- 4b Soak-harness parameterization
- 4c CI-gate transferability tagging
- 3a `dump_state.sh`
- 3b `FAILURE_MODES.md`
- 5c Apply pending dossier patches
- Draft Tier 1b/1c/2a-d scripts (so they're ready to fire)

That's roughly 10 hours of work available to do today + tomorrow
without touching the chip. Plenty to fill the soak window.

## Cross-references

- [`HARDENING_CLOSEOUT.md`](HARDENING_CLOSEOUT.md) — what signs off at end of Tier 1
- [`PRE_RFC_DOSSIER.md`](PRE_RFC_DOSSIER.md) — what 5a sends
- [`CSHIM_KERNEL_DIFF.md`](CSHIM_KERNEL_DIFF.md) — research backing 5c
- [`BLOCK_CADENCE.md`](BLOCK_CADENCE.md) — calibration backing 5c
- [`perf/r8169_comparison.md`](perf/r8169_comparison.md) — closes at end of Tier 2
- [`RTL8125_Rust_Driver_Implementation_Plan.md`](RTL8125_Rust_Driver_Implementation_Plan.md) §7 M5/M6/M7 — gating authority
