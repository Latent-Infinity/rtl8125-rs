#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static shape gate for the upstream-style net selftest.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELFTEST="$ROOT/tools/testing/selftests/net/r8125_rust_smoke.sh"
SELFTEST_MAKEFILE="$ROOT/tools/testing/selftests/net/Makefile"

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

if [[ ! -x "$SELFTEST" ]]; then
	red "missing executable selftest: $SELFTEST"
	exit 1
fi
if [[ ! -r "$SELFTEST_MAKEFILE" ]]; then
	red "missing selftest Makefile: $SELFTEST_MAKEFILE"
	exit 1
fi
if ! sh -n "$SELFTEST"; then
	red "selftest shell syntax failed"
	exit 1
fi

fail=0
grep -q 'SPDX-License-Identifier: GPL-2.0' "$SELFTEST" \
	|| { red "selftest missing SPDX"; fail=1; }
grep -q 'TAP version 13' "$SELFTEST" \
	|| { red "selftest must emit TAP"; fail=1; }
grep -q '1..0 # SKIP' "$SELFTEST" \
	|| { red "selftest must support kselftest skip-all"; fail=1; }
grep -qE '\b(insmod|modprobe)\b' "$SELFTEST" \
	|| { red "selftest must load the module"; fail=1; }
grep -q 'ip link show' "$SELFTEST" \
	|| { red "selftest must verify the netdev appears"; fail=1; }
grep -qE '\brmmod\b' "$SELFTEST" \
	|| { red "selftest must unload modules it loaded"; fail=1; }
grep -qE 'TEST_PROGS.*r8125_rust_smoke\.sh' "$SELFTEST_MAKEFILE" \
	|| { red "selftest Makefile must list r8125_rust_smoke.sh in TEST_PROGS"; fail=1; }

# Companion capability-matrix selftest: same TAP/skip-aware shape, registered in
# TEST_PROGS. It must be skip-aware (no hard failure when a tool/capability is
# absent) so it runs on any host.
FEATURES="$ROOT/tools/testing/selftests/net/r8125_rust_features.sh"
if [[ ! -x "$FEATURES" ]]; then
	red "missing executable selftest: $FEATURES"
	fail=1
elif ! sh -n "$FEATURES"; then
	red "features selftest shell syntax failed"
	fail=1
else
	grep -q 'SPDX-License-Identifier: GPL-2.0' "$FEATURES" \
		|| { red "features selftest missing SPDX"; fail=1; }
	grep -q 'TAP version 13' "$FEATURES" \
		|| { red "features selftest must emit TAP"; fail=1; }
	grep -q '1..0 # SKIP' "$FEATURES" \
		|| { red "features selftest must support kselftest skip-all"; fail=1; }
	grep -q '# SKIP' "$FEATURES" \
		|| { red "features selftest must be skip-aware per-test"; fail=1; }
fi
grep -qE 'TEST_PROGS.*r8125_rust_features\.sh' "$SELFTEST_MAKEFILE" \
	|| { red "selftest Makefile must list r8125_rust_features.sh in TEST_PROGS"; fail=1; }

if (( fail )); then
	exit 1
fi

grn "r8125_rust net selftest shape is present (smoke + features)"
exit 0
