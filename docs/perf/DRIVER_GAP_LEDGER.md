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
   - V3 descriptor capability is applicable (not V4); `EnablePtp` path exercises V3.
   - Status: **recorded and accepted**.

2. **Descriptor hash population (go/no-go)**
   - Open question remains: does V3 produce usable `RSSResult` with one RX queue on the legacy ISR surface when only minimal hash-engine configuration is active (`RSS_CTRL_8125` + key + `Q_NUM_CTRL_8125=1`)?
   - Status: **not yet measured**.

3. **Hash type classification**
   - Need to confirm mapping of V3 `HeaderInfo` bits to `PKT_HASH_TYPE_L3` / `PKT_HASH_TYPE_L4` before `skb_set_hash(...)` is enabled.
   - Status: **not yet measured**.

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

- `scripts/gateway_hw_offload_validate.sh` comparison runs (Rust vs C) with:
  - `features.csv` (ETHTOOL `-k` + `receive-hashing` state)
  - `queues.csv` (RX/TX queue counts + `ethtool -x` support)
  - `raw/ethtool_x*.txt`, `raw/ethtool_l_before.txt`, `raw/ethtool_l_after.txt`
  - `raw/interrupts_*.txt` and `raw/ethtool_S_*.txt`
- `ci/check_hw_offload_features.sh`: current static gate keeps RXHASH hidden until `set_rss_ctrl_8125` + multi-ring + queue-id contract land.

## Open risk and decision point

This plan is still at planning status because the V3 hash-population test has not been run. Without that empirical gate result, the driver should continue to keep `NETIF_F_RXHASH` and RSS disabled.

## Next immediate artifact tasks

1. Run a focused TX/RX probe on validated RTL8125B with V3 + one RX queue and minimal RSS hash-engine programming.
2. Capture descriptor `RSSResult`/`HeaderInfo` fields and matched `skb->hash` from kernel/userspace (`ethtool -S` + packet tracing or temporary debug print).
3. Populate Track A decision line in this ledger from the result and either proceed with RXHASH-only implementation or jump to Track B prerequisites.
