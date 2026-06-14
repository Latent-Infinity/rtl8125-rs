// SPDX-License-Identifier: GPL-2.0
//! Typed MMIO register accessors — the only module outside `unsafe_boundary`
//! that touches BAR memory. All other modules
//! pass around `&Regs` and call its typed methods rather than reaching into
//! the `pci::Bar` themselves.
//!
//! The typed surface started intentionally small: `tx_config()` for the
//! revision-detect path and `chip_cmd()` / `set_chip_cmd()` for the reset
//! path. Later work added register groups (descriptors, MAC address, IRQ
//! status, …) here as new typed accessors.
//!
//! All accesses go through the kernel's safe `pci::Bar` wrappers
//! (`read8`/`read32`/etc), so this module needs no `unsafe`.

use kernel::io::Io;
use kernel::pci;
use kernel::time::{delay::udelay, Delta};

use crate::{regs, unsafe_boundary};

/// Size of BAR2 on the RTL8125 (the MAC-register window). Authoritative for
/// the BAR type generic the driver carries around; pinned here so a future
/// resize requires touching only this constant.
pub(crate) const R8125_MMIO_LEN: usize = 0x1_0000;

/// Lightweight view over the device's mapped MMIO BAR. `&Regs` is what the
/// rest of the crate consumes — `pci.rs` / `hw.rs` / `pm.rs` never see the
/// `pci::Bar` directly.
pub(crate) struct Regs<'a> {
    bar: &'a pci::Bar<{ R8125_MMIO_LEN }>,
}

impl<'a> Regs<'a> {
    /// Wrap a borrow of the device's mapped BAR.
    pub(crate) fn new(bar: &'a pci::Bar<{ R8125_MMIO_LEN }>) -> Self {
        Self { bar }
    }

    /// Read `TxConfig` (offset 0x40, 32-bit). The XID extraction is done
    /// in `hw.rs` so this stays a single hardware read with no semantics.
    pub(crate) fn tx_config(&self) -> u32 {
        self.bar.read32(regs::TX_CONFIG)
    }

    /// Write `TxConfig` — DMA burst + InterFrameGap.
    /// Mirrors r8169 `rtl_set_tx_config_registers`. Required at open
    /// time for TSO to operate without TX FIFO starvation.
    pub(crate) fn set_tx_config(&self, value: u32) {
        self.bar.write32(value, regs::TX_CONFIG);
    }

    /// Read `ChipCmd` (offset 0x37, 1-byte).
    pub(crate) fn chip_cmd(&self) -> u8 {
        self.bar.read8(regs::CHIP_CMD)
    }

    /// Write `ChipCmd` (offset 0x37, 1-byte). The reset path only ever writes
    /// `regs::CMD_RESET` here; the packet path read-modify-writes to preserve
    /// TX/RX enable bits.
    pub(crate) fn set_chip_cmd(&self, value: u8) {
        self.bar.write8(value, regs::CHIP_CMD);
    }

    /// Read the factory MAC from the 8125 BACKUP registers (0x19E0/0x19E4).
    /// The legacy IDR0 window (0x00) is cleared by a soft reset, but BACKUP
    /// retains the EEPROM-loaded address — this is the authoritative source the
    /// vendor driver reads (`rtl8125_get_mac_address`). Reading IDR0 instead
    /// returns zeros after any reset, which would force a bogus random MAC.
    pub(crate) fn mac_address(&self) -> [u8; 6] {
        let low = self.bar.read32(regs::BACKUP_ADDR0_8125);
        let high = self.bar.read16(regs::BACKUP_ADDR1_8125);
        [
            low as u8,
            (low >> 8) as u8,
            (low >> 16) as u8,
            (low >> 24) as u8,
            high as u8,
            (high >> 8) as u8,
        ]
    }

    /// Program `addr` into the chip's RX-filter MAC registers (IDR0/IDR4),
    /// bracketed by the Cfg9346 unlock/lock the chip requires for these writes.
    /// Mirrors the vendor `rtl8125_rar_set`. MUST be called at open (and on a MAC
    /// change) so the hardware unicast filter matches `dev_addr` — otherwise the
    /// chip silently drops unicast frames after a reset clears IDR0, or after a
    /// random-MAC fallback / `ip link set address`.
    pub(crate) fn set_mac_address(&self, addr: &[u8; 6]) {
        let low = u32::from(addr[0])
            | (u32::from(addr[1]) << 8)
            | (u32::from(addr[2]) << 16)
            | (u32::from(addr[3]) << 24);
        let high = u32::from(addr[4]) | (u32::from(addr[5]) << 8);
        self.bar.write8(regs::CFG9346_UNLOCK, regs::CFG9346);
        self.bar.write32(low, regs::MAC_ADDR_LOW);
        self.bar.write32(high, regs::MAC_ADDR_HIGH);
        self.bar.write8(regs::CFG9346_LOCK, regs::CFG9346);
    }

    // ── hot-path accessors ────────────────────────────────────────────────

    /// Program the TX ring base address (TNPDS — low 32 bits then high 32).
    pub(crate) fn set_tx_ring_base(&self, addr: u64) {
        self.bar.write32(addr as u32, regs::TNPDS_LOW);
        self.bar.write32((addr >> 32) as u32, regs::TNPDS_HIGH);
    }

    /// Program the RX ring base address (RDSAR — low 32 bits then high 32).
    pub(crate) fn set_rx_ring_base(&self, addr: u64) {
        self.bar.write32(addr as u32, regs::RDSAR_LOW);
        self.bar.write32((addr >> 32) as u32, regs::RDSAR_HIGH);
    }

    /// Program an RX ring base address by queue id. Queue 0 uses the legacy
    /// RDSAR pair; queue 1+ use the vendor RTL8125 queue table at 0x4000.
    #[allow(dead_code)]
    pub(crate) fn set_rx_ring_base_queue(&self, queue_id: usize, addr: u64) {
        if queue_id == 0 {
            self.set_rx_ring_base(addr);
            return;
        }
        let low = regs::RDSAR_Q1_LOW_8125 + (queue_id - 1) * 8;
        self.bar.write32(addr as u32, low);
        self.bar.write32((addr >> 32) as u32, low + 4);
    }

    /// Set the maximum RX frame size the chip accepts.
    pub(crate) fn set_rx_max_size(&self, sz: u16) {
        self.bar.write16(sz, regs::RX_MAX_SIZE);
    }

    /// Write the Receive Configuration Register.
    pub(crate) fn set_rcr(&self, value: u32) {
        self.bar.write32(value, regs::RCR);
    }

    /// Read the Receive Configuration Register.
    pub(crate) fn rcr(&self) -> u32 {
        self.bar.read32(regs::RCR)
    }

    /// Trigger a hardware tally-counter DMA dump into the coherent buffer at
    /// `handle` (8-byte aligned), then poll for completion. Returns true if the
    /// dump finished, false on timeout. The C bridge owns the buffer alloc and
    /// reads the dumped struct; this only drives the MMIO handshake. Mirrors
    /// vendor `rtl8125_dump_tally_counter`.
    pub(crate) fn dump_tally(&self, handle: u64) -> bool {
        let low = (handle as u32) & !0x7;
        self.bar
            .write32((handle >> 32) as u32, regs::COUNTER_ADDR_HIGH);
        self.bar.write32(low, regs::COUNTER_ADDR_LOW);
        self.bar
            .write32(low | regs::COUNTER_DUMP, regs::COUNTER_ADDR_LOW);
        let step = Delta::from_micros(10);
        for _ in 0..200 {
            udelay(step);
            if self.bar.read32(regs::COUNTER_ADDR_LOW) & regs::COUNTER_DUMP == 0 {
                return true;
            }
        }
        false
    }

    /// Write the 64-bit multicast hash filter (MAR0/MAR4). `low` goes to 0x08,
    /// `high` to 0x0C. Callers pass the values already in hardware word order
    /// (see `layout::mar_words`).
    pub(crate) fn set_mar(&self, low: u32, high: u32) {
        self.bar.write32(low, regs::MAR0);
        self.bar.write32(high, regs::MAR4);
    }

    /// Write CPlusCmd.
    pub(crate) fn set_cpluscmd(&self, value: u16) {
        self.bar.write16(value, regs::CPLUSCMD);
    }

    /// Enable/disable IRQ sources via the Interrupt Mask Register.
    /// **32-bit on 8125** (was 16-bit on 8169 — see `regs.rs` doc).
    pub(crate) fn set_imr(&self, mask: u32) {
        self.bar.write32(mask, regs::IMR);
    }

    /// Read the Interrupt Status Register (which sources fired). 32-bit.
    pub(crate) fn isr(&self) -> u32 {
        self.bar.read32(regs::ISR)
    }

    /// Read back IMR — diagnostic only; production code should not need it.
    pub(crate) fn imr_readback(&self) -> u32 {
        self.bar.read32(regs::IMR)
    }

    /// Clear the given ISR bits (W1C). 32-bit.
    pub(crate) fn ack_isr(&self, bits: u32) {
        self.bar.write32(bits, regs::ISR);
    }

    // ── ISR_V2 / IMR_V2 (V2 register surface) ───────────────────────────
    //
    // The four methods below are the V2 counterparts of the legacy
    // `isr`/`set_imr`/`ack_isr` window. `ndo_open` selects between the
    // two via `state.irq_mode()`; `ndo_stop` writes BOTH (idempotent —
    // V2 writes are no-ops while the chip is in legacy mode and vice
    // versa). The IRQ handler reads one or the other depending on mode.

    /// Unmask the given message_id bits (write to IMR_V2_SET).
    pub(crate) fn set_imr_v2_mask(&self, bits: u32) {
        self.bar.write32(bits, regs::IMR_V2_SET);
    }

    /// Mask the given message_id bits (write to IMR_V2_CLEAR).
    pub(crate) fn clear_imr_v2_mask(&self, bits: u32) {
        self.bar.write32(bits, regs::IMR_V2_CLEAR);
    }

    /// Read which V2 message_ids have fired.
    pub(crate) fn isr_v2(&self) -> u32 {
        self.bar.read32(regs::ISR_V2)
    }

    /// Acknowledge V2 message_id bits (W1C).
    pub(crate) fn ack_isr_v2(&self, bits: u32) {
        self.bar.write32(bits, regs::ISR_V2);
    }

    /// Kick the TX engine after posting one or more descriptors. On 8125
    /// this is a 16-bit write to TxPoll_8125 (0x90) with `NPQ = BIT(0)`.
    pub(crate) fn tx_poll(&self) {
        self.bar.write16(regs::TPPOLL_NPQ, regs::TPPOLL);
    }

    /// Read `INT_CFG0_8125` (0x34, 8-bit).
    pub(crate) fn int_cfg0(&self) -> u8 {
        self.bar.read8(regs::INT_CFG0)
    }

    /// Write `INT_CFG0_8125` (0x34, 8-bit). 0x00 disables interrupt-config
    /// modes baseline.
    pub(crate) fn set_int_cfg0(&self, value: u8) {
        self.bar.write8(value, regs::INT_CFG0);
    }

    /// Set or clear only the `INT_CFG0_ENABLE_8125` bit (the V2 ISR/IMR
    /// surface toggle), preserving every other `INT_CFG0` bit.
    pub(crate) fn set_int_cfg0_v2_enable(&self, enable: bool) -> u8 {
        let cur = self.int_cfg0();
        let next = if enable {
            cur | regs::INT_CFG0_ENABLE_8125
        } else {
            cur & !regs::INT_CFG0_ENABLE_8125
        };
        self.bar.write8(next, regs::INT_CFG0);
        self.int_cfg0()
    }

    /// Diagnostic read of `IMR_V2_SET` (0x0D0C).
    ///
    /// This register uses write-to-set unmask semantics; on RTL8125B/KVM it
    /// can read back as zero even after the baseline mask has been accepted
    /// and interrupts can fire. Treat the value as evidence only, not as a
    /// latched-mask truth source.
    pub(crate) fn imr_v2_set_diagnostic(&self) -> u32 {
        self.bar.read32(regs::IMR_V2_SET)
    }

    /// Write `INT_CFG1_8125` (0x7A, 16-bit). RTL8125B baseline is 0x0000
    /// alongside the 0xa00 INT_MITI table.
    pub(crate) fn set_int_cfg1(&self, value: u16) {
        self.bar.write16(value, regs::INT_CFG1);
    }

    /// Read `PHYStatus_8125` (MMIO 0x6C, 8-bit). Bit 1 = LinkSts. We use
    /// it as a diagnostic; the kernel PHY framework is the authority.
    pub(crate) fn phy_status(&self) -> u8 {
        self.bar.read8(0x6C)
    }

    // ── Cfg9346 (8-bit at 0x50) — unlock the config registers ──────────

    /// Unlock Config1/2/5 (Cfg9346 = 0xC0). Must be balanced with `lock_config_regs`.
    pub(crate) fn unlock_config_regs(&self) {
        self.bar.write8(regs::CFG9346_UNLOCK, regs::CFG9346);
    }

    /// Re-lock Config1/2/5 (Cfg9346 = 0x00).
    pub(crate) fn lock_config_regs(&self) {
        self.bar.write8(regs::CFG9346_LOCK, regs::CFG9346);
    }

    // ── Config1 (8-bit at 0x52) ─────────────────────────────────────────

    pub(crate) fn config1(&self) -> u8 {
        self.bar.read8(regs::CONFIG1)
    }

    pub(crate) fn set_config1(&self, value: u8) {
        self.bar.write8(value, regs::CONFIG1);
    }

    // ── Config3 (8-bit at 0x54) — L2/L3 readiness ───────────────────────

    pub(crate) fn config3(&self) -> u8 {
        self.bar.read8(regs::CONFIG3)
    }

    pub(crate) fn set_config3(&self, value: u8) {
        self.bar.write8(value, regs::CONFIG3);
    }

    // ── Config5 (8-bit at 0x56) — ASPM enable ───────────────────────────

    pub(crate) fn config5(&self) -> u8 {
        self.bar.read8(regs::CONFIG5)
    }

    pub(crate) fn set_config5(&self, value: u8) {
        self.bar.write8(value, regs::CONFIG5);
    }

    // ── 8125 multi-queue / RSS disable (TSO) ───────────────────────────

    /// `RSS_CTRL_8125` (32-bit at 0x4500). Write 0 to disable.
    pub(crate) fn set_rss_ctrl_8125(&self, value: u32) {
        self.bar.write32(value, regs::RSS_CTRL_8125);
    }

    /// `Q_NUM_CTRL_8125` (16-bit at 0x4800) RX-queue-count field (bits 2..4).
    /// Read-modify-write preserving the other bits, matching vendor
    /// `rtl8125_set_rx_q_num`. `q_num_bits` is the pre-shifted `ilog2(n)` value
    /// from `layout::rss_q_num_ctrl` (0 ⇒ single queue).
    pub(crate) fn set_q_num_ctrl_8125(&self, q_num_bits: u16) {
        const Q_NUM_FIELD: u16 = 0x001C; // bits 2,3,4
        let cur = self.bar.read16(regs::Q_NUM_CTRL_8125);
        self.bar.write16(
            (cur & !Q_NUM_FIELD) | (q_num_bits & Q_NUM_FIELD),
            regs::Q_NUM_CTRL_8125,
        );
    }

    /// Write the 40-byte RSS hash key (10 dwords at 0x4600).
    /// Matches vendor `rtl8125_store_rss_key` (dword writes, low byte first).
    pub(crate) fn set_rss_key_8125(&self, key: &[u8; regs::RSS_KEY_SIZE]) {
        let mut i = 0;
        while i < regs::RSS_KEY_SIZE {
            // Pure little-endian packing lives in `crate::layout` (host-tested).
            let w = crate::layout::key_word([key[i], key[i + 1], key[i + 2], key[i + 3]]);
            self.bar.write32(w, regs::RSS_KEY_8125 + i);
            i += 4;
        }
    }

    /// Zero the RSS indirection table (128 buckets, 4-per-dword = 32 dwords) so
    /// every hash bucket maps to queue 0.
    pub(crate) fn clear_rss_indir_8125(&self) {
        let mut off = 0;
        while off < crate::layout::RSS_INDIR_TBL_ENTRIES {
            self.bar.write32(0, regs::RSS_INDIRECTION_TBL_8125 + off);
            off += 4;
        }
    }

    /// Program the RSS indirection table using Linux's default bucket mapping.
    /// RTL8125 stores four one-byte queue entries per dword; the lane packing is
    /// the host-tested `crate::layout::indir_word`.
    pub(crate) fn set_rss_indir_default_8125(&self, queue_count: u8) {
        if queue_count == 0 {
            self.clear_rss_indir_8125();
            return;
        }

        let entries_total = crate::layout::RSS_INDIR_TBL_ENTRIES as u32;
        let qc = u32::from(queue_count);
        let mut bucket = 0u32;
        while bucket < entries_total {
            let entries = [
                unsafe_boundary::rxfh_indir_default(bucket, qc) as u8,
                unsafe_boundary::rxfh_indir_default(bucket + 1, qc) as u8,
                unsafe_boundary::rxfh_indir_default(bucket + 2, qc) as u8,
                unsafe_boundary::rxfh_indir_default(bucket + 3, qc) as u8,
            ];
            self.bar.write32(
                crate::layout::indir_word(entries),
                regs::RSS_INDIRECTION_TBL_8125 + bucket as usize,
            );
            bucket += 4;
        }
    }

    // ── Generic small-region accessors used by hw_start_8125b ───────────

    /// Read a 16-bit register at an arbitrary BAR offset. Used by the
    /// 8125B init sequence which pokes one-off offsets like 0x1880.
    pub(crate) fn read_u16_at(&self, offset: usize) -> u16 {
        self.bar.read16(offset)
    }

    /// Write a 16-bit register at an arbitrary BAR offset.
    pub(crate) fn write_u16_at(&self, offset: usize, value: u16) {
        self.bar.write16(value, offset);
    }

    // ── MAC OCP — internal MAC register access (8125 family) ────────────
    //
    // Unlike GPHY OCP (which polls OCPAR_FLAG), MAC OCP writes complete
    // synchronously: write to OCPDR, the chip latches; reads return the
    // value on the next read of OCPDR.

    pub(crate) fn mac_ocp_write(&self, reg: u32, data: u16) {
        let cmd = regs::OCPAR_FLAG | ((reg & 0xFFFF) << 15) | u32::from(data);
        self.bar.write32(cmd, regs::OCPDR);
    }

    pub(crate) fn mac_ocp_read(&self, reg: u32) -> u16 {
        self.bar.write32((reg & 0xFFFF) << 15, regs::OCPDR);
        (self.bar.read32(regs::OCPDR) & 0xFFFF) as u16
    }

    /// Read-modify-write helper. `mask` is the bit set to clear before
    /// applying `set`. Mirrors r8169 `r8168_mac_ocp_modify`.
    pub(crate) fn mac_ocp_modify(&self, reg: u32, mask: u16, set: u16) {
        let cur = self.mac_ocp_read(reg);
        self.mac_ocp_write(reg, (cur & !mask) | set);
    }

    // ── MISC (0xF0) — for rtl_disable_rxdvgate ──────────────────────────

    pub(crate) fn misc(&self) -> u32 {
        self.bar.read32(regs::MISC)
    }

    pub(crate) fn set_misc(&self, value: u32) {
        self.bar.write32(value, regs::MISC);
    }

    // ── GPHY OCP — PHY register access path (8125 family) ───────────────

    /// Write a 16-bit value to a PHY OCP register. `ocp_addr` is the
    /// 16-bit OCP address (already includes the page base — i.e.
    /// `OCP_STD_PHY_BASE + mii_reg * 2`). Polls up to ~25×10 µs for the
    /// transaction to complete.
    ///
    /// Returns `Err(EIO)` on timeout (the chip never cleared OCPAR_FLAG).
    pub(crate) fn gphy_ocp_write(&self, ocp_addr: u32, data: u16) -> kernel::error::Result<()> {
        // OCPAR_FLAG | (ocp_addr << 15) | data
        let cmd = regs::OCPAR_FLAG | ((ocp_addr & 0xFFFF) << 15) | u32::from(data);
        self.bar.write32(cmd, regs::GPHY_OCP);
        let step = Delta::from_micros(10);
        for _ in 0..25 {
            udelay(step);
            if self.bar.read32(regs::GPHY_OCP) & regs::OCPAR_FLAG == 0 {
                return Ok(());
            }
        }
        Err(kernel::error::code::EIO)
    }

    /// Read a 16-bit value from a PHY OCP register. See `gphy_ocp_write`.
    pub(crate) fn gphy_ocp_read(&self, ocp_addr: u32) -> kernel::error::Result<u16> {
        let cmd = (ocp_addr & 0xFFFF) << 15;
        self.bar.write32(cmd, regs::GPHY_OCP);
        let step = Delta::from_micros(10);
        for _ in 0..25 {
            udelay(step);
            let v = self.bar.read32(regs::GPHY_OCP);
            if v & regs::OCPAR_FLAG != 0 {
                return Ok((v & 0xFFFF) as u16);
            }
        }
        Err(kernel::error::code::EIO)
    }

    /// MDIO-style PHY read: convert MII reg to OCP address using the
    /// caller-supplied `ocp_base` (default = `OCP_STD_PHY_BASE`). On
    /// non-default pages r8169 subtracts 0x10 from the reg (see
    /// `r8168g_mdio_read`).
    pub(crate) fn mdio_read(&self, ocp_base: u32, reg: u8) -> kernel::error::Result<u16> {
        let reg_adj = if ocp_base != regs::OCP_STD_PHY_BASE && reg >= 0x10 {
            reg - 0x10
        } else {
            reg
        };
        self.gphy_ocp_read(ocp_base + u32::from(reg_adj) * 2)
    }

    /// MDIO-style PHY write — same page logic as `mdio_read`.
    pub(crate) fn mdio_write(&self, ocp_base: u32, reg: u8, val: u16) -> kernel::error::Result<()> {
        let reg_adj = if ocp_base != regs::OCP_STD_PHY_BASE && reg >= 0x10 {
            reg - 0x10
        } else {
            reg
        };
        self.gphy_ocp_write(ocp_base + u32::from(reg_adj) * 2, val)
    }

    /// Zero the per-MAC_VER_63 interrupt-coalescing table:
    /// `0xa00..0xa80` step 4 (32-bit writes). Mirrors r8169
    /// `rtl_hw_start_8125` for VER_63 / VER_70.
    pub(crate) fn zero_coalesce_table_8125b(&self) {
        let mut off = regs::COALESCE_TABLE_8125B_START;
        while off < regs::COALESCE_TABLE_8125B_END {
            self.bar.write32(0u32, off);
            off += 4;
        }
    }

    /// Program one RTL8125B INT_MITI vector's moderation timers. Vendor names
    /// the registers `INT_MITI_V2_*`, but the timer table applies to the 8125
    /// interrupt block before the driver selects either the legacy or V2
    /// ISR/IMR surface.
    #[inline]
    pub(crate) fn set_coalesce_8125b_vector(
        &self,
        vector: u32,
        rx_timer: u16,
        tx_timer: u16,
    ) -> (u16, u16) {
        let base = regs::INT_MITI_V2_0_RX + (vector as usize * 8);
        let tx_offset = regs::INT_MITI_V2_0_TX - regs::INT_MITI_V2_0_RX;
        self.bar.write16(rx_timer, base);
        self.bar.write16(tx_timer, base + tx_offset);
        (self.bar.read16(base), self.bar.read16(base + tx_offset))
    }

    /// Program RTL8125B INT_MITI vector 0 moderation. Vendor names the registers
    /// `INT_MITI_V2_*`, but the timer table applies to the 8125 interrupt block
    /// before the driver selects either the legacy or V2 ISR/IMR surface.
    /// Returns immediate RX/TX timer readbacks for diagnostics.
    pub(crate) fn set_coalesce_8125b(&self, rx_timer: u16, tx_timer: u16) -> (u16, u16) {
        self.zero_coalesce_table_8125b();
        self.set_coalesce_8125b_vector(regs::V2_RX_Q0_VECTOR, rx_timer, tx_timer)
    }
}
