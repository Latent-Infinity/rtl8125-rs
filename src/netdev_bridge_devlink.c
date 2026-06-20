// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_devlink.c — a devlink instance + a "tx" health reporter for the
 * r8125_rust driver. It surfaces the existing TX-watchdog recovery
 * (ndo_tx_timeout -> reset_work -> r8125_bridge_reopen) through the standard
 * devlink-health API, so an operator can `devlink health show/diagnose/recover`
 * the interface and see the TX-timeout error count + last recovery. Neither C
 * driver (mainline r8169, vendor r8125) exposes this.
 *
 * The recovery POLICY (a full chip reopen) is unchanged and lives in the bridge;
 * this file only wires the kernel devlink objects. reset_work calls
 * the devlink health-report helper, which records the error and — because we provide a
 * .recover op (auto_recover = !!ops->recover) — invokes the reporter's recover to
 * do the reopen. `devlink health recover` triggers the same path manually. If the
 * devlink instance failed to allocate, reset_work falls back to a direct reopen.
 *
 * Needs CONFIG_NET_DEVLINK. Hard cap: 170 LOC. Enforced by
 * ci/check_cshim_loc_caps.sh.
 */
#include "netdev_bridge_internal.h"

#include <linux/slab.h>
#include <linux/rtnetlink.h>
#include <linux/workqueue.h>
#include <net/devlink.h>

/* Opaque handle stored in r8125_bridge.devlink (set up at register, torn down at
 * unregister). Keeps the devlink + reporter pointers together.
 */
struct r8125_bridge_devlink {
	struct devlink *devlink;
	struct devlink_health_reporter *tx_reporter;
};

/* No devlink params/ports/resources — only a health reporter. */
static const struct devlink_ops r8125_bridge_devlink_ops = { 0 };

/*
 * Reporter .recover: re-init the chip after a TX-watchdog timeout. Runs in
 * devlink (process) context, so take RTNL and reuse the same full reopen the
 * automatic reset_work path uses. No-op (success) when the interface is down.
 */
static int r8125_bridge_devlink_tx_recover(struct devlink_health_reporter *reporter,
					   void *priv_ctx,
					   struct netlink_ext_ack *extack)
{
	struct r8125_bridge *b = devlink_health_reporter_priv(reporter);
	struct net_device *ndev = b->ndev;
	int rc = 0;

	(void)priv_ctx;
	(void)extack;
	rtnl_lock();
	if (netif_running(ndev))
		rc = r8125_bridge_reopen(ndev);
	rtnl_unlock();
	return rc;
}

/*
 * Reporter .test: let `devlink health test` exercise the TX-timeout recovery on
 * demand. It must NOT raise the health report directly: the core invokes .test
 * (and .recover) with the reporter lock HELD, and the report path re-takes that
 * lock — the recursive self-deadlock that bit us once. Instead schedule the SAME
 * reset_work the real ndo_tx_timeout watchdog schedules; it reports +
 * auto-recovers from process context with no reporter lock held, so there is no
 * re-entrancy. schedule_work is non-blocking and lock-free, safe under .test.
 * Like a real timeout, the test causes a chip reopen (a brief link blip).
 */
static int r8125_bridge_devlink_tx_test(struct devlink_health_reporter *reporter,
					struct netlink_ext_ack *extack)
{
	struct r8125_bridge *b = devlink_health_reporter_priv(reporter);

	(void)extack;
	schedule_work(&b->reset_work);
	return 0;
}

static const struct devlink_health_reporter_ops r8125_bridge_tx_reporter_ops = {
	.name = "tx",
	.recover = r8125_bridge_devlink_tx_recover,
	.test = r8125_bridge_devlink_tx_test,
};

/*
 * Allocate + register the devlink instance and its TX health reporter. Called
 * once from r8125_bridge_register after the netdev is live. Best-effort: returns
 * NULL on failure (the driver then keeps the direct-reopen recovery). The
 * reporter is created BEFORE devlink_register per the modern split-registration
 * rule (all sub-objects before register).
 */
void *r8125_bridge_devlink_init(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct r8125_bridge_devlink *dl;
	struct devlink *devlink;

	dl = kzalloc(sizeof(*dl), GFP_KERNEL);
	if (!dl)
		return NULL;

	devlink = devlink_alloc(&r8125_bridge_devlink_ops, 0, &b->pdev->dev);
	if (!devlink) {
		kfree(dl);
		return NULL;
	}
	dl->devlink = devlink;

	dl->tx_reporter = devlink_health_reporter_create(devlink,
							 &r8125_bridge_tx_reporter_ops,
							 b);
	if (IS_ERR(dl->tx_reporter)) {
		devlink_free(devlink);
		kfree(dl);
		return NULL;
	}

	devlink_register(devlink);
	return dl;
}

/* Unregister + free the devlink instance. Reporter destroyed after unregister. */
void r8125_bridge_devlink_remove(void *cookie)
{
	struct r8125_bridge_devlink *dl = cookie;

	if (!dl)
		return;
	devlink_unregister(dl->devlink);
	devlink_health_reporter_destroy(dl->tx_reporter);
	devlink_free(dl->devlink);
	kfree(dl);
}

/*
 * Report a TX-watchdog timeout to the health reporter. Records the error
 * (count + timestamp visible via `devlink health show`) and, because the
 * reporter has a .recover op, auto-recovers via it (the chip reopen). Called
 * from reset_work (process context — devlink_health_report may sleep).
 */
void r8125_bridge_devlink_report_tx_timeout(void *cookie)
{
	struct r8125_bridge_devlink *dl = cookie;

	if (dl && dl->tx_reporter)
		devlink_health_report(dl->tx_reporter,
				      "TX queue watchdog timeout", NULL);
}

MODULE_LICENSE("GPL v2");
