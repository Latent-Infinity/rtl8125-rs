# B3 V2 MSI-X Smoke - 2026-06-07

Gateway smoke for the RTL8125B V2 interrupt ownership checkpoint. Hardware RSS
queues are still disabled; this validates the 22-vector MSI-X prerequisite and
the fixed V2 message-id ownership model before B4 RSS programming.

## Result

Driver checkpoint passed on Gateway kernel `7.0.0-22-generic`.

- Probe selected exact 22-vector MSI-X and `use_v2=true`.
- Active V2 IRQ ownership matched RTL8125B fixed entries:
  - RX0: Linux IRQ 68, MSI-X entry 0
  - TX0: Linux IRQ 197, MSI-X entry 16
  - LINK: Linux IRQ 202, MSI-X entry 21
- TCP TX/RX reached 2.353/2.353 Gbps.
- UDP 1448B TX/RX reached 2.200/2.200 Gbps; UDP TX loss was 0 and the prior
  single-vector V2 TX-completion wedge did not reproduce.
- RXHASH remained healthy: `rx_hash_l4=2006515`, `rx_hash_missing=0`.
- `rmmod` while the interface was up completed.
- Narrowed dmesg fault scan was clean.

The 64B UDP TX row is generator/iperf pressure evidence, not a B3 pass/fail
metric: it completed without wedging, but the offered 1G 64B stream overshot the
single-flow userspace/NIC path and reported loss.

See `summary.txt` and `raw/` for the captured dmesg, ethtool, iperf, and
`/proc/interrupts` evidence.

## Independent re-validation (review gate, 2026-06-08)

Rebuilt the current tree on the gateway and re-ran the V2-default smoke as part
of reviewing the full V2/queue-aware change set before staging:

- Probe selected `use_v2=true`: rx0 IRQ 68 / tx0 IRQ 197 / link IRQ 202,
  INT_CFG0=0x01; three vectors registered in `/proc/interrupts`.
- **UDP TX wedge regression — PASS.** Unidirectional UDP TX: 2,064,228 packets
  @ 2.39 Gbps, tx0 IRQ 197 delta = 1,305,671 (the TX-completion vector is
  delivered). Repeat run: 1.65M packets. No wedge (signature would be ~94-182).
- IRQ fire split confirms correct routing: tx0(197)=3.4M, rx0(68)=281k,
  link(202)=3.
- TCP TX/RX 2.36/2.35 Gbps; UDP RX drove rx0 IRQ 68 (delta 230,664).
- RXHASH: `rx_hash_l4` advancing, `rx_hash_missing=0`.
- Lifecycle: open/stop ×3 recovered carrier each time; MTU 9000 reopen + jumbo
  ping OK then back to 1500; rmmod-while-up clean. **dmesg scan clean** — no
  free_irq mismatch / WARN / oops, so the 3-vector request/free balance holds.

Review verdict: code is correct (per-queue NAPI/page_pool, queue_id plumbing,
no new unsafe; census holds at 71; all gates pass) and hardware-validated.

### `irq_v2` escape hatch (added + validated 2026-06-08)

The design note from the review — "no knob to force the proven MSI single-vector
legacy path short of `intx_only=1`" — is resolved. New module param `irq_v2`:

- `0` (off): skip V2; allocate one MSI/MSI-X vector and use the legacy combined
  ISR/IMR surface (`use_v2=false`). MSI-delivery escape hatch that does NOT drop
  to INTx.
- `1` (auto, default): try the 22-vector V2 surface, fall back to single-vector
  legacy, then INTx — the current behavior (unchanged default).
- `2` (on): require V2; probe fails (`EINVAL`) if the 22-vector MSI-X surface is
  unavailable, rather than silently downgrading.

Gated by `ci/check_irq_mode_contract.sh`. Gateway validation (all three modes,
rebuilt tree):

| mode | probe | NIC vectors | UDP TX | TCP TX/RX |
|---|---|---|---|---|
| auto (default) | `use_v2=true` | 3 (68/197/202) | 1.24M pkts, no wedge | 2.36/2.35 |
| `irq_v2=0` off | `use_v2=false` | 1 (68 only) | 1.24M pkts, no wedge | 2.36/2.35 |
| `irq_v2=2` on | `use_v2=true` | 3 | 1.24M pkts, no wedge | 2.36/2.35 |

dmesg clean across all three. The `off` path confirms a functional, wedge-free
legacy MSI fallback. (The `on` hard-fail arm is logic-/gate-verified; this
hardware always grants 22 vectors so it could not be exercised at runtime.)
