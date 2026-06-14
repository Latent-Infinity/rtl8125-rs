#!/usr/bin/env bash
# Mechanical enforcement of the unsafe-code discipline.
# Safe with no src/*.rs yet: every check passes vacuously.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
note(){ printf '  %s\n' "$*"; }
ok(){ printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
bad(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }

mapfile -t RS < <(find src -name '*.rs' 2>/dev/null)

# 1. crate root carries #![deny(unsafe_code)].
# Kernel-Rust build rule $(obj)/%.o: $(obj)/%.rs forces the crate-root filename
# to match the obj-m target — see src/Kbuild — so on this project the crate
# root is src/r8125_rust.rs, not src/lib.rs. We still tolerate src/lib.rs to
# keep the rule semantically about "whatever file is the crate root."
CRATE_ROOT=""
for cand in src/r8125_rust_main.rs src/r8125_rust.rs src/lib.rs; do
  [[ -f "$cand" ]] && CRATE_ROOT="$cand" && break
done
if [[ -n "$CRATE_ROOT" ]]; then
  grep -qE '^\s*#!\[deny\(unsafe_code\)\]' "$CRATE_ROOT" \
    && ok "$CRATE_ROOT has #![deny(unsafe_code)]" \
    || bad "$CRATE_ROOT missing #![deny(unsafe_code)]"
else
  ok "no crate root in src/ yet — deny-check vacuous"
fi

# 2. no file outside .unsafe-allowlist may #![allow(unsafe_code)]
if [[ -f .unsafe-allowlist ]]; then
  mapfile -t ALLOW < <(grep -vE '^\s*#|^\s*$' .unsafe-allowlist)
  for f in "${RS[@]:-}"; do
    [[ -z "$f" ]] && continue
    if grep -qE '^\s*#!\[allow\(unsafe_code\)\]' "$f"; then
      ok2=0; for a in "${ALLOW[@]}"; do [[ "$f" == "$a" ]] && ok2=1; done
      [[ $ok2 -eq 1 ]] && note "allowed: $f (in .unsafe-allowlist)" \
                       || bad "$f has #![allow(unsafe_code)] but is NOT in .unsafe-allowlist"
    fi
  done
  ok ".unsafe-allowlist enforcement ran (${#RS[@]} rs files)"
else
  bad ".unsafe-allowlist missing"
fi

# 3. no raw MMIO outside mmio.rs / unsafe_boundary.rs
for f in "${RS[@]:-}"; do
  [[ -z "$f" ]] && continue
  case "$f" in src/mmio.rs|src/unsafe_boundary.rs) continue;; esac
  if grep -nE '\b(readl|writel|readb|writeb|readw|writew|ioread|iowrite|read_volatile|write_volatile)\b' "$f" >/dev/null; then
    bad "raw MMIO in $f (allowed only in mmio.rs / unsafe_boundary.rs)"
  fi
done
ok "raw-MMIO containment check ran"

# 4. unsafe-block census: count may only DECREASE over time.
# Counts actual unsafe code constructs — `unsafe { ... }`, `unsafe fn`,
# `unsafe impl`, `unsafe trait`, `unsafe extern` — not the bare word "unsafe"
# in doc comments (which is fine and even encouraged for boundary docs).
CENSUS="ci/.unsafe-census"
cur=0
for f in "${RS[@]:-}"; do
  [[ -z "$f" ]] && continue
  c=$(grep -nE '\bunsafe[[:space:]]+(fn|impl|trait|extern)\b|\bunsafe[[:space:]]*\{' "$f" 2>/dev/null \
      | grep -vE '^[0-9]+:[[:space:]]*(///?|//!|\*)' \
      | wc -l)
  cur=$((cur+${c:-0}))
done
if [[ -f "$CENSUS" ]]; then
  prev=$(cat "$CENSUS");
  if [[ "$cur" -gt "$prev" ]]; then
    bad "unsafe census increased $prev → $cur — needs a justification commit"
  else
    ok "unsafe census $prev → $cur (non-increasing)"; echo "$cur" > "$CENSUS"
  fi
else
  echo "$cur" > "$CENSUS"; ok "unsafe census baseline established: $cur"
fi

exit $fail
