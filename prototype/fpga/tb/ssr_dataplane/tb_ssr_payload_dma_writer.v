`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_payload_dma_writer - the head pops, the address, the tag round trip, the
 * fence, and the two things that can go wrong: no tag, and a failed DMA.
 *
 * THE ENGINE MODEL
 *   Takes descriptors when it feels like it (a ready pattern the test sets),
 *   records every one it took, and completes them in whatever order the test
 *   asks - in order, reversed, or one at a time - with an error code if asked.
 *   The writer never sees a completion it did not earn, except in W7 where a
 *   stray one is sent on purpose.
 *
 * NEGATIVE CONTROLS (edit rtl/ssr_payload_dma_writer.v, never this file)
 *   host_addr without page_off                W1 address
 *   region_index = ridx + node (no multiply)  W1 address
 *   ridx taken from the top of round_id       W1 address
 *   o_done_slot <= cpl_meta[META_W-1 -: ...]  W2 slot routing (node bits, not slot)
 *   issue without out_free                    W3 a descriptor is overwritten unseen
 *   issue without tag_alloc_ready             W4 the pool rejects, tag is garbage
 *   o_err_valid <= cpl_hit                    W6 every completion looks like an error
 */

module tb_ssr_payload_dma_writer;

localparam integer DMA_ADDR_WIDTH = 64;
localparam integer DMA_LEN_WIDTH  = 16;
// AU200 widths: 13-bit tags, 1-bit ram_sel (0 = the staging RAM), 17-bit RAM.
localparam integer DMA_TAG_WIDTH  = 13;
localparam integer RAM_SEL_WIDTH  = 1;
localparam integer RAM_ADDR_WIDTH = 17;
localparam [0:0]   RAM_SEL        = 1'b0;
localparam integer N              = 3;
localparam integer REGION_SHIFT   = 15;
localparam integer DEPTH_LOG2     = 8;
localparam integer TAG_COUNT      = 4;      // small, so starvation is reachable
localparam [15:0]  TAG_BASE       = 16'h0100;   // not 0, so the base compare is exercised
localparam integer UNIT_COUNT     = 4;
localparam integer SLOT_PTR_W     = 4;

localparam [63:0] RING_BASE = 64'h0000_0001_0000_0000;

reg clk = 1'b0, rst = 1'b1;
always #2 clk = ~clk;
initial begin repeat (4) @(posedge clk); rst = 1'b0; end

integer checks = 0, errors = 0;
task check(input cond, input [8*96-1:0] msg);
begin
    checks = checks + 1;
    if (!cond) begin errors = errors + 1; $display("  FAIL [%0t] %0s", $time, msg); end
end
endtask
task banner(input [8*96-1:0] msg); begin $display(""); $display("---- %0s", msg); end endtask

// ---------------------------------------------------------------- DUT
reg                       enable = 1'b1;
reg                       head_valid = 1'b0;
reg  [RAM_ADDR_WIDTH-1:0] head_addr  = 0;
reg  [DMA_LEN_WIDTH-1:0]  head_len   = 0;
reg  [63:0]               head_round = 0;
reg  [7:0]                head_node  = 0;
reg  [15:0]               head_frag  = 0;
reg  [SLOT_PTR_W-1:0]     head_slot  = 0;
wire                      head_pop;

wire                      desc_done;
wire [SLOT_PTR_W-1:0]     done_slot;
wire                      err_valid;
wire [63:0]               err_round;
wire [7:0]                err_node;
wire [UNIT_COUNT-1:0]     unit_idle;

wire [DMA_ADDR_WIDTH-1:0] d_addr;
wire [RAM_SEL_WIDTH-1:0]  d_sel;
wire [RAM_ADDR_WIDTH-1:0] d_ram;
wire [DMA_LEN_WIDTH-1:0]  d_len;
wire [DMA_TAG_WIDTH-1:0]  d_tag;
wire                      d_valid;
reg                       d_ready = 1'b1;

reg  [DMA_TAG_WIDTH-1:0]  st_tag   = 0;
reg  [3:0]                st_err   = 0;
reg                       st_valid = 1'b0;

wire [31:0] c_desc, c_cpl, c_err, c_starve, c_stray;
wire [2:0]  c_hw;

ssr_payload_dma_writer #(
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH), .DMA_LEN_WIDTH(DMA_LEN_WIDTH), .DMA_TAG_WIDTH(DMA_TAG_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH), .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH), .P_RAM_SEL(RAM_SEL),
    .P_NODE_COUNT(N), .P_REGION_SHIFT(REGION_SHIFT), .P_HOST_DEPTH_LOG2(DEPTH_LOG2),
    .TAG_COUNT(TAG_COUNT), .TAG_BASE(TAG_BASE), .UNIT_COUNT(UNIT_COUNT), .SLOT_PTR_W(SLOT_PTR_W)
) dut (
    .clk(clk), .rst(rst),
    .i_enable(enable), .i_ring_base(RING_BASE),
    .i_head_valid(head_valid), .i_head_addr(head_addr), .i_head_len(head_len),
    .i_head_round_id(head_round), .i_head_node_id(head_node), .i_head_frag_idx(head_frag),
    .i_head_slot(head_slot), .o_head_pop(head_pop),
    .o_desc_done(desc_done), .o_done_slot(done_slot),
    .o_err_valid(err_valid), .o_err_round_id(err_round), .o_err_node(err_node),
    .o_unit_idle(unit_idle),
    .m_axis_dma_write_desc_dma_addr(d_addr), .m_axis_dma_write_desc_ram_sel(d_sel),
    .m_axis_dma_write_desc_ram_addr(d_ram), .m_axis_dma_write_desc_len(d_len),
    .m_axis_dma_write_desc_tag(d_tag), .m_axis_dma_write_desc_valid(d_valid),
    .m_axis_dma_write_desc_ready(d_ready),
    .s_axis_dma_write_desc_status_tag(st_tag), .s_axis_dma_write_desc_status_error(st_err),
    .s_axis_dma_write_desc_status_valid(st_valid),
    .o_desc_count(c_desc), .o_cpl_count(c_cpl), .o_err_count(c_err),
    .o_starve_count(c_starve), .o_stray_count(c_stray), .o_high_water(c_hw)
);

// ---------------------------------------------------------------- head driver
// A queue of frames the "stage" holds. The head is whatever is at hq_rd; a pop
// advances it. Metadata is poisoned the cycle after a pop, like ssr_payload_stage's
// head changes under the writer, so anything the writer reads late is wrong.
localparam integer HQ = 64;
reg [63:0] hq_round [0:HQ-1];
reg [7:0]  hq_node  [0:HQ-1];
reg [15:0] hq_frag  [0:HQ-1];
reg [15:0] hq_len   [0:HQ-1];
reg [SLOT_PTR_W-1:0] hq_slot [0:HQ-1];
integer hq_wr = 0, hq_rd = 0;

task stage_frame(input [63:0] round, input [7:0] node, input [15:0] frag, input [15:0] len);
begin
    hq_round[hq_wr % HQ] = round;
    hq_node [hq_wr % HQ] = node;
    hq_frag [hq_wr % HQ] = frag;
    hq_len  [hq_wr % HQ] = len;
    hq_slot [hq_wr % HQ] = hq_wr[SLOT_PTR_W-1:0];
    hq_wr = hq_wr + 1;
end
endtask

always @(posedge clk) begin
    if (head_pop) hq_rd <= hq_rd + 1;
end
always @* begin
    head_valid = (hq_rd != hq_wr);
    head_round = hq_round[hq_rd % HQ];
    head_node  = hq_node [hq_rd % HQ];
    head_frag  = hq_frag [hq_rd % HQ];
    head_len   = hq_len  [hq_rd % HQ];
    head_slot  = hq_slot [hq_rd % HQ];
    head_addr  = {hq_slot[hq_rd % HQ], 12'd0};
end

// ---------------------------------------------------------------- engine model
localparam integer EQ = 64;
reg [DMA_TAG_WIDTH-1:0]  eq_tag  [0:EQ-1];
reg [DMA_ADDR_WIDTH-1:0] eq_addr [0:EQ-1];
reg [RAM_ADDR_WIDTH-1:0] eq_ram  [0:EQ-1];
reg [DMA_LEN_WIDTH-1:0]  eq_len  [0:EQ-1];
reg [RAM_SEL_WIDTH-1:0]  eq_sel  [0:EQ-1];
integer eq_wr = 0, eq_rd = 0;

always @(posedge clk) if (!rst && d_valid && d_ready) begin
    eq_tag [eq_wr % EQ] <= d_tag;
    eq_addr[eq_wr % EQ] <= d_addr;
    eq_ram [eq_wr % EQ] <= d_ram;
    eq_len [eq_wr % EQ] <= d_len;
    eq_sel [eq_wr % EQ] <= d_sel;
    eq_wr <= eq_wr + 1;
end

task complete(input integer idx, input [3:0] err);
begin
    @(negedge clk);
    st_tag   = eq_tag[idx % EQ];
    st_err   = err;
    st_valid = 1'b1;
    @(posedge clk); @(negedge clk);
    st_valid = 1'b0;
end
endtask

task complete_all(input reverse);
    integer i;
begin
    if (reverse) for (i = eq_wr-1; i >= eq_rd; i = i - 1) complete(i, 4'd0);
    else         for (i = eq_rd; i < eq_wr; i = i + 1)  complete(i, 4'd0);
    eq_rd = eq_wr;
end
endtask

// what the writer must have computed
function [63:0] expect_addr(input [63:0] round, input [7:0] node, input [15:0] frag);
    reg [63:0] region_index;
begin
    region_index = (round[DEPTH_LOG2-1:0] * N) + node;
    expect_addr  = RING_BASE + (region_index << REGION_SHIFT) + ({48'd0, frag} << 12);
end
endfunction

// completions observed at the writer's output
integer n_done = 0, n_err = 0;
reg [SLOT_PTR_W-1:0] last_done_slot;
reg [7:0]  last_err_node;
reg [63:0] last_err_round;
reg [SLOT_PTR_W-1:0] done_log [0:EQ-1];
always @(posedge clk) if (!rst) begin
    if (desc_done) begin done_log[n_done % EQ] <= done_slot; n_done <= n_done + 1; last_done_slot <= done_slot; end
    if (err_valid) begin n_err <= n_err + 1; last_err_node <= err_node; last_err_round <= err_round; end
end

task settle(input integer n); begin repeat (n) @(posedge clk); end endtask

integer i, k, base;
initial begin
    @(negedge rst);
    settle(4);

    // ============================================================ W1
    banner("W1  the address: ring_base + ((round mod D) * N + node) << 15 + (frag << 12)");
    stage_frame(64'd100, 8'd0, 16'd0, 16'd4096);
    stage_frame(64'd100, 8'd2, 16'd3, 16'd4096);
    stage_frame(64'd100 + 64'd256, 8'd1, 16'd1, 16'd164);     // round wraps D_HOST
    stage_frame(64'hFFFF_FFFF_FFFF_FF05, 8'd1, 16'd0, 16'd4096);
    settle(12);
    check(eq_wr == 4, "four descriptors should have reached the engine");
    check(eq_addr[0] == expect_addr(64'd100, 8'd0, 16'd0), "W1 addr of (100, 0, 0)");
    check(eq_addr[1] == expect_addr(64'd100, 8'd2, 16'd3), "W1 addr of (100, 2, 3)");
    check(eq_addr[2] == expect_addr(64'd356, 8'd1, 16'd1), "W1 round 356 must land where round 100 does: mod D_HOST");
    check(eq_addr[2] == eq_addr[0] + (64'd1 << REGION_SHIFT) + (64'd1 << 12),
          "W1 and specifically one region and one page past (100, 0, 0)");
    check(eq_addr[3] == expect_addr(64'hFFFF_FFFF_FFFF_FF05, 8'd1, 16'd0), "W1 only the low bits of round_id matter");
    check(eq_ram[1] == 16'h1000, "W1 ram_addr is the head's addr, unchanged");
    check(eq_len[2] == 16'd164,  "W1 len is the head's len, unchanged");
    check(eq_sel[0] == RAM_SEL,  "W1 ram_sel is the staging RAM's");
    check(eq_tag[0] != eq_tag[1] && eq_tag[1] != eq_tag[2] && eq_tag[0] != eq_tag[2], "W1 tags are distinct");
    check((eq_tag[0] & 16'hFFF0) == TAG_BASE, "W1 tags sit in this pool's space");

    // ============================================================ W2
    banner("W2  completions route the slot back, in whatever order they arrive");
    check(unit_idle[100 % UNIT_COUNT] == 1'b0, "W2 round 100's unit must be busy with three descriptors out");
    complete_all(1'b1);                                    // newest first
    settle(3);
    check(n_done == 4, "W2 four completions should have come back");
    check(done_log[0] == hq_slot[3] && done_log[3] == hq_slot[0], "W2 the slots must come back in completion order, not issue order");
    check(n_err == 0, "W2 no errors were reported");
    check(unit_idle == {UNIT_COUNT{1'b1}}, "W2 every unit idle again");
    check(c_cpl == 32'd4 && c_desc == 32'd4, "W2 counters");

    // ============================================================ W3
    banner("W3  the engine says not-ready: nothing is issued, nothing is lost");
    d_ready = 1'b0;
    base = eq_wr;
    stage_frame(64'd200, 8'd0, 16'd0, 16'd4096);
    stage_frame(64'd200, 8'd0, 16'd1, 16'd4096);
    settle(10);
    check(eq_wr == base, "W3 no descriptor may be taken while ready is low");
    check(d_valid, "W3 but one must be offered, and held");
    check(hq_rd == hq_wr - 1, "W3 exactly one pop: the offered one; the second waits in the stage");
    d_ready = 1'b1;
    settle(6);
    check(eq_wr == base + 2, "W3 both go once ready returns");
    check(eq_addr[base]   == expect_addr(64'd200, 8'd0, 16'd0), "W3 the held descriptor was not corrupted");
    check(eq_addr[base+1] == expect_addr(64'd200, 8'd0, 16'd1), "W3 nor the one after it");
    complete_all(1'b0); settle(3);

    // ============================================================ W4
    banner("W4  no tag: the head is held, not popped, and the wait is counted");
    base = eq_wr;
    for (i = 0; i < TAG_COUNT + 2; i = i + 1) stage_frame(64'd300, 8'd1, i[15:0], 16'd4096);
    settle(20);
    check(eq_wr == base + TAG_COUNT, "W4 exactly TAG_COUNT descriptors may be out at once");
    check(hq_wr - hq_rd == 2, "W4 the two that could not get a tag are still in the stage");
    check(c_starve > 32'd0, "W4 the wait must be counted");
    check(c_hw == TAG_COUNT[2:0], "W4 the high-water mark is the pool size");
    complete(base, 4'd0); eq_rd = base + 1;
    settle(4);
    check(eq_wr == base + TAG_COUNT + 1, "W4 one completion frees one tag and one more goes");
    complete_all(1'b0); settle(3);
    check(hq_rd == hq_wr, "W4 everything eventually goes");

    // ============================================================ W5
    banner("W5  the fence: a unit is idle only when ALL its descriptors have completed");
    base = eq_wr;
    stage_frame(64'd404, 8'd0, 16'd0, 16'd4096);           // unit 0
    stage_frame(64'd404, 8'd2, 16'd0, 16'd4096);           // unit 0
    stage_frame(64'd405, 8'd0, 16'd0, 16'd4096);           // unit 1
    settle(8);
    check(unit_idle[0] == 1'b0 && unit_idle[1] == 1'b0, "W5 units 0 and 1 busy");
    check(unit_idle[2] == 1'b1 && unit_idle[3] == 1'b1, "W5 units 2 and 3 idle");
    complete(base + 2, 4'd0);                              // the unit-1 one
    settle(3);
    check(unit_idle[1] == 1'b1, "W5 unit 1 idle after its one descriptor");
    check(unit_idle[0] == 1'b0, "W5 unit 0 still has two out");
    complete(base + 0, 4'd0);
    settle(3);
    check(unit_idle[0] == 1'b0, "W5 unit 0 still has ONE out - half done is not done");
    complete(base + 1, 4'd0);
    settle(3);
    check(unit_idle[0] == 1'b1, "W5 unit 0 idle only now");
    eq_rd = eq_wr;

    // ============================================================ W6
    banner("W6  a failed DMA: the slot is still released, and the failure is reported by (round, node)");
    base = eq_wr;
    stage_frame(64'd500, 8'd2, 16'd0, 16'd4096);
    settle(6);
    k = n_done;
    complete(base, 4'd3);                                  // error code 3
    settle(3);
    check(n_done == k + 1, "W6 the slot must be released even though the DMA failed");
    check(last_done_slot == hq_slot[hq_rd-1], "W6 the right slot");
    check(n_err == 1, "W6 exactly one error report");
    check(last_err_node == 8'd2, "W6 reported against the node that did not land");
    check(last_err_round == 64'd500, "W6 and its round, whole");
    check(c_err == 32'd1, "W6 counted");
    check(unit_idle[500 % UNIT_COUNT] == 1'b1, "W6 a failed descriptor still completes the fence");
    eq_rd = eq_wr;

    // ============================================================ W7
    banner("W7  a completion for a tag we never issued is ignored and counted");
    k = n_done;
    @(negedge clk); st_tag = TAG_BASE | 16'd2; st_err = 0; st_valid = 1'b1;   // ours by space, but free
    @(posedge clk); @(negedge clk); st_valid = 1'b0;
    @(negedge clk); st_tag = 16'h1234; st_valid = 1'b1;                        // not even our space
    @(posedge clk); @(negedge clk); st_valid = 1'b0;
    settle(3);
    check(n_done == k, "W7 a stray completion must not release anything");
    check(c_stray == 32'd1, "W7 a stray in our tag space is counted; one outside it is simply not ours");

    // ============================================================ W8
    banner("W8  disabled: the head is held");
    enable = 1'b0;
    base = eq_wr;
    stage_frame(64'd600, 8'd0, 16'd0, 16'd4096);
    settle(8);
    check(eq_wr == base && hq_rd == hq_wr - 1, "W8 nothing issues while disabled");
    enable = 1'b1;
    settle(4);
    check(eq_wr == base + 1, "W8 and it goes when enabled");
    complete_all(1'b0); settle(3);

    $display("");
    $display("  tb_ssr_payload_dma_writer: %0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("  PASS"); else $display("  FAIL");
    $finish;
end

initial begin #400000; $display("WATCHDOG"); $display("  FAIL"); $finish; end

endmodule

`resetall
