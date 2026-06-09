#!/usr/bin/env bash
# rt8125-status.sh — read-only inventory of Controller / Gateway / KVM.
# Safe to run any time; never loads, unloads, or moves traffic. Always exits 0
# (it is a report). An unconfigured target prints `unconfigured` and is skipped.
# See docs/BUILD_TEST_ORCHESTRATION.md.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/rt8125-env.sh
. "$HERE/rt8125-env.sh"
rt8125_load_config

TARGET=all
while [ $# -gt 0 ]; do
	case "$1" in
		--target) TARGET="$2"; shift 2 ;;
		-h|--help) printf 'usage: rt8125-status.sh [--target all|controller|gateway|kvm]\n'; exit 0 ;;
		*) rt8125_die "unknown arg: $1" ;;
	esac
done

section() { printf '\n== %s ==\n' "$*"; }
kv()      { printf '  %-22s %s\n' "$1" "$2"; }

status_controller() {
	section "controller (local)"
	kv "repo_root" "$REPO_ROOT"
	kv "pwd_is_repo_root" "$([ "$PWD" = "$REPO_ROOT" ] && echo yes || echo "no ($PWD)")"
	kv "source" "$(rt8125_git_describe)"
	kv "rustc" "$(command -v "${GATEWAY_RUSTC:-rustc}" >/dev/null 2>&1 && "${GATEWAY_RUSTC:-rustc}" --version 2>/dev/null || echo absent)"
	local ko="$REPO_ROOT/src/r8125_rust.ko"
	if [ -f "$ko" ]; then
		kv "local_ko" "$ko"
		kv "local_ko_srcversion" "$(modinfo -F srcversion "$ko" 2>/dev/null || echo '?')"
		kv "local_ko_sha256" "$(sha256sum "$ko" 2>/dev/null | cut -c1-16)…"
	else
		kv "local_ko" "absent (run: rt8125-run.sh build)"
	fi
}

# status_remote TARGET HOST IFACE BDF KO — shared gateway/kvm report. Runs ONE
# ssh that prints key=value lines; read-only on the target.
status_remote() {
	local target="$1" host="$2" iface="$3" bdf="$4" ko="$5"
	local expect_kernel=""
	section "$target ($host)"
	if ! rt8125_target_configured "$target"; then
		kv "state" "unconfigured — fill config/devices.env (TODO)"
		return 0
	fi
	if ! ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" true 2>/dev/null; then
		kv "state" "unreachable (ssh $host failed)"
		return 0
	fi
	local out
	out="$(ssh -o BatchMode=yes -o ConnectTimeout=8 "$host" \
		"IFACE='$iface' BDF='$bdf' KO='$ko' bash -s" <<'REMOTE'
echo "kernel=$(uname -r)"
echo "iface_present=$([ -e "/sys/class/net/$IFACE" ] && echo yes || echo no)"
echo "carrier=$(cat "/sys/class/net/$IFACE/carrier" 2>/dev/null || echo '?')"
echo "bdf_present=$([ -e "/sys/bus/pci/devices/$BDF" ] && echo yes || echo no)"
echo "pci_id=$(cat "/sys/bus/pci/devices/$BDF/vendor" 2>/dev/null | tr -d '\n'):$(cat "/sys/bus/pci/devices/$BDF/device" 2>/dev/null) "
echo "bound_driver=$(basename "$(readlink "/sys/bus/pci/devices/$BDF/driver" 2>/dev/null)" 2>/dev/null || echo none)"
echo "loaded_srcversion=$(cat /sys/module/r8125_rust/srcversion 2>/dev/null || echo none)"
echo "built_srcversion=$(modinfo -F srcversion "$KO" 2>/dev/null || echo none)"
REMOTE
)"
	local loaded built kernel
	kernel="$(sed -n 's/^kernel=//p' <<<"$out")"
	loaded="$(sed -n 's/^loaded_srcversion=//p' <<<"$out")"
	built="$(sed -n 's/^built_srcversion=//p' <<<"$out")"
	while IFS= read -r line; do [ -n "$line" ] && kv "${line%%=*}" "${line#*=}"; done <<<"$out"
	if [ "$loaded" = none ]; then
		kv "DEPLOYED_MATCHES_BUILD" "n/a (module not loaded)"
	elif [ "$loaded" = "$built" ]; then
		kv "DEPLOYED_MATCHES_BUILD" "yes"
	else
		kv "DEPLOYED_MATCHES_BUILD" "NO (loaded=$loaded built=$built — rebuild+deploy)"
	fi
	case "$target" in
		gateway) expect_kernel="${GATEWAY_KERNEL_FAMILY:-}" ;;
		kvm) expect_kernel="${KVM_KERNEL_FAMILY:-}" ;;
	esac
	if [ -n "$kernel" ] && [ -n "$expect_kernel" ]; then
		case "$kernel" in
			"${expect_kernel}"*) : ;;
			*) kv "kernel_family_warn" "expected ${expect_kernel}.* got $kernel" ;;
		esac
	fi
}

case "$TARGET" in
	controller) status_controller ;;
	gateway)    status_remote gateway "${GATEWAY_HOST:-}" "${GATEWAY_IFACE:-}" "${GATEWAY_BDF:-}" "${GATEWAY_KO:-}" ;;
	kvm)        status_remote kvm "${KVM_HOST:-}" "${KVM_IFACE:-}" "${KVM_BDF:-}" "${KVM_KO:-}" ;;
	all)
		status_controller
		status_remote gateway "${GATEWAY_HOST:-}" "${GATEWAY_IFACE:-}" "${GATEWAY_BDF:-}" "${GATEWAY_KO:-}"
		status_remote kvm "${KVM_HOST:-}" "${KVM_IFACE:-}" "${KVM_BDF:-}" "${KVM_KO:-}"
		;;
	*) rt8125_die "unknown target: $TARGET (want all|controller|gateway|kvm)" ;;
esac

exit 0
