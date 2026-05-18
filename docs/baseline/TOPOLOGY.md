# RTL8125 physical test topology (plan §7 M0 / §15 — OPERATOR MUST COMPLETE)

Not auto-detectable. Without this, link-stability and ASPM results (plan §3.3,
M5) are not reproducible. Fill every field:

- RTL8125 RJ45 connected to: [ ] direct cable to peer  [ ] managed switch
- Switch model / firmware (if any):
- Switch port EEE / 802.3az / power-save state:
- Negotiated link speed (from ethtool_link.txt):
- Peer device NIC model:
- Peer OS / kernel version:
- Peer driver in use + version:
- Peer MTU:
- L2 isolation: is the RTL8125 port on the SAME switch domain as host mgmt? [ ] no (required) [ ] yes (NOT allowed — plan §8.1.6)
