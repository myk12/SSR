// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * ssr_rings.c - the three rings in host memory, and pointing the NIC at them.
 *
 *   proposal ring   host -> NIC   2^prop_depth_log2 entries of 4 KiB
 *   payload ring    NIC -> host   2^pay_depth_log2 rounds x N nodes x 2^region_shift
 *   verdict ring    NIC -> host   2^ver_depth_log2 records of 64 B
 *
 * All three are coherent DMA memory: the NIC writes them, the CPU reads them,
 * nobody flushes anything. The verdict ring is primed with seq = ~0 in every
 * slot, so "the record with seq s has landed" is exactly "slot s holds seq s"
 * (ring_buffer.md). The hardware consumes nothing; records age out.
 */

#include <linux/delay.h>
#include <linux/slab.h>

#include "ssr_drv.h"

static void ssr_prime_verdict_ring(struct mqnic_app_ssr *ssr)
{
	u64 n = 1ULL << ssr->info.ver_depth_log2;
	u64 i;

	memset(ssr->ver_ring, 0, ssr->info.ver_ring_bytes);
	for (i = 0; i < n; i++)
		put_unaligned_be64(~0ULL, (u8 *)ssr->ver_ring + i * SSR_VERDICT_RECORD_BYTES + SSR_VERDICT_OFF_SEQ);
}

int ssr_rings_alloc(struct mqnic_app_ssr *ssr)
{
	struct ssr_info *inf = &ssr->info;

	inf->prop_ring_bytes = (u64)inf->page_bytes << inf->prop_depth_log2;
	inf->pay_ring_bytes = ((u64)inf->node_count << inf->region_shift) << inf->pay_depth_log2;
	inf->ver_ring_bytes = (u64)SSR_VERDICT_RECORD_BYTES << inf->ver_depth_log2;

	ssr->prop_ring = dma_alloc_coherent(ssr->dma_dev, inf->prop_ring_bytes, &ssr->prop_dma, GFP_KERNEL);
	if (!ssr->prop_ring)
		return -ENOMEM;
	ssr->pay_ring = dma_alloc_coherent(ssr->dma_dev, inf->pay_ring_bytes, &ssr->pay_dma, GFP_KERNEL);
	if (!ssr->pay_ring)
		goto fail_prop;
	ssr->ver_ring = dma_alloc_coherent(ssr->dma_dev, inf->ver_ring_bytes, &ssr->ver_dma, GFP_KERNEL);
	if (!ssr->ver_ring)
		goto fail_pay;

	if ((ssr->prop_dma | ssr->pay_dma) & (inf->page_bytes - 1) ||
	    ssr->ver_dma & (SSR_VERDICT_RECORD_BYTES - 1)) {
		dev_err(ssr->dev, "ring bases are not page / record aligned\n");
		dma_free_coherent(ssr->dma_dev, inf->ver_ring_bytes, ssr->ver_ring, ssr->ver_dma);
		goto fail_pay;
	}

	memset(ssr->prop_ring, 0, inf->prop_ring_bytes);
	memset(ssr->pay_ring, 0, inf->pay_ring_bytes);
	ssr_prime_verdict_ring(ssr);

	dev_info(ssr->dev, "rings: proposal %llu KiB @ %pad, payload %llu KiB @ %pad, verdict %llu KiB @ %pad\n",
		 inf->prop_ring_bytes >> 10, &ssr->prop_dma,
		 inf->pay_ring_bytes >> 10, &ssr->pay_dma,
		 inf->ver_ring_bytes >> 10, &ssr->ver_dma);
	return 0;

fail_pay:
	dma_free_coherent(ssr->dma_dev, inf->pay_ring_bytes, ssr->pay_ring, ssr->pay_dma);
	ssr->pay_ring = NULL;
fail_prop:
	dma_free_coherent(ssr->dma_dev, inf->prop_ring_bytes, ssr->prop_ring, ssr->prop_dma);
	ssr->prop_ring = NULL;
	return -ENOMEM;
}

void ssr_rings_free(struct mqnic_app_ssr *ssr)
{
	struct ssr_info *inf = &ssr->info;

	if (ssr->ver_ring)
		dma_free_coherent(ssr->dma_dev, inf->ver_ring_bytes, ssr->ver_ring, ssr->ver_dma);
	if (ssr->pay_ring)
		dma_free_coherent(ssr->dma_dev, inf->pay_ring_bytes, ssr->pay_ring, ssr->pay_dma);
	if (ssr->prop_ring)
		dma_free_coherent(ssr->dma_dev, inf->prop_ring_bytes, ssr->prop_ring, ssr->prop_dma);
	ssr->ver_ring = ssr->pay_ring = ssr->prop_ring = NULL;
}

/* Program the bases and turn the DMA paths on. The core stays disabled: a
 * node whose host is not taking pages stops calling its peers present and
 * halts, so the rings must be live before the node ever joins. */
void ssr_rings_hw_setup(struct mqnic_app_ssr *ssr)
{
	mutex_lock(&ssr->lock);
	ssr_writel(ssr, SSR_REG_CORE_CONTROL, 0);
	ssr_writel(ssr, SSR_REG_DLV_CONTROL, 0);
	ssr_writel(ssr, SSR_REG_PROP_CONTROL, 0);

	ssr_writel(ssr, SSR_REG_PAY_BASE_LO, lower_32_bits(ssr->pay_dma));
	ssr_writel(ssr, SSR_REG_PAY_BASE_HI, upper_32_bits(ssr->pay_dma));
	ssr_writel(ssr, SSR_REG_VER_BASE_LO, lower_32_bits(ssr->ver_dma));
	ssr_writel(ssr, SSR_REG_VER_BASE_HI, upper_32_bits(ssr->ver_dma));

	ssr_writel(ssr, SSR_REG_PROP_BASE_LO, lower_32_bits(ssr->prop_dma));
	ssr_writel(ssr, SSR_REG_PROP_BASE_HI, upper_32_bits(ssr->prop_dma));
	ssr_writel(ssr, SSR_REG_PROP_DEPTH_LOG2, ssr->info.prop_depth_log2);
	/* Start from wherever the NIC is: after a reset both indices are 0. */
	ssr->producer = ssr_readl(ssr, SSR_REG_PROP_CONSUMER);
	ssr_writel(ssr, SSR_REG_PROP_PRODUCER, ssr->producer);
	ssr_writel(ssr, SSR_REG_PROP_CONTROL, SSR_PROP_CTRL_ENABLE);

	ssr->next_seq = ssr_readq_pair(ssr, SSR_REG_SEQ_LO);
	ssr->woken_seq = ssr->next_seq - 1;
	ssr_writel(ssr, SSR_REG_DLV_CONTROL, SSR_DLV_CTRL_PAYLOAD | SSR_DLV_CTRL_VERDICT);
	mutex_unlock(&ssr->lock);
}

void ssr_rings_hw_teardown(struct mqnic_app_ssr *ssr)
{
	mutex_lock(&ssr->lock);
	ssr_writel(ssr, SSR_REG_CORE_CONTROL, 0);
	ssr_writel(ssr, SSR_REG_PROP_CONTROL, 0);
	ssr_writel(ssr, SSR_REG_DLV_CONTROL, 0);
	mutex_unlock(&ssr->lock);
	/* let any descriptor already handed to the DMA engine complete */
	msleep(20);
}

/* The record read() is waiting for has landed. seq never repeats, and every
 * slot is primed with ~0, so equality is the whole freshness test. */
bool ssr_record_ready(struct mqnic_app_ssr *ssr)
{
	u64 seq = READ_ONCE(ssr->next_seq);
	const u8 *rec = ssr_record_ptr(ssr, seq);
	bool ready = ssr_record_seq(rec) == seq;

	if (ready)
		smp_rmb();  /* the seq field, then the rest of the record */
	return ready;
}
