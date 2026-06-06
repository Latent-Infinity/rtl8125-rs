#!/usr/bin/env bash
# Static checks for the M4 checksum/stat offload path. The traffic proof is
# the real test; these guards catch ordering regressions visible in source.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0
ok(){ printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
bad(){ printf '\033[1;31mFAIL\033[0m %s\n' "$*"; fail=1; }

NETDEV=src/netdev.rs
BRIDGE=src/netdev_bridge.c
HEADER=src/netdev_bridge.h
OFFLOAD=src/netdev_bridge_offload.c

# TX offload prep (TSO setup OR CSUM bit computation) must precede DMA
# mapping because both paths can mutate skb data (skb_cow_head +
# tcp_v6_gso_csum_prep for TSO; padding / skb_checksum_help for the
# narrow RTL8125 pad quirk or unsupported CHECKSUM_PARTIAL).
#
# Task #62 routed the skb operations through `DriverOwnedSkb` methods
# (`skb.tx_offload_prepare()`, `skb.dma_map_linear()`,
# `map_skb_linear(state, &skb)`).
csum_line=$(grep -nE 'skb\.tx_offload_prepare\(|compute_offload_bits\(&?skb\)' "$NETDEV" | head -1 | cut -d: -f1)
map_line=$(grep -nE 'ub::skb_(dma_map_tx|data_dma_map)\(|skb\.dma_map_linear\(|map_skb_linear\(' "$NETDEV" | head -1 | cut -d: -f1)
if [[ -n "$csum_line" && -n "$map_line" && "$csum_line" -lt "$map_line" ]]; then
  ok "TX checksum/TSO preparation happens before DMA map"
else
  bad "TX checksum/TSO preparation must run before DMA map because checksum/TSO helpers may mutate skb data"
fi

grep -q 'r8125_bridge_skb_tx_offload_prepare' "$HEADER" \
  && grep -q 'r8125_bridge_skb_tx_offload_prepare' "$OFFLOAD" \
  && grep -q 'skb_tx_offload_prepare' src/unsafe_boundary.rs \
  && grep -q 'tx_offload_prepare' src/skb.rs \
  && grep -q 'compute_offload_bits(&skb)' "$NETDEV" \
  && ok "TX offload prep is consolidated into one hot-path FFI call" \
  || bad "TX offload prep must use one cshim call for opts1/opts2/nr_frags"

grep -q 'dma_unmap_single(dev, handle, len, DMA_TO_DEVICE)' "$BRIDGE" \
  && grep -qE 'tx[._]shadow_len|tx\.shadow_len' "$NETDEV" \
  && ok "TX linear DMA unmap uses shadowed map length" \
  || bad "TX DMA unmap must use the saved DMA map length, not descriptor length"

grep -q 'opts2 |= R8125_TD1_UDP_CS' "$OFFLOAD" \
  && ok "normal UDP CHECKSUM_PARTIAL stays on hardware checksum" \
  || bad "normal UDP checksum-partial packets must set the hardware UDP checksum bit"

grep -q 'R8125_TX_CSUM_OPTS_DROP' "$OFFLOAD" \
  && grep -q 'return -EIO' "$OFFLOAD" \
  && grep -q 'Err(_)' "$NETDEV" \
  && grep -q 'skb.free_with_error()' "$NETDEV" \
  && ok "checksum-help failure drops before DMA map" \
  || bad "checksum-help failure must not transmit a partially checksummed skb"

grep -q 'R8125_PTP_EVENT_PORT0' "$OFFLOAD" \
  && grep -q 'R8125_PTP_EVENT_PORT1' "$OFFLOAD" \
  && grep -q 'r8125_quirk_udp_padto' "$OFFLOAD" \
  && grep -q '__skb_put_padto(skb, padto, false)' "$OFFLOAD" \
  && grep -q 'skb_checksum_help(skb)' "$OFFLOAD" \
  && ok "UDP pad/software-checksum quirk is scoped to r8169/vendor cases" \
  || bad "UDP pad/software-checksum fallback must be scoped to PTP/runt/ETH_ZLEN cases"

! grep -q 'return trans_data_len < R8125_MIN_UDP_PATCH_LEN' "$OFFLOAD" \
  && ! grep -q 'r8125_short_udp_needs_sw_csum' "$OFFLOAD" \
  && ok "broad short-UDP software checksum fallback is absent" \
  || bad "normal short UDP must not be forced through skb_checksum_help"

grep -q 'if nr_frags == 0' "$NETDEV" \
  && grep -q 'skb.into_raw()' "$NETDEV" \
  && grep -q 'map_skb_fragments' "$NETDEV" \
  && ok "linear-only TX bypasses the SG rollback helper" \
  || bad "linear-only TX should consume skb directly after the linear DMA map"

grep -q 'skb_frag_dma_map(dev, frag' "$OFFLOAD" \
  && grep -q 'dma_unmap_page(dev, handle, len, DMA_TO_DEVICE)' "$OFFLOAD" \
  && grep -qE 'tx[._]shadow_is_frag|tx\.shadow_is_frag' "$NETDEV" \
  && ok "SG fragment DMA map/unmap path preserves mapping type" \
  || bad "SG fragments mapped with skb_frag_dma_map must be unmapped with dma_unmap_page"

grep -q 'clear_tx_descriptor(self.state, prev_slot)' "$NETDEV" \
  && grep -q 'self.state.tx.clear_shadow_slot(prev_slot)' "$NETDEV" \
  && ok "TX SG rollback clears pre-staged fragment descriptors and shadows" \
  || bad "TX SG rollback must clear fragment descriptors as well as shadows after map failure"

grep -q 'NETIF_F_IP_CSUM' "$BRIDGE" \
  && grep -q 'NETIF_F_IPV6_CSUM' "$BRIDGE" \
  && grep -q 'NETIF_F_RXCSUM' "$BRIDGE" \
  && ok "netdev advertises checksum features wired by the offload helper" \
  || bad "checksum feature advertisement missing"

grep -q 'NETIF_F_TSO' "$BRIDGE" \
  && grep -q 'NETIF_F_TSO6' "$BRIDGE" \
  && grep -q 'netif_set_tso_max_size(ndev, 64000)' "$BRIDGE" \
  && grep -q 'netif_set_tso_max_segs(ndev, 10)' "$BRIDGE" \
  && ok "TSO advertisement is paired with RTL8125B max-size/max-segs caps" \
  || bad "TSO must be advertised only with the validated RTL8125B segment cap"

# Jumbo MTU must drop TSO + TX checksum offloads. RTL8125B's TSO MSS
# field is 11 bits, so MTU > 1500 can overflow the descriptor MSS and
# produce malformed segments. r8169 handles this in ndo_fix_features;
# we require the same pairing plus a feature refresh after MTU changes.
grep -q 'ndo_fix_features' "$BRIDGE" \
  && grep -q 'ndev->mtu > ETH_DATA_LEN' "$BRIDGE" \
  && grep -q 'NETIF_F_ALL_TSO' "$BRIDGE" \
  && grep -q 'NETIF_F_CSUM_MASK' "$BRIDGE" \
  && grep -q 'netdev_update_features(ndev)' "$BRIDGE" \
  && ok "jumbo MTU disables TSO/TX-CSUM and refreshes features on MTU change" \
  || bad "jumbo MTU must disable TSO/TX-CSUM via ndo_fix_features and netdev_update_features"

exit $fail
