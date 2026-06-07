# Hardware Offload Validation

**Status: 2026-06-07.** VLAN hardware acceleration and single-queue RXHASH are
implemented in the Rust driver. RXHASH uses one RX queue with V3 descriptor hash
reporting; full hardware RSS remains deferred until multi-ring RX and the
RTL8125B 22-vector MSI-X model are implemented.

## Run Shape

Use the same Gateway direct-link topology as the TX byte-budget sweep. Run the
new harness once with the in-tree C driver bound, then once with `r8125_rust`
bound:

```bash
LABEL=c_r8169  DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/gateway_hw_offload_validate.sh
LABEL=rust     DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/gateway_hw_offload_validate.sh
```

The script writes comparable CSVs under
`docs/perf/hw_offload_validate_<stamp>_<label>/`:

- `features.csv` records checksum, TSO, VLAN, and RXHASH feature state.
- `traffic.csv` records VLAN TCP/UDP TX/RX throughput, PPS, loss, and retransmits.
- `queues.csv` records RX/TX queue count and `ethtool -x` support state.
- `rxhash.csv` records `ethtool -S` hash counters after each mode (`rx_hash_*`).
- `irq_snapshot.csv` stores per-line totals from `/proc/interrupts` for each mode.
- `raw/` keeps `ethtool -k`, `ethtool -S`, `ethtool -x`, interrupts, and
  ethtool topology (`-g`, `-l`, `-c`) and iperf3 JSON.

The RSS/hashability probe can be run with the focused probe script:

```bash
LABEL=rust     DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/rxhash_probe.sh
LABEL=c_r8169  DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/rxhash_probe.sh
```

That focused run writes:

- `features.csv`
- `queues.csv`
- `hash_counters.csv`
- `irq_snapshot.csv`
- `traffic.csv`
- `README.md` (decision notes)

## Acceptance Criteria

- Rust and C both complete VLAN TCP/UDP traffic with no new loss/retransmit
  profile when `tx-vlan-offload` and `rx-vlan-offload` are enabled.
- Disabling VLAN offload with `ethtool -K ... txvlan off rxvlan off` still
  passes traffic, proving the software fallback path is not broken.
- Rust reports `receive-hashing: on`, keeps one RX queue, increments
  `rx_hash_l3`/`rx_hash_l4` for hashable traffic, and keeps `rx_hash_missing`
  bounded in controlled runs.
- Any future full-RSS patch must include C-vs-Rust evidence from this harness
  plus queue/RSS snapshots proving queue distribution and valid hashes.

## RSS/RXHASH Enablement Checklist

Single-queue RXHASH is advertised because all of these are true:

1. RX descriptors are versioned and the RTL8125 RxDescV3/V4 RSS fields are
   parsed instead of the current legacy 16-byte descriptor shape.
2. The RX cshim can call `skb_set_hash(...)` with the descriptor's RSS result
   and the correct L3/L4 hash type.
3. Hash counters confirm `rx_hash_l3`/`rx_hash_l4` counters increase for hashable
   TCP/UDP and `rx_hash_missing` is bounded in controlled runs.
Full RSS remains disabled until all of these are true:

4. The driver owns multiple RX rings, including per-ring
   descriptors, tails, page pools, and NAPI state.
5. Queue count and RSS registers are programmed consistently, and
   the netdev reports the real queue count to the stack.
6. Interrupt/vector ownership is reviewed for multi-queue RX
   instead of the current single-vector, single-queue mode.
7. `ethtool -x/-X` support exists for RSS indirection/key visibility and
   control, matching vendor behavior where the chip supports it.
