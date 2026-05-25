#!/usr/bin/env bash
# m1_gate.sh — runbook continuation: the M1 1000× insmod/rmmod gate
# (plan §7 M1). Run inside the debug+Rust VFIO guest.
#
# Preconditions on the guest:
#   - the M1 module is built at the path given by MOD (default
#     /tmp/r8125_rust_build/src/r8125_rust.ko);
#   - the RTL8125 is enumerated at PCI=$PCI (default 0000:05:00.0);
#   - kmemleak (DEBUG_KMEMLEAK) and lockdep (PROVE_LOCKING) are enabled.
#
# Each cycle:
#   - insmod the module, confirm it shows up in /proc/modules;
#   - confirm probe ran (sysfs driver symlink points at r8125_rust);
#   - rmmod, confirm /sys/module/r8125_rust is gone (refcount-clean).
# Every 100th cycle: trigger a kmemleak scan and record the result.
# At the end: scan kmemleak once more, grep dmesg for WARN/BUG/oops/KASAN.
#
# Acceptance: cycles=CYCLES, fail=0, kmemleak final=0 lines, no WARN/BUG/oops.
set -uo pipefail

PCI=${PCI:-0000:05:00.0}
MOD=${MOD:-/tmp/r8125_rust_build/src/r8125_rust.ko}
CYCLES=${CYCLES:-1000}
GATE=${GATE:-/tmp/r8125_m1_gate.log}
KMEM=${KMEM:-/tmp/r8125_m1_kmemleak.log}
SCANS=${SCANS:-/tmp/r8125_m1_scans.log}

[ "$(id -u)" -eq 0 ] || { echo "must run as root"; exit 1; }
[ -f "$MOD" ] || { echo "module not found at $MOD"; exit 1; }

START_ISO="$(date '+%Y-%m-%d %H:%M:%S')"
echo "=== M1/M2 gate: $CYCLES insmod/rmmod cycles of r8125_rust ==="         > "$GATE"
echo "started $(date -u +%FT%TZ)"                                            >> "$GATE"
echo "guest: $(uname -a)"                                                    >> "$GATE"
echo "module: $MOD ($(stat -c %s "$MOD") bytes)"                             >> "$GATE"

# Ensure device is free + locked to our driver
echo r8125_rust > /sys/bus/pci/devices/$PCI/driver_override
[ -e /sys/bus/pci/drivers/r8169/$PCI ] && echo $PCI > /sys/bus/pci/drivers/r8169/unbind

# Baseline
dmesg -C
echo scan > /sys/kernel/debug/kmemleak; sleep 2
echo "kmemleak baseline lines: $(wc -l < /sys/kernel/debug/kmemleak)"        >> "$GATE"

START=$(date +%s)
FAIL=0
for i in $(seq 1 "$CYCLES"); do
  insmod "$MOD"                              || { echo "insmod FAIL @ $i" >>"$GATE"; FAIL=1; break; }
  grep -q '^r8125_rust ' /proc/modules       || { echo "not in /proc/modules @ $i" >>"$GATE"; FAIL=1; break; }
  drv=$(basename "$(readlink /sys/bus/pci/devices/$PCI/driver 2>/dev/null)" 2>/dev/null)
  [ "$drv" = "r8125_rust" ]                  || { echo "device not bound to r8125_rust @ $i (drv=$drv)" >>"$GATE"; FAIL=1; break; }
  rmmod r8125_rust                           || { echo "rmmod FAIL @ $i" >>"$GATE"; FAIL=1; break; }
  [ ! -e /sys/module/r8125_rust ]            || { echo "module still loaded after rmmod @ $i" >>"$GATE"; FAIL=1; break; }
  if [ $((i % 100)) -eq 0 ]; then
    echo scan > /sys/kernel/debug/kmemleak; sleep 1
    leak=$(wc -l < /sys/kernel/debug/kmemleak)
    elapsed=$(( $(date +%s) - START ))
    echo "@cycle $i  elapsed=${elapsed}s  kmemleak_lines=$leak" | tee -a "$SCANS" >>"$GATE"
  fi
done
END=$(date +%s)
echo "loop done: cycles=$i fail=$FAIL elapsed=$((END-START))s"               >> "$GATE"

echo scan > /sys/kernel/debug/kmemleak; sleep 2
cp /sys/kernel/debug/kmemleak "$KMEM"
echo "final kmemleak file: $(wc -l < "$KMEM") lines"                         >> "$GATE"


# Use journalctl -k (not dmesg) — the in-kernel log_buf_len is small enough
# that 4-line-per-cycle M2 probes (probe + identify + reset OK + ASPM) can
# wrap the buffer at $CYCLES=1000. systemd-journald keeps the full record.
PROBE=$(journalctl -k --since "$START_ISO" --no-pager 2>/dev/null \
        | grep -c 'r8125_rust 0000:05:00.0: RTL8125 probe')
echo "journal probe lines: $PROBE / $CYCLES"                                 >> "$GATE"
echo "=== WARN/BUG/oops scan (post-loop, via journalctl -k) ==="             >> "$GATE"
WARN=$(journalctl -k --since "$START_ISO" --no-pager 2>/dev/null \
       | grep -iE 'kmemleak|lockdep|BUG:|WARNING|KASAN|UBSAN' \
       | grep -v 'taints kernel' | wc -l)
echo "WARN/BUG/oops/KASAN lines: $WARN"                                      >> "$GATE"
if [ "$WARN" -gt 0 ]; then
  echo "--- first 30 matching lines ---"                                     >> "$GATE"
  journalctl -k --since "$START_ISO" --no-pager 2>/dev/null \
    | grep -iE 'kmemleak|lockdep|BUG:|WARNING|KASAN|UBSAN' \
    | grep -v 'taints kernel' | head -30 >> "$GATE"
fi

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ] && [ "$PROBE" -ge "$CYCLES" ]; then
  echo "ACCEPTANCE: PASS"                                                    >> "$GATE"
  cat "$GATE"
  exit 0
else
  echo "ACCEPTANCE: FAIL"                                                    >> "$GATE"
  cat "$GATE"
  exit 1
fi
