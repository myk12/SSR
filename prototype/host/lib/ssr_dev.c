// SPDX-License-Identifier: BSD-2-Clause-Views
#define _GNU_SOURCE
#include "ssr_dev.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>

/* Big-endian field access into the rings (rtl/ssr_packet.vh, ssr_verdict.vh). */
static inline uint16_t be16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static inline uint32_t be32(const uint8_t *p) { return ((uint32_t)be16(p) << 16) | be16(p + 2); }
static inline uint64_t be64(const uint8_t *p) { return ((uint64_t)be32(p) << 32) | be32(p + 4); }

/* Compiler + CPU ordering for the DMA-visible rings and the register page. */
#define ssr_rmb()   __atomic_thread_fence(__ATOMIC_ACQUIRE)
#define ssr_wmb()   __atomic_thread_fence(__ATOMIC_RELEASE)
#if defined(__x86_64__) || defined(__i386__)
#define ssr_mmio_wmb()  __asm__ __volatile__("sfence" ::: "memory")
#else
#define ssr_mmio_wmb()  __sync_synchronize()
#endif

static inline uint32_t reg_rd(struct ssr_dev *d, uint32_t off) { return d->regs[off / 4]; }
static inline void reg_wr(struct ssr_dev *d, uint32_t off, uint32_t v) { d->regs[off / 4] = v; }

/* ------------------------------------------------------------- control */

int ssr_dev_open(struct ssr_dev *d, const char *path)
{
	memset(d, 0, sizeof(*d));
	d->fd = open(path, O_RDWR | O_CLOEXEC);
	if (d->fd < 0)
		return -errno;
	if (ioctl(d->fd, SSR_IOC_GET_INFO, &d->info) < 0) {
		int e = -errno;
		close(d->fd);
		d->fd = -1;
		return e;
	}
	return 0;
}

void ssr_dev_close(struct ssr_dev *d)
{
	ssr_dev_unmap(d);
	if (d->fd >= 0)
		close(d->fd);
	d->fd = -1;
}

int ssr_dev_activate(struct ssr_dev *d, uint32_t run_id, uint32_t membership,
		     uint64_t effective_round, uint32_t rounds_ahead)
{
	struct ssr_activate a = {
		.run_id = run_id, .membership = membership,
		.effective_round = effective_round, .rounds_ahead = rounds_ahead,
	};
	return ioctl(d->fd, SSR_IOC_ACTIVATE, &a) < 0 ? -errno : 0;
}

int ssr_dev_reboot(struct ssr_dev *d)
{
	return ioctl(d->fd, SSR_IOC_REBOOT) < 0 ? -errno : 0;
}

int ssr_dev_disable(struct ssr_dev *d)
{
	return ioctl(d->fd, SSR_IOC_DISABLE) < 0 ? -errno : 0;
}

int ssr_dev_status(struct ssr_dev *d, struct ssr_status *s)
{
	return ioctl(d->fd, SSR_IOC_GET_STATUS, s) < 0 ? -errno : 0;
}

int ssr_dev_counters(struct ssr_dev *d, struct ssr_counters *c)
{
	return ioctl(d->fd, SSR_IOC_GET_COUNTERS, c) < 0 ? -errno : 0;
}

int ssr_dev_prop_flush(struct ssr_dev *d)
{
	return ioctl(d->fd, SSR_IOC_PROP_FLUSH) < 0 ? -errno : 0;
}

int ssr_dev_prop_clear_error(struct ssr_dev *d)
{
	return ioctl(d->fd, SSR_IOC_PROP_CLEAR_ERR) < 0 ? -errno : 0;
}

static uint64_t now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

/* Running: the run id we asked for is installed, the activation is no longer
 * pending and the node is not halted. -ETIMEDOUT, or -EIO on a halt. */
int ssr_dev_wait_running(struct ssr_dev *d, uint32_t run_id, int timeout_ms)
{
	uint64_t deadline = now_ms() + (uint64_t)timeout_ms;
	struct ssr_status s;
	int ret;

	for (;;) {
		ret = ssr_dev_status(d, &s);
		if (ret)
			return ret;
		if (s.core_status & SSR_CORE_STATUS_HALTED)
			return -EIO;
		if (s.cur_run_id == run_id && !(s.core_status & SSR_CORE_STATUS_ACT_PENDING))
			return 0;
		if (now_ms() > deadline)
			return -ETIMEDOUT;
		usleep(100);
	}
}

void ssr_record_decode(const uint8_t *raw, struct ssr_record *r)
{
	int k;

	r->round_id = be64(raw + SSR_VERDICT_OFF_ROUND_ID);
	r->seq = be64(raw + SSR_VERDICT_OFF_SEQ);
	r->run_id = be32(raw + SSR_VERDICT_OFF_RUN_ID);
	r->commit_set = raw[SSR_VERDICT_OFF_COMMIT_SET];
	r->present_set = raw[SSR_VERDICT_OFF_PRESENT_SET];
	r->node_count = raw[SSR_VERDICT_OFF_NODE_COUNT];
	r->self_index = raw[SSR_VERDICT_OFF_SELF_INDEX];
	for (k = 0; k < SSR_VERDICT_MAX_NODES; k++)
		r->frag_count[k] = be16(raw + SSR_VERDICT_OFF_FRAG_COUNTS + 2 * k);
	r->prop_consumer = be32(raw + SSR_VERDICT_OFF_PROP_CONSUMER);
}

/* -------------------------------------------------------- the kernel path */

int ssr_dev_propose_copy(struct ssr_dev *d, const void *piece, size_t len)
{
	ssize_t n = write(d->fd, piece, len);
	return n < 0 ? -errno : (int)n;
}

int ssr_dev_recv_copy(struct ssr_dev *d, void *buf, size_t cap)
{
	ssize_t n = read(d->fd, buf, cap);
	return n < 0 ? -errno : (int)n;
}

/* ------------------------------------------------------ the zero-copy path */

int ssr_dev_map(struct ssr_dev *d)
{
	void *p;

	p = mmap(NULL, d->info.prop_ring_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, d->fd, (off_t)SSR_MMAP_PROP_RING);
	if (p == MAP_FAILED)
		goto fail;
	d->prop_ring = p;
	p = mmap(NULL, d->info.pay_ring_bytes, PROT_READ, MAP_SHARED, d->fd, (off_t)SSR_MMAP_PAY_RING);
	if (p == MAP_FAILED)
		goto fail;
	d->pay_ring = p;
	p = mmap(NULL, d->info.ver_ring_bytes, PROT_READ, MAP_SHARED, d->fd, (off_t)SSR_MMAP_VER_RING);
	if (p == MAP_FAILED)
		goto fail;
	d->ver_ring = p;
	p = mmap(NULL, d->info.regs_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, d->fd, (off_t)SSR_MMAP_REGS);
	if (p == MAP_FAILED)
		goto fail;
	d->regs = p;

	d->zc_producer = reg_rd(d, SSR_REG_PROP_PRODUCER);
	d->zc_consumer = reg_rd(d, SSR_REG_PROP_CONSUMER);
	return ssr_zc_reset_cursor(d);
fail: {
		int e = -errno;
		ssr_dev_unmap(d);
		return e;
	}
}

void ssr_dev_unmap(struct ssr_dev *d)
{
	if (d->prop_ring) munmap(d->prop_ring, d->info.prop_ring_bytes);
	if (d->pay_ring) munmap(d->pay_ring, d->info.pay_ring_bytes);
	if (d->ver_ring) munmap(d->ver_ring, d->info.ver_ring_bytes);
	if (d->regs) munmap((void *)d->regs, d->info.regs_bytes);
	d->prop_ring = d->pay_ring = d->ver_ring = NULL;
	d->regs = NULL;
}

int ssr_zc_reset_cursor(struct ssr_dev *d)
{
	uint32_t lo, hi;

	if (!d->regs)
		return -EINVAL;
	lo = reg_rd(d, SSR_REG_SEQ_LO);
	hi = reg_rd(d, SSR_REG_SEQ_HI);
	d->zc_next_seq = ((uint64_t)hi << 32) | lo;
	return 0;
}

uint32_t ssr_zc_room(struct ssr_dev *d)
{
	uint32_t depth = 1u << d->info.prop_depth_log2;

	d->zc_consumer = reg_rd(d, SSR_REG_PROP_CONSUMER);
	return depth - (d->zc_producer - d->zc_consumer);
}

int ssr_zc_propose(struct ssr_dev *d, const void *piece, size_t len)
{
	uint32_t depth = 1u << d->info.prop_depth_log2;
	uint8_t *entry;

	if (!d->prop_ring || len < 1 || len > SSR_PROPOSAL_PIECE_BYTES)
		return -EINVAL;
	/* Room, from the last consumer we saw (a record carries it; ssr_zc_room()
	 * reads the register). Only when that says full do we go to the register. */
	if (d->zc_producer - d->zc_consumer >= depth && ssr_zc_room(d) == 0)
		return -EAGAIN;

	entry = d->prop_ring + (size_t)(d->zc_producer & (depth - 1)) * d->info.page_bytes;
	memset(entry, 0, SSR_PROPOSAL_PAYLOAD_OFF);
	memcpy(entry + SSR_PROPOSAL_PAYLOAD_OFF, piece, len);
	if (len < SSR_PROPOSAL_PIECE_BYTES)
		memset(entry + SSR_PROPOSAL_PAYLOAD_OFF + len, 0, SSR_PROPOSAL_PIECE_BYTES - len);
	ssr_wmb();
	ssr_mmio_wmb();                         /* the entry is in memory before the doorbell */
	d->zc_producer++;
	reg_wr(d, SSR_REG_PROP_PRODUCER, d->zc_producer);
	return (int)len;
}

int ssr_zc_poll(struct ssr_dev *d, struct ssr_record *r, const uint8_t **raw)
{
	uint64_t mask = (1ULL << d->info.ver_depth_log2) - 1;
	const uint8_t *rec = d->ver_ring + (d->zc_next_seq & mask) * SSR_VERDICT_RECORD_BYTES;

	if (be64(rec + SSR_VERDICT_OFF_SEQ) != d->zc_next_seq)
		return 0;
	ssr_rmb();                              /* the seq field, then the rest */
	ssr_record_decode(rec, r);
	d->zc_consumer = r->prop_consumer;      /* flow control without an MMIO read */
	if (raw)
		*raw = rec;
	d->zc_next_seq++;
	return 1;
}

const uint8_t *ssr_zc_page(struct ssr_dev *d, uint64_t round_id, uint32_t node,
			   uint32_t frag, uint32_t *len)
{
	uint64_t slot = round_id & ((1ULL << d->info.pay_depth_log2) - 1);
	uint64_t region = (slot * d->info.node_count + node) << d->info.region_shift;
	const uint8_t *page = d->pay_ring + region + ((uint64_t)frag << SSR_PAGE_SHIFT);

	if (len)
		*len = be16(page + 28);
	return page;
}
