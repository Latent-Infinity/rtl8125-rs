# M6 sub-feature #3 — Jumbo frames (MTU 9000+)

**Status (2026-05-26): design only**. Implementation begins after the
M5 ASPM soak chain completes (~2026-05-28).

The chip's hardware supports jumbo up to **16380 bytes** (`JUMBO_16K`
in r8169 mainline for `MAC_VER_61..LAST`). The plan §7 M6 target is
"MTU 9000" but the chip can go further; we'll advertise up to JUMBO_9K
initially with a clear path to JUMBO_16K once validated.

The dominant cost of this M6 sub-feature is the **RX-pool refactor**:
our current `CoherentAllocation<RxBuffer>` design with `RX_BUF_LEN =
2048` doesn't scale to 16K per buffer × 256 slots = 4 MiB contiguous
DMA, which kernel allocators won't reliably provide. We need to switch
to per-slot streaming DMA mappings.

## What we have today

```rust
// src/netdev.rs
pub(crate) const RX_BUF_LEN: usize = 2048;

#[repr(C, align(64))]
pub(crate) struct RxBuffer { pub(crate) data: [u8; RX_BUF_LEN], }

// Allocated as ONE CoherentAllocation<RxBuffer> with N=256:
//   rx_bufs.dma_handle() + i * RX_BUF_LEN  is slot i's DMA address
// Total: 256 * 2048 = 512 KiB contiguous DMA — works fine.
```

`ndev->max_mtu = ETH_DATA_LEN` (1500). `RxMaxSize` register set to
the equivalent — see `src/mmio.rs::set_rx_max_size`.

## What we need for jumbo

### Chip register changes (small)

`RxMaxSize` at MMIO 0xDA (`r8169_main.c:298`) is the chip's max RX
packet length. Today we set it to ~2048; for jumbo we set it to
`R8169_RX_BUF_SIZE + 1 = 16384` (r8169 always uses 16K regardless of
MTU — it sizes the chip's RX FIFO drop threshold above any plausible
frame).

This is a 2-line change in `src/regs.rs` + `src/hw.rs`. **Not the hard
part.**

### RX pool changes (significant)

We have three options. Recommended is **C**.

#### A. Larger CoherentAllocation

Bump `RX_BUF_LEN` to 16384. Total pool = 256 × 16384 = 4 MiB.

```rust
// Hypothetical — DON'T DO THIS:
pub(crate) const RX_BUF_LEN: usize = 16384;
// rx_bufs: CoherentAllocation<RxBuffer>  // 4 MiB contiguous DMA
```

**Problem**: 4 MiB contiguous DMA-coherent is a 11th-order allocation
(`get_order(4 MiB) = 10`). On a long-running system with fragmented
memory this will fail. r8169 explicitly avoids it.

#### B. Per-slot CoherentAllocation

Allocate 256 separate `CoherentAllocation<[u8; 16384]>` objects.

```rust
pub(crate) struct NetdevState {
    rx_bufs: [CoherentAllocation<RxJumboBuffer>; 256],
    ...
}
```

**Problem**: 256 separate coherent allocations each 16K wastes kernel
overhead per slot (each one comes with a `struct page` chunk + DMA
metadata). Memory waste from rounding 16K to 16K page is zero, but
the kernel mappings are 256× the dma-coherent map calls.

#### C. Streaming DMA with per-slot pages (recommended — matches r8169)

Use `alloc_pages` for each slot (page-order such that the page
spans 16K = 4 pages on x86 = order 2), then `dma_map_page` to get a
DMA handle. The "buffer" is just a `*mut u8` + `dma_addr_t` pair.

```rust
pub(crate) struct RxSlot {
    page: *mut bindings::page,  // 4-page chunk holding 16K
    dma:  bindings::dma_addr_t, // streaming DMA mapping
    cpu:  *mut u8,              // page_address(page)
}

pub(crate) struct NetdevState {
    rx_slots: [RxSlot; 256],
    ...
}
```

**Advantages**:
- No contiguous DMA above PAGE_SIZE — works on fragmented systems
- Matches r8169 mainline (`alloc_pages_node(..., get_order(R8169_RX_BUF_SIZE))`)
- Allocation/free per slot is cheap with the page allocator
- Future RX-perf work (XDP, page_pool, recycling) builds naturally on
  this primitive

**Disadvantages**:
- More cshim work: `alloc_pages` / `__free_pages` / `dma_map_page` /
  `dma_unmap_page` / `page_address` calls go through unsafe FFI
- Cleanup must walk all 256 slots on `ndo_close` to unmap + free
- Per-slot Drop/lifecycle harder to express in safe Rust — these
  are raw pointers held across the NAPI poll boundary

**Why C wins for jumbo**: scalability. We can later swap the
`alloc_pages` call for a page_pool API call (kernel ≥5.9) which
adds recycling — that's M6+1 / RX-perf work but the same primitives.

### MTU handling (medium)

```c
// src/netdev_bridge.c — change max_mtu
ndev->min_mtu = ETH_MIN_MTU;       // 68; unchanged
ndev->max_mtu = JUMBO_9K_BYTES;    // 9000 (or chip max 16380)
```

`ndo_change_mtu` already exists; the bridge passes through to our
Rust `ndo_change_mtu` which currently does nothing because the chip
doesn't need re-init for MTU changes within the RX buffer size.

With jumbo, MTU changes within the RX buffer size are still cheap
(no realloc needed since RX buffers are sized to MAX); just update
`ndev->mtu`.

### Performance gates (per-feature M6 spec)

Per plan §7 M6:
- `ethtool -K` disables jumbo at runtime → we already accept lower
  MTU via `ndo_change_mtu`; the implicit "disable" is just setting
  MTU back to 1500. Document this as the rollback path.
- Packet capture verifies on-wire correctness → operator runs
  `iperf3 -M 9000` from peer and tcpdumps; jumbo frames visible.
- Per-revision rollback → `max_mtu = ETH_DATA_LEN` for any new
  chip rev that doesn't support jumbo. Add a `ChipInfo.max_mtu`
  field; default to 1500.
- `docs/perf/` numbers → measure CPU per Gbps at MTU 1500 vs
  MTU 9000. Expect ~30% reduction in CPU at line rate (fewer
  packets per byte).

## Proposed implementation phases

**Phase A — register + MTU advertisement only (no RX refactor)**

Set `RxMaxSize` to 16384 + advertise `max_mtu = ETH_DATA_LEN` still
1500. RX_BUF_LEN stays 2048. Reason: this is a smoke test that the
RxMaxSize register write doesn't break anything. No actual jumbo
frames sent (max_mtu still 1500).

Drop-in. ~10 LOC of Rust.

**Phase B — RX pool refactor to streaming DMA (the big lift)**

1. Add cshim wrappers for `alloc_pages_node`, `__free_pages`,
   `dma_map_page`, `dma_unmap_page`, `page_address`.
2. Replace `CoherentAllocation<RxBuffer>` in `NetdevState` with
   `[RxSlot; 256]` (heap-allocated since 256 of these is big).
3. Per-slot alloc in `ndo_open`; per-slot free in `ndo_stop`.
4. NAPI poll: use the slot's `cpu` ptr to build the skb (same as
   before but the buffer is jumbo-sized now).
5. `RX_BUF_LEN` becomes `JUMBO_16K_BYTES = 16380`.

This is ~200 LOC Rust + ~50 LOC cshim.

**Phase C — MTU advertisement**

Bump `ndev->max_mtu = JUMBO_9K_BYTES` (or JUMBO_16K_BYTES once
validated). `ndo_change_mtu` is a no-op for MTU in [68, max_mtu].

3 LOC change.

**Phase D — CI**

| Check | What |
|---|---|
| Static: `check_rx_pool_pages.sh` | confirms `alloc_pages` is paired with `__free_pages` everywhere |
| Static: `check_dma_map_unmap.sh` | confirms `dma_map_page` is paired with `dma_unmap_page` |
| Runtime: `check_jumbo_iperf.sh` | runs iperf3 at MTU 9000, asserts throughput >= 90% of MTU 1500 throughput, asserts §6.3 invariant still holds |
| Runtime: `check_jumbo_mtu_change.sh` | toggles MTU 1500 ↔ 9000 ↔ 1500, asserts each switch works + no kernel warnings |

## Risks + mitigations

- **Risk**: `dma_map_page` returns a streaming DMA address that must
  be `dma_unmap_page`'d before the buffer is freed. Missing this
  trips DMA_API_DEBUG on every RX. **Mitigation**: shadow the
  mappings in `NetdevState` (already pattern from TX); CI gate
  enforces the pairing.
- **Risk**: page_pool integration tempting but adds complexity. Defer
  to M6+1 / RX-perf work; M6 jumbo uses raw `alloc_pages` per slot.
- **Risk**: jumbo + TSO interaction. Our chip-specific
  `tso_max_segs = 10` cap (see docs/RTL8125B_TSO_NOTES.md) means
  at MTU 9000 the max TSO super-skb covers ~90 KB of payload before
  segmenting, well within `tso_max_size = 64000`. Should be fine but
  verify with iperf3 at MTU 9000 + TSO on.
- **Risk**: `max_mtu = 16380` exceeds typical L2 device support; some
  switches drop frames > 9000. **Mitigation**: advertise JUMBO_9K
  initially; raise to JUMBO_16K only after operator validates the
  cable + peer support.

## Estimated effort

| Phase | Code LOC | CI LOC | Wall-clock |
|---|---|---|---|
| A — RxMaxSize bump (no MTU change) | ~10 | ~5 | 1 session |
| B — RX pool refactor (streaming DMA) | ~200 R + ~50 C | ~50 | 2-3 sessions |
| C — max_mtu advertisement | ~5 | ~10 | 1 session |
| D — perf numbers + ethtool toggle test | ~30 | ~30 | 1 session |

Total: ~3-5 sessions of hot iteration.

## What this design does NOT cover

- **page_pool** — defer to M6+1 (RX-perf milestone).
- **XDP** — defer to M7+ (out-of-tree decision milestone).
- **MTU > 9000 on the wire** — chip supports JUMBO_16K but Ethernet
  peers commonly cap at 9000; raise the cap later if needed.
