# C-vs-Rust regression fixes — findings & status (2026-06-04)

## Regressions found (vs r8169, bare-metal gateway)
1. Loaded-latency: rust p99.9 ~1670us vs r8169 ~783us (MTU1500), ~2040 vs 563 (MTU9000).
2. Small-frame RX: rust 43-75% loss at 64-256B vs r8169 ~0%.

## Root cause (PROVEN)
Both stem from **no RX interrupt moderation** → IRQ storm → CPU saturation.
Live INT_MITI_V2 sweep (devmem 0xfce00a00, 64B UDP RX flood), IRQ/s:
  timer 0x00=166542, 0x10=22017, 0x20=9635, 0x40=4089.
So moderation cuts the IRQ rate 7.5-40x. r8169 ships moderation; rust zeroed it.

## NOT the cause
- BQL: under TX load dql limit=0, inflight=0 (TX completions are prompt), so
  there's no bufferbloat for BQL to fix. BQL is correct/no-regression but a
  no-op for these symptoms. (Implemented; stashed with the rest.)

## Fix (implemented, stashed: `git stash list`)
- Coalescing: set_coalesce_8125b(INT_MITI_V2_0_RX=0x10) after V2 enable.
- BQL prototype: netdev_sent_queue / completed_queue / reset_queue at open.
  This was later superseded by the seeded, no-reset retry in
  `docs/BQL_RETRY_PLAN.md`.
- INT_CFG0 RMW + readback verify (candidate #2): set_int_cfg0_v2_enable().

## BLOCKER (open)
Integrating the above in-driver triggers a V2/MSI **0-interrupt** state
(ISR_v2=0, vector flat) — the same class as the KVM MSI flakiness. With the
fixes loaded the register IS correct (INT_MITI=0x10, INT_CFG0=0x01) but no
IRQs fire. The zero-copy baseline (no fixes) delivers IRQs fine. Needs the
V2-surface activation/sequencing work (user candidates #2/#3) before the
proven coalescing fix can ship in-driver.

## Harness bug fixed
swap_driver.sh rust-branch insmod'd without rmmod first → stale module stayed
loaded ("File exists" silently). All earlier gateway "fix" tests unknowingly
ran the OLD binary. Fixed: always rmmod before insmod (+ readback loaded srcv).
