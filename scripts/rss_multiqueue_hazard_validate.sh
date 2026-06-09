#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RTL8125 full-RSS hazard validation.
#
# This is the hardware/runtime proof required before declaring N>1 hardware RSS
# safe. It targets the RTL8125 RSS failure classes that do not show up in host
# unit tests:
#   - hash/queue programming exists but RX work does not distribute,
#   - small-packet or fragmented UDP stress drops/reorders packets,
#   - bulk TCP data is corrupted,
#   - IRQ/kworker loops keep burning CPU after traffic stops.
#
# Expected setup: DUT uses r8125_rust, peer is directly connected and can live
# in a netns. The driver must already be loaded with enough RSS queues; this
# harness refuses to pass unless ethtool/sysfs report at least MIN_RX_QUEUES.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DUT_IFACE="${DUT_IFACE:-enp3s0}"
PEER_IFACE="${PEER_IFACE:-enp4s0}"
PEER_NS="${PEER_NS:-peer}"
USE_PEER_NS="${USE_PEER_NS:-1}"
PCI_ADDR="${PCI_ADDR:-0000:03:00.0}"

DUT_IP="${DUT_IP:-10.0.0.2}"
PEER_IP="${PEER_IP:-10.0.0.1}"
PREFIX="${PREFIX:-24}"
PORT="${PORT:-5201}"
TCP_INTEGRITY_PORT="${TCP_INTEGRITY_PORT:-5209}"

MIN_RX_QUEUES="${MIN_RX_QUEUES:-2}"
DURATION="${DURATION:-20}"
REPS="${REPS:-3}"
UDP_PARALLEL="${UDP_PARALLEL:-10}"
UDP_BITRATE="${UDP_BITRATE:-0}"
SMALL_UDP_LEN="${SMALL_UDP_LEN:-64}"
FRAG_UDP_LEN="${FRAG_UDP_LEN:-4096}"
TCP_BYTES_MB="${TCP_BYTES_MB:-128}"
KWORKER_MAX_PCPU="${KWORKER_MAX_PCPU:-25}"
MAX_UDP_LOSS_PCT="${MAX_UDP_LOSS_PCT:-0.1}"
QUIET_MAX_IRQ_DELTA="${QUIET_MAX_IRQ_DELTA:-100}"
QUIET_SECS="${QUIET_SECS:-5}"
MIN_ACTIVE_RX_IRQS="${MIN_ACTIVE_RX_IRQS:-2}"
LABEL="${LABEL:-rust_rss_n_gt_1}"

STAMP="$(date -u +'%Y%m%d_%H%M%S')"
OUT_DIR="${OUT_DIR:-"$ROOT/docs/perf/rss_multiqueue_hazard_${STAMP}"}"
RAW="$OUT_DIR/raw"
RESULTS="$OUT_DIR/results.csv"
IRQ_CSV="$OUT_DIR/irq_deltas.csv"
CPU_CSV="$OUT_DIR/cpu_watch.csv"
INTEGRITY_CSV="$OUT_DIR/integrity.csv"
SUMMARY="$OUT_DIR/SUMMARY.md"

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

setup_link() {
	run_root nmcli dev set "$DUT_IFACE" managed no >/dev/null 2>&1 || true
	run_root nmcli dev set "$PEER_IFACE" managed no >/dev/null 2>&1 || true

	if [[ "$USE_PEER_NS" == "1" ]]; then
		run_root ip netns del "$PEER_NS" >/dev/null 2>&1 || true
		run_root ip netns add "$PEER_NS"
		run_root ip link set "$PEER_IFACE" netns "$PEER_NS"
		peer_cmd ip link set lo up
	fi

	run_root ip addr flush dev "$DUT_IFACE" || true
	run_root ip addr add "$DUT_IP/$PREFIX" dev "$DUT_IFACE" || true
	run_root ip link set "$DUT_IFACE" up

	peer_cmd ip addr flush dev "$PEER_IFACE" || true
	peer_cmd ip addr add "$PEER_IP/$PREFIX" dev "$PEER_IFACE" || true
	peer_cmd ip link set "$PEER_IFACE" up
}

rx_queue_count() {
	find "/sys/class/net/$DUT_IFACE/queues" -maxdepth 1 -name 'rx-*' 2>/dev/null | wc -l
}

current_ethtool_rx_count() {
	ethtool -l "$DUT_IFACE" 2>/dev/null |
		awk '
			/^Current hardware settings:/ { current=1; next }
			current && /^RX:/ { print $2; found=1; exit }
			END { if (!found) print 0 }
		'
}

preflight_rss_enabled() {
	local sysfs_rx ethtool_rx
	sysfs_rx="$(rx_queue_count)"
	ethtool_rx="$(current_ethtool_rx_count)"

	capture "ethtool_i.txt" ethtool -i "$DUT_IFACE"
	capture "ethtool_l.txt" ethtool -l "$DUT_IFACE"
	capture "ethtool_x.txt" ethtool -x "$DUT_IFACE"
	capture "ethtool_k.txt" ethtool -k "$DUT_IFACE"
	capture "ethtool_T.txt" ethtool -T "$DUT_IFACE"
	capture "ethtool_S_before.txt" ethtool -S "$DUT_IFACE"

	if (( sysfs_rx < MIN_RX_QUEUES && ethtool_rx < MIN_RX_QUEUES )); then
		die "full RSS is not active: sysfs_rx=$sysfs_rx ethtool_rx=$ethtool_rx min=$MIN_RX_QUEUES"
	fi
	if ! ethtool -k "$DUT_IFACE" 2>/dev/null | grep -Eq 'receive-hashing:[[:space:]]+on'; then
		die "receive-hashing must be on for full RSS hazard validation"
	fi
}

interrupt_snapshot() {
	local tag="$1"
	grep -iE "$PCI_ADDR|$DUT_IFACE|r8125_rust|r8125" /proc/interrupts > "$RAW/interrupts_${tag}.txt" || true
}

irq_total_from_file() {
	local irq="$1" file="$2"
	awk -v I="$irq:" '$1==I { for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+$/) s += $i }
		END { print s + 0 }' "$file"
}

record_irq_delta() {
	local before="$1" after="$2" mode="$3"
	local irq before_total after_total desc delta

	while read -r irq _; do
		irq="${irq%:}"
		[[ "$irq" =~ ^[0-9]+$ ]] || continue
		before_total="$(irq_total_from_file "$irq" "$RAW/interrupts_${before}.txt")"
		after_total="$(irq_total_from_file "$irq" "$RAW/interrupts_${after}.txt")"
		delta="$((after_total - before_total))"
		desc="$(awk -v I="$irq:" '$1==I { for (i=2; i<=NF; i++) if ($i !~ /^[0-9]+$/) printf "%s_", $i }' "$RAW/interrupts_${after}.txt")"
		printf '%s,%s,%s,%s,%s,%s\n' "$LABEL" "$mode" "$irq" "$before_total" "$after_total" "$delta" >> "$IRQ_CSV"
		printf '%s,%s,%s\n' "$mode" "$irq" "$desc" >> "$RAW/irq_desc.csv"
	done < "$RAW/interrupts_${after}.txt"
}

active_rx_vectors() {
	local mode="$1"
	awk -F, -v mode="$mode" -v min=1000 '$2==mode && $6 >= min { n++ } END { print n + 0 }' "$IRQ_CSV"
}

json_field() {
	local file="$1" expr="$2"
	jq -r "$expr" "$file" 2>/dev/null
}

json_loss_pct() {
	json_field "$1" '(.end.sum.lost_percent // .end.sum_received.lost_percent // .end.sum_sent.lost_percent // 0)'
}

json_out_of_order() {
	json_field "$1" '(.end.sum.out_of_order // .end.sum_received.out_of_order // .end.sum_sent.out_of_order // 0)'
}

json_packets() {
	json_field "$1" '(.end.sum.packets // .end.sum_received.packets // .end.sum_sent.packets // 0)'
}

json_bps() {
	json_field "$1" '(.end.sum.bits_per_second // .end.sum_received.bits_per_second // .end.sum_sent.bits_per_second // 0)'
}

stat_value() {
	local file="$1" key="$2"
	awk -F: -v k="$key" '$1 ~ k { gsub(/ /, "", $2); print $2; found=1; exit }
		END { if (!found) print 0 }' "$file"
}

record_driver_stats_delta() {
	local before="$1" after="$2" mode="$3"
	local rx_drop_before rx_drop_after hash_missing_before hash_missing_after
	rx_drop_before="$(stat_value "$RAW/ethtool_S_${before}.txt" rx_dropped_error)"
	rx_drop_after="$(stat_value "$RAW/ethtool_S_${after}.txt" rx_dropped_error)"
	hash_missing_before="$(stat_value "$RAW/ethtool_S_${before}.txt" rx_hash_missing)"
	hash_missing_after="$(stat_value "$RAW/ethtool_S_${after}.txt" rx_hash_missing)"
	printf '%s,%s,rx_dropped_delta,%s\n' "$LABEL" "$mode" "$((rx_drop_after - rx_drop_before))" >> "$RESULTS"
	printf '%s,%s,rx_hash_missing_delta,%s\n' "$LABEL" "$mode" "$((hash_missing_after - hash_missing_before))" >> "$RESULTS"
}

start_iperf_server() {
	peer_cmd pkill -x iperf3 >/dev/null 2>&1 || true
	peer_cmd iperf3 -s -B "$PEER_IP" -p "$PORT" -D
	sleep 1
}

run_udp_case() {
	local mode="$1" length="$2"
	local file="$RAW/${mode}.json"

	interrupt_snapshot "${mode}_irq_before"
	ethtool -S "$DUT_IFACE" > "$RAW/ethtool_S_${mode}_before.txt" 2>/dev/null || true
	mpstat -P ALL 1 "$DURATION" > "$RAW/mpstat_${mode}.txt" 2>/dev/null &
	local mpid=$!
	iperf3 -c "$PEER_IP" -B "$DUT_IP" -p "$PORT" -u -l "$length" -b "$UDP_BITRATE" \
		-R -P "$UDP_PARALLEL" -t "$DURATION" -J \
		> "$file" 2> "$RAW/${mode}.err" || true
	wait "$mpid" 2>/dev/null || true
	ethtool -S "$DUT_IFACE" > "$RAW/ethtool_S_${mode}_after.txt" 2>/dev/null || true
	interrupt_snapshot "${mode}_irq_after"
	record_irq_delta "${mode}_irq_before" "${mode}_irq_after" "$mode"
	record_driver_stats_delta "${mode}_before" "${mode}_after" "$mode"
	printf '%s,%s,udp_len,%s\n' "$LABEL" "$mode" "$length" >> "$RESULTS"
	printf '%s,%s,udp_packets,%s\n' "$LABEL" "$mode" "$(json_packets "$file")" >> "$RESULTS"
	printf '%s,%s,udp_loss_pct,%s\n' "$LABEL" "$mode" "$(json_loss_pct "$file")" >> "$RESULTS"
	printf '%s,%s,udp_out_of_order,%s\n' "$LABEL" "$mode" "$(json_out_of_order "$file")" >> "$RESULTS"
	printf '%s,%s,udp_gbps,%s\n' "$LABEL" "$mode" "$(awk -v b="$(json_bps "$file")" 'BEGIN { printf "%.3f", b / 1e9 }')" >> "$RESULTS"
	printf '%s,%s,active_rx_vectors,%s\n' "$LABEL" "$mode" "$(active_rx_vectors "$mode")" >> "$RESULTS"
}

run_tcp_integrity() {
	local bytes="$((TCP_BYTES_MB * 1024 * 1024))"
	local src="$RAW/tcp_integrity_src.bin"
	local dst="/tmp/rss_integrity_${STAMP}.bin"
	local src_hash dst_hash rc=0

	dd if=/dev/urandom of="$src" bs=1M count="$TCP_BYTES_MB" status=none
	src_hash="$(sha256sum "$src" | awk '{print $1}')"
	peer_cmd rm -f "$dst"
	peer_cmd sh -c "timeout $((DURATION + 30)) nc -l -p '$TCP_INTEGRITY_PORT' -s '$PEER_IP' > '$dst'" &
	local lpid=$!
	sleep 1
	timeout $((DURATION + 30)) nc "$PEER_IP" "$TCP_INTEGRITY_PORT" < "$src" || rc=$?
	wait "$lpid" 2>/dev/null || true
	dst_hash="$(peer_cmd sha256sum "$dst" 2>/dev/null | awk '{print $1}')"
	peer_cmd rm -f "$dst"

	printf 'label,bytes,src_sha256,dst_sha256,match,nc_rc\n' > "$INTEGRITY_CSV"
	printf '%s,%s,%s,%s,%s,%s\n' "$LABEL" "$bytes" "$src_hash" "$dst_hash" \
		"$([[ "$src_hash" == "$dst_hash" ]] && echo yes || echo no)" "$rc" >> "$INTEGRITY_CSV"
}

sample_kworkers() {
	local tag="$1"
	ps -eo comm,pcpu,pid --no-headers |
		awk -v label="$LABEL" -v tag="$tag" '$1 ~ /^kworker/ {
			printf "%s,%s,%s,%s,%s\n", label, tag, $1, $2, $3
		}' >> "$CPU_CSV"
}

max_kworker_pcpu() {
	awk -F, 'NR > 1 && $3 ~ /^kworker/ && $4 > max { max=$4 } END { print max + 0 }' "$CPU_CSV"
}

max_irq_delta() {
	local mode="$1"
	awk -F, -v mode="$mode" '$2==mode && $6 > max { max=$6 } END { print max + 0 }' "$IRQ_CSV"
}

quiet_irq_loop_check() {
	interrupt_snapshot quiet_before
	sample_kworkers quiet_before
	sleep "$QUIET_SECS"
	sample_kworkers quiet_after
	interrupt_snapshot quiet_after
	record_irq_delta quiet_before quiet_after quiet
	printf '%s,quiet,max_kworker_pcpu,%s\n' "$LABEL" "$(max_kworker_pcpu)" >> "$RESULTS"
	printf '%s,quiet,active_rx_vectors,%s\n' "$LABEL" "$(active_rx_vectors quiet)" >> "$RESULTS"
}

fault_scan() {
	dmesg | grep -niE 'panic|oops|BUG:|WARNING:|call trace|soft lockup|hard lockup|rcu.*stall|watchdog|general protection|DMA-API|corrupt|skb|page allocation failure|NETDEV WATCHDOG' \
		> "$RAW/fault_scan.txt" || true
}

write_summary() {
	cat > "$SUMMARY" <<EOF
# RTL8125 Full-RSS Hazard Validation - $LABEL

- UTC: $STAMP
- DUT: $DUT_IFACE $DUT_IP/$PREFIX
- Peer: $PEER_IFACE $PEER_IP/$PREFIX (netns=$USE_PEER_NS:$PEER_NS)
- Required RX queues: >= $MIN_RX_QUEUES
- UDP stress: ${SMALL_UDP_LEN}B and ${FRAG_UDP_LEN}B datagrams, -P $UDP_PARALLEL, $DURATION seconds, bitrate=$UDP_BITRATE
- TCP integrity: ${TCP_BYTES_MB} MiB sha256 over nc
- kworker ceiling: ${KWORKER_MAX_PCPU}% during quiet check

Pass criteria for N>1 RSS:

1. \`small_udp\` and \`fragmented_udp\` have \`udp_out_of_order=0\`, acceptable loss for the offered load, and no driver \`rx_dropped_error\` growth.
2. Both UDP modes show at least \`MIN_ACTIVE_RX_IRQS=$MIN_ACTIVE_RX_IRQS\` active RX vectors.
3. \`integrity.csv\` reports matching SHA-256 hashes.
4. The quiet window has no sustained IRQ loop and max kworker CPU stays below \`KWORKER_MAX_PCPU=$KWORKER_MAX_PCPU\`.
5. \`raw/fault_scan.txt\` is empty.
6. \`raw/ethtool_T.txt\` captures timestamping capabilities. The current driver
   does not expose hardware timestamping; if that changes, this same RSS hazard
   run must be repeated with timestamping enabled.

Primary artifacts:

- \`results.csv\`
- \`irq_deltas.csv\`
- \`cpu_watch.csv\`
- \`integrity.csv\`
- \`raw/mpstat_*.txt\`
- \`raw/interrupts_*.txt\`
- \`raw/ethtool_S_*.txt\`
- \`raw/fault_scan.txt\`
EOF
}

metric_value() {
	local mode="$1" metric="$2"
	awk -F, -v mode="$mode" -v metric="$metric" \
		'$2==mode && $3==metric { print $4; found=1; exit }
		 END { if (!found) print "missing" }' "$RESULTS"
}

num_le() {
	awk -v a="$1" -v b="$2" 'BEGIN { exit !(a <= b) }'
}

num_eq_zero() {
	awk -v a="$1" 'BEGIN { exit !(a == 0) }'
}

evaluate_results() {
	local rc=0 mode loss ooo rx_dropped vectors max_kworker quiet_delta

	check_fail() {
		printf 'FAIL: %s\n' "$*" | tee -a "$SUMMARY"
		rc=1
	}
	check_pass() {
		printf 'PASS: %s\n' "$*" >> "$SUMMARY"
	}

	{
		printf '\n## Verdict\n\n'
		printf 'Configured thresholds: MAX_UDP_LOSS_PCT=%s, MIN_ACTIVE_RX_IRQS=%s, KWORKER_MAX_PCPU=%s, QUIET_MAX_IRQ_DELTA=%s\n\n' \
			"$MAX_UDP_LOSS_PCT" "$MIN_ACTIVE_RX_IRQS" "$KWORKER_MAX_PCPU" "$QUIET_MAX_IRQ_DELTA"
	} >> "$SUMMARY"

	for mode in small_udp fragmented_udp; do
		loss="$(metric_value "$mode" udp_loss_pct)"
		ooo="$(metric_value "$mode" udp_out_of_order)"
		rx_dropped="$(metric_value "$mode" rx_dropped_delta)"
		vectors="$(metric_value "$mode" active_rx_vectors)"

		if [[ "$loss" == "missing" ]] || ! num_le "$loss" "$MAX_UDP_LOSS_PCT"; then
			check_fail "$mode loss_pct=$loss exceeds $MAX_UDP_LOSS_PCT"
		else
			check_pass "$mode loss_pct=$loss"
		fi
		if [[ "$ooo" == "missing" ]] || ! num_eq_zero "$ooo"; then
			check_fail "$mode udp_out_of_order=$ooo"
		else
			check_pass "$mode udp_out_of_order=0"
		fi
		if [[ "$rx_dropped" == "missing" ]] || ! num_eq_zero "$rx_dropped"; then
			check_fail "$mode rx_dropped_delta=$rx_dropped"
		else
			check_pass "$mode rx_dropped_delta=0"
		fi
		if [[ "$vectors" == "missing" ]] || (( vectors < MIN_ACTIVE_RX_IRQS )); then
			check_fail "$mode active_rx_vectors=$vectors below $MIN_ACTIVE_RX_IRQS"
		else
			check_pass "$mode active_rx_vectors=$vectors"
		fi
	done

	if ! awk -F, 'NR==2 && $5=="yes" && $6==0 { ok=1 } END { exit !ok }' "$INTEGRITY_CSV"; then
		check_fail "TCP integrity SHA-256 mismatch or nc failed"
	else
		check_pass "TCP integrity SHA-256 matched"
	fi

	max_kworker="$(max_kworker_pcpu)"
	if ! num_le "$max_kworker" "$KWORKER_MAX_PCPU"; then
		check_fail "max kworker CPU $max_kworker exceeds $KWORKER_MAX_PCPU"
	else
		check_pass "max kworker CPU $max_kworker"
	fi

	quiet_delta="$(max_irq_delta quiet)"
	if ! num_le "$quiet_delta" "$QUIET_MAX_IRQ_DELTA"; then
		check_fail "quiet IRQ delta $quiet_delta exceeds $QUIET_MAX_IRQ_DELTA"
	else
		check_pass "quiet IRQ delta $quiet_delta"
	fi

	if [[ -s "$RAW/fault_scan.txt" ]]; then
		check_fail "kernel fault signatures found in raw/fault_scan.txt"
	else
		check_pass "kernel fault scan clean"
	fi

	return "$rc"
}

need_cmd ip
need_cmd ethtool
need_cmd iperf3
need_cmd jq
need_cmd mpstat
need_cmd nc
need_cmd sha256sum

mkdir -p "$RAW"
printf 'label,mode,metric,value\n' > "$RESULTS"
printf 'label,mode,irq,before,after,delta\n' > "$IRQ_CSV"
printf 'label,tag,comm,pcpu,pid\n' > "$CPU_CSV"
: > "$RAW/irq_desc.csv"

setup_link
preflight_rss_enabled
start_iperf_server
run_udp_case small_udp "$SMALL_UDP_LEN"
run_udp_case fragmented_udp "$FRAG_UDP_LEN"
run_tcp_integrity
quiet_irq_loop_check
fault_scan
write_summary
evaluate_results || exit 1

printf 'wrote %s\n' "$OUT_DIR"
