#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0
#
# Build the AF_XDP zero-copy validation tool (tools/xsk/afxdp_zc) + its redirect
# BPF program. Needs clang + libbpf-dev + the kernel selftest vendored xsk.c/xsk.h
# (libbpf-dev no longer ships xsk.h). Run on the box that owns the DUT (gateway).
#
#   KSRC=/path/to/linux-7.0.0 bash tools/xsk/build_zc.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KSRC="${KSRC:-/home/firestrand/kbuild/linux-7.0.0}"
BPF="$KSRC/tools/testing/selftests/bpf"

[ -f "$BPF/xsk.c" ] || { echo "vendored xsk.c not found under $BPF" >&2; exit 1; }

# BPF object (clang; -I for asm/types.h on Debian/Ubuntu multiarch).
clang -O2 -g -target bpf -I/usr/include/x86_64-linux-gnu \
	-c "$HERE/xsk_redirect.bpf.c" -o "$HERE/xsk_redirect.bpf.o"

# Userspace tool. The vendored xsk.c/xsk.h are built for the selftest Makefile
# environment, so pull in the kernel tools/ include paths (linux/types.h for
# u32, tools/arch for asm/barrier.h) alongside the system libbpf headers.
INC="-I$HERE -I$BPF -I$KSRC/tools/include -I$KSRC/tools/include/uapi -I$KSRC/tools/arch/x86/include"
gcc -O2 -Wall $INC "$HERE/afxdp_zc.c" "$BPF/xsk.c" -lbpf -o "$HERE/afxdp_zc"

echo "built: $HERE/afxdp_zc  +  $HERE/xsk_redirect.bpf.o"
