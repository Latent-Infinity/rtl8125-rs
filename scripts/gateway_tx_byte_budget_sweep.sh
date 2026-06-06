#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Gateway tx_byte_budget ablation sweep.
#
# Purpose:
#   Pick the production default for the driver-owned TX byte-budget throttle by
#   measuring the latency/throughput/PPS tradeoff on the authoritative Gateway
#   bare-metal topology:
#
#     enp3s0 (RTL8125 DUT, default netns, 10.0.0.2/24)
#       <-> Cat6 <->
#     enp4s0 (I226 peer, peer netns, 10.0.0.1/24)
#
# The script reloads r8125_rust once per budget/repetition so module parameters
# and debug counters start clean. It records:
#   - TCP TX throughput under load
#   - ICMP latency percentiles during that load
#   - UDP small-frame TX PPS
#   - disposition counters
#   - xmit_calls / tx_doorbells from the ndo_stop log
#
# Optional xmit_more probe:
#   XMIT_MORE_PROBE=1 runs a dedicated final workload and reports the
#   doorbell/xmit ratio. For a truly batched workload, set XMIT_MORE_CMD to a
#   local forwarding/sendmmsg command; otherwise the script uses parallel UDP
#   iperf3 as a coarse smoke.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DUT_BDF=${DUT_BDF:-0000:03:00.0}
DUT_IFACE=${DUT_IFACE:-enp3s0}
PEER_IFACE=${PEER_IFACE:-enp4s0}
PEER_NS=${PEER_NS:-peer}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
PEER_IP=${PEER_IP:-10.0.0.1}
PREFIX=${PREFIX:-24}
PORT=${PORT:-5201}
MODULE=${MODULE:-"$ROOT/src/r8125_rust.ko"}

TX_BYTE_BUDGETS=${TX_BYTE_BUDGETS:-"0 32768 65536 131072 262144 524288"}
BQL_MODE=${BQL_MODE:-1}
DEBUG_COUNTERS=${DEBUG_COUNTERS:-1}
EXTRA_MODPARAMS=${EXTRA_MODPARAMS:-}
REPS=${REPS:-3}
PING_COUNT=${PING_COUNT:-1000}
PING_INTERVAL=${PING_INTERVAL:-0.02}
LOAD_SECS=${LOAD_SECS:-}
PPS_SECS=${PPS_SECS:-8}
PPS_FRAMES=${PPS_FRAMES:-"64 128 256"}
PPS_BITRATE=${PPS_BITRATE:-3G}

XMIT_MORE_PROBE=${XMIT_MORE_PROBE:-0}
XMIT_MORE_BUDGET=${XMIT_MORE_BUDGET:-131072}
XMIT_MORE_STREAMS=${XMIT_MORE_STREAMS:-16}
XMIT_MORE_BITRATE=${XMIT_MORE_BITRATE:-250M}
XMIT_MORE_CMD=${XMIT_MORE_CMD:-}

RESTORE_DEFAULT=${RESTORE_DEFAULT:-1}
RESTORE_BUDGET=${RESTORE_BUDGET:-131072}

STAMP=$(date -u +'%Y%m%d_%H%M%S')
OUT_DIR=${OUT_DIR:-"$ROOT/docs/perf/tx_byte_budget_sweep_${STAMP}"}
RAW="$OUT_DIR/raw"
SUMMARY_CSV="$OUT_DIR/summary.csv"
PPS_CSV="$OUT_DIR/pps.csv"
DOORBELL_CSV="$OUT_DIR/doorbells.csv"
README="$OUT_DIR/README.md"

if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
	SUDO=()
else
	SUDO=(sudo)
fi

die() {
	printf 'ERROR: %s\n' "$*" >&2
	exit 1
}

need_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

run_root() {
	"${SUDO[@]}" "$@"
}

load_secs() {
	if [[ -n "$LOAD_SECS" ]]; then
		printf '%s\n' "$LOAD_SECS"
	else
		awk -v c="$PING_COUNT" -v i="$PING_INTERVAL" 'BEGIN { printf "%d\n", (c * i) + 8 }'
	fi
}

find_dut_iface() {
	local found
	found=$(ls "/sys/bus/pci/devices/$DUT_BDF/net" 2>/dev/null | head -1)
	if [[ -n "$found" ]]; then
		DUT_IFACE="$found"
	fi
}

wait_carrier() {
	local iface="$1"
	local i
	for i in $(seq 1 20); do
		if [[ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" == "1" ]]; then
			return 0
		fi
		sleep 1
	done
	return 1
}

setup_peer_netns() {
	run_root nmcli dev set "$DUT_IFACE" managed no >/dev/null 2>&1 || true
	run_root nmcli dev set "$PEER_IFACE" managed no >/dev/null 2>&1 || true

	run_root ip netns del "$PEER_NS" >/dev/null 2>&1 || true
	sleep 1
	run_root ip netns add "$PEER_NS"
	run_root ip link set "$PEER_IFACE" netns "$PEER_NS"
	run_root ip netns exec "$PEER_NS" ip link set lo up
	run_root ip netns exec "$PEER_NS" ip addr flush dev "$PEER_IFACE"
	run_root ip netns exec "$PEER_NS" ip addr add "$PEER_IP/$PREFIX" dev "$PEER_IFACE"
	run_root ip netns exec "$PEER_NS" ip link set "$PEER_IFACE" up
	run_root ip netns exec "$PEER_NS" pkill -x iperf3 >/dev/null 2>&1 || true
	run_root ip netns exec "$PEER_NS" iperf3 -s -B "$PEER_IP" -p "$PORT" -D
}

unbind_existing_driver() {
	if [[ -L "/sys/bus/pci/devices/$DUT_BDF/driver" ]]; then
		printf '%s\n' "$DUT_BDF" | run_root tee "/sys/bus/pci/devices/$DUT_BDF/driver/unbind" >/dev/null
	fi
}

reload_driver() {
	local budget="$1"

	run_root ip link set "$DUT_IFACE" down >/dev/null 2>&1 || true
	run_root rmmod r8125_rust >/dev/null 2>&1 || true
	run_root modprobe -r r8169 realtek >/dev/null 2>&1 || true
	unbind_existing_driver
	run_root dmesg -C >/dev/null 2>&1 || true

	# shellcheck disable=SC2086
	run_root insmod "$MODULE" tx_byte_budget="$budget" bql_mode="$BQL_MODE" debug_counters="$DEBUG_COUNTERS" $EXTRA_MODPARAMS
	sleep 2
	find_dut_iface
	run_root ip addr flush dev "$DUT_IFACE"
	run_root ip addr add "$LOCAL_IP/$PREFIX" dev "$DUT_IFACE"
	run_root ip link set "$DUT_IFACE" up
	wait_carrier "$DUT_IFACE" || die "carrier did not come up on $DUT_IFACE"
}

stat_value() {
	local key="$1" file="$2"
	awk -v key="$key" '$1 == key ":" { print $2; found=1 } END { if (!found) print 0 }' "$file"
}

capture_ethtool_stats() {
	local out="$1"
	run_root ethtool -S "$DUT_IFACE" > "$out" 2>&1 || true
}

tcp_gbps() {
	jq -r '((.end.sum_sent.bits_per_second // .end.sum.bits_per_second // 0) / 1e9)' "$1" 2>/dev/null
}

udp_field() {
	local file="$1" expr="$2"
	jq -r "$expr" "$file" 2>/dev/null
}

ping_percentiles() {
	local in="$1" out_times="$2"
	grep -oE 'time=[0-9.]+' "$in" 2>/dev/null | cut -d= -f2 | sort -n > "$out_times"
	local n
	n=$(wc -l < "$out_times")
	if [[ "${n:-0}" -le 0 ]]; then
		printf '0,0,0,0,0\n'
		return 0
	fi
	awk -v n="$n" '
		{ a[NR] = $1 }
		END {
			i50 = int(n * 0.50); if (i50 < 1) i50 = 1;
			i99 = int(n * 0.99); if (i99 < 1) i99 = 1;
			i999 = int(n * 0.999); if (i999 < 1) i999 = 1;
			printf "%d,%.1f,%.1f,%.1f,%.1f\n",
				n, a[i50] * 1000, a[i99] * 1000, a[i999] * 1000, a[n] * 1000;
		}
	' "$out_times"
}

run_loaded_latency() {
	local budget="$1" rep="$2" tag="$3" secs
	secs=$(load_secs)

	iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -p "$PORT" -t "$secs" -J \
		> "$RAW/${tag}_tcp_tx_load.json" 2> "$RAW/${tag}_tcp_tx_load.err" &
	local load_pid=$!
	sleep 2
	ping -I "$DUT_IFACE" -c "$PING_COUNT" -i "$PING_INTERVAL" -W 2 -n "$PEER_IP" \
		> "$RAW/${tag}_ping_loaded.txt" 2>&1 || true
	wait "$load_pid" || true

	local gbps pstats
	gbps=$(tcp_gbps "$RAW/${tag}_tcp_tx_load.json")
	pstats=$(ping_percentiles "$RAW/${tag}_ping_loaded.txt" "$RAW/${tag}_ping_loaded_times_ms.txt")
	printf '%s,%s,%s,%s\n' "$budget" "$rep" "$gbps" "$pstats"
}

run_pps() {
	local budget="$1" rep="$2" tag="$3" frame
	for frame in $PPS_FRAMES; do
		local raw="$RAW/${tag}_udp${frame}_tx.json"
		iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -p "$PORT" -t "$PPS_SECS" \
			-u -l "$frame" -b "$PPS_BITRATE" -J \
			> "$raw" 2> "$RAW/${tag}_udp${frame}_tx.err" || true

		local packets seconds bps mbps pps loss
		packets=$(udp_field "$raw" '(.end.sum.packets // .end.sum_sent.packets // 0)')
		seconds=$(udp_field "$raw" '(.end.sum.seconds // .end.sum_sent.seconds // 1)')
		bps=$(udp_field "$raw" '(.end.sum.bits_per_second // .end.sum_sent.bits_per_second // 0)')
		loss=$(udp_field "$raw" '(.end.sum.lost_percent // 0)')
		pps=$(awk -v p="$packets" -v s="$seconds" 'BEGIN { if (s > 0) printf "%.0f", p / s; else print 0 }')
		mbps=$(awk -v b="$bps" 'BEGIN { printf "%.0f", b / 1e6 }')
		printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
			"$budget" "$rep" "$frame" "$pps" "$mbps" "$loss" "$packets" "$seconds" >> "$PPS_CSV"
	done
}

stop_and_capture_doorbells() {
	local budget="$1" rep="$2" tag="$3" stats="$RAW/${tag}_ethtool_after.txt"
	capture_ethtool_stats "$stats"

	local tx_received tx_consumed tx_busy tx_dropped
	tx_received=$(stat_value tx_received "$stats")
	tx_consumed=$(stat_value tx_consumed "$stats")
	tx_busy=$(stat_value tx_busy_exception "$stats")
	tx_dropped=$(stat_value tx_dropped_error "$stats")

	run_root ip link set "$DUT_IFACE" down >/dev/null 2>&1 || true
	run_root rmmod r8125_rust >/dev/null 2>&1 || true
	run_root dmesg > "$RAW/${tag}_dmesg_after_unload.txt" 2>&1 || true

	local line xmits doorbells irqs polls ratio
	line=$(grep 'r8125_rust ndo_stop:' "$RAW/${tag}_dmesg_after_unload.txt" | tail -1 || true)
	xmits=$(sed -n 's/.*xmit_calls=\([0-9][0-9]*\).*/\1/p' <<<"$line")
	irqs=$(sed -n 's/.*irq_fires=\([0-9][0-9]*\).*/\1/p' <<<"$line")
	polls=$(sed -n 's/.*napi_polls=\([0-9][0-9]*\).*/\1/p' <<<"$line")
	doorbells=$(sed -n 's/.*tx_doorbells=\([0-9][0-9]*\).*/\1/p' <<<"$line")
	xmits=${xmits:-0}
	irqs=${irqs:-0}
	polls=${polls:-0}
	doorbells=${doorbells:-0}
	ratio=$(awk -v d="$doorbells" -v x="$xmits" 'BEGIN { if (x > 0) printf "%.6f", d / x; else print "0" }')

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$budget" "$rep" "$xmits" "$doorbells" "$ratio" "$irqs" "$polls" \
		"$tx_received" "$tx_consumed" "$tx_busy" "$tx_dropped" \
		"$(printf '%s' "$line" | tr ',' ';')" >> "$DOORBELL_CSV"
	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$xmits" "$doorbells" "$ratio" "$tx_received" "$tx_consumed" \
		"$tx_busy" "$tx_dropped" "$irqs" "$polls"
}

run_one() {
	local budget="$1" rep="$2" tag
	tag="budget${budget}_rep${rep}"
	printf '[budget=%s rep=%s] reload\n' "$budget" "$rep"
	reload_driver "$budget"

	printf '[budget=%s rep=%s] loaded latency + TCP TX\n' "$budget" "$rep"
	local loaded
	loaded=$(run_loaded_latency "$budget" "$rep" "$tag")

	printf '[budget=%s rep=%s] small-frame UDP TX PPS\n' "$budget" "$rep"
	run_pps "$budget" "$rep" "$tag"

	printf '[budget=%s rep=%s] unload + counters\n' "$budget" "$rep"
	local counters
	counters=$(stop_and_capture_doorbells "$budget" "$rep" "$tag")

	printf '%s,%s\n' "$loaded" "$counters" >> "$SUMMARY_CSV"
}

run_xmit_more_probe() {
	local tag="xmit_more_budget${XMIT_MORE_BUDGET}"
	printf '[xmit_more] reload budget=%s\n' "$XMIT_MORE_BUDGET"
	reload_driver "$XMIT_MORE_BUDGET"

	if [[ -n "$XMIT_MORE_CMD" ]]; then
		printf '[xmit_more] custom command: %s\n' "$XMIT_MORE_CMD"
		bash -c "$XMIT_MORE_CMD" > "$RAW/${tag}.out" 2> "$RAW/${tag}.err" || true
	else
		printf '[xmit_more] default parallel UDP iperf3 smoke\n'
		iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -p "$PORT" -t "$PPS_SECS" \
			-u -l 64 -b "$XMIT_MORE_BITRATE" -P "$XMIT_MORE_STREAMS" -J \
			> "$RAW/${tag}.json" 2> "$RAW/${tag}.err" || true
	fi

	local counters
	counters=$(stop_and_capture_doorbells "$XMIT_MORE_BUDGET" "xmit_more" "$tag")
	printf '%s,%s,%s\n' "$XMIT_MORE_BUDGET" "xmit_more" "$counters" >> "$OUT_DIR/xmit_more_probe.csv"
}

write_readme() {
	cat > "$README" <<EOF
# tx_byte_budget sweep - ${STAMP}

Environment:
- Host: $(hostname)
- Kernel: $(uname -r)
- Module: \`$MODULE\`
- DUT: \`$DUT_IFACE\` at \`$LOCAL_IP/$PREFIX\`, BDF \`$DUT_BDF\`
- Peer: \`$PEER_IFACE\` in netns \`$PEER_NS\` at \`$PEER_IP/$PREFIX\`
- Budgets: \`$TX_BYTE_BUDGETS\`
- Reps: \`$REPS\`
- BQL mode: \`$BQL_MODE\`
- Debug counters: \`$DEBUG_COUNTERS\` (enabled for doorbell-ratio evidence)
- PPS frames: \`$PPS_FRAMES\`, offered bitrate \`$PPS_BITRATE\`

Files:
- \`summary.csv\`: one row per budget/repetition with TCP TX, loaded ICMP
  latency, ethtool disposition counters, and ndo_stop doorbell counters.
- \`pps.csv\`: small-frame UDP TX PPS per frame size.
- \`doorbells.csv\`: raw ndo_stop xmit/doorbell log parse.
- \`raw/\`: iperf3 JSON, ping samples, ethtool stats, and dmesg per run.

Default-selection rule:
1. Keep \`tx_byte_budget=0\` as the control only.
2. Reject any nonzero budget that loses TCP TX line rate, reports nonzero
   \`tx_busy_exception\`, or materially drops 64/128/256 B PPS versus the best
   nonzero budget.
3. Among the remaining budgets, choose the largest value whose loaded ICMP p99
   stays at parity-or-better with the C driver target. Larger budgets reduce
   stop/wake churn; smaller budgets reduce TX residency.
4. If two adjacent budgets are statistically tied, keep the current default
   \`131072\` unless the larger one has a clear PPS or CPU advantage.

Optional xmit_more confirmation:
- Run with \`XMIT_MORE_PROBE=1\`.
- For a genuinely batched workload, set \`XMIT_MORE_CMD\` to a forwarding or
  sendmmsg-based command. The default parallel-UDP iperf3 probe is only a smoke.
- Evidence is \`tx_doorbells / xmit_calls < 1.0\` in \`xmit_more_probe.csv\`.
EOF
}

main() {
	need_cmd ip
	need_cmd iperf3
	need_cmd jq
	need_cmd ping
	need_cmd ethtool
	[[ -f "$MODULE" ]] || die "module not found: $MODULE"

	mkdir -p "$RAW"
	printf 'budget,rep,tcp_tx_gbps,ping_samples,ping_p50_us,ping_p99_us,ping_p999_us,ping_max_us,xmit_calls,tx_doorbells,doorbell_ratio,tx_received,tx_consumed,tx_busy_exception,tx_dropped_error,irq_fires,napi_polls\n' > "$SUMMARY_CSV"
	printf 'budget,rep,frame,pps,mbps,loss_pct,packets,seconds\n' > "$PPS_CSV"
	printf 'budget,rep,xmit_calls,tx_doorbells,doorbell_ratio,irq_fires,napi_polls,tx_received,tx_consumed,tx_busy_exception,tx_dropped_error,dmesg_line\n' > "$DOORBELL_CSV"
	printf 'budget,rep,xmit_calls,tx_doorbells,doorbell_ratio,tx_received,tx_consumed,tx_busy_exception,tx_dropped_error,irq_fires,napi_polls\n' > "$OUT_DIR/xmit_more_probe.csv"

	setup_peer_netns
	write_readme

	local budget rep
	for budget in $TX_BYTE_BUDGETS; do
		for rep in $(seq 1 "$REPS"); do
			run_one "$budget" "$rep"
		done
	done

	if [[ "$XMIT_MORE_PROBE" == "1" ]]; then
		run_xmit_more_probe
	fi

	if [[ "$RESTORE_DEFAULT" == "1" ]]; then
		printf '[restore] reload default budget=%s\n' "$RESTORE_BUDGET"
		reload_driver "$RESTORE_BUDGET"
	fi

	printf '\nSweep complete: %s\n' "$OUT_DIR"
	printf 'Summary: %s\n' "$SUMMARY_CSV"
	printf 'PPS:     %s\n' "$PPS_CSV"
}

main "$@"
