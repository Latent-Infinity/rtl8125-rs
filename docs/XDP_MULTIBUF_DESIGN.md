# XDP RX multi-buffer (RX_SG) — retroactive closure

> **STATUS: STRIPPED (2026-06-20).** The chip does set FS/LS at V3 positions
> (bits 25/24), but multi-descriptor RX splitting is not practically possible
> on the RTL8125. Both the vendor r8125 driver and the mainline r8169 driver
> use per-descriptor buffers (16 KiB / MTU-page) large enough for any single
> frame — so no frame ever spans multiple descriptors. The vendor's optional
> `ENABLE_RX_PACKET_FRAGMENT` (small-buffer fragment mode) is default-off and
> was never production-validated.
>
> The "fix" earlier in this session (correct V3 bit positions) was real and
> correct, but the multi-buffer code it unlocked is dead code — no test or
> on-wire workload can trigger it, so it was stripped out entirely.
>
> **Lesson:** FS/LS bit positions are format-dependent (V2 vs V3 descriptor
> format). The V3 positions (25/24) are correct. But on this chip, with
> normal buffer sizing, a frame *never* splits, so checking them is
> unnecessary. Both r8169 and r8125 treat fragmented frames as over-MTU
> errors and drop them.

## What was removed

- **`src/rx_sg.rs`** — the Rust reassembly state machine (~516 lines, 14 host
  tests): `RxSgState`, `step()`, `SegFacts`, `SegAction` — all unused.
- **`src/napi.rs`** — `rx_multibuf_step()` and the FS/LS-aware two-branch
  dispatch in `process_rx_completions`. Now every descriptor is a complete
  frame going straight to `bridge_rx_one_packet`.
- **`src/netdev.rs`** — `sg_packed` and `partial_skb` fields, their init, and
  the teardown reclaim for a partial frame.
- **`src/unsafe_boundary.rs`** — 6 extern declarations + 6 safe wrappers
  (`rx_begin_frame`, `rx_add_frag`, `rx_finish_frame`, `rx_abort_frame`,
  `rx_recycle_buf`, `rx_count_drop`).
- **C shim** — 6 implementation functions in `netdev_bridge_rx_pool.c`,
  the `sg_xdp_*` fields in `netdev_bridge_internal.h`,
  `r8125_bridge_xdp_active()` and `r8125_bridge_rx_xdp_run_multibuf()`
  in `netdev_bridge_xdp.c`, and the multi-buffer advert from
  `netdev_bridge.c`.
- **CI** — `ci/check_rx_sg.sh` gutted (no-op), `ci/check_rust_unit_tests.sh`
  no longer lists `src/rx_sg.rs`, references removed from docs and comments.

## What remains

- `regs::DESC_RX_FIRST_FRAG_V3` and `DESC_RX_LAST_FRAG_V3` — the bit
  constants are technically unused now but kept as documentation (the next
  maintainer reaching for FS/LS bits will find the correct V3 positions).
- The driver's RX path is back to the pre-multi-buffer baseline: every
  descriptor is a complete frame, no FS/LS checking in the hot path.

## Verification

- All multi-buffer symbols removed from Rust and C sources.
- The fast path (single-descriptor RX) was never touched.
- Full CI passes.
