/* SPDX-License-Identifier: BSD-2-Clause-Views */
/*
 * ssr_dev - user-space access to /dev/ssrN (kernel/ssr_uapi.h), both ways.
 *
 *   control        ssr_dev_open / info / activate / reboot / status / counters
 *   kernel path    ssr_dev_propose_copy() = write(), ssr_dev_recv_copy() = read()
 *   zero-copy path ssr_dev_map(), then ssr_zc_propose() writes the ring entry and
 *                  the doorbell from user space, ssr_zc_poll() finds the next
 *                  record in the mapped verdict ring, ssr_zc_page() addresses a
 *                  page in the mapped payload ring. No syscall on the fast path.
 *
 * Every function returns 0 or a size on success and -errno on failure.
 */
#ifndef SSR_DEV_H
#define SSR_DEV_H

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

#include "ssr_uapi.h"
#include "ssr_regs.h"

#ifdef __cplusplus
extern "C" {
#endif

struct ssr_dev {
	int fd;
	struct ssr_info info;

	/* the zero-copy path, after ssr_dev_map() */
	uint8_t *prop_ring;
	uint8_t *pay_ring;
	uint8_t *ver_ring;
	volatile uint32_t *regs;    /* the SSR register page, 4 KiB, uncached */
	uint32_t zc_producer;       /* our copy of PROP_PRODUCER */
	uint32_t zc_consumer;       /* last CONSUMER seen (from a record or the register) */
	uint64_t zc_next_seq;       /* the record ssr_zc_poll() waits for */
};

/* A decoded verdict record, host order. */
struct ssr_record {
	uint64_t round_id;
	uint64_t seq;
	uint32_t run_id;
	uint8_t commit_set;
	uint8_t present_set;
	uint8_t node_count;
	uint8_t self_index;
	uint16_t frag_count[SSR_VERDICT_MAX_NODES];
	uint32_t prop_consumer;
};

/* ---- control ---- */
int ssr_dev_open(struct ssr_dev *d, const char *path);
void ssr_dev_close(struct ssr_dev *d);
int ssr_dev_activate(struct ssr_dev *d, uint32_t run_id, uint32_t membership,
		     uint64_t effective_round, uint32_t rounds_ahead);
int ssr_dev_reboot(struct ssr_dev *d);
int ssr_dev_disable(struct ssr_dev *d);
int ssr_dev_status(struct ssr_dev *d, struct ssr_status *s);
int ssr_dev_counters(struct ssr_dev *d, struct ssr_counters *c);
int ssr_dev_wait_running(struct ssr_dev *d, uint32_t run_id, int timeout_ms);
int ssr_dev_prop_flush(struct ssr_dev *d);
int ssr_dev_prop_clear_error(struct ssr_dev *d);
void ssr_record_decode(const uint8_t *raw, struct ssr_record *r);

/* ---- the kernel path ---- */
int ssr_dev_propose_copy(struct ssr_dev *d, const void *piece, size_t len);
/* buf must hold sizeof(struct ssr_delivery) + the payload; 64 KiB is enough
 * for any cluster this bitstream supports (3 nodes x 5 pages). Returns the
 * number of bytes filled. */
int ssr_dev_recv_copy(struct ssr_dev *d, void *buf, size_t cap);

/* ---- the zero-copy path ---- */
int ssr_dev_map(struct ssr_dev *d);
void ssr_dev_unmap(struct ssr_dev *d);
/* Entries free in the proposal ring right now (reads the CONSUMER register). */
uint32_t ssr_zc_room(struct ssr_dev *d);
/* Write one piece (1..4032 bytes) into the next entry and ring the doorbell.
 * -EAGAIN if the ring is full. */
int ssr_zc_propose(struct ssr_dev *d, const void *piece, size_t len);
/* The next record, if it has landed: fills *r, advances the cursor, returns 1;
 * returns 0 if not yet. raw, if not NULL, receives a pointer to the 64 bytes. */
int ssr_zc_poll(struct ssr_dev *d, struct ssr_record *r, const uint8_t **raw);
/* One page of the payload ring: 64 bytes of frame header, then the payload.
 * *len receives the payload length the header carries. */
const uint8_t *ssr_zc_page(struct ssr_dev *d, uint64_t round_id, uint32_t node,
			   uint32_t frag, uint32_t *len);
/* Reposition the cursor at the hardware's next seq (after a long pause). */
int ssr_zc_reset_cursor(struct ssr_dev *d);

#ifdef __cplusplus
}
#endif
#endif /* SSR_DEV_H */
