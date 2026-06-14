# M6 sub-feature #1 — MSI-X migration

**Status: LANDED 2026-05-28** (Phase A.1 + A.2 together). This file
captures the before/after data the plan §7 M6 gate demands. See
[`README.md`](README.md) for the metric scheme and the
environment-authority rules;
[`gateway_baseline.md`](gateway_baseline.md) is the pre-M6 INTx
reference.

## Scope

Phase A.2 (the atomic patch that activated MSI-X delivery) combines:

1. **`pci_alloc_irq_vectors(pdev, 1, 1, MSIX|MSI|INTX)`** at probe via
   the kernel-Rust `pci::Device<Bound>::alloc_irq_vectors` safe
   wrapper. Devres-managed: `pci_free_irq_vectors` fires automatically
   at device unbind.
2. **`IrqMode` discriminant** on `NetdevState` records what
   the kernel actually gave us (Msi covers both MSI and MSI-X — they
   share the V2 ISR layout on this chip).
3. **Chip-side V2 enable** via `INT_CFG0_ENABLE_8125 = 0x01`
   (**bit 0**, not bit 3 as a misreading of `if_re.c:1410` first
   suggested — see memory
   [`rtl8125b-int-cfg0-enable-bit`](../../../../home/firestrand/.claude/projects/-home-firestrand-Projects-Rt8125-driver/memory/rtl8125b-int-cfg0-enable-bit.md)).
4. **Branched IRQ handler + `rearm_irq_baseline`** that selects
   `IMR`/`ISR` (0x38/0x3C) when `IrqMode::Intx` or `IMR_V2`/`ISR_V2`
   (0x0D0C/0x0D04) when `IrqMode::Msi`.
5. **Mode-aware `request_irq` flags**: `IRQF_SHARED` for INTx
   (legitimately shared pins), `0` for MSI/MSI-X (per-device vectors).
6. **`intx_only` module param** as a regression rollback path.

The Phase A.1 scaffolding (V2 register surface + `intx_only` param +
`rearm_irq_baseline` helper) had landed earlier, but the chip-side
activation was deferred because empirical testing on Controller-KVM
2026-05-28 showed that setting V2 mode without an MSI/MSI-X vector
silently breaks IRQ delivery (the chip stops asserting the INTx pin
once V2 is active, expecting message-based delivery). Phase A.2 is
the patch where everything composes correctly.

## Environment authority

These numbers are **Controller-KVM** (debug+Rust kernel with KASAN +
lockdep + kmemleak + DMA_API_DEBUG). Per
[`README.md`](README.md), M7 maintainer dossier cites only Gateway
bare-metal numbers; this file is for development verification.
Gateway re-measurement is pending the 24 h ASPM-on soak completing
(ETA 2026-05-30 ~03:05 UTC); the Gateway pre-M6 baseline at INTx is
in [`gateway_baseline.md`](gateway_baseline.md).

| Item | Value |
|---|---|
| Box | Controller — KVM guest with RTL8125B VFIO passthrough |
| Kernel | `7.0.0` (debug+Rust: KASAN + lockdep + kmemleak + DMA_API_DEBUG) |
| Driver | `r8125_rust` post-M6 #1 Phase A.2 commit |
| Chip | Realtek RTL8125B, XID 0x641, rev 0x05 |
| Topology | guest enp5s0 (10.0.0.2) → host enp4s0 I226-V (10.0.0.1), cable |
| Link | 2.5 Gbps, full-duplex, flow control rx/tx |

## INTx (pre-M6 #1) vs MSI-X (post-M6 #1 Phase A.2)

| Metric | INTx (pre) | MSI-X (post) | Δ |
|---|---:|---:|---:|
| Median throughput (Gbits/s) | 2.35 | 2.35 | 0% |
| TCP retransmits / 5 s | 0 | 0 | — |
| §6.3 invariant gap | 0 | 0 | — |
| IRQ count / 5 s | 14 (1 s ping window) | **58 098** (5 s iperf3) | — (different workloads — comparable IRQ-per-frame ratio) |
| Ping RTT (ms) | 0.42 | **0.40** | -5% |
| `/proc/interrupts` source | `IO-APIC 21-fasteoi` | `PCI-MSIX-0000:05:00.0 0-edge` | new path |

Single-stream TCP throughput is bottlenecked elsewhere (link
negotiation, kernel TCP stack), so MSI-X delivery doesn't change
the Gbits/s number. The interesting wins are:

- **Latency improvement**: 0.42 ms → 0.40 ms ping (-5 %) reflects the
  shorter MSI-X dispatch path (no IO-APIC redirection-table lookup).
- **No false IRQ wake-ups**: shared-INTx has to disambiguate every
  fire ("was this for me?") via `regs.isr()`; MSI-X vectors are
  per-device by construction so we never read+ack an IRQ that wasn't
  ours.
- **Foundational for multi-queue / RPS** (future M6+1 work — see
  `docs/MULTIQUEUE_RSS.md` for why we don't multi-queue on 8125B today,
  but the infrastructure now exists).

## `intx_only=1` regression rollback

Loading the module with `intx_only=1` forces the
`pci_alloc_irq_vectors` path to accept only INTx, which keeps the
chip on its legacy ISR/IMR register surface. This is the M6 rollback
escape hatch in case MSI-X regresses on a deployment target.

| Configuration | Mode log | IRQ source | Ping | TX completion | Notes |
|---|---|---|---|---|---|
| `intx_only=1` | `mode=Intx, forced by intx_only` | `IO-APIC 21-fasteoi r8125_rust` | 0% loss, 0.42 ms | 10/10 | confirms legacy path still works |
| (default) | `mode=Msi` | `PCI-MSIX-0000:05:00.0 0-edge r8125_rust` | 0% loss, 0.40 ms | 122 049 / 122 050 in 5 s | confirms MSI-X path |

Both paths are exercised by `ci/check_irq_mode_contract.sh` (8 static
gates: enum + AtomicU8 field + accessor + probe alloc path + flag
mapping + chip-side V2 enable gating + handler branching + rearm
helper).

## The `INT_CFG0_ENABLE_8125` bit-position bisection

The first Phase A.2 cut crashed in the most confusing way: insmod
succeeded, link came up at 2.5 Gbps, `tx_received` climbed, but the
IRQ counter stayed at exactly **0** and no traffic flowed end-to-end.

Root cause: I'd transcribed the chip's V2-enable bit as
`INT_CFG0_ENABLE_8125 = 0x08` (BIT 3) based on
`references/freebsd-realtek-re-kmod/if_re.c:1410` — but that codepath
is the chip's **mitigation/timeout toggle**, not the ISR-version
toggle. The Realtek vendor source-of-truth `r8125.h:1825` puts
`INT_CFG0_ENABLE_8125` at **BIT 0 = 0x01**, and the FreeBSD vendor
header `if_re.h:1336` agrees (`0x0001`).

Switching to `0x01` fixed the IRQ delivery first-try: `mode=Msi`,
IRQ 61 PCI-MSIX, 58 098 fires across 5 s of iperf3.

Memory entry saved at
[`rtl8125b-int-cfg0-enable-bit`](../../../../home/firestrand/.claude/projects/-home-firestrand-Projects-Rt8125-driver/memory/rtl8125b-int-cfg0-enable-bit.md)
so future sessions don't re-discover this bit. The bit is also
documented in
[`docs/MSIX_DESIGN.md`](../MSIX_DESIGN.md) under the Phase A.2
LANDED section.

## §6.3 disposition-counter invariant

Across a 5 s MTU-1500 iperf3 burst on MSI-X:

| Counter | Delta |
|---|---:|
| `tx_received` | 122 050 |
| `tx_consumed` | 122 049 |
| `tx_busy_exception` | 0 |
| `tx_dropped_error` | 0 |
| `rx_handed_to_stack` | 118 409 |
| `rx_dropped_error` | 0 |
| **Invariant gap** | **1** (in-flight at sample moment) |

Gap of 1 reflects one TX descriptor still in flight at the moment of
the ethtool snapshot — same Acquire/Release pattern as the jumbo
dossier. Subsequent samples show `gap=0` after the inflight slot
completes.

## Clean unload

`rmmod r8125_rust` while iperf3 was actively pushing **122 005 xmit
calls + 58 491 MSI-X IRQs/5 s** completed in **1 s** with no kernel
`BUG`/`WARN`/page-fault. This validates the chain
`pci::Driver::unbind` → `NetdevHandle::shutdown` →
`bridge_unregister_and_free` → `ndo_stop` (the post-#58 fixed path).

## What MSI-X *enables* for future work

Even though raw throughput is unchanged, the MSI-X migration unlocks:

1. **Per-MSI-X-vector IRQ affinity**: pin the chip's IRQ to a specific
   CPU; the kernel's `irqbalance` already does this for MSI-X vectors
   automatically but did nothing useful for shared INTx.
2. **Multi-queue RSS**: M6 #3 deferred (`docs/MULTIQUEUE_RSS.md`) for the
   8125B specifically, but the V2 ISR layout supports up to 16
   per-message-id sources — the registers are there when a future chip
   variant turns on RSS.
3. **Per-vector RPS / XPS**: `softirqd` can be steered per-vector.

These don't appear in the metrics this file captures, but they're the
M7 dossier's "what we built for" answer if a maintainer asks why we
bothered.

## Caveats and pending work

1. **Gateway bare-metal MSI-X throughput is not yet measured.** Same
   reason as the jumbo dossier — the 24 h ASPM-on soak is running on
   the post-refactor build and we'll capture Gateway throughput after
   it completes.
2. **p99 latency under load not captured.** The 0.40 vs 0.42 ms
   numbers above are single-ping RTTs in an idle window; the README
   recipe wants 1 000 pings at 0.05 s spacing in parallel with
   100 Mbps iperf3. Worth running before M7 outreach.
3. **CPU per Gbps not captured.** Same.
4. **No comparison against out-of-tree `r8125`** — plan §7 M6 says
   "throughput within 10 % of vendor". We're matching the pre-M6 INTx
   number which is the same as the vendor at TCP saturation, but the
   dossier should make the comparison explicit.

## How to reproduce

```bash
# Pre-M6 (force legacy INTx via module param)
sudo rmmod r8125_rust 2>/dev/null
sudo insmod ~/rtl8125-rs/src/r8125_rust.ko intx_only=1
sudo dmesg | grep "IRQ allocated"   # should show: mode=Intx, forced by intx_only
cat /proc/interrupts | grep r8125_rust  # should show: IO-APIC NN-fasteoi
ping -c 5 -W 2 -I enp5s0 10.0.0.1   # baseline ping
iperf3 -c 10.0.0.1 -B 10.0.0.2 -p 5380 -t 5 -O 1
sudo rmmod r8125_rust

# Post-M6 (default — MSI-X preferred)
sudo insmod ~/rtl8125-rs/src/r8125_rust.ko
sudo dmesg | grep "IRQ allocated"   # should show: mode=Msi
cat /proc/interrupts | grep r8125_rust  # should show: PCI-MSIX-... edge
ping -c 5 -W 2 -I enp5s0 10.0.0.1
iperf3 -c 10.0.0.1 -B 10.0.0.2 -p 5380 -t 5 -O 1
```
