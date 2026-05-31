#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# gateway_active_soak.sh — Tier 1b of docs/POST_SOAK_PLAN.md.
#
# Run a 24 h sustained-traffic soak on Gateway bare metal with
# ASPM still on, pre/post state captured via dump_state.sh, and a
# markdown summary written for the M5_CLOSEOUT addendum.
#
# Expected workflow: the previous 24 h ASPM-on idle soak completes
# (~03:05 UTC), then this script kicks the bare-metal + active-
# traffic + ASPM-on combination — the corner we haven't yet lit.
#
# Designed for unattended execution via systemd-run or nohup.
#
# Usage on Gateway:
#   sudo nohup scripts/gateway_active_soak.sh > /tmp/gateway_active.log 2>&1 &
#
# Or via the agent harness:
#   ssh gateway 'cd ~/rtl8125-rs && \
#     sudo nohup scripts/gateway_active_soak.sh > /tmp/gateway_active.log 2>&1 &'

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IFACE=${IFACE:-enp3s0}                 # Gateway-default (not enp5s0)
PEER=${PEER:-10.0.0.1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
BDF=${BDF:-0000:03:00.0}               # Gateway-default
SOAK_HOURS=${SOAK_HOURS:-24}
BANDWIDTH=${BANDWIDTH:-100M}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}

STAMP=$(date -u +'%Y%m%d_%H%M%S')
RUN_DIR=/tmp/r8125_gateway_active_${STAMP}
mkdir -p "$RUN_DIR"

REPORT="$RUN_DIR/SOAK_REPORT.md"
SOAK_LOG="$RUN_DIR/soak.log"
PRE_DUMP="$RUN_DIR/pre_state.tar.gz"
POST_DUMP="$RUN_DIR/post_state.tar.gz"

cat > "$REPORT" <<EOF
# Gateway 24 h active-traffic soak (Tier 1b)

- Started: $(date -u +'%Y-%m-%dT%H:%M:%SZ')
- Host: $(hostname)
- Kernel: $(uname -r)
- Driver: r8125_rust (commit $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null))
- Iface: $IFACE  (local $LOCAL_IP/$LOCAL_PREFIX → peer $PEER)
- Bandwidth: $BANDWIDTH (rate-limited iperf3 TCP)
- Duration: ${SOAK_HOURS} h
- ASPM state: assumed already on (carried from preceding idle soak); verified below

## Pre-soak state

EOF

# Verify ASPM is actually on. If not, this isn't the right run.
LNK_CTL=$(sudo setpci -s "$BDF" CAP_EXP+10.W 2>/dev/null || echo "?")
LNK_STA=$(sudo setpci -s "$BDF" CAP_EXP+12.W 2>/dev/null || echo "?")
ASPM_BITS=$(printf '%d' "0x$(echo "$LNK_CTL" | tr -d '\n' | head -c 4)" 2>/dev/null)
ASPM_BITS=$((ASPM_BITS & 0x3))

cat >> "$REPORT" <<EOF
- LnkCtl raw: \`$LNK_CTL\`
- LnkSta raw: \`$LNK_STA\`
- ASPM bits (LnkCtl[1:0]): $ASPM_BITS  (0=disabled, 1=L0s, 2=L1, 3=L0s+L1)

EOF

if (( ASPM_BITS == 0 )); then
	echo "**WARN: ASPM appears disabled — this run is not the ASPM-on hazard test it claims to be.** Continuing anyway." >> "$REPORT"
	echo
fi

# Capture pre-soak state.
sudo "$ROOT/scripts/dump_state.sh" "$PRE_DUMP" >/dev/null 2>&1 || true
echo "- Pre-soak state archive: \`$PRE_DUMP\`" >> "$REPORT"
echo >> "$REPORT"

# Hand off to the existing active-soak gate.
echo "Starting active soak via ci/check_active_soak.sh ..." | tee -a "$REPORT"
echo >> "$REPORT"
echo '```' >> "$REPORT"

IFACE="$IFACE" \
PEER="$PEER" \
LOCAL_IP="$LOCAL_IP" \
LOCAL_PREFIX="$LOCAL_PREFIX" \
SOAK_HOURS="$SOAK_HOURS" \
BANDWIDTH="$BANDWIDTH" \
SAMPLE_INTERVAL="$SAMPLE_INTERVAL" \
LOG="$SOAK_LOG" \
	bash "$ROOT/ci/check_active_soak.sh" 2>&1 | tail -50 >> "$REPORT" || true
gate_exit=${PIPESTATUS[0]:-0}

echo '```' >> "$REPORT"
echo >> "$REPORT"

# Post-soak state.
sudo "$ROOT/scripts/dump_state.sh" "$POST_DUMP" >/dev/null 2>&1 || true

cat >> "$REPORT" <<EOF
## Post-soak state

- Post-soak state archive: \`$POST_DUMP\`
- Soak log: \`$SOAK_LOG\`
- Gate exit code: $gate_exit
- Finished: $(date -u +'%Y-%m-%dT%H:%M:%SZ')

## §6.3 invariant delta

Run \`diff <(tar xOzf $PRE_DUMP six_three_gap.txt) <(tar xOzf $POST_DUMP six_three_gap.txt)\` for the per-counter delta.

EOF

if (( gate_exit == 0 )); then
	echo "## Verdict: PASS — Tier 1b complete, M5_CLOSEOUT bare-metal active evidence captured." >> "$REPORT"
else
	echo "## Verdict: FAIL — gate exit $gate_exit. Investigate $SOAK_LOG + $POST_DUMP." >> "$REPORT"
fi

echo
echo "Report: $REPORT"
echo "Pre-soak dump:  $PRE_DUMP"
echo "Post-soak dump: $POST_DUMP"
echo "Soak log:       $SOAK_LOG"
exit "$gate_exit"
