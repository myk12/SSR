/* SPDX-License-Identifier: BSD-2-Clause-Views */
/*
 * ssr_drv.h - what the four files of mqnic_app_ssr.ko share.
 *
 *   ssr_main.c      the module and the auxiliary driver: probe, identity, remove
 *   ssr_rings.c     the three rings in host memory and the registers that point
 *                   the NIC at them
 *   ssr_datapath.c  /dev/ssrN: write() / read() / poll() / mmap(), the poller
 *   ssr_control.c   the ioctls and the sysfs attributes: the core's registers
 *                   on behalf of user space
 *
 * The device structure, the register accessors and the ring addressing live
 * here because every file needs them; nothing else does.
 */
#ifndef SSR_DRV_H
#define SSR_DRV_H

#include <linux/cdev.h>
#include <linux/device.h>
#include <linux/dma-mapping.h>
#include <linux/io.h>
#include <linux/mutex.h>
#include <linux/wait.h>
#include <asm/unaligned.h>

#include "mqnic.h"
#include "ssr_regs.h"
#include "ssr_uapi.h"

#define DRV_NAME "mqnic_app_ssr"
#define SSR_MAX_DEVICES 16

struct mqnic_app_ssr {
	struct device *dev;
	struct mqnic_dev *mdev;
	struct device *dma_dev;

	void __iomem *app_hw_addr;
	resource_size_t app_hw_size;
	struct mqnic_reg_block *app_rb_list;
	struct mqnic_reg_block *ssr_rb;

	struct mutex lock;          /* the register page */

	/* identity and geometry, read from the bitstream (ssr_main.c) */
	struct ssr_info info;

	/* the rings (ssr_rings.c) */
	void *prop_ring;
	dma_addr_t prop_dma;
	void *pay_ring;
	dma_addr_t pay_dma;
	void *ver_ring;
	dma_addr_t ver_dma;

	/* the character device and the kernel-mediated path (ssr_datapath.c) */
	int minor;
	struct cdev cdev;
	struct device *cdev_dev;
	struct mutex prop_lock;     /* write(): one producer */
	u32 producer;               /* our copy of PROP_PRODUCER */
	struct mutex read_lock;     /* read(): one cursor */
	u64 next_seq;               /* the record read() waits for */
	u64 woken_seq;              /* the last seq the poller woke readers for */
	wait_queue_head_t wq;
	struct task_struct *poller;
};

/* ---- registers. Callers hold ssr->lock unless they own the register. ---- */

static inline u32 ssr_readl(struct mqnic_app_ssr *ssr, u32 reg)
{
	return ioread32(ssr->ssr_rb->regs + reg);
}

static inline void ssr_writel(struct mqnic_app_ssr *ssr, u32 reg, u32 value)
{
	iowrite32(value, ssr->ssr_rb->regs + reg);
}

static inline u64 ssr_readq_pair(struct mqnic_app_ssr *ssr, u32 lo_reg)
{
	u32 lo = ssr_readl(ssr, lo_reg);
	u32 hi = ssr_readl(ssr, lo_reg + 4);
	return ((u64)hi << 32) | lo;
}

/* ---- ring addressing (ring_buffer.md): a record by seq, a page by (round, node, frag) ---- */

static inline u8 *ssr_record_ptr(struct mqnic_app_ssr *ssr, u64 seq)
{
	u64 mask = (1ULL << ssr->info.ver_depth_log2) - 1;
	return (u8 *)ssr->ver_ring + (seq & mask) * SSR_VERDICT_RECORD_BYTES;
}

static inline u8 *ssr_page_ptr(struct mqnic_app_ssr *ssr, u64 round_id, u32 node, u32 frag)
{
	u64 slot = round_id & ((1ULL << ssr->info.pay_depth_log2) - 1);
	u64 region = (slot * ssr->info.node_count + node) << ssr->info.region_shift;
	return (u8 *)ssr->pay_ring + region + ((u64)frag << SSR_PAGE_SHIFT);
}

static inline u64 ssr_record_seq(const u8 *rec)
{
	return get_unaligned_be64(rec + SSR_VERDICT_OFF_SEQ);
}

/* ---- ssr_rings.c ---- */
int ssr_rings_alloc(struct mqnic_app_ssr *ssr);
void ssr_rings_free(struct mqnic_app_ssr *ssr);
void ssr_rings_hw_setup(struct mqnic_app_ssr *ssr);
void ssr_rings_hw_teardown(struct mqnic_app_ssr *ssr);
bool ssr_record_ready(struct mqnic_app_ssr *ssr);

/* ---- ssr_datapath.c ---- */
int ssr_datapath_module_init(void);
void ssr_datapath_module_exit(void);
int ssr_datapath_add(struct mqnic_app_ssr *ssr);
void ssr_datapath_remove(struct mqnic_app_ssr *ssr);
/* after a flush the NIC's indices jumped; follow them (caller holds prop_lock + lock) */
void ssr_datapath_follow_producer(struct mqnic_app_ssr *ssr);
/* read() continues from the hardware's next seq */
void ssr_datapath_reset_cursor(struct mqnic_app_ssr *ssr);

/* ---- ssr_control.c ---- */
long ssr_ioctl(struct file *file, unsigned int cmd, unsigned long arg);
extern const struct attribute_group ssr_attr_group;

#endif /* SSR_DRV_H */
