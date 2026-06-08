# Queue-Aware Bridge Smoke - 2026-06-07

Gateway smoke for the Track B queue-aware bridge checkpoint while runtime
queue count remains one.

## Result

Driver checkpoint passed. The run covered:

- default TCP/UDP traffic
- open/stop carrier recovery
- MTU 9000 reopen and return to MTU 1500
- RXHASH off/on toggle
- VLAN ping and TCP traffic
- rmmod while the interface was up
- reload and post-reload TCP/UDP traffic

The smoke harness itself had three corrected issues before the final run:
carrier wait after reopen, matching peer MTU for jumbo probes, and a
VLAN-scoped iperf server. The final run reached final stats; only the inline
summary parser failed because the command logger prefixed the iperf JSON files.
`summary.txt` was regenerated from the JSON payloads by skipping that prefix.

## Summary

```text
tcp_rx: 2.353 Gbps lost=
tcp_tx: 2.353 Gbps lost=
udp_tx: 2.200 Gbps lost=0
udp_rx: 2.198 Gbps lost=0.0952061054050458
vlan_tcp_rx: 2.347 Gbps lost=
```

Final counters:

```text
rx_hash_l3: 3
rx_hash_l4: 1762220
rx_hash_missing: 0
rx_hash_disabled: 1
rx_dropped_error: 0
tx_dropped_error: 0
```

`dmesg_recent.txt` has normal open/stop diagnostics and no warning, BUG, OOPS,
panic, skb, or DMA fault.
