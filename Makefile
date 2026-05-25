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

all default modules:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src RUSTC=$(RUSTC) BINDGEN=$(BINDGEN) modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src clean

modules_install:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src modules_install

.PHONY: all default modules clean modules_install
