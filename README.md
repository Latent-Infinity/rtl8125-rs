# rtl8125-rs — AI-assisted Rust driver for the Realtek RTL8125 (2.5 GbE)

**Status: M4-full development — M1/M2/M3/M4-skeleton are complete, M0b physical-link baseline is captured, and peer-driven M4-full packet-path work is active.** See [`docs/SESSION_RESUME.md`](docs/SESSION_RESUME.md) and [`src/README.md`](src/README.md) for the current handoff.

License: **GPL-2.0** (matches the Linux kernel — see `LICENSE`).

This repository implements the engineering plan in
[`docs/RTL8125_Rust_Driver_Implementation_Plan.md`](docs/RTL8125_Rust_Driver_Implementation_Plan.md)
(v3.4). Read that document first; it is authoritative. This README only states
what a reader must know before touching anything.

## What this is, stated honestly (plan §5.3)

This is **not** a "fully safe Rust driver". It is a layered prototype:

- A Rust core (`src/`) that owns PCI probe through descriptor-ring ownership,
  gated behind `#![deny(unsafe_code)]` at the crate root, with exactly one
  module — `src/unsafe_boundary.rs` — permitted to locally `#![allow(unsafe_code)]`
  (enforced by `.unsafe-allowlist` + CI).
- A small, audited C shim (`cshim/netdev_bridge.c`, target < 400 LOC) bridging
  the Rust core to `net_device` / NAPI / `sk_buff` **until** the upstream Rust
  netdev abstractions stabilize. The shim's value is the documented `sk_buff`
  ownership contract (plan §6.3), not its source.

The C shim is disclosed here, in code comments, and in any future RFC.
Misrepresenting the safety guarantee is worse than acknowledging the shim.

## Build model (plan §6.1 — read before you `cargo` anything)

There is **no `Cargo.toml`, no `rust-toolchain.toml`, no `cargo build`** in the
critical path. This is an out-of-tree kernel Rust module:

- Built via the kernel build system: `make -C $KDIR M=$PWD`.
- Lints via `make CLIPPY=1` — **not** `cargo clippy`.
- `rust-project.json` is *generated* for rust-analyzer; it is not a source of truth.
- **Toolchain authority is the kernel tree, not this project.** The accepted
  `rustc` / LLVM / `bindgen` versions are whatever
  `make LLVM=1 rustavailable` against the selected kernel tree accepts.
  (On the current dev box this is rustc **1.93.1** / LLVM **21**, even though
  userspace `cargo` is 1.95.0 — see `docs/VALIDATION_REPORT.md`.)

## Repository layout

| Path | Purpose |
|---|---|
| `docs/RTL8125_Rust_Driver_Implementation_Plan.md` | The authoritative plan (v3.4) |
| `docs/VALIDATION_REPORT.md` | Plan claims vs. observed reality on the dev box |
| `docs/M1_ENTRY_CRITERIA.md` | The §15 checklist gating M1; M1 is blocked until all pass |
| `docs/M0a_TO_M1_RUNBOOK.md` | **Step-by-step operator runbook** to clear every M1 gate (start here to get unblocked) |
| `docs/baseline/` | M0a pre-link fact-discovery artifacts; M0b physical-link baseline (plan §7 M0a/M0b) |
| `docs/perf/` | M6 before/after performance numbers (plan §7 M6) |
| `src/` | Rust core plus the co-located C bridge required by kbuild's composite-module layout |
| `cshim/` | C bridge rationale; source lives in `src/netdev_bridge.{c,h}` |
| `tools/` | `fetch_references.sh`, `bind_vfio.sh`, `unbind_vfio.sh`, `capture_m0_baseline.sh` |
| `ci/` | Mechanical-enforcement checks (plan §9.4) |
| `references/` | **Gitignored.** GPL reference sources, fetched not copied (plan §9.3) |

## References are read, never copied (plan §9.3)

`references/` is **gitignored**. Run `tools/fetch_references.sh` to populate it
with pinned upstream checkouts of `r8169`, the Realtek out-of-tree `r8125`, the
`ewaldc` rewrite, the Rust-for-Linux tree, and the Ubuntu kernel source. These
are **reference material for understanding only**. Concepts are paraphrased and
re-implemented from datasheet/behavior primaries; GPL source is not copied. See
`references/PROVENANCE.md`.

## AI agent policy (plan §9.2 — non-negotiable)

Agents accelerate this project; they do not author it. An AI agent never adds
`Signed-off-by:`. The human submitter holds full DCO responsibility. An optional
`Assisted-by:` trailer follows the kernel's documented format and never stands
alone. CI enforces this.

## Hardware target

Realtek RTL8125 2.5 GbE — resolved as **RTL8125B, XID `0x641`, rev `0x05`, fw
`rtl8125b-2_0.0.2`** (plan §3.1 / §16 Q1). On the development host (Minisforum
MS-A2) the device is at PCI **`0000:03:00.0`** `[10ec:8125]`, alone in IOMMU
group 18 (isolation-safe). The plan's `07:00.0` is illustrative only; the real
address is wired into `tools/bind_vfio.sh` / `unbind_vfio.sh`.

A faulty driver is contained in a VFIO-isolated guest. The intended host
lifeline is the Intel I226-V — **but on this unit that is not yet realized**:
host management is currently on Wi-Fi, the I226-V is down, and the box runs
Kubernetes. Before any destructive M0b step the operator MUST pin host
management to the I226-V and isolate the RTL8125 test segment from the
Kubernetes/host L2 domain (plan §1.2 / §8.1).
