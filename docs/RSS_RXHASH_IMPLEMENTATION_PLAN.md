# RSS / RXHASH Implementation Plan

**Status: planning only, 2026-06-06.** This plan is deliberately split into
two tracks:

- **RXHASH-only**: parse a hardware hash from an RSS-capable RX descriptor and
  call `skb_set_hash(...)` on the existing single RX queue. This can benefit
  software RPS/RFS without hardware multi-queue RSS.
- **Full hardware RSS**: add multiple RX queues, RSS indirection/key
  programming, ethtool control, and the RTL8125B V2/MSI-X interrupt topology.

Do not advertise `NETIF_F_RXHASH` or enable hardware RSS until the relevant
track's gates below are satisfied.

## Reference Constraints

The current Rust driver uses the legacy 16-byte RX descriptor shape
(`opts1`, `opts2`, `addr`). Realtek's hash result and packet-type metadata live
in RxDescV3/V4 fields (`RSSResult`, `HeaderInfo`, `RSSInfo`), not in that
legacy descriptor. The vendor hash reporting path is
`rtl8125_rx_hash_v3/v4` -> `skb_set_hash(...)`
(`references/realtek-r8125-official/src/r8125_rss.c:498-532`).

Mainline `r8169` does not implement an RTL8125 RSS/RXHASH code path; it keeps
one RX queue. Full hardware RSS is therefore beyond the upstream reference
driver. For an initial RFC, this is not a default-path requirement.

RTL8125B V2 interrupts are not remappable in the low-vector way a generic RSS
plan would assume. The V2 bit position maps to the MSI-X table entry:

- RX Q0 -> entry 0
- RX Q1 -> entry 1
- TX Q0 -> entry 16
- LINKCHG -> entry 21

The TX Q0 mapping is the root cause of the UDP-TX wedge documented in
`docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md`: enabling V2 with one vector
delivered RX but lost TX completions. The vendor requires
`R8125_MIN_MSIX_VEC_8125B = 22` (`r8125.h:690`) before using the V2 surface;
otherwise it falls back to the legacy combined ISR/IMR surface. See also
`docs/M6_MSIX_DESIGN.md` around the message-id discussion.

## Cost / Benefit

Current Gateway evidence says the single-queue Rust driver already reaches line
rate and often matches or beats the C reference. RSS is not needed to fix a
known throughput failure at 2.5G.

Potential benefits:

- RXHASH-only can let Linux RPS/RFS distribute RX processing in software if the
  NIC can produce a valid hash in a single-queue descriptor mode.
- Full RSS can spread high-pps RX interrupts and NAPI work across cores.

Costs:

- RXHASH-only still requires proving the validated RTL8125B populates
  `RSSResult` with one RX queue and the legacy interrupt surface.
- Full RSS requires queue-aware C bridge ownership, multi-ring Rust state,
  at least 22 MSI-X vectors on RTL8125B, RSS programming, ethtool control, and
  reset/recovery work.

Recommendation: pursue RXHASH-only only if Phase 0 proves `RSSResult` can be
populated safely on the validated chip without enabling full multi-queue RSS.
Defer full hardware RSS until after the RFC path unless a benchmark shows a
real user-visible gap.

## Phase 0 - Go / No-Go And Gap Ledger

Before any refactor, record the descriptor capability answer and prove the
remaining hash-engine question on hardware.

Descriptor go/no-go:

- The validated chip is `RTL8125B`, `MAC_VER_63`, XID `0x641`
  (`r8169_main.c:123`).
- In the vendor table, RTL8125B is `CFG_METHOD_4/5`
  (`r8125_n.c:112-113`).
- For `CFG_METHOD_4/5`, `HwSuppRxDescType = RX_DESC_RING_TYPE_3`
  (`r8125_n.c:15241-15244`). RTL8125B uses V3, not V4. V4 / TYPE_4 begins
  at RTL8125BP (`CFG_METHOD_8+`, `r8125_n.c:15245-15249`), so V4 enable bits
  and the 0xd8 `EnableRxDescV4_0` path are not applicable to this chip.
- `InitRxDescType` defaults to legacy and becomes V3 when `EnableRss ||
  EnablePtp` (`r8125_n.c:15256-15263`). The `EnablePtp` arm proves that the
  vendor exercises V3 descriptors on this exact chip without requiring
  multi-queue RSS or the V2/22-vector interrupt surface.
- RTL8125B's relevant descriptor enable is `EnableRxDescV3`
  (`r8125.h:1649`), applied through `rtl8125_rx_config`
  (`r8125_n.c:15274-15275`).

Make-or-break empirical gate:

- Prove whether `RSSResult` is populated with V3 descriptors, one RX queue,
  the legacy ISR/IMR surface, and minimal RSS hash-engine programming
  (`RSS_CTRL_8125` hash bits + RSS key, `Q_NUM_CTRL_8125` still one queue).
- If `RSSResult` remains zero or invalid unless full `EnableRss` / multi-queue
  RSS is active, Track A collapses into Track B.
- Answer this by a focused bench experiment before broad refactoring: enable
  V3, minimally program the hash engine, receive TCP/UDP flows, and dump both
  the descriptor `RSSResult/HeaderInfo` and the resulting `skb->hash`.

Gap ledger artifacts:

- `docs/perf/DRIVER_GAP_LEDGER.md`
- `scripts/gateway_hw_offload_validate.sh` extended for descriptor/RXHASH/RSS
  state and queue distribution

Capture for both C and Rust:

- `ethtool -k/-c/-g/-l/-x/-S`
- queue counts from sysfs
- `/proc/interrupts`
- VLAN/checksum/TSO/RXHASH/RSS state
- TCP/UDP TX/RX, 64B through jumbo, single-flow and multi-flow
- latency under load
- per-queue RX packet distribution when RSS exists

Acceptance:

- The descriptor-capability answer is recorded as RTL8125B = V3 / TYPE_3.
- The `RSSResult` population question has a documented yes/no bench answer.
- Every C-only advantage is fixed, explicitly out of scope, or documented with
  evidence.
- The harness proves RSS is disabled today and can later prove RXHASH/RSS state.

## Track A - RXHASH-Only

RXHASH-only does **not** require multiple RX queues. `NETIF_F_RXHASH` means the
driver reports a valid `skb->hash`; Linux can then use software RPS/RFS. It is
valid on a single RX queue if the descriptor hash is real and the stack gets the
right L3/L4 hash type.

### Phase A1 - RX Descriptor Format Migration

Refactor descriptor handling while preserving legacy behavior.

Implementation shape:

- Split TX descriptors from RX descriptors.
- Add `RxDescLegacy`, `RxDescV3`, and `RxDescV4`.
- Add `RxDescFormat::{Legacy, V3, V4}` selected once at open/probe for the
  running chip, never per packet.
- Track A uses V3 on the validated RTL8125B. V4 may be modeled for future
  RTL8125BP/D-family chips, but it is not part of the RTL8125B enablement
  path.
- Add a normalized completion:

```rust
struct RxHash {
    value: u32,
    kind: RxHashKind,
}

struct RxCompletion {
    len: usize,
    opts1: u32,
    opts2: u32,
    rss_hash: Option<RxHash>,
}
```

Descriptor migration ripple to handle:

- coherent ring allocation size and alignment
- descriptor tail canary layout
- `AsBytes`/`FromBytes` unsafe impls in `unsafe_boundary.rs`
- OWN/DDONE bit positions and `dma_rmb()` contract for V3
- descriptor publish order for repost
- descriptor length field extraction

Acceptance:

- Legacy descriptor behavior remains unchanged.
- V3 size and field-offset checks are gated for RTL8125B.
- V3 OWN/length/opts semantics are validated against vendor code before use.
- RXHASH remains unadvertised.

### Phase A2 - Hash Reporting

Extend RX delivery so the stack receives valid hashes.

Preferred shape:

- Rust parses the descriptor into `RxCompletion { rss_hash, ... }`.
- `rss_hash: Option<RxHash>` is lowered at the FFI boundary into explicit
  scalars so the C shim does not need to understand Rust enums.
- C shim applies the hash:

```c
r8125_bridge_rx_one_packet(..., hash_valid, hash_value, hash_type)
```

The C shim calls:

```c
skb_set_hash(skb, hash_value, PKT_HASH_TYPE_L3 or PKT_HASH_TYPE_L4);
```

Add counters:

- `rx_hash_l3`
- `rx_hash_l4`
- `rx_hash_missing`
- `rx_hash_disabled`

Acceptance:

- Hashable TCP/UDP traffic receives hashes.
- Non-hashable traffic does not receive fabricated hashes.
- `NETIF_F_RXHASH` is advertised only after this passes on Gateway.
- No per-packet dynamic dispatch or hot-path logging is added.

### Phase A3 - RXHASH Runtime Validation

Validate with one RX queue first:

- `ethtool -k` shows `receive-hashing: on`
- queue count remains one
- hash counters increment for TCP/UDP flows
- RPS/RFS can consume `skb->hash` if configured
- no throughput, loss, latency, or IRQ regression versus RXHASH off

If RXHASH-only needs RSS engine programming to generate hashes, that
programming must be limited to one queue and must not enable the V2 multi-queue
interrupt surface.

## Track B - Full Hardware RSS

Full RSS is a separate, larger effort. It should remain deferred unless Track A
is insufficient and benchmark data shows a real need.

### Phase B1 - Queue-Aware C Bridge

The C bridge must become queue-aware because `napi_struct` and `page_pool`
currently live on the C side.

Target structure:

```text
r8125_bridge
  queues[N]
    napi
    page_pool
    rx geometry
    queue_id
```

Vtable/API changes:

```c
poll(priv, queue_id, budget)
rx_pool_create(ndev, queue_id, ...)
rx_one_packet(ndev, queue_id, ...)
```

Planning notes:

- This will likely exceed the current `netdev_bridge.c` LOC cap. Budget a
  cshim split or cap update in the same series.
- The `netdev_bridge.h` contract, Rust vtable, and unsafe census updates must
  land atomically.

Acceptance:

- `N=1` behavior matches today's driver.
- MTU reopen, stop/open rollback, page-pool teardown, rmmod while up, and
  reset/recovery remain idempotent.
- Static gates cover queue-id propagation through C and Rust.

### Phase B2 - Multi-Ring RX State

Introduce `RxQueueState` in Rust:

- descriptor ring per RX queue
- tail per RX queue
- `slot_cpu[]` / `slot_dma[]` per queue
- `buf_len` per queue
- per-queue counters

Program ring bases:

- queue 0: existing `RDSAR`
- queue 1+: vendor `RDSAR_Q1_LOW_8125 + (queue - 1) * 8`
  (`r8125.h:1517`, `r8125_n.c:14670-14672`)

Acceptance:

- Multi-ring allocation/open/close works with RSS still disabled.
- FLR/reset/open failure paths unwind every queue.
- Fallback to one queue is clean.

### Phase B3 - RTL8125B MSI-X / Interrupt Model

There is no conservative 2-4 vector V2 RSS model on RTL8125B.

Required policy:

- Full RSS may use the V2 interrupt surface only if at least 22 MSI-X vectors
  are allocated.
- If fewer than 22 vectors are available, force one RX queue and keep the
  legacy combined ISR/IMR surface.
- Do not route TX completion or link change through vector 0 on V2:
  - TX Q0 is MSI-X entry 16.
  - LINKCHG is entry 21.
  - RX QN is entry N.
- TX remains single-queue for this plan. No XPS/TX multi-queue work is bundled.

Implementation requirements:

- call `pci_alloc_irq_vectors(..., min_vecs >= 22, ...)` so MSI-X entry 21
  exists before setting `INT_CFG0_ENABLE_8125`
- request IRQ handlers only for active entries: RX queues in use, TX Q0 entry
  16, and LINKCHG entry 21; unused entries such as 2-15 and 17-20 remain
  allocated but masked
- register handlers/NAPI for the RX queue entries actually used
- register handlers for TX Q0 entry 16 and link entry 21, or handle them via a
  reviewed shared owner if the kernel API requires it
- extend the existing `irq_pin_cpu` policy to per-vector affinity
- keep the current legacy MSI-X path as the default fallback

Acceptance:

- Pure UDP TX does not regress; TX completions arrive on entry 16.
- Every requested vector has exactly one owner.
- TX completions are reaped once.
- Link change is handled once.
- Fallback returns to today's single-vector legacy surface.

### Phase B4 - RSS Hardware Programming

Add RSS register helpers and state:

- `RSS_CTRL_8125` (`r8125.h:1518`, programming in `r8125_rss.c:121-150`)
- `RSS_KEY_8125` (`r8125.h:1520`)
- `RSS_INDIRECTION_TBL_8125_V2` (`r8125.h:1521`)
- `Q_NUM_CTRL_8125` (`r8125.h:1519`, `r8125_n.c:18094-18097`)
- V3 descriptor enable bit listed in Phase 0 for RTL8125B. V4 enable bits are
  future-chip material, not part of the validated RTL8125B path.

Initialize:

- RSS key via a C shim helper around `netdev_rss_key_fill`
- indirection table via `ethtool_rxfh_indir_default`
- default queue count as `min(default_rss_queues, hw_supported, usable_vectors)`

Acceptance:

- `RSS_CTRL_8125` and `Q_NUM_CTRL_8125` match queue count.
- Key and indirection table readback through ethtool matches driver state.
- RSS disabled path clears RSS control and preserves current single-queue
  performance.

### Phase B5 - Ethtool Control Plane

Add C shim ethtool ops and Rust backing state for:

- `get_rxfh_key_size`
- `get_rxfh_indir_size`
- `get_rxfh`
- `set_rxfh`
- `get_channels`
- `set_channels` later, after fixed queue-count RSS is stable

Acceptance:

- `ethtool -x` reports the same key/indir state programmed into hardware.
- Invalid indirection entries are rejected.
- `ethtool -X` changes are serialized against open/stop/reset paths.

## Static Gates

Add or evolve gates before enabling each feature:

RXHASH-only gates:

- descriptor capability for the running chip is documented
- descriptor layout size/offset checks for V3 on RTL8125B; V4 checks only
  when a future V4-capable chip path is added
- `skb_set_hash` path exists and is countered
- `NETIF_F_RXHASH` forbidden unless descriptor parser and hash reporting exist
- no per-packet dynamic dispatch in NAPI

Full RSS gates:

- RSS register programming forbidden unless descriptor format and queue count
  match
- `INT_CFG0_ENABLE_8125` forbidden unless at least 22 MSI-X vectors are owned
  on RTL8125B
- queue count must match `netif_set_real_num_rx_queues`
- RSS fallback must force one queue and hide hardware RSS controls
- per-queue IRQ/NAPI ownership is checked

The existing `check_hw_offload_features.sh` should evolve from "forbid
RXHASH" to "prove RXHASH prerequisites"; a separate RTL8125B RSS gate should
cover the 22-vector V2 rule.

## Runtime Validation

Extend the Gateway benchmark to compare Rust vs C across:

- TCP/UDP TX/RX
- 64B, 128B, 256B, 512B, 1500, 9000
- 1 flow, 2 flows, 10 flows, many flows
- VLAN on/off
- RXHASH off/on
- RSS off/on only if full RSS is implemented
- latency under load
- IRQ rate and per-vector interrupts
- CPU use
- queue distribution
- hash counters

Acceptance:

- no new packet loss or retransmit profile
- Rust throughput/PPS within 5% of C or better
- Rust latency parity-or-better
- RXHASH mode sets hashes for hashable traffic
- full RSS mode distributes multi-flow RX across queues
- `rx_hash_missing == 0` for hashable TCP/UDP flows
- no unexplained `ethtool -k/-x/-l` gap
- pure UDP TX remains at parity, proving the entry-16 TX completion path works

## Recommended Patch Order

1. Descriptor go/no-go doc and benchmark/gap-ledger extensions.
2. Descriptor type refactor, preserving legacy behavior.
3. V3 parser tests and static layout gates for RTL8125B.
4. RXHASH-only `skb_set_hash` path and counters, still feature-hidden.
5. RXHASH-only Gateway validation.
6. Advertise `NETIF_F_RXHASH` only if Track A passes.
7. Defer full RSS unless a measured gap justifies it.
8. If justified: queue-aware C bridge, still one queue.
9. Multi-ring Rust state, still RSS-disabled.
10. 22-vector MSI-X/V2 interrupt ownership.
11. RSS register programming behind a module parameter.
12. Ethtool RSS ops.
13. Advertise/enable full hardware RSS only after validation passes.

This order preserves the stable driver path and prevents repeating the
single-vector V2/TX-completion failure while still leaving a low-risk
RXHASH-only option open if the descriptor capability exists.
