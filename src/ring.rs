// SPDX-License-Identifier: GPL-2.0
//! TX / RX descriptor rings.
//!
//! - 16-byte hardware TX descriptors (legacy `struct TxDesc` / `struct RxDesc`).
//! - RX descriptors support legacy (16-byte), V3 (32-byte), and V4 (16-byte)
//!   layouts. V3/V4 are modeled as separate typed views over a shared 32-byte
//!   RX-ring storage.
//! - DMA-coherent allocation via [`kernel::dma::CoherentAllocation`]; memory is
//!   released on `Ring` drop (which happens on unbind / `rmmod`).
//! - **Software-only canaries**: a parallel `[u64; N]` shadow array plus a
//!   tail-canary descriptor at index `N` of the DMA ring. The shadow catches
//!   driver-side overwrites of per-descriptor metadata; the tail canary catches
//!   device-side one-off-the-end DMA writes during stress testing.
//! - **Typed ring indices**: newtype `TxHead`/`TxTail`/`RxHead`/`RxTail`
//!   wrappers over `usize`; the type system distinguishes them so an `RxTail`
//!   can't accidentally be passed where a `TxHead` is expected.
//! - **Compile-time bounds**: `const RING_LEN: usize = 256`; ring sizes
//!   propagate through `Ring<_, N>` const-generic parameter.

use kernel::device;
use kernel::dma::{CoherentAllocation, DmaAddress};
use kernel::error::code::EIO;
use kernel::prelude::*;
use kernel::transmute::{AsBytes, FromBytes};

/// Hardware descriptor count per direction. Matches r8169's `NUM_TX_DESC` /
/// `NUM_RX_DESC` (= 256). RTL8125 supports up to 1024 but 256 is the
/// well-trodden working default; bumping it is an M5 perf-tuning exercise.
pub(crate) const RING_LEN: usize = 256;

/// Software canary pattern for the per-descriptor shadow array. Picked so it's
/// obvious in a hex dump and unlikely to occur naturally.
const CANARY_PATTERN: u64 = 0xDEAD_BEEF_CAFE_BABE;

// TX/RX descriptor format constants used to validate per-format parsing and
// republish offsets in this module.
const RSS_HEADER_INFO_V3_L3_MASK: u16 = (1 << 10) | (1 << 12);
const RSS_HEADER_INFO_V3_L4_MASK: u16 = (1 << 13) | (1 << 9);

// TX-tail canary for 16-byte descriptor storage.
const DESC_TAIL_CANARY_OPTS1: u32 = 0xDEAD_BEEF;
const DESC_TAIL_CANARY_OPTS2: u32 = 0xCAFE_BABE;
const DESC_TAIL_CANARY_ADDR: u64 = 0xFEED_FACE_BAAD_F00D;

// RX-tail canary reuses the legacy field positions (qword 0 + qword 1 in the
// 32-byte storage). The higher qwords are zeroed so V3/V4 reads detect a stride
// and size bug quickly.
const RX_TAIL_CANARY_DW0: u64 =
    ((DESC_TAIL_CANARY_OPTS2 as u64) << 32) | DESC_TAIL_CANARY_OPTS1 as u64;
const RX_TAIL_CANARY_DW1: u64 = DESC_TAIL_CANARY_ADDR;

/// One 16-byte hardware descriptor — TX and legacy RX.
///
/// Mirrors r8169's `struct TxDesc` / legacy `struct RxDesc`:
///   `__le32 opts1; __le32 opts2; __le64 addr;`
///
/// We use plain `u32`/`u64` because x86_64 is little-endian (matching hardware
/// byte order). A `cpu_to_le32` shim would be required for a big-endian host.
#[repr(C)]
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct Descriptor {
    pub opts1: u32,
    pub opts2: u32,
    pub addr: u64,
}

/// RX legacy alias kept explicit for clarity when parsing legacy V1/V2 layouts.
#[repr(C)]
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RxDescLegacy {
    pub opts1: u32,
    pub opts2: u32,
    pub addr: u64,
}

/// RSS-capable RX descriptor (V3 path used by RTL8125B). This is the 32-byte
/// layout with the hash fields at DDWord2.
#[repr(C)]
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RxDescV3 {
    pub(crate) _rsv0: u32,
    pub(crate) _rsv1: u32,
    pub(crate) rss_result: u32,
    pub(crate) header_buffer_len: u16,
    pub(crate) header_info: u16,
    pub(crate) addr: u64,
    pub(crate) opts2: u32,
    pub(crate) opts1: u32,
}

/// RSS-capable RX descriptor (V4 path). Kept for future chip generations.
#[repr(C, align(8))]
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RxDescV4 {
    /// `union { u64 addr; struct { u32 rss_info; u32 rss_result; } }`
    pub(crate) addr_or_rss_info: u64,
    pub(crate) opts2: u32,
    pub(crate) opts1: u32,
}

/// RX ring storage type with maximum V3 width.
#[repr(C, align(8))]
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct RxDescriptor {
    pub(crate) words: [u64; 4],
}

/// Marker for RX descriptor format selection.
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub(crate) enum RxDescFormat {
    /// Legacy 16-byte V1/V2-style layout.
    #[default]
    Legacy,
    #[allow(dead_code)]
    /// RTL8125B-capable RSS-capable layout.
    V3,
    #[allow(dead_code)]
    /// RTL8125BP-capable RSS-capable layout.
    V4,
}

impl RxDescFormat {
    /// TX/RX descriptor byte stride for this format.
    #[inline]
    #[allow(dead_code)]
    pub(crate) const fn descriptor_len(self) -> usize {
        match self {
            RxDescFormat::Legacy | RxDescFormat::V4 => 16,
            RxDescFormat::V3 => 32,
        }
    }

    #[inline]
    const fn publish_offsets(self) -> (usize, usize, usize) {
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

const _: () = assert!(core::mem::size_of::<Descriptor>() == 16);
const _: () = assert!(core::mem::align_of::<Descriptor>() == 8);
const _: () = assert!(core::mem::size_of::<RxDescLegacy>() == 16);
const _: () = assert!(core::mem::align_of::<RxDescLegacy>() == 8);
const _: () = assert!(core::mem::size_of::<RxDescV3>() == 32);
const _: () = assert!(core::mem::align_of::<RxDescV3>() == 8);
const _: () = assert!(core::mem::size_of::<RxDescV4>() == 16);
const _: () = assert!(core::mem::align_of::<RxDescV4>() == 8);
const _: () = assert!(core::mem::size_of::<RxDescriptor>() == 32);
const _: () = assert!(core::mem::align_of::<RxDescriptor>() == 8);

// `unsafe impl AsBytes / FromBytes for descriptors` lives in `unsafe_boundary`.

// `RingCanary` is the minimum surface needed by [`Ring::new`] / `verify_canaries`.
// Each descriptor type records its own tail sentinel so one allocation can carry
// its matching runtime invariant.
pub(crate) trait RingCanary: Copy + PartialEq {
    fn tail_canary() -> Self;
}

impl RingCanary for Descriptor {
    fn tail_canary() -> Self {
        Descriptor {
            opts1: DESC_TAIL_CANARY_OPTS1,
            opts2: DESC_TAIL_CANARY_OPTS2,
            addr: DESC_TAIL_CANARY_ADDR,
        }
    }
}

impl RingCanary for RxDescriptor {
    fn tail_canary() -> Self {
        RxDescriptor {
            words: [RX_TAIL_CANARY_DW0, RX_TAIL_CANARY_DW1, 0, 0],
        }
    }
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
    /// `(RSSResult_off, HeaderInfo_off)` for hash-bearing formats; `None`
    /// for legacy (no hash field). V4 is not wired (validated chip is V3).
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

impl RxDescriptor {
    /// Byte offsets used by `desc_publish_own` for each format.
    pub(crate) const fn publish_offsets(format: RxDescFormat) -> (usize, usize, usize) {
        format.publish_offsets()
    }
}

// ── Typed ring indices ───────────────────────────────────────────────────
// Newtype wrappers; the compiler distinguishes them at the type level so a
// TX index can't be used where an RX index is expected.

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
ring_index!(
    TxTail,
    "TX ring consumer index (reaper advances on completion)."
);
ring_index!(
    RxHead,
    "RX ring producer index (hardware advances on receive)."
);
ring_index!(RxTail, "RX ring consumer index (NAPI advances after rx).");

// Power-of-two so the wrap mask above is a compile-time constant.
const _: () = assert!(RING_LEN.is_power_of_two());

/// Alias for the actual TX ring storage used by probe and open.
pub(crate) type TxRing = Ring<Descriptor, RING_LEN>;
/// Alias for the actual RX ring storage used by probe and open.
pub(crate) type RxRing = Ring<RxDescriptor, RING_LEN>;

/// One descriptor ring (TX or RX). `N` is the hardware-visible descriptor
/// count; the underlying DMA allocation is `N + 1` slots so slot `N` can hold
/// the tail canary.
pub(crate) struct Ring<D, const N: usize>
where
    D: Copy + Default + RingCanary + PartialEq + AsBytes + FromBytes,
{
    /// DMA-coherent descriptor array. Slots 0..N are hardware-visible; slot N is
    /// the tail canary. Drops on `Ring` drop → `dma_free_coherent`.
    desc: CoherentAllocation<D>,
    /// Per-descriptor software canary shadow. Heap-allocated (`KBox`) and filled
    /// in place so a large `N` never materialises an `[u64; N]` on the kernel
    /// stack during probe (see `Ring::new`).
    shadow: KBox<[u64; N]>,
    tail_canary: D,
}

impl<D, const N: usize> Ring<D, N>
where
    D: Copy + Default + RingCanary + PartialEq + AsBytes + FromBytes,
{
    /// Allocate the descriptor ring, zero the hardware-visible slots, and plant
    /// the format-specific tail canary at slot `N`.
    pub(crate) fn new(dev: &device::Device<device::Bound>) -> Result<Self> {
        let tail_canary = D::tail_canary();
        let desc: CoherentAllocation<D> =
            CoherentAllocation::alloc_coherent(dev, N + 1, GFP_KERNEL)?;

        // Hardware-visible slots: zero.
        for i in 0..N {
            kernel::dma_write!(desc, [i]?, D::default());
        }
        // Tail canary at slot N.
        kernel::dma_write!(desc, [N]?, tail_canary);

        // Build the shadow on the heap, filled in place: `init_array_from_fn`
        // never constructs the `[u64; N]` on the stack, so probe stays within
        // the 16 KiB x86_64 kernel-stack budget even at large `N` (e.g. 1024).
        // A by-value `[CANARY_PATTERN; N]` here overflowed the stack at N>=512
        // under KASAN (corrupted-stack-end panic during insmod) — fixed.
        let shadow = KBox::init(pin_init::init_array_from_fn(|_| CANARY_PATTERN), GFP_KERNEL)?;

        Ok(Self {
            desc,
            shadow,
            tail_canary,
        })
    }

    /// DMA address of slot 0 of the ring — what gets programmed into the
    /// device's `TNPDS` / `RDSAR` register in M4.
    pub(crate) fn dma_handle(&self) -> DmaAddress {
        self.desc.dma_handle()
    }

    /// Raw CPU pointer to descriptor[0]. Stable for the lifetime of the `Ring`
    /// (CoherentAllocation pins its backing memory).
    pub(crate) fn desc_ptr_mut(&self) -> *mut D {
        self.desc.start_ptr().cast_mut()
    }

    /// Number of hardware-visible descriptors (= `N`).
    #[allow(dead_code)]
    pub(crate) fn len(&self) -> usize {
        N
    }

    /// Verify that software shadow + tail canary are intact.
    pub(crate) fn verify_canaries(&self) -> Result<()> {
        for c in self.shadow.iter() {
            if *c != CANARY_PATTERN {
                return Err(EIO);
            }
        }
        let tail: D = kernel::dma_read!(self.desc, [N]?);
        if tail != self.tail_canary {
            return Err(EIO);
        }
        Ok(())
    }
}
