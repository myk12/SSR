/* SPDX-License-Identifier: BSD-2-Clause-Views */
/*
 * ssr_uapi.h - the user-space ABI of /dev/ssrN (kernel/ssr_datapath.c, ssr_control.c)
 *
 * One device node per SSR NIC. It offers the same hardware two ways:
 *
 *   THE KERNEL-MEDIATED PATH        write() / read() / poll()
 *     write(fd, piece, n)   n in 1..SSR_PROPOSAL_PIECE_BYTES: the kernel copies
 *                           the piece into the next proposal ring entry and
 *                           rings the doorbell. Blocks while the ring is full
 *                           (EAGAIN with O_NONBLOCK).
 *     read(fd, buf, cap)    the next decided round: a struct ssr_delivery
 *                           followed by the payload of every readable node,
 *                           copied out of the payload ring. Blocks until a
 *                           record arrives (EAGAIN with O_NONBLOCK; EMSGSIZE if
 *                           cap is too small - nothing is consumed then).
 *     poll()                POLLIN when read() would not block.
 *
 *   THE ZERO-COPY PATH              mmap() + SSR_IOC_GET_INFO
 *     The three rings and the register page are mapped into the process at the
 *     offsets GET_INFO reports. The application writes entries itself, rings
 *     the doorbell with one 32-bit store to the mapped PROP_PRODUCER register,
 *     polls the verdict ring's seq field and reads pages in place.
 *
 * Both paths share the driver's rings. The kernel path keeps its own cursor
 * into the verdict ring; a zero-copy application keeps its own. Nothing in the
 * hardware is "consumed", records simply age out of the ring after 2^depth
 * rounds, so the two may coexist, but a process should pick one.
 *
 * Every multi-byte field IN THE RINGS is big-endian (the wire and record
 * formats, rtl/ssr_packet.vh and rtl/ssr_verdict.vh). Every field in the
 * structs below is host order.
 */
#ifndef SSR_UAPI_H
#define SSR_UAPI_H

#include <linux/ioctl.h>
#include <linux/types.h>

#define SSR_DEV_NAME_FMT        "ssr%d"

/* The rings and registers in the mmap() address space of the device. */
#define SSR_MMAP_PROP_RING      0x00000000ULL   /* 2^prop_depth_log2 entries of 4 KiB */
#define SSR_MMAP_PAY_RING       0x10000000ULL   /* 2^pay_depth_log2 * N regions of 2^region_shift */
#define SSR_MMAP_VER_RING       0x20000000ULL   /* 2^ver_depth_log2 records of 64 B */
#define SSR_MMAP_REGS           0x30000000ULL   /* the SSR register page, 4 KiB, uncached */

struct ssr_info {
	__u32 node_id;
	__u32 node_count;
	__u32 round_ns;
	__u32 page_bytes;           /* 4096: an entry, a frame, a page */
	__u32 region_shift;         /* a node's pages for one round: 2^region_shift bytes */
	__u32 pay_depth_log2;       /* payload ring: 2^n rounds */
	__u32 ver_depth_log2;       /* verdict ring: 2^n records */
	__u32 prop_depth_log2;      /* proposal ring: 2^n entries */
	__u64 prop_ring_bytes;
	__u64 pay_ring_bytes;
	__u64 ver_ring_bytes;
	__u32 regs_bytes;           /* 4096 */
	__u32 reserved;
};

struct ssr_activate {
	__u32 run_id;               /* fresh, never reused within a cluster */
	__u32 membership;           /* bitmap of nodes */
	__u64 effective_round;      /* join at the first boundary >= this; 0 = now + rounds_ahead */
	__u32 rounds_ahead;         /* used when effective_round is 0 */
	__u32 reserved;
};

struct ssr_status {
	__u32 core_status;          /* SSR_CORE_STATUS_* */
	__u32 cur_run_id;
	__u32 sound_set;
	__u32 membership;
	__u64 cur_round;
	__u64 round_count;
	__u64 commit_count;
	__u32 halt_count;
	__u32 halt_reason;
	__u64 halt_round;
	__u32 halt_witness;
	__u32 halt_membership;
	__u32 halt_sound_set;       /* [7:0] produced, [15:8] before */
	__u32 fault;
	__u32 prop_status;
	__u32 prop_producer;
	__u32 prop_consumer;
	__u32 dlv_status;
	__u64 seq;                  /* the next verdict record's seq */
};

/* SSR_REG_ROUND_COUNT_LO (0x400) .. SSR_REG_VERDICT_STALE (0x534), one word each. */
#define SSR_COUNTERS_BASE       0x400
#define SSR_COUNTERS_WORDS      78
struct ssr_counters {
	__u32 w[SSR_COUNTERS_WORDS];
};
#define SSR_COUNTER(c, reg)     ((c)->w[((reg) - SSR_COUNTERS_BASE) / 4])

/*
 * What read() returns: this header, then payload. node_off[k] / node_len[k]
 * locate node k's committed bytes after the header (the pages' payloads
 * concatenated, each cut at the length its frame header carried). Our own
 * node has len 0: the host proposed those bytes itself.
 */
struct ssr_delivery {
	__u8  record[64];           /* the verdict record as written (big-endian fields) */
	__u64 round_id;
	__u64 seq;
	__u32 run_id;
	__u8  commit_set;
	__u8  present_set;
	__u8  node_count;
	__u8  self_index;
	__u16 frag_count[8];
	__u32 prop_consumer;
	__u32 node_off[8];
	__u32 node_len[8];
	__u32 total_len;            /* sum of node_len */
};

#define SSR_IOC_MAGIC           'S'
#define SSR_IOC_GET_INFO        _IOR(SSR_IOC_MAGIC, 0x01, struct ssr_info)
#define SSR_IOC_ACTIVATE        _IOW(SSR_IOC_MAGIC, 0x02, struct ssr_activate)
#define SSR_IOC_REBOOT          _IO(SSR_IOC_MAGIC, 0x03)     /* clears a halt; then ACTIVATE with a fresh run id */
#define SSR_IOC_DISABLE         _IO(SSR_IOC_MAGIC, 0x04)     /* CORE_CONTROL = 0 */
#define SSR_IOC_GET_STATUS      _IOR(SSR_IOC_MAGIC, 0x05, struct ssr_status)
#define SSR_IOC_GET_COUNTERS    _IOR(SSR_IOC_MAGIC, 0x06, struct ssr_counters)
#define SSR_IOC_PROP_FLUSH      _IO(SSR_IOC_MAGIC, 0x07)     /* drop every entry not yet on the wire */
#define SSR_IOC_PROP_CLEAR_ERR  _IO(SSR_IOC_MAGIC, 0x08)     /* after a failed read: re-read from the failed entry */
#define SSR_IOC_SET_DELIVERY    _IOW(SSR_IOC_MAGIC, 0x09, __u32)   /* SSR_DLV_CTRL_* bits */
#define SSR_IOC_RESET_CURSOR    _IO(SSR_IOC_MAGIC, 0x0a)     /* read() continues from the hardware's next seq */

#endif /* SSR_UAPI_H */
