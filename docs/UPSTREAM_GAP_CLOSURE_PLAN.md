# Upstream gap closure plan

Status: draft for review, updated 2026-06-13.

This plan converts the Vendor C / mainline r8169 / Rust driver gap analysis into
reviewable implementation work. The goal is not to clone every vendor feature.
The goal is to close the standard Linux NIC surfaces that upstream reviewers and
operators reasonably expect before an RFC, while keeping the Rust driver simple
and testable.

## Scope

P0 items are expected before upstream review. P1 items should be done before a
serious RFC unless a soak result forces a different priority. P2 items are real
feature gaps that are not first-review blockers only if the cover letter and
driver docs call them out explicitly. Anything marked SHIP must be closed before
we treat the Rust driver as production-ready on the Gateway.

| Priority | Gap | Rationale |
|---|---|---|
| P0 | `pm_ops` suspend/resume | Upstream PCI driver expectation; implemented behind the kernel Rust PCI PM extension, but default-build story and resume error propagation must be resolved. |
| P0 | `get/set_link_ksettings` + `nway_reset` | Basic `ethtool <iface>` control; phylib already owns the PHY. |
| P0 | `ndo_set_rx_mode` | Required for multicast, allmulti, promiscuous mode, bridges, IPv6, mDNS, and captures. |
| ~~P1~~ DEFER | `get/set_coalesce` | **Reclassified to DEFER (2026-06-12).** Mainline `r8169` returns `-EOPNOTSUPP` for the 8125 (`rtl_get_coalesce`: `if (rtl_is_8125(tp)) return -EOPNOTSUPP`): the 8125 INT_MITI **V2** timer unit (0xA00 table) is uncharacterized upstream, and the legacy IntrMitigate/CPlusCmd scale does not apply to it. A hardware IRQ-rate characterization was inconclusive (NAPI busy-polls under load and masks the timer). Exposing a self-invented µs scale would be a guess; matching mainline's explicit `-EOPNOTSUPP` is the honest, reviewer-safe choice. The INT_MITI timers stay tunable via the `rx/tx_coalesce_timer` module params. Revisit if the V2 timer unit is characterized. |
| P0/SHIP | Magic-packet WoL end-to-end | Standard NIC power feature. Do not advertise `get/set_wol` unless suspend leaves the PHY/MAC wake path armed and an external magic packet wakes the Gateway. |
| P1 | `get_ringparam` + fixed-depth readback | Operator visibility for queue depths; live resize is a separate SHIP gap. |
| P1 | `get/set_pauseparam` | PHY already advertises asym pause support; expose control through ethtool and revalidate carrier recovery after toggles. |
| P1 | hardware tally stats | `ndo_get_stats64` should fold hardware error counters; ethtool private stats should stay internally consistent. |
| P1 | `ndo_eth_ioctl` | Mainline r8169 exposes standard PHY MII ioctl handling; add the compatible phylib surface. |
| P1 | `ndo_features_check` | Mainline r8169 rejects/adjusts offloads for packets the hardware cannot safely checksum/segment; add the same compatibility guard. |
| P1 | `get_ts_info` | Even while hardware PTP is deferred, report the kernel-supported timestamping capabilities instead of leaving the surface absent. |
| P1 | richer MAC/control/pause stats | Match the useful r8169 ethtool stats surfaces where kernel APIs are available, especially pause/MAC error visibility. |
| P2/SHIP | EEE | Vendor and r8169 support EEE; close before production shipping unless soak proves it must remain disabled for stability and docs say so. |
| P2/SHIP | PTP / hwtstamp | Vendor supports hardware timestamping conditionally. At minimum, `get_ts_info` lands in P1; PHC/hwtstamp can be staged after the standard control plane. |
| P2/SHIP | custom RSS key/table + `rxnfc` hash opts | Rust supports default RSS correctly; add custom indirection/key readback and rxnfc policy before claiming vendor feature parity. |
| P2/SHIP | regs/eeprom/msglevel | Diagnostic compatibility surfaces from vendor/r8169. Implement read-only, truthful variants where hardware support is known. |
| P2/SHIP | netpoll | Needed for netconsole-style deployments; can remain deferred for first RFC but not for a complete production feature set. |
| P2/SHIP | live ring resize | `get_ringparam` is not enough for feature parity; add down-only resize first, then consider running resize only with rollback coverage. |
| P2/SHIP | broader WoL modes | Magic packet comes first. Add PHY/link, unicast, multicast, and broadcast wake modes only after the wake path is proven. |
| P2 | RXALL/RXFCS | Vendor diagnostic toggles; avoid exposing until there is a clear upstream use case. |

## Current pre-ship blockers

- PM resume must propagate `bridge_ndo_open()` failures instead of reattaching
  the netdev unconditionally.
- WoL must stay hidden or documented as unfinished until the suspend path keeps
  the receive wake path alive and an external magic packet wake is captured.
- Pause/ring validation evidence must prove carrier recovery and post-toggle
  traffic, not just ethtool readback.
- The feature inventory gate must match this table: implemented surfaces are
  `PRESENT`, missing pre-ship surfaces are `PLANNED`, and only explicit first-RFC
  defers remain `DEFER`.

## Phase 0 - Baseline and guardrails

Before changing behavior, freeze the current evidence surface:

1. Capture current `ethtool -i`, `ethtool -k`, `ethtool -S`, `ethtool -l`,
   `ethtool -x`, `ip -s link`, `/proc/interrupts`, and dmesg after a clean
   load/open/traffic/unload cycle.
2. Add a CI inventory gate that names each expected netdev/ethtool surface and
   marks it `present`, `intentional-defer`, or `unsupported`. This avoids
   silently reintroducing the exact class of missed detail that led to the RSS
   readback and down-interface cache fixes.
3. Keep each feature behind the existing thin C-shim pattern: C owns kernel
   callback surfaces; Rust owns chip state, policy, and host-testable pure
   validation.

Acceptance:

- Existing `ci/run_checks.sh` remains green.
- `make RUSTC=rustc-1.93 BINDGEN=bindgen` remains green.
- The 24-hour soak branch remains bisectable: no unrelated refactors mixed into
  feature commits.

## Phase 1 - P0 link and receive-mode surfaces

### Link settings and autoneg reset

Implementation:

1. Add ethtool callbacks in `src/netdev_bridge_ethtool.c`:
   - `bridge_get_link_ksettings`
   - `bridge_set_link_ksettings`
   - `bridge_nway_reset`
2. Route these to phylib helpers against `b->phydev`.
3. Return `-ENODEV` when the PHY is absent and `-EOPNOTSUPP` only when phylib
   reports unsupported behavior.
4. Preserve RTNL assumptions; ethtool link operations run under RTNL.

Tests:

- Static gate proves the three callbacks are wired.
- Hardware smoke:
  - `ethtool <iface>` reports speed, duplex, autoneg, supported modes.
  - `ethtool -r <iface>` triggers renegotiation without WARN/BUG.
  - A set-to-current `ethtool -s` round trip succeeds.
  - Invalid speed/duplex combinations fail cleanly.

Review notes:

- Do not duplicate Realtek PHY logic in this driver. The existing MDIO + phylib
  integration is the abstraction boundary.

### Receive-mode filtering

Implementation:

1. Add `.ndo_set_rx_mode` in `src/netdev_bridge.c`.
2. Compute a compact RX filter policy in C from `ndev->flags`,
   `netdev_mc_count(ndev)`, and multicast list state:
   - unicast to `dev_addr`
   - broadcast
   - all-multicast
   - promiscuous
   - multicast hash table when representable
3. Add a Rust bridge op to program the corresponding RTL8125 RX filter and
   multicast hash registers.
4. If the multicast list exceeds what we can represent, fall back to allmulti
   rather than dropping multicast frames.

Tests:

- Host unit tests for the pure multicast hash/filter policy.
- Static gate proves `.ndo_set_rx_mode` is present.
- Hardware smoke:
  - IPv6 neighbor discovery still works.
  - mDNS/multicast receive works.
  - `ip link set <iface> promisc on/off` changes behavior without reopening.
  - bridge/tcpdump use case sees expected traffic.

Review notes:

- This is a standard netdev behavior gap, not an optimization. Keep the initial
  implementation conservative.

## Phase 2 - P0 PM path

The current `docs/PM_GAP.md` documents the kernel-Rust PCI PM API gap. For
upstream review, we need one of two paths.

Preferred implementation:

1. Extend the local kernel-Rust PCI integration to expose optional PM callbacks
   or carry a small, clearly isolated cshim registration hook for this driver.
2. Wire a `struct dev_pm_ops` equivalent with:
   - suspend/freeze/poweroff: detach device, stop TX, stop PHY, mask IRQs,
     quiesce chip, save PCI state, prepare wake if WoL is enabled.
   - resume/thaw/restore: restore PCI state, enable device, set bus master,
     restore MAC address/filter state, reopen if the netdev was running.
3. Preserve current `remove` ordering: unregister netdev before tearing down the
   MDIO bus and Rust-owned state.
4. Do not add runtime PM until system suspend/resume is stable.

Tests:

- 10-cycle Gateway suspend/resume with the interface down.
- 10-cycle Gateway suspend/resume with the interface up and link connected.
- Post-resume traffic: ping, TCP iperf3, UDP smoke, `ethtool -S` counters.
- WoL disabled baseline: confirm no accidental wake enable.
- KASAN/lockdep/dmesg clean.

Acceptance:

- No WARN/BUG across all cycles.
- Link returns without module reload.
- If the interface was administratively down before suspend, it remains down
  after resume.
- If the interface was up before suspend, it resumes traffic without manual
  `ip link set down/up`.

Review notes:

- If kernel-Rust PM plumbing is too invasive for this branch, split the upstream
  API work from the driver behavior. Do not hide a fragile PM workaround inside
  unrelated feature work.

## Phase 3 - P1 ethtool operator controls

### Coalesce remains deferred

Implementation:

1. Do not add `get_coalesce` / `set_coalesce` for RTL8125 until the INT_MITI V2
   timer unit is characterized.
2. Keep the current module parameters as the only tuning surface.
3. Keep the CI inventory row marked `DEFER|coalesce` so an accidental callback
   addition fails review until the semantics are justified.

Tests:

- Static gate proves callbacks are absent and documented.
- Hardware characterization evidence must exist before this row can move back
  to `PLANNED`.
- Any future implementation must demonstrate a stable user-facing unit and live
  programming behavior across idle, NAPI busy, and saturated traffic cases.

### Magic-packet WoL

Implementation:

1. Keep `get_wol` / `set_wol` unwired until end-to-end wake works, or document
   the surface as experimental and disabled by default.
2. Track enabled wake sources in driver state.
3. Split normal suspend from WoL suspend:
   - normal suspend may fully stop the PHY/MAC.
   - WoL suspend must leave the receive wake path armed.
4. Integrate chip wake registers, PCI wake enablement, and PHY state in one
   suspend transaction with rollback on failure.
5. Start with magic-packet WoL only. Broader wake modes are tracked in the
   production backlog after magic wake is proven.

Tests:

- `ethtool -s <iface> wol g` persists in `get_wol`.
- Suspend with WoL disabled does not arm wake.
- Suspend with WoL enabled arms PCI wake.
- External magic packet wakes the Gateway.
- After wake, carrier, traffic, and `ethtool -S` remain usable without module
  reload.

### Ring parameters

Implementation:

1. Keep `get_ringparam` wired to the actual Rust ring depth.
2. Keep `set_ringparam` unsupported for the first RFC if resize is not ready.
3. Add down-only resize before production shipping:
   - validate requested depths.
   - require the device to be administratively down.
   - reallocate RX/TX rings and page-pool state as one rollback-safe operation.
4. Do not implement running resize until RX page-pool, NAPI, DMA rings, and BQL
   accounting all have explicit rollback tests.

Tests:

- `ethtool -g` reports real TX/RX descriptor counts.
- Unsupported resize fails clearly and does not change state.
- If resize lands, invalid and boundary sizes are host-tested and hardware
  smoked while down and running.

### Pause parameters

Implementation:

1. Add `get_pauseparam` / `set_pauseparam` through phylib.
2. Keep MAC and PHY advertised pause state coherent.
3. Re-negotiate when pause settings change.

Tests:

- `ethtool -a` readback matches phylib state.
- Set-to-current succeeds.
- Toggle rx/tx pause, renegotiate, verify no link loss beyond expected reneg.
- Validation evidence proves carrier recovers and traffic passes after each
  toggle. A smoke log ending with `carrier=0` is not acceptable evidence.

### Hardware tally stats

Implementation:

1. Identify the RTL8125 tally counter registers or DMA tally block used by the
   vendor driver.
2. Fold hardware error counters into `ndo_get_stats64`:
   - `rx_missed_errors`
   - `rx_fifo_errors` if available
   - `tx_errors`
   - collisions/aborted where meaningful for this MAC
3. Keep the existing section 6.3 software counters in `ethtool -S`.

Tests:

- Static gate proves `ndo_get_stats64` still folds software drops.
- Hardware smoke confirms `ip -s link` and `ethtool -S` remain internally
  consistent after traffic and after reset/reopen.
- If kernel ethtool MAC/control/pause stats callbacks are available for the
  target baseline, expose the same counters there rather than only as private
  strings.

## Phase 4 - Mainline r8169 compatibility surfaces

These are not vendor embellishments. They are standard compatibility surfaces
that reduce reviewer friction because mainline `r8169` already exposes or relies
on them.

### `ndo_features_check`

Implementation:

1. Compare mainline `r8169` feature checks against the Rust transmit feature
   contract.
2. Reject or mask checksum/segmentation offloads for packets the 8125 path
   cannot safely handle, especially long transport headers, encapsulation, and
   short/partial checksum edge cases.
3. Keep the function side-effect free. It should return the adjusted feature
   mask and leave policy decisions to the networking stack.

Tests:

- Host tests for pure feature-mask decisions.
- Traffic smoke for normal TCP/UDP checksum offload after the callback lands.
- Negative packet-shape tests where feasible through kernel selftests or a
  focused packet generator.

### `ndo_eth_ioctl`

Implementation:

1. Wire `.ndo_eth_ioctl` to the standard phylib MII ioctl helper for a running
   PHY.
2. Return stable errors when the PHY is absent or the device is not in a state
   where the helper is valid.
3. Do not add private Realtek ioctls.

Tests:

- MII read ioctl succeeds while the interface is running.
- Unsupported ioctls fail without WARN/BUG.
- Down-interface behavior is deterministic and documented.

### `get_ts_info`

Implementation:

1. Add ethtool `get_ts_info` before hardware PTP support.
2. If there is no PHC yet, report the generic software timestamping capability
   truthfully rather than implying hardware timestamp support.
3. When hardware PTP lands, extend this callback instead of replacing it.

Tests:

- `ethtool -T <iface>` reports a coherent timestamping matrix.
- No hardware timestamp flags are advertised until hwtstamp is implemented and
  validated.

### Richer MAC/control/pause stats

Implementation:

1. Compare r8169 MAC, control, and pause stats with the current Rust
   `ethtool -S` and `ndo_get_stats64` output.
2. Prefer standard ethtool stats callbacks when available in the target kernel.
3. Keep private string stats for driver-specific software counters only.

Tests:

- Counter names and values remain stable across open/close.
- Pause counters move when pause frames are generated in a controlled test, or
  are omitted if the hardware cannot report them truthfully.

## Phase 5 - Production feature parity backlog

The following gaps may be documented as first-RFC defers, but the production
plan is to close them unless validation proves the feature is unsafe on this
hardware.

### EEE

Implementation:

1. Add phylib-backed `get_eee` / `set_eee`.
2. Keep MAC EEE configuration synchronized with PHY advertisement.
3. Disable by default only if Gateway soak shows link instability that cannot be
   mitigated.

Tests:

- `ethtool --show-eee` and `--set-eee` round trip.
- Link renegotiation completes without persistent carrier loss.
- Long idle and traffic-resume soak covers EEE enabled and disabled.

### PTP / hwtstamp

Implementation:

1. Inventory vendor C timestamp registers and mainline expectations.
2. Add hardware timestamp configuration only after `get_ts_info` exists.
3. Expose PHC and `SIOCSHWTSTAMP`/`SIOCGHWTSTAMP` behavior only when timestamp
   readout, rollover handling, and reset restore are proven.

Tests:

- `ethtool -T` advertises hardware support only after implementation.
- `hwstamp_ctl` or equivalent validates RX/TX timestamp enable/disable.
- Reset, suspend/resume, and link renegotiation preserve or restore timestamp
  state.

### Custom RSS key/table and `rxnfc`

Implementation:

1. Keep default RSS behavior as the baseline.
2. Add persistent storage and validation for custom RSS key and indirection
   table values.
3. Program table/key live when safe; otherwise cache while down and reject
   unsupported running changes explicitly.
4. Add `rxnfc` hash option handling only for fields the hardware can actually
   classify.

Tests:

- `ethtool -x`/`-X` readback matches the active table/key.
- Invalid queue indices, table lengths, and key lengths fail without changing
  current state.
- Per-flow distribution smoke confirms packets land on expected queues.

### Register, EEPROM, and msglevel diagnostics

Implementation:

1. Add `get_regs` with a documented register version and a bounded, stable dump
   layout.
2. Add EEPROM access only if the chip exposes a real EEPROM/OTP path that can be
   read safely from Linux. Prefer read-only until write semantics are reviewed.
3. Add `get_msglevel` / `set_msglevel` only if the Rust logging sites have a
   meaningful mapping. Do not expose a knob that does nothing.

Tests:

- `ethtool -d` does not race reset/remove and never reads outside the approved
  register window.
- `ethtool -e` succeeds only on supported hardware and fails clearly otherwise.
- msglevel changes affect only documented log categories.

### Netpoll

Implementation:

1. Add netpoll only after the IRQ/NAPI path has a reviewed polling entry point.
2. Keep the callback minimal and avoid sleeping or taking locks that netpoll
   cannot tolerate.

Tests:

- Netconsole smoke receives logs over the driver.
- Normal traffic and panic-path polling do not deadlock.

### Broader WoL modes

Implementation:

1. Add PHY/link, unicast, multicast, and broadcast wake modes only after
   magic-packet wake is stable.
2. Map each advertised `wolopts` bit to a proven chip wake source.
3. Reject unsupported wake modes instead of accepting and ignoring them.

Tests:

- Each advertised wake source wakes the Gateway from system suspend.
- Disabled wake sources do not produce false wakes.

### Live ring resize

Implementation:

1. Implement down-only resize first.
2. Add live resize only if stop/reopen disruption is unacceptable and rollback
   coverage is strong enough.
3. Coordinate NAPI disablement, IRQ masking, DMA unmap, page-pool destruction,
   BQL state, and queue wakeup ordering in one reviewed sequence.

Tests:

- Invalid sizes leave active rings untouched.
- Down-only resize survives repeated open/close and suspend/resume.
- Live resize, if added, passes traffic under load without leaks, WARNs, or
  permanent queue stop.

### RXALL/RXFCS

Implementation:

1. Keep these vendor diagnostic toggles deferred unless an upstream use case is
   identified.
2. If implemented, ensure the receive path and skb metadata correctly represent
   frames with FCS or bad checksums.

Acceptance:

- `docs/UPSTREAM_REVIEW.md` says which items are intentionally deferred for the
  first RFC and which remain production parity work.
- User-facing docs do not imply unsupported features are present.
- Unsupported ethtool operations fail explicitly, not as silent no-ops.

## Patch breakdown

Suggested commit series:

1. `docs: add upstream gap closure plan`
2. `net: r8125-rust: add phylib link ethtool operations`
3. `net: r8125-rust: program receive mode filters`
4. `net: r8125-rust: add PM suspend and resume hooks`
5. `net: r8125-rust: report fixed ring parameters`
6. `net: r8125-rust: expose pause parameters`
7. `net: r8125-rust: fold hardware tally counters into stats64`
8. `net: r8125-rust: add features-check offload guard`
9. `net: r8125-rust: add standard PHY ioctl handling`
10. `net: r8125-rust: report timestamp capabilities`
11. `net: r8125-rust: expose MAC control and pause stats`
12. `net: r8125-rust: complete magic-packet WoL suspend path`
13. `net: r8125-rust: add EEE ethtool support`
14. `net: r8125-rust: add custom RSS table key and rxnfc policy`
15. `net: r8125-rust: add diagnostic register dump`
16. `net: r8125-rust: support down-only ring resize`
17. `docs: document remaining intentional defers`

Each behavior commit should include its static CI gate and at least one hardware
smoke command in the commit message or linked evidence file.

## Review checklist

- Is the implementation standard Linux netdev/phylib behavior rather than a
  Realtek vendor clone?
- Does every new callback have a down-interface readback test?
- Does every set operation reject unsupported changes instead of silently
  accepting them?
- Does every running-device set operation either reprogram hardware immediately
  or document/cache for next open?
- Are all hardware writes owned by Rust or by a tiny C helper with a clear ABI?
- Are PM and WoL tested independently before being tested together?
- Does the final feature matrix match actual `ethtool` behavior?
- Does `ci/check_surface_inventory.sh` match this plan for every present,
  planned, and intentionally deferred surface?
- Is the default build behavior documented separately from the `PCI_PM=1`
  kernel-extension build behavior?
- Are first-RFC defers clearly distinguished from production shipping gaps?
