#!/usr/bin/env python3
# Apply the rust-pci AER recovery extension (error_detected / slot_reset /
# resume) to a kernel's rust/kernel/pci.rs. Must run AFTER the 0003 reset patch
# (it extends the ERR_HANDLER const that 0003 introduced).
import sys

p = sys.argv[1]
s = open(p).read()

# 1. ERR_HANDLER const: add the three AER callbacks next to reset_prepare/done.
a = (
    "        reset_prepare: Some(Self::reset_prepare_callback),\n"
    "        reset_done: Some(Self::reset_done_callback),\n"
)
assert s.count(a) == 1, "ERR_HANDLER reset fields anchor not found (apply 0003 first)"
s = s.replace(
    a,
    a
    + "        error_detected: Some(Self::error_detected_callback),\n"
    + "        slot_reset: Some(Self::slot_reset_callback),\n"
    + "        resume: Some(Self::error_resume_callback),\n",
)

# 2. AER thunks, appended after the reset_done_callback thunk.
a = "        T::reset_done(pdev, data);\n    }\n"
assert s.count(a) == 1, "reset_done_callback anchor not found"
cb = """        T::reset_done(pdev, data);
    }

    extern "C" fn error_detected_callback(
        pdev: *mut bindings::pci_dev,
        state: bindings::pci_channel_state_t,
    ) -> bindings::pci_ers_result_t {
        // SAFETY: the PCI core only calls error_detected with a valid `pci_dev*`.
        let pdev = unsafe { &*pdev.cast::<Device<device::CoreInternal>>() };
        // SAFETY: called between a successful probe and remove, so drvdata holds a `T`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        T::error_detected(pdev, data, state)
    }

    extern "C" fn slot_reset_callback(pdev: *mut bindings::pci_dev) -> bindings::pci_ers_result_t {
        // SAFETY: see `error_detected_callback`.
        let pdev = unsafe { &*pdev.cast::<Device<device::CoreInternal>>() };
        // SAFETY: see `error_detected_callback`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        T::slot_reset(pdev, data)
    }

    extern "C" fn error_resume_callback(pdev: *mut bindings::pci_dev) {
        // SAFETY: see `error_detected_callback`.
        let pdev = unsafe { &*pdev.cast::<Device<device::CoreInternal>>() };
        // SAFETY: see `error_detected_callback`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        T::error_resume(pdev, data);
    }
"""
s = s.replace(a, cb)

# 3. AER trait default methods, after the reset_done() trait method.
a = (
    "    fn reset_done(dev: &Device<device::Core>, this: Pin<&Self>) {\n"
    "        let _ = (dev, this);\n"
    "    }\n"
)
assert s.count(a) == 1, "reset_done trait-method anchor not found"
tm = a + """
    /// Called when a PCI bus error affecting this device is detected (AER step 1).
    /// `state` is the `pci_channel_state_t` (normal / frozen / perm-failure).
    /// Default returns `PCI_ERS_RESULT_NONE`. Override to quiesce and request the
    /// appropriate recovery (e.g. `PCI_ERS_RESULT_NEED_RESET`).
    fn error_detected(
        dev: &Device<device::Core>,
        this: Pin<&Self>,
        state: bindings::pci_channel_state_t,
    ) -> bindings::pci_ers_result_t {
        let _ = (dev, this, state);
        bindings::pci_ers_result_PCI_ERS_RESULT_NONE
    }

    /// Called after the slot/bus reset completes (the AER step taken after a
    /// driver returns `NEED_RESET`). Config space is restored by the core;
    /// re-initialise enough to be usable and return `PCI_ERS_RESULT_RECOVERED`.
    /// Default returns `PCI_ERS_RESULT_NONE`.
    fn slot_reset(dev: &Device<device::Core>, this: Pin<&Self>) -> bindings::pci_ers_result_t {
        let _ = (dev, this);
        bindings::pci_ers_result_PCI_ERS_RESULT_NONE
    }

    /// Called when the AER core says normal operation can resume (final step).
    /// Default no-op. Override to re-attach the device and restart traffic. Named
    /// `error_resume` to avoid colliding with the system-sleep `resume` hook.
    fn error_resume(dev: &Device<device::Core>, this: Pin<&Self>) {
        let _ = (dev, this);
    }
"""
s = s.replace(a, tm)

open(p, "w").write(s)
print("applied 3 AER edits to", p)
