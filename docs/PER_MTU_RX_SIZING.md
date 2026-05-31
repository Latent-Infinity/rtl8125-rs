# Per-MTU RX buffer sizing (RX Opt #3)

Status: **design only**. Task #92. Implementation deferred until
the Gateway re-measurement (#80) confirms the magnitude of the
expected gain and after the current 24 h KVM + Gateway soaks complete.

## Current state

```rust
// src/netdev.rs
pub(crate) const RX_BUF_LEN: usize = crate::regs::JUMBO_16K_BYTES; // 16384
```

```c
// src/netdev_bridge_rx_pool.c
#define R8125_RX_JUMBO_BUF_SIZE  16384
#define R8125_RX_PAGE_ORDER      2          // order-2 = 4 contiguous 4K pages
```

Every RX slot is an `order-2` page block (16 KiB) regardless of MTU.
With 256 slots, the ring footprint is a flat **4 MiB** per netdev.

This is the same shape r8169 uses pre-`rtl_set_rx_max_size`. r8169
sizes per-MTU at open and at every `ndo_change_mtu`. We don't.

## Why we'd want to size per MTU

At MTU 1500 each frame occupies ~1.6 KiB of the 16 KiB slot. The
remaining 14.4 KiB:

1. **Wastes memory.** 14.4 KiB × 256 slots = 3.6 MiB unused per
   netdev. Trivial on a workstation, real on small-RAM appliances.
2. **Wastes L1/L2 cache.** `dma_sync_single_for_cpu(slot, full_size,
   DMA_FROM_DEVICE)` invalidates 16 KiB worth of cache lines per
   packet even though only 1.6 KiB will be read. That's a 10×
   amplification on the cache-touch budget.
3. **Wastes IOMMU bookkeeping.** Each `dma_map_page` of 16 KiB
   walks page-table entries proportional to size. Smaller maps =
   smaller TLB pressure for SMMU/AMD-Vi.
4. **Wastes streaming-DMA invalidation bandwidth.** Some platforms
   (ARM with non-coherent DMA) actually walk the cache range to
   invalidate. A 10× region growth is a 10× cost growth there.

For our heterogeneous-LB use case (MTU 1500 dominant, MTU 9000
when configured), the savings would compound at TX-to-RX-poll
turnaround time.

## Expected gain (qualitative)

We won't know the magnitude until the Gateway data lands. Hypothesis:

| Scenario | Cache-touch reduction | Memory savings |
|---|---|---|
| MTU 1500, 256 slots | ~10× | 3 MiB / netdev |
| MTU 4500, 256 slots | ~3× | 2 MiB / netdev |
| MTU 9000, 256 slots | ~2× | 1.5 MiB / netdev |

Latency impact: likely small at line-rate-bound throughput, but
**should reduce tail latency** when the system is cache-cold (rare
RX bursts that miss in L2) — exactly the scenario where the chip's
peak responsiveness matters most for a router/LB.

## Proposed implementation

### Three-bin allocation

Use one of three page orders depending on chosen buffer size, not
a continuous spectrum:

| Bin | Page order | Slot size | Covers MTU up to |
|---|---|---|---|
| **small** | 0 (4 KiB) | 4096 B | 3 KiB (MTU 1500 + VLAN + headroom = ~1620 B, fits) |
| **mid** | 1 (8 KiB) | 8192 B | 7 KiB (MTU 7000) |
| **jumbo** | 2 (16 KiB) | 16384 B | 16 KiB (current, MTU 9000 + room) |

Three bins (not a per-MTU continuous spec) keeps the allocator
predictable, avoids fragmentation drift, and matches how kernel
page-allocator perf scales.

Mapping `dev->mtu` → bin:

```c
static enum r8125_rx_bin rx_bin_for_mtu(unsigned int mtu)
{
    if (mtu <= 1500)
        return R8125_RX_BIN_SMALL;
    if (mtu <= 7000)
        return R8125_RX_BIN_MID;
    return R8125_RX_BIN_JUMBO;
}
```

### Field surface

Add `rx_buf_size: usize` and `rx_page_order: u32` to `RxRingState`
(or thread through `NetdevState`). The cshim `bridge_rx_alloc`
helper takes the size as a parameter instead of hard-coding 16384.

cshim helper signature change:

```c
/* was */
int r8125_bridge_rx_alloc_jumbo(struct device *dev, void **out_cpu,
                                 dma_addr_t *out_dma);
/* becomes */
int r8125_bridge_rx_alloc(struct device *dev, unsigned int order,
                          void **out_cpu, dma_addr_t *out_dma);
void r8125_bridge_rx_free(struct device *dev, unsigned int order,
                          void *cpu, dma_addr_t dma);
```

The `_jumbo` aliases stay as thin wrappers (`order = R8125_RX_PAGE_ORDER_JUMBO`)
so existing call sites that haven't been converted yet continue to
work. After all sites migrate, the aliases get removed in a follow-up.

### Chip register impact

The chip's `RxMaxSize` register must be programmed to a value the
slot can hold without overrun. Current value is `JUMBO_16K_BYTES`.
At each `ndo_change_mtu` we'd need to:

1. Stop the chip (or at least the RX engine).
2. Drain pending RX completions.
3. Free old RX ring buffers.
4. Re-allocate with the new bin.
5. Re-program `RxMaxSize`.
6. Restart the chip.

This is heavy. Two alternatives to consider:

* **Option A - runtime resize on `ndo_change_mtu`.** Authentic
  per-MTU sizing. Cost: chip down for ~100 ms during resize.
  Userspace observes a brief link blip.
* **Option B - sized once at `ndo_open`, fixed for lifetime of
  netdev_up.** `ndo_change_mtu` is rejected if it would cross a bin
  boundary unless the chip is taken down (ip link set down + up).
  Cost: extra cognitive load for the operator; pro: TX/RX paths
  never observe a mid-flight resize race.

**Recommendation: Option B.** MTU changes are operationally rare; the
operator can `ip link set down/up` if they need to cross a bin. This
removes a whole class of "race during resize" failure modes from the
hot path.

If the operator does `ip link set mtu 9000` while UP and that would
cross from `R8125_RX_BIN_SMALL` to `R8125_RX_BIN_JUMBO`, we return
`-EINVAL` from `ndo_change_mtu` with a clear dmesg hint. Mirrors r8169's
behaviour for jumbo MTU on chips that don't support it without reset.

### Knob shape

```rust
/// Per-MTU RX buffer sizing policy.
/// 255 = auto (track MTU, three-bin allocator)
/// 254 = jumbo-always (current behaviour, no change)
/// 4|8|16 = force that bin in KiB (debug/override)
/// other = reserved
rx_buf_kb: u8 default 255
```

Conventions follow `irq_pin_cpu`: 255 = auto, 254 = explicit
opt-out-of-feature (keep old shape), small explicit values for
operator override.

CI gate `ci/check_rx_buf_sizing.sh` enforces:

* Module param exists with the documented values
* `rx_bin_for_mtu` matches the MTU→bin table above
* `R8125_RX_BIN_JUMBO` slot size equals `JUMBO_16K_BYTES` (no drift
  from `regs::JUMBO_16K_BYTES`)
* `ndo_change_mtu` rejects bin-crossing MTU changes when UP

## Risks and pitfalls

1. **Drain race during resize (Option A).** If we ever revisit runtime resize,
   ensure RX NAPI is disabled + flushed before tearing down the
   ring. `napi_disable()` + `synchronize_rcu()` covers it. Same
   pattern as `ndo_stop`. Currently moot: the recommendation is Option B.
2. **Allocator pressure under memory fragmentation.** Order-2
   allocations can fail under memory pressure even when order-0
   succeeds. Smaller bins = better resilience. The jumbo case stays
   sensitive; document that low-memory hosts may need
   `vm.compact_memory` runs before insmod under MTU 9000.
3. **DMA mapping cost shift.** Smaller `dma_map_page` calls = more
   DMA-API calls per second (one per RX, same as today, but each is
   cheaper). Net cost should drop, not rise. Verify with `perf stat`
   post-implementation.
4. **Slot count vs bin size.** We don't change slot count; ring length
   stays at 256. Net RX queue capacity in bytes drops at MTU 1500:
   4 MiB → 1 MiB. Still 670+ MTU-1500 frames buffered. Plenty.
5. **`dev_sw_netstats_rx_add` and `napi_alloc_skb` are unaffected.**
   They take the actual `len`, not the slot capacity.

## Implementation order

1. Land the cshim signature change (`_jumbo` aliases preserved).
2. Wire `rx_buf_size` through `RxRingState`.
3. Implement `rx_bin_for_mtu` and the open-time selection.
4. Add the module param and `ndo_change_mtu` bin-crossing rejection.
5. Write `ci/check_rx_buf_sizing.sh`.
6. Smoke + soak on KVM and Gateway.
7. (Follow-up) Drop the `_jumbo` aliases once all call sites use
   the parametrised form.

## Census + LOC

* `_jumbo` aliases preserved -> no net change in safe wrappers over
  unsafe FFI calls until follow-up.
* `bridge_rx_alloc(order)` + `bridge_rx_free(order)` add 2 safe Rust
  wrappers over unsafe FFI calls (replacing the `_jumbo` pair);
  aliases keep the old functions alive during transition. Census +2
  temporarily, -2 in follow-up = net zero.
* cshim `netdev_bridge_rx_pool.c` is currently 173 LOC with a 200 LOC cap.
  The bin enum + new helpers may push it over 200; split helpers or bump
  the documented cap only with the implementation diff.

## Open questions for review

1. Should the small bin be `order-0` (4 KiB) or `order-1` (8 KiB)?
   r8169 uses 2 KiB-aligned via `napi_build_skb` directly — but our
   pool model needs full page chunks. Going with order-0 for the
   small bin; revisit if `napi_alloc_skb` ever fails for small bin
   from short-burst alloc pressure.
2. Should `ndo_change_mtu` resize between bins via Option A as an
   operator-opt-in (`allow_mtu_resize_up: u8` module param)? Adds
   complexity for a corner case. Defer.
3. What's the right default RX ring length now that slots are smaller?
   Today's 256 was chosen for the jumbo case; with smaller bins we
   could grow to 512 cheaply (still 2 MiB at MTU 1500 small bin).
   Defer to a separate task; per-MTU sizing is orthogonal.

## Cross-references

* [`RX_OPTIMIZATION_CANDIDATES.md`](RX_OPTIMIZATION_CANDIDATES.md)
  Candidate D ("napi_gro_frags") — page-pool / split-buffer
  alternative to per-MTU sizing. The two are not mutually
  exclusive but should be sequenced (this first, then evaluate D).
* r8169's `rtl_set_rx_max_size`
  (`drivers/net/ethernet/realtek/r8169_main.c`) — upstream's
  per-MTU sizing.
* docs/PATTERNS.md — "RX buffer right-sizing" pattern entry should
  be added once this lands.
