// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssr_datapath.c - /dev/ssrN: the rings handed to user space, two ways.
 *
 *   THE KERNEL-MEDIATED PATH
 *     write()   one proposal piece -> the next ring entry -> the doorbell
 *     read()    the next decided round: struct ssr_delivery + the payload of
 *               every committed peer, copied out of the payload ring
 *     poll()    POLLIN when read() would not block
 *     A kernel thread polls the verdict ring every poll_us and wakes readers;
 *     the app block has no interrupt.
 *
 *   THE ZERO-COPY PATH
 *     mmap()    the three rings and the register page, at the offsets of
 *               ssr_uapi.h. The process does the rest itself.
 *
 * This file also owns the character device itself: the class and the device
 * numbers (module init/exit) and one cdev + poller per NIC (add/remove).
 */

#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/idr.h>
#include <linux/kthread.h>
#include <linux/mm.h>
#include <linux/module.h>
#include <linux/poll.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/version.h>

#include "ssr_drv.h"

static unsigned int poll_us = 5;
module_param(poll_us, uint, 0644);
MODULE_PARM_DESC(poll_us, "verdict poller period in microseconds for the read() path (0 = busy)");

static dev_t ssr_devt_base;
static struct class *ssr_class;
static DEFINE_IDA(ssr_minor_ida);

/* ------------------------------------------------------------- the poller */

static int ssr_poller_fn(void *arg)
{
	struct mqnic_app_ssr *ssr = arg;

	while (!kthread_should_stop()) {
		u64 seq = READ_ONCE(ssr->next_seq);

		if (seq != ssr->woken_seq && ssr_record_ready(ssr)) {
			ssr->woken_seq = seq;
			wake_up_interruptible(&ssr->wq);
		}
		if (poll_us)
			usleep_range(poll_us, poll_us * 2);
		else
			cond_resched();
	}
	return 0;
}

/* ------------------------------------------------- write(): one piece in */

static ssize_t ssr_write(struct file *file, const char __user *buf, size_t n, loff_t *ppos)
{
	struct mqnic_app_ssr *ssr = file->private_data;
	u32 depth = 1u << ssr->info.prop_depth_log2;
	unsigned long deadline;
	u8 *entry;
	u32 consumer, status;
	int ret;

	if (n < 1 || n > SSR_PROPOSAL_PIECE_BYTES)
		return -EINVAL;

	ret = mutex_lock_interruptible(&ssr->prop_lock);
	if (ret)
		return ret;

	/* room: producer - consumer < depth, counted mod 2^32 */
	deadline = jiffies + HZ;
	for (;;) {
		consumer = ssr_readl(ssr, SSR_REG_PROP_CONSUMER);
		status = ssr_readl(ssr, SSR_REG_PROP_STATUS);
		if (status & SSR_PROP_STATUS_ERROR) {
			ret = -EIO;
			goto out;
		}
		if ((u32)(ssr->producer - consumer) < depth)
			break;
		if (file->f_flags & O_NONBLOCK) {
			ret = -EAGAIN;
			goto out;
		}
		if (time_after(jiffies, deadline)) {
			ret = -ETIMEDOUT;
			goto out;
		}
		usleep_range(2, 10);
	}

	entry = (u8 *)ssr->prop_ring + (size_t)(ssr->producer & (depth - 1)) * ssr->info.page_bytes;
	memset(entry, 0, SSR_PROPOSAL_PAYLOAD_OFF);      /* the header row belongs to the FPGA */
	if (copy_from_user(entry + SSR_PROPOSAL_PAYLOAD_OFF, buf, n)) {
		ret = -EFAULT;
		goto out;
	}
	if (n < SSR_PROPOSAL_PIECE_BYTES)
		memset(entry + SSR_PROPOSAL_PAYLOAD_OFF + n, 0, SSR_PROPOSAL_PIECE_BYTES - n);

	wmb();                                          /* the entry, then the doorbell */
	ssr->producer++;
	ssr_writel(ssr, SSR_REG_PROP_PRODUCER, ssr->producer);
	ret = n;
out:
	mutex_unlock(&ssr->prop_lock);
	return ret;
}

void ssr_datapath_follow_producer(struct mqnic_app_ssr *ssr)
{
	ssr->producer = ssr_readl(ssr, SSR_REG_PROP_PRODUCER);
}

/* ------------------------------------------------ read(): one round out */

/* Decode the record at seq into d and size its payload. -EIO if a page the
 * record names does not carry the header it should. */
static int ssr_build_delivery(struct mqnic_app_ssr *ssr, u64 seq, struct ssr_delivery *d)
{
	const u8 *rec = ssr_record_ptr(ssr, seq);
	u32 k, f, off = 0;

	memcpy(d->record, rec, SSR_VERDICT_RECORD_BYTES);
	d->round_id = get_unaligned_be64(rec + SSR_VERDICT_OFF_ROUND_ID);
	d->seq = get_unaligned_be64(rec + SSR_VERDICT_OFF_SEQ);
	d->run_id = get_unaligned_be32(rec + SSR_VERDICT_OFF_RUN_ID);
	d->commit_set = rec[SSR_VERDICT_OFF_COMMIT_SET];
	d->present_set = rec[SSR_VERDICT_OFF_PRESENT_SET];
	d->node_count = rec[SSR_VERDICT_OFF_NODE_COUNT];
	d->self_index = rec[SSR_VERDICT_OFF_SELF_INDEX];
	if (d->node_count > SSR_VERDICT_MAX_NODES)
		return -EIO;
	for (k = 0; k < SSR_VERDICT_MAX_NODES; k++)
		d->frag_count[k] = get_unaligned_be16(rec + SSR_VERDICT_OFF_FRAG_COUNTS + 2 * k);
	d->prop_consumer = get_unaligned_be32(rec + SSR_VERDICT_OFF_PROP_CONSUMER);

	for (k = 0; k < SSR_VERDICT_MAX_NODES; k++) {
		d->node_off[k] = off;
		d->node_len[k] = 0;
		if (k >= d->node_count || k == d->self_index || !(d->present_set & (1u << k)))
			continue;
		for (f = 0; f < d->frag_count[k]; f++) {
			const u8 *page = ssr_page_ptr(ssr, d->round_id, k, f);
			u32 len = get_unaligned_be16(page + 28);

			if (page[30] != 2 || page[14] != k ||
			    get_unaligned_be64(page + 20) != d->round_id ||
			    get_unaligned_be16(page + 32) != f ||
			    len < 1 || len > SSR_PROPOSAL_PIECE_BYTES) {
				dev_warn_ratelimited(ssr->dev,
					"page (round %llu, node %u, frag %u) carries kind %u node %u round %llu frag %u len %u\n",
					d->round_id, k, f, page[30], page[14], get_unaligned_be64(page + 20),
					get_unaligned_be16(page + 32), len);
				return -EIO;
			}
			d->node_len[k] += len;
		}
		off += d->node_len[k];
	}
	d->total_len = off;
	return 0;
}

static ssize_t ssr_read(struct file *file, char __user *buf, size_t cap, loff_t *ppos)
{
	struct mqnic_app_ssr *ssr = file->private_data;
	struct ssr_delivery *d;
	u64 seq;
	u32 k, f;
	char __user *p;
	int ret;

	if (cap < sizeof(*d))
		return -EMSGSIZE;

	ret = mutex_lock_interruptible(&ssr->read_lock);
	if (ret)
		return ret;

	if (!ssr_record_ready(ssr)) {
		if (file->f_flags & O_NONBLOCK) {
			ret = -EAGAIN;
			goto out;
		}
		ret = wait_event_interruptible(ssr->wq, ssr_record_ready(ssr));
		if (ret)
			goto out;
	}
	seq = ssr->next_seq;

	d = kmalloc(sizeof(*d), GFP_KERNEL);
	if (!d) {
		ret = -ENOMEM;
		goto out;
	}
	ret = ssr_build_delivery(ssr, seq, d);
	if (ret)
		goto out_free;
	if (cap < sizeof(*d) + d->total_len) {
		ret = -EMSGSIZE;
		goto out_free;
	}

	if (copy_to_user(buf, d, sizeof(*d))) {
		ret = -EFAULT;
		goto out_free;
	}
	p = buf + sizeof(*d);
	for (k = 0; k < d->node_count; k++) {
		if (!d->node_len[k])
			continue;
		for (f = 0; f < d->frag_count[k]; f++) {
			const u8 *page = ssr_page_ptr(ssr, d->round_id, k, f);
			u32 len = get_unaligned_be16(page + 28);

			if (copy_to_user(p, page + SSR_PAGE_PAYLOAD_OFFSET, len)) {
				ret = -EFAULT;
				goto out_free;
			}
			p += len;
		}
	}
	WRITE_ONCE(ssr->next_seq, seq + 1);
	ret = sizeof(*d) + d->total_len;
out_free:
	kfree(d);
out:
	mutex_unlock(&ssr->read_lock);
	return ret;
}

static __poll_t ssr_poll(struct file *file, poll_table *wait)
{
	struct mqnic_app_ssr *ssr = file->private_data;

	poll_wait(file, &ssr->wq, wait);
	return ssr_record_ready(ssr) ? (EPOLLIN | EPOLLRDNORM) : 0;
}

void ssr_datapath_reset_cursor(struct mqnic_app_ssr *ssr)
{
	mutex_lock(&ssr->read_lock);
	mutex_lock(&ssr->lock);
	WRITE_ONCE(ssr->next_seq, ssr_readq_pair(ssr, SSR_REG_SEQ_LO));
	ssr->woken_seq = ssr->next_seq - 1;
	mutex_unlock(&ssr->lock);
	mutex_unlock(&ssr->read_lock);
}

/* --------------------------------------------- mmap(): the zero-copy path */

static int ssr_mmap_ring(struct mqnic_app_ssr *ssr, struct vm_area_struct *vma,
			 void *cpu_addr, dma_addr_t dma, u64 bytes)
{
	unsigned long size = vma->vm_end - vma->vm_start;

	if (size > bytes)
		return -EINVAL;
	vma->vm_pgoff = 0;                              /* dma_mmap_coherent offsets by it */
	return dma_mmap_coherent(ssr->dma_dev, vma, cpu_addr, dma, bytes);
}

static int ssr_mmap(struct file *file, struct vm_area_struct *vma)
{
	struct mqnic_app_ssr *ssr = file->private_data;
	u64 off = (u64)vma->vm_pgoff << PAGE_SHIFT;
	unsigned long size = vma->vm_end - vma->vm_start;

	switch (off) {
	case SSR_MMAP_PROP_RING:
		return ssr_mmap_ring(ssr, vma, ssr->prop_ring, ssr->prop_dma, ssr->info.prop_ring_bytes);
	case SSR_MMAP_PAY_RING:
		if (ssr->pay_page) {
			/* plain pages, not coherent-API memory: map them by pfn */
			if (size > ssr->info.pay_ring_bytes)
				return -EINVAL;
			return remap_pfn_range(vma, vma->vm_start, page_to_pfn(ssr->pay_page), size, vma->vm_page_prot);
		}
		return ssr_mmap_ring(ssr, vma, ssr->pay_ring, ssr->pay_dma, ssr->info.pay_ring_bytes);
	case SSR_MMAP_VER_RING:
		return ssr_mmap_ring(ssr, vma, ssr->ver_ring, ssr->ver_dma, ssr->info.ver_ring_bytes);
	case SSR_MMAP_REGS: {
		/* the SSR register page inside the application BAR, uncached */
		phys_addr_t phys = ssr->mdev->app_hw_regs_phys +
				   (ssr->ssr_rb->regs - (u8 __iomem *)ssr->app_hw_addr);

		if (size != PAGE_SIZE || (phys & (PAGE_SIZE - 1)))
			return -EINVAL;
		vma->vm_page_prot = pgprot_noncached(vma->vm_page_prot);
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 3, 0)
		vma->vm_flags |= VM_IO | VM_DONTEXPAND | VM_DONTDUMP;
#else
		vm_flags_set(vma, VM_IO | VM_DONTEXPAND | VM_DONTDUMP);
#endif
		return io_remap_pfn_range(vma, vma->vm_start, phys >> PAGE_SHIFT, size, vma->vm_page_prot);
	}
	default:
		return -EINVAL;
	}
}

/* ------------------------------------------------------ the device node */

static int ssr_open(struct inode *inode, struct file *file)
{
	file->private_data = container_of(inode->i_cdev, struct mqnic_app_ssr, cdev);
	return 0;
}

static const struct file_operations ssr_fops = {
	.owner = THIS_MODULE,
	.open = ssr_open,
	.read = ssr_read,
	.write = ssr_write,
	.poll = ssr_poll,
	.mmap = ssr_mmap,
	.unlocked_ioctl = ssr_ioctl,
	.compat_ioctl = compat_ptr_ioctl,
};

/* /dev/ssrN and its poller, for one NIC. The rings are set up already. */
int ssr_datapath_add(struct mqnic_app_ssr *ssr)
{
	int ret;

	mutex_init(&ssr->prop_lock);
	mutex_init(&ssr->read_lock);
	init_waitqueue_head(&ssr->wq);

	ssr->minor = ida_alloc_max(&ssr_minor_ida, SSR_MAX_DEVICES - 1, GFP_KERNEL);
	if (ssr->minor < 0)
		return ssr->minor;

	cdev_init(&ssr->cdev, &ssr_fops);
	ssr->cdev.owner = THIS_MODULE;
	ret = cdev_add(&ssr->cdev, MKDEV(MAJOR(ssr_devt_base), ssr->minor), 1);
	if (ret)
		goto fail_ida;
	ssr->cdev_dev = device_create(ssr_class, ssr->dev, MKDEV(MAJOR(ssr_devt_base), ssr->minor),
				      ssr, SSR_DEV_NAME_FMT, ssr->minor);
	if (IS_ERR(ssr->cdev_dev)) {
		ret = PTR_ERR(ssr->cdev_dev);
		goto fail_cdev;
	}

	ssr->poller = kthread_run(ssr_poller_fn, ssr, "ssr%d-poll", ssr->minor);
	if (IS_ERR(ssr->poller)) {
		ret = PTR_ERR(ssr->poller);
		goto fail_devnode;
	}
	return 0;

fail_devnode:
	device_destroy(ssr_class, MKDEV(MAJOR(ssr_devt_base), ssr->minor));
fail_cdev:
	cdev_del(&ssr->cdev);
fail_ida:
	ida_free(&ssr_minor_ida, ssr->minor);
	ssr->minor = -1;
	return ret;
}

void ssr_datapath_remove(struct mqnic_app_ssr *ssr)
{
	kthread_stop(ssr->poller);
	device_destroy(ssr_class, MKDEV(MAJOR(ssr_devt_base), ssr->minor));
	cdev_del(&ssr->cdev);
	ida_free(&ssr_minor_ida, ssr->minor);
	ssr->minor = -1;
}

int ssr_datapath_module_init(void)
{
	int ret;

	ret = alloc_chrdev_region(&ssr_devt_base, 0, SSR_MAX_DEVICES, "ssr");
	if (ret)
		return ret;
#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 4, 0)
	ssr_class = class_create(THIS_MODULE, "ssr");
#else
	ssr_class = class_create("ssr");
#endif
	if (IS_ERR(ssr_class)) {
		unregister_chrdev_region(ssr_devt_base, SSR_MAX_DEVICES);
		return PTR_ERR(ssr_class);
	}
	return 0;
}

void ssr_datapath_module_exit(void)
{
	class_destroy(ssr_class);
	unregister_chrdev_region(ssr_devt_base, SSR_MAX_DEVICES);
}
