`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_rx_demux - takes SSR's own frames out of the interface's receive stream.
 *
 * THE COUNTERPART OF ssr_tx_mux
 *   ssr_tx_mux  merges this node's frames INTO the interface transmit stream.
 *   ssr_rx_demux splits this node's frames OUT of the interface receive stream.
 *
 *       ssr_tx_mux    {SSR, host} ──► port
 *       ssr_rx_demux   port ──► {SSR, host}
 *
 *   The two are the only places SSR touches the interface's own datapath, and
 *   the naming is deliberate: anything else in this tree called a "splitter" or
 *   a "mux" should be one of these two.
 *
 * ONE ETHERTYPE, AND EVERYTHING ELSE IS SOMEONE ELSE'S
 *   A frame whose ethertype is P_SSR_ETHERTYPE (0x88B5) is consumed here and
 *   handed to ssr_rx_engine. EVERY other frame - ARP, ICMP, TCP, a neighbour's
 *   LLDP, anything - passes through to the host untouched.
 *
 *   This replaces consensus_rx_splitter, which recognised a second ethertype
 *   (0x88B6) for a second application and DROPPED everything it did not
 *   recognise. Since the "second application" output was in fact wired straight
 *   to m_axis_if_rx - the host path - the effect was that a plain ping to this
 *   interface was silently discarded at the app boundary, with tready held high
 *   so nothing back-pressured and no counter moved anywhere. Passing unknown
 *   traffic through is both the correct default for an mqnic application and one
 *   fewer thing that has to be configured for the port to behave like a NIC.
 *
 * THE ROUTE IS A PROPERTY OF THE FRAME, NOT OF THE BEAT
 *   Byte 12 of a header is an ethertype; byte 12 of a payload row is payload.
 *   Classifying every beat independently is right exactly once per frame and
 *   wrong for every beat after it: a multi-beat SSR frame had its header
 *   delivered to the consensus app and its payload routed elsewhere. The route
 *   is decided on the first beat and held to tlast.
 *
 *   That bug went unnoticed for a long time because the old consensus_rx parsed
 *   a single-beat frame, so there was never a second beat to misroute. With
 *   fragmentation a frame is now 65 beats, so 64 of them depend on this latch.
 *
 * NO REGISTERS ON THE DATA PATH
 *   Frames pass combinationally, tready included. A register here would add a
 *   cycle to the receive path for no benefit - ssr_rx_engine is the thing that has
 *   to decide quickly, and it wants the header as early as it can get it.
 */

module ssr_rx_demux #(
    parameter integer AXIS_IF_DATA_WIDTH    = 512,
    parameter integer AXIS_IF_KEEP_WIDTH    = AXIS_IF_DATA_WIDTH/8,
    parameter integer AXIS_IF_RX_USER_WIDTH = 49,
    parameter integer AXIS_IF_RX_ID_WIDTH   = 8,
    parameter integer AXIS_IF_RX_DEST_WIDTH = 9,

    // Where the ethertype sits in a frame. 12 for plain Ethernet; a VLAN tag
    // would move it, which is why it is a parameter and not a 12.
    parameter integer P_ETHERTYPE_OFFSET_BYTES = 12,

    // Keep equal to ssr_rx_engine's P_ETHERTYPE and ssr_packet.vh's SSR_ETHERTYPE.
    parameter [15:0]  P_SSR_ETHERTYPE = 16'h88B5
) (
    input  wire                                     clk,
    input  wire                                     rst,

    // ---- from the interface's receive path -------------------------------
    input  wire [AXIS_IF_DATA_WIDTH-1:0]            s_axis_rx_tdata,
    input  wire [AXIS_IF_KEEP_WIDTH-1:0]            s_axis_rx_tkeep,
    input  wire                                     s_axis_rx_tvalid,
    output reg                                      s_axis_rx_tready,
    input  wire                                     s_axis_rx_tlast,
    input  wire [AXIS_IF_RX_ID_WIDTH-1:0]           s_axis_rx_tid,
    input  wire [AXIS_IF_RX_DEST_WIDTH-1:0]         s_axis_rx_tdest,
    input  wire [AXIS_IF_RX_USER_WIDTH-1:0]         s_axis_rx_tuser,

    // ---- SSR's own frames, to ssr_rx_engine ----------------------------------
    output reg  [AXIS_IF_DATA_WIDTH-1:0]            m_axis_ssr_tdata,
    output reg  [AXIS_IF_KEEP_WIDTH-1:0]            m_axis_ssr_tkeep,
    output reg                                      m_axis_ssr_tvalid,
    input  wire                                     m_axis_ssr_tready,
    output reg                                      m_axis_ssr_tlast,
    output reg  [AXIS_IF_RX_ID_WIDTH-1:0]           m_axis_ssr_tid,
    output reg  [AXIS_IF_RX_DEST_WIDTH-1:0]         m_axis_ssr_tdest,
    output reg  [AXIS_IF_RX_USER_WIDTH-1:0]         m_axis_ssr_tuser,

    // ---- everything else, to the host ------------------------------------
    output reg  [AXIS_IF_DATA_WIDTH-1:0]            m_axis_dma_tdata,
    output reg  [AXIS_IF_KEEP_WIDTH-1:0]            m_axis_dma_tkeep,
    output reg                                      m_axis_dma_tvalid,
    input  wire                                     m_axis_dma_tready,
    output reg                                      m_axis_dma_tlast,
    output reg  [AXIS_IF_RX_ID_WIDTH-1:0]           m_axis_dma_tid,
    output reg  [AXIS_IF_RX_DEST_WIDTH-1:0]         m_axis_dma_tdest,
    output reg  [AXIS_IF_RX_USER_WIDTH-1:0]         m_axis_dma_tuser,

    // ---- counters ---------------------------------------------------------
    output wire [31:0]                              o_ssr_frame_count,
    output wire [31:0]                              o_dma_frame_count
);

// ---------------------------------------------------------------- classify
// The ethertype is big-endian on the wire and byte 0 sits in tdata[7:0], so the
// two bytes come out swapped relative to the parameter.
wire [15:0] beat_ethertype = s_axis_rx_tdata[P_ETHERTYPE_OFFSET_BYTES*8 +: 16];
wire        is_ssr_first   = (beat_ethertype == {P_SSR_ETHERTYPE[7:0], P_SSR_ETHERTYPE[15:8]});

// Which way this beat would go IF it were a first beat.
wire route_ssr_first = s_axis_rx_tvalid && is_ssr_first;

// ---------------------------------------------------------------- hold to tlast
reg frame_active_reg = 1'b0;
reg frame_is_ssr_reg = 1'b0;

wire route_ssr = frame_active_reg ? frame_is_ssr_reg : route_ssr_first;

wire beat_fire  = s_axis_rx_tvalid && s_axis_rx_tready;
wire frame_done = beat_fire && s_axis_rx_tlast;

reg [31:0] ssr_frame_count_reg = 32'd0;
reg [31:0] dma_frame_count_reg = 32'd0;

assign o_ssr_frame_count = ssr_frame_count_reg;
assign o_dma_frame_count = dma_frame_count_reg;

always @(posedge clk) begin
    if (rst) begin
        frame_active_reg    <= 1'b0;
        frame_is_ssr_reg    <= 1'b0;
        ssr_frame_count_reg <= 32'd0;
        dma_frame_count_reg <= 32'd0;
    end else begin
        if (beat_fire) begin
            if (s_axis_rx_tlast) begin
                frame_active_reg <= 1'b0;
            end else begin
                // Latched on the first beat only. A mid-frame beat must never
                // be allowed to re-decide where the rest of the frame goes.
                if (!frame_active_reg) frame_is_ssr_reg <= route_ssr_first;
                frame_active_reg <= 1'b1;
            end
        end

        // Counted at tlast, so a frame is counted once and only when it has
        // actually been taken.
        if (frame_done) begin
            if (route_ssr) ssr_frame_count_reg <= ssr_frame_count_reg + 32'd1;
            else           dma_frame_count_reg <= dma_frame_count_reg + 32'd1;
        end
    end
end

// ---------------------------------------------------------------- steer
always @(*) begin
    m_axis_ssr_tdata  = s_axis_rx_tdata;
    m_axis_ssr_tkeep  = s_axis_rx_tkeep;
    m_axis_ssr_tlast  = s_axis_rx_tlast;
    m_axis_ssr_tid    = s_axis_rx_tid;
    m_axis_ssr_tdest  = s_axis_rx_tdest;
    m_axis_ssr_tuser  = s_axis_rx_tuser;

    m_axis_dma_tdata  = s_axis_rx_tdata;
    m_axis_dma_tkeep  = s_axis_rx_tkeep;
    m_axis_dma_tlast  = s_axis_rx_tlast;
    m_axis_dma_tid    = s_axis_rx_tid;
    m_axis_dma_tdest  = s_axis_rx_tdest;
    m_axis_dma_tuser  = s_axis_rx_tuser;

    // Only the chosen side sees tvalid, and tready comes back from that same
    // side. Driving both valids and OR-ing the readys would hand every frame to
    // both consumers, which is how the old module lost payload beats.
    m_axis_ssr_tvalid = s_axis_rx_tvalid &&  route_ssr;
    m_axis_dma_tvalid = s_axis_rx_tvalid && !route_ssr;
    s_axis_rx_tready  = route_ssr ? m_axis_ssr_tready : m_axis_dma_tready;
end

endmodule

`resetall
