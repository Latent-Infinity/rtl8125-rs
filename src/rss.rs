// SPDX-License-Identifier: GPL-2.0
//! Rust-owned RSS policy: the active Toeplitz hash key and the 128-entry
//! indirection table, plus the pure validation / derivation logic.
//!
//! This module is the single source of truth for "what RSS configuration is
//! active", so `get_rxfh` reports exactly what `apply_rss_programming` wrote to
//! hardware. It is kernel-free (no MMIO, no FFI) so the decisions below are
//! host-unit-tested; the hardware register programming lives in `mmio`/`netdev`
//! and the ethtool object glue in the cshim.
//!
//! A field of `None` means "use the hardware/system default" — the system
//! Toeplitz key, or the default round-robin spread for the active queue count.
//! An untouched policy therefore reproduces the prior behavior byte-for-byte,
//! and a channel-count change to an un-customized table needs no fixup.

/// RSS Toeplitz key length in bytes. Must equal `regs::RSS_KEY_SIZE` and the C
/// `R8125_RSS_KEY_SIZE` (tied by `ci/check_rss_ethtool.sh`).
pub(crate) const RSS_KEY_SIZE: usize = 40;

/// Indirection-table bucket count. Must equal `layout::RSS_INDIR_TBL_ENTRIES`
/// and the C `R8125_RSS_INDIR_SIZE`.
pub(crate) const RSS_INDIR_ENTRIES: usize = 128;

/// Why a `set_rxfh` request was rejected. Maps to an errno at the boundary.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum RssError {
    /// The supplied table had the wrong length, or an entry referenced a queue
    /// index `>=` the active queue count (`-EINVAL`).
    InvalidTable,
}

/// The active RSS configuration cache.
pub(crate) struct RssPolicy {
    key: Option<[u8; RSS_KEY_SIZE]>,
    indir: Option<[u8; RSS_INDIR_ENTRIES]>,
}

impl RssPolicy {
    /// Rebuild a policy from its persisted parts (the `NetdevState` atomic-array
    /// snapshot — `None` for a component means "default"). The inverse readers
    /// are [`Self::key`] and [`Self::custom_indir`], so the lock-free storage in
    /// `NetdevState` round-trips through this single tested type under RTNL.
    pub(crate) fn from_stored(
        key: Option<[u8; RSS_KEY_SIZE]>,
        indir: Option<[u8; RSS_INDIR_ENTRIES]>,
    ) -> Self {
        Self { key, indir }
    }

    /// The stored custom table, if any (`None` ⇒ the default spread is active).
    /// Pairs with [`Self::key`] for writing the policy back to storage.
    pub(crate) fn custom_indir(&self) -> Option<&[u8; RSS_INDIR_ENTRIES]> {
        self.indir.as_ref()
    }

    /// Default round-robin indirection entry for `bucket`: `bucket % queue_count`
    /// (mirrors `ethtool_rxfh_indir_default`). `queue_count` is clamped to `>= 1`
    /// so a `0`/disabled request maps everything to queue 0.
    #[inline]
    pub(crate) fn default_indir_entry(bucket: usize, queue_count: u8) -> u8 {
        let qc = if queue_count == 0 {
            1
        } else {
            queue_count as usize
        };
        (bucket % qc) as u8
    }

    /// True iff every entry in `indir` references an active queue (`< queue_count`).
    pub(crate) fn indir_valid(indir: &[u8], queue_count: u8) -> bool {
        let qc = if queue_count == 0 { 1 } else { queue_count };
        indir.iter().all(|&q| q < qc)
    }

    /// True iff `indir` is exactly the default round-robin spread for `queue_count`.
    pub(crate) fn is_default_indir(indir: &[u8], queue_count: u8) -> bool {
        indir.len() == RSS_INDIR_ENTRIES
            && indir
                .iter()
                .enumerate()
                .all(|(i, &q)| q == Self::default_indir_entry(i, queue_count))
    }

    /// Store a custom hash key. The cache is the source of truth; callers that
    /// only want to detect "is this the system key" compare before calling.
    pub(crate) fn set_key(&mut self, key: [u8; RSS_KEY_SIZE]) {
        self.key = Some(key);
    }

    /// Validate and store an indirection table for `queue_count`. A table equal
    /// to the default spread collapses to `None` so later channel-count changes
    /// auto-track the default. On error the policy is left unchanged.
    pub(crate) fn set_indir(&mut self, indir: &[u8], queue_count: u8) -> Result<(), RssError> {
        if indir.len() != RSS_INDIR_ENTRIES || !Self::indir_valid(indir, queue_count) {
            return Err(RssError::InvalidTable);
        }
        if Self::is_default_indir(indir, queue_count) {
            self.indir = None;
        } else {
            let mut t = [0u8; RSS_INDIR_ENTRIES];
            t.copy_from_slice(indir);
            self.indir = Some(t);
        }
        Ok(())
    }

    /// On a queue-count change, drop a now-invalid custom table back to the
    /// default (its entries would steer to queues that no longer exist). A still
    /// valid custom table is kept.
    pub(crate) fn reclamp_for_queue_count(&mut self, queue_count: u8) {
        if let Some(t) = &self.indir {
            if !Self::indir_valid(t, queue_count) {
                self.indir = None;
            }
        }
    }

    /// Materialize the effective indirection table for `queue_count` into `out`
    /// (the stored custom table, or the default spread).
    pub(crate) fn effective_indir(&self, queue_count: u8, out: &mut [u8; RSS_INDIR_ENTRIES]) {
        match &self.indir {
            Some(t) => *out = *t,
            None => {
                for (i, e) in out.iter_mut().enumerate() {
                    *e = Self::default_indir_entry(i, queue_count);
                }
            }
        }
    }

    /// The stored custom key, if any. `None` ⇒ the caller fills the system key.
    pub(crate) fn key(&self) -> Option<&[u8; RSS_KEY_SIZE]> {
        self.key.as_ref()
    }

    /// Whether a custom (non-default) indirection table is active.
    pub(crate) fn has_custom_indir(&self) -> bool {
        self.indir.is_some()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_table(qc: u8) -> [u8; RSS_INDIR_ENTRIES] {
        let mut t = [0u8; RSS_INDIR_ENTRIES];
        for (i, e) in t.iter_mut().enumerate() {
            *e = RssPolicy::default_indir_entry(i, qc);
        }
        t
    }

    #[test]
    fn default_entry_is_round_robin() {
        // qc=4: 0,1,2,3,0,1,2,3,...
        assert_eq!(RssPolicy::default_indir_entry(0, 4), 0);
        assert_eq!(RssPolicy::default_indir_entry(3, 4), 3);
        assert_eq!(RssPolicy::default_indir_entry(4, 4), 0);
        assert_eq!(RssPolicy::default_indir_entry(127, 4), 3);
        // qc=2: alternating.
        assert_eq!(RssPolicy::default_indir_entry(0, 2), 0);
        assert_eq!(RssPolicy::default_indir_entry(1, 2), 1);
        assert_eq!(RssPolicy::default_indir_entry(2, 2), 0);
        // qc=0 clamps to 1 -> everything queue 0.
        assert_eq!(RssPolicy::default_indir_entry(7, 0), 0);
        assert_eq!(RssPolicy::default_indir_entry(7, 1), 0);
    }

    #[test]
    fn indir_valid_bounds_each_entry() {
        assert!(RssPolicy::indir_valid(&default_table(4), 4));
        assert!(RssPolicy::indir_valid(&[0, 1, 0, 1], 2));
        // an entry == queue_count is out of range.
        assert!(!RssPolicy::indir_valid(&[0, 1, 2], 2));
        // qc=0 clamps to 1: only queue 0 is valid.
        assert!(RssPolicy::indir_valid(&[0, 0, 0], 0));
        assert!(!RssPolicy::indir_valid(&[0, 1], 0));
    }

    #[test]
    fn is_default_detects_exact_spread() {
        assert!(RssPolicy::is_default_indir(&default_table(4), 4));
        assert!(RssPolicy::is_default_indir(&default_table(2), 2));
        // a default-for-2 table is NOT the default for 4.
        assert!(!RssPolicy::is_default_indir(&default_table(2), 4));
        // a permuted table is not default.
        let mut t = default_table(4);
        t.swap(0, 1);
        assert!(!RssPolicy::is_default_indir(&t, 4));
        // wrong length is never "the default".
        assert!(!RssPolicy::is_default_indir(&[0, 1, 2, 3], 4));
    }

    #[test]
    fn set_indir_default_collapses_to_none() {
        let mut p = RssPolicy::from_stored(None, None);
        p.set_indir(&default_table(4), 4).unwrap();
        assert!(!p.has_custom_indir(), "default table must store as None");
    }

    #[test]
    fn set_indir_custom_is_stored_and_materialized() {
        let mut p = RssPolicy::from_stored(None, None);
        let mut custom = default_table(4);
        custom.swap(0, 5); // still all < 4, just not the default order
        p.set_indir(&custom, 4).unwrap();
        assert!(p.has_custom_indir());
        let mut out = [0u8; RSS_INDIR_ENTRIES];
        p.effective_indir(4, &mut out);
        assert_eq!(out, custom);
    }

    #[test]
    fn set_indir_rejects_out_of_range_and_keeps_old_state() {
        let mut p = RssPolicy::from_stored(None, None);
        let mut custom = default_table(4);
        custom.swap(0, 5);
        p.set_indir(&custom, 4).unwrap(); // valid custom
        let mut bad = default_table(4);
        bad[10] = 4; // queue 4 does not exist for qc=4
        assert_eq!(p.set_indir(&bad, 4), Err(RssError::InvalidTable));
        // rejected update must not have replaced the previously-valid table.
        let mut out = [0u8; RSS_INDIR_ENTRIES];
        p.effective_indir(4, &mut out);
        assert_eq!(out, custom);
    }

    #[test]
    fn set_indir_rejects_wrong_length() {
        let mut p = RssPolicy::from_stored(None, None);
        assert_eq!(p.set_indir(&[0, 1, 2, 3], 4), Err(RssError::InvalidTable));
    }

    #[test]
    fn effective_indir_none_is_default_spread() {
        let p = RssPolicy::from_stored(None, None);
        let mut out = [0u8; RSS_INDIR_ENTRIES];
        p.effective_indir(4, &mut out);
        assert_eq!(out, default_table(4));
        // and tracks the queue count without any stored table.
        p.effective_indir(2, &mut out);
        assert_eq!(out, default_table(2));
    }

    #[test]
    fn reclamp_drops_invalid_custom_keeps_valid() {
        // A custom table for qc=4 that uses queues 2/3 becomes invalid at qc=2.
        let mut p = RssPolicy::from_stored(None, None);
        let mut custom = default_table(4);
        custom.swap(0, 5);
        p.set_indir(&custom, 4).unwrap();
        p.reclamp_for_queue_count(2);
        assert!(
            !p.has_custom_indir(),
            "table referencing queues 2/3 must drop to default at qc=2"
        );
        let mut out = [0u8; RSS_INDIR_ENTRIES];
        p.effective_indir(2, &mut out);
        assert_eq!(out, default_table(2));

        // A custom table that only uses queue 0/1 survives a shrink to qc=2.
        let mut p2 = RssPolicy::from_stored(None, None);
        let mut lowq = default_table(2); // entries are all 0/1
        lowq.swap(0, 1);
        p2.set_indir(&lowq, 4).unwrap(); // valid for 4 (0/1 < 4) and custom vs default-4
        p2.reclamp_for_queue_count(2);
        assert!(
            p2.has_custom_indir(),
            "0/1-only table is still valid at qc=2"
        );
    }

    #[test]
    fn key_storage_round_trips() {
        let mut p = RssPolicy::from_stored(None, None);
        assert!(p.key().is_none());
        let k = [0xABu8; RSS_KEY_SIZE];
        p.set_key(k);
        assert_eq!(p.key(), Some(&k));
    }

    #[test]
    fn from_stored_round_trips_through_accessors() {
        // Mirrors the NetdevState atomic-array snapshot/write-back: default state.
        let p = RssPolicy::from_stored(None, None);
        assert!(p.key().is_none() && p.custom_indir().is_none());

        // Custom key + table persist through the parts round-trip.
        let k = [0x5Au8; RSS_KEY_SIZE];
        let mut t = default_table(4);
        t.swap(0, 5);
        let p2 = RssPolicy::from_stored(Some(k), Some(t));
        assert_eq!(p2.key(), Some(&k));
        assert_eq!(p2.custom_indir(), Some(&t));
        // and effective_indir returns the stored custom table verbatim.
        let mut out = [0u8; RSS_INDIR_ENTRIES];
        p2.effective_indir(4, &mut out);
        assert_eq!(out, t);
    }
}
