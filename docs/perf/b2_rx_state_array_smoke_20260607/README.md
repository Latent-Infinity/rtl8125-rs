# B2 RX State Array Smoke - 2026-06-07

Gateway smoke for the B2 checkpoint: Rust RX state is array-backed and
queue-indexed, while runtime remains one RX queue and hardware RSS remains off.

## Result

Driver checkpoint passed. The run covered:

- loading the rebuilt module on Gateway kernel `7.0.0-22-generic`
- default TCP/UDP traffic before reload
- open/stop carrier recovery
- MTU 9000 reopen and return to MTU 1500
- RXHASH off/on toggle
- VLAN ping and TCP traffic
- rmmod while the interface was up
- reload and post-reload TCP/UDP traffic

The smoke script exited nonzero only because its broad dmesg filter matched the
normal informational line `DMA rings allocated`. A narrowed fault scan for
warning, BUG, OOPS, panic, skb, DMA-API/debug/mapping, timeout, failed, and
error patterns is clean.

## Summary

```text
pre_tcp_rx: 2.353 Gbps lost=
pre_tcp_tx: 2.353 Gbps lost=
pre_udp_tx: 2.200 Gbps lost=0.00196315806694369
pre_udp_rx: 2.200 Gbps lost=0
post_tcp_rx: 2.353 Gbps lost=
post_tcp_tx: 2.353 Gbps lost=
post_udp_tx: 2.200 Gbps lost=0
post_udp_rx: 2.196 Gbps lost=0.19588211299649463
vlan_tcp_rx: 2.347 Gbps
```

Final counters:

```text
tx_received: 1411167
tx_consumed: 1411167
tx_busy_exception: 0
tx_dropped_error: 0
rx_handed_to_stack: 1762209
rx_dropped_error: 0
rx_hash_l3: 3
rx_hash_l4: 1762205
rx_hash_missing: 0
rx_hash_disabled: 1
```
