// SSR wire format - the single source of truth.
//
// ssr_tx_engine, ssr_rx_engine, the cocotb harness and the host driver all describe the
// same bytes. They have disagreed three ways before (a 64-bit run_id in the old
// consensus_tx, a 32-bit one in the harness, different field orders in both), so
// the offsets live here and nowhere else. The Python mirror is
// tb/mqnic_core_pcie_us/ssr_packet.py; keep the two in step.
//
//   offset  size  field
//   ------  ----  ---------------------------------------------------------
//        0     6  destination MAC
//        6     6  source MAC
//       12     2  ethertype - 0x88B5, IEEE 802 local experimental. The frame is
//                 identified by this alone; there is no magic or version field.
//   ---------------- consensus header ----------------
//       14     1  node_id      sender's replica id
//       15     1  reserved, 0  (was the 1-bit-per-node row)
//       16     4  run_id       fences configurations; a mismatch is dropped
//       20     8  round_id     the round this frame belongs to
//       28     2  length       THIS frame's payload bytes: 0 on a control frame,
//                              1..4032 on a fragment
//       30     1  kind         1 = CTRL, 2 = PAYLOAD
//       31     1  flags        reserved, no bits defined
//       32     2  frag_idx     which fragment of the round this is (0 on CTRL)
//       34     2  reserved, 0  (was frag_count, the announcement)
//       36     8  ack[0..7]    CONTROL FRAME ONLY, zero on a fragment. One byte
//                              per node, about the PREVIOUS round:
//                                ack[k], k != sender: how many of k's fragments
//                                  the sender holds, as a contiguous prefix
//                                ack[sender]: how many fragments it sent
//                              See docs/count_ack.md.
//   ---------------- reserved ----------------
//       44    20  zero. Padding that pushes the payload to a beat boundary.
//   ---------------- payload ----------------
//       64     N  proposal payload
//
// Multi-byte fields are network byte order (big-endian), matching the harness.
// ack is eight single bytes, ack[k] at 36+k, so on the 512-bit bus the whole
// vector is tdata[SSR_OFF_ACK*8 +: 64] with node k at [8k +: 8] - no swapping.
//
// NOTHING ON THE WIRE SAYS HOW MANY FRAGMENTS A ROUND HAS
//   A node sends whatever its proposal buffer holds, whenever it holds it, until
//   the round's cutoff; the count is only known afterwards, and it travels in
//   the next round's control frame as ack[sender]. A receiver counts fragments
//   as a prefix (frag_idx == what it already holds) and puts that count in its
//   own ack. Whether the two agree is the witness test - ssr_rx_engine's last
//   rung - so a fragment needs no field describing the round as a whole.

// WHY THE HEADER IS PADDED TO 64 BYTES
//   The header used to end at byte 30 and the payload started there, which was
//   right while a frame was a single beat: at a 32-byte payload the whole frame
//   was 62 bytes, fitted one 512-bit beat, and the datapath needed no barrel
//   shifter at all. Padding to 32 would only have shrunk the single-beat payload
//   budget from 34 bytes to 32, so it bought nothing.
//
//   Multi-beat changes the arithmetic completely. ssr_proposal_buffer hands out
//   64-byte rows on a 512-bit datapath, so a payload starting at byte 30 puts
//   every buffer row 30 bytes out of phase with every frame beat, and each beat
//   has to be assembled from two rows - a 64-byte barrel shifter plus a carry
//   register on the transmit side, and the same again in reverse on receive.
//   Padding the header to exactly one beat makes beat 0 the header and beat k
//   the buffer's row k-1, byte for byte, with no shifting anywhere.
//
//   It costs 34 bytes per frame. At the 1 KiB payload this path is built for
//   that is 3%, against two barrel shifters and the timing closure they would
//   need. At the old 32-byte payload it would have been 50%, which is why the
//   layout only makes sense once the frame spans beats.
//
// NO include guard, deliberately.
//
// These are localparams, so each module needs its own copy inside its own scope
// - the include belongs after the module header, not at file top. A guard would
// make every include after the first a silent no-op, and the second module would
// fail to elaborate with "unable to bind SSR_OFF_...". Including this file twice
// in one module is a duplicate-declaration error, which is what you want.

localparam [15:0] SSR_ETHERTYPE = 16'h88B5;

// byte offsets
localparam integer SSR_OFF_DST_MAC   = 0;
localparam integer SSR_OFF_SRC_MAC   = 6;
localparam integer SSR_OFF_ETHERTYPE = 12;
localparam integer SSR_OFF_NODE_ID   = 14;
localparam integer SSR_OFF_RUN_ID    = 16;
localparam integer SSR_OFF_ROUND_ID  = 20;
localparam integer SSR_OFF_LENGTH     = 28;   // THIS frame's payload bytes, <= SSR_FRAG_BYTES
localparam integer SSR_OFF_KIND       = 30;   // control frame or payload frame
localparam integer SSR_OFF_FLAGS      = 31;   // reserved, no bits defined
localparam integer SSR_OFF_FRAG_IDX   = 32;   // which fragment of the round this is
localparam integer SSR_OFF_ACK        = 36;   // control frame: 8 x u8, node k at +k
localparam integer SSR_ACK_BYTES      = 8;
localparam integer SSR_OFF_RESERVED   = 44;
localparam integer SSR_OFF_PAYLOAD    = 64;

// ---------------------------------------------------------------- frame kind
// A frame has to say what it is from its own contents, not from when it
// arrived: a payload frame sent at the end of a round is still in flight T_prop
// into the next one.
localparam [7:0] SSR_KIND_CTRL    = 8'd1;
localparam [7:0] SSR_KIND_PAYLOAD = 8'd2;

// ---------------------------------------------------------------- frame = page
// A FRAME IS EXACTLY ONE PAGE: 64 bytes of header and 4032 of payload.
//
//   That one equality does most of the work in the receive path. A frame lands
//   in host memory as one page with its own header at the top, so every page
//   is self-describing on its own; there is no separate header page, no second
//   descriptor for fragment 0, and a staging slot is a frame with no waste.
//   The MTU is 4096, not 4160.
//
//   A node's payload for one round is a run of proposal entries, one per
//   fragment, and the frames say WHICH one by index, not by byte offset:
//
//     frag_idx     0..4       "this is fragment k"
//     length       <= 4032    "...carrying this many bytes"
//
//   Index rather than offset because 4032 is not a power of two: an offset
//   would need a divide to check and a divide to turn into a page address,
//   while an index is a compare and a shift. The byte offset, if anyone wants
//   it, is frag_idx * SSR_FRAG_BYTES on the host.
//
//   A PROPOSAL NEVER SPANS TWO ENTRIES. An entry (one fragment) holds one or
//   more whole proposals, so a proposal is at most 4032 bytes. The cluster may
//   commit a PREFIX of a node's fragments for a round (docs/count_ack.md 3.1),
//   and this is what keeps a committed prefix from ending in half a proposal.
//   The fabric does not check it - it does not know where a proposal starts or
//   ends - so it is the application's rule.
//
// A PROPOSAL ENTRY HAS THE SAME SHAPE AS A FRAME
//   The host's proposal queue is an array of SSR_FRAME_BYTES entries, and an
//   entry is laid out exactly like the frame it becomes: bytes 0..63 are left
//   EMPTY by the host (ssr_tx_engine writes the header there), the payload piece
//   starts at SSR_OFF_PAYLOAD and is at most SSR_FRAG_BYTES long. So an entry
//   carries at most 4032 bytes of proposals, not 4096, at offset 64; ssr_proposal_dma_reader copies whole entries and
//   ssr_proposal_buffer streams rows 1..63 of each. The 64 bytes are padding on
//   purpose: it makes the proposal entry, the wire frame and the delivered
//   host page one layout, so the host reads its own proposal (its region of
//   the payload ring is never written) with the same parser and the same
//   offset as a peer's page. The alternative - dense 4032-byte entries and a
//   DMA read to slot + 64 - saves 1.6% of host memory and costs that symmetry.
//
// WHY 4096
//   Two costs pull against each other: 88 bytes of wire overhead per frame
//   (header + FCS + preamble + IFG) favours big frames, and the time the last
//   frame of a round spends on the wire favours small ones. The optimum sits
//   near sqrt(88 * (N-1) * bytes_per_round) - 3.4 KB at N = 3 and 64 KiB - and
//   4096 is the page beside it.
//
// A receiver holds a PREFIX of each node's fragments: one lost fragment stops
// the count there, and the cluster commits the prefix a quorum agrees on
// (docs/count_ack.md section 3).
localparam integer SSR_FRAME_BYTES = 4096;                              // one page
localparam integer SSR_FRAG_BYTES  = SSR_FRAME_BYTES - SSR_OFF_PAYLOAD;  // 4032 of payload
localparam integer SSR_MAX_FRAGS   = 64;                                // 252 KiB per node per round

localparam integer SSR_ETH_HDR_BYTES = 14;
localparam integer SSR_CON_HDR_BYTES = 16;
localparam integer SSR_HDR_USED_BYTES = SSR_OFF_RESERVED;   // 44 bytes carry fields
localparam integer SSR_HDR_BYTES      = SSR_OFF_PAYLOAD;    // 64 bytes on the wire

// The header occupies exactly one beat of a 512-bit datapath. Everything about
// the multi-beat layout follows from this equality; assert it where used.
localparam integer SSR_HDR_BEAT_BYTES = 64;

// field widths in bits
localparam integer SSR_W_NODE_ID  = 8;
localparam integer SSR_W_ACK      = SSR_ACK_BYTES*8;
localparam integer SSR_W_RUN_ID   = 32;
localparam integer SSR_W_ROUND_ID = 64;
localparam integer SSR_W_LENGTH   = 16;
localparam integer SSR_W_KIND      = 8;
localparam integer SSR_W_FLAGS     = 8;
localparam integer SSR_W_FRAG_IDX  = 16;

// Ethernet pads to 60 bytes before FCS; below that the MAC must pad anyway.
// The header beat is 64, so no SSR frame is ever short enough to need it.
localparam integer SSR_MIN_FRAME_BYTES = 60;
