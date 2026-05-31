# `docs/perf/` — Performance Baselines

Per plan §7 M6, every M6 sub-feature requires before/after numbers
captured in this directory. The plan calls out four metrics that must
appear, not throughput alone:

| Metric | Why |
|---|---|
| Median throughput (Gbps) | The headline number — but easy to fudge with one good run |
| p99 latency under load | Captures tail-behavior that median throughput hides |
| **CPU usage per Gbps** (system + softirq) | The honest cost — Gbps at 100% CPU isn't a win |
| Small-packet rate (pps) | Sensitivity to per-packet overhead, separate from byte throughput |

## Environment authority

| Environment | Authoritative for `docs/perf/`? |
|---|---|
| **Controller-KVM guest** (debug+Rust kernel, KASAN+lockdep+kmemleak+DMA_API_DEBUG, VFIO passthrough) | **No** — KASAN debug overhead adds ~30%+ CPU per Gbps. Useful for correctness iteration; not citable as perf evidence. |
| **Gateway bare metal** (stock Ubuntu kernel, CONFIG_RUST=y, no destructive debug) | **Yes** — the only environment whose numbers are quoted in M7 maintainer dossier. |

See `docs/RTL8125_Rust_Driver_Implementation_Plan.md` §1.3 for the
dual-environment rationale.

## File conventions

| File | Purpose |
|---|---|
| `gateway_baseline.md` | Pre-M6 reference state — what M6 changes must equal or exceed. Captured once at the start of M6 work. |
| `m6_msix_before_after.md` | Pre-M6-MSI-X (this file = gateway_baseline) vs post-M6-MSI-X. Plus rollback validation via `intx_only=1`. |
| `m6_jumbo_before_after.md` | Pre-M6-jumbo vs post-M6-jumbo (MTU 1500 vs 9000 with jumbo enabled). |
| `r8125_vendor_comparison.md` | Optional — same numbers against the out-of-tree Realtek `r8125` driver run on the same hardware. The plan §7 M6 gate calls for "throughput within 10% of out-of-tree `r8125`". |
| `r8169_comparison.md` | Optional — same numbers against the in-tree `r8169` mainline driver. Useful for the M7 dossier to claim parity with the upstream driver. |

## Measurement recipe

All Gateway runs use the same netns topology:
- `enp4s0` (Intel I226-V, stock `igc`) in `peer` netns at `10.0.0.1/24` — runs `iperf3 -s` and similar.
- `enp3s0` (RTL8125B, driver under test) in default netns at `10.0.0.2/24`.
- Cat6 cable between the two RJ45 ports.
- WiFi (MT7922) at separate address for management; never on the test path.

```bash
# Throughput
iperf3 -c 10.0.0.1 -B 10.0.0.2 -t 30 -i 5 --json > run.json

# p99 latency under load
# (start iperf3 in background, then time-stamped ping)
iperf3 -c 10.0.0.1 -B 10.0.0.2 -t 60 -b 100M -i 0 &
ping -c 1000 -i 0.05 -W 2 -I enp3s0 10.0.0.1 | awk -F= '/time=/{print $NF}' | sort -n | awk '
    {a[NR]=$1} END {print "p50:", a[int(NR*0.5)], "p99:", a[int(NR*0.99)], "max:", a[NR]}'

# CPU per Gbps (system + softirq)
# Run iperf3 + mpstat -P ALL 1 in parallel; integrate %sys + %soft over the run.
mpstat -P ALL 1 30 > cpu.txt &
iperf3 -c 10.0.0.1 -B 10.0.0.2 -t 30 --json > run.json
# Convention: CPU% / Gbps = (mean %sys + mean %soft) / Gbps_observed.

# Small-packet rate (pps) — UDP minimum-size flood
iperf3 -c 10.0.0.1 -B 10.0.0.2 -u -l 64 -b 1G -t 30 --json > udp.json
# Use json.end.sum_sent.packets / json.end.sum_sent.seconds.
```

For every entry in `*_before_after.md`, capture all four metrics
in both columns. **Per-feature gates**: also confirm runtime toggle
works (`ethtool -K` or equivalent module reload) — list any
caveats inline.

## Sample-table format

```markdown
| Metric | Before | After | Δ |
|---|---:|---:|---:|
| Median throughput (Gbps) | 2.36 | 2.40 | +1.7% |
| p99 latency (ms) under 100 Mbps load | 0.45 | 0.42 | -7% |
| CPU per Gbps (% sys+soft) | 18.2 | 14.1 | -22% |
| Small-packet rate (kpps) | 1820 | 1840 | +1.1% |
```

If `After` regresses on any metric, the gate is **not cleared**.
Investigate before moving to the next sub-feature.
