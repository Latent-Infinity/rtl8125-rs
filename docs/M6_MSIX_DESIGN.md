# M6 sub-feature #1 — MSI-X migration

**Status (2026-05-26): design only**. M5 ASPM 48-hour soak chain
running on the chip; M6 implementation begins after the soak completes
and any findings are addressed. This document is the implementation
plan we'll execute then.

## Context — what we have today

- **Single legacy INTx IRQ** allocated via `pci::Device::request_irq` in
  `src/netdev.rs::ndo_open`. The cookie is the `NetdevState` pointer;
  the handler is `raw_irq_handler` (in `unsafe_boundary.rs` glue).
- **8125 IMR/ISR register layout at 0x38/0x3C** (32-bit) — see
  `src/regs.rs::IMR / ISR`. We mask via `set_imr(0)` in the IRQ
  handler, schedule NAPI, and re-arm in `napi::poll` after
  `napi_complete_done`.
- **Single TX queue + single RX queue**, single NAPI instance bound
  through the cshim.

## What MSI-X buys (and doesn't) on 8125B

After surveying `references/realtek-r8125-official/src/r8125_n.c` +
`references/linux-mainline/drivers/net/ethernet/realtek/r8169_main.c`:

| | r8169 mainline | Realtek vendor | This driver (planned) |
|---|---|---|---|
| Interrupt mode | 1× legacy/MSI/MSI-X | Up to 32× MSI-X | 1× MSI-X (initial), expandable |
| Queue count on 8125B | 1 TX, 1 RX | **1 TX, 1 RX** | 1 TX, 1 RX |
| ISR register layout | Legacy 32-bit IMR/ISR @0x38/0x3C | ISR_V2 @0x0D00/0x0D04/0x0D0C | Migrate to ISR_V2 |
| Per-vector NAPI | No (single NAPI) | Yes (one per vector) | Single NAPI (initial) |

**Critical finding**: Realtek's own vendor driver does NOT do
multi-queue on 8125B. `HwSuppNumTxQueues = 1, HwSuppNumRxQueues = 1`
for the default case which includes our `MAC_VER_63` chip
(`r8125_n.c:15074-15077`). Only `CFG_METHOD_13` (8125D / 8126?) gets
multi-queue.

So M6 sub-feature #2 ("Multiple TX queues + RSS") **is N/A for 8125B**
at the chip's hardware level. The plan §7 M6 was written generically;
we should document this and skip the multi-queue work for this chip
revision. Documenting the gap saves the work being attempted and
finding the chip rejects it.

That leaves **MSI-X migration** (#1) and **jumbo frames** (#3) as the
real M6 work for 8125B. CSUM (#4) and TSO/GSO (#5) are already done in
M4-perf.

## Why migrate to MSI-X if we only use 1 vector?

Three benefits of MSI-X over legacy INTx even at 1 vector:

1. **MSI-X is edge-triggered** — no shared-IRQ disambiguation,
   no INTx-pin shadow state. Slightly lower IRQ overhead.
2. **PCIe MSI-X is required for any future multi-vector expansion** —
   if we ever want a separate link-change vector or a per-CPU NAPI
   instance, the table needs to be allocated up-front.
3. **r8169 mainline does this** — moving from legacy → MSI-X aligns
   us with upstream behavior on the same chip (`r8169_main.c:5340`:
   `pci_alloc_irq_vectors(tp->pci_dev, 1, 1, PCI_IRQ_MSI|PCI_IRQ_MSIX)`).

The migration is structural — we don't need to use additional vectors
to land MSI-X. Start with 1, expand later if we ever do.

## Chip hardware surface (verified from vendor source)

### MSI-X table

`R8125_MAX_MSIX_VEC_8125B = 32` (vendor `r8125.h:688`). The chip's
MSI-X table can advertise up to 32 entries. We can request fewer; the
PCI core picks the minimum the chip is willing to provide.

`R8125_MIN_MSIX_VEC_8125B = 22` (vendor `r8125.h:690`). This is the
MINIMUM the chip will allow even if we ask for 1. The unused entries
still get allocated.

In practice for a 1-vector use we still need to handle the table-size
mismatch gracefully — if the chip insists on 22 entries we get 22 even
though we hook just vector 0.

### ISR v2 register layout (the V2 surface we'd migrate to)

Vendor `r8125.h:1496-1498`:

```
IMR_V2_CLEAR_REG_8125 = 0x0D00  // 32-bit, write BIT(message_id) to mask
ISR_V2_8125           = 0x0D04  // 32-bit, status per message_id
IMR_V2_SET_REG_8125   = 0x0D0C  // 32-bit, write BIT(message_id) to unmask
```

Activated by setting `INT_CFG0_ENABLE_8125` in `INT_CFG0` (0x34, 8-bit).
Without this bit the legacy IMR/ISR layout stays active (which is what
we use today). The vendor's `rtl8125_hw_set_isr_ver` (`r8125_n.c:4531`)
toggles between v1 and v2 based on `HwSuppIsrVer` >= 2.

### Bit layout of ISR_V2 (single-queue 8125B)

Vendor `r8125.h:1832-1835`:

```
ISRIMR_V2_ROK_Q0  = BIT(0)    // RX OK on queue 0
ISRIMR_V2_LINKCHG = BIT(21)   // link change
```

Other bits are reserved / unused on single-queue 8125B. The bits map
1-to-1 onto MSI-X message_ids (bit N in ISR_V2 fires message_id N).

For 8125B specifically:
- **message_id 0** = RX queue 0 done (`ISRIMR_V2_ROK_Q0`)
- **message_id 21** = link change (`rtl8125_get_linkchg_message_id`
  default case returns 21; our chip falls in default per `HwCurrIsrVer`
  not being 4/5/7)
- The TX-queue-0 message_id isn't directly named in the V2 macros but
  vendor's `rtl8125_vec_2_tx_q_num` uses `messageId == 0x10` (16) for
  TX queue 0 when `HwSuppIsrVer == 2`. So:
  - **message_id 16** = TX queue 0 done

## Implementation status (2026-05-28)

**Phase A.1 — V2 register surface scaffolded (LANDED).** Added in
`src/regs.rs` (ISR_V2 / IMR_V2 register offsets + INT_CFG0_ENABLE_8125
+ ISRIMR_V2_* bits + INTR_V2_M4_BASELINE), `src/mmio.rs` (set/clear
v2 mask + isr_v2 + ack_isr_v2 wrappers), `src/r8125_rust_main.rs`
(`intx_only` module param) and `src/napi.rs` (centralized
`rearm_irq_baseline` helper). `ndo_stop` masks BOTH surfaces
idempotently. The V2 surface compiles, is gated `#[allow(dead_code)]`
until Phase A.2, and the legacy IRQ path is unchanged. Controller-KVM
regression: 2.32 Gbps, 0 retransmits, ping 0.4 ms — baseline
preserved exactly.

**Phase A.2 — chip-side V2 enable + MSI-X allocation (LANDED 2026-05-28).**
The atomic patch wires `pci_alloc_irq_vectors` at probe (kernel-Rust
`pci::Device<Bound>::alloc_irq_vectors` — devres-managed, so
`pci_free_irq_vectors` fires at device unbind automatically), records
the resulting `IrqMode { Intx, Msi }` on `NetdevState`, and branches
the IRQ handler + `rearm_irq_baseline` + `ndo_open`'s
`INT_CFG0_ENABLE_8125` write on that mode. `ndo_stop` keeps
dual-masking both surfaces idempotently (no edit needed from A.1).

**Empirical finding 2026-05-28 #2 (Controller-KVM, fresh testing).**
The first Phase A.2 cut still failed to deliver IRQs because the
constant `INT_CFG0_ENABLE_8125` was `0x08` (BIT 3) — a misreading of
`if_re.c:1410`'s mitigation-toggle codepath. Vendor agreement
(`r8125.h:1825` and `if_re.h:1336 = 0x0001`) puts the V2-enable at
**BIT 0**. After the one-bit fix, MSI-X delivery worked first try:

| Path | iperf3 | ping | IRQ source | IRQ count after 5 s | TX completion |
|---|---|---|---|---|---|
| `intx_only=1` (regression fallback) | not run | 0 % loss, 0.4 ms | `IO-APIC 21-fasteoi r8125_rust` | 14 | 10/10 |
| default (MSI-X) | **2.35 Gbps / 0 retr** | 0 % loss, 0.4 ms | `PCI-MSIX-0000:05:00.0 0-edge r8125_rust` | 58 098 | 122 049 / 122 050 |

Rmmod is clean: `xmit_calls=122050 irq_fires=58098 napi_polls=58097`,
unbinds clean, no kmemleak/WARN, `lsmod` confirms zero refcount.
The Phase A.1 PCI design (vector allocation outside `ndo_open`,
devres-managed) was kept. The two M6 design gates
(`check_msix_static.sh` and `check_isr_v2_paired.sh`) now engage and
PASS — total static CI is **57 PASS / 0 FAIL / 2 SKIP** (jumbo gates
which are M6 sub-feature #2).

Phase A.2 work that actually shipped:
- `IrqMode { Intx, Msi }` enum on `NetdevState` (`AtomicU8` field) — set at probe, read by IRQ handler + `rearm_irq_baseline`
- `unsafe_boundary::alloc_one_irq_vector` + `pci_irq_vector` wrappers around the kernel-Rust safe APIs
- `unsafe_boundary::request_irq` now takes a `flags` parameter so `ndo_open` selects `IRQF_SHARED` for INTx and `0` for MSI/MSI-X
- `INT_CFG0_ENABLE_8125` write moved from `hw_start_8125b` (which runs before mode is known) to `ndo_open` (gated on `state.irq_mode()`)
- Raw IRQ handler + `napi::rearm_irq_baseline` both `match state.irq_mode()` — legacy ISR/IMR for Intx, V2 ISR/IMR for Msi
- `pci.rs` probe tries `IrqType::MsiX | Msi` first, falls back to `IrqType::Intx` if that allocation fails (the `intx_only` param forces the fallback path)
- `pci_dev_irq` removed (no callers; superseded by `pci_irq_vector(pdev, 0)`)
- `INT_CFG0_ENABLE_8125` constant corrected to `0x01` with the bisection narrative inlined in `regs.rs`

## Proposed implementation path (Phase A.2 onward)

**Phase A — switch interrupt mode without changing queue count.**

1. **Register interface**: add to `src/regs.rs`:
   ```rust
   pub(crate) const INT_CFG0_ENABLE_8125: u8 = 0x08; // already present? verify
   pub(crate) const IMR_V2_CLEAR: usize = 0x0D00;
   pub(crate) const ISR_V2:       usize = 0x0D04;
   pub(crate) const IMR_V2_SET:   usize = 0x0D0C;
   pub(crate) const ISRIMR_V2_ROK_Q0:  u32 = 1 << 0;
   pub(crate) const ISRIMR_V2_TOK_Q0:  u32 = 1 << 16;  // tx queue 0
   pub(crate) const ISRIMR_V2_LINKCHG: u32 = 1 << 21;
   ```

2. **MMIO wrapper**: add to `src/mmio.rs::Regs`:
   ```rust
   pub(crate) fn set_imr_v2_mask(&self, bits: u32)   { write_u32_at(IMR_V2_SET, bits) }
   pub(crate) fn clear_imr_v2_mask(&self, bits: u32) { write_u32_at(IMR_V2_CLEAR, bits) }
   pub(crate) fn isr_v2(&self) -> u32                { read_u32_at(ISR_V2) }
   pub(crate) fn ack_isr_v2(&self, bits: u32)        { write_u32_at(ISR_V2, bits) }
   ```

3. **hw_start_8125b update**: in `src/hw.rs`, after the existing
   `INT_CFG0` / `INT_CFG1` writes, set the ENABLE_8125 bit:
   ```rust
   // Switch the chip to ISR v2 (per-message-id) interrupt layout.
   let cfg = regs.int_cfg0();
   regs.set_int_cfg0(cfg | regs::INT_CFG0_ENABLE_8125);
   // Mask all v2 sources first; we'll unmask the ones we want
   // after the IRQ handler is installed.
   regs.clear_imr_v2_mask(0xFFFF_FFFF);
   regs.ack_isr_v2(0xFFFF_FFFF);
   ```

4. **Vector allocation**: kernel-Rust pci surface — check whether
   `pci::Device::request_irq` accepts a vector index, or whether we
   need to use the lower-level `pci_alloc_irq_vectors` bindings. If
   the latter, wrap it in `src/unsafe_boundary.rs`. (TODO during
   implementation: read `/home/operator/kbuild/linux-7.0.0/rust/kernel/pci.rs`
   to confirm the API.)

5. **IRQ handler dispatch**: keep a single handler but read ISR_V2
   instead of legacy ISR:
   ```rust
   let status = regs.isr_v2();
   if status == 0 || status == 0xFFFFFFFF { return IRQ_NONE; }
   regs.ack_isr_v2(status);
   regs.clear_imr_v2_mask(status); // mask only what we saw
   // schedule NAPI; later we can dispatch to per-vector NAPIs
   ```

6. **NAPI poll re-arms ISR_V2** after `napi_complete_done`:
   ```rust
   regs.set_imr_v2_mask(ISRIMR_V2_ROK_Q0 | ISRIMR_V2_TOK_Q0 | ISRIMR_V2_LINKCHG);
   ```

7. **Fallback path**: if MSI-X allocation fails (e.g., guest kernel
   disabled MSI-X), fall back to MSI then to legacy. This is what
   `pci_alloc_irq_vectors_affinity` does naturally — request
   `PCI_IRQ_MSIX | PCI_IRQ_MSI | PCI_IRQ_INTX` and the kernel picks
   the best one. Keep the legacy ISR_V1 register path for the
   fallback case.

**Phase B — add a second vector for link change (optional).**

Once Phase A is solid, allocate 2 vectors: vector 0 for RX/TX combined
(message_ids 0 + 16), vector 21 for link change (message_id 21). This
removes link-change IRQs from the data-path NAPI's path.

This is **optional** for the M6 gate and may be deferred to a future
M6+ task. The performance benefit is small for our workload (link
change is a rare event).

## CI surface additions

| Check | What it enforces |
|---|---|
| `check_msix_static.sh` | `request_irq` is called with at most one vector, OR the vector allocation request includes `PCI_IRQ_MSIX|PCI_IRQ_MSI|PCI_IRQ_INTX` so fallback works |
| `check_isr_v2_paired.sh` | every `set_imr_v2_mask` has a matching `clear_imr_v2_mask` in the cleanup path |
| Runtime: `ci/check_msix_runtime.sh` | `cat /proc/interrupts` shows our IRQ name; toggling carrier produces interrupts; `ethtool -K msix off` (if we expose it) falls back cleanly |

## Per-feature gate compliance (plan §7 M6)

| Gate | How we satisfy it |
|---|---|
| `ethtool -K` disables feature at runtime | MSI-X mode is fixed at probe; the actual "feature" gate maps to `pci_alloc_irq_vectors` flags. Module param `intx_only=1` provides the rollback. |
| Packet capture verifies on-wire correctness | n/a — interrupt mode is invisible on the wire. Verified by `cat /proc/interrupts` showing IRQ counts increment. |
| Bad-checksum injection | not applicable to interrupt mode |
| Per-revision rollback | use `mac_version` dispatch in `hw_start_8125b` |
| `docs/perf/` numbers | measure CPU-per-Gbps before/after with MSI-X. Expectation: ~5% lower CPU at 2.35 Gbps line rate from removing INTx pin assertion overhead. |

## Risks + mitigations

- **Risk**: kernel-Rust `pci::Device::request_irq` may not expose a
  vector index. **Mitigation**: wrap `bindings::pci_alloc_irq_vectors`
  in `unsafe_boundary.rs` if needed; this is a documented unsafe extern.
- **Risk**: ISR_V2 register surface may have chip-version-specific
  bit-layout differences. **Mitigation**: phase A only uses bit 0
  (ROK_Q0) and bit 21 (LINKCHG), which the vendor source confirms
  for `HwSuppIsrVer >= 2` on 8125B.
- **Risk**: a fault during the legacy → V2 transition could mask
  interrupts forever. **Mitigation**: do the toggle atomically inside
  `hw_start_8125b` while the chip is in reset state, before
  enabling RX/TX engines. Add a `wait_isr_v2_ready` poll like the
  existing `wait_mac_ocp_e00e_clear`.
- **Risk**: M5 ASPM soak still running on the chip — can't validate
  M6 changes for ~48h. **Mitigation**: this is the documented gate;
  design now, implement after soak completes.

## Estimated effort

| Phase | Code LOC | CI LOC | Wall-clock |
|---|---|---|---|
| A — single MSI-X vector + ISR_V2 | ~80 Rust, ~30 C | ~60 | 1-2 hot-iteration sessions |
| B — split link-change vector | ~40 Rust | ~20 | 1 session |
| Per-feature gate doc + perf numbers | ~30 (mostly markdown + `docs/perf/`) | 0 | 1 session |

## What this design does NOT cover

- **Multi-queue / RSS** — explicitly N/A for 8125B per Realtek vendor
  source (single TX + single RX queue on this chip rev). Document in
  `docs/M6_MULTIQ_NA.md` instead of attempting the work.
- **Jumbo frames** — separate M6 sub-feature, designed in
  `docs/M6_JUMBO_DESIGN.md` (forthcoming).
- **Per-feature ethtool toggles** — `ethtool -L set rx 1 tx 1` would
  be trivial since we have 1+1; not worth wiring up until we have
  multi-queue, which we don't.
