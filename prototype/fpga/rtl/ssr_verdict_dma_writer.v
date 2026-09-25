`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_verdict_dma_writer - tells the host a round is decided, once its pages are.
 *
 * WHAT IT DOES, IN ONE SENTENCE
 *   When ssr_core commits a round, wait until every payload page of that
 *   round has finished landing in host memory, then write one 64-byte record
 *   (rtl/ssr_verdict.vh) saying which of those pages the host may read.
 *
 * WHY THE WAIT
 *   The pages went to the host speculatively, as they arrived, a round and a
 *   control period before the decision (round R is decided at round R+1's
 *   control deadline). The record is the host's permission to read them, so
 *   it must not overtake them: a record that lands before the last page does
 *   would have the host read a page that is still on its way. PCIe keeps
 *   writes from one requester in order only within a stream; two descriptors
 *   are two streams. So the ordering is made here, not assumed: the record's
 *   descriptor is not issued until ssr_payload_dma_writer's tag pool reports the
 *   round's unit idle - every descriptor tagged for R mod UNIT_COUNT has
 *   completed. That is the fence, and it is the only reason this module has a
 *   state machine at all.
 *
 * WHICH DMA
 *   The record goes on the app's control DMA, the pages on its data DMA.
 *   Corundum arbitrates control ahead of data, so a record is not held behind
 *   the NIC's own packet writes - and, for the same reason, it would overtake
 *   any page of its round still waiting at that mux. The fence is what stops
 *   that; the priority only shortens the wait once the fence is open. The
 *   control DMA has its own RAM read port and its own status stream, so the
 *   record needs no ram_sel of its own and its tag is free of the payload
 *   writer's.
 *
 * THE RECORD IS A REGISTER, NOT A RAM
 *   The DMA write engine fetches its bytes from a RAM through a segmented read
 *   port. The record is one beat, so instead of a RAM this module answers that
 *   port itself from a 512-bit register. A RAM segment is one 64-byte beat
 *   (512 bits on the AU200), so the record is exactly one segment: a read
 *   command on any segment returns the whole record, whatever address it
 *   names. The descriptor always says ram_addr 0, len 64, so the engine only
 *   ever asks segment 0 of row 0. One record is in flight at a time and the register
 *   is not overwritten until its completion arrives, so the engine can read it
 *   whenever it likes.
 *
 * ONE AT A TIME
 *   A verdict is 64 bytes once per round; there is nothing to pipeline. The
 *   verdicts wait in a small queue while the one ahead is fenced and written,
 *   which covers a burst of decisions arriving while PCIe is slow. If even the
 *   queue fills, a verdict is dropped and counted - the host will see a gap in
 *   seq and know.
 *
 * WHERE THE RECORD GOES
 *   ring_base + (seq mod D) * 64, D = 2^P_HOST_DEPTH_LOG2. seq is this
 *   module's record counter, in the record as well, so the host can tell a
 *   fresh entry from the one it read last time round the ring.
 */

module ssr_verdict_dma_writer #
(
    parameter integer DMA_ADDR_WIDTH     = 64,
    parameter integer DMA_LEN_WIDTH      = 16,
    parameter integer DMA_TAG_WIDTH      = 13,
    parameter integer RAM_SEL_WIDTH      = 1,
    parameter integer RAM_ADDR_WIDTH     = 17,
    parameter integer RAM_SEG_COUNT      = 2,
    parameter integer RAM_SEG_DATA_WIDTH = 512,
    parameter integer RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH/8),

    // The descriptor's ram_sel. The control DMA's RAM read port reaches only
    // this module, so nothing routes on it.
    parameter [RAM_SEL_WIDTH-1:0] P_RAM_SEL = 0,
    // The one tag every record carries, on the control DMA's own status
    // stream, where nothing else of ours reports.
    parameter [DMA_TAG_WIDTH-1:0] P_TAG   = 0,

    parameter integer P_NODE_COUNT       = 3,
    parameter integer P_NODE_ID          = 0,

    // ssr_payload_dma_writer's UNIT_COUNT: the fence is per R mod UNIT_COUNT.
    parameter integer UNIT_COUNT         = 4,
    // log2 of the host's verdict ring, in records.
    parameter integer P_HOST_DEPTH_LOG2  = 8,
    // Verdicts waiting for their turn. Power of two.
    parameter integer QUEUE_DEPTH        = 4,

    parameter integer UNIT_SEL_W         = (UNIT_COUNT > 1) ? $clog2(UNIT_COUNT) : 1
)
(
    input  wire                             clk,
    input  wire                             rst,

    input  wire                             i_enable,
    input  wire [DMA_ADDR_WIDTH-1:0]        i_ring_base,

    /*
     * From ssr_core: the decision. i_commit_set is the sound set it left in
     * force; what was committed of each node is the tracker's count for the
     * round (query B), which is our own ack vector for it.
     */
    input  wire                             i_commit_valid,
    input  wire [63:0]                      i_commit_round_id,
    input  wire [7:0]                       i_commit_set,
    input  wire [31:0]                      i_run_id,
    // ssr_proposal_dma_reader's consumer index, sampled when the record is built.
    input  wire [31:0]                      i_prop_consumer,

    /*
     * The fence, from ssr_payload_dma_writer.
     */
    input  wire [UNIT_COUNT-1:0]            i_unit_idle,

    /*
     * ssr_presence_tracker's query B for the round we are describing: the
     * committed prefix per node, and whether this host's copy is intact.
     */
    output wire [63:0]                      o_q_round_id,
    input  wire                             i_q_hit,
    input  wire [7:0]                       i_q_present,
    input  wire [8*16-1:0]                  i_q_frag_count,

    /*
     * DMA write descriptor out, completion in.
     */
    output wire [DMA_ADDR_WIDTH-1:0]        m_axis_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]         m_axis_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]        m_axis_dma_write_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]         m_axis_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]         m_axis_dma_write_desc_tag,
    output wire                             m_axis_dma_write_desc_valid,
    input  wire                             m_axis_dma_write_desc_ready,

    input  wire [DMA_TAG_WIDTH-1:0]         s_axis_dma_write_desc_status_tag,
    input  wire [3:0]                       s_axis_dma_write_desc_status_error,
    input  wire                             s_axis_dma_write_desc_status_valid,

    /*
     * The engine's read port, answered from the record register.
     */
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]  dma_ram_rd_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_resp_valid,
    input  wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_resp_ready,

    output wire [63:0]                      o_seq,             // records written so far
    output wire [31:0]                      o_record_count,    // completions, good or bad
    output wire [31:0]                      o_err_count,       // of which the engine reported an error
    output wire [31:0]                      o_overflow_count,  // verdicts dropped, queue full
    output wire [31:0]                      o_stale_count      // rounds ssr_presence_tracker no longer held
);

`include "ssr_verdict.vh"

localparam integer RECORD_BITS = SSRV_RECORD_BYTES * 8;
localparam integer QW = (QUEUE_DEPTH > 1) ? $clog2(QUEUE_DEPTH) : 1;

initial begin
    if (RAM_SEG_DATA_WIDTH != RECORD_BITS) begin
        $error("ssr_verdict_dma_writer: the record is one RAM segment, so RAM_SEG_DATA_WIDTH (%0d) must be %0d (instance %m)",
               RAM_SEG_DATA_WIDTH, RECORD_BITS);
        $finish;
    end
    if ((1 << QW) != QUEUE_DEPTH) begin
        $error("ssr_verdict_dma_writer: QUEUE_DEPTH (%0d) must be a power of two (instance %m)", QUEUE_DEPTH);
        $finish;
    end
    if (P_NODE_COUNT > SSRV_MAX_NODES) begin
        $error("ssr_verdict_dma_writer: P_NODE_COUNT (%0d) exceeds the record's %0d count entries (instance %m)",
               P_NODE_COUNT, SSRV_MAX_NODES);
        $finish;
    end
end

function [15:0] be16(input [15:0] v); be16 = {v[7:0], v[15:8]}; endfunction
function [31:0] be32(input [31:0] v);
    be32 = {v[7:0], v[15:8], v[23:16], v[31:24]};
endfunction
function [63:0] be64(input [63:0] v);
    be64 = {v[7:0], v[15:8], v[23:16], v[31:24],
            v[39:32], v[47:40], v[55:48], v[63:56]};
endfunction

// ---------------------------------------------------------------- the queue
reg [63:0] q_round  [0:QUEUE_DEPTH-1];
reg [7:0]  q_set    [0:QUEUE_DEPTH-1];
reg [31:0] q_run    [0:QUEUE_DEPTH-1];
reg [QW:0] q_wr_reg = 0, q_rd_reg = 0;      // one extra bit tells full from empty

wire [QW:0] q_count = q_wr_reg - q_rd_reg;
wire        q_empty = (q_count == 0);
wire        q_full  = q_count[QW];

wire q_push = i_commit_valid && !q_full;
wire q_drop = i_commit_valid &&  q_full;

wire [63:0] head_round = q_round[q_rd_reg[QW-1:0]];
wire [7:0]  head_set   = q_set[q_rd_reg[QW-1:0]];
wire [31:0] head_run   = q_run[q_rd_reg[QW-1:0]];

// ---------------------------------------------------------------- the FSM
localparam [1:0] S_IDLE  = 2'd0,   // nothing queued, or disabled
                 S_FENCE = 2'd1,   // head waits for its round's pages
                 S_DESC  = 2'd2,   // descriptor offered to the engine
                 S_WAIT  = 2'd3;   // descriptor taken; waiting for its completion

reg [1:0]  state_reg = S_IDLE;
reg [63:0] seq_reg   = 64'd0;

wire [UNIT_SEL_W-1:0] head_unit = head_round[UNIT_SEL_W-1:0];
wire                  fence_open = i_unit_idle[head_unit];

// ssr_presence_tracker is asked about the head round. The answer is used on the
// cycle the fence opens, and only then.
assign o_q_round_id = head_round;

// ---------------------------------------------------------------- the record
reg [RECORD_BITS-1:0] record_reg = {RECORD_BITS{1'b0}};

// Composed from the head and the tracker's answer, as one flat vector, byte
// k at [k*8 +: 8]. Big-endian inside each multi-byte field.
reg [RECORD_BITS-1:0] record_next;
integer rk;
always @* begin
    record_next = {RECORD_BITS{1'b0}};
    record_next[SSRV_OFF_ROUND_ID*8    +: 64] = be64(head_round);
    record_next[SSRV_OFF_SEQ*8         +: 64] = be64(seq_reg);
    record_next[SSRV_OFF_RUN_ID*8      +: 32] = be32(head_run);
    record_next[SSRV_OFF_COMMIT_SET*8  +: 8]  = head_set;
    record_next[SSRV_OFF_PRESENT_SET*8 +: 8]  = i_q_hit ? i_q_present : 8'd0;
    record_next[SSRV_OFF_NODE_COUNT*8  +: 8]  = P_NODE_COUNT[7:0];
    record_next[SSRV_OFF_SELF_INDEX*8  +: 8]  = P_NODE_ID[7:0];
    record_next[SSRV_OFF_PROP_CONSUMER*8 +: 32] = be32(i_prop_consumer);
    for (rk = 0; rk < SSRV_MAX_NODES; rk = rk + 1)
        record_next[(SSRV_OFF_FRAG_COUNTS + 2*rk)*8 +: 16] =
            i_q_hit ? be16(i_q_frag_count[rk*16 +: 16]) : 16'd0;
end

// ---------------------------------------------------------------- descriptor
reg                      desc_valid_reg = 1'b0;
reg [DMA_ADDR_WIDTH-1:0] desc_addr_reg  = {DMA_ADDR_WIDTH{1'b0}};

assign m_axis_dma_write_desc_dma_addr = desc_addr_reg;
assign m_axis_dma_write_desc_ram_sel  = P_RAM_SEL;
assign m_axis_dma_write_desc_ram_addr = {RAM_ADDR_WIDTH{1'b0}};
assign m_axis_dma_write_desc_len      = SSRV_RECORD_BYTES[DMA_LEN_WIDTH-1:0];
assign m_axis_dma_write_desc_tag      = P_TAG;
assign m_axis_dma_write_desc_valid    = desc_valid_reg;

wire desc_taken = desc_valid_reg && m_axis_dma_write_desc_ready;

wire cpl_hit = s_axis_dma_write_desc_status_valid
            && (s_axis_dma_write_desc_status_tag == P_TAG);
wire cpl_err = cpl_hit && (s_axis_dma_write_desc_status_error != 4'd0);

wire [DMA_ADDR_WIDTH-1:0] ring_offset =
    {{(DMA_ADDR_WIDTH-P_HOST_DEPTH_LOG2-6){1'b0}}, seq_reg[P_HOST_DEPTH_LOG2-1:0], 6'd0};

// ---------------------------------------------------------------- counters
reg [31:0] record_count_reg   = 32'd0;
reg [31:0] err_count_reg      = 32'd0;
reg [31:0] overflow_count_reg = 32'd0;
reg [31:0] stale_count_reg    = 32'd0;

// ---------------------------------------------------------------- sequential
always @(posedge clk) begin
    if (q_push) begin
        q_round[q_wr_reg[QW-1:0]] <= i_commit_round_id;
        q_set[q_wr_reg[QW-1:0]]   <= i_commit_set;
        q_run[q_wr_reg[QW-1:0]]   <= i_run_id;
        q_wr_reg <= q_wr_reg + 1;
    end
    if (q_drop) overflow_count_reg <= overflow_count_reg + 32'd1;

    case (state_reg)
        S_IDLE: begin
            if (!q_empty && i_enable) state_reg <= S_FENCE;
        end

        S_FENCE: begin
            if (fence_open) begin
                record_reg     <= record_next;
                desc_addr_reg  <= i_ring_base + ring_offset;
                desc_valid_reg <= 1'b1;
                if (!i_q_hit) stale_count_reg <= stale_count_reg + 32'd1;
                state_reg <= S_DESC;
            end
        end

        S_DESC: begin
            if (desc_taken) begin
                desc_valid_reg <= 1'b0;
                state_reg <= S_WAIT;
            end
        end

        S_WAIT: begin
            if (cpl_hit) begin
                record_count_reg <= record_count_reg + 32'd1;
                if (cpl_err) err_count_reg <= err_count_reg + 32'd1;
                seq_reg  <= seq_reg + 64'd1;
                q_rd_reg <= q_rd_reg + 1;
                state_reg <= S_IDLE;
            end
        end
    endcase

    if (rst) begin
        q_wr_reg           <= 0;
        q_rd_reg           <= 0;
        state_reg          <= S_IDLE;
        seq_reg            <= 64'd0;
        desc_valid_reg     <= 1'b0;
        record_count_reg   <= 32'd0;
        err_count_reg      <= 32'd0;
        overflow_count_reg <= 32'd0;
        stale_count_reg    <= 32'd0;
    end
end

// ---------------------------------------------------------------- read port
// One response register per segment. A command is accepted when the register
// is free or being drained this cycle; the address is not looked at.
genvar gs;
generate
    for (gs = 0; gs < RAM_SEG_COUNT; gs = gs + 1) begin : g_seg
        reg                          resp_valid_reg = 1'b0;
        reg [RAM_SEG_DATA_WIDTH-1:0] resp_data_reg  = {RAM_SEG_DATA_WIDTH{1'b0}};

        wire cmd_ready = !resp_valid_reg || dma_ram_rd_resp_ready[gs];
        wire cmd_fire  = dma_ram_rd_cmd_valid[gs] && cmd_ready;

        always @(posedge clk) begin
            if (cmd_fire) begin
                resp_valid_reg <= 1'b1;
                resp_data_reg  <= record_reg;
            end else if (dma_ram_rd_resp_ready[gs]) begin
                resp_valid_reg <= 1'b0;
            end
            if (rst) resp_valid_reg <= 1'b0;
        end

        assign dma_ram_rd_cmd_ready[gs]  = cmd_ready;
        assign dma_ram_rd_resp_valid[gs] = resp_valid_reg;
        assign dma_ram_rd_resp_data[gs*RAM_SEG_DATA_WIDTH +: RAM_SEG_DATA_WIDTH] = resp_data_reg;
    end
endgenerate

assign o_seq            = seq_reg;
assign o_record_count   = record_count_reg;
assign o_err_count      = err_count_reg;
assign o_overflow_count = overflow_count_reg;
assign o_stale_count    = stale_count_reg;

endmodule

`resetall
