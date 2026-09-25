// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * mqnic SSR application auxiliary driver
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/io.h>
#include <linux/mutex.h>
#include <linux/device.h>
#include <linux/auxiliary_bus.h>
#include <linux/sysfs.h>
#include <linux/slab.h>

#include "mqnic.h"
#include "ssr_regs.h"

#define DRV_NAME "mqnic_app_ssr"

struct mqnic_app_ssr {
    struct device *dev;
    struct mqnic_dev *mdev;

    void __iomem *app_hw_addr;
    resource_size_t app_hw_size;

    struct mqnic_reg_block *app_rb_list;
    struct mqnic_reg_block *ssr_rb;

    struct mutex lock;
};

static inline u32 ssr_readl(struct mqnic_app_ssr *app_ssr, u32 reg)
{
    return ioread32(app_ssr->ssr_rb->regs + reg);
}

static inline void ssr_writel(struct mqnic_app_ssr *app_ssr, u32 reg, u32 value)
{
    iowrite32(value, app_ssr->ssr_rb->regs + reg);
}

/*
 * ssr_self_test - Perform self-test on the SSR
 * @app_ssr: SSR application structure
 *
 * Returns 0 on success, negative error code on failure.
 */
static int ssr_self_test(struct mqnic_app_ssr *app_ssr)
{
    u32 type;
    u32 version;
    u32 node;
    u32 val;

    type = ssr_readl(app_ssr, SSR_REG_TYPE);
    version = ssr_readl(app_ssr, SSR_REG_VERSION);
    node = ssr_readl(app_ssr, SSR_REG_NODE);

    dev_info(app_ssr->dev, "SSR TYPE: 0x%08x\n", type);
    dev_info(app_ssr->dev, "SSR VERSION: 0x%08x\n", version);
    dev_info(app_ssr->dev, "SSR node %u of %u, round %u ns\n",
             SSR_NODE_ID(node), SSR_NODE_COUNT(node), ssr_readl(app_ssr, SSR_REG_ROUND_NS));

    if (type != SSR_RB_TYPE) {
        dev_err(app_ssr->dev, "Invalid SSR type: 0x%08x\n", type);
        return -ENODEV;
    }

    if (version != SSR_RB_VERSION) {
        dev_err(app_ssr->dev, "Unsupported SSR version: 0x%08x\n", version);
        return -ENODEV;
    }

    ssr_writel(app_ssr, SSR_REG_SCRATCH, 0xdeadbeef);
    val = ssr_readl(app_ssr, SSR_REG_SCRATCH);
    if (val != 0xdeadbeef) {
        dev_err(app_ssr->dev, "SSR self-test failed: expected 0xdeadbeef, got 0x%08x\n", val);
        return -EIO;
    }

    dev_info(app_ssr->dev, "SSR self-test passed\n");

    return 0;
}

/*
 * sysfs. The node's id, the cluster size and the round length are build-time
 * parameters of the bitstream: they are read here, never written.
 */

// sysfs: identity - "node_id node_count round_ns geometry page_bytes"
static ssize_t identity_show(struct device *dev,
                             struct device_attribute *attr,
                             char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 node, round_ns, geometry, page_bytes;

    mutex_lock(&app_ssr->lock);
    node = ssr_readl(app_ssr, SSR_REG_NODE);
    round_ns = ssr_readl(app_ssr, SSR_REG_ROUND_NS);
    geometry = ssr_readl(app_ssr, SSR_REG_GEOMETRY);
    page_bytes = ssr_readl(app_ssr, SSR_REG_PAGE_BYTES);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "%u %u %u 0x%08x %u\n", SSR_NODE_ID(node), SSR_NODE_COUNT(node),
                      round_ns, geometry, page_bytes);
}
static DEVICE_ATTR_RO(identity);

// sysfs: core_status - CORE_STATUS (halted, timing armed, time valid, ...)
static ssize_t core_status_show(struct device *dev,
                                struct device_attribute *attr,
                                char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;

    mutex_lock(&app_ssr->lock);
    val = ssr_readl(app_ssr, SSR_REG_CORE_STATUS);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "0x%08x\n", val);
}
static DEVICE_ATTR_RO(core_status);

// sysfs: fault - FAULT, non-zero means an internal contract broke
static ssize_t fault_show(struct device *dev,
                          struct device_attribute *attr,
                          char *buf)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;

    mutex_lock(&app_ssr->lock);
    val = ssr_readl(app_ssr, SSR_REG_FAULT);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "0x%08x\n", val);
}
static DEVICE_ATTR_RO(fault);

// sysfs: scratch
static ssize_t scratch_show(struct device *dev,
                            struct device_attribute *attr,
                            char *buf)
{    
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;

    mutex_lock(&app_ssr->lock);
    val = ssr_readl(app_ssr, SSR_REG_SCRATCH);
    mutex_unlock(&app_ssr->lock);

    return sysfs_emit(buf, "0x%08x\n", val);
}
static ssize_t scratch_store(struct device *dev,
                            struct device_attribute *attr,
                            const char *buf,
                            size_t count)
{
    struct mqnic_app_ssr *app_ssr = dev_get_drvdata(dev);
    u32 val;
    int ret;

    ret = kstrtou32(buf, 0, &val);
    if (ret)
        return ret;

    mutex_lock(&app_ssr->lock);
    ssr_writel(app_ssr, SSR_REG_SCRATCH, val);
    mutex_unlock(&app_ssr->lock);

    return count;
}
static DEVICE_ATTR_RW(scratch);

static struct attribute *ssr_attrs[] = {
    &dev_attr_identity.attr,
    &dev_attr_core_status.attr,
    &dev_attr_fault.attr,
    &dev_attr_scratch.attr,
    NULL,
};

static const struct attribute_group ssr_attr_group = {
    .attrs = ssr_attrs,
};

// auxiliary driver probe function
static int mqnic_app_ssr_probe(struct auxiliary_device *adev,
                               const struct auxiliary_device_id *id)
{
    struct device *dev = &adev->dev;
    struct mqnic_dev *mdev = container_of(adev, struct mqnic_adev, adev)->mdev;
    struct mqnic_app_ssr *ssr;
    int ret;

    dev_info(dev, "%s() called\n", __func__);

    // Check that required BAR regions are present
    if (!mdev->hw_addr || !mdev->app_hw_addr) {
        dev_err(dev, "Required BAR regions not present\n");
        return -EIO;
    }

    ssr = devm_kzalloc(dev, sizeof(*ssr), GFP_KERNEL);
    if (!ssr)   return -ENOMEM;

    ssr->dev = dev;
    ssr->mdev = mdev;
    ssr->app_hw_addr = mdev->app_hw_addr;
    ssr->app_hw_size = mdev->app_hw_regs_size;

    mutex_init(&ssr->lock);

    dev_set_drvdata(dev, ssr);

    ssr->app_rb_list = mqnic_enumerate_reg_block_list(
        ssr->app_hw_addr, 0, ssr->app_hw_size);

    if (!ssr->app_rb_list) {
        dev_err(dev, "Failed to enumerate register blocks\n");
        ret = -EIO;
        goto fail;
    }
    dev_info(dev, "Enumerated SSR register blocks:\n");
    {
        struct mqnic_reg_block *rb;
        for (rb = ssr->app_rb_list; rb->regs; rb++) {
            dev_info(dev, "  RB type=0x%08x version=0x%08x\n",
                     rb->type, rb->version);
        }
    }

    ssr->ssr_rb = mqnic_find_reg_block(ssr->app_rb_list, SSR_RB_TYPE, SSR_RB_VERSION, 0);
    if (!ssr->ssr_rb) {
        dev_err(dev, "Failed to find SSR register block\n");
        ret = -EIO;
        goto fail_free_rb_list;
    }

    ret = ssr_self_test(ssr);
    if (ret) {
        dev_err(dev, "SSR self-test failed\n");
        goto fail_free_rb_list;
    }

    ret = sysfs_create_group(&dev->kobj, &ssr_attr_group);
    if (ret) {
        dev_err(dev, "Failed to create sysfs group\n");
        goto fail_free_rb_list;
    }

    dev_info(dev, "SSR application driver loaded successfully\n");

    return 0;

fail_free_rb_list:
    mqnic_free_reg_block_list(ssr->app_rb_list);
    ssr->app_rb_list = NULL;
fail:
    dev_set_drvdata(dev, NULL);
    return ret;
}

// auxiliary driver remove function
static void mqnic_app_ssr_remove(struct auxiliary_device *adev)
{
    struct device *dev = &adev->dev;
    struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);

    dev_info(dev, "%s() called\n", __func__);

    if (!ssr) return;

    sysfs_remove_group(&dev->kobj, &ssr_attr_group);

    if (ssr->app_rb_list) {
        mqnic_free_reg_block_list(ssr->app_rb_list);
        ssr->app_rb_list = NULL;
    }

    dev_set_drvdata(dev, NULL);

    dev_info(dev, "SSR application driver removed\n");
}

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
    return auxiliary_driver_register(&mqnic_app_ssr_driver);
}

static void __exit mqnic_app_ssr_exit(void)
{
    auxiliary_driver_unregister(&mqnic_app_ssr_driver);
}

module_init(mqnic_app_ssr_init);
module_exit(mqnic_app_ssr_exit);

MODULE_DESCRIPTION("mqnic SSR application auxiliary driver");
MODULE_AUTHOR("Anonymous");
MODULE_LICENSE("Dual BSD/GPL");
MODULE_VERSION("0.1");
