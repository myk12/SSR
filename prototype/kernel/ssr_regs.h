/* SPDX-License-Identifier: BSD-2-Clause-Views */
#ifndef SSR_REGS_H
#define SSR_REGS_H

#define SSR_APP_ID 0x53535201
#define SSR_RB_TYPE 0x53535201
#define SSR_RB_VERSION 0x00000200

#define SSR_AUXILIARY_NAME "mqnic.app_53535201"

/*
 * The register map: rtl/ssr_csr.v, one 4 KiB page at the bottom of the
 * application BAR. Its header is the reference; this file and
 * tb/mqnic_core_pcie_us/ssr_dataplane.py are copies of it.
 */

/* identity and build geometry (all read-only but SCRATCH) */
#define SSR_REG_TYPE            0x000
#define SSR_REG_VERSION         0x004
#define SSR_REG_NEXTPTR         0x008
#define SSR_REG_SCRATCH         0x00c
#define SSR_REG_NODE            0x010   /* [7:0] node id, [15:8] node count */
#define SSR_REG_ROUND_NS        0x014
#define SSR_REG_GEOMETRY        0x018   /* see SSR_GEOM_* */
#define SSR_REG_PAGE_BYTES      0x01c
#define SSR_REG_FAULT           0x020   /* sticky since reset, see SSR_FAULT_* */

#define SSR_NODE_ID(n)          ((n) & 0xff)
#define SSR_NODE_COUNT(n)       (((n) >> 8) & 0xff)

/* Events a correct design never produces; a set bit is a bug to find. */
#define SSR_FAULT_RX_FOREIGN          (1u << 0)
#define SSR_FAULT_TX_LEN_MISMATCH     (1u << 1)
#define SSR_FAULT_TX_OVERSIZE         (1u << 2)
#define SSR_FAULT_STAGE_OVERSIZE      (1u << 3)
#define SSR_FAULT_STAGE_OVERLAP       (1u << 4)
#define SSR_FAULT_STAGE_LEN_MISMATCH  (1u << 5)
#define SSR_FAULT_PAY_STRAY           (1u << 6)

/* consensus (rtl/ssr_core.v) */
#define SSR_REG_CORE_CONTROL    0x100
#define SSR_REG_CORE_STATUS     0x104
#define SSR_REG_CFG_RUN_ID      0x108   /* the next configuration: ignored while an */
#define SSR_REG_CFG_MEMBERSHIP  0x10c   /* activation is pending                    */
#define SSR_REG_CFG_EFF_ROUND_LO 0x110
#define SSR_REG_CFG_EFF_ROUND_HI 0x114
#define SSR_REG_CUR_ROUND_LO    0x118
#define SSR_REG_CUR_ROUND_HI    0x11c
#define SSR_REG_CUR_RUN_ID      0x120
#define SSR_REG_CUR_SOUND_SET   0x124
#define SSR_REG_CUR_MEMBERSHIP  0x128
#define SSR_REG_HALT_REASON     0x140
#define SSR_REG_HALT_ROUND_LO   0x144
#define SSR_REG_HALT_ROUND_HI   0x148
#define SSR_REG_HALT_WITNESS    0x14c   /* who agreed with us in that evaluation */
#define SSR_REG_HALT_MEMBERSHIP 0x150
#define SSR_REG_HALT_SOUND_SET  0x154   /* [7:0] produced, [15:8] held before */

#define SSR_CORE_CTRL_ENABLE    (1u << 0)   /* a level */
#define SSR_CORE_CTRL_ACTIVATE  (1u << 1)   /* one-shot */
#define SSR_CORE_CTRL_REBOOT    (1u << 2)   /* one-shot */

#define SSR_CORE_STATUS_HALTED          (1u << 0)
#define SSR_CORE_STATUS_TIMING_ARMED    (1u << 1)
#define SSR_CORE_STATUS_TIME_VALID      (1u << 2)
#define SSR_CORE_STATUS_ACT_PENDING     (1u << 3)
#define SSR_CORE_STATUS_EXCLUDES_SELF   (1u << 4)

/*
 * Proposal ring (rtl/ssr_proposal_dma_reader.v). The host owns a ring of
 * 2^RING_DEPTH_LOG2 entries of SSR_PROPOSAL_ENTRY_BYTES each, programmed once
 * (base, depth, PROP_CONTROL.enable). To propose: write entries at the producer
 * index, then write the new producer index to PROP_PRODUCER - one posted MMIO
 * write, the doorbell. Indices are free-running u32 counts of entries; entry i
 * lives at base + ((i mod depth) << 12).
 *
 * Flow control: an entry below PROP_CONSUMER is whole on the NIC and may be
 * overwritten; post only while producer - consumer < depth. PROP_CONSUMER is also
 * in every verdict record (SSR_VERDICT_OFF_PROP_CONSUMER), so the fast path
 * needs no MMIO read.
 *
 * AN ENTRY HAS THE SAME SHAPE AS A FRAME (rtl/ssr_packet.vh): bytes 0..63 are
 * left empty - ssr_tx_engine writes the frame header there - and the payload
 * piece, at most SSR_PROPOSAL_PIECE_BYTES, starts at SSR_PROPOSAL_PAYLOAD_OFF.
 * Cut the application's byte stream at 4032, not 4096; one entry becomes one
 * fragment, one wire frame, one page at the peers.
 *
 * A failed read sets PROP_STATUS.error and PROP_CONSUMER stops on the failed entry;
 * PROP_CONTROL.clear_error re-reads it and everything after it (nothing to
 * re-post). PROP_CONTROL.flush drops every entry not yet on the wire (CONSUMER
 * jumps to PRODUCER). Both are carried out once no read is in flight: wait
 * for PROP_STATUS.pending to clear before posting again.
 */
#define SSR_PROPOSAL_ENTRY_BYTES        4096    /* one slot, one frame, one page */
#define SSR_PROPOSAL_PAYLOAD_OFF        64      /* the header row belongs to the FPGA */
#define SSR_PROPOSAL_PIECE_BYTES        (SSR_PROPOSAL_ENTRY_BYTES - SSR_PROPOSAL_PAYLOAD_OFF)   /* 4032 */

#define SSR_REG_PROP_CONTROL    0x200
#define SSR_REG_PROP_STATUS     0x204
#define SSR_REG_PROP_ERROR_CODE 0x208   /* the failed read's status */
#define SSR_REG_PROP_DEPTH_LOG2 0x20c   /* <= 16 */
#define SSR_REG_PROP_BASE_LO    0x210
#define SSR_REG_PROP_BASE_HI    0x214
#define SSR_REG_PROP_PRODUCER   0x218   /* the doorbell */
#define SSR_REG_PROP_CONSUMER   0x21c
#define SSR_REG_PROP_FETCH      0x220   /* reads issued (debug) */
#define SSR_REG_PROP_INFLIGHT   0x224

#define SSR_PROP_CTRL_ENABLE            (1u << 0)   /* a level */
#define SSR_PROP_CTRL_FLUSH             (1u << 1)   /* one-shot */
#define SSR_PROP_CTRL_CLEAR_ERROR       (1u << 2)   /* one-shot */

#define SSR_PROP_STATUS_ENABLED         (1u << 0)
#define SSR_PROP_STATUS_IDLE            (1u << 1)   /* no read in flight */
#define SSR_PROP_STATUS_ERROR           (1u << 2)
#define SSR_PROP_STATUS_PENDING         (1u << 3)   /* flush / clear_error not yet done */

/*
 * Delivery: speculative delivery to the host (docs/commit_path.md §9).
 * Two rings in host memory, programmed by base address. A fragment is DMA'd
 * to its page as it arrives; a 64-byte verdict record follows when the round
 * is decided, after every page of that round has landed.
 */
#define SSR_REG_DLV_CONTROL     0x300
#define SSR_REG_DLV_STATUS      0x304   /* [7:0] fence units idle, [15:8] tag high water */
#define SSR_REG_PAY_BASE_LO     0x308
#define SSR_REG_PAY_BASE_HI     0x30c
#define SSR_REG_VER_BASE_LO     0x310
#define SSR_REG_VER_BASE_HI     0x314
#define SSR_REG_SEQ_LO          0x318   /* the next verdict record's seq */
#define SSR_REG_SEQ_HI          0x31c

#define SSR_DLV_CTRL_PAYLOAD    (1u << 0)
#define SSR_DLV_CTRL_VERDICT    (1u << 1)

/* counters: read-only, free-running, never cleared on read */
#define SSR_REG_ROUND_COUNT_LO      0x400
#define SSR_REG_ROUND_COUNT_HI      0x404
#define SSR_REG_COMMIT_COUNT_LO     0x408
#define SSR_REG_COMMIT_COUNT_HI     0x40c
#define SSR_REG_HALT_COUNT          0x410
#define SSR_REG_TIME_FAULT_COUNT    0x414

#define SSR_REG_TX_CTRL_FRAMES      0x440
#define SSR_REG_TX_PAY_FRAMES       0x444
#define SSR_REG_TX_EMPTY            0x448
#define SSR_REG_TX_OVERRUN          0x44c
#define SSR_REG_TX_MISSED           0x450
#define SSR_REG_TX_HOST_FRAMES      0x454
#define SSR_REG_TX_CPL_COUNT        0x458
#define SSR_REG_TX_CPL_TS_0         0x45c   /* the last SSR frame's completion timestamp, */
#define SSR_REG_TX_CPL_TS_1         0x460   /* zero-extended to 96 bits, low word first   */
#define SSR_REG_TX_CPL_TS_2         0x464

#define SSR_REG_RX_FRAMES           0x480
#define SSR_REG_RX_ACCEPT           0x484
#define SSR_REG_RX_CTRL             0x488
#define SSR_REG_RX_MALFORMED        0x48c
#define SSR_REG_RX_CTRL_LATE        0x490
#define SSR_REG_RX_WINDOW_DROP      0x494
#define SSR_REG_RX_MEMBER_DROP      0x498
#define SSR_REG_RX_SOUND_DROP       0x49c
#define SSR_REG_RX_RUN_DROP         0x4a0
#define SSR_REG_RX_ROUND_DROP       0x4a4
#define SSR_REG_RX_STALL            0x4a8
#define SSR_REG_RX_HOST_FRAMES      0x4ac
#define SSR_REG_RX_ACK_DISAGREE     0x4b0   /* a peer's ack differed from ours: not a witness */

#define SSR_REG_PROP_READS          0x4c0
#define SSR_REG_PROP_READ_ERRORS    0x4c4

#define SSR_REG_STAGE_PUSH          0x500
#define SSR_REG_STAGE_FULL          0x504
#define SSR_REG_PAY_DESC            0x508
#define SSR_REG_PAY_CPL             0x50c
#define SSR_REG_PAY_ERR             0x510
#define SSR_REG_PAY_STARVE          0x514
#define SSR_REG_PRES_LATE           0x51c   /* a fragment counted after its round closed */
#define SSR_REG_PRES_ERR            0x520
#define SSR_REG_PRES_ERR_MISS       0x524
#define SSR_REG_VERDICT_RECORDS     0x528
#define SSR_REG_VERDICT_ERR         0x52c
#define SSR_REG_VERDICT_OVERFLOW    0x530
#define SSR_REG_VERDICT_STALE       0x534

#define SSR_GEOM_NODE_COUNT(g)     ((g) & 0xff)
#define SSR_GEOM_REGION_SHIFT(g)   (((g) >> 8) & 0xff)
#define SSR_GEOM_PAY_DEPTH_LOG2(g) (((g) >> 16) & 0xff)
#define SSR_GEOM_VER_DEPTH_LOG2(g) (((g) >> 24) & 0xff)

/*
 * Where the pages are (rtl/ssr_verdict.vh):
 *   region(R, k) = payload_base + (((R mod 2^pay_depth_log2) * N + k) << region_shift)
 *   page(R, k, f) = region(R, k) + (f << 12)
 * Every page carries the frame header it arrived with in its first 64 bytes.
 */
#define SSR_PAGE_SHIFT              12
#define SSR_PAGE_PAYLOAD_OFFSET     64

/* The verdict record, 64 bytes, all multi-byte fields big-endian. */
#define SSR_VERDICT_RECORD_BYTES    64
#define SSR_VERDICT_OFF_ROUND_ID    0     /* u64 */
#define SSR_VERDICT_OFF_SEQ         8     /* u64: ring index and freshness proof */
#define SSR_VERDICT_OFF_RUN_ID      16    /* u32 */
#define SSR_VERDICT_OFF_COMMIT_SET  20    /* u8 bitmap: the sound set left in force - who is still in */
#define SSR_VERDICT_OFF_PRESENT_SET 21    /* u8 bitmap: this host's copy of node k is intact */
#define SSR_VERDICT_OFF_NODE_COUNT  22    /* u8 */
#define SSR_VERDICT_OFF_SELF_INDEX  23    /* u8 */
#define SSR_VERDICT_OFF_FRAG_COUNTS 24    /* u16[8]: the committed prefix - read pages 0..n-1 of node k
                                           where present_set[k] */
#define SSR_VERDICT_OFF_PROP_CONSUMER 40  /* u32: the proposal ring's CONSUMER when written */
#define SSR_VERDICT_MAX_NODES       8

#endif /* SSR_REGS_H */
