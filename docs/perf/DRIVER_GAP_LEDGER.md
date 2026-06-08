# RSS / RXHASH Gap Ledger

**Status: 2026-06-07.** Single-queue RXHASH is implemented and closed for the
RFC path; full hardware RSS is now started for Realtek vendor-driver parity.

## Baseline evidence captured

| area | Rust driver result | C driver result | evidence |
|---|---|---|---|
| VLAN TX/RX offload | parity on parity-target paths; HW VLAN tag encode/decode implemented | parity or better depending on benchmark mix | `docs/perf/HW_OFFLOAD_VALIDATE.md`, `scripts/gateway_hw_offload_validate.sh`, `docs/perf/cvr_20260606_opt/SUMMARY.md` |
| checksum/TSO | parity-to-better on tested profiles | parity | `docs/perf/cvr_20260606_opt/SUMMARY.md`, `docs/SESSION_RESUME.md`, `ci/check_hw_offload_features.sh` |
| UDP TX wedge (legacy ISR) | fixed with `use_v2=false` on single-vector MSI path | reference baseline | `docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md`, `docs/perf/byte_budget_20260605/RESULTS.md` |
| RXHASH advertise | `NETIF_F_RXHASH` advertised with one RX queue and V3 hash reporting | vendor `r8125` supports RSS/RXHASH; mainline `r8169` does not | `ci/check_hw_offload_features.sh`, `docs/perf/HW_OFFLOAD_VALIDATE.md`, `src/netdev_bridge.c`, `docs/perf/cvr_20260607_v3rxhash/` |
| queueing model | single RX queue + one TX queue in Rust; queue-aware bridge contract and one-queue Rust RX state scaffold implemented | vendor `r8125` supports multi-queue RSS | `scripts/gateway_hw_offload_validate.sh` (`queues.csv`), `docs/perf/HW_OFFLOAD_VALIDATE.md`, `docs/perf/b2_rx_state_array_smoke_20260607/` |
| RTL8125B V2 interrupt ownership | exact 22-vector MSI-X gate implemented; V2 owns RX0/TX0/LINK entries 0/16/21; single-vector fallback remains legacy | vendor `r8125` requires the fixed V2 message-id topology | `ci/check_irq_mode_contract.sh`, `ci/check_msix_static.sh`, `ci/check_isr_v2_paired.sh`, `docs/perf/b3_v2_msix_smoke_20260607/` |

## Hashability Gate Status

1. **Chip/Vendor capability (RTL8125B)**
   - Validated as `MAC_VER_63`, XID `0x641`.
   - V3 descriptor capability is applicable (not V4); XID-mapped mcfg confirms CFG_METHOD_4/5.
   - Status: **recorded and accepted**.

2. **Descriptor hash population (go/no-go)**
  - **RESOLVED:** V3 produces usable `RSSResult` with one RX queue on the
    legacy ISR surface when minimal hash-engine configuration is active
    (`RSS_CTRL_8125` + key + `Q_NUM_CTRL_8125=0`): `rx_hash_l4=72064` and
    `rx_hash_missing=0` in gateway coverage.

3. **Hash type classification**
  - Mapping verified: V3 `HeaderInfo` maps TCP/UDP flows to `PKT_HASH_TYPE_L4`,
    non-IP does not map to a hashable type, and `PKT_HASH_TYPE_L3` paths are
    available for IP flows not carrying L4 metadata.

## Implementation Status

### Single-Queue RXHASH

- V3 hash-validity proven at single-queue + legacy IRQ mode.
- Parser + `Option<RxHash>` handoff implemented (Rust -> C shim).
- `NETIF_F_RXHASH` advertised with single-queue hash-engine programming and no full-RSS/V2 interrupt enablement.

### Full RSS (RTL8125B)

- Complete: queue-aware bridge contract (`poll`, NAPI, page-pool lifecycle, and
  RX delivery now carry `queue_id`; runtime remains `N=1`)
- Complete: one-queue Rust RX state is array-backed and queue-indexed.
- Complete: 22-vector MSI-X ownership policy and interrupt routing for V2
  (RX0 entry 0, TX Q0 entry 16, LINKCHG entry 21), with single-vector fallback
  kept on the legacy combined ISR/IMR surface.
- Complete + Gateway-smoked: RSS register/key/indirection programming is behind
  the off/default `rss_queues` gate. `rss_queues=1` programs a queue-0 default
  indirection table for validation; `rss_queues>1` fails until more RX queues
  are actually owned. Evidence: `docs/perf/rss_hw_programming_20260608/`.
- Deferred: ethtool RSS controls/readback and full N>1 activation.

**Track B value verdict (2026-06-07): defer activating N>1 — payoff does not
materialize at 2.5GbE.** Measured Rust (Track A: 1 queue + RXHASH→RPS) vs vendor
`r8125` built with RSS (4 queues = real Track B) under pinned CPU-bound-app
contention. Both generator-bound at ~2.0M pps (64B); Rust+RPS delivered *more*
pps than vendor 4-queue (~2.35M vs ~1.97M). Single-queue coexistence penalty
(app on the RX cpu → 1% CPU) is recovered by RPS (→82%) or IRQ placement
(→100%). Track B's only measured edge was apparent determinism (vendor 89–95%
every run vs Rust+RPS bimodal 82/87/**1%**), but the 1% row did not reproduce
once RPS state and RXHASH counters were captured. The queue-aware ABI scaffold
above is low-risk and fine to land; **flipping N>1 on is not yet justified by
data.** Follow-up artifacts: `docs/perf/trackb_20260607/TRACKB_VALUE.md` and
`docs/perf/rps_collapse_fe00_20260607/`.

## Required proof artifacts

- Hashability probe:
  - `scripts/rxhash_probe.sh` (single-queue legacy IRQ baseline + V3 hash-engine knob)
- `scripts/gateway_hw_offload_validate.sh` comparison runs (Rust vs C) with:
  - `features.csv` (ETHTOOL `-k` + `receive-hashing` state)
  - `queues.csv` (RX/TX queue counts + `ethtool -x` support)
  - `raw/ethtool_x*.txt`, `raw/ethtool_k_initial.txt`, `raw/ethtool_S_*`
  - `raw/interrupts_*.txt` and `raw/ethtool_S_*.txt`
  - `features.csv`, `hash_counters.csv`, `traffic.csv`, `queues.csv`, `irq_snapshot.csv`
- `ci/check_hw_offload_features.sh`: static gate requires RXHASH advertisement to stay paired with V3 parsing, `skb_set_hash(...)`, counters, and single-queue RSS programming.

## Open risk and decision point — RESOLVED 2026-06-07 (D1: YES)

Hardware verdict reached via controlled validation on the gateway (RTL8125B,
kernel 7.0.0-22):

- V3 descriptors + minimal hash engine (`RSS_CTRL=0x183F` + key) at **one RX
  queue on the legacy ISR surface (`use_v2=false`, single MSI vector)** DO
  populate `RSSResult`. Observed non-zero Toeplitz hashes varying by 4-tuple,
  `HeaderInfo`→L4 for TCP/UDP, `rx_hash_l4=72064`, `rx_hash_missing=0`.
- V3 RX/TX at line rate (2.35/2.35 Gbps), UDP 0% loss, 0 dmesg warnings.

**Decision: single-queue RXHASH is implemented.** Hardware RSS / V2 / the
22-vector MSI-X surface is NOT required to produce a valid `skb->hash`. Full RSS
is now proceeding separately for Realtek vendor-driver parity. `NETIF_F_RXHASH` is now advertised only for the single-queue V3
hash-reporting path; production uses the reviewed `ndo_open` path and does not
enable the V2 multi-queue interrupt surface.

## A3 hardening + validation (2026-06-07)

- **Validated on the gateway**: default V3 + RXHASH advertised, `receive-hashing
  on`, `rx_hash_l4` increments, `rx_hash_missing=0`, `ethtool -K rxhash on/off`
  toggles, TCP/UDP RX/TX at line rate, 0 dmesg warnings.
- **Legacy rollback knob** `rx_legacy_desc=1` forces the proven 16-byte RX path
  (RXHASH off) — the default is now V3, so this is the escape hatch.
- **Random RSS key** via `netdev_rss_key_fill` (no hardcoded key).
- **RX hot loop** de-duplicated: `RxParse` resolves the format once per poll; the
  per-packet `match` + double descriptor read are gone (single post-barrier read).
- **No UDP RX regression from V3**: the ~0.05% loss seen at `-b 2400M` is
  over-line-rate spillover present on legacy and V3 alike; 0% at ≤ line rate.

## Next immediate tasks

1. Add ethtool RSS key/indirection/channel control after fixed-queue RSS
   programming is stable.
2. If Rust+RPS collapse reappears, rerun `scripts/rps_collapse_diagnose.sh` and
   classify it from captured `rps_cpus`, IRQ affinity, `rx_hash_*`, and softnet
   deltas before changing driver code.
3. Use Realtek vendor `r8125`, not mainline `r8169`, for future RSS feature and
   performance comparisons.

## B3 V2 MSI-X Smoke

Artifact: `docs/perf/b3_v2_msix_smoke_20260607/`.

- Gateway `7.0.0-22-generic`, Rust driver rebuilt and loaded from
  `~/rtl8125-rs/src/r8125_rust.ko`.
- Probe selected exact 22-vector MSI-X and `use_v2=true`: RX0 IRQ 68
  (MSI-X entry 0), TX0 IRQ 197 (entry 16), LINK IRQ 202 (entry 21).
- `/proc/interrupts` deltas during traffic confirmed RX0 and TX0 activity:
  RX0 0 -> 235179, TX0 5 -> 2699681, LINK remained 1.
- Traffic: TCP TX/RX 2.353/2.353 Gbps; UDP 1448B TX/RX 2.200/2.200 Gbps
  with UDP TX loss 0 and no TX-completion wedge.
- RXHASH remained healthy: `rx_hash_l4=2006515`, `rx_hash_missing=0`.
- Teardown: `rmmod` while up completed; narrowed dmesg fault scan was clean.

## Queue-Aware Bridge Smoke

Artifact: `docs/perf/queue_bridge_smoke_20260607/`.

- Gateway `7.0.0-22-generic`, Rust driver loaded from
  `/tmp/r8125_rust_build/src/r8125_rust.ko`.
- Exercised default TCP/UDP, open/stop, MTU 9000 reopen, RXHASH off/on, VLAN
  traffic, rmmod while up, reload, and post-reload TCP/UDP.
- Result: pass for the driver checkpoint. The harness itself needed carrier
  waits after reopen/reload and a VLAN-scoped iperf server; those early harness
  failures are not driver failures.
- Summary: TCP RX/TX 2.353/2.353 Gbps, UDP TX/RX 2.200/2.198 Gbps at 2.2 Gbps
  offered load, VLAN TCP RX 2.347 Gbps, `rx_hash_missing=0`, no dmesg warning,
  BUG, OOPS, panic, skb, or DMA fault.

## B2 RX State Array Smoke

Artifact: `docs/perf/b2_rx_state_array_smoke_20260607/`.

- Gateway `7.0.0-22-generic`, Rust driver rebuilt from
  `/tmp/r8125_rust_build/src/r8125_rust.ko`.
- Rust state is now `rx_queues: [RxQueueState; RX_QUEUE_COUNT]`; open,
  allocation, pre-post, teardown, and NAPI slot refill paths are queue-indexed.
- Runtime remains intentionally one queue: C bridge count is 1, `ethtool -l`
  remains unsupported, and hardware RSS stays disabled.
- Exercised load, default TCP/UDP, open/stop, MTU 9000 reopen, RXHASH off/on,
  VLAN traffic, rmmod while up, reload, and post-reload TCP/UDP.
- Summary: pre TCP RX/TX 2.353/2.353 Gbps, post TCP RX/TX 2.353/2.353 Gbps,
  UDP at 2.2 Gbps offered load with only small peer/generator spillover, VLAN
  TCP RX 2.347 Gbps, `rx_hash_missing=0`, no warning, BUG, OOPS, panic, skb,
  or DMA fault under a narrowed dmesg scan.
