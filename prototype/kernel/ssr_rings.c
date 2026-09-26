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
#include <linux/gfp.h>
#include <linux/mm.h>
#include <linux/mmzone.h>
#include <linux/nodemask.h>
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

/* ---- the payload ring: 24 MiB, physically contiguous ----
 *
 * The buddy allocator stops at 4 MiB (MAX_ORDER), so dma_alloc_coherent() can
 * only give us this much from a CMA area or behind an IOMMU. The testbed's
 * kernel has neither (no CONFIG_DMA_CMA; the IOMMU is off, and the boot line
 * is managed by the lab). alloc_contig_range() is the tool the kernel itself
 * uses for huge pages: pick a range of movable memory, migrate whatever lives
 * there out of the way, hand it over. We scan ZONE_NORMAL for a candidate,
 * preferring the NIC's own NUMA node, and stop at the first range that works.
 * x86 DMA is cache-coherent, so the streaming mapping needs no sync calls;
 * dma_map_page() here is only about the bus address. */

/* One zone: 2 MiB steps, a range must lie inside the zone. */
static struct page *ssr_alloc_contig_in(struct device *dev, struct zone *zone, unsigned long nr_pages)
{
	unsigned long pfn, end = zone_end_pfn(zone);
	int tries = 0;

	if (!populated_zone(zone))
		return NULL;
	for (pfn = ALIGN(zone->zone_start_pfn, 512); pfn + nr_pages <= end && tries < 4096; pfn += 512) {
		struct page *first = pfn_to_online_page(pfn);

		if (!first || PageReserved(first))
			continue;
		tries++;
		/* NOWARN: a busy range is not an error, the next one is tried */
		if (alloc_contig_range(pfn, pfn + nr_pages, MIGRATE_MOVABLE, GFP_KERNEL | __GFP_NOWARN) == 0) {
			dev_info(dev, "payload ring: %lu pages at pfn 0x%lx (node %d, %d ranges tried)\n",
				 nr_pages, pfn, zone_to_nid(zone), tries);
			return first;
		}
	}
	return NULL;
}

/* The NIC's own NUMA node first, then the others. */
static struct page *ssr_alloc_contig(struct device *dev, unsigned long nr_pages)
{
	int nid = dev_to_node(dev), n;
	struct page *page;

	if (nid >= 0) {
		page = ssr_alloc_contig_in(dev, &NODE_DATA(nid)->node_zones[ZONE_NORMAL], nr_pages);
		if (page)
			return page;
	}
	for_each_online_node(n) {
		if (n == nid)
			continue;
		page = ssr_alloc_contig_in(dev, &NODE_DATA(n)->node_zones[ZONE_NORMAL], nr_pages);
		if (page)
			return page;
	}
	return NULL;
}

static void ssr_free_contig(struct page *page, unsigned long nr_pages)
{
	unsigned long i;

	/* alloc_contig_range() hands out nr_pages order-0 pages, one ref each */
	for (i = 0; i < nr_pages; i++)
		__free_page(page + i);
}

/* The largest block the buddy allocator hands out: order 10, 4 MiB on x86.
 * (The kernel's own name for it changed twice, MAX_ORDER then MAX_PAGE_ORDER.) */
#define SSR_BUDDY_MAX_BYTES	(PAGE_SIZE << 10)

static int ssr_pay_alloc(struct mqnic_app_ssr *ssr)
{
	struct ssr_info *inf = &ssr->info;
	unsigned long nr_pages = PAGE_ALIGN(inf->pay_ring_bytes) >> PAGE_SHIFT;

	if (inf->pay_ring_bytes <= SSR_BUDDY_MAX_BYTES) {
		ssr->pay_ring = dma_alloc_coherent(ssr->dma_dev, inf->pay_ring_bytes, &ssr->pay_dma, GFP_KERNEL);
		return ssr->pay_ring ? 0 : -ENOMEM;
	}

	ssr->pay_page = ssr_alloc_contig(ssr->dma_dev, nr_pages);
	if (!ssr->pay_page) {
		dev_err(ssr->dev, "no %lu contiguous pages for the payload ring\n", nr_pages);
		return -ENOMEM;
	}
	ssr->pay_dma = dma_map_page(ssr->dma_dev, ssr->pay_page, 0, nr_pages << PAGE_SHIFT, DMA_BIDIRECTIONAL);
	if (dma_mapping_error(ssr->dma_dev, ssr->pay_dma)) {
		dev_err(ssr->dev, "cannot map the payload ring for DMA\n");
		ssr_free_contig(ssr->pay_page, nr_pages);
		ssr->pay_page = NULL;
		return -ENOMEM;
	}
	ssr->pay_ring = page_address(ssr->pay_page);
	return 0;
}

static void ssr_pay_free(struct mqnic_app_ssr *ssr)
{
	struct ssr_info *inf = &ssr->info;

	if (!ssr->pay_ring)
		return;
	if (ssr->pay_page) {
		unsigned long nr_pages = PAGE_ALIGN(inf->pay_ring_bytes) >> PAGE_SHIFT;

		dma_unmap_page(ssr->dma_dev, ssr->pay_dma, nr_pages << PAGE_SHIFT, DMA_BIDIRECTIONAL);
		ssr_free_contig(ssr->pay_page, nr_pages);
		ssr->pay_page = NULL;
	} else {
		dma_free_coherent(ssr->dma_dev, inf->pay_ring_bytes, ssr->pay_ring, ssr->pay_dma);
	}
	ssr->pay_ring = NULL;
}

/* ---- all three ---- */

int ssr_rings_alloc(struct mqnic_app_ssr *ssr)
{
	struct ssr_info *inf = &ssr->info;

	inf->prop_ring_bytes = (u64)inf->page_bytes << inf->prop_depth_log2;
	inf->pay_ring_bytes = ((u64)inf->node_count << inf->region_shift) << inf->pay_depth_log2;
	inf->ver_ring_bytes = (u64)SSR_VERDICT_RECORD_BYTES << inf->ver_depth_log2;

	ssr->prop_ring = dma_alloc_coherent(ssr->dma_dev, inf->prop_ring_bytes, &ssr->prop_dma, GFP_KERNEL);
	if (!ssr->prop_ring)
		return -ENOMEM;
	if (ssr_pay_alloc(ssr))
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
	ssr_pay_free(ssr);
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
	ssr_pay_free(ssr);
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
