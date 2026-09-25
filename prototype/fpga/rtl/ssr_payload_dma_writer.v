`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_payload_dma_writer - turns ssr_payload_stage's head into DMA write descriptors.
 *
 * WHAT IT DOES, IN ONE SENTENCE
 *   Pop a descriptor off ssr_payload_stage, compute where in host memory those
 *   bytes belong, borrow a tag, hand the descriptor to the DMA engine; when the
 *   engine reports the tag done, give the tag back and tell ssr_payload_stage which
 *   slot it may now reuse.
 *
 * WHAT IT DOES NOT DO
 *   It does not know what a round is, beyond needing round_id for the address:
 *   ssr_presence_tracker decides completeness, ssr_core decides commitment.
 *   It does not look inside a frame. ssr_payload_stage hands it one descriptor per
 *   slot - a whole frame, header and all, to one page - and this module moves
 *   it.
 *
 *   It does not store anything and it never waits for a completion before
 *   issuing the next descriptor. Several are in flight at once - that is the
 *   whole point of the path, and it is why ssr_dma_tag_pool exists.
 *
 * WHERE THE BYTES GO
 *   A frame is a page, so a fragment's destination is a page number:
 *
 *     host_addr(R, k, f) = ring_base
 *                        + (R mod D_HOST) * SLOT      SLOT   = N * REGION
 *                        + k              * REGION    REGION = 1 << REGION_SHIFT
 *                        + f              * 4096      the fragment's page
 *
 *   Folded:
 *
 *     region_index = (R mod D_HOST) * N + k
 *     host_addr    = ring_base + (region_index << REGION_SHIFT) + (f << 12)
 *
 *   R mod D_HOST is a bit slice, because D_HOST is a power of two. * N is a
 *   constant multiply by a small integer, which synthesis turns into a shift
 *   and an add or two. f << 12 is wiring. Everything is on the head interface
 *   the cycle it is popped, so there is no state between the pop and the
 *   descriptor.
 *
 * THE TAG
 *   Every descriptor gets a unique tag from ssr_dma_tag_pool, keyed on the round
 *   slot (R mod UNIT_COUNT) so the pool can hold the ordering fence per round,
 *   and carrying {round_id, node_id, stage_slot} as its meta so the completion
 *   can be routed: the slot back to ssr_payload_stage, the (round, node) to
 *   ssr_presence_tracker if it failed. The round rides whole - 64 bits per tag -
 *   so an error can never be charged to a round that has since taken the same
 *   slot. No table is kept here; the pool is the table.
 *
 * ONE REGISTER, NO STATE MACHINE
 *   The descriptor output is a single register with valid/ready. A pop happens
 *   when the head has something, the pool has a tag, the module is enabled and
 *   the output register is free - all in one cycle, so the sustained rate is
 *   one descriptor per cycle if the engine will take them. There is nothing to
 *   sequence.
 */

module ssr_payload_dma_writer #
(
    parameter integer DMA_ADDR_WIDTH   = 64,
    parameter integer DMA_LEN_WIDTH    = 16,
    parameter integer DMA_TAG_WIDTH    = 13,
    parameter integer RAM_SEL_WIDTH    = 1,
    parameter integer RAM_ADDR_WIDTH   = 17,

    // The staging RAM's ram_sel. The data DMA's RAM read port reaches only the
    // staging RAM, so nothing routes on it.
    parameter [RAM_SEL_WIDTH-1:0] P_RAM_SEL = 0,

    parameter integer P_NODE_COUNT     = 3,

    // log2 of a node's region in host memory: clog2(P_FRAGS_PER_ROUND * 4096).
    // Five fragments is 20 KiB, so 32 KiB, so 15.
    parameter integer P_REGION_SHIFT   = 15,

    // log2 of the ring depth in rounds. Host memory, so 256 or more is cheap.
    parameter integer P_HOST_DEPTH_LOG2 = 8,

    // Tags: how many descriptors may be outstanding, and where they sit in the
    // shared tag space. See ssr_dma_tag_pool.
    parameter integer TAG_COUNT        = 16,
    parameter [15:0]  TAG_BASE         = 16'h0000,
    // Fence units: rounds that may have descriptors in flight at once.
    parameter integer UNIT_COUNT       = 4,

    // ---- derived; do not override -----------------------------------------
    parameter integer SLOT_PTR_W       = 3,     // ssr_payload_stage's, sizes a port
    parameter integer UNIT_SEL_W       = (UNIT_COUNT > 1) ? $clog2(UNIT_COUNT) : 1,
    parameter integer TAG_CNT_W        = $clog2(TAG_COUNT + 1)
)
(
    input  wire                             clk,
    input  wire                             rst,

    // ---- control -----------------------------------------------------------
    input  wire                             i_enable,
    input  wire [DMA_ADDR_WIDTH-1:0]        i_ring_base,

    // ---- head of ssr_payload_stage -------------------------------------------
    input  wire                             i_head_valid,
    input  wire [RAM_ADDR_WIDTH-1:0]        i_head_addr,
    input  wire [DMA_LEN_WIDTH-1:0]         i_head_len,
    input  wire [63:0]                      i_head_round_id,
    input  wire [7:0]                       i_head_node_id,
    input  wire [15:0]                      i_head_frag_idx,
    input  wire [SLOT_PTR_W-1:0]            i_head_slot,
    output wire                             o_head_pop,

    // ---- back to ssr_payload_stage: this slot's descriptor completed -----------
    output reg                              o_desc_done,
    output reg  [SLOT_PTR_W-1:0]            o_done_slot,

    // ---- to ssr_presence_tracker: a descriptor failed -------------------------
    // The slot is released regardless - the bytes are no longer needed - but
    // the node did not land, and the tracker clears its presence for the
    // round. Reported by (round, node): the tracker looks the round up the
    // same way it does for a fragment, so a stale report misses instead of
    // landing on whatever round occupies the slot now.
    output reg                              o_err_valid,
    output reg  [63:0]                      o_err_round_id,
    output reg  [7:0]                       o_err_node,

    // ---- the fence, per round slot -----------------------------------------
    output wire [UNIT_COUNT-1:0]            o_unit_idle,

    // ---- DMA write descriptor ----------------------------------------------
    output wire [DMA_ADDR_WIDTH-1:0]        m_axis_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]         m_axis_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]        m_axis_dma_write_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]         m_axis_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]         m_axis_dma_write_desc_tag,
    output wire                             m_axis_dma_write_desc_valid,
    input  wire                             m_axis_dma_write_desc_ready,

    // ---- DMA write status --------------------------------------------------
    input  wire [DMA_TAG_WIDTH-1:0]         s_axis_dma_write_desc_status_tag,
    input  wire [3:0]                       s_axis_dma_write_desc_status_error,
    input  wire                             s_axis_dma_write_desc_status_valid,

    // ---- counters ---------------------------------------------------------
    output wire [31:0]                      o_desc_count,    // descriptors issued
    output wire [31:0]                      o_cpl_count,     // completions matched
    output wire [31:0]                      o_err_count,     // of which failed
    output wire [31:0]                      o_starve_count,  // head ready, no tag
    output wire [31:0]                      o_stray_count,   // a completion that was not ours
    output wire [TAG_CNT_W-1:0]             o_high_water     // most ever outstanding
);

// ---------------------------------------------------------------- geometry
localparam integer NODE_W    = 8;
localparam integer RIDX_W    = P_HOST_DEPTH_LOG2;
// (R mod D_HOST) * N + k needs room for D_HOST * N.
localparam integer REGION_IDX_W = RIDX_W + $clog2(P_NODE_COUNT + 1);
localparam integer META_W    = 64 + NODE_W + SLOT_PTR_W;   // {round, node, slot}

initial begin
    if (P_NODE_COUNT < 2 || P_NODE_COUNT > 255) begin
        $error("ssr_payload_dma_writer: P_NODE_COUNT = %0d out of range (instance %m)", P_NODE_COUNT);
        $finish;
    end
    if (P_REGION_SHIFT < 12) begin
        $error("ssr_payload_dma_writer: P_REGION_SHIFT = %0d - a region must hold at least one page (instance %m)", P_REGION_SHIFT);
        $finish;
    end
    if (REGION_IDX_W + P_REGION_SHIFT + 1 > DMA_ADDR_WIDTH) begin
        $error("ssr_payload_dma_writer: the ring does not fit in a %0d-bit address (instance %m)", DMA_ADDR_WIDTH);
        $finish;
    end
end

// ---------------------------------------------------------------- host address
// All of it from the head interface, on the cycle of the pop.
wire [RIDX_W-1:0]       ridx         = i_head_round_id[RIDX_W-1:0];
wire [REGION_IDX_W-1:0] region_index = ridx * P_NODE_COUNT[REGION_IDX_W-1:0]
                                     + {{(REGION_IDX_W-NODE_W){1'b0}}, i_head_node_id};

wire [DMA_ADDR_WIDTH-1:0] region_base =
    {{(DMA_ADDR_WIDTH-REGION_IDX_W){1'b0}}, region_index} << P_REGION_SHIFT;

localparam integer PAGE_SHIFT = 12;
wire [DMA_ADDR_WIDTH-1:0] page_off = {{(DMA_ADDR_WIDTH-16-PAGE_SHIFT){1'b0}}, i_head_frag_idx, {PAGE_SHIFT{1'b0}}};

wire [DMA_ADDR_WIDTH-1:0] host_addr = i_ring_base + region_base + page_off;

// ---------------------------------------------------------------- tags
wire                  tag_alloc_ready;
wire [DMA_TAG_WIDTH-1:0] tag_alloc_tag;
wire                  cpl_hit;
wire [UNIT_SEL_W-1:0] cpl_unit;
wire [META_W-1:0]     cpl_meta;
wire                  cpl_error;
wire [31:0]           pool_alloc_count, pool_cpl_count, pool_err_count;
wire [31:0]           pool_stray_count, pool_starve_count;

// ---------------------------------------------------------------- the pop
reg                       desc_valid_reg    = 1'b0;
reg [DMA_ADDR_WIDTH-1:0]  desc_dma_addr_reg = {DMA_ADDR_WIDTH{1'b0}};
reg [RAM_ADDR_WIDTH-1:0]  desc_ram_addr_reg = {RAM_ADDR_WIDTH{1'b0}};
reg [DMA_LEN_WIDTH-1:0]   desc_len_reg      = {DMA_LEN_WIDTH{1'b0}};
reg [DMA_TAG_WIDTH-1:0]   desc_tag_reg      = {DMA_TAG_WIDTH{1'b0}};

// The output register is free this cycle if it is empty or the engine is
// taking what is in it.
wire out_free = !desc_valid_reg || m_axis_dma_write_desc_ready;

// Four things at once: something to send, a tag to send it under, permission,
// and somewhere to put it. This is the only decision in the module.
wire issue = i_head_valid && tag_alloc_ready && i_enable && out_free;

assign o_head_pop = issue;

// Counted separately from the pool's own starve counter because the pool
// cannot see i_head_valid; this one says "a descriptor was READY and waited".
reg [31:0] starve_count_reg = 32'd0;
wire starve = i_head_valid && i_enable && out_free && !tag_alloc_ready;

assign m_axis_dma_write_desc_dma_addr = desc_dma_addr_reg;
assign m_axis_dma_write_desc_ram_sel  = P_RAM_SEL;
assign m_axis_dma_write_desc_ram_addr = desc_ram_addr_reg;
assign m_axis_dma_write_desc_len      = desc_len_reg;
assign m_axis_dma_write_desc_tag      = desc_tag_reg;
assign m_axis_dma_write_desc_valid    = desc_valid_reg;

always @(posedge clk) begin
    if (issue) begin
        desc_valid_reg    <= 1'b1;
        desc_dma_addr_reg <= host_addr;
        desc_ram_addr_reg <= i_head_addr;
        desc_len_reg      <= i_head_len;
        desc_tag_reg      <= tag_alloc_tag;
    end else if (m_axis_dma_write_desc_ready) begin
        desc_valid_reg    <= 1'b0;
    end

    if (starve) starve_count_reg <= starve_count_reg + 32'd1;

    // The completion, one flop later so nothing downstream sits on the
    // status bus's combinational path.
    o_desc_done <= cpl_hit;
    o_done_slot <= cpl_meta[SLOT_PTR_W-1:0];
    o_err_valid    <= cpl_hit && cpl_error;
    o_err_round_id <= cpl_meta[META_W-1 -: 64];
    o_err_node     <= cpl_meta[SLOT_PTR_W +: NODE_W];

    if (rst) begin
        desc_valid_reg   <= 1'b0;
        starve_count_reg <= 32'd0;
        o_desc_done      <= 1'b0;
        o_done_slot      <= {SLOT_PTR_W{1'b0}};
        o_err_valid      <= 1'b0;
        o_err_round_id   <= 64'd0;
        o_err_node       <= 8'd0;
    end
end

// ---------------------------------------------------------------- the pool
ssr_dma_tag_pool #(
    .TAG_COUNT  (TAG_COUNT),
    .TAG_WIDTH  (DMA_TAG_WIDTH),
    .TAG_BASE   (TAG_BASE),
    .UNIT_COUNT (UNIT_COUNT),
    .META_WIDTH (META_W)
) pool_inst (
    .clk(clk),
    .rst(rst),

    .i_alloc_valid (issue),
    .i_alloc_unit  (ridx[UNIT_SEL_W-1:0]),        // round mod UNIT_COUNT
    .i_alloc_meta  ({i_head_round_id, i_head_node_id, i_head_slot}),
    .o_alloc_ready (tag_alloc_ready),
    .o_alloc_tag   (tag_alloc_tag),

    .i_cpl_valid (s_axis_dma_write_desc_status_valid),
    .i_cpl_tag   (s_axis_dma_write_desc_status_tag),
    .i_cpl_error (s_axis_dma_write_desc_status_error),
    .o_cpl_hit   (cpl_hit),
    .o_cpl_unit  (cpl_unit),
    .o_cpl_meta  (cpl_meta),
    .o_cpl_error (cpl_error),

    .o_unit_idle (o_unit_idle),

    .o_alloc_count  (pool_alloc_count),
    .o_cpl_count    (pool_cpl_count),
    .o_err_count    (pool_err_count),
    .o_stray_count  (pool_stray_count),
    .o_starve_count (pool_starve_count),
    .o_high_water   (o_high_water)
);

assign o_desc_count   = pool_alloc_count;
assign o_cpl_count    = pool_cpl_count;
assign o_err_count    = pool_err_count;
assign o_starve_count = starve_count_reg;
assign o_stray_count  = pool_stray_count;

endmodule

`resetall
