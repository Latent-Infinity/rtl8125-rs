# `src/` — driver core

**Status: RTL8125B packet path with MSI/MSI-X fallback, jumbo RX buffers,
offload gates, MDIO/PHY plumbing, and bounded C shim review contracts.**

- Rust PCI skeleton passed 2026-05-23 — evidence
  [`../docs/baseline/m1_gate_proof.txt`](../docs/baseline/m1_gate_proof.txt).
- Register / reset / ASPM-log passed 2026-05-24 — evidence
  [`../docs/baseline/m2_gate_proof.txt`](../docs/baseline/m2_gate_proof.txt).
- Cold DMA ring allocation passed 2026-05-24 — evidence
  [`../docs/baseline/m3_gate_proof.txt`](../docs/baseline/m3_gate_proof.txt).
- Physical topology and r8169 peer baselines captured 2026-05-25
  in [`../docs/baseline/TOPOLOGY.md`](../docs/baseline/TOPOLOGY.md) and
  `../docs/baseline/iperf3/`.
- Driver path — `net_device` registration, IRQ/NAPI, TX/RX,
  offload gates, jumbo RX pool, and MSI/INTx rollback are implemented and
  covered by the static gates in [`../ci/run_checks.sh`](../ci/run_checks.sh).

## Module layout

| Module | Responsibility | Layer | Status |
|---|---|---|---|
| `r8125_rust_main.rs` | crate root: `module_pci_driver!`, crate-root `#![deny(unsafe_code)]`, module parameters (`inject_reset_timeout`, `force_aspm`, `intx_only`, `aspm_force_off`) | core | ✅ |
| `pci.rs` | `pci::Driver` impl: probe/unbind, BAR mapping, device-id table, DMA mask, IRQ-vector mode selection, heap-in-place `NetdevState` construction | core | ✅ |
| `regs.rs` | curated register map, descriptor bits, IRQ masks, jumbo/offload constants | core | ✅ |
| `mmio.rs` | typed register read/write wrappers; only MMIO site outside `unsafe_boundary` | core | ✅ |
| `hw.rs` | XID-based revision detection, reset sequence, RTL8125B hardware init, chip-side ASPM policy, jumbo `RxMaxSize` | core | ✅ |
| `pm.rs` | probe-time ASPM visibility and documented host-side ASPM API gap | core | ✅ |
| `dma.rs` | DMA ownership notes; coherent rings live in `ring`, streaming RX/TX map/unmap flows live in netdev/cshim helpers | core | ✅ |
| `ring.rs` | TX/RX descriptor rings, typed indices, canaries, compile-time layout checks | core | ✅ |
| `skb.rs` | `DriverOwnedSkb` domain wrapper and TX/RX skb ownership verbs | core | ✅ |
| `napi.rs` | NAPI poll path: RX delivery, TX completion reaping, queue hysteresis, IRQ re-arm | hot path | ✅ |
| `netdev.rs` | Rust netdev glue: `BridgeOps` vtable, `NetdevHandle` RAII, ndo_open/stop/xmit, IRQ handler, TX/RX rollback guards | hot path | ✅ |
| `netdev_bridge.h` + `netdev_bridge*.c` | bounded C shim for net_device/NAPI/sk_buff/MDIO/PHY/ethtool/RX page-pool APIs missing from kernel Rust | cshim | ✅ |
| `unsafe_boundary.rs` | the **only** module permitted `#![allow(unsafe_code)]`; all FFI declarations, unsafe impls, and raw pointer conversions | boundary | ✅ |

## Naming note — `r8125_rust_main.rs` vs the plan's "lib.rs"

Initially the crate root was `r8125_rust.rs` (matching the `obj-m` target).
Once the driver became a **composite** module (Rust + C objects linking into a
single `r8125_rust.ko`), naming the Rust component the same as the
composite triggers a kbuild circular-dep warning and silently drops the
Rust `.o` from the final link. So the crate root was renamed to
`r8125_rust_main.rs` — the exact pattern `samples/rust/rust_print` uses
(`rust_print_main.rs` + `rust_print_events.c` → `rust_print.ko`). The
conventional ASCII layout names it `lib.rs`; that's still the **role**.

## Build

```bash
cd <repo>            # from rtl8125-rs/ root
make                 # invokes the kernel build with M=$(CURDIR)/src
```

`Makefile` is at the repo root and forwards to the kernel build;
`src/Kbuild` carries `obj-m += r8125_rust.o`. Toolchain pin: `rustc-1.93` —
do not override to a rustup default. The evidence file documents the gate run.
