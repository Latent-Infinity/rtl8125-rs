// SPDX-License-Identifier: GPL-2.0
/*
 * PHY / MDIO bridge for r8125_rust.
 *
 * The C side owns mii_bus + phy_device because those kernel surfaces are
 * not stable Rust APIs yet. Rust owns the BAR and supplies MDIO callbacks.
 */

#include "netdev_bridge_internal.h"

#include <linux/etherdevice.h>
#include <linux/errno.h>
#include <linux/mdio.h>
#include <linux/mii.h>
#include <linux/phy.h>

static int bridge_mii_read(struct mii_bus *bus, int phyaddr, int phyreg)
{
	struct r8125_bridge *b = bus->priv;

	if (phyaddr != 0)
		return -ENODEV;
	if (phyreg < 0 || phyreg > 31)
		return -EINVAL;
	if (!b->mdio_ops.read)
		return -ENXIO;
	return b->mdio_ops.read(b->priv, phyreg);
}

static int bridge_mii_write(struct mii_bus *bus, int phyaddr, int phyreg,
			    u16 val)
{
	struct r8125_bridge *b = bus->priv;

	if (phyaddr != 0)
		return -ENODEV;
	if (phyreg < 0 || phyreg > 31)
		return -EINVAL;
	if (!b->mdio_ops.write)
		return -ENXIO;
	return b->mdio_ops.write(b->priv, phyreg, val);
}

/* MDIO Clause-45 (MMD) read/write — mirrors r8169_mdio_read_reg_c45.
 * Required so the dedicated "Realtek Internal NBASE-T PHY" driver's
 * probe (rtl822x_hwmon_init → phy_clear_bits_mmd) and get_features
 * (phy_read_mmd of RTL_MDIO_PMA_SPEED for 2.5G capability) work,
 * unblocking 2.5G negotiation. Only MDIO_MMD_VEND2 + regnum > MDIO_STAT2
 * reaches the chip; other combinations return 0 / -ENODEV. */
static int bridge_mii_read_c45(struct mii_bus *bus, int phyaddr, int devad,
			       int phyreg)
{
	struct r8125_bridge *b = bus->priv;

	if (phyaddr != 0)
		return -ENODEV;
	if (!b->mdio_ops.read_c45)
		return -EOPNOTSUPP;
	return b->mdio_ops.read_c45(b->priv, devad, phyreg);
}

static int bridge_mii_write_c45(struct mii_bus *bus, int phyaddr, int devad,
				int phyreg, u16 val)
{
	struct r8125_bridge *b = bus->priv;

	if (phyaddr != 0)
		return -ENODEV;
	if (!b->mdio_ops.write_c45)
		return -EOPNOTSUPP;
	return b->mdio_ops.write_c45(b->priv, devad, phyreg, val);
}

static void bridge_phylink_handler(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct phy_device *phydev = b->phydev;

	if (!phydev)
		return;
	if (phydev->link)
		netif_carrier_on(ndev);
	else
		netif_carrier_off(ndev);
	phy_print_status(phydev);
}

int r8125_bridge_phy_register(struct net_device *ndev,
			      const struct r8125_bridge_mdio_ops *ops)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	struct mii_bus *bus;
	int ret;

	if (!ops || !ops->read || !ops->write)
		return -EINVAL;

	b->mdio_ops = *ops;
	bus = mdiobus_alloc();
	if (!bus)
		return -ENOMEM;

	bus->name = "r8125_rust";
	bus->priv = b;
	bus->parent = &b->pdev->dev;
	bus->phy_mask = GENMASK(31, 1);
	snprintf(bus->id, MII_BUS_ID_SIZE, "r8125_rust-%x-%x",
		 pci_domain_nr(b->pdev->bus), pci_dev_id(b->pdev));
	bus->read = bridge_mii_read;
	bus->write = bridge_mii_write;
	/* C45 callbacks — see comment on bridge_mii_read_c45 above. Without
	 * these the Realtek NBASE-T PHY driver fails to bind and genphy
	 * fallback caps the link at 1G. */
	bus->read_c45 = bridge_mii_read_c45;
	bus->write_c45 = bridge_mii_write_c45;

	ret = mdiobus_register(bus);
	if (ret) {
		dev_err(&b->pdev->dev,
			"r8125_rust: mdiobus_register failed: %d\n", ret);
		mdiobus_free(bus);
		return ret;
	}
	b->mii_bus = bus;

	b->phydev = mdiobus_get_phy(bus, 0);
	if (!b->phydev) {
		dev_err(&b->pdev->dev,
			"r8125_rust: no PHY device found at MDIO addr 0\n");
		return -ENODEV;
	}
	if (!b->phydev->drv) {
		dev_err(&b->pdev->dev,
			"r8125_rust: no PHY driver bound for phy_id 0x%08x\n",
			b->phydev->phy_id);
		return -EUNATCH;
	}

	dev_info(&b->pdev->dev,
		 "r8125_rust: PHY attached: %s (phy_id=0x%08x)\n",
		 b->phydev->drv->name, b->phydev->phy_id);
	b->phydev->mac_managed_pm = true;
	phy_support_asym_pause(b->phydev);
	return 0;
}
EXPORT_SYMBOL_GPL(r8125_bridge_phy_register);

int r8125_bridge_phy_connect_and_reset(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);
	int ret;

	if (!b->phydev)
		return -ENODEV;
	if (b->phy_connected)
		return 0;

	ret = phy_connect_direct(ndev, b->phydev, bridge_phylink_handler,
				 PHY_INTERFACE_MODE_GMII);
	if (ret) {
		dev_err(&b->pdev->dev,
			"r8125_rust: phy_connect_direct failed: %d\n", ret);
		return ret;
	}
	b->phy_connected = true;

	ret = phy_init_hw(b->phydev);
	if (ret)
		goto disconnect;
	ret = genphy_soft_reset(b->phydev);
	if (ret)
		goto disconnect;
	ret = phy_resume(b->phydev);
	if (ret)
		goto disconnect;
	return 0;

disconnect:
	dev_err(&b->pdev->dev, "r8125_rust: PHY reset/resume failed: %d\n", ret);
	phy_disconnect(b->phydev);
	b->phy_connected = false;
	return ret;
}
EXPORT_SYMBOL_GPL(r8125_bridge_phy_connect_and_reset);

int r8125_bridge_phy_kick_state_machine(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (!b->phydev || !b->phy_connected)
		return -ENODEV;
	phy_start(b->phydev);
	return 0;
}
EXPORT_SYMBOL_GPL(r8125_bridge_phy_kick_state_machine);

void r8125_bridge_phy_stop(struct net_device *ndev)
{
	struct r8125_bridge *b = netdev_priv(ndev);

	if (!b->phydev || !b->phy_connected)
		return;
	phy_stop(b->phydev);
	phy_disconnect(b->phydev);
	b->phy_connected = false;
}
EXPORT_SYMBOL_GPL(r8125_bridge_phy_stop);
