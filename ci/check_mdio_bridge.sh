#!/usr/bin/env bash
# Static checks for the C/Rust MDIO bridge lifecycle. These are not a
# substitute for the guest traffic gate; they catch review regressions in
# the failure paths that are hard to exercise deterministically.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
ok(){ printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
bad(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }

C=src/netdev_bridge_phy.c
NETDEV_C=src/netdev_bridge.c
H=src/netdev_bridge.h
R=src/unsafe_boundary.rs

grep -q 'phyaddr != 0' "$C" && ok "MDIO bridge rejects nonzero PHY addresses" \
  || bad "MDIO bridge must reject any PHY address other than 0"

grep -q 'phyreg < 0 || phyreg > 31' "$C" && ok "C MDIO callbacks validate register range" \
  || bad "C MDIO callbacks must validate phyreg is 0..31"

grep -q 'ret = phy_init_hw' "$C" \
  && grep -q 'ret = genphy_soft_reset' "$C" \
  && grep -q 'ret = phy_resume' "$C" \
  && grep -q 'goto disconnect' "$C" \
  && ok "PHY init/reset/resume errors unwind through disconnect" \
  || bad "PHY init/reset/resume return values must be checked and disconnected on failure"

grep -q 'mdiobus_unregister(b->mii_bus)' "$NETDEV_C" \
  && grep -q 'mdiobus_free(b->mii_bus)' "$NETDEV_C" \
  && ok "MDIO bus uses explicit unregister/free teardown" \
  || bad "MDIO bus must be explicitly unregistered/freed before module text unload"

if grep -q 'devm_' "$H"; then
  bad "MDIO bridge header must not claim devm-managed teardown"
else
  ok "MDIO bridge header documents explicit teardown"
fi

grep -q 'fn valid_mii_reg' "$R" \
  && grep -q 'errno_to_c_int(kernel::error::code::EINVAL)' "$R" \
  && ok "Rust MDIO entry points share validation/error helpers" \
  || bad "Rust MDIO entry points should use shared validation/error helpers"

exit $fail
