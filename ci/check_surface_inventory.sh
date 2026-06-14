#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Surface-coverage guardrail.
#
# Names every netdev_ops / ethtool_ops / PM surface a reviewer expects and pins
# each to a status:
#   PRESENT  - wired in the ops struct (asserted: the symbol MUST be found).
#   PLANNED  - a gap not yet implemented (asserted: must NOT be wired yet, so
#              when a feature lands this gate FAILS until the row is flipped to
#              PRESENT — it cannot silently regress or drift).
#   DEFER    - an intentional defer (asserted: documented in UPSTREAM_REVIEW.md
#              or the gap doc, and not wired).
#
# This is the anti-"silently-missed-surface" gate: the exact class of error that
# produced the RSS readback + down-interface cache fixes. As each feature lands,
# move the row PLANNED->PRESENT in the table below; CI then enforces it.

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
  # ---- PRESENT: link control plane (phylib) ----
  "PRESENT|get_link_ksettings|.get_link_ksettings|$ETH_C"
  "PRESENT|set_link_ksettings|.set_link_ksettings|$ETH_C"
  "PRESENT|nway_reset|.nway_reset|$ETH_C"
  # ---- PRESENT: receive-mode filtering ----
  "PRESENT|ndo_set_rx_mode|.ndo_set_rx_mode|$NETDEV_C"
  # ---- PRESENT: PM (via kernel-Rust pci PM extension; PCI_PM=1 build) ----
  "PRESENT|pm_ops_suspend|bridge_pm_suspend|$NETDEV_C"
  "PRESENT|pm_ops_resume|bridge_pm_resume|$NETDEV_C"
  "PRESENT|get_ringparam|.get_ringparam|$ETH_C"
  "PRESENT|get_pauseparam|.get_pauseparam|$ETH_C"
  "PRESENT|set_pauseparam|.set_pauseparam|$ETH_C"
  "PRESENT|hw_tally_stats|rx_missed_errors|$NETDEV_C"
  # ---- PLANNED: magic-packet WoL — chip arming is implemented but the
  #      end-to-end wake (PHY-alive suspend path) is unfinished, so the ethtool
  #      surface is intentionally NOT advertised yet (see docs/PM_GAP.md). ----
  "PLANNED|get_wol|.get_wol|$ETH_C"
  "PLANNED|set_wol|.set_wol|$ETH_C"
  # ---- PLANNED: mainline r8169 compatibility / production parity gaps. ----
  "PLANNED|set_ringparam|bridge_set_ringparam|$ETH_C"
  "PLANNED|ndo_features_check|.ndo_features_check|$NETDEV_C"
  "PLANNED|ndo_eth_ioctl|.ndo_eth_ioctl|$NETDEV_C"
  "PLANNED|get_ts_info|.get_ts_info|$ETH_C"
  "PLANNED|get_eth_mac_stats|.get_eth_mac_stats|$ETH_C"
  "PLANNED|get_eth_ctrl_stats|.get_eth_ctrl_stats|$ETH_C"
  "PLANNED|get_pause_stats|.get_pause_stats|$ETH_C"
  "PLANNED|get_eee|.get_eee|$ETH_C"
  "PLANNED|set_eee|.set_eee|$ETH_C"
  "PLANNED|get_rxnfc|.get_rxnfc|$ETH_C"
  "PLANNED|set_rxnfc|.set_rxnfc|$ETH_C"
  "PLANNED|get_regs|.get_regs|$ETH_C"
  "PLANNED|get_eeprom|.get_eeprom|$ETH_C"
  "PLANNED|get_msglevel|.get_msglevel|$ETH_C"
  "PLANNED|set_msglevel|.set_msglevel|$ETH_C"
  "PLANNED|netpoll|.ndo_poll_controller|$NETDEV_C"
  "PLANNED|wol_broader_modes|WAKE_UCAST|$ETH_C"
  # ---- DEFER: intentional, documented in the plan / UPSTREAM_REVIEW.md.
  #      label = keyword that must appear there; token = the op symbol. ----
  "DEFER|coalesce|.get_coalesce|$ETH_C"
  "DEFER|RXALL|.set_priv_flags|$ETH_C"
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
