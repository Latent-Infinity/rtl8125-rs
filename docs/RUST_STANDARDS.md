# rtl8125-rs Rust Driver / Firmware Standards

**Kernel Rust first: correctness, lifecycle safety, hardware sympathy, and
auditable unsafe boundaries.**

The goal of this project is a production-quality RTL8125 driver written
primarily in Rust, with a small audited C shim only where the kernel has no
stable Rust API yet. The standards below are the review rubric for this repo.
They adapt the operator-provided high-performance Rust guidance to the
kernel-driver and firmware-adjacent environment we actually target.

For userspace tools, the original Rust performance guidance still applies:
prefer borrowed data, bounded allocation, structured errors, buffered I/O,
static dispatch in hot paths, and benchmarked claims. For the driver itself,
kernel correctness and hardware lifecycle contracts take priority over
userspace idioms.

## Operating Principles

- **MUST** target the Rust toolchain supported by the validated kernel tree,
  not latest stable by default. This repo currently validates through the
  kernel build/Clippy path pinned in `ci/check_clippy.sh`.
- **MUST** keep the crate `#![deny(unsafe_code)]`; all unsafe Rust belongs in
  `src/unsafe_boundary.rs` and must be justified at the wrapper boundary.
- **MUST** treat MMIO ordering, DMA ownership, cache-coherency sync, IRQ/NAPI
  ordering, and teardown order as correctness contracts, not implementation
  details.
- **MUST** use release kernel builds and hardware-oriented evidence for
  performance claims: traffic rate, drops, CPU use, IRQ rate, error counters,
  soak duration, and bare-metal logs.
- **MUST NOT** use `unwrap`, `expect`, `panic!`, runtime `assert!`,
  `debug_assert!`, `todo!`, or equivalent panic-style exits in driver paths.
  Error paths must return kernel errors, unwind via RAII guards, or leave
  explicit recovery breadcrumbs.
- **SHOULD** keep hot paths allocation-free except for expected kernel skb
  allocation/copy points. Pre-allocate rings, shadows, and per-slot state.
- **SHOULD** prefer small local domain types and RAII guards over comments
  that describe ownership informally.

## General Rust Guidance, With Kernel Applicability

| Topic | Driver/Firmware rule | Userspace/tooling rule |
| --- | --- | --- |
| Ownership | Borrow state (`&NetdevState`), use domain wrappers (`DriverOwnedSkb`) for raw resources | Borrow `&T`, `&str`; avoid clone-to-compile |
| Allocation | Pre-allocate rings/shadows; no surprise allocation in IRQ/NAPI/TX hot paths | Use `with_capacity`, `SmallVec`, allocator profiling |
| Errors | Return `kernel::error::Result` or C errno; rollback with RAII | Use typed error enums and `?` |
| Logging | Use low-rate `pr_info!`/`dev_info!`; no packet hot-path logging unless gated | Use structured `tracing` |
| Async | N/A for driver core; NAPI/IRQ are the scheduling model | Native async features are fine in tooling |
| Lazy statics | Use kernel-supported synchronization primitives only | Prefer `LazyLock`/`OnceLock` |
| Dispatch | Static dispatch in packet/IRQ paths; no `dyn Trait` barriers | Same in hot paths |
| Memory layout | Cache-pad independently mutated atomics; avoid false sharing | Same, plus SoA/chunks where useful |
| I/O | N/A in driver core | Use buffered streaming I/O |
| Benchmarking | Release kernel build plus hardware counters, traffic, drops, soaks | Criterion/alloc counts are fine for tools |

## Kernel-Rust Caveats

The high-performance Rust standards were written for userspace Rust with
`std`. Kernel Rust differs:

- **Toolchain**: do not require Rust 1.95+ or Edition 2024 features unless the
  validated kernel tree supports them. New code must compile under the kernel
  Rust toolchain selected by CI.
- **Allocator**: allocator choice is not ours. Use kernel allocation APIs,
  `KBox::init` for large in-place initialization, and DMA APIs appropriate to
  the resource. Do not build large ring/state arrays on the kernel stack.
- **Logging**: `tracing` is not available in the driver. Use kernel logging
  sparingly and avoid high-frequency logs in NAPI, IRQ, and TX paths.
- **Async/concurrency**: kernel modules are not userspace async programs.
  Concurrency is driven by IRQ context, softirq/NAPI, process context, RTNL,
  and device teardown. Document which context owns each mutation.
- **Statics**: `LazyLock`, `OnceLock`, and userspace global patterns are
  tooling guidance only unless the kernel crate provides an equivalent.

## Hot Paths

The following paths are hot and must receive the strictest review:

1. **`napi::poll`**: RX completion plus TX reaping.
   - Pass `&NetdevState`; never clone or own large state.
   - Walk rings by index; no heap allocation beyond expected RX skb build.
   - Keep `tx.head`, `tx.tail`, and `rx.tail` cache-padded through
     `TxRingState` / `RxRingState`.
   - Preserve the NAPI contract: budget 0 is TX-cleanup only; re-arm IRQs
     only after `napi_complete_done`.
2. **`netdev::ndo_start_xmit`**: TX submission.
   - Compute offload bits before DMA mapping.
   - Keep at least one descriptor slot empty.
   - Commit fragment descriptors before the first descriptor.
   - Store `tx.head` before ringing the TX doorbell.
3. **`raw_irq_handler`**: interrupt path.
   - Do minimum work: read status, ack/mask the correct surface, schedule
     NAPI, return.
   - Branch on the probe-selected `IrqMode`; never guess the IRQ surface.

## Driver Safety Contracts

- **MMIO**: raw MMIO is restricted to `mmio.rs` and `unsafe_boundary.rs`.
  Register helpers must encode chip semantics clearly enough to review against
  r8169/vendor sources.
- **DMA**: every map has a single corresponding unmap on all success and
  rollback paths. Streaming RX pages must sync for CPU/device where required.
- **Descriptors**: shadow state owns metadata the chip may clobber, including
  TX DMA handle/len and fragment type. Descriptor publish order is part of the
  hardware contract.
- **IRQ/NAPI**: IRQ masking, ACK, NAPI schedule, completion, and re-arm order
  are load-bearing. Static checks must cover these orderings.
- **Teardown**: netdev unregister must occur before devres releases the BAR.
  Teardown paths must be idempotent because explicit remove and Drop can both
  observe the same resources.
- **Stack usage**: large arrays and per-ring state must be initialized
  in-place on the heap with pin-init patterns; no stack-built `NetdevState`.

## Ownership And Lifecycle

- Use RAII guards for acquired resources that need rollback: IRQ handlers, RX
  pools, DMA mappings, or future firmware/session handles.
- Use domain wrappers for raw ownership crossing FFI boundaries. Today
  `DriverOwnedSkb` is the skb ownership boundary; direct consume/free helper
  calls outside that wrapper are regressions.
- Resource release functions must be idempotent when they can be reached from
  both explicit lifecycle hooks and Drop.
- Slow-path state split is encouraged when it makes ownership clearer:
  `TxRingState`, `RxRingState`, `IrqState`, and `PhyState` are examples.
- Comments may explain contracts, but CI/static checks should enforce the
  important ones.

## Unsafe And C Shim Boundaries

- All unsafe Rust lives in `src/unsafe_boundary.rs`; every wrapper documents
  pointer lifetime, ownership, context, and post-call validity.
- The C shim is not a second driver. It may provide kernel-facing wrappers for
  APIs missing from kernel Rust, but chip policy and descriptor logic belong in
  Rust.
- C shim hot paths should use kernel helper APIs that encode object invariants
  instead of mutating kernel structure internals directly.
- Each `src/netdev_bridge*.c` file must declare and stay within a hard LOC cap.
  `ci/check_cshim_loc_caps.sh` enforces this so review size stays bounded.
- C shim helpers must keep counter side effects colocated with the kernel
  operation they account for.

## Validation And TDD Gates

Every non-trivial driver change should add or update a narrow static/runtime
gate before or with the implementation. Current mandatory gates include:

- `ci/check_unsafe_allowlist.sh`: unsafe containment, raw-MMIO containment,
  and non-increasing unsafe census.
- `ci/check_clippy.sh`: kernel-build Clippy, not `cargo clippy`.
- `ci/check_cache_padding.sh`: non-array atomics in cross-context state must
  be `CachePadded` or explicitly annotated `// NOT-PADDED:`.
- `ci/check_counter_infrastructure.sh`: six disposition counters wired through
  storage, increments, snapshot, and ethtool.
- `ci/check_napi_contract.sh`: NAPI budget, IRQ masking, and TX queue
  hysteresis ordering.
- `ci/check_rx_skb_build.sh`: RX skb-build hot path uses the NAPI-local
  allocator and skb helpers without direct `sk_buff` tail/len mutation.
- `ci/check_no_panic_paths.sh`: no `unwrap`, `expect`, `panic!`,
  runtime `assert!`, `unreachable!`, `todo!`, or `debug_assert!` in driver
  Rust sources.
- `ci/check_bare_metal_stack_teardown.sh`: heap in-place `NetdevState`
  initialization and remove-before-devres teardown.
- `ci/check_skb_ownership.sh`: `DriverOwnedSkb` linear ownership discipline.
- `ci/check_cshim_loc_caps.sh`: bounded C shim translation units.
- `ci/check_aspm_force_off_param.sh`: operator rollback knob is declared,
  default-off, and acknowledged by probe without implying host-side ASPM
  policy support before the binding exists.

Hardware validation should cover probe/remove, `rmmod` while up, sustained
traffic, jumbo MTU, MSI/MSI-X and INTx fallback, ASPM/suspend/resume, error
injection, and at least one bare-metal soak. Report concrete dates, kernel
config, hardware, traffic profile, counters, and observed failures.

## Observability

- Disposition counters are correctness evidence, not just telemetry:
  `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error` must
  hold at quiesce.
- Logs must be low-rate and actionable. Packet hot-path logging requires a
  reviewed debug gate.
- When possible, add counters or static checks instead of prose-only claims.

## Firmware-Oriented Addendum

If this code grows firmware/no-OS components, apply the stricter subset:

- no heap unless explicitly budgeted and failure-tested;
- bounded loops or watchdog-friendly progress points;
- explicit panic strategy and no unwinding assumptions;
- volatile MMIO wrappers for every register access;
- documented endian, alignment, and packed-structure rules;
- interrupt critical sections with bounded hold time;
- deterministic startup/shutdown order and brownout/reset recovery behavior.

## When In Doubt

Re-read this file before touching `src/napi.rs`, `src/netdev.rs`,
`src/pci.rs`, `src/skb.rs`, `src/unsafe_boundary.rs`, or the C shim.
The safest driver code is boring: small ownership domains, explicit hardware
contracts, static gates for the contract, and hardware evidence for claims.
