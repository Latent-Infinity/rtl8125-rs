#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RSSHASH hashability probe for RTL8125B.
#
# Purpose:
#   - confirm that the RTL8125B descriptor-capability answer is captured
#     (V3-capable, non-V4 in the tested path),
#   - capture pre/post RX hash counters,
#   - keep the test constrained to single-queue legacy IRQ behavior while hash
#     engine knobs are exercised to the degree this environment allows,
#   - produce normalized artifacts for Rust vs C comparison and a focused
#     evidence payload for A1/A3 gate decisions.
#
# Usage:
#   LABEL=rust     DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 \
#     scripts/rxhash_probe.sh
#   LABEL=c_r8169  DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 \
#     scripts/rxhash_probe.sh
#
# Artifacts:
#   - features.csv: ethtool -k receive-hashing / rx-hashing state
#   - traffic.csv: TCP/UDP pps/gbps/loss metrics
#   - queues.csv: RX/TX queue count and ethtool -x support
#   - hash_counters.csv: ethtool -S rx_hash_* deltas
#   - irq_snapshot.csv: per-vector /proc/interrupts deltas
#   - raw/: command output and all JSON/raw iperf3 payloads

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

LABEL=${LABEL:-rust}
EXPECTED_DRIVER=${EXPECTED_DRIVER:-r8125_rust}
if [[ "$LABEL" == "c" || "$LABEL" == "c_r8169" ]]; then
	EXPECTED_DRIVER=r8169
fi

DUT_IFACE=${DUT_IFACE:-enp3s0}
PEER_IFACE=${PEER_IFACE:-enp4s0}
PEER_NS=${PEER_NS:-peer}
USE_PEER_NS=${USE_PEER_NS:-1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
PEER_IP=${PEER_IP:-10.0.0.1}
PREFIX=${PREFIX:-24}
PORT=${PORT:-5201}
RUN_SECS=${RUN_SECS:-8}
UDP_BITRATE=${UDP_BITRATE:-3G}
UDP_LENGTHS=${UDP_LENGTHS:-"64 128 256"}
MTUS=${MTUS:-1500 9000}
PROBE_DESC_FIELDS=${PROBE_DESC_FIELDS:-1}
PROBE_SKB_HASH=${PROBE_SKB_HASH:-0}
HASH_TRACE_CMD=${HASH_TRACE_CMD:-}
V3_ENABLE_CMD=${V3_ENABLE_CMD:-}
SKIP_RUNS=${SKIP_RUNS:-0}

STAMP=$(date -u +'%Y%m%d_%H%M%S')
OUT_DIR="${OUT_DIR:-$ROOT/docs/perf/rsshash_probe_${STAMP}_${LABEL}}"
RAW="$OUT_DIR/raw"
FEATURE_CSV="$OUT_DIR/features.csv"
TRAFFIC_CSV="$OUT_DIR/traffic.csv"
QUEUE_CSV="$OUT_DIR/queues.csv"
HASH_CSV="$OUT_DIR/hash_counters.csv"
IRQ_CSV="$OUT_DIR/irq_snapshot.csv"
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

peer_cmd() {
	if [[ "$USE_PEER_NS" == "1" ]]; then
		run_root ip netns exec "$PEER_NS" "$@"
	else
		run_root "$@"
	fi
}

capture() {
	local name="$1"
	shift
	"$@" > "$RAW/$name" 2>&1 || true
}

resolve_iface_bdf() {
	if [[ -n "${DUT_BDF:-}" ]]; then
		return
	fi
	local dev_path bdf
	dev_path="$(readlink -f "/sys/class/net/$DUT_IFACE/device" 2>/dev/null || true)"
	if [[ -n "$dev_path" ]]; then
		DUT_BDF=$(basename "$dev_path")
	fi
}

check_driver() {
	local drv_path
	drv_path="$(readlink -f "/sys/class/net/$DUT_IFACE/device/driver" 2>/dev/null || true)"
	drv_path="${drv_path##*/}"
	if [[ -z "$drv_path" ]]; then
		die "no driver is bound to $DUT_IFACE"
	fi

	if [[ "$drv_path" != "$EXPECTED_DRIVER" ]]; then
		die "driver mismatch: expected $EXPECTED_DRIVER on $DUT_IFACE, found $drv_path"
	fi
}

wait_carrier() {
	local iface="$1" i
	for i in $(seq 1 20); do
		if [[ "$(cat "/sys/class/net/$iface/carrier" 2>/dev/null)" == "1" ]]; then
			return 0
		fi
		sleep 1
	done
	return 1
}

snapshot_interrupts() {
	local mode="$1"
	awk -v label="$LABEL" -v mode="$mode" '
	{
		vector=$1
		sub(":", "", vector)
		sum=0
		desc=""
		for (i=2; i<=NF; ++i) {
			if ($i ~ /^[0-9]+$/) {
				sum += $i
				continue
			}
			desc=desc $i " "
		}
		if (sum > 0 && vector !~ /^[[:space:]]*$/) {
			gsub(/[[:space:]]+/, "_", desc)
			printf "%s,%s,%s,%s,%s\n", label, mode, vector, sum, desc
		}
	}' "$RAW/interrupts_${mode}.txt" >> "$IRQ_CSV"
}

read_hash_counter() {
	local key="$1" file="$2" value
	value=$(awk -v key="$key:" '$1 == key { print $2; found=1 } END { if (!found) print "" }' "$file")
	printf '%s' "$value"
}

hash_delta() {
	local key="$1" before_file="$2" after_file="$3"
	local before after
	before=$(read_hash_counter "$key" "$before_file")
	after=$(read_hash_counter "$key" "$after_file")

	if [[ -z "$before" || -z "$after" ]]; then
		printf '%s' "missing"
		return
	fi
	if ! [[ $before =~ ^[0-9]+$ && $after =~ ^[0-9]+$ ]]; then
		printf '%s' "invalid"
		return
	fi
	printf '%d' $((after - before))
}

parse_feature() {
	local feature="$1" file="$2"
	awk -v key="$feature:" '$1 == key { print $2; found=1 } END { if (!found) print "missing" }' "$file"
}

record_features() {
	local file="$RAW/ethtool_k_initial.txt"

	capture "ethtool_k_initial.txt" run_root ethtool -k "$DUT_IFACE"
	printf 'label,feature,value\n' > "$FEATURE_CSV"
	for feature in rx-checksumming tx-checksumming scatter-gather tcp-segmentation-offload rx-vlan-offload rx-hashing receive-hashing; do
		printf '%s,%s,%s\n' "$LABEL" "$feature" "$(parse_feature "$feature" "$file")" >> "$FEATURE_CSV"
	done
}

record_queue_state() {
	local rxq txq x_state
	rxq=$(find "/sys/class/net/$DUT_IFACE/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
	txq=$(find "/sys/class/net/$DUT_IFACE/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)
	if run_root ethtool -x "$DUT_IFACE" > "$RAW/ethtool_x.txt" 2>&1; then
		x_state=supported
	else
		x_state=unsupported
	fi

	printf '%s,%s,%s,%s\n' "$LABEL" "$rxq" "$txq" "$x_state" >> "$QUEUE_CSV"
}

record_hash_delta() {
	local mode="$1"
	local before_file="$RAW/ethtool_S_before_${mode}.txt"
	local after_file="$RAW/ethtool_S_after_${mode}.txt"
	printf '%s,%s,%s,%s,%s,%s\n' \
		"$LABEL" \
		"$mode" \
		"$(hash_delta 'rx_hash_l3' "$before_file" "$after_file")" \
		"$(hash_delta 'rx_hash_l4' "$before_file" "$after_file")" \
		"$(hash_delta 'rx_hash_missing' "$before_file" "$after_file")" \
		"$(hash_delta 'rx_hash_disabled' "$before_file" "$after_file")" >> "$HASH_CSV"
}

record_interrupt_snapshot() {
	local mode="$1"
	capture "interrupts_${mode}.txt" run_root sh -c "grep -E \"${DUT_IFACE}|${PEER_IFACE}|r8125|r8169|PCI-MSI\" /proc/interrupts"
	snapshot_interrupts "$mode"
}

json_bps() {
	jq -r '(.end.sum_received.bits_per_second // .end.sum.bits_per_second // .end.sum_sent.bits_per_second // 0)' "$1" 2>/dev/null
}

json_lost() {
	jq -r '(.end.sum_received.lost_percent // .end.sum.lost_percent // 0)' "$1" 2>/dev/null
}

json_packets() {
	jq -r '(.end.sum_received.packets // .end.sum.packets // 0)' "$1" 2>/dev/null
}

json_seconds() {
	jq -r '(.end.sum_received.seconds // .end.sum.seconds // 1)' "$1" 2>/dev/null
}

gbps() {
	awk -v b="${1:-0}" 'BEGIN { printf "%.3f", b / 1e9 }'
}

pps() {
	local packets seconds
	packets=$(json_packets "$1")
	seconds=$(json_seconds "$1")
	awk -v p="$packets" -v s="$seconds" 'BEGIN { if (s > 0) printf "%.0f", p / s; else print 0 }'
}

run_iperf_tcp() {
	local mode="$1" dir="$2" mtu="$3" file="$4"
	if [[ "$dir" == "tx" ]]; then
		iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -J \
			> "$file" 2> "$RAW/${mode}_tcp_${dir}_${mtu}_err.txt" || true
	else
		iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -R -J \
			> "$file" 2> "$RAW/${mode}_tcp_${dir}_${mtu}_err.txt" || true
	fi
}

run_iperf_udp() {
	local mode="$1" dir="$2" mtu="$3" len="$4" file="$5"
	if [[ "$dir" == "tx" ]]; then
		iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -u -l "$len" -b "$UDP_BITRATE" -J \
			> "$file" 2> "$RAW/${mode}_udp_${dir}_${mtu}_${len}_err.txt" || true
	else
		iperf3 -c "$PEER_IP" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -u -l "$len" -b "$UDP_BITRATE" -R -J \
			> "$file" 2> "$RAW/${mode}_udp_${dir}_${mtu}_${len}_err.txt" || true
	fi
}

append_traffic_csv() {
	local mode="$1" proto="$2" dir="$3" mtu="$4" len="$5" file="$6" bps ppsv loss
	bps=$(json_bps "$file")
	loss=$(json_lost "$file")
	if [[ "$proto" == "tcp" ]]; then
		ppsv=0
	else
		ppsv=$(pps "$file")
	fi
	printf '%s,%s,%s,%s,%s,%s,%.3f,%.3f,%s,%s\n' \
		"$LABEL" "$mode" "$proto" "$dir" "$mtu" "$len" "$(gbps "$bps")" "$ppsv" "$loss" "$file" >> "$TRAFFIC_CSV"
}

setup_peer_netns() {
	run_root nmcli dev set "$DUT_IFACE" managed no >/dev/null 2>&1 || true
	run_root nmcli dev set "$PEER_IFACE" managed no >/dev/null 2>&1 || true

	if [[ "$USE_PEER_NS" == "1" ]]; then
		run_root ip netns del "$PEER_NS" >/dev/null 2>&1 || true
		run_root ip netns add "$PEER_NS"
		run_root ip link set "$PEER_IFACE" netns "$PEER_NS"
		peer_cmd ip link set lo up
	fi

	run_root ip addr flush dev "$DUT_IFACE" || true
	run_root ip addr add "$LOCAL_IP/$PREFIX" dev "$DUT_IFACE" || true
	run_root ip link set "$DUT_IFACE" up

	peer_cmd ip addr flush dev "$PEER_IFACE" || true
	peer_cmd ip addr add "$PEER_IP/$PREFIX" dev "$PEER_IFACE" || true
	peer_cmd ip link set "$PEER_IFACE" up

	wait_carrier "$DUT_IFACE" || die "carrier did not come up on $DUT_IFACE"
}

start_iperf_server() {
	peer_cmd pkill -x iperf3 >/dev/null 2>&1 || true
	peer_cmd iperf3 -s -B "$PEER_IP" -p "$PORT" -D
	sleep 1
}

run_single_pass() {
	local mode="$1"
	local mtu

	for mtu in $MTUS; do
		run_root ip link set "$DUT_IFACE" mtu "$mtu"
		run_root ip link set "$PEER_IFACE" mtu "$mtu"
		sleep 1

		capture "${mode}_ping_${mtu}.txt" run_root ping -I "$DUT_IFACE" -c 3 -W 2 -n "$PEER_IP"
		run_iperf_tcp "$mode" "tx" "$mtu" "$RAW/${mode}_tcp_tx_${mtu}.json"
		run_iperf_tcp "$mode" "rx" "$mtu" "$RAW/${mode}_tcp_rx_${mtu}.json"

		for len in $UDP_LENGTHS; do
			run_iperf_udp "$mode" "tx" "$mtu" "$len" "$RAW/${mode}_udp_tx_${mtu}_l${len}.json"
			run_iperf_udp "$mode" "rx" "$mtu" "$len" "$RAW/${mode}_udp_rx_${mtu}_l${len}.json"
		done

		append_traffic_csv "$mode" tcp tx "$mtu" "" "$RAW/${mode}_tcp_tx_${mtu}.json"
		append_traffic_csv "$mode" tcp rx "$mtu" "" "$RAW/${mode}_tcp_rx_${mtu}.json"
		for len in $UDP_LENGTHS; do
			append_traffic_csv "$mode" udp tx "$mtu" "$len" "$RAW/${mode}_udp_tx_${mtu}_l${len}.json"
			append_traffic_csv "$mode" udp rx "$mtu" "$len" "$RAW/${mode}_udp_rx_${mtu}_l${len}.json"
		done
	done
}

record_traffic() {
	local mode="$1"
	record_interrupt_snapshot "before_${mode}"
	run_single_pass "$mode"
	record_interrupt_snapshot "after_${mode}"
}

start_hash_trace() {
	local mode="$1" pid
	if [[ "${PROBE_SKB_HASH}" != "1" ]]; then
		return
	fi
	if [[ -n "$HASH_TRACE_CMD" ]]; then
		run_root bash -c "$HASH_TRACE_CMD" > "$RAW/hash_trace_${mode}.txt" 2>&1 &
		HASH_TRACE_PID=$!
		return
	fi
	if command -v bpftrace >/dev/null 2>&1; then
		run_root bpftrace -e "tracepoint:net:netif_receive_skb /args->skbuff->hash/ { @h[args->skbuff->hash] = count(); }" \
			> "$RAW/hash_trace_${mode}.txt" 2>&1 &
		HASH_TRACE_PID=$!
	else
		HASH_TRACE_PID=
	fi
}

stop_hash_trace() {
	if [[ -n "${HASH_TRACE_PID:-}" ]]; then
		run_root kill "$HASH_TRACE_PID" 2>/dev/null || true
		HASH_TRACE_PID=
	fi
}

run_single_mode() {
	local mode="$1"
	capture "probe_state_before_${mode}.txt" run_root uname -a
	capture "ethtool_i_${mode}.txt" run_root ethtool -i "$DUT_IFACE"
	capture "lspci_${mode}.txt" run_root lspci -nnk -s "$DUT_BDF"
	capture "ethtool_x_${mode}.txt" run_root ethtool -x "$DUT_IFACE" || true
	capture "ethtool_g_${mode}.txt" run_root ethtool -g "$DUT_IFACE"
	capture "ethtool_c_${mode}.txt" run_root ethtool -c "$DUT_IFACE" || true
	capture "dmesg_${mode}_before.txt" run_root dmesg -T | tail -n 100

	if [[ "${PROBE_DESC_FIELDS}" == "1" && -n "$V3_ENABLE_CMD" ]]; then
		capture "v3_enable_${mode}.txt" run_root bash -c "$V3_ENABLE_CMD" || true
	fi

	start_hash_trace "$mode"
	capture "ethtool_S_before_${mode}.txt" run_root ethtool -S "$DUT_IFACE"
	record_traffic "$mode"
	capture "ethtool_S_after_${mode}.txt" run_root ethtool -S "$DUT_IFACE"
	record_hash_delta "$mode"
	stop_hash_trace
	capture "dmesg_${mode}_after.txt" run_root dmesg -T | tail -n 100
}

write_readme() {
	cat > "$README" <<EOF
# RSSHASH probe — $LABEL

- UTC stamp: $STAMP
- DUT: $DUT_IFACE ($LOCAL_IP/$PREFIX), peer $PEER_IFACE ($PEER_IP/$PREFIX)
- Output dir: $OUT_DIR
- Run seconds per iperf shape: $RUN_SECS
- UDP lengths: $UDP_LENGTHS
- MTUs: $MTUS
- Run modes: one-pass TCP/UDP RX+TX traffic per MTU.

What this run captures:

- `features.csv`: `ethtool -k` receive-hashing / rx-hashing + baseline offload flags
- `queues.csv`: RX/TX queue counts and ethtool `-x` support
- `hash_counters.csv`: `ethtool -S` `rx_hash_*` deltas
- `irq_snapshot.csv`: /proc/interrupts vector deltas
- `traffic.csv`: TCP/UDP throughput and loss metrics
- `raw/`: all intermediate command and iperf outputs used to interpret the
  probe decision

Probe decision notes:

- Open the `hash_counters.csv` rows. If `rx_hash_l3`/`rx_hash_l4` increase for
  controlled hashable traffic while `rx_hash_disabled` stays bounded, capture
  the traffic + counter evidence and proceed to A2 parser wiring.
- If counters stay flat/disabled only, proceed to Track B prerequisites before
  RXHASH-only advertising.
EOF
}

need_cmd ip
need_cmd iperf3
need_cmd ethtool
need_cmd jq
need_cmd lspci
need_cmd grep
need_cmd awk

resolve_iface_bdf
if [[ -z "${DUT_BDF:-}" ]]; then
	die "could not resolve DUT_BDF for $DUT_IFACE"
fi

mkdir -p "$OUT_DIR" "$RAW"
touch "$FEATURE_CSV" "$TRAFFIC_CSV" "$QUEUE_CSV" "$HASH_CSV" "$IRQ_CSV"
trap 'stop_hash_trace' EXIT

cat > "$TRAFFIC_CSV" <<EOF
label,mode,proto,direction,mtu,udp_len,gbps,pps,loss_pct,raw_json
EOF
cat > "$QUEUE_CSV" <<EOF
label,rx_queues,tx_queues,ethtool_x
EOF
cat > "$HASH_CSV" <<EOF
label,mode,delta_rx_hash_l3,delta_rx_hash_l4,delta_rx_hash_missing,delta_rx_hash_disabled
EOF
cat > "$IRQ_CSV" <<EOF
label,mode,irq_vector,irq_count,desc
EOF

check_driver
setup_peer_netns
start_iperf_server
record_features
record_queue_state
capture "ethtool_k_initial.txt" run_root ethtool -k "$DUT_IFACE"
capture "ethtool_S_initial.txt" run_root ethtool -S "$DUT_IFACE"
capture "interrupts_initial.txt" run_root sh -c "grep -E \"${DUT_IFACE}|${PEER_IFACE}|r8125|r8169|PCI-MSI\" /proc/interrupts"

if (( SKIP_RUNS == 0 )); then
	run_single_mode "probe"
fi

write_readme
run_root ip link set "$DUT_IFACE" mtu 1500
run_root ip link set "$PEER_IFACE" mtu 1500
peer_cmd pkill -x iperf3 >/dev/null 2>&1 || true

cat > "$README.summary" <<EOF
{
  "label": "$LABEL",
  "out_dir": "$OUT_DIR",
  "expected_driver": "$EXPECTED_DRIVER",
  "dut_iface": "$DUT_IFACE",
  "dut_bdf": "$DUT_BDF",
  "probe_desc_fields": "$PROBE_DESC_FIELDS",
  "probe_skb_hash": "$PROBE_SKB_HASH"
}
EOF

printf 'Wrote %s\n' "$OUT_DIR"
