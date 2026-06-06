# BQL netdev_sent_queue ↔ MSI-X delivery interaction (2026-06-05)

## Symptom
With full BQL over MSI/V2 (use_v2=true): 0 MSI-X delivery (vector flat),
TX stuck (inflight=90, tx_consumed=0), ping FAIL — deterministic (4/4 loads).
Over INTx the SAME build works fully (ping OK, tx_consumed flows, BQL active).

## Isolation (each tested over MSI, x3, rebuild per config)
- all BQL calls disabled        -> MSI works (irq_delta 3-5)
- dql_seed only                 -> MSI works (irq_delta 3-5)
- dql_seed + netdev_sent_queue  -> MSI DEAD (0 irq)
- + sent_queue moved AFTER OWN publish -> MSI DEAD (0 irq)  [not placement]
=> netdev_sent_queue() in the xmit path, at ANY placement, deterministically
   suppresses MSI-X delivery. dql_seed + completed_queue are innocent.

## Register signature in the dead state
ISR_v2(0xD04)=0x00210000 (TOK_Q0|LINKCHG latched)
IMR_V2_CLEAR(0xD00)=0x00210001  -> chip mask UNMASKED (ROK|TOK|LINKCHG)
MSI-X cap: Enable+ Masked-      -> function not masked
IRQ 68: count=0 unhandled=0     -> not kernel-disabled, not spurious
manual IMR_V2 re-unmask via devmem -> no change
=> chip is not delivering the MSI-X message despite unmasked IMR_V2 + enabled
   MSI-X. A pure-software accounting call (netdev_sent_queue) is suppressing a
   hardware MSI-X message => indirect via kernel queue/IRQ state. Mechanism TBD
   (needs ftrace on xmit/IRQ path). Likely a V2-surface / netdev_queue-state
   interaction specific to this chip's MSI-X message-id routing.

## Status
BQL recaptures the loaded latency (1500=824us≈C, 9000=43us<<C) and is correct
over INTx. MSI+BQL blocked on this interaction. Workaround: intx_only=1 keeps
BQL+latency-fix working (higher IRQ overhead than MSI).
