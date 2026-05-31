#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# rmmod_stress_100.sh — Tier 1c of docs/POST_SOAK_PLAN.md.
#
# Run ci/check_rmmod_while_up.sh for 100 cycles with a 5-second
# traffic burst per cycle and write a markdown summary. Use after
# the active soak completes on KVM (or anywhere — script is iface
# parameterized).
#
# The underlying gate already accepts CYCLES + TRAFFIC_SECS env
# vars. This wrapper just sets them, runs unattended, and emits a
# digestible report.
#
# Usage:
#   scripts/rmmod_stress_100.sh                    # default 100 cycles
#   CYCLES=50 scripts/rmmod_stress_100.sh          # shorter
#   IFACE=enp7s0 PEER=192.168.50.1 scripts/rmmod_stress_100.sh

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CYCLES=${CYCLES:-100}
TRAFFIC_SECS=${TRAFFIC_SECS:-5}
RMMOD_DELAY=${RMMOD_DELAY:-2}
IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
BUILD_DIR=${BUILD_DIR:-/tmp/r8125_rust_build}

REPORT=${REPORT:-/tmp/r8125_rmmod_stress_$(date +%Y%m%d_%H%M%S).md}
RAW_LOG=${REPORT%.md}.log

cat > "$REPORT" <<EOF
# rmmod-under-traffic stress — ${CYCLES}× cycles

- Started: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
- Host: $(hostname)
- Kernel: $(uname -r)
- Iface: $IFACE  (local $LOCAL_IP/$LOCAL_PREFIX → peer $PEER)
- Traffic window: ${TRAFFIC_SECS}s iperf3 before each rmmod
- Rmmod delay: ${RMMOD_DELAY}s after traffic start

## Raw log

\`\`\`
EOF

# Run the gate. It already keeps per-cycle counters internally and
# exits non-zero if ANY cycle fails. Tee the output for the report.
CYCLES="$CYCLES" \
TRAFFIC_SECS="$TRAFFIC_SECS" \
RMMOD_DELAY="$RMMOD_DELAY" \
IFACE="$IFACE" \
PEER="$PEER" \
LOCAL_IP="$LOCAL_IP" \
LOCAL_PREFIX="$LOCAL_PREFIX" \
BUILD_DIR="$BUILD_DIR" \
	bash "$ROOT/ci/check_rmmod_while_up.sh" 2>&1 | tee "$RAW_LOG"
gate_exit=${PIPESTATUS[0]}

cat >> "$REPORT" <<EOF
\`\`\`

## Summary

- Gate exit code: $gate_exit
- Completed: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
EOF

# Count pass/fail lines (patterns match the gate's actual output).
passes=$(grep -cE 'cycle [0-9]+: rmmod-while-up clean' "$RAW_LOG" || true)
fails=$(grep -cE 'cycle [0-9]+: (rmmod failed|dmesg flagged)' "$RAW_LOG" || true)
busy=$(grep -cE 'cycle [0-9]+: rmmod failed.*busy' "$RAW_LOG" || true)

cat >> "$REPORT" <<EOF
- Cycles passed: $passes
- Cycles failed: $fails
- Cycles with EBUSY: $busy

EOF

if (( fails > 0 )); then
	echo "- **Verdict: FAIL ($fails / $CYCLES cycles regressed)**" >> "$REPORT"
elif (( busy > 0 )); then
	echo "- **Verdict: PASS with EBUSY ($busy noted — these are not fatal)**" >> "$REPORT"
else
	echo "- **Verdict: PASS (clean)**" >> "$REPORT"
fi

cat >> "$REPORT" <<EOF

## Post-stress capture

\`\`\`
EOF
sudo dmesg --since "$CYCLES seconds ago" 2>/dev/null \
	| grep -E 'r8125_rust|BUG|WARN' | tail -30 >> "$REPORT" || true
echo '```' >> "$REPORT"

echo
echo "Report: $REPORT"
echo "Raw log: $RAW_LOG"
exit "$gate_exit"
