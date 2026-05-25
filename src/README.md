# `src/` — Rust core

**Status: M4-full packet-path development. M1/M2/M3/M4-skeleton are complete; M0b peer baseline is captured.**

- **M1** (Rust PCI skeleton) passed 2026-05-23 — evidence
  [`../docs/baseline/m1_gate_proof.txt`](../docs/baseline/m1_gate_proof.txt).
- **M2** (register / reset / ASPM-log) passed 2026-05-24 — evidence
  [`../docs/baseline/m2_gate_proof.txt`](../docs/baseline/m2_gate_proof.txt).
- **M3** (cold DMA ring allocation) passed 2026-05-24 — evidence
  [`../docs/baseline/m3_gate_proof.txt`](../docs/baseline/m3_gate_proof.txt).
- **M0b** ✅ 2026-05-25 — physical topology and r8169 peer baselines captured
  in [`../docs/baseline/TOPOLOGY.md`](../docs/baseline/TOPOLOGY.md) and
  `../docs/baseline/iperf3/`.
- **M4-skeleton** ✅ 2026-05-24 — `net_device` registration via the C
  shim wired end-to-end; 1000× insmod/rmmod regression clean. Evidence
  [`../docs/baseline/m4_skeleton_proof.txt`](../docs/baseline/m4_skeleton_proof.txt).
  The peer-driven items (ndo_open hardware-enable, IRQ + NAPI bodies,
  ndo_start_xmit, `ip link up/down` loop, ping/iperf3) wait for the peer.

## Module layout (plan §6.1)

| Module | Responsibility | Milestone | Status |
|---|---|---|---|
| `r8125_rust.rs` | crate root: `module_pci_driver!`, crate-root `#![deny(unsafe_code)]`, `inject_reset_timeout` param (the "lib.rs" role from the plan — see naming note below) | M1 / M2 | ✅ |
| `pci.rs` | `pci::Driver` impl: probe/unbind, BAR mapping, device-id table; M2-wire to `hw`/`pm` | M1 / M2 | ✅ |
| `regs.rs` | curated register map (offsets, bitfields) | M2 | ✅ |
| `mmio.rs` | typed register read/write wrappers (only MMIO site outside `unsafe_boundary`) | M2 | ✅ |
| `hw.rs` | XID-based revision detection, dispatch table, reset sequence | M2 | ✅ |
| `pm.rs` | suspend/resume callbacks, ASPM policy, runtime PM (§3.3) | M2 (ASPM log) / M5 (suspend) | ✅ M2 log; policy deferred |
| `dma.rs` | coherent + streaming buffer allocation; streaming-mapping plan for M4+ | M3 | ✅ M3 (cold rings); streaming at M4 |
| `ring.rs` | TX/RX descriptor rings, typed indices, canaries | M3 | ✅ |
| `skb.rs` | typed `sk_buff` wrappers + FFI ownership state machine (§6.3) | M4/M5 | ✅ cshim-helper disposition for M4; type-state refactor queued for M5 |
| `napi.rs` | NAPI poll-path Rust side; calls into C shim | M4/M5 | ✅ M4 first cut |
| `netdev.rs` | Rust netdev glue: `BridgeOps` vtable, `NetdevHandle` RAII, ndo entry stubs, M4 TX/RX open path | M4 | ✅ M4-full active |
| `netdev_bridge.h` + `netdev_bridge.c` | C bridge — sk_buff ownership contract from §6.3, net_device + NAPI plumbing (≤400 LOC) | M4 | ✅ |
| `stats.rs` | counters, ethtool surfaces | M4+ | — |
| `trace.rs` | tracepoint definitions (experimental/versioned until M6, §16 Q4) | M4+ | — |
| `unsafe_boundary.rs` | the **only** module permitted `#![allow(unsafe_code)]` | M1 (empty) | ✅ — M3 residents (`set_64bit_dma_mask`, `AsBytes`/`FromBytes` for `ring::Descriptor`) plus M4 residents (cshim FFI extern block, raw pointer conversions, IRQ/DMA/skb/NAPI wrappers, `unsafe impl Send/Sync`). Census baseline: 43 |

## Naming note — `r8125_rust_main.rs` vs the plan's "lib.rs"

At M1 the crate root was `r8125_rust.rs` (matching the `obj-m` target). At
M4 we became a **composite** module (Rust + C objects linking into a
single `r8125_rust.ko`); naming the Rust component the same as the
composite triggers a kbuild circular-dep warning and silently drops the
Rust `.o` from the final link. So the crate root was renamed to
`r8125_rust_main.rs` — the exact pattern `samples/rust/rust_print` uses
(`rust_print_main.rs` + `rust_print_events.c` → `rust_print.ko`). The
plan §6.1 ASCII layout names it `lib.rs`; that's still the **role**.

## Build

```bash
cd <repo>            # from rtl8125-rs/ root
make                 # invokes the kernel build with M=$(CURDIR)/src
```

`Makefile` is at the repo root and forwards to the kernel build (plan §6.1);
`src/Kbuild` carries `obj-m += r8125_rust.o`. Toolchain pin: `rustc-1.93` —
do not override to a rustup default. M1's evidence file documents the gate run.
