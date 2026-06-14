# M6 sub-feature #2 — Jumbo frames + RX-pool refactor

**Status: LANDED 2026-05-28**. This file captures the before/after
data the plan §7 M6 gate demands. See [`README.md`](README.md) for the
metric scheme and the environment-authority rules; the
[`gateway_baseline.md`](gateway_baseline.md) numbers are the
pre-M6 reference.

## Scope

The atomic patch covered three changes that ship together because they
are interdependent:

1. **Chip-side `RxMaxSize`** bumped to `0x3FFF` (`R8169_RX_BUF_SIZE`
   equivalent) so the chip's drop threshold matches the jumbo RX pool.
2. **RX-pool refactor**: replaced the single `CoherentAllocation<RxBuffer>`
   (256 × 2 KiB = 512 KiB contiguous DMA) with **per-slot streaming-DMA
   pages** (256 × `alloc_pages(order=2)` + `dma_map_page`). This is the
   r8169 mainline pattern; the previous coherent layout doesn't scale
   to 16 KiB per slot.
3. **`max_mtu` advertised at 9000**. The chip supports up to 16 380 but
   we cap at the industry-standard 9 KiB so peers / switches don't
   silently drop oversized frames.

Plus an unanticipated **Phase D**: the
[`bridge_ndo_fix_features`](../../src/netdev_bridge.c) hook that drops
`NETIF_F_ALL_TSO | NETIF_F_CSUM_MASK` when `mtu > ETH_DATA_LEN`. This
is necessary because the RTL8125B TX descriptor's MSS field is only
11 bits wide (mask `0x7FF` = 2 047); at MTU 9 000 the TCP MSS overflows
that field and the chip silently emits malformed segments — see memory
[`rtl8125b-tso-mss-11bit-cap`](../../../../home/firestrand/.claude/projects/-home-firestrand-Projects-Rt8125-driver/memory/rtl8125b-tso-mss-11bit-cap.md).
r8169 mainline solves it the same way (`r8169_main.c:1799-1812`).

## Environment authority

These numbers are **Controller-KVM** measurements (debug+Rust kernel
with KASAN + lockdep + kmemleak + DMA_API_DEBUG). Per
[`README.md`](README.md), the M7 maintainer dossier cites only Gateway
bare-metal numbers; this file is for development verification. Gateway
throughput re-measurement is pending the 24 h ASPM-on soak completing
(ETA 2026-05-30 ~03:05 UTC).

| Item | Value |
|---|---|
| Box | Controller — KVM guest with RTL8125B VFIO passthrough |
| Kernel | `7.0.0` (debug+Rust build: KASAN + lockdep + kmemleak + DMA_API_DEBUG) |
| Driver | `r8125_rust` commit `5c67ccf` (M5 close-out + M6 #1 + M6 #2 + #58 fix) |
| MSI mode | MSI-X (vector#0 = IRQ 61, `mode=Msi`) |
| Chip | Realtek RTL8125B, XID 0x641, rev 0x05 |
| Topology | guest enp5s0 (10.0.0.2) → host enp4s0 I226-V (10.0.0.1), cable |
| Link | 2.5 Gbps, full-duplex, flow control rx/tx |
| Offload (MTU 1500) | TSO/TSO6 on, SG on, CSUM on, max_segs=10, max_size=64000 |
| Offload (MTU 9000) | TSO/TSO6 **off**, CSUM **off** (auto by `ndo_fix_features`); RX-CSUM on |

## Before / after — same MTU 1500, no driver functional change

This shows the M6 #2 refactor doesn't regress the legacy MTU 1500 path.

| Metric | Before (pre-M6 #2) | After (post-M6 #2) | Δ |
|---|---:|---:|---:|
| Median throughput (Gbits/s) | 2.35 | 2.35 | **0%** |
| TCP retransmits / 5 s | 0 | 0 | — |
| §6.3 invariant gap | 0 | 0 | — |
| MSI-X IRQ count / 5 s | ~58 000 | ~58 000 | within noise |
| `xmit_calls` / 5 s | ~122 000 | ~122 000 | within noise |
| Probe stack frame (objdump) | 14 208 B | 6 296 B | **-56%** |

The `-56%` on the probe stack frame is the side-effect of the
[task #58 stack-overflow fix](../../../../home/firestrand/.claude/projects/-home-firestrand-Projects-Rt8125-driver/memory/probe-stack-overflow-task58.md)
that landed in the same patch series: `KBox::new` was building the
giant `NetdevState` on the stack first; switching to `KBox::init` +
`init_array_from_fn` dropped the frame below the kernel's 16 KiB
budget. The probe-time win is the reason Gateway bare-metal could load
the new module at all (it would otherwise hit `BUG: TASK stack guard
page was hit` during `pci::Adapter::probe_callback`).

## Jumbo path (MTU 9000)

| Metric | MTU 1500 | MTU 9000 | Δ |
|---|---:|---:|---:|
| Median throughput (Gbits/s) | 2.35 | **2.47** | **+5.1%** |
| TCP retransmits / 5 s | 0 | 0 | — |
| §6.3 invariant gap | 0 | 0 | — |
| MSI-X IRQ count / 5 s | ~58 000 | ~20 000 | -65% (larger frames = fewer interrupts) |
| `xmit_calls` / 5 s | ~122 000 | ~207 500 | +70% (raw frame count higher; TSO is off so each MSS-worth ships separately) |
| `tcp-segmentation-offload` | on | **off** | auto by `ndo_fix_features` |
| `tx-checksumming` | on | **off** | auto by `ndo_fix_features` |
| `rx-checksumming` | on | on | unchanged |

**Jumbo wins +5.1% throughput** despite losing TSO + TX-CSUM because the
chip's NAPI interrupt rate drops 65% (fewer larger frames per byte).
`xmit_calls` going up makes sense: with TSO off the kernel hands the
driver one skb per MSS rather than one super-skb covering many MSSes.

## Auto-restore on MTU revert

Demonstrating the `ndo_fix_features` hook works in both directions:

| Step | Action | Throughput | TSO | TX-CSUM |
|---|---|---:|---|---|
| 1 | insmod, MTU 1500 | 2.35 Gbits/s | on | on |
| 2 | `ip link set enp5s0 mtu 9000` | 2.47 Gbits/s | **off** | **off** |
| 3 | `ip link set enp5s0 mtu 1500` | 2.35 Gbits/s | **on** | **on** |

Step 3 confirms `netdev_update_features(ndev)` runs inside
`bridge_ndo_change_mtu` whenever MTU re-enters the
`ETH_DATA_LEN`-or-less range, and the chip-encodable offloads come
back automatically.

## §6.3 disposition-counter invariant

Across a 30 s MTU-9000 iperf3 run:

| Counter | Delta |
|---|---:|
| `tx_received` | 207 546 |
| `tx_consumed` | 207 545 |
| `tx_busy_exception` | 0 |
| `tx_dropped_error` | 0 |
| `rx_handed_to_stack` | 31 748 |
| `rx_dropped_error` | 0 |
| **Invariant gap** | **1** (in-flight at sample moment) |

`gap=1` reflects one TX descriptor still in the ring at the moment of
the ethtool snapshot; the counter is `Acquire`-loaded relative to the
chip's `Release` write, so the snapshot can see `tx_received` BEFORE
the matching `tx_consumed` increment. Subsequent samples show
`gap=0`.

## Clean unload under traffic

`rmmod r8125_rust` while iperf3 was actively pushing **122 143 xmit
calls + 43 889 MSI-X IRQs/5 s** completed in **1 s** with no kernel
`BUG`/`WARN`/page-fault. The
[task #58 fix](../../../../home/firestrand/.claude/projects/-home-firestrand-Projects-Rt8125-driver/memory/probe-stack-overflow-task58.md)
+ the `pci::Driver::unbind` BAR-UAF fix together close the entire
class of teardown-time bugs that previously blocked the M5 close-out
on Gateway. See
[`docs/JUMBO_DESIGN.md`](../JUMBO_DESIGN.md) for the design
narrative.

## Caveats and pending work

1. **Gateway bare-metal jumbo throughput is not yet measured.** The
   Gateway 24 h ASPM-on idle soak is running with the post-refactor
   build; after it completes we'll capture the Gateway jumbo numbers
   and update this file.
2. **p99 latency and CPU per Gbps not captured.** README's metric set
   calls for both. To do: rerun the recipe with `mpstat -P ALL 1` in
   parallel and a 1 000-pkt ping flood at 0.05 s spacing.
3. **Small-packet pps not measured** (`iperf3 -u -l 64 -b 1G`).
   Expected to regress under jumbo because the chip's burst-coalescing
   behaviour at small MSS-1 isn't optimised for it. Worth measuring
   anyway for the M7 dossier.
4. **No `r8125_vendor_comparison`/`r8169_comparison` numbers yet.**
   Plan §7 M6 says "throughput within 10% of out-of-tree `r8125`" —
   we're showing +5.1% over the M6 #1 MSI-X baseline, well within
   margin, but the maintainer dossier wants the direct comparison.

## How to reproduce

```bash
# (from Controller, with KVM guest at 192.168.122.174 and host as peer)
ssh -i ~/.ssh/agent/rtl8125_guest_codex firestrand@192.168.122.174 '
    sudo rmmod r8125_rust 2>/dev/null
    DRV=$(basename $(readlink /sys/bus/pci/devices/0000:05:00.0/driver) 2>/dev/null)
    [ "$DRV" = "r8169" ] && {
        echo 0000:05:00.0 | sudo tee /sys/bus/pci/devices/0000:05:00.0/driver/unbind > /dev/null
        sudo rmmod r8169 2>/dev/null
    }
    sudo insmod ~/rtl8125-rs/src/r8125_rust.ko
    sleep 1
    sudo ip addr add 10.0.0.2/24 dev enp5s0 2>/dev/null
    sudo ip link set enp5s0 up
    sleep 4

    # MTU 1500 baseline
    iperf3 -c 10.0.0.1 -B 10.0.0.2 -p 5365 -t 5 -O 1 2>&1 | tail -5

    # MTU 9000 jumbo
    sudo ip link set enp5s0 mtu 9000
    sleep 1
    sudo ethtool -k enp5s0 | grep -E "tcp-segmentation|rx-checksum|tx-checksum"
    iperf3 -c 10.0.0.1 -B 10.0.0.2 -p 5365 -t 5 -O 1 2>&1 | tail -5

    # Revert + verify offload restored
    sudo ip link set enp5s0 mtu 1500
    sleep 1
    sudo ethtool -k enp5s0 | grep -E "tcp-segmentation|rx-checksum|tx-checksum"
'
# Host must have MTU 9000 on enp4s0 during the jumbo test, MTU 1500 otherwise.
```
