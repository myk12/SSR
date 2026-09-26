// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssr_main.c - mqnic_app_ssr.ko: the module and the auxiliary driver.
 *
 * mqnic creates one auxiliary device per NIC whose application block reports
 * APP_ID 0x53535201 ("SSR"); this driver binds to it. Probe runs the bring-up
 * in the order the simulator's driver model does (tb/mqnic_core_pcie_us/
 * ssr_dataplane.py):
 *
 *   find the SSR register block -> self test -> identity ->
 *   rings (ssr_rings.c) -> /dev/ssrN (ssr_datapath.c) -> sysfs (ssr_control.c)
 *
 * and leaves the core disabled. Nothing joins a cluster until user space
 * says so through SSR_IOC_ACTIVATE. The driver does not own the protocol;
 * run ids and membership are the control plane's (host/).
 */

#include <linux/auxiliary_bus.h>
#include <linux/init.h>
#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/slab.h>
#include <linux/sysfs.h>

#include "ssr_drv.h"

static unsigned int prop_depth_log2 = 4;
module_param(prop_depth_log2, uint, 0444);
MODULE_PARM_DESC(prop_depth_log2, "proposal ring depth, log2 (1..8)");

/* ---------------------------------------------- the bitstream, as found */

static int ssr_self_test(struct mqnic_app_ssr *ssr)
{
	u32 type = ssr_readl(ssr, SSR_REG_TYPE);
	u32 version = ssr_readl(ssr, SSR_REG_VERSION);
	u32 val;

	if (type != SSR_RB_TYPE || version != SSR_RB_VERSION) {
		dev_err(ssr->dev, "SSR block type 0x%08x version 0x%08x, expected 0x%08x / 0x%08x\n",
			type, version, SSR_RB_TYPE, SSR_RB_VERSION);
		return -ENODEV;
	}
	ssr_writel(ssr, SSR_REG_SCRATCH, 0xdeadbeef);
	val = ssr_readl(ssr, SSR_REG_SCRATCH);
	if (val != 0xdeadbeef) {
		dev_err(ssr->dev, "scratch register: wrote 0xdeadbeef, read 0x%08x\n", val);
		return -EIO;
	}
	return 0;
}

/* Node id, cluster size, round length and ring geometry are baked into the
 * bitstream; the driver reads them, it does not choose them. */
static int ssr_read_identity(struct mqnic_app_ssr *ssr)
{
	struct ssr_info *inf = &ssr->info;
	u32 node = ssr_readl(ssr, SSR_REG_NODE);
	u32 geom = ssr_readl(ssr, SSR_REG_GEOMETRY);

	inf->node_id = SSR_NODE_ID(node);
	inf->node_count = SSR_NODE_COUNT(node);
	inf->round_ns = ssr_readl(ssr, SSR_REG_ROUND_NS);
	inf->page_bytes = ssr_readl(ssr, SSR_REG_PAGE_BYTES);
	inf->region_shift = SSR_GEOM_REGION_SHIFT(geom);
	inf->pay_depth_log2 = SSR_GEOM_PAY_DEPTH_LOG2(geom);
	inf->ver_depth_log2 = SSR_GEOM_VER_DEPTH_LOG2(geom);
	inf->prop_depth_log2 = clamp(prop_depth_log2, 1u, 8u);
	inf->regs_bytes = PAGE_SIZE;

	if (inf->page_bytes != SSR_PROPOSAL_ENTRY_BYTES || inf->node_count == 0 ||
	    inf->node_count > SSR_VERDICT_MAX_NODES || inf->node_id >= inf->node_count ||
	    inf->region_shift < SSR_PAGE_SHIFT || SSR_GEOM_NODE_COUNT(geom) != inf->node_count) {
		dev_err(ssr->dev, "implausible identity: NODE 0x%08x GEOMETRY 0x%08x PAGE_BYTES %u\n",
			node, geom, inf->page_bytes);
		return -ENODEV;
	}
	dev_info(ssr->dev, "SSR node %u of %u, round %u ns, region 2^%u, payload ring 2^%u rounds, verdict ring 2^%u\n",
		 inf->node_id, inf->node_count, inf->round_ns, inf->region_shift,
		 inf->pay_depth_log2, inf->ver_depth_log2);
	return 0;
}

/* ------------------------------------------------------------ probe/remove */

static int mqnic_app_ssr_probe(struct auxiliary_device *adev, const struct auxiliary_device_id *id)
{
	struct device *dev = &adev->dev;
	struct mqnic_dev *mdev = container_of(adev, struct mqnic_adev, adev)->mdev;
	struct mqnic_app_ssr *ssr;
	struct mqnic_reg_block *rb;
	int ret;

	if (!mdev->hw_addr || !mdev->app_hw_addr) {
		dev_err(dev, "required BAR regions not present\n");
		return -EIO;
	}

	ssr = devm_kzalloc(dev, sizeof(*ssr), GFP_KERNEL);
	if (!ssr)
		return -ENOMEM;
	ssr->dev = dev;
	ssr->mdev = mdev;
	ssr->dma_dev = mdev->dev;
	ssr->app_hw_addr = mdev->app_hw_addr;
	ssr->app_hw_size = mdev->app_hw_regs_size;
	mutex_init(&ssr->lock);
	ssr->minor = -1;
	dev_set_drvdata(dev, ssr);

	ssr->app_rb_list = mqnic_enumerate_reg_block_list(ssr->app_hw_addr, 0, ssr->app_hw_size);
	if (!ssr->app_rb_list) {
		dev_err(dev, "failed to enumerate the application register blocks\n");
		return -EIO;
	}
	for (rb = ssr->app_rb_list; rb->regs; rb++)
		dev_info(dev, "  register block type 0x%08x version 0x%08x\n", rb->type, rb->version);

	ssr->ssr_rb = mqnic_find_reg_block(ssr->app_rb_list, SSR_RB_TYPE, SSR_RB_VERSION, 0);
	if (!ssr->ssr_rb) {
		dev_err(dev, "no SSR register block\n");
		ret = -EIO;
		goto fail_rb;
	}

	ret = ssr_self_test(ssr);
	if (ret)
		goto fail_rb;
	ret = ssr_read_identity(ssr);
	if (ret)
		goto fail_rb;

	ret = ssr_rings_alloc(ssr);
	if (ret) {
		dev_err(dev, "ring allocation failed (payload ring needs %llu KiB contiguous)\n",
			ssr->info.pay_ring_bytes >> 10);
		goto fail_rb;
	}
	ssr_rings_hw_setup(ssr);

	ret = ssr_datapath_add(ssr);
	if (ret)
		goto fail_rings;

	ret = sysfs_create_group(&dev->kobj, &ssr_attr_group);
	if (ret)
		goto fail_datapath;

	dev_info(dev, "/dev/ssr%d ready; core disabled until activated\n", ssr->minor);
	return 0;

fail_datapath:
	ssr_datapath_remove(ssr);
fail_rings:
	ssr_rings_hw_teardown(ssr);
	ssr_rings_free(ssr);
fail_rb:
	mqnic_free_reg_block_list(ssr->app_rb_list);
	ssr->app_rb_list = NULL;
	dev_set_drvdata(dev, NULL);
	return ret;
}

static void mqnic_app_ssr_remove(struct auxiliary_device *adev)
{
	struct device *dev = &adev->dev;
	struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);

	if (!ssr)
		return;

	sysfs_remove_group(&dev->kobj, &ssr_attr_group);
	ssr_datapath_remove(ssr);
	ssr_rings_hw_teardown(ssr);
	ssr_rings_free(ssr);
	mqnic_free_reg_block_list(ssr->app_rb_list);
	dev_set_drvdata(dev, NULL);
	dev_info(dev, "removed\n");
}

/* ------------------------------------------------------------- the module */

static const struct auxiliary_device_id mqnic_app_ssr_id_table[] = {
	{ .name = SSR_AUXILIARY_NAME },
	{ },
};
MODULE_DEVICE_TABLE(auxiliary, mqnic_app_ssr_id_table);

static struct auxiliary_driver mqnic_app_ssr_driver = {
	.name = DRV_NAME,
	.id_table = mqnic_app_ssr_id_table,
	.probe = mqnic_app_ssr_probe,
	.remove = mqnic_app_ssr_remove,
};

static int __init mqnic_app_ssr_init(void)
{
	int ret;

	ret = ssr_datapath_module_init();
	if (ret)
		return ret;
	ret = auxiliary_driver_register(&mqnic_app_ssr_driver);
	if (ret)
		ssr_datapath_module_exit();
	return ret;
}

static void __exit mqnic_app_ssr_exit(void)
{
	auxiliary_driver_unregister(&mqnic_app_ssr_driver);
	ssr_datapath_module_exit();
}

module_init(mqnic_app_ssr_init);
module_exit(mqnic_app_ssr_exit);

MODULE_DESCRIPTION("mqnic SSR application driver");
MODULE_AUTHOR("SSR");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_VERSION("0.2");
