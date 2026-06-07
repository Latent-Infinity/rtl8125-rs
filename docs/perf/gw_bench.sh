#!/bin/bash
# C(r8169) vs Rust(r8125_rust) NIC benchmark on the gw_loopback netns rig.
#   DUT  : enp3s0 in ns 'dut', 10.0.0.2 / fd00:0:0:1::2   (driver under test)
#   peer : enp4s0 in ns 'peer', 10.0.0.1 / fd00:0:0:1::1  (igc; servers up)
# Client ops run via `ip netns exec dut`. /proc/{stat,interrupts,softirqs} are
# global (not ns-scoped) — read on the host; the peer igc load is constant
# across DUT drivers so CPU/IRQ deltas remain comparable between drivers.
# Usage (run as root, after the driver is loaded + ns configured):
#   gw_bench.sh <label> [reps] [secs]
set -uo pipefail
DUT_NS=dut; PEER_NS=peer; IF=enp3s0
PEER=10.0.0.1; PEER6=fd00:0:0:1::1; LINE=2.5
LABEL="${1:-driver}"; REP="${2:-3}"; T="${3:-8}"
OUT="/home/firestrand/bench_results/$LABEL"; RAW="$OUT/raw"; mkdir -p "$RAW"
DRV=$(basename "$(readlink /sys/bus/pci/devices/0000:03:00.0/driver 2>/dev/null)")
nsx(){ ip netns exec $DUT_NS "$@"; }
CSV="$OUT/throughput.csv"; LAT="$OUT/latency.csv"; PPS="$OUT/pps.csv"
echo "driver,mtu,proto,dir,offload,load_pct,run,gbps,retr,loss_pct,jitter_ms,cpu_usr,cpu_sys,cpu_soft,cpu_irq,irq_per_s" > "$CSV"
echo "driver,mtu,test,obs,p50_us,p99_us,p999_us,max_us" > "$LAT"
echo "driver,framesize,dir,pps,mbps,loss_pct" > "$PPS"

# driver IRQ count (sum across vectors)
irqcount(){ awk '/r8125_rust|enp3s0|0000:03:00/{for(i=2;i<=NF;i++)if($i ~ /^[0-9]+$/)s+=$i} END{print s+0}' /proc/interrupts; }
# /proc/stat cpu: user nice system idle iowait irq softirq steal
st(){ awk '/^cpu /{print $2,$4,$7,$8,$2+$3+$4+$5+$6+$7+$8+$9}' /proc/stat; }
split(){ local a=($1) b=($2); local du=$((${b[0]}-${a[0]})) ds=$((${b[1]}-${a[1]})) di=$((${b[2]}-${a[2]})) dsq=$((${b[3]}-${a[3]})) dt=$((${b[4]}-${a[4]})); [ "$dt" -le 0 ]&&dt=1; awk "BEGIN{printf \"%.2f,%.2f,%.2f,%.2f\",100.0*$du/$dt,100.0*$ds/$dt,100.0*$di/$dt,100.0*$dsq/$dt}"; }

apply_offload(){ nsx ethtool -K $IF gro on tso on gso on >/dev/null 2>&1
  case "$1" in
    gro-off) nsx ethtool -K $IF gro off >/dev/null 2>&1;;
    tso-off) nsx ethtool -K $IF tso off gso off >/dev/null 2>&1;;
    all-off) nsx ethtool -K $IF gro off tso off gso off >/dev/null 2>&1;;
  esac; }
set_mtu(){ nsx ip link set $IF mtu "$1"; ip netns exec $PEER_NS ip link set enp4s0 mtu "$1"; ip netns exec $PEER_NS ip link set enp4s0 up
  local i; for i in $(seq 1 25); do [ "$(nsx cat /sys/class/net/$IF/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done; sleep 2; }

# iperf cell: $1 mtu $2 proto(tcp/udp/tcp6) $3 dir(tx/rx/bidir) $4 offload $5 load%
cell(){
  local mtu="$1" proto="$2" dir="$3" off="$4" load="$5" host=$PEER args=()
  [ "$proto" = tcp6 ] && host=$PEER6
  [ "$dir" = rx ] && args+=( -R ); [ "$dir" = bidir ] && args+=( --bidir )
  if [ "$proto" = udp ]; then local bw; bw=$(awk "BEGIN{printf \"%.0f\", $LINE*1000*$load/100}"); args+=( -u -b ${bw}M -l 1448 ); fi
  local r; for r in $(seq 1 $REP); do
    local s0=$(st) i0=$(irqcount)
    local j; j=$(nsx iperf3 -c $host -p 5201 -t $T -J "${args[@]}" 2>>"$RAW/iperf_err.log")
    local s1=$(st) i1=$(irqcount)
    echo "$j" > "$RAW/${mtu}_${proto}_${dir}_${off}_${load}_${r}.json"
    local g retr loss jit irqps
    if [ "$proto" = udp ]; then
      g=$(jq -r '(.end.sum.bits_per_second // 0)/1e9' <<<"$j" 2>/dev/null); retr=0
      loss=$(jq -r '.end.sum.lost_percent // 0' <<<"$j" 2>/dev/null); jit=$(jq -r '.end.sum.jitter_ms // 0' <<<"$j" 2>/dev/null)
    else
      if [ "$dir" = bidir ]; then g=$(jq -r '((.end.sum_sent.bits_per_second+.end.sum_received.bits_per_second)//0)/1e9' <<<"$j" 2>/dev/null)
      elif [ "$dir" = rx ]; then g=$(jq -r '(.end.sum_received.bits_per_second // 0)/1e9' <<<"$j" 2>/dev/null)
      else g=$(jq -r '(.end.sum_sent.bits_per_second // 0)/1e9' <<<"$j" 2>/dev/null); fi
      retr=$(jq -r '.end.sum_sent.retransmits // 0' <<<"$j" 2>/dev/null); loss=0; jit=0
    fi
    irqps=$(awk "BEGIN{printf \"%.0f\", ($i1-$i0)/$T}")
    echo "$DRV,$mtu,$proto,$dir,$off,$load,$r,${g:-0},${retr:-0},${loss:-0},${jit:-0},$(split "$s0" "$s1"),${irqps:-0}" >> "$CSV"
  done
}

# sockperf ping-pong latency percentiles (full RTT, us). $2=idle|loaded
lat_sp(){
  local mtu="$1" load="${2:-idle}" bg=""
  if [ "$load" = loaded ]; then ( nsx iperf3 -c $PEER -p 5201 -t 16 >/dev/null 2>&1 ) & bg=$!; sleep 1; fi
  local o; o=$(nsx sockperf ping-pong -i $PEER -p 11111 -t 12 --full-rtt 2>/dev/null)
  echo "$o" > "$RAW/sockperf_${mtu}_${load}.txt"
  [ -n "$bg" ] && wait $bg 2>/dev/null
  local p50 p99 p999 mx obs
  p50=$(grep -oP 'percentile 50\.000\s*=\s*\K[0-9.]+' <<<"$o" | head -1)
  p99=$(grep -oP 'percentile 99\.000\s*=\s*\K[0-9.]+' <<<"$o" | head -1)
  p999=$(grep -oP 'percentile 99\.900\s*=\s*\K[0-9.]+' <<<"$o" | head -1)
  mx=$(grep -oP '<MAX>\s*=\s*\K[0-9.]+' <<<"$o" | head -1)
  obs=$(grep -oP 'Total\s+\K[0-9]+(?=\s+observations)' <<<"$o" | head -1)
  echo "$DRV,$mtu,sockperf-rtt-$load,${obs:-0},${p50:-0},${p99:-0},${p999:-0},${mx:-0}" >> "$LAT"
  # ICMP loaded RTT for continuity with prior docs
  if [ "$load" = loaded ]; then
    local bg2; ( nsx iperf3 -c $PEER -p 5201 -t 12 >/dev/null 2>&1 ) & bg2=$!; sleep 1
    nsx ping -c 6000 -i 0.001 -n $PEER 2>/dev/null | grep -oP 'time=\K[0-9.]+' | sort -n > "$RAW/ping_${mtu}_loaded.txt"
    wait $bg2 2>/dev/null
    local f="$RAW/ping_${mtu}_loaded.txt" n; n=$(wc -l < "$f")
    if [ "${n:-0}" -gt 0 ]; then local i5=$((n*50/100)) i9=$((n*99/100)) i99=$((n*999/1000)); [ $i5 -lt 1 ]&&i5=1;[ $i9 -lt 1 ]&&i9=1;[ $i99 -lt 1 ]&&i99=1
      echo "$DRV,$mtu,icmp-rtt-loaded,$n,$(awk -v k=$i5 'NR==k{printf "%.1f",$1*1000}' "$f"),$(awk -v k=$i9 'NR==k{printf "%.1f",$1*1000}' "$f"),$(awk -v k=$i99 'NR==k{printf "%.1f",$1*1000}' "$f"),$(awk 'END{printf "%.1f",$1*1000}' "$f")" >> "$LAT"; fi
  fi
}

pps(){ # small-frame PPS, both dirs. $1 framesize $2 dir(tx/rx)
  # MULTI-FLOW (-P 10) + MEDIAN-of-3. The old single-flow `-b 0` form was
  # single-core-bound and wildly noisy (phantom 0s + 2x swings between runs);
  # 10 flows spread the per-packet cost across cores so the number reflects the
  # device, and median-of-3 rejects the occasional outlier run.
  local fs="$1" dir="$2" rev=""; [ "$dir" = rx ] && rev="-R"
  local r j pkts secs p; local -a pvals=() mbvals=() lossvals=()
  for r in 1 2 3; do
    j=$(nsx iperf3 -c $PEER -p 5201 -u -b 0 -l $fs $rev -P 10 -t 3 -J 2>>"$RAW/iperf_err.log")
    [ "$r" = 2 ] && echo "$j" > "$RAW/pps_${fs}_${dir}.json"
    pkts=$(jq -r '.end.sum.packets // 0' <<<"$j" 2>/dev/null); secs=$(jq -r '.end.sum.seconds // 1' <<<"$j" 2>/dev/null)
    p=$(awk "BEGIN{printf \"%.0f\", ($secs+0)?($pkts+0)/($secs):0}")
    pvals+=("${p:-0}")
    mbvals+=("$(jq -r '(.end.sum.bits_per_second // 0)/1e6' <<<"$j" 2>/dev/null)")
    lossvals+=("$(jq -r '.end.sum.lost_percent // 0' <<<"$j" 2>/dev/null)")
  done
  local med_p med_mb med_loss
  med_p=$(printf '%s\n' "${pvals[@]}" | sort -n | sed -n 2p)
  med_mb=$(printf '%s\n' "${mbvals[@]}" | sort -n | sed -n 2p)
  med_loss=$(printf '%s\n' "${lossvals[@]}" | sort -n | sed -n 2p)
  echo "$DRV,$fs,$dir,${med_p:-0},$(printf '%.0f' "${med_mb:-0}"),${med_loss:-0}" >> "$PPS"
}

vlan_cell(){ # HW VLAN-offload throughput (TX insert + RX strip) over a tagged iface
  local vid=100 dip=10.0.100.2 pip=10.0.100.1 tx rx
  nsx ip link add link $IF name vbench type vlan id $vid 2>/dev/null
  nsx ip addr add $dip/24 dev vbench 2>/dev/null; nsx ip link set vbench up
  ip netns exec $PEER_NS ip link add link enp4s0 name vbench type vlan id $vid 2>/dev/null
  ip netns exec $PEER_NS ip addr add $pip/24 dev vbench 2>/dev/null; ip netns exec $PEER_NS ip link set vbench up
  sleep 2
  tx=$(nsx iperf3 -c $pip -p 5201 -t $T 2>/dev/null | grep -E 'sender' | awk '{print $7}')
  rx=$(nsx iperf3 -c $pip -p 5201 -t $T -R 2>/dev/null | grep -E 'receiver' | awk '{print $7}')
  echo "$DRV,1500,vlan-tcp,tx,hwvlan,100,1,${tx:-0},0,0,0,0,0,0,0,0" >> "$CSV"
  echo "$DRV,1500,vlan-tcp,rx,hwvlan,100,1,${rx:-0},0,0,0,0,0,0,0,0" >> "$CSV"
  nsx ip link del vbench 2>/dev/null; ip netns exec $PEER_NS ip link del vbench 2>/dev/null
}

echo "######## BENCH [$LABEL] driver=$DRV $(date -u) ########" | tee "$OUT/run.log"
nsx ip -6 addr add fd00:0:0:1::2/64 dev $IF 2>/dev/null
nsx ethtool -k $IF > "$RAW/ethtool_k_before.txt" 2>&1
nsx ethtool -S $IF > "$RAW/ethtool_S_before.txt" 2>&1

for mtu in 1500 9000; do
  set_mtu $mtu
  nsx ip -6 addr add fd00:0:0:1::2/64 dev $IF 2>/dev/null
  echo "== MTU $mtu carrier=$(nsx cat /sys/class/net/$IF/carrier) speed=$(nsx ethtool $IF 2>/dev/null|awk '/Speed:/{print $2}') ==" | tee -a "$OUT/run.log"
  for dir in tx rx bidir; do cell $mtu tcp $dir default 100; done
  cell $mtu tcp6 tx default 100; cell $mtu tcp6 rx default 100
  cell $mtu udp tx default 100; cell $mtu udp rx default 100
  for off in gro-off tso-off all-off; do apply_offload $off; for dir in tx rx; do cell $mtu tcp $dir $off 100; done; done
  apply_offload default
  for load in 25 50 75; do cell $mtu udp tx default $load; cell $mtu udp rx default $load; done
  lat_sp $mtu idle
  lat_sp $mtu loaded
  echo "  MTU $mtu done $(date -u +%T)" | tee -a "$OUT/run.log"
done
set_mtu 1500
for fs in 64 128 256 512 1024 1448; do pps $fs tx; pps $fs rx; done
vlan_cell

nsx ethtool -S $IF > "$RAW/ethtool_S_after.txt" 2>&1
echo "######## DONE [$LABEL] $(date -u) rows tp=$(($(wc -l<"$CSV")-1)) lat=$(($(wc -l<"$LAT")-1)) pps=$(($(wc -l<"$PPS")-1)) ########" | tee -a "$OUT/run.log"
