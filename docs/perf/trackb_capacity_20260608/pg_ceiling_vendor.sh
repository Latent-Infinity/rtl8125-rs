#!/bin/bash
# Vendor 4-queue RSS ceiling: pin the 4 RX-queue vectors to cpus 16-19, flood
# with pktgen on cpus 0-3, measure aggregate delivered + per-RX-cpu softirq.
set -u
DUT_MAC="$1"; DUR="${2:-12}"; LABEL="${3:-vendor}"
DEV=enp4s0; PG=/proc/net/pktgen; NTHREADS=4
modprobe pktgen 2>/dev/null
ip netns exec peer ip link set $DEV netns 1 2>/dev/null; ip link set $DEV up
for s in $(seq 1 20); do [ "$(cat /sys/class/net/$DEV/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done
# Pin RX queue vectors enp3s0-0..3 to cpus 16..19.
cpu=16
for n in 0 1 2 3; do
  q=$(grep -E "enp3s0-$n\$" /proc/interrupts | awk -F: '{gsub(/ /,"",$1);print $1}')
  [ -n "$q" ] && echo "$cpu" > /proc/irq/$q/smp_affinity_list 2>/dev/null
  cpu=$((cpu+1))
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
mpstat -P ALL 1 "$DUR" > "/tmp/pgcv_${LABEL}.txt" 2>/dev/null & MP=$!
( echo start > "$PG/pgctrl" ) & PGPID=$!
sleep "$DUR"; echo stop > "$PG/pgctrl" 2>/dev/null
wait $PGPID 2>/dev/null; wait $MP 2>/dev/null
rxa=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $3}' /proc/net/dev)
dropa=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $6}' /proc/net/dev)
off=0; for i in $(seq 0 $((NTHREADS-1))); do p=$(grep -oE '[0-9]+pps' "$PG/${DEV}@${i}" 2>/dev/null|grep -oE '[0-9]+'|head -1); off=$((off+${p:-0})); done
deliv=$(( (rxa-rxb)/DUR )); drops=$(( (dropa-dropb)/DUR ))
# per-RX-cpu (16-19) soft
read s16 s17 s18 s19 < <(awk '/^Average:/ && $2>=16 && $2<=19 {a[$2]=$8} END{printf "%.0f %.0f %.0f %.0f",a[16],a[17],a[18],a[19]}' "/tmp/pgcv_${LABEL}.txt")
echo "[$LABEL] offered=${off} delivered=${deliv} drops=${drops}/s | RX-cpu soft%: c16=$s16 c17=$s17 c18=$s18 c19=$s19"
