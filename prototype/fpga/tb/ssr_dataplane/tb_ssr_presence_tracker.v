`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_presence_tracker - the counts behind our ack vector.
 *
 * WHY THIS BENCH EXISTS
 *   Our ack vector comes straight out of this module, and it is what every peer
 *   compares theirs against. A count one too high claims bytes this node does
 *   not hold; a count that moves after the boundary makes what we broadcast
 *   differ from what the verdict record reports. The cases that matter - a gap,
 *   a repeat, a fragment landing just after its round closed, an opening in the
 *   same cycle as a landing, a DMA error - are timing cases a three-node loop
 *   cannot produce on demand, so the module is driven by hand.
 *
 * NEGATIVE CONTROLS (edit rtl/ssr_presence_tracker.v, never this file)
 *   pl_count: drop the "pl_idx_reg == pl_have" term       5 fail (P3: a gap or a repeat counts)
 *   pl_open:  replace with 1'b1                           3 fail (P4: a late fragment counts)
 *   err_hit:  replace the slot_round compare with 1'b1    2 fail (P6: stale error lands)
 *   o_qb_present: drop the "!failed" term                 1 fail (P6)
 *   self_count: drop the "&& self_open" term              2 fail (P5: a late self-send counts)
 */

module tb_ssr_presence_tracker;

localparam integer N        = 3;
localparam integer SELF     = 0;
localparam integer DEPTH    = 4;

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
reg         open = 0;        reg [63:0] open_round = 0;
reg         loc_sent = 0;    reg [63:0] loc_round = 0;
reg         pl_sof = 0;      reg [7:0] pl_node = 0;   reg [63:0] pl_round = 0; reg [15:0] pl_idx = 0;
reg         pl_commit = 0;
reg         err_valid = 0;   reg [63:0] err_round = 0; reg [7:0] err_node = 0;
reg  [63:0] qb_round = 0;
wire [63:0] prev_ack;
wire        qb_hit;
wire [7:0]  qb_present;
wire [127:0] qb_frag;
wire [31:0] late_count, err_count, err_miss_count;

ssr_presence_tracker #(
    .P_NODE_COUNT(N), .P_NODE_ID(SELF), .P_ROUND_DEPTH(DEPTH)
) dut (
    .clk(clk), .rst(rst),
    .i_open(open), .i_open_round_id(open_round),
    .i_local_sent(loc_sent), .i_local_round_id(loc_round),
    .i_pl_sof(pl_sof), .i_pl_node_id(pl_node), .i_pl_round_id(pl_round), .i_pl_frag_idx(pl_idx),
    .i_pl_commit(pl_commit),
    .i_err_valid(err_valid), .i_err_round_id(err_round), .i_err_node(err_node),
    .o_prev_ack(prev_ack),
    .i_qb_round_id(qb_round), .o_qb_hit(qb_hit), .o_qb_present(qb_present), .o_qb_frag_count(qb_frag),
    .o_late_count(late_count), .o_err_count(err_count), .o_err_miss_count(err_miss_count)
);

// ---------------------------------------------------------------- drivers
// Every stimulus is one cycle wide, set on the negedge.
task open_round_t(input [63:0] round);
begin
    @(negedge clk); open = 1; open_round = round;
    @(negedge clk); open = 0;
    @(negedge clk);                 // o_prev_ack is registered
end
endtask

task self_sent(input [63:0] round);
begin
    @(negedge clk); loc_sent = 1; loc_round = round;
    @(negedge clk); loc_sent = 0;
end
endtask

// A fragment: sof, three beats of nothing, commit. The tracker only looks at
// sof and commit.
task fragment(input integer node, input [63:0] round, input integer idx);
begin
    @(negedge clk);
    pl_sof = 1; pl_node = node; pl_round = round; pl_idx = idx;
    @(negedge clk);
    pl_sof = 0;
    repeat (3) @(negedge clk);
    pl_commit = 1;
    @(negedge clk);
    pl_commit = 0;
end
endtask

task dma_error(input [63:0] round, input integer node);
begin
    @(negedge clk); err_valid = 1; err_round = round; err_node = node;
    @(negedge clk); err_valid = 0;
end
endtask

task query(input [63:0] round);
begin
    qb_round = round;
    #1;
end
endtask

function [15:0] cnt(input integer node);
    cnt = qb_frag[node*16 +: 16];
endfunction

function [63:0] ack3(input [7:0] a0, input [7:0] a1, input [7:0] a2);
    ack3 = {40'd0, a2, a1, a0};
endfunction

initial begin
    @(negedge rst);
    repeat (2) @(posedge clk);

    $display("---- P1  a round counts from zero once it opens; nothing before");
    query(64'd10);
    check(!qb_hit && prev_ack == 64'd0, "nothing is held before the first opening");
    fragment(1, 64'd10, 0);
    check(late_count == 32'd1, "a fragment before any round opened is late");
    open_round_t(64'd10);
    query(64'd10);
    check(qb_hit && qb_frag == 128'd0 && qb_present == 8'b111, "round 10: held, all zero, all intact");
    check(prev_ack == 64'd0, "round 9 was never held: our ack is zero");

    $display("---- P2  peers and self count up; the ack is the previous round's vector");
    self_sent(64'd10); self_sent(64'd10);
    fragment(1, 64'd10, 0); fragment(1, 64'd10, 1); fragment(1, 64'd10, 2);
    fragment(2, 64'd10, 0);
    query(64'd10);
    check(cnt(0) == 2 && cnt(1) == 3 && cnt(2) == 1, "round 10 counts: self 2, node 1 three, node 2 one");
    check(prev_ack == 64'd0, "the open round is not in our ack yet");
    open_round_t(64'd11);
    check(prev_ack == ack3(8'd2, 8'd3, 8'd1), "after the boundary our ack is round 10's vector");
    query(64'd10);
    check(cnt(0) == 2 && cnt(1) == 3 && cnt(2) == 1, "query B reports the same counts for round 10");

    $display("---- P3  the count is a prefix: a gap stops it, a repeat does not add");
    fragment(1, 64'd11, 0);
    fragment(1, 64'd11, 2);            // fragment 1 was lost
    fragment(1, 64'd11, 3);
    query(64'd11);
    check(cnt(1) == 1, "after a gap nothing more counts");
    fragment(2, 64'd11, 0);
    fragment(2, 64'd11, 0);            // a repeat
    query(64'd11);
    check(cnt(2) == 1, "a repeat of fragment 0 is not a second fragment");
    fragment(2, 64'd11, 1);
    query(64'd11);
    check(cnt(2) == 2, "the next in order still counts after a repeat");

    $display("---- P4  only the open round counts: a fragment landing after its boundary is late");
    open_round_t(64'd12);
    fragment(1, 64'd11, 1);            // round 11 is no longer open
    query(64'd11);
    check(cnt(1) == 1, "a late fragment does not change round 11's count");
    check(late_count == 32'd2, "and is counted as late");
    check(prev_ack == ack3(8'd0, 8'd1, 8'd2), "our ack about round 11 is unchanged");

    $display("---- P5  our own sends count only in the open round");
    self_sent(64'd12);
    self_sent(64'd11);                 // tx still naming the round just closed
    query(64'd12);
    check(cnt(0) == 1, "one self-send in round 12");
    check(late_count == 32'd3, "a self-send for round 11 is late");
    query(64'd11);
    check(cnt(0) == 0, "and does not move round 11");

    $display("---- P6  a DMA error clears one present bit and leaves the count");
    fragment(1, 64'd12, 0);
    dma_error(64'd12, 1);
    query(64'd12);
    check(qb_present == 8'b101, "node 1 not present on this host after the error");
    check(cnt(1) == 1, "its count is what arrived, unchanged");
    check(err_count == 32'd1, "one error counted");
    open_round_t(64'd13);
    check(prev_ack == ack3(8'd1, 8'd1, 8'd0), "the ack reports the wire, not the DMA");
    open_round_t(64'd14);              // 14 mod 4 == 10 mod 4: round 10 is gone
    dma_error(64'd10, 2);
    query(64'd14);
    check(qb_present == 8'b111, "an error for evicted round 10 leaves round 14 alone");
    check(err_miss_count == 32'd1, "and is counted as a miss");

    $display("---- P7  opening a round clears the slot it reuses");
    query(64'd10);
    check(!qb_hit, "round 10 no longer hits");
    query(64'd14);
    check(qb_hit && qb_frag == 128'd0, "round 14 starts at zero, round 10's counts did not leak");

    $display("---- P8  a fragment landing on the boundary cycle counts into its own round");
    @(negedge clk);
    pl_sof = 1; pl_node = 2; pl_round = 64'd14; pl_idx = 0;
    @(negedge clk);
    pl_sof = 0;
    repeat (2) @(negedge clk);
    pl_commit = 1; open = 1; open_round = 64'd15;
    @(negedge clk);
    pl_commit = 0; open = 0;
    @(negedge clk);
    query(64'd14);
    check(cnt(2) == 1, "counted into round 14, which was still open on that edge");
    check(prev_ack == ack3(8'd0, 8'd0, 8'd1), "and the ack about 14 includes it");

    $display("---- P9  reset forgets every round");
    @(negedge clk); rst = 1; @(negedge clk); rst = 0;
    @(negedge clk);
    query(64'd14);
    check(!qb_hit && prev_ack == 64'd0 && late_count == 32'd0, "nothing is held after reset");

    $display("");
    $display("  tb_ssr_presence_tracker: %0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("  PASS"); else $display("  FAIL");
    $finish;
end

initial begin #100000; $display("WATCHDOG"); $display("  FAIL"); $finish; end

endmodule

`resetall
