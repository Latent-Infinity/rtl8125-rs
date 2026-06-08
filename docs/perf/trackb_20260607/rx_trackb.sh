#!/bin/bash
# Track B value experiment.
# Question: with Track A (single RX queue + RXHASH) shipping, does software RPS
# survive an application stealing the NIC's CPU, or does only a hardware RX queue
# (its own IRQ landing on an idle CPU) recover throughput?
#
# Mechanism: pin the single NIC IRQ + NAPI to ONE logical CPU, then load that CPU
# with a taskset-pinned busy-loop "application" hog. Compare delivered RX pps/loss
# and per-CPU softirq under three queueing configs, with and without the hog.
#
#   A  single : IRQ->NAPI_CPU, RPS off              (today's path, no steering)
#   B  trackA : IRQ->NAPI_CPU, RPS on -> idle CPUs  (RXHASH-driven software steer)
#   C  trackB : IRQ->IDLE_CPU, RPS off              (simulated HW RX queue on idle CPU)
#
# Usage: rx_trackb.sh [framesize] [dur]   (root; rig already up with rust + peer iperf3 -s)
set -uo pipefail
DUT_NS=dut; IF=enp3s0; PEER=10.0.0.1; IRQ=68
FS="${1:-64}"; DUR="${2:-12}"
NAPI_CPU=8; IDLE_CPU=16; RPS_MASK=fe00      # bits 9..15 -> CPUs 9-15 (idle)
OUT=/home/firestrand/bench_results/trackb_${FS}; mkdir -p "$OUT/raw"
CSV="$OUT/results.csv"
echo "config,hog,deliv_pps,deliv_mbps,loss_pct,napi_cpu_idle,napi_cpu_soft,napi_cpu_sys,rps_cpus_soft_sum,softnet_drop_delta,rx_dropped_delta" > "$CSV"
nsx(){ ip netns exec $DUT_NS "$@"; }
RPS_PATH=/sys/class/net/$IF/queues/rx-0/rps_cpus

sn_sum(){ nsx awk 'BEGIN{p=0;d=0}{p+=strtonum("0x"$1);d+=strtonum("0x"$2)}END{print d}' /proc/net/softnet_stat; }
es_get(){ nsx ethtool -S $IF 2>/dev/null | awk -F: -v k="$1" '$1 ~ k {gsub(/ /,"",$2);print $2;exit}'; }

run_one(){  # $1 label  $2 irq_cpu  $3 rps_mask(0=off)  $4 hog(0/1)
  local label="$1" icpu="$2" rmask="$3" hog="$4"
  echo "$icpu" > /proc/irq/$IRQ/smp_affinity_list
  nsx sh -c "echo $rmask > $RPS_PATH"
  local hpid=""
  if [ "$hog" = 1 ]; then taskset -c "$NAPI_CPU" sh -c 'while :; do :; done' >/dev/null 2>&1 & hpid=$!; fi
  sleep 1
  local sn0 miss0 fifo0
  sn0=$(sn_sum); drop0=$(es_get rx_dropped_error)
  : "${drop0:=0}"
  # mpstat over the run (global /proc/stat); iperf3 RX flood in parallel
  mpstat -P ALL 1 "$DUR" > "$OUT/raw/mpstat_${label}_h${hog}.txt" 2>/dev/null &
  local mpid=$!
  local j; j=$(nsx iperf3 -c $PEER -p 5201 -u -b 0 -l "$FS" -R -P 10 -t "$DUR" -J 2>>"$OUT/raw/iperf_err.log")
  wait $mpid 2>/dev/null
  echo "$j" > "$OUT/raw/iperf_${label}_h${hog}.json"
  [ -n "$hpid" ] && kill "$hpid" 2>/dev/null
  local sn1 miss1 fifo1
  sn1=$(sn_sum); drop1=$(es_get rx_dropped_error)
  : "${drop1:=0}"
  # iperf metrics
  local pkts secs pps mbps loss
  pkts=$(jq -r '.end.sum.packets // 0' <<<"$j" 2>/dev/null)
  secs=$(jq -r '.end.sum.seconds // 1' <<<"$j" 2>/dev/null)
  pps=$(awk "BEGIN{printf \"%.0f\", ($secs+0)?($pkts+0)/$secs:0}")
  mbps=$(jq -r '(.end.sum.bits_per_second // 0)/1e6' <<<"$j" 2>/dev/null)
  loss=$(jq -r '.end.sum.lost_percent // 0' <<<"$j" 2>/dev/null)
  # mpstat averages for NAPI cpu + sum of soft on rps targets (9-15)
  local f="$OUT/raw/mpstat_${label}_h${hog}.txt"
  local nidle nsoft nsys rsoft
  nidle=$(awk -v c=$NAPI_CPU '/^Average:/ && $2==c {print $12}' "$f")
  nsoft=$(awk -v c=$NAPI_CPU '/^Average:/ && $2==c {print $8}' "$f")
  nsys=$(awk -v c=$NAPI_CPU  '/^Average:/ && $2==c {print $5}' "$f")
  rsoft=$(awk '/^Average:/ && $2>=9 && $2<=15 {s+=$8} END{printf "%.1f",s}' "$f")
  printf "%s,%s,%s,%.0f,%.3f,%s,%s,%s,%s,%s,%s\n" \
    "$label" "$hog" "${pps:-0}" "${mbps:-0}" "${loss:-0}" \
    "${nidle:-0}" "${nsoft:-0}" "${nsys:-0}" "${rsoft:-0}" \
    "$((sn1-sn0))" "$((drop1-drop0))" >> "$CSV"
  echo "[$label hog=$hog] pps=$pps mbps=$(printf '%.0f' ${mbps:-0}) loss=${loss}% napi_idle=${nidle}% napi_soft=${nsoft}% rps_soft=${rsoft} sn_drop+=$((sn1-sn0)) rxdrop+=$((drop1-drop0))"
}

echo "#### Track B experiment  fs=$FS dur=$DUR  NAPI_CPU=$NAPI_CPU IDLE_CPU=$IDLE_CPU rps=$RPS_MASK  $(date -u) ####" | tee "$OUT/run.log"
nsx ethtool -S $IF >/dev/null 2>&1   # warm
for hog in 0 1; do
  run_one A_single   "$NAPI_CPU" 0          "$hog"
  run_one B_trackA   "$NAPI_CPU" "$RPS_MASK" "$hog"
  run_one C_trackB   "$IDLE_CPU" 0          "$hog"
done
# restore
echo 0 > /proc/irq/$IRQ/smp_affinity_list; nsx sh -c "echo 0 > $RPS_PATH"
echo "#### DONE $(date -u) ####" | tee -a "$OUT/run.log"
echo "=== $CSV ==="; column -s, -t < "$CSV"
