#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static gate for the `DriverOwnedSkb` type discipline (task #62).
#
# The wrapper enforces linear ownership of `*mut bindings::sk_buff` between
# the FFI boundary (where the kernel hands us the pointer, or where the
# cshim builds a new skb for us) and the consume site (one of
# `consume_tx`, `deliver_rx`, `free_with_error`, or `into_raw`). The
# gates below catch regressions that would break the invariants:
#
#   1. The struct is `#[must_use]` and `#[repr(transparent)]`, with no
#      `Drop` impl (a `Drop` would mask leaks instead of surfacing them
#      via `#[must_use]` / kmemleak).
#   2. The consume helpers (`ub::skb_consume_tx`, `ub::skb_deliver_rx`,
#      `ub::skb_free_error`) are only called from `src/skb.rs`. Direct
#      use from `netdev.rs` / `napi.rs` would bypass the type wrapper.
#   3. The `from_raw` constructor (contract: non-null) is only
#      called at the FFI entry points: `rust_xmit` and `skel_xmit` (the
#      skeleton fallback). The RX path goes through `build_rx` /
#      `from_raw_nullable` so failures surface as `Option::None`.
#   4. Every public method on the wrapper carries a doc comment so the
#      consumes / borrows contract is visible at the call site.
#
# Skipped if `src/skb.rs` does not define `DriverOwnedSkb`.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
yel() { printf '\033[1;33mSKIP\033[0m %s\n' "$*"; }

SKB="$ROOT/src/skb.rs"
NETDEV="$ROOT/src/netdev.rs"
NAPI="$ROOT/src/napi.rs"

if ! grep -qE 'struct[[:space:]]+DriverOwnedSkb' "$SKB" 2>/dev/null; then
	yel "DriverOwnedSkb not defined in src/skb.rs — skipping"
	exit 0
fi

# 1. Wrapper carries #[must_use], #[repr(transparent)], no Drop.
if grep -qE '^#\[must_use' "$SKB" \
   && grep -qE '^#\[repr\(transparent\)\]' "$SKB"; then
	grn "DriverOwnedSkb has #[must_use] and #[repr(transparent)]"
else
	red "DriverOwnedSkb missing #[must_use] or #[repr(transparent)]"
fi
if grep -qE 'impl[[:space:]]+Drop[[:space:]]+for[[:space:]]+DriverOwnedSkb' "$SKB"; then
	red "DriverOwnedSkb has a Drop impl — leaks would be silent (remove it; the wrapper is must_use)"
else
	grn "DriverOwnedSkb has no Drop impl (leaks surface via #[must_use] / kmemleak)"
fi

# 2. The consume cshim helpers must only appear in skb.rs (and inside
# unsafe_boundary.rs where they're declared / wrapped). Any other call
# site bypasses the type wrapper. The dead-code `skel_xmit` is allowed
# to use `from_raw` + `free_with_error` (which routes through skb.rs).
violation=0
for fn in skb_consume_tx skb_deliver_rx skb_free_error; do
	# Allow calls only in skb.rs (where the wrapper delegates) and in
	# unsafe_boundary.rs (which exposes the raw FFI wrapper).
	hits=$(grep -hE "ub::${fn}\(" "$NETDEV" "$NAPI" 2>/dev/null | wc -l)
	if [[ "$hits" -gt 0 ]]; then
		red "ub::${fn}() called directly in netdev.rs/napi.rs ($hits site(s)) — route through DriverOwnedSkb"
		violation=1
	fi
done
if [[ "$violation" -eq 0 ]]; then
	grn "consume helpers (skb_consume_tx / deliver_rx / free_with_error) only flow through DriverOwnedSkb"
fi

# 3. Direct `from_raw` use is restricted to the FFI entry points
# (`rust_xmit`, `skel_xmit`). All other acquisitions go via
# `build_rx` (RX path) or `from_raw_nullable` (TX reaper, ndo_stop reap).
from_raw_callers=$(grep -hnE 'DriverOwnedSkb::from_raw\(' "$NETDEV" "$NAPI" 2>/dev/null | wc -l)
expected=$(awk '
	/extern "C" fn (rust_xmit|skel_xmit)/{ in_fn=1 }
	in_fn && /DriverOwnedSkb::from_raw\(/ { count++ }
	in_fn && /^}$/{ in_fn=0 }
	END { print count+0 }
' "$NETDEV")
if [[ "$from_raw_callers" -eq "$expected" ]]; then
	grn "DriverOwnedSkb::from_raw call sites all live inside rust_xmit / skel_xmit (count: $expected)"
else
	red "DriverOwnedSkb::from_raw used outside FFI entry points ($from_raw_callers calls vs $expected expected in rust_xmit/skel_xmit)"
fi

# 4. Every public-method definition on the wrapper should carry a doc
# comment. We approximate with `grep` over the impl block: for each
# `pub(crate) fn` look at the preceding line for a doc-comment marker.
missing_docs=$(awk '
	/^impl DriverOwnedSkb \{/ { in_impl=1; next }
	in_impl && /^}$/ { in_impl=0 }
	in_impl {
		if (/^[[:space:]]*pub\(crate\)[[:space:]]+fn[[:space:]]/) {
			if (prev !~ /^[[:space:]]*\/\/\// && prev !~ /^[[:space:]]*#\[/) {
				print "missing doc on:" $0
			}
		}
		prev = $0
	}
' "$SKB")
if [[ -z "$missing_docs" ]]; then
	grn "all DriverOwnedSkb public methods carry doc comments"
else
	red "DriverOwnedSkb methods missing doc comments:"
	printf '%s\n' "$missing_docs" | sed 's/^/      /'
fi

exit "$rc"
