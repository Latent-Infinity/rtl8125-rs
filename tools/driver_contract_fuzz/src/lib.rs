//! Standalone Rust contract checks for queue math and RX/TX descriptor sizing.
//!
//! This crate is intentionally host-only: it mirrors a subset of the driver
//! ring-contract logic so we can run fast perturbation tests without building
//! or running a kernel module.

#![allow(dead_code)]

/// Ring depth used by the driver (`NUM_TX_DESC` / `NUM_RX_DESC` mirror).
pub const RING_LEN: usize = 256;

/// Stop/wake thresholds mirrored from `src/netdev.rs` and `src/napi.rs`.
pub const TX_STOP_THRS: usize = 32;
pub const TX_START_THRS: usize = 64;

/// Receive descriptor len mask from `regs::DESC_LEN_MASK`.
pub const DESC_LEN_MASK: u32 = 0x3FFF;

/// RX slot size in bytes (`RX_BUF_LEN` in `src/netdev.rs` / `netdev_bridge.c`).
pub const RX_BUF_LEN: usize = 16_384;

/// Compute masked ring index for a power-of-two ring.
#[inline]
pub const fn ring_wrap(idx: usize) -> usize {
    idx & (RING_LEN - 1)
}

/// Compute how many descriptors are in flight. Returns `None` when the
/// state is already inconsistent (difference greater than ring size).
pub const fn tx_in_flight(head: usize, tail: usize) -> Option<usize> {
    let in_flight = head.wrapping_sub(tail);
    if in_flight >= RING_LEN {
        None
    } else {
        Some(in_flight)
    }
}

/// Remaining free descriptor slots. Returns `None` when state is inconsistent.
pub fn tx_free_slots(head: usize, tail: usize) -> Option<usize> {
    match tx_in_flight(head, tail) {
        Some(in_flight) => Some(RING_LEN - in_flight),
        None => None,
    }
}

/// Return true if a logical packet using `n_desc` slots can be posted now.
pub fn can_reserve_slot_batch(head: usize, tail: usize, n_desc: usize) -> bool {
    if n_desc == 0 || n_desc > RING_LEN {
        return false;
    }

    match tx_free_slots(head, tail) {
        Some(free) => free > n_desc,
        None => false,
    }
}

/// TX queue should stop when free slots drop below `TX_STOP_THRS`.
#[inline]
pub const fn queue_should_stop(free_after_xmit: usize) -> bool {
    free_after_xmit < TX_STOP_THRS
}

/// TX queue should wake when free slots clear above `TX_START_THRS`.
#[inline]
pub const fn queue_should_wake(free_after_reap: usize) -> bool {
    free_after_reap > TX_START_THRS
}

/// RX len clamping as done by `process_rx_completions()`.
#[inline]
pub const fn clamp_rx_len(desc_opts1: u32, rx_buf_len: usize) -> usize {
    let dma_len = (desc_opts1 & DESC_LEN_MASK) as usize;
    if dma_len > rx_buf_len {
        rx_buf_len
    } else {
        dma_len
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Small deterministic pseudo-RNG to avoid external deps.
    struct Lcg64 {
        state: u64,
    }

    impl Lcg64 {
        const fn new(seed: u64) -> Self {
            Self { state: seed }
        }

        fn next_u64(&mut self) -> u64 {
            // SplitMix64-style one-line LCG transition.
            self.state = self
                .state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let mut z = self.state;
            z = (z ^ (z >> 30)).wrapping_mul(0xBF58476D1CE4E5B9);
            z = (z ^ (z >> 27)).wrapping_mul(0x94D049BB133111EB);
            z ^ (z >> 31)
        }

        fn gen_range(&mut self, max_inclusive: usize) -> usize {
            let r = self.next_u64();
            (r as usize) % (max_inclusive + 1)
        }
    }

    #[test]
    fn ring_wrap_is_power_of_two_masking() {
        for idx in 0usize..(RING_LEN * 4) {
            assert_eq!(ring_wrap(idx), idx % RING_LEN);
        }
    }

    #[test]
    fn in_flight_and_free_slot_contracts_are_consistent() {
        for head in 0..(RING_LEN * 4) {
            for tail in 0..(RING_LEN * 4) {
                let in_flight = tx_in_flight(head, tail);
                let free = tx_free_slots(head, tail);

                let expected = head.wrapping_sub(tail) % RING_LEN;
                if head >= tail && head - tail < RING_LEN {
                    assert_eq!(in_flight, Some(expected));
                    assert_eq!(free, Some(RING_LEN - expected));
                    assert!(in_flight.unwrap() < RING_LEN);
                } else {
                    assert_eq!(in_flight, None);
                    assert_eq!(free, None);
                }
            }
        }
    }

    #[test]
    fn can_reserve_matches_free_minus_one_slot_guarantee() {
        for head in 0..(RING_LEN * 2) {
            for tail in 0..(RING_LEN * 2) {
                let free = match tx_free_slots(head, tail) {
                    Some(free) => free,
                    None => continue,
                };

                for n in 1..=RING_LEN {
                    if can_reserve_slot_batch(head, tail, n) {
                        assert!(free > n, "head={head} tail={tail} n={n}");
                    } else {
                        assert!(free <= n, "head={head} tail={tail} n={n}");
                    }
                }
            }
        }
    }

    #[test]
    fn rx_desc_length_is_bounded_to_descriptor_and_page_limits() {
        // All 16-bit combinations include impossible out-of-range descriptors from
        // upstream fuzzers and fuzzed packet corruption.
        for opts1 in 0u32..=u32::from(u16::MAX) {
            let clamped = clamp_rx_len(opts1 << 0, RX_BUF_LEN);
            assert!(clamped <= 0x3FFF);
            assert!(clamped <= RX_BUF_LEN);
        }
    }

    #[test]
    fn tx_ring_state_machine_fuzz_runs() {
        let mut rng = Lcg64::new(0x5eed_u64);
        let mut head = 0usize;
        let mut tail = 0usize;
        let mut stopped = false;

        for _ in 0..150_000 {
            let state_step = rng.gen_range(1);
            if state_step % 2 == 0 {
                // Emulate xmit: post 1..8 descriptors.
                let n_desc = rng.gen_range(8) + 1;
                let free_before = match tx_free_slots(head, tail) {
                    Some(v) => v,
                    None => {
                        panic!("invalid ring state before xmit: head={head} tail={tail}");
                    }
                };
                if can_reserve_slot_batch(head, tail, n_desc) {
                    head = head.wrapping_add(n_desc);
                    let free_after =
                        tx_free_slots(head, tail).expect("post-xmit state should stay valid");
                    if queue_should_stop(free_after) {
                        stopped = true;
                    }
                    assert!(free_after < free_before);
                }
            } else {
                // Emulate NAPI TX completion.
                let in_flight = tx_in_flight(head, tail)
                    .expect("in-flight state should be valid before completion");
                if in_flight == 0 {
                    continue;
                }
                let complete = (rng.gen_range(in_flight) % in_flight) + 1;
                let free_before =
                    tx_free_slots(head, tail).expect("free-before completion should be valid");
                tail = tail.wrapping_add(complete);
                let free_after =
                    tx_free_slots(head, tail).expect("post-completion state should be valid");

                if stopped {
                    if queue_should_wake(free_after) && free_after > free_before {
                        stopped = false;
                    } else {
                        assert!(!queue_should_wake(free_after) || !stopped);
                    }
                }
                assert!(free_after >= free_before);
            }
        }
    }

    #[test]
    fn tx_stop_and_wake_thresholds_use_strict_bounds() {
        assert!(!queue_should_stop(TX_STOP_THRS));
        assert!(queue_should_stop(TX_STOP_THRS - 1));
        assert!(queue_should_stop(0));

        assert!(!queue_should_wake(TX_START_THRS));
        assert!(queue_should_wake(TX_START_THRS + 1));
        assert!(queue_should_wake(RING_LEN));
    }

    #[test]
    fn stop_wake_conditions_are_mutually_consistent_over_fuzz_walk() {
        let mut rng = Lcg64::new(0xBADC0DE);
        let mut head = 0usize;
        let mut tail = 0usize;
        let mut stopped = false;

        for _ in 0..100_000 {
            let in_flight = tx_in_flight(head, tail)
                .expect("state machine starts valid and should remain valid");

            // Emulate one or more TX completions at random, with an upper
            // bound that always keeps the ring non-negative.
            if in_flight > 0 && (rng.gen_range(1) == 0) {
                let complete = (rng.gen_range(in_flight) % in_flight) + 1;
                let free_before =
                    tx_free_slots(head, tail).expect("free slots should stay valid before reap");
                tail = tail.wrapping_add(complete);
                let free_after = tx_free_slots(head, tail)
                    .expect("free slots should stay valid after reap");
                if queue_should_wake(free_after) {
                    assert!(free_after > free_before);
                    stopped = false;
                }
            }

            // Emulate a packet post when possible.
            if let Some(free_before) = tx_free_slots(head, tail) {
                let n_desc = (rng.gen_range(8) + 1) as usize;
                if can_reserve_slot_batch(head, tail, n_desc) {
                    head = head.wrapping_add(n_desc);
                    let free_after =
                        tx_free_slots(head, tail).expect("free slots should stay valid after xmit");
                    if queue_should_stop(free_after) {
                        stopped = true;
                        assert!(free_after < TX_STOP_THRS);
                    }
                    assert!(free_after <= free_before);
                    assert!(free_after > 0);
                }
            }

            // If stopped, the only permitted wake transition is crossing
            // start-threshold back to a larger free window.
            if stopped {
                let free = tx_free_slots(head, tail).expect("free slots should stay valid");
                if queue_should_wake(free) {
                    stopped = false;
                }
            }
        }
    }
}
