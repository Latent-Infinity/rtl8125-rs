# M7 prep — Upstream / Out-of-Tree decision

**Status (2026-05-29): research only**. M5 ASPM soak still running
(24 h ETA 2026-05-30 ~03:05 UTC); M6 #1 and #2 LANDED. This document
is the **internal** research dossier for the M7 maintainer
conversation. The **outbound** dossier (what we'd actually send to
maintainers) is the lighter-weight
[`M7_PRE_RFC_DOSSIER.md`](M7_PRE_RFC_DOSSIER.md).

The plan §7 M7 frames the decision as one of three exits:
1. Submit a driver RFC to netdev
2. Refactor and contribute the C-shim's Rust replacement upstream first
3. Release as a maintained out-of-tree module

The right choice depends on **what kernel-Rust looks like by then**.
This file inventories the current state and sketches the path to each
exit.

## The hard finding (kernel-Rust 7.0 status)

Survey of `/home/operator/kbuild/linux-7.0.0/rust/kernel/`:

```
rust/kernel/net/
├── phy           # PHY abstraction (we use it)
└── phy.rs
```

That's all of `rust/kernel/net/`. There is **no `net_device`, no
`napi_struct`, no `sk_buff`, no `netdev_tx_t`** in the Rust kernel
crate. PHY exists because the Realtek 8169 PHY work blazed that
trail; everything else network-side is C-only.

Confirmation:
```
$ grep -rln "net_device\|NetDevice\|napi_struct\|sk_buff" \
       /home/operator/kbuild/linux-7.0.0/rust/kernel/
   (no output)
```

This means our cshim isn't a temporary scaffold around a coming Rust
API — it's filling a permanent gap that upstream hasn't started to
fill at all. Different from `pci::Device` (which has a partial
abstraction we extend in unsafe_boundary), `block::`, `dma::`,
`devres::`, etc. — those exist and we wrap them safely.

## Inventory of our cshim surface

`src/netdev_bridge.h` declares the contract; the implementation spans
five `.c` files totaling **34 exported symbols**:

| File | Symbols | Role |
|---|---|---|
| `netdev_bridge.c` | 19 | net_device + NAPI lifecycle, sk_buff helpers, queue stop/wake |
| `netdev_bridge_offload.c` | 10 | TX DMA helpers, CSUM + TSO opts encoders |
| `netdev_bridge_phy.c` | 4 | mdiobus + phy_device lifecycle |
| `netdev_bridge_counters.c` | 1 | §6.3 percpu counter snapshot reader |
| `netdev_bridge_ethtool.c` | 0 | (table only; no exports) |

Breakdown by what kernel C struct each symbol wraps:

### `net_device` lifecycle (10 symbols)
- `r8125_bridge_alloc` — `alloc_etherdev` + `netdev_ops` + `ethtool_ops` wiring
- `r8125_bridge_free` — `free_netdev` + napi del
- `r8125_bridge_register` — `register_netdev`
- `r8125_bridge_unregister_and_free` — orchestrated teardown including PHY + mdiobus
- `r8125_bridge_tx_stop_queue` / `r8125_bridge_tx_wake_queue` — netif_tx_{stop,wake}_queue
- `r8125_bridge_tx_disable` — netif_tx_disable
- `r8125_bridge_carrier_on` / `r8125_bridge_carrier_off`
- `r8125_bridge_account_tx` / `r8125_bridge_account_rx` — netdev stats bumps

### NAPI surface (3 symbols)
- `r8125_bridge_napi_schedule` / `r8125_bridge_napi_complete_done` / `r8125_bridge_napi` (getter)

### sk_buff path (8 symbols)
- `r8125_bridge_skb_build_rx` — `netdev_alloc_skb` + `eth_type_trans` + skb_put_data
- `r8125_bridge_skb_deliver_rx` — `napi_gro_receive`
- `r8125_bridge_skb_consume_tx` — `napi_consume_skb`
- `r8125_bridge_skb_free_error` / `r8125_bridge_skb_drop_rx` — `dev_kfree_skb_any`
- `r8125_bridge_skb_data_dma_map` / `r8125_bridge_skb_frag_dma_map` — `dma_map_single` / `skb_frag_dma_map`
- `r8125_bridge_skb_dma_unmap_tx` / `r8125_bridge_skb_dma_unmap_frag_tx` — `dma_unmap_single` / `dma_unmap_page`

### Offload encoders (4 symbols)
- `r8125_bridge_skb_tx_csum_opts` — reads skb csum_partial, returns opts2 bits
- `r8125_bridge_skb_rx_csum_set` — sets skb->ip_summed from opts1
- `r8125_bridge_skb_tso_setup` — TSO opts bits (tcp_v6_gso_csum_prep for v6)
- `r8125_bridge_skb_nr_frags` / `r8125_bridge_skb_len` — accessors

### PHY (4 symbols)
- `r8125_bridge_phy_connect_and_reset` — mdiobus register + phy_attach_direct + genphy_soft_reset
- `r8125_bridge_phy_kick_state_machine` — phy_start
- `r8125_bridge_phy_stop` — phy_stop + phy_disconnect
- C45 MDIO read/write callbacks

### Counters (1 symbol)
- `r8125_bridge_counters_snapshot` — reads percpu counters

## Each kernel C surface, with the upstream Rust gap

| Kernel C type | Used by us | Has Rust abstraction? |
|---|---|---|
| `struct net_device` | every ndo callback + flow control | **NO** |
| `struct net_device_ops` | bridge_ops table | **NO** |
| `struct napi_struct` | NAPI poll loop + flow control | **NO** |
| `struct sk_buff` | TX/RX entire data path | **NO** |
| `struct dev_pm_ops` | (would need for M5 PM) | **NO** |
| `struct ethtool_ops` | ethtool -S counters | **NO** |
| `struct mii_bus` | MDIO bus | partial (`net/phy.rs`) |
| `struct phy_device` | PHY driver bind | partial (`net/phy.rs`) |
| `dma_map_*` / `dma_unmap_*` | TX/RX DMA | yes via `dma.rs` |
| `pci_*` | probe/unbind, BAR map | yes via `pci.rs` |

So of the 34 cshim symbols, the **30 not covered by upstream Rust**
fall into 4 broad categories: net_device lifecycle (10), NAPI (3),
sk_buff (8 + 4 offload encoders), and ethtool_ops (0 exports but
table sufficient surface). All four are net-stack-side abstractions.

## What each M7 exit looks like

### Exit (a) — Submit a driver RFC to netdev

**Realistic cost**: high. We'd be asking maintainers to review:
- The Rust core (modest review — kernel-Rust patterns are
  documented, our use is conventional)
- The 34-symbol C cshim (more review — every cshim entry needs to
  justify why it's not an upstream Rust abstraction)

**Likely maintainer response**: "Don't submit a driver until the
abstractions are upstream. Submit the abstractions first as a
separate series." That's the plan's explicit warning at §7 M7:
> "do not post a driver RFC until at least one networking maintainer
>  has reviewed the C-shim boundary and stated whether reusable Rust
>  netdev abstractions should be posted first."

We can pre-empt this by going to exit (b) directly.

### Exit (b) — Contribute the Rust netdev abstractions upstream first

**Realistic cost**: very high. Even a minimal `kernel::net::NetDevice`
abstraction would be:
- An RFC patch series of ~5-15 patches, each a single abstraction
- Maintainer back-and-forth over months (Jakub Kicinski + Paolo Abeni
  are the netdev maintainers; both are deeply involved in the Rust
  conversation)
- Need to satisfy the "no in-tree user yet" rule by providing one
  example user (us, or a simpler stripped-down driver)
- Need to follow ROW kernel-Rust conventions for abstraction design

**Path sketch** (in dependency order):

1. `kernel::net::SkBuff` — basic skb wrapper with safe accessors. ~200 LOC.
2. `kernel::net::NetDevice` — net_device alloc/free + the ndo_open/stop/start_xmit/poll vtable as a Rust trait. ~400 LOC.
3. `kernel::net::Napi` — napi_struct + schedule/complete_done. ~150 LOC.
4. `kernel::net::ethtool` — ethtool_ops trait, get_strings/get_ethtool_stats/get_sset_count etc. ~200 LOC.
5. Then refactor our driver to use these. Maybe 50% of the cshim
   collapses; the offload encoders and chip-specific helpers stay.

Realistic timeline: **12-18+ months** of patch iteration with
maintainers before any of those abstractions are in mainline.
Calibrated against `kernel::block` ([`M7_BLOCK_CADENCE.md`](M7_BLOCK_CADENCE.md)):
RFC May 2023 → first merge Aug 2024 (15 months) → "complete"
follow-up series still landing Feb 2026 (33+ months). Smaller
surfaces, fewer prerequisites, or plural-author teams can push
toward the low end; solo authors stall (FUJITA Tomonori 2023
net_device proposal stalled at v2).

### Exit (c) — Maintained out-of-tree module

**Realistic cost**: low (already where we are). Continue shipping the
crate as out-of-tree. Maintain compatibility with kernel-Rust API
evolution by checking against new kernel versions. Land the M6/M7+
features as they make sense.

**Trade-offs**: no upstream review of the safety claims; no DKMS-style
packaging help; users have to build from source. But the prototype
is useful as research and as ammunition for exit (b).

## Recommended posture

**Don't pick yet.** The M5 + M6 work in progress strengthens the
position for whichever exit gets chosen later:
- M5's hardening + soaks produce **evidence** that a Rust kernel
  driver can clear the historical gates that have failed C drivers
  for this chip family.
- M6's MSI-X + jumbo work exercises the cshim's design under more
  pressure, surfacing any abstraction-design issues that would also
  apply to the upstream Rust API.

Once M6 lands cleanly, the right next move is **(d) — pre-RFC
maintainer consultation**, exactly as the plan §7 M7 prescribes:
write a short markdown for netdev maintainers describing what we
built, what we'd want as upstream Rust abstractions, and ask them
to advise whether we should pursue (a), (b), or (c). Their answer
sets M7's direction.

## Pre-consultation reading list

To do before opening the consultation thread:

1. **Track the kernel-Rust netdev thread on the Rust-for-Linux ML.**
   Search lore.kernel.org `rust-for-linux@vger.kernel.org` for
   "net_device" / "skb" / "napi" in 2025–2026 archives. If active
   work exists upstream we should align with it rather than propose
   a parallel design.

2. **Read the kernel-Rust PHY abstraction discussion**
   (FUJITA Tomonori's work — landed in 6.8+). It's the only
   net-side Rust abstraction shipped; its design pattern is what
   net_device should follow. Files:
   `rust/kernel/net/phy.rs`, `rust/kernel/net/phy/`, and the
   commit history therein.

3. **Audit a recent Rust kernel-block abstraction series** as a
   model for what a netdev series might look like. `block::` is the
   most-recently-landed major subsystem in kernel-Rust; its review
   thread (search `rust-for-linux` for "block driver abstractions")
   shows the maintainer-feedback shape.

4. **Compare our cshim contract** (`src/netdev_bridge.h`,
   especially the §6.3 sk_buff ownership contract) to the kernel C
   net_device + sk_buff lifecycle docs. Identify any aspect of our
   contract that's an artifact of OUR Rust safety model that the
   upstream C model doesn't enforce — those are the trickiest
   surface to abstract.

5. **Survey other in-progress Rust driver crates** that are facing
   the same gap. The `rust-net` group on rust-for-linux exists for
   this. Aligning with their consensus saves duplicate proposals.

## What to ask maintainers (when the time comes)

Draft of the consultation message we'd post:

> Subject: Pre-RFC: Rust netdev abstractions for an out-of-tree
>          RTL8125 driver — guidance on upstream pathway
>
> We have built an out-of-tree Rust kernel driver for the Realtek
> RTL8125B that reaches line-rate TSO (2.35 Gbps) at parity with
> r8169. The driver uses a 34-symbol C shim ("netdev_bridge")
> covering the net_device + NAPI + sk_buff surface that kernel-Rust
> 7.0 does not yet provide.
>
> Before posting a driver RFC, we want guidance: is the
> abstraction-first path the right next step? The cshim's contract
> (linked) inventory shows where the Rust gap is. We'd be happy to
> bring the abstraction work upstream, but would want to know:
>
>  - Is there an existing in-progress series for Rust net_device /
>    NAPI / sk_buff that we should align with rather than duplicate?
>  - For the abstractions that don't exist, should we propose them
>    starting from a working driver as the "one example user", or
>    is a different design pattern preferred?
>  - What's the minimum viable abstraction surface that would make a
>    Rust driver upstream-acceptable?
>
> The driver, cshim contract, design docs, and test harnesses are at
> [github link]. Happy to walk through any specific area in detail.

This is research; do NOT post yet. The actual consultation is M7
work that should follow M6 completion + soak-gate sign-off.

## Cross-references

- `docs/RTL8125_Rust_Driver_Implementation_Plan.md` §7 M7 — the
  authoritative plan section this prep work derives from.
- `src/netdev_bridge.h` — the cshim contract that would either
  become a Rust abstraction (exit b) or stay as documented bridge
  code (exit c).
- `docs/M5_PM_GAP.md` — a concrete example of a kernel-Rust gap we
  already documented (`kernel::pci::Driver` exposes only
  probe/unbind, no PM).
- `docs/M5_CLOSEOUT.md` — sign-off evidence we'd cite in the
  maintainer consultation.
