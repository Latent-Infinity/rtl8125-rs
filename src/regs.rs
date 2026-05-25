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

// ── INT_CFG — 8125 interrupt config (disable coalescing baseline) ────────
/// `INT_CFG0` (8-bit at 0x34) — write 0x00 to disable interrupt-config
/// modes baseline; we don't use ENABLE_8125 or CLKREQEN at M4.
pub(crate) const INT_CFG0: usize = 0x34;
/// `INT_CFG1` (16-bit at 0x7A) — write 0x0000 to disable interrupt
/// coalescing on MAC_VER_63 (RTL8125B) per r8169.
pub(crate) const INT_CFG1: usize = 0x7A;
/// Per-VER coalescing-table region: r8169 zeros 0xa00..0xa80 step 4 for
/// VER_63 / VER_70, 0xa00..0xb00 step 4 for VER_61 / 64 / 66 / 80.
/// We target VER_63 only.
pub(crate) const COALESCE_TABLE_8125B_START: usize = 0xA00;
pub(crate) const COALESCE_TABLE_8125B_END: usize = 0xA80;

// ── Config1 (8-bit at 0x52) ──────────────────────────────────────────────
/// Various per-board PM / wake / LED config. r8169 clears bit 4 in
/// rtl_hw_start_8125_common as part of "disable UPS".
pub(crate) const CONFIG1: usize = 0x52;

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
/// M4 baseline RX policy: broadcast + multicast + my-MAC (no promisc).
pub(crate) const RCR_M4_BASELINE: u32 =
    RCR_ACCEPT_BROADCAST | RCR_ACCEPT_MULTICAST | RCR_ACCEPT_MY_PHYS;

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
