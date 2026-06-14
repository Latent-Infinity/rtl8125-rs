# M1 Entry Criteria — live tracker

Mirrors plan **§15 (v3.4)**. **M1 (writing driver code) does not begin until
every box is checked and the artifact is committed.**

> ## ✅ M1 IS OPEN — 2026-05-22
> Every M1 gate is ✅. The only unchecked rows (7, 10, 11) are **M0b** items
> that gate **M4**, not M1. Driver code may now begin (see "Critical path"
> below). Last updated **2026-05-22**, after the destructive M0a steps: host
> 100× VFIO bind-cycle, guest NIC passthrough, serial-console panic test, and
> the trivial-Rust-module load-loop in the debug guest.

Evidence: `docs/baseline/`, `references/`, `docs/VALIDATION_REPORT.md`.

**M0a vs M0b.** M0a (pre-link, RJ45 unplugged) is the non-destructive
fact-discovery + automation pass tracked here; M1–M3 may proceed once the M0a
gates are green. **M0b** (physical-link baseline: topology, peer, EEE,
`r8169`/`r8125` iperf3) is *not* an M1 gate — it is required before **M4**
(first packet-moving milestone). Rows 7/10/11 below are M0b items and do not
block M1.

Legend: ✅ done · 🟡 partial / needs a privileged or operator step · ⛔ blocked ·
⬜ not started

| # | §15 criterion | Status | Evidence / what remains |
|---|---|---|---|
| 1 | MS-A2 hardware inventory (CPU SKU, RAM, exact NIC revisions incl. RTL8125 sub-rev) | ✅ | `baseline/hw_dmidecode.txt` (2026-05-22, sudo): **AMD Ryzen 9 9955HX** 16C/32T, **32 GB DDR5-5600** (1 of 2 DIMM slots populated), MS-A2 board. NIC: **RTL8125B XID 0x641 rev 0x05** (`baseline/chip_revision.txt`, plan §3.1 / §16 Q1) |
| 2 | Ubuntu 26.04 LTS on host with selected kernel | ✅ | Ubuntu 26.04 "resolute", `7.0.0-15-generic` (`baseline/hw_uname.txt`) |
| 3 | `make LLVM=1 rustavailable` accepted; versions recorded | ✅ | `baseline/rust_toolchain.txt`: `Rust is available!`, rustc 1.93.1 / LLVM 21 recorded |
| 4 | Trivial OOT Rust module builds **and loads** against the exact guest kernel | ✅ | Build: `baseline/oot_rust_buildtest.txt` (`.ko BUILT OK`). Load: `baseline/guest_oot_loadloop.txt` — 100× `insmod`/`rmmod` in the debug+Rust guest, refcount 0 each cycle, zero kmemleak/lockdep/BUG/WARN |
| 5 | `CONFIG_RUST/MODVERSIONS/DMA_API_DEBUG/DEBUG_LOCK_ALLOC/KASAN/KCSAN/DEBUG_KMEMLEAK` feasibility recorded | ✅ | `baseline/guest_debug_rust_kernel.config`: Rust, MODVERSIONS, DMA_API_DEBUG, lockdep, kmemleak, KASAN enabled — guest built **and boots** them (the Phase 6 panic trace shows live KASAN+lockdep frames). `CONFIG_KCSAN` is excluded from this KASAN build (config-level conflict); a separate KCSAN guest kernel covers the M3/M5 race soak — not an M1 gate |
| 6 | Secure Boot state captured | ✅ | `baseline/secureboot.txt`: **enabled**, UEFI, Canonical MOK CA. Guest may disable; host needs MOK/signing |
| 7 | Physical test topology documented (peer, cable/switch, EEE, link speed) | ✅ | `baseline/TOPOLOGY.md` fully populated 2026-05-25. Direct Cat6 cable, no switch; host I226-V `enp4s0` is the peer; both ends auto-negotiated 2500 Mb/s Full-Duplex; EEE state, MAC, driver/fw all recorded. Evidence `baseline/m0b_proof.txt` |
| 8 | VFIO passthrough executed end-to-end; guest sees the device | ✅ | Guest `rtl8125-guest` enumerates the RTL8125 at `05:00.0` (`baseline/guest_lspci_rtl8125.txt`). Host 100× r8169↔vfio-pci bind-cycle clean — `baseline/vfio_bindcycle_dmesg.txt` |
| 9 | IOMMU group isolation verified (or ACS decision recorded) | ✅ | `baseline/iommu_group.txt`: **group 18, RTL8125 alone — isolation-safe** |
| 10 | L2 isolation — Realtek port not on mgmt switch domain | ✅ | 2026-05-25: RTL8125 (guest enp5s0) is on a **direct cable** to host I226-V (enp4s0), private `10.0.0.0/24`. Host mgmt + k3s stay on Wi-Fi `wlp6s0` (192.168.68.x). tcpdump on enp4s0 sees only 10.0.0.x traffic — no main-LAN multicast leak. Evidence `baseline/TOPOLOGY.md`, `baseline/iperf3/m0b_peer_capture.pcap` |
| 11 | M0 baseline numbers (`r8169`, optionally `r8125`) in `docs/baseline/` | ✅ | 2026-05-25: 8 r8169 iperf3 runs captured (TCP/UDP × 1500/9000 MTU × both directions) — `baseline/iperf3/iperf3_r8169_*.json`. TCP hits 2.33–2.48 Gb/s (93–99 % of 2.5GbE wire); see `baseline/TOPOLOGY.md` for the table + the documented UDP-asymmetry note. r8125 OOT module not installed (not applicable) |
| 12 | `tools/bind_vfio.sh` / `unbind_vfio.sh` using `driver_override`, committed | ✅ | Implemented with real address `0000:03:00.0` |
| 13 | Guest serial-console capture configured + tested with a deliberate `panic()` | ✅ | `baseline/guest_serial_panic_proof.txt`: deliberate sysrq-c panic captured as text on the host serial console (full oops trace through "end Kernel panic"). VM XML carries a libvirt `<log>` on the serial device |
| 14 | CI scaffold builds an empty Rust module against the validated kernel, in the guest | ✅ | Empty Rust module built in the guest against `/lib/modules/7.0.0/build` (`baseline/guest_oot_loadloop.txt`). `ci/run_checks.sh` green; the guest build job wires into real CI once a remote exists |
| 15 | Agent workflow rules encoded in CI | ✅ (scaffold) | `ci/check_dco_assistedby.sh` enforces §9.2; wire into real CI when a remote exists |
| 16 | `.unsafe-allowlist` present (only `src/unsafe_boundary.rs`); CI enforces | ✅ | `.unsafe-allowlist` + `ci/check_unsafe_allowlist.sh` |
| 17 | Document reviewed & signed off by the human owner | ✅ | Owner directed and approved the six `VALIDATION_REPORT.md` §5 edits → applied as plan **v3.4** (plan §17 changelog), 2026-05-18 this session. Plan body now coherent at v3.4 |
| 18 | **Debug+Rust guest kernel built & boots** (`CONFIG_RUST`+`KASAN`+`KCSAN`+`DEBUG_LOCK_ALLOC`+`PROVE_LOCKING`+`DEBUG_KMEMLEAK`+`DMA_API_DEBUG`) | ✅ | Built 2026-05-19 (`/home/operator/kbuild/linux-image-7.0.0*_amd64.deb`); **boots in the VFIO guest** — runs `7.0.0 #2`, load-loops Rust modules (`baseline/guest_oot_loadloop.txt`), survives the deliberate panic test. KASAN build; KCSAN is excluded by a config conflict → separate KCSAN guest kernel for the M3/M5 race soak (not an M1 gate) |

## Critical path to M1 (in order)

> **▶ Executable form: [`BRINGUP_RUNBOOK.md`](BRINGUP_RUNBOOK.md).** That
> file is the step-by-step, copy-pasteable version of the path below — every
> command, an acceptance check per step, the tracker row each step clears, and
> the exact evidence to commit. A human can follow it top to bottom. The
> summary below is the map; the runbook is the territory.

✅ **Owner sign-off (#17) — DONE 2026-05-18.** The six `VALIDATION_REPORT.md`
§5 edits were owner-directed and applied as plan v3.4. The remaining path is
operator/root and physical work — none of it is code, and none of it is M0b:

1. ✅ **Install the distro kernel-rust toolchain set on the build host — DONE
   2026-05-19.** Criteria **3** is green and the build half of **4** is green:
   `linux-lib-rust-7.0.0-15-generic`, kernel-pinned `rustc 1.93.1`, `bindgen`,
   `dwarves` (`pahole`) are now usable through `tools/capture_m0_baseline.sh`.
2. ✅ **Build the KASAN/debug+Rust guest kernel packages — DONE 2026-05-19.**
   Criteria **5** and the build half of **18** are now backed by
   `baseline/guest_debug_rust_kernel.config` and the `.deb` packages under
   `/home/operator/kbuild/`. Host stays stock; only the guest kernel is
   custom. A separate KCSAN guest kernel is still needed for race-soak coverage.
3. ✅ **Remaining M0a operator steps — DONE 2026-05-22.** Custom debug+Rust
   kernel installed and booted in the VFIO guest; host 100× `bind_vfio.sh`
   cycle clean (#8); guest enumerates the RTL8125 (#8); serial console
   panic-tested (#13); trivial Rust module 100× load-loop in the guest (#4,
   #14). `docs/BRINGUP_RUNBOOK.md` Phases 4–8 are closed (Phase 3 netplan
   switchover deferred — it gates M0b row 10, not M1).

   → **M1 has begun.**

4. **M0b (gates M4, *not* M1)** — complete `docs/baseline/TOPOLOGY.md`, pin host
   mgmt to the I226-V, isolate L2 from the Kubernetes domain, then take
   `r8169`/`r8125` iperf3 baselines against a documented peer. Required before
   M4, the first packet-moving milestone.
