#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# RTL8125 PHY LED netdev-trigger offload contract (W3.1).
#
# Split: the led_classdev lifecycle + the kernel TRIGGER_NETDEV_* <-> chip
# LED_CTRL mapping live in the cshim (kernel enum knowledge); the LEDSEL register
# selection + masked update are the host-tested Rust crate::led encode reached via
# ops.led_{set,get}_mode. Pin that split so a refactor cannot move chip policy
# into C or bypass the tested encode.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
rc=0
red() { printf '\033[1;31mFAIL\033[0m %s\n' "$*"; rc=1; }
grn() { printf '\033[1;32mPASS\033[0m %s\n' "$*"; }
need() { grep -qE -- "$2" "$1" && grn "$3" || red "$3 (missing in ${1#"$ROOT"/}: $2)"; }
reject() { grep -qE -- "$2" "$1" && red "$3 (present in ${1#"$ROOT"/}: $2)" || grn "$3"; }

LED_RS="$ROOT/src/led.rs"
LEDS_C="$ROOT/src/netdev_bridge_leds.c"
HDR="$ROOT/src/netdev_bridge.h"
UB="$ROOT/src/unsafe_boundary.rs"
NETDEV="$ROOT/src/netdev.rs"
NETDEV_C="$ROOT/src/netdev_bridge.c"

# 1. Pure Rust LEDSEL encode is present + host-tested.
need "$LED_RS" 'fn led_reg' "crate::led has the per-index LEDSEL register map"
need "$LED_RS" 'fn merge_mode' "crate::led has the masked LEDSEL update"
need "$LED_RS" 'LEDSEL_MASK' "crate::led owns the LEDSEL select-field mask"
need "$LED_RS" '#\[cfg\(test\)\]' "crate::led has host unit tests"

# 2. The cshim delegates the register write to Rust (chip policy stays in Rust):
#    it must NOT poke the LEDSEL registers directly (no raw RTL_W16/MMIO there).
need "$LEDS_C" 'b->ops\.led_set_mode\(b->priv' "LED hw_control_set delegates to the Rust op"
need "$LEDS_C" 'b->ops\.led_get_mode\(b->priv' "LED hw_control_get delegates to the Rust op"
reject "$LEDS_C" 'RTL_W16|writew\(|iowrite16|readw\(|ioread16' "no direct LEDSEL register poke in the cshim"

# 3. The cshim is a real netdev-trigger hw-offload (kernel enum + led_classdev).
need "$LEDS_C" 'BIT\(TRIGGER_NETDEV_LINK_2500\)' "LED maps the kernel netdev-trigger speed flags"
need "$LEDS_C" 'led_classdev_register' "LED registers led_classdev devices"
need "$LEDS_C" 'hw_control_trigger = "netdev"' "LED advertises the netdev hw-control trigger"

# 4. The vtable ops exist on both sides and are wired.
need "$HDR" 'int \(\*led_set_mode\)\(void \*priv, u32 index, u16 mode\)' "led_set_mode in the C vtable"
need "$HDR" 'int \(\*led_get_mode\)\(void \*priv, u32 index\)' "led_get_mode in the C vtable"
need "$UB" 'pub led_set_mode:' "led_set_mode in the Rust BridgeOps"
need "$UB" 'pub led_get_mode:' "led_get_mode in the Rust BridgeOps"
need "$NETDEV" 'led_set_mode: rust_led_set_mode' "led_set_mode wired in M4_FULL_OPS"
need "$NETDEV" 'led_get_mode: rust_led_get_mode' "led_get_mode wired in M4_FULL_OPS"

# 5. LED lifecycle is wired into register/unregister.
need "$NETDEV_C" 'b->leds = r8125_bridge_init_leds\(ndev\)' "LEDs registered after register_netdev"
need "$NETDEV_C" 'r8125_bridge_remove_leds\(b->leds\)' "LEDs removed at unregister"

exit "$rc"
