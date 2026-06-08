# CI gate inventory + transferability tags

Tier 4c of [`POST_SOAK_PLAN.md`](../docs/POST_SOAK_PLAN.md). Tags
every gate by how much of it transfers to the next Rust kernel
driver project. See [`PATTERNS.md`](../docs/PATTERNS.md) for the
underlying classification rationale.

## Legend

- `[generic]` — applies to ANY Rust kernel driver; copy verbatim
- `[netdev]` — applies to ANY Rust netdev driver; copy + adjust
  symbol / file names to the new driver's layout
- `[rtl8125]` — encodes RTL8125B-specific chip knowledge; replace
  per chip

## Generic — copy verbatim to next driver (11 gates)

| Gate | What it enforces |
|---|---|
| `check_unsafe_allowlist.sh` | `#![deny(unsafe_code)]` outside the boundary file + `.unsafe-allowlist` + non-increasing `.unsafe-census` |
| `check_no_panic_paths.sh` | No `unwrap()` / `expect()` / `panic!` reachable from kernel context |
| `check_dco_assistedby.sh` | Commit messages have human `Signed-off-by:` paired with any `Assisted-by:` per kernel AI policy |
| `check_rustfmt.sh` | Rust sources are rustfmt-clean without requiring a Cargo manifest |
| `check_clippy.sh` | Kernel-build clippy clean (uses rustc-1.93 toolchain pin in the Makefile) |
| `check_sparse.sh` | Kbuild `C=2 CHECK=sparse` clean when sparse is installed |
| `check_smatch.sh` | Kbuild `C=2 CHECK=smatch` clean when smatch is installed |
| `check_cache_padding.sh` | Cross-context shared atomics wrap in `CachePadded<T>` |
| `check_clean_contract_docs.sh` | Source comments don't reference stale milestones / removed IRQ modes / etc. |
| `check_build_makefile.sh` | Kbuild wrapper uses kernel's CC, post-link BTF generation, excludes Rust DWARF from pahole |
| `check_bare_metal_stack_teardown.sh` | `KBox::init` (not `KBox::new`) for large state + `pci::Driver::unbind` drains netdev BEFORE devres release + `NetdevHandle::shutdown` is idempotent |

## Netdev pattern — copy + adjust per next NIC driver (12 gates)

| Gate | What it enforces |
|---|---|
| `check_counter_infrastructure.sh` | §6.3 disposition-counter set is allocated, exported via ethtool -S, summed across CPUs |
| `check_counter_invariant.sh` | Runtime: `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error` after 1 GB transfer |
| `check_cshim_loc_caps.sh` | Per-file `Hard cap: N LOC` marker on every cshim TU + enforcement |
| `check_no_bridge_exports.sh` | C shim helpers stay module-private; no accidental global `EXPORT_SYMBOL*` API |
| `check_mdio_bridge.sh` | MDIO bus alloc/register/free lifecycle + PHY init failure unwinds via disconnect + reg-range validation |
| `check_napi_contract.sh` | NAPI poll rules: `budget==0` no complete_done, `work_done<budget` complete_done+rearm, queue hysteresis, TX-tail-before-wake ordering |
| `check_offload_path.sh` | TSO/CSUM setup BEFORE DMA map + one-call TX offload prep + normal UDP stays on HW checksum + scoped pad/software-CSUM fallback + linear unmap uses shadow length + TSO advertisement paired with chip max_segs/max_size |
| `check_packet_mutation.sh` | `ndo_start_xmit` doesn't write shared-clone fields of skb |
| `check_rmmod_while_up.sh` | `rmmod` under traffic completes without `BUG`/`WARN` — the #58 fix discipline |
| `check_skb_ownership.sh` | `DriverOwnedSkb` shape: `#[must_use]`, `#[repr(transparent)]`, no `Drop`, FFI-only `from_raw`, consume verbs only |
| `check_selftest_smoke.sh` | Upstream-style net selftest exists, emits TAP, skips cleanly, and covers load/netdev/unload shape |
| `check_soak_harness.sh` | Long-running soak harnesses parse, report traffic-generator failures, and fail without observed packet progress |

## RTL8125-specific — replace per chip (14 gates)

These encode chip knowledge: register names, masks, ASPM behavior,
init sequence parity with `r8169_main.c`. For a different chip
they need rewriting against that chip's authoritative source.

| Gate | Chip knowledge encoded |
|---|---|
| `check_hw_init.sh` | r8169-parity bring-up sequence; balanced config-unlock/lock around fallible init; PCIe power-state writes |
| `check_hw_offload_features.sh` | RTL8125 VLAN descriptor/RxConfig contract; RXHASH advertisement is paired with V3 hash parsing, `skb_set_hash`, counters, and one-queue RSS programming while hardware RSS remains separately gated |
| `check_irq_mode_contract.sh` | `IrqMode` enum + `INT_CFG0_ENABLE_8125 = BIT(0)` chip-side V2 activation gated on probe-selected mode |
| `check_isr_v2_paired.sh` | V2 ISR/IMR mask register pairing (`IMR_V2_CLEAR`/`IMR_V2_SET`/`ISR_V2`); reserved-bit avoidance |
| `check_msix_static.sh` | RTL-specific MSI-X register surface; `intx_only` rollback module param exists |
| `check_jumbo_mtu_chip.sh` | `RxMaxSize` set to `RX_MAX_SIZE_JUMBO` + `ChipInfo.max_mtu` field present |
| `check_rx_pool_pages.sh` | `alloc_pages(order=2)` (16 KiB per slot specific to 8125B's jumbo cap) + matching unmap discipline + ndo_open rollback releases jumbo slots |
| `check_rss_queue_contract.sh` | RTL8125B full-RSS prerequisite: queue-id-aware C/Rust bridge plus vendor RDSAR_Q1 queue-base layout while runtime stays N=1 |
| `check_rss_hw_programming.sh` | RTL8125B RSS register programming is off-by-default, bounded by owned queues/V2 interrupt ownership, and uses Linux's default indirection helper |
| `check_packet_mutation.sh` * | (Also netdev-pattern — RTL-side enforcement of TSO MSS 11-bit cap workaround) |
| `check_flr_cycle.sh` | Function-Level Reset cycle behavior specific to this chip's reset state machine |
| `check_active_soak.sh` | Active-traffic soak harness — references `enp5s0`/10.0.0.0/24 wiring (re-parameterized in Tier 4b) |
| `check_aspm_idle_soak.sh` | ASPM-on idle soak — chip-specific L1.x lockup detection |
| `check_aspm_on_idle_soak.sh` | Companion to above; runtime ASPM state verification |
| `check_aspm_both_soaks.sh` | Combined idle + active soak orchestration |

`check_packet_mutation.sh` is listed in both buckets — partly
netdev-pattern, partly RTL-specific.

## Summary table

| Class | Count | Effort for next driver |
|---|---:|---|
| `[generic]` | 11 | minutes (copy + adjust paths) |
| `[netdev]` | 12 | ~1 h (copy + adjust symbol names) |
| `[rtl8125]` | 14 | full rewrite per chip (~half a day each) |
| **Total** | **37** | |

The 11 `[generic]` + 12 `[netdev]` gates are the **starter pack** the
next Rust NIC driver project should clone first. Together they
cover the disciplines that prevent the bug classes named in
[`PATTERNS.md`](../docs/PATTERNS.md) §"Bug-class index".

## Recommended header tagging

Each gate's header should carry a `# Transferability: [generic|netdev|rtl8125]`
line so the tag is visible at the call site, not just here.
Format:

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Transferability: [netdev]
#
# <existing description>
```

Applying that tag line is a 5-min follow-up after this inventory
sticks. Not done in this turn to keep the diff focused on the
inventory itself.

## Cross-references

- [`../docs/PATTERNS.md`](../docs/PATTERNS.md) — the transferable-pattern catalog this enforces
- [`../docs/POST_SOAK_PLAN.md`](../docs/POST_SOAK_PLAN.md) §Tier 4c — schedule
- [`run_checks.sh`](run_checks.sh) — orchestrator
