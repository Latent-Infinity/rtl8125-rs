# FreeBSD vendor reference — 2026-05-26 investigation

While the M5 ASPM soak chain runs (~48h wall-clock), I added the
BSD-licensed Realtek vendor driver to `references/` as a 4th
independent implementation viewpoint (after r8169 mainline, Realtek
Linux vendor, ewaldc rewrite). This document captures what's worth
knowing.

## What got added to `references/`

| Reference | Status | Source |
|---|---|---|
| `freebsd-src` | VERIFIED ABSENT for 8125 | github.com/freebsd/freebsd-src — re(4) upstream chip table tops at 8168H, no 8125 support |
| `freebsd-realtek-re-kmod` | **useful**, BSD-4-clause | github.com/alexdupre/rtl_bsd_drv @ v1.101 — what FreeBSD ports ships as `net/realtek-re-kmod`; Realtek's official BSD driver plus a single FreeBSD-15 compatibility patch |

The BSD vendor driver is 44 909 lines in one `if_re.c`; covers
8169/8168/8125/8126 family. The `vendor` branch in the repo is
Realtek's pristine BSD source; `v1.101` adds **one commit**
("Add support for FreeBSD >= 15") on top — minimal local patches.

## Key findings for our project

### 1. Our chip = MACFG_83 = "8125B Rev B"

The BSD vendor's chip-version dispatch maps **PCI revision matrix
`0x64100000`** (which is our chip's XID 0x641 in BSD's encoding) to
`MACFG_83` = `NIC_RAMCODE_VERSION_8125B_REV_B`. Two MACFGs cover the
8125B silicon: MACFG_82 (Rev A) and **MACFG_83 (Rev B — us)**.

### 2. Jumbo cap is 9K, not 16K

BSD vendor sets `max_jumbo_frame_size = Jumbo_Frame_9k` for MACFG_83
(`if_re.c:3993`). The `Jumbo_Frame_9k` macro is
`9 * 1024 - VLAN_ETH_HLEN - ETH_CRC_LEN`, ~9180 bytes.

By contrast, r8169 mainline (`r8169_main.c:5553`) uses `JUMBO_16K`
(~16380 bytes) for the entire MAC_VER_61..LAST range.

**Implication for `docs/M6_JUMBO_DESIGN.md`**: our recommendation to
advertise JUMBO_9K initially (and treat JUMBO_16K as operator-opt-in)
matches BSD vendor's conservative posture exactly. Not r8169
mainline's aggressive 16K. **Keep the 9K initial cap in the M6
jumbo design.**

### 3. RX buffer allocation is per-MTU, not always-max

BSD vendor (`if_re.c:1373` + `4142`):
```c
re_rx_desc_buf_sz = (ifp->if_mtu > ETHERMTU) ? ifp->if_mtu : ETHERMTU;
re_rx_desc_buf_sz += (ETHER_VLAN_ENCAP_LEN + ETHER_HDR_LEN + ETHER_CRC_LEN);
// then bucket-fit to MCLBYTES (2K) / MJUMPAGESIZE (4K) / MJUM9BYTES (9K)
```

So the RX buffer pool is sized to the **current MTU**, not the
chip-max jumbo size. When MTU is 1500, BSD allocates 2K mbufs.
When MTU is 9000, BSD allocates MJUM9BYTES (9216-byte) mbufs.

This contrasts with r8169 mainline which always allocates `SZ_16K`
per RX slot regardless of MTU.

**Implication for our M6 jumbo design**: the streaming-DMA refactor
should allocate the buffer at the appropriate size class for the
current MTU, not always at chip-max. This matches BSD vendor's
memory efficiency. Our design doc's Phase B already implies this
(per-slot pages); confirm we size them dynamically.

### 4. ASPM is ENABLED by default at end of `re_init`

This is the most surprising finding. BSD vendor's `_re_enable_aspm_clkreq_lock(sc, 1)` is called at line 8254 of `if_re.c`, INSIDE `re_init` — the chip's start-of-day function. So after init the chip is left with ASPM-on (Config5 ASPM_en set).

This is **opposite to** what we do today (we clear ASPM_en in `hw_start_8125b`, matching r8169 mainline's `rtl_hw_aspm_clkreq_enable(false)`).

What this might mean:
- BSD has run with ASPM-on in production for years across deployments
- If BSD users were hitting L1.x lockups, it would be loud and visible — unlikely to have shipped this way
- The historical "RTL8125 L1.x lockup gate" the plan §7 M5 calls out may be **Linux-stack-specific** (interaction with the kernel's PCIe power-management, NAPI scheduling, etc.), not a hardware-permanent limitation

**Implication for our M5 ASPM-on soak (currently running)**: the soak
*should* pass. BSD vendor's production posture suggests the chip is
fine with ASPM-on. Our `force_aspm=1` phase 2 of the M5 soak chain
will tell us whether Linux KASAN-debug + KVM + VFIO is the actual
trouble vector, not the chip.

This is significant evidence for the M5 close-out interpretation when
the soak finishes.

### 5. SG fragment cap is `RE_NTXSEGS = 35` per packet

BSD vendor (`if_rereg.h:586`): `#define RE_NTXSEGS 35`.

This is the TX scatter-gather fragment limit per skb, not the same
as our `tso_max_segs = 10` (which is MSS-segments per super-skb,
post-LSO). They measure different things:
- `RE_NTXSEGS = 35` — how many DMA-mapped pieces compose one TX packet
- `tso_max_segs = 10` — how many MSS chunks the chip can segment one
  super-skb into

BSD vendor has no equivalent of `netif_set_tso_max_segs` because
FreeBSD's `ifnet` doesn't expose that API. Their TCP stack emits
super-skbs at sizes the chip's LSO engine can handle, but exactly
which constraint binds is implicit.

**Implication for `docs/RTL8125B_TSO_NOTES.md`**: our `max_segs=10`
cap finding stands. The BSD vendor doesn't contradict it; they just
don't expose it as a tunable. Our explicit cap is still the right
thing on Linux.

### 6. No surprise chip-init writes we're missing

I spot-checked a few MACFG_82/83 cases in BSD vendor's chip-init
switches (lines 549-757, 1463-1542, 2937+). The writes look like
the same kind of MAC OCP tuning + PHY config that we ported in M4-perf
session 2 (chip-init parity work). No "BSD has a write Linux doesn't"
revelation.

The local FreeBSD-port patch (one commit: "Add support for FreeBSD
>= 15") is purely API-level, not chip-level.

## Decisions this reference affects

| Existing decision | BSD evidence | Resulting action |
|---|---|---|
| `tso_max_segs = 10` in `netdev_bridge.c` | No contradiction (BSD doesn't expose this knob) | KEEP — our empirical bisection still stands |
| M6 jumbo cap = JUMBO_9K initially | BSD also uses 9K, not 16K | Matches design; jumbo phase C advertise 9K |
| M6 jumbo RX pool = per-slot streaming | BSD allocates per-MTU mbufs | Refine: size each slot to MTU-rounded class, not always 16K |
| M5 ASPM disabled in production | BSD enables ASPM by default; r8169 disables it | KEEP disabled for now (matches r8169 + our TSO requirement); the M5 phase-2 soak with `force_aspm=1` will confirm whether ASPM-on is viable on Linux too |
| `chiprev/MACFG_83` mapping | Confirmed: our XID 0x641 = 8125B Rev B silicon | Document chip rev in `src/hw.rs` ChipInfo comments |

## Things NOT to do based on BSD vendor

- **Do not enable ASPM by default** — even though BSD does, we have
  measured TSO retransmit regression in our setup when ASPM is on
  (the 2026-05-26 docs/RTL8125B_TSO_NOTES.md session results). Our
  driver shipping ASPM-disabled is the correct posture; phase 2 of
  the M5 soak (with `force_aspm=1`) is a probe, not a default.
- **Do not switch to MJUM9BYTES-style fixed-size jumbo buffers** —
  Linux's page allocator + dma_map_page is the natural primitive
  here; emulating FreeBSD's mbuf cluster classes would be a step
  sideways.

## Reference housekeeping

`references/freebsd-src/` is kept in tree as a "verified absent" record
so future maintainers don't waste time re-checking. Disk cost: small
(sparse checkout of `sys/dev/re/` + `sys/dev/mii/`). The
`fetch_references.sh` entry is annotated with the absence.

`references/freebsd-realtek-re-kmod/` is the active reference; pin
`bff7ba434755ec008f58312ff71c3b08a230aabe` (v1.101) matches the
current FreeBSD port HEAD.

## What this investigation does NOT do

- Does NOT change any code (read-only per §9.3)
- Does NOT delay M5 soak (running independently)
- Does NOT validate any of our designs end-to-end — those still need
  the M6 implementation + on-chip testing
- Does NOT cover the recently-published RTL8126 (5 GbE) silicon
  reference; that's a separate chip family
