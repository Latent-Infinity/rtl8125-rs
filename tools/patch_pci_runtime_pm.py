#!/usr/bin/env python3
# Apply the rust-pci runtime-PM extension (runtime_suspend / runtime_resume /
# runtime_idle) to a kernel's rust/kernel/pci.rs. Must run AFTER the 0001 PM
# patch (it extends the PM_OPS dev_pm_ops and reuses its suspend/resume thunks
# scaffolding: container_of!, from_result, drvdata_borrow).
import sys

p = sys.argv[1]
s = open(p).read()

# 1. PM_OPS const: add the three runtime callbacks next to the sleep ones.
a = (
    "        poweroff: Some(Self::suspend_callback),\n"
    "        restore: Some(Self::resume_callback),\n"
)
assert s.count(a) == 1, "PM_OPS sleep fields anchor not found (apply 0001 first)"
s = s.replace(
    a,
    a
    + "        runtime_suspend: Some(Self::runtime_suspend_callback),\n"
    + "        runtime_resume: Some(Self::runtime_resume_callback),\n"
    + "        runtime_idle: Some(Self::runtime_idle_callback),\n",
)

# 2. Runtime thunks, appended after the resume_callback thunk.
a = "            T::resume(pdev, data)?;\n            Ok(0)\n        })\n    }\n"
assert s.count(a) == 1, "resume_callback anchor not found"
cb = """            T::resume(pdev, data)?;
            Ok(0)
        })
    }

    unsafe extern "C" fn runtime_suspend_callback(dev: *mut bindings::device) -> c_int {
        // SAFETY: see `suspend_callback`.
        let pdev = unsafe {
            &*container_of!(dev, bindings::pci_dev, dev).cast::<Device<device::CoreInternal>>()
        };
        // SAFETY: called between probe and remove, so drvdata holds a `T`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        from_result(|| {
            T::runtime_suspend(pdev, data)?;
            Ok(0)
        })
    }

    unsafe extern "C" fn runtime_resume_callback(dev: *mut bindings::device) -> c_int {
        // SAFETY: see `suspend_callback`.
        let pdev = unsafe {
            &*container_of!(dev, bindings::pci_dev, dev).cast::<Device<device::CoreInternal>>()
        };
        // SAFETY: see `suspend_callback`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        from_result(|| {
            T::runtime_resume(pdev, data)?;
            Ok(0)
        })
    }

    unsafe extern "C" fn runtime_idle_callback(dev: *mut bindings::device) -> c_int {
        // SAFETY: see `suspend_callback`.
        let pdev = unsafe {
            &*container_of!(dev, bindings::pci_dev, dev).cast::<Device<device::CoreInternal>>()
        };
        // SAFETY: see `suspend_callback`.
        let data = unsafe { pdev.as_ref().drvdata_borrow::<T>() };
        from_result(|| {
            T::runtime_idle(pdev, data)?;
            Ok(0)
        })
    }
"""
s = s.replace(a, cb)

# 3. Runtime trait default methods, after the resume() trait method.
a = (
    "    fn resume(dev: &Device<device::Core>, this: Pin<&Self>) -> Result {\n"
    "        let _ = (dev, this);\n"
    "        Ok(())\n"
    "    }\n"
)
assert s.count(a) == 1, "resume trait-method anchor not found"
tm = a + """
    /// Runtime (autosuspend) suspend. Default no-op. Override to quiesce when the
    /// PM core decides the device is idle (e.g. link down). Distinct from the
    /// system-sleep `suspend` so a driver can choose a lighter quiesce.
    fn runtime_suspend(dev: &Device<device::Core>, this: Pin<&Self>) -> Result {
        let _ = (dev, this);
        Ok(())
    }

    /// Runtime (autosuspend) resume. Default no-op. Override to re-init on the
    /// first activity after a runtime suspend.
    fn runtime_resume(dev: &Device<device::Core>, this: Pin<&Self>) -> Result {
        let _ = (dev, this);
        Ok(())
    }

    /// Runtime idle check. Returning `Ok(())` lets the PM core autosuspend; an
    /// `Err` (typically `EBUSY`) vetoes it. Default `Ok(())`. Override to keep the
    /// device active while the link is up / traffic may flow.
    fn runtime_idle(dev: &Device<device::Core>, this: Pin<&Self>) -> Result {
        let _ = (dev, this);
        Ok(())
    }
"""
s = s.replace(a, tm)

open(p, "w").write(s)
print("applied 3 runtime-PM edits to", p)
