#!/usr/bin/env bash
# Static checks for the RTL8125B r8169-parity init sequence.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
ok(){ printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
bad(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }

HW=src/hw.rs
MMIO=src/mmio.rs
REGS=src/regs.rs

grep -q 'regs.unlock_config_regs();' "$HW" \
  && grep -q 'let result = hw_start_8125b_unlocked(regs);' "$HW" \
  && grep -q 'regs.lock_config_regs();' "$HW" \
  && ok "hw_start_8125b balances config unlock/lock around fallible init" \
  || bad "hw_start_8125b must relock config registers even if init returns an error"

grep -q 'regs.set_config3(cfg3 & !regs::CONFIG3_RDY_TO_L23)' "$HW" \
  && grep -q 'regs.set_config5(cfg5 & !regs::CONFIG5_ASPM_EN)' "$HW" \
  && grep -q 'regs::MAC_OCP_L1_EXIT_TRIGGERS' "$HW" \
  && ok "PCIe power-state r8169 parity writes are present" \
  || bad "Config3/Config5/L1-exit trigger writes must stay in the 8125B init path"

grep -q 'pub(crate) const RSS_CTRL_8125: usize = 0x4500;' "$REGS" \
  && grep -q 'pub(crate) const Q_NUM_CTRL_8125: usize = 0x4800;' "$REGS" \
  && grep -q 'pub(crate) fn set_rss_ctrl_8125' "$MMIO" \
  && grep -q 'pub(crate) fn set_q_num_ctrl_8125' "$MMIO" \
  && ok "single-queue RSS/QNum register helpers are defined" \
  || bad "8125B single-queue RSS/QNum helpers must remain wired"

exit $fail
