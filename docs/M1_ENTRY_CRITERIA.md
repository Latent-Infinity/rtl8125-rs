# M1 Entry Criteria — live tracker

Mirrors plan §15. **M1 (writing driver code) does not begin until every box is
checked and the artifact is committed.** Status as of 2026-05-18 (post asset
gathering + non-destructive M0). Evidence: `docs/baseline/`, `references/`,
`docs/VALIDATION_REPORT.md`.

Legend: ✅ done · 🟡 partial / needs a privileged or operator step · ⛔ blocked ·
⬜ not started

| # | §15 criterion | Status | Evidence / what remains |
|---|---|---|---|
| 1 | MS-A2 hardware inventory (CPU SKU, RAM, exact NIC revisions incl. RTL8125 sub-rev) | 🟡 | `baseline/hw_*`, `chip_revision.txt` → **RTL8125B XID 0x641 rev 0x05**. `dmidecode` (CPU SKU / populated RAM) needs `sudo` re-run of `capture_m0_baseline.sh` |
| 2 | Ubuntu 26.04 LTS on host with selected kernel | ✅ | Ubuntu 26.04 "resolute", `7.0.0-15-generic` (`baseline/hw_uname.txt`) |
| 3 | `make LLVM=1 rustavailable` accepted; versions recorded | ⛔ | **FAILS**: `bindgen` not found (`baseline/rust_toolchain.txt`). Kernel wants rustc 1.93.1 / LLVM 21. Fix: install kernel-pinned `rustc`+`rust-src`+`bindgen` (Validation finding 1) |
| 4 | Trivial OOT Rust module builds **and loads** against the exact guest kernel | ⛔ | **Build FAILS**: `E0463 can't find crate for core` + `KDIR/rust` dangling (`baseline/oot_rust_buildtest.txt`). Needs `linux-lib-rust-7.0.0-15-generic` + pinned toolchain, then re-test build *and* `insmod` |
| 5 | `CONFIG_RUST/MODVERSIONS/DMA_API_DEBUG/DEBUG_LOCK_ALLOC/KASAN/KCSAN/DEBUG_KMEMLEAK` feasibility recorded | ✅ (recorded) ⛔ (feasibility) | `baseline/kernel_config.txt`: RUST+MODVERSIONS ✅; **all five debug configs `not set`** on stock generic → guest needs a custom debug kernel (Validation finding 2) |
| 6 | Secure Boot state captured | ✅ | `baseline/secureboot.txt`: **enabled**, UEFI, Canonical MOK CA. Guest may disable; host needs MOK/signing |
| 7 | Physical test topology documented (peer, cable/switch, EEE, link speed) | ⬜ | `baseline/TOPOLOGY.md` **template only** — operator must complete; RTL8125 currently no-carrier (no cable) |
| 8 | VFIO passthrough executed end-to-end; guest sees the device | ⬜ | Destructive M0 (out of this pass's scope). `tools/bind_vfio.sh` ready (`03:00.0`, `driver_override`) |
| 9 | IOMMU group isolation verified (or ACS decision recorded) | ✅ | `baseline/iommu_group.txt`: **group 18, RTL8125 alone — isolation-safe** |
| 10 | L2 isolation — Realtek port not on mgmt switch domain | ⬜ | Operator step. Note: host runs **Kubernetes**; mgmt currently on **Wi-Fi**, I226-V down (Validation finding 3) |
| 11 | M0 baseline numbers (`r8169`, optionally `r8125`) in `docs/baseline/` | 🟡 | Device facts captured; **iperf3 baselines NOT taken** (destructive M0 / needs a peer) |
| 12 | `tools/bind_vfio.sh` / `unbind_vfio.sh` using `driver_override`, committed | ✅ | Implemented with real address `0000:03:00.0` |
| 13 | Guest serial-console capture configured + tested with a deliberate `panic()` | ⬜ | Requires the guest to exist (post-VFIO) |
| 14 | CI scaffold builds an empty Rust module against the validated kernel, in the guest | 🟡 | `ci/` checks scaffolded; the build job depends on #3/#4/#5 being green |
| 15 | Agent workflow rules encoded in CI | ✅ (scaffold) | `ci/check_dco_assistedby.sh` enforces §9.2; wire into real CI when a remote exists |
| 16 | `.unsafe-allowlist` present (only `src/unsafe_boundary.rs`); CI enforces | ✅ | `.unsafe-allowlist` + `ci/check_unsafe_allowlist.sh` |
| 17 | Document reviewed & signed off by the human owner | ⬜ | Pending owner review of this report + recommended §-edits |
| **+** | **(proposed new)** debug+Rust guest kernel built & boots | ⛔ | Validation finding 2 — the true M1 gate. Recommend adding to §15 |

## Critical path to M1 (in order)

1. **Install kernel-pinned Rust toolchain on the build host** (operator, root):
   `linux-lib-rust-7.0.0-15-generic`, the kernel's `rustc 1.93.1` + `rust-src`,
   `bindgen`, `dwarves` (`pahole`). Re-run `tools/capture_m0_baseline.sh` →
   criteria 3 & 4 build step should go green.
2. **Build the debug+Rust guest kernel** (finding 2). Unblocks 5/14 and the
   M1/M3/M5 gates.
3. **Destructive M0**: complete `TOPOLOGY.md`, pin mgmt to I226-V, isolate L2
   from the k8s domain, run `tools/bind_vfio.sh`, launch the guest, take
   `r8169`/`r8125` iperf3 baselines, test the serial-console panic path.
4. **Owner sign-off** on the plan edits in `docs/VALIDATION_REPORT.md` §5.

Only then does M1 begin.
