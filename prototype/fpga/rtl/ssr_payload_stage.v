`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_payload_stage - the landing ring for peer payload on its way to host memory
 *
 * WHY THIS MODULE EXISTS AT ALL
 *   Under speculative delivery (docs/speculative_delivery.md) a peer's payload
 *   is DMA'd to host memory as it arrives, without waiting for the round's
 *   verdict. It cannot go straight from the wire to PCIe: Corundum's DMA write
 *   engine is handed a descriptor naming a segmented on-chip RAM (ram_sel +
 *   ram_addr) and reads the bytes out of it. There is no path from an
 *   AXI-Stream beat into a TLP. So a staging RAM is unavoidable.
 *
 *   What changes versus commit_assembler is what SIZES it. commit_assembler is
 *   sized by P_ROUND_DEPTH * N * stride - by how long the PROTOCOL must hold the
 *   bytes. This ring is sized by how long PCIe takes to drain one FRAME, and a
 *   frame is bounded by the MTU, not by the round's payload.
 *
 *   That second half is load-bearing. A node's payload for one round can be
 *   hundreds of kilobytes; no Ethernet frame can be. So the payload is
 *   fragmented at SSR_FRAG_BYTES (see ssr_packet.vh) and this ring is sized by
 *   the fragment. On-chip storage is therefore independent of the round depth,
 *   the node count AND the payload size - it is a constant set by the MTU and
 *   the DMA turnaround, and nothing else.
 *
 * A SLOT IS A FRAME IS A PAGE
 *   A frame is exactly 4096 bytes: 64 of header and up to 4032 of payload. A
 *   slot here is exactly one frame, and a frame lands in host memory as exactly
 *   one page, header on top. So a slot holds, beat by beat (a beat is 64 bytes)
 *
 *       beat 0        the 64-byte frame header, as it was on the wire
 *       beat 1..63    the payload, beat for beat
 *
 * HOW A BEAT SITS IN THE RAM
 *   Corundum's DMA RAM is RAM_SEG_COUNT segments side by side; one RAM row is
 *   one address in every segment. On the AU200 (PCIe Gen3 x16, 512-bit TLPs) a
 *   segment is 512 bits, so a row is 1024 bits: TWO beats. Byte address a is
 *   in segment (a / 64) % 2, at segment address a / 128 - so beat b of a slot
 *   is segment b % 2, row slot*32 + b/2. This module writes one beat a cycle,
 *   into one segment; the DMA engine reads the slot back a whole row (two
 *   beats) a cycle. Nothing converts widths: a beat is simply one segment.
 *
 *   and ONE descriptor moves the whole slot to the page. There is no header
 *   page in the host layout, no second descriptor for fragment 0, and no waste
 *   in the slot: 64 KiB of staging RAM is sixteen frames.
 *
 *   The header is staged rather than discarded because it IS what the host
 *   wants at the top of every page: node_id, run_id, round_id, frag_idx,
 *   length are already in it, already 64 bytes, already one beat. Every page
 *   is self-describing on its own, which is worth more than the 64 bytes.
 *
 *   An earlier layout put the header in a page of its own at the top of the
 *   node's region so the 4096-byte payload stayed page-aligned. Making the
 *   frame the page instead deletes that page, the second descriptor, and the
 *   state machine that sequenced it.
 *
 * A SLOT IS RELEASED BY THE DMA COMPLETION, NOT BY THE POP
 *   The DMA write engine takes a descriptor into its op table and reads the
 *   staging RAM AFTERWARDS, asynchronously, over the cycles it takes to form
 *   the TLPs - and under PCIe back pressure that can be microseconds. Between
 *   the pop and the completion the slot's bytes are still being read. If the
 *   pop released the slot, the next frame off the wire could overwrite it
 *   first, and the host would receive the next frame's bytes under this
 *   frame's header.
 *
 *   The old commit_dma_writer never had this problem because it was serial:
 *   issue, wait for the status, pop. Several descriptors in flight is the whole
 *   point of this path, so the release has to come from the completion. Hence
 *   THREE pointers, not two:
 *
 *       tail_ptr   the slot being written off the wire
 *       head_ptr   the slot whose descriptor is being handed out
 *       free_ptr   the oldest slot the DMA engine may still be reading
 *
 *   and two bits per slot: handed out, and still outstanding. free_ptr
 *   advances past a slot when its descriptor has been handed out AND has
 *   completed. Completions may arrive in any order - the per-slot bit is what
 *   makes that fine - but slots are released in order, because the ring is a
 *   ring.
 *
 *   This is also why a slot is the right unit for the receive side, and not a
 *   byte-granular ring: a slot is one thing the engine can be reading, and one
 *   bit per slot says whether it still is. A byte ring with out-of-order
 *   completions fragments its free space instead.
 *
 *   The completion carries the slot number back through ssr_dma_tag_pool's
 *   per-tag meta field: ssr_payload_dma_writer puts o_head_slot into i_alloc_meta,
 *   and o_cpl_meta comes back here as i_done_slot.
 *
 * WHY A RING OF WHOLE FRAMES IS ENOUGH
 *   Frames on one RX port are serialised by the MAC. ssr_rx_engine sees one frame at
 *   a time, start to finish, never interleaved. So a ring of frame-sized slots
 *   written sequentially holds everything, and a slot's bytes are contiguous -
 *   which is what lets the DMA writer describe a whole frame with one
 *   descriptor. Two RX ports feeding one ring would break this; see
 *   docs/speculative_delivery.md section 14.
 *
 * WHAT IT DOES NOT DO
 *   It never back-pressures. o_pl_ready is tied high, for the same reason
 *   commit_assembler ties it high: holding the wire side off cannot help, because
 *   the bytes are already on the wire and the MAC will not wait. When there is
 *   no free slot the frame is DISCARDED and o_full_count counts it. The node
 *   whose frame was dropped simply does not get its present_set bit for that
 *   round, which is the same outcome as if the frame had been truncated in
 *   flight - and the host is told, through commit_set[k] & ~present_set[k].
 *
 *   That is a deliberate degradation path, not an oversight: PCIe falling behind
 *   the wire costs a node its round, never the protocol its safety.
 *
 * WHAT COUNTS AS A FRAME HERE
 *   One i_pl_sof, then one or more beats, then exactly one of i_pl_commit /
 *   i_pl_drop. That is ssr_rx_engine's contract. There is no header-only payload
 *   frame any more - "proposed nothing" is a control frame - so i_pl_len == 0
 *   is malformed here and the frame occupies no slot.
 *
 * WHEN THINGS ARE WRITTEN, AND WHY THE HEADER GOES LAST
 *   ssr_rx_engine raises i_pl_sof on the SAME cycle as the frame's first payload
 *   beat - sof is registered off the header beat and the bus has already moved
 *   on. This module has one RAM write port. If it wrote the header on sof, the
 *   first payload beat of every frame would be lost, silently, with the length
 *   cross-check the only thing left to notice.
 *
 *   An earlier version did exactly that, and its bench hid it by driving sof a
 *   cycle early - modelling the comment instead of the module. So:
 *
 *     on sof       latch the header and the tag; the beat on the bus is the
 *                  first payload beat and goes to beat 1
 *     each beat    beat 1, 2, 3 ...
 *     on commit    write the latched header to beat 0, and push the slot
 *
 *   The commit cycle is the one cycle guaranteed free of a beat: ssr_rx_engine
 *   raises commit on the frame's last beat and it lands the cycle after, by
 *   which time the engine is back in S_HDR and o_pl_valid is structurally low.
 *   That is a property of ssr_rx_engine's FSM, not a timing assumption, and it is
 *   what makes one write port enough.
 *
 *   A frame here is ONE FRAGMENT of one node's payload for one round, not the
 *   whole thing. Reassembly is the host's memory map doing the work: every
 *   fragment is written at its own frag_off inside the node's region, so the
 *   bytes land contiguous without anyone copying them. ssr_presence_tracker is what
 *   decides a node is complete; this module never looks across frames.
 *
 * RELATIONSHIP TO commit_buffer
 *   This is commit_buffer's ring with three changes: slots carry metadata
 *   (round, node, length, frag_off) so the DMA writer can compute a host
 *   address; a slot is pushed on i_pl_commit rather than on a beat count,
 *   because frames are not all the same length; and the dead dma_ram_rd_cmd_sel
 *   input is gone.
 *
 * WHAT IT DOES NOT CHECK
 *   dma_psdpram's write side is always ready (wr_cmd_ready is tied to 1 inside
 *   it) and wr_done is a one-cycle echo of wr_cmd_valid. Neither is consulted.
 */

module ssr_payload_stage #
(
    parameter integer AXIS_DATA_WIDTH    = 512,

    parameter integer DMA_LEN_WIDTH      = 16,
    parameter integer RAM_ADDR_WIDTH     = 17,
    parameter integer RAM_SEG_COUNT      = 2,
    parameter integer RAM_SEG_DATA_WIDTH = 512,
    parameter integer RAM_SEG_BE_WIDTH   = RAM_SEG_DATA_WIDTH/8,
    parameter integer RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH-$clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH),
    parameter integer RAM_PIPELINE       = 2,

    // Bytes per staged frame: one frame, one page, no waste. Sized by the MTU,
    // never by the round's payload - a 250 KiB round and a 4 KiB one stage
    // identically.
    parameter integer PAY_SLOT_BYTES     = 4096,

    // Ring depth, in frames. A double-buffering depth set by DMA turnaround,
    // NOT a protocol depth - nothing to do with P_ROUND_DEPTH. A 4096-byte
    // frame is ~330 ns on a 100G wire and PCIe turnaround is 1-2 us, so up to
    // six frames can be in flight; sixteen is the whole 64 KiB and leaves
    // room for the engine to fall behind for a while.
    parameter integer PAY_SLOT_COUNT     = 16,

    // ---- derived; do not override -----------------------------------------
    // A parameter rather than a localparam only because it sizes a port.
    parameter integer SLOT_PTR_W         = (PAY_SLOT_COUNT > 1) ? $clog2(PAY_SLOT_COUNT) : 1
)
(
    input  wire                             clk,
    input  wire                             rst,

    // ---- payload from ssr_rx_engine ------------------------------------------
    input  wire                             i_pl_sof,
    input  wire [7:0]                       i_pl_node_id,
    input  wire [63:0]                      i_pl_round_id,
    input  wire [15:0]                      i_pl_len,        // this fragment's payload bytes
    input  wire [15:0]                      i_pl_frag_idx,   // which page of the node's region
    // The raw 64-byte header beat, valid with i_pl_sof. Latched here and written
    // as beat 0 of the slot on commit, so fragment 0's descriptor can carry it to
    // the host unchanged.
    //
    // total_len is deliberately NOT an input: ssr_presence_tracker is what counts
    // fragments against it, and this module never looks across frames. Nor is
    // the beat-level last flag: the frame is closed by commit / drop, and the
    // beat count is checked against the declared length at that point.
    input  wire [AXIS_DATA_WIDTH-1:0]       i_pl_hdr_data,
    input  wire                             i_pl_valid,
    input  wire [AXIS_DATA_WIDTH-1:0]       i_pl_data,
    output wire                             o_pl_ready,
    input  wire                             i_pl_commit,
    input  wire                             i_pl_drop,

    // ---- head of the ring, to ssr_payload_dma_writer -------------------------
    // One descriptor per slot: the whole frame, header included, to one page.
    output wire                             o_head_valid,
    output wire [RAM_ADDR_WIDTH-1:0]        o_head_addr,   // the slot's first byte
    output wire [DMA_LEN_WIDTH-1:0]         o_head_len,    // 64 + payload bytes
    output wire [63:0]                      o_head_round_id,
    output wire [7:0]                       o_head_node_id,
    output wire [15:0]                      o_head_frag_idx, // which page
    // Which slot this descriptor reads from. The writer carries it through the
    // tag pool's meta field and it comes back on i_done_slot.
    output wire [SLOT_PTR_W-1:0]            o_head_slot,
    input  wire                             i_head_pop,

    // ---- DMA completion, from ssr_payload_dma_writer -------------------------
    // One pulse per completed descriptor, with the slot it read from. Every
    // pop produces exactly one of these, eventually, in any order.
    input  wire                             i_desc_done,
    input  wire [SLOT_PTR_W-1:0]            i_done_slot,

    // ---- counters ---------------------------------------------------------
    // High on the commit cycle of a frame that WAS staged: it had a slot, a
    // legal length, and will leave as a page. ssr_presence_tracker counts this,
    // not ssr_rx_engine's commit, so a frame the ring had no room for is not
    // called present on a host that will never see it.
    output wire                             o_staged,

    output wire [31:0]                      o_push_count,      // frames staged
    output wire [31:0]                      o_full_count,      // dropped, no free slot
    output wire [31:0]                      o_oversize_count,  // longer than a slot
    output wire [31:0]                      o_overlap_count,   // sof while a frame was open
    output wire [31:0]                      o_len_mismatch_count, // beats disagreed with len

    // ---- DMA RAM read interface ------------------------------------------
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]  dma_ram_rd_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]  dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_resp_valid,
    input  wire [RAM_SEG_COUNT-1:0]                     dma_ram_rd_resp_ready
);

// ---------------------------------------------------------------- geometry
// A beat is one segment (64 B); a row is RAM_SEG_COUNT beats (128 B on the AU200).
localparam integer RAM_BEAT_BYTES   = RAM_SEG_BE_WIDTH;                          // 64
localparam integer RAM_ROW_BYTES    = RAM_SEG_COUNT * RAM_SEG_BE_WIDTH;          // 128
localparam integer SLOT_BEATS       = PAY_SLOT_BYTES / RAM_BEAT_BYTES;           // 64
localparam integer SLOT_ROWS        = PAY_SLOT_BYTES / RAM_ROW_BYTES;            // 32
localparam integer BEAT_SHIFT       = $clog2(RAM_BEAT_BYTES);                    // 6

// Beat 0 of every slot is the frame header, so a fragment's payload gets one
// beat fewer than the slot holds.
localparam integer HDR_BEATS        = 1;
localparam integer PAY_BEATS_MAX    = SLOT_BEATS - HDR_BEATS;
localparam [15:0]  HDR_BYTES_16     = RAM_BEAT_BYTES;

// One bit wider than an index into the slot, so the counter can hold SLOT_BEATS
// itself. A plain $clog2(SLOT_BEATS)-bit counter wraps to zero on a frame that
// fills the slot exactly, and the length cross-check then compares 0 against
// SLOT_BEATS and reports a mismatch on every full-size frame.
localparam integer BEAT_CNT_W       = $clog2(SLOT_BEATS + 1);
localparam [16:0]  BEAT_BYTES_17    = RAM_BEAT_BYTES;
localparam [BEAT_CNT_W-1:0] SLOT_BEATS_V = SLOT_BEATS;

localparam integer SLOT_BYTE_ADDR_W = $clog2(PAY_SLOT_BYTES);
localparam integer SLOT_CNT_W       = $clog2(PAY_SLOT_COUNT + 1);

localparam integer STAGE_RAM_SIZE   = PAY_SLOT_BYTES * PAY_SLOT_COUNT;
localparam [15:0]  PAY_MAX_BYTES    = PAY_BEATS_MAX * RAM_BEAT_BYTES;

initial begin
    if (AXIS_DATA_WIDTH != RAM_SEG_DATA_WIDTH) begin
        $error("ssr_payload_stage: AXIS_DATA_WIDTH = %0d but a RAM segment is %0d bits; a beat must be one segment (instance %m)",
               AXIS_DATA_WIDTH, RAM_SEG_DATA_WIDTH);
        $finish;
    end
    if (RAM_SEG_COUNT < 1 || (RAM_SEG_COUNT & (RAM_SEG_COUNT - 1)) || PAY_SLOT_BYTES % RAM_ROW_BYTES != 0) begin
        $error("ssr_payload_stage: RAM_SEG_COUNT = %0d must be a power of two dividing a slot into whole rows (instance %m)",
               RAM_SEG_COUNT);
        $finish;
    end
    if (PAY_SLOT_BYTES == 0 ||
        PAY_SLOT_BYTES % RAM_BEAT_BYTES != 0 ||
        (PAY_SLOT_BYTES & (PAY_SLOT_BYTES - 1))) begin
        $error("ssr_payload_stage: PAY_SLOT_BYTES = %0d must be a non-zero power of two and a multiple of %0d (instance %m)",
               PAY_SLOT_BYTES, RAM_BEAT_BYTES);
        $finish;
    end
    if (PAY_SLOT_BYTES < 2*RAM_BEAT_BYTES) begin
        $error("ssr_payload_stage: PAY_SLOT_BYTES = %0d leaves no room for a header beat plus payload (instance %m)",
               PAY_SLOT_BYTES);
        $finish;
    end
    if (PAY_SLOT_COUNT < 2 || (PAY_SLOT_COUNT & (PAY_SLOT_COUNT - 1))) begin
        $error("ssr_payload_stage: PAY_SLOT_COUNT = %0d must be a power of two and at least 2, or a frame cannot be received while another drains (instance %m)",
               PAY_SLOT_COUNT);
        $finish;
    end
end

// ---------------------------------------------------------------- ring state
reg [SLOT_PTR_W-1:0] tail_ptr_reg   = {SLOT_PTR_W{1'b0}};   // written off the wire
reg [SLOT_PTR_W-1:0] head_ptr_reg   = {SLOT_PTR_W{1'b0}};   // descriptor handed out
reg [SLOT_PTR_W-1:0] free_ptr_reg   = {SLOT_PTR_W{1'b0}};   // may still be read by the engine

// Two occupancies. slot_count is tail - free: slots the wire may not reuse.
// issued_count is tail - head: slots with descriptors still to hand out.
reg [SLOT_CNT_W-1:0] slot_count_reg   = {SLOT_CNT_W{1'b0}};
reg [SLOT_CNT_W-1:0] unissued_count_reg = {SLOT_CNT_W{1'b0}};

wire ring_full  = (slot_count_reg == PAY_SLOT_COUNT[SLOT_CNT_W-1:0]);
wire head_avail = (unissued_count_reg != {SLOT_CNT_W{1'b0}});

// Per slot: whether its descriptor has been handed out, and whether it is
// still out at the engine. Two bits, because "handed out and back" and "never
// handed out" both have pend == 0 and only the first may release.
reg       slot_popped [0:PAY_SLOT_COUNT-1];
reg       slot_pend   [0:PAY_SLOT_COUNT-1];

// A slot leaves the ring when its descriptor has been handed out AND has
// completed. One per cycle, in order.
wire slot_release = slot_popped[free_ptr_reg] && !slot_pend[free_ptr_reg];

// ---------------------------------------------------------------- per-slot metadata
// The whole reason this is not commit_buffer: the DMA writer computes a host
// address from (round, node), so the ring has to remember which frame is in
// which slot.
reg [63:0]              stage_round_id [0:PAY_SLOT_COUNT-1];
reg [7:0]               stage_node_id  [0:PAY_SLOT_COUNT-1];
reg [DMA_LEN_WIDTH-1:0] stage_len      [0:PAY_SLOT_COUNT-1];  // payload bytes
reg [15:0]              stage_frag_idx [0:PAY_SLOT_COUNT-1];  // which page

integer init_i;
integer pi;
initial begin
    for (init_i = 0; init_i < PAY_SLOT_COUNT; init_i = init_i + 1) begin
        stage_round_id[init_i] = 64'd0;
        stage_node_id [init_i] = 8'd0;
        stage_len     [init_i] = {DMA_LEN_WIDTH{1'b0}};
        stage_frag_idx[init_i] = 16'd0;
        slot_pend     [init_i] = 1'b0;
        slot_popped   [init_i] = 1'b0;
    end
end

// ---------------------------------------------------------------- frame state
reg                  open_reg      = 1'b0;   // a frame is being written
reg                  nopush_reg    = 1'b0;   // ...and it will not be kept
reg [BEAT_CNT_W-1:0] wr_beat_reg   = {BEAT_CNT_W{1'b0}};
reg [63:0]           cur_round_reg = 64'd0;
reg [7:0]            cur_node_reg  = 8'd0;
reg [15:0]           cur_len_reg   = 16'd0;
reg [15:0]           cur_frag_reg  = 16'd0;
reg [AXIS_DATA_WIDTH-1:0] cur_hdr_reg = {AXIS_DATA_WIDTH{1'b0}};

// The first payload beat arrives on the sof cycle itself, so every decision
// about this frame has to be available combinationally on that cycle - the
// registered copies are one cycle too late for beat 0.
wire sof_full     = i_pl_sof && ring_full;
wire sof_oversize = i_pl_sof && (i_pl_len > PAY_MAX_BYTES);
wire sof_empty    = i_pl_sof && (i_pl_len == 16'd0);
wire sof_overlap  = i_pl_sof && open_reg;
wire sof_nopush   = sof_full || sof_oversize || sof_empty;

wire        eff_open   = open_reg || i_pl_sof;
wire        eff_nopush = i_pl_sof ? sof_nopush : nopush_reg;
wire [15:0] eff_len    = i_pl_sof ? i_pl_len   : cur_len_reg;
wire [15:0] eff_frag   = i_pl_sof ? i_pl_frag_idx : cur_frag_reg;
// Where the beat on the bus goes. On the sof cycle it is the first payload beat
// and the header owns beat 0, so it goes to beat 1; wr_beat_reg has not caught up yet.
wire [BEAT_CNT_W-1:0] eff_wr_beat = i_pl_sof ? HDR_BEATS[BEAT_CNT_W-1:0] : wr_beat_reg;

// How many beats a declared length occupies. RAM_BEAT_BYTES is a power of two,
// so the division is a shift, not a divider.
wire [16:0]           eff_beats_full = ({1'b0, eff_len} + BEAT_BYTES_17 - 17'd1) >> BEAT_SHIFT;
wire [BEAT_CNT_W-1:0] eff_beats      = eff_beats_full[BEAT_CNT_W-1:0];

wire beat_fire   = i_pl_valid && o_pl_ready;

wire push_fire  = i_pl_commit && eff_open && !eff_nopush;
wire close_fire = (i_pl_commit || i_pl_drop) && eff_open;

// Two writers into one RAM port, and they never collide: the header is written
// on COMMIT, and ssr_rx_engine cannot have a beat on the bus on the commit cycle -
// see the banner. A beat on the sof cycle is the first payload beat and goes to beat 1.
wire hdr_wr_fire = push_fire;
wire pay_wr_fire = beat_fire && eff_open && !eff_nopush
                 && (eff_wr_beat < SLOT_BEATS_V);
wire ram_wr_fire = hdr_wr_fire || pay_wr_fire;

// ---------------------------------------------------------------- head
// One descriptor per slot: from beat 0, header and payload together, to the
// page that frag_idx names. The length is the header plus what the frame
// declared, so a short final fragment moves a short page and the rest of that
// page on the host is untouched.
wire [RAM_ADDR_WIDTH-1:0] head_slot_base =
        {{(RAM_ADDR_WIDTH-SLOT_PTR_W){1'b0}}, head_ptr_reg} << SLOT_BYTE_ADDR_W;

assign o_head_valid    = head_avail;
assign o_head_addr     = head_slot_base;
assign o_head_len      = HDR_BYTES_16[DMA_LEN_WIDTH-1:0] + stage_len[head_ptr_reg];
assign o_head_round_id = stage_round_id[head_ptr_reg];
assign o_head_node_id  = stage_node_id[head_ptr_reg];
assign o_head_frag_idx = stage_frag_idx[head_ptr_reg];
assign o_head_slot     = head_ptr_reg;

wire pop_fire    = i_head_pop && o_head_valid;
// Every pop hands out a slot's only descriptor. Advances head_ptr; releases
// nothing - see the banner.
wire slot_issued = pop_fire;

// The beats written and the declared length disagreeing means ssr_rx_engine's
// geometry check and this module's arithmetic have drifted apart. It cannot
// happen while both are right, which is exactly why it is worth a counter.
wire len_mismatch = push_fire && (wr_beat_reg != (eff_beats + HDR_BEATS[BEAT_CNT_W-1:0]));

// ---------------------------------------------------------------- nothing holds the wire off
assign o_pl_ready = 1'b1;

// ---------------------------------------------------------------- counters
reg [31:0] push_count_reg     = 32'd0;
reg [31:0] full_count_reg     = 32'd0;
reg [31:0] oversize_count_reg = 32'd0;
reg [31:0] overlap_count_reg  = 32'd0;
reg [31:0] mismatch_count_reg = 32'd0;

assign o_staged             = push_fire;
assign o_push_count         = push_count_reg;
assign o_full_count         = full_count_reg;
assign o_oversize_count     = oversize_count_reg;
assign o_overlap_count      = overlap_count_reg;
assign o_len_mismatch_count = mismatch_count_reg;

// ---------------------------------------------------------------- RAM write port
// Beat 0 on the commit cycle (the header), eff_wr_beat otherwise. Beat b is
// segment b % RAM_SEG_COUNT, row b / RAM_SEG_COUNT of the slot; only that
// segment is written.
wire [BEAT_CNT_W-1:0]         wr_beat       = hdr_wr_fire ? {BEAT_CNT_W{1'b0}} : eff_wr_beat;
wire [RAM_SEG_ADDR_WIDTH-1:0] tail_base_row = tail_ptr_reg * SLOT_ROWS;
wire [RAM_SEG_ADDR_WIDTH-1:0] wr_row_addr   = tail_base_row + wr_beat / RAM_SEG_COUNT;
wire [31:0]                   wr_seg        = wr_beat % RAM_SEG_COUNT;

wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   ram_wr_cmd_be    = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};
wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] ram_wr_cmd_addr  = {RAM_SEG_COUNT{wr_row_addr}};
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] ram_wr_cmd_data  = {RAM_SEG_COUNT{hdr_wr_fire ? cur_hdr_reg : i_pl_data}};
wire [RAM_SEG_COUNT-1:0]                    wr_seg_onehot    = 1 << wr_seg;
wire [RAM_SEG_COUNT-1:0]                    ram_wr_cmd_valid = ram_wr_fire ? wr_seg_onehot : {RAM_SEG_COUNT{1'b0}};
wire [RAM_SEG_COUNT-1:0]                    ram_wr_cmd_ready;
wire [RAM_SEG_COUNT-1:0]                    ram_wr_done;

// ---------------------------------------------------------------- sequential
always @(posedge clk) begin
    if (rst) begin
        head_ptr_reg       <= {SLOT_PTR_W{1'b0}};
        tail_ptr_reg       <= {SLOT_PTR_W{1'b0}};
        free_ptr_reg       <= {SLOT_PTR_W{1'b0}};
        slot_count_reg     <= {SLOT_CNT_W{1'b0}};
        unissued_count_reg <= {SLOT_CNT_W{1'b0}};
        for (pi = 0; pi < PAY_SLOT_COUNT; pi = pi + 1) begin
            slot_pend  [pi] <= 1'b0;
            slot_popped[pi] <= 1'b0;
        end
        open_reg           <= 1'b0;
        nopush_reg         <= 1'b0;
        wr_beat_reg        <= {BEAT_CNT_W{1'b0}};
        cur_round_reg      <= 64'd0;
        cur_node_reg       <= 8'd0;
        cur_len_reg        <= 16'd0;
        cur_frag_reg       <= 16'd0;
        cur_hdr_reg        <= {AXIS_DATA_WIDTH{1'b0}};
        push_count_reg     <= 32'd0;
        full_count_reg     <= 32'd0;
        oversize_count_reg <= 32'd0;
        overlap_count_reg  <= 32'd0;
        mismatch_count_reg <= 32'd0;
    end else begin
        // ---- start of frame ------------------------------------------------
        if (i_pl_sof) begin
            open_reg      <= 1'b1;
            nopush_reg    <= sof_nopush;
            // The header took beat 0, so payload beats start at 1.
            wr_beat_reg   <= HDR_BEATS[BEAT_CNT_W-1:0];
            cur_round_reg <= i_pl_round_id;
            cur_node_reg  <= i_pl_node_id;
            cur_len_reg   <= i_pl_len;
            cur_frag_reg  <= i_pl_frag_idx;
            cur_hdr_reg   <= i_pl_hdr_data;

            if (sof_full)     full_count_reg     <= full_count_reg     + 32'd1;
            if (sof_oversize) oversize_count_reg <= oversize_count_reg + 32'd1;
            if (sof_overlap)  overlap_count_reg  <= overlap_count_reg  + 32'd1;
        end

        // ---- beats ---------------------------------------------------------
        // After the sof block, so on the sof cycle - where beat 0 is already on
        // the bus - this wins over the sof block's reset to HDR_BEATS and the
        // counter lands at 2, not 1. Last-write-wins, used on purpose.
        if (pay_wr_fire)
            wr_beat_reg <= eff_wr_beat + 1'b1;

        // ---- push ----------------------------------------------------------
        // The metadata is written from the latched copy, not from the i_pl_*
        // inputs, because by commit time ssr_rx_engine has moved on.
        if (push_fire) begin
            stage_round_id[tail_ptr_reg] <= i_pl_sof ? i_pl_round_id : cur_round_reg;
            stage_node_id [tail_ptr_reg] <= i_pl_sof ? i_pl_node_id  : cur_node_reg;
            stage_len     [tail_ptr_reg] <= eff_len[DMA_LEN_WIDTH-1:0];
            stage_frag_idx[tail_ptr_reg] <= eff_frag;

            tail_ptr_reg                 <= tail_ptr_reg + 1'b1;
            push_count_reg               <= push_count_reg + 32'd1;
        end

        if (len_mismatch)
            mismatch_count_reg <= mismatch_count_reg + 32'd1;

        // ---- end of frame --------------------------------------------------
        // Written after the sof block, so on a header-only frame - where sof and
        // commit are the same cycle - last-write-wins leaves the ring closed
        // rather than stuck open. That ordering is load-bearing; do not move
        // this above the sof block.
        if (close_fire) begin
            open_reg   <= 1'b0;
            nopush_reg <= 1'b0;
        end

        // ---- pop -----------------------------------------------------------
        if (pop_fire) begin
            head_ptr_reg              <= head_ptr_reg + 1'b1;
            slot_popped[head_ptr_reg] <= 1'b1;
        end

        // ---- in flight -----------------------------------------------------
        // Set on pop, cleared on completion. A pop and a completion for the
        // same slot in one cycle cannot happen with one descriptor per slot -
        // the completion is for the descriptor the pop is only now issuing -
        // but if it did, the pop must win: the descriptor IS outstanding.
        for (pi = 0; pi < PAY_SLOT_COUNT; pi = pi + 1) begin
            if (i_desc_done && (i_done_slot == pi[SLOT_PTR_W-1:0]))
                slot_pend[pi] <= 1'b0;
            if (pop_fire && (head_ptr_reg == pi[SLOT_PTR_W-1:0]))
                slot_pend[pi] <= 1'b1;
        end

        // ---- release -------------------------------------------------------
        if (slot_release) begin
            free_ptr_reg              <= free_ptr_reg + 1'b1;
            slot_popped[free_ptr_reg] <= 1'b0;
        end

        // ---- occupancy -----------------------------------------------------
        case ({push_fire, slot_release})
            2'b10:   slot_count_reg <= slot_count_reg + 1'b1;
            2'b01:   slot_count_reg <= slot_count_reg - 1'b1;
            default: slot_count_reg <= slot_count_reg;
        endcase
        case ({push_fire, slot_issued})
            2'b10:   unissued_count_reg <= unissued_count_reg + 1'b1;
            2'b01:   unissued_count_reg <= unissued_count_reg - 1'b1;
            default: unissued_count_reg <= unissued_count_reg;
        endcase
    end
end

// ---------------------------------------------------------------- the RAM
dma_psdpram #(
    .SIZE(STAGE_RAM_SIZE),
    .SEG_COUNT(RAM_SEG_COUNT),
    .SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .PIPELINE(RAM_PIPELINE)
)
stage_ram_inst (
    .clk(clk),
    .rst(rst),

    .wr_cmd_be(ram_wr_cmd_be),
    .wr_cmd_addr(ram_wr_cmd_addr),
    .wr_cmd_data(ram_wr_cmd_data),
    .wr_cmd_valid(ram_wr_cmd_valid),
    .wr_cmd_ready(ram_wr_cmd_ready),
    .wr_done(ram_wr_done),

    .rd_cmd_addr(dma_ram_rd_cmd_addr),
    .rd_cmd_valid(dma_ram_rd_cmd_valid),
    .rd_cmd_ready(dma_ram_rd_cmd_ready),
    .rd_resp_data(dma_ram_rd_resp_data),
    .rd_resp_valid(dma_ram_rd_resp_valid),
    .rd_resp_ready(dma_ram_rd_resp_ready)
);

endmodule

`resetall
