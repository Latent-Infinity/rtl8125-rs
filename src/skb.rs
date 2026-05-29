// SPDX-License-Identifier: GPL-2.0
//! sk_buff ownership wrapper for the RTL8125 Rust driver — plan §6.3.
//!
//! ## DriverOwnedSkb (task #62, 2026-05-29)
//!
//! [`DriverOwnedSkb`] is the minimum-viable domain type at the
//! `*mut bindings::sk_buff` ↔ Rust boundary. It is the type returned by
//! `bridge_skb_build_rx` (RX path) and the type into which the
//! `rust_xmit` callback's raw skb pointer is immediately wrapped (TX
//! path). Every skb operation the driver performs goes through one of
//! its inherent methods — `dma_map_linear`, `dma_map_frag`,
//! `tso_setup`, `tx_csum_opts`, `rx_csum_set`, `nr_frags` — so the
//! underlying raw pointer never leaks into arbitrary Rust code.
//!
//! Consumption is by-value: exactly one of [`DriverOwnedSkb::deliver_rx`]
//! / [`DriverOwnedSkb::consume_tx`] / [`DriverOwnedSkb::free_with_error`] /
//! [`DriverOwnedSkb::into_raw`] disposes of the wrapper. The `#[must_use]`
//! attribute warns at compile time when a value is dropped without being
//! consumed; that path is also a kmemleak-visible skb leak in the
//! debug+Rust guest kernel.
//!
//! ## What §6.3 type-state lands here later (refactor pending — M5)
//!
//! The plan §6.3 sketches per-state wrappers above the
//! [`DriverOwnedSkb`] layer:
//!
//! ```text
//! struct TxSkb<S: TxState> { raw: NonNull<sk_buff>, _state: PhantomData<S> }
//! struct Received;          // just arrived from ndo_start_xmit
//! struct Mapped(DmaHandle); // dma_map_single succeeded
//! struct Submitted;         // descriptor posted to ring, OWN bit set
//! struct Completing;        // hardware released OWN; reaper holds it
//! ```
//!
//! with state-consuming transitions. That refactor is queued for an
//! M5 follow-up alongside the NAPI-stability work (plan §7 M5), where
//! the type discipline pays its rent in
//! `tx_received == tx_consumed + tx_busy_exception + tx_dropped_error`
//! correctness under load. [`DriverOwnedSkb`] is the entry point both
//! state machines build on.

use kernel::bindings;
use kernel::error::Result;
use kernel::pci;
use kernel::sync::aref::ARef;

#[allow(clippy::unsafe_removed_from_name)]
use crate::unsafe_boundary as ub;

/// An `sk_buff` the driver owns exclusively for the duration of the
/// borrow. Wraps the raw `*mut bindings::sk_buff` returned by either
/// `bridge_skb_build_rx` (RX) or received as a parameter by the
/// `rust_xmit` callback (TX).
///
/// **Consumption discipline.** Exactly one of the methods marked
/// `(consumes)` below MUST be called on every value, or the skb leaks
/// (`#[must_use]` warns at compile time, kmemleak catches the leak at
/// runtime). The intermediate borrow methods (`dma_map_*`, `tso_setup`,
/// `tx_csum_opts`, `nr_frags`, `rx_csum_set`) take `&self` so the
/// caller can compose them before deciding the disposition.
///
/// **Hot path.** Constructor + Drop are zero-cost: the wrapper is a
/// `repr(transparent)` newtype around `*mut sk_buff`. All method bodies
/// are one-line forwards to `unsafe_boundary` — `#[inline]` makes them
/// fold into the call site.
#[must_use = "DriverOwnedSkb must be consumed via deliver_rx / consume_tx / free_with_error / into_raw"]
#[repr(transparent)]
pub(crate) struct DriverOwnedSkb {
    raw: *mut bindings::sk_buff,
}

impl DriverOwnedSkb {
    /// Wrap a raw `*mut sk_buff` the driver has just taken ownership of.
    ///
    /// # SAFETY contract (caller-side, since this leaves `unsafe_boundary`)
    ///
    /// `raw` must be a non-null `*mut sk_buff` for which the driver
    /// holds the sole reference. The two callers are:
    ///
    /// 1. The `rust_xmit` callback — kernel hands ownership in.
    /// 2. The NAPI poll RX path — `bridge_skb_build_rx` just returned
    ///    a fresh allocation (caller must check non-null first via
    ///    [`from_raw_nullable`]).
    ///
    /// `from_raw` is named without `unsafe` because the only way to
    /// obtain a `*mut sk_buff` outside `unsafe_boundary` is from one of
    /// the cshim wrappers, which itself is the unsafe FFI surface.
    #[inline]
    pub(crate) fn from_raw(raw: *mut bindings::sk_buff) -> Self {
        debug_assert!(!raw.is_null(), "DriverOwnedSkb::from_raw given null");
        Self { raw }
    }

    /// Wrap a possibly-null result from `bridge_skb_build_rx`. Returns
    /// `None` on null; the caller remains responsible for the RX error
    /// counter because no skb exists to consume.
    #[inline]
    pub(crate) fn from_raw_nullable(raw: *mut bindings::sk_buff) -> Option<Self> {
        if raw.is_null() {
            None
        } else {
            Some(Self { raw })
        }
    }

    /// Construct a freshly-built RX skb wrapping `len` bytes copied from
    /// `buf`. Returns `None` on cshim allocation failure (caller must
    /// account that via `rx_drop_error`).
    ///
    /// This is the typed entry point for the NAPI RX path; together
    /// with `rust_xmit`'s direct `from_raw` it makes the two call sites
    /// where the driver acquires a `DriverOwnedSkb` explicit.
    #[inline]
    pub(crate) fn build_rx(
        ndev: *mut bindings::net_device,
        buf: *const core::ffi::c_void,
        len: usize,
    ) -> Option<Self> {
        Self::from_raw_nullable(ub::skb_build_rx(ndev, buf, len))
    }

    /// Number of paged fragments (TX path). 0 for linear-only skbs.
    #[inline]
    pub(crate) fn nr_frags(&self) -> u32 {
        ub::skb_nr_frags(self.raw)
    }

    /// TSO descriptor-bit setup (TX path). Returns `Some((opts1, opts2))`
    /// for TCPv4/v6 GSO super-skbs, `None` otherwise. The cshim may
    /// mutate the skb (`skb_cow_head` + `tcp_v6_gso_csum_prep` for v6);
    /// any later DMA map sees the final bytes.
    #[inline]
    pub(crate) fn tso_setup(&self) -> Option<(u32, u32)> {
        ub::skb_tso_setup(self.raw)
    }

    /// Plain (non-TSO) CSUM offload bits (TX path). Returns the opts2
    /// value to OR into the descriptor, or
    /// `crate::regs::TX_CSUM_OPTS_DROP` if the skb must be dropped
    /// (chip can't compute the CSUM and software fallback failed).
    #[inline]
    pub(crate) fn tx_csum_opts(&self) -> u32 {
        ub::skb_tx_csum_opts(self.raw)
    }

    /// DMA-map the linear head for TX (`dma_map_single` under the hood).
    /// Returns `Ok((handle, len))` on success or the kernel error on
    /// failure. On error the wrapper is NOT consumed — the caller
    /// decides whether to free or retry.
    #[inline]
    pub(crate) fn dma_map_linear(
        &self,
        pdev: &ARef<pci::Device>,
    ) -> Result<(bindings::dma_addr_t, u32)> {
        let mut handle: bindings::dma_addr_t = 0;
        let mut len: u32 = 0;
        ub::skb_data_dma_map(pdev, self.raw, &mut handle, &mut len)?;
        Ok((handle, len))
    }

    /// DMA-map paged fragment `idx` for TX (`skb_frag_dma_map` under
    /// the hood). Caller validates `idx < nr_frags()`; the C side
    /// also bounds-checks and returns `-EINVAL` on out-of-range.
    #[inline]
    pub(crate) fn dma_map_frag(
        &self,
        pdev: &ARef<pci::Device>,
        idx: u32,
    ) -> Result<(bindings::dma_addr_t, u32)> {
        let mut handle: bindings::dma_addr_t = 0;
        let mut len: u32 = 0;
        ub::skb_frag_dma_map(pdev, self.raw, idx, &mut handle, &mut len)?;
        Ok((handle, len))
    }

    /// Inspect the RX descriptor's `opts1` and set `skb->ip_summed` if
    /// the chip validated the L4 checksum. No-op if the descriptor
    /// reports no L4 CSUM result or any fail bit.
    #[inline]
    pub(crate) fn rx_csum_set(&self, desc_opts1: u32) {
        ub::skb_rx_csum_set(self.raw, desc_opts1);
    }

    /// Borrow the underlying raw pointer without consuming the wrapper.
    /// Used for the per-TX-slot shadow store inside the fragment-map
    /// loop, where the SAME skb pointer is the disposition obligation
    /// for the LastFrag slot but the wrapper is still alive in the
    /// caller until the success commit.
    ///
    /// Returning a `*mut` rather than `*const` is intentional: the
    /// underlying C side will eventually consume the skb mutably; we
    /// just don't let arbitrary Rust code mutate it through this
    /// borrow.
    #[inline]
    pub(crate) fn as_raw(&self) -> *mut bindings::sk_buff {
        self.raw
    }

    /// Consume the wrapper and return the raw pointer. Used at the
    /// final commit point when ownership of the disposition obligation
    /// passes from `DriverOwnedSkb` to the per-TX-slot shadow.
    ///
    /// Also used on `NETDEV_TX_BUSY` paths: the kernel keeps the skb
    /// after we return BUSY, so the wrapper must dissolve without
    /// calling `dev_kfree_skb_any`. Since `DriverOwnedSkb` has no
    /// `Drop` impl, simply moving `self` here is sufficient — the
    /// wrapper does not leak any kernel resource (the underlying skb
    /// is now owned by whoever stored / received the returned raw
    /// pointer).
    #[inline]
    pub(crate) fn into_raw(self) -> *mut bindings::sk_buff {
        self.raw
    }

    /// `(consumes)` Hand off to GRO. §6.3 RX disposition (a).
    /// `rx_handed_to_stack++` happens inside the cshim helper.
    #[inline]
    pub(crate) fn deliver_rx(self, napi: *mut bindings::napi_struct) {
        ub::skb_deliver_rx(napi, self.raw);
    }

    /// `(consumes)` TX completion path — give the skb back to NAPI
    /// for recycling. §6.3 TX disposition (a). `tx_consumed++` happens
    /// inside the cshim helper.
    #[inline]
    pub(crate) fn consume_tx(self, ndev: *mut bindings::net_device) {
        ub::skb_consume_tx(ndev, self.raw);
    }

    /// `(consumes)` TX error disposition — `dev_kfree_skb_any` under
    /// the hood and `tx_dropped_error++` inside the cshim helper.
    ///
    /// RX allocation failures have no skb to free and must use
    /// `rx_drop_error(ndev)` directly. A future RX-owned error wrapper
    /// can route through the cshim's dedicated RX drop helper.
    #[inline]
    pub(crate) fn free_with_error(self) {
        ub::skb_free_error(self.raw);
    }
}

// SAFETY notes for the wrapper as a whole:
//
//   - `DriverOwnedSkb` is `#[repr(transparent)]` over `*mut sk_buff`,
//     so it has the same layout/ABI as the raw pointer.
//   - The `#[must_use]` attribute and lack of `Copy`/`Clone` ensure
//     ownership is linear: every successful return path of every
//     constructor leads to exactly one consume call.
//   - There is intentionally NO `Drop` impl. Forgetting to consume a
//     value is a kmemleak-visible skb leak — louder than a silent
//     `dev_kfree_skb_any` in `Drop` would be, and easier to debug.
