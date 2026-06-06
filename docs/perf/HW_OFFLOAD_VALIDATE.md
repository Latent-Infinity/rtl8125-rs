# Hardware Offload Validation

**Status: 2026-06-06.** VLAN hardware acceleration is implemented in the
Rust driver. RSS/RXHASH remains deliberately unadvertised until the RX
descriptor and ring topology can report hashes correctly.

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

## Acceptance Criteria

- Rust and C both complete VLAN TCP/UDP traffic with no new loss/retransmit
  profile when `tx-vlan-offload` and `rx-vlan-offload` are enabled.
- Disabling VLAN offload with `ethtool -K ... txvlan off rxvlan off` still
  passes traffic, proving the software fallback path is not broken.
- Rust keeps `receive-hashing`/RXHASH off and reports one RX queue until the
  descriptor/ring work below lands.
- Any future RXHASH patch must include C-vs-Rust evidence from this harness
  plus queue/RSS snapshots proving the stack receives valid hashes.

## RSS/RXHASH Enablement Checklist

Do not advertise `NETIF_F_RXHASH` until all of these are true:

1. RX descriptors are versioned and the RTL8125 RxDescV3/V4 RSS fields are
   parsed instead of the current legacy 16-byte descriptor shape.
2. The RX cshim can call `skb_set_hash(...)` with the descriptor's RSS result
   and the correct L3/L4 hash type.
3. The driver owns multiple RX rings, including per-ring descriptors, tails,
   page pools, and NAPI state.
4. Queue count and RSS registers are programmed consistently, and the netdev
   reports the real queue count to the stack.
5. Interrupt/vector ownership is reviewed for multi-queue RX instead of the
   current single-vector, single-queue mode.
6. `ethtool -x/-X` support exists for RSS indirection/key visibility and
   control, matching r8169/vendor behavior where the chip supports it.

Until then, advertising RXHASH would tell the stack that `skb->hash` is valid
when the current descriptor path cannot safely extract it.
