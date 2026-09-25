`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_rx_engine - ssr_rx_engine's header ladder, the two frame kinds, the two
 * receive windows and the ack rung.
 *
 * WHAT THIS BENCH IS FOR, AND WHAT tb_rx_engine WAS FOR
 *   tb_rx_engine drives ssr_rx_engine from a live ssr_tx_engine through a switch model:
 *   an integration bench, and a good one, but it can only produce frames a real
 *   transmitter would produce. This bench drives the bus directly, so it can
 *   build the frames a real transmitter never would - a control frame with a
 *   payload, a fragment numbered past the round's budget, an ack that differs
 *   from ours in one byte - which is exactly what a rejection ladder has to be
 *   tested with.
 *
 *   tb_rx_engine has not been ported to the new port list and is not in the
 *   regression.
 *
 * EVERY NEGATIVE CONTROL HERE IS ONE-SIDED
 *   A control changes the DUT and NOTHING in this file. There is deliberately
 *   no `ifdef anywhere below: a define that silences a check while breaking the
 *   thing that check is for proves nothing, and an earlier version of this
 *   bench did exactly that - all eight controls "passed" against a DUT with the
 *   corresponding test deleted. The controls are applied by editing
 *   rtl/ssr_rx_engine.v, and the bench must not know.
 *
 *   KIND      accept any kind, not just CTRL and PAYLOAD             L6
 *   CTRLLEN   stop requiring a control frame to be empty             L7
 *   FRAGIDX   stop bounding frag_idx by P_FRAGS_PER_ROUND            L10
 *   CTRLIDX   stop requiring frag_idx == 0 on a control frame        L11
 *   ONEWIN    gate both kinds on the control window                  L14
 *   ROWALL    raise o_rx_valid on payload frames too                 L4
 *   ACK       drop the ack rung (hdr_ack_ok = 1)                     L2
 *   ACKPAY    apply the ack rung to payload frames as well           L4
 *   ACKFIRST  test the ack before the round (move the rung up)       L16
 */

module tb_ssr_rx_engine;

localparam integer DW = 512;
localparam integer KW = DW/8;
localparam integer UW = 49;   // AU200: 48-bit PTP timestamp + 1

localparam integer NODE_ID    = 2;
localparam integer NODE_COUNT = 3;

localparam real CLK_PERIOD_NS = 4.0;

`include "ssr_packet.vh"

localparam integer BEAT_BYTES = DW/8;

// ---------------------------------------------------------------- clock
reg clk = 1'b0;
reg rst = 1'b1;
always #(CLK_PERIOD_NS/2.0) clk = ~clk;

// ---------------------------------------------------------------- scoreboard
integer checks = 0;
integer failures = 0;

task check(input condition, input [1023:0] message);
begin
    checks = checks + 1;
    if (condition !== 1'b1) begin
        failures = failures + 1;
        $display("  [FAIL] %0s   (t=%0t)", message, $time);
    end
end
endtask

task banner(input [1023:0] name);
begin
    $display("");
    $display("---- %0s", name);
end
endtask

// ---------------------------------------------------------------- DUT nets
reg  [DW-1:0] s_tdata  = {DW{1'b0}};
reg  [KW-1:0] s_tkeep  = {KW{1'b1}};
reg           s_tvalid = 1'b0;
wire          s_tready;
reg           s_tlast  = 1'b0;
reg  [UW-1:0] s_tuser  = {UW{1'b0}};

reg           ctrl_window = 1'b1;
reg           pay_window  = 1'b1;
reg  [31:0]   run_id      = 32'h5EED_0001;
reg  [63:0]   round_id    = 64'd100;
reg  [7:0]    sound_set   = 8'hFF;
// Our ack about the previous round: we hold 3 of node 0's fragments, 2 of node
// 1's, and sent 5 ourselves (we are node 2).
reg  [63:0]   self_ack    = 64'h0000_0000_0005_0203;

wire          rx_valid;
wire [7:0]    rx_node_id;

wire          pl_sof;
wire [7:0]    pl_node_id;
wire [63:0]   pl_round_id;
wire [15:0]   pl_len;
wire [15:0]   pl_frag_idx;
wire          pl_valid, pl_last;
reg           pl_ready = 1'b1;
wire [DW-1:0] pl_data;
wire          pl_commit, pl_drop;

wire [31:0] c_frame, c_accept, c_ctrl, c_foreign, c_malformed;
wire [31:0] c_windrop, c_ctrllate, c_member, c_sound, c_run, c_round, c_stall, c_ackdis;

// The cluster's per-round fragment budget: what the host region holds, and
// the bound on frag_idx. Deliberately far below SSR_MAX_FRAGS (64) so the
// ladder is seen to enforce the budget and not merely the format's ceiling.
localparam integer FRAGS_BUDGET = 5;

ssr_rx_engine #(
    .P_NODE_ID(NODE_ID),
    .P_NODE_COUNT(NODE_COUNT),
    .P_MAX_PAYLOAD_BYTES(SSR_FRAG_BYTES),
    .P_FRAGS_PER_ROUND(FRAGS_BUDGET),
    .AXIS_DATA_WIDTH(DW),
    .AXIS_KEEP_WIDTH(KW),
    .AXIS_USER_WIDTH(UW),
    .RAM_SEG_COUNT(2),
    .RAM_SEG_DATA_WIDTH(512)
) dut (
    .clk(clk), .rst(rst),
    .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid),
    .s_axis_tready(s_tready), .s_axis_tlast(s_tlast), .s_axis_tuser(s_tuser),

    .i_rx_ctrl_window(ctrl_window),
    .i_rx_pay_enable(pay_window),
    .i_rx_run_id(run_id),
    .i_rx_round_id(round_id),
    .i_rx_sound_set(sound_set),
    .i_rx_self_ack(self_ack),

    .o_rx_valid(rx_valid), .o_rx_node_id(rx_node_id),

    .o_pl_sof(pl_sof), .o_pl_node_id(pl_node_id), .o_pl_round_id(pl_round_id),
    .o_pl_len(pl_len), .o_pl_frag_idx(pl_frag_idx),
    .o_pl_hdr_data(),
    .o_pl_valid(pl_valid), .o_pl_data(pl_data), .o_pl_last(pl_last),
    .i_pl_ready(pl_ready),
    .o_pl_commit(pl_commit), .o_pl_drop(pl_drop),

    .o_frame_count(c_frame), .o_accept_count(c_accept), .o_ctrl_count(c_ctrl),
    .o_foreign_count(c_foreign), .o_malformed_count(c_malformed),
    .o_window_drop_count(c_windrop), .o_ctrl_late_count(c_ctrllate),
    .o_member_drop_count(c_member), .o_sound_drop_count(c_sound),
    .o_run_drop_count(c_run), .o_round_drop_count(c_round),
    .o_ack_disagree_count(c_ackdis),
    .o_stall_count(c_stall)
);

// ---------------------------------------------------------------- observers
// Counted, not compared against a queue: every test below sends one frame and
// then looks at what moved, which is both simpler and impossible to desync.
integer n_rx_valid = 0, n_sof = 0, n_commit = 0, n_drop = 0, n_beat = 0;

reg [7:0]  last_pl_node = 8'hxx;
reg [15:0] last_pl_len = 16'hxxxx;
reg [15:0] last_pl_frag = 16'hxxxx;
reg [7:0]  last_rx_node = 8'hxx;

always @(posedge clk) if (!rst) begin
    if (rx_valid) begin
        n_rx_valid   <= n_rx_valid + 1;
        last_rx_node <= rx_node_id;
    end
    if (pl_sof) begin
        n_sof         <= n_sof + 1;
        last_pl_node  <= pl_node_id;
        last_pl_len   <= pl_len;
        last_pl_frag  <= pl_frag_idx;
    end
    if (pl_valid && pl_ready) n_beat   <= n_beat + 1;
    if (pl_commit)            n_commit <= n_commit + 1;
    if (pl_drop)              n_drop   <= n_drop + 1;
end

task zero_observers;
begin
    n_rx_valid = 0; n_sof = 0; n_commit = 0; n_drop = 0; n_beat = 0;
end
endtask

// A frame that raised sof must be ended by exactly one of commit / drop.
// Watched continuously rather than per test, so no test can forget it - but
// counted as ONE check at the end, not one per cycle, or the scoreboard's
// total stops meaning anything.
integer both_pulsed = 0;
always @(posedge clk) if (!rst) begin
    if (pl_commit && pl_drop) both_pulsed = both_pulsed + 1;
end

// ---------------------------------------------------------------- frame build
// A header is built into a byte array and then packed, so the offsets in the
// test read like ssr_packet.vh rather than like bit slices.
reg [7:0] hdr [0:63];
integer bi;

task hdr_clear;
begin
    for (bi = 0; bi < 64; bi = bi + 1) hdr[bi] = 8'h00;
end
endtask

task put16(input integer off, input [15:0] v);
begin hdr[off] = v[15:8]; hdr[off+1] = v[7:0]; end
endtask

task put32(input integer off, input [31:0] v);
begin hdr[off]=v[31:24]; hdr[off+1]=v[23:16]; hdr[off+2]=v[15:8]; hdr[off+3]=v[7:0]; end
endtask

task put64(input integer off, input [63:0] v);
begin
    hdr[off]=v[63:56]; hdr[off+1]=v[55:48]; hdr[off+2]=v[47:40]; hdr[off+3]=v[39:32];
    hdr[off+4]=v[31:24]; hdr[off+5]=v[23:16]; hdr[off+6]=v[15:8]; hdr[off+7]=v[7:0];
end
endtask

function [DW-1:0] pack_hdr;
    integer k;
begin
    pack_hdr = {DW{1'b0}};
    for (k = 0; k < 64; k = k + 1) pack_hdr[k*8 +: 8] = hdr[k];
end
endfunction

// Build a well-formed header of either kind. Individual tests then poison one
// field, which keeps every negative test one edit away from the positive one.
task build_hdr(input [7:0]  kind,
               input [7:0]  node,
               input [63:0] ack,
               input [63:0] rnd,
               input [15:0] len,
               input [15:0] frag_idx);
    integer k;
begin
    hdr_clear();
    put16(SSR_OFF_ETHERTYPE, 16'h88B5);
    hdr[SSR_OFF_NODE_ID] = node;
    put32(SSR_OFF_RUN_ID,   run_id);
    put64(SSR_OFF_ROUND_ID, rnd);
    put16(SSR_OFF_LENGTH,   len);
    hdr[SSR_OFF_KIND]  = kind;
    hdr[SSR_OFF_FLAGS] = 8'd0;
    put16(SSR_OFF_FRAG_IDX, frag_idx);
    for (k = 0; k < 8; k = k + 1) hdr[SSR_OFF_ACK + k] = ack[k*8 +: 8];
end
endtask

// the two frames almost every test starts from
task ctrl_hdr(input [7:0] node, input [63:0] ack);
begin build_hdr(SSR_KIND_CTRL, node, ack, round_id, 16'd0, 16'd0); end
endtask
task pay_hdr(input [7:0] node, input [15:0] len, input [15:0] idx);
begin build_hdr(SSR_KIND_PAYLOAD, node, 64'd0, round_id, len, idx); end
endtask

// A bounded sender. An unbounded wait here turns a back-pressure bug into a
// watchdog timeout with no name on it.
localparam integer STALL_MAX = 64;
integer stall_i;

// AXI-Stream is a POSEDGE handshake, so this driver reads tready at the posedge
// and nowhere else. An earlier version of this task drove and sampled on the
// negedge; that put the sampling of tready in the same time step as the test's
// own assignment to pl_ready, and the beat that raced lost its tlast. The
// symptom was a full-length frame arriving one beat short - which the DUT
// correctly called malformed, and which looked like a DUT bug for a while.
task send_beat(input [DW-1:0] d, input last);
begin
    s_tdata  <= d;
    s_tkeep  <= {KW{1'b1}};
    s_tvalid <= 1'b1;
    s_tlast  <= last;
    stall_i  = 0;
    @(posedge clk);
    while (!s_tready && stall_i < STALL_MAX) begin
        @(posedge clk);
        stall_i = stall_i + 1;
    end
    check(stall_i < STALL_MAX, "sender stalled: tready never came back");
    s_tvalid <= 1'b0;
    s_tlast  <= 1'b0;
end
endtask

// Send the header currently in hdr[], followed by `beats` payload beats.
task send_frame(input integer beats);
    integer k;
    reg [DW-1:0] w;
begin
    send_beat(pack_hdr(), beats == 0);
    for (k = 0; k < beats; k = k + 1) begin
        w = {8{{56'd0, k[7:0]}}};   // distinctive, so a shifted beat shows up
        send_beat(w, k == beats-1);
    end
    repeat (3) @(posedge clk);
end
endtask

// beats a frame of `len` bytes occupies
function integer beats_for(input integer len);
begin
    beats_for = (len + BEAT_BYTES - 1) / BEAT_BYTES;
end
endfunction

// ---------------------------------------------------------------- snapshots
reg [31:0] s_frame, s_accept, s_ctrl, s_foreign, s_malformed;
reg [31:0] s_windrop, s_ctrllate, s_member, s_sound, s_run, s_round, s_ackdis;

task snap;
begin
    s_frame = c_frame; s_accept = c_accept; s_ctrl = c_ctrl;
    s_foreign = c_foreign; s_malformed = c_malformed;
    s_windrop = c_windrop; s_ctrllate = c_ctrllate; s_member = c_member;
    s_sound = c_sound; s_run = c_run; s_round = c_round; s_ackdis = c_ackdis;
    zero_observers();
end
endtask

// Exactly one counter must have moved, and by one. This is the test the file's
// own "one counter per reason" contract deserves, and it is what makes the
// ladder's ORDER testable rather than just its outcome.
task expect_only(input [1023:0] which);
    integer moved;
begin
    moved = 0;
    if (c_foreign   != s_foreign)   moved = moved + 1;
    if (c_malformed != s_malformed) moved = moved + 1;
    if (c_windrop   != s_windrop)   moved = moved + 1;
    if (c_ctrllate  != s_ctrllate)  moved = moved + 1;
    if (c_member    != s_member)    moved = moved + 1;
    if (c_sound     != s_sound)     moved = moved + 1;
    if (c_run       != s_run)       moved = moved + 1;
    if (c_round     != s_round)     moved = moved + 1;
    if (c_ackdis    != s_ackdis)    moved = moved + 1;
    if (c_accept    != s_accept)    moved = moved + 1;
    check(moved == 1, {"exactly one counter may move: ", which});
end
endtask

// ---------------------------------------------------------------- tests
localparam integer FRAG = SSR_FRAG_BYTES;

initial begin
    if ($test$plusargs("vcd")) begin
        $dumpfile("build/tb_ssr_rx_engine.vcd");
        $dumpvars(0, tb_ssr_rx_engine);
    end

    repeat (6) @(posedge clk);
    rst = 1'b0;
    repeat (4) @(posedge clk);

    // ============================================================ L1
    banner("L1  a control frame whose ack equals ours: the sender is trusted");
    snap();
    ctrl_hdr(8'd0, self_ack);
    send_frame(0);
    check(n_rx_valid == 1, "L1 an agreeing control frame must reach the core");
    check(last_rx_node == 8'd0, "L1 with the frame's node_id");
    check(n_sof == 0 && n_beat == 0, "L1 a control frame starts no payload");
    check(c_ctrl == s_ctrl + 1, "L1 counted as a control frame");
    expect_only("L1 accept");

    // ============================================================ L2
    banner("L2  an ack that differs from ours in ANY byte: not a witness, counted");
    // In the sender's own byte: we hold 3 of node 0's and node 0 claims it sent 4.
    snap();
    ctrl_hdr(8'd0, self_ack ^ 64'h0000_0000_0000_0007);
    send_frame(0);
    check(n_rx_valid == 0, "L2 a sender claiming a different send count is not trusted");
    check(c_ackdis == s_ackdis + 1, "L2 charged to ACK_DISAGREE");
    expect_only("L2 disagree, sender's own byte");
    // In a third node's byte: node 0 holds one fragment of node 1 fewer.
    snap();
    ctrl_hdr(8'd0, self_ack - 64'h0000_0000_0000_0100);
    send_frame(0);
    check(n_rx_valid == 0, "L2 a sender missing a fragment we hold is not trusted");
    expect_only("L2 disagree, a peer's byte");
    // In OUR byte: node 1 holds one fragment of ours fewer than we sent.
    snap();
    ctrl_hdr(8'd1, self_ack - 64'h0000_0000_0001_0000);
    send_frame(0);
    check(n_rx_valid == 0, "L2 a sender that lost one of our fragments is not trusted");
    expect_only("L2 disagree, our byte");
    // In a byte past the cluster: still a different vector.
    snap();
    ctrl_hdr(8'd1, self_ack | 64'h0100_0000_0000_0000);
    send_frame(0);
    check(n_rx_valid == 0, "L2 a stray byte past P_NODE_COUNT is still a disagreement");
    expect_only("L2 disagree, past the cluster");

    // ============================================================ L3
    banner("L3  an idle round: all-zero acks agree");
    self_ack = 64'd0;
    snap();
    ctrl_hdr(8'd1, 64'd0);
    send_frame(0);
    check(n_rx_valid == 1, "L3 zero equals zero: a round nobody sent in is agreed on");
    expect_only("L3 accept, idle");
    self_ack = 64'h0000_0000_0005_0203;

    // ============================================================ L4
    banner("L4  a payload fragment: tag, beats, commit - never the core, never the ack rung");
    snap();
    pay_hdr(8'd0, FRAG[15:0], 16'd0);
    send_frame(beats_for(FRAG));
    check(n_sof == 1, "L4 payload frame must raise sof once");
    check(last_pl_node == 8'd0 && last_pl_len == FRAG[15:0] && last_pl_frag == 16'd0, "L4 the tag");
    check(n_beat == beats_for(FRAG), "L4 every payload beat must be forwarded");
    check(n_commit == 1 && n_drop == 0, "L4 a frame that ends where it promised commits");
    check(n_rx_valid == 0, "L4 a payload frame must NOT reach the core");
    expect_only("L4 accept");
    // Its ack bytes are not looked at: a fragment is not evidence.
    snap();
    build_hdr(SSR_KIND_PAYLOAD, 8'd0, 64'hDEAD_BEEF, round_id, FRAG[15:0], 16'd1);
    send_frame(beats_for(FRAG));
    check(n_sof == 1 && n_commit == 1, "L4 the ack rung does not apply to payload frames");
    check(n_rx_valid == 0, "L4 nor does a payload frame's ack make anyone a witness");
    expect_only("L4 accept, stray ack bytes");

    // ============================================================ L5
    banner("L5  a short fragment - length need not be a whole fragment");
    snap();
    pay_hdr(8'd1, 16'd100, 16'd1);
    send_frame(beats_for(100));
    check(n_sof == 1 && last_pl_len == 16'd100 && last_pl_frag == 16'd1, "L5 its own length and index");
    check(n_beat == beats_for(100), "L5 beats follow the length, not the fragment size");
    check(n_commit == 1, "L5 commit");

    // ============================================================ L6
    banner("L6  an unknown kind is malformed, not silently accepted");
    // Well formed in every field but the kind, so no other rung can reject it.
    snap();
    build_hdr(8'd7, 8'd0, 64'd0, round_id, FRAG[15:0], 16'd0);
    send_frame(beats_for(FRAG));
    check(c_malformed == s_malformed + 1, "L6 an unknown kind must be malformed");
    check(n_sof == 0 && n_beat == 0 && n_rx_valid == 0, "L6 and goes nowhere");
    expect_only("L6 malformed");

    // ============================================================ L7
    banner("L7  a control frame that declares a length is malformed");
    // tlast IS on the header beat, so only the length field disagrees.
    snap();
    build_hdr(SSR_KIND_CTRL, 8'd0, self_ack, round_id, 16'd64, 16'd0);
    send_frame(0);
    check(c_malformed == s_malformed + 1, "L7 a control frame must declare length 0");
    check(n_rx_valid == 0, "L7 must not reach the core");
    expect_only("L7 malformed");
    // and with a real second beat, by the other half of the rule
    snap();
    build_hdr(SSR_KIND_CTRL, 8'd0, self_ack, round_id, 16'd64, 16'd0);
    send_frame(1);
    check(c_malformed == s_malformed + 1, "L7 a control frame must end on its header beat");
    expect_only("L7 malformed, second beat");

    // ============================================================ L8
    banner("L8  a zero-length payload frame is malformed");
    snap();
    pay_hdr(8'd0, 16'd0, 16'd0);
    send_frame(0);
    check(c_malformed == s_malformed + 1, "L8 an empty payload frame is malformed");
    check(n_sof == 0, "L8 must not raise sof");

    // ============================================================ L9
    banner("L9  a fragment longer than SSR_FRAG_BYTES is malformed");
    snap();
    pay_hdr(8'd0, FRAG[15:0]+16'd1, 16'd0);
    send_frame(beats_for(FRAG+1));
    check(c_malformed == s_malformed + 1, "L9 over a fragment is malformed");
    check(n_sof == 0, "L9 must not raise sof");

    // ============================================================ L10
    banner("L10 frag_idx at or past P_FRAGS_PER_ROUND is malformed; the last legal one is not");
    // The host region for (round, node) is P_FRAGS_PER_ROUND pages; one past it
    // is the next node's first page.
    snap();
    pay_hdr(8'd0, FRAG[15:0], FRAGS_BUDGET[15:0]);
    send_frame(beats_for(FRAG));
    check(c_malformed == s_malformed + 1, "L10 frag_idx == P_FRAGS_PER_ROUND is malformed");
    check(n_sof == 0, "L10 must not raise sof");
    expect_only("L10 malformed");
    // The format's ceiling is not the bound.
    snap();
    pay_hdr(8'd0, FRAG[15:0], SSR_MAX_FRAGS[15:0] - 16'd1);
    send_frame(beats_for(FRAG));
    check(c_malformed == s_malformed + 1, "L10 SSR_MAX_FRAGS is the format's ceiling, not the budget");
    expect_only("L10 malformed, ceiling");
    snap();
    pay_hdr(8'd0, FRAG[15:0], FRAGS_BUDGET[15:0] - 16'd1);
    send_frame(beats_for(FRAG));
    check(n_sof == 1 && last_pl_frag == FRAGS_BUDGET[15:0] - 16'd1, "L10 the last legal fragment is accepted");
    expect_only("L10 accept, last legal");

    // ============================================================ L11
    banner("L11 a control frame that names a fragment is malformed");
    snap();
    build_hdr(SSR_KIND_CTRL, 8'd0, self_ack, round_id, 16'd0, 16'd2);
    send_frame(0);
    check(c_malformed == s_malformed + 1, "L11 a control frame's frag_idx must be 0");
    check(n_rx_valid == 0, "L11 must not reach the core");
    expect_only("L11 malformed");

    // ============================================================ L14
    banner("L14 the control deadline: control shut, payload still admissible");
    ctrl_window = 1'b0;
    pay_window  = 1'b1;
    snap();
    ctrl_hdr(8'd0, self_ack);
    send_frame(0);
    check(c_ctrllate == s_ctrllate + 1, "L14 a late control frame is charged to RX_CTRL_LATE");
    check(n_rx_valid == 0, "L14 a late control frame is no witness");
    expect_only("L14 ctrl late");
    snap();
    pay_hdr(8'd0, FRAG[15:0], 16'd0);
    send_frame(beats_for(FRAG));
    check(n_sof == 1 && n_commit == 1, "L14 payload has no deadline - it is admitted past CTRL_PERIOD_NS");
    expect_only("L14 payload accept");

    // ============================================================ L15
    banner("L15 the protocol is not running: payload is a window drop");
    ctrl_window = 1'b0;
    pay_window  = 1'b0;
    snap();
    pay_hdr(8'd0, FRAG[15:0], 16'd0);
    send_frame(beats_for(FRAG));
    check(c_windrop == s_windrop + 1, "L15 payload while the protocol is halted is a window drop");
    check(c_ctrllate == s_ctrllate, "L15 a payload frame is never charged to RX_CTRL_LATE");
    check(n_sof == 0, "L15 must not raise sof");
    ctrl_window = 1'b1;
    pay_window  = 1'b1;

    // ============================================================ L16
    banner("L16 the ladder's order: the ack rung is the LAST one");
    // Every frame below also carries a disagreeing ack, so a ladder that tested
    // the ack earlier would charge it to ACK_DISAGREE instead.
    snap();
    ctrl_hdr(8'd0, ~self_ack);
    put16(SSR_OFF_ETHERTYPE, 16'h0800);
    send_frame(0);
    check(c_foreign == s_foreign + 1, "L16 a foreign ethertype is foreign");
    expect_only("L16 foreign");

    snap();
    ctrl_hdr(NODE_ID[7:0], ~self_ack);
    send_frame(0);
    check(c_member == s_member + 1, "L16 a frame claiming to be us is a member drop");
    expect_only("L16 member");

    snap();
    sound_set = 8'b1111_1110;                       // node 0 no longer sound
    ctrl_hdr(8'd0, ~self_ack);
    send_frame(0);
    check(c_sound == s_sound + 1, "L16 an unsound sender is a sound drop");
    expect_only("L16 sound");
    sound_set = 8'hFF;

    snap();
    ctrl_hdr(8'd0, ~self_ack);
    put32(SSR_OFF_RUN_ID, 32'hDEAD_BEEF);
    send_frame(0);
    check(c_run == s_run + 1, "L16 a different run is a run drop");
    expect_only("L16 run");

    snap();
    build_hdr(SSR_KIND_CTRL, 8'd0, ~self_ack, round_id + 64'd1, 16'd0, 16'd0);
    send_frame(0);
    check(c_round == s_round + 1, "L16 a different round is a round drop, not a disagreement");
    expect_only("L16 round");

    snap();
    ctrl_hdr(8'd0, self_ack);
    s_tuser[0] = 1'b1;                              // the MAC flagged it
    send_frame(0);
    s_tuser[0] = 1'b0;
    check(c_malformed == s_malformed + 1, "L16 a MAC-flagged frame is malformed");
    expect_only("L16 bad user");

    // ============================================================ L17
    banner("L17 a frame ending before its length promised is dropped, not committed");
    snap();
    pay_hdr(8'd0, FRAG[15:0], 16'd0);
    send_frame(beats_for(FRAG) - 1);                // one beat short
    check(n_sof == 1, "L17 sof is raised before the frame is known to be short");
    check(n_drop == 1 && n_commit == 0, "L17 a short frame drops and does not commit");
    check(c_malformed == s_malformed + 1, "L17 charged to malformed");

    // ============================================================ L18
    banner("L18 back pressure: the stage holding a beat off is counted, not lost");
    snap();
    pay_hdr(8'd0, FRAG[15:0], 16'd0);
    fork
        send_frame(beats_for(FRAG));
        begin
            repeat (8) @(posedge clk);
            pl_ready <= 1'b0;
            repeat (5) @(posedge clk);
            pl_ready <= 1'b1;
        end
    join
    check(n_beat == beats_for(FRAG), "L18 no beat may be lost to back pressure");
    check(n_commit == 1, "L18 the frame still commits");
    check(c_stall > 32'd0, "L18 the stall must be counted");

    // ============================================================ L19
    banner("L19 the parser resynchronises after a rejected multi-beat frame");
    snap();
    build_hdr(SSR_KIND_PAYLOAD, 8'd0, 64'd0, round_id + 64'd9, FRAG[15:0], 16'd0);
    send_frame(beats_for(FRAG));
    check(c_round == s_round + 1, "L19 the rejected frame is a round drop");
    snap();
    ctrl_hdr(8'd1, self_ack);
    send_frame(0);
    check(n_rx_valid == 1 && last_rx_node == 8'd1, "L19 the next good frame is still parsed");

    // ============================================================ L20
    banner("L20 the ack is judged against OUR vector as it is now");
    // Our vector moves once per round, at the boundary; a frame is judged
    // against the value on its header beat.
    self_ack = 64'h0000_0000_0001_0101;
    snap();
    ctrl_hdr(8'd0, 64'h0000_0000_0005_0203);        // last round's value
    send_frame(0);
    check(n_rx_valid == 0 && c_ackdis == s_ackdis + 1, "L20 an ack matching our OLD vector is a disagreement");
    snap();
    ctrl_hdr(8'd0, 64'h0000_0000_0001_0101);
    send_frame(0);
    check(n_rx_valid == 1, "L20 and one matching the new vector is trusted");

    // ============================================================ done
    repeat (10) @(posedge clk);
    check(both_pulsed == 0, "commit and drop must never pulse together");

    $display("");
    $display("================================================");
    $display("  tb_ssr_rx_engine: %0d checks, %0d failures", checks, failures);
    $display("================================================");
    if (failures != 0) $display("RESULT: FAIL");
    else               $display("RESULT: PASS");
    $finish;
end

// watchdog
initial begin
    #500000;
    $display("WATCHDOG: tb_ssr_rx_engine did not finish");
    $display("RESULT: FAIL");
    $finish;
end

endmodule

`resetall
