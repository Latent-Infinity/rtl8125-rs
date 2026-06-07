#!/bin/bash
# Orchestrate the full C-vs-Rust matrix on the gw_loopback rig, both drivers,
# end-to-end, as a single root background job. Run: sudo nohup bash gw_bench_all.sh &
set -uo pipefail
GWL=/home/firestrand/gw_loopback.sh
BENCH=/home/firestrand/gw_bench.sh
RESROOT=/home/firestrand/bench_results
REP="${1:-3}"; T="${2:-8}"
mkdir -p "$RESROOT"
TOP="$RESROOT/run_all.log"; : > "$TOP"
log(){ echo "[$(date -u +%T)] $*" | tee -a "$TOP"; }

peer_servers(){
  ip netns exec peer ip addr add fd00:0:0:1::1/64 dev enp4s0 2>/dev/null
  ip netns exec peer ip link set enp4s0 up
  ip netns exec peer pkill -f 'iperf3 -s' 2>/dev/null; sleep 1
  ip netns exec peer bash -c "setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &"
  ip netns exec peer pkill -f 'sockperf server' 2>/dev/null; sleep 1
  ip netns exec peer bash -c "setsid sockperf server -i 10.0.0.1 -p 11111 >/dev/null 2>&1 </dev/null &"
  ip netns exec peer pkill -f 'netserver' 2>/dev/null
  ip netns exec peer bash -c "setsid netserver -p 12865 >/dev/null 2>&1 </dev/null &"
  sleep 1
  log "peer servers: iperf3=$(ip netns exec peer pgrep -c iperf3) sockperf=$(ip netns exec peer pgrep -fc 'sockperf server') netserver=$(ip netns exec peer pgrep -c netserver)"
}

log "=== FULL MATRIX START kernel=$(uname -r) REP=$REP T=$T ==="
bash "$GWL" setup >>"$TOP" 2>&1
peer_servers

# 1) baseline C — the C driver never changes, so re-running it every matrix is
# ~19 min wasted. RUN_C=1 (default when no cached baseline exists) captures it;
# RUN_C=0 reuses the pinned $RESROOT/c_r8169 reference. Re-capture (RUN_C=1)
# only when the kernel or rig changes. Auto-forces capture if no baseline yet.
if [ ! -f "$RESROOT/c_r8169/throughput.csv" ]; then RUN_C=1; fi
if [ "${RUN_C:-1}" = 1 ]; then
  log "--- load r8169 (baseline C) ---"
  bash "$GWL" dut r8169 >>"$TOP" 2>&1
  peer_servers
  log "r8169 link: $(ip netns exec dut ethtool enp3s0 2>/dev/null|awk '/Speed:/{print $2}') carrier=$(ip netns exec dut cat /sys/class/net/enp3s0/carrier 2>/dev/null)"
  bash "$BENCH" c_r8169 "$REP" "$T" >>"$TOP" 2>&1
  log "r8169 bench complete"
else
  log "--- SKIP r8169 (RUN_C=0): reusing cached baseline $RESROOT/c_r8169 ---"
fi

# 2) Rust under test (default byte_budget)
log "--- load r8125_rust (Rust under test, default byte_budget) ---"
bash "$GWL" dut rust >>"$TOP" 2>&1
peer_servers
log "rust srcv=$(cat /sys/module/r8125_rust/srcversion 2>/dev/null) link: $(ip netns exec dut ethtool enp3s0 2>/dev/null|awk '/Speed:/{print $2}') carrier=$(ip netns exec dut cat /sys/class/net/enp3s0/carrier 2>/dev/null)"
bash "$BENCH" rust "$REP" "$T" >>"$TOP" 2>&1
log "rust bench complete"

log "=== FULL MATRIX DONE ==="
touch "$RESROOT/ALL_DONE"
