#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Wake-on-LAN suspend-path contract (W1.3).
#
# The first WoL attempt woke only on the RTC safety net because the PHY powered
# down in S3. The fix keeps the chip PLL (and therefore the internal PHY) alive
# in D3 via PMCH NO_PLL_DOWN and arms the chip WoL + PME. Pin the invariants so
# a refactor cannot silently regress them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
need() { grep -qE -- "$2" "$1" && grn "$3" || red "$3 (missing in ${1#"$ROOT"/}: $2)"; }
reject() { grep -qE -- "$2" "$1" && red "$3 (present in ${1#"$ROOT"/}: $2)" || grn "$3"; }

NETDEV_C="$ROOT/src/netdev_bridge.c"
HDR="$ROOT/src/netdev_bridge.h"
NETDEV="$ROOT/src/netdev.rs"
UB="$ROOT/src/unsafe_boundary.rs"

# 1. The WoL suspend takes a LIGHT quiesce (napi-only, NO full stop/phy_stop) and
#    arms WoL; the non-WoL path keeps the full stop. Resume rebalances + reopens.
sus=$(awk '/void r8125_bridge_pm_suspend\(/,/^}/' "$NETDEV_C")
res=$(awk '/int r8125_bridge_pm_resume\(/,/^}/' "$NETDEV_C")
if grep -qE 'bridge_napi_disable_all\(b\)' <<<"$sus" &&
	grep -qE 'b->ops\.wol_suspend_arm\(b->priv, wol\)' <<<"$sus" &&
	grep -qE 'b->ops\.get_wol\(b->priv\)' <<<"$sus" &&
	grep -qE 'b->wol_suspended = true' <<<"$sus" &&
	grep -qE 'bridge_ndo_stop\(ndev\)' <<<"$sus"; then
	grn "pm_suspend: WoL path light-quiesces (napi + wol_suspend_arm); non-WoL path full-stops"
else
	red "pm_suspend must light-quiesce + wol_suspend_arm on the WoL path and full-stop otherwise"
fi
if grep -qE 'wol_suspended' <<<"$res" &&
	grep -qE 'bridge_napi_enable_all\(b\)' <<<"$res" &&
	grep -qE 'bridge_ndo_open\(ndev\)' <<<"$res"; then
	grn "pm_resume rebalances NAPI + full stop/reopen after a WoL keep-alive suspend"
else
	red "pm_resume must rebalance NAPI and stop+reopen when wol_suspended"
fi

# 2. The WoL arm keeps the chip PLL/PHY alive in D3 (the actual keep-alive
#    mechanism, r8169 rtl_set_d3_pll_down) and does NOT power the PHY down or
#    bounce the link (no phy_stop / no phy_set_max_speed / no aneg restart).
arm=$(awk '/extern "C" fn rust_wol_suspend_arm\(/,/^}/' "$NETDEV")
if grep -qE 'PMCH_D3HOT_NO_PLL_DOWN \| regs::PMCH_D3COLD_NO_PLL_DOWN' <<<"$arm" &&
	grep -qE 'set_pmch\(' <<<"$arm"; then
	grn "wol_suspend_arm keeps the PLL/PHY alive in D3 via PMCH (rtl_set_d3_pll_down false)"
else
	red "wol_suspend_arm must keep the PLL alive in D3 via PMCH (D3HOT|D3COLD NO_PLL_DOWN)"
fi
reject "$NETDEV" 'phy_set_max_speed\(' "WoL path avoids irreversible/worker-bound phy_set_max_speed"

# 3. The arm sets the master PMEnable + PME-status + chip wake bits + RX accept.
if grep -qE 'CONFIG1_PMENABLE' <<<"$arm" &&
	grep -qE 'CONFIG2_PMSTS_EN' <<<"$arm" &&
	grep -qE 'RCR_ACCEPT_BROADCAST' <<<"$arm" &&
	grep -qE 'set_wol\(wolopts\)' <<<"$arm"; then
	grn "wol_suspend_arm sets Config1.PMEnable + Config2.PMSTS_En + RX accept + chip WoL bits"
else
	red "wol_suspend_arm must set Config1.PMEnable, Config2.PMSTS_En, RX accept, and the WoL bits"
fi

# 4. free_irq is preceded by an affinity-hint clear (else free_irq WARNs).
free=$(awk '/fn free_irq_if_registered\(/,/^}/' "$NETDEV")
if grep -qE 'ub::bridge_irq_clear_hint' <<<"$free" &&
	grep -qE 'irq_update_affinity_hint\(irq, NULL\)' "$NETDEV_C"; then
	grn "free_irq_if_registered clears the IRQ affinity hint before free_irq"
else
	red "free_irq must be preceded by bridge_irq_clear_hint (irq_update_affinity_hint NULL)"
fi

# 5. The WoL vtable op exists on both sides + the pure module is host-tested.
need "$HDR" 'void \(\*wol_suspend_arm\)\(void \*priv, u32 wolopts\)' "wol_suspend_arm in the C vtable"
need "$UB" 'pub wol_suspend_arm:' "wol_suspend_arm in the Rust BridgeOps"
need "$NETDEV" 'wol_suspend_arm: rust_wol_suspend_arm' "wol_suspend_arm wired in M4_FULL_OPS"

exit "$rc"
