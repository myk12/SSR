`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_tx_engine - turns one consensus round into the frames it puts on the wire.
 *
 * ONE PULSE, A CUTOFF, AND A RATE CAP
 *   ssr_core says "your round begins" once per round, and this module plays the
 *   round out from that:
 *
 *     i_tx_start_pulse     one control frame        always, unconditionally
 *     + P_PAY_GAP_CYCLES   a skew gap (see below)
 *     then                 a fragment whenever the proposal buffer offers a
 *                          whole slot, while i_tx_pay_open,
 *     + P_PACE_GAP_CYCLES  paced between them
 *
 *   NOTHING IS PLANNED. A proposal the host posts halfway through the round
 *   goes out in that round, as soon as the pacing allows. What this node sent
 *   is reported afterwards, in the next round's control frame, as ack[self]
 *   (docs/count_ack.md). The one thing that ends a round's payload is
 *   i_tx_pay_open falling at the cutoff: a fragment started after it could land
 *   at a peer after that peer's boundary, where it would no longer count. A
 *   slot still in the buffer at the cutoff simply goes out next round.
 *
 *   The control frame is the existing header-only path: S_IDLE -> S_HDR ->
 *   S_IDLE with has_payload = 0.
 *
 *   The payload is started by our own control frame COMPLETING, not by a second
 *   pulse from the core. That is what makes the order structural rather than
 *   arranged: there is no instant at which a fragment could be admitted before
 *   the round's ack vector has left, and no second pulse that could be missed
 *   while the FSM was busy.
 *
 * THE PACING GAP IS WHAT REPLACED TDMA
 *   Every node now transmits over the whole round instead of in a slot of its
 *   own. Nothing stops (N-1) peers from aiming at one receiver at once except
 *   this: each node holds its own rate at or below R/(N-1), so the (N-1) of
 *   them together cannot exceed R and there is no incast to avoid.
 *
 *   The cap is one gap after each fragment. To occupy one frame-time out of
 *   every (N-1):
 *
 *     P_PACE_GAP_CYCLES = frame_time * (N-2) / clk_period
 *                       = 332.8 ns * 1 / 4 ns = 84   at N = 3, 100G, 250 MHz
 *
 *   At N = 2 it is zero, which is right: with one peer there is nothing to
 *   share the receiver with.
 *
 *   The switch still sees a transient - all (N-1) senders are PTP-aligned, so
 *   their frames start together and the egress queue grows to (N-2) frames
 *   before the pacing gaps let it drain. At N = 3 that is one frame, 4160 B.
 *   Bounded, and small, because the pacing is per FRAGMENT and not per round;
 *   an unpaced sender would queue a whole round's payload instead.
 *
 * THE GAP BEFORE THE PAYLOAD IS NOT PADDING
 *   Every node aims its control frame at the same absolute instant, but clocks
 *   differ by up to +/- g. Take A early by g and B late by g:
 *
 *     A control frame on the wire   [-g, -g+t_ctrl]
 *     B control frame on the wire   [+g, +g+t_ctrl]
 *
 *   If A began its payload the moment its own control frame was out, it would
 *   be transmitting a whole fragment before B had even started its control
 *   frame - and at a switch egress port those bytes can queue AHEAD of B's
 *   control frame, which then lands ~335 ns late at a third node and eats most
 *   of that node's Tc.
 *
 *   So the gap has to cover the whole skew spread, 2g + t_ctrl, not just g.
 *   At 100 ns of spread that is 32 cycles: 128 ns, a percent of a round. The
 *   alternative is sizing Tc to absorb a whole frame, which costs about 0.7 us
 *   of commit latency every round instead.
 *
 * WHAT MUST GO OUT EVERY ROUND
 *   The control frame, and only the control frame. It carries the ack vector, so
 *   a node that has nothing to propose is still visibly alive and keeps its
 *   place in everyone's sound set. With nothing to propose, no payload frame is
 *   sent at all.
 *
 * THE CONTROL FRAME LOOKS BACK ONLY
 *   It carries i_tx_ack - ssr_presence_tracker's counts for the round just
 *   ended: how many fragments we hold from each peer, and how many we sent.
 *   Nothing in it is about the round it opens. The last payload frame of the
 *   previous round left before that round's cutoff, so by the time this frame
 *   goes out the count it reports cannot change.
 *
 * FRAGMENTS
 *   A frame is one page: 64 bytes of header and 4032 of payload. One
 *   ssr_proposal_buffer slot is one page too, with the host's payload at offset
 *   64 and the first 64 bytes left for this module - the buffer streams rows
 *   1..63 of a slot and this module puts the header it composes in front.
 *   Fragments of a round are numbered 0, 1, 2 ... in the order they leave, at
 *   most P_FRAGS_PER_ROUND of them: that is how many pages each (round, node)
 *   region of the host's payload ring holds.
 *
 * A FRAGMENT IS ADMITTED ON ITS FIRST BEAT
 *   A fragment starts only when the buffer is already offering the slot's first
 *   beat, and that beat is taken into the holding register in the same cycle.
 *   From then on the slot is on the wire as far as the buffer is concerned, so
 *   a flush cannot pull it out from under a header that has already been
 *   composed for it.
 *
 * MULTI-BEAT
 *   beat 0      the 64-byte header (see ssr_packet.vh for why it is padded)
 *   beat 1..N   the payload, taken from ssr_proposal_buffer one beat at a time
 *
 *   Because the header is exactly one beat, frame beat k is buffer beat k-1 byte
 *   for byte and there is no barrel shifter anywhere on this path. That is the
 *   entire reason the header carries 34 bytes of padding; the alternative is a
 *   64-byte rotator plus a carry register here and the same again in ssr_rx_engine.
 *
 * THE PAYLOAD LENGTH BELONGS TO ssr_proposal_buffer, NOT TO THIS MODULE
 *   Both the length (i_buf_tx_len) and the end of the payload (i_buf_tx_last)
 *   come from the buffer. This module holds no slot-geometry parameter that has
 *   to be kept equal to the buffer's - P_MAX_PAYLOAD_BYTES is an upper bound for
 *   sizing counters, never a value the logic depends on.
 *
 *   That matters because the two used to be independent parameters that nothing
 *   forced to agree. Configure them differently and the failure was silent: this
 *   module would stop asking for rows at its own count, the buffer would never
 *   see the handshake on the beat it calls last, head_pop_fire would never fire,
 *   the slot would never be released, and the ring would wedge a few proposals
 *   later with no counter moving anywhere. Taking both facts from the buffer
 *   removes the class of bug rather than detecting it.
 *
 *   It also makes variable-length slots work without touching this file, which
 *   is the first item on ring_buffer.md's future-extensions list.
 *
 * WHY THE PAYLOAD BEAT IS REGISTERED RATHER THAN PASSED THROUGH
 *   AXI-Stream forbids deasserting TVALID before the handshake completes, and
 *   this module does not want to depend on how the buffer's valid behaves. The
 *   one-deep holding register below decouples the two: it accepts a beat
 *   whenever it is free, and holds it on the wire until the MAC takes it.
 *
 *   The register takes the frame's FIRST beat while the header beat is still on
 *   the wire (S_HDR), so the first payload beat follows the header with no gap.
 *   ssr_proposal_buffer streams one beat per cycle, so a fragment is 64 back-to-back
 *   beats - which is what the round's timing budget assumes.
 */

module ssr_tx_engine #(
    parameter integer P_NODE_ID       = 0,
    parameter integer P_NODE_COUNT    = 3,

    // Node identity is compile-time, matching ssr_core's P_NODE_ID and
    // its read-only NODE register (ssr_csr): one bitstream per node.
    parameter [47:0]  P_SRC_MAC       = 48'h02_00_00_00_00_00,
    // Broadcast by default. One frame reaches every peer, which is what makes a
    // round exactly one frame; set it to a multicast group if the segment is
    // shared with anything else.
    parameter [47:0]  P_DST_MAC       = 48'hFF_FF_FF_FF_FF_FF,

    // Upper bound on a fragment's PAYLOAD, for counter widths and for spotting
    // a buffer that offers more than a frame holds. NOT the length of a frame -
    // that is i_buf_tx_len, decided per slot by ssr_proposal_buffer. Must equal
    // SSR_FRAG_BYTES (4032: a page less the header), checked below. Defaulted
    // to match so the module elaborates standalone.
    parameter integer P_MAX_PAYLOAD_BYTES = 4032,

    // Most fragments this node sends in one round: the pages each (round, node)
    // region of the host's payload ring holds. ssr_rx_engine refuses a
    // frag_idx at or past it, so every node in the cluster is built with one
    // value.
    parameter integer P_FRAGS_PER_ROUND = 16,

    // Cycles to wait after our own control frame before starting the payload.
    // Must cover 2g + t_ctrl - the full clock-skew spread plus one control
    // frame - or our payload can queue ahead of a late peer's control frame at
    // a switch egress. See the banner. 32 cycles = 128 ns at 250 MHz.
    parameter integer P_PAY_GAP_CYCLES = 32,

    // The rate cap: cycles of silence after each payload fragment, so this
    // node's average transmit rate stays at or below R/(N-1). See the banner.
    // 84 = 332.8 ns of frame time * (3-2) peers / 4 ns per cycle.
    parameter integer P_PACE_GAP_CYCLES = 84,

    parameter integer AXIS_DATA_WIDTH = 512,
    parameter integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8,
    // TX_TAG_WIDTH + 1 in Corundum: bit 0 is "bad frame", the rest is the
    // transmit tag. The old module declared this 1 bit wide and silently
    // truncated it.
    parameter integer AXIS_USER_WIDTH = 17,

    // Rides in tuser[AXIS_USER_WIDTH-1:1] and comes back on the transmit
    // completion. ssr_tx_mux matches it to tell this node's own frames from
    // the host's and keep their completions out of the interface's descriptor
    // accounting. Top bit clear: Corundum sets it on every host frame - see
    // ssr_tx_mux.v, WHICH TAG IS OURS.
    parameter [15:0]  P_TX_CPL_TAG    = 16'h4000,

    parameter integer DMA_LEN_WIDTH   = 16,
    parameter integer RAM_SEG_COUNT   = 2,
    parameter integer RAM_SEG_DATA_WIDTH = 512
) (
    input  wire                             clk,
    input  wire                             rst,

    // ---- from ssr_core -------------------------------------------
    // The pulse fires at TX_START_OFFSET_NS: our control frame goes out then.
    // i_tx_pay_open is high from the round boundary to the transmit cutoff;
    // a fragment may START only while it is high (see the banner).
    input  wire                             i_tx_start_pulse,
    input  wire [63:0]                      i_tx_round_id,
    input  wire [31:0]                      i_tx_run_id,
    input  wire                             i_tx_pay_open,

    // ---- from ssr_presence_tracker ------------------------------------------
    // Our ack vector about the previous round, node k at [8k +: 8]. Latched
    // with the start pulse.
    input  wire [63:0]                      i_tx_ack,

    // ---- from ssr_proposal_buffer ------------------------------------------
    input  wire [RAM_SEG_DATA_WIDTH-1:0]                i_buf_rd_data,   // one beat = one RAM segment
    input  wire                                         i_buf_rd_valid,
    output wire                                         o_buf_rd_ready,
    input  wire                                         i_buf_tx_last,
    input  wire [DMA_LEN_WIDTH-1:0]                     i_buf_tx_len,

    // ---- to the port MAC (direct tap) -----------------------------------
    output wire [AXIS_DATA_WIDTH-1:0]       m_axis_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0]       m_axis_tkeep,
    output wire                             m_axis_tvalid,
    input  wire                             m_axis_tready,
    output wire                             m_axis_tlast,
    output wire [AXIS_USER_WIDTH-1:0]       m_axis_tuser,

    // ---- our own fragments, to ssr_presence_tracker -------------------------
    // One pulse per fragment, the cycle it is admitted: it is how ack[self]
    // gets counted. Our bytes are already in our own host memory, so nothing
    // on the receive side wants the fragment itself.
    output reg                              o_local_sent,
    output reg [63:0]                       o_local_sent_round,

    // ---- statistics ------------------------------------------------------
    // Split by kind: one number covering both would have to be read twice to
    // mean anything, and the two kinds fail for completely different reasons.
    output wire [31:0]                      o_ctrl_frame_count,
    output wire [31:0]                      o_pay_frame_count,
    // Only the round's one start pulse can be missed now; a fragment that runs
    // out of window is the admission margin doing its job, not a fault.
    output wire [31:0]                      o_missed_count,
    // Rounds that ended with no fragment sent - nothing to propose.
    output wire [31:0]                      o_empty_count,
    output wire [31:0]                      o_overrun_count,
    // i_buf_tx_len and i_buf_tx_last disagreed: the buffer said N bytes and then
    // ended the slot somewhere other than beat ceil(N/64)-1. Both come from the
    // buffer, so this is a check on it rather than on a parameter mismatch.
    output wire [31:0]                      o_len_mismatch_count,
    // The buffer offered a slot larger than this link is configured to carry.
    // The frame still goes out whole - refusing it would leave the slot
    // unconsumed and wedge the ring - but the frame may exceed the MTU.
    output wire [31:0]                      o_oversize_count
);

`include "ssr_packet.vh"

localparam integer BUF_BEAT_BITS = RAM_SEG_DATA_WIDTH;   // ssr_proposal_buffer hands out one segment a beat
localparam integer BEAT_BYTES    = AXIS_KEEP_WIDTH;

initial begin
    if (SSR_HDR_BYTES != BEAT_BYTES) begin
        $error("the header must be exactly one beat: header %0d bytes, beat %0d",
               SSR_HDR_BYTES, BEAT_BYTES);
        $finish;
    end
    if (BUF_BEAT_BITS != AXIS_DATA_WIDTH) begin
        $error("ssr_proposal_buffer beat (one RAM segment, %0d bits) must match the stream (%0d)",
               BUF_BEAT_BITS, AXIS_DATA_WIDTH);
        $finish;
    end
    if (P_NODE_COUNT > 8) begin
        $error("the ack field is eight bytes, one per node; P_NODE_COUNT (%0d) must be <= 8", P_NODE_COUNT);
        $finish;
    end
    // One proposal slot is one fragment. If these drift apart the fragment
    // offsets this module stamps into the header stop describing where the
    // bytes actually are, and the receiver scatters them to the wrong places in
    // host memory - silently, because every frame is still well formed.
    if (P_MAX_PAYLOAD_BYTES != SSR_FRAG_BYTES) begin
        $error("a fragment is a page less its header: P_MAX_PAYLOAD_BYTES %0d, SSR_FRAG_BYTES %0d",
               P_MAX_PAYLOAD_BYTES, SSR_FRAG_BYTES);
        $finish;
    end
    if (P_PACE_GAP_CYCLES < 0) begin
        $error("P_PACE_GAP_CYCLES must not be negative (%0d)", P_PACE_GAP_CYCLES);
        $finish;
    end
    if (P_PAY_GAP_CYCLES < 1) begin
        $error("P_PAY_GAP_CYCLES must be at least 1; see the banner for how to size it");
        $finish;
    end
    if (P_FRAGS_PER_ROUND < 1 || P_FRAGS_PER_ROUND > SSR_MAX_FRAGS) begin
        $error("P_FRAGS_PER_ROUND (%0d) must be between 1 and %0d",
               P_FRAGS_PER_ROUND, SSR_MAX_FRAGS);
        $finish;
    end
end

localparam integer FRAG_CNT_W = $clog2(SSR_MAX_FRAGS + 1);

// Header fields go on the wire most-significant byte first, while AXI-Stream
// puts byte 0 in tdata[7:0]. These put the MSB at the lowest byte offset.
function [15:0] be16(input [15:0] v); be16 = {v[7:0], v[15:8]}; endfunction
function [31:0] be32(input [31:0] v);
    be32 = {v[7:0], v[15:8], v[23:16], v[31:24]};
endfunction
function [47:0] be48(input [47:0] v);
    be48 = {v[7:0], v[15:8], v[23:16], v[31:24], v[39:32], v[47:40]};
endfunction
function [63:0] be64(input [63:0] v);
    be64 = {v[7:0], v[15:8], v[23:16], v[31:24],
            v[39:32], v[47:40], v[55:48], v[63:56]};
endfunction

// ---------------------------------------------------------------- state
localparam [1:0] S_IDLE    = 2'd0,
                 S_HDR     = 2'd1,
                 S_PAYLOAD = 2'd2;

reg [1:0]  state_reg = S_IDLE;

reg [63:0] round_id_reg = 64'd0;
reg [31:0] run_id_reg   = 32'd0;
reg [63:0] ack_reg      = 64'd0;
reg [15:0] length_reg   = 16'd0;      // 0 for a header-only frame
reg        has_payload_reg = 1'b0;

// Which kind of frame is on the wire right now.
reg        is_ctrl_reg  = 1'b0;

// This round's fragments so far, and whether the round has started its payload.
reg [FRAG_CNT_W-1:0]  frag_idx_reg  = {FRAG_CNT_W{1'b0}};
reg                   pay_run_reg   = 1'b0;   // our control frame is out: payload may follow
reg                   had_round_reg = 1'b0;   // a round has begun since reset (for o_empty_count)
reg [15:0]            gap_cnt_reg   = 16'd0;  // counts down the skew gap and the pacing gap

wire [15:0] frag_idx_16 = {{(16-FRAG_CNT_W){1'b0}}, frag_idx_reg};

// Derived from the length this buffer offered, latched with it so the frame's
// geometry cannot change under it once the header has gone out.
reg [15:0]                payload_beats_reg = 16'd0;
reg [AXIS_KEEP_WIDTH-1:0] last_keep_reg = {AXIS_KEEP_WIDTH{1'b1}};

reg [31:0] ctrl_frame_count_reg   = 32'd0;
reg [31:0] pay_frame_count_reg     = 32'd0;
reg [31:0] missed_count_reg        = 32'd0;
reg [31:0] empty_count_reg         = 32'd0;
reg [31:0] overrun_count_reg       = 32'd0;
reg [31:0] len_mismatch_count_reg = 32'd0;
reg [31:0] oversize_count_reg     = 32'd0;

// one-deep holding register for a payload beat
reg                       beat_valid_reg = 1'b0;
reg [AXIS_DATA_WIDTH-1:0] beat_data_reg  = {AXIS_DATA_WIDTH{1'b0}};
reg                       beat_last_reg  = 1'b0;
reg [15:0]                beat_index_reg = 16'd0;

// The control frame is unconditional. The only thing that can stop it is this
// module still being busy with the previous round - which, with the cutoff
// sized against the round length at elaboration, means something upstream has
// stalled and is worth counting.
wire ctrl_accepted = i_tx_start_pulse && (state_reg == S_IDLE);
wire ctrl_dropped  = i_tx_start_pulse && (state_reg != S_IDLE);

// A fragment starts when everything lines up: our control frame is out and
// the round has not reached its cutoff (pay_run_reg, cleared at the cutoff -
// the i_tx_pay_open term only covers the cycle before it follows), the gap has
// run down, the round's budget is not spent, and the buffer is offering a
// slot's first beat right now.
wire pay_budget   = (frag_idx_reg < P_FRAGS_PER_ROUND[FRAG_CNT_W-1:0]);
wire gap_done     = (gap_cnt_reg == 16'd0);
wire pay_accepted = pay_run_reg && gap_done && i_tx_pay_open && pay_budget
                 && (state_reg == S_IDLE) && !i_tx_start_pulse && i_buf_rd_valid;

// The holding register may take a beat whenever it is free, or is being emptied
// this very cycle. Combinational on m_axis_tready on purpose: registering it
// would put the handshake a cycle behind the beat it was meant to accept.
//
// ...EXCEPT ON THE FRAME'S LAST BEAT, WHICH IS NOT A FREE SLOT
//   "being emptied this very cycle" is true on the last beat's own handshake
//   too, and there is no next beat in this frame to put there. Without the
//   !beat_last_reg term this asks the buffer for a beat anyway, and if the buffer
//   is fast enough to still be offering one, that beat is POPPED - it belongs to
//   the next slot and it is gone. The damage does not stop there: the register
//   is left loaded going into S_IDLE, and the next fragment admitted emits that
//   stale beat, from the wrong slot, ahead of its own.
//
//   None of this can be seen today only because ssr_proposal_buffer restarts its
//   RAM pipeline after a slot's last beat, so i_buf_rd_valid happens to be low
//   on exactly that cycle. That is a property of the buffer's current latency,
//   not a contract, and it is the wrong thing to depend on.
//
// A fragment's first beat is taken on the cycle it is admitted (see the
// banner); the register is always empty in S_IDLE.
wire payload_space = pay_accepted
                  || ((state_reg == S_PAYLOAD)
                      && (!beat_valid_reg || (m_axis_tready && !beat_last_reg)));
assign o_buf_rd_ready = payload_space;

// ------------------------------------------------- geometry of the next frame
// A function of what the buffer is offering right now; sampled once, at
// admission, and never re-read.
wire [15:0] offered_len   = i_buf_rd_valid ? i_buf_tx_len[15:0] : 16'd0;
wire        offered_valid = i_buf_rd_valid && (offered_len != 16'd0);

wire [15:0] offered_beats = (offered_len + BEAT_BYTES[15:0] - 16'd1) / BEAT_BYTES[15:0];
wire [15:0] offered_tail  = offered_len - ((offered_beats - 16'd1) * BEAT_BYTES[15:0]);

// (1 << tail) - 1, computed one bit wide so a full 64-byte tail lands on all
// ones rather than on zero.
wire [AXIS_KEEP_WIDTH:0] offered_keep_wide =
        ({{AXIS_KEEP_WIDTH{1'b0}}, 1'b1} << offered_tail) - {{AXIS_KEEP_WIDTH{1'b0}}, 1'b1};
wire [AXIS_KEEP_WIDTH-1:0] offered_keep = offered_keep_wide[AXIS_KEEP_WIDTH-1:0];

// ---------------------------------------------------------------- header beat
reg [AXIS_DATA_WIDTH-1:0] header_bits;
always @* begin
    header_bits = {AXIS_DATA_WIDTH{1'b0}};      // the reserved bytes are zero
    header_bits[SSR_OFF_DST_MAC  *8 +: 48] = be48(P_DST_MAC);
    header_bits[SSR_OFF_SRC_MAC  *8 +: 48] = be48(P_SRC_MAC);
    header_bits[SSR_OFF_ETHERTYPE*8 +: 16] = be16(SSR_ETHERTYPE);
    header_bits[SSR_OFF_NODE_ID  *8 +:  8] = P_NODE_ID[7:0];
    header_bits[SSR_OFF_RUN_ID   *8 +: 32] = be32(run_id_reg);
    header_bits[SSR_OFF_ROUND_ID *8 +: 64] = be64(round_id_reg);
    header_bits[SSR_OFF_LENGTH   *8 +: 16] = be16(length_reg);
    header_bits[SSR_OFF_KIND     *8 +:  8] = is_ctrl_reg ? SSR_KIND_CTRL : SSR_KIND_PAYLOAD;
    header_bits[SSR_OFF_FLAGS    *8 +:  8] = 8'd0;
    header_bits[SSR_OFF_FRAG_IDX *8 +: 16] = be16(is_ctrl_reg ? 16'd0 : frag_idx_16);
    // The ack is evidence about the previous round and rides only in the
    // control frame. Eight single bytes, node k at SSR_OFF_ACK + k.
    header_bits[SSR_OFF_ACK      *8 +: 64] = is_ctrl_reg ? ack_reg : 64'd0;
end

wire header_is_last = !has_payload_reg;

assign m_axis_tdata  = (state_reg == S_HDR) ? header_bits : beat_data_reg;
// The header beat and every full payload beat are complete; only the final beat
// of a payload that is not a whole number of beats is short.
assign m_axis_tkeep  = (state_reg == S_PAYLOAD && beat_last_reg)
                     ? last_keep_reg : {AXIS_KEEP_WIDTH{1'b1}};
assign m_axis_tvalid = (state_reg == S_HDR) ? 1'b1
                     : (state_reg == S_PAYLOAD) ? beat_valid_reg : 1'b0;
assign m_axis_tlast  = (state_reg == S_HDR) ? header_is_last : beat_last_reg;
// bit 0 = 0: the frame is good. The rest is the transmit tag.
assign m_axis_tuser  = {P_TX_CPL_TAG[AXIS_USER_WIDTH-2:0], 1'b0};

assign o_ctrl_frame_count   = ctrl_frame_count_reg;
assign o_pay_frame_count    = pay_frame_count_reg;
assign o_missed_count       = missed_count_reg;
assign o_empty_count        = empty_count_reg;
assign o_overrun_count      = overrun_count_reg;
assign o_len_mismatch_count = len_mismatch_count_reg;
assign o_oversize_count     = oversize_count_reg;

// ------------------------------------------------------------- sequential
always @(posedge clk) begin
    o_local_sent <= 1'b0;

    // The next round began while a frame was still on the wire. Never acted
    // upon - truncating it would put a malformed frame on the segment - only
    // counted, as evidence that a round's paced fragments do not fit in a round
    // after all, or that the proposal path stalled.
    if (i_tx_start_pulse && (state_reg != S_IDLE))
        overrun_count_reg <= overrun_count_reg + 32'd1;

    // A new round: the last one's payload is over. Nothing is lost - a slot
    // not sent stays in the buffer for this round.
    if (i_tx_start_pulse) pay_run_reg <= 1'b0;

    // ...and the cutoff ends it first. This one is not a backstop: pay_open
    // rises again at the next BOUNDARY, a whole dead zone before the next start
    // pulse, and a payload still marked running would admit a fragment there -
    // stamped with the round that has just ended, which every receiver drops.
    if (!i_tx_pay_open) pay_run_reg <= 1'b0;

    // The skew gap runs down whatever the FSM is doing, so the control frame's
    // own transmission time counts towards it.
    if (gap_cnt_reg != 16'd0) gap_cnt_reg <= gap_cnt_reg - 16'd1;

    if (ctrl_dropped) missed_count_reg <= missed_count_reg + 32'd1;

    case (state_reg)
        S_IDLE: begin
            // Control first. With one pulse this is no longer a priority
            // question at all: pay_run_reg is only ever set by our own control
            // frame leaving, so on the cycle the round starts there is nothing
            // to prioritise against.
            if (ctrl_accepted) begin
                round_id_reg <= i_tx_round_id;
                run_id_reg   <= i_tx_run_id;
                ack_reg      <= i_tx_ack;

                is_ctrl_reg     <= 1'b1;
                has_payload_reg <= 1'b0;      // the control frame is header-only
                length_reg      <= 16'd0;

                // The round before this one is over: did it send anything?
                if (had_round_reg && frag_idx_reg == {FRAG_CNT_W{1'b0}})
                    empty_count_reg <= empty_count_reg + 32'd1;
                had_round_reg <= 1'b1;

                frag_idx_reg    <= {FRAG_CNT_W{1'b0}};
                gap_cnt_reg     <= P_PAY_GAP_CYCLES[15:0];

                beat_index_reg <= 16'd0;
                state_reg      <= S_HDR;
            end else if (pay_accepted) begin
                is_ctrl_reg <= 1'b0;

                // round_id and run_id stay as the control frame latched them:
                // every frame of a round carries the same pair, and re-reading
                // ssr_core here would let a boundary crossing mid-period
                // split one round's fragments across two round ids.
                has_payload_reg   <= offered_valid;
                length_reg        <= offered_len;
                payload_beats_reg <= offered_beats;
                last_keep_reg     <= offered_keep;

                if (offered_len > P_MAX_PAYLOAD_BYTES[15:0])
                    oversize_count_reg <= oversize_count_reg + 32'd1;

                // Counted for ack[self] now, at admission: from here the
                // fragment goes out whatever the MAC does, and it carries
                // this index.
                o_local_sent       <= 1'b1;
                o_local_sent_round <= round_id_reg;

                beat_index_reg <= 16'd0;
                state_reg      <= S_HDR;
            end
        end

        S_HDR: begin
            if (m_axis_tready) begin
                if (has_payload_reg) begin
                    state_reg <= S_PAYLOAD;
                end else begin
                    if (is_ctrl_reg) begin
                        ctrl_frame_count_reg <= ctrl_frame_count_reg + 32'd1;
                        // Our ack vector is on the wire. THIS is what opens the
                        // payload: no second pulse, so no second pulse to lose.
                        pay_run_reg <= 1'b1;
                    end else begin
                        pay_frame_count_reg <= pay_frame_count_reg + 32'd1;
                    end
                    state_reg <= S_IDLE;
                end
            end
        end

        S_PAYLOAD: begin
            if (beat_valid_reg && m_axis_tready) begin
                beat_valid_reg <= 1'b0;

                if (beat_last_reg) begin
                    // The buffer told us the length and then told us where the
                    // slot ends. If those two disagree the frame is still well
                    // formed, so nothing downstream would notice - count it.
                    if (beat_index_reg != payload_beats_reg - 16'd1)
                        len_mismatch_count_reg <= len_mismatch_count_reg + 32'd1;
                    pay_frame_count_reg <= pay_frame_count_reg + 32'd1;

                    // One fragment done. pay_accepted picks the next one up out
                    // of S_IDLE once the pacing gap has run down, while the
                    // buffer has one and the round is open.
                    //
                    // THIS RELOAD IS THE RATE CAP. Without it the fragments go
                    // back to back at whatever the transmit path can manage and
                    // (N-1) senders can swamp one receiver. It is the same
                    // counter the skew gap uses, reloaded with a different
                    // value, because the two never overlap: the skew gap runs
                    // once after the control frame, the pacing gap after every
                    // fragment.
                    gap_cnt_reg  <= P_PACE_GAP_CYCLES[15:0];
                    frag_idx_reg <= frag_idx_reg + {{(FRAG_CNT_W-1){1'b0}}, 1'b1};

                    state_reg <= S_IDLE;
                end else begin
                    beat_index_reg <= beat_index_reg + 16'd1;
                end
            end

        end

        default: state_reg <= S_IDLE;
    endcase

    // Accept the next beat into the holding register (in S_HDR: the frame's
    // first beat). Written after the pop above so that a pop and a load in the
    // same cycle leave the register loaded, which is what keeps the stream
    // gapless.
    if (payload_space && i_buf_rd_valid) begin
        beat_data_reg  <= i_buf_rd_data;
        beat_last_reg  <= i_buf_tx_last;
        beat_valid_reg <= 1'b1;
    end

    if (rst) begin
        state_reg              <= S_IDLE;
        round_id_reg           <= 64'd0;
        run_id_reg             <= 32'd0;
        ack_reg                <= 64'd0;
        length_reg             <= 16'd0;
        has_payload_reg        <= 1'b0;
        is_ctrl_reg            <= 1'b0;
        frag_idx_reg           <= {FRAG_CNT_W{1'b0}};
        pay_run_reg            <= 1'b0;
        had_round_reg          <= 1'b0;
        gap_cnt_reg            <= 16'd0;
        o_local_sent           <= 1'b0;
        o_local_sent_round     <= 64'd0;
        payload_beats_reg      <= 16'd0;
        last_keep_reg          <= {AXIS_KEEP_WIDTH{1'b1}};
        beat_valid_reg         <= 1'b0;
        beat_data_reg          <= {AXIS_DATA_WIDTH{1'b0}};
        beat_last_reg          <= 1'b0;
        beat_index_reg         <= 16'd0;
        ctrl_frame_count_reg   <= 32'd0;
        pay_frame_count_reg    <= 32'd0;
        missed_count_reg       <= 32'd0;
        empty_count_reg        <= 32'd0;
        overrun_count_reg      <= 32'd0;
        len_mismatch_count_reg <= 32'd0;
        oversize_count_reg     <= 32'd0;
    end
end

endmodule

`resetall
