// SSR verdict record - the single source of truth for what the host reads
// when a round is decided.
//
// WHAT A VERDICT RECORD IS
//   Under speculative delivery the host does not receive a round's payload
//   when the round is decided. It receives it as it ARRIVES: every fragment is
//   DMA'd into the host's payload ring the moment it lands (ssr_payload_dma_writer),
//   a round and a control period before anyone knows whether the round will
//   commit. What
//   arrives at decision time is this record - 64 bytes that say which of those
//   pages the host may now read.
//
//   The record is written by ssr_verdict_dma_writer into a ring of D records at
//   ring_base + (seq mod D) * 64, after every payload descriptor of the round
//   has completed (the fence). The host polls the next ring entry for a seq it
//   has not seen; a 64-byte record is one PCIe write, so it lands whole.
//
//   offset  size  field
//   ------  ----  ---------------------------------------------------------
//        0     8  round_id      the round this record decides. NOT the round
//                               in which it was written - ssr_core
//                               decides round R at round R+1's control
//                               deadline, once every row about R is in.
//        8     8  seq           record number, counting from 0 at reset and
//                               never repeating. The host's proof that the
//                               ring entry is new, and its index into the ring.
//       16     4  run_id        fences configurations, same value as the frames
//       20     1  commit_set    bitmap: the SOUND SET this decision left in
//                               force - who is still in the group. It does NOT
//                               gate reads; frag_count does. A node with
//                               frag_count[k] > 0 and commit_set[k] = 0 left
//                               in this round and those pages are its last.
//       21     1  present_set   bitmap: this host's copy of node k's pages is
//                               intact - no DMA error for (round, k). READ NODE
//                               k ONLY WHERE present_set[k].
//       22     1  node_count    the cluster size this record was built for
//       23     1  self_index    this node's index, so the host knows which
//                               region holds its own proposal
//       24    16  frag_count[0..7]  2 bytes each, big endian: the COMMITTED
//                               PREFIX of node k - pages 0..frag_count[k]-1 of
//                               k's region are decided. Zero means nothing of
//                               k's is in this round: it was idle, or gone -
//                               commit_set says which. (docs/count_ack.md)
//       40     4  proposal_consumer  the proposal ring's consumer index when
//                               this record was written (ssr_proposal_dma_reader):
//                               entries below it are in the FPGA and may be
//                               overwritten. The host's flow control for the
//                               proposal ring, delivered with the record it is
//                               polling anyway, so the fast path reads no MMIO.
//                               A free-running 32-bit count; compare modulo 2^32.
//   ---------------- reserved ----------------
//       44    20  zero.
//
// WHERE THE PAGES ARE
//   Node k's region for round R is at
//
//     payload_base + ((R mod D_HOST) * N + k) << REGION_SHIFT
//
//   and page f of it is at + (f << 12). Every page carries the frame header it
//   arrived with in its first 64 bytes and the payload from offset 64, so a
//   page says which node, round and fragment it is. How many of them count is
//   only in this record: pages past frag_count[k] may hold bytes that arrived
//   but were not agreed on. D_HOST, N and REGION_SHIFT are ssr_dataplane parameters exposed
//   through its CSRs.
//
// THREE FIELDS, THREE QUESTIONS
//   frag_count  what the protocol decided: the prefix of each node's
//               fragments a quorum agreed it holds. The agreement is over
//               count vectors, so every node that commits this round commits
//               exactly these counts.
//   present_set a fact about bytes on THIS host: a page DMA for (round, k)
//               failed. The protocol never sees it - the ack reports what
//               arrived on the wire - so commit & ~present is a local loss the
//               host must count, not a round it may skip.
//   commit_set  who is still in, so the host can tell "idle" from "gone" for a
//               zero count, and "last pages" for a non-zero one.
//
// The host reads node k's pages 0 .. frag_count[k]-1 where present_set[k].

// Multi-byte fields are network byte order (big-endian), matching ssr_packet.vh
// so a capture of a frame and a capture of a record are read the same way.
// Keep the Python mirror (tb/mqnic_core_pcie_us/ssr_verdict.py) in step.

// NO include guard, deliberately - see the note in ssr_packet.vh. These are
// localparams and each module needs its own copy inside its own scope.

localparam integer SSRV_OFF_ROUND_ID    = 0;
localparam integer SSRV_OFF_SEQ         = 8;
localparam integer SSRV_OFF_RUN_ID      = 16;
localparam integer SSRV_OFF_COMMIT_SET  = 20;
localparam integer SSRV_OFF_PRESENT_SET = 21;
localparam integer SSRV_OFF_NODE_COUNT  = 22;
localparam integer SSRV_OFF_SELF_INDEX  = 23;
localparam integer SSRV_OFF_FRAG_COUNTS = 24;   // 2 bytes per node, node k at +2k
localparam integer SSRV_OFF_PROP_CONSUMER = 40;
localparam integer SSRV_OFF_RESERVED    = 44;
localparam integer SSRV_RESERVED_BYTES  = 20;

localparam integer SSRV_RECORD_BYTES    = 64;   // one beat, one PCIe write

// The count table is fixed at eight entries so the record stays one beat
// whatever the cluster size, and so a three-node capture and an eight-node
// capture are parsed the same way.
localparam integer SSRV_MAX_NODES       = 8;

// field widths in bits
localparam integer SSRV_W_ROUND_ID    = 64;
localparam integer SSRV_W_SEQ         = 64;
localparam integer SSRV_W_RUN_ID      = 32;
localparam integer SSRV_W_COMMIT_SET  = 8;
localparam integer SSRV_W_PRESENT_SET = 8;
localparam integer SSRV_W_NODE_COUNT  = 8;
localparam integer SSRV_W_SELF_INDEX  = 8;
localparam integer SSRV_W_FRAG_COUNT  = 16;
localparam integer SSRV_W_PROP_CONSUMER = 32;
