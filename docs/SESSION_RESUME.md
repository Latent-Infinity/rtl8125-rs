# Session Resume — 2026-05-24

Live-state tracker for the rtl8125-rs driver effort. Canonical specs:
[`M1_ENTRY_CRITERIA.md`](M1_ENTRY_CRITERIA.md) and
[`M0a_TO_M1_RUNBOOK.md`](M0a_TO_M1_RUNBOOK.md) — this file tracks where work
paused and what to do next.

---

## Current TX offload note — 2026-06-06

The current xmit path uses `r8125_bridge_skb_tx_offload_prepare` /
`DriverOwnedSkb::tx_offload_prepare()` to prepare opts1, opts2, and
`nr_frags` in one FFI crossing before DMA mapping. Normal UDP
`CHECKSUM_PARTIAL` packets stay on RTL8125 hardware checksum; software
checksum is limited to unsupported/pad cases matching r8169/vendor behavior.

## TL;DR — M4-perf phase 1 ✅ (2026-05-25): HW CSUM offload + netdev stats

Built on top of M4-traffic 2.5G. Now: link 2.5Gbps Full Duplex,
NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM | NETIF_F_RXCSUM advertised
and exercised. `ip -s link` shows real byte/packet counts (was 0/0).
ethtool -k confirms tx-checksum-ipv4/ipv6 + rx-checksumming all `on`.
Cross-validated TX descriptor bit layout against BOTH upstream r8169
AND Realtek's vendor r8125_n.c (operator-flagged: don't trust upstream
in isolation — they agree, plus the UDP-short-packet errata workaround
is ported).

iperf3 single-stream guest→host: **0.95 Gbps** (was 0.91 pre-CSUM).
Single-stream host→guest: **1.25 Gbps**. r8169 reference: 2.33 Gbps.
Remaining gap is per-packet kernel overhead in the KASAN-debug guest;
TSO+SG would close most of it — tracked as task #49.

**Implementation** (split for code-review hygiene):
- New `src/netdev_bridge_offload.c` (~140 LOC) for the offload helpers
  and stats counters — keeps `netdev_bridge.c` under the 400-line cap
  (now 375).
- New `src/phy.rs` (already there from M4-traffic), plus expanded
  `src/unsafe_boundary.rs` for the four new wrappers
  (`skb_tx_csum_opts`, `skb_rx_csum_set`, `bridge_account_tx/rx`).
- Stats accounting in cshim's `bridge_skb_complete_tx` because the
  chip clears the descriptor LEN field after TX completion and
  `napi_consume_skb` invalidates the skb pointer.

**Evidence**: `docs/baseline/m4_perf_csum_stats_proof.txt`,
`docs/baseline/iperf3/iperf3_r8125_rust_{guest2host,host2guest}_tcp_1500.json`,
`docs/baseline/m4_traffic_25g_proof.txt`,
`docs/baseline/m4_traffic_proof.txt`,
`docs/baseline/m4_full_uaf_fix_proof.txt`.

**Tasks**: task 48 ✅ closed; new task 49 opens for TSO+SG (the
remaining 2x throughput gap). Census 50 → 50 (justified at
`ci/CENSUS_JUSTIFICATIONS.md` — 4 new safe-wrapper unsafe blocks).

CI green; `netdev_bridge.c stays within 400-line review cap (375)`.

## M0b ✅ (2026-05-25) — unchanged

Direct Cat6 cable host I226-V `enp4s0` ↔ guest RTL8125 `enp5s0`. 8 r8169
iperf3 baselines captured; TCP 2.33–2.48 Gb/s; M1 board rows 7/10/11
flipped. Evidence under `baseline/m0b_proof.txt`, `TOPOLOGY.md`,
`iperf3/`.

**Topology change**: instead of waiting for a separate-machine peer, the
host I226-V (`enp4s0`) is now the peer for the guest RTL8125 (`enp5s0`)
via a **direct Cat6 cable** between the two ports on the same MS-A2
chassis. No switch. Private `10.0.0.0/24` segment. Host mgmt stays on
Wi-Fi `wlp6s0` (192.168.68.x), so L2 isolation per plan §8.1.6 is
satisfied by construction.

**Milestones**

- M1 ✅ 2026-05-23 — Rust PCI skeleton.
  Evidence: [`baseline/m1_gate_proof.txt`](baseline/m1_gate_proof.txt).
- M2 ✅ 2026-05-24 — register / reset / ASPM-log.
  Evidence: [`baseline/m2_gate_proof.txt`](baseline/m2_gate_proof.txt).
- M3 ✅ 2026-05-24 — cold DMA ring allocation (TX + RX rings, 256 desc
  + tail canary, two-layer canaries, DMA_API_DEBUG clean).
  Evidence: [`baseline/m3_gate_proof.txt`](baseline/m3_gate_proof.txt).
- **M0b ✅ 2026-05-25** — TOPOLOGY.md fully populated; 8 r8169 iperf3
  baselines (TCP/UDP × 1500/9000 × both directions) JSON-archived; peer
  packet-capture procedure verified (193 KB headers-only pcap). M1
  board rows **7, 10, 11 flipped to ✅**. TCP across all configurations
  hits 93–99 % of the 2.5GbE wire (2.33–2.48 Gb/s); a documented UDP
  guest→host asymmetry at 1500 MTU is a debug-guest software bottleneck,
  not RTL8125. Evidence: [`baseline/m0b_proof.txt`](baseline/m0b_proof.txt),
  [`baseline/TOPOLOGY.md`](baseline/TOPOLOGY.md),
  [`baseline/iperf3/`](baseline/iperf3/) (8 JSON + 1 pcap).
- **M4-skeleton ✅ 2026-05-24** — composite module (Rust + focused C
  shim) registers a `net_device` per probe, RAII-cleans on rmmod;
  vtable + §6.3 ownership contract in `src/netdev_bridge*.{c,h}` with
  carrier off + queues stopped; 1000-cycle regression passes (177 s,
  1000/1000 probe + DMA-rings + netdev-registered lines, 0
  kmemleak/dma_debug/lockdep/BUG/WARN/KASAN). Evidence:
  [`baseline/m4_skeleton_proof.txt`](baseline/m4_skeleton_proof.txt),
  [`baseline/m4_skeleton_gate_log.txt`](baseline/m4_skeleton_gate_log.txt),
  [`baseline/m4_skeleton_journalctl_excerpt.txt`](baseline/m4_skeleton_journalctl_excerpt.txt).
- M4-full ✅ unblocked — peer + iperf3 baseline in place; cshim + RAII
  handle landed at M4-skeleton. Ready to implement the 9-item peer-driven
  list from `baseline/m4_skeleton_proof.txt`.

## Runbook phase status

| Phase | Status | Notes |
|---|---|---|
| 1 — distro kernel-rust toolchain (host) | ✅ | rustc 1.93.1 pinned |
| 2 — build debug+Rust guest kernel | ✅ | `~/kbuild/*.deb` |
| 3 — pin host mgmt to I226-V, isolate L2 | ⏸️ **deferred** | not an M1 gate; gates M0b row 10. Host mgmt already on Wi-Fi (≠ RTL8125) so VFIO unbind was safe without it. Staged netplan still at `~/.local/state/rtl8125-agent/99-mgmt-i226.yaml` |
| 4 — host VFIO 100× bind-cycle | ✅ 2026-05-22 | 100/100 clean, zero WARN/oops — `baseline/vfio_bindcycle_dmesg.txt`; loop lifted to `tools/vfio_bindcycle.sh` |
| 5 — create guest, pass through NIC | ✅ | guest sees RTL8125 at `05:00.0` |
| 6 — serial-console panic test | ✅ 2026-05-22 | full panic trace captured host-side — `baseline/guest_serial_panic_proof.txt` |
| 7 — guest OOT Rust load-loop | ✅ 2026-05-22 | 100× insmod/rmmod clean — `baseline/guest_oot_loadloop.txt` |
| 8 — re-capture + flip M1 board | ✅ 2026-05-22 | `dmidecode` captured, board flipped, `ci/run_checks.sh` green |

## Done since the last resume (2026-05-22 → 2026-05-23)

### M0a → M1 close-out (2026-05-22)

- **Phase 4**: 100× r8169↔vfio-pci bind-cycle clean, zero kernel WARN/oops.
  New committed script `tools/vfio_bindcycle.sh`; evidence
  `docs/baseline/vfio_bindcycle_dmesg.txt`.
- **Phase 6**: VM XML patched to add a libvirt `<log>` element on the serial
  device; deliberate sysrq-c panic captured as text on the host via
  `virsh console` under a `script(1)` pty. Evidence
  `docs/baseline/guest_serial_panic_proof.txt`.
- **Phase 8**: `capture_m0_baseline.sh` re-run under sudo — `hw_dmidecode.txt`
  populated (Ryzen 9 9955HX 16C/32T, 32 GB DDR5-5600). M1 board flipped
  (rows 1/4/5/8/13/14/18 → ✅). Runbook Phase 7 doc bugs fixed.

### M1 — Rust PCI skeleton (2026-05-23)

- Wrote `src/r8125_rust.rs` (crate root with `#![deny(unsafe_code)]` and
  `module_pci_driver!` registration), `src/pci.rs` (`pci::Driver` impl
  matching VID `0x10EC` / DID `0x8125`, BAR2 64 KiB iomap), and
  `src/unsafe_boundary.rs` (the designated `#![allow(unsafe_code)]` boundary,
  empty at M1 because the kernel `pci`/`io`/`devres` abstractions cover it).
  Plus `src/Kbuild` and a top-level `Makefile`.
- Validated the plan §5.1 API claims against the actual kernel tree
  (`kernel::pci::{Driver, Device, DeviceId, Vendor::REALTEK,
  iomap_region_sized, config_space}`, `kernel::devres::Devres`,
  `kernel::sync::aref::ARef`, `pin_init::pin_init_scope`).
- Build with `make` against the guest's `/lib/modules/7.0.0/build` and
  `rustc-1.93` — clean (KASAN-instrumented .ko, 978 KiB).
- **M1 gate**: 1,000 cycles, 123 s, every probe ran, refcount → 0 each cycle,
  zero kmemleak/lockdep/BUG/WARN/KASAN reports. Evidence
  `docs/baseline/m1_gate_proof.txt`, `m1_gate_log.txt`,
  `m1_kmemleak_final.txt` (0 bytes).
- New committed-quality scripts: `tools/m1_gate.sh` (reproducible gate);
  `ci/check_unsafe_allowlist.sh` tightened (regex now counts unsafe **code**,
  not the word in doc comments, and recognises `src/r8125_rust.rs` as the
  crate root). `ci/run_checks.sh` stays green.

### M0b survey + M4-skeleton (2026-05-24)

- **M0b survey** captured (task 21): RTL8125 link is healthy
  (2.5G/Full, EEE supported but inactive, fw `rtl8125b-2_0.0.2 07/13/20`).
  Cable goes to the main LAN (`192.168.68.x` — printer / NetBIOS /
  UPnP traffic visible in tcpdump on `enp5s0`), which fails the plan
  §8.1.6 L2-isolation criterion. Operator chose to defer M0b until
  an isolated peer is ready; tasks 22–25 paused; M1 board rows
  7/10/11 stay un-flipped.
- **M4-skeleton landed** (tasks 26–31): composite module with the
  C shim (`src/netdev_bridge*.{c,h}`, encoding the full §6.3
  sk_buff ownership contract), `src/netdev.rs` (Rust `BridgeOps`
  vtable + `NetdevHandle` RAII), and the cshim FFI bridge in
  `src/unsafe_boundary.rs`. Crate root renamed
  `r8125_rust.rs → r8125_rust_main.rs` to avoid a kbuild
  circular-dep on the composite name (same pattern as
  `samples/rust/rust_print_main.rs`). The Kbuild is now
  `obj-m += r8125_rust.o; r8125_rust-y := r8125_rust_main.o
  netdev_bridge.o`. `ci/.unsafe-census` re-baselined `3 → 10`.
  1000-cycle regression passes clean (probe + DMA-rings + netdev
  register/unregister, 1000/1000 each, 177 s, zero warnings of any
  kind). Evidence in `docs/baseline/m4_skeleton_*.txt`.

### M3 — cold DMA ring allocation (2026-05-24)

- Added `src/ring.rs` (16-byte `#[repr(C)]` `Descriptor` matching r8169
  TxDesc/RxDesc layout; const `RING_LEN = 256`; typed `TxHead/TxTail/
  RxHead/RxTail` newtypes; `Ring<N>` holds `CoherentAllocation<Descriptor>`
  of `N+1` slots — last slot is a tail canary in DMA-coherent memory;
  parallel `[u64; N]` software shadow with `0xDEAD_BEEF_CAFE_BABE` pattern;
  `verify_canaries()` checks both layers; `Ring::new()` zeros the hardware
  descriptors and plants the canary at slot N).
- Added `src/dma.rs` — light, holds the M4 streaming-mapping plan (RX-refill
  + TX-completion ownership state machine per plan §6.3) and a pointer at
  `unsafe_boundary::set_64bit_dma_mask`.
- `src/unsafe_boundary.rs` gains its first three residents at M3:
  `set_64bit_dma_mask(pdev)` wrapping `unsafe { pdev.dma_set_mask_and_coherent(mask) }`,
  plus `unsafe impl AsBytes/FromBytes for ring::Descriptor`. Each carries a
  `// SAFETY:` comment covering the §6.2 contract (hardware invariant,
  memory ownership, ordering, no-UAF, no-overrun). `ci/.unsafe-census`
  re-baselined `0 → 3` to reflect the intentional bump.
- `src/pci.rs` probe now: set 64-bit DMA mask after `enable_device_mem`,
  allocate TX + RX rings as struct fields (auto-freed on drop), `dev_info!`
  the DMA handles + ring length, call `verify_canaries()` once at end of
  probe.
- Build with `make` clean (KASAN-instrumented .ko, ~1.08 MiB),
  `rustc-1.93`.
- **M3 gate**: 1000 cycles in 129 s, every probe ran (per `journalctl -k`),
  zero `kmemleak` / `dma_debug` / lockdep / BUG / WARN / KASAN / UBSAN
  reports. Evidence `docs/baseline/m3_gate_proof.txt`, `m3_gate_log.txt`,
  `m3_journalctl_excerpt.txt`.

### M2 — register / reset / ASPM-log layer (2026-05-24)

- Added four modules per plan §6.1: `src/regs.rs` (offsets/bits — TxConfig,
  ChipCmd, CmdReset, XID shift/mask), `src/mmio.rs` (typed `Regs` wrapper
  around `pci::Bar` — the only module that imports `kernel::io::Io` or
  touches `bar.read*` / `bar.write*`), `src/hw.rs` (XID-based dispatch table
  mirroring r8169's `rtl_chip_infos`, one entry today — `RTL8125B XID 0x641`;
  reset sequence mirroring r8169's `rtl_hw_reset` with 100×100 µs poll;
  `inject_timeout` argument), `src/pm.rs` (probe-time `dev_info!` of PCI
  Status + CAP_LIST bit; full cap-list walk + `pci_disable_link_state` policy
  recorded as deferred — kernel Rust API doesn't expose either piece).
- Added `inject_reset_timeout` module parameter (u8, default 0) to drive the
  plan §7 M2 "tested by deliberate timeout injection" requirement.
- Build with `make` clean (KASAN-instrumented .ko, ~1.0 MiB), `rustc-1.93`.
- **M2 gate**: every plan §7 M2 acceptance point ✅. 1,000-cycle regression
  clean (1000/1000 probe + identify + reset-OK confirmed via `journalctl -k`,
  0 kmemleak/lockdep/BUG/WARN/KASAN). Failure-injection probe returns -EIO
  cleanly; r8169 rebinds the device after our failed probe. Evidence
  `docs/baseline/m2_gate_proof.txt`, `m2_gate_log.txt`,
  `m2_journalctl_excerpt.txt`.
- Tooling: `tools/m1_gate.sh` updated to use `journalctl -k` instead of
  `dmesg` (the kernel ring buffer wraps when probe emits 4 lines × 1000
  cycles).

## Next actions — when the peer is ready

1. **Re-cable** the RTL8125 to an isolated test segment with the new peer.
2. **Resume M0b**: tasks 22–25 (TOPOLOGY.md, r8169 iperf3 baselines, peer
   capture, board flip). The link itself is already auto-negotiating at
   2.5G/Full — that part doesn't change.
3. **Resume M4-full** — see `baseline/m4_skeleton_proof.txt` §"What
   remains for M4-full" for the nine concrete items. Highest-impact
   ordering:
   1. Read the real MAC from `IDR0..IDR5` MMIO (replace the
      `02:00:00:00:00:01` skeleton MAC).
   2. Wire IRQ via `pci::Device::request_irq` with a `Handler` that
      calls `r8125_bridge_napi_schedule`.
   3. Implement `ndo_open` HW-enable + RX-buffer post; `ndo_stop`
      reverse — both via `src/hw.rs` (new register pokes).
   4. `src/skb.rs` type-state `TxSkb<S>` per §6.3.
   5. `src/napi.rs` RX-completion + TX-completion bodies.
   6. `ndo_start_xmit` flow-control invariants from §6.3.
   7. `ip link up/down` 100-cycle test (plan §7 M4).
   8. ARP/ping/DHCP + iperf3 baselines (against the M0b peer).
   9. CI smoke test asserting the §6.3 counter invariant
      `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error`.

### M2/M3 sub-tasks deliberately deferred

- **Full ASPM cap-list walk + `pci_disable_link_state` policy**: blocked by
  two kernel-Rust-API gaps — `ConfigSpace::try_read*` is a `build_error!`
  stub, and `pci::Device::as_raw()` is private. Both unblock once the M4
  cshim lands (which gives us a C-side `pci_find_capability` /
  `pci_disable_link_state` shim) or when upstream `kernel::pci::aspm`
  arrives. Recorded in `src/pm.rs` module doc.
- **Mechanical raw-MMIO containment beyond the current
  `readl|writel|read_volatile` grep**: a future `ci/check_unsafe_allowlist.sh`
  tightening could grep for `bar\.(read|write)[0-9]+` outside
  `src/mmio.rs`/`src/unsafe_boundary.rs`. Currently containment is
  convention-enforced (only `src/mmio.rs` imports `kernel::io::Io` and
  calls `bar.*`).

### Deferred / M0b (do NOT block M1)

- **Phase 3** netplan switchover (pin host mgmt to I226-V `enp4s0`). Staged at
  `~/.local/state/rtl8125-agent/99-mgmt-i226.yaml`. Gates M0b row 10.
- **M0b** rows 7/10/11: complete `docs/baseline/TOPOLOGY.md`, isolate the
  RTL8125 test segment, take `r8169`/`r8125` iperf3 baselines vs a documented
  peer. Required before **M4**.

## Hardware / VM facts

- Host: MS-A2 (`ms-a2-controller`), Ubuntu 26.04, host kernel `7.0.0-15-generic`
  (stock). CPU AMD Ryzen 9 9955HX 16C/32T, 32 GB DDR5-5600.
- RTL8125B: PCI `0000:03:00.0`, XID 0x641 rev 0x05, IOMMU group 18 isolated.
  Host netdev `enp3s0` when on `r8169`; 2.5Gbps link up.
- VM `rtl8125-guest`: NAT `192.168.122.174`, **running**, autostart disabled,
  custom kernel `7.0.0 #2` (KASAN+lockdep+kmemleak+DMA_API_DEBUG+Rust). RTL8125
  passed through (`hostdev managed='yes'`) at guest `05:00.0`.
- SSH key `~/.ssh/agent/rtl8125_guest_codex`; guest has NOPASSWD sudo.
- Host sudo: **full NOPASSWD ALL** as of 2026-05-23 — `operator ALL=(ALL)
  NOPASSWD: ALL` at `/etc/sudoers.d/rtl8125-agent`. `sudo -n` works for any
  command. The v1 narrow scoped grants from 2026-05-21 are superseded; the
  v1 file is kept at `~/.local/state/rtl8125-agent/rtl8125-agent.sudoers`
  and a scoped v2 alternative at `…sudoers.v2-scoped` if you ever want to
  tighten back down.
- Tailscale fallback: `operator@100.127.54.33`.

## Uncommitted

The repo still has a single commit (`558b907`). Everything from this and the
prior session — the M1 source (`src/{r8125_rust,pci,unsafe_boundary}.rs`,
`src/Kbuild`, `Makefile`), the M0a→M1 evidence (`docs/baseline/m1_*.txt`,
`vfio_bindcycle_dmesg.txt`, `guest_serial_panic_proof.txt`, refreshed baseline
files), the doc edits (M1 board, runbook, SESSION_RESUME, src/README), and
the new tools (`tools/vfio_bindcycle.sh`, `tools/m1_gate.sh`) — is
**uncommitted**. Commit scope/message is an operator decision.

## Gotchas

- VM `autostart` is **disabled** — `virsh start rtl8125-guest` after a host
  reboot.
- VM XML now differs from `~/.local/state/rtl8125-agent/rtl8125-guest.patched.xml`
  (the `<log>` serial element was added this session). The live libvirt
  definition is canonical.
- `virsh console` needs a controlling TTY — wrap it in `script(1)` when
  driving it non-interactively.
- Build any kernel/module artifact with `rustc-1.93`, never the rustup 1.95
  userspace default.
