#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Bare-metal regression guard for task #58.
#
# Two details are load-bearing on real hardware:
#   1. `NetdevState` must be initialized in-place on the heap. Building the
#      six 256-entry atomic arrays as a stack temporary before `KBox::new`
#      overflowed the 16 KiB kernel stack during PCI probe.
#   2. Netdev unregister must run from `pci::Driver::unbind`, before the PCI
#      adapter releases devres-managed BAR mappings. Waiting for Drop is too
#      late on the normal remove path.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

pci="$ROOT/src/pci.rs"
netdev="$ROOT/src/netdev.rs"

if grep -Eq '^[[:space:]]*(let[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*)?KBox::new[[:space:]]*\(' "$pci"; then
	red "NetdevState is stack-built before boxing; use KBox::init + try_init"
else
	grn "NetdevState is not stack-built via KBox::new"
fi

if ! grep -q 'KBox::init(' "$pci" || ! grep -q 'kernel::try_init!(NetdevState' "$pci"; then
	red "NetdevState heap in-place initializer contract is missing"
else
	grn "NetdevState uses heap in-place initialization"
fi

# Each large [Atomic*; RING_LEN] array must reach the heap via
# init_array_from_fn (not core::array::from_fn, which stack-builds).
# After the #59 split the call sites moved from pci.rs into the
# substruct `new()` constructors in netdev.rs — accept either file.
# RX slots renamed slot_cpu/slot_dma; TX shadows kept their suffixes.
for field in slot_cpu slot_dma shadow shadow_dma shadow_len shadow_is_frag; do
	if ! grep -hq "${field} <- pin_init::init_array_from_fn" "$pci" "$netdev"; then
		red "$field is not initialized with pin_init::init_array_from_fn"
	fi
done

if grep -hq 'core::array::from_fn' "$pci" "$netdev"; then
	red "still uses core::array::from_fn; verify it cannot create large probe-stack temporaries"
else
	grn "NetdevState array fields avoid core::array::from_fn stack temporaries"
fi

if ! grep -A4 'fn unbind' "$pci" | grep -q '_netdev.shutdown();'; then
	red "R8125Driver::unbind does not shut netdev down before devres release"
else
	grn "R8125Driver::unbind drains netdev before devres release"
fi

if ! grep -q 'ndev: AtomicPtr<bindings::net_device>' "$netdev"; then
	red "NetdevHandle ndev is not atomically drained"
fi

if ! grep -q 'cookie: AtomicPtr<NetdevState>' "$netdev"; then
	red "NetdevHandle cookie is not atomically drained"
fi

if ! grep -q 'pub(crate) fn shutdown(&self)' "$netdev"; then
	red "NetdevHandle::shutdown is missing"
else
	grn "NetdevHandle exposes idempotent shutdown"
fi

exit "$rc"
