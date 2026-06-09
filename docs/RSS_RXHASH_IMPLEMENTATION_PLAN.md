# RSS / RXHASH Implementation Plan

**Status: Track A (RXHASH-only) CLOSED + gateway-validated, 2026-06-07.
Track B (full hardware RSS) STARTED for Realtek vendor-driver parity.** This plan is deliberately
split into two tracks:

- **RXHASH-only**: parse a hardware hash from an RSS-capable RX descriptor and
  call `skb_set_hash(...)` on the existing single RX queue. This can benefit
  software RPS/RFS without hardware multi-queue RSS.
- **Full hardware RSS**: add multiple RX queues, RSS indirection/key
  programming, ethtool control, and the RTL8125B V2/MSI-X interrupt topology.

Do not advertise `NETIF_F_RXHASH` or enable hardware RSS until the relevant
track's gates below are satisfied.

Current checkpoint:

- `docs/perf/DRIVER_GAP_LEDGER.md` is the implementation ledger.
- Track A is implemented, advertised, validated, and closed for the RFC path.
- Track B is now the feature-parity target because the Realtek vendor `r8125`
  driver implements full RSS; use that vendor driver, not mainline `r8169`, for
  future RSS feature and performance comparisons.

Phase 0 status:

- **Status: COMPLETE — verdict D1 (YES), 2026-06-07 gateway run.**
  - Run in production path: probe selects V3 RX descriptors, `ndo_open` programs
    the hash-only RSS engine (`RSS_CTRL=0x183F` bits + fixed key, `Q_NUM_CTRL=0`),
    and single-queue legacy ISR (`use_v2=false`, one MSI vector). No
    `NETIF_F_RXHASH` advertisement yet.
  - **Result: `RSSResult` IS populated single-queue / legacy-ISR / no-V2.** Raw
    dump showed non-zero Toeplitz hashes varying by 4-tuple (0xc6d42420,
    0xba9a6d2d, 0xa81be34a, …); `HeaderInfo` decoded deterministically to L4 for
    TCP/UDP and "no-hash" for non-IP; `rx_hash_l4=72064`, **`rx_hash_missing=0`**.
  - V3 RX/TX ran at line rate (2.35/2.35 Gbps), UDP 0% loss, 0 dmesg warnings —
    so the A1 stride fix holds for the 32B path and there's no V3-mode regression.
  - **Decision: D1 satisfied → Track A (RXHASH-only) is GO.** The hash engine does
    NOT require multi-queue RSS or the 22-vector V2 surface, so the cheap path is
    real. The path is now in the reviewed `ndo_open`/`set_features` path
    (single-queue legacy ISR), with throwaway probe scaffolding retired.

Decision register:

- **D1**: Confirmed — V3 hashability is proven at one queue without multi-queue V2
  interrupts.
- **D2**: If V3 hashes require full V2-style RSS/queue enablement, promote
  Track B as the implementation path and defer Track A advertising.
- **D3**: Keep RSS off and report one queue until `B` phases materially improve a
  measured Gateway user-visible gap.

## Reference Constraints

The current Rust driver uses `RxDescFormat::V3` on the validated RTL8125B
single-queue path. In V3, `opts1`/`opts2`/`addr` are positioned for the
32-byte layout, and hash packets arrive in `RSSResult` + `HeaderInfo` fields.
The vendor hash reporting path is
`rtl8125_rx_hash_v3/v4` -> `skb_set_hash(...)`
(`references/realtek-r8125-official/src/r8125_rss.c:498-532`).

For the validated chip:

- `MAC_VER_63` / `XID 0x641` is the target (`r8169_main.c:123`), and it maps to
  V3 descriptor capability (`CFG_METHOD_4/5`; `r8125_n.c:7606-7610` shows XID
  0x641 resolves to both METHOD_4 and METHOD_5, both TYPE_3 capable).
- V4 enable paths are not applicable; the validated chip does not require or use
  `EnableRxDescV4_*`.

Mainline `r8169` does not implement an RTL8125 RSS/RXHASH code path; it keeps
one RX queue. The Realtek vendor `r8125` driver does implement full RSS, so
Track B uses the vendor driver as the reference for feature behavior, register
programming, ethtool state, and performance.

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
  EnablePtp` (`r8125_n.c:15256-15263`). This confirms V3-format selection is
  possible on this chip, but does **not** prove RSS hash fields are populated:
  `EnablePtp` is a timestamp write-back mode, not the RSS-normal path.
- RTL8125B's relevant descriptor enable is `EnableRxDescV3`
  (`r8125.h:1649`), applied through `rtl8125_rx_config`
  (`r8125_n.c:15274-15275`).
- V3 descriptors are 32 bytes (`RX_DESC_LEN_TYPE_3`), so RTL8125B RX ring allocation,
  tail canary layout, and index stepping are all 2× the legacy descriptor
  shape.

Make-or-break empirical gate:

- Prove whether `RSSResult` is populated with V3 descriptors, one RX queue,
  the legacy ISR/IMR surface, and minimal RSS hash-engine programming
  (`RSS_CTRL_8125` hash bits + RSS key, `Q_NUM_CTRL_8125` still one queue).
- If `RSSResult` remains zero or invalid unless full `EnableRss` / multi-queue
  RSS is active, Track A collapses into Track B.
- Answer this by a focused bench experiment before broad refactoring: enable RSS-normal
  V3 descriptors only, minimally program the hash engine, receive TCP/UDP flows,
  and inspect descriptor `RSSResult/HeaderInfo` values and `ethtool -S` counters.

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

Execution status:

- **A1**: complete + validated — RX format migration and completion normalization
  are in place. A 2026-06-06 gateway audit found and fixed a descriptor-stride
  regression (single 32-byte `RxDescriptor` path still being read with legacy
  assumptions). The fix routes descriptor access through `format.descriptor_len()`;
  `ci/check_rx_desc_stride.sh` now enforces it. Revalidated on the gateway (line
  rate TCP/UDP RX, 0% loss, 1.15M packets, 0 dmesg warnings).
- **A2**: complete — completion `rss_hash` is parsed and marshaled over the C RX bridge
  boundary in `hash_info` metadata; C-side counters/instrumentation now include
  `rx_hash_l3`, `rx_hash_l4`, `rx_hash_missing` and `skb_set_hash(...)` is called for
  valid hashable frames.
- **A3**: complete + validated on the gateway (2026-06-07) — `receive-hashing on`,
  `rx_hash_l4` increments, `rx_hash_missing=0`, `ethtool -K rxhash on/off` toggles
  via `set_features`, TCP/UDP RX/TX at line rate, loaded latency unchanged, 0
  dmesg warnings. NOTE: the first audit run found the gateway was still on the
  pre-A3 binary; A3 was only substantiated after a sync+build+run — no phase is
  "complete" until built and run on hardware.
- **A3 hardening (2026-06-07)**:
  - **Legacy rollback knob** `rx_legacy_desc=1` forces the proven 16-byte RX
    descriptor path and disables RXHASH — an escape hatch since the default RX
    path is now V3 (the legacy path otherwise has no runtime fallback).
  - **Random RSS key**: the hash key is now `netdev_rss_key_fill` (boot-stable
    system key) instead of a hardcoded constant.
  - **RX hot loop**: replaced the per-packet `match RxDescFormat` + double
    descriptor read with `RxParse` (format → byte offsets resolved once per
    poll) + a single post-barrier fetch.
  - **Naming**: `RSS_CTRL_PROBE_HASH_BITS` → `RSS_CTRL_HASH_BITS`; probe key
    removed.
  - **UDP RX "regression" was a benchmarking artifact**, not a V3/A3 issue: the
    ~0.05% loss only appears when the sender is driven *above* the 2.35 Gbps line
    rate (`-b 2400M`), affects legacy and V3 equally, and is 0% at ≤ line rate.
- **A4**: complete — Track A is closed in the plan and gap ledger. The
  V3+RXHASH default matrix is captured under
  `docs/perf/cvr_20260607_v3rxhash/`; full RSS is now proceeding for Realtek
  vendor-driver parity, not because a current 2.5G throughput gap requires it.
- **B1**: complete + Gateway-smoked — the C bridge and Rust vtable are queue-id
  aware while retaining the current `N=1` runtime behavior. `napi_struct`,
  page-pool geometry, and RX delivery now live behind a queue object in the C
  bridge. Smoke artifacts are in
  `docs/perf/queue_bridge_smoke_20260607/`.
- **B2**: complete + Gateway-smoked — Rust RX state is array-backed
  (`rx_queues: [RxQueueState; RX_QUEUE_COUNT]`), open/stop/pre-post/teardown
  are queue-indexed, and the RX hot path resolves `queue_id` into that array.
  Runtime still reports and schedules exactly one RX queue; hardware RSS remains
  disabled. Smoke artifacts are in
  `docs/perf/b2_rx_state_array_smoke_20260607/`.
- **B3**: complete + Gateway-smoked — RTL8125B now uses the V2 interrupt
  surface only after an exact 22-vector MSI-X allocation, owns RX0/TX0/LINK on
  the fixed entries 0/16/21, and keeps the single-vector fallback on the legacy
  combined ISR/IMR surface. Smoke artifacts are in
  `docs/perf/b3_v2_msix_smoke_20260607/`.
- **B4**: complete + Gateway-smoked — RSS register/key/indirection programming
  now sits behind the off-by-default `rss_queues` gate. Default behavior remains
  the reviewed single-queue RXHASH path; `rss_queues=1` programs the same
  queue-0 table for validation; `rss_queues>1` fails `ndo_open` until the
  driver owns more RX queues. Smoke artifacts are in
  `docs/perf/rss_hw_programming_20260608/`.
- **B5**: complete + Gateway-smoked — ethtool RSS control plane is wired:
  `get_rxfh`/`get_rxfh_key_size`/`get_rxfh_indir_size` report the programmed
  boot key + all-zero (single-queue) indirection table, `get_channels` reports
  one RX/TX queue, and `get_rx_ring_count` answers the `ETHTOOL_GRXRINGS` query
  (kernel 7.0.0 routes it to the dedicated op, not `get_rxnfc` — so this works
  where the vendor's older `get_rxnfc`-only path does not). `set_rxfh` validates
  the indirection table through the host-tested `layout::rxfh_indir_all_valid`
  (rejecting entries that exceed owned queues) and refuses a custom hash key
  while only one RX queue is owned; it runs under RTNL, serialized against
  open/stop. Validated: `ethtool -x` readback, `ethtool -X equal 1` accepted,
  `ethtool -X equal 2` rejected (EINVAL), custom `hkey` rejected (EOPNOTSUPP),
  traffic healthy after. Gate: `ci/check_rss_ethtool.sh`. set_channels and
  custom multi-queue keys remain deferred with N>1 activation.
- **B6**: required before any N>1 RSS acceptance — run
  `scripts/rss_multiqueue_hazard_validate.sh` with full hardware RSS active.
  This is the explicit guard for RTL8125 RSS bug classes that host tests cannot
  prove away: small-packet and fragmented-UDP stress must record
  `udp_out_of_order=0`, no driver `rx_dropped_error` growth, and acceptable
  loss for the offered rate; TCP byte-integrity must pass SHA-256 comparison;
  at least two RX IRQ vectors must advance under load; the quiet post-load
  window must show no IRQ loop and no kworker CPU runaway; timestamping
  capabilities must be captured (current Rust path has no hardware timestamping
  support, and any future support must rerun this hazard test with timestamping
  enabled); and `fault_scan.txt` must be empty. Static gate:
  `ci/check_rss_multiqueue_hazard.sh`.

### Phase 0 Evidence Protocol

To close the phase-0 gate, we need one controlled experiment before any
structural refactor:

1. Confirm the validated RTL8125B is in one-queue mode with the legacy ISR/IMR
   surface.
2. Program RSS-normal V3 descriptors only (exclude PTP timestamp write-back path).
3. Set minimal hash-engine state (`RSS_CTRL_8125` hash bits + key, `Q_NUM_CTRL_8125`
   pinned to one queue).
4. Exercise TCP and UDP traffic and capture:
   - descriptor `RSSResult` / `HeaderInfo` (phase-0 primary signal),
   - `ethtool -S` `rx_hash_*` deltas,
   - and `skb->hash` only after A2 in A3 validation.
5. Accept `Track A` only if:
   - hash values are non-zero for hashable traffic,
   - `HeaderInfo` maps deterministically to `PKT_HASH_TYPE_L3/L4`,
   - missing hash counter does not rise for controlled hashable traffic.

If the above is inconclusive, Track A is blocked and the plan must move to Track
B full-RSS prerequisites.

Recommended execution:

```bash
LABEL=rust     DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/phase0_rsshash_probe.sh
LABEL=c_r8169  DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/phase0_rsshash_probe.sh
```

Artifacts expected in `docs/perf/rsshash_phase0_<timestamp>_<label>/`.

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
- Track A runtime format selection is explicit but remains `Legacy` on Rust until
  phase-0 confirms single-queue V3 hash population; the V3/V4 parse paths are
  now implemented and compile-time validated.
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
- descriptor length and field extraction from V3 offsets:
  - `opts1` at offset 28, `opts2` at 24, `addr` at 16,
  - RSSResult and HeaderInfo at 8–15,
  - OWN in `opts1` bit 31.
- VLAN/csum parity re-validation: `opts2` still carries VLAN tag bit/metadata and
  `opts1` still carries checksum/length ownership semantics; only offsets move.

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
- `Option<RxHash>` is lowered at exactly one boundary (`Rust -> C`); C stays on
  plain scalars and does not grow enum dispatch.

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

### Phase A4 - Documentation & Gate Closure

No code change in this phase. It records the implementation outcome and holds
Track B behind an explicit decision:

- If phase-0 empirics and A1/A2 are positive:
  - update this plan status to `A1` / `A2` / `A3` complete,
  - set `RXHASH` gate as satisfied in
    `docs/perf/DRIVER_GAP_LEDGER.md`,
  - move to Track B only if benchmark evidence shows a remaining gap.
- If negative:
  - keep `NETIF_F_RXHASH` hidden,
  - mark Track A as intentionally blocked by `Track B` prerequisites,
  - proceed to Phase B only if required by the broader roadmap.

Closure result, 2026-06-07:

- Track A is positive and closed: A1/A2/A3 are complete, RXHASH is advertised,
  and the gateway matrix on the V3+RXHASH default is captured in
  `docs/perf/cvr_20260607_v3rxhash/`.
- The `RXHASH` gate is satisfied in `docs/perf/DRIVER_GAP_LEDGER.md` and
  statically guarded by `ci/check_hw_offload_features.sh`.
- Track B is now started for vendor-driver parity. B1 must preserve the
  single-queue runtime while making every C/Rust RX ownership boundary
  queue-aware.

## Track B - Full Hardware RSS

Full RSS is a separate, larger effort. Its reference is the Realtek vendor
`r8125` driver, because mainline `r8169` does not expose the RTL8125 RSS
surface.

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

Implementation status:

- Complete: `struct r8125_bridge` now owns queue state through
  `r8125_bridge_rx_queue`.
- Complete: C/Rust vtable polling uses `poll(priv, queue_id, budget)`.
- Complete: RX page-pool lifecycle and RX delivery APIs accept
  `queue_id`.
- Hardware-smoked on Gateway `7.0.0-22-generic` with `N=1`: default TCP/UDP,
  open/stop, MTU 9000 reopen, RXHASH toggle, VLAN traffic, rmmod while up, and
  post-reload traffic all passed. Final counters kept `rx_hash_missing=0`.
- Still `N=1`: all runtime call sites use queue 0; no hardware RSS or
  multi-ring allocation is enabled yet.

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

- Gateway smoke of the one-queue queue-aware bridge is green before increasing
  queue count. Complete:
  `docs/perf/queue_bridge_smoke_20260607/`.
- Rust RX state is array-backed and open/close/pre-post/teardown are
  queue-indexed while `RX_QUEUE_COUNT=1`. Complete:
  `docs/perf/b2_rx_state_array_smoke_20260607/`.
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

Implementation status:

- Complete: probe attempts an exact 22-vector MSI-X allocation before enabling
  V2. If that allocation fails, the driver falls back to one MSI-X/MSI/INTx
  vector with `use_v2=false`.
- Complete: V2 requests only active Linux IRQs for RX0, TX0, and LINKCHG while
  leaving unused MSI-X entries allocated but masked.
- Complete: interrupt moderation programs the RX timer on entry 0 and the TX
  timer on entry 16 when V2 is active.
- Complete: `irq_pin_cpu` applies to each active V2 IRQ.
- Gateway-smoked on `7.0.0-22-generic`:
  - exact V2 allocation selected `rx0 IRQ 68`, `tx0 IRQ 197`, `link IRQ 202`
    with `use_v2=true`;
  - `/proc/interrupts` showed entry 0 and entry 16 deltas under traffic;
  - TCP TX/RX reached 2.353/2.353 Gbps;
  - UDP TX/RX at 1448B completed at 2.200/2.200 Gbps with no UDP-TX wedge;
  - `rx_hash_l4=2006515`, `rx_hash_missing=0`, `tx_dropped_error=0`,
    `rx_dropped_error=0`;
  - narrowed dmesg fault scan was clean, and `rmmod` while up completed.

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
- Key and indirection table are programmed through the shared RSS helper; ethtool
  readback/control lands in B5.
- RSS disabled path clears RSS control and preserves current single-queue
  performance.

Implementation checkpoint:

- `rss_queues` is default-off. Value 1 is a single-queue register-programming
  validation mode; values above `RX_QUEUE_COUNT` or above one without the V2
  interrupt surface return `-EINVAL`.
- RSS key programming uses `netdev_rss_key_fill`.
- RSS indirection programming uses the kernel `ethtool_rxfh_indir_default`
  helper via the cshim.
- `ci/check_rss_hw_programming.sh` enforces the register-programming gate.
- Gateway validation covers `rss_queues=0`, `rss_queues=1`, and the
  `rss_queues=2` negative gate under `docs/perf/rss_hw_programming_20260608/`.

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

- descriptor capability for the running chip is documented as RTL8125B V3.
- descriptor layout size/offset checks for V3 on RTL8125B; V4 checks only
  when a future V4-capable chip path is added.
- RXHASH can remain on a single RX queue; no queue-count gate is required for
  valid hash reporting.
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
`check_hw_offload_features.sh` should also include the explicit hard gate that
Track A can advertise `receive-hashing` only if:

- parser contract is compiled for RTL8125B V3, and
- `rx_hash_missing == 0` for hashable TCP/UDP in a controlled bench run.

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

Required benchmark artifacts:

- `raw/ethtool_k_before.txt`, `raw/ethtool_k_after.txt`
- `raw/ethtool_S_before.txt`, `raw/ethtool_S_after.txt`
- `raw/ethtool_x_before.txt`, `raw/ethtool_x_after.txt`
- `raw/interrupts_before.txt`, `raw/interrupts_after.txt`
- `features.csv`, `queues.csv`, `rxhash.csv`, `traffic.csv`, `latency.csv`

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

1. Descriptor go/no-go doc and benchmark/gap-ledger extensions. Done.
2. Descriptor type refactor, preserving legacy behavior. Done.
3. V3 parser tests and static layout gates for RTL8125B. Done.
4. RXHASH-only `skb_set_hash` path and counters, still feature-hidden. Done.
5. RXHASH-only Gateway validation. Done.
6. Advertise `NETIF_F_RXHASH` only if Track A passes. Done.
7. Full RSS is now proceeding for Realtek vendor-driver parity.
8. Queue-aware C bridge, still one queue. Done.
9. Multi-ring Rust state, still RSS-disabled. Done.
10. 22-vector MSI-X/V2 interrupt ownership. Done.
11. RSS register programming behind a module parameter. Done.
12. Ethtool RSS ops.
13. Advertise/enable full hardware RSS only after validation passes.

This order preserves the stable driver path and prevents repeating the
single-vector V2/TX-completion failure while still leaving a low-risk
RXHASH-only option open if the descriptor capability exists.

## Phase-by-Phase Verification Matrix

Track A validation evidence:

- A1:
  - `cargo check` and targeted `ring`/unsafe-boundary tests pass for descriptor
    parse changes.
  - A dedicated assertion verifies `RxDescFormat` is selected once per open.
  - No regressions in legacy path behavior or ring canary checks.
- A2:
  - C shim compiles and accepts `(hash_valid, hash_value, hash_type)`.
  - `ethtool -S` shows counters for `rx_hash_*` when enabled.
  - `sk_buff` hash-path is only invoked on hash-valid V3 packets.
- A3:
  - `scripts/gateway_hw_offload_validate.sh` produces all required artifacts.
  - `features.csv` shows `receive-hashing: on` after enable.
  - `rx_hash_missing` remains bounded for hashable control traffic.
  - Throughput/latency/IRQ deltas are within control budget.
- B1:
  - `cshim` vtable and queue-id contract compiles in lockstep.
  - queue-id is fully threaded to RX pool allocation/poll/reap and page-pool
    teardown.
- B2:
  - multi-ring memory allocation and tail updates are consistent with queue count.
  - open/stop/reset paths cleanly release per-queue resources.
- B3:
  - vector ownership and affinity are statically asserted in code comments and
    runtime checks.
  - `proc/interrupts` deltas show TX completion on vector 16 for RTL8125B.
  - Gateway smoke proves UDP TX does not reproduce the single-vector V2 wedge.
- B4/B5:
  - key/indir programming and RSS topology are reflected through `ethtool -x/-X`
    and read back matches.
