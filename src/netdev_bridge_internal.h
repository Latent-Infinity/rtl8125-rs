/* SPDX-License-Identifier: GPL-2.0 */
#ifndef _R8125_NETDEV_BRIDGE_INTERNAL_H
#define _R8125_NETDEV_BRIDGE_INTERNAL_H

#include "netdev_bridge.h"

#include <linux/atomic.h>
#include <linux/mdio.h>
#include <linux/mii.h>
#include <linux/netdevice.h>
#include <linux/pci.h>
#include <linux/phy.h>

struct r8125_bridge {
	struct net_device *ndev;
	struct pci_dev *pdev;
	struct napi_struct napi;
	void *priv;
	struct r8125_bridge_ops ops;

	struct mii_bus *mii_bus;
	struct phy_device *phydev;
	struct r8125_bridge_mdio_ops mdio_ops;
	bool phy_connected;

	u64 tx_received;
	u64 tx_consumed;
	u64 tx_busy_exception;
	u64 tx_dropped_error;
	u64 rx_handed_to_stack;
	u64 rx_dropped_error;
};

#endif /* _R8125_NETDEV_BRIDGE_INTERNAL_H */
