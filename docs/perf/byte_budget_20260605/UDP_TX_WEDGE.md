# Unidirectional UDP TX wedge — root cause: V2/MSI-X TOK_Q0 not delivered — 2026-06-05

## Symptom
On the gateway loopback rig (kernel 7.0.0-22, clean differential vs r8169):
- **r8169 (C reference): UDP TX = 259,058 pkt/s, 1000 Mbit/s, 0% loss.**
- **r8125_rust (default, MSI/V2): UDP TX wedges after ~94–182 packets** (≈ one socket
  send-buffer worth), 359–698 kbit/s. iperf3 dies with "control socket closed".
- TCP TX/RX/bidir and UDP **RX** are all at parity with C. Only **unidirectional UDP TX** fails.

First surfaced now because the old test topology's kube-router blocked gateway→peer
UDP TX, so UDP TX had never been measured; the self-contained netns rig exposes it.

## Isolation

All root-cause isolation below was done on the gateway, the valid hardware
differential. The Controller-KVM guest is not authoritative for single-stream
UDP TX because iperf3's userspace pacing loop on `kvm-clock` can wedge or
collapse both drivers. A later KVM follow-up showed r8169 reaches 2.36 Gbps
with `-u -l 1448 -b 250M -P 10`; see
`docs/perf/kvm_udp_tx_20260605/RESULTS.md`.

| Test | Result |
|------|--------|
| rust default (MSI/V2), UDP TX no RX | **94–182 pkt — WEDGE** |
| rust `tx_byte_budget=0`, UDP TX no RX | 94 pkt — still wedges (byte-budget not the cause) |
| rust MSI + `tx_coalesce_timer=0`, UDP TX no RX | 182 pkt — coalescing not the cause |
| rust, TX-checksum offload OFF, UDP TX no RX | 182 pkt — checksum offload not the cause |
| rust default, **UDP TX + concurrent RX (ping flood)** | **241,515 pkt — WORKS** |
| rust **`intx_only=1` (legacy IRQ surface)**, UDP TX no RX | **259,047 pkt — WORKS** |

IRQ counters during a TX-only flood: **12 IRQs in 3 s** (vs 22,011 during TCP, which is
dominated by RX-ACK interrupts). So the TX-completion interrupt essentially never fires
on the V2/MSI-X surface.

## Root cause
On the **V2/MSI-X interrupt surface**, the TX-completion source **TOK_Q0** (ISR_V2 bit 16)
is **latched but its MSI-X message is never delivered** — the same defect noted in
`MSI_SENT_QUEUE_INTERACTION.md` ("ISR_v2 latches TOK_Q0+LINKCHG but MSI-X delivers 0 IRQs").
RX (ROK_Q0, bit 0) *is* delivered. Consequences:

- NAPI is scheduled only by RX interrupts. TX completions get reaped **only incidentally**,
  when an RX interrupt happens to run the poll (which also reaps TX).
- TCP and bidirectional traffic always have RX (ACKs / reverse data), so TX is reaped and
  the bug is invisible.
- **Pure unidirectional UDP TX has no return traffic** → no RX interrupt → TX completions
  never reaped → skbs never freed → the socket send buffer fills (~94–182 pkts of 1448 B ≈
  the default `wmem`) → `sendto` blocks → flow wedges.

The C reference (mainline r8169) drives the RTL8125 via the **legacy** interrupt surface and
does **not** use this V2 per-queue surface — which is exactly why `intx_only=1` (legacy)
works at line rate.

## Fixes
1. **Lost-wakeup barrier (DONE this session).** Independently, the TX stop/recheck vs
   reaper drain/wake had no StoreLoad barrier, so the queue could wedge XOFF *permanently*
   (ping 100% loss) under UDP load. Added `fence(SeqCst)` on both sides
   (`netdev::stop_tx_queue_with_recheck` + `napi::poll`), the kernel `netif_subqueue_maybe_stop`
   / r8169 `smp_mb__after_atomic` pattern. After this, the queue *recovers* (ping OK) but
   UDP TX is still throttled by the TOK-delivery bug below — so this is necessary but not
   sufficient.
2. **Root cause + fix (DONE).** From the vendor r8125 driver
   (`rtl8125_setup_interrupt_mask` / `HwCurrIsrVer` selection,
   `references/realtek-r8125-official`): the V2 per-queue ISR surface routes each
   interrupt source to MSI-X table entry == its bit position — RX Q0 → entry 0,
   **TX Q0 (TOK_Q0) → entry 0x10 (16)**, LINKCHG → entry 21. The vendor only enables
   the V2 surface (`HwCurrIsrVer = 2`) when MSI-X is active **with ≥ 22 vectors**
   (`R8125_MIN_MSIX_VEC_8125B`); otherwise it downgrades to `HwCurrIsrVer = 1`, the
   legacy combined ISR/IMR (0x3C/0x38). The Rust driver enabled the V2 surface with a
   **single** vector, so RX (entry 0) was delivered but TX completions (entry 16) never
   were. Fix (`src/pci.rs`): allocate the single MSI/MSI-X vector but set `use_v2 =
   false` — i.e. use the legacy combined ISR over that vector (RxOK + TxOK on one
   entry), matching mainline r8169 and the vendor's `< 22 vector` fallback. The IMR_V2
   mask itself was already correct; the defect was purely enabling V2 with too few
   vectors. `select_bql_active` was re-anchored to `IrqMode::Intx` (the `!use_v2` proxy
   is meaningless now that V2 is never used).

## Validation of the fix (gateway -22, default config, MSI-X delivery)
| Metric | Before | After |
|--------|--------|-------|
| UDP TX (1G target) | 94–182 pkt, wedge, ping 100% loss | **259,060 pkt, 1000 Mbit/s, 0% loss, ping OK** |
| UDP-TX IRQ delta / 3 s | 12 | **1405** |
| IRQ delivery | MSI-X (V2, broken) | MSI-X (legacy ISR) — still MSI, not INTx |
| TCP TX/RX/bidir | = C | = C (2.35 Gbps) |
| UDP RX | = C | = C (0% loss) |
| Loaded latency p50/p99 | 425/628 µs | 505/649 µs (byte-budget still active over MSI) |

Plus a defensive `fence(SeqCst)` was added to the TX stop/recheck vs reaper wake paths
(see fix #1) — independent of this, it closes a lost-wakeup race that could strand the
queue XOFF.

## Note on the perf matrix
The cvr_20260605_k22 matrix (this session) shows rust == C on TCP (TX/RX/bidir, all offload
modes) and UDP RX; the only red cell is UDP TX, explained entirely by this bug.
