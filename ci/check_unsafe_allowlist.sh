#!/usr/bin/env bash
# Mechanical enforcement of the unsafe-code discipline (plan §6.2, §9.4).
# M0-safe: with no src/*.rs yet, every check passes vacuously.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
note(){ printf '  %s\n' "$*"; }
ok(){ printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
bad(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }

mapfile -t RS < <(find src -name '*.rs' 2>/dev/null)

# 1. crate root carries #![deny(unsafe_code)]  (only enforced once lib.rs exists)
if [[ -f src/lib.rs ]]; then
  grep -qE '^\s*#!\[deny\(unsafe_code\)\]' src/lib.rs \
    && ok "src/lib.rs has #![deny(unsafe_code)]" \
    || bad "src/lib.rs missing #![deny(unsafe_code)] (plan §6.2)"
else
  ok "no src/lib.rs yet (M0) — deny-check vacuous"
fi

# 2. no file outside .unsafe-allowlist may #![allow(unsafe_code)]
if [[ -f .unsafe-allowlist ]]; then
  mapfile -t ALLOW < <(grep -vE '^\s*#|^\s*$' .unsafe-allowlist)
  for f in "${RS[@]:-}"; do
    [[ -z "$f" ]] && continue
    if grep -qE '^\s*#!\[allow\(unsafe_code\)\]' "$f"; then
      ok2=0; for a in "${ALLOW[@]}"; do [[ "$f" == "$a" ]] && ok2=1; done
      [[ $ok2 -eq 1 ]] && note "allowed: $f (in .unsafe-allowlist)" \
                       || bad "$f has #![allow(unsafe_code)] but is NOT in .unsafe-allowlist (plan §6.2)"
    fi
  done
  ok ".unsafe-allowlist enforcement ran (${#RS[@]} rs files)"
else
  bad ".unsafe-allowlist missing"
fi

# 3. no raw MMIO outside mmio.rs / unsafe_boundary.rs (plan §7 M2 gate, §9.4)
for f in "${RS[@]:-}"; do
  [[ -z "$f" ]] && continue
  case "$f" in src/mmio.rs|src/unsafe_boundary.rs) continue;; esac
  if grep -nE '\b(readl|writel|readb|writeb|readw|writew|ioread|iowrite|read_volatile|write_volatile)\b' "$f" >/dev/null; then
    bad "raw MMIO in $f (allowed only in mmio.rs / unsafe_boundary.rs — plan §7 M2)"
  fi
done
ok "raw-MMIO containment check ran"

# 4. unsafe-block census: count may only DECREASE over time (plan §9.4)
CENSUS="ci/.unsafe-census"
cur=0
for f in "${RS[@]:-}"; do [[ -z "$f" ]] && continue; c=$(grep -cE '\bunsafe\b' "$f" 2>/dev/null || echo 0); cur=$((cur+c)); done
if [[ -f "$CENSUS" ]]; then
  prev=$(cat "$CENSUS");
  if [[ "$cur" -gt "$prev" ]]; then
    bad "unsafe census increased $prev → $cur — needs a justification commit (plan §9.4)"
  else
    ok "unsafe census $prev → $cur (non-increasing)"; echo "$cur" > "$CENSUS"
  fi
else
  echo "$cur" > "$CENSUS"; ok "unsafe census baseline established: $cur"
fi

exit $fail
