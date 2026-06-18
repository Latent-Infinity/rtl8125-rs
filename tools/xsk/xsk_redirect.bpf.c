// SPDX-License-Identifier: GPL-2.0
/*
 * Minimal XDP redirect-to-AF_XDP-socket program for r8125_rust zero-copy
 * validation. Every frame arriving on a queue that has a socket bound in
 * xsks_map is redirected to that socket (zero-copy when the socket bound with
 * XDP_ZEROCOPY); otherwise it passes to the stack. Loaded by tools/xsk/afxdp_zc.
 *
 * Build (clang): clang -O2 -g -target bpf -c xsk_redirect.bpf.c -o xsk_redirect.bpf.o
 */
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

struct {
	__uint(type, BPF_MAP_TYPE_XSKMAP);
	__uint(max_entries, 4);
	__type(key, __u32);
	__type(value, __u32);
} xsks_map SEC(".maps");

SEC("xdp")
int xdp_redirect_xsk(struct xdp_md *ctx)
{
	__u32 idx = ctx->rx_queue_index;

	if (bpf_map_lookup_elem(&xsks_map, &idx))
		return bpf_redirect_map(&xsks_map, idx, 0);
	return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
