# tx_byte_budget final-default sweep

Use `scripts/gateway_tx_byte_budget_sweep.sh` on the Gateway bare-metal
loopback rig to choose the final `tx_byte_budget` default.

Recommended run:

```bash
sudo TX_BYTE_BUDGETS="0 32768 65536 131072 262144 524288" \
  REPS=3 \
  PING_COUNT=1000 \
  PING_INTERVAL=0.02 \
  PPS_FRAMES="64 128 256" \
  scripts/gateway_tx_byte_budget_sweep.sh
```

Read the result from the generated `summary.csv` and `pps.csv`.

The harness loads `r8125_rust` with `debug_counters=1` because it needs
`xmit_calls` and `tx_doorbells` from the `ndo_stop` log. Production/default
loads leave those hot-path debug atomics disabled.

Selection rule:

1. Treat `0` as the off-control, not a default candidate.
2. Reject any nonzero budget that loses TCP line rate, creates
   `tx_busy_exception`, or drops 64/128/256 B TX PPS versus the best nonzero
   budget.
3. Pick the largest remaining budget whose loaded ICMP p99 stays
   parity-or-better versus the C-driver target. Larger budgets reduce queue
   stop/wake churn; smaller budgets reduce TX residency.
4. If adjacent budgets tie, keep `131072` unless the larger value clearly
   improves PPS or CPU cost.

Optional `xmit_more` confirmation:

```bash
sudo XMIT_MORE_PROBE=1 \
  XMIT_MORE_CMD='<forwarding or sendmmsg workload>' \
  scripts/gateway_tx_byte_budget_sweep.sh
```

The evidence to look for is `tx_doorbells / xmit_calls < 1.0` in
`xmit_more_probe.csv`. The default probe uses parallel UDP iperf3 only as a
smoke; forwarding or sendmmsg is the stronger batching workload.
