#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Phase 0 guardrail for docs/UPSTREAM_GAP_CLOSURE_PLAN.md.
#
# Names every netdev_ops / ethtool_ops / PM surface a reviewer expects and pins
# each to a status:
#   PRESENT  - wired in the ops struct (asserted: the symbol MUST be found).
#   PLANNED  - a P0/P1 gap not yet implemented (asserted: must NOT be wired yet,
#              so when a feature lands this gate FAILS until the row is flipped to
#              PRESENT — it cannot silently regress or drift).
#   DEFER    - a P2 intentional defer (asserted: documented in the plan or
#              UPSTREAM_REVIEW.md, and not wired).
#
# This is the anti-"silently-missed-surface" gate: the exact class of error that
# produced the RSS readback + down-interface cache fixes. As each plan phase
# lands, move the row PLANNED->PRESENT in the table below; CI then enforces it.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NETDEV_C="$ROOT/src/netdev_bridge.c"          # bridge_ops (net_device_ops)
ETH_C="$ROOT/src/netdev_bridge_ethtool.c"     # r8125_bridge_ethtool_ops
PLAN="$ROOT/docs/UPSTREAM_GAP_CLOSURE_PLAN.md"
REVIEW="$ROOT/docs/UPSTREAM_REVIEW.md"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
inv() { printf '       %-8s %-22s %s\n' "$1" "$2" "$3"; }

# status | surface label | grep-token | file
# token is matched literally (fixed-string) in the ops struct file.
ROWS=(
  # ---- PRESENT: net_device_ops ----
  "PRESENT|ndo_open|.ndo_open|$NETDEV_C"
  "PRESENT|ndo_stop|.ndo_stop|$NETDEV_C"
  "PRESENT|ndo_start_xmit|.ndo_start_xmit|$NETDEV_C"
  "PRESENT|ndo_change_mtu|.ndo_change_mtu|$NETDEV_C"
  "PRESENT|ndo_set_features|.ndo_set_features|$NETDEV_C"
  "PRESENT|ndo_set_mac_address|.ndo_set_mac_address|$NETDEV_C"
  "PRESENT|ndo_validate_addr|.ndo_validate_addr|$NETDEV_C"
  "PRESENT|ndo_tx_timeout|.ndo_tx_timeout|$NETDEV_C"
  "PRESENT|ndo_get_stats64|.ndo_get_stats64|$NETDEV_C"
  # ---- PRESENT: ethtool_ops ----
  "PRESENT|get_drvinfo|.get_drvinfo|$ETH_C"
  "PRESENT|get_link|.get_link|$ETH_C"
  "PRESENT|ethtool_stats|.get_ethtool_stats|$ETH_C"
  "PRESENT|get_rxfh|.get_rxfh|$ETH_C"
  "PRESENT|set_rxfh|.set_rxfh|$ETH_C"
  "PRESENT|get_channels|.get_channels|$ETH_C"
  "PRESENT|set_channels|.set_channels|$ETH_C"
  "PRESENT|get_rx_ring_count|.get_rx_ring_count|$ETH_C"
  # ---- PRESENT: P0 link control plane (Phase 1, phylib) ----
  "PRESENT|get_link_ksettings|.get_link_ksettings|$ETH_C"
  "PRESENT|set_link_ksettings|.set_link_ksettings|$ETH_C"
  "PRESENT|nway_reset|.nway_reset|$ETH_C"
  # ---- PRESENT: P0 receive-mode filtering (Phase 1) ----
  "PRESENT|ndo_set_rx_mode|.ndo_set_rx_mode|$NETDEV_C"
  # ---- PLANNED: P0 (Phase 2) ----
  "PLANNED|pm_ops_suspend|bridge_pm_suspend|$NETDEV_C"
  "PLANNED|pm_ops_resume|bridge_pm_resume|$NETDEV_C"
  # ---- PLANNED: P1 (Phase 3) ----
  "PLANNED|get_wol|.get_wol|$ETH_C"
  "PLANNED|set_wol|.set_wol|$ETH_C"
  "PRESENT|get_ringparam|.get_ringparam|$ETH_C"
  "PRESENT|get_pauseparam|.get_pauseparam|$ETH_C"
  "PRESENT|set_pauseparam|.set_pauseparam|$ETH_C"
  "PRESENT|hw_tally_stats|rx_missed_errors|$NETDEV_C"
  "PLANNED|coalesce|.get_coalesce|$ETH_C"
  # ---- DEFER: P2 (documented, not implemented). label = keyword that must
  #      appear in the plan / UPSTREAM_REVIEW.md; token = the op symbol. ----
  "DEFER|EEE|.get_eee|$ETH_C"
  "DEFER|PTP|.get_ts_info|$ETH_C"
  "DEFER|rxnfc|.get_rxnfc|$ETH_C"
  "DEFER|regs|.get_regs|$ETH_C"
  "DEFER|eeprom|.get_eeprom|$ETH_C"
  "DEFER|msglevel|.get_msglevel|$ETH_C"
  "DEFER|netpoll|.ndo_poll_controller|$NETDEV_C"
)

echo "== netdev / ethtool surface inventory (UPSTREAM_GAP_CLOSURE_PLAN) =="
present=0 planned=0 defer=0
for row in "${ROWS[@]}"; do
  IFS='|' read -r status label token file <<<"$row"
  case "$status" in
    PRESENT)
      if grep -qF -- "$token" "$file"; then inv PRESENT "$label" "wired"; present=$((present+1))
      else red "surface '$label' claims PRESENT but '$token' not found in ${file#$ROOT/}"; fi ;;
    PLANNED)
      if grep -qF -- "$token" "$file"; then
        red "surface '$label' is wired ('$token' found) but still tagged PLANNED — flip it to PRESENT in this gate"
      else inv PLANNED "$label" "gap (not yet implemented)"; planned=$((planned+1)); fi ;;
    DEFER)
      if grep -qF -- "$token" "$file"; then
        red "surface '$label' tagged DEFER but appears wired ('$token') — reclassify"
      elif grep -qiF -- "$label" "$PLAN" || grep -qiF -- "$label" "$REVIEW"; then
        inv DEFER "$label" "documented defer"; defer=$((defer+1))
      else red "surface '$label' is DEFER but not documented in the plan or UPSTREAM_REVIEW.md"; fi ;;
  esac
done

echo
# get_ringparam reports R8125_BRIDGE_RING_LEN from C; it MUST equal Rust
# ring::RING_LEN or ethtool -g lies about the real depth.
hdr_len=$(grep -oE '#define R8125_BRIDGE_RING_LEN[[:space:]]+[0-9]+' "$ROOT/src/netdev_bridge.h" | grep -oE '[0-9]+$')
rs_len=$(grep -oE 'RING_LEN: usize = [0-9]+' "$ROOT/src/ring.rs" | grep -oE '[0-9]+$' | head -1)
if [[ -n "$hdr_len" && "$hdr_len" == "$rs_len" ]]; then
  grn "get_ringparam depth matches Rust ring::RING_LEN ($hdr_len)"
else
  red "R8125_BRIDGE_RING_LEN ($hdr_len) != ring::RING_LEN ($rs_len) — ethtool -g would misreport"
fi

if [[ $rc -eq 0 ]]; then
  grn "surface inventory consistent: $present present, $planned planned, $defer deferred"
else
  red "surface inventory drift — update ci/check_surface_inventory.sh or wire the surface"
fi
exit "$rc"
