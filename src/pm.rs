// SPDX-License-Identifier: GPL-2.0
//! Power-management surface for the ASPM **probe-time log line**, plus a
//! recorded deferral for full cap-list walk and
//! `pci_disable_link_state()`-style policy enforcement.
//!
//! ## What works today
//!
//! `kernel::pci::Device::config_space()` returns a [`ConfigSpace`] with
//! **infallible**, compile-time-bound-checked `read8`/`read16`/`read32`
//! methods. With **const** offsets these are completely safe and incur no
//! runtime overhead. Reading PCI Status (offset 0x06) tells us whether the
//! device exposes a capability list, which is the only ASPM bit we can
//! capture in pure safe Rust today.
//!
//! ## What does NOT work today (recorded gap — plan §13)
//!
//! Walking the PCI capability list to find the PCIe capability requires
//! **runtime** offsets (each `next` pointer is read at runtime), and
//! `ConfigSpace`'s `read*` are const-bound-checked while its `try_read*`
//! fall through to the `Io` trait's default which is `build_error!()`. The
//! C-side helper `bindings::pci_find_capability` does the right thing, but
//! taking it would require a `*mut pci_dev`, which the kernel Rust API does
//! not expose to out-of-tree crates (`pci::Device::as_raw()` is private).
//!
//! Mirror situation on the policy side: `pci_disable_link_state()` is not
//! yet exposed as a `kernel::pci` abstraction.
//!
//! Do not claim host-side ASPM policy enforcement until either the upstream
//! `kernel::pci` API exposes the necessary surface or this driver adds a
//! small audited C shim wrapper for it.

use kernel::io::Io;
use kernel::pci;
use kernel::prelude::*;

/// PCI Status register (config space byte 0x06).
const PCI_STATUS: usize = 0x06;
/// `CAP_LIST` bit in PCI Status — set means the device exposes a capability
/// list, which is where ASPM advertisement lives.
const PCI_STATUS_CAP_LIST: u16 = 0x10;

/// Log a single dmesg line about ASPM at probe time. The actual cap-list walk
/// is still deferred (see this file's module doc for why). The log records
/// what we *can* see (Status + CAP_LIST bit) and explicitly states that the
/// policy step is deferred so reviewers see the gap rather than miss it.
pub(crate) fn log_aspm(pdev: &pci::Device<kernel::device::Bound>) {
    let status = pdev.config_space().read16(PCI_STATUS);
    let cap_list = (status & PCI_STATUS_CAP_LIST) != 0;
    dev_info!(
        pdev,
        "ASPM: PCI Status=0x{:04x} CAP_LIST={} — cap-list walk + policy deferred until kernel::pci or cshim exposes ASPM control (no fallible config read and no ASPM API yet; see src/pm.rs)\n",
        status,
        u8::from(cap_list)
    );
}
