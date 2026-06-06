# BQL retry design (RX Opt #2 v2)

Status: **implemented behind `bql_mode`**. The safe default runs BQL on INTx
only (`bql_mode=1`). `netdev_sent_queue()` was isolated as unsafe on the
one-vector V2/MSI-X surface; the driver now uses MSI delivery with the legacy
ISR surface, but BQL remains INTx-only until that MSI path is separately
revalidated. See `docs/perf/bql_20260605/`.
Supersedes the failed first attempt logged in
[`RX_OPTIMIZATION_CANDIDATES.md`](RX_OPTIMIZATION_CANDIDATES.md)
("RX Opt #2 — REVERTED" section). Task #91.

The first attempt stalled TX after the very first 60 B xmit on KVM,
made the guest's management network unresponsive within seconds, and
was reverted the same day. This doc records what we learned and
specifies a retry that won't re-hit the same trap.

## Root cause restated

`netdev_reset_queue()` calls `dql_reset(&q->dql)`, which sets

```
dql->limit = dql->min_limit;
```

`dql_min_limit` defaults to **0** (`include/linux/dynamic_queue_limits.h`).
Once the queue is up, the first `__netdev_sent_queue(bytes=60)` evaluates

```
dql_avail = limit(0) - num_queued(60) + num_completed(0) = -60
```

which the BQL machinery interprets as "over budget" and which causes
the qdisc layer to set `__QUEUE_STATE_STACK_XOFF` on the queue.
Because our v1 of #2 *also* suppressed doorbells based on
`netdev_xmit_more()`, the doorbell never rang for that first packet,
no completion ever fired, `num_completed` never grew, and the queue
stayed XOFF'd forever. Classic BQL-bootstrap deadlock.

Critically, **calling `netdev_reset_queue()` is not the only way to
hit this** — any starting `dql->limit == 0` plus a doorbell-suppressing
xmit path will deadlock identically. The fix has to address the limit
itself, not just the reset call.

## Two viable retry shapes

### Approach A — Seed `dql_min_limit` before first xmit *(recommended)*

Set `dql->min_limit` to a value large enough that the first xmit
cannot make `dql_avail` go negative. A safe seed is
`ETH_DATA_LEN + max_header_room ≈ 1564` bytes (one full MTU 1500 frame
plus headroom). For MTU > 1500 the seed scales with `dev->mtu`.

```c
/* cshim helper. Call from open after netif_start_queue is set up
 * but before any xmit can fire. Safe to call multiple times (idempotent). */
void r8125_bridge_dql_seed_min_limit(struct net_device *ndev)
{
    struct netdev_queue *txq = netdev_get_tx_queue(ndev, 0);
    unsigned int seed = READ_ONCE(ndev->mtu) + VLAN_ETH_HLEN + NET_SKB_PAD;

    /* Hold the queue lock so any concurrent xmit observes the new
     * baseline before its dql_queued() probe. */
    __netif_tx_lock_bh(txq);
    netdev_queue_set_dql_min_limit(txq, seed);
    if (txq->dql.limit < seed)
        txq->dql.limit = seed;
    __netif_tx_unlock_bh(txq);
}
```

Pros: minimal cshim surface, fixes the zero-limit bootstrap explicitly,
and doesn't require a reset-time BQL state transition.

Cons: `min_limit` uses a public helper, but there is no helper for the
initial `limit` floor. The cshim still sets `txq->dql.limit` directly
under the TX queue lock to avoid the first-packet negative-availability
stall. `ci/check_bql_accounting.sh` enforces this shape.

### Approach B — Skip `netdev_reset_queue()` entirely; ramp from zero

Don't call `netdev_reset_queue()` at all. Let `dql->limit` start at
whatever value the previous run left it at (or zero on first open).
Combined with a TX path that **always rings the doorbell when
`dql_avail < 0`** — see below — the first xmit goes through, completes,
the limit grows, and BQL settles into its normal envelope.

The TX path becomes the same shape r8169 uses: `xmit_more` and BQL are coupled
inside `__netdev_sent_queue()`, which returns true when the doorbell must be
used to kick the NIC.

```rust
let xmit_more = ub::netdev_xmit_more();
let should_doorbell = if bql_active(state) {
    ub::netdev_sent_queue(ndev, bytes, xmit_more)
} else {
    !xmit_more
};
if should_doorbell {
    state.regs().tx_poll();
}
```

Pros: no `dql` struct touching from cshim — relies only on `netif_*` /
`netdev_*` public surface.

Cons: requires a second predicate helper, and "force doorbell on first
xmit" is harder to specify than "seed the limit."

### Decision

**Ship Approach A first**, with one structural simplification: we still
*don't* call `netdev_reset_queue()` at all. The seed runs once at open
(idempotent), and on close we let the queue accounting fade naturally.
That sidesteps the brittle "should we reset or not" question entirely
and matches what r8169 does — upstream `rtl_open` never calls
`netdev_reset_queue()`.

## TX path (with A in place)

```rust
// in ndo_start_xmit, after publishing the descriptor but before tx_head + doorbell:
let bytes = skb.len();  // captured before consume
let xmit_more = ub::netdev_xmit_more();
let should_doorbell = ub::netdev_sent_queue(ndev, bytes, xmit_more);
```

In the NAPI TX reap path:

```rust
// after we've drained N completed packets totalling `bytes_completed`:
ub::netdev_completed_queue(ndev, n_reaped, bytes_completed);
```

The reap path tracks completed byte counts by returning `skb->len` from
`DriverOwnedSkb::consume_tx`. That value feeds `netdev_completed_queue`
immediately in the same NAPI batch.

## ndo_open / ndo_stop boundaries

* **open**, after `netif_start_queue`:
  `bridge_dql_seed_min_limit(ndev, ETH_DATA_LEN + headroom)`. Seed
  scales with current `dev->mtu`.
* **stop**: free any in-flight TX shadows and complete their BQL bytes before
  clearing `bql_enabled`, so sent/completed accounting remains balanced across
  explicit stop and Drop-driven teardown.

## CI gates

1. **`ci/check_bql_accounting.sh`** — static gate. Static
   checks for:
   * cshim helper `r8125_bridge_dql_seed_min_limit` present
   * cshim helper `r8125_bridge_netdev_sent_queue` present
   * Rust `dql_seed_min_limit` wrapper called from
     `ndo_open` exactly once
   * `ndo_start_xmit` feeds `xmit_more` into `__netdev_sent_queue` so BQL and
     the doorbell decision cannot drift
   * `ndo_start_xmit` has no local `unsafe` block for BQL
   * completed byte accounting is used, not parked in `_bytes_completed`
   * `netdev_reset_queue` not called from either Rust or C
     (proves we're using Approach A, not v1's broken pattern)
2. **New runtime gate (guest-CI-only)** —
   `ci/check_bql_bootstrap.sh`: insmod the module, drive a single
   60 B ping, assert `tx_consumed >= 1` within 100 ms. Reproduces
   the exact failure mode v1 hit and prevents regression.

## Census + LOC

* Adds **4** safe Rust wrappers over unsafe FFI calls (`skb_len`,
  `sent_queue`, `completed_queue`, `dql_seed_min_limit`). Census 56 -> 60.
  Justification is recorded in `ci/CENSUS_JUSTIFICATIONS.md`.
* cshim helpers fit inside `netdev_bridge_offload.c` (currently
  ~300 LOC, cap 400) — no LOC cap bump expected.

## Open questions

1. **Multi-queue future-proofing.** Right now we have one TX queue.
   The seed helper takes `tx_queue_idx=0` implicitly. When we move
   to multi-queue we'll iterate over all queues.
2. **What seed value to use at MTU > 1500?** Conservative answer:
   `dev->mtu + max_header_room` where `max_header_room` is the worst
   case from `LL_RESERVED_SPACE`. At MTU 9000 that's
   `~9000 + 100 ≈ 9100`. Still under the typical `dql_max_limit` so
   BQL still throttles normally.
3. **Should the seed be a module param?** Probably not — it's an
   architectural constraint of the chip + linker, not a tuning knob.
   Document the formula and hard-code from `dev->mtu`.

## Expected gain

BQL fixes loaded latency by bounding TX ring residency so fq_codel can
protect interactive packets under a saturated bulk TX flow. Gateway results
on 2026-06-05 show p99.9 latency returning to r8169 parity over INTx; see
`docs/perf/bql_20260605/RESULTS.md`.

## Test plan post-soak

1. Implement Approach A under the CI gates above.
2. Smoke: 60 B ping must complete (`check_bql_bootstrap.sh`).
3. Sustained: 100 Mbps iperf3 for 5 min — `tx_consumed` grows at
   line rate, no STACK_XOFF transitions in tracepoint.
4. Burst: `iperf3 -P 32` to force xmit_more bursts. Measure doorbell
   count via `perf stat` on `r8125_rust_*tx_poll`.
5. 20-cycle rmmod stress at line rate.
6. 24 h KVM active soak before promoting to Gateway.

## Cross-references

* [`RX_OPTIMIZATION_CANDIDATES.md`](RX_OPTIMIZATION_CANDIDATES.md) —
  v1 post-mortem with full counter trace.
* Memory `rtl8125b-bql-reset-zero` — the lesson distilled for future
  driver work.
* `include/linux/dynamic_queue_limits.h` (kernel header) — `dql`
  struct definition; the field offsets we touch.
* r8169's open path
  (`drivers/net/ethernet/realtek/r8169_main.c:rtl_open`) — confirms
  upstream never calls `netdev_reset_queue()` at open, which is what
  Approach A copies.
