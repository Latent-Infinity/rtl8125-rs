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
