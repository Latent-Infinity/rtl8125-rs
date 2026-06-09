#!/bin/bash
# pktgen 64B RX flood at the DUT; measure delivered RX ceiling + CPU saturation.
set -u
DUT_MAC="$1"; DUR="${2:-12}"; NTHREADS="${3:-4}"; LABEL="${4:-run}"
DEV=enp4s0; PG=/proc/net/pktgen
modprobe pktgen 2>/dev/null
# Ensure peer NIC is in root ns (pktgen is init_net only) + link up.
ip netns exec peer ip link set $DEV netns 1 2>/dev/null
ip link set $DEV up
for s in $(seq 1 20); do [ "$(cat /sys/class/net/$DEV/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done
car=$(cat /sys/class/net/$DEV/carrier 2>/dev/null)
for t in $(ls $PG | grep kpktgend); do echo "rem_device_all" > "$PG/$t" 2>/dev/null; done
for i in $(seq 0 $((NTHREADS-1))); do
  echo "add_device ${DEV}@${i}" > "$PG/kpktgend_${i}" 2>/dev/null
  D="$PG/${DEV}@${i}"
  { echo "count 0"; echo "clone_skb 1000"; echo "pkt_size 60";
    echo "dst 10.0.0.2"; echo "dst_mac $DUT_MAC";
    echo "flag UDPSRC_RND"; echo "udp_src_min 1024"; echo "udp_src_max 65000";
    echo "queue_map_min $i"; echo "queue_map_max $i"; } > "$D" 2>/dev/null
done
rxb=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $3}' /proc/net/dev)
dropb=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $6}' /proc/net/dev)
mpstat -P ALL 1 "$DUR" > "/tmp/pg_mp_${LABEL}.txt" 2>/dev/null & MP=$!
( echo start > "$PG/pgctrl" ) & PGPID=$!
sleep "$DUR"; echo stop > "$PG/pgctrl" 2>/dev/null
wait $PGPID 2>/dev/null; wait $MP 2>/dev/null
rxa=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $3}' /proc/net/dev)
dropa=$(ip netns exec dut awk -F'[: ]+' '/enp3s0:/{print $6}' /proc/net/dev)
off=0
for i in $(seq 0 $((NTHREADS-1))); do
  p=$(grep -oE '[0-9]+pps' "$PG/${DEV}@${i}" 2>/dev/null | grep -oE '[0-9]+' | head -1)
  off=$((off + ${p:-0}))
done
deliv=$(( (rxa - rxb) / DUR )); drops=$(( (dropa - dropb) / DUR ))
read ncpu peak < <(awk '/^Average:/ && $2 ~ /^[0-9]+$/ {if($8>5)n++; if($8>mx)mx=$8} END{printf "%d %.1f",n+0,mx+0}' "/tmp/pg_mp_${LABEL}.txt")
echo "[$LABEL] carrier=$car threads=$NTHREADS offered=${off}pps delivered=${deliv}pps drops=${drops}/s | softirq>5%_cpus=$ncpu peak_soft=${peak}%"
