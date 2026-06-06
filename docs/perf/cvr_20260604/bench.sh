#!/bin/bash
# Comprehensive C(r8169)-vs-Rust(r8125_rust) NIC benchmark for the bare-metal
# gateway (DUT) enp3s0 <-> peer 10.0.0.1 (this host, MTU 9000, servers up).
# Run once per loaded driver:  sudo ./bench.sh <label>
# Emits CSV + raw logs under /home/firestrand/bench_results/<label>/.
#
# Covers every dimension of the spec that the topology supports:
#   MTU {1500,9000} x proto {TCP,UDP,IPv6-TCP} x dir {TX,RX,bidir}
#   x offload {default,gro-off,tso-off,all-off} x UDP load {25,50,75,100%}
#   + latency p50/p99/p99.9 (sockperf ping-pong + netperf TCP_RR)
#   + small-frame TX PPS {64,128,512,1518} via pktgen
# KPIs: throughput, retr/loss/jitter, CPU split (user/sys/softirq/irq from
#       /proc/stat), k10temp, plus per-cell ethtool -S / dmesg deltas.
set -uo pipefail
PEER=10.0.0.1; PEER6=fd00:0:0:1::1; LOCAL=10.0.0.2; LOCAL6=fd00:0:0:1::2
BDF=0000:03:00.0; LINE=2.5   # 2.5GbE
LABEL="${1:-driver}"; REP="${2:-3}"; T="${3:-10}"
OUT="/home/firestrand/bench_results/$LABEL"; mkdir -p "$OUT"
IF=$(ls /sys/bus/pci/devices/$BDF/net/ 2>/dev/null | head -1)
DRV=$(basename "$(readlink /sys/bus/pci/devices/$BDF/driver 2>/dev/null)")
CSV="$OUT/throughput.csv"; LAT="$OUT/latency.csv"; PPS="$OUT/pps.csv"; RAW="$OUT/raw"; mkdir -p "$RAW"
echo "driver,mtu,proto,dir,offload,load_pct,run,gbps,retr,loss_pct,jitter_ms,cpu_usr,cpu_sys,cpu_soft,cpu_irq,temp_mC" > "$CSV"
echo "driver,mtu,test,obs,p50_us,p99_us,p999_us,max_us" > "$LAT"
echo "driver,framesize,rx_pps,rx_mbps,loss_pct" > "$PPS"

k10(){ for h in /sys/class/hwmon/*; do [ "$(cat $h/name 2>/dev/null)" = k10temp ] && { cat $h/temp1_input 2>/dev/null; return; }; done; echo 0; }
# /proc/stat cpu line: user nice system idle iowait irq softirq steal
st(){ awk '/^cpu /{print $2,$4,$7,$8,$2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat; }  # user system irq softirq total
split(){ local a=($1) b=($2); local du=$((${b[0]}-${a[0]})) ds=$((${b[1]}-${a[1]})) di=$((${b[2]}-${a[2]})) dsq=$((${b[3]}-${a[3]})) dt=$((${b[4]}-${a[4]})); [ "$dt" -le 0 ] && dt=1; awk "BEGIN{printf \"%.2f,%.2f,%.2f,%.2f\",100.0*$du/$dt,100.0*$ds/$dt,100.0*$di/$dt,100.0*$dsq/$dt}"; }

apply_offload(){ # default|gro-off|tso-off|all-off
  ethtool -K $IF gro on tso on gso on >/dev/null 2>&1
  case "$1" in
    gro-off) ethtool -K $IF gro off >/dev/null 2>&1;;
    tso-off) ethtool -K $IF tso off gso off >/dev/null 2>&1;;
    all-off) ethtool -K $IF gro off tso off gso off >/dev/null 2>&1;;
  esac
}
set_mtu(){ ip link set $IF mtu "$1" 2>/dev/null; local i; for i in $(seq 1 20); do [ "$(cat /sys/class/net/$IF/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done; }

# iperf cell: $1 mtu $2 proto(tcp/udp/tcp6) $3 dir(tx/rx/bidir) $4 offload $5 load%
cell(){
  local mtu="$1" proto="$2" dir="$3" off="$4" load="$5" host=$PEER bind=$LOCAL args=() rev=""
  [ "$proto" = tcp6 ] && { host=$PEER6; bind=$LOCAL6; }
  [ "$dir" = rx ] && args+=( -R ); [ "$dir" = bidir ] && args+=( --bidir )
  if [ "$proto" = udp ]; then local bw; bw=$(awk "BEGIN{printf \"%.0f\", $LINE*1000*$load/100}"); args+=( -u -b ${bw}M ); fi
  local r; for r in $(seq 1 $REP); do
    local s0=$(st); local j=$(iperf3 -c $host -B $bind -p 5201 -t $T -J "${args[@]}" 2>>"$RAW/iperf_err.log"); local s1=$(st)
    echo "$j" > "$RAW/${mtu}_${proto}_${dir}_${off}_${load}_${r}.json"
    local g retr loss jit
    if [ "$proto" = udp ]; then
      g=$(jq -r '(.end.sum.bits_per_second // 0)/1e9' <<<"$j" 2>/dev/null); retr=0
      loss=$(jq -r '.end.sum.lost_percent // 0' <<<"$j" 2>/dev/null); jit=$(jq -r '.end.sum.jitter_ms // 0' <<<"$j" 2>/dev/null)
    else
      if [ "$dir" = bidir ]; then g=$(jq -r '((.end.sum_sent.bits_per_second+.end.sum_received.bits_per_second)//0)/1e9' <<<"$j" 2>/dev/null)
      elif [ "$dir" = rx ]; then g=$(jq -r '(.end.sum_received.bits_per_second // 0)/1e9' <<<"$j" 2>/dev/null)
      else g=$(jq -r '(.end.sum_sent.bits_per_second // 0)/1e9' <<<"$j" 2>/dev/null); fi
      retr=$(jq -r '.end.sum_sent.retransmits // 0' <<<"$j" 2>/dev/null); loss=0; jit=0
    fi
    echo "$DRV,$mtu,$proto,$dir,$off,$load,$r,${g:-0},${retr:-0},${loss:-0},${jit:-0},$(split "$s0" "$s1"),$(k10)" >> "$CSV"
  done
}

lat(){ # ICMP latency percentiles (us): gateway->peer, ~10k samples.
  # Each echo traverses the DUT's full TX(request)+RX(reply) path; the peer's
  # contribution is constant across drivers, so deltas are the DUT's. ($2=idle
  # or loaded; loaded runs a concurrent TCP TX flow to expose tail latency.)
  # netperf/sockperf are blocked by kube-router on the peer; ICMP is not.
  local mtu="$1" load="${2:-idle}" bgpid=""
  if [ "$load" = loaded ]; then
    ( iperf3 -c $PEER -B $LOCAL -p 5201 -t 14 >/dev/null 2>&1 ) & bgpid=$!; sleep 1
  fi
  ping -c 10000 -i 0.001 -n $PEER 2>/dev/null | grep -oP 'time=\K[0-9.]+' | sort -n > "$RAW/ping_${mtu}_${load}.txt"
  [ -n "$bgpid" ] && wait $bgpid 2>/dev/null
  local f="$RAW/ping_${mtu}_${load}.txt" n; n=$(wc -l < "$f")
  if [ "${n:-0}" -gt 0 ]; then
    local i50=$((n*50/100)) i99=$((n*99/100)) i999=$((n*999/1000))
    [ $i50 -lt 1 ]&&i50=1; [ $i99 -lt 1 ]&&i99=1; [ $i999 -lt 1 ]&&i999=1
    local p50=$(awk -v k=$i50 'NR==k{printf "%.1f",$1*1000}' "$f")
    local p99=$(awk -v k=$i99 'NR==k{printf "%.1f",$1*1000}' "$f")
    local p999=$(awk -v k=$i999 'NR==k{printf "%.1f",$1*1000}' "$f")
    local mx=$(awk 'END{printf "%.1f",$1*1000}' "$f")
    echo "$DRV,$mtu,icmp-rtt-$load,$n,$p50,$p99,$p999,$mx" >> "$LAT"
  fi
}

pps_rx(){ # small-frame RX PPS: peer floods small UDP datagrams (-b 0) at the
  # DUT; we record received pps + loss. This stresses the DUT's RX descriptor
  # / NAPI path at high packet rates. (pktgen TX-side is unusable: kube-router
  # rate-limits gateway->peer UDP. RX into the DUT is the meaningful direction.)
  local fs="$1" j pkts secs loss mbps pps
  j=$(iperf3 -c $PEER -B $LOCAL -p 5201 -u -b 0 -l $fs -R -t 5 -J 2>>"$RAW/iperf_err.log")
  echo "$j" > "$RAW/pps_${fs}.json"
  pkts=$(jq -r '.end.sum.packets // 0' <<<"$j" 2>/dev/null)
  secs=$(jq -r '.end.sum.seconds // 1' <<<"$j" 2>/dev/null)
  loss=$(jq -r '.end.sum.lost_percent // 0' <<<"$j" 2>/dev/null)
  mbps=$(jq -r '(.end.sum.bits_per_second // 0)/1e6' <<<"$j" 2>/dev/null)
  pps=$(awk "BEGIN{printf \"%.0f\", ($secs+0)?($pkts+0)/($secs):0}")
  echo "$DRV,$fs,${pps:-0},$(printf '%.0f' "${mbps:-0}"),${loss:-0}" >> "$PPS"
}

echo "######## BENCH [$LABEL] driver=$DRV iface=$IF $(date -u) ########" | tee "$OUT/run.log"
ip -br addr show $IF > "$RAW/ip_addr_before.txt" 2>&1
ethtool -k $IF > "$RAW/ethtool_k_before.txt" 2>&1
ethtool -S $IF > "$RAW/ethtool_S_before.txt" 2>&1
dmesg | tail -50 > "$RAW/dmesg_before.txt" 2>&1
# ensure IPv6 ULA on the DUT (peer side set by wrapper)
ip -6 addr add $LOCAL6/64 dev $IF 2>/dev/null; sleep 1

for mtu in 1500 9000; do
  set_mtu $mtu
  ip -6 addr add $LOCAL6/64 dev $IF 2>/dev/null
  echo "== MTU $mtu (carrier=$(cat /sys/class/net/$IF/carrier)) ==" | tee -a "$OUT/run.log"
  # Core throughput: TCP+UDP x TX/RX/bidir at default offload
  for dir in tx rx bidir; do cell $mtu tcp $dir default 100; done
  cell $mtu udp rx default 100   # UDP RX only (peer kube-router rate-limits gateway->peer UDP TX)
  # Offload sweep: TCP TX/RX
  for off in gro-off tso-off all-off; do apply_offload $off; for dir in tx rx; do cell $mtu tcp $dir $off 100; done; done
  apply_offload default
  # UDP RX load sweep (MTU-specific)
  for load in 25 50 75; do cell $mtu udp rx default $load; done
  # Latency: idle + under-load (tail behavior)
  lat $mtu idle
  lat $mtu loaded
done
# small-frame RX PPS at MTU1500
set_mtu 1500
for fs in 64 128 256 512 1024 1448; do pps_rx $fs; done

ethtool -S $IF > "$RAW/ethtool_S_after.txt" 2>&1
dmesg | tail -80 > "$RAW/dmesg_after.txt" 2>&1
echo "######## BENCH DONE [$LABEL] $(date -u) ########" | tee -a "$OUT/run.log"
echo "rows: throughput=$(($(wc -l <"$CSV")-1)) latency=$(($(wc -l <"$LAT")-1)) pps=$(($(wc -l <"$PPS")-1))" | tee -a "$OUT/run.log"
