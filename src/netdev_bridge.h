/* SPDX-License-Identifier: GPL-2.0 */
/*
 * netdev_bridge.h — the canonical Rust ↔ C ownership contract for the
 *                   r8125_rust driver.
 *
 * This file is the DELIVERABLE, not its implementation in netdev_bridge*.c.
 * Reviewers compare every `struct sk_buff *`-touching call against the
 * pre/post-conditions stated here. Any change to a function signature or
 * an ownership transition requires updating both this header AND the
 * matching Rust code in `src/skb.rs` / `src/netdev.rs` / `src/napi.rs` in
 * the same commit.
 *
 * Filename note: the original layout places this file in `cshim/` at the
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
 *    - NETDEV_TX_BUSY (0x10):  kernel retains the skb.
 *
 *  Rust implementations must be marked `extern "C"` and `pub`; nothing
 *  else in Rust calls them directly.
 * ──────────────────────────────────────────────────────────────────────
 */
struct r8125_bridge_ops {
	/*
	 * open(priv, feature_flags) — full device bring-up
	 * ─────────
	 * Pre   : netdev is registered, RTNL held, device hardware is in
	 *         the post-reset / post-probe state from probe time.
	 * Post  : on success, the device is fully ready to move packets:
	 *           - hw_start_8125b run (MAC init, INT_CFG, TXCFG,
	 *             RXCFG baseline, RSS disable, OCP tuning,
	 *             L1-exit triggers).
	 *           - All RX descriptor slots posted with OWN bit set.
	 *           - IRQ requested through the Rust unsafe-boundary
	 *             wrapper around request_threaded_irq.
	 *           - NAPI enabled (handled by bridge_ndo_open before
	 *             this callback runs).
	 *           - PHY attached, soft-reset done, link state machine
	 *             started (carrier-on follows asynchronously when
	 *             auto-neg completes).
	 *           - TX queue ready to accept skbs from xmit (subject
	 *             to the NETDEV_TX_BUSY ring-full guard).
	 *         The kernel may start calling xmit / poll / change_mtu
	 *         immediately after open returns 0.
	 * Return: 0 on success; negative errno on failure. On failure the
	 *         driver MUST roll back any state acquired (free IRQ,
	 *         undo PHY connect, free DMA mappings) so a subsequent
	 *         open() retry sees the same pre-state. The netdev stays
	 *         in the down state and the kernel will not call any
	 *         other ndo until open succeeds.
	 */
	int (*open)(void *priv, unsigned int feature_flags);

	/*
	 * stop(priv)
	 * ──────────
	 * Pre   : open(priv) returned 0 at some point in the past.
	 * Post  : device hardware quiescent. All TX skbs that were in flight
	 *         have either reached `bridge_skb_consume_tx` (the normal
	 *         path) or been `dev_kfree_skb_any`'d. All RX buffers have
	 *         been recycled or freed. NAPI is disabled. IRQ is freed.
	 *         The `tx_received == tx_consumed + tx_busy_exception
	 *         + tx_dropped_error` invariant must hold after this returns.
	 */
	void (*stop)(void *priv);

	/*
	 * xmit(priv, skb) — TX path entry, ownership contract holds
	 * ───────────────
	 * Pre   : kernel hands `skb` ownership to driver. Driver MUST dispose
	 *         in EXACTLY ONE of:
	 *           (a) NETDEV_TX_OK + skb mapped + queued + posted to ring
	 *                 → slot transition `Empty → Submitted`,
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
	 * poll(priv, queue_id, budget) — NAPI poll callback
	 * ─────────────────
	 * Pre   : NAPI is scheduled (either from IRQ or from a manual
	 *         napi_schedule call). `queue_id` identifies the RX queue
	 *         whose NAPI instance is polling. `budget` is the maximum
	 *         number of RX frames the driver may pass to the stack in this
	 *         call.
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
	int (*poll)(void *priv, unsigned int queue_id, int budget);

	/*
	 * change_mtu(priv, new_mtu) — MTU sysfs / ip link mtu N
	 * ───────────────────────
	 * Pre   : new_mtu is the requested MTU. Driver must validate range.
	 *         Jumbo MTU up to 9000 bytes is supported by the Rust-side
	 *         per-slot RX page pool and the bridge's MTU bounds.
	 * Post  : on success, the net_device's `mtu` field has already been
	 *         updated by the kernel; this callback runs AFTER. The
	 *         driver refreshes feature flags so jumbo disables the
	 *         offloads that are not safe at that MTU.
	 */
	int (*change_mtu)(void *priv, int new_mtu);

	/*
	 * set_features(priv, feature_flags) — runtime ethtool -K update
	 * ─────────────────────────────────
	 * Pre   : RTNL held and the netdev is running. C translated the kernel's
	 *         netdev_features_t mask into R8125_BRIDGE_FEATURE_* flags.
	 * Post  : Rust has programmed the chip-side RX checksum/VLAN feature bits
	 *         to match the effective netdev feature mask.
	 */
	int (*set_features)(void *priv, unsigned int feature_flags);

	/*
	 * rss_indir_check(priv, indir, len) — ethtool set_rxfh validation
	 * ─────────────────────────────────
	 * Pre   : RTNL held. `indir` is the kernel ethtool_rxfh_param table of
	 *         `len` entries (or NULL/0 for no indirection change).
	 * Post  : returns 0 if every entry maps to an active RX queue, -EINVAL
	 *         otherwise. `queue_count` is the runtime active queue count
	 *         reported through ethtool, not the compile-time allocation max.
	 *         Delegates to the host-tested Rust validator
	 *         (crate::layout::rxfh_indir_all_valid) so C and Rust cannot
	 *         disagree on the rule.
	 */
	int (*rss_indir_check)(void *priv, const u32 *indir, unsigned int len,
			       unsigned int queue_count);

	/*
	 * rss_get(priv, key_out, indir_out) — ethtool get_rxfh (-x)
	 * ─────────────────────────────────
	 * Pre   : RTNL held. key_out (RSS_KEY_SIZE bytes) and/or indir_out
	 *         (RSS_INDIR_SIZE u32 entries) point to ethtool-allocated buffers;
	 *         either may be NULL when only the other is requested.
	 * Post  : both buffers are filled from the Rust-owned RSS policy (the active
	 *         key + indirection table). The chip RSS key is write-only, so this
	 *         cache is the only truthful source for `ethtool -x`.
	 */
	void (*rss_get)(void *priv, u8 *key_out, u32 *indir_out);

	/*
	 * rss_set(priv, key_in, indir_in, queue_count) — ethtool set_rxfh (-X)
	 * ────────────────────────────────────────────
	 * Pre   : RTNL held. key_in (RSS_KEY_SIZE bytes) and/or indir_in
	 *         (RSS_INDIR_SIZE u32 entries) are the requested values; either may
	 *         be NULL for "no change". `queue_count` is the active RX-queue count.
	 * Post  : on success (0) the Rust policy stores the new key/table. If the
	 *         device is running, the chip is reprogrammed live (same path as
	 *         open); if it is down, the next open programs the cached policy. An
	 *         out-of-range indirection entry returns -EINVAL with the policy
	 *         unchanged.
	 */
	int (*rss_set)(void *priv, const u8 *key_in, const u32 *indir_in,
		       unsigned int queue_count);

	/*
	 * set_channels(priv, rx_count) — ethtool set_channels (-L)
	 * ───────────────────────────
	 * Pre   : RTNL held. C has already rejected tx/combined changes; rx_count
	 *         is the requested active RX-queue count.
	 * Post  : Rust validates rx_count against owned queues + the V3/V2
	 *         prerequisites and, on success, stores it as the runtime override
	 *         consumed at the next open. Returns 0 (accepted; C then reopens to
	 *         apply) or -EINVAL (rejected; the live config is untouched).
	 */
	int (*set_channels)(void *priv, unsigned int rx_count);

	/*
	 * set_rx_mode(priv, accept, mc0, mc1) — ndo_set_rx_mode programming
	 * ──────────────────────────────────
	 * Pre   : RTNL held. C computed `accept` (RCR accept bits: a subset of
	 *         R8125_RX_ACCEPT_*) and the two natural-order 32-bit multicast
	 *         hash words from ndev->flags + the mc list.
	 * Post  : Rust merges `accept` into the live RCR (preserving descriptor /
	 *         feature bits) and writes the MAR0/MAR4 multicast hash filter.
	 */
	void (*set_rx_mode)(void *priv, unsigned int accept,
			    unsigned int mc0, unsigned int mc1);

	/*
	 * tally_dump(priv, dma_addr) — ndo_get_stats64 hardware-counter dump
	 * ──────────────────────────
	 * Pre   : RTNL/stats context. C owns the coherent buffer at `dma_addr`
	 *         (sizeof(struct r8125_tally)) and reads it after the call.
	 * Post  : Rust drives the chip's DMA dump handshake into that buffer.
	 *         Returns 0 on success, negative on timeout (C then leaves the
	 *         hardware-error stats unchanged).
	 */
	int (*tally_dump)(void *priv, u64 dma_addr);

	/*
	 * tally_reset(priv, dma_addr) — zero the on-die tally counters
	 * ──────────────────────────
	 * Issued once from bridge_ndo_open after the chip's RX is enabled, so the
	 * extended counters (octets, collisions, pause frames) begin a clean
	 * per-session baseline. Same DMA handshake as tally_dump; 0 on success.
	 */
	int (*tally_reset)(void *priv, u64 dma_addr);

	/*
	 * get_wol(priv) / set_wol(priv, wolopts) — ethtool Wake-on-LAN
	 * ──────────────────────────
	 * get_wol returns the active WAKE_* mask read back from the chip
	 * (Config3.MagicPacket + Config5 wake-frame bits). set_wol programs the
	 * chip arm state; the C side validates wolopts (rejects bits outside the
	 * supported set) and manages device wakeup-enable around the call.
	 */
	u32 (*get_wol)(void *priv);
	void (*set_wol)(void *priv, u32 wolopts);

	/*
	 * wol_suspend_arm(priv, wolopts) — WoL-aware suspend arming.
	 * ──────────────────────────────
	 * Pre   : RTNL held; PM suspend has detached the netdev and disabled NAPI
	 *         but intentionally has NOT run the normal stop/phy_stop path;
	 *         wolopts != 0 (a wake source is armed).
	 * Post  : the chip is armed for Wake-on-LAN in D3 — Config3/5 wake bits +
	 *         Config1.PMEnable + Config2.PMSTS_En + RX accept filter open +
	 *         PMCH NO_PLL_DOWN so the internal PHY stays powered in D3. The PCI
	 *         core arms PME on the following D3 transition (device_may_wakeup
	 *         was set by set_wol). Resume runs a full reopen.
	 */
	void (*wol_suspend_arm)(void *priv, u32 wolopts);

	/*
	 * read_reg(priv, offset) — read one 32-bit MMIO register for `ethtool -d`.
	 * The C side loops to fill the ethtool buffer, so no raw buffer crosses
	 * the Rust boundary.
	 */
	u32 (*read_reg)(void *priv, u32 offset);

	/*
	 * set_mac_filter(priv) — reprogram the chip RX unicast filter (RAR) from
	 * the current net_device address. Called from ndo_set_mac_address when the
	 * interface is running so a live address change takes effect in hardware
	 * immediately (the open path programs it otherwise).
	 */
	void (*set_mac_filter)(void *priv);

	/*
	 * led_set_mode(priv, index, mode) / led_get_mode(priv, index) — LED
	 * netdev-trigger hardware offload. The cshim (netdev_bridge_leds.c) owns the
	 * led_classdev lifecycle and the kernel TRIGGER_NETDEV_* <-> chip LED_CTRL
	 * mapping; Rust owns the LEDSEL register choice + masked update. set returns
	 * 0 / -EINVAL; get returns the active select field (>= 0) / -EINVAL.
	 */
	int (*led_set_mode)(void *priv, u32 index, u16 mode);
	int (*led_get_mode)(void *priv, u32 index);

	/*
	 * xdp_xmit_one(priv, frame_dma, frame_len, frame) — enqueue one XDP_TX
	 * frame on the Rust-owned TX ring. Called from the XDP verdict path
	 * (netdev_bridge_xdp.c) under the txq lock, which serialises this
	 * NAPI-context producer against ndo_start_xmit. `frame_dma`/`frame_len`
	 * describe the DMA_TO_DEVICE mapping the caller made over the frame data;
	 * `frame` is the xdp_frame the reaper hands to xdp_return_frame at
	 * completion. Returns 0 on enqueue, -ENOSPC if the ring is full (the
	 * caller then unmaps + returns the frame). No doorbell is rung here.
	 */
	int (*xdp_xmit_one)(void *priv, u64 frame_dma, u32 frame_len,
			    void *frame);

	/*
	 * xdp_tx_flush(priv) — ring the TX doorbell once. Called from
	 * r8125_bridge_xdp_finalize at NAPI-poll end when at least one XDP_TX
	 * frame was enqueued during the poll, so the posted descriptors are
	 * signalled to hardware exactly once per poll.
	 */
	void (*xdp_tx_flush)(void *priv);

	/*
	 * xsk_xmit_one(priv, umem_dma, len, queue_id) — AF_XDP zero-copy TX
	 * producer. Enqueue one umem chunk (already DMA_TO_DEVICE-synced by the
	 * caller) on the TX ring, tagged so the reaper completes it back to RX
	 * queue_id's bound xsk pool (xsk_tx_completed). Called from
	 * r8125_bridge_xsk_tx under the txq lock. Returns 0 on enqueue, -ENOSPC if
	 * the ring is full.
	 */
	int (*xsk_xmit_one)(void *priv, u64 umem_dma, u32 len, u32 queue_id);

	/*
	 * xsk_kick(priv, queue_id) — AF_XDP zero-copy RX cold-start kick. Post umem
	 * buffers into the ZC RX ring from the fill ring synchronously. Called from
	 * ndo_xsk_wakeup: with an empty ring the chip takes no RX IRQ, so the wakeup
	 * must post buffers itself (serialised against the NAPI poll on the Rust
	 * side) rather than only scheduling NAPI.
	 */
	void (*xsk_kick)(void *priv, u32 queue_id);

	/*
	 * Live per-queue RX reconfigure (AF_XDP bind/unbind without a full
	 * stop+open / link-down). Phase 1 rx_quiesce: disable the chip RX engine
	 * (TX/PHY/IRQ stay up) + free this queue's RX buffers/pool with the CURRENT
	 * pool type; called under RTNL, NAPI disabled, BEFORE q->xsk_pool toggles.
	 * Phase 2 rx_restore: build the pool for the NOW-current type, re-post,
	 * reset the chip RX head, re-enable RX; called AFTER the toggle. Returns 0
	 * or -errno (RX left off on error).
	 */
	void (*rx_quiesce)(void *priv, u32 queue_id);
	int (*rx_restore)(void *priv, u32 queue_id);
};

/*
 * On-die statistics block the chip DMAs on a tally dump. Field offsets/order
 * match the RTL8125 counter block exactly (vendor `struct rtl8125_counters`):
 * the whole block is replicated so ndo_get_stats64 (leading fields) and the
 * ethtool standard-stats ops (get_eth_mac_stats / get_eth_ctrl_stats /
 * get_pause_stats — extended fields) all read the right offsets. The chip
 * writes the full block, so the struct must mirror it field-for-field.
 */
struct r8125_tally {
	/* legacy */
	__le64 tx_packets;
	__le64 rx_packets;
	__le64 tx_errors;
	__le32 rx_errors;
	__le16 rx_missed;	/* RX FIFO-overflow misses */
	__le16 align_errors;
	__le32 tx_one_collision;
	__le32 tx_multi_collision;
	__le64 rx_unicast;
	__le64 rx_broadcast;
	__le32 rx_multicast;
	__le16 tx_aborted;
	__le16 tx_underrun;
	/* extended (RTL8125) */
	__le64 tx_octets;
	__le64 rx_octets;
	__le64 rx_multicast64;
	__le64 tx_unicast64;
	__le64 tx_broadcast64;
	__le64 tx_multicast64;
	__le32 tx_pause_on;
	__le32 tx_pause_off;
	__le32 tx_pause_all;
	__le32 tx_deferred;
	__le32 tx_late_collision;
	__le32 tx_all_collision;
	__le32 tx_aborted32;
	__le32 align_errors32;
	__le32 rx_frame_too_long;
	__le32 rx_runt;
	__le32 rx_pause_on;
	__le32 rx_pause_off;
	__le32 rx_pause_all;
	__le32 rx_unknown_opcode;
	__le32 rx_mac_error;
	__le32 tx_underrun32;
	__le32 rx_mac_missed;
	__le32 rx_tcam_dropped;
	__le32 tdu;
	__le32 rdu;
};

/*
 * RX accept-filter bits (RTL8125 RxConfig low byte) the C ndo_set_rx_mode
 * computes and hands to Rust. Values match src/regs.rs RCR_ACCEPT_*.
 */
#define R8125_RX_ACCEPT_ALLPHYS		0x01
#define R8125_RX_ACCEPT_MYPHYS		0x02
#define R8125_RX_ACCEPT_MULTICAST	0x04
#define R8125_RX_ACCEPT_BROADCAST	0x08
#define R8125_RX_ACCEPT_RUNT		0x10
#define R8125_RX_ACCEPT_ERR		0x20

/* Max multicast groups we program individually before falling back to allmulti
 * (64-bit hash; above this the hash saturates, so allmulti is equivalent and
 * cheaper than walking a huge list).
 */
#define R8125_MC_HASH_MAX		64

/* TX/RX descriptor ring depth, reported by ethtool -g (get_ringparam). MUST
 * equal Rust `ring::RING_LEN` (asserted by ci/check_surface_inventory.sh).
 * Resize (set_ringparam) is intentionally unsupported for the first RFC, so
 * `ethtool -G` returns -EOPNOTSUPP.
 */
#define R8125_BRIDGE_RING_LEN		256

#define R8125_BRIDGE_FEATURE_RXCSUM	0x00000001U
#define R8125_BRIDGE_FEATURE_RXVLAN	0x00000002U
#define R8125_BRIDGE_FEATURE_RXHASH	0x00000004U

/* RSS table geometry exposed via ethtool. These MUST equal the Rust
 * source-of-truth constants — regs::RSS_KEY_SIZE (40) and
 * layout::RSS_INDIR_TBL_ENTRIES (128); ci/check_rss_ethtool.sh asserts it.
 */
#define R8125_RSS_KEY_SIZE	40U
#define R8125_RSS_INDIR_SIZE	128U

/* ──────────────────────────────────────────────────────────────────────
 *  Lifecycle: alloc → register → … → unregister_and_free.
 *
 *  Allocation accounting (the TX disposition invariant) is initialised in
 *  the alloc call; `r8125_bridge_counters_snapshot` exposes the running totals.
 * ──────────────────────────────────────────────────────────────────────
 */

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
 * register; do not also call free() afterwards.
 */
void r8125_bridge_unregister_and_free(struct net_device *ndev);

/*
 * Pin the MSI-X (or MSI/INTx) vector `irq` to `cpu` via
 * `irq_set_affinity_and_hint`. Latency-aligned default
 * (RX_OPTIMIZATION_CANDIDATES.md). Returns 0 on
 * success or a negative errno; the kernel auto-clears the hint at
 * `free_irq`.
 */
int r8125_bridge_irq_pin_cpu(unsigned int irq, int cpu);
void r8125_bridge_irq_clear_hint(unsigned int irq);

/*
 * Multi-queue affinity-spread inputs. The Rust side's host-tested
 * `layout::irq_affinity_cpu` decides each vector's CPU; these feed it the
 * kernel facts: the online-CPU count (fan-out width) and the PCI-local
 * NUMA-node first-online CPU (fan-out base, negative errno if none online).
 */
unsigned int r8125_bridge_num_online_cpus(void);
int r8125_bridge_node_base_cpu(struct pci_dev *pdev);

/* DMA read barrier after an RX descriptor's OWN bit clears. Mirrors
 * r8169's rtl_rx ordering: descriptor fields and DMA-written bytes are
 * not read until the device's OWN-clear publish is visible.
 */
void r8125_bridge_dma_rmb(void);

/* DMA write barrier before publishing a descriptor with the DescOwn bit
 * set. Pair with the chip's view: without this, the chip could observe
 * `opts1`'s OWN-set before the matching `addr`/`opts2` stores are
 * visible on weakly-ordered archs (ARM, RISC-V). r8169 uses dma_wmb()
 * at the equivalent points.
 */
void r8125_bridge_dma_wmb(void);

/* ──────────────────────────────────────────────────────────────────────
 *  Flow-control + NAPI-arming helpers — the TX disposition invariants live here.
 * ──────────────────────────────────────────────────────────────────────
 */

/* Stop the TX queue. Call from xmit BEFORE the ring fills, NOT in the
 * NETDEV_TX_BUSY hot path. Safe from xmit context.
 */
void r8125_bridge_tx_stop_queue(struct net_device *ndev);

/* Wake the TX queue. Call from the completion reaper once descriptors are
 * available again. Safe from NAPI / IRQ-thread context.
 */
void r8125_bridge_tx_wake_queue(struct net_device *ndev);

/* netdev_xmit_more() batching hint — true if the qdisc has more queued packets
 * for this xmit burst, so the driver may defer the TX doorbell. MSI-safe.
 */
bool r8125_bridge_netdev_xmit_more(void);

/* Fill `key[0..len]` with the boot-stable system RSS hash key
 * (netdev_rss_key_fill). Used by the single-queue RXHASH path.
 */
void r8125_bridge_rss_key_fill(u8 *key, u32 len);

/* Return Linux's default RSS indirection entry for `index` and `n_rx_rings`.
 * Used by Rust when programming the RTL8125 indirection table.
 */
u32 r8125_bridge_rxfh_indir_default(u32 index, u32 n_rx_rings);

/* Schedule a NAPI poll. Safe to call from atomic (IRQ) context. */
void r8125_bridge_napi_schedule(struct net_device *ndev, unsigned int queue_id);

/* Tell NAPI we processed `work_done` frames this round and are done. The
 * driver MUST call this from inside the poll callback before returning
 * `work_done` when `work_done < budget`.
 */
void r8125_bridge_napi_complete_done(struct net_device *ndev,
				     unsigned int queue_id, int work_done);

/* Set the runtime active RX queue count: updates ethtool reporting and
 * netif_set_real_num_rx_queues. Called from Rust ndo_open under RTNL. Clamped
 * to [1, R8125_BRIDGE_RX_QUEUE_COUNT].
 */
void r8125_bridge_set_active_rx_queues(struct net_device *ndev, unsigned int n);

/* Copy ndev->dev_addr out (6 bytes) so the Rust open path can program the chip
 * RX filter (rar_set) from the address the alloc path settled on.
 */
void r8125_bridge_dev_addr(struct net_device *ndev, unsigned char out[ETH_ALEN]);

/*
 * Reconfigure a running netdev (ethtool set_channels): stop then re-open so the
 * new runtime RX-queue count is applied (re-IRQ, re-NAPI, RSS reprogram,
 * netif_set_real_num_rx_queues). Called under RTNL from the ethtool op. Returns
 * 0 or a negative errno from the re-open (leaving the netdev down on failure).
 */
int r8125_bridge_reopen(struct net_device *ndev);

/* System-sleep PM (called from the Rust pci::Driver suspend/resume callbacks).
 * suspend: detach + quiesce if up; resume: re-init + attach if it was up. The
 * PCI core handles config save/restore + D-state around these.
 */
void r8125_bridge_pm_suspend(struct net_device *ndev);
int r8125_bridge_pm_resume(struct net_device *ndev);

/* PCIe AER teardown + resume (RTNL-free; called under pci_bus_sem). detach is
 * full-stop for Frozen/unknown channels (sets a flag the resume consumes so it
 * re-opens only what it tore down) and detach-only for permanent failure (the
 * AER core may not call resume; remove owns final teardown). Rust-gated on
 * r8125_pci_aer.
 */
void r8125_bridge_pm_error_detach(struct net_device *ndev, bool full_stop);
int r8125_bridge_pm_error_resume(struct net_device *ndev);

/* Runtime PM (autosuspend while the interface is closed). Rust-gated on
 * r8125_pci_runtime_pm. idle returns 0 (idle) / -EBUSY (keep active);
 * suspend/resume only detach/attach (closed device); enable/disable manage the
 * probe/unbind usage reference + the b->runtime_pm bracket flag.
 */
int r8125_bridge_runtime_idle(struct net_device *ndev);
void r8125_bridge_runtime_suspend(struct net_device *ndev);
void r8125_bridge_runtime_resume(struct net_device *ndev);
void r8125_bridge_pm_runtime_enable(struct net_device *ndev);
void r8125_bridge_pm_runtime_disable(struct net_device *ndev);

/* Link-state helpers — Rust calls these after detecting carrier change. */
void r8125_bridge_carrier_on(struct net_device *ndev);
void r8125_bridge_carrier_off(struct net_device *ndev);

/* Convenience: full TX-queue disable (used at ndo_stop). */
void r8125_bridge_tx_disable(struct net_device *ndev);

/* ──────────────────────────────────────────────────────────────────────
 *  sk_buff helpers — Rust never dereferences `struct sk_buff` directly.
 *  Every read/write goes through one of these (type-state).
 *
 *  Each helper documents the counter side-effect; the Rust type-state
 *  in `src/skb.rs` mirrors these into `TxSkb<S>` transitions.
 * ──────────────────────────────────────────────────────────────────────
 */

/* DMA-unmap. No counter change here; skb consume/free is the counter event. */
void r8125_bridge_skb_dma_unmap_tx(struct device *dev,
				   dma_addr_t handle, size_t len);
void r8125_bridge_skb_dma_unmap_frag_tx(struct device *dev,
					dma_addr_t handle, size_t len);

/* ──────────────────────────────────────────────────────────────────────
 *  Jumbo RX-pool: per-slot streaming-DMA allocator.
 *
 *  The earlier 2 KiB coherent-ring design used one allocation sized for
 *  256 slots. This design uses `page_pool` because fragmented systems
 *  cannot reliably allocate 4 MiB contiguous DMA-coherent memory.
 *  These helpers own the zero-copy RX buffer lifecycle: a
 *  per-MTU page_pool at ndo_open, with napi_build_skb delivery +
 *  page recycling. Implementation: netdev_bridge_rx_pool.c.
 *
 *  Lifecycle: `ndo_open` calls `rx_pool_create` (returns the per-buffer
 *  device-writable length) then `rx_alloc` per ring slot; `ndo_stop`
 *  calls `rx_free` per slot then `rx_pool_destroy`. The NAPI RX super-call
 *  below owns the streaming-DMA sync + the alloc-before-consume refill.
 * ──────────────────────────────────────────────────────────────────────
 */
int  r8125_bridge_rx_pool_create(struct net_device *ndev, unsigned int queue_id,
				 unsigned int ring_len, u32 *out_buf_len);
void r8125_bridge_rx_pool_destroy(struct net_device *ndev, unsigned int queue_id);
int  r8125_bridge_rx_alloc(struct net_device *ndev, unsigned int queue_id,
			   void **out_cpu, dma_addr_t *out_dma);
void r8125_bridge_rx_free(struct net_device *ndev, unsigned int queue_id,
			  void *cpu);

/*
 * `r8125_bridge_rx_one_packet` — zero-copy RX super-call
 * (docs/RX_OPTIMIZATION_CANDIDATES.md). Hands the received page
 * to the stack via napi_build_skb + skb_mark_for_recycle (no copy), and
 * refills the slot alloc-before-consume from the pool. Outputs the slot's
 * refilled (cpu, dma); on a refill-failure drop they equal the inputs.
 * Bumps `rx_dropped_error` internally on failure. NAPI-poll context only.
 */
void r8125_bridge_rx_one_packet(struct net_device *ndev,
				unsigned int queue_id, dma_addr_t dma, const void *buf,
				size_t len, u32 desc_opts1, u32 desc_opts2,
				u64 hash_info,
				void **new_cpu, dma_addr_t *new_dma);



/*
 * Free an skb on the TX-error path (validation reject, DMA-map failure,
 * etc.). Counter: tx_dropped_error++. Calls `dev_kfree_skb_any` exactly
 * once; the skb pointer is invalid after this call.
 *
 * This is the "(c) drop_with_error" disposition.
 */
void r8125_bridge_skb_free_error(struct sk_buff *skb);

/* Count a NETDEV_TX_BUSY return where the kernel retains skb ownership.
 * Call only on the documented exceptional ring-full race path.
 */
void r8125_bridge_tx_busy_exception(struct net_device *ndev);

/* ndo_change_mtu support for per-MTU zero-copy RX: detect the running
 * state, and (when up) re-open at the new MTU with the napi_disable/enable
 * bracket so the RX page_pool is never destroyed mid-NAPI. On failure,
 * the shim restores the old MTU before returning an error so callers see
 * stable state. See `netdev::rust_change_mtu`.
 */
bool r8125_bridge_netif_running(struct net_device *ndev);
int  r8125_bridge_reopen_for_mtu(struct net_device *ndev, int new_mtu);

/* ──────────────────────────────────────────────────────────────────────
 *  HW checksum offload.
 *
 *  The Rust ndo_start_xmit / napi::poll paths don't peek into sk_buff internals.
 *  The cshim gathers protocol facts and applies the side effects chosen by the
 *  Rust TX policy (`src/tx_offload.rs`), including descriptor bits, feature
 *  vetoes, and software-checksum fallback. On RX, the cshim consumes descriptor
 *  `opts1` to set `skb->ip_summed = CHECKSUM_UNNECESSARY` when the chip
 *  validated the checksum.
 *
 *  The RTL8125 pad quirk mirrors r8169/vendor scope: normal short UDP
 *  checksum-partial packets stay on hardware checksum; only PTP event
 *  UDP ports 319/320 with transport data < 47 bytes, packets shorter
 *  than their transport header, or frames below ETH_ZLEN are padded and
 *  software-checksummed before DMA mapping. If padding or checksum
 *  completion fails, combined TX offload prep returns a negative errno; Rust
 *  drops the skb before DMA mapping.
 */

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

/* Bump TX netdev stats from inside the cshim. RX accounting lives in
 * `r8125_bridge_rx_one_packet`, next to `napi_gro_receive`, so the
 * Rust RX hot path makes a single cshim call per packet.
 */
void r8125_bridge_account_tx(struct net_device *ndev, unsigned int bytes);

/* ──────────────────────────────────────────────────────────────────────
 *  Scatter-gather TX + TSO.
 *
 *  For multi-fragment skbs we post one descriptor per
 *  (linear-head + each paged frag); the chip walks them from FirstFrag
 *  to LastFrag. The Rust hot-path doesn't see sk_buff internals — the
 *  cshim does the introspection and DMA mapping.
 * ──────────────────────────────────────────────────────────────────────
 */

/* Map the LINEAR head of `skb` (skb->data .. +skb_headlen) for TX DMA.
 * Returns 0 on success, negative errno on mapping failure.
 */
int r8125_bridge_skb_data_dma_map(struct device *dev, struct sk_buff *skb,
				  dma_addr_t *out_handle, unsigned int *out_len);

/* Map paged fragment `frag_idx` (0 .. nr_frags-1) for TX DMA. Uses
 * skb_frag_dma_map (page-aware) under the hood.
 */
int r8125_bridge_skb_frag_dma_map(struct device *dev, struct sk_buff *skb,
				  unsigned int frag_idx,
				  dma_addr_t *out_handle, unsigned int *out_len);

/* Combined TX offload prep for Rust's hot xmit path: fills opts1/opts2 and
 * returns nr_frags in one FFI crossing. May mutate skb for v6 TSO or the
 * narrow RTL8125 pad/software-checksum quirk, so call before DMA mapping.
 */
int r8125_bridge_skb_tx_offload_prepare(struct sk_buff *skb,
					u32 *opts1_bits, u32 *opts2_bits,
					unsigned int *nr_frags);

/* Consume an skb on TX completion (no DMA unmap — caller did per-
 * descriptor unmap already). Bumps netdev->stats.tx_{packets,bytes}
 * from skb->len and hands the skb back to NAPI for recycling. Returns the
 * wire length (skb->len) so the NAPI reaper can batch it into
 * netdev_completed_queue() for BQL.
 */
unsigned int r8125_bridge_skb_consume_tx(struct net_device *ndev,
					 struct sk_buff *skb);

/* Wire length (skb->len) for the BQL sent_queue at the xmit commit. */
unsigned int r8125_bridge_skb_len(const struct sk_buff *skb);

/* BQL (byte queue limits) — Approach A (docs/BQL_RETRY_PLAN.md). Seed the
 * dql floor at open (no netdev_reset_queue), feed sent at the xmit commit
 * and completed (batched) at the NAPI reap. Bounds TX ring residency so
 * fq_codel can protect latency under a saturated bulk flow.
 */
void r8125_bridge_dql_seed_min_limit(struct net_device *ndev);
bool r8125_bridge_netdev_sent_queue(struct net_device *ndev,
				    unsigned int bytes, bool xmit_more);
void r8125_bridge_netdev_completed_queue(struct net_device *ndev,
					 unsigned int pkts, unsigned int bytes);

/* ──────────────────────────────────────────────────────────────────────
 *  Counter snapshot — the invariant `tx_received == tx_consumed +
 *  tx_busy_exception + tx_dropped_error`. CI smoke test reads this at
 *  quiesce and asserts.
 * ──────────────────────────────────────────────────────────────────────
 */
struct r8125_bridge_counters {
	u64 tx_received;
	u64 tx_consumed;
	u64 tx_busy_exception;
	u64 tx_dropped_error;
	u64 rx_handed_to_stack;
	u64 rx_dropped_error;
	u64 rx_hash_l3;
	u64 rx_hash_l4;
	u64 rx_hash_missing;
	u64 rx_hash_disabled;
};
void r8125_bridge_counters_snapshot(struct net_device *ndev,
				    struct r8125_bridge_counters *out);

/* ──────────────────────────────────────────────────────────────────────
 *  PHY plumbing.
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
 * ──────────────────────────────────────────────────────────────────────
 */

/* MDIO read/write: u16 in [0, 0xFFFF] on success, negative errno on
 * failure. Called from process context (RTNL held). The C45 variants
 * add an MMD device address (devad) — only MDIO_MMD_VEND2 with a
 * regnum > MDIO_STAT2 actually reaches the chip; other (devad, regnum)
 * combinations return 0 (read) / -ENODEV (write), matching r8169.
 */
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

/* Jumbo MTU config: raise PCIe readrq to 4096 and, when MTU > ETH_DATA_LEN,
 * disable pause on the PHY (the chip does not support pause in jumbo mode).
 * Mirrors mainline r8169's `rtl_jumbo_config`. Safe to call after the PHY
 * has been connected + reset but before the chip RX/TX engines are enabled.
 */
void r8125_bridge_jumbo_config(struct net_device *ndev, bool jumbo);

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
 * safe to call when phy_start was never reached.
 */
void r8125_bridge_phy_stop(struct net_device *ndev);

/* PHY errata register-access glue (phylib paged/MMD accessors) — driven by the
 * Rust hw_phy_config table in src/phy_config.rs.
 */
void r8125_bridge_phy_modify_paged(struct net_device *ndev, u16 page, u16 reg,
				   u16 mask, u16 set);
void r8125_bridge_phy_write_paged(struct net_device *ndev, u16 page, u16 reg,
				  u16 val);
void r8125_bridge_phy_write_mmd(struct net_device *ndev, u16 devad, u16 reg,
				u16 val);
void r8125_bridge_phy_modify_mmd(struct net_device *ndev, u16 devad, u16 reg,
				 u16 mask, u16 set);
void r8125_bridge_set_fw_version(struct net_device *ndev, const char *ver);

#endif /* _R8125_NETDEV_BRIDGE_H */
