`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_rx_engine - turns SSR frames on the wire into two things: a "this peer is
 * trusted for this round" pulse for the core, and a tagged payload stream for
 * ssr_payload_stage.
 *
 * Why it is shaped this way, and what it replaced: docs/rx_datapath.md.
 * What the round looks like around it: docs/round_structure.md.
 * Where the payload goes after this: docs/commit_path.md.
 *
 *   AXIS ─►[ S_HDR ]── kind == CTRL ───► ack == ours? ─► "trusted" to the core
 *              │  │                      (a control frame has no payload,
 *              │  │                       so the parser is free immediately)
 *              │  │
 *              │  ├── kind == PAYLOAD ─► payload tag, then
 *              │  │                      [ S_PAYLOAD ]──beats──► ssr_payload_stage
 *              │  │                                 │
 *              │  └── rejected ──► one counter per reason
 *              ▼                             ▼
 *          [ S_DROP ]  eat to tlast
 *
 *
 * TWO KINDS OF FRAME, AND THE WHOLE MODULE FOLLOWS FROM THAT
 *
 *   A CONTROL frame is the round's protocol message: one per node per round,
 *   carrying that node's ACK VECTOR about the previous round - how many of
 *   each node's fragments it holds, and how many it sent (docs/count_ack.md).
 *   It has no payload at all (length == 0, tlast on the header beat).
 *
 *   A PAYLOAD frame is bulk data: one fragment of one node's round, carrying
 *   frag_idx to say which. A frame is exactly one page - 64 bytes of header
 *   and up to 4032 of payload - so it lands in host memory as one page with its
 *   own header on top. There are up to P_FRAGS_PER_ROUND of them per node per
 *   round and they say nothing about the protocol.
 *
 *   ONLY A CONTROL FRAME REACHES THE CORE, AND ONLY AS ONE BIT. A control
 *   frame that clears every rung says "node k is trusted for this round": its
 *   run and round are ours, it is still in our sound set, and its ack vector
 *   is IDENTICAL to ours (i_rx_self_ack, from ssr_presence_tracker). That last
 *   rung is the witness test - two nodes whose vectors agree hold exactly the
 *   same fragments of everyone - so the core only has to count the pulses
 *   against a quorum. A node whose control frame is lost, or disagrees, is
 *   simply not a witness this round.
 *
 * ONE WINDOW AND ONE ENABLE, BECAUSE ONLY ONE KIND HAS A DEADLINE
 *
 *   A control frame has a hard deadline: ssr_core evaluates at the end of
 *   the control period, so a control frame arriving after CTRL_PERIOD_NS has
 *   missed the only moment it could have mattered. A payload frame has no
 *   deadline at all - the senders are rate-capped rather than time-sliced, so a
 *   fragment may legitimately arrive at any point in the round and the round_id
 *   in its header is what places it.
 *
 *   Hence one window and one enable, selected by the frame's own kind. This is
 *   the only asymmetry; everything else in the ladder is applied to both kinds
 *   identically.
 *
 *   THE WINDOW GATES THE HEADER BEAT AND NOTHING ELSE. An accepted frame
 *   streams to its tlast even if the window shuts underneath it. Re-checking
 *   per beat would truncate a frame that was admissible when it started, which
 *   is never what anyone wants.
 *
 *
 * CONTRACTS
 *
 *   The filter is here and ONLY here; ssr_core applies none of it. Its
 *   run / round / sound_set / window registers and our own ack vector are read
 *   COMBINATIONALLY: they move only at a round boundary, so a pipeline register
 *   on that path would let a frame from the round just ended be judged against
 *   the new round's state - which is the one thing the round boundary exists to
 *   prevent. (Our ack vector moves on the cycle after a boundary, and the first
 *   peer control frame arrives hundreds of nanoseconds later.)
 *
 *   o_pl_sof is a ONE-CYCLE pulse landing on the SAME cycle as the frame's
 *   first payload beat, with o_pl_hdr_data and the rest of the tag beside it.
 *   ssr_payload_stage must latch the tag and accept a beat in the same cycle.
 *   There is no header-only payload frame: a node with nothing to propose
 *   sends no payload frame at all, so sof always has a beat under it.
 *
 *   Exactly one of o_pl_commit / o_pl_drop ends every frame that raised sof.
 *   Nothing else terminates a payload. THEY NEVER COINCIDE WITH A BEAT: both
 *   are raised on the beat that ends the frame and land the cycle after, by
 *   which time this engine is back in S_HDR (or S_DROP) and o_pl_valid is
 *   structurally low. ssr_payload_stage relies on that - it writes the staged
 *   header on commit, into the one cycle it knows the bus is quiet.
 *
 *   Payload beats are forwarded BEFORE the frame is known to end where its
 *   length promised, so a drop abandons bytes ssr_payload_stage has already
 *   written. ssr_payload_stage rewinds its own write pointer on o_pl_drop.
 *
 *   Every rejection path still eats the frame to its tlast. Stopping mid-frame
 *   resynchronises the parser on a payload beat and corrupts every frame after.
 *
 *   Each beat is tagged with node_id, round_id and frag_idx taken from the
 *   FRAME, so placement is addressing and never arrival order. That is what
 *   lets ssr_payload_dma_writer compute a host address at the first beat: the
 *   fragment's page is (round, node, frag_idx), three slices and a shift.
 *
 *   o_pl_len is authoritative for how many bytes are meaningful. tkeep is not
 *   forwarded - the stage clamps by length.
 */

module ssr_rx_engine #(
    parameter integer P_NODE_ID       = 0,
    parameter integer P_NODE_COUNT    = 3,

    // Upper bound on ONE FRAGMENT's payload. The real length of each frame
    // comes from the header's length field; this exists so a corrupt length
    // cannot make the engine promise the stage more beats than a slot can hold.
    // It must equal SSR_FRAG_BYTES (4032) - checked below - because the
    // transmit side, the stage and the host page layout are all sized from
    // that one constant: header + payload = one page.
    parameter integer P_MAX_PAYLOAD_BYTES = 4032,

    // The most fragments any node sends in a round: the same P_FRAGS_PER_ROUND
    // every node in the cluster is built with, and what the host region for
    // one (round, node) is sized to hold. A frag_idx at or past it would be
    // written into the NEXT node's region, so it is refused here, before it is
    // addressed.
    parameter integer P_FRAGS_PER_ROUND = 5,

    parameter [15:0]  P_ETHERTYPE     = 16'h88B5,

    parameter integer AXIS_DATA_WIDTH = 512,
    parameter integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8,
    // The receive tuser carries the PTP timestamp plus a bad-frame bit in bit 0;
    // only bit 0 is read here.
    parameter integer AXIS_USER_WIDTH = 97,

    parameter integer RAM_SEG_COUNT      = 2,
    parameter integer RAM_SEG_DATA_WIDTH = 512
) (
    input  wire                             clk,
    input  wire                             rst,

    // ---- from the port ---------------------------------------------------
    input  wire [AXIS_DATA_WIDTH-1:0]       s_axis_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0]       s_axis_tkeep,
    input  wire                             s_axis_tvalid,
    output wire                             s_axis_tready,
    input  wire                             s_axis_tlast,
    input  wire [AXIS_USER_WIDTH-1:0]       s_axis_tuser,

    // ---- ssr_core's state, read combinationally --------------------
    // One window and one enable. The control frame has a hard deadline at
    // CTRL_PERIOD_NS; a payload frame has none, so i_rx_pay_enable is simply
    // "the protocol is running" and the round_id in the header is what says
    // which round the fragment belongs to. Both already carry protocol_active -
    // see ssr_core.v, which ANDs each with it.
    input  wire                             i_rx_ctrl_window,
    input  wire                             i_rx_pay_enable,
    input  wire [31:0]                      i_rx_run_id,
    input  wire [63:0]                      i_rx_round_id,
    input  wire [7:0]                       i_rx_sound_set,

    // ---- ssr_presence_tracker's o_prev_ack, read combinationally ------------
    // Our ack vector about the previous round. A peer's control frame for this
    // round carries its vector about the same round, and must equal this one.
    input  wire [63:0]                      i_rx_self_ack,

    // ---- trusted peer -> ssr_core -----------------------------------------
    // A one-cycle pulse for a CONTROL frame that cleared every rung: node k is
    // a witness for the round the core is about to decide.
    output reg                              o_rx_valid,
    output reg  [7:0]                       o_rx_node_id,

    // ---- payload -> ssr_payload_stage ----------------------------------------
    // o_pl_sof marks the start of a fragment's payload and carries everything
    // needed to place it: which node, which round, which fragment, how many
    // bytes.
    //
    // TIMING: sof lands on the same cycle as the frame's FIRST payload beat,
    // not before it.
    output reg                              o_pl_sof,
    output reg  [7:0]                       o_pl_node_id,
    output reg  [63:0]                      o_pl_round_id,
    output reg  [15:0]                      o_pl_len,        // THIS fragment's payload bytes
    output reg  [15:0]                      o_pl_frag_idx,   // which page of the node's region
    // The header beat itself, exactly as it was on the wire, valid with
    // o_pl_sof. ssr_payload_stage stages it as beat 0 of the slot so fragment 0 can
    // carry it to the top of the node's host region unchanged - the host's
    // self-describing record is the frame header, not something composed here.
    output reg  [AXIS_DATA_WIDTH-1:0]       o_pl_hdr_data,

    output wire                             o_pl_valid,
    output wire [AXIS_DATA_WIDTH-1:0]       o_pl_data,
    output wire                             o_pl_last,
    input  wire                             i_pl_ready,

    // Exactly one of these pulses at the end of every frame that raised
    // o_pl_sof. Nothing else terminates a payload.
    output reg                              o_pl_commit,
    output reg                              o_pl_drop,

    // ---- counters --------------------------------------------------------
    // One counter per reason. A frame that fails is charged to exactly one of
    // them, so a non-zero value names the fault instead of merely reporting
    // that there was one.
    output wire [31:0]                      o_frame_count,        // beats parsed as headers
    output wire [31:0]                      o_accept_count,       // passed the whole filter
    output wire [31:0]                      o_ctrl_count,         // of which control frames
    output wire [31:0]                      o_foreign_count,      // not an SSR ethertype
    output wire [31:0]                      o_malformed_count,    // geometry disagrees with the header
    output wire [31:0]                      o_window_drop_count,  // payload while the protocol is not running
    output wire [31:0]                      o_ctrl_late_count,    // control frame past its deadline
    output wire [31:0]                      o_member_drop_count,  // node id out of range, or claims to be us
    output wire [31:0]                      o_sound_drop_count,   // sender already dropped from the sound set
    output wire [31:0]                      o_run_drop_count,     // a different run
    output wire [31:0]                      o_round_drop_count,   // a different round: late or early
    output wire [31:0]                      o_ack_disagree_count, // control frame whose ack is not ours
    output wire [31:0]                      o_stall_count         // the stage held a beat off
);

`include "ssr_packet.vh"

localparam integer BEAT_BYTES = AXIS_DATA_WIDTH/8;


// ---------------------------------------------------------------- checks
initial begin
    if (AXIS_DATA_WIDTH != SSR_HDR_BEAT_BYTES*8) begin
        $error("ssr_rx_engine: the header is one %0d-byte beat, the datapath is %0d bytes (instance %m)",
               SSR_HDR_BEAT_BYTES, BEAT_BYTES);
        $finish;
    end
    // beat == one staging RAM segment is what lets the payload be forwarded
    // with no shifting at all, the same identity the transmit side relies on.
    if (BEAT_BYTES != RAM_SEG_DATA_WIDTH/8) begin
        $error("ssr_rx_engine: a frame beat (%0d B) must equal a staging RAM segment (%0d B) (instance %m)",
               BEAT_BYTES, RAM_SEG_DATA_WIDTH/8);
        $finish;
    end
    if (P_FRAGS_PER_ROUND < 1 || P_FRAGS_PER_ROUND > SSR_MAX_FRAGS) begin
        $error("ssr_rx_engine: P_FRAGS_PER_ROUND (%0d) must be between 1 and SSR_MAX_FRAGS (%0d) (instance %m)",
               P_FRAGS_PER_ROUND, SSR_MAX_FRAGS);
        $finish;
    end
    if (P_MAX_PAYLOAD_BYTES != SSR_FRAG_BYTES) begin
        $error("ssr_rx_engine: P_MAX_PAYLOAD_BYTES (%0d) must equal SSR_FRAG_BYTES (%0d) - header + payload is one page, and the transmit side, ssr_payload_stage and the host layout are all sized from it (instance %m)",
               P_MAX_PAYLOAD_BYTES, SSR_FRAG_BYTES);
        $finish;
    end
    if (P_NODE_COUNT > 8) begin
        $error("ssr_rx_engine: the ack field holds 8 nodes, P_NODE_COUNT = %0d (instance %m)", P_NODE_COUNT);
        $finish;
    end
end

// ---------------------------------------------------------------- byte order
// The mirror of ssr_tx_engine's be16/be32/be64: network byte order on the wire,
// native order inside.
function [15:0] rd16(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    rd16 = {d[off*8 +: 8], d[(off+1)*8 +: 8]};
endfunction
function [31:0] rd32(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    rd32 = {d[off*8 +: 8], d[(off+1)*8 +: 8], d[(off+2)*8 +: 8], d[(off+3)*8 +: 8]};
endfunction
function [63:0] rd64(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    rd64 = {d[off*8 +: 8], d[(off+1)*8 +: 8], d[(off+2)*8 +: 8], d[(off+3)*8 +: 8],
            d[(off+4)*8 +: 8], d[(off+5)*8 +: 8], d[(off+6)*8 +: 8], d[(off+7)*8 +: 8]};
endfunction

// ---------------------------------------------------------------- header view
// Combinational decode of whatever beat is on the bus. Only sampled in S_HDR,
// where that beat is a header by construction.
wire [15:0] hdr_ethertype = rd16(s_axis_tdata, SSR_OFF_ETHERTYPE);
wire [7:0]  hdr_node_id   = s_axis_tdata[SSR_OFF_NODE_ID*8 +: 8];
wire [31:0] hdr_run_id    = rd32(s_axis_tdata, SSR_OFF_RUN_ID);
wire [63:0] hdr_round_id  = rd64(s_axis_tdata, SSR_OFF_ROUND_ID);
wire [15:0] hdr_length     = rd16(s_axis_tdata, SSR_OFF_LENGTH);
wire [7:0]  hdr_kind       = s_axis_tdata[SSR_OFF_KIND*8 +: 8];
wire [15:0] hdr_frag_idx   = rd16(s_axis_tdata, SSR_OFF_FRAG_IDX);
wire [63:0] hdr_ack        = s_axis_tdata[SSR_OFF_ACK*8 +: 64];   // node k at [8k +: 8]

wire hdr_is_ssr   = (hdr_ethertype == P_ETHERTYPE);
wire hdr_is_ctrl  = (hdr_kind == SSR_KIND_CTRL);
wire hdr_is_pay   = (hdr_kind == SSR_KIND_PAYLOAD);
wire hdr_kind_ok  = hdr_is_ctrl || hdr_is_pay;

wire hdr_full     = (s_axis_tkeep == {AXIS_KEEP_WIDTH{1'b1}});
wire hdr_bad_user = s_axis_tuser[0];        // the MAC flagged the frame

// ceil(length / BEAT_BYTES). The mirror of ssr_tx_engine's offered_beats.
//
// There is deliberately no keep mask here. ssr_payload_stage places bytes by the
// length in the tag, so a per-beat mask had no consumer - computing one cost a
// 65-bit variable shifter and 64 flops to carry the result nowhere.
wire [15:0] hdr_beats = (hdr_length + BEAT_BYTES[15:0] - 16'd1) / BEAT_BYTES[15:0];

// ---------------------------------------------------------------- geometry
// A header is well formed if the frame arrived whole, was not flagged bad by
// the MAC, names a kind, and its fragment fields tell one consistent story.
//
// The kind and the length are tied together: a control frame is exactly one
// beat and carries nothing, a payload frame carries at least one byte. So
// "length == 0" and "this is a control frame" are the same statement, and
// tlast on the header beat is the third way of saying it. All three must agree.
wire hdr_len_ok   = hdr_is_ctrl ? (hdr_length == 16'd0)
                                : (hdr_length != 16'd0) && (hdr_length <= P_MAX_PAYLOAD_BYTES[15:0]);
wire hdr_end_ok   = (s_axis_tlast == hdr_is_ctrl);

// Which fragment. A control frame is not one, so it says 0; a payload frame
// has to name a page inside its (round, node) region, which is exactly
// P_FRAGS_PER_ROUND pages. Nothing here needs a divide, because the fragment
// is an index and not a byte offset - see ssr_packet.vh.
wire hdr_frag_ok  = hdr_is_ctrl ? (hdr_frag_idx == 16'd0)
                                : (hdr_frag_idx < P_FRAGS_PER_ROUND[15:0]);

wire hdr_geom_ok = hdr_full && !hdr_bad_user && hdr_kind_ok
                && hdr_len_ok && hdr_end_ok && hdr_frag_ok;

// ---------------------------------------------------------------- the filter
// Node.receive, applied here against ssr_core's own registers.
//
// hdr_node_ok is checked before hdr_sound_ok is meaningful, but the index is
// masked to three bits and the sound set is eight, so the lookup is in range
// whatever the frame claims.
wire hdr_node_ok  = (hdr_node_id < P_NODE_COUNT[7:0]) && (hdr_node_id != P_NODE_ID[7:0]);
wire hdr_sound_ok = i_rx_sound_set[hdr_node_id[2:0]];
wire hdr_run_ok   = (hdr_run_id   == i_rx_run_id);
wire hdr_round_ok = (hdr_round_id == i_rx_round_id);

// The witness test, for control frames only: the sender holds exactly the
// fragments we hold, of every node, and sent exactly as many as we got.
wire hdr_ack_ok   = (hdr_ack == i_rx_self_ack);

// The one asymmetry between the two kinds. Reached only once hdr_geom_ok has
// confirmed the kind is one of the two, so the select is never on a wild value.
wire hdr_window_ok = hdr_is_ctrl ? i_rx_ctrl_window : i_rx_pay_enable;

// ---------------------------------------------------------------- state
localparam [1:0] S_HDR     = 2'd0,
                 S_PAYLOAD = 2'd1,
                 S_DROP    = 2'd2;

reg [1:0]  state_reg = S_HDR;

reg [15:0] payload_beats_reg = 16'd0;
reg [15:0] beat_index_reg    = 16'd0;

reg [31:0] frame_count_reg     = 32'd0;
reg [31:0] accept_count_reg    = 32'd0;
reg [31:0] ctrl_count_reg      = 32'd0;
reg [31:0] foreign_count_reg   = 32'd0;
reg [31:0] malformed_count_reg = 32'd0;
reg [31:0] window_drop_reg     = 32'd0;
reg [31:0] ctrl_late_reg       = 32'd0;
reg [31:0] member_drop_reg     = 32'd0;
reg [31:0] sound_drop_reg      = 32'd0;
reg [31:0] run_drop_reg        = 32'd0;
reg [31:0] round_drop_reg      = 32'd0;
reg [31:0] ack_disagree_reg    = 32'd0;
reg [31:0] stall_count_reg     = 32'd0;

// Nothing here ever closes the input except the stage holding a payload beat
// off. The header is judged on its own beat, so an accepted frame streams with
// no bubble.
assign s_axis_tready = (state_reg == S_PAYLOAD) ? i_pl_ready : 1'b1;

wire beat_fire  = s_axis_tvalid && s_axis_tready;
wire is_last_pl = (beat_index_reg == payload_beats_reg - 16'd1);

// The payload is forwarded byte for byte: beat k of the frame is beat k of the
// staging slot. That identity is the whole reason the header was padded to a
// full beat - see ssr_packet.vh.
assign o_pl_valid = (state_reg == S_PAYLOAD) && s_axis_tvalid;
assign o_pl_data  = s_axis_tdata;
assign o_pl_last  = (state_reg == S_PAYLOAD) && is_last_pl;

assign o_frame_count       = frame_count_reg;
assign o_accept_count      = accept_count_reg;
assign o_ctrl_count        = ctrl_count_reg;
assign o_foreign_count     = foreign_count_reg;
assign o_malformed_count   = malformed_count_reg;
assign o_window_drop_count = window_drop_reg;
assign o_ctrl_late_count   = ctrl_late_reg;
assign o_member_drop_count = member_drop_reg;
assign o_sound_drop_count  = sound_drop_reg;
assign o_run_drop_count    = run_drop_reg;
assign o_round_drop_count  = round_drop_reg;
assign o_ack_disagree_count = ack_disagree_reg;
assign o_stall_count       = stall_count_reg;

always @(posedge clk) begin
    o_rx_valid  <= 1'b0;
    o_pl_sof    <= 1'b0;
    o_pl_commit <= 1'b0;
    o_pl_drop   <= 1'b0;

    if (state_reg == S_PAYLOAD && s_axis_tvalid && !i_pl_ready)
        stall_count_reg <= stall_count_reg + 32'd1;

    case (state_reg)

    // ------------------------------------------------------------- header
    // The rejection ladder is ordered so each counter means one thing: can we
    // parse it at all, is it well formed, should we be listening, is the sender
    // someone we believe, is the frame fresh, and - control frames only - does
    // the sender agree with us. A frame is charged to the first test it fails
    // and to no other.
    S_HDR: begin
        if (beat_fire) begin
            frame_count_reg <= frame_count_reg + 32'd1;

            if (!hdr_is_ssr) begin
                // Not ours. ssr_rx_demux takes only 0x88B5, so a non-zero
                // counter here means the demux is not doing what it claims.
                foreign_count_reg <= foreign_count_reg + 32'd1;
                if (!s_axis_tlast) state_reg <= S_DROP;
            end else if (!hdr_geom_ok) begin
                malformed_count_reg <= malformed_count_reg + 32'd1;
                if (!s_axis_tlast) state_reg <= S_DROP;
            end else if (!hdr_window_ok) begin
                // A control frame past its deadline, or any frame while this
                // node is not running. Charging a frame to the wrong round is
                // worse than losing it.
                //
                // The two counters are separate because the two faults want
                // different fixes: a late control frame means CTRL_PERIOD_NS is
                // too short for the actual link, whereas a payload frame here
                // only ever means we are halted or not yet activated.
                if (hdr_is_ctrl) ctrl_late_reg   <= ctrl_late_reg   + 32'd1;
                else             window_drop_reg <= window_drop_reg + 32'd1;
                if (!s_axis_tlast) state_reg <= S_DROP;
            end else if (!hdr_node_ok) begin
                // Out of range, or a frame claiming to come from us - which
                // would make us our own witness a second time, and put
                // fragments into the one region nobody else may write.
                member_drop_reg <= member_drop_reg + 32'd1;
                if (!s_axis_tlast) state_reg <= S_DROP;
            end else if (!hdr_sound_ok) begin
                // The sender was dropped from the sound set at some earlier
                // boundary. Believing it again would grow the set, which is the
                // one thing the protocol never allows.
                sound_drop_reg <= sound_drop_reg + 32'd1;
                if (!s_axis_tlast) state_reg <= S_DROP;
            end else if (!hdr_run_ok) begin
                run_drop_reg <= run_drop_reg + 32'd1;
                if (!s_axis_tlast) state_reg <= S_DROP;
            end else if (!hdr_round_ok) begin
                // Late or early. This is the one arrival hazard TDMA does not
                // remove, so this counter is the one to watch on hardware.
                round_drop_reg <= round_drop_reg + 32'd1;
                if (!s_axis_tlast) state_reg <= S_DROP;
            end else if (hdr_is_ctrl && !hdr_ack_ok) begin
                // A live, current peer that holds different fragments from us -
                // or says it sent a different number than we got. Not a bad
                // frame: a protocol event, and the sender is simply not a
                // witness this round. The frame is one beat (hdr_end_ok).
                ack_disagree_reg <= ack_disagree_reg + 32'd1;
            end else begin
                accept_count_reg <= accept_count_reg + 32'd1;

                if (hdr_is_ctrl) begin
                    ctrl_count_reg <= ctrl_count_reg + 32'd1;

                    // To the core: this peer is a witness.
                    o_rx_node_id <= hdr_node_id;
                    o_rx_valid   <= 1'b1;

                    // A control frame is one beat. tlast was on it (hdr_end_ok),
                    // so the parser is already back at S_HDR.
                end else begin
                    // The frame's geometry, latched once. Nothing re-reads the
                    // header after this beat.
                    payload_beats_reg <= hdr_beats;
                    beat_index_reg    <= 16'd0;

                    // To the stage: the tag, and the start of frame.
                    o_pl_node_id    <= hdr_node_id;
                    o_pl_round_id   <= hdr_round_id;
                    o_pl_len        <= hdr_length;
                    o_pl_frag_idx   <= hdr_frag_idx;
                    o_pl_hdr_data   <= s_axis_tdata;
                    o_pl_sof        <= 1'b1;

                    state_reg <= S_PAYLOAD;
                end
            end
        end
    end

    // ------------------------------------------------------------- payload
    S_PAYLOAD: begin
        if (beat_fire) begin
            if (s_axis_tlast) begin
                // The frame ending somewhere other than where the header's
                // length promised means the two disagree, and the payload is
                // unusable even though the header itself was fine.
                if (is_last_pl) begin
                    o_pl_commit <= 1'b1;
                end else begin
                    malformed_count_reg <= malformed_count_reg + 32'd1;
                    o_pl_drop           <= 1'b1;
                end
                state_reg <= S_HDR;
            end else if (is_last_pl) begin
                // More beats than the length allows. Stop feeding the slot,
                // abandon it, and keep eating until tlast.
                malformed_count_reg <= malformed_count_reg + 32'd1;
                o_pl_drop <= 1'b1;
                state_reg <= S_DROP;
            end else begin
                beat_index_reg <= beat_index_reg + 16'd1;
            end
        end
    end

    // ------------------------------------------------------------- drop
    S_DROP: begin
        if (beat_fire && s_axis_tlast) state_reg <= S_HDR;
    end

    // 2'd3 is unreachable; an upset that lands there must not stick.
    default: state_reg <= S_HDR;
    endcase

    if (rst) begin
        state_reg           <= S_HDR;
        o_rx_valid          <= 1'b0;
        o_rx_node_id        <= 8'd0;
        o_pl_sof            <= 1'b0;
        o_pl_node_id        <= 8'd0;
        o_pl_round_id       <= 64'd0;
        o_pl_len            <= 16'd0;
        o_pl_frag_idx       <= 16'd0;
        o_pl_hdr_data       <= {AXIS_DATA_WIDTH{1'b0}};
        o_pl_commit         <= 1'b0;
        o_pl_drop           <= 1'b0;
        payload_beats_reg   <= 16'd0;
        beat_index_reg      <= 16'd0;
        frame_count_reg     <= 32'd0;
        accept_count_reg    <= 32'd0;
        ctrl_count_reg      <= 32'd0;
        foreign_count_reg   <= 32'd0;
        malformed_count_reg <= 32'd0;
        window_drop_reg     <= 32'd0;
        ctrl_late_reg       <= 32'd0;
        member_drop_reg     <= 32'd0;
        sound_drop_reg      <= 32'd0;
        run_drop_reg        <= 32'd0;
        round_drop_reg      <= 32'd0;
        ack_disagree_reg    <= 32'd0;
        stall_count_reg     <= 32'd0;
    end
end

endmodule

`resetall
