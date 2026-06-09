// SPDX-License-Identifier: GPL-2.0
//! Pure hardware field-layout and packing math for the RTL8125 RX descriptor
//! and RSS register block.
//!
//! Everything here is deliberately **kernel-free** - it depends only on `core`,
//! so it compiles standalone with `rustc --test` and is covered by host unit
//! tests (`ci/check_rust_unit_tests.sh`). The kernel-coupled callers
//! ([`crate::ring`], [`crate::mmio`], [`crate::netdev`]) re-export and call
//! these functions; keeping the arithmetic isolated lets the descriptor
//! stride/offset logic - the source of the 2026-06-06 RX-stall regression - be
//! unit-tested without a device.
#![allow(dead_code)]

// -- V3 descriptor HeaderInfo hash classification masks ---------------------
const RSS_HEADER_INFO_V3_L3_MASK: u16 = (1 << 10) | (1 << 12);
const RSS_HEADER_INFO_V3_L4_MASK: u16 = (1 << 13) | (1 << 9);

/// RSS indirection table: 128 one-byte queue entries (4 per 32-bit register
/// word, so 32 dwords). RTL8125B `RSS_INDIRECTION_TBL_8125` spans these bytes.
pub(crate) const RSS_INDIR_TBL_ENTRIES: usize = 128;

/// RX descriptor on-the-wire format. Fixed once at probe.
#[derive(Copy, Clone, Debug, PartialEq, Eq, Default)]
pub(crate) enum RxDescFormat {
    /// Legacy 16-byte V1/V2-style layout.
    #[default]
    Legacy,
    /// RTL8125B RSS-capable 32-byte layout.
    V3,
    /// RTL8125BP RSS-capable 16-byte layout.
    V4,
}

impl RxDescFormat {
    /// TX/RX descriptor byte stride for this format. The single source of truth
    /// for stride - every RX accessor derives from this so the reaper, the
    /// publisher, and the chip can never disagree (`ci/check_rx_desc_stride.sh`).
    #[inline]
    pub(crate) const fn descriptor_len(self) -> usize {
        match self {
            RxDescFormat::Legacy | RxDescFormat::V4 => 16,
            RxDescFormat::V3 => 32,
        }
    }

    /// `(addr_off, opts2_off, opts1_off)` byte offsets within one slot.
    #[inline]
    pub(crate) const fn publish_offsets(self) -> (usize, usize, usize) {
        match self {
            // Legacy RX: opts2/opts1 at qword0, addr at qword1.
            RxDescFormat::Legacy => (8, 4, 0),
            // V3: addr at +16, opts2/opts1 at +24/+28.
            RxDescFormat::V3 => (16, 24, 28),
            // V4: addr at +0, opts2/opts1 at +8/+12.
            RxDescFormat::V4 => (0, 8, 12),
        }
    }
}

/// RSS hash payload extracted from V3/V4 descriptor fields.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum RxHashType {
    L3,
    L4,
}

/// Parsed hardware hash payload.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) struct RxHash {
    pub(crate) value: u32,
    pub(crate) kind: RxHashType,
}

/// Normalized RX completion fields consumed by the Rust hot path.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) struct RxCompletion {
    pub(crate) len: usize,
    pub(crate) opts1: u32,
    pub(crate) opts2: u32,
    pub(crate) rss_hash: Option<RxHash>,
}

#[inline]
fn rx_hash_type_v3(header_info: u16) -> Option<RxHashType> {
    if header_info & RSS_HEADER_INFO_V3_L3_MASK == 0 {
        return None;
    }
    if header_info & RSS_HEADER_INFO_V3_L4_MASK != 0 {
        Some(RxHashType::L4)
    } else {
        Some(RxHashType::L3)
    }
}

/// Decode a V3 descriptor hash from its raw `RSSResult` + `HeaderInfo` words.
/// Shared by the NAPI fast path (`unsafe_boundary::rx_read_completion`).
#[inline]
pub(crate) fn rx_hash_from_v3(rss_result: u32, header_info: u16) -> Option<RxHash> {
    rx_hash_type_v3(header_info).map(|kind| RxHash {
        value: rss_result,
        kind,
    })
}

/// Per-open RX descriptor parse parameters. The format match is resolved ONCE
/// here (at poll entry) so the NAPI hot loop reads fields by precomputed byte
/// offsets with NO per-packet `match RxDescFormat`. `stride` MUST come from
/// `RxDescFormat::descriptor_len()` so it agrees with the chip and the
/// publish/write paths (`ci/check_rx_desc_stride.sh`).
#[derive(Copy, Clone)]
pub(crate) struct RxParse {
    /// Per-descriptor byte stride (16 legacy, 32 V3).
    pub(crate) stride: usize,
    /// Byte offset of `opts1` (carries OWN + length) within the slot.
    pub(crate) opts1_off: usize,
    /// Byte offset of `opts2` (csum/VLAN metadata) within the slot.
    pub(crate) opts2_off: usize,
    /// `(RSSResult_off, HeaderInfo_off)` for hash-bearing formats; `None` for
    /// legacy (no hash field). V4 is not wired (validated chip is V3).
    pub(crate) hash_off: Option<(usize, usize)>,
}

impl RxParse {
    #[inline]
    pub(crate) fn new(format: RxDescFormat) -> Self {
        let (_addr_off, opts2_off, opts1_off) = format.publish_offsets();
        let hash_off = match format {
            // V3: RSSResult @ +8, HeaderInfo @ +14 (see `struct RxDescV3`).
            RxDescFormat::V3 => Some((8, 14)),
            RxDescFormat::Legacy | RxDescFormat::V4 => None,
        };
        Self {
            stride: format.descriptor_len(),
            opts1_off,
            opts2_off,
            hash_off,
        }
    }
}

// -- RSS register packing ---------------------------------------------------

/// `Q_NUM_CTRL_8125` value for a queue count: the vendor programs `count - 1`
/// (0 means single queue), clamped so a `0` request never underflows.
#[inline]
pub(crate) const fn rss_q_num_ctrl(queue_count: u8) -> u16 {
    queue_count.saturating_sub(1) as u16
}

/// Pack four 1-byte indirection-table queue entries into the little-endian
/// dword the chip expects (four entries per `RSS_INDIRECTION_TBL` register).
#[inline]
pub(crate) const fn indir_word(entries: [u8; 4]) -> u32 {
    (entries[0] as u32)
        | ((entries[1] as u32) << 8)
        | ((entries[2] as u32) << 16)
        | ((entries[3] as u32) << 24)
}

/// Pack four RSS key bytes into a register dword (low byte first), matching
/// vendor `rtl8125_store_rss_key`.
#[inline]
pub(crate) const fn key_word(bytes: [u8; 4]) -> u32 {
    u32::from_le_bytes(bytes)
}

/// Number of RX queues to actually set up from an `rss_queues` request, clamped
/// to the compile-time maximum (B6). `0` (RSS off / default) means the proven
/// single-queue path; any non-zero request activates that many queues, capped
/// at `max`. Centralizing this keeps probe, ndo_open, IRQ wiring, and RSS
/// programming from each clamping differently.
#[inline]
pub(crate) const fn active_rx_queues(rss_queues: u8, max: usize) -> usize {
    let r = rss_queues as usize;
    if r == 0 {
        1
    } else if r > max {
        max
    } else {
        r
    }
}

/// Validate an ethtool RSS indirection table (B5 `set_rxfh`): every bucket must
/// map to an owned queue (`entry < queue_count`). At the current `N=1` runtime
/// that means every entry must be 0; the check generalizes once more queues are
/// owned. An empty slice is vacuously valid (caller passed no indir change).
#[inline]
pub(crate) fn rxfh_indir_all_valid(indir: &[u32], queue_count: u32) -> bool {
    queue_count > 0 && indir.iter().all(|&e| e < queue_count)
}

// -- TX byte-budget hysteresis (test-5 MSI-safe latency throttle) -----------

/// Wake-predicate core for the TX queue. The queue may resume only when BOTH
/// hysteresis halves permit it:
///   - descriptor slots have drained past `start_thrs`, AND
///   - in-flight TX bytes are below the byte-budget low-water, `max(1, budget/2)`.
///
/// The byte half is a no-op when `byte_budget == 0` (throttle off). The kernel
/// wrapper [`crate::netdev::tx_should_wake`] reads the atomics and calls this so
/// the ring-full and byte-budget stop reasons share one re-check. Pure means
/// host-unit-tested (the hysteresis is easy to get subtly wrong).
#[inline]
pub(crate) fn tx_should_wake_decision(
    free: usize,
    start_thrs: usize,
    byte_budget: usize,
    inflight_bytes: usize,
) -> bool {
    if free <= start_thrs {
        return false;
    }
    if byte_budget == 0 {
        return true;
    }
    let low_water = (byte_budget / 2).max(1);
    inflight_bytes < low_water
}

/// Bytes to charge against the in-flight byte budget for one TX packet. Returns
/// 0 (untracked) when the throttle is off, OR when even a full descriptor
/// window (`desc_window` slots) of this packet size could never reach the
/// budget, so small packets never trip the throttle and pay no accounting.
#[inline]
pub(crate) const fn tx_budget_tracked_bytes(
    byte_budget: usize,
    wire_len: usize,
    desc_window: usize,
) -> usize {
    if byte_budget == 0 || wire_len.saturating_mul(desc_window) < byte_budget {
        0
    } else {
        wire_len
    }
}

/// Clamp a tracked byte count into the `u32` per-slot shadow field.
#[inline]
pub(crate) const fn tx_budget_shadow_len(bytes: usize) -> u32 {
    if bytes > u32::MAX as usize {
        u32::MAX
    } else {
        bytes as u32
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // -- descriptor stride: the 2026-06-06 RX-stall regression guard --------
    #[test]
    fn descriptor_len_per_format() {
        assert_eq!(RxDescFormat::Legacy.descriptor_len(), 16);
        assert_eq!(RxDescFormat::V3.descriptor_len(), 32);
        assert_eq!(RxDescFormat::V4.descriptor_len(), 16);
    }

    #[test]
    fn publish_offsets_per_format() {
        assert_eq!(RxDescFormat::Legacy.publish_offsets(), (8, 4, 0));
        assert_eq!(RxDescFormat::V3.publish_offsets(), (16, 24, 28));
        assert_eq!(RxDescFormat::V4.publish_offsets(), (0, 8, 12));
    }

    #[test]
    fn rxparse_legacy() {
        let p = RxParse::new(RxDescFormat::Legacy);
        assert_eq!(p.stride, 16);
        assert_eq!(p.opts1_off, 0);
        assert_eq!(p.opts2_off, 4);
        assert_eq!(p.hash_off, None);
    }

    #[test]
    fn rxparse_v3() {
        let p = RxParse::new(RxDescFormat::V3);
        assert_eq!(p.stride, 32);
        assert_eq!(p.opts1_off, 28);
        assert_eq!(p.opts2_off, 24);
        assert_eq!(p.hash_off, Some((8, 14)));
    }

    #[test]
    fn rxparse_stride_matches_descriptor_len() {
        // The exact invariant ci/check_rx_desc_stride.sh enforces statically.
        for f in [RxDescFormat::Legacy, RxDescFormat::V3, RxDescFormat::V4] {
            assert_eq!(RxParse::new(f).stride, f.descriptor_len());
        }
    }

    // -- V3 hash classification --------------------------------------------
    #[test]
    fn hash_none_when_no_l3_bits() {
        assert_eq!(rx_hash_from_v3(0xDEAD_BEEF, 0), None);
        // An L4 bit without any L3 bit still classifies as no-hash: L3 is the
        // gate. (1<<9) is an L4 mask bit.
        assert_eq!(rx_hash_from_v3(0x1234, 1 << 9), None);
    }

    #[test]
    fn hash_l3_when_l3_only() {
        let h = rx_hash_from_v3(0xAABB_CCDD, 1 << 10).unwrap();
        assert_eq!(h.kind, RxHashType::L3);
        assert_eq!(h.value, 0xAABB_CCDD);
        assert_eq!(rx_hash_from_v3(0, 1 << 12).unwrap().kind, RxHashType::L3);
    }

    #[test]
    fn hash_l4_when_l3_and_l4() {
        let h = rx_hash_from_v3(0x0102_0304, (1 << 10) | (1 << 13)).unwrap();
        assert_eq!(h.kind, RxHashType::L4);
        assert_eq!(h.value, 0x0102_0304);
        assert_eq!(
            rx_hash_from_v3(0, (1 << 12) | (1 << 9)).unwrap().kind,
            RxHashType::L4
        );
    }

    // -- RSS register packing ----------------------------------------------
    #[test]
    fn q_num_ctrl_is_count_minus_one_clamped() {
        assert_eq!(rss_q_num_ctrl(0), 0);
        assert_eq!(rss_q_num_ctrl(1), 0);
        assert_eq!(rss_q_num_ctrl(2), 1);
        assert_eq!(rss_q_num_ctrl(4), 3);
    }

    #[test]
    fn indir_word_lane_order() {
        assert_eq!(indir_word([0, 0, 0, 0]), 0);
        assert_eq!(indir_word([1, 2, 3, 4]), 0x0403_0201);
        assert_eq!(indir_word([0xff, 0, 0, 0]), 0x0000_00ff);
        assert_eq!(indir_word([0, 0, 0, 0xff]), 0xff00_0000);
    }

    #[test]
    fn key_word_is_little_endian() {
        assert_eq!(key_word([0x01, 0x02, 0x03, 0x04]), 0x0403_0201);
        assert_eq!(key_word([0xde, 0xad, 0xbe, 0xef]), 0xefbe_adde);
    }

    #[test]
    fn indir_tbl_entries_is_one_byte_per_bucket() {
        // 128 entries, 4 per dword, so 32 register writes.
        assert_eq!(RSS_INDIR_TBL_ENTRIES % 4, 0);
        assert_eq!(RSS_INDIR_TBL_ENTRIES / 4, 32);
    }

    // -- TX byte-budget hysteresis -----------------------------------------
    const START: usize = 64; // mirrors napi::TX_START_THRS
    const WINDOW: usize = 224; // mirrors RING_LEN(256) - TX_STOP_THRS(32)

    #[test]
    fn wake_blocked_below_descriptor_floor() {
        // At or below the floor the queue never wakes, regardless of bytes.
        assert!(!tx_should_wake_decision(START, START, 0, 0));
        assert!(!tx_should_wake_decision(START - 1, START, 0, 0));
        assert!(!tx_should_wake_decision(10, START, 131072, 0));
    }

    #[test]
    fn wake_when_budget_off_and_slots_free() {
        // budget == 0 means byte half is a no-op; only the floor matters.
        assert!(tx_should_wake_decision(START + 1, START, 0, 999_999));
    }

    #[test]
    fn wake_gated_by_byte_low_water() {
        // budget 131072 means low-water 65536. Above the floor, wake iff inflight <
        // low-water.
        assert!(tx_should_wake_decision(128, START, 131072, 65535));
        assert!(!tx_should_wake_decision(128, START, 131072, 65536));
        assert!(!tx_should_wake_decision(128, START, 131072, 200000));
    }

    #[test]
    fn low_water_never_zero() {
        // budget 1 means budget/2 == 0, clamped to 1: inflight 0 wakes, 1 does not.
        assert!(tx_should_wake_decision(128, START, 1, 0));
        assert!(!tx_should_wake_decision(128, START, 1, 1));
    }

    #[test]
    fn tracked_bytes_off_when_budget_zero() {
        assert_eq!(tx_budget_tracked_bytes(0, 1448, WINDOW), 0);
    }

    #[test]
    fn tracked_bytes_ignores_small_packets() {
        // 64B * 224 = 14336 < 131072 default budget, so untracked (0).
        assert_eq!(tx_budget_tracked_bytes(131072, 64, WINDOW), 0);
        // 1448B * 224 = 324352 >= 131072, so tracked at full wire length.
        assert_eq!(tx_budget_tracked_bytes(131072, 1448, WINDOW), 1448);
    }

    #[test]
    fn shadow_len_clamps_to_u32() {
        assert_eq!(tx_budget_shadow_len(0), 0);
        assert_eq!(tx_budget_shadow_len(1448), 1448);
        assert_eq!(tx_budget_shadow_len(u32::MAX as usize), u32::MAX);
        assert_eq!(tx_budget_shadow_len(u32::MAX as usize + 1), u32::MAX);
    }

    // ── B5 ethtool rxfh validation ─────────────────────────────────────────
    #[test]
    fn indir_valid_single_queue_requires_all_zero() {
        assert!(rxfh_indir_all_valid(&[0, 0, 0, 0], 1));
        assert!(!rxfh_indir_all_valid(&[0, 1], 1));
        assert!(!rxfh_indir_all_valid(&[1], 1));
    }

    #[test]
    fn indir_valid_multi_queue_bounds() {
        assert!(rxfh_indir_all_valid(&[0, 1, 2, 3], 4));
        assert!(!rxfh_indir_all_valid(&[0, 4], 4)); // 4 not < 4
        assert!(!rxfh_indir_all_valid(&[0, 1, 2, 3, 99], 4));
    }

    #[test]
    fn indir_valid_edge_cases() {
        assert!(rxfh_indir_all_valid(&[], 1)); // no-change: vacuously valid
        assert!(!rxfh_indir_all_valid(&[0], 0)); // zero queues: nothing valid
    }

    // ── B6 active RX queue count ───────────────────────────────────────────
    #[test]
    fn active_rx_queues_default_is_single() {
        // RSS off (0) and explicit 1 both mean the single-queue path.
        assert_eq!(active_rx_queues(0, 4), 1);
        assert_eq!(active_rx_queues(1, 4), 1);
    }

    #[test]
    fn active_rx_queues_activates_requested() {
        assert_eq!(active_rx_queues(2, 4), 2);
        assert_eq!(active_rx_queues(3, 4), 3);
        assert_eq!(active_rx_queues(4, 4), 4);
    }

    #[test]
    fn active_rx_queues_clamps_to_max() {
        assert_eq!(active_rx_queues(8, 4), 4);
        assert_eq!(active_rx_queues(255, 4), 4);
    }
}
