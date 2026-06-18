#!/usr/bin/env python3
# Apply the rust-pci reset_prepare/reset_done (err_handler) extension to a
# kernel's rust/kernel/pci.rs. Must run AFTER the 0002 shutdown patch.
import sys

p = sys.argv[1]
s = open(p).read()

# 1. registration: add err_handler next to the shutdown field.
a = "            (*pdrv.get()).shutdown = Some(Self::shutdown_callback);\n"
assert s.count(a) == 1, "shutdown registration anchor not found (apply 0002 first)"
s = s.replace(a, a + "            (*pdrv.get()).err_handler = &Self::ERR_HANDLER;\n")

# 2. reset thunks + ERR_HANDLER const, after shutdown_callback.
a = "        T::shutdown(pdev, data);\n    }\n"
assert s.count(a) == 1, "shutdown_callback anchor not found"
cb = """        T::shutdown(pdev, data);
    }

    extern "C" fn reset_prepare_callback(pdev: *mut bindings::pci_dev) {
        // SAFETY: the PCI core only calls reset_prepare with a valid `pci_dev*`.
        let pdev = unsafe { &*pdev.cast::<Device<device::CoreInternal>>() };
        // SAFETY: called between a successful probe and remove, so drvdata holds a `T`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        T::reset_prepare(pdev, data);
    }

    extern "C" fn reset_done_callback(pdev: *mut bindings::pci_dev) {
        // SAFETY: see `reset_prepare_callback`.
        let pdev = unsafe { &*pdev.cast::<Device<device::CoreInternal>>() };
        // SAFETY: see `reset_prepare_callback`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        T::reset_done(pdev, data);
    }

    const ERR_HANDLER: bindings::pci_error_handlers = bindings::pci_error_handlers {
        reset_prepare: Some(Self::reset_prepare_callback),
        reset_done: Some(Self::reset_done_callback),
        // SAFETY: zero-initialises the remaining Option<fn> / ptr fields.
        ..unsafe { core::mem::MaybeUninit::<bindings::pci_error_handlers>::zeroed().assume_init() }
    };
"""
s = s.replace(a, cb)

# 3. trait reset_prepare/reset_done default methods, after shutdown().
a = (
    "    fn shutdown(dev: &Device<device::Core>, this: Pin<&Self>) {\n"
    "        let _ = (dev, this);\n"
    "    }\n"
)
assert s.count(a) == 1, "shutdown trait-method anchor not found"
tm = a + """
    /// Called before a PCI function reset (secondary-bus / FLR / sysfs reset).
    /// Default no-op. Override to quiesce (phy_stop, stop DMA) so the reset does
    /// not catch the device mid-DMA and the link drop does not WARN phylib.
    fn reset_prepare(dev: &Device<device::Core>, this: Pin<&Self>) {
        let _ = (dev, this);
    }

    /// Called after a PCI function reset completes (config space restored by the
    /// core). Default no-op. Override to re-initialise the device.
    fn reset_done(dev: &Device<device::Core>, this: Pin<&Self>) {
        let _ = (dev, this);
    }
"""
s = s.replace(a, tm)

open(p, "w").write(s)
print("applied 3 reset edits to", p)
