#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Gateway hardware-offload validation harness.
#
# Run once with the C driver bound and once with r8125_rust bound:
#
#   LABEL=c_r8169  DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/gateway_hw_offload_validate.sh
#   LABEL=rust     DUT_IFACE=enp3s0 PEER_IFACE=enp4s0 scripts/gateway_hw_offload_validate.sh
#
# The output schema is stable so the two runs can be diffed directly:
#   - features.csv: ethtool -k values for VLAN/checksum/TSO/RXHASH features
#   - traffic.csv: VLAN TCP/UDP tx/rx results with HW VLAN on and, optionally, off
#   - queues.csv: RX/TX queue count plus ethtool RSS table support state
#   - raw/: ethtool, stats, RSS, interrupts, and iperf3 JSON artifacts

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DUT_IFACE=${DUT_IFACE:-enp3s0}
PEER_IFACE=${PEER_IFACE:-enp4s0}
PEER_NS=${PEER_NS:-peer}
USE_PEER_NS=${USE_PEER_NS:-1}

LOCAL_IP=${LOCAL_IP:-10.0.0.2}
PEER_IP=${PEER_IP:-10.0.0.1}
PREFIX=${PREFIX:-24}

VLAN_ID=${VLAN_ID:-125}
DUT_VLAN=${DUT_VLAN:-"$DUT_IFACE.$VLAN_ID"}
PEER_VLAN=${PEER_VLAN:-"$PEER_IFACE.$VLAN_ID"}
VLAN_LOCAL_IP=${VLAN_LOCAL_IP:-10.125.0.2}
VLAN_PEER_IP=${VLAN_PEER_IP:-10.125.0.1}
VLAN_PREFIX=${VLAN_PREFIX:-24}

PORT=${PORT:-5201}
RUN_SECS=${RUN_SECS:-10}
UDP_BITRATE=${UDP_BITRATE:-3G}
UDP_LENGTHS=${UDP_LENGTHS:-"64 128 256 512 1448"}
MTUS=${MTUS:-1500}
TOGGLE_VLAN_OFF=${TOGGLE_VLAN_OFF:-1}
LABEL=${LABEL:-rust}

STAMP=$(date -u +'%Y%m%d_%H%M%S')
OUT_DIR=${OUT_DIR:-"$ROOT/docs/perf/hw_offload_validate_${STAMP}_${LABEL}"}
RAW="$OUT_DIR/raw"
FEATURE_CSV="$OUT_DIR/features.csv"
TRAFFIC_CSV="$OUT_DIR/traffic.csv"
QUEUE_CSV="$OUT_DIR/queues.csv"
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
	local name="$1"; shift
	"$@" > "$RAW/$name" 2>&1 || true
}

feature_value() {
	local feature="$1" file="$2"
	awk -v key="$feature:" '$1 == key { print $2; found=1 } END { if (!found) print "missing" }' "$file"
}

json_bps() {
	jq -r '(.end.sum_received.bits_per_second //
		.end.sum_sent.bits_per_second //
		.end.sum.bits_per_second // 0)' "$1" 2>/dev/null
}

json_retrans() {
	jq -r '(.end.sum_received.retransmits //
		.end.sum_sent.retransmits //
		.end.sum.retransmits // 0)' "$1" 2>/dev/null
}

json_loss() {
	jq -r '(.end.sum.lost_percent //
		.end.sum_received.lost_percent //
		.end.sum_sent.lost_percent // 0)' "$1" 2>/dev/null
}

json_packets() {
	jq -r '(.end.sum.packets //
		.end.sum_received.packets //
		.end.sum_sent.packets // 0)' "$1" 2>/dev/null
}

json_seconds() {
	jq -r '(.end.sum.seconds //
		.end.sum_received.seconds //
		.end.sum_sent.seconds // 1)' "$1" 2>/dev/null
}

gbps_from_bps() {
	awk -v b="${1:-0}" 'BEGIN { printf "%.3f", b / 1e9 }'
}

pps_from_json() {
	local file="$1" packets seconds
	packets=$(json_packets "$file")
	seconds=$(json_seconds "$file")
	awk -v p="${packets:-0}" -v s="${seconds:-1}" 'BEGIN { if (s > 0) printf "%.0f", p / s; else print 0 }'
}

set_vlan_features() {
	local value="$1"
	run_root ethtool -K "$DUT_IFACE" txvlan "$value" rxvlan "$value" \
		> "$RAW/ethtool_K_vlan_${value}.txt" 2>&1 || true
	sleep 1
	capture "ethtool_k_after_vlan_${value}.txt" run_root ethtool -k "$DUT_IFACE"
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

setup_peer() {
	run_root nmcli dev set "$DUT_IFACE" managed no >/dev/null 2>&1 || true
	run_root nmcli dev set "$PEER_IFACE" managed no >/dev/null 2>&1 || true

	if [[ "$USE_PEER_NS" == "1" ]]; then
		run_root ip netns del "$PEER_NS" >/dev/null 2>&1 || true
		sleep 1
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

setup_vlan_links() {
	local mtu="$1"

	run_root ip link del "$DUT_VLAN" >/dev/null 2>&1 || true
	peer_cmd ip link del "$PEER_VLAN" >/dev/null 2>&1 || true

	run_root ip link set "$DUT_IFACE" mtu "$mtu" || true
	peer_cmd ip link set "$PEER_IFACE" mtu "$mtu" || true

	run_root ip link add link "$DUT_IFACE" name "$DUT_VLAN" type vlan id "$VLAN_ID"
	peer_cmd ip link add link "$PEER_IFACE" name "$PEER_VLAN" type vlan id "$VLAN_ID"

	run_root ip addr flush dev "$DUT_VLAN" || true
	run_root ip addr add "$VLAN_LOCAL_IP/$VLAN_PREFIX" dev "$DUT_VLAN"
	run_root ip link set "$DUT_VLAN" up

	peer_cmd ip addr flush dev "$PEER_VLAN" || true
	peer_cmd ip addr add "$VLAN_PEER_IP/$VLAN_PREFIX" dev "$PEER_VLAN"
	peer_cmd ip link set "$PEER_VLAN" up
}

start_iperf_server() {
	peer_cmd pkill -x iperf3 >/dev/null 2>&1 || true
	peer_cmd iperf3 -s -B "$VLAN_PEER_IP" -p "$PORT" -D
	sleep 1
}

record_features() {
	local file="$RAW/ethtool_k_initial.txt" feature

	capture "ethtool_k_initial.txt" run_root ethtool -k "$DUT_IFACE"
	printf 'label,feature,value\n' > "$FEATURE_CSV"
	for feature in \
		rx-checksumming \
		tx-checksumming \
		scatter-gather \
		tcp-segmentation-offload \
		tx-vlan-offload \
		rx-vlan-offload \
		receive-hashing \
		rx-hashing; do
		printf '%s,%s,%s\n' "$LABEL" "$feature" "$(feature_value "$feature" "$file")" >> "$FEATURE_CSV"
	done
}

record_queues() {
	local rxq txq rss_state

	rxq=$(find "/sys/class/net/$DUT_IFACE/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l)
	txq=$(find "/sys/class/net/$DUT_IFACE/queues" -maxdepth 1 -name 'tx-*' 2>/dev/null | wc -l)
	if run_root ethtool -x "$DUT_IFACE" > "$RAW/ethtool_x.txt" 2>&1; then
		rss_state=supported
	else
		rss_state=unsupported
	fi

	printf 'label,rx_queues,tx_queues,ethtool_x\n' > "$QUEUE_CSV"
	printf '%s,%s,%s,%s\n' "$LABEL" "$rxq" "$txq" "$rss_state" >> "$QUEUE_CSV"
}

record_preflight() {
	capture "uname.txt" uname -a
	capture "ip_link_dut.txt" ip -d link show dev "$DUT_IFACE"
	capture "ethtool_i.txt" run_root ethtool -i "$DUT_IFACE"
	capture "ethtool_S_before.txt" run_root ethtool -S "$DUT_IFACE"
	capture "interrupts_before.txt" grep -E "$DUT_IFACE|r8125|r8169|enp|PCI-MSI" /proc/interrupts
	record_features
	record_queues
}

record_after_mode() {
	local mode="$1"
	capture "ethtool_S_after_${mode}.txt" run_root ethtool -S "$DUT_IFACE"
	capture "interrupts_after_${mode}.txt" grep -E "$DUT_IFACE|r8125|r8169|enp|PCI-MSI" /proc/interrupts
}

append_tcp_result() {
	local mode="$1" dir="$2" mtu="$3" file="$4" bps retrans

	bps=$(json_bps "$file")
	retrans=$(json_retrans "$file")
	printf '%s,%s,tcp,%s,%s,,%s,,,%s,%s\n' \
		"$LABEL" "$mode" "$dir" "$mtu" "$(gbps_from_bps "$bps")" "$retrans" "$file" >> "$TRAFFIC_CSV"
}

append_udp_result() {
	local mode="$1" dir="$2" mtu="$3" len="$4" file="$5" bps pps loss

	bps=$(json_bps "$file")
	pps=$(pps_from_json "$file")
	loss=$(json_loss "$file")
	printf '%s,%s,udp,%s,%s,%s,%s,%s,%s,,%s\n' \
		"$LABEL" "$mode" "$dir" "$mtu" "$len" "$(gbps_from_bps "$bps")" "$pps" "$loss" "$file" >> "$TRAFFIC_CSV"
}

run_traffic_mode() {
	local mode="$1" mtu="$2" len file

	printf '[%s] VLAN mode=%s mtu=%s\n' "$LABEL" "$mode" "$mtu"
	capture "ping_${mode}_${mtu}.txt" ping -I "$DUT_VLAN" -c 5 -W 2 -n "$VLAN_PEER_IP"

	file="$RAW/${mode}_${mtu}_tcp_tx.json"
	iperf3 -c "$VLAN_PEER_IP" -B "$VLAN_LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -J \
		> "$file" 2> "$RAW/${mode}_${mtu}_tcp_tx.err" || true
	append_tcp_result "$mode" tx "$mtu" "$file"

	file="$RAW/${mode}_${mtu}_tcp_rx.json"
	iperf3 -c "$VLAN_PEER_IP" -B "$VLAN_LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -R -J \
		> "$file" 2> "$RAW/${mode}_${mtu}_tcp_rx.err" || true
	append_tcp_result "$mode" rx "$mtu" "$file"

	for len in $UDP_LENGTHS; do
		file="$RAW/${mode}_${mtu}_udp${len}_tx.json"
		iperf3 -c "$VLAN_PEER_IP" -B "$VLAN_LOCAL_IP" -p "$PORT" -t "$RUN_SECS" \
			-u -l "$len" -b "$UDP_BITRATE" -J \
			> "$file" 2> "$RAW/${mode}_${mtu}_udp${len}_tx.err" || true
		append_udp_result "$mode" tx "$mtu" "$len" "$file"

		file="$RAW/${mode}_${mtu}_udp${len}_rx.json"
		iperf3 -c "$VLAN_PEER_IP" -B "$VLAN_LOCAL_IP" -p "$PORT" -t "$RUN_SECS" \
			-u -l "$len" -b "$UDP_BITRATE" -R -J \
			> "$file" 2> "$RAW/${mode}_${mtu}_udp${len}_rx.err" || true
		append_udp_result "$mode" rx "$mtu" "$len" "$file"
	done
	record_after_mode "$mode"
}

write_readme() {
	cat > "$README" <<EOF
# HW Offload Validation - $LABEL

- UTC stamp: $STAMP
- Driver label: $LABEL
- DUT: $DUT_IFACE ($LOCAL_IP/$PREFIX), VLAN $DUT_VLAN id $VLAN_ID ($VLAN_LOCAL_IP/$VLAN_PREFIX)
- Peer: $PEER_IFACE ($PEER_IP/$PREFIX), VLAN $PEER_VLAN id $VLAN_ID ($VLAN_PEER_IP/$VLAN_PREFIX)
- Duration: ${RUN_SECS}s per iperf3 run
- UDP lengths: $UDP_LENGTHS at $UDP_BITRATE offered
- MTUs: $MTUS

Expected Rust-vs-C comparison:

- VLAN: \`tx-vlan-offload\` and \`rx-vlan-offload\` should be on when supported, and VLAN TCP/UDP traffic should stay loss-free or match the C driver's loss profile.
- RSS/RXHASH: Rust should keep \`receive-hashing\`/RXHASH off until RxDescV3/V4 parsing, multi-RX-ring state, and queue/vector programming land.
- Queues: Rust is expected to report one RX queue for now; r8169/vendor output is the baseline for a future RSS implementation.

Primary artifacts:

- \`features.csv\`
- \`traffic.csv\`
- \`queues.csv\`
- \`raw/ethtool_x.txt\`
- \`raw/ethtool_S_*.txt\`
- \`raw/interrupts_*.txt\`
EOF
}

need_cmd ip
need_cmd ethtool
need_cmd iperf3
need_cmd jq

mkdir -p "$RAW"
printf 'label,mode,proto,direction,mtu,udp_len,gbps,pps,loss_pct,retransmits,raw_json\n' > "$TRAFFIC_CSV"

setup_peer
record_preflight
write_readme

for mtu in $MTUS; do
	setup_vlan_links "$mtu"
	start_iperf_server

	set_vlan_features on
	run_traffic_mode hw_vlan_on "$mtu"

	if [[ "$TOGGLE_VLAN_OFF" == "1" ]]; then
		set_vlan_features off
		run_traffic_mode hw_vlan_off "$mtu"
		set_vlan_features on
	fi
done

capture "ethtool_k_final.txt" run_root ethtool -k "$DUT_IFACE"
capture "ip_link_final.txt" ip -d link show dev "$DUT_IFACE"
peer_cmd pkill -x iperf3 >/dev/null 2>&1 || true

printf 'Wrote %s\n' "$OUT_DIR"
