// SPDX-License-Identifier: GPL-2.0
//! RTL8125B PHY MCU firmware (`rtl_nic/rtl8125b-2.fw`) decode + opcode
//! interpreter — a faithful, **host-tested** port of mainline
//! `r8169_firmware.c` (`rtl_fw_format_ok` + `rtl_fw_data_ok` +
//! `rtl_fw_write_firmware`).
//!
//! The blob is a list of 32-bit opcodes that drive PHY MDIO and MAC-OCP "MCU"
//! register writes. **Critically, the stream has two targets**: a `PHY_MDIO_CHG`
//! opcode switches subsequent writes between the PHY (paged MDIO) and the MAC-OCP
//! MCU register space (the blob starts on MAC-OCP and switches to PHY partway
//! through). A PHY-only interpreter would corrupt the chip — so the interpreter
//! is generic over a [`FwSink`] that the kernel applier (`crate::phy`) implements
//! with the correct per-target register access; the whole control-flow + decode +
//! validation logic here is kernel-free and unit-tested.
//!
//! Only the checksummed (`magic == 0`) container the real blob uses is exercised
//! on hardware; the raw format is supported for completeness. The full blob is
//! validated (`parse`) before any register is touched, exactly like r8169.
#![allow(dead_code)]

/// Firmware file requested via `request_firmware` (also the `MODULE_FIRMWARE`).
pub(crate) const FW_NAME: &str = "rtl_nic/rtl8125b-2.fw";

const FW_OPCODE_SIZE: usize = 4;
/// `sizeof(struct fw_info)` packed: u32 magic + [u8;32] version + le32 fw_start +
/// le32 fw_len + u8 chksum.
const FW_INFO_SIZE: usize = 45;
const VER_OFF: usize = 4;
pub(crate) const VER_LEN: usize = 32;
const FW_START_OFF: usize = 36;
const FW_LEN_OFF: usize = 40;

// Opcode nibble (action >> 28), values from `enum rtl_fw_opcode`.
const PHY_READ: u32 = 0x0;
const PHY_DATA_OR: u32 = 0x1;
const PHY_DATA_AND: u32 = 0x2;
const PHY_BJMPN: u32 = 0x3;
const PHY_MDIO_CHG: u32 = 0x4;
const PHY_CLEAR_READCOUNT: u32 = 0x7;
const PHY_WRITE: u32 = 0x8;
const PHY_READCOUNT_EQ_SKIP: u32 = 0x9;
const PHY_COMP_EQ_SKIPN: u32 = 0xa;
const PHY_COMP_NEQ_SKIPN: u32 = 0xb;
const PHY_WRITE_PREVIOUS: u32 = 0xc;
const PHY_SKIPN: u32 = 0xd;
const PHY_DELAY_MS: u32 = 0xe;

/// Which register space a write/read currently targets (toggled by `PHY_MDIO_CHG`).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum FwTarget {
    /// Paged PHY MDIO (`r8168g_mdio_write` semantics, incl. the 0x1f page reg).
    Phy,
    /// MAC-OCP MCU space (`mac_mcu_write` semantics, incl. the 0x1f page reg).
    MacMcu,
}

/// Reason a firmware blob was rejected (mirrors r8169's format/data checks).
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub(crate) enum FwError {
    TooSmall,
    BadChecksum,
    BadStart,
    BadLen,
    BadOpcode,
    OutOfRange,
}

/// A validated firmware: a borrow of the opcode region + its length + version.
pub(crate) struct ParsedFw<'a> {
    code: &'a [u8],
    size: usize,
    version: [u8; VER_LEN],
}

impl ParsedFw<'_> {
    pub(crate) fn size(&self) -> usize {
        self.size
    }

    /// NUL-padded version string bytes (for ethtool `fw_version`).
    pub(crate) fn version(&self) -> &[u8; VER_LEN] {
        &self.version
    }

    #[inline]
    fn op(&self, i: usize) -> u32 {
        let b = i * 4;
        u32::from_le_bytes([
            self.code[b],
            self.code[b + 1],
            self.code[b + 2],
            self.code[b + 3],
        ])
    }
}

/// Decode + fully validate a firmware blob before any register access
/// (`rtl_fw_format_ok` + `rtl_fw_data_ok`). Returns the opcode view on success.
pub(crate) fn parse(fw: &[u8]) -> Result<ParsedFw<'_>, FwError> {
    if fw.len() < FW_OPCODE_SIZE {
        return Err(FwError::TooSmall);
    }
    let magic = u32::from_le_bytes([fw[0], fw[1], fw[2], fw[3]]);

    let parsed = if magic == 0 {
        if fw.len() < FW_INFO_SIZE {
            return Err(FwError::TooSmall);
        }
        // checksum: every byte of the file sums (mod 256) to zero.
        let mut sum: u8 = 0;
        for &b in fw {
            sum = sum.wrapping_add(b);
        }
        if sum != 0 {
            return Err(FwError::BadChecksum);
        }
        let start = u32::from_le_bytes([
            fw[FW_START_OFF],
            fw[FW_START_OFF + 1],
            fw[FW_START_OFF + 2],
            fw[FW_START_OFF + 3],
        ]) as usize;
        if start > fw.len() {
            return Err(FwError::BadStart);
        }
        let size = u32::from_le_bytes([
            fw[FW_LEN_OFF],
            fw[FW_LEN_OFF + 1],
            fw[FW_LEN_OFF + 2],
            fw[FW_LEN_OFF + 3],
        ]) as usize;
        if size > (fw.len() - start) / FW_OPCODE_SIZE {
            return Err(FwError::BadLen);
        }
        let mut version = [0u8; VER_LEN];
        version.copy_from_slice(&fw[VER_OFF..VER_OFF + VER_LEN]);
        ParsedFw {
            code: &fw[start..start + size * FW_OPCODE_SIZE],
            size,
            version,
        }
    } else {
        if !fw.len().is_multiple_of(FW_OPCODE_SIZE) {
            return Err(FwError::BadLen);
        }
        ParsedFw {
            code: fw,
            size: fw.len() / FW_OPCODE_SIZE,
            version: [0u8; VER_LEN],
        }
    };

    data_ok(&parsed)?;
    Ok(parsed)
}

/// Bounds + opcode validity check (`rtl_fw_data_ok`): every jump/skip stays in
/// range and every opcode is known, so the interpreter cannot run off the end.
fn data_ok(p: &ParsedFw<'_>) -> Result<(), FwError> {
    for index in 0..p.size {
        let action = p.op(index);
        let val = action & 0x0000ffff;
        let regno = ((action & 0x0fff0000) >> 16) as usize;
        match action >> 28 {
            PHY_READ | PHY_DATA_OR | PHY_DATA_AND | PHY_CLEAR_READCOUNT | PHY_WRITE
            | PHY_WRITE_PREVIOUS | PHY_DELAY_MS => {}
            PHY_MDIO_CHG => {
                if val > 1 {
                    return Err(FwError::OutOfRange);
                }
            }
            PHY_BJMPN => {
                if regno > index {
                    return Err(FwError::OutOfRange);
                }
            }
            PHY_READCOUNT_EQ_SKIP => {
                if index + 2 >= p.size {
                    return Err(FwError::OutOfRange);
                }
            }
            PHY_COMP_EQ_SKIPN | PHY_COMP_NEQ_SKIPN | PHY_SKIPN => {
                if index + 1 + regno >= p.size {
                    return Err(FwError::OutOfRange);
                }
            }
            _ => return Err(FwError::BadOpcode),
        }
    }
    Ok(())
}

/// Per-target register access the interpreter drives. The kernel applier
/// implements this over the chip (PHY MDIO + MAC-OCP); host tests implement a
/// recording mock. `reg`/`val` are raw — the implementer applies the
/// `r8168g_mdio_write` / `mac_mcu_write` page (0x1f) + offset semantics.
pub(crate) trait FwSink {
    fn write(&mut self, target: FwTarget, reg: u16, val: u16);
    fn read(&mut self, target: FwTarget, reg: u16) -> u16;
    fn delay_ms(&mut self, ms: u16);
}

/// Run a validated firmware (`rtl_fw_write_firmware`). The index arithmetic
/// mirrors the C `size_t` for-loop exactly (wrapping on the jump opcodes; the
/// trailing `+1` is the for-loop's post-increment), which `data_ok` has already
/// proven stays in range.
pub(crate) fn run<S: FwSink>(p: &ParsedFw<'_>, sink: &mut S) {
    let mut predata: i32 = 0;
    let mut count: i32 = 0;
    let mut target = FwTarget::Phy;
    let mut index: usize = 0;

    while index < p.size {
        let action = p.op(index);
        let data = (action & 0x0000ffff) as u16;
        let regno = ((action & 0x0fff0000) >> 16) as usize;
        match action >> 28 {
            PHY_READ => {
                predata = i32::from(sink.read(target, regno as u16));
                count += 1;
            }
            PHY_DATA_OR => predata |= i32::from(data),
            PHY_DATA_AND => predata &= i32::from(data),
            PHY_BJMPN => index = index.wrapping_sub(regno + 1),
            PHY_MDIO_CHG => {
                target = if data != 0 {
                    FwTarget::MacMcu
                } else {
                    FwTarget::Phy
                }
            }
            PHY_CLEAR_READCOUNT => count = 0,
            PHY_WRITE => sink.write(target, regno as u16, data),
            PHY_READCOUNT_EQ_SKIP => {
                if count == i32::from(data) {
                    index = index.wrapping_add(1);
                }
            }
            PHY_COMP_EQ_SKIPN => {
                if predata == i32::from(data) {
                    index = index.wrapping_add(regno);
                }
            }
            PHY_COMP_NEQ_SKIPN => {
                if predata != i32::from(data) {
                    index = index.wrapping_add(regno);
                }
            }
            PHY_WRITE_PREVIOUS => sink.write(target, regno as u16, predata as u16),
            PHY_SKIPN => index = index.wrapping_add(regno),
            PHY_DELAY_MS => sink.delay_ms(data),
            _ => {} // unreachable: data_ok rejected unknown opcodes.
        }
        index = index.wrapping_add(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build one opcode word: nibble | regno(12) | data(16).
    fn op(opcode: u32, regno: u16, data: u16) -> u32 {
        (opcode << 28) | ((regno as u32 & 0x0fff) << 16) | data as u32
    }

    /// Wrap an opcode list into a checksummed (magic==0) container.
    fn blob(ops: &[u32]) -> Vec<u8> {
        let mut v = Vec::new();
        v.extend_from_slice(&0u32.to_le_bytes()); // magic = 0
        v.extend_from_slice(&[0u8; VER_LEN]); // version
        v.extend_from_slice(&(FW_INFO_SIZE as u32).to_le_bytes()); // fw_start
        v.extend_from_slice(&(ops.len() as u32).to_le_bytes()); // fw_len
        v.push(0); // chksum placeholder
        for o in ops {
            v.extend_from_slice(&o.to_le_bytes());
        }
        // Fix the checksum byte so the whole file sums to 0 (mod 256).
        let s: u8 = v.iter().fold(0u8, |a, &b| a.wrapping_add(b));
        v[FW_INFO_SIZE - 1] = (0u8).wrapping_sub(s);
        v
    }

    struct Mock {
        events: Vec<(FwTarget, u16, u16)>,
        delays: Vec<u16>,
        read_val: u16,
    }
    impl FwSink for Mock {
        fn write(&mut self, t: FwTarget, reg: u16, val: u16) {
            self.events.push((t, reg, val));
        }
        fn read(&mut self, _t: FwTarget, _reg: u16) -> u16 {
            self.read_val
        }
        fn delay_ms(&mut self, ms: u16) {
            self.delays.push(ms);
        }
    }
    fn mock() -> Mock {
        Mock {
            events: Vec::new(),
            delays: Vec::new(),
            read_val: 0,
        }
    }

    #[test]
    fn parse_rejects_too_small_and_bad_checksum() {
        assert!(matches!(parse(&[0u8; 2]), Err(FwError::TooSmall)));
        // a magic==0 blob with a deliberately wrong checksum byte.
        let mut b = blob(&[op(PHY_WRITE, 0x10, 0x1234)]);
        b[FW_INFO_SIZE - 1] = b[FW_INFO_SIZE - 1].wrapping_add(1);
        assert!(matches!(parse(&b), Err(FwError::BadChecksum)));
    }

    #[test]
    fn parse_accepts_real_shaped_blob() {
        let b = blob(&[op(PHY_WRITE, 0x10, 0x1), op(PHY_DELAY_MS, 0, 5)]);
        let p = parse(&b).expect("valid");
        assert_eq!(p.size(), 2);
    }

    #[test]
    fn parse_rejects_unknown_opcode_and_out_of_range_jumps() {
        assert!(matches!(
            parse(&blob(&[op(0x5, 0, 0)])),
            Err(FwError::BadOpcode)
        ));
        // BJMPN with regno > index (index 0, regno 1).
        assert!(matches!(
            parse(&blob(&[op(PHY_BJMPN, 1, 0)])),
            Err(FwError::OutOfRange)
        ));
        // SKIPN running past the end.
        assert!(matches!(
            parse(&blob(&[op(PHY_SKIPN, 5, 0)])),
            Err(FwError::OutOfRange)
        ));
        // MDIO_CHG with data > 1.
        assert!(matches!(
            parse(&blob(&[op(PHY_MDIO_CHG, 0, 2)])),
            Err(FwError::OutOfRange)
        ));
    }

    #[test]
    fn run_switches_target_on_mdio_chg() {
        // start MAC-OCP, write, switch to PHY, write.
        let b = blob(&[
            op(PHY_MDIO_CHG, 0, 1), // -> MacMcu
            op(PHY_WRITE, 0x1f, 0xa01),
            op(PHY_WRITE, 0x10, 0x55),
            op(PHY_MDIO_CHG, 0, 0), // -> Phy
            op(PHY_WRITE, 0x1f, 0xa43),
            op(PHY_WRITE, 0x14, 0xaa),
        ]);
        let p = parse(&b).unwrap();
        let mut m = mock();
        run(&p, &mut m);
        assert_eq!(
            m.events,
            [
                (FwTarget::MacMcu, 0x1f, 0xa01),
                (FwTarget::MacMcu, 0x10, 0x55),
                (FwTarget::Phy, 0x1f, 0xa43),
                (FwTarget::Phy, 0x14, 0xaa),
            ]
        );
    }

    #[test]
    fn run_read_modify_write_previous() {
        let mut m = mock();
        m.read_val = 0x00f0;
        // READ -> predata=0x00f0; OR 0x0005 -> 0x00f5; AND 0x00ff -> 0x00f5;
        // WRITE_PREVIOUS reg 0x12 -> writes 0x00f5.
        let b = blob(&[
            op(PHY_READ, 0x11, 0),
            op(PHY_DATA_OR, 0, 0x0005),
            op(PHY_DATA_AND, 0, 0x00ff),
            op(PHY_WRITE_PREVIOUS, 0x12, 0),
        ]);
        let p = parse(&b).unwrap();
        run(&p, &mut m);
        assert_eq!(m.events, [(FwTarget::Phy, 0x12, 0x00f5)]);
    }

    #[test]
    fn run_skipn_skips_following_ops() {
        // SKIPN 1 skips the next op; the one after runs.
        let b = blob(&[
            op(PHY_SKIPN, 1, 0),
            op(PHY_WRITE, 0x10, 0xdead), // skipped
            op(PHY_WRITE, 0x11, 0xbeef), // runs
        ]);
        let p = parse(&b).unwrap();
        let mut m = mock();
        run(&p, &mut m);
        assert_eq!(m.events, [(FwTarget::Phy, 0x11, 0xbeef)]);
    }

    #[test]
    fn run_delay_ms_recorded() {
        let b = blob(&[op(PHY_DELAY_MS, 0, 7)]);
        let p = parse(&b).unwrap();
        let mut m = mock();
        run(&p, &mut m);
        assert_eq!(m.delays, [7]);
    }
}
