`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_verdict_dma_writer - one record per decision, after the fence, with the
 * bytes the host expects where it expects them.
 *
 * WHY THIS BENCH EXISTS
 *   The record is the host's permission to read pages that were DMA'd
 *   speculatively. A record that overtakes its pages, or names a page that
 *   failed, or lands in the wrong ring entry, is a silent data fault on the
 *   host that no counter here would show. So the bench is a DMA engine model
 *   that fetches the record through the RAM read port exactly as Corundum's
 *   would, and checks every byte of what it fetched.
 *
 * NEGATIVE CONTROLS (edit rtl/ssr_verdict_dma_writer.v, never this file)
 *   fence_open = 1'b1                                   V2 fails (record before the pages)
 *   be64 -> identity                                    V1 fails (byte order)
 *   seq_reg not incremented                             V3 fails (all records at entry 0)
 *   ring_offset: whole seq, not seq mod D               V8 fails (falls off the ring)
 *   q_full = 1'b0                                       V4 fails (overflow never counted)
 *   cpl_hit without the tag compare                     V6 fails (a stray completes us)
 *   cpl_err not counted                                 V5 fails
 *   present_set <= i_q_present without the hit gate     V7 fails
 *   S_IDLE: drop the i_enable term                      V9 fails
 *   read port: gs*RAM_SEG_DATA_WIDTH -> 0               V1 fails (segment 1 never answers)
 */

module tb_ssr_verdict_dma_writer;

localparam integer DMA_ADDR_WIDTH = 64;
localparam integer DMA_LEN_WIDTH  = 16;
// The AU200's app DMA geometry: 13-bit tags, a 1-bit ram_sel, and a RAM row
// of two 512-bit segments - so the 64-byte record is exactly one segment.
localparam integer DMA_TAG_WIDTH  = 13;
localparam integer RAM_SEL_WIDTH  = 1;
localparam integer RAM_ADDR_WIDTH = 17;
localparam integer SEG_COUNT      = 2;
localparam integer SEG_DW         = 512;
localparam integer SEG_AW         = RAM_ADDR_WIDTH - 7;
localparam integer N              = 3;
localparam integer SELF           = 1;
localparam integer UNIT_COUNT     = 4;
localparam integer DEPTH_LOG2     = 2;      // a 4-entry ring, so the wrap is reachable
localparam integer QUEUE_DEPTH    = 4;
localparam [0:0]   RAM_SEL        = 1'b1;
localparam [12:0]  TAG            = 13'd16;
localparam [63:0]  BASE           = 64'h0000_0001_2340_0000;

`include "ssr_verdict.vh"

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

// ---------------------------------------------------------------- DUT
reg          enable = 1'b1;
reg          commit_valid = 1'b0;
reg  [63:0]  commit_round = 64'd0;
reg  [7:0]   commit_set = 8'd0;
reg  [31:0]  run_id = 32'h0000_0BAD;
reg  [31:0]  prop_consumer = 32'hC0DE_0042;   // passed through to the record
reg  [UNIT_COUNT-1:0] unit_idle = {UNIT_COUNT{1'b1}};

wire [63:0]  q_round;
reg          q_hit = 1'b1;
reg  [7:0]   q_present = 8'd0;
reg  [127:0] q_frag = 128'd0;

wire [63:0]  desc_addr;
wire [RAM_SEL_WIDTH-1:0]  desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0] desc_ram_addr;
wire [15:0]  desc_len;
wire [DMA_TAG_WIDTH-1:0]  desc_tag;
wire         desc_valid;
reg          desc_ready = 1'b1;

reg  [DMA_TAG_WIDTH-1:0] cpl_tag = 0;
reg  [3:0]   cpl_err = 4'd0;
reg          cpl_valid = 1'b0;

reg  [SEG_COUNT*SEG_AW-1:0] rd_addr = 0;
reg  [SEG_COUNT-1:0]        rd_valid = 0;
wire [SEG_COUNT-1:0]        rd_ready;
wire [SEG_COUNT*SEG_DW-1:0] rd_data;
wire [SEG_COUNT-1:0]        rd_resp_valid;
reg  [SEG_COUNT-1:0]        rd_resp_ready = {SEG_COUNT{1'b1}};

wire [63:0] seq;
wire [31:0] record_count, err_count, overflow_count, stale_count;

ssr_verdict_dma_writer #(
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH), .DMA_LEN_WIDTH(DMA_LEN_WIDTH), .DMA_TAG_WIDTH(DMA_TAG_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH), .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(SEG_COUNT), .RAM_SEG_DATA_WIDTH(SEG_DW), .RAM_SEG_ADDR_WIDTH(SEG_AW),
    .P_RAM_SEL(RAM_SEL), .P_TAG(TAG), .P_NODE_COUNT(N), .P_NODE_ID(SELF),
    .UNIT_COUNT(UNIT_COUNT), .P_HOST_DEPTH_LOG2(DEPTH_LOG2), .QUEUE_DEPTH(QUEUE_DEPTH)
) dut (
    .clk(clk), .rst(rst),
    .i_enable(enable), .i_ring_base(BASE),
    .i_commit_valid(commit_valid), .i_commit_round_id(commit_round), .i_commit_set(commit_set), .i_run_id(run_id), .i_prop_consumer(prop_consumer),
    .i_unit_idle(unit_idle),
    .o_q_round_id(q_round), .i_q_hit(q_hit), .i_q_present(q_present), .i_q_frag_count(q_frag),
    .m_axis_dma_write_desc_dma_addr(desc_addr), .m_axis_dma_write_desc_ram_sel(desc_ram_sel),
    .m_axis_dma_write_desc_ram_addr(desc_ram_addr), .m_axis_dma_write_desc_len(desc_len),
    .m_axis_dma_write_desc_tag(desc_tag), .m_axis_dma_write_desc_valid(desc_valid),
    .m_axis_dma_write_desc_ready(desc_ready),
    .s_axis_dma_write_desc_status_tag(cpl_tag), .s_axis_dma_write_desc_status_error(cpl_err),
    .s_axis_dma_write_desc_status_valid(cpl_valid),
    .dma_ram_rd_cmd_addr(rd_addr), .dma_ram_rd_cmd_valid(rd_valid), .dma_ram_rd_cmd_ready(rd_ready),
    .dma_ram_rd_resp_data(rd_data), .dma_ram_rd_resp_valid(rd_resp_valid), .dma_ram_rd_resp_ready(rd_resp_ready),
    .o_seq(seq), .o_record_count(record_count), .o_err_count(err_count),
    .o_overflow_count(overflow_count), .o_stale_count(stale_count)
);

// ---------------------------------------------------------------- engine model
// Takes a descriptor, reads the record, then reports the completion. The
// record is one segment; the model asks both, and both must answer with it
// (the engine asks whichever segment the address falls in). What it fetched is kept for the checks. It does not
// complete on its own - the test says when, and with what error, so the
// waiting is observable.
reg  [63:0] got_addr = 0;
reg  [15:0] got_len = 0;
reg  [DMA_TAG_WIDTH-1:0] got_tag = 0;
reg  [RAM_SEL_WIDTH-1:0] got_sel = 0;
reg  [SEG_COUNT*SEG_DW-1:0] got_row = 0;
wire [511:0] got_record = got_row[0 +: 512];
integer     desc_seen = 0;

always @(posedge clk) begin
    if (desc_valid && desc_ready) begin
        got_addr <= desc_addr; got_len <= desc_len; got_tag <= desc_tag; got_sel <= desc_ram_sel;
        desc_seen <= desc_seen + 1;
    end
end

// The response side of the port, watched continuously: a response is one
// cycle wide when the engine is ready, so it has to be caught on the edge it
// is handed over, not looked for afterwards.
reg  [SEG_COUNT-1:0] seg_got = 0;
integer ms;
always @(posedge clk) begin
    for (ms = 0; ms < SEG_COUNT; ms = ms + 1)
        if (rd_resp_valid[ms] && rd_resp_ready[ms]) begin
            got_row[ms*SEG_DW +: SEG_DW] <= rd_data[ms*SEG_DW +: SEG_DW];
            seg_got[ms] <= 1'b1;
        end
end

// Fetch the record: one command per segment, as the engine would for one row.
task fetch_record;
    integer s, guard;
begin
    @(negedge clk);
    seg_got  = 0;
    rd_addr  = 0;
    rd_valid = {SEG_COUNT{1'b1}};
    guard = 0;
    while (rd_valid != 0 && guard < 50) begin
        @(posedge clk);
        for (s = 0; s < SEG_COUNT; s = s + 1)
            if (rd_valid[s] && rd_ready[s]) rd_valid[s] <= 1'b0;
        guard = guard + 1;
    end
    guard = 0;
    while (seg_got != {SEG_COUNT{1'b1}} && guard < 50) begin
        @(posedge clk); #1;
        guard = guard + 1;
    end
    check(seg_got == {SEG_COUNT{1'b1}}, "the read port answered both segments");
    check(got_row[SEG_DW +: SEG_DW] === got_row[0 +: SEG_DW], "both segments answer with the record");
end
endtask

task complete(input [DMA_TAG_WIDTH-1:0] tag, input [3:0] err);
begin
    @(negedge clk);
    cpl_tag = tag; cpl_err = err; cpl_valid = 1'b1;
    @(negedge clk);
    cpl_valid = 1'b0;
end
endtask

task commit(input [63:0] round, input [7:0] set);
begin
    @(negedge clk);
    commit_valid = 1'b1; commit_round = round; commit_set = set;
    @(negedge clk);
    commit_valid = 1'b0;
end
endtask

task wait_desc(input integer expect_seen);
    integer guard;
begin
    guard = 0;
    while (desc_seen < expect_seen && guard < 100) begin @(posedge clk); #1; guard = guard + 1; end
    check(desc_seen == expect_seen, "a descriptor should have been issued by now");
end
endtask

function [63:0] be64(input [63:0] v);
    be64 = {v[7:0], v[15:8], v[23:16], v[31:24], v[39:32], v[47:40], v[55:48], v[63:56]};
endfunction
function [31:0] be32(input [31:0] v); be32 = {v[7:0], v[15:8], v[23:16], v[31:24]}; endfunction
function [15:0] be16(input [15:0] v); be16 = {v[7:0], v[15:8]}; endfunction

// Every field of the fetched record against what the test set up.
task check_record(input [63:0] round, input [63:0] expect_seq, input [7:0] set,
                  input [7:0] present, input [127:0] frag);
    integer k;
begin
    check(got_record[SSRV_OFF_ROUND_ID*8    +: 64] == be64(round),      "record: round_id, big-endian");
    check(got_record[SSRV_OFF_SEQ*8         +: 64] == be64(expect_seq), "record: seq");
    check(got_record[SSRV_OFF_RUN_ID*8      +: 32] == be32(run_id),     "record: run_id");
    check(got_record[SSRV_OFF_COMMIT_SET*8  +: 8]  == set,              "record: commit_set");
    check(got_record[SSRV_OFF_PRESENT_SET*8 +: 8]  == present,          "record: present_set");
    check(got_record[SSRV_OFF_NODE_COUNT*8  +: 8]  == N[7:0],           "record: node_count");
    check(got_record[SSRV_OFF_SELF_INDEX*8  +: 8]  == SELF[7:0],        "record: self_index");
    for (k = 0; k < 8; k = k + 1)
        check(got_record[(SSRV_OFF_FRAG_COUNTS+2*k)*8 +: 16] == be16(frag[k*16 +: 16]),
              "record: a frag_count entry");
    check(got_record[SSRV_OFF_PROP_CONSUMER*8 +: 32] == {prop_consumer[7:0], prop_consumer[15:8], prop_consumer[23:16], prop_consumer[31:24]},
          "record: proposal_consumer, big-endian");
    check(got_record[SSRV_OFF_RESERVED*8 +: SSRV_RESERVED_BYTES*8] == 0, "record: reserved bytes are zero");
end
endtask

integer i;
initial begin
    @(negedge rst);
    repeat (2) @(posedge clk);

    $display("---- V1  one decision, fence open: one record, every byte in place");
    q_hit = 1; q_present = 8'b011; q_frag = {16'd0,16'd0,16'd0,16'd0,16'd0, 16'd7, 16'd2, 16'd0};
    commit(64'd10, 8'b011);
    wait_desc(1);
    check(got_addr == BASE, "record 0 goes to ring entry 0");
    check(got_len == 16'd64 && got_sel == RAM_SEL && got_tag == TAG, "len 64, our ram_sel, our tag");
    check(q_round == 64'd10, "the tracker was asked about the committed round");
    fetch_record;
    check_record(64'd10, 64'd0, 8'b011, 8'b011, q_frag);
    check(record_count == 32'd0 && seq == 64'd0, "nothing is counted until the completion");
    complete(TAG, 4'd0);
    check(record_count == 32'd1 && seq == 64'd1 && err_count == 32'd0, "one record, seq 1");

    $display("---- V2  the fence: no record while the round's pages are in flight");
    unit_idle[11 % UNIT_COUNT] = 1'b0;
    q_present = 8'b001;                       // what the tracker says at commit time
    commit(64'd11, 8'b111);
    repeat (20) @(posedge clk); #1;
    check(desc_seen == 1, "no descriptor while the unit is busy");
    check(q_round == 64'd11, "the head round is being asked about meanwhile");
    q_present = 8'b111;                       // the last page lands, then the fence opens
    @(negedge clk); unit_idle[11 % UNIT_COUNT] = 1'b1;
    wait_desc(2);
    check(got_addr == BASE + 64, "record 1 goes to ring entry 1");
    fetch_record;
    check_record(64'd11, 64'd1, 8'b111, 8'b111, q_frag);   // present as of the fence, not the commit
    complete(TAG, 4'd0);

    $display("---- V3  decisions queue up and go out in order, one at a time");
    commit(64'd12, 8'b001);
    commit(64'd13, 8'b010);
    commit(64'd14, 8'b100);
    wait_desc(3);
    repeat (10) @(posedge clk); #1;
    check(desc_seen == 3, "the second record waits for the first's completion");
    check(got_addr == BASE + 128, "record 2 at entry 2");
    fetch_record; check_record(64'd12, 64'd2, 8'b001, 8'b111, q_frag);
    complete(TAG, 4'd0);
    wait_desc(4);
    check(got_addr == BASE + 192, "record 3 at entry 3");
    fetch_record; check_record(64'd13, 64'd3, 8'b010, 8'b111, q_frag);
    complete(TAG, 4'd0);
    $display("---- V8  ...and the fifth record wraps to entry 0");
    wait_desc(5);
    check(got_addr == BASE, "record 4 wraps to entry 0 of a 4-entry ring");
    fetch_record; check_record(64'd14, 64'd4, 8'b100, 8'b111, q_frag);
    complete(TAG, 4'd0);
    check(record_count == 32'd5 && seq == 64'd5, "five records");

    $display("---- V4  a full queue drops the decision and counts it");
    unit_idle = {UNIT_COUNT{1'b0}};
    for (i = 0; i < QUEUE_DEPTH + 1; i = i + 1) commit(64'd20 + i, 8'b111);
    check(overflow_count == 32'd1, "the fifth decision into a four-deep queue overflows");
    unit_idle = {UNIT_COUNT{1'b1}};
    for (i = 0; i < QUEUE_DEPTH; i = i + 1) begin
        wait_desc(6 + i);
        fetch_record;
        check(got_record[SSRV_OFF_ROUND_ID*8 +: 64] == be64(64'd20 + i), "the queued rounds go out in order");
        complete(TAG, 4'd0);
    end
    repeat (10) @(posedge clk); #1;
    check(desc_seen == 9 && record_count == 32'd9, "exactly four records for four queued decisions");

    $display("---- V5  a DMA error is counted; the writer moves on");
    commit(64'd30, 8'b111);
    wait_desc(10);
    fetch_record;
    complete(TAG, 4'd3);
    check(err_count == 32'd1 && record_count == 32'd10 && seq == 64'd10, "error counted, record counted, seq advanced");

    $display("---- V6  a completion with someone else's tag is not ours");
    commit(64'd31, 8'b111);
    wait_desc(11);
    fetch_record;
    complete(TAG ^ 13'h0001, 4'd0);
    repeat (5) @(posedge clk); #1;
    check(record_count == 32'd10, "a stray completion does not complete our record");
    commit(64'd32, 8'b111);
    repeat (10) @(posedge clk); #1;
    check(desc_seen == 11, "and the next record still waits");
    complete(TAG, 4'd0);
    check(record_count == 32'd11, "the real completion does");
    wait_desc(12); fetch_record; complete(TAG, 4'd0);

    $display("---- V7  a round the tracker no longer holds: nobody present, counts zero");
    q_hit = 0;
    commit(64'd40, 8'b111);
    wait_desc(13);
    fetch_record;
    check_record(64'd40, 64'd12, 8'b111, 8'd0, 128'd0);
    check(stale_count == 32'd1, "counted as stale");
    complete(TAG, 4'd0);
    q_hit = 1;

    $display("---- V9  disabled: decisions wait in the queue, nothing is issued");
    enable = 1'b0;
    commit(64'd50, 8'b111);
    repeat (20) @(posedge clk); #1;
    check(desc_seen == 13, "no descriptor while disabled");
    enable = 1'b1;
    wait_desc(14);
    fetch_record;
    check(got_record[SSRV_OFF_ROUND_ID*8 +: 64] == be64(64'd50), "the queued decision goes out on enable");
    complete(TAG, 4'd0);

    $display("---- V10 the read port holds its answer while the engine is not ready");
    commit(64'd51, 8'b101);
    wait_desc(15);
    rd_resp_ready = 2'b00;
    @(negedge clk); rd_valid = 2'b11; rd_addr = 0;
    @(negedge clk); rd_valid = 2'b00;
    repeat (5) @(posedge clk); #1;
    check(rd_resp_valid == 2'b11, "both responses stand while resp_ready is low");
    check(rd_data[SSRV_OFF_ROUND_ID*8 +: 64] == be64(64'd51), "and carry the current record");
    check(rd_ready == 2'b00, "no further command is accepted meanwhile");
    rd_resp_ready = 2'b11;
    @(posedge clk); #1;
    check(rd_resp_valid == 2'b00, "drained once ready");
    complete(TAG, 4'd0);

    $display("");
    $display("  tb_ssr_verdict_dma_writer: %0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("  PASS"); else $display("  FAIL");
    $finish;
end

initial begin #200000; $display("WATCHDOG"); $display("  FAIL"); $finish; end

endmodule

`resetall
