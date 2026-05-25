#!/usr/bin/env bash
# vfio_bindcycle.sh — runbook Phase 4: cycle the RTL8125 between r8169 and
# vfio-pci N times and verify the kernel log stays clean. Makes the M0a
# "100x bind-cycle" deliverable reproducible (plan §15, runbook Phase 4).
#
# Preconditions:
#   - the VFIO guest VM is SHUT OFF (else libvirt owns the device);
#   - host management is NOT on the RTL8125 (bind_vfio.sh enforces this).
# Usage:  sudo ./vfio_bindcycle.sh [cycles]   (default 100)
set -euo pipefail

CYCLES="${1:-100}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIND="$HERE/bind_vfio.sh"
UNBIND="$HERE/unbind_vfio.sh"
TMP="$(mktemp -d /tmp/vfio_bindcycle.XXXXXX)"

[[ $(id -u) -eq 0 ]] || { echo "must run as root (sudo)"; exit 1; }

echo "vfio_bindcycle: $CYCLES cycles, per-cycle logs in $TMP"
start=$(date '+%s')
for i in $(seq 1 "$CYCLES"); do
  "$BIND"   >"$TMP/cycle.$i.bind"   2>&1 || { echo "BIND FAIL @ cycle $i";   cat "$TMP/cycle.$i.bind";   exit 1; }
  "$UNBIND" >"$TMP/cycle.$i.unbind" 2>&1 || { echo "UNBIND FAIL @ cycle $i"; cat "$TMP/cycle.$i.unbind"; exit 1; }
done
elapsed=$(( $(date '+%s') - start ))

bok=$(grep -l 'OK: bound to vfio-pci'  "$TMP"/cycle.*.bind   | wc -l)
uok=$(grep -l 'OK: returned to r8169'  "$TMP"/cycle.*.unbind | wc -l)
echo "RESULT: $CYCLES cycles in ${elapsed}s — bind OK $bok/$CYCLES, unbind OK $uok/$CYCLES"
[[ "$bok" -eq "$CYCLES" && "$uok" -eq "$CYCLES" ]] || { echo "FAIL: not every cycle reported OK"; exit 1; }
echo "OK: every cycle bound to vfio-pci and returned to r8169"
echo "Now scan the kernel log for new WARN/BUG/oops, e.g.:"
echo "  journalctl -k --since @$start | grep -iE 'WARNING|BUG:|Oops|call trace'"
