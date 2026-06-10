#!/bin/bash
# trackb_cvr_sweep.sh — Rust vs vendor-C (r8125 RSS) runtime-validation sweep.
# Implements the RSS_RXHASH_IMPLEMENTATION_PLAN "Runtime Validation" matrix:
# packet sizes, flow counts, TCP/UDP TX/RX, RSS on/off, latency-under-load, and
# per-queue RX distribution — fresh-load per driver (the methodology lesson:
# never measure on a non-reloaded driver). Emits CSV + raw artifacts.
#
# Run ON the gateway as root:  sudo bash trackb_cvr_sweep.sh [out_dir]
# Drivers compared: rust4 (rss_queues=4), rust0 (rss_queues=0/RFC), vendorC.
set -u

RKO=/home/firestrand/rtl8125-rs/src/r8125_rust.ko
VKO=/home/firestrand/rtl8125-rs/references/realtek-r8125-official/src/r8125.ko
GWL=/home/firestrand/gw_loopback.sh
DUT="ip netns exec dut"; PEER="ip netns exec peer"
DEV=enp3s0; PEERDEV=enp4s0; PIP=10.0.0.1; DIP=10.0.0.2; BDF=0000:03:00.0
OUT="${1:-/tmp/cvr_sweep_$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT/raw"
CSV="$OUT/sweep.csv"
echo "driver,test,proto,dir,size,flows,gbps,retr,loss_pct,extra" > "$CSV"

log(){ printf '%s\n' "$*" | tee -a "$OUT/sweep.log"; }

peer_up(){ ip netns add peer 2>/dev/null
  ip link show $PEERDEV >/dev/null 2>&1 && ip link set $PEERDEV netns peer 2>/dev/null
  $PEER ip addr flush dev $PEERDEV 2>/dev/null; $PEER ip addr add $PIP/24 dev $PEERDEV
  $PEER ip link set $PEERDEV mtu "${1:-1500}"; $PEER ip link set $PEERDEV up; $PEER ip link set lo up
  $PEER pkill -9 iperf3 2>/dev/null; sleep 1
  $PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 1; }

load(){ # $1 = rust4|rust0|vendorC ; $2 = mtu
  $DUT ip link set $DEV netns 1 2>/dev/null
  local cur; cur=$(basename "$(readlink /sys/bus/pci/devices/$BDF/driver 2>/dev/null)" 2>/dev/null)
  [ -n "$cur" ] && echo $BDF > /sys/bus/pci/devices/$BDF/driver/unbind 2>/dev/null
  rmmod r8125_rust 2>/dev/null; rmmod r8125 2>/dev/null; modprobe -r r8169 2>/dev/null
  case "$1" in
    rust4) insmod $RKO rss_queues=4; ov=r8125_rust ;;
    rust0) insmod $RKO rss_queues=0; ov=r8125_rust ;;
    vendorC) insmod $VKO; ov=r8125 ;;
  esac
  echo $ov > /sys/bus/pci/devices/$BDF/driver_override 2>/dev/null
  echo $BDF > /sys/bus/pci/drivers_probe 2>/dev/null
  echo "" > /sys/bus/pci/devices/$BDF/driver_override 2>/dev/null
  sleep 3
  ip netns add dut 2>/dev/null; ip link set $DEV netns dut 2>/dev/null
  $DUT ip addr add $DIP/24 dev $DEV 2>/dev/null; $DUT ip link set $DEV mtu "${2:-1500}"; $DUT ip link set $DEV up; $DUT ip link set lo up
  for i in $(seq 1 12); do [ "$($DUT cat /sys/class/net/$DEV/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done
}

# tcp TX/RX: $1 driver $2 dir(tx|rx) $3 flows. JSON parse (unambiguous): the
# text receiver line has no Retr column, so the old awk `$9` recorded the literal
# "receiver" in the retr field. retransmits are always on the SENDER side
# (`sum_sent.retransmits`); throughput is the direction's rate (sum_received for
# -R, sum_sent for TX).
tcp(){ local drv=$1 dir=$2 fl=$3 rflag="" rate=sum_sent
  [ "$dir" = rx ] && { rflag="-R"; rate=sum_received; }
  local j; j=$(timeout 25 $DUT iperf3 -c $PIP -p 5201 -P "$fl" -t8 $rflag -J 2>/dev/null)
  local g r
  g=$(echo "$j" | jq -r "(.end.${rate}.bits_per_second//0)/1e9" 2>/dev/null)
  r=$(echo "$j" | jq -r '.end.sum_sent.retransmits//0' 2>/dev/null)
  g=$(printf '%.2f' "${g:-0}" 2>/dev/null)
  echo "$drv,tcp_$dir,tcp,$dir,1500,$fl,${g:-0},${r:-0},," >> "$CSV"
  log "  $drv tcp $dir flows=$fl: ${g:-0} Gbit retr=${r:-0}"; }

# udp RX: $1 driver $2 size $3 flows. Bound the offered rate (~25% over 2.4 Gbit
# line) to measure loss without an unbounded `-b 0` flood, which intermittently
# wedges the shared peer iperf3 server and zeroes the rest of the UDP block.
# Restart the peer server first so a prior flood can't carry over.
udp(){ local drv=$1 sz=$2 fl=$3
  $PEER pkill -9 iperf3 2>/dev/null; $PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 1
  local j; j=$(timeout 20 $DUT iperf3 -c $PIP -p 5201 -u -b 3000M -l "$sz" -R -P "$fl" -t6 -J 2>/dev/null)
  local g loss; g=$(echo "$j" | jq -r '(.end.sum.bits_per_second//0)/1e9' 2>/dev/null); loss=$(echo "$j" | jq -r '.end.sum.lost_percent//0' 2>/dev/null)
  echo "$drv,udp_rx,udp,rx,$sz,$fl,${g:-0},,${loss:-0}," >> "$CSV"
  log "  $drv udp rx size=$sz flows=$fl: $(printf %.2f ${g:-0}) Gbit loss=${loss:-0}%"; }

# latency under load: ping RTT while a bulk TCP flow runs
latency(){ local drv=$1
  ( timeout 12 $DUT iperf3 -c $PIP -p 5201 -t10 >/dev/null 2>&1 ) & local bg=$!
  sleep 1
  local p; p=$(timeout 8 $DUT ping -c20 -i0.2 -W1 $PIP 2>/dev/null | awk -F'/' '/rtt|round-trip/{print $5}')
  wait $bg 2>/dev/null
  echo "$drv,latency,icmp,under_load,,1,,,,avg_rtt_ms=${p:-na}" >> "$CSV"
  log "  $drv latency under load: avg_rtt=${p:-na} ms"; }

# rx queue spread: count per-vector IRQ deltas over a multi-flow load. Uses the
# device's MSI-X irq set from sysfs so it is driver-agnostic (vendor and Rust
# name their IRQs differently).
spread(){ local drv=$1
  $PEER pkill -9 iperf3 2>/dev/null; $PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 1
  # The irq numbers ARE the filenames under msi_irqs/ (not the file contents).
  local irqs; irqs=$(ls /sys/bus/pci/devices/$BDF/msi_irqs/ 2>/dev/null)
  [ -z "$irqs" ] && irqs=$(grep -E 'r8125' /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1}')
  declare -A B; for i in $irqs; do B[$i]=$(awk -v I="$i:" '$1==I{t=0;for(c=2;c<=NF-2;c++)if($c~/^[0-9]+$/)t+=$c;print t}' /proc/interrupts); done
  ( timeout 13 $DUT iperf3 -c $PIP -p 5201 -P16 -t11 >/dev/null 2>&1 ) & local bg=$!
  sleep 11
  local active=0
  for i in $irqs; do a=$(awk -v I="$i:" '$1==I{t=0;for(c=2;c<=NF-2;c++)if($c~/^[0-9]+$/)t+=$c;print t}' /proc/interrupts); d=$((a-${B[$i]:-0})); [ "$d" -gt 500 ] && active=$((active+1)); done
  wait $bg 2>/dev/null
  echo "$drv,spread,tcp,rx,,16,,,,active_irq_vectors=$active" >> "$CSV"
  log "  $drv irq spread: $active vectors >500 irqs under 16-flow load"; }

snapshot(){ local drv=$1
  $DUT ethtool -l $DEV >"$OUT/raw/${drv}_ethtool_l.txt" 2>/dev/null
  $DUT ethtool -S $DEV >"$OUT/raw/${drv}_ethtool_S.txt" 2>/dev/null
  $DUT ethtool -x $DEV >"$OUT/raw/${drv}_ethtool_x.txt" 2>/dev/null
  grep -E 'r8125' /proc/interrupts >"$OUT/raw/${drv}_interrupts.txt" 2>/dev/null; }

# gentle single-flow warm-up: a -P8 warm-up DEGRADES the vendor C driver
# (its real parallel-stress weakness), which would wedge its later measurements;
# a single flow warms caches without that confound.
warm(){ timeout 8 $DUT iperf3 -c $PIP -p 5201 -t3 >/dev/null 2>&1 || true; }
mtu_ok(){ [ "$($DUT cat /sys/class/net/$DEV/mtu 2>/dev/null)" = "$1" ] && [ "$($PEER cat /sys/class/net/$PEERDEV/mtu 2>/dev/null)" = "$1" ]; }

sweep_driver(){ local drv=$1
  log "==== $drv : MTU 1500 ===="
  load "$drv" 1500; peer_up 1500; warm
  snapshot "$drv"
  for fl in 1 10; do tcp "$drv" tx "$fl"; tcp "$drv" rx "$fl"; done
  for sz in 64 256 1024 1448; do for fl in 1 10; do udp "$drv" "$sz" "$fl"; done; done
  latency "$drv"
  spread "$drv"
  log "==== $drv : MTU 9000 (jumbo TCP) ===="
  load "$drv" 9000; peer_up 9000
  # verify BOTH ends are jumbo before measuring (the igc peer can race the first
  # MTU set; an un-applied peer MTU silently zeros jumbo TCP).
  for s in $(seq 1 8); do mtu_ok 9000 && break; $PEER ip link set $PEERDEV mtu 9000 2>/dev/null; $DUT ip link set $DEV mtu 9000 2>/dev/null; sleep 1; done
  if mtu_ok 9000; then warm; tcp "$drv" tx 1; tcp "$drv" rx 1
  else log "  $drv: MTU 9000 not applied on both ends (dut=$($DUT cat /sys/class/net/$DEV/mtu) peer=$($PEER cat /sys/class/net/$PEERDEV/mtu)); skipping jumbo"
       echo "$drv,jumbo,tcp,both,9000,1,SKIP,,,mtu_not_applied" >> "$CSV"; fi
}

log "### Track B C-vs-Rust sweep -> $OUT ###"
for d in rust4 rust0 vendorC; do sweep_driver "$d"; done
log "### restore rust4 ###"; load rust4 1500; peer_up 1500
log "### done -> $CSV ###"
echo "(end)"
