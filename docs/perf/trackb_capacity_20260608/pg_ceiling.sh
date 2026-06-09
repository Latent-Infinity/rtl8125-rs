#!/bin/bash
# Find the DUT single-RX-queue ceiling: pin rx0 IRQ to an isolated CPU, flood
# with pktgen on CPUs 0-3, and read THAT cpu's softirq% (= pure RX NAPI cost).
set -u
DUT_MAC="$1"; DUR="${2:-12}"; NAPI_CPU="${3:-16}"; LABEL="${4:-run}"
DEV=enp4s0; PG=/proc/net/pktgen; NTHREADS=4
modprobe pktgen 2>/dev/null
ip netns exec peer ip link set $DEV netns 1 2>/dev/null
ip link set $DEV up
for s in $(seq 1 20); do [ "$(cat /sys/class/net/$DEV/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done
# Pin every DUT NIC IRQ to NAPI_CPU so all RX/TX/link NAPI lands there.
for q in $(grep -iE 'r8125_rust|r8125|0000:03:00' /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1}'); do
  echo "$NAPI_CPU" > /proc/irq/$q/smp_affinity_list 2>/dev/null
done
for t in $(ls $PG | grep kpktgend); do echo "rem_device_all" > "$PG/$t" 2>/dev/null; done
for i in $(seq 0 $((NTHREADS-1))); do
  echo "add_device ${DEV}@${i}" > "$PG/kpktgend_${i}" 2>/dev/null
  D="$PG/${DEV}@${i}"
  { echo "count 0"; echo "clone_skb 100000"; echo "pkt_size 60";
    echo "dst 10.0.0.2"; echo "dst_mac $DUT_MAC";
    echo "flag UDPSRC_RND"; echo "flag IPSRC_RND"; echo "src_min 10.0.1.1"; echo "src_max 10.0.1.250"; echo "udp_src_min 1024"; echo "udp_src_max 65000";
    echo "queue_map_min $i"; echo "queue_map_max $i"; } > "$D" 2>/dev/null
done
rxb=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $3}' /proc/net/dev)
dropb=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $6}' /proc/net/dev)
i68b=$(awk -v I="68:" '$1==I{for(i=2;i<=NF-2;i++)if($i~/^[0-9]+$/)s+=$i;print s}' /proc/interrupts)
mpstat -P ALL 1 "$DUR" > "/tmp/pgc_${LABEL}.txt" 2>/dev/null & MP=$!
( echo start > "$PG/pgctrl" ) & PGPID=$!
sleep "$DUR"; echo stop > "$PG/pgctrl" 2>/dev/null
wait $PGPID 2>/dev/null; wait $MP 2>/dev/null
rxa=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $3}' /proc/net/dev)
dropa=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $6}' /proc/net/dev)
i68a=$(awk -v I="68:" '$1==I{for(i=2;i<=NF-2;i++)if($i~/^[0-9]+$/)s+=$i;print s}' /proc/interrupts)
off=0; for i in $(seq 0 $((NTHREADS-1))); do p=$(grep -oE '[0-9]+pps' "$PG/${DEV}@${i}" 2>/dev/null|grep -oE '[0-9]+'|head -1); off=$((off+${p:-0})); done
deliv=$(( (rxa-rxb)/DUR )); drops=$(( (dropa-dropb)/DUR ))
# NAPI cpu soft/sys/idle from mpstat Average
read nsoft nsys nidle < <(awk -v c=$NAPI_CPU '/^Average:/ && $2==c {printf "%.1f %.1f %.1f",$8,$5,$12}' "/tmp/pgc_${LABEL}.txt")
echo "[$LABEL] offered=${off} delivered=${deliv} drops=${drops}/s rx0_irq68=$(( (i68a-i68b)/DUR ))/s | NAPI cpu$NAPI_CPU soft=${nsoft}% sys=${nsys}% idle=${nidle}%"
