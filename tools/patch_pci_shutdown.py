#!/usr/bin/env python3
# Apply the rust-pci .shutdown extension to a kernel's rust/kernel/pci.rs.
# Idempotent-ish: asserts each anchor appears exactly once (so a re-run on an
# already-patched tree fails loudly rather than double-applying).
import sys

p = sys.argv[1]
s = open(p).read()

# 1. registration: add the shutdown field next to the PM ops.
a = "            (*pdrv.get()).driver.pm = &Self::PM_OPS;\n"
assert s.count(a) == 1, "registration anchor not unique"
s = s.replace(a, a + "            (*pdrv.get()).shutdown = Some(Self::shutdown_callback);\n")

# 2. shutdown_callback thunk after remove_callback.
a = "        T::unbind(pdev, data);\n    }\n"
assert s.count(a) == 1, "remove_callback anchor not unique"
cb = """        T::unbind(pdev, data);
    }

    /// PCI `.shutdown` thunk. The bus passes a `pci_dev*` (like remove); recover
    /// the bound device + drvdata and run the driver shutdown. Returns void.
    extern "C" fn shutdown_callback(pdev: *mut bindings::pci_dev) {
        // SAFETY: the PCI bus only calls .shutdown with a valid `pci_dev*`.
        // INVARIANT: `pdev` is valid for the duration of `shutdown_callback()`.
        let pdev = unsafe { &*pdev.cast::<Device<device::CoreInternal>>() };

        // SAFETY: .shutdown runs only between a successful `probe_callback` and
        // `remove_callback`, so drvdata holds a `Pin<KBox<T>>`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };

        T::shutdown(pdev, data);
    }
"""
s = s.replace(a, cb)

# 3. trait shutdown() default method after resume().
a = (
    "    /// System-sleep resume. Default no-op. Override to restore device state.\n"
    "    fn resume(dev: &Device<device::Core>, this: Pin<&Self>) -> Result {\n"
    "        let _ = (dev, this);\n"
    "        Ok(())\n"
    "    }\n"
)
assert s.count(a) == 1, "resume trait-method anchor not unique"
tm = a + """
    /// Device shutdown (reboot / kexec / poweroff). Default no-op. Override to
    /// quiesce the device (stop DMA, mask IRQs) so it is quiet for the next
    /// kernel / power-off; the PCI core does not save/restore around this.
    fn shutdown(dev: &Device<device::Core>, this: Pin<&Self>) {
        let _ = (dev, this);
    }
"""
s = s.replace(a, tm)

open(p, "w").write(s)
print("applied 3 edits to", p)
