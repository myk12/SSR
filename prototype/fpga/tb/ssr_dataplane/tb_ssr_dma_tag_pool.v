`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_dma_tag_pool - the fence, on its own, before anything depends on it
 *
 * docs/speculative_delivery.md section 13 says this is the piece to build
 * carefully: everything downstream assumes the fence is correct, and a fence
 * that is subtly wrong produces a bug that only appears under load and looks
 * like a peer problem.
 *
 * The tests that matter are T3 (out-of-order completions) and T7 (allocate and
 * complete the same unit in one cycle). An in-order, non-colliding bench would
 * let a broken pool pass, which is exactly the trap this file exists to avoid.
 */

module tb_ssr_dma_tag_pool;

localparam integer TAG_COUNT  = 8;
localparam integer TAG_WIDTH  = 16;
localparam [15:0]  TAG_BASE   = 16'h0040;   // id field is bits [2:0]
localparam integer UNIT_COUNT = 4;
localparam integer META_WIDTH = 8;

localparam integer ID_W       = 3;
localparam integer UNIT_SEL_W = 2;
localparam integer TAG_CNT_W  = 4;

localparam integer CLK_PERIOD = 4;

// ---------------------------------------------------------------- clock / reset
reg clk = 1'b0;
reg rst = 1'b1;
always #(CLK_PERIOD/2) clk = ~clk;

initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
end

// ---------------------------------------------------------------- DUT
reg                   alloc_valid = 1'b0;
reg  [UNIT_SEL_W-1:0] alloc_unit  = 0;
reg  [META_WIDTH-1:0] alloc_meta  = 0;
wire                  alloc_ready;
wire [TAG_WIDTH-1:0]  alloc_tag;

reg                   cpl_valid = 1'b0;
reg  [TAG_WIDTH-1:0]  cpl_tag   = 0;
reg  [3:0]            cpl_error = 4'd0;
wire                  cpl_hit;
wire [UNIT_SEL_W-1:0] cpl_unit;
wire [META_WIDTH-1:0] cpl_meta;
wire                  cpl_err_o;

wire [UNIT_COUNT-1:0] unit_idle;
wire [31:0]           n_alloc, n_cpl, n_err, n_stray, n_starve;
wire [TAG_CNT_W-1:0]  n_high;

ssr_dma_tag_pool #(
    .TAG_COUNT  (TAG_COUNT),
    .TAG_WIDTH  (TAG_WIDTH),
    .TAG_BASE   (TAG_BASE),
    .UNIT_COUNT (UNIT_COUNT),
    .META_WIDTH (META_WIDTH)
) dut (
    .clk           (clk),
    .rst           (rst),
    .i_alloc_valid (alloc_valid),
    .i_alloc_unit  (alloc_unit),
    .i_alloc_meta  (alloc_meta),
    .o_alloc_ready (alloc_ready),
    .o_alloc_tag   (alloc_tag),
    .i_cpl_valid   (cpl_valid),
    .i_cpl_tag     (cpl_tag),
    .i_cpl_error   (cpl_error),
    .o_cpl_hit     (cpl_hit),
    .o_cpl_unit    (cpl_unit),
    .o_cpl_meta    (cpl_meta),
    .o_cpl_error   (cpl_err_o),
    .o_unit_idle   (unit_idle),
    .o_alloc_count (n_alloc),
    .o_cpl_count   (n_cpl),
    .o_err_count   (n_err),
    .o_stray_count (n_stray),
    .o_starve_count(n_starve),
    .o_high_water  (n_high)
);

// ---------------------------------------------------------------- bookkeeping
integer checks = 0;
integer errors = 0;

task check(input cond, input [8*96-1:0] msg);
begin
    checks = checks + 1;
    if (!cond) begin
        errors = errors + 1;
        $display("  \033[31mFAIL\033[0m [%0t] %0s", $time, msg);
    end
end
endtask

task banner(input [8*96-1:0] msg);
begin
    $display("");
    $display("---- %0s", msg);
end
endtask

// ---------------------------------------------------------------- drivers
// alloc_do returns the tag the pool handed out. o_alloc_tag is combinational,
// so it is sampled BEFORE the edge that consumes it.
task alloc_do(input [UNIT_SEL_W-1:0] u, input [META_WIDTH-1:0] m, output [TAG_WIDTH-1:0] t);
begin
    @(negedge clk);
    alloc_valid = 1'b1;
    alloc_unit  = u;
    alloc_meta  = m;
    #0;
    t = alloc_tag;
    @(posedge clk);
    @(negedge clk);
    alloc_valid = 1'b0;
end
endtask

task cpl_do(input [TAG_WIDTH-1:0] t, input [3:0] e);
begin
    @(negedge clk);
    cpl_valid = 1'b1;
    cpl_tag   = t;
    cpl_error = e;
    @(posedge clk);
    @(negedge clk);
    cpl_valid = 1'b0;
    cpl_error = 4'd0;
end
endtask

// ---------------------------------------------------------------- watchdog
initial begin
    #200000;
    $display("");
    $display("\033[31mTIMEOUT\033[0m - the bench never finished");
    $finish;
end

// ---------------------------------------------------------------- tests
reg [TAG_WIDTH-1:0] t0, t1, t2, t3, tx;
reg [TAG_WIDTH-1:0] held [0:TAG_COUNT-1];
integer k;
reg seen_dup;
integer j;

initial begin : main
    @(negedge rst);
    repeat (2) @(posedge clk);

    // ------------------------------------------------------------------ T1
    banner("T1  allocate: distinct tags, correct base, ready falls when full");
    seen_dup = 1'b0;
    for (k = 0; k < TAG_COUNT; k = k + 1) begin
        check(alloc_ready, "pool said full before TAG_COUNT allocations");
        alloc_do(k[UNIT_SEL_W-1:0] & 2'b11, k[META_WIDTH-1:0], held[k]);
        check((held[k] & ~{{(TAG_WIDTH-ID_W){1'b0}}, {ID_W{1'b1}}}) == TAG_BASE,
              "issued tag does not carry TAG_BASE");
        for (j = 0; j < k; j = j + 1)
            if (held[j] == held[k]) seen_dup = 1'b1;
    end
    check(!seen_dup, "the pool issued the same tag twice");
    check(!alloc_ready, "pool still ready after TAG_COUNT allocations");
    check(n_alloc == TAG_COUNT, "alloc_count wrong");
    check(n_high == TAG_COUNT, "high_water did not reach TAG_COUNT");

    // asking while full must be counted, not silently ignored
    @(negedge clk); alloc_valid = 1'b1; @(posedge clk); @(negedge clk); alloc_valid = 1'b0;
    check(n_starve == 1, "an allocation request while full was not counted");

    // ------------------------------------------------------------------ T2
    banner("T2  the fence: a unit is busy from allocation until its last completion");
    // Units 0..3 each hold two tags (k and k+4 map to units 0..3 twice).
    check(unit_idle == 4'b0000, "every unit should be busy here");
    for (k = 0; k < TAG_COUNT; k = k + 1)
        cpl_do(held[k], 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle == 4'b1111, "every unit should be idle after all completions");
    check(n_cpl == TAG_COUNT, "cpl_count wrong");
    check(alloc_ready, "tags were not returned to the free list");

    // ------------------------------------------------------------------ T3
    banner("T3  completions accepted OUT OF ORDER");
    alloc_do(2'd1, 8'hA1, t0);
    alloc_do(2'd1, 8'hA2, t1);
    alloc_do(2'd1, 8'hA3, t2);
    repeat (2) @(posedge clk);
    check(unit_idle[1] == 1'b0, "unit 1 should be busy with three descriptors");

    cpl_do(t2, 4'd0);                       // last issued, first completed
    repeat (2) @(posedge clk);
    check(unit_idle[1] == 1'b0, "unit 1 went idle with two descriptors still out");
    cpl_do(t0, 4'd0);                       // middle
    repeat (2) @(posedge clk);
    check(unit_idle[1] == 1'b0, "unit 1 went idle with one descriptor still out");
    cpl_do(t1, 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle[1] == 1'b1, "unit 1 did not go idle after the last completion");

    // ------------------------------------------------------------------ T4
    banner("T4  units are independent");
    alloc_do(2'd0, 8'h10, t0);
    alloc_do(2'd3, 8'h30, t3);
    repeat (2) @(posedge clk);
    check(unit_idle == 4'b0110, "only units 0 and 3 should be busy");
    cpl_do(t0, 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle == 4'b0111, "unit 0 should be idle, unit 3 still busy");
    cpl_do(t3, 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle == 4'b1111, "both units should be idle");

    // ------------------------------------------------------------------ T5
    banner("T5  an error is reported once, on the right unit, with the right meta");
    alloc_do(2'd2, 8'h5C, t0);
    @(negedge clk);
    cpl_valid = 1'b1; cpl_tag = t0; cpl_error = 4'd3;
    #0;
    check(cpl_hit,                "completion for an outstanding tag did not hit");
    check(cpl_unit == 2'd2,       "completion reported the wrong unit");
    check(cpl_meta == 8'h5C,      "completion reported the wrong meta");
    check(cpl_err_o,              "a non-zero error code was not reported");
    @(posedge clk); @(negedge clk);
    cpl_valid = 1'b0; cpl_error = 4'd0;
    repeat (2) @(posedge clk);
    check(n_err == 1,             "error was not counted exactly once");
    check(unit_idle[2] == 1'b1,   "a failed descriptor must still free its unit");

    // ------------------------------------------------------------------ T6
    banner("T6  a stray completion is counted and changes nothing else");
    alloc_do(2'd0, 8'h77, t0);
    repeat (2) @(posedge clk);
    // same TAG_BASE, an id we do not hold
    tx = TAG_BASE | ((t0[ID_W-1:0] + 3'd1) & 3'b111);
    if (tx == t0) tx = TAG_BASE | ((t0[ID_W-1:0] + 3'd2) & 3'b111);
    cpl_do(tx, 4'd0);
    repeat (2) @(posedge clk);
    check(n_stray == 1,           "a completion for a tag we never issued was not counted");
    check(unit_idle[0] == 1'b0,   "a stray completion wrongly cleared a live unit");
    // a foreign TAG_BASE must not even be looked at
    cpl_do(16'h0800, 4'd0);
    repeat (2) @(posedge clk);
    check(n_stray == 1,           "a completion from another pool's tag space was claimed");
    cpl_do(t0, 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle[0] == 1'b1,   "unit 0 did not go idle");

    // ------------------------------------------------------------------ T7
    banner("T7  allocate and complete the SAME unit in one cycle");
    alloc_do(2'd1, 8'hE1, t0);
    repeat (2) @(posedge clk);
    check(unit_idle[1] == 1'b0, "unit 1 should be busy");

    // one in, one out, same edge: the count must not move, and the unit must
    // NOT appear idle - there is still exactly one descriptor outstanding.
    @(negedge clk);
    alloc_valid = 1'b1; alloc_unit = 2'd1; alloc_meta = 8'hE2;
    #0; t1 = alloc_tag;
    cpl_valid = 1'b1; cpl_tag = t0; cpl_error = 4'd0;
    @(posedge clk);
    @(negedge clk);
    alloc_valid = 1'b0; cpl_valid = 1'b0;
    repeat (2) @(posedge clk);
    check(unit_idle[1] == 1'b0, "simultaneous alloc+completion wrongly opened the fence");
    check(t1 != t0,             "the pool reused a tag in the same cycle it was freed");
    cpl_do(t1, 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle[1] == 1'b1, "unit 1 did not go idle after the second completion");

    // ------------------------------------------------------------------ T8
    banner("T8  negative control: the fence really does gate");
    // If o_unit_idle were wired to a constant 1 - the shape of a broken fence -
    // every assertion above that expects a LOW would pass anyway. This restates
    // one of them as an explicit count so a constant-1 implementation is caught.
    alloc_do(2'd3, 8'h01, t0);
    alloc_do(2'd3, 8'h02, t1);
    repeat (2) @(posedge clk);
    check(unit_idle[3] === 1'b0, "fence open with two descriptors outstanding (constant-1 fence?)");
    cpl_do(t0, 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle[3] === 1'b0, "fence open with one descriptor outstanding");
    cpl_do(t1, 4'd0);
    repeat (2) @(posedge clk);
    check(unit_idle[3] === 1'b1, "fence never closed (constant-0 fence?)");

    // ------------------------------------------------------------------ report
    $display("");
    $display("================================================================");
    $display("  tb_ssr_dma_tag_pool: %0d checks, %0d failures", checks, errors);
    $display("  alloc=%0d cpl=%0d err=%0d stray=%0d starve=%0d high_water=%0d",
             n_alloc, n_cpl, n_err, n_stray, n_starve, n_high);
    if (errors == 0) $display("  \033[32mPASS\033[0m");
    else             $display("  \033[31mFAIL\033[0m");
    $display("================================================================");
    $finish;
end

// ---------------------------------------------------------------- waveform
initial begin
    if (!$test$plusargs("nodump")) begin
        $dumpfile("build/tb_ssr_dma_tag_pool.vcd");
        $dumpvars(0, tb_ssr_dma_tag_pool);
    end
end

endmodule

`resetall
