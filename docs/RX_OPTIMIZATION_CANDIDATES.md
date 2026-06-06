# RX hot-path optimization candidates (post-#79)

**Status (2026-05-30):** Candidates **A**, **B**, **C**, **F**, **G**,
**L**, **M**, **#1** (TX/RX dma_wmb), **#4** (irq_pin_cpu policy)
SHIPPED on KVM. Candidate **#2** (BQL + xmit_more) REVERTED
2026-05-30 — see "RX Opt #2 — REVERTED" section below for the
dql_min_limit=0 bootstrap-stall root cause. Candidate **H**
skipped (LLVM likely elides the bounds check). The decision tree
at the bottom of this file is still active for the Gateway
re-measurement (task #80) outcome — it determines whether more
aggressive optimizations (I, J, D, K, E) become warranted.

KVM measurement after A + B both landed:

| Direction | MTU | r8169 | Pre-RX-work | Post-A+B | Δ vs pre-RX |
|---|---|---:|---:|---:|---:|
| g → h | 1500 | 2.328 | 2.343 | 2.333 ± 0.025 | within noise |
| g → h | 9000 | 2.373 | 2.474 | 2.473 | within noise |
| h → g | 1500 | 2.325 | 1.205 | 1.413 ± 0.009 | **+17.3%** (from `napi_alloc_skb` fix; A+B+F+G no further KVM win) |
| h → g | 9000 | 2.472 | 2.466 | 2.472 | within noise |

The +17.8% h→g 1500 gain came entirely from the `napi_alloc_skb` +
`__skb_put_data` fix that landed earlier (commit c8f0ef0). A and B
are architecturally cleaner but produce no measurable additional
KVM win because **KASAN + lockdep dominate ~40% of cycles on the
KVM debug+Rust kernel** (perf record snapshot in §"What we did"
below). The FFI-reduction benefit of A + B is expected to surface
on Gateway bare-metal (no KASAN), where the cshim's tighter
inlining + 1 vs 7 boundary crossings per packet should matter.

Other A + B wins that are not perf-numbers:

- Unsafe census 54 → **47** after A+B (6 fewer Rust unsafe wrappers;
  obsolete extern declarations removed too).
- One fewer Rust-side hot-path symbol (`account_rx`) — A.
- Six fewer Rust-side RX helper wrappers (`build_rx`, `deliver_rx`,
  `rx_drop_error`, `rx_csum_set`, `rx_sync_for_*`, `bridge_napi`) — B.
- The now-dead C shim RX helper symbols/prototypes were removed during
  review instead of kept as private ABI.
- The cshim `r8125_bridge_rx_one_packet` mirrors r8169's `rtl_rx`
  inline-everything shape exactly.

## Hardware offload state — VLAN vs RSS/RXHASH

2026-06-06: VLAN hardware acceleration is wired into the current RX/TX
descriptor path. TX encodes the VLAN TCI into descriptor `opts2`, and RX
passes descriptor `opts2` through `__vlan_hwaccel_put_tag` after enabling the
RTL8125 RxConfig VLAN strip bits.

RSS/RXHASH is intentionally **not** advertised yet. The current Rust RX ring
uses the legacy 16-byte descriptor shape (`opts1`, `opts2`, `addr`), while
Realtek's RSS hash result and packet-type metadata live in RxDescV3/V4 fields.
Enabling `NETIF_F_RXHASH` before migrating the descriptor parser and adding a
multi-RX-ring topology would give the stack invalid hash promises. The runtime
C-vs-Rust validation harness and the checklist for enabling RXHASH are in
[`perf/HW_OFFLOAD_VALIDATE.md`](perf/HW_OFFLOAD_VALIDATE.md).

## FFI crossings per packet — the structural finding

Our `napi::process_rx_completions` hot-path makes **7 FFI
crossings per RX packet** (each is a Rust→cshim or Rust→inline-
unsafe function call/return):

```rust
let desc = ub::desc_read(state.rx.desc, rx_tail);     // 1: inlined
ub::rx_sync_for_cpu(&state.pdev, slot.dma, len);      // 2: FFI
DriverOwnedSkb::build_rx(ndev, buf_ptr, len)          // 3: FFI (napi_alloc_skb path)
skb.rx_csum_set(desc.opts1);                          // 4: FFI
let napi = ub::bridge_napi(ndev);                     // 5: FFI (one MOV)
skb.deliver_rx(napi);                                 // 6: FFI (napi_gro_receive + counter)
ub::bridge_account_rx(ndev, len as u32);              // 7: FFI (READ_ONCE/WRITE_ONCE)
ub::rx_sync_for_device(&state.pdev, slot.dma);        // 8: FFI
ub::desc_write(state.rx.desc, rx_tail, …);            // inlined
```

r8169's `rtl_rx`
(`references/ubuntu-kernel-7.0.0-15/drivers/net/ethernet/realtek/r8169_main.c:4803`)
does the equivalent
**inside one C function** — zero FFI crossings, full compiler
visibility for inlining and reordering.

At 166 K pps (MTU 1500 line rate) × 7 FFI crossings = **>1.16 M
boundary crosses/sec**. Each is a call/ret pair, register save,
typically a cache touch on the cshim function's instruction
cache line. On modern x86 that's tens of nanoseconds total per
packet — at line rate that's ~5-10% of the cycle budget.

## Candidate A — Fold `account_rx` into `deliver_rx` ★★★★★

**Effort: 15 minutes. Risk: minimal. Expected gain: small but free.**

`bridge_skb_deliver_rx` already does
`this_cpu_inc(*b->rx_handed_to_stack)` plus `napi_gro_receive`.
`bridge_account_rx` does an additional `WRITE_ONCE`+1 on
`ndev->stats.rx_packets/_bytes`.

Both are called for every successful RX packet. We can fold
`account_rx`'s body into `deliver_rx`, save one FFI call per
packet, and end up with one fewer cshim symbol exported. The
Rust call to `bridge_account_rx` simply goes away.

Even better — replace the `WRITE_ONCE` pair with
`dev_sw_netstats_rx_add(dev, pkt_size)` which uses the kernel's
per-CPU sharded netstats. r8169 does this in `rtl_rx`
(`r8169_main.c:4881`). Cache-line contention disappears,
counter semantics stay identical.

Implementation shape: capture `skb->len` before `napi_gro_receive`,
increment `rx_handed_to_stack`, and call
`dev_sw_netstats_rx_add(ndev, len)` in the same C helper. Then
`bridge_account_rx` becomes unused; delete it and remove the Rust-side
call from `process_rx_completions`.

Final A+B code puts the folded RX stats update in
`r8125_bridge_rx_one_packet`, next to `napi_gro_receive`.

**Side effects:** counter is now per-CPU; reader-side ethtool
already walks per-CPU in `bridge_counter_sum`, no change needed.

## Candidate B — Super-call: `bridge_rx_one_packet` ★★★★

**Effort: 1-2 hours. Risk: medium (touches Rust↔C contract). Expected gain: 10-20% RX path.**

Replace the 5-call sequence
{`rx_sync_for_cpu` + `build_rx` + `rx_csum_set` + `deliver_rx` +
`rx_sync_for_device`} with one cshim function that takes the
descriptor slot's DMA address + virtual address + length +
opts1, and does everything internally.

```c
void r8125_bridge_rx_one_packet(struct net_device *ndev,
                                dma_addr_t dma, const void *buf,
                                size_t len, u32 opts1)
{
    struct r8125_bridge *b = netdev_priv(ndev);
    struct device *d = &b->pdev->dev;
    struct sk_buff *skb;
    unsigned int rx_len;

    dma_sync_single_for_cpu(d, dma, len, DMA_FROM_DEVICE);
    skb = napi_alloc_skb(&b->napi, len + NET_IP_ALIGN);
    if (unlikely(!skb)) {
        this_cpu_inc(*b->rx_dropped_error);
        dma_sync_single_for_device(d, dma, R8125_RX_JUMBO_BUF_SIZE,
                                   DMA_FROM_DEVICE);
        return;
    }
    skb_reserve(skb, NET_IP_ALIGN);
    prefetch(buf);
    __skb_put_data(skb, buf, len);
    skb->protocol = eth_type_trans(skb, ndev);
    r8125_bridge_skb_rx_csum_set(skb, opts1);
    rx_len = skb->len;
    this_cpu_inc(*b->rx_handed_to_stack);
    dev_sw_netstats_rx_add(ndev, rx_len);
    napi_gro_receive(&b->napi, skb);
    dma_sync_single_for_device(d, dma, R8125_RX_JUMBO_BUF_SIZE,
                               DMA_FROM_DEVICE);
}
```

Rust side:

```rust
ub::bridge_rx_one_packet(ndev, slot.dma, slot.cpu.cast_const(), len, desc.opts1);
```

That collapses 5 FFI calls → 1 FFI call per RX packet, cuts 80%
of the boundary cost. The cshim hot function inlines all the
helpers it calls (modern gcc does, with PGO it definitely
will).

**Risk areas:**
- Need a new exported symbol; CI gate `check_skb_ownership.sh`
  is satisfied because the skb never crosses back to Rust.
- Replaces `DriverOwnedSkb::build_rx` and `deliver_rx` for this
  path. The structural-CI gate now checks the super-call body directly.
- Keep the super-call in `netdev_bridge_rx_pool.c`, where the RX
  streaming-DMA sync contract already lives. After dead helper pruning,
  both cshim TUs stay under their original caps.

**Recommendation:** if Gateway shows residual gap, this is the
biggest single-step win. Pair with Candidate A as one commit.

## Candidate C — `dma_rmb()` barrier after OWN check ✅ shipped 2026-05-30

**Effort: 5 minutes. Risk: zero. Expected gain: zero on x86, correctness on weak-ordering archs.**

r8169 has at `r8169_main.c:4824`:

```c
status = le32_to_cpu(READ_ONCE(desc->opts1));
if (status & DescOwn)
    break;

/* This barrier is needed to keep us from reading
 * any other fields out of the Rx descriptor until
 * we know the status of DescOwn
 */
dma_rmb();
```

Our `process_rx_completions` reads `desc.opts1` to check OWN,
then reads `desc.addr` (in the slot lookup, but the chip might
also write back fields like length). Without a `dma_rmb()` the
CPU is free to speculatively load `desc.addr` before the OWN
check, which could read stale bytes.

On x86 (TSO memory model) loads are not reordered with other
loads, so this is purely a portability fix for ARM64/RISC-V.

Implemented as `unsafe_boundary::dma_rmb()`, backed by the cshim's
`r8125_bridge_dma_rmb()` wrapper around Linux `dma_rmb()`. The static
RX gate now requires it between the OWN check and descriptor length read.

## Candidate D — `napi_gro_frags` zero-copy ★★

**Effort: 4-8 hours. Risk: high (RX-pool refactor). Expected gain: 20-40% RX, but only above ~500 K pps.**

Instead of `napi_alloc_skb` + copy, build the skb to wrap the
chip's RX buffer page directly using `napi_get_frags(napi)` +
`__skb_fill_page_desc_noacc` + `napi_gro_frags(napi)`. The skb
references the page; the RX pool refill allocates a new page
for the slot.

Used by mlx5, i40e, ice. Not used by r8169 (because Realtek
chose the copy-path for their family).

**Why we're behind it for now:**
- Our RX pool is jumbo-sized (`alloc_pages(order=2)` for 16 KiB
  per slot). Zero-copy with 16 KiB pages "wastes" 14.5 KiB per
  small packet because the page can't be reused until the
  skb is freed.
- The pool refactor to dual-size (small order for MTU 1500,
  large order for MTU 9000) doubles RX-pool state complexity.
- Real win shows up beyond 500 K pps; we're at 166 K pps line
  rate. Diminishing returns.

If we adopt this, it's a milestone-scale piece of work, probably
M6++ or beyond.

## Candidate E — Compiler LTO across cshim + Rust ★

**Effort: ?. Risk: ?. Expected gain: would eliminate boundary cost.**

If the kernel-Rust toolchain supports cross-language LTO (Link-
Time Optimization), the FFI boundary calls become inlineable and
candidate B becomes moot.

Status: kernel-Rust does NOT support cross-language LTO as of
7.1-rc5. Tracked in the rust-for-linux backlog. If/when it
lands, our entire FFI boundary cost evaporates — not a project
deliverable, but worth watching.

## Ranking summary

| # | Candidate | Effort | Risk | Expected gain | Recommend |
|---|---|---|---|---|---|
| A | Fold `account_rx` into `deliver_rx` (+ `dev_sw_netstats`) | 15 min | minimal | 1-2% | **always do** |
| B | Super-call `bridge_rx_one_packet` | 1-2 h | medium | 10-20% | **if Gateway gap > 10%** |
| C | `dma_rmb()` after OWN | 5 min | zero | 0% x86 / correctness ARM | **always do** before any non-x86 deployment |
| D | `napi_gro_frags` zero-copy | 4-8 h | high | 20-40% (only > 500K pps) | defer to M6++ |
| E | Cross-language LTO | n/a | n/a | eliminates boundary | watch upstream |

## Decision tree for tomorrow's Gateway numbers

```
Gateway h→g 1500 TCP measured:

  ≥ 2.1 Gbps (within 10% of r8169):
    Done. Ship as-is. Optionally do Candidate A as free win.
    Close task #80.

  1.6 – 2.1 Gbps (10-30% gap):
    Do Candidate A + Candidate B. Re-measure.

  1.0 – 1.6 Gbps (30-50% gap):
    Do A + B + C. Profile with perf record on Gateway (no KASAN).
    If still over 20% gap, plan Candidate D for M6++.

  < 1.0 Gbps:
    Something's wrong. Suspect a chip-side issue (RX coalescing
    register, MSI-X vector affinity, IRQ rate). Open a new task
    rather than assuming it's RX-path code.
```

## Cross-references

- [`RUST_STANDARDS.md`](RUST_STANDARDS.md) hot-path and C-shim contracts
- r8169 reference: `references/ubuntu-kernel-7.0.0-15/drivers/net/ethernet/realtek/r8169_main.c:4803` (RX path)

## Candidate F — Hoist `ndev` load out of NAPI loop ✅ shipped 2026-05-30

In `napi::process_rx_completions`, moved
`state.ndev.load(Ordering::Acquire)` from inside the `while` loop
to the function-prologue. `ndev` is invariant for the entire poll
call; one Acquire load saved per packet.

Measurement: within noise on KVM (as expected — KASAN dominates).

## Candidate G — `dev_sw_netstats_rx_add` + per-CPU TSTATS ✅ shipped 2026-05-30

Set `ndev->pcpu_stat_type = NETDEV_PCPU_STAT_TSTATS` at
`bridge_alloc`. Replaced the WRITE_ONCE rx_packets/rx_bytes and
tx_packets/tx_bytes pairs with `dev_sw_netstats_{rx,tx}_add`. Same
idiom as r8169 (`r8169_main.c:5828`).

- `bridge_rx_one_packet` now uses `dev_sw_netstats_rx_add(ndev, rx_len)`.
- `bridge_account_tx` now uses `dev_sw_netstats_tx_add(ndev, 1, bytes)`.
- The kernel's `dev_get_tstats64` sums per-CPU at read time
  automatically (set on `pcpu_stat_type = TSTATS`).

Validation: `ip -s link show enp5s0` RX packet/byte counts
correctly match `rx_handed_to_stack` after the change (4,301,800
both sides). No iperf3 regression, jumbo intact, 20× stress clean.

## Candidate H — `get_unchecked` on `rx_slot` ⏸ skipped 2026-05-30

After analysis: `rx_slot(rx_tail)` is called with `rx_tail` that's
provably in `[0, RING_LEN)` (always `% RING_LEN`). LLVM's value
range propagation typically elides bounds checks under these
conditions. Adding `get_unchecked` would require either:

1. Exposing `RxRingState` internals through `unsafe_boundary.rs`, or
2. Adding `unsafe` to `netdev.rs` which carries `#![deny(unsafe_code)]`.

Both options cost real architectural friction for a gain that may
be zero (if LLVM is already eliding) or negligible (one branch on
a predicted path). Decision: skip H. Reconsider if Gateway profile
shows `rx_slot` as a measurable hot spot.

## Updated decision tree post-A+B+F+G

KVM measurement after all four shipped:

```
h→g MTU 1500: 1.413 Gbps (was 1.205 pre-fix, 1.443 napi_alloc_skb-only)
g→h MTU 1500: 2.333 Gbps (held throughout)
h→g MTU 9000: 2.472 Gbps (parity with r8169)
g→h MTU 9000: 2.473 Gbps (parity with r8169)
```

For Gateway tomorrow:

```
Gateway h→g MTU 1500 TCP:

  ≥ 2.1 Gbps (within 10% of r8169):
    DONE. Close task #80. Skip I/J/K.

  1.8 – 2.1 Gbps:
    Add I (skb list batching). Re-measure.

  1.5 – 1.8 Gbps:
    Add I + J (HW coalesce tuning). Profile on Gateway.

  < 1.5 Gbps:
    Likely chip-side problem (coalesce settings, IRQ affinity).
    Profile heavily. Consider K (page_pool) if alloc/map shows up.
```

## Post-A+B+F+G+L+M re-profile (Tier B, 2026-05-30 ~15:00 UTC)

Re-ran `perf record -a -g -F 999 -- sleep 15` on the KVM during
the active soak (100 Mbps sustained TCP, A+B+F+G+L+M build, all
RX-optimization candidates landed). Compared against the pre-
optimization profile from §"What we did":

| Symbol | Pre | Post | Δ |
|---|---:|---:|---:|
| `__pv_queued_spin_lock_slowpath` | 4.90% | <0.5% | **-4.4%** |
| `unwind_next_frame` | 5.31% | 1.37% | -3.94% |
| `stack_trace_consume_entry` | 6.20% | 2.87% | -3.33% |
| `update_stack_state` | 5.55% | 2.73% | -2.82% |
| `do_csum` | 2.15% | (out of top 25) | -2.15% |
| `stack_depot_save_flags` | 2.31% | 1.04% | -1.27% |
| `__lock_acquire` | 11.42% | 10.33% | -1.09% |
| **Top-14 KASAN+lockdep sum** | **53.1%** | **39.8%** | **-13.3%** |

### Three findings

1. **`__pv_queued_spin_lock_slowpath` collapsed (4.9% → <0.5%).**
   Candidate G's per-CPU TSTATS removed the
   `ndev->stats.{rx,tx}_packets` cache-line contention. NAPI poll
   on one core no longer bounces a line with `ifconfig` /
   `softnet` readers on others. This is the clearest single signal
   that G shipped despite being invisible on KVM throughput.

2. **KASAN+lockdep overhead dropped 13 percentage points.** Not
   because KASAN got faster — because the driver's hot path
   generates fewer events for stack_trace_consume_entry and
   unwind_next_frame to walk. Candidate B (5 FFI → 1) means 4×
   fewer call/return frames per packet. Candidate F's hoisted
   `ndev` load is one fewer atomic for `__lock_acquire` to
   record. Translates to a similar real-world gain on Gateway
   (where KASAN doesn't run at all).

3. **`do_csum` (TCP/UDP software checksum) fell out of the top 25.**
   Previously 2.15%. Either the chip's RX-checksum offload is now
   reliably eating those cycles, or `dev_sw_netstats_rx_add` (G)
   removed enough surrounding overhead that csum dropped relative.
   Either way, the path is healthier.

### `r8125_rust` symbols are not in the top 25

The driver hot path is now below the KVM instrumentation noise
floor. **We have nothing more to optimize on KVM** — anything we
do is speculative without bare-metal data. Decision: STOP RX-opt
work on KVM, gate next candidates on Gateway measurements per the
decision tree above.

### Sole open issue: `rx_missed`

ethtool reports `rx_missed = 51107` during the 15-second window.
The chip RX-overran ~51K times in 15s = ~3.4K misses/sec at
100 Mbps. Likely the host can't drain RX fast enough under KASAN
instrumentation. **Expected to drop to near-zero on Gateway**
(no KASAN). If it doesn't, that's the canonical signal to do
Candidate J's "chip RX coalescing → 0" tuning to widen the
chip's RX FIFO drain window.

## Candidate J — Redirected: latency-first chip-side coalescing (instead of efficiency)

Per operator direction 2026-05-30, J is reframed for this project:
**we don't tune coalesce for CPU efficiency — we minimize coalesce
to maintain low and predictable tail latency.** The heterogeneous-
load-balancer use case needs the chip to interrupt the host on
every packet (or close to it) so the LB sees an honest signal of
device capacity and doesn't introduce hidden delay.

Target chip programming when J is exercised:
- RTL8125B `INT_MITI` table (offset 0xA00 for queue/vector 0) — sweep low
  RX/TX timer values while keeping `INT_CFG0_TIMEOUT0_BYPASS_8125` and
  `INT_CFG0_MITIGATION_BYPASS_8125` cleared. The old 8168/8169 `IntrMitigate`
  address at 0xE2 is RX/TX FIFO status on RTL8125-family chips, not the
  coalescing control path.
- `CPlusCmd[14:13]` (CMTR enable in older references) — leave cleared /
  explicitly clear.

Trade: higher CPU at line rate, lower tail latency + lower jitter.

Will be measured on Gateway alongside the rest of Tier 2 perf.

## Candidate L — IRQ affinity hint at probe ✅ shipped 2026-05-30

`r8125_bridge_irq_pin_cpu(irq, cpu)` cshim helper added; called from
probe immediately after `pci_irq_vector` returns the chip's IRQ
number. Pins to CPU 0 by default; operator can override via
`/proc/irq/N/smp_affinity`.

**KVM verification:**
- dmesg: `RTL8125 IRQ 62 affinity hint set to CPU 0`
- `/proc/irq/62/affinity_hint = 01`
- `/proc/irq/62/smp_affinity = 01` (irqbalance respected)

## Candidate M — `tx_queue_len` 1000 → 256 ✅ shipped 2026-05-30

`ndev->tx_queue_len = 256` at `bridge_alloc`. At 2.35 Gbps line
rate this caps worst-case TX queueing delay at ~870 us vs the
1000-deep default's ~3.4 ms bufferbloat window.

**KVM verification:** `ip link show enp5s0` shows `qlen 256`.

## L + M measured latency win (KVM)

Under sustained 100 Mbps load with parallel 500-sample ping flood:

| Metric | Pre-L+M (A+B+F+G) | Post-L+M | Δ |
|---|---:|---:|---:|
| Min RTT | 0.093 ms | 0.104 ms | within noise |
| Avg RTT | 0.212 ms | 0.207 ms | -2% |
| **Max RTT** | **1.351 ms** | **0.979 ms** | **-27.5%** |
| Stddev | 0.097 ms | 0.111 ms | within noise |

The 27% max-RTT drop is the first non-noise latency improvement
measurable on KVM since the original `napi_alloc_skb` fix.
Throughput unchanged (2.338 g→h, 1.400 h→g, jumbo paths intact).
20× rmmod-under-traffic stress clean.

This validates the bufferbloat-reduction (M) + IRQ-affinity-
stability (L) combination as a real latency win independent of
KASAN dominance — exactly what the heterogeneous-LB use case
demands. Expected to compound on Gateway bare-metal where
softirq cross-CPU migration costs are higher.

## RX Opt #2 — BQL + `netdev_xmit_more()` ⛔ REVERTED 2026-05-30

Shipped briefly, then reverted the same day after observing a
hard TX stall on KVM.

**Symptom:** after `rmmod` + `insmod` of the new build, the first
ping (`bytes=60`) returned RX traffic but TX completions never
happened. `tx_received` climbed to 1 then froze; `tx_consumed`
stayed at 0. Management network in the KVM guest became
unresponsive within seconds.

**Bisection:** the only path-altering change in #2 vs the prior
#1+#4 build was the BQL pair (`netdev_sent_queue` / `xmit_more`
gated doorbell) and `netdev_reset_queue()` at ndo_open/ndo_stop.

**Root cause:** `netdev_reset_queue()` sets
`dql->limit = dql->min_limit`. `dql_min_limit` defaults to **0**.
So the very first xmit with `skb->len=60` produces
`dql_avail = limit - inflight - bytes = 0 - 0 - 60 = -60`,
which `dql_queued()` interprets as "over budget" and sets
`__QUEUE_STATE_STACK_XOFF` on the queue. Our doorbell-suppression
gate then declined to ring (because `xmit_more` saw the queue
already stopped), so no completions ever arrived to grow the
limit back up. Classic BQL-bootstrap deadlock.

**Re-do plan (deferred):** before reactivating #2 we must either
(a) seed `dql_min_limit` to at least `MTU + max_header_room` so
the first xmit doesn't immediately fence the queue, **or** (b)
skip `netdev_reset_queue()` at open and let BQL ramp organically
from the first ack instead. Either approach needs a chip-up
smoke that proves `tx_consumed` advances on the very first
xmit before we re-enable the path.

**State after review:** the failed BQL/xmit_more implementation is
fully out of tree. No disabled gate, dead FFI wrappers, or unused
`consume_tx` byte-return path remain. Future work should reintroduce
the smallest possible surface behind a fresh failing gate and a first-
packet TX smoke test.

This finding is also a small lesson for future BQL adopters: any
out-of-tree driver that calls `netdev_reset_queue()` at probe or
open *must* seed `dql_min_limit` first or skip the reset.
