# AI-Assisted Rust Driver for the Realtek RTL8125 on the Minisforum MS-A2

**Implementation Planning Document — v3.2**
**Target: Ubuntu 26.04 LTS / Linux 7.0+ / Rust-for-Linux**
**Status: Ready for M0a (pre-link fact discovery). M1 begins only when §15 entry criteria are met.**

---

## 0. Executive Summary

This document defines the engineering plan for an AI-assisted, Rust-based Linux network driver for the Realtek RTL8125 2.5 GbE controller, hosted and validated on the Minisforum MS-A2 small-form-factor workstation.

The plan is deliberately scoped against the **state of Rust-for-Linux as of May 2026**, not against an idealized version of it. Two facts shape every decision below:

1. **Rust PCI, DMA, MMIO, allocation, and module-lifecycle abstractions exist in mainline and are sufficient for a staged out-of-tree prototype.** A Rust driver can express probing, BAR mapping, register access, descriptor-ring memory, IRQ binding, and module lifecycle through wrapped APIs today. **The exact API surface, Rust metadata availability, and buildability must be validated against the selected kernel tree before M1.** Out-of-tree Rust APIs can still change between kernel point releases.
2. **Rust netdev / `sk_buff` / NAPI abstractions are not yet mainline-complete.** Patch series exist (RFC level through Q1 2026); a fully idiomatic Rust `net_device_ops` implementation is not a stable target a new driver can rely on.

The correct response is **not** to wait, and **not** to claim more safety than the kernel currently offers. The correct response is a layered prototype:

- A Rust core that owns everything from PCI probe through descriptor-ring ownership, gated behind `#![deny(unsafe_code)]` at the crate root with a single named `unsafe_boundary` module that locally allows it.
- A small, audited C shim (`cshim/netdev_bridge.c`) that bridges the Rust core to `net_device`, NAPI, and `sk_buff` until the upstream Rust abstractions stabilize. The shim's value is the documented **`sk_buff` ownership contract** (§6.3) it implements, not its source code.
- **Active hostile treatment of two known-historical failure modes** for this silicon family: PCIe ASPM / L1 sub-state stability (§3.3), promoted from "perf tuning" to a tier-1 correctness gate at M5, and `sk_buff` ownership across the FFI boundary (§6.3), enforced by a type-state Rust wrapper with panic-on-Drop leak detection in development builds.
- A bring-up plan (M0a/M0b → M7) where the **first** successful driver milestone is "PCI probe + chip revision logged + clean unload 1,000×," not "packets moving."
- A VFIO-isolated test harness so a faulty driver crashes only the guest, never the MS-A2 host.
- An AI agent workflow that is **bounded by the kernel's coding-assistant policy**: agents never sign off, humans hold DCO responsibility, optional `Assisted-by:` trailer only.

**Out of scope for this phase:** immediate upstream merge, full feature parity with the out-of-tree `r8125`, replacement of `r8169`, and any claim of a "fully safe Rust driver" while the netdev shim is in place.

---

## 1. Validated Hardware Baseline — Minisforum MS-A2

The MS-A2 is the right development host because its NIC redundancy lets the target Realtek port be isolated and crashed repeatedly without ever costing the developer their SSH session. Specifications below are taken from the official Minisforum product listing.

### 1.1 Compute and Memory

| Component | Specification |
|---|---|
| CPU (top SKU) | AMD Ryzen 9 9955HX — Zen 5, 16C/32T, 2.5 GHz base / 5.4 GHz boost, 64 MB L3, 75 W TDP |
| RAM | Up to 96 GB DDR5-5600 SO-DIMM, dual-channel |
| Expansion | 1× PCIe 4.0 ×16 slot (electrically ×8), bifurcation supported |
| NVMe | 3× M.2 (2× PCIe 4.0 ×4, 1× PCIe 3.0 ×4) |

The combination supports parallel kernel + LLVM/Clang + `rustc` builds, multiple long-lived QEMU/KVM guests, and local LLM inference for the agent loop without contention.

### 1.2 Network Topology — Why This Box Specifically

The MS-A2 ships with **four heterogeneous NICs**, and this is the single most important platform property for this project:

| Interface | Silicon | Port | Role in this project |
|---|---|---|---|
| 2× 10 GbE | Intel X710 | SFP+ | High-throughput VM backbone, telemetry export |
| 2.5 GbE | Intel I226-V | RJ45 | **Pinned host management — SSH never drops** |
| 2.5 GbE | **Realtek RTL8125** | **RJ45** | **Target device — bound to `vfio-pci`** |

The Intel I226-V (or one X710 port) carries all host traffic. The Realtek port is dedicated to the experimental driver via VFIO passthrough into the guest. A guest kernel panic never touches host connectivity.

---

## 2. Validated Software Baseline

| Component | Selection | Rationale |
|---|---|---|
| Host OS | **Ubuntu 26.04 LTS** | Supported through April 2031; ships Linux 7.0, LLVM 21, GCC 15.2, Rust 1.93 in-stack |
| Host kernel | Ubuntu 7.0 GA / HWE | Mainline Rust-for-Linux PCI/DMA/MMIO present |
| Guest OS | Ubuntu 26.04 Server (or minimal Buildroot) | Matches host toolchain; minimal attack surface |
| Rust / LLVM / bindgen | Whatever the selected kernel source tree accepts via `make LLVM=1 rustavailable` | Kernel build system is authoritative; Ubuntu 26.04's Rust 1.93 is the distro baseline, **not** the project's source of truth |
| Build tools | Kernel build (`make -C $KDIR M=$PWD`), `make CLIPPY=1`, generated `rust-project.json` for editor support | See §11; **`cargo` is not in the build path** |
| Hypervisor | QEMU/KVM via `libvirt` | First-class VFIO passthrough |
| Logging | Host-side serial-console capture, `dmesg`, `ftrace`, `perf`, `bpftrace`, `KASAN`, `CONFIG_DMA_API_DEBUG` | See §10 |

**Toolchain authority lies with the kernel tree, not with this project.** Before M1, run `make LLVM=1 rustavailable` against the selected kernel source and record the accepted Rust, LLVM, and `bindgen` versions. If the installed kernel headers are missing Rust metadata (a known limitation of some distributed kernel packages), build a self-managed kernel for the guest instead.

---

## 3. Target Hardware — Realtek RTL8125 Profile

The RTL8125 is a single-lane PCIe 2.x controller integrating a 4-speed IEEE 802.3 MAC, a multi-speed PHY, on-chip OTP (no external EEPROM), and DSP-based 2.5 Gbps signaling over CAT 5e. **PCIe 2.0 signals at 5.0 GT/s raw; with 8b/10b line encoding the usable payload ceiling is roughly 4 Gbps per direction before protocol overhead.** Because PCIe is full-duplex, this is adequate for 2.5 GbE simultaneous RX and TX in principle, but it does not leave headroom for inefficient DMA patterns — descriptor and buffer sizing matter.

### 3.1 Revision Detection Is Mandatory

The family includes RTL8125A, RTL8125B, RTL8125BG, RTL8125BGS, RTL8125BP — differing in EMI tuning, core voltage rails (e.g., 0.95 V), and minor register layouts. **The driver MUST read PCIe config space to determine the exact revision and dispatch through a per-revision register table.** Hard-coding a single register layout is the most common cause of immediate lockups in community drivers.

### 3.2 Hardware Features the Driver Will Eventually Expose

Listed for planning, not for M1 implementation:

- Multiple TX/RX queues
- MSI-X interrupt distribution
- Receive Side Scaling (RSS)
- Hardware checksum offload (IPv4/TCP/UDP)
- TSO / GSO (verify descriptor semantics before enabling)
- VLAN tag insert/strip
- PTP timestamping
- Jumbo frames (>1500 MTU; reduces packet rate and CPU overhead. **Line rate at 1500 MTU remains a performance target — jumbo is not the path of least resistance to throughput.**)
- PCIe Active State Power Management (ASPM L0s / L1 / L1 sub-states) — see §3.3
- D3hot / D3cold suspend-resume — see §3.3

**None of these are M1–M4 deliverables.** They are unlocked only after the single-queue path is provably stable. See §6.

### 3.3 ASPM and Runtime Power Management — A First-Class Hazard

The RTL8125 family has a documented history of PCIe Active State Power Management instability. A large fraction of bugs blamed on "Realtek being buggy" are in fact driver–firmware power-state coordination failures. Reported symptoms across `r8169` and `r8125` history include:

- DMA writes silently dropped during PCIe link state transitions
- Device failing to wake from D3hot under traffic resumption
- Idle-time lockups that correlate not with load but with the absence of load (system idles → ASPM kicks in → device wedges)
- "Data corruption" that on inspection is torn descriptor writes during link retraining

A driver that passes `iperf3` benchmarks at full load can lock up overnight the first time the system goes idle. This is the single most likely reason a "working" RTL8125 driver fails in production.

The Rust driver **MUST**:

1. **Read ASPM capabilities at probe** via the PCIe config space and log the device-advertised L0s / L1 / L1 sub-state support and the platform's current policy.
2. **Default to conservative ASPM policy** for any revision not on a known-good allowlist: disable L1 sub-states (L1.1, L1.2) via the kernel's `pci_disable_link_state()` equivalent at probe time.
3. **Implement working `suspend` and `resume` PCI driver callbacks** — D3hot is the minimum bar; D3cold support only enabled per-revision after explicit validation.
4. **Expose a module parameter `aspm_policy`** with these unambiguous values:
   - `kernel` — do not override kernel/platform policy
   - `conservative` (default) — disable L1 sub-states unless the revision is allowlisted
   - `force_off` — disable every ASPM state this driver can disable
   - `aggressive` — opt-in for allowlisted revision/board combinations to use deeper states
5. **Treat suspend/resume cycling as a tier-1 test gate** at M5, not a future enhancement.

This is the area where the out-of-tree `r8125` rewrite is most valuable as a reference: its long change-log of ASPM workarounds is effectively a database of known-bad revision/platform combinations. Read it, don't copy it.

---

## 4. Why Rust, Stated Honestly

The motivation is not "Rust is fashionable" and not "C is bad." The motivation is specific:

The community `r8125` derivatives (notably the well-known rewrite by developer `ewaldc`) are explicit in their commit history about the bugs they exist to fix: **"several hangs/crashes (wrong fragment count with lots of small packets) and occasional data corruption."** Translated, these are the classic memory-safety failure modes of complex DMA-ring lifecycle management in C:

- Off-by-one errors in descriptor indexing
- Use-after-free when an interrupt fires asynchronously with the cleanup path
- Race conditions between the producer (kernel) and consumer (hardware) views of a ring
- Fragment-count desync between software and silicon, producing overlapping DMA writes

Rust's ownership model, lifetime analysis, and compile-time data-race prevention are designed to eliminate exactly this class of bug. The benefit is realized **only if the unsafe boundary is small, named, and reviewed** — which is why §5 makes that an architectural rule rather than a coding guideline.

What Rust does **not** solve: a wrong register write, a wrong hardware initialization sequence, an incorrect interrupt-acknowledgement protocol. Those bugs are equally easy to write in any language. Hardware correctness is a separate, parallel problem.

---

## 5. Rust-for-Linux Readiness Assessment

A truthful split, applied to this driver specifically:

### 5.1 Available Today — Use Native Rust Where the Target Kernel Supports It

- **PCI device registration and probe/remove lifecycle** — `kernel::pci` exposes safe wrappers around the C PCI subsystem.
- **BAR mapping and MMIO access** — `kernel::io::mem::IoMem`-style wrappers provide typed register I/O without raw pointer arithmetic.
- **DMA coherent + streaming allocations** — `kernel::dma` covers `dma_alloc_coherent` equivalents and scatter-gather mapping.
- **Module lifecycle** — `module!` macro plus the `Module` trait; `Drop` semantics handle cleanup deterministically.
- **Devres-style resource cleanup on probe failure** — automatic rollback if `probe()` returns `Err`.
- **`pin_init`** — safe, fallible initialization of self-referential and address-stable structures (descriptor rings).

**M1 explicitly validates each of these APIs against the selected kernel tree.** If an API is missing, renamed, or unstable in the Ubuntu kernel package, the project either vendors a tiny compatibility layer in `unsafe_boundary.rs` (with a `// FIXME(kernel-vX.Y):` comment and an issue tracker reference) or switches the guest to a self-built kernel pinned to a known-good Rust-for-Linux revision. Out-of-tree Rust modules are explicitly **not** promised internal-API stability.

### 5.2 Not Mainline-Stable — Use a C Shim, Plan to Migrate

- **`net_device` registration and `net_device_ops` trait** — RFC-level only as of Q1 2026.
- **`sk_buff` ownership wrappers** — proposed but not merged in a form a driver should depend on.
- **NAPI integration in safe Rust** — sketches exist; no stable trait surface.
- **`ethtool_ops` integration** — depends on the above.

### 5.3 Planning Consequence

The driver is structured as a Rust core plus a deliberately minimal C bridge. The bridge is itself reviewable in a single sitting (target: under 400 LOC). As upstream Rust netdev abstractions land, the bridge shrinks and eventually disappears.

This is **not** a temporary compromise that the project tries to hide. It is documented in the README, in code comments, and in any RFC posting. Misrepresenting safety guarantees is worse than acknowledging the shim.

---

## 6. Driver Architecture

### 6.1 Module Layout

```
r8125_rust/
├── Kbuild                       # AUTHORITATIVE build description (kernel build system)
├── Makefile                     # invokes the kernel build via make -C $KDIR M=$PWD
├── rust-project.json            # GENERATED for rust-analyzer; not a source of truth
├── src/
│   ├── lib.rs                   # module! entry, PCI driver registration
│   ├── pci.rs                   # probe/remove, BAR mapping, IRQ acquisition
│   ├── hw.rs                    # revision detection, reset sequence, init table
│   ├── mmio.rs                  # typed register read/write wrappers
│   ├── regs.rs                  # generated/curated register map (offsets, bitfields)
│   ├── dma.rs                   # coherent + streaming buffer allocation
│   ├── ring.rs                  # TX/RX descriptor rings, typed indices
│   ├── skb.rs                   # typed sk_buff wrappers + FFI ownership state machine (§6.3)
│   ├── pm.rs                    # suspend/resume callbacks, ASPM policy, runtime PM (§3.3)
│   ├── napi.rs                  # NAPI poll-path Rust side; calls into C shim
│   ├── netdev.rs                # thin Rust→C bridge surface
│   ├── stats.rs                 # counters, ethtool surfaces
│   ├── trace.rs                 # tracepoint definitions
│   └── unsafe_boundary.rs       # the ONLY module allowed to contain unsafe
└── cshim/
    ├── netdev_bridge.c          # net_device, sk_buff, NAPI glue
    ├── netdev_bridge.h          # canonical sk_buff ownership contract (§6.3)
    └── README.md                # explicit rationale + migration plan
```

**No `Cargo.toml`, no `rust-toolchain.toml`, no `cargo build` in the critical path.** Kernel Rust out-of-tree modules build through `Kbuild` / `Makefile` and the kernel's own build system. Editor tooling (rust-analyzer) consumes a `rust-project.json` generated by the kernel build, not a Cargo manifest. Lint runs via `make CLIPPY=1`, not `cargo clippy`.

### 6.2 The Unsafe-Code Rule (Architectural, Not Aspirational)

At the crate root:

```rust
#![deny(unsafe_code)]
```

Exactly one module — `unsafe_boundary.rs` — locally permits it:

```rust
#![allow(unsafe_code)]
```

**Why `deny` rather than `forbid`:** Rust's lint semantics do not permit `allow` to override `forbid`. `deny` plus a CI-enforced allowlist of files that may locally `allow` it gives the same practical guarantee with a working override mechanism. CI rejects any new file that `allow`s `unsafe_code` unless that file is named in `.unsafe-allowlist`.

Every `unsafe` block inside `unsafe_boundary.rs` carries a `// SAFETY:` comment that explicitly states:

- Which hardware or C-side invariant is being relied on
- Who currently owns the memory (CPU vs. device)
- What ordering or barrier requirement applies
- Why use-after-free is impossible
- Why ring overrun is impossible

CI enforces the lint. AI-generated patches touching `unsafe_boundary.rs` get the strictest human review.

### 6.3 sk_buff and DMA Ownership at the FFI Boundary

The C shim hands raw `struct sk_buff *` pointers to Rust and accepts them back. To Rust's borrow checker, these are opaque `*mut c_void` values — the compiler cannot enforce ownership across this boundary. Correctness in this region rests on a **manually enforced state machine**, documented here and encoded in `cshim/netdev_bridge.h` as the canonical contract.

The two failure modes this protocol is designed to prevent are exactly the ones the `ewaldc` rewrite calls out: "wrong fragment count with lots of small packets" (a TX slot believes it's empty while still holding a live skb pointer) and "occasional data corruption" (an RX page is freed or recycled while hardware is mid-write).

#### TX Path Ownership

| Stage | Owner | Transition |
|---|---|---|
| 1. Kernel calls `ndo_start_xmit(skb)` | Driver receives ownership | Driver MUST dispose in exactly one of (2a, 2b, 2c) |
| 2a. Driver accepts: maps DMA, stores skb in TX ring slot, posts descriptor | Driver | Slot: `Empty → Submitted` |
| 2b. **Exceptional ring-full race**: driver returns `NETDEV_TX_BUSY` | Kernel **retains** ownership | Driver must not have stored, DMA-mapped, freed, or retained the skb. Wrapper goes out of scope **without** calling `dev_kfree_skb`. `tx_busy_exception` counter increments. |
| 2c. Driver drops (malformed, DMA map failure, validation reject) | Driver | Driver calls `dev_kfree_skb_any()` **exactly once** |
| 3. Hardware finishes TX, IRQ fires | Driver still owns | Slot: `Submitted → Completing` |
| 4. Completion reaper extracts skb, unmaps DMA, calls `napi_consume_skb()` | Stack reabsorbs | Slot: `Completing → Empty` |

**`NETDEV_TX_BUSY` is not a normal backpressure path.** Linux netdev documentation is explicit that `ndo_start_xmit()` should not return `NETDEV_TX_BUSY` under normal circumstances — the driver's responsibility is to stop the TX queue (via `netif_stop_queue()` / `netif_tx_stop_queue()`) before the ring fills, and to wake it (via `netif_wake_queue()` / `netif_tx_wake_queue()`) from the completion path once descriptors are available again. A `TX_BUSY` return means the driver missed the stop boundary; it is a counted exception, not a routine outcome. The invariants when it does happen:

- No DMA mapping exists.
- No ring slot references the skb.
- No driver-owned reference remains anywhere.
- No free path ran (the kernel will requeue).
- The `tx_busy_exception` counter increments and the event is tracepoint-logged for diagnosis.

Flow-control correctness is therefore part of the M5 NAPI gate (see §7 M5), not an afterthought.

#### RX Path Ownership

| Stage | Owner | Transition |
|---|---|---|
| 1. Driver pre-allocates page-pool / page-frag buffers at `ndo_open` | Driver | Buffers are recycled across packets; never per-packet `alloc_pages` on the hot path |
| 2. Hardware DMA-writes packet into a posted buffer | Driver still owns the page | Slot: `Posted → Filled` |
| 3. NAPI poll constructs an skb wrapping (or copying from) the buffer using `napi_build_skb` / `napi_alloc_skb` / page-pool recycling primitives | Driver owns the skb briefly | Page is given to the skb as a frag, recycled, or for small packets copied into a freshly allocated linear skb |
| 4. Driver calls `napi_gro_receive(napi, skb)` | Stack takes ownership | Transfer is unconditional — the call has no failure return that requires the caller to free |
| 5. Failure between steps 3 and 4 | Driver | Driver MUST `dev_kfree_skb()` exactly once and recycle/free the page |

**Hot-path allocation policy (reconciling with §6.4):** the driver does not perform descriptor, page, or page-pool allocations on the RX hot path — those are paid at `ndo_open`. It does construct an skb head per packet via the NAPI/page-pool fast paths (`napi_build_skb` and friends), which the kernel's networking stack treats as the supported zero-copy-style RX strategy. Any failure on this path is a counted, tested branch.

#### Encoded in the Type System

Type-state wrappers in `skb.rs` make illegal sequences unrepresentable:

```rust
// Conceptual — exact shape depends on what netdev_bridge.h exposes.
pub struct TxSkb<S: TxState> {
    raw: NonNull<c_skbuff>,
    _state: PhantomData<S>,
}

pub struct Received;          // Just arrived from ndo_start_xmit
pub struct Mapped(DmaHandle); // DMA mapping established
pub struct Submitted;         // Posted to ring; HW may be reading
pub struct Completing;        // HW released; reaper holds it

// State transitions consume `self` — no path back to a prior state by accident.
impl TxSkb<Received> {
    pub fn map_for_dma(self, dev: &PciDev) -> Result<TxSkb<Mapped>, (Self, DmaErr)> { /* ... */ }
    pub fn return_to_stack_busy(self) -> TxBusy { /* exceptional path; releases without freeing */ }
    pub fn drop_with_error(self) { /* calls dev_kfree_skb_any exactly once */ }
}

// Drop is the LEAK DETECTOR, not the cleanup path.
// Reaching Drop means the state machine was violated.
impl<S: TxState> Drop for TxSkb<S> {
    fn drop(&mut self) {
        #[cfg(debug_assertions)]
        panic!("TxSkb<{}> dropped without explicit disposition", S::NAME);
        // Release builds: WARN_ON_ONCE + quarantine queue + fatal counter; fail closed.
    }
}
```

Each terminal transition (`submit_to_ring`, `return_to_stack_busy`, `drop_with_error`, `complete_and_consume`) uses `mem::ManuallyDrop` or `mem::forget` after performing exactly one disposition.

**Environment-specific `Drop` behavior:**

- **VFIO development guest (debug build):** panic on `Drop`. Fast feedback; the guest is disposable.
- **Release / user-installed module:** emit `WARN_ON_ONCE`, increment a fatal accounting counter, quarantine the affected queue if possible, and fail closed (do not silently leak). Panic-on-Drop is too aggressive for user systems.

#### Allocation Accounting

Every disposition path increments a tracepoint counter (`tx_consumed`, `tx_busy_exception`, `tx_dropped_error`, `rx_handed_to_stack`, `rx_dropped_error`). At any quiescent moment, the invariant `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error` must hold. CI runs a smoke test that asserts this after a 1 GB transfer; mismatch is a P0 bug.

#### The Boundary Contract Is the Deliverable

The C shim's value is not its source code — it is this contract. `cshim/netdev_bridge.h` documents every function with explicit pre/post-conditions on skb ownership, including the flow-control invariants above. Any change to the contract requires updating both the header and `skb.rs` in the same commit. Reviewers reject patches that touch one without the other.

### 6.4 Performance Discipline

Hot paths in the driver (RX poll, TX submit, completion reaping) are subject to the project's separate **High-Performance Rust Coding Standards v2.0** document. Specifically relevant patterns:

- **No descriptor, page, or page-pool allocation on the hot path.** RX data buffers are pre-posted and recycled via page-pool primitives. skb head construction uses the kernel's NAPI fast paths (`napi_build_skb` and friends), which are the supported zero-copy-style RX strategy — see §6.3 for the reconciliation. Any allocation-failure branch is tested and counted.
- **No `format!`, `String`, or heap collections in interrupt/NAPI context.** Logging on the hot path uses tracepoints, not `pr_info!`.
- **Cache-line awareness.** Producer and consumer indices for TX and RX rings are placed on separate cache lines to avoid false sharing between the IRQ thread and NAPI poll context. Use explicit `#[repr(align(64))]` on shared-counter structs.
- **Static dispatch only on the hot path.** No `dyn Trait` in poll or submit paths.
- **Branchless inner loops where possible** in checksum and copy paths.

Kernel Rust differs from userspace Rust in important ways — no `std`, custom allocator, no `LazyLock` in the same form, no `tracing` crate — so the coding standards apply in spirit rather than verbatim. The principles (borrow over clone, pre-size collections, avoid allocations in hot paths, structured-not-string telemetry) translate directly. The specific APIs do not.

---

## 7. Hardware Bring-Up Milestones

Each milestone is a **gate**. M1-M3 depend on M0a. M4 and later require both M0a and M0b, because M4 is the first packet-moving milestone.

### M0a — Pre-Link Fact Discovery and Automation (No Switch Required)

This milestone is deliberately runnable with the RTL8125 RJ45 port unplugged. It proves that the host, guest, kernel toolchain, VFIO path, and non-packet driver lifecycle are testable before any physical link partner is connected.

**Deliverables:**
- `lspci -nnvv` output for the RTL8125 on the actual MS-A2 unit
- `ethtool -i`, `ethtool -k`, `ethtool --show-eee`, and link-state `dmesg` under existing `r8169`; link may be down
- Exact chip revision (A / B / BG / BGS / BP) of the physical part
- IOMMU group membership of the RTL8125 PCI function
- **Kernel-build feasibility check** (pre-M1 blocker): `make LLVM=1 rustavailable` runs successfully against the selected kernel source tree, accepted versions recorded
- **Trivial OOT Rust module check** (pre-M1 blocker): a "hello world" Rust kernel module (e.g., the Rust-for-Linux samples) builds and loads against the *exact* installed guest kernel and headers. If it does not, the Ubuntu kernel package lacks the Rust metadata required for OOT Rust modules, and the project switches the guest to a self-built kernel before M1.
- **Guest kernel configuration captured**: `CONFIG_RUST`, `CONFIG_MODVERSIONS`, `CONFIG_DMA_API_DEBUG` feasibility, `CONFIG_DEBUG_LOCK_ALLOC` (lockdep), `CONFIG_KASAN`, `CONFIG_KCSAN`, `CONFIG_DEBUG_KMEMLEAK`, Secure Boot state, `vermagic` string, `Module.symvers` hash
- **Host VFIO bind-cycle automation**: 100 cycles of `r8169 → vfio-pci → r8169` using per-device `driver_override`, with the final driver verified by `lspci -k` and zero new `dmesg` warnings
- **Guest VFIO visibility**: QEMU/libvirt guest boots with the RTL8125 passed through; guest `lspci -nnvv` sees the device and host-side serial-console capture is working
- **Privileged trivial-module load loop**: the trivial OOT Rust module is `insmod`/`rmmod` cycled in the guest with module refcount returning to zero and no `dmesg`, `lockdep`, or `kmemleak` reports
- **CI policy checks**: `.unsafe-allowlist` contains only `src/unsafe_boundary.rs`; crate root keeps `#![deny(unsafe_code)]`; no raw MMIO helpers appear outside allowed files; no `Cargo.toml` is introduced; `Assisted-by:` never appears without a human `Signed-off-by:`

**Gate:** All pre-link artifacts checked into `docs/baseline/`. Kernel-build feasibility, trivial OOT Rust module build/load, VFIO guest visibility, serial capture, and CI policy checks pass while the RTL8125 RJ45 port remains unplugged.

### M0b — Physical Link Baseline (Switch or Peer Required)

This milestone starts only when the RTL8125 is connected to the intended test segment. It is required before M4 because packet movement, DHCP, peer captures, throughput, and ASPM/link-stability results are not meaningful without a documented link partner.

**Deliverables:**
- **Physical test topology documented**: what is the RTL8125 RJ45 plugged into? Direct cable to a second machine, or via a managed switch? Switch model, switch firmware, negotiated link speed, EEE / 802.3az / power-save settings on the switch port. None of this is optional — without it, link-stability and ASPM results are not reproducible.
- **Peer device details**: NIC model, kernel version, driver in use on the peer, MTU configured
- Baseline `iperf3` numbers under `r8169` (TCP, UDP, 1500 MTU, 9000 MTU)
- Baseline `iperf3` numbers under out-of-tree `r8125`, if installed
- Packet capture path on the peer verified before the Rust driver sends traffic

**Gate:** Physical topology, peer facts, baseline throughput, negotiated link settings, EEE/power-save settings, and peer capture procedure are checked into `docs/baseline/`.

### M1 — Rust PCI Skeleton

M1 may run with the RTL8125 RJ45 unplugged. It depends on M0a, not M0b.

**Deliverables:**
- Rust module builds via `make -C $KDIR M=$PWD` against the validated kernel
- PCI driver registers for VID `0x10EC` / DID `0x8125`
- `probe()` maps the BAR, reads revision, logs it via `pr_info!`, then succeeds
- `remove()` cleanly tears down — no leaks under `kmemleak`
- **No `net_device` registration yet**
- **`lockdep` enabled in the guest kernel** and clean across the load/unload cycle
- **Periodic `kmemleak` scan** during the test loop (every 100 cycles), not only after the final cycle
- **Module reference count** verified to return to zero after every `rmmod`
- **The selected `kernel::pci` / `kernel::dma` / `kernel::io::mem` APIs** are confirmed to exist and behave as expected in the chosen kernel tree (this is the "validate §5.1 claims" gate)

**Gate:** `insmod` / `rmmod` cycle succeeds **1,000 times** in the guest with zero `dmesg` warnings, zero `lockdep` complaints, zero `kmemleak` reports, and module refcount returning cleanly to zero each iteration.

### M2 — Register and Reset Layer

M2 may run with the RTL8125 RJ45 unplugged. Reset, revision dispatch, and ASPM policy logging are pre-link tests.

**Deliverables:**
- Typed register accessors in `mmio.rs` (e.g., `regs.cmd().write(Cmd::RESET)`)
- Per-revision dispatch table (`hw.rs`) — driver refuses to bind to unknown revisions (**no silent fallback**)
- Controlled hardware reset path with timeout + post-reset register verification
- **Failed reset path is recoverable**: timeout logs revision, PCI address, and last register snapshot; hardware is left in a state where rebind (by us or by `r8169`/`r8125`) succeeds
- After unbind, `r8169` or `r8125` can rebind successfully (state is clean)
- **ASPM capability read from PCIe config space and logged** (L0s / L1 / L1 sub-state advertised support, current platform policy)
- **Conservative ASPM policy applied at probe** for any revision not on the known-good allowlist (L1 sub-states disabled via `pci_disable_link_state()` equivalent)

**Gate:** No raw MMIO access outside `mmio.rs` / `unsafe_boundary.rs`, enforced by `grep` in CI. ASPM policy log line present in `dmesg` after probe. Reset failure path tested by deliberate timeout injection.

### M3 — DMA Ring Allocation (Cold)

M3 may run with the RTL8125 RJ45 unplugged. Descriptor-ring allocation and teardown do not require carrier or packets.

**Deliverables:**
- TX and RX descriptor structures with explicit layout (`#[repr(C)]`, alignment asserted)
- Coherent DMA allocation for descriptor memory via `kernel::dma`
- Streaming-mapping plan documented for packet buffers
- Typed ring indices (newtype `TxHead`, `TxTail`, `RxHead`, `RxTail` — not `usize`)
- Compile-time bounds on ring length (`const RING_LEN: usize`)
- **`CONFIG_DMA_API_DEBUG` enabled in the guest kernel** for this milestone forward; any mapping/freeing API violation triggers a `WARN`
- **Descriptor canaries**: each descriptor includes a software-only sentinel field initialized to a known pattern; the reaper verifies the pattern survived hardware writes, catching device or driver overwrites outside expected descriptor boundaries

**Gate:** Ring allocation + free succeeds under `kmemleak` and `CONFIG_DMA_API_DEBUG`. No packets moved yet.

### M4 — Minimal Single-Queue Packet Path

M4 is the first milestone that requires M0b and a connected physical link partner.

**Deliverables:**
- `net_device` registration via the C shim (`cshim/netdev_bridge.c`)
- `ndo_open` / `ndo_stop` implemented end-to-end
- One TX queue, one RX queue, standard MTU
- No offloads — `ethtool -k` reports all offloads disabled initially
- IRQ fires, NAPI poll runs, packets actually move
- `ping`, ARP resolution, **static IP** addressing, and DHCP lease acquisition all succeed (test both static and DHCP — DHCP exercises broadcast RX, static exercises only directed RX)
- `iperf3` at any throughput
- **`ip link set <iface> down/up` loop** (100 cycles) succeeds with no leak, no stuck link, no `dmesg` warning
- Packet capture on the **peer** interface verifies on-wire correctness, not just local kernel acceptance

**Gate:** 1 GB iperf3 transfer completes with no checksum errors on a packet capture taken at the peer. `ip link` up/down loop passes clean.

### M5 — NAPI Stability, Power Management, and Fuzzing

**Deliverables — NAPI correctness:**
- **`budget == 0` path**: NAPI poll called with budget 0 performs TX cleanup only; does **not** call any RX, page-pool, or XDP API; does **not** call `napi_complete_done()`; this path is explicitly tested
- **Exactly-budget-consumed path**: when poll processes exactly `budget` packets, it returns `budget` (signaling more work) without calling `napi_complete_done()`, and is re-polled
- **IRQ-masking discipline**: interrupts remain masked from the moment NAPI is scheduled until `napi_complete_done()` is acknowledged; this is tracepoint-verified
- **`napi_disable()` / `napi_enable()` sequencing**: cannot double-disable; cannot race with `remove`; cannot race with `ndo_stop`; verified by deliberate concurrent-stress test
- **PREEMPT_RT note**: if the guest kernel is `PREEMPT_RT`, NAPI runs in a kthread context rather than softirq; this is captured in the test report but is not a separate gate
- **Queue stop/wake flow control invariants**:
  - Queue is stopped (`netif_tx_stop_queue`) **before** the TX ring becomes full
  - Completion path wakes the queue (`netif_tx_wake_queue`) only after sufficient descriptors are free
  - Ring indices are updated before queue-state helpers are called
  - `NETDEV_TX_BUSY` returns are counted exceptions, not a normal path; `tx_busy_exception` rate must be ~zero under sustained `iperf3`
- TX completion reaping frees each buffer exactly once (validated by ref-count tracepoint)
- `rmmod` while interface is `up` is either rejected cleanly or quiesces hardware first — never crashes

**Deliverables — Power management:**
- **`suspend` / `resume` PCI callbacks fully implemented** (D3hot minimum; D3cold gated per-revision)
- **10× suspend/resume cycles** with an active traffic harness on the peer. The harness may observe link interruption during suspend, but after every resume it MUST verify: link comes back, packets flow, no DMA faults logged, no stuck link state, allocation-accounting invariants hold.
- **24-hour ASPM idle soak**: device idle with ASPM at conservative policy; at the end, the device must transmit a single packet successfully without manual intervention. This is the historical L1.x lockup test.

**Deliverables — Soak and fuzzing:**
- **24-hour low-rate active soak** (≤ 100 Mbps mixed traffic) with `KASAN` + `KCSAN` + `CONFIG_DMA_API_DEBUG` enabled — zero reports
- **`syzkaller`** configured for networking syscalls and control-plane paths (link up/down, ethtool, MTU change, addr add/del) for at least 4 hours. Scope caveat: `syzkaller` primarily stresses syscall/control-plane code; **`KCOV` does not collect soft/hard interrupt coverage by default**, so NAPI and IRQ paths are not fully covered by syzkaller alone.
- **Packet-mutation harness** to cover the data path: `pktgen` and Scapy/`mausezahn` injecting malformed L2/L3/L4 headers, bad checksums, truncated TCP options, illegal fragmentation. No panics, no `KASAN`/`KCSAN` reports.
- **Optional**: KCOV remote-coverage annotations on the NAPI poll function to bring softirq paths into coverage if syzkaller findings are sparse.
- **Allocation accounting invariant** (§6.3) holds at the end of every soak: `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error`, and the analogous RX equation

**Gate:** All NAPI edge-case tests pass. All four soak/cycle/fuzz tests complete clean. The ASPM 24-hour idle soak is the gate that has historically eliminated entire generations of RTL8125 driver candidates — passing it is the explicit goal of this milestone.

### M6 — Performance Features

Enabled **one at a time**, each with the following gates applied per feature before moving to the next:

1. MSI-X (replace legacy IRQ)
2. Multiple TX queues + RSS
3. Jumbo frames (MTU 9000)
4. RX/TX checksum offload
5. TSO/GSO (only after descriptor semantics verified against datasheet)

**Per-feature gates:**
- `ethtool -K` (or per-feature equivalent) can **disable** the feature at runtime; disabling restores correctness immediately
- Packet capture on the peer verifies on-wire correctness with the feature enabled
- **Bad-checksum injection** (Scapy) does **not** falsely pass as good when checksum offload is enabled (i.e., the driver/hardware does not silently overwrite incoming bad checksums)
- The feature can be disabled per-revision via the revision dispatch table if a regression is found
- Before/after numbers checked into `docs/perf/` include: median throughput, p99 latency under load, **CPU usage per Gbps** (system + softirq), and packet rate for small-packet workloads — not throughput alone

**Gate:** Throughput within 10% of out-of-tree `r8125` on the same hardware. CPU usage no worse. All per-feature rollback paths verified.

### M7 — Upstream / Out-of-Tree Decision

**Deliverables:**
- Maintainer-facing design note
- Feature-delta table vs. `r8169`
- Safety-boundary audit (every `unsafe` block reviewed and signed off)
- License and provenance review (no GPL `r8125` code copied; references documented)
- **Pre-RFC maintainer consultation**: do not post a driver RFC until at least one networking maintainer has reviewed the C-shim boundary and stated whether reusable Rust netdev abstractions should be posted first, separately, as the upstream-acceptable contribution path. Avoid burning reviewer attention on a duplicate-driver RFC if the abstraction path is preferred.
- Decision: (a) submit driver RFC, (b) refactor and contribute the C-shim's Rust replacement upstream first, or (c) release as a maintained out-of-tree module

---

## 8. VFIO Isolation — Mandatory, Not Optional

A faulty driver will panic the kernel. The point of VFIO is that the kernel that panics is the guest's, not the host's.

### 8.1 Host Preparation (One-Time)

1. Enable AMD-V and AMD IOMMU in UEFI.
2. Add to `/etc/default/grub`:
   ```
   GRUB_CMDLINE_LINUX_DEFAULT="... amd_iommu=on iommu=pt"
   ```
   then `update-grub` and reboot.
3. Confirm the RTL8125's PCI address: `lspci -nn | grep 8125` → record (e.g., `07:00.0`).
4. Confirm its IOMMU group is isolated:
   ```
   for d in /sys/kernel/iommu_groups/*/devices/*; do echo "$d"; done | grep 07:00.0
   ```
   The group must contain **only** the RTL8125. If it contains other functions, passthrough is unsafe — see §13 risk register.
5. Blacklist `r8169` from auto-binding to the target device, **without** blacklisting it globally (other Realtek devices on the box may still need it).
6. **Physical / L2 isolation**: ensure the RTL8125 RJ45 is not plugged into the same management switch port domain as the host's I226-V or X710 ports. Even with VFIO containment, a misbehaving driver inside the guest can still generate L2 noise (broadcast storms, malformed frames, MAC flapping). Use a dedicated test-segment switch or a direct cable to a peer machine for the Realtek port.

### 8.2 Per-Session Binding

A script in `tools/bind_vfio.sh` performs:

1. Unbind RTL8125 from `r8169` via `/sys/bus/pci/devices/0000:07:00.0/driver/unbind`
2. **Prefer `driver_override`** over `new_id`: write `vfio-pci` to `/sys/bus/pci/devices/0000:07:00.0/driver_override`, then trigger a rebind. Using `new_id` matches by VID/DID and can affect **all** devices with the same Realtek VID/DID on the system; `driver_override` is per-device and safer.
3. Trigger driver probe: `echo 0000:07:00.0 > /sys/bus/pci/drivers_probe`
4. Verify with `lspci -k` — driver should report `vfio-pci`

A matching `tools/unbind_vfio.sh` reverses the operation cleanly by clearing `driver_override` and rebinding to `r8169`.

**Negative gate — ACS override:** If the RTL8125 shares an IOMMU group with other devices and the `pcie_acs_override` kernel parameter is required to split them, the setup is marked **test-only, not isolation-safe**. Host memory is no longer protected from a malicious or buggy device in the guest. Document this prominently in the README and do not run untrusted guest images in this configuration.

### 8.3 Guest Launch

QEMU/libvirt domain XML includes:

```xml
<hostdev mode='subsystem' type='pci' managed='yes'>
  <source>
    <address domain='0x0000' bus='0x07' slot='0x00' function='0x0'/>
  </source>
</hostdev>
```

The guest's serial console is captured to a host-side file so a panic is recoverable as text even after the guest dies:

```xml
<serial type='file'>
  <source path='/var/log/r8125-guest-serial.log'/>
</serial>
```

### 8.4 Recovery Path

On guest panic:
1. Read `/var/log/r8125-guest-serial.log` for the panic trace.
2. Reset the PCI function: `echo 1 > /sys/bus/pci/devices/0000:07:00.0/reset` (if function-level reset is supported).
3. If the device is wedged hard, a host reboot is the fallback — the I226-V keeps SSH alive throughout the diagnosis.

---

## 9. AI Agent Orchestration — Bounded, Policy-Compliant

AI agents accelerate this project. They do not author it.

### 9.1 Roles

| Mode | Tool example | Scope |
|---|---|---|
| Autonomous loop | OpenHands (self-hosted on MS-A2) | Build, run guest tests, parse serial logs, propose small patches |
| Surgical edits | Aider | Resolve `rustc` errors, refactor register accessors, adjust ring logic |
| Reference reading | Either | Datasheet ingestion, RFC threads, `r8169` source — for understanding only |

### 9.2 Kernel Coding-Assistant Policy — Hard Rules

The Linux kernel's documented policy on AI tools is non-negotiable for this project. Concretely:

- **An AI agent does not add `Signed-off-by:`.** Ever. The DCO is a human attestation.
- **The human submitter remains fully responsible** under the DCO for everything they sign off on, regardless of whether an agent helped write it.
- **`Assisted-by:` trailers are optional** and follow the kernel's documented format when used. They do not transfer responsibility.
- **The normal review process is not modified** because an agent was involved.

Operationally:
- The agent runs in a non-privileged user account that cannot push to the protected branch.
- The CI pipeline rejects commits whose `Signed-off-by:` email does not match a registered human reviewer.
- **CI rejects any commit that contains an `Assisted-by:` trailer without at least one human `Signed-off-by:`.** The `Assisted-by:` trailer documents the assistant's involvement; it does not transfer responsibility, and it does not stand alone.

### 9.3 Provenance Hygiene

- GPL `r8125` derivatives are **read as references**, not copied. Concepts (e.g., "RTL8125B requires this reset sequence") are paraphrased and re-implemented.
- Any patch that closely mirrors external GPL code is rejected and re-written from datasheet primaries.
- The agent's context window is curated: datasheets, register maps, our own architecture doc, the kernel Rust docs. Large external source trees are **not** dumped wholesale into context.

### 9.4 Mechanical Enforcement

The MUST/SHOULD rules in this document and in the Rust Coding Standards are encoded where mechanically possible:

- `make CLIPPY=1` (the kernel build's Clippy integration — **not** `cargo clippy`) runs in CI
- A `grep`-based check that no raw MMIO appears outside `mmio.rs` / `unsafe_boundary.rs`
- A `grep`-based check that `#![deny(unsafe_code)]` is intact at the crate root
- A check that no file outside `.unsafe-allowlist` contains `#![allow(unsafe_code)]`
- An `unsafe` block census in CI — count must only decrease over time, never increase, without an attached justification commit
- `KASAN`, `KCSAN`, `lockdep`, `kmemleak`, and `CONFIG_DMA_API_DEBUG` enabled in the guest test kernel

Human reviewer effort is reserved for judgment calls — architecture, the C-shim surface, hardware reset sequences, the `unsafe` boundary itself.

---

## 10. Debugging and Telemetry

Kernel Rust does not give you `RUST_BACKTRACE=1` line-mapped traces the way userspace does. Plan accordingly.

### 10.1 What Actually Works

| Tool | Purpose |
|---|---|
| Guest serial console captured to host file | Survives guest panic; primary fault-trace source |
| `dmesg` with `dyndbg` enabled | Runtime-toggleable debug prints |
| Debug symbols + `addr2line` on the `.ko` | Map panic addresses back to source lines |
| `panic_on_warn` in guest kernel | Promote `WARN_ON` to a hard fault during development |
| `ftrace` + custom tracepoints (`trace.rs`) | Low-overhead structured event capture on the hot path |
| `perf record` + flamegraphs | CPU profile of the NAPI poll path |
| `bpftrace` / eBPF | Ad-hoc probes into IRQ latency, allocation patterns, queue depth |
| `KASAN` | Catches OOB, UAF, use-after-return in the unsafe boundary |
| `KCSAN` | Catches data races between IRQ and NAPI contexts |
| `kmemleak` | Long-soak leak detection |
| `lockdep` (`CONFIG_DEBUG_LOCK_ALLOC`) | Detects lock-ordering inversions and incorrect locking primitive usage |
| **`CONFIG_DMA_API_DEBUG`** | **Catches DMA mapping/freeing API misuse: double-mapping, freeing unmapped memory, wrong direction, missing sync. Debug-only performance cost. Enable from M3 forward.** |
| **IOMMU fault logging** (`amd_iommu_dump=1`) | **Catches invalid device DMA attempts; correlates fault address to descriptor ring slot** |
| **Descriptor canaries** | **Software-only sentinel field in each descriptor; reaper verifies pattern survived. Detects device or driver overwrites outside expected descriptor boundaries** |
| **Ring snapshot dump on panic** | **On `Oops` or `BUG`, dump head/tail indices, per-slot ownership bits, and skb state for both TX and RX rings to the serial console before the kernel finishes dying** |
| `syzkaller` | Coverage-guided kernel fuzzer; configured for networking syscalls and control-plane paths. **Scope caveat**: `KCOV` does not collect soft/hard interrupt coverage by default, so syzkaller alone does not exercise NAPI/IRQ data paths. Use KCOV remote-coverage annotations on the NAPI poll function if you want softirq coverage. |
| `pktgen` | Built-in kernel TX packet generator. Used for stress and malformed-frame injection without leaving the guest. |
| `scapy` / `mausezahn` | User-space packet crafting for targeted edge cases (bad checksums, illegal headers, fragmentation pathology, truncated TCP options). |
| `pcap` replay + mutation | Replay capture files through the interface with byte-level mutation to exercise parser edge cases. |

### 10.2 What Does Not Work / What to Avoid

- **`RUST_BACKTRACE=1`** is a userspace runtime convention. The kernel's panic path produces an oops with an instruction pointer; you map it back with debug symbols, not with a runtime env var.
- **`pr_info!` on the hot path.** Tracepoints, not printk.
- **Userspace allocators** (`Vec::with_capacity`, etc., in their `std` form) — kernel Rust uses kernel-side fallible allocation; check the `kernel::alloc` APIs, and treat every allocation as fallible.
- **`cargo`-anything as a primary tool.** `cargo asm`, `cargo clippy`, `cargo bench` are userspace conventions. Use `make CLIPPY=1`, `llvm-objdump`, `perf annotate`, and `pahole` instead.

### 10.3 Telemetry into the Agent Loop

The autonomous agent loop ingests:
1. Guest serial log (parsed for `Oops`, `BUG`, `WARN`, `KASAN`, `KCSAN`, `DMA-API`, IOMMU faults)
2. `ftrace` ring-buffer dumps from the guest after each test run
3. `perf` flame data for the M6 performance milestones
4. `iperf3` JSON output for regression comparison
5. Allocation-accounting tracepoint counters at every test boundary (§6.3 invariants)

These are fed back as structured inputs to the next patch-proposal cycle.

---

## 11. Performance Standards

Hot paths in this driver fall under the project's separate **High-Performance Rust Coding Standards v2.0**, with the following kernel-specific adaptations:

| Standards Section | Kernel Adaptation |
|---|---|
| §1 Ownership & Borrowing | Applies directly. `sk_buff` lifetime is the canonical example — ownership crosses the C/Rust boundary; the bridge enforces it (see §6.3). |
| §2 Pre-allocation | Even more critical: kernel hot paths must not allocate descriptors or pages. Pre-allocate at `ndo_open`. skb head construction via NAPI fast paths is the exception, and is itself a tested, counted branch. |
| §3 Iterator chains | Applies; the compiler still fuses well. Verify with `llvm-objdump -dr --demangle` on the built `.ko` and `perf annotate` on hot symbols — **not** `cargo asm`. |
| §8 Static dispatch | Mandatory on hot paths. No `dyn Trait` in NAPI poll. |
| §11 Hashing | Driver has no internal hash maps on the hot path — N/A. |
| §15 Cache alignment & false sharing | **Critically applicable.** TX and RX index pairs must be `#[repr(align(64))]` or wrapped equivalently. Use `pahole` to verify layout. |
| §15 SIMD | Not applicable in kernel; no FPU/SIMD in interrupt context without explicit `kernel_fpu_begin`/`kernel_fpu_end`. Skip. |
| §15 Allocator selection | Not applicable; kernel uses its own slab allocator. |
| §16 Benchmarking | Adapted: in-kernel benchmarks use `ftrace` timing, `bpftrace` histograms, and `iperf3` regressions instead of `criterion`. |
| §18 Tooling & lints | `make CLIPPY=1` runs against the crate in CI. **No Cargo workspace lints in the kernel-build path.** |

PRs that touch hot paths include before/after `iperf3` median + p95 numbers in the PR body. "Feels faster" is not data here either.

---

## 12. Comparison Baseline

Every M4+ milestone is measured against two reference implementations, on the same MS-A2 hardware:

| Reference | Where it comes from | What it tells us |
|---|---|---|
| Mainline `r8169` | Stock Ubuntu kernel | **Upstream-supported baseline.** This is what users get by default; `CONFIG_R8169` covers Realtek 8169/8168/8101/8125 devices. |
| Out-of-tree `r8125` (e.g., `ewaldc` rewrite) | DKMS / source install | **Feature and performance reference**, especially for RSS, MSI-X, multi-TX queues, PTP, and historical hang / data-corruption fixes that motivated the rewrite |

Metrics tracked per milestone:
- TCP single-stream throughput (1500 MTU, 9000 MTU)
- TCP 8-stream aggregate
- UDP small-packet PPS
- CPU% per Gbps (system + softirq)
- p99 latency under load (ping flood + iperf3 background)

---

## 13. Risk Register

| Risk | Severity | Mitigation |
|---|---|---|
| Rust netdev/`sk_buff` abstractions never stabilize in a form compatible with our shim | High | C shim is documented and self-contained; migration is a refactor, not a rewrite |
| **ASPM / L1 sub-state mishandling causes silent DMA loss or idle-time lockup** | **High** | **Conservative default at M2 (L1.x disabled for unvalidated revisions); suspend/resume + 24h idle soak as M5 gate; per-revision allowlist for aggressive policy; module parameter override for users** |
| **`sk_buff` ownership leak or double-free at the FFI boundary** | **High** | **Typed wrapper with type-state transitions in `skb.rs`; panic-on-Drop in debug builds, `WARN_ON_ONCE` + queue quarantine in release; explicit allocation-accounting invariants asserted in CI; protocol fixed in `cshim/netdev_bridge.h` as the canonical contract** |
| **Installed Ubuntu kernel headers lack Rust metadata needed for OOT Rust modules** | **High** | **M0a pre-M1 blocker: build and load a trivial OOT Rust kernel module against the exact installed guest kernel; if it fails, switch the guest to a self-built kernel** |
| **`NETDEV_TX_BUSY` used as a normal backpressure path instead of as an exceptional ring-full race** | **High** | **Queue stop/wake flow-control invariants in M5; `tx_busy_exception` counter must trend to zero under sustained traffic; tracepoint-logged for diagnosis** |
| **Secure Boot blocks the unsigned out-of-tree module on user systems** | **High (distribution)** | **Provide MOK enrollment instructions or signed-package flow; refuse to load rather than fall back silently; lab builds may disable Secure Boot in the VFIO guest** |
| Upstream rejects another RTL8125 driver as duplicate of `r8169` | High | Plan as out-of-tree first; build the case (safety, features, perf) before any submission |
| RTL8125 register documentation is incomplete or wrong | High | Use `r8169` + `r8125` as behavior references; never write undocumented registers blind; bisect against working drivers via PCI traces |
| DMA ownership bug corrupts memory invisibly | High | `KASAN` + `KCSAN` + `CONFIG_DMA_API_DEBUG` + IOMMU fault logging + descriptor canaries; ring-ownership encoded in types; small named unsafe boundary |
| AI-generated unsafe code is plausible but wrong | High | `#![deny(unsafe_code)]` global with CI-enforced file allowlist; `unsafe_boundary` requires human reviewer signoff on every change |
| **Kernel HWE update silently changes the required `rustc` version, breaking DKMS rebuilds at apt-upgrade time** | **High** | **Do not ship DKMS as the default install path. Use per-kernel-build pre-built `.ko` artifacts; see §16 Q5** |
| **`syzkaller` alone misses NAPI/IRQ paths because KCOV does not collect interrupt coverage by default** | **Medium** | **Pair `syzkaller` with a packet-mutation harness (`pktgen` + Scapy) for data-path coverage; add KCOV remote-coverage annotations on NAPI poll if data-path findings are sparse** |
| **Tracepoint schema accidentally becomes a de facto stable ABI** | **Medium** | **Mark all tracepoints as experimental/versioned until M6; document in `trace.rs` and in the README; do not promise stability to downstream tooling** |
| **`#![forbid(unsafe_code)]` cannot be overridden in `unsafe_boundary.rs`** | **Medium (was a v3.1 bug)** | **Use `#![deny(unsafe_code)]` plus a CI-enforced file allowlist instead. Verified before commit.** |
| RTL8125 IOMMU group contains other devices | Medium | Verify in M0a; if group is shared, ACS-override setup is marked **test-only, not isolation-safe** |
| Guest crash wedges the device hard | Medium | Host-side PCI function reset script; cold reboot fallback |
| Performance lags `r8125` | Medium | M6 unlocks features incrementally with measurement; correctness first |
| Provenance ambiguity from GPL references | Medium | Read-don't-copy rule; agent context curated; human DCO signoff only |

---

## 14. Upstream Strategy — Plan B, Not Plan A

Kernel Rust policy is explicit: each subsystem decides Rust adoption, duplicate C/Rust drivers are not accepted by default, and out-of-tree Rust modules must expect internal API churn.

The realistic argument for upstream consideration would require at least one of:

1. The driver supports a specific RTL8125 feature `r8169` does not adequately support, with measured user impact.
2. The driver is materially safer (auditable, smaller unsafe surface) while matching `r8169` performance.
3. The work produces reusable Rust netdev / `sk_buff` / NAPI abstractions that other drivers can build on — in which case those abstractions are the upstream contribution, and the RTL8125 driver is the proof-of-use.
4. A networking maintainer explicitly agrees this device is a useful Rust target.

Until at least one of those is demonstrated with code and measurements, **the project's posture is out-of-tree maintained module, not upstream candidate.**

**Practical pre-RFC gate:** do not post an RTL8125 driver RFC to netdev until at least one networking maintainer has reviewed the C-shim boundary in private and stated whether the reusable Rust netdev abstraction work should be posted first, separately. This avoids burning maintainer attention on a duplicate-driver discussion when the abstraction path is the actually-acceptable contribution.

---

## 15. M1 Entry Criteria — When Implementation May Begin

This document's overall status is **ready for M0a (pre-link fact discovery)**. M1 (code-writing) may begin only when **all** of the following pre-link criteria are true and checked into the repo:

- [ ] MS-A2 hardware inventory captured (CPU SKU, RAM populated, exact NIC silicon revisions including the RTL8125 sub-revision)
- [ ] Ubuntu 26.04 LTS installed on host with the selected kernel
- [ ] **`make LLVM=1 rustavailable` accepted against the selected kernel source tree**; accepted Rust, LLVM, `bindgen` versions recorded
- [ ] **A trivial out-of-tree Rust kernel module builds and loads against the exact guest kernel** using the same KDIR, Rust metadata, LLVM, `bindgen`, `Module.symvers`, and `vermagic` that the RTL8125 module will use
- [ ] `CONFIG_RUST`, `CONFIG_MODVERSIONS`, `CONFIG_DMA_API_DEBUG`, `CONFIG_DEBUG_LOCK_ALLOC`, `CONFIG_KASAN`, `CONFIG_KCSAN`, `CONFIG_DEBUG_KMEMLEAK` feasibility checked and recorded
- [ ] Secure Boot state captured (enabled/disabled, MOK status)
- [ ] Pre-link `r8169` facts captured for the unplugged target port (`ethtool -i`, `ethtool -k`, `ethtool --show-eee`, link state, and relevant `dmesg`)
- [ ] VFIO passthrough procedure executed end-to-end against the RTL8125, with the guest seeing the device, **before any driver code is written**
- [ ] IOMMU group isolation verified (or ACS-override decision recorded — marked test-only if so)
- [ ] Host-side `r8169 → vfio-pci → r8169` bind-cycle automation passes using `driver_override`
- [ ] RTL8125 RJ45 port remains unplugged, or otherwise physically isolated, for all M0a/M1-M3 tests
- [ ] `tools/bind_vfio.sh` / `tools/unbind_vfio.sh` using `driver_override` working and committed
- [ ] Guest serial-console capture configured and tested with a deliberate `panic()` from a known-good test module
- [ ] CI scaffold builds an empty Rust kernel module against the validated kernel, in the guest, automatically
- [ ] Agent workflow rules (no `Signed-off-by` from agents, `Assisted-by` format, CI rejection of agent-only commits) encoded in CI checks
- [ ] `.unsafe-allowlist` file in place containing only `src/unsafe_boundary.rs`; CI enforces it
- [ ] This document reviewed and signed off by the human owner

Only then does M1 begin.

M0b physical topology, peer details, L2 isolation, and `r8169`/`r8125` throughput baselines are required before M4 begins.

---

## 16. Open Questions to Resolve Before M1

1. **Exact RTL8125 revision** on the physical MS-A2 unit — drives the register dispatch table.
2. **IOMMU group composition** — does the group include only the RTL8125, or are other functions captive? If captive, the setup is marked test-only and the README documents it.
3. **C-shim scope freeze** — what is the maximum LOC budget for `cshim/netdev_bridge.c`? Proposed: 400 LOC, hard-capped, reviewed line-by-line.
4. **Tracepoint schema** — **all tracepoints are marked experimental/versioned until M6.** No external tooling should treat them as a stable ABI before that. Minimum event set: RX submit, RX complete, TX submit, TX complete, TX busy exception, IRQ entry, NAPI poll entry/exit, ASPM state change, suspend/resume entry/exit.
5. **Out-of-tree distribution model** — DKMS is **not** viable as the default mechanism on Ubuntu LTS because Hardware Enablement (HWE) kernel updates can silently change the kernel's required `rustc` version (e.g., 1.93 → 1.95) under a user during a routine `apt upgrade`. The next boot rebuilds the module with the wrong toolchain and the network interface vanishes — exactly the failure mode that destroys user trust in out-of-tree drivers.
   - **Primary: pre-built module package per exact kernel ABI tuple.** A small APT repository publishes one binary per tuple:
     ```
     (kernel release,
      Ubuntu kernel ABI package version,
      architecture,
      vermagic string,
      CONFIG_MODVERSIONS / Module.symvers CRC set,
      kernel config hash,
      CONFIG_RUST state,
      rust metadata package version,
      rustc version,
      LLVM version,
      bindgen version,
      module signing state)
     ```
     The package's post-install script verifies the running kernel matches a published artifact; if not, it logs a clear message and **refuses to activate** the module rather than rebuilding with an unknown toolchain or falling back to a wrong-ABI binary. CI publishes new artifacts within 48 hours of each Ubuntu HWE kernel release.
   - **Secure Boot:** if Secure Boot is enabled on the user system, the package must either ship modules signed through a trusted key path or provide an explicit MOK enrollment flow. Refusing to load is better than silently falling back to an unsigned or wrong-ABI module.
   - **Secondary (advanced users): source distribution with a pinned toolchain bootstrap.** A `setup.sh` checks out a known-good kernel source tree, fetches the matching `rustup` toolchain via `make LLVM=1 rustavailable`, and builds locally. Explicitly opt-in, explicitly **not** registered with DKMS.
   - **Explicitly rejected: DKMS as the default install path.** If a distro packager insists on DKMS, the package's pre-build hook must verify the toolchain version against an embedded allowlist and fail fast on mismatch. Document this prominently in the README.
6. **License declaration** — GPL v2 (matches kernel); confirm no MIT-only dependencies in the Rust crate.
7. **Naming** — `r8125_rust` is a working name. A non-confusable name avoids collisions with the existing out-of-tree `r8125`.

---

## 17. Changelog

- **v3.3** — Split M0 into M0a pre-link automation and M0b physical-link baseline. M0a is explicitly runnable with the RTL8125 RJ45 unplugged and adds automated host VFIO bind cycling, guest passthrough visibility, privileged trivial-module load/unload looping, serial-capture validation, and CI policy checks before any switch or peer is connected. M0b now owns physical topology, peer details, L2 isolation, peer packet-capture readiness, and `r8169`/`r8125` throughput baselines, and is required before M4 rather than before M1. Clarified that M1-M3 may run unplugged, while M4 is the first packet-moving milestone requiring a link partner. Removed duplicate "Only then does M1 begin."
- **v3.2** — Addressed second-round review feedback. Softened §0 Rust API maturity claim from "production-grade" to "sufficient for a staged out-of-tree prototype, must be validated against the selected kernel tree." Switched lint discipline from `#![forbid(unsafe_code)]` to `#![deny(unsafe_code)]` (forbid cannot be overridden by allow). Made Kbuild/Makefile authoritative in §6.1; removed `Cargo.toml` and `rust-toolchain.toml` from the critical build path; replaced `cargo asm`/`cargo clippy` with kernel-build equivalents (`make CLIPPY=1`, `llvm-objdump`, `perf annotate`, `pahole`) throughout §10 and §11. Replaced rust-toolchain.toml pin language in §2 with `make LLVM=1 rustavailable` against the kernel tree. Added a pre-M1 blocker for OOT Rust kernel-metadata feasibility (M0 + §15). Reframed `NETDEV_TX_BUSY` in §6.3 as an exceptional ring-full race, with explicit queue-stop/wake flow-control invariants moved into M5; reconciled the §6.3 vs §6.4 RX-allocation contradiction (no descriptor/page allocation on the hot path; skb head via NAPI fast paths is the supported, counted exception). Renamed ASPM module-parameter values to unambiguous `kernel|conservative|force_off|aggressive`. Fixed PCIe 2.0 bandwidth claim (5.0 GT/s with 8b/10b ≈ 4 Gbps per direction); softened jumbo-frame language. Expanded M5 with explicit NAPI edge cases (budget==0, exactly-budget-consumed, IRQ-masking, `napi_disable` race, PREEMPT_RT note). Clarified syzkaller scope re: KCOV not collecting soft/hard IRQ coverage by default. Added `CONFIG_DMA_API_DEBUG`, IOMMU fault logging, descriptor canaries, and ring-snapshot-on-panic to §10 and M3. Made the type-state `Drop` behavior environment-specific (panic in debug VFIO guest; `WARN_ON_ONCE` + quarantine in release). Switched VFIO binding to `driver_override` (per-device, safer than `new_id`); added ACS-override negative gate and L2 isolation requirement. Added CI rule rejecting `Assisted-by:` without human `Signed-off-by:`. Reworded §12 baseline (r8169 as upstream-supported baseline, not "floor"). Added P0/P1 risks: OOT Rust metadata missing, `NETDEV_TX_BUSY` misuse, Secure Boot block, syzkaller miss, tracepoint ABI accident, and the v3.1 forbid/allow lint bug itself. Added §14 pre-RFC maintainer consultation gate. Renamed §15 to "M1 Entry Criteria" to remove the "implementation-ready" contradiction with the status line; expanded checklist with kernel-build feasibility, OOT module test, kernel config capture, Secure Boot state, physical topology, L2 isolation, `.unsafe-allowlist`. Marked tracepoints experimental in §16 Q4. Expanded §16 Q5 distribution tuple with `vermagic`, `Module.symvers` CRC, kernel config hash, Rust metadata package version, module signing state, plus an explicit Secure Boot policy. Removed MS-A1 distraction and "community-validated 128 GB" anecdote.
- **v3.1** — Addressed review feedback. Added §3.3 (ASPM and runtime power management as a first-class hazard, with module-parameter override and per-revision allowlist). Added §6.3 (`sk_buff` and DMA ownership protocol at the FFI boundary) with explicit TX and RX state-machine tables, type-state Rust wrapper sketch, panic-on-Drop leak detection, and an allocation-accounting invariant. Renumbered §6.3 Performance Discipline → §6.4. Added `skb.rs` and `pm.rs` to the module layout. Added ASPM capability detection and conservative-default policy to M2. Renamed M5 to "NAPI Stability, Power Management, and Fuzzing" and added suspend/resume cycling under load, 24-hour ASPM idle soak, and a 4-hour `syzkaller` fuzzing run to its gate. Added `syzkaller`, `pktgen`, Scapy/`mausezahn`, and `pcap` replay+mutation to the §10 debug stack. Added three risks to §13: ASPM lockup, `sk_buff` ownership leak, and HWE-triggered Rust toolchain drift. Rewrote §16 Q5 with a concrete distribution model that rejects DKMS as the default install path in favor of per-kernel-build pre-built artifacts.
- **v3.0** — Unified implementation-planning revision. Adopted all corrections from the validation review: official MS-A2 specs as authoritative, Ubuntu 26.04 LTS baseline, honest split of mature vs. RFC-level Rust-for-Linux subsystems, explicit C-shim approach for netdev/`sk_buff`/NAPI with documented migration plan, kernel coding-assistant policy compliance, realistic debugging stack (no `RUST_BACKTRACE=1`), measured upstream strategy. Restructured around gated milestones M0–M7 with explicit acceptance criteria. Added §15 Acceptance Criteria and §16 Open Questions for pre-M1 close-out.
- **v2.0** — Validation/correction pass (source document 2).
- **v1.0** — Original feasibility analysis (source document 1).
