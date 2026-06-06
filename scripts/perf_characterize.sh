#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# perf_characterize.sh — Tier 2 of docs/POST_SOAK_PLAN.md.
#
# Closes the deferred items in docs/perf/r8169_comparison.md by
# running four perf characterizations against the local driver:
#
#   2a Bidirectional saturation        — TCP both directions @ line rate
#   2b p99 latency under load          — 1000 pings at 0.05 s + 100 Mbps iperf3
#   2c Small-packet pps                — UDP -l 64 -b 1G one-way
#   2d Fresh h→g + UDP captures        — TCP and UDP, both directions, MTUs 1500 + 9000
#
# Writes JSON outputs to docs/perf/captures/ and a markdown
# summary table the operator pastes into r8169_comparison.md.
#
# Expects: iperf3 server running on $PEER:$PORT, peer MTU adjustable.
# Default: KVM controller-guest topology (10.0.0.2 → 10.0.0.1).
#
# Usage:
#   scripts/perf_characterize.sh
#   IFACE=enp3s0 PEER=10.0.0.1 scripts/perf_characterize.sh
#   ONLY=2b scripts/perf_characterize.sh   # one sub-run only
#
# KVM/debug-guest note:
#   Single-stream UDP TX at MTU 1500 is an iperf3/userspace packet-rate
#   bottleneck on the KVM guest, and collapses for both r8169 and this driver.
#   The default 2d guest→host UDP-1500 shape therefore uses 10 streams at
#   250M each. Override UDP_G2H_1500_STREAMS=1 UDP_G2H_1500_BITRATE=3G when
#   intentionally measuring the single-stream iperf3 ceiling.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

IFACE=${IFACE:-enp5s0}
PEER=${PEER:-10.0.0.1}
LOCAL_IP=${LOCAL_IP:-10.0.0.2}
LOCAL_PREFIX=${LOCAL_PREFIX:-24}
PORT=${PORT:-5380}
RUN_SECS=${RUN_SECS:-10}
ONLY=${ONLY:-}                          # "2a" | "2b" | "2c" | "2d" | ""
UDP_DEFAULT_BITRATE=${UDP_DEFAULT_BITRATE:-3G}
UDP_G2H_1500_STREAMS=${UDP_G2H_1500_STREAMS:-10}
UDP_G2H_1500_BITRATE=${UDP_G2H_1500_BITRATE:-250M}

STAMP=$(date -u +'%Y%m%d_%H%M%S')
OUT_DIR="$ROOT/docs/perf/captures/${STAMP}"
SUMMARY="$ROOT/docs/perf/captures/${STAMP}/SUMMARY.md"
mkdir -p "$OUT_DIR"

run_if() {
	local id="$1"; shift
	if [[ -n "$ONLY" && "$ONLY" != "$id" ]]; then
		return 0
	fi
	"$@"
}

extract_bps() {
	jq -r '.end.sum_received.bits_per_second // .end.sum.bits_per_second' "$1" 2>/dev/null
}

extract_retr() {
	jq -r '.end.sum_received.retransmits // .end.sum_sent.retransmits // 0' "$1" 2>/dev/null
}

extract_loss() {
	jq -r '.end.sum.lost_percent // 0' "$1" 2>/dev/null
}

gbps() {
	# bits/s -> Gbps with 3 decimals
	awk "BEGIN { printf \"%.3f\", $1/1e9 }"
}

udp_shape() {
	local dir="$1" mtu="$2"
	if [[ "$dir" == "g2h" && "$mtu" == "1500" ]]; then
		printf '%sx%s' "$UDP_G2H_1500_STREAMS" "$UDP_G2H_1500_BITRATE"
	else
		printf '1x%s' "$UDP_DEFAULT_BITRATE"
	fi
}

udp_args_for() {
	local dir="$1" mtu="$2" blk="$3"
	UDP_ARGS=(-u -l "$blk")
	if [[ "$dir" == "g2h" && "$mtu" == "1500" ]]; then
		UDP_ARGS+=(-b "$UDP_G2H_1500_BITRATE")
		if (( UDP_G2H_1500_STREAMS > 1 )); then
			UDP_ARGS+=(-P "$UDP_G2H_1500_STREAMS")
		fi
	else
		UDP_ARGS+=(-b "$UDP_DEFAULT_BITRATE")
	fi
}

# Address must be ready.
sudo ip addr add "$LOCAL_IP/$LOCAL_PREFIX" dev "$IFACE" 2>/dev/null || true

cat > "$SUMMARY" <<EOF
# Perf characterization run — ${STAMP}

- Iface: $IFACE  ($LOCAL_IP/$LOCAL_PREFIX → $PEER:$PORT)
- iperf3 duration: ${RUN_SECS}s per direction
- UDP default bitrate: ${UDP_DEFAULT_BITRATE}; UDP g2h MTU1500 shape: $(udp_shape g2h 1500)
- Driver: r8125_rust (commit $(cd "$ROOT" && git rev-parse --short HEAD 2>/dev/null))
- Kernel: $(uname -r)

EOF

# ----- 2a: bidirectional saturation -----
sub_2a() {
	echo "[2a] bidirectional saturation..."
	local mtu
	for mtu in 1500 9000; do
		# Peer must match. We can't drive the peer from here; assume operator set it.
		sudo ip link set "$IFACE" mtu "$mtu" 2>/dev/null || true
		sleep 2
		# Forward (guest→host) and reverse (host→guest) at once, in parallel.
		iperf3 -c "$PEER" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -J \
			> "$OUT_DIR/2a_g2h_tcp_${mtu}.json" 2>&1 &
		PID_FWD=$!
		iperf3 -c "$PEER" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -J -R \
			> "$OUT_DIR/2a_h2g_tcp_${mtu}.json" 2>&1 &
		PID_REV=$!
		wait $PID_FWD
		wait $PID_REV
		fwd=$(gbps "$(extract_bps "$OUT_DIR/2a_g2h_tcp_${mtu}.json")")
		rev=$(gbps "$(extract_bps "$OUT_DIR/2a_h2g_tcp_${mtu}.json")")
		fwd_retr=$(extract_retr "$OUT_DIR/2a_g2h_tcp_${mtu}.json")
		rev_retr=$(extract_retr "$OUT_DIR/2a_h2g_tcp_${mtu}.json")
		cat >> "$SUMMARY" <<EOF

## 2a — Bidirectional saturation @ MTU $mtu

| Direction | Throughput (Gbps) | Retransmits |
|---|---:|---:|
| guest → host | $fwd | $fwd_retr |
| host → guest | $rev | $rev_retr |

EOF
	done
	sudo ip link set "$IFACE" mtu 1500 2>/dev/null || true
}

# ----- 2b: p99 latency under load -----
sub_2b() {
	echo "[2b] p99 latency under load..."
	# 100 Mbps iperf3 in the background, 1000 pings at 0.05s spacing in foreground.
	iperf3 -c "$PEER" -B "$LOCAL_IP" -p "$PORT" -t 60 -b 100M -J \
		> "$OUT_DIR/2b_bg_iperf.json" 2>&1 &
	BG_PID=$!
	sleep 2
	ping -c 1000 -i 0.05 -q "$PEER" > "$OUT_DIR/2b_ping.txt" 2>&1 || true
	wait $BG_PID 2>/dev/null || true

	# parse rtt = min/avg/max/mdev
	rtt_line=$(grep '^rtt' "$OUT_DIR/2b_ping.txt" 2>/dev/null | head -1)
	p99=$(awk -F'/' '/rtt/ { print $7 }' "$OUT_DIR/2b_ping.txt" 2>/dev/null)
	loss=$(grep -oE '[0-9.]+% packet loss' "$OUT_DIR/2b_ping.txt" | head -1)

	cat >> "$SUMMARY" <<EOF

## 2b — p99 latency under 100 Mbps load

- Ping: 1000 × ICMP, 0.05s spacing, in parallel with 100 Mbps iperf3 TCP
- RTT (min/avg/max/mdev ms): \`$rtt_line\`
- Approx p99 proxy (max): $p99 ms  *(true p99 needs sort; see raw file)*
- Loss: $loss

EOF
}

# ----- 2c: small-packet pps -----
sub_2c() {
	echo "[2c] small-packet pps..."
	iperf3 -c "$PEER" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -u -l 64 -b 1G -J \
		> "$OUT_DIR/2c_udp_64B.json" 2>&1 || true
	bps=$(extract_bps "$OUT_DIR/2c_udp_64B.json")
	loss=$(extract_loss "$OUT_DIR/2c_udp_64B.json")
	# pps = bps / (64*8)
	pps=$(awk "BEGIN { printf \"%.0f\", $bps/512 }")
	cat >> "$SUMMARY" <<EOF

## 2c — Small-packet pps (UDP 64B, 1 Gbps offered)

- Achieved: $(gbps "$bps") Gbps
- Estimated pps: $pps
- Loss: $loss %

EOF
}

# ----- 2d: fresh h→g + UDP captures for r8169_comparison.md -----
sub_2d() {
	echo "[2d] fresh h→g + UDP captures..."
	local mtu proto dir blk
	for mtu in 1500 9000; do
		sudo ip link set "$IFACE" mtu "$mtu" 2>/dev/null || true
		sleep 2

		# TCP both directions
		for dir in g2h h2g; do
			flag=""
			[[ "$dir" == "h2g" ]] && flag="-R"
			iperf3 -c "$PEER" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" -J $flag \
				> "$OUT_DIR/2d_${dir}_tcp_${mtu}.json" 2>&1 || true
		done

		# UDP both directions
		[[ "$mtu" == "9000" ]] && blk="8948" || blk="1448"
		for dir in g2h h2g; do
			flag=""
			[[ "$dir" == "h2g" ]] && flag="-R"
			udp_args_for "$dir" "$mtu" "$blk"
			iperf3 -c "$PEER" -B "$LOCAL_IP" -p "$PORT" -t "$RUN_SECS" "${UDP_ARGS[@]}" -J $flag \
				> "$OUT_DIR/2d_${dir}_udp_${mtu}.json" 2>&1 || true
		done
	done
	sudo ip link set "$IFACE" mtu 1500 2>/dev/null || true

	{
		echo
		echo "## 2d — Fresh capture matrix"
		echo
		echo "| Proto | Dir | MTU | Throughput | Retr / Loss | Shape |"
		echo "|---|---|---:|---:|---:|---|"
		for mtu in 1500 9000; do
			for proto in tcp udp; do
				for dir in g2h h2g; do
					f="$OUT_DIR/2d_${dir}_${proto}_${mtu}.json"
					if [[ -s "$f" ]]; then
						bps=$(extract_bps "$f")
						gb=$(gbps "$bps")
						if [[ "$proto" == "tcp" ]]; then
							retr=$(extract_retr "$f")
							echo "| TCP | $dir | $mtu | $gb Gbps | $retr retr | single stream |"
						else
							loss=$(extract_loss "$f")
							echo "| UDP | $dir | $mtu | $gb Gbps | $loss % loss | $(udp_shape "$dir" "$mtu") |"
						fi
					fi
				done
			done
		done
	} >> "$SUMMARY"
}

run_if 2a sub_2a
run_if 2b sub_2b
run_if 2c sub_2c
run_if 2d sub_2d

cat >> "$SUMMARY" <<EOF

## Next steps

1. Paste the 2d table rows into \`docs/perf/r8169_comparison.md\`
   under §"TCP, single stream" + §"UDP" to close
   the *pending* lines.
2. Paste the 2a + 2b + 2c sections into a new §"Tier 2 expanded
   capture" of \`r8169_comparison.md\`.
3. Compare bidirectional rates against the unidirectional baseline
   to detect TX/RX arbitration anomalies.
4. Archive this directory ($OUT_DIR) for later comparison.
EOF

echo
echo "Summary: $SUMMARY"
echo "Captures: $OUT_DIR/*.json (and 2b_ping.txt)"
