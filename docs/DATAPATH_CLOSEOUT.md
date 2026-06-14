# M4 close-out — rtl8125-rs

**Status: M4 COMPLETE 2026-05-26.** Every M4 sub-task in the plan §7
checklist is now done. Single-stream throughput matches the r8169
mainline reference. The §6.3 disposition-counter invariant is enforced
by CI (static + runtime).

This document is the formal hand-off for M4. M5 work (per-CPU counter
sharding, Clippy gates, additional polish) starts from a known-good
baseline captured here.

## What M4 delivered

| Sub-task | Status | Notes |
|---|---|---|
| #1 MAC from MMIO IDR0..5 | done | `src/netdev.rs::read_mac` |
| #2 `TxSkb<S>` type-state | done | `src/skb.rs`; mirrors §6.3 lifecycle states |
| #3 HW register set + ring base + ChipCmd + IMR/ISR/CPCR | done | `src/regs.rs`, `src/mmio.rs` |
| #4 IRQ handler via `pci::Device::request_irq` | done | `src/netdev.rs::raw_irq_handler` |
| #5 `ndo_open` / `ndo_stop` full bodies | done | `src/netdev.rs`; UAF fix #41 |
| #6 NAPI poll body — RX + TX completion | done | `src/napi.rs` |
| #7 `ndo_start_xmit` w/ §6.3 flow control | done | `src/netdev.rs::ndo_start_xmit` |
| #8 build + ip link 100-cycle test + ping + iperf3 vs r8169 | done | see `docs/baseline/iperf3/` |
| #9 §6.3 counter invariant CI + close-out | **THIS DOC** | static + runtime checks below |

Plus M4-perf sub-tasks (PHY init, 2.5 G C45 MDIO, HW CSUM + stats,
SG, TSO at line rate) — all completed.

## Performance vs r8169 reference

All measurements: validated MS-A2 (RTL8125B, XID 0x641), Linux 7.0.0
with KASAN + Rust enabled, KVM guest via VFIO PCI passthrough, direct
Cat6 to Intel I226-V host peer, MTU 1500, single TCP stream.

| Driver | g→h | h→g | TSO |
|---|---:|---:|---|
| **rtl8125-rs (this driver)** | **2.35 Gbps, 0 retr** | 1.27 Gbps, 0 retr | yes (max_segs=10) |
| r8169 mainline reference | 2.33 Gbps | ~1.2 Gbps | yes |

Single-stream throughput is at parity with r8169 on the same kernel.
The h→g direction is RX-bound at the guest CPU; that's a KVM/VFIO
artifact, not a driver bug.

Baselines:
- `docs/baseline/iperf3/iperf3_r8125_rust_guest2host_tcp_1500_tso.json`
- `docs/baseline/iperf3/iperf3_r8125_rust_host2guest_tcp_1500_tso.json`

## §6.3 disposition-counter accounting

Six counters in `struct r8125_bridge` (see
`src/netdev_bridge_internal.h`), each incremented at exactly one
disposition site:

| Counter | Increment site | Meaning |
|---|---|---|
| `tx_received` | `r8125_bridge_skb_data_dma_map` | xmit reached DMA-map |
| `tx_consumed` | `r8125_bridge_skb_consume_tx` | TX completion |
| `tx_busy_exception` | `r8125_bridge_tx_busy_exception` | NETDEV_TX_BUSY |
| `tx_dropped_error` | `r8125_bridge_skb_free_error` | drop before DMA |
| `rx_handed_to_stack` | `r8125_bridge_skb_deliver_rx` | napi_gro_receive ok |
| `rx_dropped_error` | `r8125_bridge_rx_drop_error` | RX build/chip-error drop |

Invariant (plan §6.3):

```
tx_received == tx_consumed + tx_busy_exception + tx_dropped_error
```

### Static CI gate

`ci/check_counter_infrastructure.sh` enforces that all six counters
have:
1. a `u64` field in `struct r8125_bridge`
2. at least one `WRITE_ONCE(b->{counter}, ...)` increment site
3. a corresponding `out->{counter} = READ_ONCE(b->{counter})` row in
   `r8125_bridge_counters_snapshot`
4. an entry in the `ethtool -S` strings table
   (`src/netdev_bridge_ethtool.c::bridge_ethtool_strings[]`)

Plus checks that the invariant equation is documented in the bridge
sources, and that the runtime check script is executable. Wired into
`ci/run_checks.sh` as the `§6.3 disposition-counter infrastructure`
section. 9 checks, all currently PASS.

### Runtime CI gate

`ci/check_counter_invariant.sh` is the hardware-required runtime test.
Usage:

```
$ ci/check_counter_invariant.sh enp5s0 10.0.0.1
Before:
  tx_received=222662 tx_consumed=222662 tx_busy=0 tx_drop=0 rx_hand=220891 rx_drop=0
INFO: running iperf3 -c 10.0.0.1 -B 10.0.0.2 -n 1G ...
[  5]   0.00-4.00   sec  1.00 GBytes  2.15 Gbits/sec                  receiver
After:
  tx_received=296846 tx_consumed=296846 tx_busy=0 tx_drop=0 rx_hand=290117 rx_drop=0

Deltas:
  tx_received=74184 tx_consumed=74184 tx_busy=0 tx_drop=0 rx_hand=69226 rx_drop=0

§6.3 invariant: tx_received == tx_consumed + tx_busy_exception + tx_dropped_error
  74184 == 74184  (gap 0)
PASS: §6.3 counter invariant holds across 1G transfer
```

The script:
1. Reads counters before via `ethtool -S`
2. Runs `iperf3 -c $PEER -B $LOCAL -n 1G`
3. Cycles `ip link down/up` to quiesce in-flight skbs
4. Reads counters after
5. Asserts `Δtx_received == Δtx_consumed + Δtx_busy + Δtx_drop`
6. Asserts `Δrx_handed_to_stack > 0`

Validated on the dev box 2026-05-26: PASS across 1 GB transfer with
gap = 0, zero drops, zero busy, RX path exercised.

## Code metrics at close

| Item | Value | Cap |
|---|---|---|
| `src/netdev_bridge.c` LOC | 362 | 400 |
| `src/netdev_bridge_ethtool.c` LOC | 77 | (new) |
| `src/netdev_bridge_offload.c` LOC | ~265 | — |
| `src/netdev_bridge_phy.c` LOC | ~190 | — |
| `unsafe` blocks | 53 | non-increasing |
| `unsafe`-allowing files | 1 (`src/unsafe_boundary.rs`) | 1 |
| Static CI checks | 34/34 PASS, 0 FAIL | — |

## What's NOT part of M4 (deferred to M5)

- **Per-CPU counter sharding** (task #45, RUST_STANDARDS.md §15.2):
  current counters live in the bridge struct, written from NAPI
  context (CPU-local) and read from ethtool (any CPU). Single-stream
  is fine but multi-queue / multi-CPU loads will see cache-line
  bouncing. Plan: shard to `__percpu` on the cshim side.
- **Clippy + cache-padding lint gates** (task #43, RUST_STANDARDS.md
  §18): `make CLIPPY=1` integration into `ci/run_checks.sh`.
- **Multi-queue / RSS**: M4 ships single-queue. Multi-queue lives in
  M5+.
- **Power management** (PM ops, runtime PM, WoL): deferred to M6.
- **Ethtool surfaces beyond -S**: link settings, ring sizes, coalesce,
  pause params — all reachable via `ethtool_ops` but not implemented
  yet. M5 / M6.

## Known caveats

- **TSO max_segs = 10** (not the upstream-published 64) — see
  `docs/RTL8125B_TSO_NOTES.md`. RTL8125B's LSO engine reproducibly
  stalls at 12+ segments per super-skb. This is a chip-specific cap
  that the driver must keep.
- **KVM/VFIO/KASAN-debug guest** is the only validated environment.
  Bare-metal and non-KASAN kernel testing is M5 close-out work.
- **h→g (RX direction) caps at ~1.27 Gbps** in the guest — RX path
  hasn't been optimized yet (no XDP, no page-pool, no GRO tuning).
  M5 RX-perf work.

## Sign-off

M4 entry criteria (plan §15) all green:
- [x] Static CI: 34/34 PASS
- [x] Driver loads and unloads cleanly on the validated chip
- [x] 100-cycle ip link up/down soak: no leaks
- [x] iperf3 baseline captured vs r8169
- [x] §6.3 invariant holds across 1 GB transfer (gap=0)
- [x] Documented in this file

Ready for M5.
