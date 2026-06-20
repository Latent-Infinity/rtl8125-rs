# Unsafe census justifications

Every census bump (rejected by `ci/run_checks.sh`) needs a
short rationale here. Append; never delete.

## 2026-06-13 — system-sleep PM bump 76 → 78

Net +2 `unsafe { ... }` blocks in `src/unsafe_boundary.rs` for the pci::Driver
suspend/resume callbacks (kernel-Rust PCI PM extension; see docs/PM_GAP.md +
kernel-patches/0001-rust-pci-add-pm-callbacks.patch).

- ADDED `bridge_pm_suspend(ndev)` — wraps `r8125_bridge_pm_suspend`, which takes
  RTNL and (if the iface was up) detaches + quiesces via the existing ndo_stop.
- ADDED `bridge_pm_resume(ndev)` — wraps `r8125_bridge_pm_resume`, which re-inits
  via ndo_open + reattaches. SAFETY for both: `ndev` is the registered
  net_device (null-checked in the wrapper; the C side no-ops on a down iface),
  called from the PM callback while the device is bound. No ownership/MMIO/skb at
  the boundary; the chip work is the already-audited ndo_open/stop paths.

## 2026-06-11 — MAC RX-filter programming bump 75 → 76

Net +1 `unsafe { ... }` block in `src/unsafe_boundary.rs` for the vendor-accurate
MAC handling (read BACKUP_ADDR + rar_set the chip RX filter at open, so the
hardware unicast filter matches `dev_addr` — fixes "link up but no RX" after a
reset clears IDR0 or after a random-MAC fallback; mirrors `rtl8125_rar_set`).

- ADDED `bridge_dev_addr(ndev) -> [u8; 6]` — wraps `r8125_bridge_dev_addr`,
  which `memcpy`s exactly `ETH_ALEN` (6) bytes of `ndev->dev_addr` into the
  caller's buffer. SAFETY: `ndev` is the registered `net_device` alive across the
  call; the destination is a fixed 6-byte stack array matching ETH_ALEN. No
  ownership transfer, no MMIO, no skb. The MMIO write of the address
  (`Regs::set_mac_address`) is in safe `mmio.rs` via the typed `Bar` accessors.

## 2026-05-25 — traffic-path PHY plumbing bump 43 → 46

Net +3 `unsafe { ... }` blocks in `src/unsafe_boundary.rs`: four new wrappers
for the C-side PHY plumbing, minus the removed Rust `carrier_on` wrapper now
handled directly by the C PHY link handler.

- `bridge_phy_register(ndev, &BridgeMdioOps)` — wraps the C
  `r8125_bridge_phy_register` call that allocates the MDIO bus,
  registers it, walks for a PHY device, and binds the dedicated PHY
  driver. SAFETY: `ndev` is a registered `net_device` alive for the
  duration of the call; `ops` is borrowed only for the call (the cshim
  copies the struct).
- `bridge_phy_connect_and_reset(ndev)` — wraps
  `r8125_bridge_phy_connect_and_reset` (phy_connect_direct + phy_init_hw
  + genphy_soft_reset + phy_resume). SAFETY: `ndev` alive; idempotency
  guard inside the cshim handles double-call.
- `bridge_phy_kick_state_machine(ndev)` — wraps the `phy_start` call.
  SAFETY: `ndev` alive; the phy was connected by the preceding
  `bridge_phy_connect_and_reset`.
- `bridge_phy_stop(ndev)` — wraps `r8125_bridge_phy_stop` (phy_stop +
  phy_disconnect). SAFETY: `ndev` alive; idempotent (the cshim no-ops if
  the phy never reached the connected state).

These are mechanical FFI wrappers — each is a single line of `unsafe`
calling out to the C side. The C side is the actual boundary; the Rust
side preserves the unsafe-boundary discipline by keeping every `unsafe`
block in the one allowlisted file with a SAFETY comment.

No new MMIO-touching `unsafe` was added by this change; all MMIO for
the PHY OCP path goes through the existing `Regs::gphy_ocp_*` methods
which use the kernel `pci::Bar` accessors (safe).

## 2026-05-25 — performance offload wrappers bump 46 → 49

Three new safe wrappers in `src/unsafe_boundary.rs`, each a one-line
`unsafe { … }` calling a C bridge function:

- `skb_tx_csum_opts(skb) -> u32` — wraps `r8125_bridge_skb_tx_csum_opts`.
  SAFETY: `skb` is the kernel-allocated buffer just received by
  ndo_start_xmit; the driver holds the unique reference.
- `skb_rx_csum_set(skb, opts1)` — wraps `r8125_bridge_skb_rx_csum_set`.
  SAFETY: `skb` was just built by `skb_build_rx` (driver-owned).
- `bridge_account_rx(ndev, bytes)` — wraps `r8125_bridge_account_rx`.
  SAFETY: `ndev` is registered and alive (NetdevHandle holds the
  reference until Drop).

All three mutate state owned by the kernel net stack (skb fields, netdev
stats) and are therefore mechanical FFI wrappers. No new MMIO unsafe
was added by this change.

## 2026-05-25 — SG/TSO wrappers (WIP) bump 49 → 53

Six SG/TSO wrappers were added in `src/unsafe_boundary.rs`, each a
one-line `unsafe { … }` calling a C bridge function. The obsolete
single-buffer TX map/complete wrappers were retired after the SG path
started tracking per-descriptor DMA mappings, so the net census moves
49 → 53.

- `skb_nr_frags(skb) -> u32` — wraps `r8125_bridge_skb_nr_frags`.
  SAFETY: `skb` is the kernel-allocated buffer just received by xmit
  (driver-owned exclusively at this moment).
- `skb_data_dma_map(pdev, skb, &out_handle, &out_len)` — wraps
  `r8125_bridge_skb_data_dma_map`. SAFETY: `pdev` alive via ARef;
  `skb` driver-owned.
- `skb_frag_dma_map(pdev, skb, frag_idx, &out_handle, &out_len)` —
  wraps `r8125_bridge_skb_frag_dma_map`. SAFETY: as above; `frag_idx`
  validated by the C side against `nr_frags`.
- `skb_dma_unmap_frag_tx(pdev, handle, len)` — wraps
  `r8125_bridge_skb_dma_unmap_frag_tx`. SAFETY: `handle/len` came from
  a prior successful `skb_frag_dma_map`; this pairs the page-based map
  helper with `dma_unmap_page`.
- `skb_tso_setup(skb) -> Option<(u32, u32)>` — wraps
  `r8125_bridge_skb_tso_setup`. SAFETY: as above; the C side may
  mutate skb (skb_cow_head + tcp_v6_gso_csum_prep) on IPv6 TSO.
- `skb_consume_tx(ndev, skb)` — wraps `r8125_bridge_skb_consume_tx`.
  SAFETY: `ndev` alive (NetdevHandle); `skb` is the LastFrag-slot
  pointer the NAPI reaper has just swapped out of `tx_shadow`.

Note: `NETIF_F_SG` is advertised after the per-fragment DMA unmap fix
and is covered by the task #49 SG proof. `NETIF_F_TSO | NETIF_F_TSO6`
are now advertised with the RTL8125B-specific `netif_set_tso_max_segs`
cap documented in `docs/RTL8125B_TSO_NOTES.md`. This did not require
additional unsafe wrappers.

## 2026-05-28 — jumbo RX-pool refactor bump 53 → 54

Net `unsafe { … }` count moves 53 → 54 in `src/unsafe_boundary.rs`:

**Added (4)** — FFI surface for the per-slot streaming-DMA RX pool
(`src/netdev_bridge_rx_pool.c`):

- `rx_alloc_jumbo(pdev) -> (cpu, dma)` — wraps
  `r8125_bridge_rx_alloc_jumbo`. SAFETY: `pdev` is alive via ARef; the
  cshim allocates one `order-2` page chunk + `dma_map_page(FROM_DEVICE)`,
  freeing both atomically on failure so the Rust side can't double-free.
- `rx_free_jumbo(pdev, cpu, dma)` — wraps `r8125_bridge_rx_free_jumbo`
  which does `dma_unmap_page` + `__free_pages(virt_to_page(cpu))`.
  SAFETY: `(cpu, dma)` are either both null (no-op short-circuit) or
  the values returned from a prior `rx_alloc_jumbo` on the same pdev.
- `rx_sync_for_cpu(pdev, dma, len)` — wraps
  `r8125_bridge_rx_sync_for_cpu` (`dma_sync_single_for_cpu`). SAFETY:
  `dma` came from a prior `rx_alloc_jumbo`; `len` is bounded by the
  chip-side `RxMaxSize` which we program to `JUMBO_16K_BYTES - 1`.
- `rx_sync_for_device(pdev, dma)` — wraps
  `r8125_bridge_rx_sync_for_device` (`dma_sync_single_for_device`).
  SAFETY: as above; the whole buffer is synced because the chip can
  fill any portion of it next time.

**Removed (3)** — the earlier coherent-allocation RX pool helpers:

- `rx_buf_ptr(bufs, idx)` — slot-pointer math inside the
  `CoherentAllocation<RxBuffer>` is gone; NAPI reads
  `state.rx_slot(i).cpu` directly.
- `unsafe impl AsBytes for RxBuffer` — `RxBuffer` was the contents of
  the coherent allocation; the type is dropped now that the pool moved
  to per-slot streaming-DMA pages.
- `unsafe impl FromBytes for RxBuffer` — same reason.

Net: +4 added − 3 removed = +1. The new helpers are all mechanical
FFI wrappers around C cshim functions that themselves perform the
allocation, mapping, and free; no MMIO-touching unsafe is introduced.

## 2026-05-30 — RX accounting move decrement 54 → 53

`bridge_account_rx(ndev, bytes)` removed from `src/unsafe_boundary.rs`.
RX packet/byte accounting now lives next to `napi_gro_receive` inside
`r8125_bridge_rx_one_packet`, so the RX hot path makes one fewer FFI
crossing per packet. See `docs/RX_OPTIMIZATION_CANDIDATES.md` for
the rationale.

TX accounting (`bridge_account_tx` / `r8125_bridge_account_tx`) is
unchanged: xmit calls it once per skb (not per packet), so the FFI
cost is bounded and the symbol stays as-is.

## 2026-05-30 — RX super-call consolidation decrement 53 → 47

The `bridge_rx_one_packet` super-call (see
docs/RX_OPTIMIZATION_CANDIDATES.md) collapses five per-packet FFI
crossings into one cshim entry point. Net effect on the Rust unsafe
boundary: **7 wrappers removed**, **1 wrapper added** = census
53 → 47.

Removed Rust safe wrappers + extern declarations
(`src/unsafe_boundary.rs`):

- `skb_build_rx` / `r8125_bridge_skb_build_rx` — replaced by
  cshim-internal `napi_alloc_skb` inside `bridge_rx_one_packet`.
- `skb_deliver_rx` / `r8125_bridge_skb_deliver_rx` — replaced by
  cshim-internal `napi_gro_receive`.
- `rx_drop_error` / `r8125_bridge_rx_drop_error` — cshim handles
  the `rx_dropped_error` bump internally on alloc failure.
- `rx_sync_for_cpu` / `r8125_bridge_rx_sync_for_cpu` — replaced by
  cshim-internal `dma_sync_single_for_cpu`.
- `rx_sync_for_device` / `r8125_bridge_rx_sync_for_device` —
  replaced by cshim-internal `dma_sync_single_for_device`.
- `bridge_napi` / `r8125_bridge_napi` — `bridge_rx_one_packet` gets
  `&b->napi` directly via `netdev_priv`.
- `skb_rx_csum_set` / extern decl — the cshim symbol stays but is
  now called C-side only from inside `bridge_rx_one_packet`.

The corresponding `DriverOwnedSkb` methods (`build_rx`,
`rx_csum_set`, `deliver_rx`) were also removed from `src/skb.rs`;
the type is now TX-only.

Added Rust safe wrapper + extern declaration (+1):

- `bridge_rx_one_packet` / `r8125_bridge_rx_one_packet` —
  super-call.

Net change to the unsafe surface: **-6 items**. The C cshim
symbols/prototypes that became dead were removed instead of kept as
private ABI.

## 2026-05-30 — RX loop hoist + per-CPU TSTATS (no census change)

Hoisting `state.ndev.load` out of the NAPI RX loop and the per-CPU
`dev_sw_netstats_{rx,tx}_add` + `NETDEV_PCPU_STAT_TSTATS` accounting
shipped without changing the unsafe surface. Both are inside the
cshim or inside existing safe Rust code; no new wrappers, no extern
decl changes. Census remains 47.

The `rx_packets`/`rx_bytes`/`tx_packets`/`tx_bytes` counters now
live in per-CPU storage allocated by the kernel core when
`pcpu_stat_type` is set at bridge_alloc; the kernel sums across
CPUs on stats-read via `dev_get_tstats64`. The application-visible
`ip -s link show enp5s0` output is unchanged in semantics.

The bounds-check-elision optimization was skipped (LLVM bounds-check
elision is sufficient; `unsafe` surface trade-off not worth marginal
gain). See `docs/RX_OPTIMIZATION_CANDIDATES.md`.

## 2026-05-30 — IRQ affinity hint bump 47 → 48

Added `bridge_irq_pin_cpu(irq, cpu)` safe wrapper in
`src/unsafe_boundary.rs`. Calls the new cshim
`r8125_bridge_irq_pin_cpu` which calls `irq_set_affinity_and_hint`
to nudge the kernel + irqbalance toward keeping the chip's MSI-X
vector on a specific CPU. Latency-aligned default for the
heterogeneous-LB use case (see docs/RX_OPTIMIZATION_CANDIDATES.md).

Net change: +1 unsafe wrapper (mechanical FFI call). No MMIO
touching unsafe added.

The `tx_queue_len` change (1000 → 256) is cshim-side only and
introduces no Rust unsafe.

## 2026-05-30 — RX descriptor dma_rmb bump 48 → 49

Added `dma_rmb()` safe wrapper in `src/unsafe_boundary.rs`. Calls the
new cshim `r8125_bridge_dma_rmb`, which invokes Linux `dma_rmb()` after
the RX descriptor OWN bit clears and before Rust reads descriptor
length/checksum fields or DMA-written bytes.

This mirrors r8169's `rtl_rx` ordering and closes the weak-memory
correctness gap documented in
`docs/RX_OPTIMIZATION_CANDIDATES.md`. The helper has no pointer or
ownership preconditions; the safety contract is ordering-only and is
enforced by `ci/check_rx_skb_build.sh`.

## 2026-05-31 — descriptor publish barrier bump 49 → 51

Added `dma_wmb()` safe wrapper in `src/unsafe_boundary.rs`, calling
the new cshim `r8125_bridge_dma_wmb` (which calls Linux `dma_wmb()`).
Also added `desc_publish_own`, the reviewed descriptor publisher that
writes `addr` and `opts2`, calls `dma_wmb()`, then writes `opts1` as
the OWN-bit handoff.

Call sites:

- `src/napi.rs::process_rx_completions` — OWN-set RX re-post.
- `src/netdev.rs::ndo_start_xmit` — FirstFrag publish that releases the
  TX chain to the chip.

Net change: +1 mechanical FFI wrapper plus +1 descriptor-ring unsafe
block. The descriptor writes target DMA-coherent memory, not MMIO, and
are covered by `ci/check_dma_barriers.sh`.

## 2026-05-31 — NUMA-aware IRQ auto-pin bump 51 → 52

Added `bridge_irq_pin_auto(pdev, irq)` safe wrapper in
`src/unsafe_boundary.rs`, calling new cshim
`r8125_bridge_irq_pin_auto` which picks the first online CPU on
`pdev`'s NUMA node and calls `irq_set_affinity_and_hint`. Sister
to `bridge_irq_pin_cpu` (CPU 0 hardcoded → now policy-selected).

Net change: +1 mechanical FFI wrapper. The new module param
`irq_pin_cpu: u8` (default 255 = auto) selects between
`bridge_irq_pin_auto` (255), no-op (254), and explicit
`bridge_irq_pin_cpu(N)` (0..253). See
`docs/RX_OPTIMIZATION_CANDIDATES.md`.

## 2026-05-31 — Temporary stall diagnostics bump 52 → 54

Added the temporary KVM-stall ethtool diagnostic surface:

- `bridge_jiffies()` safe wrapper in `src/unsafe_boundary.rs`, calling
  cshim `r8125_bridge_jiffies()` (`get_jiffies_64`) so Rust can stamp
  IRQ/NAPI/RX/TX/xmit events.
- `r8125_rust_diag_snapshot(out)` C ABI entry point in
  `src/unsafe_boundary.rs`, which copies the safe Rust
  `netdev::diag_snapshot()` into the cshim's stack-local ethtool mirror.

Net change: +1 mechanical FFI wrapper and +1 raw-pointer copy at the
audited C ABI boundary. No new unsafe is permitted in `src/netdev.rs`;
`ci/check_diag_instrumentation.sh` enforces that the temporary surface
stays in `unsafe_boundary.rs`, that the Rust/C snapshot layouts stay
paired, and that the hot-path diagnostic atomics are cache padded.

## 2026-06-01 — Temporary stall diagnostics removed 54 → 52

Removed the temporary KVM-stall ethtool diagnostic surface after review:

- `bridge_jiffies()` and the cshim `r8125_bridge_jiffies()` helper.
- `r8125_rust_diag_snapshot(out)`, the raw-pointer C ABI copy.
- DIAG-TEMP hot-path atomics, note hooks, and ethtool strings.

Net change: -1 mechanical FFI wrapper and -1 raw-pointer C ABI copy, so the
unsafe census returns to 52. The permanent ethtool counters remain, and
`ci/check_counter_infrastructure.sh` plus the runtime counter-invariant gate
cover that retained surface.

## 2026-06-05 — BQL retry wrappers bump 56 → 60

Added four safe wrappers in `src/unsafe_boundary.rs` for the BQL retry path:

- `skb_len(skb) -> usize` — wraps `r8125_bridge_skb_len` so
  `ndo_start_xmit` can snapshot the byte count before ring ownership moves.
- `dql_seed_min_limit(ndev)` — wraps `r8125_bridge_dql_seed_min_limit`, which
  seeds the single TX queue's BQL floor at open.
- `netdev_sent_queue(ndev, bytes, xmit_more) -> bool` — wraps the kernel
  `__netdev_sent_queue` helper at the TX commit point, coupling BQL sent-side
  accounting with the r8169-style doorbell decision for `xmit_more` batches.
- `netdev_completed_queue(ndev, pkts, bytes)` — wraps the kernel BQL
  completion helper once per NAPI TX reap batch.

All four are mechanical FFI wrappers around kernel netdev queue helpers. The
new `ci/check_bql_accounting.sh` gate enforces sent/completed pairing,
pre-commit byte capture, the common `bql_active` predicate, the coupled
`__netdev_sent_queue` doorbell decision, and the no-`netdev_reset_queue`
bootstrap rule.

## 2026-06-05 — netdev_xmit_more() batching wrapper bump 60 → 61

Added one safe wrapper in `src/unsafe_boundary.rs`:

- `netdev_xmit_more() -> bool` — wraps `r8125_bridge_netdev_xmit_more`, a
  mechanical FFI read of the net core's per-CPU xmit-burst hint. `ndo_start_xmit`
  uses it to defer the TX doorbell (`tx_poll`) while the qdisc has more queued
  packets, amortizing one MMIO write across a burst (r8169
  `rtl8169_start_xmit` pattern). On the default non-BQL MSI path it is a pure
  batching hint; when BQL is enabled the same hint is passed into
  `__netdev_sent_queue` so BQL accounting and doorbell forcing stay coupled.
  The doorbell is still rung whenever the queue is stopped/throttled so no
  descriptor is left unsignaled. A `TX_DOORBELLS` counter (ndo_stop log) tracks
  the doorbells/xmit ratio for validation.

## 2026-06-06 — TX offload prep consolidation decrement 61 → 59

Collapsed the xmit hot-path offload setup into one C shim call:

- Added `skb_tx_offload_prepare(skb) -> Result<(opts1, opts2, nr_frags)>`,
  wrapping `r8125_bridge_skb_tx_offload_prepare`.
- Removed Rust wrappers and extern declarations for `skb_tx_csum_opts`,
  `skb_nr_frags`, and `skb_tso_setup`.

Net change: +1 wrapper, -3 wrappers = **-2 unsafe blocks**. The lower-level
checksum and TSO helpers are now file-local C implementation details, and the
dead `r8125_bridge_skb_nr_frags` symbol was removed. This reduces per-packet
FFI crossings on the single-buffer TX path while preserving the rule that all
skb mutations happen before DMA mapping.

## 2026-06-06 — descriptor migration bump 59 → 69

This change introduced format-aware RX/TX descriptor publication and type-safe
V3/V4 parsing support:

- Added `AsBytes`/`FromBytes` implementations for `RxDescriptor` /
  `RxDescLegacy` / `RxDescV3` / `RxDescV4` in `src/unsafe_boundary.rs`.
- Added `desc_read_rx` / `desc_write_rx` helpers for typed RX descriptor arrays.
- Reworked `desc_publish_own` to be format-aware for ordered OWN handoff for
  both 16-byte and 32-byte RX descriptor layouts and keep TX publication on the
  same ordering contract.

Net effect: +10 unsafe `impl` / helpers in `unsafe_boundary.rs`. This is the
intended cost of the descriptor migration and is bounded to the audited boundary.

## 2026-06-07 — RSS key fill wrapper bump 69 → 70

Added one safe wrapper in `src/unsafe_boundary.rs`:

- `rss_key_fill(key: &mut [u8; RSS_KEY_SIZE])` — wraps `r8125_bridge_rss_key_fill`
  (→ `netdev_rss_key_fill`) to fill the single-queue RXHASH Toeplitz key from the
  boot-stable system key instead of a hardcoded constant. The `&mut [u8; N]`
  argument guarantees the pointer is valid for exactly the `N` bytes passed.

## 2026-06-07 — RX reader refactor bump 70 → 71

Replaced `desc_read_rx` (1 unsafe block) with two precomputed-offset readers in
`src/unsafe_boundary.rs` (net +1):

- `rx_read_opts1(ring, idx, &RxParse)` — single volatile read of the OWN/opts1
  word for the pre-`dma_rmb()` ownership check.
- `rx_read_completion(ring, idx, &RxParse)` — one volatile descriptor fetch
  using the precomputed `RxParse` offsets (no per-packet `match RxDescFormat`).

Both stride by `parse.stride` (= `RxDescFormat::descriptor_len()`, the single
source enforced by `ci/check_rx_desc_stride.sh`). This removes the per-packet
double-read + format match from the NAPI RX hot loop.

## 2026-06-08 — RSS indirection default wrapper bump 71 → 72

Added one safe wrapper in `src/unsafe_boundary.rs`:

- `rxfh_indir_default(index, n_rx_rings) -> u32` — wraps
  `r8125_bridge_rxfh_indir_default`, which forwards to the kernel
  `ethtool_rxfh_indir_default` helper. Rust uses it only while programming
  the RTL8125 RSS indirection table at open time, keeping the default bucket
  mapping aligned with Linux ethtool semantics instead of duplicating modulo
  logic in Rust.

This is a pure mechanical FFI wrapper: no pointers, ownership transfer, MMIO,
or skb lifetime are involved.

## ethtool RSS control plane (72 → 73)

Added one unsafe block in `src/unsafe_boundary.rs`:

- `rxfh_indir_valid(ptr, len, queue_count) -> bool` — views the kernel
  `ethtool_rxfh_param` indirection buffer (`*const u32` + length, allocated by
  the ethtool core to `get_rxfh_indir_size()` entries) as a read-only,
  call-scoped slice via `core::slice::from_raw_parts`, then delegates the
  decision to the host-unit-tested `crate::layout::rxfh_indir_all_valid`. The
  borrow never outlives the `set_rxfh` call and the buffer is read-only, so no
  ownership, MMIO, or skb lifetime is involved — only a bounded slice view of a
  kernel-owned array. This keeps the indirection-validity rule (entry < owned
  queue count) tested in safe Rust rather than duplicated in C.

## Multi-queue RSS activation (73 → 74)

Added one unsafe block in `src/unsafe_boundary.rs`:

- `set_active_rx_queues(ndev, n)` — wraps the cshim
  `r8125_bridge_set_active_rx_queues`, which clamps the count and calls
  `netif_set_real_num_rx_queues`. Pure mechanical FFI to a registered
  net_device from `ndo_open` (RTNL held); no pointers beyond `ndev`, no
  ownership transfer, MMIO, or skb lifetime.

## Multi-queue IRQ affinity spread (74 → 75)

Net +1 unsafe block in `src/unsafe_boundary.rs`: added two, removed one. The
spread *policy* is the host-unit-tested `crate::layout::irq_affinity_cpu`; these
wrappers only feed it kernel facts / apply its result:

- ADDED `bridge_num_online_cpus() -> u32` — wraps `num_online_cpus()`. No
  pointers, no preconditions; reports the fan-out width.
- ADDED `bridge_node_base_cpu(pdev) -> c_int` — wraps the cshim helper that
  returns the PCI device's NUMA-local first-online CPU (the fan-out base).
  `pdev` is a live `pci_dev` from probe (`pci::Device<Bound>`); the helper only
  reads the device's NUMA node + online-CPU mask. No ownership/MMIO/skb.
- REMOVED `bridge_irq_pin_auto` — the old single-CPU auto-pin, superseded by
  the spread (`node_base_cpu` + `irq_affinity_cpu` + the existing
  `bridge_irq_pin_cpu`), which fans the active vectors across distinct CPUs so
  each queue's DMA stays on one per-CPU IOVA cache (the `tx_dropped_error`
  multi-queue TX-collapse fix).

## 2026-06-15 — PHY errata config bump 78 → 82

Net +4 `unsafe { ... }` blocks in `src/unsafe_boundary.rs` for the PHY errata
register-access wrappers used by `rtl8125b_hw_phy_config` (host-tested table in
`src/phy_config.rs`):

- ADDED `phy_modify_paged`, `phy_write_paged`, `phy_write_mmd`,
  `phy_modify_mmd` — each wraps the matching cshim (`r8125_bridge_phy_*`), which
  forwards to the phylib paged/MMD accessor on `b->phydev` (phylib owns PHY
  paging). SAFETY: `ndev` is the registered net_device; the cshim no-ops on a
  null phydev; called single-threaded during open before the PHY state machine
  starts. No ownership/MMIO/skb crosses the boundary — only scalar PHY
  reg/mask/val. The errata sequence + values live in the host-tested Rust table,
  not in C.

## 2026-06-15 — PHY firmware version readback bump 82 → 83

Net +1 `unsafe { ... }` block in `src/unsafe_boundary.rs`:

- ADDED `set_fw_version(ndev, &[u8; 32])` — wraps `r8125_bridge_set_fw_version`,
  which `memcpy`s exactly 32 bytes of the parsed PHY-firmware version field into
  `b->fw_version` (NUL-terminated) for `ethtool -i`. SAFETY: `ndev` is the
  registered net_device; `ver` is a fixed 32-byte array; the cshim reads exactly
  32 bytes. No ownership/MMIO/skb. (The firmware request + decode + apply are all
  safe Rust: `kernel::firmware::Firmware` + the host-tested `phy_fw` interpreter +
  the `mmio`/`phy` typed accessors — no unsafe added there.)

## 2026-06-15 — XDP redirect flush bump 83 → 84

Net +1 `unsafe { ... }` block in `src/unsafe_boundary.rs`:

- ADDED `bridge_xdp_finalize(ndev, queue_id)` — wraps `r8125_bridge_xdp_finalize`,
  which does a single `xdp_do_flush()` at NAPI-poll end if any frame was
  XDP_REDIRECT'd. SAFETY: `ndev` is the registered net_device; `queue_id` is
  bounds-checked in the cshim; called from NAPI poll context. No ownership/MMIO/
  skb crosses the boundary. (The XDP verdict path itself — bpf_prog_run_xdp,
  xdp_buff, xdp_do_redirect, the xdp_rxq lifecycle, ndo_bpf — is all C in
  netdev_bridge_xdp.c; no Rust unsafe added there.)

## 2026-06-15 — XDP_TX frame return bump 84 → 85

Net +1 `unsafe { ... }` block in `src/unsafe_boundary.rs`:

- ADDED `xdp_return_frame(frame)` — wraps `r8125_bridge_xdp_return_frame`, which
  calls the kernel `xdp_return_frame()` to return an XDP_TX frame's page to its
  origin RX page_pool at TX completion (via the frame's captured mem model).
  SAFETY: `frame` is the exact `xdp_frame*` a prior `xdp_xmit_one` stored in the
  TX shadow and is returned exactly once (the reaper swaps the shadow pointer to
  NULL and resets the slot's `TxSlotKind` tag before the call). No MMIO/skb. (The
  XDP_TX producer — buff→frame convert, dma_map_single, txq lock, enqueue — is
  C in netdev_bridge_xdp.c calling the Rust `xdp_xmit_one` op, which uses only the
  already-wrapped `desc_publish_own` accessor; the new `xdp_tx_enqueue` /
  `rust_xdp_xmit_one` / `rust_xdp_tx_flush` add no unsafe.)

## 2026-06-16 — custom RSS key/table copy wrappers bump 85 → 89

Net +4 `unsafe { ... }` blocks in `src/unsafe_boundary.rs`, all the same shape as
the existing `rxfh_indir_valid`: view a kernel ethtool RSS buffer as a call-scoped
slice (`core::slice::from_raw_parts[_mut]`) to copy the active RSS key /
indirection table in or out of the Rust-owned `rss::RssPolicy`.

- ADDED `read_rss_key(*const u8, &mut [u8; 40])` / `write_rss_key(*mut u8, &[u8; 40])`
  — copy a `set_rxfh` / `get_rxfh` key buffer. SAFETY: the ethtool core allocated
  `get_rxfh_key_size()` (= 40) bytes before invoking the op; the borrow is
  call-scoped; no ownership/MMIO crosses.
- ADDED `read_rss_indir(*const u32, &mut [u8; 128])` (saturating-narrow each entry
  so an out-of-range value is rejected by the host-tested `RssPolicy::set_indir`,
  not silently wrapped) / `write_rss_indir(*mut u32, &[u8; 128])`. SAFETY: the
  ethtool core allocated `get_rxfh_indir_size()` (= 128) `u32` entries; borrows are
  call-scoped. All RSS *policy* decisions (validation, default-collapse, reclamp)
  are pure safe Rust in `src/rss.rs` (host-tested); these wrappers only move bytes
  across the ethtool boundary.

## 2026-06-16 — WoL suspend affinity-hint clear bump 89 → 90

Net +1 `unsafe { ... }` block in `src/unsafe_boundary.rs`:

- ADDED `bridge_irq_clear_hint(irq)` — wraps `r8125_bridge_irq_clear_hint`, which
  calls `irq_update_affinity_hint(irq, NULL)` to drop the multi-queue affinity
  hint before `free_irq` (free_irq WARNs — `WARN_ON_ONCE(desc->affinity_hint)` —
  if a hint is still attached; this fixes a pre-existing WARN on every ndo_stop
  that the kasan kernel surfaced, and is a prerequisite for the WoL suspend path).
  SAFETY: `irq` is a vector this driver requested; the call is a no-op when no
  hint was set. No ownership/MMIO/skb crosses the boundary. (The WoL keep-alive
  register programming is safe Rust in `src/netdev.rs`, using existing `mmio`
  accessors for Config1/2, PMCH, RCR, and the existing `set_wol` path — no new
  unsafe.)

## 2026-06-16 — AF_XDP zero-copy datapath bump 90 → 95

Net +5 `unsafe { ... }` blocks in `src/unsafe_boundary.rs`, all thin FFI wrappers
over the new `netdev_bridge_xsk.c` cshim. The xsk kernel-API knowledge
(`xsk_buff_*`, `xsk_tx_peek_desc`, `xsk_pool_dma_map`, need-wakeup) stays entirely
in the C bridge; the Rust producer/consumer ring discipline (the fill-cursor poll
in `src/napi.rs`, the `XskTx` TX slot kind) is safe Rust. The wrappers only move a
buffer pointer / DMA address / count across the boundary:

- ADDED `bridge_xsk_rx_consume(ndev, qid, cpu, len)` — run the XDP verdict on a
  received umem chunk (`cpu` = its `xdp_buff`) and dispose it. SAFETY: `cpu` came
  from a prior `rx_alloc` on the live pool; `len` ≤ the umem chunk size; NAPI ctx.
- ADDED `bridge_xsk_tx(ndev, qid, budget)` — drain up to `budget` umem chunks from
  the bound socket TX ring onto the shared TX ring. SAFETY: `budget` ≤ free TX
  slots (bounded by the caller) so the producer never overflows; NAPI ctx.
- ADDED `bridge_xsk_tx_completed(ndev, qid, count)` — complete `count` ZC TX chunks
  to the socket completion ring. SAFETY: `count` = XskTx slots reaped this pass.
- ADDED `bridge_xsk_set_rx_wakeup(ndev, qid, need)` — toggle RX need-wakeup when
  the umem fill ring is exhausted/replenished. SAFETY: reads only the bound pool.
- ADDED `bridge_rxq_is_zc(ndev, qid)` — read whether a ZC pool is bound to the
  queue (drives the RX branch). SAFETY: bounds-checks qid, reads one bridge field.

## 2026-06-18 — PCIe AER recovery teardown bump 95 → 96

Net +1 `unsafe { ... }` block in `src/unsafe_boundary.rs`, a thin FFI wrapper over
the new `r8125_bridge_pm_error_detach` cshim helper (`src/netdev_bridge.c`). Gated
on `r8125_pci_aer`. The recovery policy (channel-state decode, verdict mapping,
ABI values) is safe, host-tested Rust in `src/aer.rs`; the kernel callbacks in
`src/pci.rs` are safe delegations. The one new unsafe block only crosses the FFI
boundary to run the balanced teardown:

- ADDED `bridge_pm_error_detach(ndev, full_stop)` — AER `error_detected` quiesce:
  detach from the stack and, for Frozen/unknown channels, full balanced
  `ndo_stop`; permanent failure uses detach-only because the core may return
  Disconnect without a matching resume. SAFETY: `ndev` is the registered
  net_device (null-checked; the cshim no-ops on a down/detached device); called
  from the AER callback while the device is still bound. Mirrors the existing
  `bridge_pm_suspend` / `bridge_pm_resume` wrappers (same contract).

## 2026-06-18 — PCI runtime-PM bump 96 → 101

Net +5 `unsafe { ... }` blocks in `src/unsafe_boundary.rs`, all thin FFI wrappers
over the new runtime-PM cshim helpers (`src/netdev_bridge.c`). Gated on
`r8125_pci_runtime_pm`. Policy is safe Rust: the suspend/resume callbacks
(`src/pci.rs`) only run on a closed interface (runtime_idle vetoes while up), so
they never touch rings/RTNL. The wrappers only cross the FFI boundary:

- ADDED `bridge_runtime_idle(ndev)` — `netif_running` veto check (0 idle / EBUSY
  busy). SAFETY: reads one netdev flag; bound device.
- ADDED `bridge_runtime_suspend(ndev)` — `netif_device_detach` (closed device;
  PCI core does D3). SAFETY: bound device, RTNL-free, no ring work.
- ADDED `bridge_runtime_resume(ndev)` — `netif_device_attach` after D0 restore.
  SAFETY: as above; runs from the ndo_open get_sync bracket.
- ADDED `bridge_pm_runtime_enable(ndev)` — probe-end: set the bracket flag + drop
  the core's usage ref (gated on pci_dev_run_wake). SAFETY: called once after the
  netdev is registered.
- ADDED `bridge_pm_runtime_disable(ndev)` — unbind: re-take the ref. SAFETY:
  called at unbind start, device still bound + resumed by the core.

## 2026-06-18 — AER resume split (RTNL-free) bump 101 → 102

Net +1 `unsafe { ... }` block in `src/unsafe_boundary.rs`: `bridge_pm_error_resume`,
the FFI wrapper over the new RTNL-free `r8125_bridge_pm_error_resume` cshim. The
AER resume previously reused `bridge_pm_resume` (which takes RTNL); under
pci_bus_sem (where the AER core runs the callbacks) that inverts the lock order
the runtime-PM D-state path establishes (rtnl -> pci_bus_sem), an ABBA cycle
lockdep flagged once AER and runtime PM were built together. The dedicated
RTNL-free resume (and the now RTNL-free detach) break the cycle; it re-opens only
a device the teardown actually tore down (Frozen path), gated on b->aer_torn_down.

- ADDED `bridge_pm_error_resume(ndev)` — RTNL-free AER re-open. SAFETY: bound
  device (null-checked); runs from the AER resume callback under pci_bus_sem.
