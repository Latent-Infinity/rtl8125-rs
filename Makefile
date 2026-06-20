# SPDX-License-Identifier: GPL-2.0
# Top-level OOT-module Makefile. Invokes the kernel build for the
# Rust crate rooted in src/. The kernel build system — not Cargo — is
# authoritative for this driver.
#
# Usage (from the repo root, inside the debug+Rust guest):
#   make                  # build r8125_rust.ko
#   make clean
#   make modules_install  # only meaningful on a target install
#
# Toolchain pin (runbook "toolchain pin"): the kernel was built with
# rustc-1.93.1; do NOT override RUSTC to the rustup default (1.95.x) — it has
# no stable ABI and the kernel's precompiled crate metadata is bound to 1.93.x.

KDIR    ?= /lib/modules/$(shell uname -r)/build
RUSTC   ?= rustc-1.93
BINDGEN ?= bindgen
CLIPPY_DRIVER ?= /usr/lib/rust-1.93/bin/clippy-driver
ifeq ($(origin CC),default)
CC      := x86_64-linux-gnu-gcc
endif
PAHOLE  ?= pahole
OBJCOPY ?= objcopy
BTF_BASE ?= /sys/kernel/btf/vmlinux
PAHOLE_FLAGS ?= --lang_exclude=Rust
RESOLVE_BTFIDS ?= $(KDIR)/tools/bpf/resolve_btfids/resolve_btfids

# System-sleep PM (pci::Driver suspend/resume) requires the kernel-Rust PCI PM
# extension (kernel-patches/0001-rust-pci-add-pm-callbacks.patch). It is gated on
# the `r8125_pci_pm` cfg so the driver still builds against a stock kernel.
#   make            -> PM compiled out (default; stock-kernel + upstream safe)
#   make PCI_PM=1   -> PM compiled in  (requires a PM-extended kernel tree)
# `-A unexpected_cfgs` is passed unconditionally so the custom `r8125_pci_pm`
# cfg name never trips the unexpected_cfgs lint under CONFIG_WERROR (the kernel
# rustc recipe runs flags through a shell, so the parenthesised --check-cfg form
# is unusable here; the allow form is paren-free and equivalent for one cfg).
KRUSTFLAGS := -A unexpected_cfgs
ifeq ($(PCI_PM),1)
KRUSTFLAGS += --cfg=r8125_pci_pm
endif
# PCI .shutdown (reboot/kexec quiesce) requires the kernel-Rust PCI shutdown
# extension (kernel-patches/0002-rust-pci-add-shutdown-callback.patch). Gated on
# the `r8125_pci_shutdown` cfg so the default build stays stock-kernel buildable.
#   make SHUTDOWN=1 -> .shutdown compiled in (requires a shutdown-extended kernel)
ifeq ($(SHUTDOWN),1)
KRUSTFLAGS += --cfg=r8125_pci_shutdown
endif
# PCI function-reset handlers (reset_prepare/reset_done) require the kernel-Rust
# PCI reset extension (kernel-patches/0003-rust-pci-add-reset-callbacks.patch).
# Gated on the `r8125_pci_reset` cfg.
#   make RESET=1 -> reset handlers compiled in (requires a reset-extended kernel)
ifeq ($(RESET),1)
KRUSTFLAGS += --cfg=r8125_pci_reset
endif
# PCIe AER recovery handlers (error_detected/slot_reset/resume) require the
# kernel-Rust PCI AER extension (kernel-patches/0004-rust-pci-add-aer-callbacks.patch).
# Gated on the `r8125_pci_aer` cfg.
#   make AER=1 -> AER recovery compiled in (requires an AER-extended kernel)
ifeq ($(AER),1)
KRUSTFLAGS += --cfg=r8125_pci_aer
endif
# PCI runtime-PM (autosuspend a closed interface) requires the kernel-Rust PCI
# runtime-PM extension (kernel-patches/0005-rust-pci-add-runtime-pm-callbacks.patch).
# Gated on the `r8125_pci_runtime_pm` cfg.
#   make RUNTIME_PM=1 -> runtime PM compiled in (requires a runtime-PM-extended kernel)
ifeq ($(RUNTIME_PM),1)
KRUSTFLAGS += --cfg=r8125_pci_runtime_pm
endif

all default modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src RUSTC=$(RUSTC) BINDGEN=$(BINDGEN) CLIPPY_DRIVER=$(CLIPPY_DRIVER) CC=$(CC) KRUSTFLAGS="$(KRUSTFLAGS)" CONFIG_DEBUG_INFO_BTF_MODULES= modules
	@$(MAKE) --no-print-directory btf

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src clean

modules_install:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src CC=$(CC) modules_install

btf:
	@if grep -q '^CONFIG_DEBUG_INFO_BTF_MODULES=y' "$(KDIR)/include/config/auto.conf"; then \
		test -r "$(BTF_BASE)"; \
		test -x "$(RESOLVE_BTFIDS)"; \
		printf '  BTF [M] %s\n' "$(CURDIR)/src/r8125_rust.ko"; \
		$(OBJCOPY) --remove-section .BTF --remove-section .BTF.base "$(CURDIR)/src/r8125_rust.ko"; \
		CONFIG_SHELL=/bin/sh objtree="$(KDIR)" srctree="$(KDIR)" \
			PAHOLE="$(PAHOLE)" PAHOLE_FLAGS="$(PAHOLE_FLAGS)" \
			RESOLVE_BTFIDS="$(RESOLVE_BTFIDS)" OBJCOPY="$(OBJCOPY)" CC="$(CC)" \
			"$(KDIR)/scripts/gen-btf.sh" --btf_base "$(BTF_BASE)" "$(CURDIR)/src/r8125_rust.ko"; \
	fi

.PHONY: all default modules clean modules_install btf
