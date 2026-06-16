// SPDX-License-Identifier: GPL-2.0
//! Curated RTL8125 register map — offsets and bitfield constants for the
//! validated RTL8125B driver surface. Per-revision register quirks land here
//! as the supported hardware surface grows.
//!
//! Authority: r8169's `drivers/net/ethernet/realtek/r8169_main.c` register
//! enums and `rtl_chip_infos`. Cross-checked against the published RTL8125B
//! datasheet (the validated MS-A2 target, XID 0x641).

// ── ChipCmd (1-byte register at offset 0x37) ─────────────────────────────
/// `ChipCmd` register offset. r8169 calls this register `ChipCmd`.
pub(crate) const CHIP_CMD: usize = 0x37;
/// `CmdReset` bit (write-1-to-trigger; auto-clears when reset completes).
pub(crate) const CMD_RESET: u8 = 0x10;
#[allow(dead_code)]
pub(crate) const CMD_RX_ENB: u8 = 0x08;
#[allow(dead_code)]
pub(crate) const CMD_TX_ENB: u8 = 0x04;

// ── TxConfig (4-byte register at offset 0x40) ────────────────────────────
/// `TxConfig` register offset. Upper bits encode the chip's MAC version /
/// XID; r8169 derives the XID with `(TxConfig >> 20) & 0xfcf`.
pub(crate) const TX_CONFIG: usize = 0x40;
/// Right-shift applied to `TxConfig` to expose the XID nibble.
pub(crate) const XID_SHIFT: u32 = 20;
/// Mask applied after the shift; mirrors `rtl8169_get_chip_version` exactly.
pub(crate) const XID_MASK: u32 = 0xfcf;

// ── MAC address (IDR0..IDR5, MMIO 0x00..0x05) ────────────────────────────
/// IDR0 — low 32 bits of the device's 6-byte MAC address. Read after reset
/// (r8169 reads here too — the device repopulates IDR* from EEPROM during
/// hardware init).
pub(crate) const MAC_ADDR_LOW: usize = 0x00;
/// IDR4 — high 16 bits of the MAC address.
pub(crate) const MAC_ADDR_HIGH: usize = 0x04;

/// 8125 BACKUP MAC registers (0x19E0/0x19E4). The chip loads the factory MAC
/// from EEPROM into these AND into IDR0 at power-on, but a soft reset clears
/// IDR0 while BACKUP persists — so BACKUP is the authoritative source the vendor
/// driver reads (`rtl8125_get_mac_address` reads MAC0 then overwrites from
/// BACKUP). We read BACKUP and write the result back into IDR0/IDR4 (the RX
/// filter) via `rar_set`.
pub(crate) const BACKUP_ADDR0_8125: usize = 0x19E0;
pub(crate) const BACKUP_ADDR1_8125: usize = 0x19E4;

// ── TX/RX ring base addresses (TNPDS, RDSAR) ─────────────────────────────
/// `TNPDS` — TX Normal Priority Descriptors. 64-bit DMA base address of the
/// TX descriptor ring; we write the low 32 bits then the high 32 bits.
pub(crate) const TNPDS_LOW: usize = 0x20;
pub(crate) const TNPDS_HIGH: usize = 0x24;
/// `RDSAR` — Receive Descriptor Start Address Register. Same shape as TNPDS.
pub(crate) const RDSAR_LOW: usize = 0xE4;
pub(crate) const RDSAR_HIGH: usize = 0xE8;
/// RX queue 1+ descriptor base registers. Vendor maps queue N at
/// `RDSAR_Q1_LOW_8125 + (N - 1) * 8`; queue 0 uses legacy `RDSAR`.
pub(crate) const RDSAR_Q1_LOW_8125: usize = 0x4000;

// ── ChipCmd RX/TX enable bits ────────────────────────────────────────────
// (CHIP_CMD offset + CMD_RESET already defined at top of file.)

// ── IMR/ISR — Interrupt Mask / Status (**32-bit for 8125 family**) ───────
//
// RTL8125 moves IMR/ISR vs the older 8169 layout:
//   8169:    IMR=0x3C (16-bit), ISR=0x3E (16-bit), TxPoll=0x38 (8-bit, NPQ=0x40)
//   8125:    IMR=0x38 (32-bit), ISR=0x3C (32-bit), TxPoll=0x90 (16-bit, NPQ=BIT(0))
// We target 8125B (MAC_VER_63) only, so the names below use 8125 offsets.
// See r8169_main.c:265-437 and the inline 8125 dispatch in rtl_irq_enable.
/// Interrupt Mask Register — bits enabled fire IRQs.
pub(crate) const IMR: usize = 0x38;
/// Interrupt Status Register — write-1-to-clear.
pub(crate) const ISR: usize = 0x3C;
pub(crate) const INTR_ROK: u32 = 0x0001;
pub(crate) const INTR_RER: u32 = 0x0002;
pub(crate) const INTR_TOK: u32 = 0x0004;
pub(crate) const INTR_TER: u32 = 0x0008;
pub(crate) const INTR_LINK_CHG: u32 = 0x0020;
/// IRQ sources we listen for at baseline: RX OK + RX err + TX OK + TX err
/// + link-change. RX descriptor unavailable / overrun are silently dropped.
pub(crate) const INTR_M4_BASELINE: u32 = INTR_ROK | INTR_RER | INTR_TOK | INTR_TER | INTR_LINK_CHG;

// ── ISR_V2 / IMR_V2 — per-message-id interrupt layout ───────────────────
//
// Activated when `INT_CFG0_ENABLE_8125` is set in `ndo_open`, paired
// with an MSI/MSI-X vector allocation from probe. Bit N corresponds to
// MSI-X message_id N. We use a small subset: ROK_Q0 (bit 0), TOK_Q0
// (bit 16), LINKCHG (bit 21 — vendor default `HwCurrIsrVer`).
// Full hardware RSS can later add RX queue bits here; this baseline only
// unmasks queue 0 plus the single TX/link owners validated for B3.
//
// Vendor: `IMR_V2_CLEAR_REG_8125 = 0x0D00`, `ISR_V2_8125 = 0x0D04`,
// `IMR_V2_SET_REG_8125 = 0x0D0C` (r8125.h:1496-1498).
/// Write `BIT(message_id)` to mask that source. Idempotent.
pub(crate) const IMR_V2_CLEAR: usize = 0x0D00;
/// Read for currently-set status bits; write `BIT(N)` to ack message N.
pub(crate) const ISR_V2: usize = 0x0D04;
/// Write `BIT(message_id)` to unmask that source. Idempotent.
pub(crate) const IMR_V2_SET: usize = 0x0D0C;

/// RX queue 0 done — `ISRIMR_V2_ROK_Q0 = BIT(0)` (vendor `r8125.h:1832`).
pub(crate) const ISRIMR_V2_ROK_Q0: u32 = 1 << 0;
/// TX queue 0 done — `messageId == 0x10` for `HwSuppIsrVer == 2` in
/// vendor's `rtl8125_vec_2_tx_q_num` mapping.
pub(crate) const ISRIMR_V2_TOK_Q0: u32 = 1 << 16;
/// Link change — vendor `rtl8125_get_linkchg_message_id()` returns 21
/// for the default `HwCurrIsrVer` (our chip's case).
pub(crate) const ISRIMR_V2_LINKCHG: u32 = 1 << 21;

/// V2 sources we want at baseline. Mirrors `INTR_M4_BASELINE` for the
/// legacy layout: RX OK on queue 0, TX OK on queue 0, link change.
/// RX error / TX error don't have explicit V2 messages on 8125B; the
/// chip surfaces them as TOK_Q0 / ROK_Q0 with status flags in the
/// descriptor, which the NAPI reaper inspects per-packet.
pub(crate) const INTR_V2_M4_BASELINE: u32 = ISRIMR_V2_ROK_Q0 | ISRIMR_V2_TOK_Q0 | ISRIMR_V2_LINKCHG;
/// RTL8125B ISR version 2 fixed MSI-X message IDs. Bit position == MSI-X table
/// entry; there is no remap for this surface.
pub(crate) const V2_RX_Q0_VECTOR: u32 = 0;
pub(crate) const V2_TX_Q0_VECTOR: u32 = 16;
pub(crate) const V2_LINK_VECTOR: u32 = 21;
/// Vendor `R8125_MIN_MSIX_VEC_8125B`: minimum allocation that covers LINKCHG.
pub(crate) const V2_MIN_MSIX_VECTORS_8125B: u32 = 22;

// ── INT_CFG — 8125 interrupt config ──────────────────────────────────────
/// `INT_CFG0` (8-bit at 0x34). We write 0 (legacy-ISR mode).
/// The B3 interrupt model sets `INT_CFG0_ENABLE_8125` to activate the
/// per-message-id ISR_V2 register layout (`IMR_V2_*` / `ISR_V2` at
/// 0x0D0C / 0x0D04). See docs/MSIX_DESIGN.md.
pub(crate) const INT_CFG0: usize = 0x34;
/// `INT_CFG0` bit 0 — enables the V2 ISR/IMR register layout. Vendor:
/// `rtl8125_hw_set_interrupt_type` (`r8125_n.c:4534`) does
/// `tmp = R8(INT_CFG0_8125); tmp &= ~INT_CFG0_ENABLE_8125;
///  if (isr_ver > 1) tmp |= INT_CFG0_ENABLE_8125; W8(tmp)`.
/// Both Realtek vendor (`r8125.h:1825`) and FreeBSD re-kmod
/// (`if_re.h:1336 = 0x0001`) agree the bit is BIT(0), not BIT(3) —
/// a misreading of BIT(3) in an unrelated `if_re.c:1410` codepath
/// (the timeout/mitigation toggle, not the ISR-version toggle) caused
/// an early MSI-X enablement attempt to silently never deliver IRQs on
/// Controller-KVM 2026-05-28. When clear, legacy IMR/ISR at 0x38/0x3C
/// are authoritative. Set by `ndo_open` only when probe allocated an
/// MSI/MSI-X vector.
pub(crate) const INT_CFG0_ENABLE_8125: u8 = 0x01;
/// `INT_CFG0` bit 1 — timeout-bypass for the 8125 interrupt-mitigation block.
/// r8169 clears this by writing `INT_CFG0 = 0`; the vendor driver clears it in
/// `rtl8125_hw_clear_int_miti()`. Leaving it set can bypass the 0xa00 table.
pub(crate) const INT_CFG0_TIMEOUT0_BYPASS_8125: u8 = 0x02;
/// `INT_CFG0` bit 2 — mitigation-bypass for the 8125 interrupt-mitigation block.
/// Clear before programming `INT_MITI_V2_*` timers on either legacy or V2
/// interrupt surface.
pub(crate) const INT_CFG0_MITIGATION_BYPASS_8125: u8 = 0x04;
/// `INT_CFG1` (16-bit at 0x7A). r8169 and the vendor driver write 0x0000
/// while clearing the MAC_VER_63 (RTL8125B) INT_MITI table.
pub(crate) const INT_CFG1: usize = 0x7A;
/// 8125 INT_MITI per-vector interrupt-moderation table. Vendor names this
/// `INT_MITI_V2`, but the timer block is still the 8125 moderation surface
/// when the chip delivers interrupts through the legacy ISR/IMR window. Each
/// vector gets an 8-byte slot: a 16-bit RX timer at +0 and a 16-bit TX timer
/// at +2. We drive only queue 0 (vector 0).
pub(crate) const INT_MITI_V2_0_RX: usize = 0xA00;
pub(crate) const INT_MITI_V2_0_TX: usize = 0xA02;
/// Per-VER coalescing-table region: r8169 zeros 0xa00..0xa80 step 4 for
/// VER_63 / VER_70, 0xa00..0xb00 step 4 for VER_61 / 64 / 66 / 80.
/// We target VER_63 only.
pub(crate) const COALESCE_TABLE_8125B_START: usize = 0xA00;
pub(crate) const COALESCE_TABLE_8125B_END: usize = 0xA80;
/// RX moderation timer for vector 0. `0x10` eliminated 64/128B
/// packet loss but capped peak RX pps versus r8169, so the next validation
/// pass starts lower and sweeps via the module parameter.
pub(crate) const RX_COALESCE_TIMER_8125B_DEFAULT: u16 = 0x0008;
/// TX moderation timer for vector 0. BQL is disabled on the tracked
/// MSI path by default, so TX-completion timing is still swept separately from
/// the INTx+BQL latency fix.
pub(crate) const TX_COALESCE_TIMER_8125B_DEFAULT: u16 = 0x0010;

// RTL8125B repurposes the older 8168/8169 `IntrMitigate` register at 0xE2 as
// RX/TX FIFO-empty status (`RxTxFifo` in vendor references). Do not use 0xE2
// for interrupt moderation on 8125-family chips; use the INT_MITI table above.

// ── Configuration-register lock (Cfg9346 at 0x50, 8-bit) ────────────────
//
// r8169 unlocks the config registers (Config1/Config2/Config5 at 0x52/0x53/
// 0x56) at the top of `rtl_hw_start` and re-locks at the end. Without the
// unlock, writes to those registers — including the ASPM disable in
// Config5 and Config1 PM-bit clear — silently no-op. Performance validation
// found that this missing unlock contributes to TSO segment loss because
// ASPM stays enabled and the PCIe link enters L1 power-save between
// super-skb bursts.
pub(crate) const CFG9346: usize = 0x50;
pub(crate) const CFG9346_LOCK: u8 = 0x00;
pub(crate) const CFG9346_UNLOCK: u8 = 0xC0;

// ── Config1 (8-bit at 0x52) ──────────────────────────────────────────────
/// Various per-board PM / wake / LED config. r8169 clears bit 4 in
/// rtl_hw_start_8125_common as part of "disable UPS".
pub(crate) const CONFIG1: usize = 0x52;
/// Config1 `PMEnable (BIT0)` — master Power-Management/Wake-on-LAN enable. The
/// chip cannot assert PME# on a WoL match unless this is set (r8169
/// `__rtl8169_set_wol` sets it iff wolopts).
pub(crate) const CONFIG1_PMENABLE: u8 = 1 << 0;

// ── Config2 (8-bit at 0x53) — PME status ─────────────────────────────────
/// `PMSTS_En (BIT5)` arms PME-status reporting so the chip can assert PME# on a
/// Wake-on-LAN match while in D3 (vendor `rtl8125_powerdown_pll`). Set only on
/// the WoL suspend path; left clear in normal operation.
pub(crate) const CONFIG2: usize = 0x53;
pub(crate) const CONFIG2_PMSTS_EN: u8 = 1 << 5;

// ── Config3 (8-bit at 0x54) — L2/L3 readiness ────────────────────────────
/// r8169 `rtl_pcie_state_l2l3_disable` clears `Rdy_to_L23 (BIT(1))` in
/// Config3 as a workaround "when PCI reset occurs during L2/L3 state".
/// Required by all 8125 hw_start paths.
pub(crate) const CONFIG3: usize = 0x54;
pub(crate) const CONFIG3_RDY_TO_L23: u8 = 0x02;
/// Config3 `MagicPacket (BIT5)` — arm Wake-on-LAN magic-packet reception.
/// Vendor `rtl8125_set_hw_wol` sets this (Cfg9346-unlocked) for `WAKE_MAGIC`.
pub(crate) const CONFIG3_MAGIC: u8 = 1 << 5;

// ── Config5 (8-bit at 0x56) — ASPM enable bit ────────────────────────────
/// r8169 `rtl_hw_aspm_clkreq_enable(false)` clears `ASPM_en (BIT(0))` in
/// Config5 before TX bring-up so the PCIe link doesn't enter L1 during
/// transmit bursts. Must be done while Cfg9346 is unlocked.
pub(crate) const CONFIG5: usize = 0x56;
pub(crate) const CONFIG5_ASPM_EN: u8 = 0x01;
/// Config5 Wake-on-LAN wake-frame enables (vendor `rtl8125_set_hw_wol`):
/// LanWake (master, WAKE_ANY), UWF/BWF/MWF for unicast/broadcast/multicast
/// wake frames. Programmed Cfg9346-unlocked.
pub(crate) const CONFIG5_LANWAKE: u8 = 1 << 1;
pub(crate) const CONFIG5_UWF: u8 = 1 << 4;
pub(crate) const CONFIG5_MWF: u8 = 1 << 5;
pub(crate) const CONFIG5_BWF: u8 = 1 << 6;

// ── RSS + per-queue config (8125-only, 32-bit / 16-bit) ──────────────────
/// `RSS_CTRL_8125` (0x4500, 32-bit) — multi-queue receive-side-scaling.
/// r8169 writes 0 to fully disable RSS so all RX lands on queue 0 (our
/// single-queue setup). Default chip state may have RSS partially
/// enabled, sending segments to non-existent queues.
pub(crate) const RSS_CTRL_8125: usize = 0x4500;
/// `Q_NUM_CTRL_8125` (0x4800, 16-bit) — number of TX/RX queues. r8169
/// writes 0 (single queue). Without this, the chip may try to use
/// multiple TX queues despite us only programming queue 0's TNPDS.
pub(crate) const Q_NUM_CTRL_8125: usize = 0x4800;
/// `RSS_KEY_8125` (0x4600) — 40-byte Toeplitz hash key, 10 dwords
/// (`r8125.h:1520`, `RTL8125_RSS_KEY_SIZE = 40`).
pub(crate) const RSS_KEY_8125: usize = 0x4600;
/// RSS hash key size in bytes (`r8125_rss.h:41`).
pub(crate) const RSS_KEY_SIZE: usize = 40;
/// `RSS_INDIRECTION_TBL_8125_V2` (0x4700) — hash-bucket → queue map
/// (`r8125.h:1521`). Zeroed for the probe so every bucket lands on queue 0.
pub(crate) const RSS_INDIRECTION_TBL_8125: usize = 0x4700;
/// `RxConfig`/RCR bit 24 — emit V3 (32-byte, RSS-capable) RX descriptors
/// (`EnableRxDescV3`, `r8125.h:1649`).
pub(crate) const RCR_ENABLE_RX_DESC_V3: u32 = 1 << 24;
/// RXHASH `RSS_CTRL_8125` enable bits for TCP/IPv4, TCP/IPv6, UDP/
/// IPv4, UDP/IPv6, and raw IPv4/IPv6 hashing (`r8125_rss.c:40-48`).
/// With `CPU_NUM=0` (single queue) and `MASK=0`, this programs the minimal
/// one-queue hash engine for hash-only support.
pub(crate) const RSS_CTRL_HASH_BITS: u32 =
    (1 << 0) | (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5) | (1 << 11) | (1 << 12);
/// Anonymous tuning register at 0x382 (16-bit) — r8169 writes 0x221b at
/// the top of `rtl_hw_start_8125_common`. Function unclear from the
/// source comment; included for parity.
pub(crate) const MMIO_0X382: usize = 0x0382;
pub(crate) const MMIO_0X382_VAL: u16 = 0x221b;

// ── L1-exit triggers (OCP 0xC0AC) ────────────────────────────────────────
/// r8169 `rtl_enable_exit_l1` for MAC_VER_40..LAST writes
/// `r8168_mac_ocp_modify(0xc0ac, 0, 0x1f80)` — enables bits 7-12 (txpla,
/// pktavi, xadm, txdma_poll, ltr_msg, rxdv) so the chip wakes the PCIe
/// link out of L1 when any of those events fires. Kept for r8169 parity;
/// TSO still also requires the RTL8125B-specific max-segs cap in
/// `netdev_bridge.c`.
pub(crate) const MAC_OCP_L1_EXIT_TRIGGERS: u32 = 0xC0AC;
pub(crate) const MAC_OCP_L1_EXIT_TRIGGERS_MASK: u16 = 0x1F80;

// ── WoL magic-packet V3 enable (OCP 0xC0B6) ──────────────────────────────
/// Vendor `rtl8125_enable_magic_packet` (HwSuppMagicPktVer V3 = RTL8125B/
/// MAC_VER_63) sets `BIT0` of MAC OCP 0xC0B6 to arm magic-packet detection;
/// clearing it disarms. Paired with [`CONFIG3_MAGIC`].
pub(crate) const MAC_OCP_MAGIC_V3: u32 = 0xC0B6;
pub(crate) const MAC_OCP_MAGIC_V3_EN: u16 = 1 << 0;

// ── MAC OCP — internal MAC register-set access (8125 family) ─────────────
//
// r8169's r8168_mac_ocp_read/write (see references/linux-mainline/.../
// r8169_main.c lines 1144-1180). 32-bit register at MMIO 0xB0:
//   write: RTL_W32(OCPDR, OCPAR_FLAG | (ocp_addr << 15) | data16)  — no poll
//   read:  RTL_W32(OCPDR, ocp_addr << 15); val = RTL_R32(OCPDR) & 0xFFFF
// Used for the 8125-specific MAC init OCP writes in rtl_hw_start_8125_*.
pub(crate) const OCPDR: usize = 0xB0;

// ── MISC (8125 family — MMIO 0xF0, 32-bit) ───────────────────────────────
//
// Bit 19 = RXDV_GATED_EN: when set, the MAC gates the PHY's RX_DV signal,
// meaning packets received by the PHY don't reach the MAC. r8169
// `rtl_disable_rxdvgate` clears this bit; without it, RX is dead.
pub(crate) const MISC: usize = 0xF0;
pub(crate) const MISC_RXDV_GATED_EN: u32 = 1 << 19;

// ── 8125B (MAC_VER_63) MAC OCP init magic numbers ────────────────────────
// Subset of rtl_hw_start_8125_common + rtl_hw_start_8125b that's required
// to get the TX engine accepting our 16-byte legacy descriptors AND the
// RX engine ungated. Tuning writes (FIFO thresholds, RSS, EEE) are
// deliberately deferred until they are validated against r8169/vendor behavior.
//
// 0xeb58 bit 0: "new tx descriptor format" — if set, the chip expects
// 40-byte descriptors; we use 16-byte (legacy r8169), so this MUST be 0.
pub(crate) const MAC_OCP_NEW_TX_DESC: u32 = 0xEB58;
pub(crate) const MAC_OCP_NEW_TX_DESC_BIT0: u16 = 0x0001;

// ── GPHY_OCP — PHY register access via MAC OCP path (8125 family) ────────
//
// r8169's r8168_phy_ocp_read/write (see references/linux-mainline/.../r8169_main.c
// lines 1110-1133). 32-bit register at MMIO 0xB8:
//   write: RTL_W32(GPHY_OCP, OCPAR_FLAG | (ocp_addr << 15) | data16)
//          then poll until (R32(GPHY_OCP) & OCPAR_FLAG) == 0 (flag clears)
//   read:  RTL_W32(GPHY_OCP, ocp_addr << 15)
//          then poll until OCPAR_FLAG sets, then read low 16 bits.
// ocp_addr = OCP_STD_PHY_BASE + mii_reg * 2 (for the standard page).
pub(crate) const GPHY_OCP: usize = 0xB8;
pub(crate) const OCPAR_FLAG: u32 = 0x8000_0000;
/// Standard PHY page base. MII reg `n` lives at `OCP_STD_PHY_BASE + n * 2`.
pub(crate) const OCP_STD_PHY_BASE: u32 = 0xA400;
/// MII page-select register (writing this picks an alternate OCP page).
pub(crate) const MII_PAGE_SELECT: u8 = 0x1F;

// ── PMCH (8-bit at 0x6F) — D3 PLL power gate (Wake-on-LAN keep-alive) ──────
// Setting these keeps the chip PLL (and thus the internal PHY) powered while the
// device is in D3, so a magic packet can reach the wake detector. r8169
// `rtl_set_d3_pll_down(!wolopts)` sets both for the 8125 default case when WoL is
// armed; clearing D3COLD lets the PLL drop in D3cold for power saving otherwise.
pub(crate) const PMCH: usize = 0x6F;
pub(crate) const PMCH_D3HOT_NO_PLL_DOWN: u8 = 1 << 6;
pub(crate) const PMCH_D3COLD_NO_PLL_DOWN: u8 = 1 << 7;

// ── MDIO Clause-45 access (MMD) — mirrors `r8169_mdio_read_reg_c45` ──────
//
// For RTL8125B the C45 callbacks accept ANY MMD device address, but only
// `MDIO_MMD_VEND2` with a regnum greater than `MDIO_STAT2` reaches the
// chip — the access lands as a direct PHY OCP read/write at `regnum`
// (NOT the OCP_STD_PHY_BASE-relative path used by C22 mdio_read).
// Anything else: read returns 0, write returns -ENODEV. The kernel's
// `phy_read_mmd` for MMD VEND2 is how the dedicated Realtek PHY driver
// reads `RTL_MDIO_PMA_SPEED` (for 2.5G capability) + writes
// `RTL822X_VND2_TSALRM` (for thermal-sensor init in hwmon).
pub(crate) const MDIO_MMD_VEND2: i32 = 31;
pub(crate) const MDIO_STAT2: i32 = 8;

// ── TPPoll — 8125 layout (TxPoll_8125 = 0x90, 16-bit, NPQ = BIT(0)) ──────
pub(crate) const TPPOLL: usize = 0x90;
/// `NPQ` — Normal Priority Queue kick bit (write to TPPOLL after posting TX).
pub(crate) const TPPOLL_NPQ: u16 = 0x0001;

// ── TxConfig (32-bit at 0x40) — DMA burst + InterFrameGap ────────────────
//
// Same register read for XID detection (upper bits encode chip version).
// r8169 `rtl_set_tx_config_registers` writes
// `(TX_DMA_BURST << TxDMAShift) | (IFG << TxIFGShift)` to set the TX
// engine's PCI burst length and inter-frame gap. Without this write,
// default reset values starve the TX FIFO under TSO bursts (manifests
// as massive retransmits when iperf3 enables TSO).
//   TX_DMA_BURST = 7 (unlimited) at bits 8-10 → 0x700
//   IFG = 3 (shortest) at bits 24-25 → 0x03000000
pub(crate) const TXCFG_DMA_SHIFT: u32 = 8;
pub(crate) const TXCFG_IFG_SHIFT: u32 = 24;
pub(crate) const TXCFG_DMA_BURST_UNLIMITED: u32 = 7;
pub(crate) const TXCFG_IFG_SHORTEST: u32 = 3;
pub(crate) const TXCFG_M4_BASELINE: u32 =
    (TXCFG_DMA_BURST_UNLIMITED << TXCFG_DMA_SHIFT) | (TXCFG_IFG_SHORTEST << TXCFG_IFG_SHIFT);

// ── Hardware tally counter dump (CounterAddr at 0x10/0x14) ───────────────
// `ndo_get_stats64` triggers a DMA dump of the on-die statistics block to a
// driver-provided coherent buffer: write the buffer's 64-bit DMA address, set
// the dump bit in the low word, poll it clear. Mirrors vendor
// `rtl8125_dump_tally_counter`.
pub(crate) const COUNTER_ADDR_LOW: usize = 0x10;
pub(crate) const COUNTER_ADDR_HIGH: usize = 0x14;
pub(crate) const COUNTER_DUMP: u32 = 0x8;
/// `CounterReset (BIT0)` of CounterAddrLow — zero the on-die tally block. Issued
/// once at open (after RX is enabled) so the extended counters start from a
/// clean per-session baseline; matches r8169/vendor `CounterReset`.
pub(crate) const COUNTER_RESET: u32 = 0x1;

// ── MAR — Multicast hash filter (MAR0..MAR7 at 0x08, two 32-bit words) ────
// `ndo_set_rx_mode` programs the 64-bit multicast hash here (ether_crc>>26 bit
// per joined group), written as two 32-bit words at 0x08 and 0x0C.
pub(crate) const MAR0: usize = 0x08;
pub(crate) const MAR4: usize = 0x0C;

// ── RCR — Receive Configuration Register (32-bit) ────────────────────────
pub(crate) const RCR: usize = 0x44;
#[allow(dead_code)]
pub(crate) const RCR_ACCEPT_ALL_PHYS: u32 = 0x01;
pub(crate) const RCR_ACCEPT_MY_PHYS: u32 = 0x02;
pub(crate) const RCR_ACCEPT_MULTICAST: u32 = 0x04;
pub(crate) const RCR_ACCEPT_BROADCAST: u32 = 0x08;
#[allow(dead_code)]
pub(crate) const RCR_ACCEPT_RUNT: u32 = 0x10;
#[allow(dead_code)]
pub(crate) const RCR_ACCEPT_ERR: u32 = 0x20;

// 8125B chip-config bits in RxConfig (high bits), per r8169 rtl_init_rxcfg
// VER_63 case. Must be OR'd with the accept-policy bits at write time.
// Without these the RX engine fetches descriptors too slowly under bursty
// peer-ACK traffic.
pub(crate) const RXCFG_DMA_BURST: u32 = 7 << 8; // bits 8-10
pub(crate) const RXCFG_PAUSE_SLOT_ON_8125B: u32 = 1 << 11;
pub(crate) const RXCFG_FETCH_DFLT_8125: u32 = 8 << 27; // bits 27-29
pub(crate) const RXCFG_8125B_CHIP_BITS: u32 =
    RXCFG_DMA_BURST | RXCFG_PAUSE_SLOT_ON_8125B | RXCFG_FETCH_DFLT_8125;

/// baseline RX policy: broadcast + multicast + my-MAC (no promisc)
/// + the 8125B chip-config bits above. r8169 writes these together so
///
/// the full 32-bit RxConfig has both accept policy AND FIFO/DMA setup.
pub(crate) const RCR_M4_BASELINE: u32 =
    RCR_ACCEPT_BROADCAST | RCR_ACCEPT_MULTICAST | RCR_ACCEPT_MY_PHYS | RXCFG_8125B_CHIP_BITS;

// ── CPlusCmd (16-bit, MMIO 0xE0) ─────────────────────────────────────────
pub(crate) const CPLUSCMD: usize = 0xE0;
pub(crate) const CPLUSCMD_RX_CHKSUM: u16 = 0x0020;
#[allow(dead_code)]
pub(crate) const CPLUSCMD_RX_VLAN: u16 = 0x0040;
/// RTL8125 RxConfig VLAN strip enables. r8169 programs these instead of the
/// older CPlusCmd RxVlan bit for 8125-family chips.
pub(crate) const RX_VLAN_INNER_8125: u32 = 1 << 22;
pub(crate) const RX_VLAN_OUTER_8125: u32 = 1 << 23;
pub(crate) const RX_VLAN_8125: u32 = RX_VLAN_INNER_8125 | RX_VLAN_OUTER_8125;

// ── RxMaxSize (MMIO 0xDA, 16-bit) — max RX frame the chip will accept ───
pub(crate) const RX_MAX_SIZE: usize = 0xDA;
/// Standard 1500-MTU Ethernet frame max + room for VLAN tag. r8169 uses
/// `0x05F3` (1523) for the same purpose at non-jumbo; we round to 1536.
#[allow(dead_code)]
pub(crate) const RX_MAX_SIZE_DEFAULT: u16 = 1536;
/// Jumbo-frame `RxMaxSize`. r8169 mainline sets the chip's RX max-frame
/// threshold to `R8169_RX_BUF_SIZE = 0x05F3` for non-jumbo and to the
/// allocated buffer size (`JUMBO_16K` minus VLAN/CRC slack) for jumbo
/// builds. We follow r8169's "size the chip's drop threshold to match
/// the actual buffer" rule and program `RX_MAX_SIZE_JUMBO` whenever the
/// RX pool is allocated at jumbo size. Matches `R8169_RX_BUF_SIZE`
/// (16383) plus we round to the chip's 14-bit length field cap.
pub(crate) const RX_MAX_SIZE_JUMBO: u16 = 0x3FFF;

// ── Jumbo-buffer sizing — paired with src/netdev_bridge_rx_pool.c ────────
/// 9 KiB jumbo cap (the standard Ethernet-industry limit; switches and
/// SFPs commonly support up to here, and our chip's TSO `max_segs = 10`
/// (see `docs/RTL8125B_TSO_NOTES.md`) means a single super-skb covers
/// ~90 KB of payload at MTU 9000 — comfortably under
/// `netif_set_tso_max_size(64000)`).
#[allow(dead_code)]
pub(crate) const JUMBO_9K_BYTES: usize = 9000;
/// Chip-side jumbo maximum (the hardware accepts up to `R8169_RX_BUF_SIZE
/// = 16383` per `r8169_main.c`). Documents the upper bound the per-MTU
/// page_pool geometry rounds up to for a 9000-MTU open (order-2, 16 KiB).
/// Kept as the documented chip ceiling and referenced by the static gate
/// `ci/check_jumbo_mtu_chip.sh`; the RX buffer size itself is now computed
/// per-MTU in `netdev_bridge_rx_pool.c`, so nothing in Rust consumes it.
#[allow(dead_code)]
pub(crate) const JUMBO_16K_BYTES: usize = 16384;

// ── Descriptor opts1 bits (TX + RX share this layout) ───────────────────
/// `OWN` — set means hardware owns the descriptor. Driver clears on
/// preparing a fresh slot; hardware clears on completion.
pub(crate) const DESC_OWN: u32 = 0x8000_0000;
/// `EOR` — End-Of-Ring marker. Set on the last descriptor of the ring.
pub(crate) const DESC_EOR: u32 = 0x4000_0000;
/// TX: `FS`/`LS` — first / last fragment of a packet. The baseline uses
/// linear single-fragment TX, so both bits are set on every TX descriptor.
pub(crate) const DESC_TX_FS: u32 = 0x2000_0000;
pub(crate) const DESC_TX_LS: u32 = 0x1000_0000;
/// 14-bit length field in `opts1[13:0]`.
pub(crate) const DESC_LEN_MASK: u32 = 0x0000_3FFF;
