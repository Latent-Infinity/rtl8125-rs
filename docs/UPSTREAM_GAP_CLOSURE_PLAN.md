# Upstream gap closure plan

Status: draft for review, 2026-06-11.

This plan converts the Vendor C / mainline r8169 / Rust driver gap analysis into
reviewable implementation work. The goal is not to clone every vendor feature.
The goal is to close the standard Linux NIC surfaces that upstream reviewers and
operators reasonably expect before an RFC, while keeping the Rust driver simple
and testable.

## Scope

P0 items are expected before upstream review. P1 items should be done before a
serious RFC unless a soak result forces a different priority. P2 items are
explicit defers: real gaps, but not blockers for the first review cycle.

| Priority | Gap | Rationale |
|---|---|---|
| P0 | `pm_ops` suspend/resume | Upstream PCI driver expectation; currently documented as a hard blocker. |
| P0 | `get/set_link_ksettings` + `nway_reset` | Basic `ethtool <iface>` control; phylib already owns the PHY. |
| P0 | `ndo_set_rx_mode` | Required for multicast, allmulti, promiscuous mode, bridges, IPv6, mDNS, and captures. |
| ~~P1~~ DEFER | `get/set_coalesce` | **Reclassified to DEFER (2026-06-12).** Mainline `r8169` returns `-EOPNOTSUPP` for the 8125 (`rtl_get_coalesce`: `if (rtl_is_8125(tp)) return -EOPNOTSUPP`): the 8125 INT_MITI **V2** timer unit (0xA00 table) is uncharacterized upstream, and the legacy IntrMitigate/CPlusCmd scale does not apply to it. A hardware IRQ-rate characterization was inconclusive (NAPI busy-polls under load and masks the timer). Exposing a self-invented µs scale would be a guess; matching mainline's explicit `-EOPNOTSUPP` is the honest, reviewer-safe choice. The INT_MITI timers stay tunable via the `rx/tx_coalesce_timer` module params. Revisit if the V2 timer unit is characterized. |
| P1 | WoL `get/set_wol` | Standard NIC power feature; depends on PM policy and PCI wake handling. |
| P1 | `get/set_ringparam` | Operator visibility/control for queue depths; may initially be read-only plus clear unsupported resize. |
| P1 | `get/set_pauseparam` | PHY already advertises asym pause support; expose control through ethtool. |
| P1 | hardware tally stats | `ndo_get_stats64` exists, but hardware error counters are still missing. |
| P2 | EEE | Useful, but can be deferred if documented. |
| P2 | PTP / hwtstamp / `get_ts_info` | Vendor supports it conditionally; no current soak dependency. |
| P2 | custom RSS key/table + `rxnfc` hash opts | Rust supports default RSS correctly; custom policy is a follow-up. |
| P2 | regs/eeprom/msglevel/netpoll/RXALL/RXFCS | Diagnostic or vendor-specific surfaces; not first-RFC blockers. |

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

The current `docs/M5_PM_GAP.md` documents the kernel-Rust PCI PM API gap. For
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

### Coalesce

Implementation:

1. Add `get_coalesce` / `set_coalesce`.
2. Store configured RX/TX moderation values in driver state instead of reading
   only module parameters at open.
3. Program INT_MITI live when the device is running; cache for next open when
   down.
4. Map user-facing units carefully. If hardware units are not microseconds, use
   the closest stable conversion and document rounding.

Tests:

- Static gate proves callbacks are wired.
- Set while down, read back, then open and verify register readback.
- Set while running and verify no traffic drop, WARN, or stale readback.
- Boundary tests: zero, current default, max accepted, above max rejected.

### WoL

Implementation:

1. Add `get_wol` / `set_wol`.
2. Track enabled wake sources in driver state.
3. Integrate with PM suspend path and PCI wake enablement.
4. Start with magic-packet WoL only unless the chip-specific pattern filters are
   already proven.

Tests:

- `ethtool -s <iface> wol g` persists in `get_wol`.
- Suspend with WoL disabled does not arm wake.
- Suspend with WoL enabled arms PCI wake.
- Magic packet wakes the Gateway, if test infrastructure is available.

### Ring parameters

Implementation:

1. Add `get_ringparam` immediately.
2. For `set_ringparam`, choose one of:
   - return `-EOPNOTSUPP` with stable readback if dynamic resize is out of
     scope for the first RFC, or
   - implement down-only resize with full stop/open reallocation.
3. Do not implement live resize until RX page-pool, NAPI, DMA rings, and BQL
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

## Phase 4 - P2 defers with explicit documentation

These should be documented in the driver RST and upstream cover letter rather
than implemented before the first RFC:

- EEE: defer unless soak reveals a link-stability issue tied to EEE.
- PTP/hwtstamp: defer until the basic control plane is accepted.
- Custom RSS key/table and `rxnfc`: current default RSS behavior is correct;
  custom policy can be a follow-up.
- regs/eeprom/msglevel: diagnostic convenience, not core behavior.
- netpoll: useful for netconsole, not a first-RFC blocker.
- RXALL/RXFCS: vendor diagnostic toggles; avoid exposing until there is a clear
  upstream use case.

Acceptance:

- `docs/UPSTREAM_REVIEW.md` says which items are intentionally deferred.
- User-facing docs do not imply unsupported features are present.
- Unsupported ethtool operations fail explicitly, not as silent no-ops.

## Patch breakdown

Suggested commit series:

1. `docs: add upstream gap closure plan`
2. `net: r8125-rust: add phylib link ethtool operations`
3. `net: r8125-rust: program receive mode filters`
4. `net: r8125-rust: add PM suspend and resume hooks`
5. `net: r8125-rust: expose interrupt coalescing via ethtool`
6. `net: r8125-rust: add WoL control`
7. `net: r8125-rust: report ring parameters`
8. `net: r8125-rust: expose pause parameters`
9. `net: r8125-rust: fold hardware tally counters into stats64`
10. `docs: mark remaining vendor-only features deferred`

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
