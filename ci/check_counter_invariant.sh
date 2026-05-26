#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Runtime invariant check for plan §6.3:
#
#     tx_received == tx_consumed + tx_busy_exception + tx_dropped_error
#
# (with the analogous RX equation as a soft check). Hardware-required —
# not part of the static `ci/run_checks.sh` set. Designed to be run
# from inside a guest that has the driver loaded and a peer reachable
# at $PEER (default 10.0.0.1).
#
# Pass criteria (per plan §15 M4 close-out):
#   - tx_received - (tx_consumed + tx_busy_exception + tx_dropped_error) == 0
#     after a >= 1 GiB transfer and a brief quiesce
#   - rx_handed_to_stack > 0 (RX path exercised)
#
# Usage:
#   ci/check_counter_invariant.sh [IFACE] [PEER]
#   ci/check_counter_invariant.sh enp5s0 10.0.0.1
#
# Defaults match the rtl8125-rs dev setup.

set -euo pipefail

IFACE=${1:-enp5s0}
PEER=${2:-10.0.0.1}
BYTES=${BYTES:-1G}

red()  { printf '\033[1;31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yel()  { printf '\033[1;33m%s\033[0m\n' "$*"; }

# Sanity: interface exists and is up.
if ! ip link show "$IFACE" >/dev/null 2>&1; then
	red "FAIL: interface $IFACE not found"; exit 1
fi
if [[ $(cat "/sys/class/net/$IFACE/operstate") != "up" ]]; then
	yel "INFO: bringing $IFACE up"
	sudo ip link set "$IFACE" up
	sleep 5
fi

# Snapshot all six §6.3 counters from ethtool -S into shell vars.
snapshot() {
	local prefix=$1
	while read -r name val; do
		declare -g "${prefix}${name}=${val}"
	done < <(ethtool -S "$IFACE" 2>/dev/null | \
		awk '/^\s+(tx_received|tx_consumed|tx_busy_exception|tx_dropped_error|rx_handed_to_stack|rx_dropped_error):/ {
			gsub(":","",$1); print $1, $2
		}')
}

snapshot before_
for counter in tx_received tx_consumed tx_busy_exception tx_dropped_error \
	       rx_handed_to_stack rx_dropped_error; do
	var="before_${counter}"
	if [[ -z "${!var:-}" ]]; then
		red "FAIL: ethtool -S did not expose $counter - is r8125_bridge_ethtool_ops wired up?"
		exit 1
	fi
done

echo "Before:"
printf '  tx_received=%s tx_consumed=%s tx_busy=%s tx_drop=%s rx_hand=%s rx_drop=%s\n' \
	"$before_tx_received" "$before_tx_consumed" "$before_tx_busy_exception" \
	"$before_tx_dropped_error" "$before_rx_handed_to_stack" "$before_rx_dropped_error"

# Run the 1 GiB transfer. iperf3 -n $BYTES does a fixed-byte transfer.
LOCAL_IP=$(ip -4 -o addr show "$IFACE" | awk '{print $4}' | cut -d/ -f1)
if [[ -z "$LOCAL_IP" ]]; then
	red "FAIL: interface $IFACE has no IPv4 address for iperf3 bind"
	exit 1
fi
yel "INFO: running iperf3 -c $PEER -B $LOCAL_IP -n $BYTES ..."
# `-i 1` (the default) is needed; -i 0 can cause control-socket errors on
# some iperf3 versions. We just summarize the last line for context.
iperf3 -c "$PEER" -B "$LOCAL_IP" -n "$BYTES" 2>&1 | tail -3

# Quiesce: stop the TX queue (link down/up cycle) so in-flight skbs flush.
sudo ip link set "$IFACE" down
sleep 1
sudo ip link set "$IFACE" up
sleep 3

snapshot after_

echo "After:"
printf '  tx_received=%s tx_consumed=%s tx_busy=%s tx_drop=%s rx_hand=%s rx_drop=%s\n' \
	"$after_tx_received" "$after_tx_consumed" "$after_tx_busy_exception" \
	"$after_tx_dropped_error" "$after_rx_handed_to_stack" "$after_rx_dropped_error"

# Deltas — invariant must hold on the deltas so previous runs don't pollute.
dtx_recv=$((after_tx_received       - before_tx_received))
dtx_cons=$((after_tx_consumed       - before_tx_consumed))
dtx_busy=$((after_tx_busy_exception - before_tx_busy_exception))
dtx_drop=$((after_tx_dropped_error  - before_tx_dropped_error))
drx_hand=$((after_rx_handed_to_stack - before_rx_handed_to_stack))
drx_drop=$((after_rx_dropped_error  - before_rx_dropped_error))

echo
echo "Deltas:"
printf '  tx_received=%d tx_consumed=%d tx_busy=%d tx_drop=%d rx_hand=%d rx_drop=%d\n' \
	"$dtx_recv" "$dtx_cons" "$dtx_busy" "$dtx_drop" "$drx_hand" "$drx_drop"

lhs=$dtx_recv
rhs=$((dtx_cons + dtx_busy + dtx_drop))
gap=$((lhs - rhs))

echo
echo "§6.3 invariant: tx_received == tx_consumed + tx_busy_exception + tx_dropped_error"
echo "  $lhs == $rhs  (gap $gap)"

fail=0
if [[ $gap -ne 0 ]]; then
	red "FAIL: §6.3 TX invariant violated (gap = $gap, expected 0)"
	fail=1
fi
if [[ $drx_hand -eq 0 ]]; then
	red "FAIL: rx_handed_to_stack delta is 0 — RX path was not exercised"
	fail=1
fi
if [[ $drx_drop -gt 0 ]]; then
	yel "WARN: rx_dropped_error delta = $drx_drop (acceptable but worth reviewing)"
fi

if [[ $fail -eq 0 ]]; then
	grn "PASS: §6.3 counter invariant holds across ${BYTES} transfer"
fi
exit "$fail"
