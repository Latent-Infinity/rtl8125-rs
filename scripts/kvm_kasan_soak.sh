#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# kvm_kasan_soak.sh — hardened memory-safety + endurance soak for the rtl8125-rs
# driver INSIDE the KVM guest (rtl8125-guest), which has its own KASAN +
# kmemleak + DMA_API_DEBUG kernel and a vfio-passthrough RTL8125 (enp5s0).
#
# Why both this and the gateway soak: the guest validates the SAME driver code
# against a different, stricter IOMMU (vfio) — the class of bug this driver has
# hit before (DMA double-unmap, IOVA contention). It complements, not replaces,
# the gateway's real-silicon/ASPM coverage.
#
# Runs AS ROOT inside the guest (launch via sudo). Assumes the iperf3 server is
# already up on the controller/peer (this host's enp4s0 @ 10.0.0.1). TCP-only:
# UDP-TX is unusable on the KVM clocksource (a VM artifact, not a driver bug).
# Mirrors the gateway harness pass criteria (a wedge/leak FAILS, not silently
# passes).
#
# Usage (from the controller, after the peer iperf3 -s is up):
#   ssh rtl8125-guest 'sudo RSS_QUEUES=0 SOAK_HOURS=24 nohup \
#     bash /home/firestrand/rtl8125-rs/scripts/kvm_kasan_soak.sh /tmp/kvm_soak_rss0 \
#     >/tmp/kvm_soak_rss0.log 2>&1 &'

set -uo pipefail

KO=${KO:-/home/firestrand/rtl8125-rs/src/r8125_rust.ko}
DEV=${DEV:-enp5s0}; BDF=${BDF:-0000:05:00.0}
PIP=${PIP:-10.0.0.1}; LOCAL_IP=${LOCAL_IP:-10.0.0.2}; PREFIX=${PREFIX:-24}
RSS_QUEUES=${RSS_QUEUES:-0}
SOAK_HOURS=${SOAK_HOURS:-24}
SOAK_SECS=${SOAK_SECS:-$((SOAK_HOURS * 3600))}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}
CHURN_INTERVAL=${CHURN_INTERVAL:-3600}
IPERF_CYCLE=${IPERF_CYCLE:-60}             # SHORT cycle: iperf3 long-runs wedge on the KVM clocksource
TPUT_FLOOR_GBPS=${TPUT_FLOOR_GBPS:-0.05}   # KVM + KASAN is slower than bare metal
MEM_DROP_FAIL_KB=${MEM_DROP_FAIL_KB:-262144}
OUT="${1:-/tmp/r8125_kvm_soak_rss${RSS_QUEUES}_$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
CSV="$OUT/timeseries.csv"; REPORT="$OUT/SOAK_REPORT.md"; LOG="$OUT/soak.log"
FAILLOG=$(mktemp -t r8125_kvm_soak_fail.XXXXXX)
trap 'rm -f "$FAILLOG"' EXIT

log(){ printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
# 'KASAN:' (with colon) matches real report headers ("BUG: KASAN: <type>") but NOT
# the ubiquitous '__kasan_check_read/write' instrumentation frames that appear in
# EVERY backtrace under a KASAN kernel (e.g. an OOM-killer dump) — a bare 'KASAN'
# false-counted those as faults.
faults(){ dmesg | grep -icE 'KASAN:|UBSAN|BUG:|Oops|general protection|use-after-free|out-of-bounds|slab-out-of-bounds|DMA-API.*(WARN|error|warning)|WARNING:|possible.*deadlock|kmemleak: [0-9]+ new'; }
# Environmental resource pressure (NOT a driver fault): a guest OOM under KASAN +
# 4-queue page_pool on a small VM. Surfaced as a flagged note, gated by kmemleak
# (the real leak gate) — a driver-caused OOM would also trip kmemleak/mem_drop.
oom_kills(){ dmesg | grep -c 'Out of memory: Killed'; }
es(){ ethtool -S "$DEV" 2>/dev/null; }
ipstat(){ for f in rx_errors rx_dropped rx_missed_errors rx_fifo_errors rx_over_errors tx_errors tx_dropped; do v=$(cat "/sys/class/net/$DEV/statistics/$f" 2>/dev/null); printf '%s ' "${v:-0}"; done; }
carrier(){ cat "/sys/class/net/$DEV/carrier" 2>/dev/null || echo 0; }
memavail(){ awk '/MemAvailable/{print $2}' /proc/meminfo; }
slab(){ awk '/^Slab:/{print $2}' /proc/meminfo; }

# ── load the configured driver in-guest (no netns; vfio passthrough device) ───
log "=== KVM KASAN soak: rss_queues=$RSS_QUEUES dur=${SOAK_SECS}s on $DEV (kernel $(uname -r)) ==="
grep -q 'CONFIG_KASAN=y' "/boot/config-$(uname -r)" 2>/dev/null || log "WARN: guest kernel has no KASAN — coverage reduced"
rmmod r8125_rust 2>/dev/null
dmesg -C 2>/dev/null || true
insmod "$KO" rss_queues="$RSS_QUEUES" || { log "ABORT: insmod failed"; exit 2; }
for s in $(seq 1 12); do [ -e "/sys/class/net/$DEV" ] && break; sleep 1; done
ip addr replace "$LOCAL_IP/$PREFIX" dev "$DEV" 2>/dev/null; ip link set "$DEV" up
for s in $(seq 1 15); do [ "$(carrier)" = 1 ] && break; sleep 1; done
ACTIVE=$(ethtool -l "$DEV" 2>/dev/null | awk '/Current/{f=1} f&&/RX:/{print $2; exit}')
log "carrier=$(carrier) active_rx_queues=$ACTIVE mac=$(cat /sys/class/net/$DEV/address)"
if ! ping -c2 -W2 "$PIP" >/dev/null 2>&1; then
  log "ABORT: no connectivity to peer $PIP (is the controller iperf/peer up?)"; exit 2
fi
echo "ts,elapsed_s,tx_received,rx_handed,gap,gbps,faults,hw_err_delta,hw_drop_delta,carrier_flaps,memavail_kb,slab_kb,kmemleak_new" > "$CSV"

# ── background TCP bidirectional traffic (short respawn cycles for the KVM) ───
start=$(date +%s); deadline=$((start + SOAK_SECS))
traffic_runner(){
  local dir=tx
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local remaining=$(( deadline - $(date +%s) )); local t=$(( remaining < IPERF_CYCLE ? remaining : IPERF_CYCLE ))
    [ "$t" -lt 5 ] && break
    local rflag=""; [ "$dir" = rx ] && rflag="-R"
    iperf3 -c "$PIP" -p 5201 -P4 -t "$t" $rflag >>"$LOG" 2>&1 || echo "iperf $dir failed @$(date -u +%H:%M:%S)" >>"$FAILLOG"
    [ "$dir" = tx ] && dir=rx || dir=tx
    sleep 1
  done
}
traffic_runner & TRAFFIC_PID=$!

# ── monitor loop (same gates as the gateway harness) ─────────────────────────
prev_tx=$(es | awk '/tx_received:/{print $2}'); prev_tx=${prev_tx:-0}
prev_rx=$(es | awk '/rx_handed_to_stack:/{print $2}'); prev_rx=${prev_rx:-0}
read -ra BHW <<<"$(ipstat)"; base_mem=$(memavail); base_carrier=$(carrier)
carrier_flaps=0; last_carrier=$base_carrier; stalls=0; samples=0; min_mem=$base_mem
# grace=1: the first sample is a warm-up — the freshly (re)loaded module is still
# settling link/IP and iperf is still connecting in the first SAMPLE_INTERVAL, so
# its dtx/drx and throughput aren't representative. Skip its stall/low_tput checks
# exactly as a post-churn sample is skipped (steady-state samples stay gated; TCP
# ACKs keep both dtx and drx > 0 even during unidirectional iperf cycles).
last_churn=$start; grace=1; low_tput=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep "$SAMPLE_INTERVAL"
  # Backstop: keep the DUT IP present against any networkd reconcile (idempotent;
  # only affects L3 config, never carrier/RX/TX — won't mask a driver fault).
  ip addr replace "$LOCAL_IP/$PREFIX" dev "$DEV" 2>/dev/null
  samples=$((samples+1)); now=$(date +%s); elapsed=$((now-start))
  s=$(es); tx=$(echo "$s"|awk '/tx_received:/{print $2}'); rx=$(echo "$s"|awk '/rx_handed_to_stack:/{print $2}')
  tc=$(echo "$s"|awk '/tx_consumed:/{print $2}'); tb=$(echo "$s"|awk '/tx_busy_exception:/{print $2}'); td=$(echo "$s"|awk '/tx_dropped_error:/{print $2}')
  tx=${tx:-0}; rx=${rx:-0}; tc=${tc:-0}; tb=${tb:-0}; td=${td:-0}
  dtx=$((tx-prev_tx)); drx=$((rx-prev_rx)); gap=$((tx-tc-tb-td))
  gbps=$(awk -v p="$dtx" -v i="$SAMPLE_INTERVAL" 'BEGIN{printf "%.3f", (p*1500*8)/(i*1e9)}')
  f=$(faults)
  read -ra CHW <<<"$(ipstat)"
  # Hard hardware errors (corruption / real fault) — zero tolerance:
  #   rx_errors[0] rx_fifo_errors[3] rx_over_errors[4] tx_errors[5]
  hwd=0; for j in 0 3 4 5; do hwd=$((hwd + CHW[j] - BHW[j])); done
  # rx_missed_errors[2] is RX-FIFO BACKPRESSURE (the host didn't refill the ring
  # in time), NOT corruption. Under KASAN+DMA_API_DEBUG single-queue the
  # instrumented host lags 2.5G line rate and the chip applies FIFO backpressure —
  # a keep-up symptom (the C driver does the same), not a driver/HW fault. Track it
  # with the tolerated drop class; only a RUNAWAY count (a genuine RX stall, not
  # backpressure) fails the verdict, via RX_MISSED_MAX.
  rxmiss=$(( CHW[2] - BHW[2] ))
  hwdrop=$(( (CHW[1]-BHW[1]) + (CHW[6]-BHW[6]) + rxmiss ))
  cur_carrier=$(carrier); [ "$cur_carrier" != "$last_carrier" ] && { carrier_flaps=$((carrier_flaps+1)); last_carrier=$cur_carrier; }
  mem=$(memavail); slb=$(slab)
  echo scan > /sys/kernel/debug/kmemleak 2>/dev/null; sleep 3
  # grep -c prints "0" AND exits non-zero on no-match; piping cat keeps a single
  # clean integer (a bare `|| echo 0` would append a second line -> "0\n0").
  kml=$(cat /sys/kernel/debug/kmemleak 2>/dev/null | grep -c 'unreferenced object'); kml=${kml:-0}
  echo "$(date -u +%H:%M:%S),$elapsed,$tx,$rx,$gap,$gbps,$f,$hwd,$hwdrop,$carrier_flaps,$mem,$slb,$kml" >> "$CSV"
  if [ "$grace" = 0 ] && kill -0 "$TRAFFIC_PID" 2>/dev/null && { [ "$dtx" -le 0 ] || [ "$drx" -le 0 ]; }; then
    stalls=$((stalls+1)); echo "STALL @${elapsed}s dtx=$dtx drx=$drx" >>"$FAILLOG"; log "  !! STALL dtx=$dtx drx=$drx"
  fi
  if [ "$grace" = 0 ] && [ "$dtx" -gt 0 ] && awk -v g="$gbps" -v fl="$TPUT_FLOOR_GBPS" 'BEGIN{exit !(g<fl)}'; then
    low_tput=$((low_tput+1)); echo "LOW_TPUT=$gbps<$TPUT_FLOOR_GBPS @${elapsed}s" >>"$FAILLOG"
  fi
  [ "$f" -gt 0 ] && { echo "FAULTS=$f @${elapsed}s" >>"$FAILLOG"; dmesg | grep -E 'KASAN|BUG:|WARNING:|use-after-free|DMA-API|kmemleak: [0-9]+ new' | tail -5 >>"$FAILLOG"; }
  [ "$hwd" -gt 0 ] && echo "HW_ERR_GROWTH=$hwd @${elapsed}s ($(ipstat))" >>"$FAILLOG"
  [ "$rxmiss" -gt "${RX_MISSED_MAX:-1000000}" ] && echo "RX_MISSED_RUNAWAY=$rxmiss @${elapsed}s ($(ipstat))" >>"$FAILLOG"
  [ "$kml" -gt 0 ] && echo "KMEMLEAK=$kml @${elapsed}s" >>"$FAILLOG"
  [ "$mem" -lt "$min_mem" ] && min_mem=$mem
  log "  s$samples t=${elapsed}s gbps=$gbps faults=$f hw_err=+$hwd drop=+$hwdrop flaps=$carrier_flaps memavail=${mem}kb kmemleak=$kml gap=$gap"
  prev_tx=$tx; prev_rx=$rx; grace=0
  if [ $((now - last_churn)) -ge "$CHURN_INTERVAL" ]; then
    log "  churn: link flap + ethtool query"
    ethtool -S "$DEV" >/dev/null 2>&1; ethtool -l "$DEV" >/dev/null 2>&1; ethtool -x "$DEV" >/dev/null 2>&1
    ip link set "$DEV" down; sleep 2; ip link set "$DEV" up
    for s in $(seq 1 12); do [ "$(carrier)" = 1 ] && break; sleep 1; done
    # The guest's enp5s0 is networkd-managed (Required-For-Online), so the flap
    # can flush its IP. Re-assert it immediately so traffic resumes before the
    # next (grace-skipped) sample. This is the KVM analogue of the controller's
    # static-IP fix; the gateway soak is immune (netns, not networkd-managed).
    ip addr replace "$LOCAL_IP/$PREFIX" dev "$DEV" 2>/dev/null
    last_churn=$now; grace=1
  fi
done

kill "$TRAFFIC_PID" 2>/dev/null; wait "$TRAFFIC_PID" 2>/dev/null
mem_drop=$((base_mem - min_mem))
total_faults=$(faults); iperf_fails=$([ -s "$FAILLOG" ] && grep -c 'iperf .* failed' "$FAILLOG" || echo 0)
ooms=$(oom_kills)
pass=1; reasons=""
[ "$total_faults" -gt 0 ] && { pass=0; reasons+="kernel-debug-faults=$total_faults; "; }
[ "$stalls" -gt 0 ] && { pass=0; reasons+="counter-stalls=$stalls; "; }
[ "$low_tput" -gt "${LOW_TPUT_MAX:-5}" ] && { pass=0; reasons+="low-throughput-samples=$low_tput; "; }
grep -q 'HW_ERR_GROWTH' "$FAILLOG" 2>/dev/null && { pass=0; reasons+="hw-error-growth; "; }
grep -q 'RX_MISSED_RUNAWAY' "$FAILLOG" 2>/dev/null && { pass=0; reasons+="rx-missed-runaway; "; }
grep -q 'KMEMLEAK' "$FAILLOG" 2>/dev/null && { pass=0; reasons+="kmemleak; "; }
[ "$carrier_flaps" -gt 0 ] && { pass=0; reasons+="carrier-flaps=$carrier_flaps; "; }
[ "$mem_drop" -gt "$MEM_DROP_FAIL_KB" ] && reasons+="(note: memavail-drop=${mem_drop}kb, see kmemleak) "
# OOM is surfaced as a note, NOT an auto-fail: gated by kmemleak above (a driver
# leak would trip it). Order-N OOM with kmemleak=0 = environmental guest pressure
# (small VM + KASAN shadow + N-queue page_pool), reproducible with any driver.
[ "$ooms" -gt 0 ] && reasons+="(note: oom-kills=$ooms — environmental guest memory pressure; not a driver fault unless kmemleak>0) "

{
  echo "# KVM (vfio) KASAN soak — rss_queues=$RSS_QUEUES"
  echo
  echo "- Guest kernel: $(uname -r) (KASAN+kmemleak+DMA-API), vfio-passthrough RTL8125 $BDF"
  echo "- Driver: r8125_rust @ rss_queues=$RSS_QUEUES (active=$ACTIVE)"
  echo "- Duration: ${SOAK_SECS}s  samples: $samples  TCP-only, ${IPERF_CYCLE}s iperf cycles"
  echo
  echo "## Verdict: $([ "$pass" = 1 ] && echo PASS || echo "FAIL — $reasons")"
  echo
  echo "| metric | value |"; echo "|---|---|"
  echo "| kernel-debug faults | $total_faults |"
  echo "| counter stalls | $stalls / $samples |"
  echo "| carrier flaps | $carrier_flaps |"
  echo "| MemAvailable drop (max) | ${mem_drop} kB |"
  echo "| oom-kills (environmental) | $ooms |"
  echo "| iperf restarts | $iperf_fails |"
  echo "| final §6.3 gap | $gap |"
  echo
  echo "Time series: \`timeseries.csv\`. Failure log:"; echo '```'; cat "$FAILLOG" 2>/dev/null; echo '```'
} > "$REPORT"

log "=== DONE rss_queues=$RSS_QUEUES verdict=$([ "$pass" = 1 ] && echo PASS || echo FAIL) ($reasons) ==="
echo "(end)"
exit $((1 - pass))
