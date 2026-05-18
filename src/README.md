# `src/` — Rust core

**Status: M0. Intentionally empty of driver code.**

Per the plan, M1 (code-writing) begins **only** when every entry criterion in
[`../docs/M1_ENTRY_CRITERIA.md`](../docs/M1_ENTRY_CRITERIA.md) is met and checked
in. Writing driver code now would violate the gate. This file documents the
*planned* module layout (plan §6.1) so the structure is agreed before code:

| Module | Responsibility | First milestone |
|---|---|---|
| `lib.rs` | `module!` entry, PCI driver registration; crate-root `#![deny(unsafe_code)]` | M1 |
| `pci.rs` | probe/remove, BAR mapping, IRQ acquisition | M1 |
| `hw.rs` | revision detection, reset sequence, per-revision init table | M2 |
| `mmio.rs` | typed register read/write wrappers (only MMIO site outside `unsafe_boundary`) | M2 |
| `regs.rs` | curated register map (offsets, bitfields) | M2 |
| `dma.rs` | coherent + streaming buffer allocation | M3 |
| `ring.rs` | TX/RX descriptor rings, typed indices | M3 |
| `skb.rs` | typed `sk_buff` wrappers + FFI ownership state machine (§6.3) | M4 |
| `pm.rs` | suspend/resume callbacks, ASPM policy, runtime PM (§3.3) | M2 (ASPM) / M5 (suspend) |
| `napi.rs` | NAPI poll-path Rust side; calls into C shim | M4/M5 |
| `netdev.rs` | thin Rust→C bridge surface | M4 |
| `stats.rs` | counters, ethtool surfaces | M4+ |
| `trace.rs` | tracepoint definitions (experimental/versioned until M6, §16 Q4) | M4+ |
| `unsafe_boundary.rs` | the **only** module permitted `#![allow(unsafe_code)]` | M1 |

The toolchain-validation "hello world" OOT Rust module used to satisfy the §15
"trivial OOT Rust module builds and loads" criterion is **not** kept here — it
is exercised by `tools/check_oot_rust.sh` against the kernel's own
`samples/rust`, so this directory stays free of non-driver code.
