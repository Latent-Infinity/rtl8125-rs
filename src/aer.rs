// SPDX-License-Identifier: GPL-2.0
//! PCIe Advanced Error Reporting (AER) recovery policy — pure and host-testable.
//!
//! The kernel-facing AER callbacks (`error_detected` / `slot_reset` / `resume`)
//! live in [`crate::pci`]; this module holds only the *decision* they make, as
//! plain data so it can be unit-tested off-target. The `pci_error_handlers`
//! ABI passes/returns small C enums (`pci_channel_state_t` /
//! `pci_ers_result_t`); we mirror them as Rust enums with the values pinned to
//! the kernel ABI (`include/linux/pci.h`). [`crate::pci`] carries a
//! compile-time assert tying these values to the real `bindings::` constants on
//! a kernel build, so a future ABI renumber is caught at build time rather than
//! silently mis-reported to the AER core.
//!
//! Policy follows `igb_io_error_detected` rather than `igc`: a permanent failure
//! is unrecoverable (Disconnect), a *fatal/frozen* channel requests a slot reset
//! (NeedReset), but a *non-fatal* channel recovers in place (CanRecover) WITHOUT
//! asking the core for another reset. That distinction is load-bearing on this
//! controller: its only `reset_method` is a secondary-bus reset, and the chip
//! emits an Uncorrectable (non-fatal) error on every bus reset — so returning
//! NeedReset for a non-fatal error makes the AER core reset the slot, which
//! re-triggers the same error, an endless reset storm (observed 2026-06-18).
//! CanRecover skips the reset; the core still calls `resume`, which is a no-op
//! unless `error_detected` tore the device down. Frozen/unknown channels get a
//! full stop and are re-opened in `resume`. Permanent failure is detach-only: the
//! core returns Disconnect and may not call `resume`, so remove owns final
//! teardown.

/// PCI channel state reported to `error_detected` (`pci_channel_state_t`).
/// Values pinned to `enum pci_channel_state` in `include/linux/pci.h`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ChannelState {
    /// `pci_channel_io_normal` (1) — I/O still works (non-fatal error).
    Normal,
    /// `pci_channel_io_frozen` (2) — I/O blocked; slot reset required (fatal).
    Frozen,
    /// `pci_channel_io_perm_failure` (3) — device is permanently dead.
    PermFailure,
    /// Anything the kernel adds later — treated conservatively (see policy).
    Unknown(u32),
}

impl ChannelState {
    /// Decode the raw `pci_channel_state_t` the AER core passes in.
    pub(crate) const fn from_raw(v: u32) -> Self {
        match v {
            1 => Self::Normal,
            2 => Self::Frozen,
            3 => Self::PermFailure,
            other => Self::Unknown(other),
        }
    }
}

/// Recovery verdict returned to the AER core (`pci_ers_result_t`).
/// Values pinned to `enum pci_ers_result` in `include/linux/pci.h`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum ErsResult {
    /// `PCI_ERS_RESULT_NONE` (1).
    None,
    /// `PCI_ERS_RESULT_CAN_RECOVER` (2).
    CanRecover,
    /// `PCI_ERS_RESULT_NEED_RESET` (3).
    NeedReset,
    /// `PCI_ERS_RESULT_DISCONNECT` (4).
    Disconnect,
    /// `PCI_ERS_RESULT_RECOVERED` (5).
    Recovered,
}

impl ErsResult {
    /// Encode to the raw `pci_ers_result_t` the AER core expects back.
    pub(crate) const fn to_raw(self) -> u32 {
        match self {
            Self::None => 1,
            Self::CanRecover => 2,
            Self::NeedReset => 3,
            Self::Disconnect => 4,
            Self::Recovered => 5,
        }
    }
}

/// Map a reported channel state to the verdict we return from `error_detected`.
///
/// - `Normal` (non-fatal) → `CanRecover`: recover in place. Crucially we do NOT
///   return `NeedReset` here — on this controller a slot reset *is* a
///   secondary-bus reset, which the chip answers with another non-fatal error,
///   so `NeedReset` for a non-fatal channel loops forever. The core still runs
///   `resume`, which re-inits the device via the balanced open path.
/// - `Frozen` (fatal) → `NeedReset`: I/O is blocked; only a slot reset can clear
///   it, after which `slot_reset` + `resume` rebuild the device.
/// - `PermFailure` → `Disconnect`: the device is gone; don't fight it.
/// - `Unknown` → `NeedReset`: conservative — treat an unrecognised state as
///   needing the strongest non-terminal recovery.
pub(crate) fn aer_policy(state: ChannelState) -> ErsResult {
    match state {
        ChannelState::Normal => ErsResult::CanRecover,
        ChannelState::Frozen | ChannelState::Unknown(_) => ErsResult::NeedReset,
        ChannelState::PermFailure => ErsResult::Disconnect,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn channel_state_decodes_kernel_abi() {
        assert_eq!(ChannelState::from_raw(1), ChannelState::Normal);
        assert_eq!(ChannelState::from_raw(2), ChannelState::Frozen);
        assert_eq!(ChannelState::from_raw(3), ChannelState::PermFailure);
        assert_eq!(ChannelState::from_raw(0), ChannelState::Unknown(0));
        assert_eq!(ChannelState::from_raw(99), ChannelState::Unknown(99));
    }

    #[test]
    fn ers_result_encodes_kernel_abi() {
        assert_eq!(ErsResult::None.to_raw(), 1);
        assert_eq!(ErsResult::CanRecover.to_raw(), 2);
        assert_eq!(ErsResult::NeedReset.to_raw(), 3);
        assert_eq!(ErsResult::Disconnect.to_raw(), 4);
        assert_eq!(ErsResult::Recovered.to_raw(), 5);
    }

    #[test]
    fn policy_permfailure_disconnects() {
        assert_eq!(aer_policy(ChannelState::PermFailure), ErsResult::Disconnect);
    }

    #[test]
    fn policy_normal_recovers_in_place_no_reset() {
        // The anti-reset-storm invariant: a non-fatal channel must NOT request a
        // reset (this controller errors on every bus reset → endless loop).
        assert_eq!(aer_policy(ChannelState::Normal), ErsResult::CanRecover);
        assert_ne!(aer_policy(ChannelState::Normal), ErsResult::NeedReset);
    }

    #[test]
    fn policy_frozen_requests_reset() {
        assert_eq!(aer_policy(ChannelState::Frozen), ErsResult::NeedReset);
        assert_eq!(aer_policy(ChannelState::Unknown(7)), ErsResult::NeedReset);
    }

    #[test]
    fn policy_never_silently_drops_an_error() {
        // No reachable channel state maps to the true no-op verdict (None): every
        // error drives a real recovery action (reset, in-place recover, or
        // disconnect) and the core runs `resume` for all but Disconnect.
        for raw in 0u32..8 {
            let verdict = aer_policy(ChannelState::from_raw(raw));
            assert_ne!(
                verdict,
                ErsResult::None,
                "raw {raw} produced a no-op verdict"
            );
        }
    }
}
