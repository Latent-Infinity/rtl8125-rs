# Unsafe census justifications

Per plan §9.4, every census bump (rejected by `ci/run_checks.sh`) needs a
short rationale here. Append; never delete.

## 2026-05-25 — M4-traffic bump 43 → 46

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
side preserves the §6.2 discipline by keeping every `unsafe` block in
the one allowlisted file with a SAFETY comment.

No new MMIO-touching `unsafe` was added by this milestone; all MMIO for
the PHY OCP path goes through the existing `Regs::gphy_ocp_*` methods
which use the kernel `pci::Bar` accessors (safe).

## 2026-05-25 — M4-perf phase 1 bump 46 → 49

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
was added by this milestone.

## 2026-05-25 — M4-perf phase 2 (SG/TSO WIP) bump 49 → 53

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

## 2026-05-28 — M6 #2 jumbo RX-pool refactor bump 53 → 54

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

**Removed (3)** — the M4 coherent-allocation RX pool helpers:

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

## 2026-05-30 — RX Optimization Candidate A decrement 54 → 53

`bridge_account_rx(ndev, bytes)` removed from `src/unsafe_boundary.rs`.
RX packet/byte accounting now lives next to `napi_gro_receive` inside
`r8125_bridge_rx_one_packet`, so the RX hot path makes one fewer FFI
crossing per packet. See `docs/RX_OPTIMIZATION_CANDIDATES.md` §A for
the rationale.

TX accounting (`bridge_account_tx` / `r8125_bridge_account_tx`) is
unchanged: xmit calls it once per skb (not per packet), so the FFI
cost is bounded and the symbol stays as-is.

## 2026-05-30 — RX Optimization Candidate B decrement 53 → 47

`bridge_rx_one_packet` super-call (Candidate B of
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
  the §6.3 `rx_dropped_error` bump internally on alloc failure.
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

## 2026-05-30 — RX Optimization Candidates F + G (no census change)

Candidates F (hoist `state.ndev.load` out of NAPI RX loop) and G
(per-CPU `dev_sw_netstats_{rx,tx}_add` + `NETDEV_PCPU_STAT_TSTATS`)
shipped without changing the unsafe surface. Both are inside the
cshim or inside existing safe Rust code; no new wrappers, no extern
decl changes. Census remains 47.

The `rx_packets`/`rx_bytes`/`tx_packets`/`tx_bytes` counters now
live in per-CPU storage allocated by the kernel core when
`pcpu_stat_type` is set at bridge_alloc; the kernel sums across
CPUs on stats-read via `dev_get_tstats64`. The application-visible
`ip -s link show enp5s0` output is unchanged in semantics.

Candidate H was skipped (LLVM bounds-check elision is sufficient;
`unsafe` surface trade-off not worth marginal gain). See
`docs/RX_OPTIMIZATION_CANDIDATES.md`.

## 2026-05-30 — RX Optimization Candidate L bump 47 → 48

Added `bridge_irq_pin_cpu(irq, cpu)` safe wrapper in
`src/unsafe_boundary.rs`. Calls the new cshim
`r8125_bridge_irq_pin_cpu` which calls `irq_set_affinity_and_hint`
to nudge the kernel + irqbalance toward keeping the chip's MSI-X
vector on a specific CPU. Latency-aligned default for the
heterogeneous-LB use case (see docs/RX_OPTIMIZATION_CANDIDATES.md
§L).

Net change: +1 unsafe wrapper (mechanical FFI call). No MMIO
touching unsafe added.

Candidate M (`tx_queue_len` 1000 → 256) is cshim-side only and
introduces no Rust unsafe.

## 2026-05-30 — RX descriptor dma_rmb bump 48 → 49

Added `dma_rmb()` safe wrapper in `src/unsafe_boundary.rs`. Calls the
new cshim `r8125_bridge_dma_rmb`, which invokes Linux `dma_rmb()` after
the RX descriptor OWN bit clears and before Rust reads descriptor
length/checksum fields or DMA-written bytes.

This mirrors r8169's `rtl_rx` ordering and closes the weak-memory
correctness gap documented as Candidate C in
`docs/RX_OPTIMIZATION_CANDIDATES.md`. The helper has no pointer or
ownership preconditions; the safety contract is ordering-only and is
enforced by `ci/check_rx_skb_build.sh`.

## 2026-05-31 — RX Opt #1 bump 49 → 51

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

## 2026-05-31 — RX Opt #4 bump 51 → 52

Added `bridge_irq_pin_auto(pdev, irq)` safe wrapper in
`src/unsafe_boundary.rs`, calling new cshim
`r8125_bridge_irq_pin_auto` which picks the first online CPU on
`pdev`'s NUMA node and calls `irq_set_affinity_and_hint`. Sister
to `bridge_irq_pin_cpu` (CPU 0 hardcoded → now policy-selected).

Net change: +1 mechanical FFI wrapper. The new module param
`irq_pin_cpu: u8` (default 255 = auto) selects between
`bridge_irq_pin_auto` (255), no-op (254), and explicit
`bridge_irq_pin_cpu(N)` (0..253). See Candidate #4 of
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
unsafe census returns to 52. The permanent §6.3 ethtool counters remain, and
`ci/check_counter_infrastructure.sh` plus the runtime counter-invariant gate
cover that retained surface.
