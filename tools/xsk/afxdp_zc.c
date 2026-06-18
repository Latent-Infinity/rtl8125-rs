// SPDX-License-Identifier: GPL-2.0
/*
 * afxdp_zc — minimal AF_XDP zero-copy validation tool for r8125_rust.
 *
 * Single-interface ZC exerciser for the cross-machine rig (the gateway DUT's
 * port is cabled to a peer box, not to a second local port, so the kernel's
 * xskxceiver — which needs two connected local interfaces — does not fit). The
 * peer box generates (rxdrop) or sinks (txonly) the traffic.
 *
 *   rxdrop : bind a ZC socket on <iface> queue 0, redirect all RX to it via the
 *            companion XDP prog, and drop every frame. Proves the ZC RX datapath
 *            (xsk_buff_alloc / fill-cursor refill / redirect-to-socket). Peer:
 *            flood the DUT (e.g. `ping -f 10.0.0.2` or a UDP blast).
 *   txonly : transmit a fixed L2 frame (ethertype 0x88b5, broadcast) from a ZC
 *            socket as fast as the completion ring drains. Proves the ZC TX
 *            datapath (xsk_tx_peek_desc drain + xsk_tx_completed). Peer:
 *            `tcpdump -i <peerif> 'ether proto 0x88b5'` to count.
 *
 * Build (on a box with clang + libbpf-dev + the kernel-selftest vendored xsk.c):
 *   KSRC=/path/to/linux bash tools/xsk/build_zc.sh
 *
 * Uses the vendored selftest xsk.h/xsk.c (libbpf-dev no longer ships xsk.h).
 */
#define _GNU_SOURCE
#include <errno.h>
#include <getopt.h>
#include <net/if.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <linux/if_xdp.h>
#include <linux/if_link.h>
#include <linux/if_ether.h>
#include <bpf/bpf.h>
#include <bpf/libbpf.h>

#include "xsk.h"

#define NUM_FRAMES   4096
#define FRAME_SIZE   XSK_UMEM__DEFAULT_FRAME_SIZE /* 4096 */
#define FILL_SIZE    XSK_RING_PROD__DEFAULT_NUM_DESCS
#define COMP_SIZE    XSK_RING_CONS__DEFAULT_NUM_DESCS
#define RX_SIZE      XSK_RING_CONS__DEFAULT_NUM_DESCS
#define TX_SIZE      XSK_RING_PROD__DEFAULT_NUM_DESCS
#define BATCH        64

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

struct xsk {
	void *umem_area;
	struct xsk_umem *umem;
	struct xsk_socket *sock;
	struct xsk_ring_prod fq;	/* fill */
	struct xsk_ring_cons cq;	/* completion */
	struct xsk_ring_cons rx;
	struct xsk_ring_prod tx;
};

/* A fixed broadcast L2 frame with a private ethertype, for txonly counting. */
static void build_tx_frame(__u8 *buf, __u32 *len)
{
	static const __u8 dst[6] = { 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
	static const __u8 src[6] = { 0x02, 0x52, 0x38, 0x31, 0x32, 0x35 };

	memset(buf, 0, 64);
	memcpy(buf, dst, 6);
	memcpy(buf + 6, src, 6);
	buf[12] = 0x88; buf[13] = 0xb5;	/* IEEE Std 802 - local experimental 1 */
	memset(buf + 14, 0xa5, 64 - 14);
	*len = 64;
}

static int run_rxdrop(struct xsk *x)
{
	unsigned long long rxpkts = 0;
	__u32 idx, i, n;

	/* Prime the fill ring with every frame. */
	if (xsk_ring_prod__reserve(&x->fq, FILL_SIZE, &idx) != FILL_SIZE) {
		fprintf(stderr, "fill prime failed\n");
		return 1;
	}
	for (i = 0; i < FILL_SIZE; i++)
		*xsk_ring_prod__fill_addr(&x->fq, idx + i) = i * FRAME_SIZE;
	xsk_ring_prod__submit(&x->fq, FILL_SIZE);

	while (!stop) {
		struct pollfd pfd = { .fd = xsk_socket__fd(x->sock), .events = POLLIN };

		/* Always kick the driver (ndo_xsk_wakeup) so the RX ring bootstraps
		 * from a cold start even before the need-wakeup flag is observed. */
		recvfrom(xsk_socket__fd(x->sock), NULL, 0, MSG_DONTWAIT, NULL, NULL);
		if (xsk_ring_prod__needs_wakeup(&x->fq))
			poll(&pfd, 1, 200);
		n = xsk_ring_cons__peek(&x->rx, BATCH, &idx);
		if (!n)
			continue;
		/* Recycle the consumed frames straight back to the fill ring. */
		__u32 fidx;
		if (xsk_ring_prod__reserve(&x->fq, n, &fidx) == n) {
			for (i = 0; i < n; i++) {
				__u64 addr = xsk_ring_cons__rx_desc(&x->rx, idx + i)->addr;
				*xsk_ring_prod__fill_addr(&x->fq, fidx + i) =
					xsk_umem__extract_addr(addr);
			}
			xsk_ring_prod__submit(&x->fq, n);
		}
		xsk_ring_cons__release(&x->rx, n);
		rxpkts += n;
	}
	printf("rxdrop: received %llu frames (zero-copy)\n", rxpkts);
	return 0;
}

static int run_txonly(struct xsk *x)
{
	unsigned long long txpkts = 0, completed = 0;
	__u32 frame_len, idx, i, n;
	__u8 frame[64];

	build_tx_frame(frame, &frame_len);
	/* Pre-write the frame into the first BATCH umem slots. */
	for (i = 0; i < BATCH; i++)
		memcpy((__u8 *)x->umem_area + i * FRAME_SIZE, frame, frame_len);

	while (!stop) {
		if (xsk_ring_prod__reserve(&x->tx, BATCH, &idx) == BATCH) {
			for (i = 0; i < BATCH; i++) {
				struct xdp_desc *d = xsk_ring_prod__tx_desc(&x->tx, idx + i);

				d->addr = (i % BATCH) * FRAME_SIZE;
				d->len = frame_len;
			}
			xsk_ring_prod__submit(&x->tx, BATCH);
			txpkts += BATCH;
		}
		/* Kick the driver to drain the TX ring (ndo_xsk_wakeup). */
		if (xsk_ring_prod__needs_wakeup(&x->tx))
			sendto(xsk_socket__fd(x->sock), NULL, 0, MSG_DONTWAIT, NULL, 0);
		/* Reclaim completions. */
		n = xsk_ring_cons__peek(&x->cq, BATCH, &idx);
		if (n) {
			xsk_ring_cons__release(&x->cq, n);
			completed += n;
		}
	}
	printf("txonly: submitted %llu, completed %llu frames (zero-copy)\n",
	       txpkts, completed);
	return 0;
}

int main(int argc, char **argv)
{
	const char *iface = NULL, *mode = NULL, *objpath = "xsk_redirect.bpf.o";
	struct xsk_umem_config ucfg = {
		.fill_size = FILL_SIZE, .comp_size = COMP_SIZE,
		.frame_size = FRAME_SIZE, .frame_headroom = 0, .flags = 0,
	};
	struct xsk_socket_config scfg = {
		.rx_size = RX_SIZE, .tx_size = TX_SIZE,
		.bind_flags = XDP_ZEROCOPY | XDP_USE_NEED_WAKEUP,
	};
	struct bpf_object *obj = NULL;
	struct bpf_program *prog;
	struct bpf_map *map;
	struct xsk x = { 0 };
	int ifindex, ret, c;
	__u64 umem_sz = (__u64)NUM_FRAMES * FRAME_SIZE;

	while ((c = getopt(argc, argv, "i:m:o:")) != -1) {
		switch (c) {
		case 'i': iface = optarg; break;
		case 'm': mode = optarg; break;
		case 'o': objpath = optarg; break;
		default: goto usage;
		}
	}
	if (!iface || !mode) goto usage;
	/* Line-buffer so progress/errors are visible over an ssh pipe even if the
	 * process is later killed (block buffering would otherwise swallow them). */
	setvbuf(stdout, NULL, _IOLBF, 0);
	setvbuf(stderr, NULL, _IOLBF, 0);
	ifindex = if_nametoindex(iface);
	if (!ifindex) { perror("if_nametoindex"); return 1; }

	signal(SIGINT, on_sig);
	signal(SIGTERM, on_sig);

	if (posix_memalign(&x.umem_area, getpagesize(), umem_sz)) {
		perror("posix_memalign"); return 1;
	}
	ret = xsk_umem__create(&x.umem, x.umem_area, umem_sz, &x.fq, &x.cq, &ucfg);
	if (ret) { fprintf(stderr, "xsk_umem__create: %s\n", strerror(-ret)); return 1; }

	/* Load + attach our redirect program in DRIVER (native) mode — required
	 * for XDP_ZEROCOPY; then publish the socket into the XSKMAP.
	 */
	obj = bpf_object__open_file(objpath, NULL);
	if (!obj || libbpf_get_error(obj)) {
		fprintf(stderr, "open %s failed\n", objpath); return 1;
	}
	if (bpf_object__load(obj)) { fprintf(stderr, "bpf load failed\n"); return 1; }
	prog = bpf_object__find_program_by_name(obj, "xdp_redirect_xsk");
	map = bpf_object__find_map_by_name(obj, "xsks_map");
	if (!prog || !map) { fprintf(stderr, "prog/map not found\n"); return 1; }
	ret = xsk_attach_xdp_program(prog, ifindex, XDP_FLAGS_DRV_MODE);
	if (ret) { fprintf(stderr, "attach xdp (drv): %s\n", strerror(-ret)); return 1; }

	ret = xsk_socket__create(&x.sock, ifindex, 0, x.umem, &x.rx, &x.tx, &scfg);
	if (ret) {
		fprintf(stderr, "xsk_socket__create (ZC): %s\n", strerror(-ret));
		xsk_detach_xdp_program(ifindex, XDP_FLAGS_DRV_MODE);
		return 1;
	}
	if (xsk_update_xskmap(map, x.sock, 0)) {
		fprintf(stderr, "xsk_update_xskmap failed\n"); return 1;
	}
	printf("AF_XDP ZERO-COPY bound on %s q0 (mode=%s). Ctrl-C to stop.\n",
	       iface, mode);

	if (!strcmp(mode, "rxdrop")) ret = run_rxdrop(&x);
	else if (!strcmp(mode, "txonly")) ret = run_txonly(&x);
	else { fprintf(stderr, "unknown mode %s\n", mode); ret = 2; }

	xsk_clear_xskmap(map);
	xsk_socket__delete(x.sock);
	xsk_detach_xdp_program(ifindex, XDP_FLAGS_DRV_MODE);
	xsk_umem__delete(x.umem);
	bpf_object__close(obj);
	return ret;

usage:
	fprintf(stderr, "usage: %s -i <iface> -m <rxdrop|txonly> [-o xsk_redirect.bpf.o]\n",
		argv[0]);
	return 2;
}
