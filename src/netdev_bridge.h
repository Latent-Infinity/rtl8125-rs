/* SPDX-License-Identifier: GPL-2.0 */
/*
 * netdev_bridge.h — the canonical Rust ↔ C ownership contract for the
 *                   r8125_rust driver (plan §5.2 / §6.3 / §7 M4).
 *
 * This file is the DELIVERABLE, not its implementation in netdev_bridge*.c.
 * Reviewers compare every `struct sk_buff *`-touching call against the
 * pre/post-conditions stated here. Any change to a function signature or
 * an ownership transition requires updating both this header AND the
 * matching Rust code in `src/skb.rs` / `src/netdev.rs` / `src/napi.rs` in
 * the same commit (plan §6.3 final paragraph).
 *
 * Filename note: the plan §6.1 layout places this file in `cshim/` at the
 * repo root. We deviate to `src/` because the kernel build's composite-
 * module pattern (used by `samples/rust/rust_print` — main.rs + events.c
 * co-located) requires C and Rust components in the same M= directory.
 * The cshim README at the repo root points here.
 */

#ifndef _R8125_NETDEV_BRIDGE_H
#define _R8125_NETDEV_BRIDGE_H

#include <linux/types.h>
#include <linux/if_ether.h>

/* Forward declarations so this header pulls in as little as possible. */
struct net_device;
struct sk_buff;
struct device;
struct pci_dev;
struct napi_struct;

/* ──────────────────────────────────────────────────────────────────────
 *  Vtable populated by Rust and consumed by the C bridge.
 *
 *  Every callback receives the same `priv` pointer the Rust side passed to
 *  `r8125_bridge_alloc`. The C bridge stores it in the net_device's private
 *  area. None of these calls are re-entrant from the same context — `open`
 *  and `stop` run under RTNL; `xmit` runs under the TX queue lock; `poll`
 *  runs in NAPI context.
 *
 *  Every callback returning `int` returns 0 on success or a negative
 *  errno. `xmit` returns the standard `netdev_tx_t` value:
 *    - NETDEV_TX_OK (0): driver took the skb (queued or freed it).
 *    - NETDEV_TX_BUSY (0x10):  kernel retains the skb. See §6.3.
 *
 *  Rust implementations must be marked `extern "C"` and `pub`; nothing
 *  else in Rust calls them directly.
 * ────────────────────────────────────────────────────────────────────── */
struct r8125_bridge_ops {
	/*
	 * open(priv)
	 * ─────────
	 * Pre   : netdev is registered, RTNL held, device hardware is in the
	 *         post-reset / post-probe state from M2.
	 * Post  : on success, hardware is brought up to the limit of what
	 *         M4-without-peer allows — at minimum, queues stopped, no
	 *         RX programmed, no IRQ requested. Once the peer arrives,
	 *         this is where TX/RX enable + IRQ request + NAPI enable
	 *         live.
	 * Return: 0 on success; negative errno on failure (the netdev stays
	 *         in the down state and the kernel will not call any other
	 *         ndo until open succeeds).
	 */
	int (*open)(void *priv);

	/*
	 * stop(priv)
	 * ──────────
	 * Pre   : open(priv) returned 0 at some point in the past.
	 * Post  : device hardware quiescent. All TX skbs that were in flight
	 *         have either reached `bridge_skb_complete_tx` (the normal
	 *         path) or been `dev_kfree_skb_any`'d. All RX buffers have
	 *         been recycled or freed. NAPI is disabled. IRQ is freed.
	 *         Per §6.3 the `tx_received == tx_consumed + tx_busy_exception
	 *         + tx_dropped_error` invariant must hold after this returns.
	 */
	void (*stop)(void *priv);

	/*
	 * xmit(priv, skb) — TX path entry, §6.3 contract holds
	 * ───────────────
	 * Pre   : kernel hands `skb` ownership to driver. Driver MUST dispose
	 *         in EXACTLY ONE of:
	 *           (a) NETDEV_TX_OK + skb mapped + queued + posted to ring
	 *                 → §6.3 slot transition `Empty → Submitted`,
	 *                   counter `tx_received++`.
	 *           (b) NETDEV_TX_BUSY + skb UNTOUCHED (not freed, not mapped,
	 *               not stored) — kernel will requeue. Counter
	 *                 `tx_busy_exception++` (this is a counted exception,
	 *                  NOT a normal backpressure path).
	 *           (c) NETDEV_TX_OK + driver called `dev_kfree_skb_any(skb)`
	 *                 EXACTLY ONCE on a validation/DMA-map failure.
	 *                 Counter `tx_dropped_error++`.
	 * Post  : as above. The skb pointer is invalid for the driver after
	 *         (b) and (c).
	 */
	int /* netdev_tx_t */ (*xmit)(void *priv, struct sk_buff *skb);

	/*
	 * poll(priv, budget) — NAPI poll callback
	 * ─────────────────
	 * Pre   : NAPI is scheduled (either from IRQ or from a manual
	 *         napi_schedule call). `budget` is the maximum number of RX
	 *         frames the driver may pass to the stack in this call.
	 * Post  : returns `work_done` in `[0, budget]`. If `work_done < budget`
	 *         the driver MUST call `r8125_bridge_napi_complete_done()`
	 *         before returning so the kernel re-enables IRQs.
	 *         (NAPI re-arm semantics — net/core/dev.c expects this.)
	 *
	 *         For every RX frame passed to the stack in this call the
	 *         counter `rx_handed_to_stack++`; for every TX completion
	 *         processed `tx_consumed++` (and `tx_received - tx_consumed
	 *         - tx_busy_exception - tx_dropped_error` is the queue depth).
	 */
	int (*poll)(void *priv, int budget);

	/*
	 * change_mtu(priv, new_mtu) — MTU sysfs / ip link mtu N
	 * ───────────────────────
	 * Pre   : new_mtu is the requested MTU. Driver must validate range.
 *         M4 accepts the standard Ethernet MTU only; jumbo support lands
 *         with the M5 RX-buffer/page-fragment refactor.
	 * Post  : on success, the net_device's `mtu` field has already been
	 *         updated by the kernel; this callback runs AFTER. The
	 *         driver may need to retune RX buffer sizes — that work
	 *         arrives with the peer.
	 */
	int (*change_mtu)(void *priv, int new_mtu);
};

/* ──────────────────────────────────────────────────────────────────────
 *  Lifecycle: alloc → register → … → unregister_and_free.
 *
 *  Allocation accounting (§6.3 invariant) is initialised in the alloc
 *  call; `r8125_bridge_counters_snapshot` exposes the running totals.
 * ────────────────────────────────────────────────────────────────────── */

/*
 * Allocate a net_device whose private area is `struct r8125_bridge` (an
 * opaque struct living entirely in the C side). The Rust `priv` pointer
 * + `ops` vtable + MAC address are stored in the bridge.
 *
 * Returns the net_device pointer (NOT the bridge; use the dedicated
 * accessors below if you need to talk to the bridge from C) or NULL on
 * allocation failure. On NULL the caller has nothing to free.
 *
 * Ownership rule: the Rust caller MUST follow up with one of:
 *   - `r8125_bridge_register()`, then eventually `r8125_bridge_unregister_and_free()`;
 *   - or `r8125_bridge_free()` (un-registered free, error path only).
 */
struct net_device *r8125_bridge_alloc(struct pci_dev *pdev,
				      void *priv,
				      const struct r8125_bridge_ops *ops,
				      const unsigned char mac[ETH_ALEN]);

/* Free an UNREGISTERED netdev (error path between alloc and register). */
void r8125_bridge_free(struct net_device *ndev);

/* Register with the kernel network stack. Returns 0 on success. */
int r8125_bridge_register(struct net_device *ndev);

/* Unregister + free in one step (the normal teardown path). Idempotent in
 * the sense that the driver must call it exactly once after a successful
 * register; do not also call free() afterwards. */
void r8125_bridge_unregister_and_free(struct net_device *ndev);

/* ──────────────────────────────────────────────────────────────────────
 *  Flow-control + NAPI-arming helpers — the §6.3 invariants live here.
 * ────────────────────────────────────────────────────────────────────── */

/* Stop the TX queue. Call from xmit BEFORE the ring fills, NOT in the
 * NETDEV_TX_BUSY hot path (see §6.3). Safe from xmit context. */
void r8125_bridge_tx_stop_queue(struct net_device *ndev);

/* Wake the TX queue. Call from the completion reaper once descriptors are
 * available again. Safe from NAPI / IRQ-thread context. */
void r8125_bridge_tx_wake_queue(struct net_device *ndev);

/* Schedule a NAPI poll. Safe to call from atomic (IRQ) context. */
void r8125_bridge_napi_schedule(struct net_device *ndev);

/* Tell NAPI we processed `work_done` frames this round and are done. The
 * driver MUST call this from inside the poll callback before returning
 * `work_done` when `work_done < budget`. */
void r8125_bridge_napi_complete_done(struct net_device *ndev, int work_done);

/* Link-state helpers — Rust calls these after detecting carrier change. */
void r8125_bridge_carrier_on(struct net_device *ndev);
void r8125_bridge_carrier_off(struct net_device *ndev);

/* Convenience: full TX-queue disable (used at ndo_stop). */
void r8125_bridge_tx_disable(struct net_device *ndev);

/* ──────────────────────────────────────────────────────────────────────
 *  sk_buff helpers — Rust never dereferences `struct sk_buff` directly.
 *  Every read/write goes through one of these (plan §6.3, type-state).
 *
 *  Each helper documents the counter side-effect; the Rust type-state
 *  in `src/skb.rs` mirrors these into `TxSkb<S>` transitions.
 * ────────────────────────────────────────────────────────────────────── */

/* Read-only accessors. No counter changes. */
size_t r8125_bridge_skb_len(struct sk_buff *skb);
const unsigned char *r8125_bridge_skb_data(struct sk_buff *skb);

/*
 * DMA-map the skb's linear region for TX. Counter: tx_received++.
 *
 * Pre   : `skb` was just received from xmit() (state `Received`).
 * Post  : on success, `*out_handle` and `*out_len` are set; the driver
 *         must remember them for the matching unmap call. State
 *         transition `Received → Mapped`.
 * Return: 0 on success; -EIO or similar on DMA-mapping failure (counter
 *         is still incremented — the failure path is `tx_dropped_error`).
 */
int r8125_bridge_skb_dma_map_tx(struct device *dev,
				struct sk_buff *skb,
				dma_addr_t *out_handle,
				size_t *out_len);

/* DMA-unmap. No counter change here; the matching `complete_tx` or
 * `free_error` call is the counter event. */
void r8125_bridge_skb_dma_unmap_tx(struct device *dev,
				   dma_addr_t handle, size_t len);

/*
 * Free an skb on the TX-error path (validation reject, DMA-map failure,
 * etc.). Counter: tx_dropped_error++. Calls `dev_kfree_skb_any` exactly
 * once; the skb pointer is invalid after this call.
 *
 * This is the §6.3 "(c) drop_with_error" disposition.
 */
void r8125_bridge_skb_free_error(struct sk_buff *skb);

/*
 * Complete a posted TX descriptor: DMA-unmap + `napi_consume_skb`.
 * Counter: tx_consumed++.
 *
 * This is the §6.3 step 4 — `Submitted → Completing → Empty`.
 */
void r8125_bridge_skb_complete_tx(struct device *dev,
				  dma_addr_t handle, size_t len,
				  struct sk_buff *skb);

/* Count a NETDEV_TX_BUSY return where the kernel retains skb ownership.
 * Call only on the documented exceptional ring-full race path. */
void r8125_bridge_tx_busy_exception(struct net_device *ndev);

/*
 * Build an skb wrapping a freshly-DMA'd RX buffer. Pre-allocated by the
 * driver at ndo_open and never reused while hardware has it — see §6.3
 * RX-path table.
 *
 * Pre   : `buf` is CPU-readable (post-`dma_unmap_single` from
 *         `DataDirection::FromDevice`) and `len` is the valid byte count.
 * Post  : returns a new skb whose data points into a copy of `buf` (M4
 *         baseline — page-pool / `napi_build_skb` zero-copy comes later).
 *         Returns NULL on alloc failure (rare).
 *
 * Counter: NO change here. The dispostion counter increments when the
 *          skb is handed to the stack (`rx_handed_to_stack`) or freed
 *          on error (`rx_dropped_error`).
 */
struct sk_buff *r8125_bridge_skb_build_rx(struct net_device *ndev,
					  const void *buf, size_t len);

/*
 * Hand the skb to the network stack via `napi_gro_receive`. This is the
 * §6.3 step-4 transfer that is unconditional — no failure return that
 * requires the caller to free. Counter: rx_handed_to_stack++.
 */
void r8125_bridge_skb_deliver_rx(struct napi_struct *napi, struct sk_buff *skb);

/* ──────────────────────────────────────────────────────────────────────
 *  HW checksum offload (M4-perf, task 48).
 *
 *  The Rust ndo_start_xmit / napi::poll paths don't peek into sk_buff
 *  internals; the cshim does the protocol introspection and tells the
 *  Rust side what TX descriptor `opts2` bits to OR in (or 0 = pass-
 *  through software checksum), and consumes the RX descriptor `opts1`
 *  to set `skb->ip_summed = CHECKSUM_UNNECESSARY` when the chip
 *  validated the checksum.
 *
 *  Bit values mirror both r8169_main.c (TD1_*_CS) and Realtek's r8125
 *  vendor driver (TxTCPCS_C / TxUDPCS_C / TxIPCS_C / TxIPV6F_C):
 *    bit 31 (TxUDPCS_C) — chip computes UDP/IP checksum
 *    bit 30 (TxTCPCS_C) — chip computes TCP/IP checksum
 *    bit 29 (TxIPCS_C)  — chip computes IPv4 checksum
 *    bit 28 (TxIPV6F_C) — frame is IPv6
 *    bits [27:18] TCPHO_SHIFT — transport header offset
 *
 *  For short UDP frames (transport data < 47 bytes) the chip computes
 *  the WRONG checksum (vendor errata, upstream r8169 has the same
 *  workaround). This helper calls `skb_checksum_help` to fall back to
 *  software in that case and returns 0 so the TX descriptor goes out
 *  with no HW-CSUM bits set. If `skb_checksum_help` itself fails, the
 *  helper returns `0xffffffff`; Rust drops the skb before DMA mapping.
 */
u32 r8125_bridge_skb_tx_csum_opts(struct sk_buff *skb);

/* Inspect RX descriptor `opts1` and, if it indicates a successfully
 * checksummed TCP or UDP packet (PID bits set, no fail bits),
 * set `skb->ip_summed = CHECKSUM_UNNECESSARY`. Otherwise no change
 * (kernel will fall back to software verification).
 *
 * Bits referenced from rtl_rx_desc_bit (r8169_main.c lines 622-638):
 *   bit 17 (PID0) — TCP if set
 *   bit 18 (PID1) — UDP if set
 *   bit 16 (IPFail)   — IP   checksum failed
 *   bit 15 (UDPFail)  — UDP  checksum failed
 *   bit 14 (TCPFail)  — TCP  checksum failed
 */
void r8125_bridge_skb_rx_csum_set(struct sk_buff *skb, u32 desc_opts1);

/* Bump netdev->stats from inside the cshim. The Rust hot-path
 * doesn't have access to `struct net_device` members; counter
 * mutation lives here. */
void r8125_bridge_account_tx(struct net_device *ndev, unsigned int bytes);
void r8125_bridge_account_rx(struct net_device *ndev, unsigned int bytes);

/* Free an skb on the RX-error path (e.g. CRC error, truncated). Counter:
 * rx_dropped_error++. */
void r8125_bridge_skb_drop_rx(struct sk_buff *skb);

/* Count an RX drop when no skb exists to free (for example allocation
 * failure in r8125_bridge_skb_build_rx). */
void r8125_bridge_rx_drop_error(struct net_device *ndev);

/* ──────────────────────────────────────────────────────────────────────
 *  Counter snapshot — §6.3 invariant `tx_received == tx_consumed +
 *  tx_busy_exception + tx_dropped_error`. CI smoke test reads this at
 *  quiesce and asserts.
 * ────────────────────────────────────────────────────────────────────── */
struct r8125_bridge_counters {
	u64 tx_received;
	u64 tx_consumed;
	u64 tx_busy_exception;
	u64 tx_dropped_error;
	u64 rx_handed_to_stack;
	u64 rx_dropped_error;
};
void r8125_bridge_counters_snapshot(struct net_device *ndev,
				    struct r8125_bridge_counters *out);

/* Accessor for the `napi_struct` embedded in the bridge — needed by Rust
 * to call `r8125_bridge_skb_deliver_rx` from the poll callback. */
struct napi_struct *r8125_bridge_napi(struct net_device *ndev);

/* ──────────────────────────────────────────────────────────────────────
 *  PHY plumbing (plan §7 M4-traffic, task #46).
 *
 *  The cshim owns the kernel-side MDIO bus + `struct phy_device` (the
 *  Rust crate does not expose these surfaces yet). Rust supplies the
 *  two MDIO transaction callbacks via the function-pointer struct
 *  below; the cshim wires them into a kernel `mii_bus->{read,write}`.
 *  Rust then drives `phy_start` / `phy_stop` through the helpers
 *  below at the appropriate ndo lifecycle points.
 *
 *  Why Rust callbacks?  The PHY registers are accessed through a
 *  32-bit MMIO transaction at offset 0xB8 (GPHY_OCP). MMIO must stay
 *  inside the Rust `unsafe_boundary`; the cshim is forbidden from
 *  touching the BAR directly.
 * ────────────────────────────────────────────────────────────────────── */

/* MDIO read/write: u16 in [0, 0xFFFF] on success, negative errno on
 * failure. Called from process context (RTNL held). The C45 variants
 * add an MMD device address (devad) — only MDIO_MMD_VEND2 with a
 * regnum > MDIO_STAT2 actually reaches the chip; other (devad, regnum)
 * combinations return 0 (read) / -ENODEV (write), matching r8169. */
typedef int (*r8125_bridge_mdio_read_fn)(void *priv, int phyreg);
typedef int (*r8125_bridge_mdio_write_fn)(void *priv, int phyreg, u16 val);
typedef int (*r8125_bridge_mdio_read_c45_fn)(void *priv, int devad, int phyreg);
typedef int (*r8125_bridge_mdio_write_c45_fn)(void *priv, int devad, int phyreg, u16 val);

struct r8125_bridge_mdio_ops {
	r8125_bridge_mdio_read_fn      read;
	r8125_bridge_mdio_write_fn     write;
	r8125_bridge_mdio_read_c45_fn  read_c45;
	r8125_bridge_mdio_write_c45_fn write_c45;
};

/*
 * Allocate an MDIO bus for this netdev, register it with the kernel,
 * walk it, and attach a phy_device. Stores the resulting phy_device
 * inside the bridge so subsequent `phy_start` / `phy_stop` calls find
 * it. Returns 0 on success, negative errno on failure.
 *
 * Must be called AFTER `r8125_bridge_register` and BEFORE any
 * `r8125_bridge_phy_connect_and_reset`. The MDIO bus is explicitly
 * unregistered and freed by `r8125_bridge_unregister_and_free`, while
 * this module's text is still loaded.
 *
 * If no PHY driver (realtek.ko) is loaded for the discovered phy_id
 * the function returns `-EUNATCH`, matching r8169's behaviour.
 */
int r8125_bridge_phy_register(struct net_device *ndev,
			      const struct r8125_bridge_mdio_ops *ops);

/* Two-step PHY bring-up matching the r8169 ordering for 8125B (the
 * embedded MAC/PHY couple: phy_soft_reset clobbers ChipCmd, so the
 * MAC init must happen AFTER PHY reset, with phy_start LAST).
 *
 * Call from ndo_open in this order:
 *   1. bridge_phy_connect_and_reset()   - early, before MAC init
 *   2. <MAC OCP init + ChipCmd RX|TX + IMR>
 *   3. bridge_phy_kick_state_machine()  - last, kicks autoneg
 */
int r8125_bridge_phy_connect_and_reset(struct net_device *ndev);
int r8125_bridge_phy_kick_state_machine(struct net_device *ndev);

/* Tear down the open-time PHY state: phy_stop + phy_disconnect. Idempotent;
 * safe to call when phy_start was never reached. */
void r8125_bridge_phy_stop(struct net_device *ndev);

#endif /* _R8125_NETDEV_BRIDGE_H */
