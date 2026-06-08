# Rust RPS Collapse Diagnostic - 2026-06-07

Follow-up to `docs/perf/trackb_20260607/TRACKB_VALUE.md`.

Run shape:

- Gateway `ms-a2-gateway`, kernel `7.0.0-22-generic`
- Driver: `r8125_rust`
- DUT: `enp3s0` in netns `dut`, peer `enp4s0` in netns `peer`
- Traffic: `iperf3 -u -b 0 -l 64 -R -P 10`
- Active IRQ: 68 pinned to CPU8
- RPS: `rx-0/rps_cpus=0000fe00` (CPUs 9-15)
- App: `app_bench` pinned to CPU8

Verdict:

- 5/5 reps classified `ok`.
- P2 app retention: 75-83%.
- P2 RX: 2.28-2.39 Mpps.
- `rx_hash_l4` advanced every run.
- `rx_hash_missing=0`, `rx_hash_disabled=0`.
- Softnet drops were 0 in the intended-mask run.

Conclusion: the earlier 1% Rust+RPS row is not reproduced when RPS state and
RXHASH counters are captured. Treat it as an inconclusive RPS-control-plane
outlier unless it reproduces under `scripts/rps_collapse_diagnose.sh`.
