#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# kvm_kasan_soak_campaign.sh — runs the soak campaign INSIDE the KVM guest
# (vfio-passthrough RTL8125, KASAN kernel), fresh-loading per phase:
#   Phase 1: rss_queues=0  — 24 h
#   Phase 2: rss_queues=2  —  6 h
#   Phase 3: rss_queues=4  —  6 h
# Mirrors the gateway campaign so the two rigs cover the same configs; the unique
# value here is the vfio IOMMU + DMA_API_DEBUG context. A phase FAIL aborts.
#
# Run AS ROOT in the guest, with the controller peer iperf3 -s already up:
#   ssh rtl8125-guest 'sudo nohup bash \
#     /home/firestrand/rtl8125-rs/scripts/kvm_kasan_soak_campaign.sh /tmp/kvm_campaign \
#     >/tmp/kvm_campaign.log 2>&1 &'
# Shorter dry run:  PH1_H=1 PH2_H=1 PH3_H=1 ...

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOAK="$HERE/kvm_kasan_soak.sh"
OUT="${1:-/tmp/r8125_kvm_campaign_$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
PH1_H=${PH1_H:-24}; PH2_H=${PH2_H:-6}; PH3_H=${PH3_H:-6}
log(){ printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$OUT/campaign.log"; }

grep -q 'CONFIG_KASAN=y' "/boot/config-$(uname -r)" 2>/dev/null || log "WARN: guest kernel has no KASAN"

run_phase(){ local rss=$1 hours=$2 name=$3
  log "=== PHASE $name: rss_queues=$rss for ${hours}h ==="
  if SOAK_HOURS="$hours" RSS_QUEUES="$rss" bash "$SOAK" "$OUT/$name"; then
    log "PHASE $name PASS"
  else
    log "PHASE $name FAIL — aborting (see $OUT/$name/SOAK_REPORT.md)"; return 1
  fi
}

rc=0
run_phase 0 "$PH1_H" rss0_single || rc=1
[ "$rc" = 0 ] && { run_phase 2 "$PH2_H" rss2_multi || rc=1; }
[ "$rc" = 0 ] && { run_phase 4 "$PH3_H" rss4_multi || rc=1; }

log "=== KVM CAMPAIGN $([ "$rc" = 0 ] && echo PASS || echo FAIL) ==="
for p in rss0_single rss2_multi rss4_multi; do
  [ -f "$OUT/$p/SOAK_REPORT.md" ] && grep -h '## Verdict' "$OUT/$p/SOAK_REPORT.md" | sed "s|^|  $p: |" | tee -a "$OUT/campaign.log"
done
echo "(end)"
exit "$rc"
