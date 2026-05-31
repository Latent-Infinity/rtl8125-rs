#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# soak_watch.sh - pull-the-state, print-the-status soak watcher.
#
# Idempotent. Safe to run on a timer, from cron, from a wakeup, or
# just by hand. No daemon, no state file. Each invocation re-reads
# the current SOAK_REPORT.md + soak.log + ethtool counters from
# every soak host, computes deltas vs the previous sample line,
# and prints one table.
#
# Hosts are addressed via SSH aliases. Defaults match the dev rig:
#   kvm     - Controller-KVM guest (default `kvm` alias or 192.168.122.174)
#   gateway - bare-metal Gateway (Tailscale via `gateway` alias)
#
# Override with:
#   SOAK_HOSTS="alias1 alias2 ..."
#   <ALIAS>_IFACE=enp5s0        # interface on that host
#   <ALIAS>_PATTERN='/tmp/r8125_gateway_active_*'
#                               # glob to locate the most recent run
#   <ALIAS>_SSH_FLAGS="..."     # extra ssh args (e.g. identity file)
#
# Exit code: 0 if all soaks healthy, non-zero if any look stalled
# (tx_received not advancing between samples by at least
# STALL_MIN_PPS packets/s, or driver-error counters non-zero).

set -uo pipefail

SOAK_HOSTS="${SOAK_HOSTS:-kvm gateway}"
STALL_MIN_PPS="${STALL_MIN_PPS:-100}"   # at 100 Mbps and ~1500B avg, expect ~8000 pps

# Per-host defaults. Override via "<alias_upper>_IFACE" etc.
kvm_IFACE_DEFAULT=enp5s0
kvm_PATTERN_DEFAULT='/tmp/r8125_gateway_active_*'
kvm_SSH_FLAGS_DEFAULT='-i /home/firestrand/.ssh/agent/rtl8125_guest_codex -o StrictHostKeyChecking=no firestrand@192.168.122.174'

gateway_IFACE_DEFAULT=enp3s0
gateway_PATTERN_DEFAULT='/tmp/r8125_gateway_active_*'
gateway_SSH_FLAGS_DEFAULT='gateway'

# ---- helpers ----------------------------------------------------------------

# Look up "$1_$2_DEFAULT" with optional override via "<UPPER>_$2".
host_var() {
	local alias="$1" key="$2"
	local upper override default
	upper=$(printf '%s' "$alias" | tr '[:lower:]' '[:upper:]')
	override="${upper}_${key}"
	default="${alias}_${key}_DEFAULT"
	if [[ -v "$override" ]]; then
		printf '%s' "${!override}"
	elif [[ -v "$default" ]]; then
		printf '%s' "${!default}"
	else
		return 1
	fi
}

# Run a shell snippet on $alias via the configured ssh flags.
host_ssh() {
	local alias="$1"; shift
	local flags
	flags=$(host_var "$alias" SSH_FLAGS) || return 1
	# shellcheck disable=SC2086
	ssh -o ConnectTimeout=10 $flags "$@"
}

human_secs() {
	local s="$1"
	printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
}

# Bright status pip (no ANSI when not a tty so cron logs stay clean).
pip() {
	if [[ -t 1 ]]; then
		case "$1" in
			ok)   printf '\033[1;32mOK\033[0m' ;;
			warn) printf '\033[1;33m!\033[0m' ;;
			err)  printf '\033[1;31mFAIL\033[0m' ;;
		esac
	else
		case "$1" in ok) printf 'OK';; warn) printf 'WARN';; err) printf 'FAIL';; esac
	fi
}

# ---- per-host probe ---------------------------------------------------------

# Bash $() strips NUL bytes, so we use ASCII 31 (Unit Separator) as the
# field delimiter. Bash preserves it through command substitution and
# it never appears in our payload (counters, paths, dmesg).
US=$'\x1f'

probe_one() {
	local alias="$1"
	local iface pattern iface_q pattern_q
	iface=$(host_var "$alias" IFACE) || { printf 'no-config'; return 0; }
	pattern=$(host_var "$alias" PATTERN) || { printf 'no-config'; return 0; }
	printf -v iface_q '%q' "$iface"
	printf -v pattern_q '%q' "$pattern"

	# Pull everything we need in one remote bash invocation. This minimises ssh
	# round trips and gives a quasi-atomic snapshot.
	#
	# Output format (US-delimited records, US = \x1f):
	#   RUN_DIR<US>STARTED_LINE<US>SAMPLES_TXT<US>DMESG_TAIL<US>TX_RECVD<US>TX_CONS<US>TX_DROP<US>RX_HAND<US>RX_DROP
	host_ssh "$alias" "R8125_IFACE=$iface_q R8125_PATTERN=$pattern_q bash -s" <<'REMOTE' 2>/dev/null
set -uo pipefail
US=$'\x1f'
shopt -s nullglob
matches=( $R8125_PATTERN )
if (( ${#matches[@]} == 0 )); then
	printf 'no-run'
	exit 0
fi
RUN=$(ls -td -- "${matches[@]}" 2>/dev/null | head -1)
if [[ -z "$RUN" ]]; then
	printf 'no-run'
	exit 0
fi
printf '%s%s' "$RUN" "$US"
sudo head -3 "$RUN/soak.log" 2>/dev/null | sed -n 2p | tr -d '\n'
printf '%s' "$US"
sudo grep -E '^sample [0-9]+ ' "$RUN/soak.log" 2>/dev/null | tail -2 | tr '\n' '|'
printf '%s' "$US"
sudo dmesg 2>/dev/null | tail -200 | grep -iE 'r8125|err|warn|fault|trace|hung|stall' | tail -3 | tr '\n' '|'
printf '%s' "$US"
sudo ethtool -S "$R8125_IFACE" 2>/dev/null | awk -v US="$US" '
	/^[[:space:]]*tx_received:/        { tx=$2 }
	/^[[:space:]]*tx_consumed:/        { tc=$2 }
	/^[[:space:]]*tx_dropped_error:/   { td=$2 }
	/^[[:space:]]*rx_handed_to_stack:/ { rh=$2 }
	/^[[:space:]]*rx_dropped_error:/   { rd=$2 }
	END { printf "%s%s%s%s%s%s%s%s%s", tx+0,US,tc+0,US,td+0,US,rh+0,US,rd+0 }
'
REMOTE
}

# ---- per-host report --------------------------------------------------------

emit_one() {
	local alias="$1" snap="$2"
	local -a rec
	# Split on US (Unit Separator, \x1f).
	IFS="$US" read -ra rec <<<"$snap"

	local run_dir="${rec[0]:-}"
	if [[ "$run_dir" == "no-config" ]]; then
		printf '  %s %-8s missing IFACE/PATTERN/SSH_FLAGS configuration\n' "$(pip warn)" "$alias"
		return 1
	fi
	if [[ "$run_dir" == "no-run" || -z "$run_dir" ]]; then
		printf '  %s %-8s no active soak run found\n' "$(pip warn)" "$alias"
		return 1
	fi

	# rec[1] is the soak-start banner line (currently unused; future:
	# parse to compute wall-clock elapsed independently of t= samples).
	local samples_blob="${rec[2]:-}"
	local dmesg_blob="${rec[3]:-}"
	local tx_recvd="${rec[4]:-0}"
	local tx_cons="${rec[5]:-0}"
	local tx_drop="${rec[6]:-0}"
	local rx_hand="${rec[7]:-0}"
	local rx_drop="${rec[8]:-0}"

	# Last two samples -> derive recent pps. Pipe-delimited so bash array
	# indexing is straightforward; trailing '|' from `tr` produces an
	# empty final element which we ignore.
	local -a samples
	IFS='|' read -ra samples <<<"${samples_blob%|}"
	local n="${#samples[@]}"
	local cur="" prev=""
	(( n >= 1 )) && cur="${samples[n-1]}"
	(( n >= 2 )) && prev="${samples[n-2]}"
	local t_cur=0 tx_cur=0 t_prev=0 tx_prev=0
	# format: "sample N (t=Xs): tx_received=Y gap=Z"
	if [[ "$cur" =~ t=([0-9]+)s.*tx_received=([0-9]+) ]]; then
		t_cur="${BASH_REMATCH[1]}"
		tx_cur="${BASH_REMATCH[2]}"
	fi
	if [[ "$prev" =~ t=([0-9]+)s.*tx_received=([0-9]+) ]]; then
		t_prev="${BASH_REMATCH[1]}"
		tx_prev="${BASH_REMATCH[2]}"
	fi

	local dt=$((t_cur - t_prev))
	local dtx=$((tx_cur - tx_prev))
	local pps=0
	(( dt > 0 )) && pps=$((dtx / dt))

	local elapsed_h
	elapsed_h=$(human_secs "$t_cur")

	# Stall / error / health verdict.
	local status="ok" reason=""
	if (( tx_drop > 0 || rx_drop > 0 )); then
		status="warn"
		reason="driver errors: tx_drop=$tx_drop rx_drop=$rx_drop"
	fi
	# Only flag low-pps as stall if we have at least one delta to compare.
	if (( dt > 0 && pps < STALL_MIN_PPS )); then
		status="err"
		reason="traffic stalled: ${pps} pps over last ${dt}s"
	fi

	printf '  %s %-8s t=%s pps~%d  tx_recvd=%s gap=%d  rx_hand=%s' \
		"$(pip "$status")" "$alias" "$elapsed_h" "$pps" "$tx_recvd" "$((tx_recvd - tx_cons))" "$rx_hand"
	if [[ -n "$reason" ]]; then
		printf '\n           reason: %s' "$reason"
	fi
	if [[ -n "$dmesg_blob" && "$dmesg_blob" != "|" ]]; then
		printf '\n           dmesg: %s' "${dmesg_blob//|/ ; }"
	fi
	printf '\n'

	[[ "$status" == "ok" ]]
}

# ---- main -------------------------------------------------------------------

printf 'soak status  %s\n\n' "$(date -u +'%Y-%m-%d %H:%M UTC')"

rc=0
for alias in $SOAK_HOSTS; do
	snap=$(probe_one "$alias")
	emit_one "$alias" "$snap" || rc=1
done
printf '\n'

if (( rc == 0 )); then
	printf 'overall: %s healthy\n' "$(pip ok)"
else
	printf 'overall: %s attention\n' "$(pip warn)"
fi
exit "$rc"
