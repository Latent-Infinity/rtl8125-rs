# Transferable patterns — for the next Rust kernel NIC driver

**Status (2026-05-29):** extracted from rtl8125-rs while context
is fresh. Aimed at making the next Rust NIC driver project
(whatever chip / whatever bus) **roughly 50% cheaper** by skipping
the discovery work that produced these patterns.

Each entry: what the pattern is, why we adopted it, the bug
class it prevents, and how to apply it to a different chip. Items
marked **[chip-agnostic]** transfer verbatim; **[chip-specific]**
need adaptation; **[discipline]** is project-management not code.

## Foundation

### 1. Cshim + Rust-core split with thin-but-thick contract  **[chip-agnostic]**

**What.** The driver is two halves: a small audited C shim
(`src/netdev_bridge*.c`, ~1 250 LOC, 38 exports) wrapping kernel
structs without Rust abstractions yet, and the Rust core
(`src/*.rs`, ~5 000 LOC) containing all chip logic + state.

**Why.** Kernel-Rust 7.x ships `kernel::pci`, `kernel::dma`,
`kernel::devres`, `kernel::block`, partial `kernel::net::phy` —
but no `net_device` / `napi_struct` / `sk_buff` / `ethtool_ops`.
Inlining the FFI unsafety into the Rust crate would 3× the unsafe
surface; carving a small audited C side gives a 38-symbol contract
that's reviewable in isolation.

**Bug class prevented.** "Unsafe sprawl" — every Rust file becoming
a target for safety audit because every file touches FFI.

**Apply.** For each kernel C struct your driver consumes, check
[`rust.docs.kernel.org/kernel/`](https://rust.docs.kernel.org/kernel/)
first. If there's an abstraction, use it. If not, the cshim
absorbs the C-side handling and exports a contract-documented
symbol per operation. Cshim hard cap: 400 LOC per TU (see #8).

### 2. Plan-driven milestones with hard gates  **[discipline]**

**What.** `docs/RTL8125_Rust_Driver_Implementation_Plan.md` §7
defines M0a → M7 with explicit acceptance criteria per milestone.
Each milestone has its own closeout doc with evidence.

**Why.** Kernel driver bring-up has dozens of orthogonal axes
(probe, IRQ, DMA, NAPI, ASPM, PM, ethtool, jumbo, MSI-X, ...).
Without gating you ship a partial driver that nobody trusts.

**Bug class prevented.** "Premature integration" — the temptation
to start packet flow before probe is reliable.

**Apply.** Copy the M0a → M7 outline. Adjust acceptance criteria
to your chip (e.g. if no ASPM hazard, drop the L1.x soak gate;
if multi-queue exists, add an RSS gate). Each milestone gets a
closeout doc that *cites evidence* (counter snapshots, dmesg
excerpts, soak durations), not just "done".

### 3. Unsafe-boundary discipline  **[chip-agnostic]**

**What.** Every Rust file outside `src/unsafe_boundary.rs` carries
`#![deny(unsafe_code)]`. The boundary file is the *only* place
`unsafe extern "C"` FFI wrappers live. `ci/.unsafe-allowlist` is
the per-file enable list; `ci/.unsafe-census` is the count
(currently 52), gated non-increasing by `check_unsafe_allowlist.sh`.

**Why.** Constraining unsafe to one auditable file means safety
review is bounded to ~1000 LOC, not the whole crate.

**Bug class prevented.** Drive-by `unsafe` blocks that bypass type
safety in places nobody reviews.

**Apply.** Start with `#![forbid(unsafe_code)]` everywhere except
one boundary module. As you add FFI wrappers, append entries to
`.unsafe-census` and tighten the allowlist. The CI gate
`check_unsafe_allowlist.sh` enforces the contract.

## Safety patterns

### 4. §6.3 disposition-counter invariant  **[chip-agnostic]**

**What.** Six per-CPU counters: `tx_received`, `tx_consumed`,
`tx_busy_exception`, `tx_dropped_error`, `rx_handed_to_stack`,
`rx_dropped_error`. The invariant
`tx_received == tx_consumed + tx_busy_exception + tx_dropped_error`
must hold at every snapshot. `ethtool -S` exposes them;
`ci/check_counter_invariant.sh` asserts the equation runtime.

**Why.** Drop attribution. When a packet doesn't make it through,
which class swallowed it? Without this, postmortems can't tell
whether a missing packet was queued-and-OK, queue-stop-busied, or
errored-and-dropped.

**Bug class prevented.** Silent drops mis-attributed. Heterogeneous-LB
postmortems rely on this signal to know whether a downweighted
device was actually overloaded vs. driver-buggy.

**Apply.** Same six counters; per-CPU via `alloc_percpu(u64)`;
incremented at the disposition point only (one site per class);
sum-walked at snapshot time. The cshim files
`src/netdev_bridge_counters.c` + `src/netdev_bridge_ethtool.c`
are directly portable.

### 5. `DriverOwnedSkb` — linear sk_buff ownership  **[chip-agnostic]**

**What.** A `#[must_use]`, `#[repr(transparent)]` wrapper around
`*mut sk_buff` with no `Drop` impl. Methods consume `self`:
`consume_tx`, `deliver_rx`, `free_with_error`, `into_raw`. Borrow
methods take `&self`. `from_raw` only inside FFI entry points.

**Why.** Forbids the entire class of skb mishandling at compile
time: leaks surface via `#[must_use]` + kmemleak, double-free is
impossible because consumers take `self` by value.

**Bug class prevented.** Double-free, use-after-free, leak — the
top failure mode of every legacy netdev driver.

**Apply.** Direct copy of `src/skb.rs` + `ci/check_skb_ownership.sh`.
Independent convergence with FUJITA Tomonori's 2023 net_device
proposal validates the shape — it's the right Rust-side answer.

### 6. RAII guards with `Option<T>::take()` linear transfer  **[chip-agnostic]**

**What.** `RxPoolGuard` / `IrqGuard` / `TxMapGuard` each hold an
`Option<T>` of the resource. The constructor inserts; success
paths call `.take()` to transfer ownership; failure paths drop
the guard which calls `.take()` automatically and cleans up.

**Why.** Replaces `goto cleanup_N:` labels with type-driven Drop
unwind. Every error path is correct by construction.

**Bug class prevented.** "Forgot to clean up intermediate state on
error" — observed in r8169's history and easy to mis-write in any
C driver.

**Apply.** Each multi-step allocation (`ndo_open` is the canonical
case) gets a guard. Pattern in `src/netdev.rs` `ndo_open_inner`.

### 7. `ChipInfo` per-revision capability table  **[chip-specific shape, chip-agnostic pattern]**

**What.** `struct ChipInfo` enumerates per-stepping capabilities:
`max_mtu`, `tso_max_segs`, `tso_max_size`, descriptor format ID,
RX max size, etc. Probe chooses the right `ChipInfo` from the
chip's XID/rev registers; everything downstream reads from it.

**Why.** Future chip steppings (8125B → 8125C → 8126) differ in
small, table-driven ways. Hard-coded constants force per-stepping
ifdefs in every code path.

**Bug class prevented.** "Driver supports chip A correctly but
breaks chip B because someone hard-coded chip A's MSS cap" —
exactly the kind of bug rtl8125b's 11-bit MSS cap could have
caused for a chip with a larger field.

**Apply.** Build the table during probe. All capability gates read
from it. New chip stepping = new row + revision-detection branch.

## Performance patterns

### 8. Per-CPU stats via percpu storage + sum-snapshot  **[chip-agnostic]**

**What.** All hot-path counters live in `alloc_percpu(u64)` storage.
Writers use `this_cpu_inc()` (single decorated INC on x86, no
cache-line traffic). Readers do `for_each_possible_cpu` sum at
snapshot time.

**Why.** A `WRITE_ONCE(x, READ_ONCE(x)+1)` pattern on a global ping-
pongs the cache line between writer CPUs. Per-CPU storage gives
each writer its own line.

**Bug class prevented.** Hot-path cache contention — drops several
percent of throughput at line rate.

**Apply.** Every counter in the §6.3 set + any chip-specific
counters use this pattern. The cshim files `*_counters.c` show
the alloc / free / sum helpers.

### 9. Cache-padded atomics for cross-context shared state  **[chip-agnostic]**

**What.** Any `AtomicU64`/`AtomicUsize` shared between hot contexts
(NAPI poll vs xmit, IRQ handler vs poll) wraps in `CachePadded<T>`.
Enforced by `ci/check_cache_padding.sh`.

**Why.** False sharing between independent hot contexts serializes
them on a single cache line.

**Bug class prevented.** Latency floor hard to debug — packets
slow not because of any single bottleneck but because two
contexts contend on a shared cache line.

**Apply.** Wrap every cross-context atomic. Local-context atomics
(only one CPU writes) can stay unpadded.

### 10. NAPI poll contract — budget rules + IRQ-rearm ordering  **[chip-agnostic]**

**What.** Poll function:
1. `budget == 0` ⇒ never `napi_complete_done`; may run TX reaper;
   no XDP / page-pool touches.
2. `work_done < budget` ⇒ `napi_complete_done` then unmask IRQ.
3. `work_done == budget` ⇒ return without `napi_complete_done`;
   IRQ stays masked across re-poll.

`ci/check_napi_contract.sh` enforces all three.

**Why.** Each edge case has a specific kernel-side requirement.
Getting any one wrong means missed IRQs or busy-loops.

**Bug class prevented.** Stuck queues + spurious IRQs.

**Apply.** Direct copy of `src/napi.rs` poll skeleton + the CI gate.

### 11. Atomic-pointer cross-context state holders  **[chip-agnostic]**

**What.** Long-lived state pointers (the net_device, the BAR
mapping, the napi pointer) live in `AtomicPtr<T>` fields on
`NetdevState`. IRQ-context handlers Acquire-load; setup-context
writers Release-store.

**Why.** IRQ handlers can't take locks. Need lock-free pointer
access with C11-style ordering.

**Apply.** Each long-lived chip-side handle becomes a CachePadded
AtomicPtr field.

## Operational patterns

### 12. Module-param rollback knobs  **[chip-agnostic]**

**What.** For every behavior change that touches a known-historical
hazard, ship a module parameter that disables the change. We have
`intx_only=1` (MSI-X rollback) and we're adding `aspm_force_off`
(L1.x rollback).

**Why.** When a deployment regression bites in the field, the
operator needs a fast escape hatch that doesn't require code
changes.

**Bug class prevented.** "Field regression with no rollback" — the
worst kind, because the user has to choose between known-bad new
behavior and reverting the entire driver.

**Apply.** Every behavioral change to a historical-hazard area
ships with a `_force_off` or `_only` companion param.

### 13. Soak harness + runtime counter-invariant check  **[chip-agnostic]**

**What.** Soak scripts run iperf3 + link-cycle stress for N hours,
periodically snapshotting `ethtool -S` and asserting the §6.3
invariant equation. Any violation surfaces immediately as a
script-level failure.

**Why.** Stability bugs surface at long-tail timescales (hours,
not minutes). A 5-minute test won't find them.

**Bug class prevented.** Slow leaks, slow drift, time-of-day
wraparound bugs.

**Apply.** Direct copy of soak harness + `check_counter_invariant.sh`.
Parameterize iface / subnet / peer for the next chip (Tier 4b in
`POST_SOAK_PLAN.md`).

### 14. Dual-environment authority — KVM for iteration, bare-metal for sign-off  **[discipline]**

**What.** KVM with VFIO passthrough is the iteration loop
(KASAN + lockdep + kmemleak + DMA_API_DEBUG visible, fast
rebuild). Bare-metal Gateway is the perf + ASPM authority (no
debug overhead, real PCIe link).

**Why.** KVM's synthetic upstream PCIe bridge advertises ASPM L0s
only — we cannot exercise L1.x hazards inside the VM no matter
what the driver does. Bare-metal evidence is necessary for
"historical hazards cleared" claims.

**Bug class prevented.** "Driver works in CI / fails in production"
— extremely common with PCIe drivers because emulation hides
state transitions.

**Apply.** Any Rust NIC driver project should have two boxes: an
iteration box with debug-instrumented kernel, and a clean-kernel
box for perf + ASPM evidence. The implementation plan §1.3
documents the split.

## Chip-feature patterns

### 15. `ndo_fix_features` for offload-MTU dependency  **[chip-specific]**

**What.** When MTU > `ETH_DATA_LEN`, drop `NETIF_F_ALL_TSO |
NETIF_F_CSUM_MASK` because the chip's TSO descriptor MSS field
overflows at jumbo. r8169 does the same.

**Why.** Different chips have different limits. r8125b's MSS
field is 11 bits (2047 max). Some chips have 16 bits, some have
custom encodings. Per-chip.

**Apply.** Audit your chip's TSO MSS field width. If it can't
encode jumbo MSS, copy this hook. The cshim
`bridge_ndo_fix_features` is the template.

### 16. r8169 source-line-by-line parity for `hw_start`  **[discipline]**

**What.** `src/hw.rs` `hw_start_8125b_unlocked` is 128 lines and
intentionally linear — each line maps to a specific
`r8169_main.c` source line via in-code comments. The function
isn't refactored to substructure because the parity-with-r8169
review pattern requires line-correspondence.

**Why.** Realtek chips are notoriously firmware-fragile. The
canonical reset/init sequence is encoded in r8169 (and the
out-of-tree r8125 vendor source). Deviating risks chip lockup
or worse.

**Bug class prevented.** "Driver works most of the time, hangs
on the 100th reset" — subtle init-order bugs that take 1000s of
cycles to surface.

**Apply.** For any chip whose authoritative C reference exists
(r8169, e1000e, mlx5, ...), the bring-up sequence stays linear
and cross-referenced. Refactor for elegance only after multi-cycle
stability is proven.

## CI gate set — transferability sketch

The current 24 gates (see `ci/check_*.sh`) split into three
classes for the next driver:

| Class | Examples | Transferability |
|---|---|---|
| **Mechanical / safety** (apply to ANY Rust kernel driver) | `check_unsafe_allowlist`, `check_no_panic_paths`, `check_dco_assistedby`, `check_clippy`, `check_cache_padding`, `check_clean_contract_docs` | Verbatim copy |
| **Pattern-checkers** (apply to ANY Rust netdev driver) | `check_counter_infrastructure`, `check_napi_contract`, `check_skb_ownership`, `check_cshim_loc_caps`, `check_offload_path`, `check_mdio_bridge`, `check_bare_metal_stack_teardown` | Copy + adjust the expected symbols / file layout |
| **Chip-specific** (RTL8125B knowledge) | `check_hw_init`, `check_isr_v2_paired`, `check_irq_mode_contract`, `check_rx_pool_pages`, `check_jumbo_mtu_chip`, `check_msix_static`, `check_packet_mutation`, `check_rmmod_while_up`, `check_flr_cycle`, `check_active_soak`, `check_aspm_*` | Replace per chip |

Tier 4c (`POST_SOAK_PLAN.md`) tags each gate's header. The
generic-tier set (above) is the **starter pack** for the next
driver project.

## What's intentionally NOT a transferable pattern

- **Cshim header structure** (`netdev_bridge.h` Contract /
  Lifecycle / Counters layout) — TRANSFER IT; this is the
  ownership-documentation skeleton.
- **§6.3 specific counters** — TRANSFER; the disposition set is
  generic.
- **Hot-path inlining decisions** — DO NOT transfer; chip-specific
  perf profiling decides.
- **TSO max_segs / max_size values** — chip-specific.
- **PCI device IDs + chip-revision branches** — chip-specific.
- **Module name + symbol prefix** — rename per project.

## RX hot-path optimization methodology  **[discipline]**

The single most important lesson from the M5+ post-soak work:
**profile FIRST, measure skeptically, KASAN dominates KVM**. The
specific recipe that produced the latency-aligned wins in this
project:

### 1. Build a candidate menu before measurement

Before touching code, write a ranked list of plausible
optimizations with effort × risk × expected-gain estimates. See
[`RX_OPTIMIZATION_CANDIDATES.md`](RX_OPTIMIZATION_CANDIDATES.md)
A through M. The menu came from reading r8169's `rtl_rx` end-to-
end, counting FFI crossings, and identifying:

- **Direct r8169 deltas** (`napi_alloc_skb` vs `netdev_alloc_skb`,
  `__skb_put_data` vs `skb_put_data`, `prefetch()` placement).
- **Structural framing differences** (FFI crossings per packet
  vs r8169's single-C-function).
- **Latency-vs-efficiency knobs** (TX queue depth, IRQ affinity,
  hardware coalescing direction).

The menu was concrete enough that the FIRST candidate (`napi_alloc_skb`
+ `__skb_put_data` + `prefetch`) yielded **+17.3% h→g MTU 1500**
on KVM — the only non-noise throughput improvement of the entire
RX-optimization session. Everything after that was within KVM
noise; the structural cleanups (A, B, F, G) shipped anyway for
correctness/contract reasons but produced no measurable KVM win.

### 2. Profile, don't guess

`perf record -a -g -F 999 -- sleep 10` during sustained
adversarial traffic surfaced the real cost:

```
__lock_acquire                  11.42%
stack_trace_consume_entry        6.20%
update_stack_state               5.55%
unwind_next_frame                5.31%
__pv_queued_spin_lock_slowpath   4.90%
rcu_is_watching                  3.82%
kasan_check_range                2.61%
```

**40% of cycles were KASAN + lockdep instrumentation.** No
`r8125_rust` symbol appeared in the top 25. This was the moment we
realised KVM was lying about FFI-reduction wins; the "50% gap vs
r8169 on h→g 1500" we'd been chasing was *largely a debug-kernel
artifact*, not a real driver issue. Profile DATA prevents the
project from spending days optimizing instrumentation overhead.

### 3. Measure skeptically — three samples minimum

A single 10-second iperf3 run varies ±3-5%. We adopted a rule:
**three samples per direction, report mean ± stddev.** The
post-`napi_alloc_skb` h→g 1500 measurement was 1.412 → 1.443 →
1.400 Gbps across three samples; without the second and third
we'd have mis-attributed the +0.6% noise to "fix worked."
Conversely, the L+M latency improvement was 1.351 → 0.979 ms
worst-case under 100 Mbps load with stddev 0.111 ms — clearly
outside noise.

### 4. Separate throughput from latency, and choose

For the heterogeneous-LB use case in this project, **latency
matters more than throughput** once we're at parity. That made:

- TX queue depth 256 (not the kernel default 1000) — bounded
  bufferbloat.
- IRQ affinity hint to one CPU — predictable softirq path.
- Hardware coalescing toward "per-packet IRQ" (deferred for
  Gateway), not "batch for CPU efficiency."

The opposite-direction defaults (giant queue, batched IRQs,
maximal coalesce) are what cloud / hyperscale Ethernet drivers
typically tune toward. Picking sides on the
latency-vs-efficiency axis early IS the design.

### 5. Cache the discipline in CI gates

After each shipped optimization, write a static gate that asserts
the knob stays in tree. The five-minute gate prevents a future
refactor from silently undoing the work.
[`ci/check_latency_knobs.sh`](../ci/check_latency_knobs.sh) is
the canonical example — three knobs (G, L, M), one gate, 60 LOC.

### 6. Trust the dual-environment authority

When KVM measurements stop moving (Candidate A, B, F, G all
within noise), **stop optimizing on KVM**. The
[`docs/perf/README.md`](perf/README.md) environment-authority rule
exists precisely for this: KVM = correctness iteration, Gateway =
perf truth. Pre-Gateway speculative optimization without bare-metal
data is the trap. The decision tree at the bottom of
[`RX_OPTIMIZATION_CANDIDATES.md`](RX_OPTIMIZATION_CANDIDATES.md)
gates each next candidate on a specific Gateway measurement.

## Anti-patterns observed during this project (do NOT carry)

- **KBox::new(LargeStruct)** — built the struct on the stack first;
  blew the 16 KiB kernel stack on bare-metal. Always
  `KBox::init(try_init!(...))` for non-trivial state. See
  [`probe-stack-overflow-task58`](../memory/probe-stack-overflow-task58.md).
- **Single-author abstraction proposal** — FUJITA Tomonori's 2023
  net_device series stalled at v2 because solo. Plural-author is
  load-bearing for upstream. See `BLOCK_CADENCE.md`.
- **Transcribing register bits from secondary references** — the
  INT_CFG0_ENABLE_8125 = BIT(0) vs BIT(3) bisection was caused by
  reading FreeBSD if_re.c instead of the chip vendor's r8125.h.
  Cite the chip vendor's header, not third-party drivers.
- **Single-version coupling of cshim + driver** — when the cshim
  contract changes, update the cshim header AND the matching Rust
  code in the same commit. The plan §6.3 final paragraph documents
  this; `check_clean_contract_docs.sh` partially enforces it.

## Bug-class index

If your next chip needs the same protection against the same bug,
copy the named pattern from above:

| Bug class | Pattern that prevents it |
|---|---|
| sk_buff double-free / UAF | #5 DriverOwnedSkb |
| Lost drop attribution | #4 §6.3 invariant |
| MSI mode mix-up | #7 ChipInfo + IrqMode enum |
| BAR-UAF on rmmod | #1 cshim ordering + RAII |
| Stuck queues from bad NAPI poll | #10 NAPI contract |
| Cache contention at line rate | #8 percpu + #9 cache-padded |
| Field regression with no rollback | #12 module-param knobs |
| Slow drift surfacing at long timescales | #13 soak harness |
| Probe stack overflow on large state | "Anti-patterns" #1 |
| Init-sequence subtle ordering | #16 r8169 parity |
| Stepping-specific capability divergence | #7 ChipInfo |
| Stalled upstream proposal | "Anti-patterns" #2 plural authors |

## Cross-references

- [`RTL8125_Rust_Driver_Implementation_Plan.md`](RTL8125_Rust_Driver_Implementation_Plan.md) — the gating authority
- [`CSHIM_KERNEL_DIFF.md`](CSHIM_KERNEL_DIFF.md) — kernel-C audit of patterns #1, #4, #5, #6
- [`BLOCK_CADENCE.md`](BLOCK_CADENCE.md) — `kernel::block` calibration; sources of the plural-author finding
- [`RUST_STANDARDS.md`](RUST_STANDARDS.md) — the project-wide rubric these patterns enact
- [`POST_SOAK_PLAN.md`](POST_SOAK_PLAN.md) §Tier 4 — schedule for the portability work that completes this extraction
