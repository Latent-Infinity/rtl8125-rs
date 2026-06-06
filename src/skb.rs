// SPDX-License-Identifier: GPL-2.0
//! sk_buff ownership wrapper for the RTL8125 Rust driver — plan §6.3.
//!
//! ## DriverOwnedSkb (task #62, 2026-05-29)
//!
//! [`DriverOwnedSkb`] is the minimum-viable domain type at the
//! `*mut bindings::sk_buff` <-> Rust boundary. The RX path is handled
//! entirely inside the C shim by `r8125_bridge_rx_one_packet`, so this
//! wrapper now covers the TX ownership path: the `rust_xmit` callback's
//! raw skb pointer is immediately wrapped, mapped, either submitted to
//! the TX ring or freed, and later consumed by the TX reaper. Every TX
//! skb operation the Rust driver performs goes through one of its
//! inherent methods — `tx_offload_prepare`, `dma_map_linear`,
//! `dma_map_frag` — so the underlying raw pointer never
//! leaks into arbitrary Rust code.
//!
//! Consumption is by-value: exactly one of [`DriverOwnedSkb::consume_tx`],
//! [`DriverOwnedSkb::free_with_error`], or [`DriverOwnedSkb::into_raw`]
//! disposes of the wrapper. The `#[must_use]` attribute warns at compile
//! time when a value is dropped without being consumed; that path is also
//! a kmemleak-visible skb leak in the debug+Rust guest kernel.
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
//! correctness under load. [`DriverOwnedSkb`] is the entry point for
//! that TX state machine.

use kernel::bindings;
use kernel::error::Result;
use kernel::pci;
use kernel::sync::aref::ARef;

#[allow(clippy::unsafe_removed_from_name)]
use crate::unsafe_boundary as ub;

/// An `sk_buff` the driver owns exclusively for the duration of the
/// borrow. Wraps the raw `*mut bindings::sk_buff` received as a
/// parameter by the `rust_xmit` callback, or reclaimed from a TX shadow
/// slot on completion/rollback.
///
/// **Consumption discipline.** Exactly one of the methods marked
/// `(consumes)` below MUST be called on every value, or the skb leaks
/// (`#[must_use]` warns at compile time, kmemleak catches the leak at
/// runtime). The intermediate borrow methods (`tx_offload_prepare`,
/// `dma_map_*`) take `&self` so the caller can compose them before
/// deciding the disposition.
///
/// **Hot path.** Constructor + Drop are zero-cost: the wrapper is a
/// `repr(transparent)` newtype around `*mut sk_buff`. All method bodies
/// are one-line forwards to `unsafe_boundary` — `#[inline]` makes them
/// fold into the call site.
#[must_use = "DriverOwnedSkb must be consumed via consume_tx / free_with_error / into_raw"]
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
    /// holds the sole reference. The direct callers are FFI xmit entry
    /// points where the kernel has handed ownership to the driver.
    ///
    /// `from_raw` is named without `unsafe` because the only way to
    /// obtain a `*mut sk_buff` outside `unsafe_boundary` is from a
    /// kernel callback argument or from a TX shadow slot previously
    /// populated by [`Self::into_raw`].
    #[inline]
    pub(crate) fn from_raw(raw: *mut bindings::sk_buff) -> Self {
        Self { raw }
    }

    /// Wrap a possibly-null TX shadow pointer. Returns `None` for empty
    /// slots; otherwise the caller has reclaimed the disposition
    /// obligation and must consume the wrapper.
    #[inline]
    pub(crate) fn from_raw_nullable(raw: *mut bindings::sk_buff) -> Option<Self> {
        if raw.is_null() {
            None
        } else {
            Some(Self { raw })
        }
    }

    /// Combined TX offload prep: returns `(opts1, opts2, nr_frags)` for
    /// descriptor programming after any C-side skb mutation. This must run
    /// before DMA mapping.
    #[inline]
    pub(crate) fn tx_offload_prepare(&self) -> Result<(u32, u32, u32)> {
        ub::skb_tx_offload_prepare(self.raw)
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

    /// `(consumes)` TX completion path — give the skb back to NAPI
    /// for recycling. §6.3 TX disposition (a). `tx_consumed++` happens
    /// inside the cshim helper. Returns the wire length (`skb->len`) so the
    /// reaper can batch it into the BQL completed-queue accounting.
    #[inline]
    pub(crate) fn consume_tx(self, ndev: *mut bindings::net_device) -> usize {
        ub::skb_consume_tx(ndev, self.raw)
    }

    /// Wire length (`skb->len`) — read in `ndo_start_xmit` before the skb is
    /// handed to the ring, for the BQL `netdev_sent_queue` at the commit.
    #[inline]
    pub(crate) fn wire_len(&self) -> usize {
        ub::skb_len(self.raw)
    }

    /// `(consumes)` TX error disposition — `dev_kfree_skb_any` under
    /// the hood and `tx_dropped_error++` inside the cshim helper.
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
