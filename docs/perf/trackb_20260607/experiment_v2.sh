#!/bin/bash
# Track B value: RX capacity + app-CPU coexistence for the loaded driver.
# Detects ACTIVE RX vectors (interrupt delta during warmup), pins them to cpus
# 8.., app pinned to cpu8 (shares with RX queue 0). P0 app-solo; P1 flood only;
# P2 flood + app sharing cpu8.
set -uo pipefail
DUT_NS=dut; IF=enp3s0; PEER=10.0.0.1
FS="${1:-64}"; DUR="${2:-10}"; LABEL="${3:-drv}"; RPS="${4:-0}"; APPCPU="${5:-8}"
OUT=/home/firestrand/bench_results/trackb2; mkdir -p "$OUT/raw"
CSV="$OUT/results.csv"
[ -f "$CSV" ] || echo "label,driver,appcpu,active_rx_vec,rx_cpus,app_solo_mops,p1_pps,p1_mbps,p1_loss,p1_active_softcpus,p1_peak_soft,p2_pps,p2_loss,p2_app_mops,p2_app_retain_pct,p2_peak_soft" > "$CSV"
nsx(){ ip netns exec $DUT_NS "$@"; }
DRV=$(basename "$(readlink /sys/bus/pci/devices/0000:03:00.0/driver)")
icount(){ awk -v I="$1:" '$1==I{for(i=2;i<=NF-2;i++)if($i~/^[0-9]+$/)s+=$i}END{print s+0}' /proc/interrupts; }
flood(){ nsx iperf3 -c $PEER -p 5201 -u -b 0 -l $FS -R -P 10 -t "$1" -J 2>>"$OUT/raw/err.log"; }

mapfile -t IRQS < <(grep -iE "0000:03:00" /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1}')
declare -A B; for q in "${IRQS[@]}"; do B[$q]=$(icount "$q"); done
flood 3 >/dev/null 2>&1
active=( $(for q in "${IRQS[@]}"; do a=$(icount "$q"); echo "$((a-${B[$q]})) $q"; done | sort -rn | awk '$1>2000{print $2}') )
cpu=8; rxcpus=""; for q in "${active[@]}"; do echo $cpu > /proc/irq/$q/smp_affinity_list 2>/dev/null; rxcpus="$rxcpus$cpu "; cpu=$((cpu+1)); done
NQ=${#active[@]}
for d in /sys/class/net/$IF/queues/rx-*; do nsx sh -c "echo $RPS > $d/rps_cpus" 2>/dev/null; done
sleep 1
ppsof(){ jq -r '((.end.sum.packets//0)/(.end.sum.seconds//1))' <<<"$1" 2>/dev/null; }
mbof(){  jq -r '(.end.sum.bits_per_second//0)/1e6' <<<"$1" 2>/dev/null; }
lossof(){ jq -r '.end.sum.lost_percent//0' <<<"$1" 2>/dev/null; }
softstat(){ awk '/^Average:/ && $2 ~ /^[0-9]+$/ {if($8>5)n++; if($8>mx)mx=$8} END{printf "%d %.1f",n+0,mx+0}' "$1"; }

app_solo=$(taskset -c $APPCPU /home/firestrand/app_bench $DUR)
mpstat -P ALL 1 $DUR > "$OUT/raw/mp_${LABEL}_p1.txt" 2>/dev/null & MP=$!
J1=$(flood $DUR); wait $MP 2>/dev/null
read p1n p1mx < <(softstat "$OUT/raw/mp_${LABEL}_p1.txt")
mpstat -P ALL 1 $DUR > "$OUT/raw/mp_${LABEL}_p2.txt" 2>/dev/null & MP=$!
( taskset -c $APPCPU /home/firestrand/app_bench $DUR > "$OUT/raw/app_${LABEL}.txt" ) & AP=$!
J2=$(flood $DUR); wait $MP 2>/dev/null; wait $AP 2>/dev/null
read p2n p2mx < <(softstat "$OUT/raw/mp_${LABEL}_p2.txt")
app_under=$(cat "$OUT/raw/app_${LABEL}.txt" 2>/dev/null)
p1pps=$(ppsof "$J1"); p1mb=$(mbof "$J1"); p1ls=$(lossof "$J1")
p2pps=$(ppsof "$J2"); p2ls=$(lossof "$J2")
retain=$(awk "BEGIN{printf \"%.0f\", ($app_solo>0)?100*$app_under/$app_solo:0}")
printf '%s,%s,%s,%d,%s,%s,%.0f,%.0f,%.3f,%s,%s,%.0f,%.3f,%s,%s,%s\n' \
 "$LABEL" "$DRV" "$APPCPU" "$NQ" "${rxcpus% }" "$app_solo" "${p1pps:-0}" "${p1mb:-0}" "${p1ls:-0}" "$p1n" "$p1mx" \
 "${p2pps:-0}" "${p2ls:-0}" "$app_under" "$retain" "$p2mx" >> "$CSV"
echo "[$LABEL drv=$DRV active_rx_vec=$NQ rxcpus=${rxcpus% }] solo=${app_solo}Mops | P1 pps=$(printf %.0f ${p1pps:-0}) loss=${p1ls}% softcpus=${p1n} peak=${p1mx}% | P2 pps=$(printf %.0f ${p2pps:-0}) app=${app_under}Mops retain=${retain}%"
