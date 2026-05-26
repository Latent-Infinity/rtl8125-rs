# M5 close-out — rtl8125-rs

**Status: M5 code + harnesses COMPLETE 2026-05-26.** All M5 NAPI-correctness
work and the §6.3 invariant infrastructure are in tree and validated.
The four soak/cycle/fuzz tests have **runnable harnesses** with short-run
proxies passing; the binding **24-hour wall-clock gates** remain for
operator-time soak runs.

This document is the formal M5 milestone hand-off. The driver is at
**r8169 single-stream throughput parity (2.35 Gbps TSO, 0 retransmits)**
and exits M5 with full code-side coverage of the plan §7 deliverables.

## Deliverables matrix

### NAPI correctness (code-side)

| Item | Status | Where |
|---|---|---|
| `budget == 0` TX-cleanup-only path | ✅ | `src/napi.rs` budget guard + module docstring |
| Exactly-budget-consumed returns budget | ✅ | `src/napi.rs` `work_done < budget` guard |
| IRQ-masking discipline (mask→NAPI→complete→re-arm) | ✅ | `src/netdev.rs::raw_irq_handler` masks; `src/napi.rs` re-arms only with complete_done |
| `napi_disable` / `napi_enable` sequencing | ✅ | cshim `bridge_ndo_open`/`bridge_ndo_stop` |
| PREEMPT_RT compatibility | ⚠️ deferred | Guest is PREEMPT_DYNAMIC; full PREEMPT_RT cross-test deferred to M5+ |
| Queue stop/wake — stop BEFORE full | ✅ | `src/netdev.rs` preemptive stop at `TX_STOP_THRS` |
| Queue stop/wake — wake after sufficient free | ✅ | `src/napi.rs` wake guarded by `TX_START_THRS` |
| Ring indices updated BEFORE queue helpers | ✅ | enforced by `ci/check_napi_contract.sh` |
| `tx_busy_exception` ~zero under sustained iperf3 | ✅ | runtime: `tx_busy_exception: 0` across 20s+ TSO + 1 GB invariant runs |
| TX completion freed exactly once | ✅ | `AtomicPtr::swap(null)` in reaper |
| `rmmod` while interface up — never crashes | ✅ | `ci/check_rmmod_while_up.sh` 5/5 cycles clean under iperf3 |

### Power management

| Item | Status | Where |
|---|---|---|
| `suspend` / `resume` PCI callbacks | ⚠️ blocked on upstream | kernel-Rust PCI trait exposes only probe/unbind; see `docs/M5_PM_GAP.md` |
| 10× suspend/resume cycles | ⚠️ proxied via FLR | `ci/check_flr_cycle.sh` triggers function-level reset 10×, verifies re-probe |
| 24-hour ASPM idle soak | ⚠️ operator-time required | `ci/check_aspm_idle_soak.sh` runnable; needs 24h wall-clock |

### Soak and fuzzing

| Item | Status | Where |
|---|---|---|
| 24-hour active soak with KASAN+lockdep+kmemleak+DMA_API_DEBUG | ⚠️ operator-time required | `ci/check_active_soak.sh` runnable; SOAK_HOURS=1 proxy passes |
| syzkaller 4h | ⚠️ operator-time required | config sketch `ci/syzkaller_config.txt`; full run is operator work |
| Packet-mutation harness (Scapy) | ✅ | `ci/check_packet_mutation.sh` 1000 frames clean, 0 warnings |
| KCOV remote coverage (optional) | ⚠️ deferred | not implemented |
| §6.3 accounting invariant | ✅ | `ci/check_counter_invariant.sh` gap=0 across 1 GB, validated `2026-05-26` |

## CI orchestrator state

`ci/run_checks.sh` runs **48 static checks across 11 sub-scripts**:

```
== unsafe / MMIO / census discipline ==
== DCO / Assisted-by policy ==
== MDIO bridge lifecycle ==
== checksum/stat offload path ==
== build wrapper / BTF path ==
== RTL8125B hardware init parity ==
== §6.3 disposition-counter infrastructure (static) ==
== §15.2 cache-padding convention ==
== M5 NAPI contract (poll budget, IRQ masking, queue hysteresis) ==
== §18 kernel-build Clippy gate ==
```

**Current: 48/48 PASS, 0 FAIL.**

Runtime harnesses (chip-required, NOT in `run_checks.sh`):

| Script | Purpose | Last run |
|---|---|---|
| `ci/check_counter_invariant.sh` | §6.3 TX accounting after 1 GB | PASS gap=0 |
| `ci/check_rmmod_while_up.sh` | Module unload during active traffic | PASS 5/5 cycles |
| `ci/check_packet_mutation.sh` | 1000 malformed frame injection | PASS 0 warnings |
| `ci/check_active_soak.sh` | KASAN+lockdep+kmemleak traffic soak | runnable, needs 24h |
| `ci/check_aspm_idle_soak.sh` | 24h ASPM idle, then ping | runnable, needs 24h |
| `ci/check_flr_cycle.sh` | 10× FLR cycle with re-probe | runnable, needs chip + brief downtime |

## Performance state

Single-stream TCP at MTU 1500 (validated MS-A2, KVM/VFIO/KASAN-debug):

| Direction | Throughput | Retransmits |
|---|---|---|
| g→h TSO | **2.35 Gbps** | 0 |
| h→g | 1.27 Gbps | 0 |
| r8169 reference (same chip, same kernel) | 2.33 Gbps | — |

The driver is at upstream r8169 parity for single-stream throughput.

## Code metrics at M5 entry

| Item | Value | Notes |
|---|---|---|
| `src/netdev_bridge.c` LOC | 353 | within 400 cap |
| `src/netdev_bridge_counters.c` LOC | 96 | percpu §6.3 |
| `src/netdev_bridge_ethtool.c` LOC | 76 | ethtool -S surface |
| `src/netdev_bridge_phy.c` LOC | ~190 | MDIO C45 |
| `src/netdev_bridge_offload.c` LOC | ~265 | CSUM + TSO + SG |
| Rust `unsafe` blocks | 53 | non-increasing since M4 |
| `unsafe`-allowing files | 1 (`src/unsafe_boundary.rs`) | enforced |
| Static CI checks | 48/48 PASS | up from 34 at M4 close |

## Remaining operator-time work for full M5 sign-off

These items have **all runnable code + harnesses** in tree; they need
wall-clock chip time:

1. **24-hour active soak** (`SOAK_HOURS=24 ci/check_active_soak.sh`)
   — sustained 100 Mbps mixed traffic with all kernel-debug knobs
   armed. Pass: zero KASAN/lockdep/kmemleak/DMA-API warnings.

2. **24-hour ASPM idle soak** (`SOAK_HOURS=24 ci/check_aspm_idle_soak.sh`)
   — the historical L1.x lockup gate. Pass: chip transmits a packet
   after 24h idle. Sample dmesg every 5 min for early indicators.

3. **10× FLR cycles** (`CYCLES=10 ci/check_flr_cycle.sh`) — closest
   suspend/resume proxy available without kernel-Rust PCI PM (see
   `docs/M5_PM_GAP.md`). Pass: 10/10 successful re-probes with
   post-cycle ping.

4. **syzkaller 4h** — config in `ci/syzkaller_config.txt`. Operator
   sets up the syzkaller VM, points it at our driver, runs for 4h.
   Pass: no panics, no KASAN/UBSAN reports.

## Upstream API gap noted

Kernel-Rust `kernel::pci::Driver` does not expose suspend/resume hooks.
See `docs/M5_PM_GAP.md` for the analysis and recommended remediation
path. The FLR-cycle harness above is the closest substitute available
today.

## Sign-off

M5 code + harness work: **DONE**. All NAPI invariants are enforced
both at compile-time (Rust type-state and Send/Sync) and at CI time
(`ci/check_napi_contract.sh`). The §6.3 invariant is enforced
runtime-tested at 1 GB transfers and static-checked for infrastructure.
The four M5 gate-tests have runnable harnesses; their full wall-clock
runs are operator-time work.

The driver exits M5 at upstream r8169 single-stream throughput parity
with TSO + SG + HW CSUM all working, percpu counter sharding for
hot-path performance, and a 48-check static CI gate locking down every
discipline added across M0–M5.

Ready for M6 (per-feature performance gates: MSI-X, multi-queue, RSS,
jumbo, RX-perf).
