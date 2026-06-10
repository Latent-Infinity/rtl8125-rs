#!/bin/bash
# cvr_stat_sweep.sh — statistically honest Rust vs in-tree(r8169) vs vendor(r8125)
# comparison sweep. Supersedes the single-sample trackb_cvr_sweep.sh: every point
# is sampled N times and reported as median/min/max, and retransmit-style metrics
# are reported as a SPIKE RATE (fraction of runs over a threshold), because
# iperf3 retransmits on this rig are bursty peer/TCP noise with zero NIC drops —
# a single sample once produced a false "vendor C beats Rust on 10-flow RX"
# (see docs/perf + memory tcp-retransmit-rig-noise). Fresh-load per driver.
#
# Run ON the gateway as root:  sudo bash cvr_stat_sweep.sh [out_dir]
# Drivers: rust4 (rss_queues=4), rust0 (rss_queues=0/RFC), r8169 (in-tree), vendorC.
set -u

# median/min/max of stdin numbers -> "median min max". Pure function (no root, no
# device): unit-tested via `--selftest` so a stats bug can't silently fabricate a
# driver "gap" (the class of error that produced every false alarm in this rig).
stats(){ awk '{a[NR]=$1} END{ if(NR==0){print "0 0 0";exit}
  n=asort(a); mn=a[1]; mx=a[n];
  if(n%2)md=a[(n+1)/2]; else md=(a[n/2]+a[n/2+1])/2;
  printf "%.2f %.2f %.2f\n", md, mn, mx }'; }

# Host self-test of the stats helper + spike-count logic. Runs anywhere with gawk;
# no hardware needed. Used by ci/check_sweep_stats.sh.
selftest(){ local fail=0 got
  chk(){ [ "$2" = "$3" ] && echo "  PASS $1" || { echo "  FAIL $1: want '$3' got '$2'"; fail=1; }; }
  got=$(printf '2\n4\n1\n3\n5\n' | stats);                 chk "odd median/min/max" "$got" "3.00 1.00 5.00"
  got=$(printf '10\n20\n30\n40\n' | stats);                chk "even median"        "$got" "25.00 10.00 40.00"
  got=$(printf '2.35\n' | stats);                          chk "single value"      "$got" "2.35 2.35 2.35"
  got=$(printf '' | stats);                                chk "empty -> zeros"    "$got" "0 0 0"
  got=$(printf '2.36\n2.34\n2.35\n' | stats | cut -d' ' -f1); chk "gbps median"     "$got" "2.35"
  # spike count: retr values, threshold 100 -> expect 2 over
  local sp=0 r; for r in 0 4757 0 899 0; do [ "$r" -gt 100 ] && sp=$((sp+1)); done
  chk "spike count >100" "$sp" "2"
  [ "$fail" = 0 ] && { echo "ALL PASS"; return 0; } || { echo "SELFTEST FAILED"; return 1; }; }

[ "${1:-}" = "--selftest" ] && { selftest; exit $?; }

RKO=/home/firestrand/rtl8125-rs/src/r8125_rust.ko
VKO=/home/firestrand/rtl8125-rs/references/realtek-r8125-official/src/r8125.ko
DUT="ip netns exec dut"; PEER="ip netns exec peer"
DEV=enp3s0; PEERDEV=enp4s0; PIP=10.0.0.1; DIP=10.0.0.2; BDF=0000:03:00.0
OUT="${1:-/tmp/cvr_stat_$(date -u +%Y%m%dT%H%M%SZ)}"
N="${N:-5}"          # samples per throughput/latency point
NRETR="${NRETR:-12}" # samples for the bursty retransmit point
SPIKE="${SPIKE:-100}" # retr above this counts as a spike
mkdir -p "$OUT/raw"
CSV="$OUT/sweep.csv"
echo "driver,test,proto,dir,size,flows,metric,median,min,max,n,extra" > "$CSV"
log(){ printf '%s\n' "$*" | tee -a "$OUT/sweep.log"; }

peer_up(){ ip netns add peer 2>/dev/null
  ip link show $PEERDEV >/dev/null 2>&1 && ip link set $PEERDEV netns peer 2>/dev/null
  $PEER ip addr flush dev $PEERDEV 2>/dev/null; $PEER ip addr add $PIP/24 dev $PEERDEV
  $PEER ip link set $PEERDEV mtu "${1:-1500}"; $PEER ip link set $PEERDEV up; $PEER ip link set lo up
  $PEER pkill -9 iperf3 2>/dev/null; sleep 1
  $PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 1; }

peer_restart(){ $PEER pkill -9 iperf3 2>/dev/null; $PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 1; }

load(){ # $1 = rust4|rust0|r8169|vendorC ; $2 = mtu
  $DUT ip link set $DEV netns 1 2>/dev/null
  local cur; cur=$(basename "$(readlink /sys/bus/pci/devices/$BDF/driver 2>/dev/null)" 2>/dev/null)
  [ -n "$cur" ] && echo $BDF > /sys/bus/pci/devices/$BDF/driver/unbind 2>/dev/null
  rmmod r8125_rust 2>/dev/null; rmmod r8125 2>/dev/null; modprobe -r r8169 2>/dev/null
  local ov
  case "$1" in
    rust4) insmod $RKO rss_queues=4; ov=r8125_rust ;;
    rust0) insmod $RKO rss_queues=0; ov=r8125_rust ;;
    r8169) modprobe r8169; ov=r8169 ;;
    vendorC) insmod $VKO; ov=r8125 ;;
  esac
  echo $ov > /sys/bus/pci/devices/$BDF/driver_override 2>/dev/null
  echo $BDF > /sys/bus/pci/drivers_probe 2>/dev/null
  echo "" > /sys/bus/pci/devices/$BDF/driver_override 2>/dev/null
  sleep 3
  ip netns add dut 2>/dev/null; ip link set $DEV netns dut 2>/dev/null
  $DUT ip addr add $DIP/24 dev $DEV 2>/dev/null; $DUT ip link set $DEV mtu "${2:-1500}"; $DUT ip link set $DEV up; $DUT ip link set lo up
  local i; for i in $(seq 1 15); do [ "$($DUT cat /sys/class/net/$DEV/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done
}

warm(){ timeout 8 $DUT iperf3 -c $PIP -p 5201 -t3 >/dev/null 2>&1 || true; }
mtu_ok(){ [ "$($DUT cat /sys/class/net/$DEV/mtu 2>/dev/null)" = "$1" ] && [ "$($PEER cat /sys/class/net/$PEERDEV/mtu 2>/dev/null)" = "$1" ]; }

# TCP point: N samples; emit median gbps AND retr spike-rate. $1 drv $2 dir $3 flows $4 nsamp
# The peer iperf3 server is restarted before EVERY sample (same as udp()): a prior
# run's lingering server state otherwise injects phantom TX retransmits that look
# like a driver gap but are pure harness artifact (verified 2026-06-10: rust0 TX
# 10-flow went 4/5 "spikes" -> 0/12 once the peer was restarted per sample).
tcp(){ local drv=$1 dir=$2 fl=$3 ns=$4 rflag="" rate=sum_sent
  [ "$dir" = rx ] && { rflag="-R"; rate=sum_received; }
  local gs="" rs="" spikes=0 k j g r
  for k in $(seq 1 "$ns"); do
    peer_restart
    j=$(timeout 25 $DUT iperf3 -c $PIP -p 5201 -P "$fl" -t8 $rflag -J 2>/dev/null)
    g=$(echo "$j" | jq -r "(.end.${rate}.bits_per_second//0)/1e9" 2>/dev/null)
    r=$(echo "$j" | jq -r '.end.sum_sent.retransmits//0' 2>/dev/null)
    gs+="${g:-0}"$'\n'; rs+="${r:-0}"$'\n'
    [ "${r:-0}" -gt "$SPIKE" ] && spikes=$((spikes+1))
  done
  local st; st=$(printf '%s' "$gs" | stats); local rst; rst=$(printf '%s' "$rs" | stats)
  read -r gmd gmn gmx <<<"$st"; read -r rmd rmn rmx <<<"$rst"
  echo "$drv,tcp_$dir,tcp,$dir,1500,$fl,gbps,$gmd,$gmn,$gmx,$ns," >> "$CSV"
  echo "$drv,tcp_$dir,tcp,$dir,1500,$fl,retr,$rmd,$rmn,$rmx,$ns,spikes=${spikes}/${ns}" >> "$CSV"
  log "  $drv tcp $dir fl=$fl: gbps med=$gmd [$gmn-$gmx]  retr med=$rmd max=$rmx spikes=${spikes}/${ns}"; }

# UDP RX: N samples median gbps+loss. $1 drv $2 size $3 flows $4 nsamp
udp(){ local drv=$1 sz=$2 fl=$3 ns=$4; local gs="" ls="" k j g l
  for k in $(seq 1 "$ns"); do peer_restart
    j=$(timeout 20 $DUT iperf3 -c $PIP -p 5201 -u -b 3000M -l "$sz" -R -P "$fl" -t6 -J 2>/dev/null)
    g=$(echo "$j" | jq -r '(.end.sum.bits_per_second//0)/1e9' 2>/dev/null); l=$(echo "$j" | jq -r '.end.sum.lost_percent//0' 2>/dev/null)
    gs+="${g:-0}"$'\n'; ls+="${l:-0}"$'\n'
  done
  local st; st=$(printf '%s' "$gs" | stats); read -r gmd gmn gmx <<<"$st"
  local lmd; lmd=$(printf '%s' "$ls" | stats | awk '{print $1}')
  echo "$drv,udp_rx,udp,rx,$sz,$fl,gbps,$gmd,$gmn,$gmx,$ns,loss_med=$lmd" >> "$CSV"
  log "  $drv udp rx sz=$sz fl=$fl: gbps med=$gmd [$gmn-$gmx] loss_med=$lmd%"; }

# latency under load: N samples, median avg-RTT (lower=better -> a real win axis)
latency(){ local drv=$1 ns=$2; local ps="" k bg p
  for k in $(seq 1 "$ns"); do
    peer_restart
    ( timeout 12 $DUT iperf3 -c $PIP -p 5201 -t10 >/dev/null 2>&1 ) & bg=$!
    sleep 1
    p=$(timeout 8 $DUT ping -c20 -i0.2 -W1 $PIP 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
    wait $bg 2>/dev/null; ps+="${p:-0}"$'\n'
  done
  local st; st=$(printf '%s' "$ps" | stats); read -r md mn mx <<<"$st"
  echo "$drv,latency,icmp,under_load,,1,avg_rtt_ms,$md,$mn,$mx,$ns," >> "$CSV"
  log "  $drv latency under load: avg_rtt med=$md ms [$mn-$mx]"; }

# RX queue spread under 16-flow load (driver-agnostic via msi_irqs)
spread(){ local drv=$1; peer_restart
  local irqs; irqs=$(ls /sys/bus/pci/devices/$BDF/msi_irqs/ 2>/dev/null)
  [ -z "$irqs" ] && irqs=$(grep -E 'r8125|r8169|enp3s0' /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1}')
  declare -A B; local i; for i in $irqs; do B[$i]=$(awk -v I="$i:" '$1==I{t=0;for(c=2;c<=NF-2;c++)if($c~/^[0-9]+$/)t+=$c;print t}' /proc/interrupts); done
  ( timeout 13 $DUT iperf3 -c $PIP -p 5201 -P16 -t11 >/dev/null 2>&1 ) & local bg=$!
  sleep 11
  local active=0 a d; for i in $irqs; do a=$(awk -v I="$i:" '$1==I{t=0;for(c=2;c<=NF-2;c++)if($c~/^[0-9]+$/)t+=$c;print t}' /proc/interrupts); d=$((a-${B[$i]:-0})); [ "$d" -gt 500 ] && active=$((active+1)); done
  wait $bg 2>/dev/null
  echo "$drv,spread,tcp,rx,,16,active_vectors,$active,$active,$active,1," >> "$CSV"
  log "  $drv irq spread: $active vectors >500 irqs under 16-flow load"; }

# sustained parallel stress: repeated -P16 bursts; report worst gbps + total retr
# + dmesg fault delta (this is where vendor C historically degrades/fails).
stress(){ local drv=$1 rounds="${2:-6}"; peer_restart
  local d0; d0=$(dmesg | grep -icE 'warn|error|timeout|hang|reset|fault' 2>/dev/null)
  local worst=99 totr=0 k j g r
  for k in $(seq 1 "$rounds"); do
    j=$(timeout 20 $DUT iperf3 -c $PIP -p 5201 -P16 -t6 -J 2>/dev/null)
    g=$(echo "$j" | jq -r '(.end.sum_sent.bits_per_second//0)/1e9' 2>/dev/null)
    r=$(echo "$j" | jq -r '.end.sum_sent.retransmits//0' 2>/dev/null)
    awk "BEGIN{exit !(${g:-0} < $worst)}" && worst=${g:-0}
    totr=$((totr + ${r:-0}))
  done
  local d1; d1=$(dmesg | grep -icE 'warn|error|timeout|hang|reset|fault' 2>/dev/null)
  echo "$drv,stress,tcp,tx,1500,16,worst_gbps,$worst,$worst,$worst,$rounds,total_retr=${totr};dmesg_faults=+$((d1-d0))" >> "$CSV"
  log "  $drv sustained -P16 x$rounds: worst=$worst Gbit total_retr=$totr dmesg_faults=+$((d1-d0))"; }

snapshot(){ local drv=$1
  $DUT ethtool -l $DEV >"$OUT/raw/${drv}_ethtool_l.txt" 2>/dev/null
  $DUT ethtool -S $DEV >"$OUT/raw/${drv}_ethtool_S.txt" 2>/dev/null
  $DUT ethtool -x $DEV >"$OUT/raw/${drv}_ethtool_x.txt" 2>/dev/null
  grep -E 'r8125|r8169|enp3s0' /proc/interrupts >"$OUT/raw/${drv}_interrupts.txt" 2>/dev/null; }

sweep_driver(){ local drv=$1
  log "==== $drv : MTU 1500 (N=$N, retr N=$NRETR) ===="
  load "$drv" 1500; peer_up 1500; warm; snapshot "$drv"
  tcp "$drv" tx 1 "$N"; tcp "$drv" rx 1 "$N"
  tcp "$drv" tx 10 "$N"
  tcp "$drv" rx 10 "$NRETR"     # the bursty point: extra samples for honest spike-rate
  udp "$drv" 1448 1 "$N"; udp "$drv" 1448 10 "$N"; udp "$drv" 64 10 "$N"
  latency "$drv" "$N"
  spread "$drv"
  stress "$drv" 6
  log "==== $drv : MTU 9000 (jumbo TCP) ===="
  load "$drv" 9000; peer_up 9000
  local s; for s in $(seq 1 8); do mtu_ok 9000 && break; $PEER ip link set $PEERDEV mtu 9000 2>/dev/null; $DUT ip link set $DEV mtu 9000 2>/dev/null; sleep 1; done
  if mtu_ok 9000; then warm; tcp "$drv" tx 1 "$N"; tcp "$drv" rx 1 "$N"
  else log "  $drv: MTU 9000 not on both ends; skipping jumbo"
       echo "$drv,jumbo,tcp,both,9000,1,gbps,SKIP,,,0,mtu_not_applied" >> "$CSV"; fi
}

log "### statistical C-vs-Rust sweep -> $OUT (N=$N NRETR=$NRETR SPIKE=$SPIKE) ###"
for d in rust4 rust0 r8169 vendorC; do sweep_driver "$d"; done
log "### restore rust4 ###"; load rust4 1500; peer_up 1500
log "### done -> $CSV ###"
echo "(end)"
