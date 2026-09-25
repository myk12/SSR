`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_rx_demux - which way a frame goes, and that it goes exactly one way
 *
 * D2 is the one that earns its place twice over. Byte 12 of a header is an
 * ethertype; byte 12 of a payload row is payload. Classifying every beat on its
 * own is right exactly once per frame and wrong for every beat after it - and
 * with fragmentation a frame is 65 beats, so 64 of them depend on the latch.
 * The test sends a frame whose SECOND beat looks like the other route.
 *
 * D4 is the defect this module was rewritten to fix: unknown traffic used to be
 * dropped at the app boundary with tready held high, so a plain ping to this
 * interface vanished with no back pressure and no counter moving anywhere.
 */

module tb_ssr_rx_demux;

localparam integer DW = 512;
localparam integer KW = DW/8;
localparam integer UW = 49;   // AU200: 48-bit PTP timestamp + 1
localparam integer IDW = 1;   // AU200: one port per interface
localparam integer DESTW = 9;   // AU200: RX_QUEUE_INDEX_WIDTH + 1
localparam integer ETH_OFF = 12;
localparam [15:0]  SSR_ET  = 16'h88B5;
localparam integer CLK_P = 4;
// How long a beat may wait for tready before the bench calls it a stall.
localparam integer STALL_MAX = 64;

reg clk = 1'b0, rst = 1'b1;
always #(CLK_P/2) clk = ~clk;
initial begin repeat (4) @(posedge clk); rst = 1'b0; end

// ---------------------------------------------------------------- DUT
reg  [DW-1:0]    s_tdata  = {DW{1'b0}};
reg  [KW-1:0]    s_tkeep  = {KW{1'b1}};
reg              s_tvalid = 1'b0;
wire             s_tready;
reg              s_tlast  = 1'b0;
reg  [IDW-1:0]   s_tid    = 0;
reg  [DESTW-1:0] s_tdest  = 0;
reg  [UW-1:0]    s_tuser  = {UW{1'b0}};

wire [DW-1:0]    ssr_tdata;  wire [KW-1:0] ssr_tkeep;
wire             ssr_tvalid; reg           ssr_tready = 1'b1;
wire             ssr_tlast;
wire [IDW-1:0]   ssr_tid;    wire [DESTW-1:0] ssr_tdest; wire [UW-1:0] ssr_tuser;

wire [DW-1:0]    dma_tdata;  wire [KW-1:0] dma_tkeep;
wire             dma_tvalid; reg           dma_tready = 1'b1;
wire             dma_tlast;
wire [IDW-1:0]   dma_tid;    wire [DESTW-1:0] dma_tdest; wire [UW-1:0] dma_tuser;

wire [31:0] n_ssr, n_dma;

ssr_rx_demux #(
    .AXIS_IF_DATA_WIDTH(DW), .AXIS_IF_KEEP_WIDTH(KW),
    .AXIS_IF_RX_USER_WIDTH(UW), .AXIS_IF_RX_ID_WIDTH(IDW),
    .AXIS_IF_RX_DEST_WIDTH(DESTW),
    .P_ETHERTYPE_OFFSET_BYTES(ETH_OFF), .P_SSR_ETHERTYPE(SSR_ET)
) dut (
    .clk(clk), .rst(rst),
    .s_axis_rx_tdata(s_tdata), .s_axis_rx_tkeep(s_tkeep),
    .s_axis_rx_tvalid(s_tvalid), .s_axis_rx_tready(s_tready),
    .s_axis_rx_tlast(s_tlast), .s_axis_rx_tid(s_tid),
    .s_axis_rx_tdest(s_tdest), .s_axis_rx_tuser(s_tuser),

    .m_axis_ssr_tdata(ssr_tdata), .m_axis_ssr_tkeep(ssr_tkeep),
    .m_axis_ssr_tvalid(ssr_tvalid), .m_axis_ssr_tready(ssr_tready),
    .m_axis_ssr_tlast(ssr_tlast), .m_axis_ssr_tid(ssr_tid),
    .m_axis_ssr_tdest(ssr_tdest), .m_axis_ssr_tuser(ssr_tuser),

    .m_axis_dma_tdata(dma_tdata), .m_axis_dma_tkeep(dma_tkeep),
    .m_axis_dma_tvalid(dma_tvalid), .m_axis_dma_tready(dma_tready),
    .m_axis_dma_tlast(dma_tlast), .m_axis_dma_tid(dma_tid),
    .m_axis_dma_tdest(dma_tdest), .m_axis_dma_tuser(dma_tuser),

    .o_ssr_frame_count(n_ssr), .o_dma_frame_count(n_dma)
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

// ---------------------------------------------------------------- monitors
// Count beats on each side, and - the property that matters most - catch any
// beat that appears on BOTH. A demux that drove both valids would deliver every
// frame twice and no single-sided count would notice.
integer ssr_beats = 0, dma_beats = 0, both_beats = 0, lost_beats = 0;
always @(posedge clk) if (!rst) begin
    if (ssr_tvalid && ssr_tready) ssr_beats = ssr_beats + 1;
    if (dma_tvalid && dma_tready) dma_beats = dma_beats + 1;
    if (ssr_tvalid && dma_tvalid) both_beats = both_beats + 1;
    // A beat accepted upstream that reached neither consumer is a silent drop -
    // exactly the failure the old module had.
    if (s_tvalid && s_tready && !ssr_tvalid && !dma_tvalid)
        lost_beats = lost_beats + 1;
end

// ---------------------------------------------------------------- drivers
function [DW-1:0] mk_beat(input [15:0] et, input [31:0] tag);
begin
    mk_beat = {DW{1'b0}};
    mk_beat[ETH_OFF*8 +: 16] = {et[7:0], et[15:8]};   // big-endian on the wire
    mk_beat[64 +: 32]        = tag;
end
endfunction

// A frame of nb beats. Only beat 0 is a real header; later beats carry
// `body_et` where an ethertype would be, which is what payload actually does.
task send_frame(input [15:0] hdr_et, input [15:0] body_et, input integer nb);
    integer b, guard;
begin
    for (b = 0; b < nb; b = b + 1) begin
        @(negedge clk);
        s_tdata  = mk_beat(b == 0 ? hdr_et : body_et, b[31:0]);
        s_tvalid = 1'b1;
        s_tlast  = (b == nb-1);
        @(posedge clk);
        // BOUNDED. An unbounded `while (!s_tready)` turns a misrouted frame -
        // steered at a consumer that happens to be stalled - into a watchdog
        // timeout with nothing pointing at the cause. Four of this bench's six
        // negative controls failed that way before the guard existed.
        guard = 0;
        while (!s_tready && guard < STALL_MAX) begin
            @(posedge clk);
            guard = guard + 1;
        end
        check(s_tready, "the demux stalled the source - steered at a consumer that is not ready?");
        if (!s_tready) b = nb;      // give up on this frame rather than hang
    end
    @(negedge clk);
    s_tvalid = 1'b0;
    s_tlast  = 1'b0;
end
endtask

task settle(input integer n); begin repeat (n) @(posedge clk); end endtask

initial begin
    #200000;
    $display(""); $display("\033[31mTIMEOUT\033[0m"); $finish;
end

// ---------------------------------------------------------------- tests
integer b0, b1;

initial begin : main
    @(negedge rst); settle(2);

    // ------------------------------------------------------------------ D1
    banner("D1  an SSR frame goes to ssr_rx_engine, and only there");
    b0 = ssr_beats; b1 = dma_beats;
    send_frame(SSR_ET, 16'h0000, 4);
    settle(4);
    check(ssr_beats == b0 + 4, "the SSR side did not receive all four beats");
    check(dma_beats == b1,     "beats of an SSR frame leaked to the host");
    check(n_ssr == 32'd1,      "the SSR frame was not counted");
    check(n_dma == 32'd0,      "an SSR frame was counted as host traffic");

    // ------------------------------------------------------------------ D2
    banner("D2  the route is held to tlast, even when a payload beat looks like a header");
    // Beat 0 says SSR; beats 1..64 carry 0x0800 (IPv4) where the ethertype
    // would be. A per-beat classifier sends beat 0 one way and 64 beats the
    // other - which is precisely what the old splitter did.
    b0 = ssr_beats; b1 = dma_beats;
    send_frame(SSR_ET, 16'h0800, 65);
    settle(4);
    check(ssr_beats == b0 + 65, "a payload beat that looked like IPv4 was misrouted");
    check(dma_beats == b1,      "payload beats leaked to the host");

    // and the mirror image: a host frame whose payload looks like SSR
    b0 = ssr_beats; b1 = dma_beats;
    send_frame(16'h0800, SSR_ET, 65);
    settle(4);
    check(dma_beats == b1 + 65, "a host frame lost beats to the SSR side");
    check(ssr_beats == b0,      "a payload beat that looked like SSR was misrouted");

    // ------------------------------------------------------------------ D3
    banner("D3  no beat is ever delivered to both sides");
    check(both_beats == 0, "a beat was presented to ssr_rx_engine and the host at once");

    // ------------------------------------------------------------------ D4
    banner("D4  unknown traffic reaches the host instead of the floor");
    // The defect this module replaced: consensus_rx_splitter recognised exactly
    // two ethertypes and dropped the rest with tready high.
    b1 = dma_beats;
    send_frame(16'h0806, 16'h0000, 1);      // ARP
    send_frame(16'h0800, 16'h0000, 3);      // IPv4
    send_frame(16'h86DD, 16'h0000, 2);      // IPv6
    send_frame(16'h88CC, 16'h0000, 1);      // LLDP
    settle(4);
    check(dma_beats == b1 + 7, "unknown traffic did not reach the host");
    check(lost_beats == 0,     "a beat was accepted upstream and delivered nowhere");
    check(n_dma == 32'd5,      "host frames were not counted (1 from D2 + 4 here)");

    // ------------------------------------------------------------------ D5
    banner("D5  back pressure comes from the chosen side only");
    // Hold the HOST off and send an SSR frame: it must flow, because the host's
    // tready is not in its path at all. A demux that ANDed the two readys would
    // deadlock here.
    b0 = ssr_beats;
    dma_tready = 1'b0;
    send_frame(SSR_ET, 16'h0000, 4);
    settle(4);
    check(ssr_beats == b0 + 4, "an SSR frame was blocked by the host's back pressure");
    dma_tready = 1'b1;

    // ...and the mirror: hold SSR off, send a host frame.
    b1 = dma_beats;
    ssr_tready = 1'b0;
    send_frame(16'h0800, 16'h0000, 3);
    settle(4);
    check(dma_beats == b1 + 3, "a host frame was blocked by ssr_rx_engine's back pressure");
    ssr_tready = 1'b1;

    // ------------------------------------------------------------------ D6
    banner("D6  a stalled consumer stalls its own side and loses nothing");
    b0 = ssr_beats;
    ssr_tready = 1'b0;
    fork
        send_frame(SSR_ET, 16'h0000, 4);
        begin settle(12); @(negedge clk); ssr_tready = 1'b1; end
    join
    settle(6);
    check(ssr_beats == b0 + 4, "beats were lost while the SSR consumer was stalled");
    check(lost_beats == 0,     "a beat vanished under back pressure");

    // ------------------------------------------------------------------ report
    $display("");
    $display("================================================================");
    $display("  tb_ssr_rx_demux: %0d checks, %0d failures", checks, errors);
    $display("  ssr_frames=%0d host_frames=%0d  ssr_beats=%0d host_beats=%0d  both=%0d lost=%0d",
             n_ssr, n_dma, ssr_beats, dma_beats, both_beats, lost_beats);
    if (errors == 0) $display("  \033[32mPASS\033[0m");
    else             $display("  \033[31mFAIL\033[0m");
    $display("================================================================");
    $finish;
end

initial begin
    if (!$test$plusargs("nodump")) begin
        $dumpfile("build/tb_ssr_rx_demux.vcd");
        $dumpvars(0, tb_ssr_rx_demux);
    end
end

endmodule

`resetall
