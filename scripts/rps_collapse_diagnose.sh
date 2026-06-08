#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Diagnose Rust single-queue RXHASH + software-RPS collapse under app/IRQ
# contention. This is intentionally evidence-heavy: the Track B value run showed
# a rare collapse, but did not capture enough state to distinguish a driver hash
# failure from RPS control-plane drift.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DUT_NS="${DUT_NS:-dut}"
DUT_IFACE="${DUT_IFACE:-enp3s0}"
PEER_ADDR="${PEER_ADDR:-10.0.0.1}"
PEER_PORT="${PEER_PORT:-5201}"
PCI_ADDR="${PCI_ADDR:-0000:03:00.0}"
FRAME_SIZE="${FRAME_SIZE:-64}"
DURATION="${DURATION:-10}"
REPS="${REPS:-5}"
APP_CPU="${APP_CPU:-8}"
IRQ_CPU_BASE="${IRQ_CPU_BASE:-8}"
RPS_MASK="${RPS_MASK:-fe00}"
RPS_MASK_NORM="$(printf '%08x' "$((16#$RPS_MASK))")"
APP_BIN="${APP_BIN:-/home/firestrand/app_bench}"
OUT_DIR="${OUT_DIR:-$ROOT/docs/perf/rps_collapse_$(date -u +%Y%m%d_%H%M%S)}"

RAW="$OUT_DIR/raw"
CSV="$OUT_DIR/results.csv"
mkdir -p "$RAW"

nsx() { ip netns exec "$DUT_NS" "$@"; }

need() {
	if ! command -v "$1" >/dev/null 2>&1; then
		printf 'missing required command: %s\n' "$1" >&2
		exit 1
	fi
}

need ip
need ethtool
need iperf3
need jq
need mpstat
need taskset

if [[ $EUID -ne 0 ]]; then
	printf 'run as root; this script writes IRQ affinity and rps_cpus\n' >&2
	exit 1
fi

if [[ ! -x "$APP_BIN" ]]; then
	if command -v gcc >/dev/null 2>&1 && [[ -f "$ROOT/docs/perf/trackb_20260607/app_bench.c" ]]; then
		gcc -O2 -Wall -Wextra -o "$OUT_DIR/app_bench" \
			"$ROOT/docs/perf/trackb_20260607/app_bench.c"
		APP_BIN="$OUT_DIR/app_bench"
	else
		printf 'APP_BIN not executable and app_bench.c cannot be built: %s\n' "$APP_BIN" >&2
		exit 1
	fi
fi

driver_name() {
	basename "$(readlink "/sys/bus/pci/devices/$PCI_ADDR/driver" 2>/dev/null || echo unknown)"
}

irq_total() {
	local irq="$1"
	awk -v I="$irq:" '$1==I { for (i=2; i<=NF; i++) if ($i ~ /^[0-9]+$/) s += $i }
		END { print s + 0 }' /proc/interrupts
}

detect_active_irqs() {
	local -a irqs=()
	local irq before after
	mapfile -t irqs < <(grep -iE "$PCI_ADDR" /proc/interrupts |
		awk -F: '{ gsub(/ /, "", $1); print $1 }')
	: > "$RAW/irq_detect_before.txt"
	for irq in "${irqs[@]}"; do
		printf '%s %s\n' "$irq" "$(irq_total "$irq")" >> "$RAW/irq_detect_before.txt"
	done
	flood 3 >/dev/null 2>&1 || true
	: > "$RAW/irq_detect_after.txt"
	for irq in "${irqs[@]}"; do
		after="$(irq_total "$irq")"
		before="$(awk -v q="$irq" '$1==q { print $2 }' "$RAW/irq_detect_before.txt")"
		printf '%s %s delta=%s\n' "$irq" "$after" "$((after - before))" >> "$RAW/irq_detect_after.txt"
	done
	awk '$3 ~ /^delta=/ { split($3, a, "="); if (a[2] > 2000) print $1 }' \
		"$RAW/irq_detect_after.txt"
}

pin_irqs() {
	local cpu="$IRQ_CPU_BASE"
	local irq
	: > "$RAW/irq_affinity_current.txt"
	for irq in "$@"; do
		printf '%s\n' "$cpu" > "/proc/irq/$irq/smp_affinity_list" 2>/dev/null || true
		printf '%s ' "$irq" >> "$RAW/irq_affinity_current.txt"
		cat "/proc/irq/$irq/smp_affinity_list" >> "$RAW/irq_affinity_current.txt" 2>/dev/null ||
			printf 'unreadable\n' >> "$RAW/irq_affinity_current.txt"
		cpu=$((cpu + 1))
	done
}

write_rps_mask() {
	nsx sh -c '
		set -u
		iface="$1"
		mask="$2"
		for q in /sys/class/net/"$iface"/queues/rx-*; do
			echo "$mask" > "$q/rps_cpus"
		done
	' sh "$DUT_IFACE" "$RPS_MASK"
}

read_rps_masks() {
	nsx sh -c '
		set -u
		iface="$1"
		for q in /sys/class/net/"$iface"/queues/rx-*; do
			printf "%s=%s " "$(basename "$q")" "$(cat "$q/rps_cpus")"
		done
		echo
	' sh "$DUT_IFACE" 2>/dev/null
}

capture_state() {
	local tag="$1"
	{
		printf '## %s\n' "$tag"
		date -u
		printf 'driver=%s\n' "$(driver_name)"
		printf 'rps_masks=%s\n' "$(read_rps_masks)"
		printf 'rps_sock_flow_entries='
		cat /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true
		printf '\n'
		printf 'irq_affinity\n'
		cat "$RAW/irq_affinity_current.txt" 2>/dev/null || true
		printf '\nfeatures\n'
		nsx ethtool -k "$DUT_IFACE" 2>/dev/null || true
		printf '\nstats\n'
		nsx ethtool -S "$DUT_IFACE" 2>/dev/null || true
		printf '\nsoftnet\n'
		nsx cat /proc/net/softnet_stat 2>/dev/null || true
	} > "$RAW/state_${tag}.txt"
}

stat_value() {
	local file="$1" key="$2"
	awk -F: -v k="$key" '$1 ~ k { gsub(/ /, "", $2); print $2; found=1; exit }
		END { if (!found) print 0 }' "$file"
}

softnet_drops() {
	local file="$1"
	local drops=0 hex
	while read -r _ hex _; do
		[[ -n "${hex:-}" ]] || continue
		drops=$((drops + 16#$hex))
	done < "$file"
	printf '%s\n' "$drops"
}

write_stats() {
	local tag="$1"
	nsx ethtool -S "$DUT_IFACE" > "$RAW/ethtool_S_${tag}.txt" 2>/dev/null || true
	nsx cat /proc/net/softnet_stat > "$RAW/softnet_${tag}.txt" 2>/dev/null || true
}

delta_stat() {
	local before="$1" after="$2" key="$3"
	local a b
	a="$(stat_value "$RAW/ethtool_S_${after}.txt" "$key")"
	b="$(stat_value "$RAW/ethtool_S_${before}.txt" "$key")"
	printf '%s' "$((a - b))"
}

delta_softnet_drops() {
	local before="$1" after="$2"
	local a b
	a="$(softnet_drops "$RAW/softnet_${after}.txt")"
	b="$(softnet_drops "$RAW/softnet_${before}.txt")"
	printf '%s' "$((a - b))"
}

flood() {
	nsx iperf3 -c "$PEER_ADDR" -p "$PEER_PORT" -u -b 0 -l "$FRAME_SIZE" \
		-R -P 10 -t "$1" -J 2>>"$RAW/iperf_err.log"
}

json_pps() {
	jq -r '((.end.sum.packets // 0) / (.end.sum.seconds // 1))' <<<"$1" 2>/dev/null
}

json_loss() {
	jq -r '(.end.sum.lost_percent // 0)' <<<"$1" 2>/dev/null
}

mp_cpu_field() {
	local file="$1" cpu="$2" field="$3"
	local col
	case "$field" in
		usr) col=3 ;;
		sys) col=5 ;;
		soft) col=8 ;;
		idle) col=12 ;;
		*) return 1 ;;
	esac
	awk -v c="$cpu" -v col="$col" '$1=="Average:" && $2==c { print $col; found=1 }
		END { if (!found) print 0 }' "$file"
}

mp_peak_soft() {
	local file="$1"
	awk '$1=="Average:" && $2 ~ /^[0-9]+$/ { if ($8 > max) { max=$8; cpu=$2 } }
		END { printf "%s,%.2f", cpu, max + 0 }' "$file"
}

printf 'rep,driver,rps_requested,rps_observed,active_irqs,irq_affinity,app_cpu,irq_cpu_base,app_solo_mops,p1_pps,p1_loss,p1_appcpu_soft,p1_peak_soft_cpu,p1_peak_soft,p1_rx_hash_l4_delta,p1_rx_hash_missing_delta,p1_rx_hash_disabled_delta,p1_softnet_drop_delta,p2_pps,p2_loss,p2_app_mops,p2_app_retain_pct,p2_appcpu_usr,p2_appcpu_soft,p2_peak_soft_cpu,p2_peak_soft,p2_rx_hash_l4_delta,p2_rx_hash_missing_delta,p2_rx_hash_disabled_delta,p2_softnet_drop_delta,classification\n' > "$CSV"

capture_state initial
mapfile -t ACTIVE_IRQS < <(detect_active_irqs)
pin_irqs "${ACTIVE_IRQS[@]}"
write_rps_mask
sleep 1
capture_state configured

for rep in $(seq 1 "$REPS"); do
	write_rps_mask
	rps_observed="$(read_rps_masks | tr ' ' ';' | sed 's/;$//')"
	app_solo="$("$APP_BIN" "$DURATION")"

	write_stats "r${rep}_p1_before"
	mpstat -P ALL 1 "$DURATION" > "$RAW/mp_r${rep}_p1.txt" 2>/dev/null &
	mpid=$!
	j1="$(flood "$DURATION")"
	wait "$mpid" 2>/dev/null || true
	printf '%s\n' "$j1" > "$RAW/iperf_r${rep}_p1.json"
	write_stats "r${rep}_p1_after"

	write_stats "r${rep}_p2_before"
	mpstat -P ALL 1 "$DURATION" > "$RAW/mp_r${rep}_p2.txt" 2>/dev/null &
	mpid=$!
	( taskset -c "$APP_CPU" "$APP_BIN" "$DURATION" > "$RAW/app_r${rep}.txt" ) &
	app_pid=$!
	j2="$(flood "$DURATION")"
	wait "$mpid" 2>/dev/null || true
	wait "$app_pid" 2>/dev/null || true
	printf '%s\n' "$j2" > "$RAW/iperf_r${rep}_p2.json"
	write_stats "r${rep}_p2_after"

	app_under="$(cat "$RAW/app_r${rep}.txt" 2>/dev/null || echo 0)"
	retain="$(awk -v solo="$app_solo" -v under="$app_under" \
		'BEGIN { printf "%.0f", (solo > 0) ? 100 * under / solo : 0 }')"
	p1_peak="$(mp_peak_soft "$RAW/mp_r${rep}_p1.txt")"
	p2_peak="$(mp_peak_soft "$RAW/mp_r${rep}_p2.txt")"
	p1_peak_cpu="${p1_peak%,*}"
	p1_peak_soft="${p1_peak#*,}"
	p2_peak_cpu="${p2_peak%,*}"
	p2_peak_soft="${p2_peak#*,}"
	classification="ok"
	if [[ "$rps_observed" != *"=$RPS_MASK_NORM"* ]]; then
		classification="rps_mask_mismatch"
	elif (( $(delta_stat "r${rep}_p1_before" "r${rep}_p1_after" "rx_hash_l4") <= 0 )); then
		classification="rxhash_not_incrementing"
	elif (( $(delta_stat "r${rep}_p1_before" "r${rep}_p1_after" "rx_hash_disabled") > 0 )); then
		classification="rxhash_disabled"
	elif awk -v soft="$(mp_cpu_field "$RAW/mp_r${rep}_p1.txt" "$APP_CPU" soft)" \
		'BEGIN { exit !(soft > 50) }'; then
		classification="rps_not_steering_appcpu"
	fi

	printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%.0f,%.3f,%s,%s,%s,%s,%s,%s,%s,%.0f,%.3f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
		"$rep" "$(driver_name)" "$RPS_MASK" "$rps_observed" \
		"$(IFS=';'; echo "${ACTIVE_IRQS[*]}")" \
		"$(tr '\n' ';' < "$RAW/irq_affinity_current.txt" | sed 's/;$//')" \
		"$APP_CPU" "$IRQ_CPU_BASE" "$app_solo" \
		"$(json_pps "$j1")" "$(json_loss "$j1")" \
		"$(mp_cpu_field "$RAW/mp_r${rep}_p1.txt" "$APP_CPU" soft)" \
		"$p1_peak_cpu" "$p1_peak_soft" \
		"$(delta_stat "r${rep}_p1_before" "r${rep}_p1_after" "rx_hash_l4")" \
		"$(delta_stat "r${rep}_p1_before" "r${rep}_p1_after" "rx_hash_missing")" \
		"$(delta_stat "r${rep}_p1_before" "r${rep}_p1_after" "rx_hash_disabled")" \
		"$(delta_softnet_drops "r${rep}_p1_before" "r${rep}_p1_after")" \
		"$(json_pps "$j2")" "$(json_loss "$j2")" "$app_under" "$retain" \
		"$(mp_cpu_field "$RAW/mp_r${rep}_p2.txt" "$APP_CPU" usr)" \
		"$(mp_cpu_field "$RAW/mp_r${rep}_p2.txt" "$APP_CPU" soft)" \
		"$p2_peak_cpu" "$p2_peak_soft" \
		"$(delta_stat "r${rep}_p2_before" "r${rep}_p2_after" "rx_hash_l4")" \
		"$(delta_stat "r${rep}_p2_before" "r${rep}_p2_after" "rx_hash_missing")" \
		"$(delta_stat "r${rep}_p2_before" "r${rep}_p2_after" "rx_hash_disabled")" \
		"$(delta_softnet_drops "r${rep}_p2_before" "r${rep}_p2_after")" \
		"$classification" >> "$CSV"
	printf 'rep=%s retain=%s%% class=%s p1_pps=%.0f p2_pps=%.0f rps=%s\n' \
		"$rep" "$retain" "$classification" "$(json_pps "$j1")" "$(json_pps "$j2")" "$rps_observed"
done

capture_state final
printf 'results: %s\n' "$CSV"
