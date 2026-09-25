`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_presence_tracker - how many of each node's fragments we hold, per round.
 *
 * WHAT IT IS FOR
 *   Every node's control frame at the top of round R+1 carries an ACK VECTOR
 *   about round R: for each peer k, how many of k's fragments it holds, and
 *   for itself, how many it sent (docs/count_ack.md). This module keeps those
 *   counts. It is the only place in the design that knows a count:
 *
 *     o_prev_ack    our vector about the round before the open one. It goes
 *                   out in our control frame (ssr_tx_engine) and is what a
 *                   peer's vector must equal to be trusted (ssr_rx_engine's
 *                   last rung).
 *     query B       counts and DMA health of a round, for the verdict record
 *                   (ssr_verdict_dma_writer).
 *
 *   ssr_core never sees a count: it only learns, per peer per round, whether
 *   the peer was trusted.
 *
 * WHAT IS COUNTED
 *   A peer's fragment counts when it has been stored whole (ssr_payload_stage's
 *   o_staged) AND its frag_idx is the next one we expect from that node: the
 *   count is a PREFIX. One lost fragment stops it there, and anything after the
 *   gap - or a repeat - is not counted. On one link frames stay in order, so a
 *   gap is a loss; counting a later fragment would let one loss and one
 *   duplicate add up to "all of them".
 *
 *   Our own fragments count when ssr_tx_engine starts them (o_local_sent): our
 *   bytes are in our own host memory already, nothing has to land.
 *
 * ONLY THE OPEN ROUND COUNTS
 *   A round opens at its boundary (ssr_core's o_round_start_pulse, ungated -
 *   pure timing) and stays open until the next one. Anything that arrives for
 *   another round is not counted and is charged to o_late_count. That is what
 *   freezes round R's counts at the boundary into R+1: our ack about R goes out
 *   ~330 ns later, peers compare against it through R+1's control period, and
 *   the verdict for R is written after that - all three must see one value.
 *   ssr_rx_engine already refuses a payload frame from another round; what can
 *   still be late here is a fragment admitted just before the boundary whose
 *   last beat is stored just after it. The transmit cutoff (TX_PAY_CUTOFF_NS in
 *   ssr_dataplane) is sized so that does not happen; this counter is how you
 *   would see that it did.
 *
 * DMA ERRORS
 *   ssr_payload_dma_writer reports a completion error as (round, node): the bytes
 *   were staged but did not reach the host. That sets a FAILED bit, which the
 *   verdict record reports as present_set[k] = 0. It does NOT change the count:
 *   the ack says what arrived on the wire, the record says whether this host's
 *   copy is intact (ssr_verdict.vh). A report for a round no longer held is
 *   dropped and counted.
 *
 * ROUND SLOTS
 *   P_ROUND_DEPTH slots, a power of two, indexed by the low bits of the round id
 *   and holding the full id to tell a hit from a wrap. Round R is still needed
 *   in R+1 (the ack, and its decision) and by the verdict writer after that,
 *   possibly late if its pages are still draining; four leaves two rounds of
 *   slack. Opening a round clears its slot, which is the only eviction.
 */

module ssr_presence_tracker #
(
    parameter integer P_NODE_COUNT  = 3,
    parameter integer P_NODE_ID     = 0,
    parameter integer P_ROUND_DEPTH = 4,
    parameter integer SLOT_W        = (P_ROUND_DEPTH > 1) ? $clog2(P_ROUND_DEPTH) : 1
)
(
    input  wire                     clk,
    input  wire                     rst,

    /*
     * A round begins: ssr_core's o_round_start_pulse and o_round_id.
     */
    input  wire                     i_open,
    input  wire [63:0]              i_open_round_id,

    /*
     * One of our own fragments left: ssr_tx_engine's o_local_sent.
     */
    input  wire                     i_local_sent,
    input  wire [63:0]              i_local_round_id,

    /*
     * A peer's fragment: ssr_rx_engine's o_pl_sof carries whose, which round and
     * which fragment; ssr_payload_stage's o_staged, some beats later, says it was
     * stored whole. Frames do not interleave on one stream, so one latch covers
     * the gap.
     */
    input  wire                     i_pl_sof,
    input  wire [7:0]               i_pl_node_id,
    input  wire [63:0]              i_pl_round_id,
    input  wire [15:0]              i_pl_frag_idx,
    input  wire                     i_pl_commit,

    /*
     * A DMA failure, from ssr_payload_dma_writer.
     */
    input  wire                     i_err_valid,
    input  wire [63:0]              i_err_round_id,
    input  wire [7:0]               i_err_node,

    /*
     * Our ack vector about the round before the open one, node k at [8k +: 8].
     * Registered; zero until that round has been held.
     */
    output reg  [63:0]              o_prev_ack,

    /*
     * Query B: the record for ssr_verdict_dma_writer.
     */
    input  wire [63:0]              i_qb_round_id,
    output wire                     o_qb_hit,
    output wire [7:0]               o_qb_present,      // no DMA error for (round, k)
    output wire [8*16-1:0]          o_qb_frag_count,   // node k at [16k +: 16]

    output wire [31:0]              o_late_count,      // fragments for a round not open
    output wire [31:0]              o_err_count,       // present bits withdrawn by a DMA error
    output wire [31:0]              o_err_miss_count   // DMA errors for a round no longer held
);

localparam integer DEPTH       = P_ROUND_DEPTH;
localparam [7:0]   MEMBER_MASK = (8'd1 << P_NODE_COUNT) - 8'd1;
localparam [2:0]   SELF        = P_NODE_ID;

initial begin
    if (DEPTH < 2) begin
        $error("ssr_presence_tracker: P_ROUND_DEPTH (%0d) must be at least 2 - a round's ack is sent in the round after it (instance %m)", DEPTH);
        $finish;
    end
    if ((1 << SLOT_W) != DEPTH) begin
        $error("ssr_presence_tracker: P_ROUND_DEPTH (%0d) must be a power of two (instance %m)", DEPTH);
        $finish;
    end
    if (P_NODE_COUNT > 8 || P_NODE_ID >= P_NODE_COUNT) begin
        $error("ssr_presence_tracker: P_NODE_COUNT (%0d) must be <= 8 and P_NODE_ID (%0d) inside it (instance %m)", P_NODE_COUNT, P_NODE_ID);
        $finish;
    end
end

// ---------------------------------------------------------------- the slots
// One entry per (slot, node), addressed as {slot, node}. Counts are 8 bits:
// ssr_rx_engine refuses a frag_idx at or past P_FRAGS_PER_ROUND (<= 64), and
// ssr_tx_engine never sends more than that. A node at or past P_NODE_COUNT
// never counts - ssr_rx_engine refuses its frames - so its entries stay zero.
reg              slot_valid [0:DEPTH-1];
reg  [63:0]      slot_round [0:DEPTH-1];
reg              failed     [0:DEPTH*8-1];
reg  [7:0]       count      [0:DEPTH*8-1];

integer init_i;
initial begin
    for (init_i = 0; init_i < DEPTH; init_i = init_i + 1) begin
        slot_valid[init_i] = 1'b0;
        slot_round[init_i] = 64'd0;
    end
    for (init_i = 0; init_i < DEPTH*8; init_i = init_i + 1) begin
        failed[init_i] = 1'b0;
        count[init_i]  = 8'd0;
    end
end

reg        open_valid_reg = 1'b0;
reg [63:0] open_round_reg = 64'd0;
wire [SLOT_W-1:0] open_slot = open_round_reg[SLOT_W-1:0];
wire [SLOT_W-1:0] new_slot  = i_open_round_id[SLOT_W-1:0];

// ---------------------------------------------------------------- fragments
reg  [7:0]  pl_node_reg  = 8'd0;
reg  [63:0] pl_round_reg = 64'd0;
reg  [15:0] pl_idx_reg   = 16'd0;

always @(posedge clk) begin
    if (i_pl_sof) begin
        pl_node_reg  <= i_pl_node_id;
        pl_round_reg <= i_pl_round_id;
        pl_idx_reg   <= i_pl_frag_idx;
    end
end

wire       pl_open  = open_valid_reg && (pl_round_reg == open_round_reg);
wire [7:0] pl_have  = count[open_slot*8 + pl_node_reg[2:0]];
// The next fragment in order, and only that one.
wire       pl_count = i_pl_commit && pl_open && (pl_idx_reg == {8'd0, pl_have});
wire       pl_late  = i_pl_commit && !pl_open;

wire       self_open  = open_valid_reg && (i_local_round_id == open_round_reg);
wire       self_count = i_local_sent && self_open;
wire       self_late  = i_local_sent && !self_open;

wire [SLOT_W-1:0] err_slot = i_err_round_id[SLOT_W-1:0];
wire              err_hit  = slot_valid[err_slot] && (slot_round[err_slot] == i_err_round_id);

// ---------------------------------------------------------------- counters
reg [31:0] late_count_reg     = 32'd0;
reg [31:0] err_count_reg      = 32'd0;
reg [31:0] err_miss_count_reg = 32'd0;

// ---------------------------------------------------------------- update
// ORDER MATTERS: an opening clears its slot after the counts are written, so a
// count for the round being evicted - four rounds old, which the open-round
// test already refuses - could never survive into the new one anyway. The
// open round moves at the same edge, so a fragment landing on the boundary
// cycle is counted into the round it belongs to, which is still the open one.
integer k;
always @(posedge clk) begin
    if (pl_count)
        count[open_slot*8 + pl_node_reg[2:0]] <= pl_have + 8'd1;
    if (self_count)
        count[open_slot*8 + SELF] <= count[open_slot*8 + SELF] + 8'd1;
    late_count_reg <= late_count_reg + {31'd0, pl_late} + {31'd0, self_late};

    if (i_err_valid && err_hit) begin
        failed[err_slot*8 + i_err_node[2:0]] <= 1'b1;
        err_count_reg <= err_count_reg + 32'd1;
    end
    if (i_err_valid && !err_hit)
        err_miss_count_reg <= err_miss_count_reg + 32'd1;

    if (i_open) begin
        open_valid_reg       <= 1'b1;
        open_round_reg       <= i_open_round_id;
        slot_valid[new_slot] <= 1'b1;
        slot_round[new_slot] <= i_open_round_id;
        for (k = 0; k < 8; k = k + 1) begin
            failed[new_slot*8+k] <= 1'b0;
            count[new_slot*8+k]  <= 8'd0;
        end
    end

    if (rst) begin
        for (k = 0; k < DEPTH; k = k + 1) slot_valid[k] <= 1'b0;
        open_valid_reg     <= 1'b0;
        late_count_reg     <= 32'd0;
        err_count_reg      <= 32'd0;
        err_miss_count_reg <= 32'd0;
    end
end

// ---------------------------------------------------------------- our ack
// The round before the open one. Re-read every cycle rather than snapshotted
// at the boundary, so a fragment counted on the boundary cycle itself is in it
// - the same value query B will report for that round.
wire [63:0]       prev_round = open_round_reg - 64'd1;
wire [SLOT_W-1:0] prev_slot  = prev_round[SLOT_W-1:0];
wire              prev_hit   = open_valid_reg && slot_valid[prev_slot] && (slot_round[prev_slot] == prev_round);

genvar ga;
generate
    for (ga = 0; ga < 8; ga = ga + 1) begin : g_ack
        always @(posedge clk) begin
            o_prev_ack[ga*8 +: 8] <= prev_hit ? count[prev_slot*8 + ga] : 8'd0;
            if (rst) o_prev_ack[ga*8 +: 8] <= 8'd0;
        end
    end
endgenerate

// ---------------------------------------------------------------- query B
wire [SLOT_W-1:0] qb_slot = i_qb_round_id[SLOT_W-1:0];
wire              qb_hit  = slot_valid[qb_slot] && (slot_round[qb_slot] == i_qb_round_id);
assign o_qb_hit = qb_hit;

genvar gn;
generate
    for (gn = 0; gn < 8; gn = gn + 1) begin : g_qb
        assign o_qb_present[gn] = qb_hit && MEMBER_MASK[gn] && !failed[qb_slot*8 + gn];
        assign o_qb_frag_count[gn*16 +: 16] =
            qb_hit ? {8'd0, count[qb_slot*8 + gn]} : 16'd0;
    end
endgenerate

assign o_late_count     = late_count_reg;
assign o_err_count      = err_count_reg;
assign o_err_miss_count = err_miss_count_reg;

endmodule

`resetall
