# Upstream-readiness critical review

What a Linux netdev maintainer expects to see on first submission of a new
PCI Ethernet driver, what this tree already provides, and the concrete gaps
that this pass closes (or notes for a follow-up).

The framing assumes a netdev RFC posting against `linux-next` with cc to
`netdev@vger.kernel.org`, `linux-kernel@vger.kernel.org`, and
`rust-for-linux@vger.kernel.org`. The cshim shape adds a second axis of
review -- kernel-Rust hasn't merged a netdev abstraction yet, so any patch
series must justify the bridge approach. The maintainer-expectations list
below was assembled from the netdev FAQ, `Documentation/process/`,
`Documentation/networking/`, and the comparison r8169 thread history.

## Maintainer expectations vs current state

| Expectation | Status | Where |
|---|---|---|
| **SPDX license header on every source file** | done | All `src/*.{rs,c,h}` carry `SPDX-License-Identifier: GPL-2.0` (auto-gen `r8125_rust.mod.c` is exempt by convention) |
| **`MODULE_LICENSE` / `description` / `authors`** | done | Rust `module_pci_driver!` macro covers all three; cshim TUs set `MODULE_LICENSE("GPL v2")` |
| **`MODULE_DEVICE_TABLE(pci, ...)` for hot-plug autoload** | done | `kernel::pci_device_table!()` macro at `src/pci.rs:74` emits both `PCI_TABLE` and `MODULE_PCI_TABLE` |
| **DMA discipline (`dma_set_mask_and_coherent`, sync APIs, `dma_wmb`/`dma_rmb`)** | done | `set_64bit_dma_mask` at probe; `dma_sync_single_for_{cpu,device}` paired in cshim RX path; `dma_rmb` after OWN-clear; `dma_wmb` before OWN-publish (commit `cf802f8` + `69bc442`) |
| **Memory-ordering comments on every barrier** | done | Every `dma_*mb` site carries the r8169 cross-reference + ownership narrative |
| **`devm_*` / lifetime-safe resource acquisition** | done | Rust `Devres<pci::Bar>`, `kernel::pci::Bar`, RAII guards for IRQ + DMA frags (task #61) |
| **Clean rmmod path; no leaks on probe failure** | done | `pci.rs` unbind sequencing documented; 100-cycle rmmod-under-traffic stress green (task #69); 20-cycle KVM stress green |
| **NAPI contract (budget, completion, IRQ masking)** | done | `napi.rs` module docstring lists the M5 section 7 contract; `ci/check_napi_contract.sh` enforces statically |
| **ethtool baseline (`get_link`, `get_drvinfo`, stats)** | done | `get_link`, `get_drvinfo`, `-S` stats; **plus** the RSS control plane (`get/set_rxfh`, `get_rxfh_*_size`, `get_channels`, `set_channels`, `get_rx_ring_count`). **Gaps (see HW-feature row below):** `get/set_link_ksettings` + `nway_reset`, `get/set_coalesce`, `get/set_wol`, `get/set_ringparam`, `get/set_pauseparam` |
| **HW-feature surface for a NIC RFC** | partial — gaps tracked | Present: csum/TSO/SG/VLAN/RXHASH/jumbo offloads, multi-queue RSS. **Missing before posting (chip supports all): `link_ksettings`+`nway_reset` (basic `ethtool <if>` — high), `pm_ops` suspend/resume (high, see `docs/M5_PM_GAP.md`), WoL `get/set_wol` (high), `get/set_coalesce` (INT_MITI already programmed), `get/set_ringparam`, `get/set_pauseparam`; EEE + PTP/`get_ts_info` deferrable.** |
| **Driver-level PM ops (`suspend` / `resume`)** | Deferred | No `pm_ops` set on `pci_driver`; system-suspend across the driver is untested. Documented in `docs/M5_PM_GAP.md`; tracked for a follow-up patch |
| **PCI hot-plug `remove` ordering** | done | `R8125Driver::remove` sequencing documented at `src/pci.rs:132`; tested by 100-cycle stress |
| **MAINTAINERS entry** | Drafted this pass | **Added `MAINTAINERS` stanza in this pass** with the current repository author identity; the human submitter must confirm or replace it before posting |
| **`Documentation/networking/device_drivers/realtek/r8125_rust.rst`** | Fixed this pass | **Added user-facing reST doc in this pass**, kernel-style, covers module params + supported chips + ethtool stats + limitations |
| **Kconfig entry** | Fixed this pass | **Added sample `Kconfig` stanza** for the eventual mainline-tree integration (out-of-tree build uses the top-level `Makefile`) |
| **checkpatch.pl clean (cshim)** | Fixed this pass | `ci/check_checkpatch.sh` runs on six cshim C files plus two headers; current state is clean |
| **Clippy clean (Rust)** | done | `ci/check_clippy.sh` enforces; full `clippy::pedantic` plus crate-local `#![deny(unsafe_code)]` except for the one audited `unsafe_boundary` module |
| **Signed-off-by on every commit** | Blocked | Current commit history was developed in agent-assisted shape **without** DCO trailers. **A `.gitmessage` template + `docs/COMMIT_POLICY.md` added in this pass.** Pre-submission requires `git rebase -i --signoff` or `git filter-repo` to add DCO retroactively; flagged in the M7 dossier as a hard prerequisite |
| **Reviewed-by / Tested-by from a second engineer** | Blocked | Single-developer tree; this is normal for a pre-RFC dossier, but the submission cover letter should call out the Tested-by from the soak harness automation explicitly (Controller + Gateway 24h ASPM-{on,off} x {idle,active} matrix per `docs/M5_CLOSEOUT.md`) |
| **Performance numbers vs in-tree alternative** | done | `docs/perf/r8169_comparison.md` + Gateway baseline; KVM 24h active soak + Gateway 24h active soak both clean with cache-padded fix |
| **KASAN / lockdep / DMA_API_DEBUG clean over 24h soak** | done | `ci/check_active_soak.sh` enforces; M5_CLOSEOUT confirms |
| **Cover-letter material (why this driver, given r8169)** | done | `docs/M7_PRE_RFC_DOSSIER.md` answers verbatim; section "Why a Rust RTL8125 driver" |
| **Self-tests in `tools/testing/selftests/net/`** | Added this pass | `tools/testing/selftests/net/r8125_rust_smoke.sh` covers load, bound netdev discovery, `ip link show`, and unload; the local Makefile wires it into `TEST_PROGS`; `ci/check_selftest_smoke.sh` enforces its TAP/skip/load/unload shape |
| **Reproducible CI (`make`, build matrix)** | done | `ci/run_checks.sh` runs the local static gate suite plus `ci/check_clippy.sh` against the validated rustc-1.93 |
| **No new global symbols leaked to other modules** | Fixed this pass | Removed `EXPORT_SYMBOL_GPL` from module-private `r8125_bridge_*` cshim helpers; `ci/check_no_bridge_exports.sh` prevents regressions |
| **kernel-doc (`/** ... */`) on public C API** | Follow-up | `netdev_bridge.h` carries detailed cshim contract comments, but they are not parseable kernel-doc blocks; local `scripts/kernel-doc` was unavailable here, so convert/verify before posting if these contracts are exposed as kernel-doc |
| **Sparse / smatch clean on cshim** | Gate added | `ci/check_sparse.sh` and `ci/check_smatch.sh` run through Kbuild `C=2`; this host lacks the analyzer binaries, so run them on an analyzer-equipped kernel-build host before posting |
| **No deprecated APIs** | done | Uses `napi_gro_receive` (current), `napi_alloc_skb`, `pcpu_stats`, `phylib`; no `netif_rx`-style legacy paths |

## Categorisation of remaining gaps

### Hard blockers for an RFC posting

1. **Signed-off-by trailers on every commit.** This is a kernel community
   hard requirement (DCO). Plan: when we open the upstream PR branch we
   `git filter-repo --commit-callback` to add `Signed-off-by: <author>`
   to every commit. The author identity has to be the real person who
   takes responsibility for the patch -- see `docs/COMMIT_POLICY.md`.
2. **Driver suspend/resume (`pm_ops`).** Even RFC patches that touch a
   PCI device under power management get pushback if `pm_ops` is left
   empty. We have the design noted in `docs/M5_PM_GAP.md` but no code.
   Suggested scope: implement `pci_driver.driver.pm = &r8125_rust_pm`
   with `suspend_late` / `resume_early` callbacks that tear down the
   chip via `ndo_stop` shape and bring it back up via `ndo_open`.

### Soft blockers (should fix before RFC, but maintainer might accept "in flight")

3. **Sparse + smatch clean on cshim.** CI gates exist now; remaining work is
   to run them on an analyzer-equipped kernel-build host and fix any findings.
4. **Run the new selftest on hardware.** The script and static shape gate
   exist now; remaining work is to run it on the RTL8125B host with a built
   module and capture the TAP output.

### Acceptable to defer past RFC

5. **Reviewed-by trailers.** Maintainer will assign reviewers; we can
   collect Reviewed-by during the review cycle.
6. **A second hardware-revision test (RTL8125A / RTL8126).** Not in our
   procurement plan; document supported chips explicitly in the RST.
7. **EEE / PTP-hwtstamp.** Chip supports them (vendor params), not yet wired;
   reasonable to defer past the first RFC (note in the RST).

> **Update 2026-06-09 — multi-queue + RSS is now DONE, not deferred.** Track A
> (RXHASH) and Track B (full hardware multi-queue RSS: per-queue rings/NAPI,
> V2/MSI-X routing, RSS key+indirection, `ethtool -x/-X/-l/-L`/`set_channels`)
> are implemented and hardware-validated at vendor-C parity-or-better (default
> stays single-queue `rss_queues=0`). See `docs/RSS_RXHASH_IMPLEMENTATION_PLAN.md`,
> `docs/perf/rss_multiqueue_20260609/`, `docs/perf/cvr_sweep_20260609/`. The old
> `docs/M6_MULTIQ_NA.md` is superseded (its "N/A on 8125B" premise was wrong).

## Architectural concerns the maintainer will raise

These are not gaps in our tree -- they're known choices the cover letter
must justify:

- **"Why a new driver if r8169 already covers RTL8125?"** Covered by
  `docs/M7_PRE_RFC_DOSSIER.md` section Background; the rebuttal is "this is
  a Rust netdev prototype driver; if the pathway is acceptable, the
  reusable abstractions are the leverage." If the maintainer prefers
  Exit (b) in `docs/M7_PREP.md` (land abstractions first, port driver second),
  we're prepared for that path.
- **"Why a cshim?"** Covered by `docs/M7_CSHIM_KERNEL_DIFF.md` --
  the cshim helper set is documented there and mirrored by `// SAFETY:`
  rationale on the Rust side. The narrative is "thin C bridge, thick
  Rust core"; per-file C shim LOC caps and checkpatch keep the bridge
  reviewable.
- **"Why CachePadded on the debug counters?"** The KVM stall we hit
  on 2026-05-31 made file-scope hot-path atomics part of the review
  surface. Even low-rate counters are mutated from independent xmit,
  IRQ, and NAPI contexts, so `ci/check_cache_padding.sh` now enforces
  padding for file-scope statics as well as state-struct fields.

## What this pass does NOT do

- We do NOT add Signed-off-by to existing commits -- that's a
  pre-submission step the human author has to take ownership of.
- We do NOT implement `pm_ops` -- design exists; implementation is a
  separate task once Gateway PM-soak passes.
- We do NOT claim a local sparse/smatch analyzer result on hosts where the
  analyzer binaries are absent; the CI gates skip cleanly there.
- We do NOT claim the new selftest has passed on hardware until the RTL8125B
  host runs it with the built module and captures TAP output.

## Concrete additions in this pass

1. `MAINTAINERS` -- kernel-style stanza for `Documentation/process/`-
   compatible review routing.
2. `Documentation/networking/device_drivers/realtek/r8125_rust.rst` --
   user-facing kernel-style reST driver documentation.
3. `Kconfig` -- sample tristate entry for eventual mainline integration.
4. `get_drvinfo` ethtool op in `src/netdev_bridge_ethtool.c` so
   `ethtool -i enp5s0` returns driver/bus_info.
5. `docs/COMMIT_POLICY.md` + `.gitmessage` template -- DCO discipline
   doc.
6. `docs/CHECKPATCH_NOTES.md` -- first checkpatch.pl run results +
   triage.
7. This document -- `docs/UPSTREAM_REVIEW.md`.
8. `ci/check_sparse.sh` + `ci/check_smatch.sh` -- Kbuild `C=2`
   analyzer gates that skip cleanly when the analyzer binaries are absent.
9. `ci/check_no_bridge_exports.sh` -- prevents module-private C shim
   helpers from re-entering the global kernel symbol namespace.
10. `tools/testing/selftests/net/r8125_rust_smoke.sh`,
   `tools/testing/selftests/net/Makefile`, and `ci/check_selftest_smoke.sh`
   -- upstream-style load/netdev/unload smoke selftest and static shape gate.

## Cross-references

- `docs/M7_PRE_RFC_DOSSIER.md` -- narrative cover letter draft.
- `docs/M7_PREP.md` -- exit-path decision tree.
- `docs/M7_CSHIM_KERNEL_DIFF.md` -- cshim <-> kernel surface diff.
- `docs/M7_RUST_NETDEV_LANDSCAPE.md` -- kernel-Rust netdev work in-flight.
- `Documentation/process/submitting-patches.rst` (in any kernel tree) --
  the canonical patch-submission checklist.
- `Documentation/networking/index.rst` -- where the RST under
  `device_drivers/realtek/` slots into the kernel docs build.
