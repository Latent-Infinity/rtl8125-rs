#!/usr/bin/env bash
# rt8125-run.sh — verb-driven build / deploy / gates / collect with a manifest
# per step, enforcing the Measurement Contract for runtime gates. Target-aware:
#
#   gateway — single-host netns rig (wraps gw_loopback.sh: dut/peer netns).
#   kvm     — 2-node rig: guest enp5s0 (DUT) <-> THIS controller's enp4s0
#             (iperf peer). Build + load happen in-guest (no gw_loopback).
#
# See docs/BUILD_TEST_ORCHESTRATION.md.
#
#   rt8125-run.sh build  --target gateway|kvm
#   rt8125-run.sh deploy --target gateway|kvm --params "rss_queues=4"
#   rt8125-run.sh gates  --target gateway --group mq
#   rt8125-run.sh gates  --target kvm --group tcp
#   rt8125-run.sh collect --target gateway --run-id <id>
#
# --dry-run prints the plan and writes a manifest WITHOUT touching the target.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rt8125-env.sh
. "$HERE/rt8125-env.sh"
rt8125_load_config

[ $# -ge 1 ] || rt8125_die "usage: rt8125-run.sh <build|deploy|gates|collect> [opts]"
VERB="$1"; shift

TARGET=gateway GROUP="" PARAMS="" RUN_ID="" DRY=0
while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="$2"; shift 2 ;;
		--group)  GROUP="$2"; shift 2 ;;
		--params) PARAMS="$2"; shift 2 ;;
		--run-id) RUN_ID="$2"; shift 2 ;;
		--dry-run) DRY=1; shift ;;
		-h|--help) sed -n '2,18p' "$0"; exit 0 ;;
		*) rt8125_die "unknown arg: $1" ;;
	esac
done
[ -n "$RUN_ID" ] && export RT8125_RUN_ID="$RUN_ID"

rt8125_verify_repo_root
rt8125_target_configured "$TARGET" ||
	rt8125_die "$TARGET unconfigured — fill config/devices.env, then retry"
case "$TARGET" in
	gateway|kvm) : ;;
	*) rt8125_die "runtime verbs target gateway|kvm (got: $TARGET)" ;;
esac

# ── Target resolution: one place maps TARGET -> the per-host facts ───────────
# T_BUILD is the make prefix; KVM needs rustc-1.93 on PATH, the gateway Makefile
# pins it itself.
case "$TARGET" in
	gateway)
		T_HOST="$GATEWAY_HOST"; T_REPO="$GATEWAY_REPO_ROOT"; T_KO="$GATEWAY_KO"
		T_IFACE="$GATEWAY_IFACE"; T_BDF="$GATEWAY_BDF"; T_KFAM="$GATEWAY_KERNEL_FAMILY"
		T_PEER_IP="$GATEWAY_PEER_IP"; T_BUILD="make" ;;
	kvm)
		T_HOST="$KVM_HOST"; T_REPO="$KVM_REPO_ROOT"; T_KO="$KVM_KO"
		T_IFACE="$KVM_IFACE"; T_BDF="$KVM_BDF"; T_KFAM="$KVM_KERNEL_FAMILY"
		T_PEER_IP="$KVM_PEER_IP"; T_BUILD="PATH=/usr/lib/rust-1.93/bin:\$PATH make" ;;
esac

HOST="$T_HOST"
DIR="$(rt8125_run_dir "$TARGET" "$VERB")"
MAN="$DIR/manifest.env"
rt8125_header "$TARGET" "$VERB" "$DIR"

manifest_common() {
	rt8125_manifest_set "$MAN" RUN_ID "$(basename "$DIR")"
	rt8125_manifest_set "$MAN" TARGET "$TARGET"
	rt8125_manifest_set "$MAN" OPERATION "$VERB"
	rt8125_manifest_set "$MAN" GATE_GROUP "${GROUP:-none}"
	rt8125_manifest_set "$MAN" SOURCE_COMMIT "$(rt8125_git_describe)"
	rt8125_manifest_set "$MAN" SOURCE_DIR "$REPO_ROOT"
	rt8125_manifest_set "$MAN" TARGET_HOST "$HOST"
	rt8125_manifest_set "$MAN" TARGET_REPO_ROOT "$T_REPO"
	rt8125_manifest_set "$MAN" TARGET_IFACE "$T_IFACE"
	rt8125_manifest_set "$MAN" TARGET_BDF "$T_BDF"
	rt8125_manifest_set "$MAN" MODULE_PARAMS "${PARAMS:-}"
}

remote_kernel() { ssh -o BatchMode=yes "$HOST" 'uname -r' 2>/dev/null || echo unknown; }
built_srcver()  { ssh -o BatchMode=yes "$HOST" "modinfo -F srcversion '$T_KO'" 2>/dev/null || echo none; }
loaded_srcver() { ssh -o BatchMode=yes "$HOST" 'cat /sys/module/r8125_rust/srcversion' 2>/dev/null || echo none; }
built_sha()     { ssh -o BatchMode=yes "$HOST" "sha256sum '$T_KO' 2>/dev/null | cut -d' ' -f1" 2>/dev/null || echo none; }

# ── verb: build ─────────────────────────────────────────────────────────────
verb_build() {
	manifest_common
	rt8125_manifest_set "$MAN" MODULE_PATH "$T_KO"
	if [ "$DRY" = 1 ]; then
		rt8125_log "DRY: rsync $REPO_ROOT/ -> $HOST:$T_REPO/ ; $T_BUILD"
		rt8125_manifest_set "$MAN" RESULT incomplete
		rt8125_manifest_set "$MAN" MODULE_SHA256 dry-run
		rt8125_manifest_set "$MAN" MODULE_SRCVERSION_BUILT dry-run
		return 0
	fi
	rt8125_log "syncing tree -> $HOST:$T_REPO"
	rsync -az --exclude=.git --exclude=target --exclude=docs/perf/runs \
		-e 'ssh -o BatchMode=yes' "$REPO_ROOT"/ "$HOST:$T_REPO"/ >>"$DIR/build.log" 2>&1 ||
		{ rt8125_manifest_set "$MAN" RESULT fail; rt8125_die "rsync failed (see $DIR/build.log)"; }
	rt8125_log "building on $HOST ($T_BUILD)"
	if ssh -o BatchMode=yes "$HOST" "cd '$T_REPO' && $T_BUILD" >>"$DIR/build.log" 2>&1; then
		rt8125_manifest_set "$MAN" TARGET_KERNEL "$(remote_kernel)"
		rt8125_manifest_set "$MAN" MODULE_SHA256 "$(built_sha)"
		rt8125_manifest_set "$MAN" MODULE_SRCVERSION_BUILT "$(built_srcver)"
		rt8125_manifest_set "$MAN" RESULT pass
		rt8125_log "build OK; srcversion=$(built_srcver)"
	else
		rt8125_manifest_set "$MAN" RESULT fail
		rt8125_die "build failed (see $DIR/build.log)"
	fi
}

# load_body PARAMS — echo the shell (run ON the target) that loads the driver
# and brings the DUT link up. Gateway uses gw_loopback; KVM does in-guest
# insmod + IP restore (the test link drops on reload). `\$(...)` stays literal
# so it runs on the target, not here.
load_body() {
	local params="$1"
	if [ "$TARGET" = gateway ]; then
		printf 'bash %q dut rust %q >/dev/null 2>&1; bash %q setup >/dev/null 2>&1\n' \
			"$GATEWAY_LOOPBACK" "$params" "$GATEWAY_LOOPBACK"
	else
		cat <<KVMEOF
rmmod r8125_rust 2>/dev/null; sleep 1
insmod "$KVM_KO" $params || { echo INSMOD_FAIL; exit 1; }
for s in \$(seq 1 10); do [ -e /sys/class/net/$KVM_IFACE ] && break; sleep 1; done
ip addr replace $KVM_LOCAL_IP/24 dev $KVM_IFACE 2>/dev/null; ip link set $KVM_IFACE up
for s in \$(seq 1 10); do [ "\$(cat /sys/class/net/$KVM_IFACE/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done
KVMEOF
	fi
}

# dut_prefix — command prefix to run as the DUT on the target (gateway: dut
# netns; kvm: direct in the guest).
dut_prefix() {
	if [ "$TARGET" = gateway ]; then printf 'ip netns exec %s ' "$GATEWAY_DUT_NS"; fi
}

# ── verb: deploy ────────────────────────────────────────────────────────────
verb_deploy() {
	manifest_common
	rt8125_manifest_set "$MAN" MODULE_PATH "$T_KO"
	if [ "$DRY" = 1 ]; then
		rt8125_log "DRY: load on $HOST ($TARGET) params=\"$PARAMS\" ; verify srcversion"
		rt8125_manifest_set "$MAN" MODULE_SRCVERSION_BUILT dry-run
		rt8125_manifest_set "$MAN" MODULE_SRCVERSION_LOADED dry-run
		rt8125_manifest_set "$MAN" DEPLOYED_MATCHES_BUILD dry-run
		rt8125_manifest_set "$MAN" RESULT incomplete
		return 0
	fi
	local built; built="$(built_srcver)"
	rt8125_manifest_set "$MAN" MODULE_SRCVERSION_BUILT "$built"
	rt8125_log "loading on $TARGET (params: ${PARAMS:-none})"
	if ! run_priv "$HOST" >>"$DIR/deploy.log" 2>&1 <<EOF
set -u
$(load_body "$PARAMS")
EOF
	then
		rt8125_manifest_set "$MAN" RESULT fail
		rt8125_die "deploy failed (see $DIR/deploy.log)"
	fi
	local loaded; loaded="$(loaded_srcver)"
	rt8125_manifest_set "$MAN" TARGET_KERNEL "$(remote_kernel)"
	rt8125_manifest_set "$MAN" MODULE_SHA256 "$(built_sha)"
	rt8125_manifest_set "$MAN" MODULE_SRCVERSION_LOADED "$loaded"
	if [ "$loaded" = "$built" ] && [ "$loaded" != none ]; then
		rt8125_manifest_set "$MAN" DEPLOYED_MATCHES_BUILD yes
		rt8125_manifest_set "$MAN" RESULT pass
		rt8125_log "deployed; loaded srcversion matches built ($loaded)"
	else
		rt8125_manifest_set "$MAN" DEPLOYED_MATCHES_BUILD no
		rt8125_manifest_set "$MAN" RESULT incomplete
		rt8125_warn "loaded ($loaded) != built ($built) — rebuild+deploy"
	fi
}

# ── Measurement Contract: split a marker-delimited capture into <DIR>/<name>.txt
split_capture() {
	local src="$1" name="" out=""
	while IFS= read -r line; do
		case "$line" in
			@@*@@)
				name="$(printf '%s' "$line" | tr -d '@' | tr 'A-Z' 'a-z')"
				out="$DIR/$name.txt"; [ -e "$out" ] || : >"$out" ;;
			*) [ -n "$name" ] && printf '%s\n' "$line" >>"$out" ;;
		esac
	done <"$src"
}

# assess_tx_capture RAW — shared post-processing for tx_counter_clean on either
# target. Applies the Measurement Contract: counter deltas as hard pass/fail
# PLUS a throughput floor (a ~0-throughput run is a false pass, not a clean one).
assess_tx_capture() {
	split_capture "$1"
	local floor="${DEFAULT_MIN_TPUT_GBPS:-1.0}"
	local tx_drop rx_err faults med tput_ok
	tx_drop="$(ethtool_delta "$DIR/ethtool_before.txt" "$DIR/ethtool_after.txt" tx_dropped_error)"
	rx_err="$(ethtool_delta_sum "$DIR/ethtool_before.txt" "$DIR/ethtool_after.txt" 'rx_.*error')"
	faults="$(dmesg_delta_faults "$DIR/dmesg.txt")"
	# tput.txt holds ONLY the measured (post-warmup) flows — the warmup runs
	# before the baseline snapshot, so it never emits a @@TPUT@@ line.
	med="$(sort -n "$DIR/tput.txt" 2>/dev/null | \
		awk '{a[NR]=$1} END{if(NR==0){print 0;exit} print (NR%2?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2)}')"
	med="${med:-0}"
	tput_ok="$(awk -v m="$med" -v f="$floor" 'BEGIN{print (m+0>=f+0)?1:0}')"
	rt8125_manifest_set "$MAN" ETHTOOL_DELTA_TX_DROPPED_ERROR "$tx_drop"
	rt8125_manifest_set "$MAN" ETHTOOL_DELTA_RX_ERRORS "$rx_err"
	rt8125_manifest_set "$MAN" DMESG_DELTA_FAULTS "$faults"
	rt8125_manifest_set "$MAN" THROUGHPUT_MED_GBPS "$med"
	rt8125_manifest_set "$MAN" REPEATS "${DEFAULT_REPEATS:-3}"
	rt8125_log "tx_dropped_error=$tx_drop rx_errors=$rx_err dmesg_faults=$faults tput_med=${med}Gbit (floor ${floor})"
	[ "$tput_ok" = 1 ] || rt8125_warn "throughput ${med}Gbit < floor ${floor} — no/low traffic, NOT a clean pass"
	[ "${tx_drop:-1}" -eq 0 ] && [ "${rx_err:-1}" -eq 0 ] && [ "${faults:-1}" -eq 0 ] && [ "$tput_ok" = 1 ]
}

# _tx_capture — produce the marker-delimited TX capture into <DIR>/tx.raw.
# Gateway: one privileged body (peer iperf server in the peer netns). KVM: the
# controller hosts the iperf server (colocated peer); the guest runs the client.
_tx_capture() {
	local reps="$1" warm="$2" secs="$3" to="$4" params="$5"
	if [ "$TARGET" = gateway ]; then
		run_priv "$HOST" >"$DIR/tx.raw" 2>>"$DIR/gates.log" <<EOF
set -u
DUT="ip netns exec $GATEWAY_DUT_NS"; PEER="ip netns exec $GATEWAY_PEER_NS"
$(load_body "$params")
for s in \$(seq 1 12); do [ "\$(\$DUT cat /sys/class/net/$T_IFACE/carrier 2>/dev/null)" = 1 ] && break; sleep 1; done
\$PEER pkill -9 iperf3 2>/dev/null; sleep 1
\$PEER bash -c 'setsid iperf3 -s -p 5201 >/dev/null 2>&1 </dev/null &'; sleep 2
# Warmup (discarded): warms the per-CPU IOVA caches + TCP cwnd. Its cold-start
# effects are EXCLUDED from the measured window by snapshotting after it.
for i in \$(seq 1 $warm); do timeout $to \$DUT iperf3 -c $T_PEER_IP -p 5201 -t $secs >/dev/null 2>&1; done
dmesg -C >/dev/null 2>&1
echo "@@ETHTOOL_BEFORE@@"; \$DUT ethtool -S $T_IFACE 2>/dev/null
for i in \$(seq 1 $reps); do
  g=\$(timeout $to \$DUT iperf3 -c $T_PEER_IP -p 5201 -t $secs 2>/dev/null | awk '/sender/{print \$7}')
  echo "@@TPUT@@"; echo "\${g:-0}"
done
echo "@@ETHTOOL_AFTER@@"; \$DUT ethtool -S $T_IFACE 2>/dev/null
echo "@@DMESG@@"; dmesg 2>/dev/null
EOF
		return $?
	fi
	# KVM: controller = iperf peer on enp4s0; guest = DUT client.
	pkill -9 iperf3 2>/dev/null || true; sleep 1
	setsid iperf3 -s -B "$CONTROLLER_PEER_IP" -p 5201 >/dev/null 2>&1 </dev/null &
	local srv=$! ok=1
	sleep 1
	if ! run_priv "$HOST" >"$DIR/tx.raw" 2>>"$DIR/gates.log" <<EOF
set -u
$(load_body "$params")
# Warmup (discarded) — see gateway branch.
for i in \$(seq 1 $warm); do timeout $to iperf3 -c $T_PEER_IP -p 5201 -t $secs >/dev/null 2>&1; done
dmesg -C >/dev/null 2>&1
echo "@@ETHTOOL_BEFORE@@"; ethtool -S $T_IFACE 2>/dev/null
for i in \$(seq 1 $reps); do
  g=\$(timeout $to iperf3 -c $T_PEER_IP -p 5201 -t $secs 2>/dev/null | awk '/sender/{print \$7}')
  echo "@@TPUT@@"; echo "\${g:-0}"
done
echo "@@ETHTOOL_AFTER@@"; ethtool -S $T_IFACE 2>/dev/null
echo "@@DMESG@@"; dmesg 2>/dev/null
EOF
	then ok=0; fi
	kill "$srv" 2>/dev/null || true; pkill -9 iperf3 2>/dev/null || true
	[ "$ok" = 1 ]
}

# ── gate: tx_counter_clean (multi-queue counter-clean blocker) ──────────────
gate_tx_counter_clean() {
	local reps="${DEFAULT_REPEATS:-3}" warm="${DEFAULT_WARMUP:-1}"
	local secs="${DEFAULT_IPERF_SECONDS:-8}" to="${DEFAULT_TIMEOUT_SECONDS:-15}"
	local params="${PARAMS:-rss_queues=4}"
	rt8125_log "gate tx_counter_clean[$TARGET]: params='$params' reps=$reps warmup=$warm"
	if ! _tx_capture "$reps" "$warm" "$secs" "$to" "$params"; then
		rt8125_warn "tx_counter_clean capture failed"; return 1
	fi
	assess_tx_capture "$DIR/tx.raw"
}

# ── gate: load_unload — load, unload, RELOAD (restore), assert no faults. ─────
# Leaves the driver loaded so the gate is state-neutral regardless of order.
gate_load_unload() {
	local params="${PARAMS:-}"
	if ! run_priv "$HOST" >"$DIR/load_unload.raw" 2>>"$DIR/gates.log" <<EOF
set -u
dmesg -C >/dev/null 2>&1
$(load_body "$params")
sleep 1
rmmod r8125_rust 2>/dev/null
sleep 1
$(load_body "$params")
echo "@@DMESG@@"; dmesg 2>/dev/null
EOF
	then rt8125_warn "load_unload body failed"; return 1; fi
	split_capture "$DIR/load_unload.raw"
	local faults; faults="$(dmesg_delta_faults "$DIR/dmesg.txt")"
	rt8125_manifest_set "$MAN" DMESG_DELTA_FAULTS "$faults"
	rt8125_log "load_unload dmesg_faults=$faults"
	[ "${faults:-1}" -eq 0 ]
}

# ── gate: ping — self-loads first so it is state-independent. ─────────────────
gate_ping() {
	local params="${PARAMS:-}" got
	got="$(run_priv "$HOST" 2>>"$DIR/gates.log" <<EOF
set -u
$(load_body "$params")
$(dut_prefix)ping -c3 -W1 $T_PEER_IP 2>/dev/null | grep -oE '[0-9]+ received' | grep -oE '^[0-9]+'
EOF
)" || got=0
	got="$(printf '%s' "$got" | tail -n1)"
	rt8125_log "ping received=${got:-0}/3"
	[ "${got:-0}" -ge 1 ]
}

# ── gate: ethtool_snapshot — inventory only, always passes. ──────────────────
gate_ethtool_snapshot() {
	run_priv "$HOST" >"$DIR/ethtool_snapshot.txt" 2>>"$DIR/gates.log" <<EOF
$(dut_prefix)ethtool -l $T_IFACE 2>/dev/null
$(dut_prefix)ethtool -S $T_IFACE 2>/dev/null
EOF
	return 0
}

# ── verb: gates ─────────────────────────────────────────────────────────────
verb_gates() {
	[ -n "$GROUP" ] || rt8125_die "gates needs --group (e.g. smoke|mq|tcp)"
	local tu gu var list
	tu="$(printf '%s' "$TARGET" | tr 'a-z' 'A-Z')"
	gu="$(printf '%s' "$GROUP" | tr 'a-z' 'A-Z')"
	var="${tu}_${gu}_GATES"
	list="${!var:-}"
	[ -n "$list" ] || rt8125_die "unknown gate group '$GROUP' for $TARGET (no $var in config)"
	manifest_common
	rt8125_manifest_set "$MAN" MODULE_PATH "$T_KO"
	if [ "$DRY" = 1 ]; then
		rt8125_log "DRY: would run [$list] on $HOST ($TARGET)"
		rt8125_manifest_set "$MAN" TARGET_KERNEL dry-run
		rt8125_manifest_set "$MAN" MODULE_SRCVERSION_BUILT dry-run
		rt8125_manifest_set "$MAN" MODULE_SRCVERSION_LOADED dry-run
		rt8125_manifest_set "$MAN" RESULT incomplete
		return 0
	fi
	rt8125_manifest_set "$MAN" TARGET_KERNEL "$(remote_kernel)"
	rt8125_manifest_set "$MAN" MODULE_SRCVERSION_BUILT "$(built_srcver)"
	rt8125_manifest_set "$MAN" MODULE_SRCVERSION_LOADED "$(loaded_srcver)"
	local g rc=0 results=""
	for g in $list; do
		rt8125_log "--- gate: $g ---"
		if "gate_$g"; then
			rt8125_log "gate $g: PASS"; results="$results $g=pass"
		else
			rt8125_log "gate $g: FAIL"; results="$results $g=fail"; rc=1
		fi
	done
	rt8125_manifest_set "$MAN" GATE_RESULTS "${results# }"
	rt8125_manifest_set "$MAN" RESULT "$([ "$rc" = 0 ] && echo pass || echo fail)"
	[ "$rc" = 0 ] && rt8125_log "gates group '$GROUP'[$TARGET]: PASS" || rt8125_warn "gates group '$GROUP'[$TARGET]: FAIL"
	return "$rc"
}

# ── verb: collect ───────────────────────────────────────────────────────────
verb_collect() {
	manifest_common
	rt8125_manifest_set "$MAN" RESULT pass
	rt8125_log "collecting late diagnostics -> $DIR"
	{
		echo "@@KERNEL@@ $(remote_kernel)"
		echo "@@DMESG_TAIL@@"
		ssh -o BatchMode=yes "$HOST" 'dmesg 2>/dev/null | tail -50' 2>/dev/null
		echo "@@INTERRUPTS@@"
		ssh -o BatchMode=yes "$HOST" 'grep r8125_rust /proc/interrupts' 2>/dev/null
	} >"$DIR/collect.txt" 2>&1
	rt8125_log "wrote $DIR/collect.txt"
}

case "$VERB" in
	build)   verb_build ;;
	deploy)  verb_deploy ;;
	gates)   verb_gates ;;
	collect) verb_collect ;;
	*) rt8125_die "unknown verb: $VERB (build|deploy|gates|collect)" ;;
esac
rt8125_log "manifest: $MAN"
