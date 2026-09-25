`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_proposal_ring - ssr_proposal_dma_reader + ssr_proposal_buffer: the host's
 * proposal ring, fetched with several reads in flight, streamed in order.
 *
 * WHAT IS UNDER TEST
 *   - the doorbell: nothing is read until PRODUCER moves, and then exactly the
 *     posted entries, at base + (idx mod 2^depth) << 12, wrapping the ring
 *   - reads in flight: up to MAX_INFLIGHT, completing OUT OF ORDER (the
 *     engine model gives each read a random latency), and still streamed in
 *     ring order
 *   - the stream: beats 1..63 of each slot, never beat 0, tx_last on beat 63,
 *     ONE BEAT PER CYCLE while the sink is ready - the property whose absence
 *     made ssr_tx_engine break its announcement (a fragment at 1/4 rate)
 *   - flow control: never more than 8 slots in use; CONSUMER counts entries
 *     whole in the buffer
 *   - an error: CONSUMER stops on the failed entry, nothing more is read,
 *     clear_error re-fetches it and everything after, in order
 *   - flush: posted-but-unfetched and committed-but-unstreamed entries go
 *     (including a head slot the RAM was already reading out, P4); a slot
 *     with beats on the wire finishes whole (P5); while a flush waits for a
 *     read, no new slot starts (P6); what is posted after goes out normally
 *
 * The sink stands in for ssr_tx_engine: it takes beats when ready and checks each
 * against the pattern of the entry it expects next.
 *
 * NEGATIVE CONTROLS (edit the RTL, never this file)
 *   ssr_proposal_buffer: commit_fire without done_reg[commit_slot]   P1 fails: a slot
 *       is streamed before its read landed (stale beats)
 *   ssr_proposal_buffer: FIRST_BEAT = 0                             P1 fails at once
 *   ssr_proposal_buffer: rd_resp_ready tied to 1'b1                 P1 fails: beats lost
 *                                                                while the sink holds
 *   ssr_proposal_dma_reader: MAX_INFLIGHT[..] -> 1                  P1 fails: "max in
 *                                                                flight 1"
 *   ssr_proposal_dma_reader: exec_clear: fetch_reg <= fetch_reg     P3 fails: the failed
 *                                                                entry is never re-read
 *   ssr_proposal_buffer: flush: `tx_active_reg && started`          P4 fails: entry 58,
 *       -> `tx_active_reg`                                       flushed, goes out
 *   ssr_proposal_buffer: flush: `tx_active_reg && started`          P5 fails: entry 67 is
 *       -> `1'b0`                                                cut off mid-slot
 *   ssr_proposal_buffer: tx_start without `!i_hold`                 P6 fails: entry 74
 *                                                                starts while the flush
 *                                                                waits for reads, and goes out
 */

module tb_ssr_proposal_ring;

localparam integer DW          = 512;
// The AU200's DMA RAM: a row is two 512-bit segments, i.e. two beats.
localparam integer SEG_DW      = 512;
localparam integer SEG_BE      = 64;
localparam integer RAM_AW      = 17;
localparam integer SEG_AW      = RAM_AW - 7;
localparam integer SLOT_BYTES  = 4096;
localparam integer SLOT_COUNT  = 8;
localparam integer SLOT_W      = 3;
localparam integer BEATS       = 64;         // a 4 KiB slot, 64 B a beat
localparam integer ROWS        = BEATS / 2;  // two beats to a RAM row
localparam integer MAX_IF      = 4;
localparam integer DEPTH_LOG2  = 4;          // 16 entries: the tests wrap it
localparam [63:0]  RING_BASE   = 64'h0000_0007_0000_0000;
// The reader has no register bus of its own: its registers are ssr_csr's
// PROP_* (0x200) and PROP_READS / PROP_READ_ERRORS (0x4C0), and the bench
// talks to them through an ssr_csr, as ssr_dataplane does.
localparam [23:0] R_CONTROL  = 24'h200;
localparam [23:0] R_STATUS   = 24'h204;
localparam [23:0] R_ERRCODE  = 24'h208;
localparam [23:0] R_DEPTH    = 24'h20C;
localparam [23:0] R_BASE_LO  = 24'h210;
localparam [23:0] R_BASE_HI  = 24'h214;
localparam [23:0] R_PRODUCER = 24'h218;
localparam [23:0] R_CONSUMER = 24'h21C;
localparam [23:0] R_FETCH    = 24'h220;
localparam [23:0] R_READS    = 24'h4C0;
localparam [23:0] R_RERRS    = 24'h4C4;

reg clk = 1'b0, rst = 1'b1;
always #2 clk = ~clk;

integer checks = 0, errors = 0;
task check(input cond, input [8*120-1:0] msg);
begin
    checks = checks + 1;
    if (!cond) begin errors = errors + 1; $display("  FAIL [%0t] %0s", $time, msg); end
end
endtask
task banner(input [8*160-1:0] t); begin $display(""); $display("---- %0s", t); end endtask

// ---------------------------------------------------------------- the pattern
// Row r of the entry with absolute index e.
function [DW-1:0] word(input integer e, input integer r);
    integer l;
begin
    word = 0;
    for (l = 0; l < DW/32; l = l + 1) word[l*32 +: 32] = {8'h6B, l[7:0], r[7:0], e[7:0]} ^ {e[15:8], 24'd0};
end
endfunction

// ---------------------------------------------------------------- CSR
reg  [23:0] csr_addr = 0; reg [31:0] csr_wdata = 0; reg csr_wr = 0, csr_rd = 0;
wire [31:0] csr_rdata; wire csr_wack, csr_rack;
task csr_write(input [23:0] a, input [31:0] d);
begin
    @(negedge clk); csr_addr = a; csr_wdata = d; csr_wr = 1;
    @(posedge clk); while (!csr_wack) @(posedge clk);
    @(negedge clk); csr_wr = 0;
end
endtask
task csr_read(input [23:0] a, output [31:0] d);
begin
    @(negedge clk); csr_addr = a; csr_rd = 1;
    @(posedge clk); #0.1; while (!csr_rack) begin @(posedge clk); #0.1; end
    d = csr_rdata;
    @(negedge clk); csr_rd = 0;
end
endtask

// ---------------------------------------------------------------- DUT
wire [63:0] rd_addr; wire [0:0] rd_sel; wire [RAM_AW-1:0] rd_ram; wire [15:0] rd_len; wire [12:0] rd_tag; wire rd_valid;
reg  rd_ready = 1'b1;
reg  [12:0] st_tag = 0; reg [3:0] st_err = 0; reg st_valid = 0;

wire resv_ready, resv, done, commit, settled, rewind, flush, hold;
wire [SLOT_W-1:0] resv_slot, done_slot;
wire [RAM_AW-1:0] resv_addr;
wire [31:0] consumer_out;

reg  [2*SEG_BE-1:0] wr_be = 0; reg [2*SEG_DW-1:0] wr_data = 0; reg [2*SEG_AW-1:0] wr_addr = 0; reg [1:0] wr_valid = 0;
wire [1:0] wr_ready, wr_done;

wire [DW-1:0] out_data; wire [63:0] out_be; wire out_valid, out_last; wire [15:0] out_len; wire [7:0] slot_count;
reg  out_ready = 1'b0;

wire        p_enable, p_flush, p_clear, p_idle, p_error, p_pending;
wire [4:0]  p_depth;
wire [63:0] p_base;
wire [3:0]  p_errcode;
wire [31:0] p_producer, p_fetch, p_inflight, p_reads, p_rerrs;

ssr_csr csr (
    .clk(clk), .rst(rst),
    .reg_wr_addr(csr_addr), .reg_wr_data(csr_wdata), .reg_wr_strb(4'hF), .reg_wr_en(csr_wr),
    .reg_wr_wait(), .reg_wr_ack(csr_wack),
    .reg_rd_addr(csr_addr), .reg_rd_data(csr_rdata), .reg_rd_en(csr_rd), .reg_rd_wait(), .reg_rd_ack(csr_rack),
    .o_prop_enable(p_enable), .o_prop_flush(p_flush), .o_prop_clear_error(p_clear),
    .o_prop_depth_log2(p_depth), .o_prop_base(p_base), .o_prop_producer(p_producer),
    .i_prop_idle(p_idle),
    .i_prop_error(p_error),
    .i_prop_pending(p_pending),
    .i_prop_error_code(p_errcode),
    .i_prop_consumer(consumer_out),
    .i_prop_fetch(p_fetch),
    .i_prop_inflight(p_inflight),
    .i_prop_reads(p_reads),
    .i_prop_read_errors(p_rerrs),
    // not in this bench: the core, delivery, the datapath counters
    .o_core_enable(), .o_core_reboot(), .o_activate_pending(), .o_cfg_run_id(), .o_cfg_membership(),
    .o_cfg_effective_round(), .o_pay_enable(), .o_ver_enable(), .o_payload_base(), .o_verdict_base(),
        .i_fault('0), .i_activate_taken('0), .i_halt('0), .i_timing_armed('0),
        .i_ptp_time_valid('0), .i_config_excludes_self('0), .i_round_id('0), .i_cur_run_id('0),
        .i_cur_sound_set('0), .i_cur_membership('0), .i_halt_reason('0), .i_halt_round_id('0),
        .i_halt_witness('0), .i_halt_membership('0), .i_halt_sound_set('0),
        .i_halt_prev_sound_set('0), .i_round_count('0), .i_commit_count('0),
        .i_halt_count('0), .i_time_fault_count('0), .i_unit_idle('0), .i_tag_high_water('0),
        .i_verdict_seq('0), .i_tx_ctrl_frames('0), .i_tx_pay_frames('0), .i_tx_empty('0),
        .i_tx_overrun('0), .i_tx_missed('0), .i_tx_host_frames('0), .i_tx_cpl_count('0),
        .i_tx_cpl_ts('0), .i_rx_frames('0), .i_rx_accept('0), .i_rx_ctrl('0), .i_rx_malformed('0),
        .i_rx_ctrl_late('0), .i_rx_window_drop('0), .i_rx_member_drop('0), .i_rx_sound_drop('0),
        .i_rx_run_drop('0), .i_rx_round_drop('0), .i_rx_stall('0), .i_rx_host_frames('0), .i_rx_ack_disagree('0),
        .i_stage_push('0), .i_stage_full('0), .i_pay_desc('0), .i_pay_cpl('0), .i_pay_err('0),
        .i_pay_starve('0), .i_pres_late('0), .i_pres_err('0),
        .i_pres_err_miss('0), .i_verdict_records('0), .i_verdict_err('0), .i_verdict_overflow('0),
        .i_verdict_stale('0)
);

ssr_proposal_dma_reader #(
    .RAM_ADDR_WIDTH(RAM_AW),
    .DMA_TAG_PROP(16'h0040), .PROPOSAL_SLOT_BYTES(SLOT_BYTES),
    .PROPOSAL_SLOT_COUNT(SLOT_COUNT), .MAX_INFLIGHT(MAX_IF)
) reader (
    .clk(clk), .rst(rst),
    .i_enable(p_enable), .i_flush(p_flush), .i_clear_error(p_clear), .i_ring_base(p_base),
    .i_depth_log2(p_depth), .i_producer(p_producer),
    .o_idle(p_idle), .o_error(p_error), .o_pending(p_pending), .o_error_code(p_errcode),
    .o_fetch(p_fetch), .o_inflight(p_inflight), .o_reads(p_reads), .o_read_errors(p_rerrs),
    .m_axis_dma_read_desc_dma_addr(rd_addr), .m_axis_dma_read_desc_ram_sel(rd_sel),
    .m_axis_dma_read_desc_ram_addr(rd_ram), .m_axis_dma_read_desc_len(rd_len),
    .m_axis_dma_read_desc_tag(rd_tag), .m_axis_dma_read_desc_valid(rd_valid),
    .m_axis_dma_read_desc_ready(rd_ready),
    .s_axis_dma_read_desc_status_tag(st_tag), .s_axis_dma_read_desc_status_error(st_err),
    .s_axis_dma_read_desc_status_valid(st_valid),
    .i_resv_ready(resv_ready), .i_resv_slot(resv_slot), .i_resv_addr(resv_addr), .o_resv(resv),
    .o_done(done), .o_done_slot(done_slot), .i_commit(commit), .i_settled(settled),
    .o_rewind(rewind), .o_flush(flush), .o_hold(hold), .o_consumer(consumer_out)
);

ssr_proposal_buffer #(
    .RAM_ADDR_WIDTH(RAM_AW), .PROPOSAL_SLOT_BYTES(SLOT_BYTES), .PROPOSAL_SLOT_COUNT(SLOT_COUNT)
) buffer (
    .clk(clk), .rst(rst),
    .o_resv_ready(resv_ready), .o_resv_slot(resv_slot), .o_resv_addr(resv_addr), .i_resv(resv),
    .i_done(done), .i_done_slot(done_slot), .o_commit(commit), .o_settled(settled),
    .i_rewind(rewind), .i_flush(flush), .i_hold(hold),
    .dma_ram_wr_cmd_sel(2'b00), .dma_ram_wr_cmd_be(wr_be), .dma_ram_wr_cmd_data(wr_data),
    .dma_ram_wr_cmd_addr(wr_addr), .dma_ram_wr_cmd_valid(wr_valid), .dma_ram_wr_cmd_ready(wr_ready),
    .dma_ram_wr_done(wr_done),
    .o_buf_rd_data(out_data), .o_buf_rd_be(out_be), .o_buf_rd_valid(out_valid), .i_buf_rd_ready(out_ready),
    .o_buf_tx_last(out_last), .o_buf_tx_len(out_len), .o_buf_slot_count(slot_count)
);

// ---------------------------------------------------------------- the host
// ring_seq[pos] is the absolute index of the entry the host last wrote at
// ring position pos - what the engine model reads.
integer ring_seq [0:(1<<DEPTH_LOG2)-1];
integer posted = 0;
task post(input integer n);
    integer i;
begin
    for (i = 0; i < n; i = i + 1) begin
        ring_seq[(posted + i) % (1 << DEPTH_LOG2)] = posted + i;
    end
    posted = posted + n;
    csr_write(R_PRODUCER, posted);
end
endtask

// ---------------------------------------------------------------- the read engine
// Descriptors are accepted into a table with a random latency each; whichever
// expires first is written into the RAM and completed. So completions come
// back out of order.
localparam integer ET = 16;
reg [63:0] e_addr [0:ET-1]; reg [RAM_AW-1:0] e_ram [0:ET-1]; reg [12:0] e_tag [0:ET-1];
integer    e_left [0:ET-1]; reg e_busy [0:ET-1];
integer    lat_min = 20, lat_span = 300;
integer    force_err_entry = -1;
integer    inflight_now = 0, inflight_max = 0, descs = 0;
integer    ei, seed = 7;
reg        addr_ok = 1'b1;
initial for (ei = 0; ei < ET; ei = ei + 1) e_busy[ei] = 0;

always @(posedge clk) if (!rst) begin
    for (ei = 0; ei < ET; ei = ei + 1) if (e_busy[ei] && e_left[ei] > 0) e_left[ei] = e_left[ei] - 1;
    if (rd_valid && rd_ready) begin : take
        integer f;
        f = -1;
        for (ei = ET-1; ei >= 0; ei = ei - 1) if (!e_busy[ei]) f = ei;
        e_addr[f] = rd_addr; e_ram[f] = rd_ram; e_tag[f] = rd_tag;
        e_left[f] = lat_min + ({$random(seed)} % lat_span); e_busy[f] = 1;
        descs = descs + 1;
        inflight_now = inflight_now + 1;
        if (inflight_now > inflight_max) inflight_max = inflight_now;
        if (rd_len != SLOT_BYTES || rd_sel != 0) addr_ok = 0;
    end
end

// The addresses must walk the ring in order. fetch_expect is the entry the
// next descriptor must be for; the tests move it where the RTL is meant to
// jump (clear_error back to CONSUMER, flush forward to PRODUCER).
integer fetch_expect = 0;
always @(posedge clk) if (!rst && rd_valid && rd_ready) begin
    if (rd_addr != RING_BASE + (((fetch_expect) % (1 << DEPTH_LOG2)) << 12)) begin
        errors = errors + 1;
        $display("  FAIL [%0t] read descriptor for %h, expected entry %0d at %h", $time, rd_addr,
                 fetch_expect, RING_BASE + (((fetch_expect) % (1 << DEPTH_LOG2)) << 12));
    end
    checks = checks + 1;
    fetch_expect = fetch_expect + 1;
end

initial begin : engine
    integer f, r, seq, pos;
    forever begin
        @(negedge clk);
        f = -1;
        for (ei = ET-1; ei >= 0; ei = ei - 1) if (e_busy[ei] && e_left[ei] == 0) f = ei;
        if (!rst && f >= 0) begin
            pos = (e_addr[f] - RING_BASE) >> 12;
            seq = ring_seq[pos];
            if (seq == force_err_entry) begin
                force_err_entry = -1;
                st_err = 4'd3;
            end else begin
                st_err = 4'd0;
                // a row at a time, both segments: beats 2r and 2r+1
                for (r = 0; r < ROWS; r = r + 1) begin
                    wr_addr  = {2{e_ram[f][RAM_AW-1:7] + r[SEG_AW-1:0]}};
                    wr_data  = {word(seq, 2*r+1), word(seq, 2*r)};
                    wr_be    = {2*SEG_BE{1'b1}};
                    wr_valid = 2'b11;
                    @(negedge clk);
                end
                wr_valid = 2'b00;
            end
            st_tag = e_tag[f]; st_valid = 1;
            e_busy[f] = 0; inflight_now = inflight_now - 1;
            @(negedge clk); st_valid = 0;
        end
    end
end

// ---------------------------------------------------------------- the sink (ssr_tx_engine)
reg     sink_random = 1'b0;
reg     sink_on     = 1'b1;
integer expect_entry = 0, expect_beat = 1, slots_out = 0, bubbles = 0;
reg     in_slot = 1'b0;
always @(posedge clk) begin
    if (rst) out_ready <= 1'b0;
    else     out_ready <= sink_on && (!sink_random || ({$random(seed)} % 4 != 0));
end
always @(posedge clk) if (!rst) begin
    // A beat per cycle while ready: once a slot has started, a ready cycle
    // without a beat is a bubble.
    if (in_slot && out_ready && !out_valid) bubbles = bubbles + 1;
    if (out_valid && out_ready) begin
        in_slot = 1'b1;
        checks = checks + 1;
        if (out_data !== word(expect_entry, expect_beat)) begin
            errors = errors + 1;
            $display("  FAIL [%0t] slot %0d beat %0d: got entry %0d beat %0d, expected entry %0d beat %0d",
                     $time, slots_out, expect_beat, out_data[7:0], out_data[15:8], expect_entry[7:0], expect_beat);
        end
        checks = checks + 1;
        if (out_last !== (expect_beat == BEATS-1)) begin
            errors = errors + 1;
            $display("  FAIL [%0t] tx_last %0b on beat %0d", $time, out_last, expect_beat);
        end
        if (expect_beat == BEATS-1) begin
            expect_beat = 1; expect_entry = expect_entry + 1; slots_out = slots_out + 1; in_slot = 1'b0;
        end else expect_beat = expect_beat + 1;
    end
end

integer max_slots = 0;
always @(posedge clk) if (!rst && slot_count > max_slots) max_slots = slot_count;

// ---------------------------------------------------------------- tests
reg [31:0] rd;
integer g;

task wait_out(input integer n, input integer max_cycles);
begin
    g = 0;
    while (slots_out < n && g < max_cycles) begin @(posedge clk); g = g + 1; end
    check(slots_out >= n, "slots streamed within the time allowed");
end
endtask

// A flush (or clear) is carried out once no read is in flight; until then
// STATUS.pending is set. The host waits for it before posting again - an entry
// posted while the flush is pending is flushed too.
task wait_flushed;
begin
    g = 0;
    rd = 32'h8;
    while (rd[3] && g < 10000) begin csr_read(R_STATUS, rd); g = g + 1; end
    check(!rd[3], "the flush was carried out");
end
endtask

initial begin
    $display("tb_ssr_proposal_ring: %0d slots, %0d in flight, ring of %0d", SLOT_COUNT, MAX_IF, 1 << DEPTH_LOG2);
    repeat (5) @(posedge clk); rst = 0; repeat (5) @(posedge clk);

    csr_write(R_BASE_LO, RING_BASE[31:0]);
    csr_write(R_BASE_HI, RING_BASE[63:32]);
    csr_write(R_DEPTH, DEPTH_LOG2);

    // ---- P0: the doorbell. Posted but disabled: nothing is read.
    banner("P0  nothing is read until enabled, and then only what was posted");
    post(3);
    repeat (50) @(posedge clk);
    check(descs == 0, "no read while disabled");
    sink_on = 1'b0;                       // hold the stream: P1 checks the rate on a full buffer
    csr_write(R_CONTROL, 32'h1);
    repeat (1000) @(posedge clk);
    check(descs == 3, "exactly the three posted entries are read");
    csr_read(R_CONSUMER, rd); check(rd == 3, "CONSUMER counts the three");
    csr_read(R_FETCH, rd);    check(rd == 3, "FETCH counts the three");

    // ---- P1: many entries, out-of-order completions, the ring wraps twice.
    banner("P1  40 entries through a 16-entry ring: reads in flight, completions out of order, streamed in order at one beat a cycle");
    post(13);                             // 16 posted: the ring is full
    repeat (2000) @(posedge clk);
    check(max_slots <= SLOT_COUNT, "never more than eight slots in use");
    csr_read(R_CONSUMER, rd); check(rd == 8, "with the stream held, eight entries fill the buffer and stop");
    sink_on = 1'b1;
    wait_out(16, 40000);
    post(12); wait_out(28, 40000);
    post(12); wait_out(40, 40000);
    repeat (100) @(posedge clk);
    check(slots_out == 40, "40 slots streamed");
    check(bubbles == 0, "no bubble inside a slot while the sink was ready: one beat per cycle");
    check(inflight_max == MAX_IF, "reads really were in flight together (max in flight == MAX_INFLIGHT)");
    check(addr_ok, "every descriptor: one slot long, RAM_SEL_PROP");
    csr_read(R_CONSUMER, rd); check(rd == 40, "CONSUMER == 40");
    check(consumer_out == 40, "o_consumer (to the verdict record) == 40");
    $display("        max in flight %0d, max slots committed %0d, bubbles %0d", inflight_max, max_slots, bubbles);

    // ---- P2: back pressure on the stream.
    banner("P2  the stream under random back pressure: nothing lost, nothing out of order");
    sink_random = 1'b1;
    post(10); wait_out(50, 80000);
    sink_random = 1'b0;
    repeat (50) @(posedge clk);
    check(slots_out == 50, "50 slots");

    // ---- P3: an error. Entry 53 fails; 50..52 go out, 53.. wait; clear; all go.
    banner("P3  a failed read: CONSUMER stops on it, nothing more is read, clear re-fetches it and the rest");
    force_err_entry = 53;
    post(8);                                                      // 50..57
    repeat (3000) @(posedge clk);
    csr_read(R_STATUS, rd);
    check(rd[2] == 1'b1, "STATUS.error");
    check(rd[1] == 1'b1, "STATUS.idle: nothing left in flight");
    csr_read(R_CONSUMER, rd); check(rd == 53, "CONSUMER settles on the failed entry (53)");
    csr_read(R_ERRCODE, rd);  check(rd == 3, "ERROR_CODE is the engine's");
    csr_read(R_RERRS, rd);    check(rd == 1, "READ_ERRORS == 1");
    check(slots_out == 53, "the three before it streamed, nothing after");
    csr_read(R_FETCH, rd);
    g = rd;
    repeat (500) @(posedge clk);
    csr_read(R_FETCH, rd); check(rd == g, "no new reads while in error");
    fetch_expect = 53;                                            // clear re-reads from CONSUMER
    csr_write(R_CONTROL, 32'h5);                                 // enable | clear error
    wait_out(58, 40000);
    csr_read(R_STATUS, rd); check(rd[2] == 1'b0, "error cleared");
    csr_read(R_CONSUMER, rd); check(rd == 58, "CONSUMER == 58: 53..57 were fetched again");

    // ---- P4: flush.
    banner("P4  flush drops what has not started streaming; what is posted after goes out");
    sink_on = 1'b0;
    post(6);                                                      // 58..63, held in the buffer
    repeat (3000) @(posedge clk);
    check(slot_count == 6, "six committed, stream held");
    csr_write(R_CONTROL, 32'h3);                                 // enable | flush
    wait_flushed;
    check(slot_count == 0, "flush emptied the buffer");
    csr_read(R_CONSUMER, rd); check(rd == 64, "CONSUMER jumped to PRODUCER");
    expect_entry = 64;                                            // 58..63 are gone
    fetch_expect = 64;
    sink_on = 1'b1;
    post(3); wait_out(61, 40000);
    repeat (100) @(posedge clk);
    check(slots_out == 61, "only the three posted after the flush streamed");
    check(bubbles == 0, "still one beat per cycle");

    // ---- P5: flush with a slot half on the wire. It must finish whole; the
    // rest go. (P4 flushed a head slot the RAM was reading but whose first beat
    // had not gone out: that one is dropped and its readout drained.)
    banner("P5  flush mid-slot: the slot on the wire finishes, the rest are dropped");
    post(4);                                                      // 67..70
    g = 0;
    while (!(slots_out == 61 && expect_beat >= 20) && g < 40000) begin @(posedge clk); g = g + 1; end
    check(g < 40000, "entry 67 is half out");
    sink_on = 1'b0;                                               // 67 stays half out until the flush is done
    csr_write(R_CONTROL, 32'h3);                                 // enable | flush
    fetch_expect = 71;
    wait_flushed;
    sink_on = 1'b1;
    wait_out(62, 40000);                                          // 67 finishes
    expect_entry = 71;                                            // 68..70 are gone
    post(2); wait_out(64, 40000);
    repeat (100) @(posedge clk);
    check(slots_out == 64, "67 whole, then only 71 and 72");
    csr_read(R_CONSUMER, rd); check(rd == 73, "CONSUMER == PRODUCER == 73");

    // ---- P6: the flush waits for a slow read. Meanwhile the slot on the wire
    // finishes - and the committed slots behind it must NOT start: they were
    // not on the wire when the host asked.
    banner("P6  while a flush waits for a read, no new slot starts");
    post(1);                                                      // 73
    g = 0;
    while (!(slots_out == 64 && expect_beat >= 5) && g < 40000) begin @(posedge clk); g = g + 1; end
    check(g < 40000, "entry 73 is on the wire");
    sink_on = 1'b0;
    post(2);                                                      // 74, 75: committed behind 73
    g = 0;
    while (slot_count != 3 && g < 40000) begin @(posedge clk); g = g + 1; end
    check(slot_count == 3, "73 (streaming), 74 and 75 committed");
    lat_min = 3000;
    post(1);                                                      // 76: a slow read
    repeat (20) @(posedge clk);
    csr_write(R_CONTROL, 32'h3);                                 // enable | flush: pending on 76
    fetch_expect = 77;
    sink_on = 1'b1;
    wait_out(65, 40000);                                          // 73 finishes under the pending flush
    expect_entry = 77;                                            // 74..76 are gone
    repeat (200) @(posedge clk);
    csr_read(R_STATUS, rd); check(rd[3] == 1'b1, "the flush is still pending (76 in flight)");
    check(slots_out == 65, "nothing started after 73 while the flush was pending");
    wait_flushed;
    lat_min = 20;
    post(1); wait_out(66, 40000);                                 // 77
    repeat (100) @(posedge clk);
    check(slots_out == 66, "73 whole, then only 77");
    check(bubbles == 0, "still one beat per cycle");

    $display("");
    $display("  tb_ssr_proposal_ring: %0d checks, %0d failures", checks, errors);
    if (errors == 0) $display("  PASS"); else $display("  FAIL");
    $finish;
end

initial begin #20_000_000; $display("  FAIL: timeout"); $finish; end

endmodule

`resetall
