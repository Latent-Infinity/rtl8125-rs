# Final C(r8169)-vs-Rust comparison — conclusion (2026-06-04)

Config: rx_coalesce_timer=8, tx_coalesce_timer=8, BRIDGE_NAPI_WEIGHT=128,
zero-copy RX + per-MTU pool + V2/MSI surface fix (use_v2 gating).

## Fixed / at parity
- Throughput: PARITY across TCP+UDP x TX/RX/bidir x MTU{1500,9000} x
  offload{default,gro-off,tso-off,all-off} x load{25..100%} (all <2% of r8169,
  line rate).
- Idle latency: parity (~34-36us p50).
- Small-frame RX LOSS: FIXED by coalescing (was 66% at 64B with no moderation,
  now 0.14%).
- V2/MSI 0-IRQ blocker: FIXED (use_v2 gating + sequencing).

## Residual gaps vs r8169 (INTRINSIC — not knob-tunable)
- Loaded latency: rust p99.9 ~1720us (1500) / ~1990us (9000) vs r8169 783/563
  (2-3.5x). Invariant to RX coalesce, TX coalesce, and NAPI weight (swept).
- Small-frame peak pps: 64B 652k vs r8169 841k (-22%); 256/512B -15%.

## Why the residuals are intrinsic (evidence)
- Coalesce sweep rx{4,8,12} / tx{4,8,16}: no setting closes latency; loss-fix
  only. IRQ/s during TX load ~7.7k regardless.
- NAPI weight sweep {128,64,32}: loaded latency flat ~1700us; no effect.
- r8169 reference: 108k IRQ/s under TX load (14x rust's 7.7k) yet LOWER latency
  + higher small-frame pps. So r8169's edge is prompt per-completion servicing +
  cheaper per-packet path, not coalescing. Closing these needs hot-path /
  NAPI-cadence work (why rust gets 7.7k vs 108k completion IRQs; per-packet
  xmit/RX cost), a future item — NOT a coalescing/weight tune.

## Recommended default
rx_coalesce_timer=8 (loss fix), tx immaterial, weight=128. Module params allow
field override.
