// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssr_control.c - the core's registers on behalf of user space.
 *
 *   ioctls   what a program does: activate a run, reboot after a halt,
 *            disable, read the status and the counters, recover the
 *            proposal ring, move the read() cursor (ssr_uapi.h)
 *   sysfs    what a person does at the shell: identity, core_status, fault,
 *            counters, scratch
 *
 * Nothing here decides anything. Run ids and membership come from the
 * control plane (host/); this file writes them into the registers.
 */

#include <linux/delay.h>
#include <linux/fs.h>
#include <linux/slab.h>
#include <linux/sysfs.h>
#include <linux/uaccess.h>

#include "ssr_drv.h"

/* ----------------------------------------------------------------- ioctls */

/* Enable the core without joining a run: the timing arms and CUR_ROUND starts
 * following the PHC. While the core is disabled CUR_ROUND reads 0
 * (ssr_core.v holds round_id_reg at 0 until i_enable), so anything that wants
 * "the current round" - an activation relative to now, the coordinator picking
 * an effective round for the cluster - has to go through here first.
 * Caller holds ssr->lock. -EIO if halted (REBOOT first), -ETIMEDOUT if the
 * timing does not arm; it normally does within a microsecond. */
static int ssr_core_arm(struct mqnic_app_ssr *ssr)
{
	unsigned long deadline = jiffies + HZ / 10;
	u32 st;

	ssr_writel(ssr, SSR_REG_CORE_CONTROL, SSR_CORE_CTRL_ENABLE);
	for (;;) {
		st = ssr_readl(ssr, SSR_REG_CORE_STATUS);
		if (st & SSR_CORE_STATUS_HALTED)
			return -EIO;
		if (st & SSR_CORE_STATUS_TIMING_ARMED)
			return 0;
		if (time_after(jiffies, deadline))
			return -ETIMEDOUT;
		usleep_range(5, 20);
	}
}

static int ssr_ioc_enable(struct mqnic_app_ssr *ssr)
{
	int ret;

	mutex_lock(&ssr->lock);
	ret = ssr_core_arm(ssr);
	mutex_unlock(&ssr->lock);
	return ret;
}

/* The cluster and the round, from ssrd, into the 0x040 block: the core is
 * disabled first because the block refuses writes otherwise. The identity is
 * then re-read - NODE / ROUND_NS / GEOMETRY read back the block - and, since
 * the payload ring is node_count regions per round, the rings are rebuilt
 * when its size changed. Held off proposing and reading meanwhile. */
static int ssr_ioc_configure(struct mqnic_app_ssr *ssr, void __user *uarg)
{
	struct ssr_config c;
	u64 old_pay_bytes = ssr->info.pay_ring_bytes;
	int ret;

	if (copy_from_user(&c, uarg, sizeof(c)))
		return -EFAULT;

	mutex_lock(&ssr->prop_lock);
	mutex_lock(&ssr->read_lock);
	mutex_lock(&ssr->lock);
	ssr_writel(ssr, SSR_REG_CORE_CONTROL, 0);
	ssr_writel(ssr, SSR_REG_CFG_NODE, (c.node_count << 8) | c.node_id);
	ssr_writel(ssr, SSR_REG_CFG_QUORUM, c.quorum);
	ssr_writel(ssr, SSR_REG_CFG_SRC_MAC_LO, get_unaligned_be32(c.src_mac + 2));
	ssr_writel(ssr, SSR_REG_CFG_SRC_MAC_HI, get_unaligned_be16(c.src_mac));
	ssr_writel(ssr, SSR_REG_CFG_ROUND_NS, c.round_ns);
	ssr_writel(ssr, SSR_REG_CFG_ROUNDS_PER_SEC, c.rounds_per_sec);
	ssr_writel(ssr, SSR_REG_CFG_TX_START_NS, c.tx_start_ns);
	ssr_writel(ssr, SSR_REG_CFG_CTRL_DEADLINE_NS, c.ctrl_deadline_ns);
	ssr_writel(ssr, SSR_REG_CFG_PAY_CUTOFF_NS, c.pay_cutoff_ns);
	ssr_writel(ssr, SSR_REG_CFG_PACE_GAP, c.pace_gap);
	ssr_writel(ssr, SSR_REG_CFG_PAY_GAP, c.pay_gap);
	ssr_writel(ssr, SSR_REG_CFG_FRAGS_PER_ROUND, c.frags_per_round);
	ret = ssr_read_identity(ssr);
	mutex_unlock(&ssr->lock);

	if (!ret && ssr->info.pay_ring_bytes != old_pay_bytes) {
		ssr_rings_hw_teardown(ssr);
		ssr_rings_free(ssr);
		ret = ssr_rings_alloc(ssr);
		if (ret)
			dev_err(ssr->dev, "no rings for %u nodes; the device is dead until reprobed\n",
				ssr->info.node_count);
		else
			ssr_rings_hw_setup(ssr);
	}
	mutex_unlock(&ssr->read_lock);
	mutex_unlock(&ssr->prop_lock);
	if (!ret)
		dev_info(ssr->dev, "configured: node %u of %u, quorum %u, round %u ns, ctrl %u..%u ns, cutoff %u ns, %u frags\n",
			 c.node_id, c.node_count, c.quorum, c.round_ns, c.tx_start_ns,
			 c.ctrl_deadline_ns, c.pay_cutoff_ns, c.frags_per_round);
	return ret;
}

static int ssr_ioc_activate(struct mqnic_app_ssr *ssr, void __user *uarg)
{
	struct ssr_activate a;
	u64 eff;
	int ret;

	if (copy_from_user(&a, uarg, sizeof(a)))
		return -EFAULT;
	mutex_lock(&ssr->lock);
	eff = a.effective_round;
	if (!eff) {
		ret = ssr_core_arm(ssr);
		if (ret) {
			mutex_unlock(&ssr->lock);
			return ret;
		}
		eff = ssr_readq_pair(ssr, SSR_REG_CUR_ROUND_LO) + a.rounds_ahead;
	}
	ssr_writel(ssr, SSR_REG_CFG_RUN_ID, a.run_id);
	ssr_writel(ssr, SSR_REG_CFG_MEMBERSHIP, a.membership);
	ssr_writel(ssr, SSR_REG_CFG_EFF_ROUND_LO, lower_32_bits(eff));
	ssr_writel(ssr, SSR_REG_CFG_EFF_ROUND_HI, upper_32_bits(eff));
	ssr_writel(ssr, SSR_REG_CORE_CONTROL, SSR_CORE_CTRL_ENABLE | SSR_CORE_CTRL_ACTIVATE);
	mutex_unlock(&ssr->lock);
	dev_info(ssr->dev, "activate: run 0x%x membership 0x%02x at round %llu\n",
		 a.run_id, a.membership, eff);
	return 0;
}

static int ssr_ioc_get_status(struct mqnic_app_ssr *ssr, void __user *uarg)
{
	struct ssr_status s;

	mutex_lock(&ssr->lock);
	s.core_status = ssr_readl(ssr, SSR_REG_CORE_STATUS);
	s.cur_run_id = ssr_readl(ssr, SSR_REG_CUR_RUN_ID);
	s.sound_set = ssr_readl(ssr, SSR_REG_CUR_SOUND_SET) & 0xff;
	s.membership = ssr_readl(ssr, SSR_REG_CUR_MEMBERSHIP) & 0xff;
	s.cur_round = ssr_readq_pair(ssr, SSR_REG_CUR_ROUND_LO);
	s.round_count = ssr_readq_pair(ssr, SSR_REG_ROUND_COUNT_LO);
	s.commit_count = ssr_readq_pair(ssr, SSR_REG_COMMIT_COUNT_LO);
	s.halt_count = ssr_readl(ssr, SSR_REG_HALT_COUNT);
	s.halt_reason = ssr_readl(ssr, SSR_REG_HALT_REASON);
	s.halt_round = ssr_readq_pair(ssr, SSR_REG_HALT_ROUND_LO);
	s.halt_witness = ssr_readl(ssr, SSR_REG_HALT_WITNESS) & 0xff;
	s.halt_membership = ssr_readl(ssr, SSR_REG_HALT_MEMBERSHIP) & 0xff;
	s.halt_sound_set = ssr_readl(ssr, SSR_REG_HALT_SOUND_SET) & 0xffff;
	s.fault = ssr_readl(ssr, SSR_REG_FAULT);
	s.prop_status = ssr_readl(ssr, SSR_REG_PROP_STATUS);
	s.prop_producer = ssr_readl(ssr, SSR_REG_PROP_PRODUCER);
	s.prop_consumer = ssr_readl(ssr, SSR_REG_PROP_CONSUMER);
	s.dlv_status = ssr_readl(ssr, SSR_REG_DLV_STATUS);
	s.seq = ssr_readq_pair(ssr, SSR_REG_SEQ_LO);
	mutex_unlock(&ssr->lock);
	return copy_to_user(uarg, &s, sizeof(s)) ? -EFAULT : 0;
}

static int ssr_ioc_get_counters(struct mqnic_app_ssr *ssr, void __user *uarg)
{
	struct ssr_counters *c;
	int i, ret;

	c = kmalloc(sizeof(*c), GFP_KERNEL);
	if (!c)
		return -ENOMEM;
	mutex_lock(&ssr->lock);
	for (i = 0; i < SSR_COUNTERS_WORDS; i++)
		c->w[i] = ssr_readl(ssr, SSR_COUNTERS_BASE + 4 * i);
	mutex_unlock(&ssr->lock);
	ret = copy_to_user(uarg, c, sizeof(*c)) ? -EFAULT : 0;
	kfree(c);
	return ret;
}

/* FLUSH drops every entry not yet on the wire; CLEAR_ERROR re-reads from the
 * failed entry. Both pulse a bit and wait for the engine to settle. */
static int ssr_ioc_prop_recover(struct mqnic_app_ssr *ssr, u32 bit)
{
	unsigned long deadline = jiffies + HZ;
	int ret = 0;

	mutex_lock(&ssr->prop_lock);
	mutex_lock(&ssr->lock);
	ssr_writel(ssr, SSR_REG_PROP_CONTROL, SSR_PROP_CTRL_ENABLE | bit);
	while (ssr_readl(ssr, SSR_REG_PROP_STATUS) & SSR_PROP_STATUS_PENDING) {
		if (time_after(jiffies, deadline)) {
			ret = -ETIMEDOUT;
			goto out;
		}
		usleep_range(5, 20);
	}
	ssr_datapath_follow_producer(ssr);
out:
	mutex_unlock(&ssr->lock);
	mutex_unlock(&ssr->prop_lock);
	return ret;
}

static int ssr_ioc_set_delivery(struct mqnic_app_ssr *ssr, void __user *uarg)
{
	u32 v;

	if (copy_from_user(&v, uarg, sizeof(v)))
		return -EFAULT;
	mutex_lock(&ssr->lock);
	ssr_writel(ssr, SSR_REG_DLV_CONTROL, v & (SSR_DLV_CTRL_PAYLOAD | SSR_DLV_CTRL_VERDICT));
	mutex_unlock(&ssr->lock);
	return 0;
}

static void ssr_core_control(struct mqnic_app_ssr *ssr, u32 value)
{
	mutex_lock(&ssr->lock);
	ssr_writel(ssr, SSR_REG_CORE_CONTROL, value);
	mutex_unlock(&ssr->lock);
}

long ssr_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	struct mqnic_app_ssr *ssr = file->private_data;
	void __user *uarg = (void __user *)arg;

	switch (cmd) {
	case SSR_IOC_GET_INFO:
		return copy_to_user(uarg, &ssr->info, sizeof(ssr->info)) ? -EFAULT : 0;
	case SSR_IOC_ACTIVATE:
		return ssr_ioc_activate(ssr, uarg);
	case SSR_IOC_REBOOT:
		ssr_core_control(ssr, SSR_CORE_CTRL_ENABLE | SSR_CORE_CTRL_REBOOT);
		return 0;
	case SSR_IOC_DISABLE:
		ssr_core_control(ssr, 0);
		return 0;
	case SSR_IOC_GET_STATUS:
		return ssr_ioc_get_status(ssr, uarg);
	case SSR_IOC_GET_COUNTERS:
		return ssr_ioc_get_counters(ssr, uarg);
	case SSR_IOC_PROP_FLUSH:
		return ssr_ioc_prop_recover(ssr, SSR_PROP_CTRL_FLUSH);
	case SSR_IOC_PROP_CLEAR_ERR:
		return ssr_ioc_prop_recover(ssr, SSR_PROP_CTRL_CLEAR_ERROR);
	case SSR_IOC_SET_DELIVERY:
		return ssr_ioc_set_delivery(ssr, uarg);
	case SSR_IOC_RESET_CURSOR:
		ssr_datapath_reset_cursor(ssr);
		return 0;
	case SSR_IOC_ENABLE:
		return ssr_ioc_enable(ssr);
	case SSR_IOC_CONFIGURE:
		return ssr_ioc_configure(ssr, uarg);
	default:
		return -ENOTTY;
	}
}

/* ------------------------------------------------------------------ sysfs */

static ssize_t identity_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);
	struct ssr_info *i = &ssr->info;

	return sysfs_emit(buf, "node %u of %u, round %u ns, page %u, region 2^%u, rings 2^%u/2^%u/2^%u, /dev/ssr%d\n",
			  i->node_id, i->node_count, i->round_ns, i->page_bytes, i->region_shift,
			  i->prop_depth_log2, i->pay_depth_log2, i->ver_depth_log2, ssr->minor);
}
static DEVICE_ATTR_RO(identity);

static ssize_t core_status_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);
	u32 st, run, sound;
	u64 round, commits;

	mutex_lock(&ssr->lock);
	st = ssr_readl(ssr, SSR_REG_CORE_STATUS);
	run = ssr_readl(ssr, SSR_REG_CUR_RUN_ID);
	sound = ssr_readl(ssr, SSR_REG_CUR_SOUND_SET);
	round = ssr_readq_pair(ssr, SSR_REG_CUR_ROUND_LO);
	commits = ssr_readq_pair(ssr, SSR_REG_COMMIT_COUNT_LO);
	mutex_unlock(&ssr->lock);
	return sysfs_emit(buf, "status 0x%02x run 0x%x sound 0x%02x round %llu commits %llu\n",
			  st, run, sound & 0xff, round, commits);
}
static DEVICE_ATTR_RO(core_status);

static ssize_t fault_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);
	u32 val;

	mutex_lock(&ssr->lock);
	val = ssr_readl(ssr, SSR_REG_FAULT);
	mutex_unlock(&ssr->lock);
	return sysfs_emit(buf, "0x%08x\n", val);
}
static DEVICE_ATTR_RO(fault);

static ssize_t counters_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	static const struct { u32 reg; const char *name; } tbl[] = {
		{ SSR_REG_ROUND_COUNT_LO, "rounds" }, { SSR_REG_COMMIT_COUNT_LO, "commits" },
		{ SSR_REG_HALT_COUNT, "halts" }, { SSR_REG_TIME_FAULT_COUNT, "time_faults" },
		{ SSR_REG_TX_CTRL_FRAMES, "tx_ctrl" }, { SSR_REG_TX_PAY_FRAMES, "tx_pay" },
		{ SSR_REG_TX_EMPTY, "tx_empty" }, { SSR_REG_TX_OVERRUN, "tx_overrun" },
		{ SSR_REG_TX_MISSED, "tx_missed" }, { SSR_REG_TX_HOST_FRAMES, "tx_host" },
		{ SSR_REG_RX_FRAMES, "rx_frames" }, { SSR_REG_RX_ACCEPT, "rx_accept" },
		{ SSR_REG_RX_CTRL, "rx_ctrl" }, { SSR_REG_RX_MALFORMED, "rx_malformed" },
		{ SSR_REG_RX_CTRL_LATE, "rx_ctrl_late" }, { SSR_REG_RX_WINDOW_DROP, "rx_window_drop" },
		{ SSR_REG_RX_MEMBER_DROP, "rx_member_drop" }, { SSR_REG_RX_SOUND_DROP, "rx_sound_drop" },
		{ SSR_REG_RX_RUN_DROP, "rx_run_drop" }, { SSR_REG_RX_ROUND_DROP, "rx_round_drop" },
		{ SSR_REG_RX_ACK_DISAGREE, "rx_ack_disagree" }, { SSR_REG_RX_HOST_FRAMES, "rx_host" },
		{ SSR_REG_PROP_READS, "prop_reads" }, { SSR_REG_PROP_READ_ERRORS, "prop_read_errors" },
		{ SSR_REG_STAGE_PUSH, "stage_push" }, { SSR_REG_STAGE_FULL, "stage_full" },
		{ SSR_REG_PAY_DESC, "pay_desc" }, { SSR_REG_PAY_CPL, "pay_cpl" },
		{ SSR_REG_PAY_ERR, "pay_err" }, { SSR_REG_PAY_STARVE, "pay_starve" },
		{ SSR_REG_PRES_LATE, "pres_late" }, { SSR_REG_PRES_ERR, "pres_err" },
		{ SSR_REG_VERDICT_RECORDS, "verdict_records" }, { SSR_REG_VERDICT_ERR, "verdict_err" },
		{ SSR_REG_VERDICT_OVERFLOW, "verdict_overflow" }, { SSR_REG_VERDICT_STALE, "verdict_stale" },
	};
	struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);
	ssize_t n = 0;
	int i;

	mutex_lock(&ssr->lock);
	for (i = 0; i < ARRAY_SIZE(tbl); i++)
		n += sysfs_emit_at(buf, n, "%s %u\n", tbl[i].name, ssr_readl(ssr, tbl[i].reg));
	mutex_unlock(&ssr->lock);
	return n;
}
static DEVICE_ATTR_RO(counters);

static ssize_t scratch_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);
	u32 val;

	mutex_lock(&ssr->lock);
	val = ssr_readl(ssr, SSR_REG_SCRATCH);
	mutex_unlock(&ssr->lock);
	return sysfs_emit(buf, "0x%08x\n", val);
}
static ssize_t scratch_store(struct device *dev, struct device_attribute *attr, const char *buf, size_t count)
{
	struct mqnic_app_ssr *ssr = dev_get_drvdata(dev);
	u32 val;
	int ret;

	ret = kstrtou32(buf, 0, &val);
	if (ret)
		return ret;
	mutex_lock(&ssr->lock);
	ssr_writel(ssr, SSR_REG_SCRATCH, val);
	mutex_unlock(&ssr->lock);
	return count;
}
static DEVICE_ATTR_RW(scratch);

static struct attribute *ssr_attrs[] = {
	&dev_attr_identity.attr,
	&dev_attr_core_status.attr,
	&dev_attr_fault.attr,
	&dev_attr_counters.attr,
	&dev_attr_scratch.attr,
	NULL,
};

const struct attribute_group ssr_attr_group = {
	.attrs = ssr_attrs,
};
