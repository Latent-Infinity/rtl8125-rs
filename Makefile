# SPDX-License-Identifier: GPL-2.0
# Top-level OOT-module Makefile (plan §6.1). Invokes the kernel build for the
# Rust crate rooted in src/. The kernel build system — not Cargo — is
# authoritative for this driver (plan §6.1 / §2 / v3.2 changelog).
#
# Usage (from the repo root, inside the debug+Rust guest):
#   make                  # build r8125_rust.ko
#   make clean
#   make modules_install  # only meaningful on a target install
#
# Toolchain pin (runbook "toolchain pin" + plan §2): the kernel was built with
# rustc-1.93.1; do NOT override RUSTC to the rustup default (1.95.x) — it has
# no stable ABI and the kernel's precompiled crate metadata is bound to 1.93.x.

KDIR    ?= /lib/modules/$(shell uname -r)/build
RUSTC   ?= rustc-1.93
BINDGEN ?= bindgen
ifeq ($(origin CC),default)
CC      := x86_64-linux-gnu-gcc
endif
PAHOLE  ?= pahole
OBJCOPY ?= objcopy
BTF_BASE ?= /sys/kernel/btf/vmlinux
PAHOLE_FLAGS ?= --lang_exclude=Rust
RESOLVE_BTFIDS ?= $(KDIR)/tools/bpf/resolve_btfids/resolve_btfids

all default modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src RUSTC=$(RUSTC) BINDGEN=$(BINDGEN) CC=$(CC) CONFIG_DEBUG_INFO_BTF_MODULES= modules
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
