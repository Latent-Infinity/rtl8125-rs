#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Static/TDD contract for the build/test orchestration MVP.
# Hardware/live SSH behavior belongs in runtime gates; this check proves the
# repo-local config and pure helpers are present, parse, and preserve the
# Measurement Contract shape.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_SH="$ROOT/scripts/rt8125-env.sh"
STATUS_SH="$ROOT/scripts/rt8125-status.sh"
RUN_SH="$ROOT/scripts/rt8125-run.sh"
DEVICES="$ROOT/config/devices.env"
rc=0

red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }

for f in "$ENV_SH" "$STATUS_SH" "$RUN_SH" "$DEVICES"; do
	if [[ -f "$f" ]]; then
		grn "${f#$ROOT/} exists"
	else
		red "${f#$ROOT/} must exist"
	fi
done

for f in "$ENV_SH" "$STATUS_SH" "$RUN_SH"; do
	if [[ -x "$f" ]]; then
		grn "${f#$ROOT/} is executable"
	else
		red "${f#$ROOT/} must be executable"
	fi
	if bash -n "$f"; then
		grn "${f#$ROOT/} parses"
	else
		red "${f#$ROOT/} must parse under bash"
	fi
done

if [[ -f "$DEVICES" ]] && bash -n "$DEVICES"; then
	grn "config/devices.env parses as bash assignments"
else
	red "config/devices.env must parse as bash assignments"
fi

required_vars=(
	REPO_ROOT EVIDENCE_ROOT CONTROLLER_HOST GATEWAY_HOST
	GATEWAY_REPO_ROOT GATEWAY_KO GATEWAY_LOOPBACK GATEWAY_IFACE GATEWAY_BDF
	GATEWAY_PEER_IFACE GATEWAY_DUT_NS GATEWAY_PEER_NS GATEWAY_PEER_IP
	GATEWAY_LOCAL_IP GATEWAY_KERNEL_FAMILY GATEWAY_RUSTC
	CONTROLLER_PEER_IFACE CONTROLLER_PEER_IP
	STATIC_GATES GATEWAY_SMOKE_GATES GATEWAY_MQ_GATES GATEWAY_STRESS_GATES
	DEFAULT_REPEATS DEFAULT_WARMUP DEFAULT_IPERF_SECONDS
	DEFAULT_TIMEOUT_SECONDS DEFAULT_SOAK_HOURS DEFAULT_MIN_TPUT_GBPS PCI_ID_RTL8125
)

# KVM is now a configured target (2-node rig). If KVM_HOST is set, its full set
# must be present; an empty KVM_HOST means the target is intentionally
# unconfigured (skipped, non-fatal).
kvm_vars=(
	KVM_HOST KVM_REPO_ROOT KVM_KO KVM_IFACE KVM_BDF KVM_LOCAL_IP KVM_PEER_IP
	KVM_KERNEL_FAMILY KVM_SMOKE_GATES KVM_TCP_GATES
)

if [[ -f "$DEVICES" ]]; then
	# shellcheck disable=SC1090
	. "$DEVICES"
	for v in "${required_vars[@]}"; do
		if [[ -n "${!v:-}" ]]; then
			grn "config var $v is set"
		else
			red "config var $v must be non-empty"
		fi
	done
	if [[ -z "${KVM_HOST:-}" ]]; then
		grn "KVM target is intentionally unconfigured (skipped, non-fatal)"
	else
		for v in "${kvm_vars[@]}"; do
			if [[ -n "${!v:-}" ]]; then
				grn "KVM config var $v is set"
			else
				red "KVM_HOST set but $v is empty — fill the KVM block"
			fi
		done
	fi
fi

if grep -q 'sudo -n bash' "$ENV_SH" &&
	grep -q 'run_priv()' "$ENV_SH"; then
	grn "run_priv uses non-interactive synchronous sudo"
else
	red "run_priv must use non-interactive synchronous sudo"
fi

if awk '/gateway\)/,/;;/' "$ENV_SH" | grep -q 'GATEWAY_PEER_IP' &&
	awk '/gateway\)/,/;;/' "$ENV_SH" | grep -q 'GATEWAY_DUT_NS' &&
	awk '/gateway\)/,/;;/' "$ENV_SH" | grep -q 'GATEWAY_LOCAL_IP' &&
	awk '/kvm\)/,/;;/' "$ENV_SH" | grep -q 'KVM_LOCAL_IP' &&
	awk '/kvm\)/,/;;/' "$ENV_SH" | grep -q 'KVM_PEER_IP'; then
	grn "target configured checks cover runtime Gateway/KVM variables"
else
	red "target configured checks must cover every runtime Gateway/KVM variable"
fi

if grep -q 'printf.*%q' "$ENV_SH"; then
	grn "manifest writer shell-quotes values"
else
	red "manifest writer must shell-quote values"
fi

for fn in ethtool_delta ethtool_delta_sum dmesg_delta_faults repeat; do
	if grep -q "^$fn()" "$ENV_SH"; then
		grn "measurement primitive $fn exists"
	else
		red "measurement primitive $fn must exist"
	fi
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/before" <<'EOF'
NIC statistics:
     tx_dropped_error: 2
     rx_crc_error: 4
EOF
cat > "$tmp/after" <<'EOF'
NIC statistics:
     tx_dropped_error: 5
     rx_crc_error: 6
     rx_dropped_error: 3
EOF
printf 'ok\nWARNING: test\niommu_dma_unmap bad\n' > "$tmp/dmesg"

# shellcheck source=scripts/rt8125-env.sh
. "$ENV_SH"
if [[ "$(ethtool_delta "$tmp/before" "$tmp/after" tx_dropped_error)" == 3 ]]; then
	grn "ethtool_delta computes exact counter deltas"
else
	red "ethtool_delta fixture failed"
fi
if [[ "$(ethtool_delta_sum "$tmp/before" "$tmp/after" 'rx_.*error')" == 5 ]]; then
	grn "ethtool_delta_sum computes unique counter-family deltas"
else
	red "ethtool_delta_sum fixture failed"
fi
if [[ "$(dmesg_delta_faults "$tmp/dmesg")" == 2 ]]; then
	grn "dmesg_delta_faults counts fault signatures"
else
	red "dmesg_delta_faults fixture failed"
fi
if [[ "$(repeat 3 1 -- printf '7\n')" == "7 7 7" ]]; then
	grn "repeat discards warm-up and reports min/median/max"
else
	red "repeat fixture failed"
fi

mkdir -p "$tmp/fakebin"
cat > "$tmp/fakebin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'unexpected ssh in dry-run: %s\n' "$*" >&2
exit 99
EOF
chmod +x "$tmp/fakebin/ssh"

dry_run_ok=1
for args in \
	"build --target gateway --dry-run" \
	"deploy --target gateway --params rss_queues=4 --dry-run" \
	"gates --target gateway --group mq --dry-run" \
	"build --target kvm --dry-run" \
	"deploy --target kvm --params rss_queues=4 --dry-run" \
	"gates --target kvm --group tcp --dry-run"
do
	if ! PATH="$tmp/fakebin:$PATH" "$RUN_SH" $args >"$tmp/dry.out" 2>"$tmp/dry.err"; then
		dry_run_ok=0
		printf '%s\n' "--- dry-run failure: $args ---" >&2
		cat "$tmp/dry.err" >&2
	fi
done
if [[ "$dry_run_ok" == 1 ]]; then
	grn "dry-run build/deploy/gates do not touch ssh (gateway + kvm)"
else
	red "dry-run commands must not touch remote hosts"
fi

# tx_counter_clean must enforce a throughput floor — a ~0-throughput run has
# trivially-clean counters and would otherwise be a false pass (multi-queue lesson).
if grep -q 'DEFAULT_MIN_TPUT_GBPS' "$RUN_SH" && grep -q 'tput_ok' "$RUN_SH"; then
	grn "tx_counter_clean enforces a throughput floor (no false pass on zero traffic)"
else
	red "tx_counter_clean must gate on DEFAULT_MIN_TPUT_GBPS (throughput floor)"
fi

# Gates must be target-aware: the gateway netns rig (GATEWAY_DUT_NS) AND the
# kvm 2-node rig (CONTROLLER_PEER_IP) must both be handled.
if grep -q 'GATEWAY_DUT_NS' "$RUN_SH" && grep -q 'CONTROLLER_PEER_IP' "$RUN_SH"; then
	grn "run.sh is target-aware (gateway netns + kvm controller-peer rigs)"
else
	red "run.sh must support both the gateway and kvm rigs"
fi

exit "$rc"
