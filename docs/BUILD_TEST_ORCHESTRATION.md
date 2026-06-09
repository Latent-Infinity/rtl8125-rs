# Build and Test Orchestration Direction

**Status:** reviewed and revised (v2). Direction accepted in principle;
implement in the MVP order in "Test-First Implementation Plan". Do not expand
beyond the MVP file set without a follow-up review.

This v2 was rewritten against the *actual* friction observed during the multi-queue
multi-queue debug (2026-06-09), not just an a-priori problem list. Where the
two disagreed, lived experience won — see "What actually cost us time".

## Problem

The workflow grew organically across the local controller, the KVM guest, and
the Gateway. Two classes of friction emerged, and they are not equally costly.

**Class 1 — inventory drift (annoying, cheap to fix).** Implicit facts:
- which machine is the active build host,
- which directory holds the source tree on each machine,
- which kernel/toolchain is deployed,
- which `.ko` was built and loaded,
- which interface, PCI address, and peer IP belong to each target,
- which gates are host-only / KVM-only / Gateway-only / deferred,
- where evidence is written,
- which scripts are safe from the repo root vs only on a remote target.

**Class 2 — unreliable execution and measurement (expensive, the real cost).**
These are what actually burned hours and are under-served by a config file:
- privileged commands silently lost root and failed late,
- traffic tests hung instead of failing,
- numbers could not be trusted (stale buffers, single-run noise, a headline
  metric that hid the real fault).

## What actually cost us time (multi-queue evidence)

Every requirement below traces to a concrete failure in one debug session:

| Failure observed | Root issue | Requirement it drives |
|---|---|---|
| `sudo nohup bash x.sh &` ran as **non-root** → every `ip netns` returned "Operation not permitted"; 3 runs wasted | backgrounded `sudo` drops privileges | single, synchronous privileged-exec pattern (`run_priv`) |
| rsync landed in `…/rtl8125-rs-build/`, not the dir `gw_loopback.sh` loads from | no single source of truth for paths | `devices.env` + deploy verifies path |
| Could not tell if my fix was loaded — `srcversion` looked unchanged | "what is deployed?" unanswerable | manifest records **and verifies** built vs loaded `srcversion` |
| "21 IOMMU faults" was **stale ring-buffer** from a pre-fix run | counted absolute `dmesg` lines | `dmesg -C`/cursor **before**, diff **after** |
| Same config gave **0 vs 62 859** TX drops across runs | single-run measurement is noise | N-repeat with variance reported |
| rss=4 showed **2.36 Gbit *and* 62 859 drops** at once | throughput hid the fault | `ethtool -S` **counter deltas as pass/fail**, not just bandwidth |
| iperf hung (`RC=124`) on a wedged TX | no per-test timeout | every traffic command wrapped in `timeout` |
| root-owned `/tmp/*.txt` blocked output redirection | evidence not in a per-run user-owned dir | unique, user-owned run dir per invocation |

The headline conclusion: **measurement reliability and privileged-execution
reliability matter more than inventory tidiness.** v2 leads with those.

## Goal

Add a small, reusable orchestration layer that makes build + test **repeatable
and trustworthy** across:

- **Controller (local host):** source editing, static checks, KVM control.
- **KVM guest:** fast load/unload and VFIO-passthrough validation.
- **Gateway:** bare-metal validation and long-running hardware tests.

The layer must be configurable, auditable, and boring. It must reduce decision
points and make every reported result reproducible.

## Non-Goals

- Do not replace the existing `ci/check_*.sh` gates.
- Do not replace `gw_loopback.sh` — **wrap** it (see "Relationship to
  `gw_loopback.sh`"). It already encodes the working load/netns/override logic.
- Do not create a framework or daemon, or add another build system.
- Do not make driver feature changes while this work is in progress.
- Do not encode plan or milestone labels in commit messages or artifact names.

## Design Principles

- **Trust no number.** A result is only valid if produced with a cleared
  baseline, counter deltas, a timeout, and repetition. Measurement methodology
  lives in the run layer, not in each ad-hoc script.
- **One source of truth.** Host names, paths, interfaces, PCI addresses, kernel
  identity, and evidence roots live in config, confirmed by `status`, never
  trusted blindly.
- **Thin orchestration.** Call existing focused checks and `gw_loopback.sh`;
  do not duplicate their logic.
- **Privileged exec is explicit.** Exactly one synchronous root pattern; never
  background a `sudo`.
- **Local first / fail early.** Print the exact target, path, kernel, module,
  and evidence dir before doing work; stop on any preflight mismatch.
- **No hidden deployment.** Every deploy records source commit (with dirty
  flag), build command, module path + sha256 + srcversion, target host/kernel,
  load params, and timestamp — and verifies loaded == built.
- **TDD for scripts:** contract/parse/dry-run checks first, then the smallest
  behavior that satisfies them.
- **KISS:** POSIX-ish shell + a `.env` sourced by bash. No new parser.

## The Measurement Contract (central requirement)

Every **runtime** gate (anything that loads the driver or moves traffic) MUST:

1. **Clear the baseline.** `dmesg -C` (or capture the cursor) before; compute
   the **delta** after. Never assert on absolute `dmesg` counts.
2. **Snapshot counters.** Capture `ethtool -S <iface>` before and after; assert
   on **deltas**. Default hard-fail conditions:
   - `tx_dropped_error` delta `== 0`
   - `rx_*_error` / `rx_dropped_error` delta `== 0`
   - dmesg delta has no `warn|error|bug|oops|call trace|iommu_dma_unmap`
   Throughput is recorded but is a *soft* metric, never the sole pass criterion.
3. **Bound every traffic command** with `timeout` so a wedge fails loudly.
4. **Repeat, warm-up FIRST.** Run a discarded warm-up *before* the baseline
   snapshot, then `N` measured runs (default 3). The warm-up must precede
   `dmesg -C` and the `ethtool` baseline so its cold-start effects (e.g. the
   per-CPU IOVA-cache warming that produces a one-time burst of
   `tx_dropped_error` on a fresh driver load; see the multi-queue debug
   session) are EXCLUDED from the measured window. The gate measures steady
   state, not cold start. Report min / median / max and flag high variance as a
   finding.
   (Lesson: snapshotting before the warm-up made a fresh-load gateway run show
   95 `tx_dropped_error`; measuring post-warm-up it is 0 — steady state is clean.)
5. **Throughput floor.** A counter-clean run with ~0 throughput means no traffic
   actually flowed — a false pass. `tx_counter_clean` also FAILs below
   `DEFAULT_MIN_TPUT_GBPS`.
6. **Persist the evidence.** Write counter deltas, dmesg delta, per-run values,
   and the pass/fail decision into the run manifest.

This contract is what would have caught this issue automatically and is the
first thing CI should enforce on the harness scripts.

## Relationship to `gw_loopback.sh`

`gw_loopback.sh` is the existing, working Gateway rig: it knows the BDF, the
`enp3s0`/`enp4s0` ports, the `dut`/`peer` netns, and the driver
load/`driver_override` dance. The orchestration layer **wraps** it:

- `rt8125-deploy.sh` (or the `deploy` verb) calls `gw_loopback.sh dut rust
  "<params>"` to load, then verifies srcversion + params.
- `rt8125-run.sh` calls `gw_loopback.sh setup` for topology, then runs gates
  under the Measurement Contract.

Do not reimplement netns/override logic. If `gw_loopback.sh` needs a knob the
orchestration requires (e.g. a `--no-load` mode), extend it rather than fork it.

## KVM topology (different rig — `rt8125-run.sh` is target-aware)

The KVM is **not** a single-host netns rig. It is a **2-node** setup:

- **DUT** = the libvirt guest `rtl8125-guest` (ssh alias → `192.168.122.174` on
  the virbr0 mgmt net; the test NIC is a *passthrough* RTL8125 = `enp5s0`,
  `10.0.0.2`). The mgmt link is a separate virtio NIC, so reloading the test
  driver does not drop the ssh session.
- **Peer** = THIS controller's `enp4s0` (`10.0.0.1`), cabled to the guest NIC.
  KVM gates run the iperf3 server here (colocated), and the guest runs the
  client. There is no `gw_loopback`, no netns.
- **Load** is in-guest: `rmmod; insmod $KVM_KO <params>; ip addr replace
  10.0.0.2/24 dev enp5s0; ip link set enp5s0 up` (the test link drops on
  reload). `driver_override=r8125_rust` keeps r8169 from grabbing the device.
- **Build** is in-guest with rustc-1.93 on PATH.

Constraints (from prior soak work): UDP-TX is unusable on the VM clocksource
(iperf3 UDP wedges identically for the C driver — a virtualization artifact, not
a driver signal), so KVM gate groups are **TCP-only**; do UDP / latency / IRQ
work on the gateway. The VM also auto-pauses if the libvirt host disk fills.

`rt8125-run.sh` resolves these per-target facts up front (`T_HOST`, `T_IFACE`,
`load_body`, `dut_prefix`, the gateway-vs-controller peer) so build / deploy /
gates work on either target from the same command vocabulary.

## Confirmed Configuration (corrected)

Values verified during the multi-queue debug session are marked ✓; unverified
values are TODO and must be confirmed by `rt8125-status.sh` before use —
shipping a guess as truth defeats the purpose of this layer.

```bash
# config/devices.env
REPO_ROOT=/home/firestrand/Projects/Rt8125-driver/rtl8125-rs   # ✓ controller
EVIDENCE_ROOT=docs/perf

CONTROLLER_HOST=local
GATEWAY_HOST=gateway                 # ✓ ~/.ssh/config alias (100.125.107.46)
KVM_HOST=rtl8125-guest               # ✓ ~/.ssh/config alias (192.168.122.174)

# Gateway — ✓ confirmed this session
GATEWAY_REPO_ROOT=/home/firestrand/rtl8125-rs   # ✓ (gw_loopback KO lives here)
GATEWAY_KO=/home/firestrand/rtl8125-rs/src/r8125_rust.ko   # ✓
GATEWAY_LOOPBACK=/home/firestrand/gw_loopback.sh           # ✓
GATEWAY_IFACE=enp3s0                 # ✓ (DUT)
GATEWAY_BDF=0000:03:00.0             # ✓
GATEWAY_PEER_IFACE=enp4s0            # ✓
GATEWAY_DUT_NS=dut                   # ✓
GATEWAY_PEER_NS=peer                 # ✓
GATEWAY_PEER_IP=10.0.0.1             # ✓
GATEWAY_LOCAL_IP=10.0.0.2            # ✓
GATEWAY_KERNEL_FAMILY=7.0.0          # ✓ (built against 7.0.0-22-generic)
GATEWAY_RUSTC=rustc-1.93             # ✓

# KVM — verified 2026-06-09 (libvirt VM `rtl8125-guest`, see "KVM topology").
KVM_HOST=rtl8125-guest               # ssh alias -> 192.168.122.174 (virbr0 mgmt)
KVM_REPO_ROOT=/home/firestrand/rtl8125-rs
KVM_KO=/home/firestrand/rtl8125-rs/src/r8125_rust.ko
KVM_IFACE=enp5s0                     # guest DUT (passthrough RTL8125)
KVM_BDF=0000:05:00.0
KVM_LOCAL_IP=10.0.0.2                # guest test addr
KVM_PEER_IP=10.0.0.1                 # = controller enp4s0 (colocated peer)
CONTROLLER_PEER_IFACE=enp4s0         # this host's port cabled to the guest NIC
CONTROLLER_PEER_IP=10.0.0.1
KVM_SMOKE_GATES="load_unload ping"
KVM_TCP_GATES="tx_counter_clean"     # TCP only — UDP-TX is a VM clocksource artifact
```

An empty `KVM_HOST` still means "unconfigured": `status` skips it (exit 0) and
`build/deploy/gates --target kvm` refuse with a clear error. No guessed values.

`.env` is sourced by bash (it executes code): keep it repo-owned, lint it in
the contract gate, and never source an `.env` from outside the tree.

Gate groups can stay inline in `devices.env` until they are large enough to
warrant a split:

```bash
STATIC_GATES="run_checks"                 # host-only (ci/run_checks.sh)
GATEWAY_SMOKE_GATES="load_unload ping ethtool_snapshot"
GATEWAY_MQ_GATES="tx_counter_clean rss_hazard rmmod_under_traffic"  # multi-queue blockers
GATEWAY_STRESS_GATES="active_soak idle_soak"
DEFAULT_REPEATS=3
DEFAULT_WARMUP=1
DEFAULT_IPERF_SECONDS=30
DEFAULT_TIMEOUT_SECONDS=15
DEFAULT_SOAK_HOURS=24
```

## Privileged Execution Model

Lesson from the multi-queue debug session: a backgrounded `sudo` silently dropped root. The rule:

- Run privileged work as **one synchronous invocation**: `sudo bash <script>`
  (the whole script runs as root), never `sudo nohup … &` and never per-line
  `sudo` inside a backgrounded shell.
- `rt8125-env.sh` exposes a single `run_priv "<cmd>"` helper that the harness
  uses everywhere; long runs use the background facility on the *outer* ssh,
  with the privileged body still synchronous on the target.
- Preflight asserts passwordless `sudo -n true` on the target.
- Evidence is written to a **per-run, user-owned** directory — not root-owned
  `/tmp` files (those blocked output redirection this session).

## MVP File Set

Ship these five artifacts first (one config + three scripts + one CI gate).
Grow only after a follow-up review.

| Path | Purpose |
|---|---|
| `config/devices.env` | Single source of truth (machines, paths, ifaces, BDFs, gate groups, defaults). |
| `scripts/rt8125-env.sh` | Config loader, required-var checks, `run_priv`, ssh wrapper, run-dir + manifest helpers, the Measurement-Contract primitives (`dmesg_delta`, `ethtool_delta`, `repeat`). |
| `scripts/rt8125-status.sh` | Read-only inventory for controller / KVM / Gateway, incl. `DEPLOYED_MATCHES_BUILD`. Safe any time. |
| `scripts/rt8125-run.sh` | Verb-driven: `build` / `deploy` / `gates` / `collect`, each writing a manifest. Wraps `gw_loopback.sh` for Gateway load/topology. |
| `ci/check_orchestration_contract.sh` | Static gate: `bash -n` all scripts, required `.env` vars present + non-empty (except TODO-marked), manifest field contract, Measurement-Contract primitives exist. |

Deferred until proven necessary (originally separate scripts, now verbs of
`rt8125-run.sh`): standalone `build` / `deploy` / `run-gates` / `collect`.
`gates.env` stays folded into `devices.env` until it hurts.

## Command Model

```bash
scripts/rt8125-status.sh --target all
scripts/rt8125-run.sh build  --target gateway
scripts/rt8125-run.sh deploy --target gateway --params "rss_queues=4"
scripts/rt8125-run.sh gates  --target gateway --group mq
scripts/rt8125-run.sh collect --target gateway --run-id 20260609T120000Z
```

Every command: (1) load config, (2) verify repo root, (3) print an execution
header, (4) run preflight, (5) write a manifest, (6) execute under the
Measurement Contract, (7) collect evidence or write a failure bundle.

## Run Manifest

```text
docs/perf/runs/<UTC ISO8601>_<target>_<operation>/manifest.env
# docs/perf/runs/ is gitignored (rule added to .gitignore in this change).
```

```bash
RUN_ID=20260609T120000Z
TARGET=gateway
OPERATION=gates
GATE_GROUP=mq
SOURCE_COMMIT=<git describe --always --dirty>     # dirty flag is mandatory —
                                                  # most builds are uncommitted
SOURCE_DIR=/home/firestrand/Projects/Rt8125-driver/rtl8125-rs
TARGET_HOST=gateway
TARGET_REPO_ROOT=/home/firestrand/rtl8125-rs
TARGET_KERNEL=<uname -r>
TARGET_IFACE=enp3s0
TARGET_BDF=0000:03:00.0
MODULE_PATH=<absolute path>
MODULE_SHA256=<sha256 of the built .ko>
MODULE_SRCVERSION_BUILT=<modinfo srcversion of the .ko>
MODULE_SRCVERSION_LOADED=<cat /sys/module/r8125_rust/srcversion>
DEPLOYED_MATCHES_BUILD=yes|no                      # built == loaded srcversion
MODULE_PARAMS=<params>
# Measurement Contract evidence:
DMESG_DELTA_FAULTS=<count>
ETHTOOL_DELTA_TX_DROPPED_ERROR=<count>
ETHTOOL_DELTA_RX_ERRORS=<count>
THROUGHPUT_MED_GBPS=<median over repeats>          # soft metric
REPEATS=3
RESULT=pass|fail|incomplete
```

`DEPLOYED_MATCHES_BUILD` is the direct fix for the "is my fix even loaded?"
confusion. A `no` is an automatic incomplete.

## Preflight Checks

Before any deploy or runtime test:

- repo root matches `REPO_ROOT`; working-tree status printed;
- target SSH alias resolves; passwordless `sudo -n true` works;
- target `uname -r` matches the intended kernel family;
- target interface and PCI BDF exist and BDF matches Realtek `10ec:8125`;
- management route is **not** the interface under test (lockout guard);
- required commands present on the target (`ethtool`, `iperf3`, `jq`, …);
- previous driver instance absent or explicitly unloaded;
- evidence directory uniquely named and user-owned.

Gateway multi-queue / stress gates additionally confirm peer topology
(`gw_loopback.sh setup` succeeded, peer iperf3 reachable) before traffic.

## Test-First Implementation Plan

1. `ci/check_orchestration_contract.sh`: fails until the MVP files exist, parse
   (`bash -n`), expose required functions (incl. `run_priv`, `dmesg_delta`,
   `ethtool_delta`, `repeat`), and define required `.env` vars.
2. Config contract: required vars (controller + gateway + KVM + controller-peer
   + measurement defaults) present and non-empty; when `KVM_HOST` is set its full
   block must be complete; `.env` is repo-local.
3. Dry-run tests: each command prints its header + writes a manifest with all
   required fields **without** touching remote hosts.
4. Unit-style config-loader tests with temporary `.env` files.
5. Implement `rt8125-status.sh` (read-only) first, including
   `DEPLOYED_MATCHES_BUILD`.
6. Implement the Measurement-Contract primitives in `rt8125-env.sh` and a
   self-test (`dmesg_delta`/`ethtool_delta`/`repeat` on a no-op).
7. Implement `rt8125-run.sh build` + manifest.
8. Implement `deploy` (wrapping `gw_loopback.sh`) with a dry-run mode before
   live load; verify srcversion match.
9. Implement `gates` (sequencing existing `check_*.sh` + harnesses under the
   Measurement Contract), then `collect`.

## Resolved Review Questions

- **`.env` vs TOML/YAML?** `.env`, sourced by bash. KISS; no parser dependency.
  Mitigate the code-execution risk by keeping it repo-owned and linting it.
- **Separate target checkouts vs ship artifacts?** Ship the **built `.ko` +
  manifest**; do not maintain parallel source checkouts that drift. (Rebuilding
  on the Gateway from a synced tree is fine; the artifact + manifest is what
  proves what's loaded.)
- **Canonical Gateway SSH alias?** `gateway` (`100.125.107.46`).
- **Commit `docs/perf/runs/`?** No — raw run dirs are **already gitignored**
  (rule added to `.gitignore` alongside this doc); commit only curated summaries
  (e.g. the RSS multi-queue summary pattern).
- **Which gates block feature work?** The Gateway **multi-queue counter-clean
  gate** (`tx_dropped_error` delta `== 0` + dmesg-delta-clean at
  `rss_queues=4`, N≥3), plus **rss_hazard** and **rmmod-under-traffic**. These
  are exactly the checks that would have caught this issue without a manual debug.

## Acceptance Criteria

Complete when:

- one command reports current state for Controller, KVM, and Gateway, including
  whether the loaded module matches the built one. KVM and Gateway are both
  configured + verified. **MVP behavior for any target whose config is later
  blanked/added:** an empty `*_HOST` reports `unconfigured` and is **skipped,
  not failed** — `status --target all` exits 0;
- one command builds and records a build manifest;
- one command deploys a chosen module, verifies srcversion, and records params;
- one command runs a named gate group **under the Measurement Contract**
  (cleared baseline, counter deltas as pass/fail, timeouts, N-repeat) and stores
  evidence predictably;
- CI statically checks the orchestration scripts, config, and the
  Measurement-Contract primitives;
- the documentation explains how to recover state without guessing directories,
  hosts, kernels, module paths, or evidence locations — and how to trust a
  result once produced.
