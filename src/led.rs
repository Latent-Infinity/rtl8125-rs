// SPDX-License-Identifier: GPL-2.0
//! RTL8125 LED control-register (LEDSEL) encoding for the netdev-trigger LED
//! offload. Kernel-free + host-unit-tested; the `led_classdev` lifecycle and the
//! kernel `TRIGGER_NETDEV_*` <-> chip-mode mapping live in the cshim (kernel enum
//! knowledge), and the MMIO read/write in `mmio`/`netdev`. This module owns the
//! chip-register knowledge: which LEDSEL register backs each LED and how the
//! select field is updated.
//!
//! Each of the 4 LEDs has its own 16-bit LEDSEL register; the low bits select
//! which link-speed / activity conditions light it. r8169 `rtl8125_set_led_mode`
//! does a masked update: `(cur & ~LEDSEL_MASK) | mode`.

/// LEDSEL select-field mask (r8169 `LEDSEL_MASK_8125`) — the link/activity bits
/// the driver owns in each LEDSEL register; all other bits are preserved.
pub(crate) const LEDSEL_MASK: u16 = 0x23f;

/// LEDSEL register byte offset for LED `index` (r8169 `rtl8125_get_led_reg`:
/// LEDSEL0=0x18, LEDSEL1=0x86, LEDSEL2=0x84, LEDSEL3=0x96). `None` out of range.
pub(crate) fn led_reg(index: u32) -> Option<usize> {
    match index {
        0 => Some(0x18),
        1 => Some(0x86),
        2 => Some(0x84),
        3 => Some(0x96),
        _ => None,
    }
}

/// Masked LEDSEL update: replace the select field with `mode` (itself masked to
/// the owned bits), preserving every other bit. Mirrors `rtl8125_set_led_mode`.
pub(crate) fn merge_mode(cur: u16, mode: u16) -> u16 {
    (cur & !LEDSEL_MASK) | (mode & LEDSEL_MASK)
}

/// The active select field read back from a LEDSEL register value (for
/// `hw_control_get`). Mirrors masking the raw register down to the owned bits.
pub(crate) fn mode_from_reg(cur: u16) -> u16 {
    cur & LEDSEL_MASK
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn led_reg_maps_each_index() {
        assert_eq!(led_reg(0), Some(0x18));
        assert_eq!(led_reg(1), Some(0x86));
        assert_eq!(led_reg(2), Some(0x84));
        assert_eq!(led_reg(3), Some(0x96));
        assert_eq!(led_reg(4), None);
        assert_eq!(led_reg(u32::MAX), None);
    }

    #[test]
    fn merge_mode_preserves_non_select_bits() {
        // Reserved bits outside LEDSEL_MASK are preserved; the (stale, fully-set)
        // select field is replaced by the new mode.
        let cur = 0xC000 | LEDSEL_MASK; // reserved high bits + a stale select field
        let mode = 0x008; // LINK_1000 select
        let out = merge_mode(cur, mode);
        assert_eq!(out & !LEDSEL_MASK, 0xC000, "non-select bits preserved");
        assert_eq!(out & LEDSEL_MASK, 0x008, "select field replaced");
    }

    #[test]
    fn merge_mode_clamps_mode_to_mask() {
        // Bits in `mode` outside the owned mask must not leak into the register.
        assert_eq!(merge_mode(0x0000, 0xFFFF), LEDSEL_MASK);
        // clearing: mode 0 zeroes the select field, keeps the rest.
        assert_eq!(merge_mode(0xF23f, 0x000), 0xF000);
    }

    #[test]
    fn mode_from_reg_masks_to_owned_bits() {
        assert_eq!(mode_from_reg(0xF23f), LEDSEL_MASK);
        assert_eq!(mode_from_reg(0xF000), 0);
        assert_eq!(mode_from_reg(0x0208), 0x0208 & LEDSEL_MASK); // ACT(BIT9)+LINK_1000(BIT3)
    }
}
