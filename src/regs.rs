// SPDX-License-Identifier: GPL-2.0
//! Curated RTL8125 register map — offsets and bitfield constants (plan §6.1,
//! §7 M2). M2 scope is intentionally small: just what's needed for chip-version
//! detection (TxConfig) and the reset sequence (ChipCmd). Per-revision register
//! quirks land here as later milestones extend the surface.
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

// ── TX/RX ring base addresses (TNPDS, RDSAR) ─────────────────────────────
/// `TNPDS` — TX Normal Priority Descriptors. 64-bit DMA base address of the
/// TX descriptor ring; we write the low 32 bits then the high 32 bits.
pub(crate) const TNPDS_LOW: usize = 0x20;
pub(crate) const TNPDS_HIGH: usize = 0x24;
/// `RDSAR` — Receive Descriptor Start Address Register. Same shape as TNPDS.
pub(crate) const RDSAR_LOW: usize = 0xE4;
pub(crate) const RDSAR_HIGH: usize = 0xE8;

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
/// IRQ sources we listen for at M4 baseline: RX OK + RX err + TX OK + TX err
/// + link-change. RX descriptor unavailable / overrun are silently dropped.
pub(crate) const INTR_M4_BASELINE: u32 =
    INTR_ROK | INTR_RER | INTR_TOK | INTR_TER | INTR_LINK_CHG;

// ── ISR_V2 / IMR_V2 — per-message-id interrupt layout (M6 #1 Phase A.2) ──
//
// Activated when `INT_CFG0_ENABLE_8125` is set in `ndo_open`, paired
// with an MSI/MSI-X vector allocation from probe. Bit N corresponds to
// MSI-X message_id N. We use a small subset: ROK_Q0 (bit 0), TOK_Q0
// (bit 16), LINKCHG (bit 21 — vendor default `HwCurrIsrVer`).
// Multi-queue is N/A on 8125B (docs/M6_MULTIQ_NA.md).
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
pub(crate) const INTR_V2_M4_BASELINE: u32 =
    ISRIMR_V2_ROK_Q0 | ISRIMR_V2_TOK_Q0 | ISRIMR_V2_LINKCHG;

// ── INT_CFG — 8125 interrupt config ──────────────────────────────────────
/// `INT_CFG0` (8-bit at 0x34). At M4 we write 0 (legacy-ISR mode).
/// M6 sub-feature #1 sets `INT_CFG0_ENABLE_8125` to activate the
/// per-message-id ISR_V2 register layout (`IMR_V2_*` / `ISR_V2` at
/// 0x0D0C / 0x0D04). See docs/M6_MSIX_DESIGN.md.
pub(crate) const INT_CFG0: usize = 0x34;
/// `INT_CFG0` bit 0 — enables the V2 ISR/IMR register layout. Vendor:
/// `rtl8125_hw_set_interrupt_type` (`r8125_n.c:4534`) does
/// `tmp = R8(INT_CFG0_8125); tmp &= ~INT_CFG0_ENABLE_8125;
///  if (isr_ver > 1) tmp |= INT_CFG0_ENABLE_8125; W8(tmp)`.
/// Both Realtek vendor (`r8125.h:1825`) and FreeBSD re-kmod
/// (`if_re.h:1336 = 0x0001`) agree the bit is BIT(0), not BIT(3) —
/// a misreading of BIT(3) in an unrelated `if_re.c:1410` codepath
/// (the timeout/mitigation toggle, not the ISR-version toggle) caused
/// the Phase A.2 first cut to silently never deliver MSI-X IRQs on
/// Controller-KVM 2026-05-28. When clear, legacy IMR/ISR at 0x38/0x3C
/// are authoritative. Set by `ndo_open` only when probe allocated an
/// MSI/MSI-X vector.
pub(crate) const INT_CFG0_ENABLE_8125: u8 = 0x01;
/// `INT_CFG1` (16-bit at 0x7A) — write 0x0000 to disable interrupt
/// coalescing on MAC_VER_63 (RTL8125B) per r8169.
pub(crate) const INT_CFG1: usize = 0x7A;
/// Per-VER coalescing-table region: r8169 zeros 0xa00..0xa80 step 4 for
/// VER_63 / VER_70, 0xa00..0xb00 step 4 for VER_61 / 64 / 66 / 80.
/// We target VER_63 only.
pub(crate) const COALESCE_TABLE_8125B_START: usize = 0xA00;
pub(crate) const COALESCE_TABLE_8125B_END: usize = 0xA80;

// ── Configuration-register lock (Cfg9346 at 0x50, 8-bit) ────────────────
//
// r8169 unlocks the config registers (Config1/Config2/Config5 at 0x52/0x53/
// 0x56) at the top of `rtl_hw_start` and re-locks at the end. Without the
// unlock, writes to those registers — including the ASPM disable in
// Config5 and Config1 PM-bit clear — silently no-op. M4-perf phase 2
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

// ── Config3 (8-bit at 0x54) — L2/L3 readiness ────────────────────────────
/// r8169 `rtl_pcie_state_l2l3_disable` clears `Rdy_to_L23 (BIT(1))` in
/// Config3 as a workaround "when PCI reset occurs during L2/L3 state".
/// Required by all 8125 hw_start paths.
pub(crate) const CONFIG3: usize = 0x54;
pub(crate) const CONFIG3_RDY_TO_L23: u8 = 0x02;

// ── Config5 (8-bit at 0x56) — ASPM enable bit ────────────────────────────
/// r8169 `rtl_hw_aspm_clkreq_enable(false)` clears `ASPM_en (BIT(0))` in
/// Config5 before TX bring-up so the PCIe link doesn't enter L1 during
/// transmit bursts. Must be done while Cfg9346 is unlocked.
pub(crate) const CONFIG5: usize = 0x56;
pub(crate) const CONFIG5_ASPM_EN: u8 = 0x01;

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
// deliberately deferred — M5 will port the rest. See plan §7 M4-traffic.
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

// Sentinel returned by the cshim TX checksum helper when software checksum
// completion failed. This is not a valid opts2 combination: real checksum
// offload uses bits 28..31 plus TCPHO bits 18..27.
pub(crate) const TX_CSUM_OPTS_DROP: u32 = 0xFFFF_FFFF;

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
pub(crate) const RXCFG_DMA_BURST: u32 = 7 << 8;        // bits 8-10
pub(crate) const RXCFG_PAUSE_SLOT_ON_8125B: u32 = 1 << 11;
pub(crate) const RXCFG_FETCH_DFLT_8125: u32 = 8 << 27; // bits 27-29
pub(crate) const RXCFG_8125B_CHIP_BITS: u32 =
    RXCFG_DMA_BURST | RXCFG_PAUSE_SLOT_ON_8125B | RXCFG_FETCH_DFLT_8125;

/// M4 baseline RX policy: broadcast + multicast + my-MAC (no promisc)
/// + the 8125B chip-config bits above. r8169 writes these together so
///
/// the full 32-bit RxConfig has both accept policy AND FIFO/DMA setup.
pub(crate) const RCR_M4_BASELINE: u32 = RCR_ACCEPT_BROADCAST
    | RCR_ACCEPT_MULTICAST
    | RCR_ACCEPT_MY_PHYS
    | RXCFG_8125B_CHIP_BITS;

// ── CPlusCmd (16-bit, MMIO 0xE0) ─────────────────────────────────────────
pub(crate) const CPLUSCMD: usize = 0xE0;
pub(crate) const CPLUSCMD_RX_CHKSUM: u16 = 0x0020;
#[allow(dead_code)]
pub(crate) const CPLUSCMD_RX_VLAN: u16 = 0x0040;

// ── RxMaxSize (MMIO 0xDA, 16-bit) — max RX frame the chip will accept ───
pub(crate) const RX_MAX_SIZE: usize = 0xDA;
/// Standard 1500-MTU Ethernet frame max + room for VLAN tag. r8169 uses
/// `0x05F3` (1523) for the same purpose at non-jumbo; we round to 1536.
pub(crate) const RX_MAX_SIZE_DEFAULT: u16 = 1536;

// ── Descriptor opts1 bits (TX + RX share this layout) ───────────────────
/// `OWN` — set means hardware owns the descriptor. Driver clears on
/// preparing a fresh slot; hardware clears on completion.
pub(crate) const DESC_OWN: u32 = 0x8000_0000;
/// `EOR` — End-Of-Ring marker. Set on the last descriptor of the ring.
pub(crate) const DESC_EOR: u32 = 0x4000_0000;
/// TX: `FS`/`LS` — first / last fragment of a packet. M4 baseline uses
/// linear single-fragment TX, so both bits are set on every TX descriptor.
pub(crate) const DESC_TX_FS: u32 = 0x2000_0000;
pub(crate) const DESC_TX_LS: u32 = 0x1000_0000;
/// 14-bit length field in `opts1[13:0]`.
pub(crate) const DESC_LEN_MASK: u32 = 0x0000_3FFF;
