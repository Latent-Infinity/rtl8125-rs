# RTL8125B TSO — Investigation, Root Cause, and Fix

**Status (2026-05-26): TSO IS ENABLED AND WORKING.** Single-stream
TCP guest→host reaches **2.35 Gbits/sec sustained over 60 s with zero
retransmits**, matching the r8169 mainline reference driver under
identical conditions (2.33 Gbps). The driver ships with `NETIF_F_TSO |
NETIF_F_TSO6` advertised plus a chip-specific segment-count cap.

This document captures the full investigation across four debug sessions,
the empirical bisection that uncovered the root cause, and the one-line
fix that made TSO work.

## TL;DR

```c
/* src/netdev_bridge.c — required when NETIF_F_TSO is advertised */
netif_set_tso_max_size(ndev, 64000);
netif_set_tso_max_segs(ndev, 10);   /* <-- THE FIX */
```

The RTL8125B chip's LSO (Large Send Offload) engine has an undocumented
empirical limit: it reliably segments super-skbs of up to **11 MSS
segments** per offload. At 12+ segments per super-skb the chip stalls
the TX queue and drops segments wholesale. Both r8169 mainline and the
Realtek vendor driver publish a cap of 64 segments. **For this chip
revision that limit is wrong in practice.** We use 10 as a one-segment
safety margin under the measured 11→12 cliff.

The fix is two lines in `src/netdev_bridge.c::r8125_bridge_alloc`.
Nothing in the Rust side needed to change; nothing in the chip-init
sequence needed to change beyond the chip-init parity work documented in
sessions 1–3 below.

## Performance

| Direction | Throughput | Retransmits |
|---|---|---|
| g→h, TCP, MTU 1500, 60 s sustained | **2.35 Gbits/sec** | **0** |
| h→g, TCP, MTU 1500, 30 s sustained | 1.27 Gbits/sec | 0 |
| r8169 mainline reference, g→h | 2.33 Gbits/sec | — |

Single-stream throughput is now at r8169 parity. The h→g direction
remains lower because that's the RX-side path (TSO doesn't help — only
the host CPU's TX coalescing does), and our RX path hasn't been
optimized yet. KVM/VFIO/KASAN-debug guest overhead caps this around
1.2-1.3 Gbps regardless of driver.

Baseline JSONs:
- `docs/baseline/iperf3/iperf3_r8125_rust_guest2host_tcp_1500_tso.json`
- `docs/baseline/iperf3/iperf3_r8125_rust_host2guest_tcp_1500_tso.json`

## Architecture context

- **Chip**: RTL8125B (`MAC_VER_63`, XID 0x641, PCI device ID 0x8125, rev 0x05)
- **Driver**: this crate, in-kernel Rust against Linux 7.0.0 with KASAN + Rust enabled
- **Host PHY peer**: Intel I226-V at `10.0.0.1`
- **Cable**: direct Cat6 (no switch), 2.5 GBASE-T negotiated
- **Topology**: KVM guest, RTL8125B via VFIO PCI passthrough

## How the bug presented

With `NETIF_F_TSO | NETIF_F_TSO6` advertised but no `netif_set_tso_max_*`
calls (or with the r8169-published cap of 64):

```
[  5]   0.00-3.00   sec  234 MBytes   654 Mbits/sec  2760 retransmits
[  5]   3.00-6.00   sec  172 MBytes   481 Mbits/sec  1992 retransmits
[  5]   6.00-9.00   sec  151 MBytes   423 Mbits/sec  1942 retransmits
[  5]   9.00-12.00  sec  0   bits/sec — TX queue stalled
iperf3: error - control socket has closed unexpectedly
```

Wire frames captured with `tcpdump -i enp9s0 -vvv` (GRO off) showed
SOME segments arriving correctly — MSS-sized, valid TCP checksums,
sequential sequence numbers — but ~5-7% of segments per super-skb
simply never appeared on the wire. TCP retransmits piled up,
congestion window collapsed, and eventually the TX queue stalled.

## Root cause (the actual bug)

The kernel hands TSO-enabled drivers super-skbs sized by the system-wide
`gso_max_segs` and `gso_max_size`. Without `netif_set_tso_max_segs`,
these default to ~65535/65535 — essentially unbounded.

The RTL8125B's LSO engine accepts the super-skb's descriptor but
**cannot reliably segment payloads of more than 11 MSS-worth of TCP
data per offload**. When it receives a super-skb that would need 12+
MSS segments, it:
1. Emits the first few segments correctly (the ones tcpdump saw)
2. Stalls or drops the remainder silently
3. Eventually wedges its TX FIFO entirely

This isn't documented in any datasheet or driver source we have access
to. The Realtek vendor driver publishes `NIC_MAX_PHYS_BUF_COUNT_LSO2 =
64`; r8169 mainline publishes `RTL_GSO_MAX_SEGS_V2 = 64`. Both are too
high for this chip revision (`MAC_VER_63`). Either the upstream
authors test on a different stepping, or the limit isn't tickled
under their test loads (which run on real hardware, not KVM/VFIO/
KASAN-debug).

## The bisection (how we found it)

Session 4 (2026-05-26 PM) bisected `netif_set_tso_max_segs` across
the full range. iperf3 with each setting, 5-second runs:

| `tso_max_segs` | Bitrate | Retransmits | Status |
|---|---:|---:|---|
| 2 | 1.19 Gbps | 0 | ✓ |
| 4 | 2.24 Gbps | 0 | ✓ |
| 8 | 2.35 Gbps | 0 | ✓ line rate |
| 9 | 2.34 Gbps | 0 | ✓ |
| 10 | 2.35 Gbps | 0 | ✓ |
| 11 | 2.35 Gbps | 0 | ✓ **last working value** |
| 12 | — | — | ✗ TX queue hangs immediately |
| 13 | — | — | ✗ TX queue hangs immediately |
| 14 | 696 Mbps | 4962 | ✗ partial collapse |
| 15 | — | — | ✗ TX queue hangs |
| 16 | 65.5 Mbps | 532 | ✗ near-complete collapse |
| 32, 64 | — | — | ✗ instant stall |

The 11→12 threshold is reproducible and abrupt. We ship `max_segs=10`
for a one-segment safety margin. Line rate is already saturated at 8
segments per super-skb so the cap does not bottleneck throughput.

## What we tried that did NOT help

These items were explored across sessions 1–3 before the bisection
identified the true cause. **None of them moved the TSO retransmit
needle**, though several improved baseline stability and remain in
tree because they match r8169 mainline + Realtek vendor behavior and
benefit the SG+CSUM path.

### Session 1 (2026-05-25)
- Memory ordering: `core::sync::atomic::fence(Ordering::Release)`
  between fragment writes and FirstFrag commit. No change.
- Field-by-field descriptor writes (`addr → opts2 → wmb → opts1`)
  applied to ALL descriptors. **Regressed SG+CSUM.** Reverted.

### Session 2 (2026-05-26 AM)
Added every chip-init register write from r8169
`rtl_hw_start_8125_common` + `rtl_hw_aspm_clkreq_enable(false)` we
hadn't ported yet (all in `src/hw.rs::hw_start_8125b`, wrapped in
Cfg9346 unlock/lock so the writes stick):

| Write | r8169 source | Purpose |
|---|---|---|
| `Cfg9346` unlock/lock | wraps `rtl_hw_start` | makes Config* writes take effect |
| `Config3 &= ~Rdy_to_L23` | `rtl_pcie_state_l2l3_disable` | PCI L2/L3 reset workaround |
| `Config5 &= ~ASPM_en` | `rtl_hw_aspm_clkreq_enable(false)` | keeps PCIe out of L1 |
| `MMIO 0x382 = 0x221b` | top of `rtl_hw_start_8125_common` | anonymous tuning |
| `RSS_CTRL_8125 = 0` | `rtl_hw_start_8125_common` | single-queue RX |
| `Q_NUM_CTRL_8125 = 0` | `rtl_hw_start_8125_common` | single-queue mode |
| OCP `0xC0AC |= 0x1F80` | `rtl_enable_exit_l1` | L1-exit triggers |

**Kept in tree** — these are correct chip-init parity work and improved
the SG+CSUM baseline from 945 to 960 Mbps even before TSO. They did
NOT fix the TSO retransmit issue alone.

### Session 3 (2026-05-26 PM, first half)
- `netif_set_tso_max_size(64000)` + `netif_set_tso_max_segs(64)` —
  matching r8169 + Realtek vendor numbers. NOT a fix at 64; the bug
  reproduces just the same. (Session 4 revealed that **the limit was
  the right idea but the value of 64 was too high**.)
- Head-only two-phase descriptor commit (`desc_commit_head_tx` in
  `src/unsafe_boundary.rs`, used only at the FirstFrag write in
  `ndo_start_xmit`). Mirrored r8169's
  `txd_first->opts1 |= cpu_to_le32(DescOwn | FirstFrag)` pattern at
  `r8169_main.c:4595`. **A/B-tested against whole-struct
  `desc_write`** after the `max_segs=10` cap landed: the two-phase
  variant and the whole-struct variant both deliver 2.35 Gbps with
  zero retransmits. The two-phase commit is therefore NOT required;
  reverted to keep the code surface minimal.

### Session 4 (2026-05-26 PM, second half) — the breakthrough
Cross-checked C sources rigorously and noticed:
- r8169 mainline calls `netif_set_tso_max_size` + `netif_set_tso_max_segs`
- Our bridge does not
- BUT setting them to the r8169 values of 64000/64 did NOT fix it
- Tried `max_segs=2` as a diagnostic to bisect "does the chip fail
  proportionally with segment count" — and **it worked perfectly**

Bisected from 2 to 64 → discovered the 11→12 cliff → shipped
`max_segs=10` → done.

## What's in tree as a result

```c
/* src/netdev_bridge.c::r8125_bridge_alloc */
ndev->hw_features = NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM |
                    NETIF_F_RXCSUM | NETIF_F_SG |
                    NETIF_F_TSO | NETIF_F_TSO6;
ndev->features = ndev->hw_features;
ndev->vlan_features = NETIF_F_IP_CSUM | NETIF_F_IPV6_CSUM |
                      NETIF_F_SG | NETIF_F_TSO | NETIF_F_TSO6;

netif_set_tso_max_size(ndev, 64000);
netif_set_tso_max_segs(ndev, 10);
```

All Session 2 chip-init parity writes also remain in tree. The Session
1 / Session 3 field-ordered descriptor write code was removed after
the A/B test proved it unnecessary.

## Lessons

1. **Upstream-published constants are not always right for every
   chip stepping.** r8169 mainline and Realtek vendor both publish
   64 as the TSO segment cap. The validated MS-A2 8125B (XID 0x641,
   `MAC_VER_63`) reproducibly fails at 12. Either we have a stepping
   that upstream doesn't test on, or KVM/VFIO/KASAN-debug exposes the
   bug they don't see, or both. Be willing to deviate from upstream
   constants when measurements say to.

2. **Wire-correct frames + retransmits = the chip is dropping segments
   it claimed to emit.** When tcpdump shows valid MSS-sized segments
   on the wire but TCP retransmits keep climbing, the chip is
   processing the descriptor but failing to actually emit some
   fraction of the segmented frames. This is the LSO engine
   misbehaving, not a CSUM / descriptor / DMA / cache problem. Bisect
   by load (segments per super-skb), not by code.

3. **Bisection beats theory.** Sessions 1–3 produced multiple
   theoretically-motivated changes (memory ordering, two-phase
   descriptor commit, chip-init parity) and none of them moved the
   needle for TSO. Session 4's bisection found the answer in 30
   minutes. The bisection should have come first.

4. **Document negative results as carefully as positive ones.** The
   chip-init parity work (Session 2) and the two-phase descriptor
   write hypothesis (Session 3) were both reasonable, well-motivated
   investigations. They turned out to be wrong for THIS bug but
   they're documented here so a future maintainer doesn't repeat
   them.

## Cross-references

- `src/netdev_bridge.c` — feature advertisement + `netif_set_tso_max_*` calls
- `src/netdev.rs::ndo_start_xmit` — TX path (whole-struct descriptor commit)
- `src/netdev_bridge_offload.c::r8125_bridge_skb_tso_setup` — TSO opts encoding
- `src/hw.rs::hw_start_8125b` — Session 2 chip-init parity writes
- `references/linux-mainline/drivers/net/ethernet/realtek/r8169_main.c`
  lines 4321-4625 + 5732-5735 — r8169 TX path + feature setup
- `references/realtek-r8125-official/src/r8125_n.c` lines 17498-17505 —
  Realtek vendor TSO + LSO size constants
- `docs/baseline/m4_perf_tso_debug_session.txt` — Session 1 log
- `docs/baseline/m4_perf_tso_debug_session2.txt` — Sessions 2-4 log
- `docs/baseline/iperf3/iperf3_r8125_rust_guest2host_tcp_1500_tso.json` —
  validated 2.35 Gbps TSO baseline

## Driver capability matrix today

| Feature | Status | Throughput (g→h, MTU 1500) |
|---|---|---|
| Plain (no offload, no SG) | works | ~700 Mbps (kernel CPU-bound) |
| HW checksum offload (CSUM) | works | ~850 Mbps |
| Scatter-gather (SG) | works | 960 Mbps, 0 retransmits |
| **CSUM + SG + TSO (shipping)** | **works** | **2.35 Gbps, 0 retransmits** |
| r8169 reference (same chip) | works | 2.33 Gbps |

The driver is now at single-stream throughput parity with r8169 mainline.
