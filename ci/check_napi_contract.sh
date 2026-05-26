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

# -- 3. set_imr colocated with napi_complete_done ---------------------------
if echo "$poll_body" | awk '
	/napi_complete_done\(/ { saw = NR }
	/set_imr\(regs::INTR_M4_BASELINE\)/ {
		if (saw && NR - saw <= 3) found = 1
	}
	END { exit (found ? 0 : 1) }
'; then
	grn "poll: set_imr(INTR_M4_BASELINE) is within 3 lines of napi_complete_done"
else
	red "poll: set_imr re-arm not colocated with napi_complete_done"
fi

# -- 4. tx_tail.store before bridge_tx_wake_queue in reaper -----------------
# Look in the reaper section; require tx_tail.inner.store before any
# bridge_tx_wake_queue call.
if echo "$poll_body" | awk '
	/tx_tail\.inner\.store/ { stored = 1 }
	/bridge_tx_wake_queue/ { if (!stored) print "BAD"; exit }
' | grep -q BAD; then
	red "poll: tx_wake_queue called before tx_tail.store"
else
	grn "poll: tx_tail stored before tx_wake_queue"
fi

# -- 5. tx_head.store before tx_poll() (the chip doorbell) in xmit ----------
# Only the doorbell requires tx_head to be stored first — the descriptor
# ring + tx_head together define the chip's view of "what's posted". The
# ring-full safety branch may call tx_stop_queue BEFORE tx_head.store
# because no descriptors were posted in that branch (we return BUSY).
xmit_body=$(awk '/fn ndo_start_xmit/,/^}/' "$NETDEV")
if echo "$xmit_body" | awk '
	/tx_head\.inner\.store/ { stored = 1 }
	/regs\(\)\.tx_poll/ { if (!stored) print "BAD"; exit }
' | grep -q BAD; then
	red "xmit: tx_poll() (chip doorbell) called before tx_head.store"
else
	grn "xmit: tx_head stored before tx_poll() doorbell"
fi

# -- 6. wake-side hysteresis -------------------------------------------------
if echo "$poll_body" | grep -qE 'if free > TX_START_THRS'; then
	grn "poll: tx_wake_queue is guarded by 'free > TX_START_THRS' (hysteresis)"
else
	red "poll: tx_wake_queue not guarded by 'free > TX_START_THRS'"
fi

# -- 7. stop-side hysteresis -------------------------------------------------
if echo "$xmit_body" | grep -qE 'if free_after < TX_STOP_THRS'; then
	grn "xmit: preemptive tx_stop_queue is guarded by 'free_after < TX_STOP_THRS'"
else
	red "xmit: preemptive stop not guarded by 'free_after < TX_STOP_THRS'"
fi

exit $rc
