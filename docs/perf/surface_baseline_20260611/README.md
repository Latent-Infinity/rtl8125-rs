# Pre-gap-closure netdev/ethtool surface baseline (2026-06-11)

Frozen evidence of the driver's user-visible surface **before** the
`docs/UPSTREAM_GAP_CLOSURE_PLAN.md` work, so each landed feature can be diffed
against it. Captured read-only from the gateway DUT (`enp3s0`, dut netns,
`r8125_rust rss_queues=0`) on the `7.0.0-kasan` kernel via
`scripts/capture_surface.sh`.

Raw `ethtool`/`ip` outputs are the authoritative artifacts. Gaps visible here
that the plan closes:

- `ethtool_link_ksettings.txt` — only `Link detected: yes`; **no Speed/Duplex/
  autoneg/supported-modes** (get_link works; get_link_ksettings absent → P0).
- `ethtool_a_pause.txt` — `Operation not supported` (P1).
- `ethtool_c_coalesce.txt` — `Operation not supported` (P1).
- `ethtool_g_ring.txt` — `Operation not supported` (P1).
- `ethtool_eee.txt` — `Operation not supported` (P2 defer).
- `ethtool_S_stats.txt` / `ip_s_link.txt` — software §6.3 + folded drops present;
  hardware tally (`rx_missed_errors`/`rx_fifo_errors`) still 0 (P1).

Note: `SUMMARY.txt`'s "present" for link_ksettings/tsinfo is a heuristic
artifact — the kernel returns default/partial data (via `get_link` /
default ts_info) instead of an explicit "not supported", so the grep doesn't
flag them. The raw files and `ci/check_surface_inventory.sh` (code-based) are
the accurate trackers.

Re-capture after a feature lands:
`bash scripts/capture_surface.sh <out> enp3s0 ssh gateway sudo ip netns exec dut`
