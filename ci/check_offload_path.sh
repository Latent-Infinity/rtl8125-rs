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

csum_line=$(grep -n 'let opts2 = ub::skb_tx_csum_opts(skb)' "$NETDEV" | head -1 | cut -d: -f1)
map_line=$(grep -n 'ub::skb_dma_map_tx' "$NETDEV" | head -1 | cut -d: -f1)
if [[ -n "$csum_line" && -n "$map_line" && "$csum_line" -lt "$map_line" ]]; then
  ok "TX checksum preparation happens before DMA map"
else
  bad "TX checksum preparation must run before DMA map because skb_checksum_help mutates skb data"
fi

grep -q 'dma_unmap_single(dev, handle, skb_len, DMA_TO_DEVICE)' "$BRIDGE" \
  && ok "TX DMA unmap uses original skb length" \
  || bad "TX DMA unmap must use skb->len, not descriptor length"

grep -q 'skb_checksum_help(skb)' "$OFFLOAD" \
  && grep -q 'R8125_MIN_UDP_PATCH_LEN' "$OFFLOAD" \
  && ok "short-UDP checksum errata fallback is present" \
  || bad "short-UDP checksum errata must fall back to skb_checksum_help"

grep -q 'R8125_TX_CSUM_OPTS_DROP' "$OFFLOAD" \
  && grep -q 'TX_CSUM_OPTS_DROP' "$NETDEV" \
  && ok "checksum-help failure drops before DMA map" \
  || bad "checksum-help failure must not transmit a partially checksummed skb"

grep -q 'NETIF_F_IP_CSUM' "$BRIDGE" \
  && grep -q 'NETIF_F_IPV6_CSUM' "$BRIDGE" \
  && grep -q 'NETIF_F_RXCSUM' "$BRIDGE" \
  && ok "netdev advertises checksum features wired by the offload helper" \
  || bad "checksum feature advertisement missing"

exit $fail
