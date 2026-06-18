# SPDX-License-Identifier: GPL-2.0

TEST_PROGS := r8125_rust_smoke.sh r8125_rust_features.sh

ifneq ($(wildcard ../lib.mk),)
include ../lib.mk
else
.PHONY: all run_tests clean
all:
	@:
run_tests:
	@for test in $(TEST_PROGS); do ./$$test; done
clean:
	@:
endif
