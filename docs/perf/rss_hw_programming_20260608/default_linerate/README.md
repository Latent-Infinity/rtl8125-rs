# HW Offload Validation - rust_rss_default_linerate

- UTC stamp: 20260608_061536
- Driver label: rust_rss_default_linerate
- DUT: enp3s0 (10.0.0.2/24), VLAN enp3s0.125 id 125 (10.125.0.2/24)
- Peer: enp4s0 (10.0.0.1/24), VLAN enp4s0.125 id 125 (10.125.0.1/24)
- Duration: 5s per iperf3 run
- UDP lengths: 64 1448 at 2350M offered
- MTUs: 1500

Expected Rust-vs-C comparison:

- VLAN: `tx-vlan-offload` and `rx-vlan-offload` should be on when supported, and VLAN TCP/UDP traffic should stay loss-free or match the C driver's loss profile.
- RSS/RXHASH: Rust should advertise validated single-queue RXHASH, keep `rx_hash_missing=0` for hashable traffic, and keep full N>1 hardware RSS off until queue/vector programming and ethtool controls are validated.
- Queues: Rust is expected to report one RX queue for now; vendor `r8125` output is the baseline for future full-RSS feature comparisons.

Primary artifacts:

- `features.csv`
- `traffic.csv`
- `queues.csv`
- `rxhash.csv` and per-mode `raw/ethtool_S_after_*.txt`
- `irq_snapshot.csv` and raw per-mode interrupt snapshots
- `raw/ethtool_S_*.txt`
- `raw/interrupts_*.txt`
