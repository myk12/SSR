`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_tx_engine - the per-round frame SEQUENCE, driven by hand
 *
 * This bench drives the start pulse, the cutoff level and the buffer directly
 * and asks only about the sequence:
 *
 *     one control frame, always, first, carrying the ack it was given
 *     a gap wide enough to cover the clock-skew spread
 *     then a fragment whenever the buffer offers one, paced, until the cutoff
 *     or the round's budget - and NOTHING when there is nothing to propose
 *
 * Three of these earn their place over the others:
 *
 *   R4  a proposal that arrives halfway through the round goes out in THAT
 *       round. It is the reason the engine no longer plans a round at its
 *       control frame (docs/count_ack.md), and an engine that still did would
 *       pass every other test here.
 *
 *   R5  nothing starts after the cutoff. A fragment started later could land
 *       after a peer's boundary, where it no longer counts, and the sender's
 *       own count would disagree with everyone's.
 *
 *   R7  the gap between our control frame and our first fragment. Removing it
 *       breaks nothing locally and nothing in a two-node run; it only shows up
 *       as another node's control frame arriving late behind our payload at a
 *       switch. A bench on one transmitter cannot see that, so it measures the
 *       gap directly instead.
 *
 * NEGATIVE CONTROLS (edit rtl/ssr_tx_engine.v, never this file)
 *   drop "if (!i_tx_pay_open) pay_run_reg <= 0"                R5 fails (sends between the
 *                                                              boundary and the control frame,
 *                                                              with the old round's id)
 *   (pay_accepted's own "&& i_tx_pay_open" only covers the one cycle on
 *   which the level falls, before pay_run_reg follows it; dropping it alone
 *   changes nothing this bench can see.)
 *   pay_accepted: drop "&& pay_budget"                         R2 fails
 *   ctrl_accepted branch: do not reset frag_idx_reg            R2 fails (indices run on)
 *   header: ack on payload frames too (drop "is_ctrl_reg ?")   R1 fails
 */

module tb_ssr_tx_engine;

localparam integer DW        = 512;
localparam integer KW        = DW/8;
localparam integer UW        = 17;
localparam integer NODE_ID   = 1;
localparam integer NODE_CNT  = 3;
localparam integer FRAGS_MAX = 4;
localparam integer PAY_GAP   = 32;   // skew gap, once after the control frame
localparam integer PACE_GAP  = 20;   // rate cap, after every fragment
localparam integer CLK_P     = 4;

`include "ssr_packet.vh"

// 4032 payload bytes is 63 beats; with the header beat a frame is 64 = one page.
localparam integer FRAG_BEATS = SSR_FRAG_BYTES / 64;

// ---------------------------------------------------------------- clock / reset
reg clk = 1'b0, rst = 1'b1;
always #(CLK_P/2) clk = ~clk;
initial begin repeat (4) @(posedge clk); rst = 1'b0; end

// ---------------------------------------------------------------- DUT
reg         start_pulse = 1'b0;
reg [63:0]  round_id   = 64'd0;
reg [31:0]  run_id     = 32'd7;
reg [63:0]  ack        = 64'h0000_0000_0003_0207;   // node 0: 7, node 1: 2, node 2: 3
reg         pay_open   = 1'b0;

wire [DW-1:0] buf_data;
wire          buf_valid;
wire          buf_ready;
wire          buf_last;
reg  [15:0]   buf_len   = SSR_FRAG_BYTES;

wire [DW-1:0] m_tdata;
wire [KW-1:0] m_tkeep;
wire          m_tvalid;
reg           m_tready = 1'b1;
wire          m_tlast;
wire [UW-1:0] m_tuser;

wire          lo_sent;
wire [63:0]   lo_sent_round;

wire [31:0] n_ctrl_frames, n_pay_frames, n_missed;
wire [31:0] n_empty, n_overrun, n_lenmis, n_oversize;

ssr_tx_engine #(
    .P_NODE_ID(NODE_ID), .P_NODE_COUNT(NODE_CNT),
    .P_MAX_PAYLOAD_BYTES(SSR_FRAG_BYTES),
    .P_FRAGS_PER_ROUND(FRAGS_MAX),
    .P_PAY_GAP_CYCLES(PAY_GAP),
    .P_PACE_GAP_CYCLES(PACE_GAP),
    .AXIS_DATA_WIDTH(DW), .AXIS_USER_WIDTH(UW)
) dut (
    .clk(clk), .rst(rst),
    .i_tx_start_pulse(start_pulse),
    .i_tx_round_id(round_id), .i_tx_run_id(run_id), .i_tx_pay_open(pay_open),
    .i_tx_ack(ack),

    .i_buf_rd_data(buf_data), .i_buf_rd_valid(buf_valid),
    .o_buf_rd_ready(buf_ready), .i_buf_tx_last(buf_last),
    .i_buf_tx_len(buf_len),

    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tvalid(m_tvalid),
    .m_axis_tready(m_tready), .m_axis_tlast(m_tlast), .m_axis_tuser(m_tuser),

    .o_local_sent(lo_sent), .o_local_sent_round(lo_sent_round),

    .o_ctrl_frame_count(n_ctrl_frames), .o_pay_frame_count(n_pay_frames),
    .o_missed_count(n_missed),
    .o_empty_count(n_empty), .o_overrun_count(n_overrun),
    .o_len_mismatch_count(n_lenmis), .o_oversize_count(n_oversize)
);

// ---------------------------------------------------------------- bookkeeping
integer checks = 0, errors = 0;
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
begin $display(""); $display("---- %0s", msg); end
endtask

// ---------------------------------------------------------------- wire monitor
// Header fields go out most-significant byte first, so reading them back means
// undoing that. Everything the tests assert about a frame comes from here.
function [15:0] rd16(input [DW-1:0] b, input integer off);
    reg [15:0] v;
begin v = b[off*8 +: 16]; rd16 = {v[7:0], v[15:8]}; end
endfunction
function [31:0] rd32(input [DW-1:0] b, input integer off);
    reg [31:0] v;
begin v = b[off*8 +: 32]; rd32 = {v[7:0], v[15:8], v[23:16], v[31:24]}; end
endfunction
function [63:0] rd64(input [DW-1:0] b, input integer off);
    reg [63:0] v;
begin v = b[off*8 +: 64];
      rd64 = {v[7:0],v[15:8],v[23:16],v[31:24],v[39:32],v[47:40],v[55:48],v[63:56]};
end
endfunction

integer frames_seen = 0;
reg     in_frame    = 1'b0;

// Ordered log of what actually went out. Checking the monitor's "most recent
// header" only works while frames are far enough apart that a settle() lands
// between them - which stopped being true the moment fragments started
// following the control frame immediately. Order is the property under test, so
// record it rather than infer it from delays.
localparam integer LOG_MAX = 64;
reg [7:0]  log_kind  [0:LOG_MAX-1];
reg [15:0] log_frag  [0:LOG_MAX-1];
reg [63:0] log_ack   [0:LOG_MAX-1];
reg [63:0] log_round [0:LOG_MAX-1];
integer log_i;
initial for (log_i = 0; log_i < LOG_MAX; log_i = log_i + 1) begin
    log_kind[log_i]  = 8'hFF;
    log_frag[log_i]  = 16'hFFFF;
    log_ack[log_i]   = {64{1'b1}};
    log_round[log_i] = {64{1'b1}};
end

// captured from the most recent header beat
reg [7:0]  f_kind, f_node, f_flags;
reg [15:0] f_len;
reg [15:0] f_frag;
reg [31:0] f_run;
reg [63:0] f_round;
integer    f_beats;

always @(posedge clk) begin
    if (rst) begin in_frame <= 1'b0; end
    else if (m_tvalid && m_tready) begin
        if (!in_frame) begin
            f_node  <= m_tdata[SSR_OFF_NODE_ID*8 +: 8];
            f_kind  <= m_tdata[SSR_OFF_KIND   *8 +: 8];
            f_flags <= m_tdata[SSR_OFF_FLAGS  *8 +: 8];
            f_len   <= rd16(m_tdata, SSR_OFF_LENGTH);
            f_run   <= rd32(m_tdata, SSR_OFF_RUN_ID);
            f_frag  <= rd16(m_tdata, SSR_OFF_FRAG_IDX);
            f_round <= rd64(m_tdata, SSR_OFF_ROUND_ID);
            f_beats <= 1;
            in_frame <= !m_tlast;
            if (frames_seen < LOG_MAX) begin
                log_kind [frames_seen] <= m_tdata[SSR_OFF_KIND*8 +: 8];
                log_frag [frames_seen] <= rd16(m_tdata, SSR_OFF_FRAG_IDX);
                log_ack  [frames_seen] <= m_tdata[SSR_OFF_ACK*8 +: 64];
                log_round[frames_seen] <= rd64(m_tdata, SSR_OFF_ROUND_ID);
            end
        end else begin
            f_beats  <= f_beats + 1;
            in_frame <= !m_tlast;
        end
        if (m_tlast) frames_seen <= frames_seen + 1;
    end
end

// ---------------------------------------------------------------- fake buffer
// ssr_proposal_buffer's read side, reduced to what ssr_tx_engine consumes: while a
// slot is committed, its next beat is offered, tx_last on the slot's final one.
// The tests post slots (as the host would, at any moment); the buffer counts
// them out as their last beats are taken.
integer posted = 0, popped = 0, fb_beat = 0;
assign buf_valid = !rst && (posted != popped);
assign buf_last  = buf_valid && (fb_beat == FRAG_BEATS-1);
assign buf_data  = {{(DW-32){1'b0}}, fb_beat[31:0]};
always @(posedge clk) begin
    if (rst) begin
        fb_beat <= 0;
    end else if (buf_valid && buf_ready) begin
        if (fb_beat == FRAG_BEATS-1) begin fb_beat <= 0; popped <= popped + 1; end
        else                          fb_beat <= fb_beat + 1;
    end
end

task post(input integer n);
begin @(negedge clk); posted = posted + n; end
endtask

// ---------------------------------------------------------------- drivers
// A round as ssr_core plays it: pay_open rises at the boundary, the start pulse
// follows (here: at once), and pay_open falls at the cutoff - end_round - after
// which the engine finishes the fragment it is on and goes idle before the next
// boundary. A test that wants a slot to wait for the NEXT round posts it after
// end_round.
task start_round(input [63:0] r);
begin
    @(negedge clk); round_id = r; pay_open = 1'b1; start_pulse = 1'b1;
    @(posedge clk); @(negedge clk); start_pulse = 1'b0;
end
endtask

task end_round;
begin
    @(negedge clk); pay_open = 1'b0;
    while (dut.state_reg != 2'd0) @(negedge clk);
    @(negedge clk);
end
endtask

task settle(input integer n);
begin repeat (n) @(posedge clk); end
endtask

// ---------------------------------------------------------------- watchdog
initial begin
    #2000000;
    $display(""); $display("\033[31mTIMEOUT\033[0m"); $finish;
end

// ---------------------------------------------------------------- tests
integer base_f, sent_count;
reg [63:0] last_sent_round;

// R7's probe: cycle stamps for "our control frame left" and "our first fragment
// started", taken from the wire rather than from the DUT's internals.
integer cyc = 0;
reg     gap_arm = 1'b0;
integer gap_ctrl_at, gap_pay_at;

// Cycle stamp of each fragment's first beat, for the pacing test.
reg     pace_arm = 1'b0;
integer pace_n = 0;
integer pace_at [0:7];
always @(posedge clk) begin
    cyc = cyc + 1;
    if (pace_arm && m_tvalid && m_tready && !in_frame
        && m_tdata[SSR_OFF_KIND*8 +: 8] == SSR_KIND_PAYLOAD && pace_n < 8) begin
        pace_at[pace_n] = cyc;
        pace_n = pace_n + 1;
    end
    if (gap_arm && m_tvalid && m_tready && !in_frame) begin
        if (m_tdata[SSR_OFF_KIND*8 +: 8] == SSR_KIND_CTRL && gap_ctrl_at == 0)
            gap_ctrl_at = cyc;
        if (m_tdata[SSR_OFF_KIND*8 +: 8] == SSR_KIND_PAYLOAD && gap_pay_at == 0)
            gap_pay_at = cyc;
    end
end

// count local sends independently of the tests
initial sent_count = 0;
always @(posedge clk) if (!rst && lo_sent) begin
    sent_count = sent_count + 1;
    last_sent_round = lo_sent_round;
end

// A round's worth of frames: control, gap, n fragments paced.
function integer round_cycles(input integer n);
    round_cycles = PAY_GAP + n*(FRAG_BEATS + 1 + PACE_GAP) + 40;
endfunction

initial begin : main
    @(negedge rst); settle(2);

    // ------------------------------------------------------------------ R1
    banner("R1  three slots waiting: control frame with the ack first, then three fragments");
    post(3);
    base_f = frames_seen;
    start_round(64'd100);
    settle(round_cycles(3));
    end_round;

    check(frames_seen == base_f + 4, "one control frame and three fragments did not go out");
    check(log_kind[base_f+0] == SSR_KIND_CTRL,    "frame 0 of the round is not the control frame");
    check(log_ack[base_f+0]  == ack,              "the control frame does not carry the ack it was given");
    check(log_frag[base_f+0] == 16'd0,            "the control frame is not a fragment: frag_idx 0");
    check(log_kind[base_f+1] == SSR_KIND_PAYLOAD && log_frag[base_f+1] == 16'd0, "fragment 0 wrong");
    check(log_kind[base_f+2] == SSR_KIND_PAYLOAD && log_frag[base_f+2] == 16'd1, "fragment 1 wrong");
    check(log_kind[base_f+3] == SSR_KIND_PAYLOAD && log_frag[base_f+3] == 16'd2, "fragment 2 wrong");
    check(log_ack[base_f+1] == 64'd0 && log_ack[base_f+3] == 64'd0, "a payload frame must not carry the ack");
    check(log_round[base_f+3] == 64'd100,       "a fragment carries a different round id");
    check(f_beats == FRAG_BEATS + 1,            "a fragment must be exactly one page of beats: header + 63");
    check(sent_count == 3 && last_sent_round == 64'd100, "o_local_sent: three pulses naming round 100");
    check(n_ctrl_frames == 32'd1 && n_pay_frames == 32'd3, "frame counters wrong");

    // ------------------------------------------------------------------ R2
    banner("R2  P_FRAGS_PER_ROUND caps a round; the rest go out next round, numbered from 0");
    post(FRAGS_MAX + 2);
    base_f = frames_seen;
    start_round(64'd101);
    settle(round_cycles(FRAGS_MAX) + 200);
    end_round;
    check(frames_seen == base_f + 1 + FRAGS_MAX, "the round sent more (or fewer) than its budget");
    check(log_frag[base_f + FRAGS_MAX] == FRAGS_MAX - 1, "the last fragment of the round has the wrong index");
    base_f = frames_seen;
    start_round(64'd102);
    settle(round_cycles(2));
    end_round;
    check(frames_seen == base_f + 3, "the two left over did not go out in the next round");
    check(log_frag[base_f+1] == 16'd0 && log_frag[base_f+2] == 16'd1, "the next round's indices do not start at 0");
    check(log_round[base_f+1] == 64'd102, "the left-over fragments carry the old round id");

    // ------------------------------------------------------------------ R3
    banner("R3  nothing to propose: the control frame goes out, and NOTHING else");
    base_f = frames_seen;
    start_round(64'd103);
    settle(PAY_GAP + 200);
    end_round;
    check(frames_seen == base_f + 1, "a payload frame went out with nothing to propose");
    check(log_kind[base_f] == SSR_KIND_CTRL, "wrong kind");
    start_round(64'd104);              // round 103 is over: it sent nothing
    settle(20);
    check(n_empty == 32'd1, "the empty round was not counted");

    // ------------------------------------------------------------------ R4
    banner("R4  a proposal posted halfway through the round goes out in that round");
    settle(2000);                      // well into round 104, nothing sent yet
    base_f = frames_seen;
    post(2);
    settle(round_cycles(2));
    check(frames_seen == base_f + 2, "a mid-round proposal waited for the next round");
    check(log_round[base_f] == 64'd104 && log_frag[base_f] == 16'd0, "it went out as round 104, fragment 0");
    check(log_frag[base_f+1] == 16'd1, "and the second as fragment 1");

    // ------------------------------------------------------------------ R5
    banner("R5  nothing starts after the cutoff; what is left goes out next round");
    end_round;                         // round 104 reaches its cutoff
    base_f = frames_seen;
    post(1);
    settle(round_cycles(1) + 200);
    check(frames_seen == base_f, "a fragment started after the cutoff");
    start_round(64'd105);
    settle(round_cycles(1));
    end_round;
    check(frames_seen == base_f + 2, "the held slot did not go out in the next round");
    check(log_round[base_f+1] == 64'd105 && log_frag[base_f+1] == 16'd0,
          "it went out as fragment 0 of the new round");
    // The boundary reopens the window a whole dead zone before the next start
    // pulse. A slot waiting there must still wait for the control frame: sent
    // now it would carry the round that has just ended.
    end_round;
    post(1);
    base_f = frames_seen;
    @(negedge clk); pay_open = 1'b1;   // the boundary, no start pulse yet
    settle(round_cycles(1) + 200);
    check(frames_seen == base_f, "a fragment went out between the boundary and the control frame");
    @(negedge clk); round_id = 64'd200; start_pulse = 1'b1;
    @(posedge clk); @(negedge clk); start_pulse = 1'b0;
    settle(round_cycles(1));
    check(frames_seen == base_f + 2 && log_kind[base_f] == SSR_KIND_CTRL && log_round[base_f+1] == 64'd200,
          "after the control frame, the waiting slot went out with the new round's id");
    end_round;
    // The cutoff also holds a fragment the pacing gap was about to release.
    post(2);
    base_f = frames_seen;
    start_round(64'd106);
    settle(PAY_GAP + FRAG_BEATS + 8);  // first fragment out, second waiting on the pacing gap
    end_round;
    settle(round_cycles(1) + 200);
    check(frames_seen == base_f + 2, "the cutoff did not stop the second fragment");
    start_round(64'd107);
    settle(round_cycles(1));
    end_round;

    // ------------------------------------------------------------------ R6
    banner("R6  a start pulse arriving while a frame is on the wire is dropped and counted");
    post(1);
    start_round(64'd108);
    settle(PAY_GAP + 4);              // into the fragment
    m_tready = 1'b0;                  // freeze it on the wire
    settle(4);
    check(dut.state_reg != 2'd0, "the engine should be mid-frame here");
    start_round(64'd109);
    settle(4);
    check(n_missed == 32'd1,  "the dropped start pulse was not counted");
    check(n_overrun == 32'd1, "a round beginning mid-frame was not counted as an overrun");
    check(dut.pay_run_reg == 1'b0, "the new round's pulse did not end the old round's payload");
    m_tready = 1'b1;
    settle(PAY_GAP + FRAG_BEATS + 40);
    end_round;
    check(n_lenmis == 32'd0 && n_oversize == 32'd0, "no geometry errors anywhere in the run");

    // ------------------------------------------------------------------ R7
    banner("R7  the skew gap: the payload waits P_PAY_GAP_CYCLES after the control frame");
    // Measured, not asserted structurally, because the thing this protects
    // against happens at ANOTHER node's receiver: our payload queueing ahead of
    // a late peer's control frame at a switch egress. One transmitter cannot
    // observe that, so the bench checks the only local evidence there is.
    post(1);
    gap_arm   = 1'b1;
    gap_ctrl_at = 0; gap_pay_at = 0;
    start_round(64'd110);
    settle(PAY_GAP + FRAG_BEATS + 40);
    end_round;
    gap_arm = 1'b0;

    check(gap_ctrl_at != 0, "never saw the control frame leave");
    check(gap_pay_at  != 0, "never saw a fragment start");
    check((gap_pay_at - gap_ctrl_at) >= PAY_GAP,
          "the payload started before the skew gap had elapsed");
    $display("     control frame out at cycle %0d, first fragment at %0d (gap %0d, need %0d)",
             gap_ctrl_at, gap_pay_at, gap_pay_at - gap_ctrl_at, PAY_GAP);
    settle(400);

    // ------------------------------------------------------------------ R8
    banner("R8  the rate cap: consecutive fragments are P_PACE_GAP_CYCLES apart");
    // This is what replaced TDMA. Without it the fragments go back to back at
    // whatever the transmit path can manage, and (N-1) senders can swamp one
    // receiver. A single transmitter cannot observe the incast it prevents, so
    // the bench checks the only local evidence there is: the spacing.
    post(3);
    pace_arm  = 1'b1;
    pace_n    = 0;
    start_round(64'd111);
    settle(PAY_GAP + 3*(FRAG_BEATS + PACE_GAP) + 60);
    end_round;
    pace_arm = 1'b0;

    check(pace_n >= 2, "did not see two fragments start");
    check((pace_at[1] - pace_at[0]) >= (FRAG_BEATS + PACE_GAP),
          "fragments went out back to back - the rate cap is not being applied");
    $display("     fragment starts at cycles %0d and %0d (delta %0d, need >= %0d)",
             pace_at[0], pace_at[1], pace_at[1] - pace_at[0], FRAG_BEATS + PACE_GAP);
    settle(4);

    // ------------------------------------------------------------------ report
    $display("");
    $display("================================================================");
    $display("  tb_ssr_tx_engine: %0d checks, %0d failures", checks, errors);
    $display("  ctrl=%0d pay=%0d missed=%0d empty=%0d overrun=%0d len_mismatch=%0d",
             n_ctrl_frames, n_pay_frames, n_missed, n_empty, n_overrun, n_lenmis);
    if (errors == 0) $display("  \033[32mPASS\033[0m");
    else             $display("  \033[31mFAIL\033[0m");
    $display("================================================================");
    $finish;
end

initial begin
    if (!$test$plusargs("nodump")) begin
        $dumpfile("build/tb_ssr_tx_engine.vcd");
        $dumpvars(0, tb_ssr_tx_engine);
    end
end

endmodule

`resetall
