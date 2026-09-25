`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_proposal_buffer - the on-chip ring of proposal slots between the host's
 * proposal ring and ssr_tx_engine.
 *
 * WHAT A SLOT IS
 *   One page, and the frame it becomes is one page: 64 bytes of header and
 *   4032 of payload. The host writes its payload at offset 64 of a proposal
 *   entry and leaves its first 64 bytes alone (ssr_packet.vh, "A PROPOSAL ENTRY
 *   HAS THE SAME SHAPE AS A FRAME"); the DMA copies the whole entry into a slot,
 *   and ssr_tx_engine composes the header and puts it in front. So the transmit
 *   side streams beats 1..63 of a slot (a beat is 64 bytes), and the length it
 *   reports is the slot less the header beat.
 *
 * HOW A BEAT SITS IN THE RAM
 *   Corundum's DMA RAM is RAM_SEG_COUNT segments side by side, one RAM row being
 *   one address in every segment. On the AU200 a segment is 512 bits, so a row
 *   is 1024 bits: two beats. The DMA engine writes an entry a whole row a cycle;
 *   beat b of slot s is in segment b % 2, at row s*32 + b/2. The transmit side
 *   reads it back one beat a cycle, from alternating segments - a beat is one
 *   segment, and no width conversion happens anywhere.
 *
 * THREE POINTERS, BECAUSE THE READS COMPLETE OUT OF ORDER
 *   ssr_proposal_dma_reader keeps several DMA reads in flight, one slot each, and
 *   Corundum's read engine may complete them in any order. So a slot goes
 *   through three states, and the ring has a pointer at each boundary:
 *
 *       resv_ptr     next slot to hand out for a read       (reader's side)
 *       commit_ptr   first slot not yet transmittable       (in ring order)
 *       head_ptr     slot being, or next to be, streamed    (ssr_tx_engine's side)
 *
 *       [head, commit)   committed: whole, in order, counted in o_buf_slot_count
 *       [commit, resv)   reserved: a read was issued; done[] says which landed
 *
 *   A read's completion sets its slot's done bit, whatever its position. The
 *   commit pointer walks forward over done bits, one slot a cycle, and stops
 *   at the first slot whose read has not completed - so slots become
 *   transmittable in ring order, which is the order the host posted them in.
 *   A slot is free again once ssr_tx_engine has taken its last beat (head moves).
 *
 *   A read that FAILS never sets its done bit, so commit stops in front of it
 *   and everything behind it waits. That is on purpose: the reader stops on an
 *   error, and when the host clears it the reader asks for i_rewind, which
 *   gives back every reserved slot (resv = commit) so the failed entry and the
 *   ones after it are fetched again, in order, into the same slots.
 *
 * THE TRANSMIT SIDE IS PIPELINED
 *   Commands for beats 1..63 of the head slot are issued to the RAM back to
 *   back, each to its own segment, and the RAM's responses are the stream:
 *   o_buf_rd_valid is the response of the segment holding the next beat,
 *   i_buf_rd_ready is its ready. dma_psdpram keeps each segment's responses in
 *   order and holds them while ready is low, so taking beats from alternating
 *   segments keeps them in order, and the stream runs at one beat per cycle - 128 Gbit/s at 250 MHz,
 *   above the 100 Gbit/s the port can take - and a 4 KiB frame costs 64
 *   cycles, which is what ssr_dataplane's LAST_ARRIVAL_NS check assumes.
 *
 *   The previous engine issued one command, waited for its response, handed
 *   it on and only then issued the next: four cycles a beat, a quarter of line
 *   rate. A fragment took ~1 us on the wire and only three fitted in a round.
 *
 *   Commands for the next slot start only after the current one's last beat
 *   has been handed out. The bubble that leaves (the RAM's pipeline depth) is
 *   inside ssr_tx_engine's pacing gap, which is 82 cycles.
 *
 * FLUSH
 *   i_flush drops every reserved slot and every committed one that has not
 *   put a beat on the stream yet; a slot with beats already out finishes (it is
 *   on the wire). The head slot is usually already being READ from the RAM
 *   before ssr_tx_engine takes its first beat - the readout starts as soon as it
 *   commits - so dropping it means aborting that readout: stop issuing
 *   commands, swallow the responses still in the RAM's pipeline (counted in
 *   pend_reg), then go idle. The reader only raises i_flush when no read is
 *   in flight, which can be a while after the host asked; i_hold is high in
 *   between, and no new slot starts under it - so what is flushed is what had
 *   not started when the host asked, not when the last read came back.
 */

module ssr_proposal_buffer #
(
    parameter DMA_LEN_WIDTH = 16,
    parameter RAM_SEL_WIDTH = 1,
    parameter RAM_SEL_PROP = 0,
    parameter RAM_ADDR_WIDTH = 17,
    parameter RAM_SEG_COUNT = 2,
    parameter RAM_SEG_DATA_WIDTH = 512*2/RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = RAM_SEG_DATA_WIDTH/8,
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,
    parameter PROPOSAL_SLOT_BYTES = 4096,
    parameter PROPOSAL_SLOT_COUNT = 8,
    // derived; do not override
    parameter SLOT_PTR_WIDTH = PROPOSAL_SLOT_COUNT > 1 ? $clog2(PROPOSAL_SLOT_COUNT) : 1
)
(
    input  wire                                             clk,
    input  wire                                             rst,

    // ---- the reader's side -------------------------------------------------
    output wire                                             o_resv_ready,  // a slot is free to read into
    output wire [SLOT_PTR_WIDTH-1:0]                        o_resv_slot,
    output wire [RAM_ADDR_WIDTH-1:0]                        o_resv_addr,   // that slot's first byte
    input  wire                                             i_resv,        // a read was issued into it
    input  wire                                             i_done,        // a read completed without error
    input  wire [SLOT_PTR_WIDTH-1:0]                        i_done_slot,
    output wire                                             o_commit,      // one slot became transmittable
    output wire                                             o_settled,     // nothing more will commit on its own
    input  wire                                             i_rewind,      // give back every reserved slot
    input  wire                                             i_flush,       // drop everything not yet streaming
    input  wire                                             i_hold,        // a flush is pending: start no new slot

    // ---- DMA RAM write interface (the read engine writes the slots) --------
    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]           dma_ram_wr_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]        dma_ram_wr_cmd_be,
    input  wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      dma_ram_wr_cmd_data,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]      dma_ram_wr_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                         dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                         dma_ram_wr_done,

    // ---- the stream to ssr_tx_engine -------------------------------------------
    // One beat: one RAM segment.
    output wire [RAM_SEG_DATA_WIDTH-1:0]                    o_buf_rd_data,
    output wire [RAM_SEG_BE_WIDTH-1:0]                      o_buf_rd_be,
    output wire                                             o_buf_rd_valid,
    input  wire                                             i_buf_rd_ready,
    output wire                                             o_buf_tx_last,
    output wire [DMA_LEN_WIDTH-1:0]                         o_buf_tx_len,

    // How many whole slots are committed right now. Nothing in ssr_dataplane
    // reads it any more - ssr_tx_engine starts a fragment when the first beat
    // is offered, it does not plan a round - but the proposal-ring bench does.
    output wire [7:0]                                       o_buf_slot_count
);

localparam integer SLOT_BYTE_ADDR_W = $clog2(PROPOSAL_SLOT_BYTES);
localparam integer BEAT_BYTES       = RAM_SEG_BE_WIDTH;                      // a beat is a segment
localparam integer ROW_BYTES        = RAM_SEG_COUNT * RAM_SEG_BE_WIDTH;      // a row is RAM_SEG_COUNT beats
localparam integer SLOT_BEATS       = PROPOSAL_SLOT_BYTES / BEAT_BYTES;      // 64
localparam integer SLOT_ROWS        = PROPOSAL_SLOT_BYTES / ROW_BYTES;       // 32 on the AU200
localparam integer BEAT_W           = $clog2(SLOT_BEATS);
localparam integer RAM_SIZE         = PROPOSAL_SLOT_BYTES * PROPOSAL_SLOT_COUNT;
localparam integer PW               = SLOT_PTR_WIDTH + 1;      // one extra bit: full vs empty

localparam [BEAT_W-1:0] FIRST_BEAT = 1;                // beat 0 is the header's
localparam [BEAT_W-1:0] LAST_BEAT  = SLOT_BEATS - 1;
localparam [PW-1:0]     SLOTS     = PROPOSAL_SLOT_COUNT;

initial begin
    if (PROPOSAL_SLOT_BYTES & (PROPOSAL_SLOT_BYTES-1)) begin
        $error("ssr_proposal_buffer: PROPOSAL_SLOT_BYTES (%0d) must be a power of 2", PROPOSAL_SLOT_BYTES);
        $finish;
    end
    if (PROPOSAL_SLOT_COUNT < 2 || (PROPOSAL_SLOT_COUNT & (PROPOSAL_SLOT_COUNT-1))) begin
        $error("ssr_proposal_buffer: PROPOSAL_SLOT_COUNT (%0d) must be a power of 2, at least 2", PROPOSAL_SLOT_COUNT);
        $finish;
    end
    if (RAM_SEG_COUNT * RAM_PIPELINE > 14) begin
        $error("ssr_proposal_buffer: RAM_SEG_COUNT*RAM_PIPELINE (%0d) > 14 overflows pend_reg", RAM_SEG_COUNT*RAM_PIPELINE);
        $finish;
    end
    if (RAM_SEG_COUNT < 1 || (RAM_SEG_COUNT & (RAM_SEG_COUNT-1)) || PROPOSAL_SLOT_BYTES % ROW_BYTES != 0) begin
        $error("ssr_proposal_buffer: RAM_SEG_COUNT (%0d) must be a power of 2 dividing a slot into whole rows", RAM_SEG_COUNT);
        $finish;
    end
    if (RAM_SIZE > (1 << RAM_ADDR_WIDTH)) begin
        $error("ssr_proposal_buffer: %0d slots of %0d bytes do not fit RAM_ADDR_WIDTH %0d", PROPOSAL_SLOT_COUNT, PROPOSAL_SLOT_BYTES, RAM_ADDR_WIDTH);
        $finish;
    end
    if (PROPOSAL_SLOT_BYTES > (1 << DMA_LEN_WIDTH) - 1) begin
        $error("ssr_proposal_buffer: PROPOSAL_SLOT_BYTES (%0d) exceeds DMA_LEN_WIDTH", PROPOSAL_SLOT_BYTES);
        $finish;
    end
end

// ---------------------------------------------------------------- pointers
reg [PW-1:0] resv_ptr_reg   = {PW{1'b0}};
reg [PW-1:0] commit_ptr_reg = {PW{1'b0}};
reg [PW-1:0] head_ptr_reg   = {PW{1'b0}};
reg [PROPOSAL_SLOT_COUNT-1:0] done_reg = {PROPOSAL_SLOT_COUNT{1'b0}};

wire [SLOT_PTR_WIDTH-1:0] resv_slot   = resv_ptr_reg[SLOT_PTR_WIDTH-1:0];
wire [SLOT_PTR_WIDTH-1:0] commit_slot = commit_ptr_reg[SLOT_PTR_WIDTH-1:0];
wire [SLOT_PTR_WIDTH-1:0] head_slot   = head_ptr_reg[SLOT_PTR_WIDTH-1:0];

wire [PW-1:0] in_use    = resv_ptr_reg - head_ptr_reg;
wire [PW-1:0] committed = commit_ptr_reg - head_ptr_reg;

assign o_resv_ready = (in_use < SLOTS);
assign o_resv_slot  = resv_slot;
assign o_resv_addr  = {{(RAM_ADDR_WIDTH-SLOT_PTR_WIDTH){1'b0}}, resv_slot} << SLOT_BYTE_ADDR_W;

wire commit_fire = (commit_ptr_reg != resv_ptr_reg) && done_reg[commit_slot];
assign o_commit  = commit_fire;
assign o_settled = !commit_fire;

assign o_buf_slot_count = {{(8-PW){1'b0}}, committed};

// ---------------------------------------------------------------- transmit side
// Beat b of the head slot lives in segment b % RAM_SEG_COUNT, at row
// head_slot*SLOT_ROWS + b / RAM_SEG_COUNT. A command goes to that one segment;
// the next beat's response is taken from that segment's pipeline. Each
// segment returns its responses in order, so the beats come out in order.
reg               tx_active_reg = 1'b0;          // the head slot is being read out
reg  [BEAT_W-1:0] cmd_beat_reg  = FIRST_BEAT;    // next beat to ask the RAM for
reg               cmd_done_reg  = 1'b0;          // every beat of the slot has been asked for
reg  [BEAT_W-1:0] out_beat_reg  = FIRST_BEAT;    // beat the stream is offering
reg               started_reg   = 1'b0;          // a beat of the head slot has gone out
reg               abort_reg     = 1'b0;          // flushed before it started: drain, then idle
reg  [3:0]        pend_reg      = 4'd0;          // commands whose response is not yet taken

wire [RAM_SEG_COUNT-1:0]                    ram_rd_cmd_ready;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] ram_rd_resp_data;
wire [RAM_SEG_COUNT-1:0]                    ram_rd_resp_valid;

wire [31:0] cmd_seg = cmd_beat_reg % RAM_SEG_COUNT;
wire [31:0] out_seg = out_beat_reg % RAM_SEG_COUNT;
wire [RAM_SEG_COUNT-1:0] cmd_seg_onehot = 1 << cmd_seg;
wire [RAM_SEG_COUNT-1:0] out_seg_onehot = 1 << out_seg;

wire tx_start   = !tx_active_reg && (committed != {PW{1'b0}}) && !i_hold && !i_flush && !i_rewind;
wire cmd_valid  = tx_active_reg && !cmd_done_reg && !abort_reg;
wire cmd_fire   = cmd_valid && ram_rd_cmd_ready[cmd_seg];
// While aborting, every segment's responses are swallowed; otherwise only the
// segment holding the next beat is taken from, and only when the sink is ready.
wire [RAM_SEG_COUNT-1:0] resp_ready = !tx_active_reg ? {RAM_SEG_COUNT{1'b0}}
                                    : abort_reg      ? {RAM_SEG_COUNT{1'b1}}
                                    : (i_buf_rd_ready ? out_seg_onehot : {RAM_SEG_COUNT{1'b0}});
wire [RAM_SEG_COUNT-1:0] resp_fire  = ram_rd_resp_valid & resp_ready;
wire out_valid  = tx_active_reg && !abort_reg && ram_rd_resp_valid[out_seg];
wire out_fire   = out_valid && i_buf_rd_ready;
wire out_last   = (out_beat_reg == LAST_BEAT);
wire pop_fire   = out_fire && out_last;
wire started    = started_reg || out_fire;

// How many responses were taken this cycle (more than one only while aborting).
// A function behind a continuous assign rather than an always @*, so it has a
// value from time 0: pend_reg is only ever corrected by arithmetic, and one X
// in it would hold an abort open forever.
function [3:0] popcount(input [RAM_SEG_COUNT-1:0] v);
    integer k;
begin
    popcount = 4'd0;
    for (k = 0; k < RAM_SEG_COUNT; k = k + 1)
        popcount = popcount + v[k];
end
endfunction
wire [3:0] resp_fire_count = popcount(resp_fire);

wire [RAM_SEG_ADDR_WIDTH-1:0] cmd_addr = head_slot * SLOT_ROWS + cmd_beat_reg / RAM_SEG_COUNT;

assign o_buf_rd_data  = ram_rd_resp_data[out_seg*RAM_SEG_DATA_WIDTH +: RAM_SEG_DATA_WIDTH];
assign o_buf_rd_be    = {RAM_SEG_BE_WIDTH{1'b1}};
assign o_buf_rd_valid = out_valid;
assign o_buf_tx_last  = out_valid && out_last;
assign o_buf_tx_len   = PROPOSAL_SLOT_BYTES - BEAT_BYTES;

// ---------------------------------------------------------------- sequential
integer di;
always @(posedge clk) begin
    // ---- reader side
    if (i_resv) resv_ptr_reg <= resv_ptr_reg + 1'b1;
    if (i_done) done_reg[i_done_slot] <= 1'b1;
    if (commit_fire) begin
        done_reg[commit_slot] <= 1'b0;
        commit_ptr_reg        <= commit_ptr_reg + 1'b1;
    end

    // ---- transmit side
    if (tx_start) begin
        tx_active_reg <= 1'b1;
        cmd_beat_reg  <= FIRST_BEAT;
        cmd_done_reg  <= 1'b0;
        out_beat_reg  <= FIRST_BEAT;
        started_reg   <= 1'b0;
    end
    pend_reg <= pend_reg + (cmd_fire ? 4'd1 : 4'd0) - resp_fire_count;
    if (out_fire) started_reg <= 1'b1;
    if (abort_reg && pend_reg == 4'd0) begin
        abort_reg     <= 1'b0;
        tx_active_reg <= 1'b0;
    end
    if (cmd_fire) begin
        if (cmd_beat_reg == LAST_BEAT) cmd_done_reg <= 1'b1;
        else                           cmd_beat_reg <= cmd_beat_reg + 1'b1;
    end
    if (out_fire) out_beat_reg <= out_beat_reg + 1'b1;
    if (pop_fire) begin
        tx_active_reg <= 1'b0;
        head_ptr_reg  <= head_ptr_reg + 1'b1;
    end

    // ---- rewind and flush. The reader raises these only with nothing in
    // flight and nothing left to commit, so no i_resv, i_done or commit_fire
    // can land on the same cycle; the transmit side may, and is accounted for.
    if (i_rewind) begin
        resv_ptr_reg <= commit_ptr_reg;
        done_reg     <= {PROPOSAL_SLOT_COUNT{1'b0}};
    end
    if (i_flush) begin
        // Keep the slot with beats on the wire; drop the rest. If it finishes
        // this very cycle, head+1 is the new head either way.
        if (tx_active_reg && started) begin
            commit_ptr_reg <= head_ptr_reg + 1'b1;
            resv_ptr_reg   <= head_ptr_reg + 1'b1;
        end else begin
            commit_ptr_reg <= head_ptr_reg;
            resv_ptr_reg   <= head_ptr_reg;
            if (tx_active_reg) abort_reg <= 1'b1;
        end
        done_reg <= {PROPOSAL_SLOT_COUNT{1'b0}};
    end

    if (rst) begin
        resv_ptr_reg   <= {PW{1'b0}};
        commit_ptr_reg <= {PW{1'b0}};
        head_ptr_reg   <= {PW{1'b0}};
        done_reg       <= {PROPOSAL_SLOT_COUNT{1'b0}};
        tx_active_reg  <= 1'b0;
        cmd_beat_reg   <= FIRST_BEAT;
        cmd_done_reg   <= 1'b0;
        out_beat_reg   <= FIRST_BEAT;
        started_reg    <= 1'b0;
        abort_reg      <= 1'b0;
        pend_reg       <= 4'd0;
    end
end

// ---------------------------------------------------------------- the RAM
dma_psdpram #(
    .SIZE(RAM_SIZE),
    .SEG_COUNT(RAM_SEG_COUNT),
    .SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .PIPELINE(RAM_PIPELINE)
)
proposal_ram_inst (
    .clk(clk),
    .rst(rst),

    .wr_cmd_be(dma_ram_wr_cmd_be),
    .wr_cmd_addr(dma_ram_wr_cmd_addr),
    .wr_cmd_data(dma_ram_wr_cmd_data),
    .wr_cmd_valid(dma_ram_wr_cmd_valid),
    .wr_cmd_ready(dma_ram_wr_cmd_ready),
    .wr_done(dma_ram_wr_done),

    .rd_cmd_addr({RAM_SEG_COUNT{cmd_addr}}),
    .rd_cmd_valid(cmd_valid ? cmd_seg_onehot : {RAM_SEG_COUNT{1'b0}}),
    .rd_cmd_ready(ram_rd_cmd_ready),
    .rd_resp_data(ram_rd_resp_data),
    .rd_resp_valid(ram_rd_resp_valid),
    .rd_resp_ready(resp_ready)
);

endmodule

`resetall
