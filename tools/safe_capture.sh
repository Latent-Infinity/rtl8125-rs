#!/usr/bin/env bash
# safe_capture.sh - bounded, self-reaping tcpdump wrapper for driver testing.
#
# WHY THIS EXISTS (2026-05-25 incident): an ad-hoc `tcpdump -w file.pcap` was
# run with no rotation and no working timeout. Two failure modes bit us:
#   1. Unbounded capture: a single -w file grows until the filesystem fills.
#   2. Stale capture: if a capture is deleted while tcpdump still has it open,
#      `du` no longer sees it but `df` still counts the space until tcpdump
#      exits. Launching under an unconfined timeout context makes normal
#      reaping reliable on AppArmor systems.
#
# This wrapper makes the safe path the easy path:
#   * Hard size cap via rotation: -C <MB/file> -W <ring count> => max MB*W on disk.
#   * Writes to a DISK-backed scratch dir, never tmpfs /tmp (which is RAM here).
#   * Launches the whole timeout+tcpdump pipeline under `aa-exec -p unconfined`
#     when available, so the duration timeout and cleanup trap signal tcpdump
#     from a peer AppArmor permits.
#   * Preflight free-space check; EXIT/INT trap force-reaps any stray child.
#
# Usage:
#   tools/safe_capture.sh <iface> [tcpdump filter expr ...]
# Env knobs (all optional):
#   CAP_SECS   capture duration in seconds            (default 10)
#   CAP_MB     megabytes per rotated file             (default 100)
#   CAP_FILES  number of files in the ring            (default 5) -> cap = MB*FILES
#   CAP_DIR    output directory (must be disk-backed)  (default /var/tmp/rtl8125_captures)
#   CAP_NAME   safe basename for the capture set        (default capture)
#   CAP_SNAP   per-packet snap length, bytes           (default 0 = full)
#
# Examples:
#   tools/safe_capture.sh enp4s0 host 10.0.0.2
#   CAP_SECS=8 CAP_NAME=tso tools/safe_capture.sh enp4s0 host 10.0.0.2 and tcp port 5201
#   CAP_MB=50 CAP_FILES=3 tools/safe_capture.sh enp3s0       # cap = 150 MB total
set -uo pipefail

IFACE="${1:?usage: safe_capture.sh <iface> [filter expr ...]}"; shift || true
FILTER=("$@")

CAP_SECS="${CAP_SECS:-10}"
CAP_MB="${CAP_MB:-100}"
CAP_FILES="${CAP_FILES:-5}"
CAP_DIR="${CAP_DIR:-/var/tmp/rtl8125_captures}"
CAP_NAME="${CAP_NAME:-capture}"
CAP_SNAP="${CAP_SNAP:-0}"

is_pos_uint() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_uint() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

for v in CAP_SECS CAP_MB CAP_FILES; do
  val="${!v}"
  if ! is_pos_uint "$val"; then
    echo "ERROR: $v must be a positive integer (got '$val')" >&2
    exit 1
  fi
done
if ! is_uint "$CAP_SNAP"; then
  echo "ERROR: CAP_SNAP must be a non-negative integer (got '$CAP_SNAP')" >&2
  exit 1
fi
if [[ ! "$CAP_NAME" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: CAP_NAME must use only letters, numbers, '.', '_', or '-'" >&2
  exit 1
fi

TOTAL_CAP=$(( CAP_MB * CAP_FILES ))

have() { command -v "$1" >/dev/null 2>&1; }
have tcpdump || { echo "ERROR: tcpdump not installed" >&2; exit 1; }

# Run a command from an unconfined AppArmor context when possible, so signals
# to the tcpdump child come from an allowed peer. Falls back to plain sudo if
# aa-exec is unavailable (non-AppArmor systems).
aa_root() {
  if have aa-exec; then sudo aa-exec -p unconfined -- "$@"; else sudo "$@"; fi
}

mkdir -p "$CAP_DIR" || {
  echo "ERROR: failed to create CAP_DIR=$CAP_DIR" >&2
  exit 1
}

# Guard 1: never write captures to a tmpfs (RAM); that risks OOM, not just disk.
FS_LIST="$(findmnt -no FSTYPE --target "$CAP_DIR" 2>/dev/null || true)"
FS="$(printf '%s\n' "$FS_LIST" | head -n1)"
FS="${FS:-unknown}"
if printf '%s\n' "$FS_LIST" | grep -qxE 'tmpfs|ramfs'; then
  echo "ERROR: CAP_DIR=$CAP_DIR is on $FS (RAM-backed). Pick a disk-backed dir," >&2
  echo "       e.g. CAP_DIR=/var/tmp/rtl8125_captures (ext4 here)." >&2
  exit 1
fi

# Guard 2: refuse to start if free space can't even hold the ring + headroom.
AVAIL_MB="$(df -Pm "$CAP_DIR" | awk 'NR==2{print $4}')"
NEED_MB=$(( TOTAL_CAP + 256 ))
if [[ "${AVAIL_MB:-0}" -lt "$NEED_MB" ]]; then
  echo "ERROR: only ${AVAIL_MB}MB free in $CAP_DIR; need >= ${NEED_MB}MB" >&2
  echo "       (ring is ${CAP_MB}MB x ${CAP_FILES} = ${TOTAL_CAP}MB + headroom)." >&2
  exit 1
fi

PREFIX="$CAP_DIR/${CAP_NAME}.pcap"
echo "safe_capture: iface=$IFACE dur=${CAP_SECS}s ring=${CAP_MB}MB x ${CAP_FILES} (cap ${TOTAL_CAP}MB)"
echo "  filter : ${FILTER[*]:-<none>}"
echo "  out    : ${PREFIX} (rotated to ${CAP_NAME}.pcap0 .. )  fs=$FS free=${AVAIL_MB}MB"

# Reap any tcpdump still writing OUR prefix, from an unconfined context, on exit.
cleanup() {
  local line pid cmd
  local -a pids=()

  while IFS= read -r line; do
    pid="${line%% *}"
    cmd="${line#* }"
    if [[ "$cmd" == *" -w $PREFIX"* ]]; then
      pids+=("$pid")
    fi
  done < <(pgrep -af tcpdump 2>/dev/null || true)

  if ((${#pids[@]})); then
    echo "safe_capture: reaping stray tcpdump (${pids[*]})"
    aa_root kill -TERM "${pids[@]}" 2>/dev/null || true
    sleep 1
    aa_root kill -KILL "${pids[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

# Launch the whole timeout+tcpdump pipeline unconfined so timeout can reap it.
# -C <MB> rotates at size; -W <n> caps the ring; -G is deliberately NOT used so
# size, not time, bounds disk. -Z root keeps files owned predictably.
aa_root timeout --signal=TERM --kill-after=3 "$CAP_SECS" \
  tcpdump -i "$IFACE" -nn -s "$CAP_SNAP" \
          -C "$CAP_MB" -W "$CAP_FILES" -Z root -w "$PREFIX" \
          "${FILTER[@]}"
rc=$?
# timeout exits 124 when it had to stop the capture at the time limit: expected.
[[ $rc -eq 124 ]] && echo "safe_capture: stopped at ${CAP_SECS}s limit (expected)" && rc=0

echo "safe_capture: files written:"
ls -lh "${PREFIX}"* 2>/dev/null || echo "  (none - no packets matched?)"
exit $rc
