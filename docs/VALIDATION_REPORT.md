# RTL8125 Rust Driver Plan — Validation Report

**Generated:** 2026-05-18 · **Host:** `ms-a2-controller` (the actual Minisforum MS-A2) ·
**Plan validated:** `RTL8125_Rust_Driver_Implementation_Plan.md` v3.2 ·
**Scope:** asset gathering + non-destructive M0 fact discovery. No NIC was
disturbed; no packages were installed; no driver code was written (M1 is gated).

This report maps every material claim, assumption, and risk in the plan to what
was actually observed on the target hardware and against the fetched upstream
sources. Evidence lives in `docs/baseline/` and `references/` (manifest:
`references/MANIFEST.txt`).

---

## 0. Verdict

**The plan is sound and its core technical claims validate.** §5.1 (mature Rust
PCI/DMA/MMIO) is confirmed against the *exact* running-kernel source; §5.2
(netdev/sk_buff/NAPI not mainline) is confirmed (only `net::phy` exists); §9.2
(kernel AI policy) is faithful to the real `coding-assistants.rst`; §4's
motivating bug citation is verbatim-accurate.

**Four corrections / refinements are required before M1**, none fatal, all
caused by *this box's current state*, not by flaws in the approach:

1. **The §13/§16 "Ubuntu lacks Rust metadata" High risk is mis-scoped.** It is
   not "distro doesn't ship it → build a self-managed kernel." It is "three
   apt-installable packages are not yet installed." Downgrade + correct the
   mitigation.
2. **The real M1 blocker is the debug-instrumentation kernel, not Rust
   metadata.** The stock generic kernel has **no** `KASAN/KCSAN/lockdep/
   kmemleak/DMA_API_DEBUG`. The plan's M1/M3/M5 gates *cannot run* on it. The
   VFIO guest needs a purpose-built debug kernel regardless of Rust.
3. **Hardware addresses in the plan are examples, not facts.** RTL8125 is
   `03:00.0` (not `07:00.0`); chip is **RTL8125B XID 0x641**; IOMMU group is
   **isolated** (good). Host management is currently **Wi-Fi**, not the I226-V.
4. **§3.3's "ewaldc changelog is the ASPM database" premise is slightly
   wrong.** ewaldc's git history is 3 commits. The rich ASPM-workaround history
   is in **Realtek-official (99 commits)** + in-source comments. Repoint it.

Detailed M1-entry status: `docs/M1_ENTRY_CRITERIA.md`.

---

## 1. Claim-by-claim validation

| Plan ref | Claim / assumption | Observed on MS-A2 | Verdict |
|---|---|---|---|
| §1.2 | NIC mix incl. RTL8125, I226-V, X710 | RTL8125 `03:00.0` `[10ec:8125]` rev 05; I226-V `04:00.0`; X710 ×2 `05:00.{0,1}`; +MT7922 Wi-Fi `06:00.0` | ✅ confirmed (X710 present as RJ45-less SFP+; plan's "2×10GbE Intel X710" matches) |
| §1.2 | "Intel I226-V pinned host management — SSH never drops" | I226-V (`enp4s0`) is **DOWN**; host connectivity is currently **Wi-Fi `wlp6s0`** (MT7922). Box also runs **Kubernetes** (flannel/cni/veth) | ⚠️ assumption not yet realized — see §3 finding 3 |
| §2 | Ubuntu 26.04 LTS / Linux 7.0 / Rust-for-Linux | Ubuntu 26.04 LTS "resolute", kernel `7.0.0-15-generic`, `CONFIG_RUST=y` | ✅ exact match |
| §2 | "Toolchain authority lies with the kernel tree, not the distro Rust" | Userspace `rustc/cargo 1.95.0`; kernel-authoritative `rustc 1.93.1` / LLVM 21 (`CONFIG_RUSTC_VERSION_TEXT`). Mismatch is real and exactly as predicted | ✅ claim vindicated — see finding 1 |
| §3.1 | Revision detection mandatory; sub-revisions differ | Kernel log: **`RTL8125B, XID 641`**, PCI rev `0x05`, fw `rtl8125b-2_0.0.2`. §16 Q1 now answered | ✅ resolved: target = RTL8125B / XID 0x641 |
| §3.3 | ASPM is a first-class hazard; read the OOT changelog | ASPM compiled in (`CONFIG_PCIEASPM=y`, `_DEFAULT=y`). `lspci -vv` ASPM/L1ss detail needs **root** (not captured unprivileged) | ⚠️ partial — ASPM capability dump deferred to a `sudo` re-run; premise about *where* the changelog lives is off (finding 4) |
| §5.1 | Rust PCI/DMA/MMIO/alloc/pin_init mature & usable | In **Ubuntu-exact** `rust/kernel/`: `pci.rs`, `dma.rs` (`CoherentAllocation::alloc_attrs`), `io.rs`, `io/mem.rs`, `init.rs`, `alloc/` all **present** | ✅ confirmed against the authoritative tree |
| §5.2 | netdev/`sk_buff`/NAPI **not** mainline-stable | `rust/kernel/net/` = **`phy` only** in both Ubuntu tree and rust-for-linux `rust-next`. No `net_device`/`sk_buff`/NAPI | ✅ confirmed — the C-shim (§5.3) is necessary, not optional |
| §6.1 | No Cargo in build path; kernel build authoritative | `make rustavailable` is the gate; userspace cargo is irrelevant. Confirmed by the build-test failure mode | ✅ approach correct |
| §8 | VFIO isolation possible; IOMMU group must be RTL8125-only | IOMMU **on** (27 groups). RTL8125 is **alone in group 18** | ✅ isolation-safe; §16 Q2 resolved; §13 "shared group" Medium risk **retired** for this unit |
| §9.2 | Kernel AI policy: no agent `Signed-off-by`, `Assisted-by:` format | `Documentation/process/coding-assistants.rst` (mainline v7.0) states verbatim: "AI agents MUST NOT add Signed-off-by tags…"; format `Assisted-by: AGENT_NAME:MODEL_VERSION [TOOL1] [TOOL2]` | ✅ plan is faithful to real policy |
| §4 | ewaldc motivating quote | ewaldc `README.md` verbatim: "several hangs/crashes (wrong fragment count with lots of small packets) and occasional data corruption" | ✅ citation accurate |
| §13 | "Ubuntu kernel lacks Rust metadata" = High | Metadata pkg **exists in archive** (`linux-lib-rust-7.0.0-15-generic 7.0.0-15.15`, `resolute-updates/main`); just not installed | ⚠️ **mis-scoped** — see finding 1 |
| §13 | Secure Boot blocks unsigned OOT module | Secure Boot **ENABLED**, UEFI, Canonical MOK CA enrolled | ✅ risk is **live on this host** (mitigable in guest; needs MOK/signing for host) |
| §13 | DMA-ownership bug needs KASAN/KCSAN/DMA_API_DEBUG | **None enabled** in stock generic kernel | ⚠️ blocks the gates — see finding 2 |

---

## 2. Asset inventory (what was gathered)

All in gitignored `references/` (read-only, plan §9.3). Manifest with resolved
SHAs: `references/MANIFEST.txt`. Provenance & licenses: `references/PROVENANCE.md`.

| Asset | Pinned to | Size | Validated content |
|---|---|---|---|
| `linux-mainline` | torvalds `v7.0` `028ef9c9…` | 41 MB | `r8169_main.c` + `rust/`; `Documentation/process/coding-assistants.rst`, `submitting-patches.rst`, `maintainer-netdev.rst` |
| `rust-for-linux` | `rust-next` `5d691905…` (moving) | 209 MB | `rust/kernel/{pci,dma,io,net}.rs`; `net/` = `phy` only (§5.2 evidence) |
| `realtek-r8125-official` | tag `9.016.01-1` `60c86586…` | 1.6 MB | full Realtek OOT `r8125` v9.016.01; **99 commits** of history (the real ASPM/workaround database) |
| `ewaldc-r8125-rewrite` | `master` `527bcbe5…` | 1.3 MB | the rewrite; ASPM/L1 logic in `src/r8125_n.c`; **only 3 git commits** (see finding 4) |
| `ubuntu-kernel-7.0.0-15` | tag `Ubuntu-7.0.0-15.15` | 290 MB | **exact running-kernel source**: `r8169_main.c` + `rust/kernel/` — authoritative for §5.1 |
| `rust-metadata-pkg` | `linux-lib-rust-7.0.0-15-generic 7.0.0-15.15` | 38 MB | the kernel Rust `.deb`, downloaded **not installed** (system change) |

Reproducibility caveats (documented in `PROVENANCE.md`): `rust-next` is a
moving branch (pin recorded, drift expected); `git.launchpad.net` ignores
`--filter` and its annotated tag resolves to a different object than
`ls-remote --refs` (DRIFT warning is benign — tree is correct; `apt-get source
linux=7.0.0-15.15` is the guaranteed-exact alternative).

The **RTL8125 datasheet is NDA** — not fetched, not stored. Public register
primaries are the r8169/r8125 sources above (plan §13 "never write undocumented
registers blind"). Documented in `PROVENANCE.md`.

---

## 3. The four pre-M1 findings (detail)

### Finding 1 — §13/§16 "Rust metadata missing" is mis-scoped (downgrade)

`make LLVM=1 rustavailable` fails with **`bindgen … could not be found`**, and
the OOT build fails with **`error[E0463]: can't find crate for core`** *and*
`KDIR/rust -> <dangling>`. Three independent gaps, **all apt-installable on
stock Ubuntu**, none requiring a self-managed kernel:

1. `linux-lib-rust-7.0.0-15-generic` (kernel Rust metadata) — in archive.
2. The kernel-pinned **`rustc 1.93.1` + `rust-src`** (userspace 1.95.0 has no
   kernel `core`/target) — Ubuntu ships pinned kernel-rust toolchain packages.
3. **`bindgen`** at the kernel-accepted version.
   (Plus `dwarves`/`pahole` and a matching `gcc` for clean builds & §11 layout
   verification — `pahole` reported version `0`.)

**Plan change:** rewrite the §13 mitigation and §16 Q5 framing: the default
recovery is *install the distro-provided kernel-rust toolchain set*, not
"switch the guest to a self-built kernel." Keep the self-built-kernel path —
but for finding 2's reason, not this one.

### Finding 2 — the real M1 blocker: no debug-instrumented kernel

Stock `7.0.0-15-generic` has **`# CONFIG_DMA_API_DEBUG/DEBUG_LOCK_ALLOC/
PROVE_LOCKING/KASAN/KCSAN/DEBUG_KMEMLEAK is not set`**. The plan *requires*:

- M1 gate: lockdep clean + kmemleak clean → needs `DEBUG_LOCK_ALLOC` + `DEBUG_KMEMLEAK`
- M3 gate: `CONFIG_DMA_API_DEBUG`
- M5 gate: 24 h soak under `KASAN` + `KCSAN`

None are satisfiable on any stock Ubuntu generic flavour. **The VFIO guest must
run a purpose-built debug kernel** — and since that kernel is custom anyway, it
is the natural place to also pin the Rust toolchain (finding 1). This *unifies*
the plan's two "maybe self-build" hedges into one decisive M0 deliverable:
**build one debug+Rust guest kernel; the host stays stock.** Recommend
elevating this to an explicit §15 entry criterion (added to the tracker).

### Finding 3 — hardware facts vs. plan examples

| Plan said | Reality | Action |
|---|---|---|
| RTL8125 at `07:00.0` | `0000:03:00.0` | wired into `tools/bind_vfio.sh` |
| revision A/B/BG/… TBD | **RTL8125B, XID 0x641**, rev `0x05`, fw `rtl8125b-2_0.0.2` | §16 Q1 resolved → drives `hw.rs` dispatch |
| IOMMU group may be shared | **group 18, RTL8125 alone** | §13 Medium risk retired for this unit |
| I226-V pins host mgmt | I226-V down; mgmt on **Wi-Fi**; box runs **k8s** | operator must pin mgmt to I226-V and isolate the k8s/L2 domain before destructive M0 (plan §8.1.6) |

### Finding 4 — §3.3 ewaldc-changelog premise

§3.3: *"the out-of-tree r8125 rewrite … its long change-log of ASPM
workarounds is effectively a database … Read it."* But `ewaldc` has **3 git
commits**. The actual workaround history is **Realtek-official's 99 commits** +
in-source comments (`src/r8125_n.c`). Both are now fetched with full history.
**Plan change:** §3.3 should point at *Realtek-official git history + r8125_n.c
comments* (and ewaldc's *code*), not ewaldc's git log.

---

## 4. Risks: status delta vs. plan §13

| Risk (plan §13) | Plan severity | Validated status |
|---|---|---|
| Rust netdev/sk_buff never stabilizes compatibly | High | **Unchanged/confirmed** — only `net::phy` exists; C-shim mandatory |
| Ubuntu kernel lacks Rust metadata | High | **Downgrade → Medium**: apt-installable; *but* see next row |
| (new) No debug-instrumented kernel for the gates | — | **New High** — finding 2; must build a debug+Rust guest kernel |
| Secure Boot blocks unsigned OOT module | High (distribution) | **Confirmed live** on host (Secure Boot on, MOK = Canonical CA) |
| ASPM/L1 mishandling | High | Unchanged; ASPM compiled-in; capability dump needs `sudo` re-run |
| sk_buff FFI ownership leak/double-free | High | Unchanged (design-time; nothing to validate pre-code) |
| RTL8125 IOMMU group shared | Medium | **Retired** for this unit (group 18 isolated) |
| HWE silently bumps rustc, breaks DKMS | High | **Confirmed plausible** — kernel pins 1.93.1 while userspace already drifted to 1.95.0; DKMS-default rejection (§16 Q5) is justified |

---

## 5. Recommended plan edits (for the human owner)

1. **§13 + §16 Q5:** reword the Rust-metadata mitigation to "install
   distro-provided `linux-lib-rust-<ver>` + pinned kernel `rustc`/`rust-src` +
   `bindgen`"; reserve "self-built kernel" for the debug-instrumentation reason.
2. **§7 M0 / §15:** add explicit criterion — *"a debug+Rust guest kernel
   (`KASAN KCSAN DEBUG_LOCK_ALLOC PROVE_LOCKING DEBUG_KMEMLEAK DMA_API_DEBUG`
   + `CONFIG_RUST`) is built and boots in the guest"* — it is the true M1 gate.
3. **§1.2 / §8.1:** record that on this unit host mgmt must be deliberately
   moved to the I226-V and the existing Kubernetes/L2 domain isolated from the
   RTL8125 test segment before any destructive M0 step.
4. **§3.1 / §16 Q1:** fill in *RTL8125B, XID 0x641, rev 0x05, fw
   rtl8125b-2_0.0.2* as the resolved target revision.
5. **§3.3:** repoint the "ASPM workaround database" reference from ewaldc's
   changelog to Realtek-official's git history + `r8125_n.c` comments.
6. **§8 addresses:** globally treat `07:00.0` as illustrative; canonical is
   `0000:03:00.0` (already done in `tools/`).

None of these change the architecture. The layered Rust-core + audited C-shim
design, the unsafe-boundary discipline, and the gated milestones all stand.
