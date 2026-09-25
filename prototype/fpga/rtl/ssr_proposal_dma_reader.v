`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_proposal_dma_reader - fetches the host's proposal ring into ssr_proposal_buffer.
 *
 * THE SHAPE, AND WHY
 *   The proposal path is the commit path run backwards. The host owns a ring
 *   of 2^DEPTH_LOG2 entries of one page each, configured once (base and
 *   depth). An entry has the same shape as the frame it becomes: 64 empty
 *   bytes for ssr_tx_engine's header, then one piece of at most 4032 bytes
 *   (ssr_packet.vh). To propose, the host writes entries at its producer index
 *   and then writes the new producer index here - ONE posted MMIO write, the
 *   doorbell. That is the whole fast path; there is no per-entry descriptor,
 *   no batch to arm, no status to poll.
 *
 *   This module keeps two indices of its own, both free-running 32-bit counts
 *   of entries:
 *
 *       fetch      entries whose DMA read has been issued
 *       consumer   entries that are whole in ssr_proposal_buffer, in order
 *
 *   and issues a read for entry `fetch` whenever fetch != producer, the
 *   buffer has a free slot, and fewer than MAX_INFLIGHT reads are out. The
 *   address is a shift, as on the commit path:
 *
 *       dma_addr = ring_base + ((fetch mod 2^DEPTH_LOG2) << 12)
 *
 *   consumer is what the host needs for flow control - an entry below it may
 *   be overwritten - and it goes back to the host two ways: this block's
 *   PROP_CONSUMER register, and the proposal_consumer field of every verdict
 *   record (ssr_verdict.vh), which the host is polling anyway. So the host
 *   never has to read an MMIO register on the fast path.
 *
 * SEVERAL READS IN FLIGHT, COMPLETING IN ANY ORDER
 *   A 4 KiB read from host memory takes a microsecond or more; a round wants
 *   up to five entries every four. One read at a time cannot keep up, so up
 *   to MAX_INFLIGHT are outstanding. Each goes into its own buffer slot, and
 *   its tag is DMA_TAG_PROP with the slot number in the low bits - so a
 *   completion names its slot with no table here. ssr_proposal_buffer commits
 *   slots in ring order however the completions arrive.
 *
 * ERRORS
 *   A read that completes with an error sets PROP_STATUS.error, records the code, and
 *   stops new reads. Its slot never commits, so the buffer's commit stops in
 *   front of it and CONSUMER settles on exactly the entry that failed. The
 *   host writes PROP_CONTROL.clear_error; once nothing is in flight the buffer
 *   rewinds its reserved slots and fetch goes back to consumer, so the failed
 *   entry and everything after it are fetched again, in order.
 *
 * FLUSH
 *   PROP_CONTROL.flush discards everything not yet on the wire: entries posted
 *   but not fetched (consumer and fetch jump to producer) and slots committed
 *   but not yet streaming. It is executed once nothing is in flight; until
 *   then PROP_STATUS.pending reads 1, no new slot starts streaming (o_hold), and an
 *   entry the host posts is flushed too - so the host waits for pending to
 *   clear before it posts again. A flush
 *   while the node is running can cost it the round in progress - the
 *   fragments it announced are gone - so do it with the core stopped, or
 *   accept that.
 *
 * REGISTERS
 *   None of its own. The ring's settings (enable, base, depth, the producer
 *   doorbell) and the flush / clear requests come in on i_* ports from
 *   ssr_csr; its state goes back out on o_* ports. ssr_csr's PROP_* registers
 *   at 0x200 and PROP_READS / PROP_READ_ERRORS at 0x4C0 are the host's view.
 */

module ssr_proposal_dma_reader #
(
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 13,
    parameter RAM_SEL_WIDTH = 1,
    parameter RAM_ADDR_WIDTH = 17,
    parameter RAM_SEL_PROP = 0,
    parameter DMA_TAG_PROP = 0,
    parameter PROPOSAL_SLOT_BYTES = 4096,
    parameter PROPOSAL_SLOT_COUNT = 8,
    parameter MAX_INFLIGHT = 4,
    // derived; do not override
    parameter SLOT_PTR_WIDTH = PROPOSAL_SLOT_COUNT > 1 ? $clog2(PROPOSAL_SLOT_COUNT) : 1
)
(
    input  wire                                     clk,
    input  wire                                     rst,

    // The host's settings (ssr_csr). i_flush and i_clear_error are one-cycle
    // requests; the rest are levels, i_producer is the doorbell.
    input  wire                                     i_enable,
    input  wire                                     i_flush,
    input  wire                                     i_clear_error,
    input  wire [DMA_ADDR_WIDTH-1:0]                i_ring_base,
    input  wire [4:0]                               i_depth_log2,
    input  wire [31:0]                              i_producer,

    // What the host can see (ssr_csr)
    output wire                                     o_idle,        // no read in flight
    output wire                                     o_error,
    output wire                                     o_pending,     // a flush or clear not yet carried out
    output wire [3:0]                               o_error_code,
    output wire [31:0]                              o_fetch,
    output wire [31:0]                              o_inflight,
    output wire [31:0]                              o_reads,
    output wire [31:0]                              o_read_errors,

    // DMA read descriptor out, status in
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_dma_read_desc_tag,
    output wire                                     m_axis_dma_read_desc_valid,
    input  wire                                     m_axis_dma_read_desc_ready,

    input  wire [DMA_TAG_WIDTH-1:0]                 s_axis_dma_read_desc_status_tag,
    input  wire [3:0]                               s_axis_dma_read_desc_status_error,
    input  wire                                     s_axis_dma_read_desc_status_valid,

    // ssr_proposal_buffer's reader side
    input  wire                                     i_resv_ready,
    input  wire [SLOT_PTR_WIDTH-1:0]                i_resv_slot,
    input  wire [RAM_ADDR_WIDTH-1:0]                i_resv_addr,
    output wire                                     o_resv,
    output wire                                     o_done,
    output wire [SLOT_PTR_WIDTH-1:0]                o_done_slot,
    input  wire                                     i_commit,
    input  wire                                     i_settled,
    output wire                                     o_rewind,
    output wire                                     o_flush,
    output wire                                     o_hold,     // a flush is pending

    // For the verdict record: the host's flow control, without an MMIO read.
    output wire [31:0]                              o_consumer
);

localparam integer ENTRY_SHIFT = $clog2(PROPOSAL_SLOT_BYTES);
localparam integer IF_W        = $clog2(MAX_INFLIGHT + 1);
localparam [DMA_TAG_WIDTH-1:0] TAG_BASE = DMA_TAG_PROP;

initial begin
    if (TAG_BASE[SLOT_PTR_WIDTH-1:0] != 0) begin
        $error("ssr_proposal_dma_reader: DMA_TAG_PROP (%0h) must have its low %0d bits clear - they carry the slot", DMA_TAG_PROP, SLOT_PTR_WIDTH);
        $finish;
    end
    if (MAX_INFLIGHT < 1 || MAX_INFLIGHT > PROPOSAL_SLOT_COUNT) begin
        $error("ssr_proposal_dma_reader: MAX_INFLIGHT (%0d) must be 1..PROPOSAL_SLOT_COUNT (%0d)", MAX_INFLIGHT, PROPOSAL_SLOT_COUNT);
        $finish;
    end
end

// ---------------------------------------------------------------- state
reg [31:0]               consumer_reg   = 32'd0;
reg [31:0]               fetch_reg      = 32'd0;
reg [IF_W-1:0]           inflight_reg   = {IF_W{1'b0}};
reg                      error_reg      = 1'b0;
reg [3:0]                error_code_reg = 4'd0;
reg                      flush_req_reg  = 1'b0;
reg                      clear_req_reg  = 1'b0;
reg [31:0]               reads_reg      = 32'd0;
reg [31:0]               read_err_reg   = 32'd0;

reg                      desc_valid_reg = 1'b0;
reg [DMA_ADDR_WIDTH-1:0] desc_addr_reg  = {DMA_ADDR_WIDTH{1'b0}};
reg [RAM_ADDR_WIDTH-1:0] desc_ram_reg   = {RAM_ADDR_WIDTH{1'b0}};
reg [DMA_TAG_WIDTH-1:0]  desc_tag_reg   = {DMA_TAG_WIDTH{1'b0}};

// ---------------------------------------------------------------- issue
// The entry's position in the ring: the low depth_log2 bits of fetch.
wire [31:0] ring_mask = (32'd1 << i_depth_log2) - 32'd1;
wire [31:0] ring_pos  = fetch_reg & ring_mask;
wire [DMA_ADDR_WIDTH-1:0] entry_addr =
    i_ring_base + ({{(DMA_ADDR_WIDTH-32){1'b0}}, ring_pos} << ENTRY_SHIFT);

wire out_free = !desc_valid_reg || m_axis_dma_read_desc_ready;
wire issue = i_enable && !error_reg && !flush_req_reg && !clear_req_reg
          && (fetch_reg != i_producer)
          && i_resv_ready
          && (inflight_reg < MAX_INFLIGHT[IF_W-1:0])
          && out_free;

assign o_resv = issue;

// ---------------------------------------------------------------- completion
wire cpl_ours = s_axis_dma_read_desc_status_valid
             && ((s_axis_dma_read_desc_status_tag >> SLOT_PTR_WIDTH) == (TAG_BASE >> SLOT_PTR_WIDTH));
wire cpl_ok   = cpl_ours && (s_axis_dma_read_desc_status_error == 4'd0);
wire cpl_bad  = cpl_ours && (s_axis_dma_read_desc_status_error != 4'd0);

assign o_done      = cpl_ok;
assign o_done_slot = s_axis_dma_read_desc_status_tag[SLOT_PTR_WIDTH-1:0];

// ---------------------------------------------------------------- flush / clear
// Both wait for a quiet buffer: nothing in flight (so no completion can land)
// and nothing left to commit (so consumer is final).
wire quiet      = (inflight_reg == {IF_W{1'b0}}) && i_settled;
wire exec_flush = flush_req_reg && quiet;
wire exec_clear = clear_req_reg && !flush_req_reg && quiet;

assign o_flush  = exec_flush;
assign o_hold   = flush_req_reg;
assign o_rewind = exec_clear;
assign o_consumer = consumer_reg;

// ---------------------------------------------------------------- sequential
always @(posedge clk) begin
    // ---- the descriptor register
    if (desc_valid_reg && m_axis_dma_read_desc_ready) desc_valid_reg <= 1'b0;
    if (issue) begin
        desc_valid_reg <= 1'b1;
        desc_addr_reg  <= entry_addr;
        desc_ram_reg   <= i_resv_addr;
        desc_tag_reg   <= TAG_BASE | {{(DMA_TAG_WIDTH-SLOT_PTR_WIDTH){1'b0}}, i_resv_slot};
        fetch_reg      <= fetch_reg + 32'd1;
        reads_reg      <= reads_reg + 32'd1;
    end

    // ---- in flight: up on issue, down on any completion of ours
    inflight_reg <= inflight_reg + (issue ? 1'b1 : 1'b0) - (cpl_ours ? 1'b1 : 1'b0);

    if (cpl_bad) begin
        error_reg      <= 1'b1;
        error_code_reg <= s_axis_dma_read_desc_status_error;
        read_err_reg   <= read_err_reg + 32'd1;
    end

    if (i_commit) consumer_reg <= consumer_reg + 32'd1;

    // ---- flush / clear, once quiet
    if (exec_flush) begin
        flush_req_reg <= 1'b0;
        clear_req_reg <= 1'b0;
        error_reg     <= 1'b0;
        consumer_reg  <= i_producer;
        fetch_reg     <= i_producer;
    end
    if (exec_clear) begin
        clear_req_reg <= 1'b0;
        error_reg     <= 1'b0;
        fetch_reg     <= consumer_reg;
    end

    // ---- requests from the host, after the above: a request landing on the
    // cycle an earlier one is carried out is a new one and stays pending
    if (i_flush)       flush_req_reg <= 1'b1;
    if (i_clear_error) clear_req_reg <= 1'b1;

    if (rst) begin
        consumer_reg   <= 32'd0;
        fetch_reg      <= 32'd0;
        inflight_reg   <= {IF_W{1'b0}};
        error_reg      <= 1'b0;
        error_code_reg <= 4'd0;
        flush_req_reg  <= 1'b0;
        clear_req_reg  <= 1'b0;
        reads_reg      <= 32'd0;
        read_err_reg   <= 32'd0;
        desc_valid_reg <= 1'b0;
    end
end

assign o_idle        = (inflight_reg == {IF_W{1'b0}});
assign o_error       = error_reg;
assign o_pending     = flush_req_reg | clear_req_reg;
assign o_error_code  = error_code_reg;
assign o_fetch       = fetch_reg;
assign o_inflight    = {{(32-IF_W){1'b0}}, inflight_reg};
assign o_reads       = reads_reg;
assign o_read_errors = read_err_reg;

assign m_axis_dma_read_desc_dma_addr = desc_addr_reg;
assign m_axis_dma_read_desc_ram_sel  = RAM_SEL_PROP;
assign m_axis_dma_read_desc_ram_addr = desc_ram_reg;
assign m_axis_dma_read_desc_len      = PROPOSAL_SLOT_BYTES;
assign m_axis_dma_read_desc_tag      = desc_tag_reg;
assign m_axis_dma_read_desc_valid    = desc_valid_reg;

endmodule

`resetall
