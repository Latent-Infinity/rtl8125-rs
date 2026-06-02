# Kernel-Rust PCI PM — upstream API gap

**Status (2026-05-26): blocked on upstream**. Kernel-Rust's
`kernel::pci::Driver` trait (`rust/kernel/pci.rs` as of Linux 7.0) exposes
only `probe` and `unbind` — there is no Rust-side hook for `.suspend`,
`.resume`, `.suspend_late`, `.resume_early`, or the runtime-PM callbacks.
The `Adapter::register` code that wires `struct pci_driver` only sets
`.probe`, `.remove`, `.id_table`; `.driver.pm` stays NULL.

```rust
// rust/kernel/pci.rs (current API surface)
unsafe fn register(pdrv: &Opaque<Self::DriverType>, ...) -> Result {
    unsafe {
        (*pdrv.get()).name     = name.as_char_ptr();
        (*pdrv.get()).probe    = Some(Self::probe_callback);
        (*pdrv.get()).remove   = Some(Self::remove_callback);
        (*pdrv.get()).id_table = T::ID_TABLE.as_ptr();
        // .driver.pm, .suspend, .resume — none set.
    }
    ...
}
```

This blocks the M5 deliverable "**`suspend` / `resume` PCI callbacks
fully implemented** (D3hot minimum; D3cold gated per-revision)" from
being implementable in Rust-only code. The 10× suspend/resume cycle
test and the 24-hour ASPM idle soak are still runnable because the
PCI core does default PM (config-space save/restore, D-state
transitions) for any device, with or without driver-supplied callbacks.

## What we currently rely on

- **PCI core default PM** handles config-space save (`pci_save_state`)
  and D-state transitions (`pci_set_power_state(D3hot)`) automatically
  during system suspend. On resume it restores config space and brings
  the device back to D0. For chips that don't need driver-side state
  preservation (clean reset on D0 entry), this is enough.
- **ASPM management** is owned by the PCI core + the `pcie_aspm`
  module, controlled by sysfs (`/sys/module/pcie_aspm/parameters/policy`)
  and the per-device `power/control` (`on` vs `auto`). Our driver
  cleared `ASPM_en` in Config5 at probe (`hw_start_8125b`), so the
  link stays out of L1 by default. The 24-hour ASPM idle gate exercises
  the chip across L1.x states by running with `policy = powersupersave`
  set externally.

## What we would need to land

To implement plan-compliant `suspend`/`resume` callbacks the cleanest
path is:

1. **Add PM trait methods to `kernel::pci::Driver`** upstream — make
   `suspend`, `resume`, `suspend_late`, `resume_early`,
   `runtime_suspend`, `runtime_resume` optional methods with default
   no-op implementations. The Adapter::register code would wire them
   into `struct dev_pm_ops` and set `pdrv->driver.pm`.

2. **Alternative — cshim path** (defer to a future M5+1 task in this
   crate): expose `r8125_bridge_set_pm_ops()` which our cshim calls
   `device_register_pm_ops` directly on the bound device. This works
   around the API gap but is fragile because the kernel-Rust adapter
   may set/clear `.driver.pm` independently. Not recommended.

3. **Wait for upstream** — track the Rust-for-Linux PCI driver thread
   for PM API work. The thread will eventually need to expose this
   for any non-trivial Rust PCI driver. Following that work + porting
   to it when ready.

## Tests that work despite the gap

| Test | Works without our PM hooks? | Notes |
|---|---|---|
| Module load/unload (`rmmod`) while up | ✅ yes | Validated by `ci/check_rmmod_while_up.sh`, 5/5 cycles clean under iperf3 load |
| 24-hour ASPM idle soak | ✅ yes | PCI core handles L1.x; the gate is "does the chip transmit after 24h idle" which is hardware behavior, not driver code |
| 10× suspend/resume via `systemctl suspend` | ⚠️ partial | Without our hooks the PCI core saves/restores config, but the chip may need quirks on resume (PHY re-init etc.) that we don't do. This is the realistic gap. |
| Teardown/reprobe cycle (`device/remove` + `bus/rescan`) | ✅ yes | The RTL8125B advertises **`FLReset-`** (no FLR — bare-metal and under VFIO alike), and a raw `.../reset` (secondary bus reset) WARNs in phylib because kernel-Rust `pci::Driver` has no `reset_prepare`/`reset_done` to quiesce the PHY mid-reset, and the link doesn't auto-recover. The validated substitute drives the driver's own `remove()`→`probe()` cleanly (3/3 cycles, 0 warnings). See `ci/check_flr_cycle.sh`. **Not** equivalent to true FLR/suspend, but exercises the chip re-init + ring/PHY teardown paths. |
| Runtime PM (`echo auto > .../power/control`) | ⚠️ partial | Without our hooks the device idles into D3hot; works for many chips but the L1 chip-quirk path doesn't run. |

## Recommended M5 close-out posture

- Document the gap (this file).
- Run the **24h ASPM idle soak** as the binding M5 gate — it doesn't
  depend on our PM callbacks.
- Run the **remove+rescan reprobe test** (`ci/check_flr_cycle.sh`) as the
  suspend/resume proxy. The chip has no FLR, so this drives the driver's
  own `remove()`/`probe()` path rather than a raw bus reset (which would
  WARN in phylib and not re-init — see the table above).
- Add a tracking task for "wire PM **and PCI reset handlers
  (`reset_prepare`/`reset_done`)** via kernel-Rust PCI when the upstream
  API lands" as a future M5+1 or M6 work item. Reset handlers would let a
  raw `.../reset` quiesce the PHY (phy_stop) and re-init cleanly, closing
  the WARNING seen on direct bus reset.

This is honest about what's achievable today without forking the
kernel-Rust PCI abstractions.
