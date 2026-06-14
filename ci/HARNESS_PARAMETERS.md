# Soak / stress harness parameterization

Tier 4b of [`../docs/POST_SOAK_PLAN.md`](../docs/POST_SOAK_PLAN.md).
Every runtime soak / stress / counter-invariant script accepts the
same environment-variable knob set so the harness transfers to a
different NIC without script edits.

## Standard parameters

All values shown are defaults — the scripts behave today exactly
as before unless the env var is overridden.

| Variable | Default | Used by | Purpose |
|---|---|---|---|
| `IFACE` | `enp5s0` | all soaks, counter-invariant, rmmod stress | Interface under test |
| `PEER` | `10.0.0.1` | all | iperf3 / ping target IP |
| `LOCAL_IP` | `10.0.0.2` | all | IP assigned to `$IFACE` |
| `LOCAL_PREFIX` | `24` | all | CIDR prefix for `$LOCAL_IP` |
| `BDF` | `0000:05:00.0` | ASPM-on, FLR | PCI domain:bus:device.function for ASPM register access |
| `BUILD_DIR` | `/tmp/r8125_rust_build` | rmmod stress, ASPM-on | Where the built `.ko` lives |
| `SOAK_HOURS` | `24` | all soaks | Duration |
| `SAMPLE_INTERVAL` | `300` | all soaks | dmesg-sample interval, seconds |
| `BANDWIDTH` | `100M` | active soak | iperf3 rate-limit during sustained-traffic soak |
| `CYCLES` | `5` | rmmod stress | Stress cycles per invocation |
| `TRAFFIC_SECS` | `8` | rmmod stress | Active iperf3 window before rmmod fires |
| `RMMOD_DELAY` | `3` | rmmod stress | Delay between traffic start and rmmod |
| `LOG` | `/tmp/r8125_*.log` | all | Log destination (varies per script) |

## Example: same harness on a different NIC

```bash
# Imagine running the same active soak on an I226-V (igc) at the
# same Gateway, with a 192.168.50.0/24 test subnet:
IFACE=enp7s0 \
PEER=192.168.50.1 \
LOCAL_IP=192.168.50.2 \
LOCAL_PREFIX=24 \
BANDWIDTH=200M \
SOAK_HOURS=12 \
bash ci/check_active_soak.sh
```

## Parameterized scripts

- `ci/check_active_soak.sh` — sustained-traffic soak (active path,
  ASPM-off by default)
- `ci/check_aspm_idle_soak.sh` — ASPM idle soak (L1.x hazard)
- `ci/check_aspm_on_idle_soak.sh` — ASPM-on idle soak (with
  `force_aspm=1` module-side activation)
- `ci/check_aspm_both_soaks.sh` — orchestrator running both above
  back-to-back
- `ci/check_counter_invariant.sh` — runtime counter-invariant check
  (positional args also accepted for back-compat:
  `check_counter_invariant.sh <iface> <peer>`)
- `ci/check_rmmod_while_up.sh` — rmmod-under-traffic stress loop

## What is NOT parameterized (and won't be without good reason)

- **Per-CPU counter names** (`tx_received` etc.) — these are the
  counter contract; if the next driver renames them, it's a different
  invariant. Don't templatize.
- **Module name** (`r8125_rust`) — every script targets this
  specific module. Renaming per project is a one-line per-script
  change, but isn't worth env-var-izing because each project
  ships its own scripts anyway.
- **`/tmp/r8125_*.log` paths** — convention. Override via `LOG=`
  if needed.

## What's still to do

The `BDF` parameter is correctly threaded but the ASPM scripts'
`setpci` lines reference `$BDF` directly already; nothing further
needed.

If we ever want to drive the harness from a remote runner (current
KVM control flow), that orchestration lives in `scripts/`, not in
`ci/check_*.sh`. The check scripts assume they run on the DUT
itself.

## Cross-references

- [`GATE_INVENTORY.md`](GATE_INVENTORY.md) — which gates are
  generic / netdev / rtl8125
- [`../docs/PATTERNS.md`](../docs/PATTERNS.md) #13 soak harness
- [`../docs/POST_SOAK_PLAN.md`](../docs/POST_SOAK_PLAN.md) §Tier 4b
