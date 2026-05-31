# cshim contract vs kernel netdev C contract — diff

**Status (2026-05-29):** desk-research for M7 outbound-blocker #4
(see [`M7_PRE_RFC_DOSSIER.md`](M7_PRE_RFC_DOSSIER.md) reading-list
checklist). Goal: surface every aspect of our cshim contract
([`src/netdev_bridge.h`](../src/netdev_bridge.h)) that's an artifact
of OUR Rust safety model rather than a kernel-C requirement. Those
are the places a maintainer would want to know "why did you encode
this, and what would weakening it cost you?"

Two-way check: where we encode something the kernel C side doesn't
demand, we want to justify it; where the kernel C side demands
something we appear to NOT encode, we want to verify we satisfy it
by some other means before claiming the contract is sound.

## Methodology

Source-of-truth for the kernel C contract:

- [`Documentation/networking/driver.html`](https://docs.kernel.org/networking/driver.html)
  — net_device lifecycle, `ndo_start_xmit` return semantics,
  `ndo_stop` post-condition, cloned-skb rule.
- [`Documentation/networking/napi.html`](https://docs.kernel.org/networking/napi.html)
  — NAPI poll budget, IRQ masking, `napi_disable` race rule.
- [`Documentation/networking/netdev-features.html`](https://docs.kernel.org/networking/netdev-features.html)
  — `ndo_fix_features`, `netdev_update_features` locking.

Source-of-truth for our cshim contract:

- [`src/netdev_bridge.h`](../src/netdev_bridge.h) — the deliverable.
- [`src/netdev_bridge.c`](../src/netdev_bridge.c) — actual wiring.
- [`src/napi.rs`](../src/napi.rs) §poll — NAPI-side compliance.
- [`src/netdev.rs`](../src/netdev.rs) §xmit — TX-side compliance.

## §A — Rules where the cshim MATCHES kernel C docs

These are the boring ones; we satisfy the documented kernel C
contract verbatim. No raise needed; included for completeness.

| Kernel C rule | Where it lives in our cshim |
|---|---|
| `NETDEV_TX_OK` ⇒ driver takes ownership of skb, must free in finite time | `netdev_bridge.h` §xmit Post + `src/netdev.rs` `rust_xmit` consume paths |
| `NETDEV_TX_BUSY` ⇒ kernel retains skb, driver must NOT keep ref or free it | `netdev_bridge.h:102` "skb UNTOUCHED" + `netdev.rs:1189` early return without map/free |
| `ndo_stop` post-condition: "hardware must not receive or transmit any data" | `netdev_bridge.c` `bridge_ndo_stop` calls `b->ops.stop(b->priv)` which is `quiesce_chip()` |
| `napi_complete_done` MUST be called only when `work_done < budget` | `napi.rs:255` `if work_done < budget` guard, enforced by `ci/check_napi_contract.sh` |
| IRQ unmask only AFTER successful `napi_complete_done` | `napi.rs:260-261` strict ordering, enforced by `check_napi_contract.sh` |
| `budget == 0` ⇒ never call `napi_complete_done`; may run TX reaper; no XDP/page-pool | `napi.rs:226-232` `budget_u = 0` collapse, RX skipped; TX reaper still runs; we have no XDP/page-pool |
| Exactly-budget-consumed ⇒ skip `napi_complete_done`, return `budget` for re-schedule | `napi.rs:255-265` `work_done < budget` is false ⇒ falls through to return |
| `ndo_fix_features`: disable features when dependencies aren't met | `netdev_bridge.c` `bridge_ndo_fix_features` drops TSO+CSUM when `mtu > ETH_DATA_LEN` (mirrors r8169) |
| `netdev_update_features` must hold rtnl_lock | `bridge_ndo_change_mtu` calls it from rtnl-held ndo callback context |
| `ndo_start_xmit` must not modify shared parts of cloned SKB | Cshim offload helpers READ `skb->ip_summed` / `shinfo->gso_size` / protocol headers; NEVER write skb fields (verified: `grep -nE 'skb->' src/netdev_bridge_offload.c` shows reads only) |

## §B — Where the cshim is STRICTER than kernel C (over-enforcement)

These are the deliberate raises. Each is a place where kernel C
permits something we've forbidden, because forbidding it lets us
encode the invariant in the Rust type system or in mechanical CI
gates. **For the M7 outbound, these are the answer to "why do you
even need a cshim that does X when kernel C doesn't require it?"**

| Cshim over-enforcement | Kernel C permits | Our reason | M7-dossier value |
|---|---|---|---|
| **Linear sk_buff ownership** via `DriverOwnedSkb` (`#[must_use]`, no `Drop`, consume verbs only) | `skb_get` / `skb_unref` for multi-ref reads | We don't need multi-ref; forbidding it eliminates a class of double-free / use-after-free at compile time | **Highest** — directly mirrors FUJITA Tomonori's 2023 sk_buff proposal ("must explicitly call to drop, can't go out of scope"). Independent convergence on the same shape is a strong design signal. |
| **§6.3 disposition-counter invariant** `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error` | No kernel C driver maintains this. Drivers bump `ndo_get_stats64` arbitrarily | Machine-checkable counter correctness; `ci/check_counter_invariant.sh` runs after every 1 GB transfer | **High** — gives us drop attribution by class, which heterogeneous-LB postmortem needs. Easy to propose as a kernel-Rust pattern. |
| **`IrqMode` enum** discriminating `Intx` vs `Msi`/`MsiX` at the type level | C drivers commonly handle MSI/INTx polymorphically via `pdev->msi_enabled` runtime checks | The chip's V2 ISR register surface differs from legacy ISR — type-discriminating prevents "read legacy ISR while in V2 mode" (the bug class that bit us during M6 #1 Phase A.2) | **Medium** — would translate to a Rust `IrqType` enum on `kernel::pci::Device<Bound>` |
| **`NetdevHandle::shutdown()` BEFORE `devres_release_all`** ordering enforced by `pci::Driver::unbind` | C drivers rely on convention + code review for teardown order | This is the explicit fix for the [#58 BAR-UAF](../../../../home/firestrand/.claude/projects/-home-firestrand-Projects-Rt8125-driver/memory/gateway-rmmod-hang-takedown.md). Mechanical ordering prevents the entire bug class. | **High** — concrete real-bug example we can cite |
| **RAII guards** (`RxPoolGuard` / `IrqGuard` / `TxMapGuard`) with `Option<T>::take()` linear ownership | C drivers use goto-cleanup labels | Mechanical Drop-impl unwind handles ALL error paths uniformly. goto-cleanup has documented track record of dropping cleanup steps in the middle. | **Medium** — Drop-impl unwind is idiomatic kernel-Rust; we'd just describe |
| **Per-file `Hard cap: N LOC`** on every cshim TU | Kernel C has soft conventions (~1000 LOC) | Forces decomposition before files become unreviewable. Enforced by `ci/check_cshim_loc_caps.sh`. | **Low** — interesting as project discipline, not abstraction-relevant |
| **Idempotent free guards** (`if (!cpu) return;` in RX pool free) on partial-allocation paths | C drivers usually handle this via init/cleanup-symmetry conventions | Cheap defensive coding for the M-of-N partial-allocation rollback case | **Low** — boring detail |

## §C — Rules where kernel C demands something we appear to relax (verification)

The dangerous direction. If kernel C requires something and our
cshim or Rust side appears to NOT encode it, we either (i) satisfy
it by accident-of-good-design, or (ii) have a real bug. Each row is
explicitly verified.

| Kernel C rule | Our apparent compliance | Verification |
|---|---|---|
| `napi_disable()` "waits for ownership released, not for poll method to exit. Drivers should avoid accessing data structures after `napi_complete_done`." | Our `napi.rs:260-261` calls `bridge_napi_complete_done` then `rearm_irq_baseline(state)` — looks like a UAF window | **Safe by ordering.** Cshim's `r8125_bridge_unregister_and_free()` (netdev_bridge.c:208-229) calls `unregister_netdev()` (runs `ndo_stop`+`napi_disable`) → `netif_napi_del()` → `free_netdev()`. `netif_napi_del` waits for the active poll to actually exit before returning. Our `NetdevState` `KBox` is dropped only AFTER the entire shutdown sequence returns. So between `napi_complete_done` and `KBox::drop` the state is alive AND no future poll will run. The race the kernel doc warns about (data freed between napi_disable return and poll's natural exit) is closed. |
| `NETDEV_TX_BUSY` "considered a hard error unless there's no way your device can tell ahead of time when its transmit function will become busy" | We DO have ring-fullness visibility ahead of time; `TX_STOP_THRS=32` queues stop before we return BUSY | **Compliant.** `netdev.rs:1267-1289` `tx_stop_queue` is called *preemptively* on the success path when post-xmit free slots cross under `TX_STOP_THRS`. `NETDEV_TX_BUSY` is reserved for the documented exceptional SMP race (TX reaper drained the ring on another CPU between our free-check and our reservation). Plan §6.3 names this. |
| `ndo_start_xmit` "must not modify the shared parts of a cloned SKB" | We read shinfo + ip_summed + protocol headers, never write skb data fields | **Compliant.** `grep -nE 'skb->[A-Za-z_]+ = ' src/netdev_bridge.c src/netdev_bridge_offload.c` returns no writes. The csum offset / TSO opts are computed and returned in out-parameters; the skb is never mutated. |
| `napi_disable()` "is not idempotent. Calling napi_disable() multiple times causes deadlock." | Our `NetdevHandle::shutdown()` could in principle be called twice | **Compliant.** `shutdown()` is gated by `disposed` atomic flag — first caller transitions it false→true and runs the teardown; subsequent calls are early-return no-ops. Documented in `pci.rs` shutdown impl. |
| `ndo_open` / `ndo_stop` run under RTNL | Our Rust open/stop assume RTNL-held caller context (for reading PHY state, etc.) | **Compliant.** netdev_bridge.h:54 documents the pre-condition. Our Rust code does no recursive RTNL acquisition; it consumes the held-by-caller lock for the duration. |

No real bugs surfaced. Every place where we appeared to relax a kernel C requirement turned out to be satisfied by some structural property we'd already established. That's a positive signal — our refactor sequence (#59-#62) drove us to ordering invariants that close several kernel-C-doc concerns without us having had those docs in front of us when we did the work.

## What this means for the M7 outbound dossier

| Dossier claim | Refinement after this diff |
|---|---|
| "Our `DriverOwnedSkb` discipline is the same pattern Tomonori proposed in 2023" | **Strengthened.** §B row 1 — verified the design rationale is mechanical (eliminating a class of bugs at compile time), not just aesthetic. The independent convergence with Tomonori's 2023 design becomes a stronger argument for the shape. |
| "We could propose `kernel::net::SkBuff`" | **Concrete shape now known.** §B row 1 + §C row 3 + §C row 4 give us the actual invariants the type would enforce: linear ownership + immutable across cloned-shared boundary + must-call-consume + idempotent shutdown. |
| "Our cshim isn't doing anything the C side wouldn't" | **Wrong as stated; revise.** Per §B we are deliberately encoding 7 over-enforcements vs kernel C. Those are FEATURES, not bugs. The outbound should own them: "here are the invariants we chose to add over the kernel C baseline, and here is the bug each one prevented." |
| "Single-series proposal" framing | **Sharpened.** §B row 4 (the #58 BAR-UAF teardown ordering) is concrete bug evidence the abstractions prevent. Maintainers respond to real bug stories. Worth quoting in the outbound. |

## Recommended dossier patches (not yet applied)

1. **Add §"Our deliberate over-enforcements vs kernel C"** to the
   outbound dossier, citing this file as the diff. List the 7 rows
   from §B with one-line rationale each.
2. **Sharpen the M7-dossier intro paragraph** to say "we encode
   N invariants over the kernel C baseline; each one prevents a
   real bug class we've experienced" rather than the current "we
   built a thin cshim." The cshim is thin in LOC but thick in
   contract — that's a feature.
3. **Cite the #58 BAR-UAF story** as a concrete example. Real bug,
   real fix, mechanical encoding. Maintainers will care.

## Outbound-blocker checklist

- [x] cshim vs `Documentation/networking/` lifecycle diff — **this file**.

That closes 4 of 5 M7 outbound-blockers. Only the soak sign-off
(item 5) remains, and it's purely time — Gateway 24 h ASPM-on
finishes 2026-05-30 ~03:05 UTC.

## Cross-references

- [`M7_PRE_RFC_DOSSIER.md`](M7_PRE_RFC_DOSSIER.md) — outbound consultation
- [`M7_RUST_NETDEV_LANDSCAPE.md`](M7_RUST_NETDEV_LANDSCAPE.md) — on-list survey
- [`M7_BLOCK_CADENCE.md`](M7_BLOCK_CADENCE.md) — block:: timing calibration
- [`M7_PREP.md`](M7_PREP.md) — three-exit decision matrix
- [`../src/netdev_bridge.h`](../src/netdev_bridge.h) — the cshim contract
- [`../src/napi.rs`](../src/napi.rs) — NAPI poll compliance
- Kernel docs: [driver.html](https://docs.kernel.org/networking/driver.html),
  [napi.html](https://docs.kernel.org/networking/napi.html),
  [netdev-features.html](https://docs.kernel.org/networking/netdev-features.html)
