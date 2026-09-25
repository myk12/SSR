`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_tx_mux - merges the SSR transmit stream into the interface's transmit
 * stream, and keeps the SSR frames' completions out of the NIC's books.
 *
 * Replaces consensus_tx_arbiter, which had three problems:
 *
 *   1. It selected combinationally on tvalid with no frame lock, so a source
 *      asserting mid-frame switched the output and interleaved two frames on
 *      the wire.
 *   2. It drove BOTH s_axis_*_tready from m_axis_tx_tready unconditionally, so
 *      whenever the downstream accepted a beat, both sources believed their beat
 *      had been taken. One of them was silently dropped every time.
 *   3. It passed the completion stream straight through.
 *
 * WHY (3) IS NOT COSMETIC
 *   Corundum's transmit path returns one completion per frame, carrying the tag
 *   the sender put in tuser[TX_TAG_WIDTH:1]. The interface matches that tag
 *   against its transmit descriptor table to time-stamp and retire a descriptor.
 *   An SSR frame has no descriptor - it was injected by the application, not
 *   posted by the host - so forwarding its completion makes the interface retire
 *   a descriptor that was never posted, corrupting the transmit completion queue
 *   the driver is reading.
 *
 *   The frames are told apart by their tag rather than by timing or by
 *   counting, because the completion comes back an unpredictable number of
 *   cycles later and nothing else about it identifies the sender.
 *
 * WHICH TAG IS OURS
 *   Corundum's tx_engine puts {1, descriptor index} in the tag: the TOP bit is
 *   set on every host frame, and a completion is only acted on if its top bit
 *   is set (tx_engine.v, "tx_cpl_tag[TX_TAG_WIDTH-1]"). So the top bit is the
 *   one bit SSR must NOT use. SSR frames carry P_SSR_TAG = 0x4000: top bit
 *   clear (Corundum would ignore the completion even if it leaked through),
 *   next bit set (a host tag never has it: the index is 5 bits). A completion
 *   is SSR's if its tag is exactly P_SSR_TAG.
 *
 *   The first version used the top bit as the SSR marker. It swallowed every
 *   host completion on SSR's interface, the descriptor table stopped draining,
 *   and host transmit stalled after a few frames - the cocotb run on the
 *   AU200's parameters is where it showed.
 *
 * THE TIMESTAMP IS WORTH KEEPING
 *   The completion also carries the PTP transmit timestamp of the frame, which
 *   is the hardware's own measurement of when this node actually transmitted.
 *   That is exactly what tells you whether the TDMA sub-slot is placed where
 *   ssr_core thinks it is, so it is captured here and published through a
 *   CSR rather than discarded with the rest of the completion.
 */

module ssr_tx_mux #(
    parameter integer AXIS_DATA_WIDTH = 512,
    parameter integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8,
    parameter integer AXIS_ID_WIDTH   = 13,
    parameter integer AXIS_DEST_WIDTH = 4,
    parameter integer TX_TAG_WIDTH    = 16,
    parameter integer AXIS_USER_WIDTH = TX_TAG_WIDTH + 1,
    parameter integer PTP_TS_WIDTH    = 48,

    // The tag SSR's own frames carry; a completion with exactly this tag is
    // SSR's. See WHICH TAG IS OURS above: top bit clear, the bit below it set.
    parameter [15:0]  P_SSR_TAG       = 16'h4000
) (
    input  wire                            clk,
    input  wire                            rst,

    // ---- SSR frames, from ssr_tx_engine -------------------------------------
    input  wire [AXIS_DATA_WIDTH-1:0]      s_axis_ssr_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0]      s_axis_ssr_tkeep,
    input  wire                            s_axis_ssr_tvalid,
    output wire                            s_axis_ssr_tready,
    input  wire                            s_axis_ssr_tlast,
    input  wire [AXIS_USER_WIDTH-1:0]      s_axis_ssr_tuser,
    input  wire [AXIS_ID_WIDTH-1:0]        s_axis_ssr_tid,
    input  wire [AXIS_DEST_WIDTH-1:0]      s_axis_ssr_tdest,

    // ---- host frames, from the interface's DMA path ----------------------
    input  wire [AXIS_DATA_WIDTH-1:0]      s_axis_dma_tdata,
    input  wire [AXIS_KEEP_WIDTH-1:0]      s_axis_dma_tkeep,
    input  wire                            s_axis_dma_tvalid,
    output wire                            s_axis_dma_tready,
    input  wire                            s_axis_dma_tlast,
    input  wire [AXIS_USER_WIDTH-1:0]      s_axis_dma_tuser,
    input  wire [AXIS_ID_WIDTH-1:0]        s_axis_dma_tid,
    input  wire [AXIS_DEST_WIDTH-1:0]      s_axis_dma_tdest,

    // ---- merged, towards the port ----------------------------------------
    output wire [AXIS_DATA_WIDTH-1:0]      m_axis_tx_tdata,
    output wire [AXIS_KEEP_WIDTH-1:0]      m_axis_tx_tkeep,
    output wire                            m_axis_tx_tvalid,
    input  wire                            m_axis_tx_tready,
    output wire                            m_axis_tx_tlast,
    output wire [AXIS_USER_WIDTH-1:0]      m_axis_tx_tuser,
    output wire [AXIS_ID_WIDTH-1:0]        m_axis_tx_tid,
    output wire [AXIS_DEST_WIDTH-1:0]      m_axis_tx_tdest,

    // ---- completions, from the port --------------------------------------
    input  wire [PTP_TS_WIDTH-1:0]         s_axis_tx_cpl_ts,
    input  wire [TX_TAG_WIDTH-1:0]         s_axis_tx_cpl_tag,
    input  wire                            s_axis_tx_cpl_valid,
    output wire                            s_axis_tx_cpl_ready,

    // ---- completions, towards the interface (SSR's removed) --------------
    output wire [PTP_TS_WIDTH-1:0]         m_axis_tx_cpl_ts,
    output wire [TX_TAG_WIDTH-1:0]         m_axis_tx_cpl_tag,
    output wire                            m_axis_tx_cpl_valid,
    input  wire                            m_axis_tx_cpl_ready,

    // ---- the SSR frames' own transmit timestamps -------------------------
    output reg  [PTP_TS_WIDTH-1:0]         o_ssr_cpl_ts,
    output reg  [31:0]                     o_ssr_cpl_count,
    // Counts SSR completions that arrived while a previous one had not been
    // read. Harmless - the newest timestamp simply wins - but a non-zero value
    // means software is sampling more slowly than the round rate.
    output reg  [31:0]                     o_ssr_cpl_overrun,
    input  wire                            i_ssr_cpl_ack,

    output wire [31:0]                     o_ssr_frame_count,
    output wire [31:0]                     o_dma_frame_count
);

// ---------------------------------------------------------------- arbitration
localparam [1:0] SEL_NONE = 2'd0,
                 SEL_SSR  = 2'd1,
                 SEL_DMA  = 2'd2;

reg [1:0]  sel_reg = SEL_NONE;
reg [31:0] ssr_frame_count_reg = 32'd0;
reg [31:0] dma_frame_count_reg = 32'd0;

wire out_fire = m_axis_tx_tvalid && m_axis_tx_tready;
wire out_done = out_fire && m_axis_tx_tlast;

// SSR wins an idle mux. It is the time-critical stream: its frame has to leave
// inside a TDMA sub-slot, while a host frame has no deadline. Note this is only
// a tie-break at the START of a frame - a host frame already in flight is never
// interrupted, which is why a busy mux can still push an SSR frame past its
// sub-slot and have ssr_tx_engine count an overrun.
always @(posedge clk) begin
    if (sel_reg == SEL_NONE) begin
        if (s_axis_ssr_tvalid)      sel_reg <= SEL_SSR;
        else if (s_axis_dma_tvalid) sel_reg <= SEL_DMA;
    end else if (out_done) begin
        sel_reg <= SEL_NONE;
        if (sel_reg == SEL_SSR) ssr_frame_count_reg <= ssr_frame_count_reg + 32'd1;
        else                    dma_frame_count_reg <= dma_frame_count_reg + 32'd1;
    end

    if (rst) begin
        sel_reg             <= SEL_NONE;
        ssr_frame_count_reg <= 32'd0;
        dma_frame_count_reg <= 32'd0;
    end
end

assign m_axis_tx_tdata  = (sel_reg == SEL_SSR) ? s_axis_ssr_tdata  : s_axis_dma_tdata;
assign m_axis_tx_tkeep  = (sel_reg == SEL_SSR) ? s_axis_ssr_tkeep  : s_axis_dma_tkeep;
assign m_axis_tx_tlast  = (sel_reg == SEL_SSR) ? s_axis_ssr_tlast  : s_axis_dma_tlast;
assign m_axis_tx_tuser  = (sel_reg == SEL_SSR) ? s_axis_ssr_tuser  : s_axis_dma_tuser;
assign m_axis_tx_tid    = (sel_reg == SEL_SSR) ? s_axis_ssr_tid    : s_axis_dma_tid;
assign m_axis_tx_tdest  = (sel_reg == SEL_SSR) ? s_axis_ssr_tdest  : s_axis_dma_tdest;

assign m_axis_tx_tvalid = (sel_reg == SEL_SSR) ? s_axis_ssr_tvalid
                        : (sel_reg == SEL_DMA) ? s_axis_dma_tvalid : 1'b0;

// Only the granted source sees ready. This is the half the old arbiter got
// wrong: it handed the same ready to both, so every accepted beat was counted
// as accepted by a source that had not been selected, and that source's beat
// vanished.
assign s_axis_ssr_tready = (sel_reg == SEL_SSR) && m_axis_tx_tready;
assign s_axis_dma_tready = (sel_reg == SEL_DMA) && m_axis_tx_tready;

assign o_ssr_frame_count = ssr_frame_count_reg;
assign o_dma_frame_count = dma_frame_count_reg;

// ---------------------------------------------------------------- completions
wire cpl_is_ssr = (s_axis_tx_cpl_tag == P_SSR_TAG[TX_TAG_WIDTH-1:0]);

assign m_axis_tx_cpl_ts    = s_axis_tx_cpl_ts;
assign m_axis_tx_cpl_tag   = s_axis_tx_cpl_tag;
assign m_axis_tx_cpl_valid = s_axis_tx_cpl_valid && !cpl_is_ssr;

// An SSR completion is always accepted immediately - there is nothing to back it
// up against, and stalling it would stall every host completion queued behind
// it. A host completion follows the interface's own ready.
assign s_axis_tx_cpl_ready = cpl_is_ssr ? 1'b1 : m_axis_tx_cpl_ready;

reg ssr_cpl_pending_reg = 1'b0;

always @(posedge clk) begin
    if (s_axis_tx_cpl_valid && cpl_is_ssr) begin
        o_ssr_cpl_ts    <= s_axis_tx_cpl_ts;
        o_ssr_cpl_count <= o_ssr_cpl_count + 32'd1;
        if (ssr_cpl_pending_reg)
            o_ssr_cpl_overrun <= o_ssr_cpl_overrun + 32'd1;
        ssr_cpl_pending_reg <= 1'b1;
    end else if (i_ssr_cpl_ack) begin
        ssr_cpl_pending_reg <= 1'b0;
    end

    if (rst) begin
        o_ssr_cpl_ts        <= {PTP_TS_WIDTH{1'b0}};
        o_ssr_cpl_count     <= 32'd0;
        o_ssr_cpl_overrun   <= 32'd0;
        ssr_cpl_pending_reg <= 1'b0;
    end
end

endmodule

`resetall
