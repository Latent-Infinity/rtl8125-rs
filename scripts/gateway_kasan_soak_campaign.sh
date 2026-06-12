#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# gateway_kasan_soak_campaign.sh — runs the full pre-upstream soak campaign on the
# gateway KASAN debug kernel, fresh-loading the driver for each phase:
#   Phase 1: rss_queues=0 (single-queue / RFC default)  — 24 h
#   Phase 2: rss_queues=2 (multi-queue, smallest valid)  —  6 h
#   Phase 3: rss_queues=4 (multi-queue, full)            —  6 h
# (multi-queue 12 h split across all valid RSS sizes: 2 and 4.)
#
# Each phase is an independent gateway_kasan_soak.sh run with its own report+CSV.
# A phase FAIL aborts the campaign (the driver state is suspect). Total ~36 h.
#
# Usage on the gateway (booted into 7.0.0-kasan):
#   sudo nohup bash scripts/gateway_kasan_soak_campaign.sh /tmp/soak_campaign \
#        >/tmp/soak_campaign.log 2>&1 &
# Override per-phase hours for a shorter dry run:
#   PH1_H=1 PH2_H=1 PH3_H=1 sudo bash scripts/gateway_kasan_soak_campaign.sh ...

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOAK="$HERE/gateway_kasan_soak.sh"
OUT="${1:-/tmp/r8125_soak_campaign_$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
PH1_H=${PH1_H:-24}; PH2_H=${PH2_H:-6}; PH3_H=${PH3_H:-6}
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/campaign.log"; }

[ "$(uname -r)" = "7.0.0-kasan" ] || { log "ABORT: not on 7.0.0-kasan (uname=$(uname -r))"; exit 2; }

run_phase(){ local rss=$1 hours=$2 name=$3
  log "=== PHASE $name: rss_queues=$rss for ${hours}h ==="
  if SOAK_HOURS="$hours" RSS_QUEUES="$rss" bash "$SOAK" "$OUT/$name"; then
    log "PHASE $name PASS"
  else
    log "PHASE $name FAIL — aborting campaign (see $OUT/$name/SOAK_REPORT.md)"
    return 1
  fi
}

rc=0
run_phase 0 "$PH1_H" rss0_single || rc=1
[ "$rc" = 0 ] && { run_phase 2 "$PH2_H" rss2_multi || rc=1; }
[ "$rc" = 0 ] && { run_phase 4 "$PH3_H" rss4_multi || rc=1; }

log "=== CAMPAIGN $([ "$rc" = 0 ] && echo PASS || echo FAIL) ==="
for p in rss0_single rss2_multi rss4_multi; do
  [ -f "$OUT/$p/SOAK_REPORT.md" ] && grep -h '## Verdict' "$OUT/$p/SOAK_REPORT.md" | sed "s|^|  $p: |" | tee -a "$OUT/campaign.log"
done
echo "(end)"
exit "$rc"
