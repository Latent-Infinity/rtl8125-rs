# rtl8125-rs — Capability Plan: full parity + standout features

Status anchor: the netdev/ethtool surface inventory is **41 present, 0 planned,
7 deferred** (`ci/check_surface_inventory.sh`). Core datapath, RSS multi-queue,
the ethtool control plane, WoL *control* surface, and (cfg-gated) system-sleep
PM are done + validated. This plan closes the remaining real parity gaps against
mainline `r8169` and vendor `r8125`, enables the Tier-2 capabilities that need a
kernel-Rust PCI API extension, and adds the net-new features **neither** C driver
has — to make the Rust driver clearly exceed both.

## Principles (apply to every item)

- **SOLID / thin-cshim + thick-Rust split.** C owns kernel objects with no
  stable Rust API (net_device, NAPI, sk_buff, page_pool, the ops tables, bpf/xdp
  APIs); Rust owns chip state, rings, policy. They meet only in
  `src/unsafe_boundary.rs` (the sole Rust `unsafe` module; `#![deny(unsafe_code)]`
  crate-wide). Each new C translation unit has one reason to change and one
  kernel subsystem boundary.
- **DRY.** Reuse existing bridges (`r8125_bridge_pm_suspend/_resume` for every
  quiesce/re-init; the single `PM_OPS` for all PM; the TX reserve/commit path for
  every TX producer). One source of truth per concept; host-test it. Do not add a
  second cache of MAC address, WoL state, queue count, feature flags, or firmware
  state unless the plan names the owner and the synchronization rule.
- **KISS.** Prefer the always-on simple geometry / pointer-swap over conditional
  rebuilds. Reject features mainline itself rejects (coalesce on RTL8125, live
  ring resize) unless new hardware evidence proves they carry their weight. No
  private ioctl/procfs/debugfs surfaces for features that already have a standard
  ethtool, phylib, hwmon, devlink, or netdev-genl API.
- **TDD.** Write the failing guard first, then the implementation. Pure logic
  lives in small kernel-free domain modules (`src/layout.rs` today; add
  `src/phy_fw.rs`, `src/xdp_plan.rs`, etc. only when they have their own tests)
  with `#[cfg(test)]` host tests (`ci/check_rust_unit_tests.sh`) plus
  `const _: assert!()` compile-time ties where layout matters. Hardware behavior
  is validated on the gateway/KVM KASAN+lockdep rigs with 0 splats. Every new
  surface flips a `ci/check_surface_inventory.sh` row or adds an equivalent
  static gate.
- **Performance first.** The no-XDP / no-new-feature fast path must stay
  byte-for-byte as fast (Track-B `-P16` win must not regress). New per-packet cost
  is a single predicted-not-taken branch at most; new MMIO is amortized once per
  NAPI poll.
- **Upstreamability.** Kernel-Rust API additions ship as out-of-tree kernel
  patches (`kernel-patches/`) with driver code cfg-gated so the default `make`
  build stays buildable on a stock kernel; each is flagged for the matching
  upstream RfL contribution.

---

## Batch contract

Every batch must be reviewable on its own. A batch that mixes a kernel-Rust API
extension, a new cshim subsystem, a hot-path change, and a documentation rename
is too large.

1. **Red gate first.** Add or tighten the host unit test, static inventory row,
   cshim LOC cap, or hardware-smoke script before wiring the feature.
2. **Smallest implementation.** Add the narrowest callback/helper/table needed
   for that gate. Keep chip policy in Rust and kernel object lifetime in C.
3. **No silent support.** Unsupported settings return `-EOPNOTSUPP` or
   `-EINVAL`; accepted settings must read back from the active driver state or
   hardware.
4. **Rollback path.** Any operation that can fail after hardware writes must name
   the rollback owner and have a failure-injection or repeated-cycle test.
5. **Evidence.** Each batch lands with `ci/run_checks.sh`, `git diff --check`,
   the relevant host tests, and a hardware smoke artifact when behavior changed.

Definition of done for a capability:

- host unit tests cover pure decisions and edge cases, including invalid input;
- static gates prove the advertised surface is present or intentionally absent;
- default `make` remains stock-kernel buildable, with cfg-gated builds documented;
- hardware validation covers down-interface, running-interface, suspend/resume
  where relevant, and post-failure recovery;
- docs remove limitations only after the evidence exists.

---

## Workstream W1 — Tier-1 parity (real, functional)

### W1.1 PHY firmware + `hw_phy_config` — the biggest gap
**Finding (verified on hardware):** PHY is `Realtek Internal NBASE-T PHY`
(`phy_id 0x001cc840`); **no `rtl8125b-2.fw` on the system, no firmware load in
dmesg, no MAC-side `hw_phy_config`.** Both mainline (`rtl8125b_hw_phy_config` +
`r8169_apply_firmware`) and vendor apply ~40 PHY register tunes + a firmware MCU
patch we don't. Link runs at 2.5G without it, but it patches PHY errata (signal
integrity, EEE/link-stability corners) and a reviewer will require it.

- **Design (DRY/KISS):** port `rtl8125b_hw_phy_config` to Rust chip code
  (`src/phy.rs` / `src/mmio.rs` OCP/MDIO accessors already exist) as a
  host-tested table of declarative PHY operations, run from the PHY bring-up
  bracket (`netdev_bridge_phy.c` → Rust). Add `r8169_apply_firmware`-equivalent:
  load `rtl_nic/rtl8125b-2.fw` via a tiny `request_firmware` cshim + a Rust
  firmware-opcode decoder in a new kernel-free module (`src/phy_fw.rs`). Decode
  and validate the whole blob into a bounded operation list before any PHY write.
  Place the firmware blob requirement in the .rst + `MODULE_FIRMWARE`.
- **TDD:** `src/phy_fw.rs` lands first with fixtures for opcode decode, branch
  bounds, malformed/truncated blobs, max-operation limits, and checksum/version
  handling. A static gate proves the firmware path cannot write until decode
  succeeds. Hardware: confirm `dmesg` shows the firmware version loaded; compare
  PHY register dump (`ethtool -d` once W4.x extends it, or MDIO reads) against
  vendor post-config values; link-stability soak with EEE enabled and disabled.
- **Performance:** one-time at open; no hot-path cost.
- **Risk:** firmware blob licensing/redistribution (reference the in-tree
  `linux-firmware` `rtl_nic/rtl8125b-2.fw`); opcode interpreter correctness
  (host-tested). **Highest-value W1 item.**
- **Errata table DONE + validated (2026-06-15).** `rtl8125b_hw_phy_config` (26
  ops) ported as a host-tested table in `src/phy_config.rs` (`PhyOp` → pure
  `expand` → phylib paged/MMD accessors via 4 cshim wrappers); applied in the
  open path after PHY connect/reset, before the link state machine. Confirmed:
  the stock phylib realtek driver applies NONE of this. Validated on the gateway:
  3 link cycles all negotiate 2.5G stably, line-rate traffic (2.34 Gbit/s -P8),
  EEE works, 0 splats. Census 78 → 82 (4 PHY-accessor wrappers, justified).
  Evidence: `docs/perf/feature_smoke/phy_hw_config.txt`.
- **Firmware (MCU patch) DONE + validated (2026-06-15).** `src/phy_fw.rs` —
  host-tested (7 tests) port of `r8169_firmware.c` (`rtl_fw_format_ok` +
  `rtl_fw_data_ok` + `rtl_fw_write_firmware`): full validation before any write,
  and the **dual-target** interpreter (`PHY_MDIO_CHG` switches MAC-OCP ↔ PHY) over
  a `FwSink` trait. Loaded via the safe `kernel::firmware::Firmware` API (no
  cshim, no new unsafe for the request); the kernel `PhyFwSink` routes PHY ops
  through `r8168g_mdio_write` semantics (our `phy` module) and MAC-OCP ops through
  `mac_ocp_write`, sharing `state.phy.ocp_base` like r8169's `tp->ocp_base`. Runs
  *before* the errata table in the open path; post-apply resets the page base +
  polls BMCR. `MODULE_FIRMWARE` + `ethtool -i` fw_version (`set_fw_version`
  cshim, census 82 → 83). Validated on the gateway: the real 800-op blob applies
  (125 MAC-OCP + 675 PHY), `firmware-version: rtl8125b-2_0.0.2 07/13/20`, link
  2.5G, line-rate traffic, 0 splats. Optional: absent/invalid fw → errata-only
  fallback (matches r8169). Evidence: `docs/perf/feature_smoke/phy_firmware.txt`.
  **W1.1 complete — biggest parity gap closed.**

### W1.2 `ndo_set_mac_address` live RAR write
**Finding:** ours is bare `eth_mac_addr`; mainline `rtl_set_mac_address` writes
the new MAC to the chip RAR on a live change. We only program the RAR at open, so
`ip link set dev X address ...` while up leaves the hardware unicast filter stale.

- **Design:** replace `.ndo_set_mac_address = eth_mac_addr` with
  `bridge_ndo_set_mac_address` → validate/update the netdev address once, then if
  running call the existing Rust RAR writer through a small vtable op
  (`set_mac_filter`) reusing `mmio::set_mac_address`. Set `IFF_LIVE_ADDR_CHANGE`
  only when live programming is proven.
- **TDD:** add a static gate that rejects bare `eth_mac_addr` in the ops table;
  host-test the MAC→RAR low/high u32 packing in the domain module that owns it;
  hardware: `ip link set address` while up + unicast ping must keep flowing
  without reopen, and down-interface address change must program on next open.
- **Small, validatable, do early.**

### W1.3 WoL deep-S3 wake path — DONE + validated (2026-06-16, task #56)
**Magic-packet wake from real S3 deep sleep works**, validated end-to-end with an
external sender on the cross-machine rig (controller igc → gateway DUT).

- **Root cause of the long-standing gap:** the suspend powered the chip-internal
  PHY down, so no magic packet reached the wake detector. The fix is the
  r8169-mainline `__rtl8169_set_wol` recipe applied in a WoL-aware suspend branch:
  - `Config1.PMEnable` (master chip PME — our `set_wol` never set it),
    `Config2.PMSTS_En`, RxConfig accept bits, and the chip wake bits (`set_wol`).
  - **`PMCH` `D3HOT|D3COLD_NO_PLL_DOWN` (`rtl_set_d3_pll_down(false)`)** — keep the
    chip PLL (hence the PHY) powered across D3. *This* is the keep-alive; no link-
    speed change is needed, so the earlier phylib-worker / autoneg-timing dead ends
    are gone.
- **Suspend = light quiesce** (`napi_disable` only; NO `bridge_ndo_stop` /
  `phy_stop` / `free_irq`) so the PHY is never powered down; `wol_suspend_arm`
  (Rust op) does the chip arming. **Resume** rebalances NAPI + a full stop+reopen
  to clear the D3-reset chip state. Prerequisite fix: clear the IRQ affinity hint
  before `free_irq` (`irq_update_affinity_hint(NULL)`) — the kasan kernel WARNed on
  every `ndo_stop` otherwise (also fixes the rtcwake path).
- **Validation** (`docs/perf/feature_smoke/wol_wake_s3_external_sender.txt`): WoL
  armed → 3/3 cycles woke ~9 s after the magic packet (carrier stayed up in S3),
  0 KASAN/WARN/BUG; WoL disabled → woke only on the 240 s RTC safety (PHY down, no
  spurious wake — the non-WoL full-stop path is intact). Static contract gate
  `ci/check_wol_suspend.sh`. Needs the PM-patched kernel + `make PCI_PM=1` (same
  cfg as the rest of system-sleep PM).

---

## Workstream W2 — Tier-2 kernel-Rust PCI capability enablement

Done as a small kernel-patch series (reset and AER ended up split for clarity).
See `kernel-patches/README.md` for the full table + dependency order. ALL DONE +
validated live on the gateway (2026-06-19):

- `0002-rust-pci-add-shutdown-callback.patch`
- `0003-rust-pci-add-reset-callbacks.patch`
- `0004-rust-pci-add-aer-callbacks.patch`
- `0005-rust-pci-add-runtime-pm-callbacks.patch`

Each patch extends `pci::Driver` exactly like the landed `0001` PM patch:
default-no-op trait method, adapter thunk, one registration hook, and driver code
behind a matching cfg (`r8125_pci_shutdown`, `r8125_pci_aer`,
`r8125_pci_runtime_pm`). The default `make` path remains stock-kernel-buildable.
**DRY:** runtime PM extends the *existing* `PM_OPS`; `.shutdown`/AER reuse the
existing `bridge_pm_suspend/_resume` quiesce/re-init bridges. **KISS:** do not
add a new driver-private PM state machine unless a test proves the shared
quiesce/re-init bridge is insufficient.

Landing order = cheapest/most-upstreamable first:

### W2.1 `.shutdown` — DONE (2026-06-18)
- `kernel-patches/0002-rust-pci-add-shutdown-callback.patch`: adds
  `pci::Driver::shutdown` (default no-op), `shutdown_callback` (takes `pci_dev*`
  like remove, void), and the `(*pdrv.get()).shutdown = Some(...)` registration —
  mirrors the 0001 PM patch. Applied to the gateway kernel tree + kasan rebuilt.
- Driver: cfg-gated `fn shutdown` (`r8125_pci_shutdown`, Makefile `SHUTDOWN=1`)
  reusing the validated `bridge_pm_suspend` quiesce (no DriverData drop). The
  `bridge_pm_suspend` + `ndev` cfgs were widened to `any(r8125_pci_pm,
  r8125_pci_shutdown)`. Default `make` stays stock-kernel buildable; CI 406/0.
- **Validated:** built `SHUTDOWN=1`, loaded + bound, reboot completed CLEANLY
  (~120s; a hung .shutdown would stall the reboot — it didn't), quiesce is the
  identical fully-validated PM path. Positive printk capture of the shutdown line
  was NOT achievable on this rig (device_shutdown runs after journald stops; no
  pstore; netconsole emits nothing over this driver — no netpoll/W3.5). Evidence:
  `docs/perf/feature_smoke/pci_shutdown.txt`. The remaining W2.2–W2.4 hooks
  (reset/AER/runtime-PM) need NO reboot to validate (live sysfs-reset / aer-inject
  / autosuspend), only a kernel rust/ rebuild per patch.

### W2.2 `reset_prepare` / `reset_done` — DONE + VALIDATED (2026-06-19, with W2.3)
- `kernel-patches/0003-rust-pci-add-reset-callbacks.patch`: adds
  `pci::Driver::reset_prepare`/`reset_done` + the two `pci_dev*` void thunks + an
  `ERR_HANDLER: pci_error_handlers` const wired via `(*pdrv.get()).err_handler`.
  Driver: cfg-gated (`r8125_pci_reset`, `RESET=1`) reset_prepare = bridge_pm_suspend
  quiesce, reset_done = bridge_pm_resume re-init. Built + loaded clean; CI green.
- **VALIDATION FINDING:** `echo 1 > /sys/.../reset` on this device does NOT cleanly
  hit reset_prepare/done — the device's only `reset_method` is "bus" (secondary
  bus reset), which generates a PCIe **Uncorrectable AER** (UnsupReq), so the
  kernel takes the AER path. dmesg: *"AER: can't recover (no error_detected
  callback)"* — which PROVES our err_handler is registered (the core read it) but
  bails for lack of `error_detected` (= W2.3). Link recovered, no phylib WARN, no
  KASAN, datapath fine. So reset_prepare/reset_done are correctly wired; on THIS
  device the reset is AER-driven, so exercising them on-wire needs the W2.3 AER
  handlers (the AER recovery's slot_reset calls reset_prepare/reset_done). W2.2 +
  W2.3 validate together. Evidence: `docs/perf/feature_smoke/pci_reset_aer.txt`.

### W2.3 Full AER error handlers — DONE + VALIDATED (2026-06-19)
- `kernel-patches/0004-rust-pci-add-aer-callbacks.patch`: `error_detected` /
  `slot_reset` / `error_resume` (named `error_resume` to avoid the PM-`resume`
  clash) + AER fields on the `ERR_HANDLER` const. The mirrored enums
  `ChannelState`/`ErsResult` live in host-tested `src/aer.rs`.
- **DEVIATION from plan:** no `bindings_helper.h` change was needed — bindgen
  already emits `pci_channel_io_*` and `pci_ers_result_PCI_ERS_RESULT_*`. The ABI
  is pinned by a compile-time `const _` assert in `src/pci.rs` tying `aer.rs`'s
  values to the real `bindings::` constants.
- **DEVIATION (verdict policy):** a non-fatal (`Normal`) channel returns
  **CanRecover**, NOT NeedReset — this controller's only reset_method is a
  secondary-bus reset, and the chip emits an Uncorrectable error on *every* bus
  reset, so NeedReset → slot reset → another error → endless **reset storm**
  (observed live, then fixed to the igb pattern). Only `Frozen` → NeedReset.
- **DEVIATION (frozen-MMIO):** rather than "branch on state, MMIO only when
  Normal", the AER callbacks are RTNL-free and Normal does nothing at all (the
  device keeps working / was re-init'd by reset_done); only Frozen/PermFailure
  quiesce. RTNL-free is load-bearing: AER runs under `pci_bus_sem`, and taking
  rtnl there deadlocks against the runtime-PM D-state path (W2.4) — an ABBA
  lockdep caught and we fixed. `ci/check_aer.sh` statically enforces rtnl-free.
- **Validated:** `echo 1 > /sys/.../reset` → `error_detected Normal->CanRecover`
  → "AER: device recovery successful" (was "can't recover"); 3× resets = 3
  recoveries, 1:1 no storm, 0 splats, datapath OK. Evidence
  `docs/perf/feature_smoke/pci_aer.txt`.

### W2.4 Runtime PM — DONE + VALIDATED (2026-06-19)
- `kernel-patches/0005-rust-pci-add-runtime-pm-callbacks.patch` populates the
  existing `PM_OPS` `runtime_suspend`/`runtime_resume`/`runtime_idle` slots (DRY:
  NO second `dev_pm_ops`). The `pm_runtime_*` inlines are **cshim** wrappers
  (`r8125_bridge_pm_runtime_*` / `r8125_bridge_runtime_*`) behind cfg-gated safe
  wrappers (`r8125_pci_runtime_pm` / `RUNTIME_PM=1`).
- **DEVIATION (KISS, anti-wedge):** the model is *closed-interface autosuspend*,
  NOT the per-TX get/put originally sketched. `runtime_idle` vetoes (`EBUSY`)
  whenever `netif_running`, so the suspend/resume callbacks only ever run on a
  closed interface — they just `netif_device_detach`/`attach` (no rings, no
  RTNL); the PCI core does the D-state. This avoids the per-packet `get_sync`
  cost AND the rtnl/ring hazards. Autosuspend is gated on `pci_dev_run_wake`
  (mirrors r8169).
- **Anti-deadlock:** the ndo open/stop `pm_runtime_get/put_sync` brackets live in
  dedicated `*_entry` wrappers (only the netdev_ops entry), NOT in
  `bridge_ndo_open/stop` — those are reused by the PM/reset/AER resume paths,
  where `get_sync` from inside a runtime callback would deadlock. Probe-end drops
  the core's usage ref (run-wake gated); unbind re-takes it. `ci/check_runtime_pm.sh`
  pins these invariants.
- **Validated (gateway):** `power/control=auto` + ifdown → `runtime_status`
  suspended (real D3); ifup → active; 3× cycles, interleaved with AER, **0
  lockdep/KASAN splats** (the combined AER+runtime-PM build is the ABBA test).
  Evidence `docs/perf/feature_smoke/runtime_pm.txt`.

Upstream split: `.shutdown` + `reset_*` → strong RfL candidates; ERS enums →
heavier RfL series; `pm_runtime_*` helpers → RfL `rust/helpers/`.

---

## Workstream W3 — Tier-3 parity (implementable, modest value)

### W3.1 LEDs — DONE + validated (2026-06-16)
- The 4 RTL8125 LEDs are exposed as `led_classdev` devices with the kernel
  "netdev" hw_control trigger (offload), ported from mainline `r8169_leds.c`.
  **Split:** the `led_classdev` lifecycle + the `TRIGGER_NETDEV_*` <-> chip
  `LED_CTRL` mapping live in the cshim (`netdev_bridge_leds.c`, kernel enum +
  LED-class knowledge); the LEDSEL register selection + masked update are the
  host-tested Rust `crate::led` encode (`src/led.rs`, 4 host tests:
  `led_reg`/`merge_mode`/`mode_from_reg`) reached via `ops.led_set_mode` /
  `ops.led_get_mode`. C does not poke the LEDSEL registers directly (gate
  `ci/check_led.sh`). No kernel patch (needs `CONFIG_LEDS_CLASS` +
  `LEDS_TRIGGER_NETDEV`, present on the gateway).
- **Validated on gateway** (`docs/perf/feature_smoke/led_netdev_trigger.txt`): 4
  LED class devices register; a single-flag offload (link_100) writes LEDSEL =
  0x02 exactly; link_2500 + activity writes 0x220 exactly; `hw_control_get`
  round-trips the flags; tx-without-rx is rejected `-EOPNOTSUPP` (chip activity is
  combined); dmesg clean. Exceeds the vendor (no upstream LED support) and reaches
  mainline parity.

### W3.2 Feature-flag parity — DONE (HIGHDMA; RXALL/RXFCS stay deferred)
- **`NETIF_F_HIGHDMA` DONE + confirmed (2026-06-17).** Advertised in
  `netdev_bridge.c` (`ndev->features |= NETIF_F_HIGHDMA`, a fixed capability in
  `features` not `hw_features`, like mainline r8169). On-wire: `ethtool -k enp3s0`
  → `highdma: on [fixed]`. Cosmetic marker (the 64-bit DMA mask is already set);
  isolated from RX behavior.
- Advertise `NETIF_F_HIGHDMA` if the target kernel still expects it as a visible
  capability marker. This is cosmetic because the driver already sets the 64-bit
  DMA mask; keep it isolated from behavioral RX changes.
- `NETIF_F_RXALL` / `NETIF_F_RXFCS` stay deferred until the RX path can prove skb
  metadata, checksum state, length accounting, and FCS handling are correct for
  errored/FCS-retained frames. These are not "just RCR bits."
- **TDD:** host-test only the feature-mask/RCR decision first. Hardware must use
  controlled bad-frame/FCS captures before flipping the inventory row.

### W3.3 Custom RSS key/table and `rxnfc`
- Current behavior is intentionally simple: default Toeplitz key and default
  indirection spread for the active queue count. For a gateway/load-balancer,
  custom key/table support is useful and should be the next real operator
  control after W1/W2.
- **Design:** add one Rust-owned RSS policy object that stores the active key,
  indirection table, and hash options. `get_rxfh` reads that object; `set_rxfh`
  validates and swaps it atomically under RTNL; hardware programming uses the
  same `apply_rss_programming` path for boot, open, channel changes, and live
  updates. `rxnfc` is limited to hash-field options the chip can really express;
  n-tuple steering remains unsupported unless the hardware classifier is proven.
- **TDD:** host-test table length, queue bounds, default equivalence, custom-key
  equality, unsupported hfunc, and channel-count shrink behavior. Hardware:
  `ethtool -X/-x` readback must match, invalid changes must leave the old table
  active, and flow distribution must move as expected.
- **Custom key/table DONE + validated (2026-06-16).** Rust-owned `RssPolicy`
  (`src/rss.rs`, 11 host tests) holds the active key + 128-bucket table; storage
  is lock-free atomics in `NetdevState` (RTNL-only, no hot-path touch), round-
  tripped via `rss_policy_snapshot`/`store`. `get_rxfh`/`set_rxfh` call new
  `ops.rss_get`/`rss_set`; the chip reprograms live through the existing
  `apply_rss_programming` path (one programming path for boot/open/channel/live).
  A default-equal table collapses to "track default"; `set_channels` reclamps a
  now-invalid custom table. **Validated on gateway**
  (`docs/perf/feature_smoke/rss_custom_key_table.txt`): custom indir persists +
  reads back (non-default); custom hash key reads back exactly (the chip key is
  write-only, so this proves the Rust cache); reclamp keeps valid / kernel guards
  invalid shrink; 0 KASAN splats; `ethtool -X default` restores. The single-queue
  fast path is unchanged. **rxnfc hash-field selection + n-tuple remain deferred**
  (fixed chip hash fields; no proven classifier).

### W3.4 EEPROM / OTP diagnostics
- `get_eeprom` remains deferred. The RTL8125B platform appears to rely on OTP /
  firmware state rather than a conventional external EEPROM. Do not expose
  `ethtool -e` until the read path, bounds, and content meaning are proven.
- **Design if reopened:** read-only first; no write support. Return
  `-EOPNOTSUPP` on chips without a safe readable store.
- **TDD:** pure bounds/version helper; hardware proof on at least one chip with
  known content. No byte-dump API that can race reset/remove.

### W3.5 Netpoll / netconsole
- Useful for panic-time diagnostics but not free: `ndo_poll_controller` cannot
  sleep, cannot take locks that netpoll forbids, and must coordinate with NAPI
  and IRQ masking.
- **Design:** only after the IRQ/NAPI ownership model has a reviewed poll entry.
  Keep the callback C-thin and reuse the existing NAPI poll path.
- **TDD / validation:** static gate for no sleeping calls in the callback;
  netconsole smoke plus panic-path polling test on the gateway.

### W3.6 Ring resize and coalesce stay closed until evidence changes
- `set_ringparam`: keep unsupported for the first RFC. Down-only resize is a
  possible future feature, but it must be its own batch with ring allocation,
  page_pool teardown, BQL reset, queue stop/wake, and rollback tests. Live resize
  is not planned.
- `get/set_coalesce`: keep unsupported on RTL8125 because mainline r8169 returns
  `-EOPNOTSUPP` and the INT_MITI V2 timer unit is not characterized. Module
  parameters remain the low-level tuning surface.
- **Gate:** the inventory rows stay `DEFER` unless new hardware evidence and a
  stable user-visible unit are documented first.

---

## Workstream W4 — Standout features (neither C driver has)

Ordered by value for this device's gateway/load-balancer role.

### W4.1 XDP (headline) — staged
Full design in the research notes; summary + staging:

- **Stage -1 — red tests / scaffolding:** before changing RX geometry, add
  `ci/check_xdp_contract.sh` with expected absent/present markers per stage, add
  host tests for XDP headroom geometry, and add a perf artifact placeholder that
  records the Track-B fresh-load baseline. This prevents an unmeasured hot-path
  regression from slipping in with the first geometry patch.
- **Stage 0 — geometry: DONE + validated (2026-06-15).** RX headroom is now
  `max(NET_SKB_PAD, XDP_PACKET_HEADROOM)=256` unconditionally
  (`netdev_bridge_rx_pool.c`), so an XDP attach/detach is a pointer swap (no pool
  rebuild). At standard MTU the page order is unchanged. Regression-isolated on
  the gateway: `-P16` held **2.34 Gbit/s** line rate, 0 splats — no hot-path cost.
- **Honest-advertisement finding (2026-06-15):** `NETDEV_XDP_ACT_BASIC` is the
  all-drivers set (PASS/DROP/**TX**/ABORTED), so advertising XDP at all requires
  XDP_TX — which needs the Stage-2 Rust TX-ring producer + `TxSlotKind` page
  disposition (the #1 use-after-free risk; needs a KASAN page-recycle soak). So
  Stages 1+2 must land together before `xdp_features` is advertised; the RX-only
  read path can't be shipped honestly on its own. This is the large next batch —
  kept its own focused effort per the batch contract ("a hot-path change is too
  large to mix"), not rushed.
- **Stage 1 — RX read path: DONE + validated (2026-06-15).** `xdp_rxq_info_reg`
  per RX queue at open (against the page_pool memory model); the prog runs inside
  `r8125_bridge_rx_one_packet` via `r8125_bridge_xdp_run` (prog / `xdp_buff` /
  `bpf_prog_run_xdp` live 100% in `netdev_bridge_xdp.c` — never in
  `unsafe_boundary`). PASS falls through to the skb path with adjusted off/len,
  DROP/ABORTED recycle (`page_pool_put_page`) + refill, REDIRECT via
  `xdp_do_redirect` + end-of-poll `xdp_do_flush` (per-queue `xdp_redirect_pending`).
  `ndo_bpf` attach/detach stores one device-wide RCU `bpf_prog*`
  (`rcu_replace_pointer_rtnl` under RTNL; `rcu_dereference_bh` in NAPI;
  RCU-deferred put). No-prog fast path = one predicted-not-taken branch.
  **Validated on gateway** (`docs/perf/feature_smoke/xdp_rx_readpath.txt`):
  native driver-mode attach succeeds *without* `xdp_features` advertised; DROP =
  100% loss, PASS = 0% loss, detach restores; no-prog TX 2.34 / RX 1.46 Gbit/s
  (== baseline, no regression); KASAN-clean across attach/drop/pass/detach + soak.
  **`xdp_features` stays unadvertised** until Stage 2 — `NETDEV_XDP_ACT_BASIC`
  includes XDP_TX, so advertising it before XDP_TX works would be dishonest.
  Copy-mode AF_XDP unlocks once `BASIC|REDIRECT` is advertised in Stage 2.
- **Stage 2 — XDP_TX: DONE + validated (2026-06-15).** The Rust-owned TX ring
  gains a new producer `xdp_tx_enqueue` (`rust_xdp_xmit_one` op) and a per-slot
  `TxSlotKind {Skb, Xdp}` tag (an `AtomicU8` shadow array). The C verdict path
  (`netdev_bridge_xdp.c`) converts the buffer to an `xdp_frame`, DMA-maps it
  TO_DEVICE, and enqueues under the txq lock (**R2** — `__netif_tx_lock`
  serialises this NAPI-context producer against `ndo_start_xmit`); a per-queue
  `xdp_tx_pending` flag drives one doorbell at poll end (`ops.xdp_tx_flush`).
  The reaper branches on the tag: `Skb` takes the existing `napi_consume_skb`
  path; `Xdp` does `dma_unmap` + `xdp_return_frame` (which returns the page to
  its origin page_pool via the frame's mem model) and resets the tag — so XDP_TX
  is deliberately outside the skb disposition invariant / BQL. **Disposition
  collapses to two kinds, not three:** routing every XDP frame through
  `xdp_return_frame` (vs a page_pool-DMA `page_pool_put_full_page` fast path) is
  the KISS/correctness-first choice and makes Stage 3 (`ndo_xdp_xmit`) share the
  exact path; the page_pool-DMA optimization is a later refinement.
  **Validated on gateway** (`docs/perf/feature_smoke/xdp_tx_datapath.txt`):
  `xdp-features = {basic, redirect}` confirmed via netdev-genl; on-wire reflection
  proven (echo-requests double 16→31); **30 s KASAN flood soak, 2722 reflections,
  TX ring wrapped 10×, zero splats (R1 clear)**; no-prog TX 2.34 Gbit/s (no
  regression); clean attach/detach. `xdp_features = BASIC | REDIRECT` is now
  advertised honestly. Copy-mode AF_XDP unlocked for free.
- **Stage 3 — `ndo_xdp_xmit`: DONE + validated (2026-06-16).** The redirect-target
  transmit side. `r8125_bridge_ndo_xdp_xmit` (`netdev_bridge_xdp.c`) takes the txq
  lock once per batch, loops the **shared** `xdp_frame_xmit_locked` (factored out
  of the XDP_TX path — one TX producer, no second implementation), rejects
  non-linear frames until the SG bit is advertised, returns any unconsumed tail
  frames on partial failure, returns `nxmit`, rings one doorbell on
  `XDP_XMIT_FLUSH`, and rejects unknown flags (`-EINVAL`) / no-carrier
  (`-ENETDOWN`). The reaper's `TxSlotKind::Xdp` disposition already returns foreign frames via
  `xdp_return_frame` (the frame's own mem model routes the page to its ORIGIN
  pool). `xdp_features` now advertises **`BASIC | REDIRECT | NDO_XMIT`**.
  **Validated on gateway** (`docs/perf/feature_smoke/xdp_ndo_xmit.txt`): a native
  XDP redirect from the gateway igc port to our enp3s0 transmits foreign
  `xdp_frame`s — guest (segment-B `10.0.2.2`) frames appear on segment A
  (47/50), proving the target-transmit path; **25 s flood soak, 2273 redirected
  frames, 0 KASAN splats** (foreign-frame return clean); `ndo-xmit` confirmed via
  netdev-genl; clean detach. Remaining in W4.1: RX multi-buffer for jumbo+XDP
  (reject `XDP_SETUP_PROG` `-EOPNOTSUPP` on jumbo until then), then Stage 4.
- **Stage 4 — AF_XDP zero-copy (RX + TX): DONE + VALIDATED on-wire (2026-06-17).**
  `netdev_bridge_xsk.c` owns the xsk kernel API (RX
  `xsk_buff_alloc`/`MEM_TYPE_XSK_BUFF_POOL`/consume, TX `xsk_tx_peek_desc` drain +
  `xsk_tx_completed`, `xsk_pool_dma_map`, need-wakeup); the RX producer/consumer
  fill-cursor poll (`process_rx_completions_zc`) and the `XskTx` TX slot
  disposition are safe Rust. `XDP_SETUP_XSK_POOL` + `ndo_xsk_wakeup` +
  `NETDEV_XDP_ACT_XSK_ZEROCOPY`. Cold-start bootstrap = a synchronous `xsk_kick`
  vtable op (ndo_xsk_wakeup posts umem buffers via `rust_xsk_kick` ->
  `napi::zc_refill_locked`, serialised by a per-queue `xsk_lock`) + RX need-wakeup
  at bind. **The bind/unbind uses a SURGICAL per-queue RX reconfigure**
  (igc_xdp_enable_pool pattern: `r8125_bridge_xsk_reconfig_queue` swaps just the
  bound queue's RX pool with the chip RX engine briefly off — TX/PHY/IRQ untouched
  — via `rust_rx_quiesce`/`rust_rx_restore`), so the **link never drops** and the
  bootstrap is deterministic (single-queue live path; multi-queue falls back to a
  full reopen). Static gate `ci/check_xsk.sh` (26 checks). Validation
  (`docs/perf/feature_smoke/afxdp_zerocopy.txt`, harness `tools/xsk/afxdp_zc` built
  against the kernel-selftest vendored xsk.c since libxdp/xdpsock are absent):
  **ZC RX 3 runs 2.20M / 1.98M / 2.25M frames zero-copy** (link-down 0, 0 splats
  every run); **ZC TX 6,842,816 submitted / 6,840,561 completed** (peer captured
  on-wire, 0 splats); unbind cleanly restores the page_pool RX path; non-ZC
  production path unaffected. **Copy-mode AF_XDP already works after Stage 1.**
  (Earlier full-stop+open bind dropped the link ~4s and was flaky 771k/13/0 — the
  per-queue reconfigure removed both the link-down and the race.)
- **TDD:** status fold, TX-ring XDP-admit predicate, `TxSlotKind` disposition
  mapping, geometry → all host-tested in a small kernel-free module rather than
  spread through the hot path. Hardware: `xdp-bench`/`xdpdump`/`xdpsock`, BPF
  selftests, per-packet-cost regression on the gateway, page-recycle KASAN soak.
- **cshim caps:** split the XDP run/finalize into `netdev_bridge_xdp.c` (and
  `_xsk.c`) up front so `ci/check_cshim_loc_caps.sh` stays green. ~4 new
  `unsafe_boundary` wrappers in Stage 1.
- Update the .rst (remove the "No XDP" limitation as each stage lands).

### W4.2 hwmon thermal sensor — DONE (provided by phylib; 2026-06-15)
- **Already exposed via standard hwmon, for free.** The temp sensor lives in the
  PHY, and the stock realtek phylib driver bound to our PHY registers a hwmon
  device (`rtl822x_hwmon_init`, `CONFIG_REALTEK_PHY_HWMON=y`) through the mdio bus
  we register. No driver code needed — the same phylib-inheritance pattern as EEE
  / cable-test / link management.
- **Validated on the gateway:** `hwmon0` name `r8125_rust_0_300:00`,
  `temp1_input=49000` (49 °C), `temp1_max=120000`. Standard `temp1_input` —
  **exceeds the vendor's non-upstreamable procfs** with zero code. Evidence:
  `docs/perf/feature_smoke/hwmon_thermal.txt`. (Implementing a duplicate MAC-side
  hwmon would conflict with the PHY one — correctly NOT done.)

### W4.3 Modern per-queue stats (`netdev_stat_ops` / qstats)
- The current netdev-genl standard; few drivers implement it. Exposes per-queue
  rx/tx packets/bytes/drops. cshim wires `netdev_stat_ops`; Rust/C supply
  per-queue values. Exceeds both C drivers + aligns with current netdev direction.
- **Finding (2026-06-15):** we do NOT currently keep per-queue counters — RX
  accounting is per-CPU (`dev_sw_netstats`), not per-queue. So qstats needs new
  per-queue rx_packets/rx_bytes (+ tx for the single TX queue) counters added to
  the RX accounting path. They are single-writer-per-queue (one NAPI per queue),
  so a plain `u64` + `WRITE_ONCE`/`READ_ONCE` is correct without atomics, but it
  is a hot-path touch. **Reclassified out of the trivial group into its own batch
  with a Track-B `-P16` no-regression check** (per "performance first"). Implement
  `get_base_stats` (report 0 base — fixed queue set, no deleted-queue history),
  `get_queue_stats_rx`, `get_queue_stats_tx`.
- **Done + validated (2026-06-15).** Per-queue `rx_packets`/`rx_bytes` (rxq) and
  single-TX-queue `tx_packets`/`tx_bytes` (bridge) counters, single-writer,
  incremented next to `dev_sw_netstats_{rx,tx}_add`. `netdev_stat_ops` wired
  (`get_queue_stats_rx`/`_tx`/`get_base_stats`). ynl `qstats-get` rollup matched
  `ip -s link` device totals to the packet; `-P16` held line rate (2.34 Gbit/s)
  — no regression. Static gate in `check_netdev_robustness.sh`; evidence in
  `docs/perf/feature_smoke/qstats_per_queue.txt`.
- **TDD:** pure per-queue snapshot fold tests; static gate proves the global
  `ndo_get_stats64` totals still equal the sum where the counters overlap.
- **Validate:** `ynl`/netdev-genl query shows stable per-queue values before and
  after queue-count changes, open/close, and suspend/resume.

### W4.4 `get_rmon_stats` (RMON histogram group)
- Standardized ethtool group complementing the eth-mac/ctrl/pause stats already
  added — IF the hardware tally carries the rx/tx size-bucket histograms (verify
  against the extended counter block we now map). Cheap if present.
- **TDD:** table-driven mapping from tally offsets to RMON buckets; unit tests
  reject overlapping or missing bucket ranges.
- **Decision gate:** if the hardware does not expose true size buckets, do not
  synthesize them from software hot-path counters.
- **Resolved (2026-06-15): not implemented.** The RTL8125 tally block (vendor
  `struct rtl8125_counters`, fully mapped in `r8125_tally`) has **no rx/tx
  size-bucket histograms** — only aggregate frame/octet/error counters. Per the
  decision gate, RMON stats are not exposed (synthesizing buckets from software
  counters would be misleading). Revisit only if a counter block with true
  buckets is found on a future stepping.

### W4.5 page_pool stats — DONE + validated (2026-06-17)
- Exposed through the **standard** page_pool ethtool helpers (no private API):
  `bridge_get_sset_count` adds `page_pool_ethtool_stats_get_count()`,
  `get_strings` calls `page_pool_ethtool_stats_get_strings`, and
  `get_ethtool_stats` sums every active queue's `page_pool_get_stats` then emits
  via `page_pool_ethtool_stats_get` (netdev_bridge_ethtool.c). On-wire
  (`ethtool -S enp3s0`): 11 `rx_pp_*` counters with live values
  (rx_pp_alloc_fast/slow/empty/refill, recycle_cached/ring, …). Neither C driver
  exposes this. CONFIG_PAGE_POOL_STATS=y on the rig.
- We already use page_pool; enable `page_pool_get_stats` exposure so
  `ethtool -S --include-page-pool-stats` reports alloc/recycle/cache rates. Nearly
  free observability win neither C driver has.
- **TDD:** static gate proves page_pool stats are exposed only through the
  standard page_pool API and the normal driver private stats order remains stable.
- **Validate:** stats move under traffic and reset to sane values after reopen.

### W4.6 Cable test (`ethtool --cable-test`) — RESOLVED: not implementable on this PHY (2026-06-17)
- **Decision gate said "verify PHY capability first" — verified negative.** The
  bound `Realtek Internal NBASE-T PHY` driver does not implement TDR cable test:
  `ethtool --cable-test enp3s0` → *"PHY driver does not support cable testing /
  Operation not supported"*. Cable test is a **phylib/PHY-driver** capability
  (`cable_test_start`), not something the MAC driver can wire up; there is no
  Realtek-private TDR path worth adding (and a private one would violate the
  "delegate to phylib, no private TDR" rule). Same shape as W4.4 RMON: the
  hardware/stack doesn't expose it, so we don't synthesize it. Revisit only if a
  future PHY-driver/stepping gains `cable_test_start` (then it is free, like
  hwmon).
- Via phylib `phy_start_cable_test` if the bound realtek PHY supports TDR. Modern
  diagnostic neither C driver exposes; likely a thin `.ndo`/ethtool wire-up that
  delegates to phylib. Verify PHY capability first.

### W4.7 devlink — DONE (code complete + CI-green; on-wire re-validation pending a reboot)
- A devlink instance + a "tx" devlink-health reporter (`netdev_bridge_devlink.c`)
  surface the existing TX-watchdog recovery (ndo_tx_timeout → reset_work →
  `r8125_bridge_reopen`) via the standard devlink-health API. Recovery POLICY
  stays in the bridge; the cshim wires the kernel objects. `.recover` =
  rtnl_lock + reopen; `reset_work` calls `r8125_bridge_devlink_report_tx_timeout`
  (records the error + auto-recovers via `.recover`), with a direct-reopen
  fallback if devlink init failed. Static gate `ci/check_devlink.sh`.
- **On-wire:** `devlink dev show` → `pci/0000:03:00.0`; `devlink health show` →
  `reporter tx state healthy ... auto_recover true`; dmesg clean.
- **Self-deadlock found + fixed:** an early `.test` op called
  `devlink_health_report()`, which the core invokes with the reporter lock held →
  recursive deadlock (wedged the devlink task in D-state on rtnl). Removed the
  `.test` op; the report call now lives only in `reset_work` (no devlink lock).
  The gate enforces `devlink_health_report()` appears exactly once (error path),
  so it can't regress. **Consequence: the gateway rtnl is wedged and needs a
  reboot to clear; the fixed module is CI-green + ready to re-validate the full
  report→recover cycle after a reboot.** See
  `docs/perf/feature_smoke/devlink_health.txt`.

### W4.8 Upstream selftests — DONE + validated (2026-06-17)
- `tools/testing/selftests/net/r8125_rust_features.sh` (NEW) joins the existing
  `r8125_rust_smoke.sh`: a TAP-13, skip-aware capability-matrix test covering
  ethtool disposition + page_pool stats, highdma, driver/firmware identity, RSS
  table readback, the PHY hwmon temp, advertised `xdp_features` (incl
  xsk-zerocopy), and the channel query. `Makefile` TEST_PROGS lists both;
  `ci/check_selftest_smoke.sh` enforces both shapes (TAP + skip-aware).
- On-wire run (enp3s0): **7 ok + 1 skip** (xdp_features not rendered by this
  `ip -d`; honest SKIP), 0 failures.
- Every check that needs an absent tool/capability is a TAP SKIP, so it runs on
  any host (the failing-skip-aware-first discipline).

---

## Cross-cutting

### Recommended next work
1. **W2.1/W2.2 kernel-Rust PCI hooks (`shutdown`, then `reset_prepare/done`).**
   These are small upstreamable API increments and close real lifecycle gaps:
   clean shutdown/kexec quiesce and the sysfs PCI reset phylib warning. Keep the
   driver default stock-kernel buildable behind cfgs and validate each hook on the
   gateway before moving to AER/runtime PM.
2. **W4.1 XDP remaining work: jumbo/multi-buffer gate, then AF_XDP zero-copy.**
   Now that BASIC, REDIRECT, and NDO_XMIT are validated, the next XDP item should
   be a small compatibility batch: reject driver-mode XDP at jumbo MTU until
   multi-buffer support is real, or implement RX multi-buffer and advertise the SG
   bits with a dedicated KASAN soak. AF_XDP zero-copy remains a later isolated
   branch because it touches the validated RX allocation path.
3. **W3.3 `rxnfc` hash-field selection decision.** Custom RSS key/table is done;
   only add `get_rxnfc`/`set_rxnfc` for hash-field controls the chip can actually
   express. Keep n-tuple steering deferred unless a hardware classifier is proven.
4. **W4.8 upstream selftests.** Convert the proven smoke evidence into
   repeatable, skip-aware tests for ethtool surfaces, XDP attach/pass/drop/tx, RSS
   readback, and PM cfg builds. This improves review confidence without touching
   the hot path.

### Sequencing / dependencies
1. **Do not batch lifecycle and datapath risk together.** W1.3 WoL, XDP
   jumbo/AF_XDP work, and W2 PCI hooks should each land as separate reviewable
   series with their own evidence.
2. **Kernel-patch track:** W2.1 → W2.2 → W2.3 → W2.4, each its own patch
   increment + reboot. Driver code remains cfg-gated until the corresponding API
   exists.
3. **Deferred compatibility with decision gates:** W3.4 EEPROM, W3.5 netpoll, and
   W3.6 ring resize/coalesce/RXALL remain intentionally closed unless hardware
   evidence changes. Do not implement them opportunistically inside unrelated
   work.
4. **Highest-risk later:** AF_XDP zero-copy waits until `ndo_xdp_xmit` has soaked;
   it touches the validated RX allocation path and deserves its own branch.

### Test / CI strategy (every item)
- Pure logic → kernel-free module with `#[cfg(test)]` + `const _: assert!()` ties
  where applicable; add that module to `ci/check_rust_unit_tests.sh`.
- New surface → flip `ci/check_surface_inventory.sh` PLANNED→PRESENT (or add a
  row); keep `make` (default, stock-kernel) green + `make CLIPPY=1` warning-free.
- New cshim TU → respect/raise its documented `Hard cap:` LOC (justified) and the
  one-concern rule; `unsafe` stays only in `unsafe_boundary.rs` (census +
  justification per added block).
- Hardware → gateway + KVM KASAN+lockdep+kmemleak+DMA_API_DEBUG, 0 splats; perf
  items re-run the Track-B `-P16` fresh-load baseline to prove no regression.

### Review checklist per batch
- Is there exactly one capability or one kernel API hook family in the patch?
- Can the core decision be tested without hardware? If yes, is it covered by a
  host unit test that would have failed before the implementation?
- Does C only own kernel object lifetime/callback glue, with chip policy in Rust?
- Is the unsupported path explicit and tested?
- Are all readbacks sourced from the active state or hardware, not from a stale
  user request?
- Does the failure path leave queues, page_pool pages, BQL, IRQ masks, and PHY
  state recoverable?
- Did default stock-kernel `make` stay green when a kernel-Rust extension is
  cfg-gated?

### Validation rigs
- **Gateway** (7.0.0-kasan, S3-capable): PM/runtime-PM/AER/shutdown, XDP
  throughput + per-packet cost, PHY firmware link stability, **WoL wake (after the
  move, with the external sender)**.
- **KVM** (s2idle only): functional XDP/AF_XDP-copy, KASAN page-recycle soak; not
  PM-wake or UDP-TX.

### Doc/artifact updates
- `Documentation/networking/device_drivers/realtek/r8125_rust.rst` — drop the "No
  XDP" + single-queue/PM-untested limitations as each lands; add hwmon/XDP usage.
- `docs/PM_GAP.md` — track W2 shutdown/reset/AER/runtime-PM as future patched
  kernel capabilities until their evidence lands.
- `docs/UPSTREAM_REVIEW.md` — move closed items out of the gap table; this plan is
  the live tracker.
- `docs/UPSTREAM_GAP_CLOSURE_PLAN.md` — keep the deferred-surface rationale in
  sync with W3.3-W3.6 so reviewers see why each absent callback is intentional.
- `MODULE_FIRMWARE("rtl_nic/rtl8125b-2.fw")` + Kconfig `select`s for LEDS/hwmon as
  those land.
