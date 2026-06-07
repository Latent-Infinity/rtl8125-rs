# RSS / RXHASH Gap Ledger

**Status: 2026-06-07.** Single-queue RXHASH is implemented; full hardware RSS
remains deferred.

## Baseline evidence captured

| area | Rust driver result | C driver result | evidence |
|---|---|---|---|
| VLAN TX/RX offload | parity on parity-target paths; HW VLAN tag encode/decode implemented | parity or better depending on benchmark mix | `docs/perf/HW_OFFLOAD_VALIDATE.md`, `scripts/gateway_hw_offload_validate.sh`, `docs/perf/cvr_20260606_opt/SUMMARY.md` |
| checksum/TSO | parity-to-better on tested profiles | parity | `docs/perf/cvr_20260606_opt/SUMMARY.md`, `docs/SESSION_RESUME.md`, `ci/check_hw_offload_features.sh` |
| UDP TX wedge (legacy ISR) | fixed with `use_v2=false` on single-vector MSI path | reference baseline | `docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md`, `docs/perf/byte_budget_20260605/RESULTS.md` |
| RXHASH advertise | `NETIF_F_RXHASH` advertised with one RX queue and V3 hash reporting | mainline r8169 has no RTL8125 RSS/RXHASH path | `ci/check_hw_offload_features.sh`, `docs/perf/HW_OFFLOAD_VALIDATE.md`, `src/netdev_bridge.c` |
| queueing model | single RX queue + one TX queue in Rust | single queue in current Rust baseline | `scripts/gateway_hw_offload_validate.sh` (`queues.csv`), `docs/perf/HW_OFFLOAD_VALIDATE.md` |

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

- Deferred: queue-aware bridge contract (queue id plumbing for `napi`, `page_pool`, and reset)
- Deferred: 22-vector MSI-X ownership policy and interrupt routing (RX QN, TX Q0 entry 16, LINKCHG entry 21)
- Deferred: hardware RSS register/key/indirection stack and ethtool controls

## Required proof artifacts

- Hashability probe:
  - `scripts/rxhash_probe.sh` (single-queue legacy IRQ baseline + V3 hash-engine knob)
- `scripts/gateway_hw_offload_validate.sh` comparison runs (Rust vs C) with:
  - `features.csv` (ETHTOOL `-k` + `receive-hashing` state)
  - `queues.csv` (RX/TX queue counts + `ethtool -x` support)
  - `raw/ethtool_x*.txt`, `raw/ethtool_k_initial.txt`, `raw/ethtool_S_*`
  - `raw/interrupts_*.txt` and `raw/ethtool_S_*.txt`
  - `features.csv`, `hash_counters.csv`, `traffic.csv`, `queues.csv`, `irq_snapshot.csv`
- `ci/check_hw_offload_features.sh`: static gate requires RXHASH advertisement to stay paired with V3 parsing, `skb_set_hash(...)`, counters, and single-queue RSS programming. Multi-ring/queue-id work remains deferred.

## Open risk and decision point — RESOLVED 2026-06-07 (D1: YES)

Hardware verdict reached via controlled validation on the gateway (RTL8125B,
kernel 7.0.0-22):

- V3 descriptors + minimal hash engine (`RSS_CTRL=0x183F` + key) at **one RX
  queue on the legacy ISR surface (`use_v2=false`, single MSI vector)** DO
  populate `RSSResult`. Observed non-zero Toeplitz hashes varying by 4-tuple,
  `HeaderInfo`→L4 for TCP/UDP, `rx_hash_l4=72064`, `rx_hash_missing=0`.
- V3 RX/TX at line rate (2.35/2.35 Gbps), UDP 0% loss, 0 dmesg warnings.

**Decision: single-queue RXHASH is implemented.** Hardware RSS / V2 / the
22-vector MSI-X surface is NOT required to produce a valid `skb->hash`; full RSS
stays deferred. `NETIF_F_RXHASH` is now advertised only for the single-queue V3
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

1. Full C-vs-Rust matrix on the V3+RXHASH default (the prior `cvr_20260606_formal`
   certification was on the legacy default and is now stale).
2. Keep full RSS deferred unless evidence shows a gap single-queue RXHASH can't close.
