# RSS / RXHASH Gap Ledger

**Status: 2026-06-06.** Tracks only the gaps relevant to `docs/RSS_RXHASH_IMPLEMENTATION_PLAN.md` and what is still needed before Track A (RXHASH-only) and Track B (full RSS) can proceed.

## Baseline evidence captured

| area | Rust driver result | C driver result | evidence |
|---|---|---|---|
| VLAN TX/RX offload | parity on parity-target paths; HW VLAN tag encode/decode implemented | parity or better depending on benchmark mix | `docs/perf/HW_OFFLOAD_VALIDATE.md`, `scripts/gateway_hw_offload_validate.sh`, `docs/perf/cvr_20260606_opt/SUMMARY.md` |
| checksum/TSO | parity-to-better on tested profiles | parity | `docs/perf/cvr_20260606_opt/SUMMARY.md`, `docs/SESSION_RESUME.md`, `ci/check_hw_offload_features.sh` |
| UDP TX wedge (legacy ISR) | fixed with `use_v2=false` on single-vector MSI path | reference baseline | `docs/perf/byte_budget_20260605/UDP_TX_WEDGE.md`, `docs/perf/byte_budget_20260605/RESULTS.md` |
| RXHASH advertise | intentionally off | not advertised on Rust; not visible on stack | `ci/check_hw_offload_features.sh`, `docs/RX_OPTIMIZATION_CANDIDATES.md`, `src/netdev_bridge.h` |
| queueing model | single RX queue + one TX queue in Rust | single queue in current Rust baseline | `scripts/gateway_hw_offload_validate.sh` (`queues.csv`), `docs/perf/HW_OFFLOAD_VALIDATE.md` |

## Phase 0 gate status

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

## Track A / Track B blockers

### Track A — RXHASH-only

- Blocker A1: prove V3 hash-validity at single-queue + legacy IRQ mode.
- Blocker A2: implement parser + `Option<RxHash>` handoff (Rust -> C shim).
- Blocker A3: wire `NETIF_F_RXHASH` only after the empirical gate and counter evidence above pass.

### Track B — Full RSS (RTL8125B)

- Blocker B1: queue-aware bridge contract (queue id plumbing for `napi`, `page_pool`, and reset)
- Blocker B2: 22-vector MSI-X ownership policy and interrupt routing (RX QN, TX Q0 entry 16, LINKCHG entry 21)
- Blocker B3: hardware RSS register/key/indirection stack and ethtool controls

## Required proof artifacts

- Phase-0 probe:
  - `scripts/phase0_rsshash_probe.sh` (single-queue legacy IRQ baseline + V3 hash-engine knob)
- `scripts/gateway_hw_offload_validate.sh` comparison runs (Rust vs C) with:
  - `features.csv` (ETHTOOL `-k` + `receive-hashing` state)
  - `queues.csv` (RX/TX queue counts + `ethtool -x` support)
  - `raw/ethtool_x*.txt`, `raw/ethtool_k_initial.txt`, `raw/ethtool_S_*`
  - `raw/interrupts_*.txt` and `raw/ethtool_S_*.txt`
  - `features.csv`, `hash_counters.csv`, `traffic.csv`, `queues.csv`, `irq_snapshot.csv`
- `ci/check_hw_offload_features.sh`: current static gate keeps RXHASH hidden until `set_rss_ctrl_8125` + multi-ring + queue-id contract land.

## Open risk and decision point — RESOLVED 2026-06-07 (D1: YES)

Hardware verdict reached via `phase0` style controlled validation on the
gateway (RTL8125B, kernel 7.0.0-22):

- V3 descriptors + minimal hash engine (`RSS_CTRL=0x183F` + key) at **one RX
  queue on the legacy ISR surface (`use_v2=false`, single MSI vector)** DO
  populate `RSSResult`. Observed non-zero Toeplitz hashes varying by 4-tuple,
  `HeaderInfo`→L4 for TCP/UDP, `rx_hash_l4=72064`, `rx_hash_missing=0`.
- V3 RX/TX at line rate (2.35/2.35 Gbps), UDP 0% loss, 0 dmesg warnings.

**Decision: Track A (RXHASH-only) is GO.** Hardware RSS / V2 / the 22-vector
MSI-X surface is NOT required to produce a valid `skb->hash`; full RSS (Track B)
stays deferred. `NETIF_F_RXHASH` remains hidden until A1/A2 land cleanly and
advertise it behind the static gate; production now uses the reviewed `ndo_open`
path with gating instead of a throwaway probe parameter.

## Next immediate tasks (Track A is unblocked)

1. Keep RXHASH internally gated until A1/A2 runtime gate criteria are met in a
   controlled stack test (counters and `skb->hash` validation).
2. Wire `NETIF_F_RXHASH` advertisement behind `ci/check_hw_offload_features.sh`
   (parser compiled for V3 + `rx_hash_missing==0` in a controlled run).
3. Run A3 runtime validation in `gateway_hw_offload_validate.sh` and set the
   static gate when it passes.
