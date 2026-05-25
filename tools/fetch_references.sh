#!/usr/bin/env bash
# fetch_references.sh — reproducibly populate ./references/ with PINNED upstream
# checkouts for READ-ONLY reference (plan §9.3: read, don't copy).
#
# references/ is gitignored. Nothing here is ever copied into src/ or cshim/;
# concepts are paraphrased and re-implemented from datasheet/behavior primaries.
#
# Strategy: blob:none partial clone + cone sparse-checkout of only the subtrees
# we need, shallow where possible. Each ref is pinned to an exact commit; the
# script warns loudly if a fetched ref has drifted from its pin (expected only
# for the moving Rust-for-Linux branch).
#
# Usage:
#   tools/fetch_references.sh            # fetch all (idempotent; skips populated)
#   tools/fetch_references.sh --force    # re-fetch everything
#   tools/fetch_references.sh <name>...  # fetch only the named reference(s)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REF_DIR="$REPO_ROOT/references"
MANIFEST="$REF_DIR/MANIFEST.txt"
mkdir -p "$REF_DIR"

FORCE=0
SELECT=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*) echo "unknown flag: $a" >&2; exit 2 ;;
    *) SELECT+=("$a") ;;
  esac
done

# name|url|pinned_sha|fetch_ref|sparse_paths(space-sep, empty=full)|note
# fetch_ref is a tag or branch resolvable with a shallow fetch; pinned_sha is
# the commit we EXPECT it to resolve to (verified, warned on drift).
#
# DEPTH POLICY: the two r8125 references are cloned with FULL history on
# purpose. Plan §3.3 (v3.4) makes Realtek-official's history (~99 commits) +
# its `src/r8125_n.c` comments the effective ASPM/L1.x workaround database;
# the ewaldc rewrite (only 3 commits) is kept for its code/approach to the
# fragment-count / data-corruption fixes (plan §4). For both, history IS part
# of the deliverable, so `--depth 1` would discard it. They are small
# (~1.5 MB each). All other refs are shallow.
#
# LAUNCHPAD CAVEAT: git.launchpad.net does NOT honour `--filter=blob:none`
# ("filtering not recognized by server, ignoring") and its annotated tags can
# resolve to a different object than `git ls-remote --refs` reports, so the
# ubuntu-kernel pin will show DRIFT. The tree is still the exact-match source
# and is usable. For a guaranteed-exact tree prefer the apt path documented in
# references/PROVENANCE.md: `apt-get source linux=7.0.0-15.15` (deb-src enabled).
REFS=(
"linux-mainline|https://github.com/torvalds/linux.git|028ef9c96e96197026887c0f092424679298aae8|v7.0|drivers/net/ethernet/realtek drivers/net/phy rust samples/rust Documentation/networking Documentation/process Documentation/rust include/uapi/linux|Mainline v7.0: upstream r8169 (§12 baseline), Rust abstractions to validate §5.1, kernel AI/DCO policy (§9.2)"
"rust-for-linux|https://github.com/Rust-for-Linux/linux.git|5d6919055dec134de3c40167a490f33c74c12581|rust-next|rust/kernel rust/kernel/net samples/rust drivers/net Documentation/rust|Rust-for-Linux rust-next: most-advanced netdev/sk_buff/NAPI/phylib abstractions for the §5.2 status check (MOVING branch — drift expected)"
"realtek-r8125-official|https://github.com/awesometic/realtek-r8125-dkms.git|60c86586fbe22cea7ed660a629e2d1374cc26196|9.016.01-1||Realtek official OOT r8125 v9.016.01 (clean DKMS mirror): feature/perf reference (§12), register behavior reference (§13), and the ASPM/L1.x workaround DATABASE — ~99 commits + r8125_n.c comments (plan §3.3 v3.4); full history kept on purpose"
"ewaldc-r8125-rewrite|https://github.com/ewaldc/realtek-r8125-dkms.git|527bcbe5ed45c67b20abae73dccc683eb6f0dc2b|master||The ewaldc r8125 rewrite (plan §4, §3.3): kept for its CODE/APPROACH to the wrong-fragment-count / data-corruption fixes that motivate this project (README citation, §4). Only 3 commits — NOT the ASPM database (validation finding 4)"
"ubuntu-kernel-7.0.0-15|https://git.launchpad.net/~ubuntu-kernel/ubuntu/+source/linux/+git/resolute|6ed57a7b3d0cdb198711521ba0c88a3ecbf7325e|Ubuntu-7.0.0-15.15|drivers/net/ethernet/realtek rust samples/rust Documentation/networking Documentation/process debian.master|EXACT source of the running kernel — authoritative for §5.1 API validation and the §15 OOT-Rust-metadata check"
)

log()  { printf '\033[1;34m[fetch]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN ]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

fetch_one() {
  local name="$1" url="$2" pin="$3" ref="$4" sparse="$5" note="$6"
  local dest="$REF_DIR/$name"

  if [[ -d "$dest/.git" && $FORCE -eq 0 ]]; then
    # Already present: still record it so the regenerated MANIFEST is COMPLETE
    # even on a partial/idempotent run (no network needed for this path).
    local cur; cur="$(git -C "$dest" rev-parse HEAD 2>/dev/null || echo unknown)"
    log "$name: already present (use --force to refresh) — skipping (recorded $cur)"
    if [[ "$cur" != "$pin" && "$cur" != "unknown" ]]; then
      warn "$name: present tree at $cur differs from pin $pin (expected for rust-next; investigate for tags)"
    fi
    printf '%s\t%s\t%s\t%s\tpinned=%s\n' "$name" "$url" "$ref" "$cur" "$pin" >> "$MANIFEST.tmp"
    return 0
  fi
  rm -rf "$dest"; mkdir -p "$dest"
  log "$name: $url @ $ref"

  git -C "$dest" init -q
  git -C "$dest" remote add origin "$url"
  git -C "$dest" config extensions.partialClone origin
  if [[ -n "$sparse" ]]; then
    git -C "$dest" sparse-checkout init --cone
    # shellcheck disable=SC2086
    git -C "$dest" sparse-checkout set $sparse
  fi
  # r8125 references: full history (changelog is the §3.3 deliverable).
  local depth=(--depth 1)
  case "$name" in realtek-r8125-official|ewaldc-r8125-rewrite) depth=() ;; esac
  if ! git -C "$dest" fetch -q --filter=blob:none "${depth[@]}" origin "$ref"; then
    err "$name: fetch of '$ref' failed (network? ref renamed?) — see references/PROVENANCE.md"
    return 1
  fi
  git -C "$dest" checkout -q FETCH_HEAD

  local got; got="$(git -C "$dest" rev-parse HEAD)"
  if [[ "$got" != "$pin" ]]; then
    warn "$name: DRIFT — pinned $pin but fetched $got"
    warn "       (expected only for rust-for-linux/rust-next; for tags this means the upstream tag moved — investigate before trusting)"
  else
    log "$name: pin verified ($got)"
  fi
  printf '%s\t%s\t%s\t%s\tpinned=%s\n' "$name" "$url" "$ref" "$got" "$pin" >> "$MANIFEST.tmp"
}

: > "$MANIFEST.tmp"
rc=0
for line in "${REFS[@]}"; do
  IFS='|' read -r name url pin ref sparse note <<< "$line"
  if [[ ${#SELECT[@]} -gt 0 ]]; then
    skip=1; for s in "${SELECT[@]}"; do [[ "$s" == "$name" ]] && skip=0; done
    [[ $skip -eq 1 ]] && continue
  fi
  fetch_one "$name" "$url" "$pin" "$ref" "$sparse" "$note" || rc=1
done

# --- Kernel Rust metadata package (NOT a git ref): download the .deb for
#     offline reference. Its ABSENCE is the §13/§16 risk (Medium in plan v3.4 —
#     apt-installable; validation finding 1); installing the distro kernel-rust
#     SET is the mitigation. We download, we do NOT auto-install (system change).
if [[ ${#SELECT[@]} -eq 0 || " ${SELECT[*]} " == *" rust-metadata-pkg "* ]]; then
  PKG_DIR="$REF_DIR/rust-metadata-pkg"
  # nullglob-safe presence test: a literal "*.deb" must not count as present.
  if ! ls "$PKG_DIR"/*.deb >/dev/null 2>&1 || [[ $FORCE -eq 1 ]]; then
    mkdir -p "$PKG_DIR"
    log "rust-metadata-pkg: downloading linux-lib-rust-7.0.0-15-generic .deb (reference only; not installed)"
    if (cd "$PKG_DIR" && apt-get download linux-lib-rust-7.0.0-15-generic >/dev/null 2>&1); then
      log "rust-metadata-pkg: $(ls "$PKG_DIR"/*.deb 2>/dev/null | xargs -r basename)"
      printf 'rust-metadata-pkg\tapt\tlinux-lib-rust-7.0.0-15-generic\t7.0.0-15.15\tNOT installed\n' >> "$MANIFEST.tmp"
    else
      warn "rust-metadata-pkg: apt-get download failed (offline?) — see docs/VALIDATION_REPORT.md for the apt install mitigation"
    fi
  else
    log "rust-metadata-pkg: already present — skipping (recorded)"
    printf 'rust-metadata-pkg\tapt\tlinux-lib-rust-7.0.0-15-generic\t7.0.0-15.15\tNOT installed\n' >> "$MANIFEST.tmp"
  fi
fi

{
  echo "# references/ manifest — generated by tools/fetch_references.sh on $(date -u +%FT%TZ)"
  echo "# name <TAB> origin <TAB> ref <TAB> resolved_sha <TAB> pin"
  sort "$MANIFEST.tmp" 2>/dev/null || true
} > "$MANIFEST"
rm -f "$MANIFEST.tmp"

echo
log "Done. Manifest: $MANIFEST"
log "Reminder (plan §9.3): references/ is READ-ONLY. Paraphrase and re-implement; never copy GPL source."
exit $rc
