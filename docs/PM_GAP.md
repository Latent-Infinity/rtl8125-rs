# Kernel-Rust PCI PM — upstream API gap

> **RESOLUTION (2026-06-13): implemented + hardware-validated as a cfg-gated
> prototype.** The kernel-Rust PCI PM API extension and the driver's
> `suspend`/`resume` callbacks are written, build cleanly, and were validated on
> the gateway across **6 `rtcwake -m mem` suspend/resume cycles** (interface
> down + up + 3-cycle loop + a final cfg-gated confirm): every resume restores
> carrier and resumes traffic (~1.44 Gbit/s) **with no manual `ip link`
> up/down**, **0 KASAN/lockdep splats**. See "Resolution" at the bottom.

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

## 2026-06-12 — refined plan for the pm_ops attempt (gap-closure Phase 2)

Re-confirmed against the running `7.0.0-kasan` kernel tree
(`~/kbuild/linux-7.0.0/rust/kernel/pci.rs`): `Adapter::register` still wires only
`probe`/`remove`/`id_table`; `.driver.pm` stays NULL. So pm_ops is **not
implementable in driver-only code** — it needs the kernel-Rust API extension
(Option 1), which is a *kernel-tree* change, not part of the driver submission:

1. Patch `rust/kernel/pci.rs`: add optional `suspend`/`resume` (default no-op)
   to the `pci::Driver` trait; build a `static dev_pm_ops` and set
   `pdrv->driver.pm` in `register`. (The cshim hack — Option 2 — is rejected:
   it races the adapter's ownership of `.driver.pm`; the plan forbids fragile PM
   workarounds.)
2. Driver side: `suspend` = netif_device_detach + stop TX + phy_stop + mask IRQ +
   quiesce chip + (WoL: arm PCI wake); `resume` = restore + set bus master +
   rar_set + reopen-if-was-up.
3. **Build/boot cost:** changing the kernel rust core requires a **full kernel
   rebuild + reboot** of each rig (gateway, and the KVM guest for vfio coverage).

**Testing the headless gateway is now unblocked:** use `rtcwake -m mem -s N`
(suspend-to-RAM with an RTC auto-wake after N seconds) so the bare-metal box
resumes itself — a remote `systemctl suspend` would otherwise leave it
unreachable (no working WoL yet). The KVM guest can use `virsh dompmsuspend
--target mem` / `dompmwakeup` from the host (vfio-passthrough S3 to be verified).

**WoL is coupled:** `set_wol` programs the chip Config3/Config5 + magic-packet-V3
OCP sequence, but its actual wake only takes effect through the pm `suspend`
path arming PCI wake — so WoL lands with pm_ops, not before.

**Scope:** this is the "split the upstream API work" effort the plan calls for —
a kernel-Rust patch + 2 kernel rebuilds + a suspend/resume validation cycle —
best done as its own focused pass, not mixed into the ethtool feature commits.

---

## Resolution (2026-06-13)

Implemented exactly as Option 1, with a build gate so the driver still compiles
against a **stock** (unextended) kernel — the whole point of keeping it
upstreamable.

### Two contributions, kept separate

1. **Kernel-Rust PCI PM API** — `kernel-patches/0001-rust-pci-add-pm-callbacks.patch`.
   Adds default-no-op `suspend`/`resume` to the `pci::Driver` trait, a
   `suspend_callback`/`resume_callback` + `const PM_OPS: dev_pm_ops` on
   `Adapter<T>`, and sets `pdrv->driver.pm = &Self::PM_OPS` in `register()`.
   This is the upstream RfL contribution and must land before the driver side
   can be enabled on a stock tree.
2. **Driver `suspend`/`resume`** — in-tree, but gated on the `r8125_pci_pm`
   cfg (built only with `make PCI_PM=1`; compiled out of the default build):
   - `src/pci.rs`: `R8125Driver::suspend`/`resume` → cshim PM helpers.
   - `src/unsafe_boundary.rs`: `bridge_pm_suspend`/`_resume` safe wrappers
     (+ extern decls) — census 76 → 78.
   - `src/netdev.rs`: `NetdevHandle::ndev()` accessor.
   - `src/netdev_bridge.c`: `r8125_bridge_pm_{suspend,resume}` (RTNL +
     netif_device_detach/attach around the existing ndo_stop/open). `resume`
     returns `int` and only `netif_device_attach`es on a successful reopen — a
     failed re-init propagates through `bridge_pm_resume` → `Driver::resume` as
     an error rather than reattaching a dead interface.

### Build gate

`make` (default) compiles PM **out** — stock-kernel + upstream-safe, CI builds
this. `make PCI_PM=1` compiles PM **in** — requires a kernel carrying patch
0001. The Makefile always passes `-A unexpected_cfgs` so the custom cfg name is
clean under `CONFIG_WERROR` (the parenthesised `--check-cfg` form is unusable
because the kernel rustc recipe runs flags through a shell). When the kernel
API lands upstream, drop the cfg gate and make the callbacks unconditional.

### Release modes — what a given build actually ships

The cfg gate means PM is **not** in the default artifact. Be explicit about
which of the two supported builds you are shipping:

| Build | Kernel | PM in `.ko`? | Status |
|-------|--------|--------------|--------|
| `make` (default) | stock | **no** | system-sleep PM is a **known gap** — the PCI core still does its default config-save/D-state, but the driver has no `suspend`/`resume`. This is the upstream-submission build. |
| `make PCI_PM=1` | patched with `kernel-patches/0001` | **yes** | full driver suspend/resume, validated. This is the only build that should be described as "has PM". |

Do not describe a default-build artifact as having driver PM. Until the
kernel-Rust PCI PM API lands upstream, "PM shipped" means *patched kernel +
`PCI_PM=1`*; otherwise PM remains the documented gap above.

### Validation (gateway, 7.0.0-kasan, KASAN+lockdep+kmemleak+DMA_API_DEBUG)

`rtcwake -m mem -s N` (RTC auto-wake; a headless box has no working WoL yet to
wake it otherwise). dmesg per cycle: `PM: suspend entry (deep)` → our callback
`Link is Down` → resume `ndo_open complete` → `Link is Up - 2.5Gbps/Full` →
`PM: suspend exit`. Interface-down cycle no-ops cleanly (callback sees
`!netif_running`). 6 cycles, 0 splats, traffic resumes every time.

### WoL — NOT advertised (chip-arming sequence prototyped, not wired)

**Decision (2026-06-13): the ethtool WoL surface is intentionally not wired.**
An earlier pass implemented + validated the magic-packet chip arming (Cfg9346 →
OCP 0xC0B6 BIT0 → Config3.MagicPacket), and `ethtool -s wol g/d` round-tripped
on the gateway (`Wake-on: g`, PCI `power/wakeup=enabled`; unsupported modes
rejected). That validated only the *arming*, not an actual wake — and the
end-to-end wake has two unmet prerequisites, so advertising `WAKE_MAGIC` would
promise a wake the driver cannot deliver. The surface was therefore reverted;
`get_wol`/`set_wol` are tracked **PLANNED** in the surface inventory. The
arming-validation evidence is kept at
`docs/perf/pm_validation_20260613/wol_test.out` for the follow-up.

**Prerequisites for advertising `WAKE_MAGIC` (both must be met):**

1. *Suspend keeps the PHY alive.* The current PM suspend path runs the full
   `ndo_stop` (phy_stop), so the link drops in S3 and a magic packet can't be
   received. A real wake needs the vendor `powerdown_pll(from_suspend)`
   behaviour — renegotiate to a WoL link speed and keep the PHY powered, only
   when WoL is armed — coupled into the `r8125_pci_pm` suspend path.
2. *A rig that can test the wake.* The gateway's loopback topology (enp3s0 ↔
   enp4s0) can't self-test it: during S3 the magic-packet sender sleeps with the
   box. This needs an **external** sender on enp3s0's L2 segment.

Until both are done and an actual magic-packet wake is observed, WoL stays
unadvertised. (Vendor C and mainline r8169 both couple WoL programming with the
suspend/PHY-power path for exactly this reason.)
