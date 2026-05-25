# Unsafe census justifications

Per plan §9.4, every census bump (rejected by `ci/run_checks.sh`) needs a
short rationale here. Append; never delete.

## 2026-05-25 — M4-traffic bump 43 → 46

Net +3 `unsafe { ... }` blocks in `src/unsafe_boundary.rs`: four new wrappers
for the C-side PHY plumbing, minus the removed Rust `carrier_on` wrapper now
handled directly by the C PHY link handler.

- `bridge_phy_register(ndev, &BridgeMdioOps)` — wraps the C
  `r8125_bridge_phy_register` call that allocates the MDIO bus,
  registers it, walks for a PHY device, and binds the dedicated PHY
  driver. SAFETY: `ndev` is a registered `net_device` alive for the
  duration of the call; `ops` is borrowed only for the call (the cshim
  copies the struct).
- `bridge_phy_connect_and_reset(ndev)` — wraps
  `r8125_bridge_phy_connect_and_reset` (phy_connect_direct + phy_init_hw
  + genphy_soft_reset + phy_resume). SAFETY: `ndev` alive; idempotency
  guard inside the cshim handles double-call.
- `bridge_phy_kick_state_machine(ndev)` — wraps the `phy_start` call.
  SAFETY: `ndev` alive; the phy was connected by the preceding
  `bridge_phy_connect_and_reset`.
- `bridge_phy_stop(ndev)` — wraps `r8125_bridge_phy_stop` (phy_stop +
  phy_disconnect). SAFETY: `ndev` alive; idempotent (the cshim no-ops if
  the phy never reached the connected state).

These are mechanical FFI wrappers — each is a single line of `unsafe`
calling out to the C side. The C side is the actual boundary; the Rust
side preserves the §6.2 discipline by keeping every `unsafe` block in
the one allowlisted file with a SAFETY comment.

No new MMIO-touching `unsafe` was added by this milestone; all MMIO for
the PHY OCP path goes through the existing `Regs::gphy_ocp_*` methods
which use the kernel `pci::Bar` accessors (safe).

## 2026-05-25 — M4-perf phase 1 bump 46 → 49

Three new safe wrappers in `src/unsafe_boundary.rs`, each a one-line
`unsafe { … }` calling a C bridge function:

- `skb_tx_csum_opts(skb) -> u32` — wraps `r8125_bridge_skb_tx_csum_opts`.
  SAFETY: `skb` is the kernel-allocated buffer just received by
  ndo_start_xmit; the driver holds the unique reference.
- `skb_rx_csum_set(skb, opts1)` — wraps `r8125_bridge_skb_rx_csum_set`.
  SAFETY: `skb` was just built by `skb_build_rx` (driver-owned).
- `bridge_account_rx(ndev, bytes)` — wraps `r8125_bridge_account_rx`.
  SAFETY: `ndev` is registered and alive (NetdevHandle holds the
  reference until Drop).

All three mutate state owned by the kernel net stack (skb fields, netdev
stats) and are therefore mechanical FFI wrappers. No new MMIO unsafe
was added by this milestone.
