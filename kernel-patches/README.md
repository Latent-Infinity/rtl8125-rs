# kernel-Rust PCI abstraction patches (0001–0005)

These patches extend the in-tree kernel-Rust PCI abstraction
(`rust/kernel/pci.rs`) to expose PCI lifecycle callbacks it does not yet provide.
They are **independent of this driver** — any Rust PCI driver would use the same
hooks — and are intended for upstream submission to the rust-for-linux / netdev
lists as abstraction enhancements, separate from the r8125_rust driver itself.

The driver consumes each hook behind a `cfg` (see the Makefile knobs), so the
default `make` build stays buildable against a **stock** kernel; only a build
with the matching knob requires the corresponding patch.

| Patch | Adds to `pci::Driver` | C struct wired | cfg / Makefile knob | Apply with |
|-------|-----------------------|----------------|---------------------|------------|
| 0001 | `suspend` / `resume` | `dev_pm_ops PM_OPS` (suspend/resume/freeze/thaw/poweroff/restore) → `driver.pm` | `r8125_pci_pm` / `PCI_PM=1` | `patch -p0` |
| 0002 | `shutdown` | `pci_driver.shutdown` | `r8125_pci_shutdown` / `SHUTDOWN=1` | `tools/patch_pci_shutdown.py` |
| 0003 | `reset_prepare` / `reset_done` | `pci_error_handlers ERR_HANDLER` → `pci_driver.err_handler` | `r8125_pci_reset` / `RESET=1` | `tools/patch_pci_reset.py` |
| 0004 | `error_detected` / `slot_reset` / `error_resume` | AER fields on `ERR_HANDLER` | `r8125_pci_aer` / `AER=1` | `tools/patch_pci_aer.py` |
| 0005 | `runtime_suspend` / `runtime_resume` / `runtime_idle` | runtime fields on `PM_OPS` | `r8125_pci_runtime_pm` / `RUNTIME_PM=1` | `tools/patch_pci_runtime_pm.py` |

## Dependency order

Apply in numeric order against a clean `rust/kernel/pci.rs`:

1. **0001** is the base — it introduces `PM_OPS` and `driver.pm`. 0005 extends
   that same `PM_OPS` (DRY: runtime PM reuses the system-sleep dev_pm_ops).
2. **0003** introduces `ERR_HANDLER` (`pci_error_handlers`) and `err_handler`.
   0004 extends that same const with the AER callbacks.
3. 0002 is independent (only `pci_driver.shutdown`).

The `tools/patch_pci_*.py` appliers are idempotent-checked: each asserts its
anchor appears exactly once, so a missing prerequisite fails loudly rather than
mis-patching. 0001 is a plain unified diff (`patch -p0`).

## Shape of each patch (kernel-Rust convention)

Every callback follows the same three-part shape already used by the abstraction's
`probe`/`remove`:

1. a **trait method** on `pci::Driver` with a safe default (no-op / benign
   return) so existing drivers are unaffected;
2. an `extern "C"` **thunk** that recovers the `pci_dev` via
   `container_of!` / `cast`, borrows drvdata with `drvdata_borrow::<T>()`, and
   calls the trait method — each unsafe step carrying a `// SAFETY:` comment;
3. **registration** of the thunk into the relevant C struct (`pci_driver` field,
   `dev_pm_ops`, or `pci_error_handlers`).

The AER callbacks return `pci_ers_result_t`; the channel state arrives as
`pci_channel_state_t`. Both are passed through as the raw bindgen types — the
driver maps them to/from Rust enums in `src/aer.rs` (host-tested, ABI-pinned).

## Validation

All five are validated live on the RTL8125B gateway (7.0.0-kasan, PROVE_LOCKING +
KASAN). See `docs/perf/feature_smoke/{pci_aer.txt,runtime_pm.txt,pci_reset_aer.txt,
afxdp_zerocopy.txt}` and `docs/PM_GAP.md`. Notably, AER and runtime PM were
validated **together** (the combination first exposed, then cleared, an
rtnl ↔ pci_bus_sem lockdep ABBA — the AER callbacks are deliberately rtnl-free).

## For upstream submission

These `.patch` files are mechanical diffs (no commit message). Before posting,
turn each into a proper commit with a Signed-off-by and a changelog explaining
the new `pci::Driver` hook, per Documentation/process/. The driver-side `cfg`
gating can drop once the abstraction lands upstream.
