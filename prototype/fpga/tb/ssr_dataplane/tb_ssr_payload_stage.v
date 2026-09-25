`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_payload_stage - the landing ring, driven directly
 *
 * The cases this module exists to survive - the ring filling because PCIe fell
 * behind the wire, a frame that ssr_rx_engine declares bad after its beats are
 * already written, a header-only frame that must occupy no slot - cannot be
 * produced on demand from a three-node loop. So the bench drives the ssr_rx_engine
 * interface by hand and reads the staged bytes back through the same DMA read
 * port the real engine uses, so the slot ADDRESS is under test and not just the
 * bytes.
 *
 * S7 is a regression test, not a feature test: a beat counter sized
 * $clog2(SLOT_BEATS) wraps to zero on a frame that fills the slot exactly, and
 * the length cross-check then fires on every full-size frame. That bug is
 * invisible unless a test sends a frame of exactly PAY_SLOT_BYTES.
 */

module tb_ssr_payload_stage;

localparam integer DW              = 512;
localparam integer RAM_SEG_COUNT   = 2;
// The AU200's DMA RAM: two 512-bit segments side by side, so a row is two
// beats. Beat k of the RAM is segment k%2 of row k/2.
localparam integer RAM_SEG_DW      = 512;
localparam integer RAM_SEG_BE      = RAM_SEG_DW/8;
localparam integer RAM_ADDR_WIDTH  = 17;
localparam integer RAM_SEG_AW      = RAM_ADDR_WIDTH - 7;   // clog2(2*64) = 7 -> 17-7 = 10
localparam integer DMA_LEN_WIDTH   = 16;

localparam integer PAY_SLOT_BYTES  = 1024;
localparam integer PAY_SLOT_COUNT  = 4;
localparam integer SLOT_PTR_W      = 2;
// One "page" for the bench. Kept small so the arithmetic is readable; the real
// build uses 4096, which is where the whole point of the layout comes from.

localparam integer BEAT_BYTES      = RAM_SEG_BE;                 // 64: a beat is one segment
localparam integer BEAT_MASK       = (1 << (RAM_ADDR_WIDTH-6)) - 1;
localparam integer SLOT_BEATS      = PAY_SLOT_BYTES/BEAT_BYTES;  // 16
localparam integer SLOT_ADDR_SHIFT = 10;                         // clog2(1024)

// Beat 0 of a slot is the frame header, so a fragment's payload gets one beat
// fewer than the slot holds. In the real build the protocol caps a fragment at
// SSR_FRAG_BYTES well below this; here it is the physical limit being tested.
localparam integer PAY_MAX   = (SLOT_BEATS-1)*BEAT_BYTES;        // 960
localparam integer HDR_BYTES = BEAT_BYTES;                       // 64

localparam integer CLK_PERIOD = 4;

// ---------------------------------------------------------------- clock / reset
reg clk = 1'b0;
reg rst = 1'b1;
always #(CLK_PERIOD/2) clk = ~clk;

initial begin
    repeat (4) @(posedge clk);
    rst = 1'b0;
end

// ---------------------------------------------------------------- DUT wires
reg          pl_sof      = 1'b0;
reg  [7:0]   pl_node_id  = 8'd0;
reg  [63:0]  pl_round_id = 64'd0;
reg  [15:0]  pl_len      = 16'd0;
reg  [15:0]  pl_frag     = 16'd0;
reg  [DW-1:0] pl_hdr     = {DW{1'b0}};
reg          pl_valid    = 1'b0;
reg  [DW-1:0] pl_data    = {DW{1'b0}};
wire         pl_ready;
reg          pl_commit   = 1'b0;
reg          pl_drop     = 1'b0;

wire                      head_valid;
wire [RAM_ADDR_WIDTH-1:0] head_addr;
wire [DMA_LEN_WIDTH-1:0]  head_len;
wire [15:0]               head_frag;
wire [63:0]               head_round;
wire [7:0]                head_node;
wire [SLOT_PTR_W-1:0]     head_slot;
reg                       head_pop = 1'b0;
reg                       desc_done = 1'b0;
reg  [SLOT_PTR_W-1:0]     done_slot = {SLOT_PTR_W{1'b0}};

wire [31:0] n_push, n_full, n_oversize, n_overlap, n_mismatch;

reg  [RAM_SEG_COUNT*RAM_SEG_AW-1:0] rd_cmd_addr  = 0;
reg  [RAM_SEG_COUNT-1:0]            rd_cmd_valid = 0;
wire [RAM_SEG_COUNT-1:0]            rd_cmd_ready;
wire [RAM_SEG_COUNT*RAM_SEG_DW-1:0] rd_resp_data;
wire [RAM_SEG_COUNT-1:0]            rd_resp_valid;
reg  [RAM_SEG_COUNT-1:0]            rd_resp_ready = {RAM_SEG_COUNT{1'b1}};

ssr_payload_stage #(
    .AXIS_DATA_WIDTH    (DW),
    .DMA_LEN_WIDTH      (DMA_LEN_WIDTH),
    .RAM_ADDR_WIDTH     (RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT      (RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH (RAM_SEG_DW),
    .RAM_SEG_BE_WIDTH   (RAM_SEG_BE),
    .RAM_SEG_ADDR_WIDTH (RAM_SEG_AW),
    .RAM_PIPELINE       (2),
    .PAY_SLOT_BYTES     (PAY_SLOT_BYTES),
    .PAY_SLOT_COUNT     (PAY_SLOT_COUNT)
) dut (
    .clk (clk),
    .rst (rst),

    .i_pl_sof      (pl_sof),
    .i_pl_node_id  (pl_node_id),
    .i_pl_round_id (pl_round_id),
    .i_pl_len      (pl_len),
    .i_pl_frag_idx (pl_frag),
    .i_pl_hdr_data (pl_hdr),
    .i_pl_valid    (pl_valid),
    .i_pl_data     (pl_data),
    .o_pl_ready    (pl_ready),
    .i_pl_commit   (pl_commit),
    .i_pl_drop     (pl_drop),

    .o_head_valid    (head_valid),
    .o_head_addr     (head_addr),
    .o_head_len      (head_len),
    .o_head_frag_idx (head_frag),
    .o_head_round_id (head_round),
    .o_head_node_id  (head_node),
    .o_head_slot     (head_slot),
    .i_head_pop      (head_pop),
    .i_desc_done     (desc_done),
    .i_done_slot     (done_slot),

    .o_push_count         (n_push),
    .o_full_count         (n_full),
    .o_oversize_count     (n_oversize),
    .o_overlap_count      (n_overlap),
    .o_len_mismatch_count (n_mismatch),

    .dma_ram_rd_cmd_addr   (rd_cmd_addr),
    .dma_ram_rd_cmd_valid  (rd_cmd_valid),
    .dma_ram_rd_cmd_ready  (rd_cmd_ready),
    .dma_ram_rd_resp_data  (rd_resp_data),
    .dma_ram_rd_resp_valid (rd_resp_valid),
    .dma_ram_rd_resp_ready (rd_resp_ready)
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

// o_pl_ready must never fall. Nothing may hold the wire side off; the whole
// degradation story depends on it. Checked continuously, not in one test.
integer ready_low = 0;
always @(posedge clk) if (!rst && !pl_ready) ready_low = ready_low + 1;

// ---------------------------------------------------------------- drivers
function [DW-1:0] beat_pattern(input [7:0] node, input [63:0] round, input integer b);
begin
    beat_pattern = {{(DW-128){1'b0}}, round[31:0], 16'hBEEF, node, b[7:0], 32'hA5A5_5A5A};
end
endfunction

// The header beat as ssr_rx_engine would hand it over: the real SSR offsets, so a
// test that reads it back out of the staging RAM is checking the bytes the host
// will actually see at the top of the node's region.
function [DW-1:0] hdr_pattern(input [7:0] node, input [63:0] round,
                              input [15:0] len, input [15:0] frag_idx, input [15:0] frag_count);
begin
    hdr_pattern = {DW{1'b0}};
    hdr_pattern[12*8 +: 16] = 16'h88B5;     // ethertype
    hdr_pattern[14*8 +:  8] = node;         // SSR_OFF_NODE_ID
    hdr_pattern[20*8 +: 64] = round;        // SSR_OFF_ROUND_ID
    hdr_pattern[28*8 +: 16] = len;          // SSR_OFF_LENGTH
    hdr_pattern[32*8 +: 16] = frag_idx;     // SSR_OFF_FRAG_IDX
    hdr_pattern[34*8 +: 16] = frag_count;   // SSR_OFF_FRAG_COUNT
end
endfunction

function integer beats_of(input integer len);
begin
    beats_of = (len + BEAT_BYTES - 1) / BEAT_BYTES;
end
endfunction

// One frame, exactly as ssr_rx_engine presents it - and THIS IS THE PART THAT
// MATTERS: sof is on the SAME cycle as beat 0. ssr_rx_engine registers sof off the
// header beat, so by the time it is high the bus has moved on to the first
// payload beat. An earlier version of this task drove sof a cycle early, on a
// bus with nothing on it, which matched a comment in ssr_payload_stage and not the
// module - and the stage's one write port silently lost beat 0 of every frame
// in the real wiring while this bench said everything was fine.
//
// The verdict lands the cycle after the last beat, with nothing on the bus.
// That too is ssr_rx_engine's timing, and ssr_payload_stage writes the header into
// exactly that gap.
//
// A zero-length frame raises sof with no beat and the verdict on the same
// cycle; ssr_rx_engine no longer produces one, but the stage must still not choke.
task send_frag(input [7:0] node, input [63:0] round, input integer len,
               input integer frag_idx, input integer frag_count, input verdict_ok);
    integer nb, b;
begin
    nb = beats_of(len);

    @(negedge clk);
    pl_sof      = 1'b1;
    pl_node_id  = node;
    pl_round_id = round;
    pl_len      = len[15:0];
    pl_frag     = frag_idx[15:0];
    pl_hdr      = hdr_pattern(node, round, len[15:0], frag_idx[15:0], frag_count[15:0]);
    if (nb == 0) begin
        pl_commit = verdict_ok;
        pl_drop   = !verdict_ok;
    end else begin
        pl_valid = 1'b1;                       // beat 0, coincident with sof
        pl_data  = beat_pattern(node, round, 0);
    end
    @(posedge clk);
    @(negedge clk);
    pl_sof    = 1'b0;
    pl_commit = 1'b0;
    pl_drop   = 1'b0;

    // Poison the sideband the moment sof is over. ssr_rx_engine does not hold these
    // steady for the whole frame, so a stage that reads them at commit instead
    // of latching them at sof is wrong - and if the bench left them parked at
    // their sof values, that bug would be invisible. Only the DRIVER changes
    // here; the checks still expect the value that was driven at sof. The
    // header in particular: the stage writes it at COMMIT, so a stage that
    // reads i_pl_hdr_data then instead of latching it at sof writes all-ones.
    pl_node_id  = 8'hFF;
    pl_round_id = 64'hDEAD_BEEF_DEAD_BEEF;
    pl_len      = 16'hFFFF;
    pl_frag     = 16'hFFFF;
    pl_hdr      = {DW{1'b1}};

    for (b = 1; b < nb; b = b + 1) begin
        pl_valid = 1'b1;
        pl_data  = beat_pattern(node, round, b);
        @(posedge clk);
        @(negedge clk);
    end
    pl_valid = 1'b0;

    if (nb != 0) begin
        pl_commit = verdict_ok;
        pl_drop   = !verdict_ok;
        @(posedge clk);
        @(negedge clk);
        pl_commit = 1'b0;
        pl_drop   = 1'b0;
    end
end
endtask

// A single-fragment frame: frag_off 0, total_len equal to this frame's length.
// This is what every test that does not care about fragmentation should use.
task send_frame(input [7:0] node, input [63:0] round, input integer len, input verdict_ok);
begin
    send_frag(node, round, len, 0, 1, verdict_ok);
end
endtask

// One descriptor.
// ---------------------------------------------------------------- DMA engine model
// The real engine takes a descriptor into its op table and reads the staging
// RAM LATER - asynchronously, over however many cycles the TLPs take, and under
// PCIe back pressure that can be microseconds. Completion comes after that.
//
// This model does the same, and it is the part of the bench that gives the
// release-on-completion rule something to fail against. Every pop is queued
// with the RAM beats it named AND a snapshot of what those beats held at the
// moment of issue. Completion happens later - immediately by default, so the
// older tests run as they always did, or held back until engine_drain when
// eng_hold is set - and at completion the beats are read AGAIN and compared to
// the snapshot. A stage that released the slot on the pop would have let the
// wire overwrite those beats in between, and this is where that shows up.
localparam integer EQ_DEPTH = 32;
localparam integer EQ_ROWS  = SLOT_BEATS;
reg                  eng_hold = 1'b0;
reg [SLOT_PTR_W-1:0] eq_slot  [0:EQ_DEPTH-1];
integer              eq_row   [0:EQ_DEPTH-1];   // first beat
integer              eq_rows  [0:EQ_DEPTH-1];
reg [DW-1:0]         eq_snap  [0:EQ_DEPTH-1][0:EQ_ROWS-1];
integer eq_wr = 0, eq_rd = 0;
integer eng_completions = 0;

task engine_queue_head;
    integer r, nrows;
begin
    nrows = (head_len + BEAT_BYTES - 1) / BEAT_BYTES;
    eq_slot[eq_wr % EQ_DEPTH] = head_slot;
    eq_row [eq_wr % EQ_DEPTH] = head_addr >> 6;
    eq_rows[eq_wr % EQ_DEPTH] = nrows;
    for (r = 0; r < nrows; r = r + 1)
        ram_read_beat(((head_addr >> 6) + r) & BEAT_MASK, eq_snap[eq_wr % EQ_DEPTH][r]);
    eq_wr = eq_wr + 1;
end
endtask

// Complete queue entry `idx`: re-read its beats, compare, pulse done.
task engine_complete(input integer idx);
    integer r;
    reg [DW-1:0] now;
    reg ok;
begin
    ok = 1'b1;
    for (r = 0; r < eq_rows[idx % EQ_DEPTH]; r = r + 1) begin
        ram_read_beat((eq_row[idx % EQ_DEPTH] + r) & BEAT_MASK, now);
        if (now !== eq_snap[idx % EQ_DEPTH][r]) ok = 1'b0;
    end
    check(ok, "the staging RAM changed under a descriptor the engine had not finished reading");
    @(negedge clk);
    desc_done = 1'b1;
    done_slot = eq_slot[idx % EQ_DEPTH];
    @(posedge clk);
    @(negedge clk);
    desc_done = 1'b0;
    eng_completions = eng_completions + 1;
end
endtask

// Complete everything queued: oldest first, or newest first when `reverse`.
task engine_drain(input reverse);
    integer i;
begin
    if (reverse) begin
        for (i = eq_wr - 1; i >= eq_rd; i = i - 1) engine_complete(i);
    end else begin
        for (i = eq_rd; i < eq_wr; i = i + 1) engine_complete(i);
    end
    eq_rd = eq_wr;
end
endtask

task pop_head;
begin
    engine_queue_head;
    @(negedge clk);
    head_pop = 1'b1;
    @(posedge clk);
    @(negedge clk);
    head_pop = 1'b0;
    if (!eng_hold) engine_drain(1'b0);
end
endtask

// One whole staged frame, however many descriptors it yields. A fragment-0 slot
// yields two - its header, then its payload - and only the second frees it.
task pop_frame;
begin
    if (head_valid) pop_head;
end
endtask

// Drain the ring, BOUNDED. An unbounded `while (head_valid) pop_frame;` turns a
// slot that never releases into a watchdog timeout twenty tests later, with no
// message pointing at the cause. The bound turns it into a named failure here.
task drain_ring;
    integer guard;
begin
    guard = 0;
    while (head_valid && guard < 4*PAY_SLOT_COUNT + 8) begin
        pop_frame;
        guard = guard + 1;
    end
    check(!head_valid, "the ring would not drain - a slot is not releasing");
    engine_drain(1'b0);
    repeat (PAY_SLOT_COUNT + 1) @(posedge clk); #1;
    check(dut.slot_count_reg == 0, "slots were not released after their completions");
end
endtask

// Read one 64-byte beat out of the staging RAM through the DMA read port, the
// same way the real engine would: the whole row, then the beat's segment.
task ram_read_beat(input integer beat, output [DW-1:0] data);
    reg [RAM_SEG_AW-1:0] row;
begin
    row = beat / RAM_SEG_COUNT;
    @(negedge clk);
    rd_cmd_addr  = {RAM_SEG_COUNT{row}};
    rd_cmd_valid = {RAM_SEG_COUNT{1'b1}};
    @(posedge clk);
    while (rd_cmd_ready != {RAM_SEG_COUNT{1'b1}}) @(posedge clk);
    @(negedge clk);
    rd_cmd_valid = {RAM_SEG_COUNT{1'b0}};
    while (rd_resp_valid != {RAM_SEG_COUNT{1'b1}}) @(posedge clk);
    data = rd_resp_data[(beat % RAM_SEG_COUNT)*RAM_SEG_DW +: RAM_SEG_DW];
    @(negedge clk);
end
endtask

// ---------------------------------------------------------------- watchdog
initial begin
    #500000;
    $display("");
    $display("\033[31mTIMEOUT\033[0m - the bench never finished");
    $finish;
end

// ---------------------------------------------------------------- tests
reg [DW-1:0] got;
integer i, b, bad;
reg [31:0] base_push, base_full, base_over, base_mis;
integer guard;

initial begin : main
    @(negedge rst);
    repeat (2) @(posedge clk);

    // ------------------------------------------------------------------ S1
    banner("S1  a frame yields ONE descriptor: header and payload together, to one page");
    send_frame(8'd2, 64'd100, 256, 1'b1);
    repeat (2) @(posedge clk);

    check(head_valid,               "the ring did not present a head slot");
    check(head_addr  == 16'd0,      "the descriptor must start at the slot base - beat 0, the header");
    check(head_len   == 16'd64 + 16'd256, "the descriptor is the header plus the payload");
    check(head_frag  == 16'd0,      "head_frag_idx is wrong");
    check(head_round == 64'd100,    "head_round_id is wrong");
    check(head_node  == 8'd2,       "head_node_id is wrong");
    check(n_push == 32'd1,          "push_count is not 1");

    // beat 0 is the header the host will read at the top of the page
    ram_read_beat(0, got);
    check(got === hdr_pattern(8'd2, 64'd100, 16'd256, 16'd0, 16'd1),
          "the staged header is not the header ssr_rx_engine handed over");

    bad = 0;
    for (b = 0; b < beats_of(256); b = b + 1) begin
        ram_read_beat((b+1) & BEAT_MASK, got);
        if (got !== beat_pattern(8'd2, 64'd100, b)) bad = bad + 1;
    end
    check(bad == 0, "the staged payload does not follow the header beat for beat");

    // ------------------------------------------------------------------ S2
    banner("S2  the ring advances by PAY_SLOT_BYTES and wraps");
    pop_head;                                  // the payload descriptor from S1
    repeat (2) @(posedge clk);
    check(!head_valid, "the ring did not empty after the only slot was popped");

    for (i = 0; i < PAY_SLOT_COUNT; i = i + 1)
        send_frame(8'd1, 64'd200 + i, 128, 1'b1);
    repeat (2) @(posedge clk);

    // slot 0 was consumed above, so these land in slots 1,2,3,0
    for (i = 0; i < PAY_SLOT_COUNT; i = i + 1) begin
        check(head_valid, "the ring lost a slot");
        check(head_addr == (((i + 1) % PAY_SLOT_COUNT) << SLOT_ADDR_SHIFT),
              "a slot is not at base + k*PAY_SLOT_BYTES");
        check(head_round == 64'd200 + i, "slots came back out of order");
        pop_frame;
        repeat (1) @(posedge clk);
    end
    check(!head_valid, "the ring did not empty");

    // ------------------------------------------------------------------ S3
    banner("S3  the ring fills: the frame is DISCARDED and counted, never buffered");
    base_full = n_full;
    base_push = n_push;
    for (i = 0; i < PAY_SLOT_COUNT; i = i + 1)
        send_frame(8'd1, 64'd300 + i, 64, 1'b1);
    repeat (2) @(posedge clk);
    check(n_push == base_push + PAY_SLOT_COUNT, "the ring did not take PAY_SLOT_COUNT frames");
    check(n_full == base_full,                  "the ring reported full too early");

    send_frame(8'd1, 64'd399, 64, 1'b1);        // one too many
    repeat (2) @(posedge clk);
    check(n_full == base_full + 1,              "a frame arriving at a full ring was not counted");
    check(n_push == base_push + PAY_SLOT_COUNT, "a frame was staged into a full ring");
    check(head_round == 64'd300,                "the discarded frame disturbed the head");

    // and it recovers
    pop_frame;
    repeat (2) @(posedge clk);
    send_frame(8'd1, 64'd400, 64, 1'b1);
    repeat (2) @(posedge clk);
    check(n_push == base_push + PAY_SLOT_COUNT + 1, "the ring did not recover after a drop");

    // drain
    drain_ring;
    repeat (2) @(posedge clk);

    // ------------------------------------------------------------------ S4
    banner("S4  i_pl_drop: the beats are written but the slot is never pushed");
    base_push = n_push;
    send_frame(8'd2, 64'd500, 256, 1'b0);       // verdict = drop
    repeat (2) @(posedge clk);
    check(n_push == base_push, "a dropped frame was staged");
    check(!head_valid,         "a dropped frame produced a head slot");

    // the next good frame reuses the same slot, so the dropped bytes are gone
    send_frame(8'd3, 64'd501, 128, 1'b1);
    repeat (2) @(posedge clk);
    check(n_push == base_push + 1, "the ring did not recover after a drop verdict");
    check(head_round == 64'd501,   "the dropped frame leaked into the head slot");
    check(head_node  == 8'd3,      "the dropped frame's node id leaked through");
    drain_ring;

    // ------------------------------------------------------------------ S5
    banner("S5  a header-only frame occupies no slot and is not an error");
    base_push = n_push;
    base_over = n_oversize;
    base_mis  = n_mismatch;
    send_frame(8'd2, 64'd600, 0, 1'b1);         // sof and commit in one cycle
    repeat (2) @(posedge clk);
    check(n_push     == base_push, "a zero-length frame took a slot");
    check(!head_valid,             "a zero-length frame produced a head slot");
    check(n_oversize == base_over, "a zero-length frame was called oversize");
    check(n_mismatch == base_mis,  "a zero-length frame was called a length mismatch");

    // the ring must not be stuck open afterwards
    send_frame(8'd2, 64'd601, 64, 1'b1);
    repeat (2) @(posedge clk);
    check(n_push == base_push + 1, "the ring was left open by a header-only frame");
    check(n_overlap == 32'd0,      "a header-only frame was seen as an overlap");
    drain_ring;

    // ------------------------------------------------------------------ S6
    banner("S6  a frame longer than a slot is refused, not truncated into the next slot");
    base_push = n_push;
    base_over = n_oversize;
    send_frame(8'd1, 64'd700, PAY_MAX + BEAT_BYTES, 1'b1);
    repeat (2) @(posedge clk);
    check(n_oversize == base_over + 1, "an oversize frame was not counted");
    check(n_push     == base_push,     "an oversize frame was staged");
    check(!head_valid,                 "an oversize frame produced a head slot");

    // ------------------------------------------------------------------ S7
    banner("S7  REGRESSION: a fragment that fills the slot exactly is not a length mismatch");
    base_mis  = n_mismatch;
    base_push = n_push;
    send_frame(8'd2, 64'd800, PAY_MAX, 1'b1);
    repeat (2) @(posedge clk);
    check(n_push     == base_push + 1, "a full-size fragment was refused");
    check(head_len   == PAY_SLOT_BYTES[15:0], "a full-size fragment's descriptor is the whole slot");
    check(n_mismatch == base_mis,      "a full-size fragment tripped the length cross-check (beat counter wrapped?)");

    bad = 0;
    for (b = 0; b < SLOT_BEATS-1; b = b + 1) begin
        ram_read_beat(((head_addr >> 6) + b + 1) & BEAT_MASK, got);
        if (got !== beat_pattern(8'd2, 64'd800, b)) bad = bad + 1;
    end
    check(bad == 0, "a full-size fragment did not land whole");

    drain_ring;

    // ------------------------------------------------------------------ S10
    banner("S10 fragments: one descriptor each, numbered, no reassembly");
    base_push = n_push;
    // one node's round as three fragments, indices 0, 1, 2 of 3
    send_frag(8'd1, 64'd900, 256, 0, 3, 1'b1);
    send_frag(8'd1, 64'd900, 256, 1, 3, 1'b1);
    send_frag(8'd1, 64'd900, 100, 2, 3, 1'b1);      // a short final one
    repeat (2) @(posedge clk);
    check(n_push == base_push + 3, "the ring did not take all three fragments");

    check(head_frag == 16'd0,                  "fragment 0 must come out first");
    check(head_len  == 16'd64 + 16'd256,       "fragment 0: header plus payload");
    check((head_addr & {SLOT_ADDR_SHIFT{1'b1}}) == 0, "every descriptor starts at its slot base");
    pop_head; repeat (1) @(posedge clk);

    check(head_frag == 16'd1,                  "fragment 1 must come out second");
    check(head_len  == 16'd64 + 16'd256,       "fragment 1: header plus payload");
    check((head_addr & {SLOT_ADDR_SHIFT{1'b1}}) == 0, "every descriptor starts at its slot base");
    pop_head; repeat (1) @(posedge clk);

    check(head_frag == 16'd2,                  "fragment 2 must come out third");
    check(head_len  == 16'd64 + 16'd100,       "a short final fragment moves a short page - header plus 100");
    pop_head; repeat (1) @(posedge clk);
    check(!head_valid, "the ring did not empty after three fragments");
    check(n_mismatch == 32'd0, "a fragment tripped the length cross-check");
    drain_ring;

    // ------------------------------------------------------------------ S8
    banner("S8  a second sof before a verdict is counted, not silently accepted");
    check(n_overlap == 32'd0, "an overlap was reported before one was created");
    @(negedge clk);
    pl_sof = 1'b1; pl_node_id = 8'd1; pl_round_id = 64'd900; pl_len = 16'd128;
    @(posedge clk); @(negedge clk);
    pl_sof = 1'b1; pl_node_id = 8'd2; pl_round_id = 64'd901; pl_len = 16'd128;
    @(posedge clk); @(negedge clk);
    pl_sof = 1'b0;
    pl_commit = 1'b1; @(posedge clk); @(negedge clk); pl_commit = 1'b0;
    repeat (2) @(posedge clk);
    check(n_overlap == 32'd1, "a sof arriving while a frame was open was not counted");
    // The second sof declared 128 bytes and then no beats arrived, so the
    // length cross-check must fire too. Asserted explicitly so the non-zero
    // len_mismatch in the summary is accounted for rather than lurking.
    check(n_mismatch == 32'd1, "the overlapping frame's beats/length disagreement was missed");
    drain_ring;

    // ------------------------------------------------------------------ S9
    banner("S9  the wire side was never held off");
    check(ready_low == 0, "o_pl_ready fell - the stage back-pressured ssr_rx_engine");

    // ------------------------------------------------------------------ S11
    banner("S11 a slot is held until the DMA engine has FINISHED reading it");
    // The engine now holds every completion. Pop all four slots' descriptors -
    // the head must hand them all out, because handing out is not releasing -
    // then offer a fifth frame. It must be DROPPED as full: every slot is still
    // being read. Then complete them newest-first, so the release order (which
    // is the ring order) and the completion order disagree, and the ring must
    // still come back empty and accept frames again.
    drain_ring;
    eng_hold = 1'b1;
    base_push = n_push;
    base_full = n_full;
    send_frame(8'd1, 64'd1100, 256, 1'b1);
    send_frame(8'd1, 64'd1101, 256, 1'b1);
    send_frame(8'd1, 64'd1102, 256, 1'b1);
    send_frame(8'd1, 64'd1103, 256, 1'b1);
    repeat (2) @(posedge clk);
    check(n_push == base_push + 4, "four frames should have been staged");

    guard = 0;                                   // bounded, so a head that never
    while (head_valid && guard < 2*PAY_SLOT_COUNT) begin   // drops fails by name
        pop_frame; guard = guard + 1;
    end
    check(guard <= PAY_SLOT_COUNT, "the head kept presenting slots past the number staged");
    repeat (2) @(posedge clk);
    check(!head_valid,               "everything should be handed out");
    check(dut.slot_count_reg == 4,   "handing out descriptors must not release slots");
    check(eq_wr - eq_rd == 4,        "four frames should have queued four descriptors");

    send_frame(8'd1, 64'd1104, 256, 1'b1);       // a fifth: nowhere to put it
    repeat (2) @(posedge clk);
    check(n_full == base_full + 1,   "a frame arriving while every slot is still being read must be dropped as full");
    check(n_push == base_push + 4,   "and must not have been staged");

    engine_drain(1'b1);                          // newest first: out of order
    // Release is one slot per cycle, in ring order, so four slots take four
    // cycles after the last completion lands - plus one to read the result
    // after the NBA region rather than before it.
    repeat (PAY_SLOT_COUNT + 1) @(posedge clk); #1;
    $display("     after drain: slot_count=%0d free=%0d tail=%0d head=%0d pend=%0d,%0d,%0d,%0d",
             dut.slot_count_reg, dut.free_ptr_reg, dut.tail_ptr_reg, dut.head_ptr_reg,
             dut.slot_pend[0], dut.slot_pend[1], dut.slot_pend[2], dut.slot_pend[3]);
    check(dut.slot_count_reg == 0,   "out-of-order completions did not release every slot");
    check(dut.free_ptr_reg == dut.tail_ptr_reg, "free_ptr did not catch up with tail_ptr");

    // ...and the ring is usable again, from where it left off.
    send_frame(8'd1, 64'd1105, 256, 1'b1);
    repeat (2) @(posedge clk);
    check(n_push == base_push + 5,   "the ring did not accept a frame after its slots were released");
    eng_hold = 1'b0;
    drain_ring;

    // ------------------------------------------------------------------ S12
    banner("S12 a pop and a stale completion for the same slot in ONE cycle: the pop wins");
    // With one descriptor per slot this cannot happen in a correct system -
    // the completion is for a descriptor the pop is only now issuing. But the
    // ordering in the RTL has to be right anyway, and this is the case that
    // tells two if-statements apart: if the completion is written last, the
    // slot looks idle with its descriptor still out, and the release-on-
    // completion rule is silently defeated.
    eng_hold = 1'b1;
    send_frame(8'd2, 64'd1200, 256, 1'b1);
    repeat (2) @(posedge clk);
    engine_queue_head;                           // record the descriptor...
    @(negedge clk);
    head_pop  = 1'b1;                            // ...hand it out
    desc_done = 1'b1;                            // and complete "it" the same cycle
    done_slot = head_slot;
    @(posedge clk);
    @(negedge clk);
    head_pop  = 1'b0;
    desc_done = 1'b0;
    repeat (2) @(posedge clk); #1;
    check(dut.slot_pend[done_slot] == 1'b1,
          "a pop and a completion in one cycle must leave the descriptor outstanding");
    check(dut.slot_count_reg == 1,   "the slot must still be allocated");
    engine_drain(1'b0);                          // the real completion
    repeat (3) @(posedge clk); #1;
    check(dut.slot_pend[done_slot] == 1'b0, "the real completion must clear it");
    check(dut.slot_count_reg == 0,   "and release the slot");
    eng_hold = 1'b0;

    // ------------------------------------------------------------------ report
    $display("");
    $display("================================================================");
    $display("  tb_ssr_payload_stage: %0d checks, %0d failures", checks, errors);
    $display("  push=%0d full=%0d oversize=%0d overlap=%0d len_mismatch=%0d",
             n_push, n_full, n_oversize, n_overlap, n_mismatch);
    if (errors == 0) $display("  \033[32mPASS\033[0m");
    else             $display("  \033[31mFAIL\033[0m");
    $display("================================================================");
    $finish;
end

// ---------------------------------------------------------------- waveform
initial begin
    if (!$test$plusargs("nodump")) begin
        $dumpfile("build/tb_ssr_payload_stage.vcd");
        $dumpvars(0, tb_ssr_payload_stage);
    end
end

endmodule

`resetall
