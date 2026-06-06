#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# M5 NAPI contract enforcement (plan §7 M5).
#
# The kernel NAPI core has invariants every poll function must honour
# to avoid IRQ races, queue-state deadlocks, and exactly-once TX
# completion bugs. This script statically enforces them for our
# `src/napi.rs::poll` body so regressions show up in CI rather than
# during a 24-hour soak.
#
# Invariants enforced (each is a one-line check):
#   1. `budget == 0` (or negative) maps to `budget_u = 0` — the RX
#      loop's `work_done < budget_u` test then keeps it from running.
#   2. `napi_complete_done` is called ONLY inside the `work_done <
#      budget` branch. Calling it from any other path is a UAF risk
#      (kernel may re-enable IRQs while we're still mid-poll).
#   3. The IMR re-arm (`set_imr(INTR_M4_BASELINE)`) is colocated with
#      `napi_complete_done`. Re-arming without complete_done leaves
#      the kernel thinking we still own the IRQ; re-arming AFTER but
#      not LEXICALLY-NEAR is hard to reason about.
#   4. The TX reaper updates `tx_tail` BEFORE calling
#      `bridge_tx_wake_queue`. Wake-before-tail = woken xmit sees
#      stale tail = immediate BUSY.
#   5. xmit updates `tx_head` BEFORE calling `bridge_tx_stop_queue`
#      (for the preemptive stop) and BEFORE `regs().tx_poll()`.
#      Doorbell-before-head = chip fetches a slot the driver hasn't
#      written.
#   6. Wake-side hysteresis: reaper's wake call is guarded by a
#      `free > TX_START_THRS` check, not unconditional.
#   7. Stop-side hysteresis: xmit's preemptive stop is guarded by
#      a `free_after < TX_STOP_THRS` check.
#   8. Doorbell batching: xmit must couple `netdev_xmit_more()` with the
#      doorbell predicate and still force a doorbell when stop/throttle fires.
#   9. Byte-budget accounting must use a per-packet shadow so small packets
#      that cannot hit the byte budget before ring stop do not pay inflight
#      atomics and do not subtract untracked bytes at completion.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAPI="$ROOT/src/napi.rs"
NETDEV="$ROOT/src/netdev.rs"
rc=0

red()  { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn()  { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

# -- 1. budget guard ---------------------------------------------------------
if awk '/pub\(crate\) fn poll/,/^}/' "$NAPI" | \
	grep -qE 'let budget_u = if budget <= 0 \{ 0 \} else \{ budget as usize \};'; then
	grn "poll: budget<=0 collapses to budget_u=0 (TX-cleanup-only path)"
else
	red "poll: missing 'budget <= 0 -> budget_u = 0' guard"
fi

# -- 2. napi_complete_done conditional on work_done < budget -----------------
# Extract the poll body, look for napi_complete_done calls, verify each
# follows an `if work_done < budget` line within the prior 5 lines.
complete_calls=$(awk '/pub\(crate\) fn poll/,/^}/' "$NAPI" | grep -nE 'napi_complete_done')
if [[ -z "$complete_calls" ]]; then
	red "poll: napi_complete_done not called at all"
fi
# Check the guard appears before each call.
poll_body=$(awk '/pub\(crate\) fn poll/,/^}/' "$NAPI")
if echo "$poll_body" | awk '
	/if work_done < budget/ { guarded = 1; next }
	/napi_complete_done\(/ {
		if (!guarded) { print "UNGUARDED"; exit 1 }
	}
' | grep -q UNGUARDED; then
	red "poll: napi_complete_done call not preceded by 'if work_done < budget' guard"
else
	grn "poll: napi_complete_done is guarded by 'work_done < budget'"
fi

# -- 3. IRQ re-arm colocated with napi_complete_done ------------------------
# Accept either a direct `set_imr(INTR_M4_BASELINE)` call or a call to
# a helper named like `rearm_irq*` (the M6 #1 surface-aware helper
# wraps the V2 vs legacy branch in one site). Either way the re-arm
# must land within 3 lines of complete_done.
if echo "$poll_body" | awk '
	/napi_complete_done\(/ { saw = NR }
	/set_imr\(regs::INTR_M4_BASELINE\)|rearm_irq[a-z_]*\(/ {
		if (saw && NR - saw <= 3) found = 1
	}
	END { exit (found ? 0 : 1) }
'; then
	grn "poll: IRQ re-arm is within 3 lines of napi_complete_done"
else
	red "poll: IRQ re-arm not colocated with napi_complete_done"
fi

# -- 4. tx tail store before bridge_tx_wake_queue in reaper -----------------
# Look in the reaper section; require the tx-tail inner store before any
# bridge_tx_wake_queue call. (Task #59 nested the tail under `tx.`; the
# regex matches both pre-refactor `tx_tail.inner.store` and the current
# `tx.tail.inner.store`.)
if echo "$poll_body" | awk '
	/tx[_.]tail\.inner\.store/ { stored = 1 }
	/bridge_tx_wake_queue/ { if (!stored) print "BAD"; exit }
' | grep -q BAD; then
	red "poll: tx_wake_queue called before tx_tail.store"
else
	grn "poll: tx_tail stored before tx_wake_queue"
fi

# -- 5. tx head store before tx_poll() (the chip doorbell) in xmit ----------
# Only the doorbell requires the tx-head value to be stored first — the
# descriptor ring + head together define the chip's view of "what's
# posted". The ring-full safety branch may call tx_stop_queue BEFORE the
# store because no descriptors were posted in that branch (we return
# BUSY). Regex tolerates the task #59 `tx.head` nesting.
xmit_body=$(awk '/fn ndo_start_xmit/,/^}/' "$NETDEV")
tx_reap_body=$(awk '/fn process_tx_completions/,/^}/' "$NAPI")
if echo "$xmit_body" | awk '
	/tx[_.]head\.inner\.store/ { stored = 1 }
	/regs\(\)\.tx_poll/ { if (!stored) print "BAD"; exit }
' | grep -q BAD; then
	red "xmit: tx_poll() (chip doorbell) called before tx_head.store"
else
	grn "xmit: tx_head stored before tx_poll() doorbell"
fi

# -- 6. wake-side hysteresis -------------------------------------------------
# The wake is guarded either directly by `if free > TX_START_THRS`, or via the
# shared `tx_should_wake(state, free)` predicate that folds the same
# `free <= TX_START_THRS` floor together with the byte-budget low-water (the
# test-5 MSI-safe throttle). For the predicate form we also confirm the floor
# actually lives inside `tx_should_wake` so the hysteresis cannot be bypassed.
if echo "$poll_body" | grep -qE 'if free > TX_START_THRS'; then
	grn "poll: tx_wake_queue is guarded by 'free > TX_START_THRS' (hysteresis)"
elif echo "$poll_body" | grep -qE 'tx_should_wake\(state, free\)'; then
	tsw_body=$(awk '/fn tx_should_wake\(/,/^}/' "$NETDEV")
	if echo "$tsw_body" | grep -qE 'free <= .*TX_START_THRS'; then
		grn "poll: tx_wake_queue guarded via tx_should_wake (TX_START_THRS floor + byte budget)"
	else
		red "poll: tx_should_wake is missing the TX_START_THRS hysteresis floor"
	fi
	if echo "$tsw_body" | grep -qE '\(budget / 2\)\.max\(1\)'; then
		grn "poll: tx_should_wake keeps byte-budget low-water nonzero"
	else
		red "poll: tx_should_wake must keep byte-budget low-water nonzero"
	fi
else
	red "poll: tx_wake_queue not guarded by 'free > TX_START_THRS' or tx_should_wake"
fi

# -- 7. stop-side hysteresis -------------------------------------------------
# Accept either the direct `if free_after < TX_STOP_THRS { ... }` form
# or an equivalent local boolean used to feed the stop call.
if echo "$xmit_body" | grep -qE 'free_after < TX_STOP_THRS'; then
	grn "xmit: preemptive tx_stop_queue is guarded by 'free_after < TX_STOP_THRS'"
else
	red "xmit: preemptive stop not guarded by 'free_after < TX_STOP_THRS'"
fi

# -- 8. xmit_more doorbell batching -----------------------------------------
if echo "$xmit_body" | grep -q 'let xmit_more = ub::netdev_xmit_more();' \
   && echo "$xmit_body" | grep -q 'let should_doorbell_for_batch = if bql_enabled' \
   && echo "$xmit_body" | grep -q 'ub::netdev_sent_queue(ndev, wire_len, xmit_more)' \
   && echo "$xmit_body" | grep -q 'if should_doorbell_for_batch || stop_for_ring_or_budget' \
   && echo "$xmit_body" | grep -q 'TX_DOORBELLS.fetch_add'; then
	grn "xmit: xmit_more/BQL doorbell batching is gated and stop/throttle forces tx_poll"
else
	red "xmit: doorbell batching must use xmit_more/BQL and force tx_poll on stop/throttle"
fi

# -- 9. byte-budget tracked-byte shadow ---------------------------------------
if grep -Fq 'tx_budget_tracked_bytes(byte_budget, wire_len)' <<<"$xmit_body" \
   && grep -Fq 'state.tx.shadow_budget_len' <<<"$xmit_body" \
   && grep -Fq 'fetch_add(budgeted_wire_len, Ordering::AcqRel)' <<<"$xmit_body" \
   && grep -Fq 'completed_budget_bytes' <<<"$tx_reap_body" \
   && grep -Fq 'state.tx.shadow_budget_len[slot].swap' <<<"$tx_reap_body" \
   && grep -Fq 'saturating_sub(completed_budget_bytes)' <<<"$tx_reap_body"; then
	grn "tx byte-budget uses tracked-byte shadow and skips untracked small-frame atomics"
else
	red "tx byte-budget must add/subtract the per-packet tracked-byte shadow"
fi

exit $rc
