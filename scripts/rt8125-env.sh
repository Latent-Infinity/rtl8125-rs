# shellcheck shell=bash
# rt8125-env.sh — shared mechanics for the build/test orchestration layer.
# Sourced by rt8125-status.sh and rt8125-run.sh. See
# docs/BUILD_TEST_ORCHESTRATION.md.
#
# This is a *library*: it defines functions and does NOT enable `set -e`
# (that is the caller's job) so sourcing it can't change the caller's shell
# options unexpectedly. All functions are written to be `set -e` safe.
#
# Two kinds of helper live here:
#   - I/O + orchestration: config load, repo-root check, ssh, run_priv,
#     run-dir/manifest, headers.
#   - The Measurement-Contract primitives (ethtool_delta, ethtool_delta_sum,
#     dmesg_delta_faults, repeat). These are deliberately PURE text/number
#     functions so they are unit-testable on fixtures with no hardware
#     (ci/check_orchestration_contract.sh exercises them).

[ -n "${RT8125_ENV_LOADED:-}" ] && return 0
RT8125_ENV_LOADED=1

rt8125_log()  { printf 'rt8125: %s\n' "$*" >&2; }
rt8125_die()  { printf 'rt8125: FATAL: %s\n' "$*" >&2; exit 1; }
rt8125_warn() { printf 'rt8125: warn: %s\n' "$*" >&2; }

# rt8125_load_config — locate the repo from this script's path, source
# config/devices.env from inside the tree, and assert the core vars.
# Refuses to source a config from outside the repo (the .env executes code).
rt8125_load_config() {
	local self_dir repo cfg
	self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	repo="$(cd "$self_dir/.." && pwd)"
	RT8125_REPO="$repo"
	cfg="${RT8125_CONFIG:-$repo/config/devices.env}"
	[ -f "$cfg" ] || rt8125_die "config not found: $cfg"
	case "$(cd "$(dirname "$cfg")" && pwd)/" in
		"$repo"/*) : ;;
		*) rt8125_die "refusing to source config outside the repo: $cfg" ;;
	esac
	# shellcheck disable=SC1090
	. "$cfg"
	: "${REPO_ROOT:?REPO_ROOT missing in $cfg}"
	: "${EVIDENCE_ROOT:?EVIDENCE_ROOT missing in $cfg}"
	: "${GATEWAY_HOST:?GATEWAY_HOST missing in $cfg}"
}

# rt8125_require_vars VAR... — fail if any named var is empty.
rt8125_require_vars() {
	local v
	for v in "$@"; do
		[ -n "${!v:-}" ] || rt8125_die "config var $v is empty (config/devices.env)"
	done
}

# rt8125_verify_repo_root — the script must run from REPO_ROOT, and the
# checkout it lives in must be that same tree (catches wrong-checkout runs).
rt8125_verify_repo_root() {
	local here="$PWD"
	[ "$here" = "$REPO_ROOT" ] ||
		rt8125_die "run from REPO_ROOT ($REPO_ROOT), not $here"
	[ "$RT8125_REPO" = "$REPO_ROOT" ] ||
		rt8125_die "script lives in $RT8125_REPO but REPO_ROOT=$REPO_ROOT (wrong checkout?)"
}

# rt8125_target_configured TARGET — true if the target has its required config.
# An unconfigured target is skipped, not failed.
rt8125_target_configured() {
	case "$1" in
		controller|local) return 0 ;;
		gateway)
			[ -n "${GATEWAY_HOST:-}" ] &&
				[ -n "${GATEWAY_REPO_ROOT:-}" ] &&
				[ -n "${GATEWAY_IFACE:-}" ] &&
				[ -n "${GATEWAY_BDF:-}" ] &&
				[ -n "${GATEWAY_KO:-}" ] &&
				[ -n "${GATEWAY_LOOPBACK:-}" ] &&
				[ -n "${GATEWAY_DUT_NS:-}" ] &&
				[ -n "${GATEWAY_PEER_NS:-}" ] &&
				[ -n "${GATEWAY_PEER_IP:-}" ] &&
				[ -n "${GATEWAY_LOCAL_IP:-}" ]
			;;
		kvm)
			[ -n "${KVM_HOST:-}" ] &&
				[ -n "${KVM_REPO_ROOT:-}" ] &&
				[ -n "${KVM_KO:-}" ] &&
				[ -n "${KVM_IFACE:-}" ] &&
				[ -n "${KVM_BDF:-}" ] &&
				[ -n "${KVM_LOCAL_IP:-}" ] &&
				[ -n "${KVM_PEER_IP:-}" ]
			;;
		*) return 1 ;;
	esac
}

# rt8125_target_host TARGET — echo the ssh host (or "local").
rt8125_target_host() {
	case "$1" in
		controller|local) printf 'local\n' ;;
		gateway) printf '%s\n' "$GATEWAY_HOST" ;;
		kvm) printf '%s\n' "$KVM_HOST" ;;
		*) return 1 ;;
	esac
}

# rt8125_ssh HOST CMD... — thin ssh wrapper (BatchMode so it fails fast
# instead of prompting). HOST=local runs the command locally.
rt8125_ssh() {
	local host="$1"; shift
	if [ "$host" = "local" ]; then
		bash -c "$*"
	else
		ssh -o BatchMode=yes "$host" "$@"
	fi
}

# run_priv HOST  — run a privileged script body (read from stdin) SYNCHRONOUSLY
# as root on HOST. This is the ONLY sanctioned privileged-exec path: a single
# `sudo bash` reading the whole body. NEVER background a sudo: the multi-queue
# debug session showed backgrounded sudo can silently lose root and make every
# privileged setup step fail late.
#
#   run_priv gateway <<'EOF'
#     ip netns exec dut ...
#   EOF
run_priv() {
	local host="$1"
	if [ "$host" = "local" ]; then
		sudo -n bash
	else
		ssh -o BatchMode=yes "$host" 'sudo -n bash -s'
	fi
}

# rt8125_run_dir TARGET OP — create and echo a per-run, user-owned evidence
# dir. RT8125_RUN_ID may pin the timestamp (for reproducible manifests/tests).
rt8125_run_dir() {
	local target="$1" op="$2" ts dir
	ts="${RT8125_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
	dir="$REPO_ROOT/$EVIDENCE_ROOT/runs/${ts}_${target}_${op}"
	mkdir -p "$dir"
	printf '%s\n' "$dir"
}

# rt8125_header TARGET OP EVIDENCE_DIR — print the execution header (stderr).
rt8125_header() {
	local target="$1" op="$2" dir="$3"
	{
		printf '=== rt8125 %s -> target=%s ===\n' "$op" "$target"
		printf '  repo:     %s\n' "$REPO_ROOT"
		printf '  source:   %s\n' "$(rt8125_git_describe)"
		printf '  evidence: %s\n' "$dir"
	} >&2
}

# rt8125_git_describe — commit id with a mandatory dirty flag (most builds
# are from staged-but-uncommitted trees).
rt8125_git_describe() {
	git -C "$REPO_ROOT" describe --always --dirty 2>/dev/null || printf 'unknown\n'
}

# rt8125_manifest_set FILE KEY VALUE — append/replace KEY=VALUE in a manifest.
rt8125_manifest_set() {
	local file="$1" key="$2" value="$3"
	mkdir -p "$(dirname "$file")"
	if [ -f "$file" ] && grep -q "^${key}=" "$file" 2>/dev/null; then
		local tmp; tmp="$(mktemp)"
		grep -v "^${key}=" "$file" >"$tmp"
		mv "$tmp" "$file"
	fi
	printf '%s=%q\n' "$key" "$value" >>"$file"
}

# ── Measurement-Contract primitives (pure; unit-tested on fixtures) ──────────

# ethtool_delta BEFORE AFTER COUNTER — print (after-before) for an exact
# counter name from two raw `ethtool -S` captures. Missing => 0.
ethtool_delta() {
	local before="$1" after="$2" name="$3" b a
	b="$(_ethtool_value "$before" "$name")"
	a="$(_ethtool_value "$after" "$name")"
	printf '%s\n' "$(( a - b ))"
}

# ethtool_delta_sum BEFORE AFTER REGEX — sum of deltas over every counter whose
# name matches REGEX (e.g. 'rx_.*error'). Used for aggregate error families.
ethtool_delta_sum() {
	local before="$1" after="$2" rx="$3" key db total=0
	while IFS= read -r key; do
		[ -n "$key" ] || continue
		db="$(ethtool_delta "$before" "$after" "$key")"
		total=$(( total + db ))
	done < <({ _ethtool_keys "$before" "$rx"; _ethtool_keys "$after" "$rx"; } | sort -u)
	printf '%s\n' "$total"
}

_ethtool_value() {
	# exact (trimmed) key match -> integer value, or 0
	awk -F: -v n="$2" '
		{ k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k);
		  if (k==n) { v=$2; gsub(/[^0-9-]/,"",v); print (v==""?0:v); exit } }
		END { }' "$1" 2>/dev/null | head -n1 | { read -r x; printf '%s\n' "${x:-0}"; }
}

_ethtool_keys() {
	awk -F: -v rx="$2" '
		{ k=$1; gsub(/^[ \t]+|[ \t]+$/,"",k);
		  if (k ~ rx) print k }' "$1" 2>/dev/null | sort -u
}

# dmesg_delta_faults FILE — count fault-ish lines in a dmesg delta capture.
# The capture MUST be a delta (dmesg -C before / dmesg after), never absolute.
dmesg_delta_faults() {
	local c
	c="$(grep -ciE 'warn|error|bug|oops|call trace|iommu_dma_unmap' "$1" 2>/dev/null || true)"
	printf '%s\n' "${c:-0}"
}

# repeat N WARMUP -- CMD... — run CMD (WARMUP+N) times; CMD prints ONE number
# per run. Discard the first WARMUP runs; print "min median max" of the rest.
# Pure harness: with `-- echo 5` it yields "5 5 5" (the contract self-test).
repeat() {
	local n="$1" warmup="$2"; shift 2
	[ "${1:-}" = "--" ] && shift
	local total=$(( n + warmup )) i out
	local vals=()
	for (( i=1; i<=total; i++ )); do
		out="$("$@")"
		[ "$i" -le "$warmup" ] && continue
		vals+=("$out")
	done
	printf '%s\n' "${vals[@]}" | sort -n | awk '
		{ a[NR]=$1 }
		END {
			if (NR==0) { print "0 0 0"; exit }
			min=a[1]; max=a[NR];
			if (NR%2==1) med=a[(NR+1)/2]; else med=(a[NR/2]+a[NR/2+1])/2;
			print min, med, max
		}'
}
