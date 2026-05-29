#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
# Transferability: [rtl8125]
#
# Tier 3c — `aspm_force_off` module-param contract gate.
#
# Verifies:
#   1. The param is declared in `r8125_rust_main.rs` `module!` block
#      with `u8 default: 0`.
#   2. The probe path in `pci.rs` reads the param and logs an
#      acknowledgement dmesg line when set.
#
# Scope today: the param logs intent. Chip-side ASPM is already
# disabled by default via `force_aspm=0` → `Config5 ASPM_en` clear
# in `hw_start_8125b_unlocked`. The host-side `pci_disable_link_state`
# call lands when the kernel-Rust binding exists.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

# 1. Param declared with the right shape.
if awk '
	/module_pci_driver! \{/ { in_block=1 }
	in_block && /aspm_force_off:/ {
		in_param=1
		found_decl=1
		if ($0 ~ /aspm_force_off:[[:space:]]+u8/) found_type=1
	}
	in_param && /^[[:space:]]*default:[[:space:]]*0,/ { found_default=1 }
	in_param && /^[[:space:]]*},/ { in_param=0 }
	END {
		if (!found_decl) exit 1
		if (!found_type) exit 2
		if (!found_default) exit 3
	}
' "$ROOT/src/r8125_rust_main.rs"; then
	grn "aspm_force_off declared in module! block as u8 default 0"
else
	red "aspm_force_off missing, wrong type, or nonzero default in src/r8125_rust_main.rs module! block"
fi

# 2. Probe reads the param.
if grep -qE '\bmodule_parameters::aspm_force_off\.value\(\)' "$ROOT/src/pci.rs"; then
	grn "pci.rs reads module_parameters::aspm_force_off.value()"
else
	red "pci.rs does not read aspm_force_off"
fi

# 2b. Probe logs an acknowledgement dmesg line when set.
if grep -qE 'aspm_force_off=1 acknowledged' "$ROOT/src/pci.rs"; then
	grn "probe logs aspm_force_off=1 acknowledgement"
else
	red "probe does not log aspm_force_off=1 acknowledgement"
fi

exit "$rc"
