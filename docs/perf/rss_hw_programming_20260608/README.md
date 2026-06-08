# RSS Hardware Programming Gateway Smoke - 2026-06-08

Gateway: `ms-a2-gateway`, kernel `7.0.0-22-generic`.

Build source: synced from this worktree to a temporary gateway directory and
built on the gateway with `make`. Module `modinfo` exposed `rss_queues`.

Accepted smoke runs:

| mode | module parameter | result |
|---|---|---|
| `default_linerate` | `rss_queues=0` | TCP TX/RX at 2.345+ Gbps, UDP 1448B TX/RX at 2.350 Gbps, `rx_hash_missing=0`, no driver drops, 1 RX / 1 TX queue |
| `rssq1` | `rss_queues=1` | TCP TX/RX at 2.346+ Gbps, UDP 1448B TX/RX at 2.350 Gbps, `rx_hash_missing=0`, no driver drops, 1 RX / 1 TX queue |
| `rssq2_negative` | `rss_queues=2` | `ip link set enp3s0 up` returns `EINVAL`; dmesg logs that only one RX queue is owned |

Both accepted traffic runs used:

```text
RUN_SECS=5 UDP_BITRATE=2350M UDP_LENGTHS="64 1448" TOGGLE_VLAN_OFF=0 MTUS=1500
```

Artifacts:

- `default_linerate/`
- `rssq1/`
- `rssq2_negative.txt`

Notes:

- `ethtool -x` remains unsupported; RSS key/indir readback and control are the
  next ethtool-control step.
- An initial exploratory default run used `UDP_BITRATE=3G` and produced one
  AMD-Vi `IO_PAGE_FAULT` under above-line-rate 64B UDP stress. The accepted
  line-rate runs above did not reproduce it. Treat that as overload-stress
  follow-up, not as evidence that the RSS programming checkpoint regressed the
  default path.
