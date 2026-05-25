# `cshim/` — the C↔Rust netdev bridge

**Status: M4.** The bridge rationale and migration plan live here. The actual
kbuild-visible implementation lives in `../src/netdev_bridge.c` and the
canonical ownership contract lives in `../src/netdev_bridge.h`, because the
kernel composite-module pattern requires C and Rust objects in the same `M=`
directory.

## Why a C shim exists at all

As of Q1–Q2 2026, Rust-for-Linux has mainline-sufficient PCI / DMA / MMIO /
allocation / module-lifecycle abstractions, but **`net_device` registration,
`net_device_ops`, `sk_buff` ownership wrappers, and NAPI integration are
RFC-level only** (plan §5.2). A new driver cannot depend on them as a stable
target. So:

- Everything from PCI probe through descriptor-ring ownership is **Rust**
  (`../src/`).
- `net_device` / NAPI / `sk_buff` glue is a **deliberately minimal C bridge**
  here, reviewable in one sitting.

## Scope freeze (plan §16 Q3)

- `../src/netdev_bridge.c` — **hard cap 400 LOC**, reviewed line-by-line.
- `../src/netdev_bridge.h` — the **canonical `sk_buff` ownership contract** (plan §6.3).
  Every function carries explicit pre/post-conditions on skb ownership,
  including the TX flow-control invariants (`netif_tx_stop_queue` before the
  ring fills; `netif_tx_wake_queue` from completion; `NETDEV_TX_BUSY` is a
  counted exception, not a backpressure path).

## The contract is the deliverable, not the source

`../src/netdev_bridge.h` is the contract. Any change to it requires updating
`../src/skb.rs` in the **same commit**. Reviewers reject patches that touch one
without the other (plan §6.3).

## Migration plan

As upstream Rust netdev abstractions land, this bridge **shrinks and eventually
disappears**. Tracking the relevant Rust-for-Linux work and lore.kernel.org RFC
threads is part of M7 (plan §5.3, §7 M7, §14). The migration is a refactor
against the §6.3 contract, not a rewrite — this is the explicit mitigation for
the corresponding High risk in plan §13.
