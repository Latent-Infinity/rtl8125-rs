// SPDX-License-Identifier: GPL-2.0
//! TX / RX descriptor rings — plan §7 M3.
//!
//! - 16-byte hardware descriptors with explicit layout, matching r8169's
//!   `struct TxDesc` / `struct RxDesc` (the validated MS-A2 chip uses the
//!   same descriptor format for both directions).
//! - Coherent DMA allocation via [`kernel::dma::CoherentAllocation`]; freed
//!   automatically on `Ring` drop (which happens on unbind / `rmmod`).
//! - **Software-only canaries**: a parallel `[u64; N]` shadow array plus a
//!   tail-canary descriptor at index `N` of the DMA ring. The shadow catches
//!   driver-side overwrites of per-descriptor metadata; the tail canary
//!   catches device-side one-off-the-end DMA writes (M4+ exercise).
//! - **Typed ring indices**: newtype `TxHead`/`TxTail`/`RxHead`/`RxTail`
//!   wrappers over `usize`; the type system distinguishes them so an
//!   `RxTail` can't accidentally be passed where a `TxHead` is expected.
//! - **Compile-time bounds**: `const RING_LEN: usize = 256`; ring sizes
//!   propagate through `Ring<N>` const-generic parameter.

use kernel::dma::{CoherentAllocation, DmaAddress};
use kernel::device;
use kernel::error::code::EIO;
use kernel::prelude::*;

/// Hardware descriptor count per direction. Matches r8169's `NUM_TX_DESC` /
/// `NUM_RX_DESC` (= 256). RTL8125 supports up to 1024 but 256 is the
/// well-trodden working default; bumping it is an M5 perf-tuning exercise.
pub(crate) const RING_LEN: usize = 256;

/// Software canary pattern for the per-descriptor shadow array. Picked so
/// it's obvious in a hex dump and unlikely to occur naturally.
const CANARY_PATTERN: u64 = 0xDEAD_BEEF_CAFE_BABE;

/// Tail-canary descriptor (slot `N` of the DMA ring; hardware only ever
/// touches slots `0..N`). Distinct from the shadow canary so a hex dump can
/// tell the two sources apart on failure.
const TAIL_CANARY_OPTS1: u32 = 0xDEAD_BEEF;
const TAIL_CANARY_OPTS2: u32 = 0xCAFE_BABE;
const TAIL_CANARY_ADDR: u64 = 0xFEED_FACE_BAAD_F00D;

/// One 16-byte hardware descriptor — same layout for TX and RX on this chip.
/// Mirrors r8169's `struct TxDesc` / `struct RxDesc`:
///   `__le32 opts1; __le32 opts2; __le64 addr;`
///
/// We use plain `u32`/`u64` because x86_64 is little-endian (matching the
/// hardware byte order); a `cpu_to_le32` shim would be required if a big-
/// endian host were ever targeted.
#[repr(C)]
#[derive(Copy, Clone, Default, Debug)]
pub(crate) struct Descriptor {
    pub opts1: u32,
    pub opts2: u32,
    pub addr: u64,
}

// Compile-time assertions — descriptor size and alignment are part of the
// hardware ABI and must not silently change.
const _: () = assert!(core::mem::size_of::<Descriptor>() == 16);
const _: () = assert!(core::mem::align_of::<Descriptor>() == 8);

// `unsafe impl AsBytes / FromBytes for Descriptor` lives in `unsafe_boundary`
// per plan §6.2 (those traits are unsafe; implementing them is `unsafe impl`,
// which the crate-root `#![deny(unsafe_code)]` rejects in other files).

// ── Typed ring indices ────────────────────────────────────────────────────
// Newtype wrappers; the compiler distinguishes them at the type level so a
// TX index can't be used where an RX index is expected (plan §7 M3).

macro_rules! ring_index {
    ($name:ident, $doc:literal) => {
        #[doc = $doc]
        #[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
        pub(crate) struct $name(pub usize);

        impl $name {
            /// Wrap the index modulo `RING_LEN`. Cheap because `RING_LEN`
            /// is a power of two — the compiler turns this into `& (N-1)`.
            #[inline]
            #[allow(dead_code)] // used from M4 onward
            pub(crate) fn wrapped(self) -> Self {
                $name(self.0 & (RING_LEN - 1))
            }
        }
    };
}

ring_index!(TxHead, "TX ring producer index (driver advances).");
ring_index!(TxTail, "TX ring consumer index (reaper advances on completion).");
ring_index!(RxHead, "RX ring producer index (hardware advances on receive).");
ring_index!(RxTail, "RX ring consumer index (NAPI advances after rx).");

// Power-of-two so the wrap mask above is a compile-time constant.
const _: () = assert!(RING_LEN.is_power_of_two());

// ── Ring ──────────────────────────────────────────────────────────────────

/// One descriptor ring (TX or RX). `N` is the hardware-visible descriptor
/// count; the underlying DMA allocation is `N + 1` slots so slot `N` can
/// hold the tail canary without overlapping anything hardware writes.
pub(crate) struct Ring<const N: usize> {
    /// DMA-coherent descriptor array. Slots 0..N are hardware-visible;
    /// slot N is the tail canary. Drops on `Ring` drop → `dma_free_coherent`.
    desc: CoherentAllocation<Descriptor>,
    /// Per-descriptor software canary shadow. Catches driver-side scribbles
    /// in M4+ (in M3 it is vacuously preserved — no driver writes happen).
    shadow: [u64; N],
}

impl<const N: usize> Ring<N> {
    /// Allocate the descriptor ring against `dev`, zero the hardware
    /// descriptors, plant the tail canary at slot `N`, and seed the software
    /// shadow with the canary pattern. Returns `EIO` if the underlying
    /// `dma_alloc_coherent` fails.
    pub(crate) fn new(dev: &device::Device<device::Bound>) -> Result<Self> {
        let desc: CoherentAllocation<Descriptor> =
            CoherentAllocation::alloc_coherent(dev, N + 1, GFP_KERNEL)?;

        // Hardware-visible slots: zero.
        for i in 0..N {
            kernel::dma_write!(desc, [i]?, Descriptor::default());
        }
        // Tail canary at slot N.
        kernel::dma_write!(
            desc,
            [N]?,
            Descriptor {
                opts1: TAIL_CANARY_OPTS1,
                opts2: TAIL_CANARY_OPTS2,
                addr: TAIL_CANARY_ADDR,
            }
        );

        Ok(Self {
            desc,
            shadow: [CANARY_PATTERN; N],
        })
    }

    /// DMA address of slot 0 of the ring — what gets programmed into the
    /// device's `TNPDS` / `RDSAR` register in M4.
    pub(crate) fn dma_handle(&self) -> DmaAddress {
        self.desc.dma_handle()
    }

    /// Raw CPU pointer to descriptor[0]. Stable for the lifetime of the
    /// `Ring` (CoherentAllocation pins its backing memory). Used by the
    /// M4 hot path to read/write descriptors via the `desc_read` /
    /// `desc_write` helpers in `unsafe_boundary`.
    pub(crate) fn desc_ptr_mut(&self) -> *mut Descriptor {
        self.desc.start_ptr().cast_mut()
    }

    /// Number of hardware-visible descriptors (= `N`).
    #[allow(dead_code)]
    pub(crate) fn len(&self) -> usize {
        N
    }

    /// Verify that the software shadow + tail-canary descriptor are intact.
    /// Returns `EIO` and a `dev_err!` line on failure. In M3 this is
    /// expected to pass trivially (no driver activity touches either area);
    /// it gains teeth at M4+ where the hot path could in principle scribble.
    pub(crate) fn verify_canaries(&self) -> Result<()> {
        for c in self.shadow.iter() {
            if *c != CANARY_PATTERN {
                return Err(EIO);
            }
        }
        // Tail canary read-back. `dma_read!` and friends require the index
        // to fit in the allocation (N + 1).
        let tail: Descriptor = kernel::dma_read!(self.desc, [N]?);
        if tail.opts1 != TAIL_CANARY_OPTS1
            || tail.opts2 != TAIL_CANARY_OPTS2
            || tail.addr != TAIL_CANARY_ADDR
        {
            return Err(EIO);
        }
        Ok(())
    }
}
