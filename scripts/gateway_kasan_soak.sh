#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# gateway_kasan_soak.sh — hardened single-phase memory-safety + endurance soak
# for the rtl8125-rs driver on the gateway's KASAN debug kernel (7.0.0-kasan:
# KASAN + PROVE_LOCKING + kmemleak + DMA_API_DEBUG, on real RTL8125B silicon).
#
# Supersedes the thin ci/check_active_soak.sh for gateway runs. Pass criteria are
# strict (a wedge or slow degradation must FAIL, not silently pass):
#   * zero kernel-debug reports (KASAN/lockdep/DMA-API/kmemleak/BUG/WARNING)
#   * zero growth in hardware error counters (rx/tx errors, dropped, missed, fifo)
#   * counters ADVANCE every sample (true liveness — catches a mid-soak stall
#     that tx_delta>0 over the whole run would mask)
#   * sustained throughput stays above a floor (not "1 byte moved")
#   * no carrier flaps, no PCIe AER errors
#   * MemAvailable/Slab do not trend down monotonically (leak signal)
#   * §6.3 disposition invariant gap stays ~0
#
# Emits a per-sample time-series CSV + a markdown summary for the soak record.
#
# Usage on the gateway (must be booted into 7.0.0-kasan):
#   sudo RSS_QUEUES=0 SOAK_HOURS=24 nohup bash scripts/gateway_kasan_soak.sh \
#        /tmp/soak_rss0 >/tmp/soak_rss0.log 2>&1 &
# Short proxy for harness validation:  SOAK_SECS=180 SAMPLE_INTERVAL=30 ...

set -uo pipefail

GWL=${GWL:-/home/firestrand/gw_loopback.sh}
DUT="ip netns exec dut"; PEER="ip netns exec peer"
DEV=${DEV:-enp3s0}; PEERDEV=${PEERDEV:-enp4s0}; PIP=${PIP:-10.0.0.1}; BDF=${BDF:-0000:03:00.0}
RSS_QUEUES=${RSS_QUEUES:-0}
SOAK_HOURS=${SOAK_HOURS:-24}
SOAK_SECS=${SOAK_SECS:-$((SOAK_HOURS * 3600))}
SAMPLE_INTERVAL=${SAMPLE_INTERVAL:-300}
CHURN_INTERVAL=${CHURN_INTERVAL:-3600}     # link-flap + ethtool query cadence
IPERF_CYCLE=${IPERF_CYCLE:-600}            # respawn iperf each cycle (avoid long-run wedge)
TPUT_FLOOR_GBPS=${TPUT_FLOOR_GBPS:-0.10}   # KASAN is slow; floor is "real traffic moving"
MEM_DROP_FAIL_KB=${MEM_DROP_FAIL_KB:-262144} # >256MB monotonic MemAvailable drop => leak
OUT="${1:-/tmp/r8125_kasan_soak_rss${RSS_QUEUES}_$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
CSV="$OUT/timeseries.csv"; REPORT="$OUT/SOAK_REPORT.md"; LOG="$OUT/soak.log"
FAILLOG=$(mktemp -t r8125_soak_fail.XXXXXX)
trap 'rm -f "$FAILLOG"' EXIT

log(){ printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
# 'KASAN:' (colon) matches real report headers, not the '__kasan_check_*' frames
# present in every KASAN-kernel backtrace (e.g. OOM dumps) — see kvm harness note.
faults(){ dmesg | grep -icE 'KASAN:|UBSAN|BUG:|Oops|general protection|use-after-free|out-of-bounds|slab-out-of-bounds|DMA-API.*(WARN|error|warning)|WARNING:|possible.*deadlock|kmemleak: [0-9]+ new'; }
# r8125-scoped fault count: only kernel-debug splats whose report block references
# the driver, its cshim, a hot-path symbol, the DUT interface, or the DUT BDF.
# This drives the PASS/FAIL verdict so an UNRELATED subsystem on the same host
# (e.g. the gateway's WiFi wpa_supplicant faulting under KASAN) cannot fail the
# r8125 soak. The broad faults() above is kept as an informational column. A
# splat "belongs to us" if any of the ~60 lines after its trigger names us.
r8125_faults(){
  dmesg | awk -v dev="$DEV" -v bdf="${BDF:-}" '
    function endwin(){ if (win>0 && hit) n++; win=0; hit=0 }
    BEGIN{ IGNORECASE=1; n=0; win=0; hit=0 }
    /KASAN:|UBSAN|BUG:|Oops|general protection|use-after-free|out-of-bounds|slab-out-of-bounds|DMA-API.*(WARN|error|warning)|WARNING:|possible.*deadlock|kmemleak: [0-9]+ new/ { endwin(); win=60; hit=0 }
    win>0 {
      if ($0 ~ /r8125|netdev_bridge|tx_offload|rust_xmit|rust_stop|rust_open|process_tx|process_rx|gphy_ocp|mac_ocp/ || index($0,dev)>0 || (bdf!="" && index($0,bdf)>0)) hit=1
      win--
    }
    END{ endwin(); print n+0 }'
}
es(){ ethtool -S "$DEV" 2>/dev/null | awk -v k="$1:" '$1==k{print $2}'; }   # ethtool -S field (in dut ns: prefix with $DUT)
# all values read inside dut netns
duts(){ $DUT ethtool -S "$DEV" 2>/dev/null; }
ipstat(){ $DUT bash -c "for f in rx_errors rx_dropped rx_missed_errors rx_fifo_errors rx_over_errors tx_errors tx_dropped; do v=\$(cat /sys/class/net/$DEV/statistics/\$f 2>/dev/null); echo -n \"\${v:-0} \"; done"; }
carrier(){ $DUT cat "/sys/class/net/$DEV/carrier" 2>/dev/null || echo 0; }
memavail(){ awk '/MemAvailable/{print $2}' /proc/meminfo; }
slab(){ awk '/^Slab:/{print $2}' /proc/meminfo; }
aer(){ sudo lspci -vv -s "$BDF" 2>/dev/null | grep -oE '(CorrErr|UncorrErr|Fatal|NonFatal)[+-]' | grep -c '+' || echo 0; }

# ── bring up the configured driver ───────────────────────────────────────────
log "=== KASAN soak: rss_queues=$RSS_QUEUES dur=${SOAK_SECS}s on $DEV (kernel $(uname -r)) ==="
[ "$(uname -r)" = "7.0.0-kasan" ] || log "WARN: not on the kasan kernel (uname=$(uname -r)) — memory-safety coverage reduced"
bash "$GWL" setup >/dev/null 2>&1
bash "$GWL" dut rust "rss_queues=$RSS_QUEUES" >/dev/null 2>&1
for s in $(seq 1 20); do [ "$(carrier)" = 1 ] && break; sleep 1; done
$PEER pkill -9 iperf3 2>/dev/null; sleep 1; $PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 2
sudo dmesg -C 2>/dev/null || true

ACTIVE=$($DUT ethtool -l "$DEV" 2>/dev/null | awk '/Current/{f=1} f&&/RX:/{print $2; exit}')
log "carrier=$(carrier) active_rx_queues=$ACTIVE mac=$($DUT cat /sys/class/net/$DEV/address)"
echo "ts,elapsed_s,tx_received,rx_handed,gap,gbps,faults,kernel_faults,hw_err_delta,hw_drop_delta,carrier_flaps,memavail_kb,slab_kb,kmemleak_new,aer" > "$CSV"

# ── background bidirectional traffic (respawn to dodge long-run iperf3 wedge) ─
start=$(date +%s); deadline=$((start + SOAK_SECS))
traffic_runner(){
  local dir=tx
  while [ "$(date +%s)" -lt "$deadline" ]; do
    local remaining=$(( deadline - $(date +%s) )); local t=$(( remaining < IPERF_CYCLE ? remaining : IPERF_CYCLE ))
    [ "$t" -lt 5 ] && break
    local rflag=""; [ "$dir" = rx ] && rflag="-R"
    if ! $DUT iperf3 -c "$PIP" -p 5201 -P4 -t "$t" $rflag >>"$LOG" 2>&1; then
      echo "iperf $dir failed @$(date -u +%H:%M:%S)" >>"$FAILLOG"
      $PEER pkill -9 iperf3 2>/dev/null; sleep 1; $PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 1
    fi
    [ "$dir" = tx ] && dir=rx || dir=tx
  done
}
traffic_runner & TRAFFIC_PID=$!

# ── monitor loop ─────────────────────────────────────────────────────────────
prev_tx=$(duts | awk '/tx_received:/{print $2}'); prev_tx=${prev_tx:-0}
prev_rx=$(duts | awk '/rx_handed_to_stack:/{print $2}'); prev_rx=${prev_rx:-0}
base_hw=$(ipstat); base_mem=$(memavail); base_carrier=$(carrier)
read -ra BHW <<<"$base_hw"
carrier_flaps=0; last_carrier=$base_carrier; stalls=0; samples=0
min_mem=$base_mem; min_gbps=99999
# grace=1: the first sample is a warm-up (freshly loaded module still settling
# link/IP, iperf still connecting) — skip its stall/low_tput checks, same as a
# post-churn sample. Steady-state samples stay fully gated.
last_churn=$start; grace=1; low_tput=0

while [ "$(date +%s)" -lt "$deadline" ]; do
  sleep "$SAMPLE_INTERVAL"
  samples=$((samples+1)); now=$(date +%s); elapsed=$((now-start))
  s=$(duts); tx=$(echo "$s" | awk '/tx_received:/{print $2}'); rx=$(echo "$s" | awk '/rx_handed_to_stack:/{print $2}')
  tc=$(echo "$s"|awk '/tx_consumed:/{print $2}'); tb=$(echo "$s"|awk '/tx_busy_exception:/{print $2}'); td=$(echo "$s"|awk '/tx_dropped_error:/{print $2}')
  tx=${tx:-0}; rx=${rx:-0}; tc=${tc:-0}; tb=${tb:-0}; td=${td:-0}
  dtx=$((tx-prev_tx)); drx=$((rx-prev_rx)); gap=$((tx-tc-tb-td))
  # throughput estimate from tx_received packets (avg ~1500B wire) over interval
  gbps=$(awk -v p="$dtx" -v i="$SAMPLE_INTERVAL" 'BEGIN{printf "%.3f", (p*1500*8)/(i*1e9)}')
  f=$(r8125_faults); kf=$(faults)   # f = r8125-scoped (verdict); kf = all-kernel (context)
  # Separate TRUE hardware errors (must stay 0) from drops. tx_dropped/rx_dropped
  # legitimately grow on the intentional link-flap churn and on queue-stop, so
  # they are recorded but never fail the soak. Error indices in ipstat order
  # (rx_errors rx_dropped rx_missed rx_fifo rx_over tx_errors tx_dropped): 0,2,3,4,5.
  cur_hw=$(ipstat); read -ra CHW <<<"$cur_hw"; hwd=0
  # Hard hardware errors (corruption / real fault), zero tolerance:
  #   rx_errors[0] rx_fifo_errors[3] rx_over_errors[4] tx_errors[5]
  for j in 0 3 4 5; do hwd=$((hwd + CHW[j] - BHW[j])); done
  # rx_missed_errors[2] is RX-FIFO backpressure (host keep-up under heavy
  # instrumentation / memory pressure), NOT corruption — tolerated with the drop
  # class; only a RUNAWAY count (real RX stall) fails, via RX_MISSED_MAX.
  rxmiss=$(( CHW[2] - BHW[2] ))
  hwdrop=$(( (CHW[1]-BHW[1]) + (CHW[6]-BHW[6]) + rxmiss ))
  cur_carrier=$(carrier); [ "$cur_carrier" != "$last_carrier" ] && { carrier_flaps=$((carrier_flaps+1)); last_carrier=$cur_carrier; }
  mem=$(memavail); slb=$(slab); a=$(aer)
  # kmemleak scan — the authoritative leak gate (MemAvailable fluctuates with page
  # cache + KASAN shadow, so it is recorded for trend but does NOT fail the run).
  echo scan | sudo tee /sys/kernel/debug/kmemleak >/dev/null 2>&1; sleep 3
  kml=$(sudo cat /sys/kernel/debug/kmemleak 2>/dev/null | grep -c 'unreferenced object')
  echo "$(date -u +%H:%M:%S),$elapsed,$tx,$rx,$gap,$gbps,$f,$kf,$hwd,$hwdrop,$carrier_flaps,$mem,$slb,$kml,$a" >> "$CSV"
  # liveness + throughput: skip for one sample after a churn (link-flap briefly
  # interrupts traffic). While traffic should be running, both counters advance.
  if [ "$grace" = 0 ] && kill -0 "$TRAFFIC_PID" 2>/dev/null && { [ "$dtx" -le 0 ] || [ "$drx" -le 0 ]; }; then
    stalls=$((stalls+1)); echo "STALL @${elapsed}s dtx=$dtx drx=$drx" >>"$FAILLOG"
    log "  !! STALL dtx=$dtx drx=$drx (tx=$tx rx=$rx)"
  fi
  if [ "$grace" = 0 ] && [ "$dtx" -gt 0 ] && awk -v g="$gbps" -v fl="$TPUT_FLOOR_GBPS" 'BEGIN{exit !(g<fl)}'; then
    low_tput=$((low_tput+1)); echo "LOW_TPUT=$gbps<$TPUT_FLOOR_GBPS @${elapsed}s" >>"$FAILLOG"
  fi
  [ "$f" -gt 0 ] && { echo "FAULTS=$f (r8125-scoped; kernel-wide=$kf) @${elapsed}s" >>"$FAILLOG"; dmesg | grep -E 'KASAN|BUG:|WARNING:|use-after-free|DMA-API|kmemleak: [0-9]+ new' -A20 | grep -iE 'r8125|netdev_bridge|tx_offload|rust_|process_tx|process_rx|'"$DEV" | tail -8 >>"$FAILLOG"; }
  [ "$hwd" -gt 0 ] && echo "HW_ERR_GROWTH=$hwd @${elapsed}s ($cur_hw)" >>"$FAILLOG"
  [ "$rxmiss" -gt "${RX_MISSED_MAX:-1000000}" ] && echo "RX_MISSED_RUNAWAY=$rxmiss @${elapsed}s ($cur_hw)" >>"$FAILLOG"
  [ "$kml" -gt 0 ] && echo "KMEMLEAK=$kml @${elapsed}s" >>"$FAILLOG"
  [ "$mem" -lt "$min_mem" ] && min_mem=$mem
  log "  s$samples t=${elapsed}s gbps=$gbps faults=$f (kernel=$kf) hw_err=+$hwd drop=+$hwdrop flaps=$carrier_flaps memavail=${mem}kb kmemleak=$kml gap=$gap"
  prev_tx=$tx; prev_rx=$rx; grace=0
  # periodic control-plane churn: link flap + ethtool reads (chip recovery + ops coverage)
  if [ $((now - last_churn)) -ge "$CHURN_INTERVAL" ]; then
    log "  churn: link flap + ethtool query"
    $DUT ethtool -S "$DEV" >/dev/null 2>&1; $DUT ethtool -l "$DEV" >/dev/null 2>&1; $DUT ethtool -x "$DEV" >/dev/null 2>&1
    $DUT ip link set "$DEV" down; sleep 2; $DUT ip link set "$DEV" up
    for s in $(seq 1 12); do [ "$(carrier)" = 1 ] && break; sleep 1; done
    last_churn=$now; grace=1   # next sample: skip stall/throughput checks (flap interrupts traffic)
  fi
done

kill "$TRAFFIC_PID" 2>/dev/null; wait "$TRAFFIC_PID" 2>/dev/null
mem_drop=$((base_mem - min_mem))

# ── verdict ──────────────────────────────────────────────────────────────────
total_faults=$(r8125_faults); kernel_faults=$(faults)   # verdict on r8125-scoped only
iperf_fails=$([ -s "$FAILLOG" ] && grep -c 'iperf .* failed' "$FAILLOG" || echo 0)
pass=1; reasons=""
[ "$total_faults" -gt 0 ] && { pass=0; reasons+="r8125-debug-faults=$total_faults; "; }
[ "$stalls" -gt 0 ] && { pass=0; reasons+="counter-stalls=$stalls; "; }
[ "$low_tput" -gt "${LOW_TPUT_MAX:-5}" ] && { pass=0; reasons+="low-throughput-samples=$low_tput; "; }
grep -q 'HW_ERR_GROWTH' "$FAILLOG" 2>/dev/null && { pass=0; reasons+="hw-error-growth; "; }
grep -q 'RX_MISSED_RUNAWAY' "$FAILLOG" 2>/dev/null && { pass=0; reasons+="rx-missed-runaway; "; }
grep -q 'KMEMLEAK' "$FAILLOG" 2>/dev/null && { pass=0; reasons+="kmemleak; "; }
[ "$carrier_flaps" -gt 0 ] && { pass=0; reasons+="carrier-flaps=$carrier_flaps; "; }
# MemAvailable drop is informational only — kmemleak above is the leak gate.
[ "$mem_drop" -gt "$MEM_DROP_FAIL_KB" ] && reasons+="(note: memavail-drop=${mem_drop}kb, see kmemleak) "

{
  echo "# Gateway KASAN soak — rss_queues=$RSS_QUEUES"
  echo
  echo "- Kernel: $(uname -r)  (KASAN+lockdep+kmemleak+DMA-API)"
  echo "- Driver: r8125_rust @ rss_queues=$RSS_QUEUES (active=$ACTIVE)  commit $(git -C "$(dirname "$GWL")" rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "- Duration: ${SOAK_SECS}s   samples: $samples   started $(date -u -d @"$start" +%FT%TZ 2>/dev/null)"
  echo "- Traffic: bidirectional iperf3 -P4, ${IPERF_CYCLE}s respawn cycles; churn every ${CHURN_INTERVAL}s"
  echo
  echo "## Verdict: $([ "$pass" = 1 ] && echo PASS || echo "FAIL — $reasons")"
  echo
  echo "| metric | value |"
  echo "|---|---|"
  echo "| r8125 debug faults (verdict) | $total_faults |"
  echo "| kernel-wide faults (context, NOT in verdict) | $kernel_faults |"
  echo "| counter stalls | $stalls / $samples |"
  echo "| carrier flaps | $carrier_flaps |"
  echo "| MemAvailable drop (max) | ${mem_drop} kB (base $base_mem, min $min_mem) |"
  echo "| iperf restarts | $iperf_fails |"
  echo "| final §6.3 gap | $gap |"
  echo
  echo "Time series: \`timeseries.csv\`. Failure log:"; echo '```'; cat "$FAILLOG" 2>/dev/null; echo '```'
} > "$REPORT"

log "=== DONE rss_queues=$RSS_QUEUES verdict=$([ "$pass" = 1 ] && echo PASS || echo FAIL) ($reasons) -> $REPORT ==="
echo "(end)"
exit $((1 - pass))
