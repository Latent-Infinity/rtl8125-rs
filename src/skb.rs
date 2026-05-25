// SPDX-License-Identifier: GPL-2.0
//! sk_buff ownership wrapper for the RTL8125 Rust driver — plan §6.3.
//!
//! ## M4-full first cut (this file's current scope)
//!
//! TX and RX disposition for M4-full's first cut is handled inline in
//! `src/netdev.rs` / `src/napi.rs` using the safe cshim helpers
//! (`bridge_skb_data_dma_map` / `bridge_skb_frag_dma_map` /
//! `bridge_skb_consume_tx` / `bridge_skb_free_error` /
//! `bridge_skb_build_rx` / `bridge_skb_deliver_rx` /
//! `bridge_skb_drop_rx`). The cshim does the
//! `dev_kfree_skb_any` / `napi_consume_skb` / `napi_gro_receive` calls and
//! the §6.3 counter increments, so the Rust side cannot accidentally leak
//! an skb to the wrong disposition — every helper enforces exactly one
//! outcome.
//!
//! ## What §6.3 type-state lands here later (refactor pending — M5)
//!
//! The plan §6.3 sketches per-state wrappers:
//!
//! ```text
//! struct TxSkb<S: TxState> { raw: NonNull<sk_buff>, _state: PhantomData<S> }
//! struct Received;          // just arrived from ndo_start_xmit
//! struct Mapped(DmaHandle); // dma_map_single succeeded
//! struct Submitted;         // descriptor posted to ring, OWN bit set
//! struct Completing;        // hardware released OWN; reaper holds it
//! ```
//!
//! with state-consuming transitions and `Drop` as the leak detector
//! (panic in debug; `WARN_ON_ONCE` + quarantine in release). The wrappers
//! prevent "wrong fragment count with lots of small packets" — a TX slot
//! cannot believe it is empty while still holding a live skb pointer,
//! because the type system tracks where in the state machine the pointer
//! lives. The refactor is queued for M5 alongside the NAPI-stability work
//! (plan §7 M5), where the type discipline pays its rent in
//! `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error`
//! correctness under load.
//!
//! Until the refactor lands, the §6.3 counter invariant is enforced by
//! the cshim helpers themselves (counters incremented exactly once per
//! disposition) plus the CI smoke test (`tx_received - tx_consumed -
//! tx_busy_exception - tx_dropped_error == 0` at quiesce).
