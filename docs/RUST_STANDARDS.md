# High-Performance Rust Coding Standards v2.0

**Hardware Sympathy & Modern Idioms — Rust 1.95+ / Edition 2024**

> If it feels fast at small scale but collapses under load, the problem is design, not the compiler.

Rust enables writing code that's simultaneously safe and fast through zero-cost abstractions, but achieving peak performance requires understanding specific patterns. **The most impactful optimizations come from treating allocations, syscalls, cache locality, and scheduler interactions as first-class design constraints.** Modern CPUs spend most of their cycles waiting for memory; the cure is hardware sympathy, not clever instructions.

This guide combines authoritative best practices from the Rust Performance Book, core team members, and real-world benchmarks with enforceable standards and practical patterns. Each section provides both the underlying performance rationale and clear MUST/SHOULD/AVOID directives for immediate application.

## Operating Principles

* **MUST** target Rust 1.95+ to access modern stdlib features (`LazyLock`, native async fn in traits, async closures, let-chains)
* **MUST** profile before and after changes (CPU + allocations) and record results in PRs
* **MUST** use release builds for performance evaluation
* **MUST** treat allocations, syscalls, hashing, and scheduler interactions as design constraints, not afterthoughts
* **SHOULD** apply hardware sympathy patterns (Section 15) for latency-critical or numerically-intensive workloads
* **SHOULD** identify "hot paths" (see criteria in Section 17) and apply rigorous standards to them
* **SHOULD** adopt Edition 2024 for new projects

---

## Quick Reference: Do / Don't Table

| Topic              | Prefer                                | Avoid                                |
| ------------------ | ------------------------------------- | ------------------------------------ |
| Ownership          | `&T`, `&str`, `Cow`, `Arc<str>`       | `.clone()` to "make it compile"      |
| Iteration          | Chained iterators, lazy pipelines     | `collect::<Vec<_>>()` then transform |
| Collections        | `with_capacity`, `SmallVec` where apt | Repeated `push` without sizing       |
| Hashing            | FxHash/AHash for trusted hot paths    | Default hasher for all internal data |
| I/O                | `BufReader`/`BufWriter`, streaming    | Unbuffered I/O, intermediate Strings |
| Errors             | `thiserror` enums + `?`               | `Result<T, String>` + `format!`      |
| Logging            | `tracing` with structured fields      | Unstructured `println!/log!` blobs   |
| Concurrency        | Scoped threads, bounded channels      | Copying large `String`s into tasks   |
| Lazy statics       | `LazyLock`/`OnceLock` (std)           | `lazy_static!`, `once_cell` crate    |
| Async traits       | Native `async fn` in traits           | `#[async_trait]` macro by default    |
| Dispatch           | Static generics in hot paths          | `dyn Trait` as optimization barrier  |
| Memory layout      | Cache-aligned independent atomics     | Adjacent atomics → false sharing     |
| Numeric loops      | Branchless, SoA, `chunks_exact`       | Branches in inner loops, AoS         |
| Allocator          | `mimalloc`/`jemalloc` for heavy alloc | Default for allocation-bound work    |
| Conditionals       | `let`-chains, `let-else`              | Nested `if let` pyramids             |
| Build              | LTO + reduced codegen units           | Default release profile              |
| Bench discipline   | Criterion median/p95 + alloc counts   | "Feels faster" anecdotes             |

---

(Full document is the v2.0 standards file the operator provided 2026-05-25. The
canonical text is preserved in this file verbatim — `docs/RUST_STANDARDS.md`
is the source of truth for the rtl8125-rs Rust review rubric. Sections 1–21:
ownership/borrowing, pre-allocation, iterator chains, collection selection,
string handling, error handling, structured logging, dispatch,
concurrency, async, hashing, I/O, build config, advanced patterns, data
locality + hardware sympathy, benchmarking, hot-paths definition,
tooling/lints, code-review checklist, Edition 2024 idioms, conclusion.)

## How this driver applies the standards

### Kernel-Rust caveats (where the standards diverge from userspace)

The standards target userspace Rust with `std`. Kernel-Rust differs in
important ways already noted in the doc itself (no `std`, custom allocator,
no `LazyLock` in the same form, no `tracing` crate, etc.). For this driver:

- **Allocator** — kernel-side allocator selection is not under our control;
  use `KBox::new(value, GFP_KERNEL)` / `kernel::dma::CoherentAllocation` and
  pre-allocate sizes (M3 ring sizes already follow this).
- **Logging** — `tracing` isn't available; `pr_info!`/`dev_info!` plus
  per-tracepoint events are what we have. Plan §6.4 calls for tracepoints
  on the hot path — that lands at M4/M5.
- **Async** — kernel modules are not `async` in the userspace sense; NAPI
  poll + IRQ handlers are the equivalent. Sections 9–10 apply only to
  userspace tooling we write later (e.g. test rigs).
- **`LazyLock`/`OnceLock`** — replace with `Mutex<Option<T>>` or
  `kernel::sync::Arc` patterns as the kernel crate offers them.

### Hot paths in this driver (Section 17 application)

The following code paths are HOT and demand strict standards adherence:

1. **`napi::poll`** — RX completion + TX completion reaping (per packet).
   - **Borrow over clone**: pass `&NetdevState`, never own.
   - **Iterator discipline**: walk RX/TX rings via index, no allocations.
   - **Cache padding**: per-direction atomic indices (`tx.head/tail`,
     `rx.tail`) must be cache-line padded (`CachePadded` equivalent) —
     currently satisfied in `TxRingState` / `RxRingState`.
   - **Static dispatch**: no `dyn Trait` in poll path.
2. **`netdev::ndo_start_xmit`** — TX submission (per packet).
   - Same cache-padding requirement on `tx.head`.
   - Pre-allocate TX shadow array (already done at probe — `[AtomicPtr; N]`).
3. **`netdev::raw_irq_handler`** — IRQ handler (per interrupt).
   - Minimum work: read+ack ISR, mask further IRQs, schedule NAPI.
   - Currently follows this discipline.

Counters in `src/netdev_bridge_counters.c` (`tx_received`,
`tx_consumed`, `tx_busy_exception`, `tx_dropped_error`,
`rx_handed_to_stack`, `rx_dropped_error`) are sharded per-CPU via
`u64 __percpu *` storage with `this_cpu_inc(*b->X)` on the hot path
(a single decorated INC on x86 with no cache-line bouncing). The
ethtool / snapshot reader sums across `for_each_possible_cpu` —
acceptable cost for a non-hot-path readout. Lifecycle helpers
`r8125_bridge_counters_alloc` / `_free` allocate and free all six
counters in lockstep; the wiring is enforced by
`ci/check_counter_infrastructure.sh`.

### Mandatory enforcement (Section 18) — what CI already does

- `ci/check_unsafe_allowlist.sh` enforces the unsafe-allowlist + crate-root
  `#![deny(unsafe_code)]` + non-increasing census + raw-MMIO containment.
- `ci/check_dco_assistedby.sh` enforces the §9.2 DCO / Assisted-by policy.
- `ci/check_clippy.sh` runs `make CLIPPY=1` (the kernel-Rust build's
  in-tree Clippy — **not** `cargo clippy`) and fails on any
  `warning:`-prefixed lint. Skips cleanly when the validated
  toolchain (rustc-1.93 + clippy-driver-1.93) is absent.
- `ci/check_cache_padding.sh` enforces that non-array `Atomic*` fields
  in cross-context state structs (`NetdevState`, `TxRingState`,
  `RxRingState`, `IrqState`, `PhyState`) are wrapped in
  `CachePadded<...>` or carry an explicit `// NOT-PADDED:` annotation
  on a nearby comment line documenting why padding is unnecessary.
- `ci/check_counter_infrastructure.sh` enforces that the six §6.3
  disposition counters are wired through storage, increments,
  snapshot, and `ethtool -S`.

### When in doubt

Re-read this file before opening a PR that touches `src/napi.rs`,
`src/netdev.rs`, `src/pci.rs`, or `src/unsafe_boundary.rs`. The §6.3
ownership contract in `src/netdev_bridge.h` is the orthogonal correctness
discipline; this file is the **performance** discipline. Both apply.

---

(For the canonical full text of v2.0 with all 21 sections, see the original
operator-supplied document — the operator stores it locally; this file
captures the gist plus the rtl8125-rs-specific application notes above.
When the full v2.0 text is needed verbatim — e.g. for a third-party
reviewer — fetch it from the operator's source.)
