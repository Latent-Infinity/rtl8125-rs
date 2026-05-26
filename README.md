# rtl8125-rs

Experimental Rust-for-Linux driver for Realtek RTL8125 2.5 GbE network
controllers.

This repository is an out-of-tree Linux kernel module. It explores how much of
an RTL8125 driver can live in Rust today while still using small C bridge code
for kernel networking APIs that are not yet exposed through stable Rust
abstractions.

License: GPL-2.0. See `LICENSE`.

## Scope

`rtl8125-rs` targets Realtek RTL8125-class PCIe Ethernet controllers, with the
current validation work focused on RTL8125B hardware.

The driver includes:

- Rust PCI probe, device state, register access wrappers, DMA/ring ownership,
  TX/RX paths, NAPI polling, PHY setup, checksum offload, scatter-gather, and
  TSO support.
- A small C bridge for `net_device`, NAPI, `sk_buff`, PHY/MDIO, ethtool stats,
  and other kernel networking interfaces that Rust-for-Linux does not yet
  expose directly.
- Static CI scripts that enforce the unsafe boundary, C bridge ownership
  contracts, counter accounting, cache-padding conventions, Clippy cleanliness,
  and NAPI queue/IRQ invariants.
- Hardware-oriented validation harnesses for counter invariants, packet
  mutation, module unload under traffic, FLR cycles, ASPM idle soak, active
  traffic soak, and syzkaller control-plane fuzzing.

This is not production driver software. Treat it as a research and engineering
prototype for Rust kernel-driver development on RTL8125 hardware.

## Safety Model

The Rust crate root denies unsafe code. Unsafe operations are concentrated in
`src/unsafe_boundary.rs`, which is the only Rust source file allowed to opt into
`unsafe_code`; this is enforced by `.unsafe-allowlist` and CI.

The C bridge is intentional and part of the safety model. It provides a narrow,
audited boundary around kernel networking objects that Rust currently cannot
represent directly, especially `struct net_device`, `struct napi_struct`, and
`struct sk_buff`. The ownership contract for that bridge is documented in
`src/netdev_bridge.h`.

The project does not claim to be a fully safe Rust driver. The goal is to keep
unsafe code and C interop explicit, reviewable, and mechanically checked.

## Build

This project does not use Cargo.

Build it through Kbuild from the repository root:

```sh
make
```

Clean generated module artifacts:

```sh
make clean
```

Run the kernel Clippy path:

```sh
make CLIPPY=1
```

The selected kernel tree is the toolchain authority. On the current validation
setup, the Makefile defaults to:

- `RUSTC=rustc-1.93`
- `BINDGEN=bindgen`
- `CLIPPY_DRIVER=/usr/lib/rust-1.93/bin/clippy-driver`

Do not use `cargo build` or `cargo clippy`; there is no `Cargo.toml`, and Cargo
cannot build this kernel module.

## Quality Gates

Run the local static and build checks with:

```sh
bash ci/run_checks.sh
```

The CI scripts check, among other things:

- the unsafe allowlist and non-increasing unsafe census
- raw MMIO containment
- C bridge lifecycle and ownership invariants
- checksum, scatter-gather, and TSO path structure
- BTF build wiring
- RTL8125B initialization parity checks
- per-CPU disposition counter infrastructure
- cache-padding conventions for cross-context atomics
- NAPI budget, IRQ masking, and TX queue hysteresis
- kernel-build Clippy warnings

Hardware-required tests live in `ci/` as runnable harnesses but are not part of
the default static check set because they require the validated RTL8125 test
host or guest.

## Repository Layout

| Path | Purpose |
|---|---|
| `src/` | Rust driver core plus C bridge files used by the composite Kbuild module |
| `src/netdev_bridge.h` | Canonical C bridge ownership and `sk_buff` contract |
| `src/unsafe_boundary.rs` | The single Rust unsafe boundary module |
| `ci/` | Static checks and hardware validation harnesses |
| `docs/` | Design notes, standards, validation reports, and milestone close-out docs |
| `docs/RUST_STANDARDS.md` | Project-specific Rust quality and performance rubric |
| `docs/RTL8125_Rust_Driver_Implementation_Plan.md` | Original implementation plan |
| `docs/baseline/` | Captured validation artifacts and performance baselines |
| `tools/` | Reference-fetching and VFIO helper scripts |
| `references/` | Gitignored reference checkouts; fetched locally, not vendored |

## References and Provenance

Reference source trees are fetched into `references/`, which is intentionally
gitignored. Use:

```sh
tools/fetch_references.sh
```

Those trees are for reading and comparison only. They are not vendored into this
repository. See `references/PROVENANCE.md` after fetching.

## Hardware Notes

The current validation target is RTL8125B, observed as XID `0x641`, PCI device
ID `[10ec:8125]`, revision `0x05`.

Validation has been done in a VFIO-isolated guest on a debug kernel with Rust
support and kernel debugging options enabled. Hardware-specific paths,
especially PHY, ASPM, FLR, and traffic soak tests, should be rerun on any new
platform before treating results as representative.

## Development Notes

- Keep hot paths allocation-free and statically dispatched.
- Keep `napi::poll`, `netdev::ndo_start_xmit`, and IRQ handling aligned with
  `docs/RUST_STANDARDS.md`.
- Keep new unsafe Rust inside `src/unsafe_boundary.rs` unless the allowlist and
  safety model are deliberately updated.
- Update CI checks when adding a new invariant that can be enforced
  mechanically.
- Do not commit generated module artifacts or fetched reference sources.

Milestone status and historical validation notes belong in `docs/`, not in this
README.
