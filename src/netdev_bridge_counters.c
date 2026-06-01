// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_counters.c — per-CPU storage for the §6.3 disposition
 * counters.
 *
 * The six counters (tx_received / tx_consumed / tx_busy_exception /
 * tx_dropped_error / rx_handed_to_stack / rx_dropped_error) used to be
 * plain `u64` fields in `struct r8125_bridge`, incremented with
 * WRITE_ONCE(READ_ONCE+1). Under load that pattern is a contended cache
 * line — every TX side calls `tx_received++` from process/BH context
 * while the NAPI reaper calls `tx_consumed++` from softirq, ping-ponging
 * the line between TX and RX CPUs (RUST_STANDARDS.md §15.2 — sharing
 * lines between independent hot contexts serialises them).
 *
 * Per-CPU storage replaces both writer-side WRITE_ONCEs with
 * `this_cpu_inc(*b->X)` (a single decorated INC on x86, no cache-line
 * traffic) and replaces the reader side with a `for_each_possible_cpu`
 * sum at snapshot time (ethtool -S / the runtime invariant check).
 *
 * Lives in its own translation unit so `netdev_bridge.c` stays within
 * its 400-line review cap.
 *
 * Hard cap: 200 LOC. Enforced by ci/check_cshim_loc_caps.sh.
 */

#include "netdev_bridge_internal.h"

#include <linux/percpu.h>

/* Allocate the six per-CPU counters in lockstep; on partial failure
 * release any partial successes and return -ENOMEM. `free_percpu(NULL)`
 * is a no-op, so the free helper is safe to call from this rollback.
 */
int r8125_bridge_counters_alloc(struct r8125_bridge *b)
{
	b->tx_received        = alloc_percpu(u64);
	b->tx_consumed        = alloc_percpu(u64);
	b->tx_busy_exception  = alloc_percpu(u64);
	b->tx_dropped_error   = alloc_percpu(u64);
	b->rx_handed_to_stack = alloc_percpu(u64);
	b->rx_dropped_error   = alloc_percpu(u64);
	if (!b->tx_received || !b->tx_consumed || !b->tx_busy_exception ||
	    !b->tx_dropped_error || !b->rx_handed_to_stack ||
	    !b->rx_dropped_error) {
		r8125_bridge_counters_free(b);
		return -ENOMEM;
	}
	return 0;
}

void r8125_bridge_counters_free(struct r8125_bridge *b)
{
	free_percpu(b->tx_received);
	free_percpu(b->tx_consumed);
	free_percpu(b->tx_busy_exception);
	free_percpu(b->tx_dropped_error);
	free_percpu(b->rx_handed_to_stack);
	free_percpu(b->rx_dropped_error);
	b->tx_received = NULL;
	b->tx_consumed = NULL;
	b->tx_busy_exception = NULL;
	b->tx_dropped_error = NULL;
	b->rx_handed_to_stack = NULL;
	b->rx_dropped_error = NULL;
}

/* Sum one per-CPU counter across all possible CPUs.
 *
 * `READ_ONCE` pairs with `this_cpu_inc()` (which the kernel guarantees
 * is an atomic decorated INC) — the reader sees a coherent u64 from
 * each CPU's slot. We make no attempt to freeze the per-CPU values
 * during the walk; the snapshot is an instantaneous photograph and
 * small aggregate skew is acceptable for the ethtool/invariant-check
 * use cases (the §6.3 invariant runtime check quiesces TX via a link
 * down/up cycle before reading, so writers are silent at snapshot
 * time anyway).
 */
static u64 bridge_counter_sum(u64 __percpu *counter)
{
	u64 sum = 0;
	int cpu;

	for_each_possible_cpu(cpu)
		sum += READ_ONCE(*per_cpu_ptr(counter, cpu));
	return sum;
}

void r8125_bridge_counters_snapshot(struct net_device *ndev,
				    struct r8125_bridge_counters *out)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	out->tx_received        = bridge_counter_sum(b->tx_received);
	out->tx_consumed        = bridge_counter_sum(b->tx_consumed);
	out->tx_busy_exception  = bridge_counter_sum(b->tx_busy_exception);
	out->tx_dropped_error   = bridge_counter_sum(b->tx_dropped_error);
	out->rx_handed_to_stack = bridge_counter_sum(b->rx_handed_to_stack);
	out->rx_dropped_error   = bridge_counter_sum(b->rx_dropped_error);
}
EXPORT_SYMBOL_GPL(r8125_bridge_counters_snapshot);
