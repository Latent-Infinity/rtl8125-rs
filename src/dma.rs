// SPDX-License-Identifier: GPL-2.0
//! DMA strategy for the RTL8125 (plan §6.1, §7 M3).
//!
//! ## What lands here at M3 (cold ring allocation)
//!
//! Descriptor rings only — and they live in [`ring`](crate::ring). M3 sets the
//! device's DMA mask (via `unsafe_boundary::set_64bit_dma_mask`) and allocates
//! the coherent rings, but moves no packets and allocates no packet buffers.
//! The M3 gate verifies that ring allocation + ring free is balanced under
//! `kmemleak` and `CONFIG_DMA_API_DEBUG=y`.
//!
//! ## Streaming-mapping plan (plan §7 M3 deliverable — documented, not yet implemented)
//!
//! Packet buffer ownership at M4 / M5 will follow the §6.3 ownership contract:
//!
//! ### RX (Driver → Device)
//!
//! - Driver allocates a page-aligned RX buffer (one page per descriptor at
//!   1500 MTU, multiple pages at jumbo).
//! - Driver maps `dma_map_single(... , DataDirection::FromDevice)` and stores
//!   the DMA address in the RX descriptor's `addr` field.
//! - Driver writes `opts1 = OWN | buf_len` to hand the descriptor to hardware.
//! - **Ownership: Device** until hardware clears `OWN` on packet arrival.
//! - NAPI poll sees `OWN` cleared → calls `dma_unmap_single(...,
//!   DataDirection::FromDevice)` → owns the buffer → builds the skb → passes
//!   to `netif_rx` (via the C shim) — **Ownership: Network stack**.
//! - Driver refills the descriptor with a fresh mapping — never reuses the
//!   same page across device cycles without an unmap/remap pair (DMA_API_DEBUG
//!   would scream).
//!
//! ### TX (Network stack → Device → Driver)
//!
//! - C shim's `ndo_start_xmit(skb)` hands skb ownership to Rust.
//! - Driver maps `dma_map_single(skb->data, DataDirection::ToDevice)`, stores
//!   skb pointer in the parallel software-shadow slot, writes the descriptor
//!   `addr` + `opts1 = OWN | TX_FS | TX_LS | len`, kicks the device.
//! - **Ownership: Device** until hardware clears `OWN` on completion.
//! - Reaper (NAPI completion path) sees `OWN` cleared → calls
//!   `dma_unmap_single(..., DataDirection::ToDevice)` → `dev_kfree_skb_any` →
//!   resets the shadow slot. Plan §6.3 forbids a TX slot from looking empty
//!   while still holding a live skb pointer — the shadow slot is the type-state
//!   that makes that impossible to express.
//!
//! ## Where the actual code lives
//!
//! - **`ring`**: the descriptor ring type, descriptor struct, canaries,
//!   per-direction indices. Used by M3 (cold alloc) and M4+ (hot path).
//! - **`unsafe_boundary::set_64bit_dma_mask`**: the one `unsafe` call needed
//!   from probe — `dma_set_mask_and_coherent` is `unsafe fn` in the kernel
//!   Rust API (its only safety requirement is "no concurrent DMA-mapping
//!   calls", trivially true in single-threaded probe).
