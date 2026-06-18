// SPDX-License-Identifier: GPL-2.0
/*
 * netdev_bridge_leds.c — RTL8125 PHY LED netdev-trigger hardware offload.
 *
 * The led_classdev lifecycle and the kernel TRIGGER_NETDEV_* <-> chip LED_CTRL
 * mapping live here (this is kernel LED-class + trigger-enum knowledge); the
 * LEDSEL register selection + masked update are Rust (crate::led, host-tested),
 * reached through ops.led_set_mode / ops.led_get_mode. Ported from mainline
 * r8169_leds.c (rtl8125 path). Best-effort: LED registration failure never fails
 * probe (mirrors r8169 "ignore errors").
 *
 * Hard cap: 180 LOC. Enforced by ci/check_cshim_loc_caps.sh.
 */
#include "netdev_bridge_internal.h"

#include <linux/leds.h>
#include <uapi/linux/uleds.h>

/*
 * RTL8125 LEDSEL select bits (r8169_leds.c). The cshim maps the kernel
 * netdev-trigger flags to these; the Rust led_set_mode writes them into the
 * LEDSEL register for the LED's index.
 */
#define R8125_LED_CTRL_LINK_10		BIT(0)
#define R8125_LED_CTRL_LINK_100		BIT(1)
#define R8125_LED_CTRL_LINK_1000	BIT(3)
#define R8125_LED_CTRL_LINK_2500	BIT(5)
#define R8125_LED_CTRL_ACT		BIT(9)
#define R8125_NUM_LEDS			4

struct r8125_bridge_led {
	struct led_classdev led;
	struct net_device *ndev;
	char name[LED_MAX_NAME_SIZE];
	u32 index;
};

#define to_r8125_led(cdev) container_of(cdev, struct r8125_bridge_led, led)

/*
 * Only the hardware-expressible trigger combinations are accepted: the chip has
 * no half/full-duplex LED condition, and its activity condition is combined (it
 * cannot light RX-only or TX-only), so RX and TX must be requested together.
 */
static bool r8125_led_mode_valid(unsigned long flags)
{
	bool rx, tx;

	if (flags & BIT(TRIGGER_NETDEV_HALF_DUPLEX))
		return false;
	if (flags & BIT(TRIGGER_NETDEV_FULL_DUPLEX))
		return false;
	rx = flags & BIT(TRIGGER_NETDEV_RX);
	tx = flags & BIT(TRIGGER_NETDEV_TX);
	return rx == tx;
}

static int r8125_led_hw_control_is_supported(struct led_classdev *cdev,
					     unsigned long flags)
{
	struct r8125_bridge_led *l = to_r8125_led(cdev);
	struct r8125_bridge *b = netdev_priv(l->ndev);

	if (!r8125_led_mode_valid(flags)) {
		/* Switch the LED off to indicate the mode isn't supported. */
		b->ops.led_set_mode(b->priv, l->index, 0);
		return -EOPNOTSUPP;
	}
	return 0;
}

static int r8125_led_hw_control_set(struct led_classdev *cdev,
				    unsigned long flags)
{
	struct r8125_bridge_led *l = to_r8125_led(cdev);
	struct r8125_bridge *b = netdev_priv(l->ndev);
	u16 mode = 0;

	if (flags & BIT(TRIGGER_NETDEV_LINK_10))
		mode |= R8125_LED_CTRL_LINK_10;
	if (flags & BIT(TRIGGER_NETDEV_LINK_100))
		mode |= R8125_LED_CTRL_LINK_100;
	if (flags & BIT(TRIGGER_NETDEV_LINK_1000))
		mode |= R8125_LED_CTRL_LINK_1000;
	if (flags & BIT(TRIGGER_NETDEV_LINK_2500))
		mode |= R8125_LED_CTRL_LINK_2500;
	if (flags & (BIT(TRIGGER_NETDEV_TX) | BIT(TRIGGER_NETDEV_RX)))
		mode |= R8125_LED_CTRL_ACT;

	return b->ops.led_set_mode(b->priv, l->index, mode);
}

static int r8125_led_hw_control_get(struct led_classdev *cdev,
				    unsigned long *flags)
{
	struct r8125_bridge_led *l = to_r8125_led(cdev);
	struct r8125_bridge *b = netdev_priv(l->ndev);
	int mode = b->ops.led_get_mode(b->priv, l->index);

	if (mode < 0)
		return mode;
	if (mode & R8125_LED_CTRL_LINK_10)
		*flags |= BIT(TRIGGER_NETDEV_LINK_10);
	if (mode & R8125_LED_CTRL_LINK_100)
		*flags |= BIT(TRIGGER_NETDEV_LINK_100);
	if (mode & R8125_LED_CTRL_LINK_1000)
		*flags |= BIT(TRIGGER_NETDEV_LINK_1000);
	if (mode & R8125_LED_CTRL_LINK_2500)
		*flags |= BIT(TRIGGER_NETDEV_LINK_2500);
	if (mode & R8125_LED_CTRL_ACT)
		*flags |= BIT(TRIGGER_NETDEV_TX) | BIT(TRIGGER_NETDEV_RX);
	return 0;
}

static struct device *r8125_led_hw_control_get_device(struct led_classdev *cdev)
{
	struct r8125_bridge_led *l = to_r8125_led(cdev);

	return &l->ndev->dev;
}

static void r8125_led_setup(struct r8125_bridge_led *l, struct net_device *ndev,
			    u32 index)
{
	struct led_classdev *cdev = &l->led;

	l->ndev = ndev;
	l->index = index;
	snprintf(l->name, sizeof(l->name), "r8125_rust-%s:lan:%u",
		 netdev_name(ndev), index);
	cdev->name = l->name;
	cdev->hw_control_trigger = "netdev";
	cdev->flags |= LED_RETAIN_AT_SHUTDOWN;
	cdev->hw_control_is_supported = r8125_led_hw_control_is_supported;
	cdev->hw_control_set = r8125_led_hw_control_set;
	cdev->hw_control_get = r8125_led_hw_control_get;
	cdev->hw_control_get_device = r8125_led_hw_control_get_device;
	/* Best-effort: a failed LED never fails the netdev. */
	led_classdev_register(&ndev->dev, cdev);
}

void *r8125_bridge_init_leds(struct net_device *ndev)
{
	struct r8125_bridge_led *leds;
	u32 i;

	leds = kcalloc(R8125_NUM_LEDS, sizeof(*leds), GFP_KERNEL);
	if (!leds)
		return NULL;
	for (i = 0; i < R8125_NUM_LEDS; i++)
		r8125_led_setup(&leds[i], ndev, i);
	return leds;
}

void r8125_bridge_remove_leds(void *leds)
{
	struct r8125_bridge_led *l = leds;
	u32 i;

	if (!l)
		return;
	for (i = 0; i < R8125_NUM_LEDS; i++)
		led_classdev_unregister(&l[i].led);
	kfree(l);
}
