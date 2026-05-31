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
OFFLOAD=src/netdev_bridge_offload.c

# TX offload prep (TSO setup OR CSUM bit computation) must precede DMA
# mapping because both paths can mutate skb data (skb_cow_head +
# tcp_v6_gso_csum_prep for TSO; skb_checksum_help for the short-UDP
# errata in the CSUM path). Look for either pre-DMA helper.
#
# Task #62 routed the skb operations through `DriverOwnedSkb` methods
# (`skb.tso_setup()`, `skb.tx_csum_opts()`, `skb.dma_map_linear()`,
# `map_skb_linear(state, &skb)`); accept either the raw `ub::` form or
# the method-call / helper form.
csum_line=$(grep -nE 'ub::skb_tx_csum_opts\(skb\)|ub::skb_tso_setup\(skb\)|skb\.(tso_setup|tx_csum_opts)\(|compute_offload_bits\(&?skb\)' "$NETDEV" | head -1 | cut -d: -f1)
map_line=$(grep -nE 'ub::skb_(dma_map_tx|data_dma_map)\(|skb\.dma_map_linear\(|map_skb_linear\(' "$NETDEV" | head -1 | cut -d: -f1)
if [[ -n "$csum_line" && -n "$map_line" && "$csum_line" -lt "$map_line" ]]; then
  ok "TX checksum/TSO preparation happens before DMA map"
else
  bad "TX checksum/TSO preparation must run before DMA map because skb_checksum_help / tcp_v6_gso_csum_prep mutate skb data"
fi

grep -q 'dma_unmap_single(dev, handle, len, DMA_TO_DEVICE)' "$BRIDGE" \
  && grep -qE 'tx[._]shadow_len|tx\.shadow_len' "$NETDEV" \
  && ok "TX linear DMA unmap uses shadowed map length" \
  || bad "TX DMA unmap must use the saved DMA map length, not descriptor length"

grep -q 'skb_checksum_help(skb)' "$OFFLOAD" \
  && grep -q 'R8125_MIN_UDP_PATCH_LEN' "$OFFLOAD" \
  && ok "short-UDP checksum errata fallback is present" \
  || bad "short-UDP checksum errata must fall back to skb_checksum_help"

grep -q 'R8125_TX_CSUM_OPTS_DROP' "$OFFLOAD" \
  && grep -q 'TX_CSUM_OPTS_DROP' "$NETDEV" \
  && ok "checksum-help failure drops before DMA map" \
  || bad "checksum-help failure must not transmit a partially checksummed skb"

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
