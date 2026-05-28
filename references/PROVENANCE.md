# `references/` — provenance and the read-don't-copy rule

Everything under `references/` (except this file and `.gitkeep`) is
**gitignored** and **fetched, never committed**. Populate it with
`tools/fetch_references.sh`. These trees are **reference material for
understanding only** (plan §9.3):

> GPL `r8125` derivatives are read as references, not copied. Concepts (e.g.,
> "RTL8125B requires this reset sequence") are paraphrased and re-implemented
> from datasheet primaries. Any patch that closely mirrors external GPL code is
> rejected and re-written.

CI (plan §9.4) and human review enforce this. Do not paste from these trees.

## Pinned sources

| name | origin | pinned commit | ref | license | authoritative for |
|---|---|---|---|---|---|
| `linux-mainline` | github.com/torvalds/linux | `028ef9c96e96197026887c0f092424679298aae8` | tag `v7.0` | GPL-2.0 | Upstream `r8169` (§12 baseline); Rust `kernel::pci`/`dma`/`io::mem` to validate §5.1; kernel AI-tools & DCO policy in `Documentation/process/` (§9.2) |
| `rust-for-linux` | github.com/Rust-for-Linux/linux | `5d6919055dec134de3c40167a490f33c74c12581` | branch `rust-next` (**moving** — drift expected) | GPL-2.0 | Most-advanced Rust netdev / `sk_buff` / NAPI / phylib abstractions; the §5.2 "not mainline-stable" status check; the C-shim migration target (§5.3, §7 M7) |
| `realtek-r8125-official` | github.com/awesometic/realtek-r8125-dkms | `60c86586fbe22cea7ed660a629e2d1374cc26196` | tag `9.016.01-1` | GPL-2.0 (Realtek) | Realtek's official OOT `r8125` v9.016.01 via a clean DKMS mirror: feature/perf reference (§12); register *behavior* reference (§13). **The ASPM/L1.x workaround database (plan §3.3, v3.4): ~99 commits of history + the in-source comments in `src/r8125_n.c`** — cloned with FULL history for exactly this reason. Never write undocumented registers blind |
| `ewaldc-r8125-rewrite` | github.com/ewaldc/realtek-r8125-dkms | `527bcbe5ed45c67b20abae73dccc683eb6f0dc2b` | branch `master` | GPL-2.0 | The `ewaldc` rewrite (plan §4, §3.3): valued for its **code and approach** to the "wrong fragment count with lots of small packets / occasional data corruption" fixes that motivate this project (verbatim citation in its `README.md`, plan §4). Only **3 commits** — its changelog is *not* the ASPM database; Realtek-official's history is (validation finding 4) |
| `ubuntu-kernel-7.0.0-15` | git.launchpad.net `~ubuntu-kernel/.../resolute` | `6ed57a7b3d0cdb198711521ba0c88a3ecbf7325e` | tag `Ubuntu-7.0.0-15.15` | GPL-2.0 | **Exact** source of the running kernel (Ubuntu 26.04 LTS, `7.0.0-15-generic`): authoritative for §5.1 API validation and the §15 OOT-Rust-metadata gate |
| `rust-metadata-pkg` | Ubuntu archive (`apt`) | `linux-lib-rust-7.0.0-15-generic` `7.0.0-15.15` | n/a | GPL-2.0 | The kernel Rust library/metadata `.deb`. Its absence on the dev box is the §13/§16 risk — **downgraded High → Medium in plan v3.4** (validation finding 1): it is apt-installable, *not* a self-built-kernel trigger. **Installing** the distro kernel-rust set is the mitigation. Downloaded for reference; **not auto-installed** (system change) |
| `freebsd-src` | github.com/freebsd/freebsd-src | `44eb2883...` (HEAD when fetched 2026-05-26) | branch `main` | BSD-2-Clause | **VERIFIED ABSENT for 8125**: re(4) upstream chip table stops at 8168H/8411B. Reference is kept in tree as a "we checked, no 8125 here" record so future maintainers don't re-investigate. See `docs/FREEBSD_VENDOR_FINDINGS.md` |
| `freebsd-realtek-re-kmod` | github.com/alexdupre/rtl_bsd_drv | `bff7ba434755ec008f58312ff71c3b08a230aabe` | branch `v1.101` | BSD-4-Clause | **Realtek's official BSD driver**, packaged for FreeBSD ports as `net/realtek-re-kmod`. Supports RTL8125/8125B/8126. Useful as a 4th independent vantage point on chip-init order, ASPM defaults (BSD enables ASPM at end of `re_init`; r8169 + we disable), jumbo cap (9K, not 16K), and per-MTU RX buffer sizing. The repo has a `vendor` branch for diffing against the original Realtek source. See `docs/FREEBSD_VENDOR_FINDINGS.md` |

`apt-get source` alternative for the Ubuntu kernel (deb-src is enabled on the
dev box): the source package is **`linux` `7.0.0-15.15`** (the
`linux-image-7.0.0-15-generic` binary maps to the `linux-signed` wrapper; the
real tree is the `linux` source package). The launchpad git tag above is the
primary because it is exact and scriptable.

## RTL8125 datasheet (plan §16 Q1, §13)

The Realtek RTL8125 / RTL8125B datasheet is **under NDA and is not publicly
redistributable**. No datasheet PDF is fetched or stored here. Public,
citable primary sources for register semantics are:

- The register definitions and init/reset sequences in `linux-mainline`
  (`drivers/net/ethernet/realtek/r8169*`) and `realtek-r8125-official`.
- Realtek's public product brief / product-selector page (marketing-level only).
- Community register notes (OpenWrt, kernel mailing-list archives).

Register *behavior* is learned by reading these and the working drivers; the
driver "never writes undocumented registers blind" (plan §13) and bisects
against working drivers via PCI traces when documentation is absent.

## Reproducibility note

Tag-based refs (`v7.0`, `9.016.01-1`, `Ubuntu-7.0.0-15.15`) resolve to a fixed
commit; the fetch script verifies the pin and warns on drift (a moved tag is a
red flag — investigate). `rust-for-linux/rust-next` is a moving integration
branch: drift from the recorded pin is expected and benign, but the recorded
SHA is what any §5.2 finding in `docs/VALIDATION_REPORT.md` was assessed
against.
