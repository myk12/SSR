`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_dataplane - the SSR application inside Corundum's mqnic_app_block.
 *
 * -----------------------------------------------------
 *            Modules, and how they are named
 * -----------------------------------------------------
 * Every SSR file and module is ssr_<name>, one module per file, file name =
 * module name. Corundum has its own tx_engine, rx_engine and dma_* modules in
 * the same file list; the prefix is what keeps them apart. Instances drop the
 * prefix: ssr_tx_engine is tx_engine_inst.
 *
 *   ssr_csr                  every host-visible register, one map (see its header)
 *   ssr_core                 PTP rounds, the consensus pipeline, halt
 *   transmit
 *     ssr_proposal_dma_reader  host proposal ring -> DMA reads (doorbell, CONSUMER)
 *     ssr_proposal_buffer      8 slots, commits in ring order, streams beats 1..63
 *     ssr_tx_engine            control frame, then fragments as they arrive, paced, until the cutoff
 *     ssr_tx_mux               SSR and host frames onto the port
 *   receive
 *     ssr_rx_demux             ethertype 0x88B5 -> SSR, everything else -> host
 *     ssr_rx_engine            the header ladder, the ack rung: trusted peers, payload
 *     ssr_payload_stage        16 slots of received frames on their way to the host
 *     ssr_payload_dma_writer   a staged frame -> one DMA write to its host page
 *     ssr_dma_tag_pool         tags for those writes, and the per-round fence
 *     ssr_presence_tracker     how many fragments we hold of each node -> our ack vector
 *     ssr_verdict_dma_writer   the 64-byte verdict record, fenced behind its pages
 *   headers: ssr_packet.vh (the frame), ssr_verdict.vh (the record)
 *
 * -----------------------------------------------------
 *            Registers
 * -----------------------------------------------------
 * All of them are in ssr_csr, one 4 KiB page at the bottom of the app's
 * register space; ssr_csr's header is the map and kernel/ssr_regs.h copies it.
 * No other module has a register bus: settings go down to them as ports and
 * what the host may read comes back up as ports, all wired in this file.
 *
 * -----------------------------------------------------
 *         The receive side, end to end
 * -----------------------------------------------------
 *
 *   port -> ssr_rx_demux -> ssr_rx_engine -+-> ssr_core             (trusted peers)
 *                                          +-> ssr_presence_tracker (fragment counts)
 *                                          +-> ssr_payload_stage -> ssr_payload_dma_writer -> host pages
 *   ssr_core -> ssr_verdict_dma_writer -> host record, fenced behind the pages
 *
 *   The two writers use the two DMA paths Corundum gives an app block. Pages
 *   go on the data DMA, whose RAM read port reads the staging RAM. The verdict
 *   record goes on the control DMA, whose RAM read port the verdict writer
 *   answers from its record register. Corundum arbitrates control ahead of
 *   data (mqnic_core.v, "data/control DMA mux (priority)"), so a verdict does
 *   not queue behind the NIC's own packet writes on either interface - only
 *   behind whatever operation is already in the write engine.
 */

module ssr_dataplane #
(
    parameter APP_ID = 0,

    // Register interface configuration
    parameter REG_ADDR_WIDTH    = 24,
    parameter REG_DATA_WIDTH    = 32,
    parameter REG_STRB_WIDTH    = (REG_DATA_WIDTH / 8),
    // Defaults are the AU200 build (fpga/config.tcl + Corundum's fpga_100g
    // top); docs/au200_parameters.md derives each one.
    //
    // The AU200 has two interfaces, one per QSFP28 cage. SSR runs on one of
    // them, SSR_IF_INDEX; every other lane goes straight through untouched.
    parameter IF_COUNT      = 2,
    parameter SSR_IF_INDEX  = 0,
    parameter PORTS_PER_IF  = 1,
    parameter SCHED_PER_IF  = PORTS_PER_IF, // number of schedulers per interface (must be <= PORTS_PER_IF)
    parameter PORT_COUNT    = IF_COUNT * PORTS_PER_IF,

    // PTP configuration parameters
    parameter PTP_CLK_PERIOD_NS_NUM     = 4,
    parameter PTP_CLK_PERIOD_NS_DENOM   = 1,
    parameter PTP_PORT_CDC_PIPELINE     = 0,
    parameter PTP_PEROUT_ENABLE         = 0,
    parameter PTP_PEROUT_COUNT          = 1,

    // Interface configuration
    parameter PTP_TS_ENABLE     = 1,
    // The interface timestamps (tx completion, rx tuser). 48-bit relative on
    // the AU200. SSR's own time comes from ptp_sync_ts_tod, which is always
    // the 96-bit ToD whatever this is.
    parameter PTP_TS_FMT_TOD    = 0,
    parameter PTP_TS_WIDTH      = PTP_TS_FMT_TOD ? 96 : 48,
    parameter TX_TAG_WIDTH      = 16,
    parameter MAX_TX_SIZE       = 9214,
    parameter MAX_RX_SIZE       = 9214,

    // DMA interface configuration
    parameter DMA_ADDR_WIDTH = 64,
    parameter DMA_IMM_ENABLE = 0,
    parameter DMA_IMM_WIDTH = 32,
    parameter DMA_LEN_WIDTH = 16,
    parameter DMA_TAG_WIDTH = 13,
    parameter RAM_SEL_WIDTH = 1,
    parameter RAM_ADDR_WIDTH = 17,
    parameter RAM_SEG_COUNT = 2,
    // One segment is one 512-bit frame beat; a RAM row is RAM_SEG_COUNT of
    // them side by side (1024 bits on the AU200's Gen3 x16).
    parameter RAM_SEG_DATA_WIDTH = 512 * 2 / RAM_SEG_COUNT,
    parameter RAM_SEG_BE_WIDTH = (RAM_SEG_DATA_WIDTH / 8),
    parameter RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT * RAM_SEG_BE_WIDTH),
    parameter RAM_PIPELINE = 2,

    // One proposal slot is one FRAME is one PAGE: 64 bytes of header (beat 0,
    // left for ssr_tx_engine) and 4032 of the host's payload from offset 64. Must
    // equal ssr_packet.vh's SSR_FRAME_BYTES; ssr_tx_engine and ssr_rx_engine check the
    // payload half of it at elaboration.
    parameter RAM_BUFF_SLOT_BYTES = 4096, // size of a proposal slot in bytes
    // 8 slots x 4096 B = 32 KiB, inside the 128 KiB RAM address space and
    // comfortably above P_FRAGS_PER_ROUND (5) so the host can stage the next
    // round while this one drains. ssr_tx_engine reads the queued count once at the
    // round boundary and sends at most P_FRAGS_PER_ROUND of them, so a slot
    // that arrives mid-round belongs to the next round.
    parameter RAM_BUFF_SLOT_COUNT = 8,

    // Ethernet interface configuration (interface)
    parameter AXIS_IF_DATA_WIDTH = 512,
    parameter AXIS_IF_KEEP_WIDTH = (AXIS_IF_DATA_WIDTH / 8),
    parameter AXIS_IF_TX_ID_WIDTH = 13,
    parameter AXIS_IF_RX_ID_WIDTH = PORTS_PER_IF > 1 ? $clog2(PORTS_PER_IF) : 1,
    parameter AXIS_IF_TX_DEST_WIDTH = $clog2(PORTS_PER_IF) + 4,
    parameter AXIS_IF_RX_DEST_WIDTH = 9,
    // These MUST match what mqnic_app_block passes down. They used to default to
    // 1, which silently dropped the transmit tag out of tuser for anything that
    // instantiated this module on its defaults - including the shadow copy in
    // ssr_dataplane_test.v. The tag is what tells an SSR frame's completion from
    // a host frame's, so a 1-bit tuser makes the completion filter unbuildable.
    parameter AXIS_IF_TX_USER_WIDTH = TX_TAG_WIDTH + 1,
    parameter AXIS_IF_RX_USER_WIDTH = (PTP_TS_ENABLE ? PTP_TS_WIDTH : 0) + 1,

    // Consensus Parameters
    parameter P_NODE_ID = 0,
    parameter P_NODE_COUNT = 3,
    parameter P_SYS_CLOCK_FREQ_HZ = 250_000_000,
    parameter P_SLOT_DURATION_NS = 4000,
    parameter P_GUARD_NS = 50,

    // THE ROUND GEOMETRY, AND WHY THESE NUMBERS
    //
    //   Tc = 2*T_prop + (N-1)*t_ctrl + 2g + settle
    //      = 500 + 2*5.12 + 100 + 32 = 642 ns  ->  646
    //
    //   The binding constraint is the RECEIVE side, not the transmit side: we
    //   send one node's payload but receive (N-1) of them on one 100G link.
    //   The payload may arrive from Tc until one propagation past the round
    //   boundary, so
    //
    //      span     = (ROUND + T_prop) - Tc = 3604 ns
    //      capacity = 3604 ns * 12.5 B/ns   = 45 050 B
    //      per peer = 45 050 / (N-1)        = 22 525 B
    //               = 5 frames of 4096 B     -> P_FRAGS_PER_ROUND = 5
    //
    //   So 5 * 4032 = 20 160 B of payload per node per round, 40 Gbps of
    //   payload per node at 250 000 rounds/s, and an end-to-end latency of
    //   2*Tc + Tp = 4.6 us. Raising the fragment count from here means raising
    //   ROUND_LENGTH_NS with it - the throughput barely moves, because both
    //   settle against the same link, but the latency grows in step.
    parameter P_CTRL_PERIOD_NS      = 646,
    parameter P_PROP_DEAD_NS        = 250,
    parameter P_PRESENT_SETTLE_NS   = 32,
    parameter P_FRAGS_PER_ROUND     = 5,
    parameter P_LINE_RATE_GBPS      = 100,
    // The skew gap after our control frame, before any payload. Covers
    // 2g + t_ctrl - see ssr_tx_engine's banner.
    parameter P_PAY_GAP_CYCLES      = 32,
    parameter P_DATA_WIDTH = 512,
    parameter P_KEEP_WIDTH = P_DATA_WIDTH / 8,
    parameter P_ETHERNET_TYPE = 16'h88B5,

    // ---- speculative delivery ----
    // Slots in the receive staging RAM, one frame each. 16 x 4 KiB = 64 KiB,
    // half the 128 KiB RAM address space.
    parameter P_PAY_SLOT_COUNT      = 16,
    // Rounds ssr_presence_tracker holds, and the modulus of the DMA fence. At
    // least 2 - round R is decided at round R+1's control deadline - and a
    // power of two; 4 leaves slack for a verdict held back by a slow PCIe.
    parameter P_ROUND_DEPTH         = 4,
    // DMA write descriptors in flight at once (the tag pool).
    parameter P_DMA_TAG_COUNT       = 16,
    // log2 of the host payload ring, in rounds. 256 rounds is 1 ms.
    parameter P_HOST_DEPTH_LOG2     = 8,
    // log2 of the host verdict ring, in records.
    parameter P_VERDICT_DEPTH_LOG2  = 8,
    // Proposal DMA reads outstanding at once. A 4 KiB read from host memory
    // is ~1-1.5 us; a round wants up to P_FRAGS_PER_ROUND entries every
    // P_SLOT_DURATION_NS. Four keeps the ring ahead of the round.
    parameter P_PROP_MAX_INFLIGHT   = 4
)
(
    input  wire                                     clk,
    input  wire                                     rst,

    // --------------------------------------------------------------
    //                 Control/Status Register interface
    // --------------------------------------------------------------
    input  wire [REG_ADDR_WIDTH-1:0]                reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]                reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]                reg_wr_strb,
    input  wire                                     reg_wr_en,
    output wire                                     reg_wr_wait,
    output wire                                     reg_wr_ack,
    input  wire [REG_ADDR_WIDTH-1:0]                reg_rd_addr,
    input  wire                                     reg_rd_en,
    output wire [REG_DATA_WIDTH-1:0]                reg_rd_data,
    output wire                                     reg_rd_wait,
    output wire                                     reg_rd_ack,

    // --------------------------------------------------------------
    //                          DMA interface
    // --------------------------------------------------------------
    // DMA read descriptor output interface
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_data_dma_read_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_data_dma_read_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_data_dma_read_desc_ram_addr,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_data_dma_read_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_data_dma_read_desc_tag,
    output wire                                     m_axis_data_dma_read_desc_valid,
    input  wire                                     m_axis_data_dma_read_desc_ready,

    // DMA read descriptor status input interface
    input wire [DMA_TAG_WIDTH-1:0]                  s_axis_data_dma_read_desc_status_tag,
    input wire [3:0]                                s_axis_data_dma_read_desc_status_error,
    input wire                                      s_axis_data_dma_read_desc_status_valid,

    // DMA write descriptor output interface
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_data_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_data_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_data_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                 m_axis_data_dma_write_desc_imm,
    output wire                                     m_axis_data_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_data_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_data_dma_write_desc_tag,
    output wire                                     m_axis_data_dma_write_desc_valid,
    input  wire                                     m_axis_data_dma_write_desc_ready,


    // DMA write descriptor status input interface
    input wire [DMA_TAG_WIDTH-1:0]                  s_axis_data_dma_write_desc_status_tag,
    input wire [3:0]                                s_axis_data_dma_write_desc_status_error,
    input wire                                      s_axis_data_dma_write_desc_status_valid,
    
    // DMA RAM write interface
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]            data_dma_ram_wr_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]         data_dma_ram_wr_cmd_be,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]       data_dma_ram_wr_cmd_addr,
    input wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]       data_dma_ram_wr_cmd_data,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_wr_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_wr_cmd_ready,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_wr_done,
    
    // DMA RAM read interface
    input wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]            data_dma_ram_rd_cmd_sel,
    input wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]       data_dma_ram_rd_cmd_addr,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      data_dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                         data_dma_ram_rd_resp_valid,
    input wire [RAM_SEG_COUNT-1:0]                          data_dma_ram_rd_resp_ready,

    // --------------------------------------------------------------
    //              Control DMA: the verdict record only
    // --------------------------------------------------------------
    // Corundum's top-level DMA mux gives the control DMA strict priority over
    // the data DMA (mqnic_core.v, "data/control DMA mux (priority)"), so a
    // verdict never queues behind the NIC's own packet writes - only behind
    // the one operation already in the write engine. Only the write side is
    // used: the descriptor, its status, and this path's own RAM read port,
    // through which the engine fetches the 64 bytes.
    output wire [DMA_ADDR_WIDTH-1:0]                m_axis_ctrl_dma_write_desc_dma_addr,
    output wire [RAM_SEL_WIDTH-1:0]                 m_axis_ctrl_dma_write_desc_ram_sel,
    output wire [RAM_ADDR_WIDTH-1:0]                m_axis_ctrl_dma_write_desc_ram_addr,
    output wire [DMA_IMM_WIDTH-1:0]                 m_axis_ctrl_dma_write_desc_imm,
    output wire                                     m_axis_ctrl_dma_write_desc_imm_en,
    output wire [DMA_LEN_WIDTH-1:0]                 m_axis_ctrl_dma_write_desc_len,
    output wire [DMA_TAG_WIDTH-1:0]                 m_axis_ctrl_dma_write_desc_tag,
    output wire                                     m_axis_ctrl_dma_write_desc_valid,
    input  wire                                     m_axis_ctrl_dma_write_desc_ready,

    input  wire [DMA_TAG_WIDTH-1:0]                 s_axis_ctrl_dma_write_desc_status_tag,
    input  wire [3:0]                               s_axis_ctrl_dma_write_desc_status_error,
    input  wire                                     s_axis_ctrl_dma_write_desc_status_valid,

    input  wire [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]           ctrl_dma_ram_rd_cmd_sel,
    input  wire [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0]      ctrl_dma_ram_rd_cmd_addr,
    input  wire [RAM_SEG_COUNT-1:0]                         ctrl_dma_ram_rd_cmd_valid,
    output wire [RAM_SEG_COUNT-1:0]                         ctrl_dma_ram_rd_cmd_ready,
    output wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0]      ctrl_dma_ram_rd_resp_data,
    output wire [RAM_SEG_COUNT-1:0]                         ctrl_dma_ram_rd_resp_valid,
    input  wire [RAM_SEG_COUNT-1:0]                         ctrl_dma_ram_rd_resp_ready,

    // --------------------------------------------------------------
    //                          PTP clock
    // --------------------------------------------------------------
    input wire                                          ptp_clk,
    input wire                                          ptp_rst,
    input wire                                          ptp_sample_clk,
    input wire                                          ptp_td_sd,
    input wire                                          ptp_pps,
    input wire                                          ptp_pps_str,
    input wire                                          ptp_sync_locked,
    // These two do not follow PTP_TS_WIDTH: mqnic_ptp always produces a 64-bit
    // relative time {ns[47:0], fns[15:0]} and a 96-bit ToD
    // {sec[47:0], ns[31:0], fns[15:0]}.
    input wire [63:0]                                   ptp_sync_ts_rel,
    input wire                                          ptp_sync_ts_rel_step,
    input wire [95:0]                                   ptp_sync_ts_tod,
    input wire                                          ptp_sync_ts_tod_step,
    input wire                                          ptp_sync_pps,
    input wire                                          ptp_sync_pps_str,
    input wire [PTP_PEROUT_COUNT-1:0]                   ptp_perout_locked,
    input wire [PTP_PEROUT_COUNT-1:0]                   ptp_perout_error,
    input wire [PTP_PEROUT_COUNT-1:0]                   ptp_perout_pulse,

    // --------------------------------------------------------------
    //                      Ethernet interfaces
    // --------------------------------------------------------------
    // Ethernet (internal at interface module)
    // TX interface (from DMA to MAC) from host to MAC
    input  wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           s_axis_if_tx_tdata,
    input  wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           s_axis_if_tx_tkeep,
    input  wire [IF_COUNT-1:0]                              s_axis_if_tx_tvalid,
    output wire [IF_COUNT-1:0]                              s_axis_if_tx_tready,
    input  wire [IF_COUNT-1:0]                              s_axis_if_tx_tlast,
    input  wire [IF_COUNT*AXIS_IF_TX_ID_WIDTH-1:0]          s_axis_if_tx_tid,
    input  wire [IF_COUNT*AXIS_IF_TX_DEST_WIDTH-1:0]        s_axis_if_tx_tdest,
    input  wire [IF_COUNT*AXIS_IF_TX_USER_WIDTH-1:0]        s_axis_if_tx_tuser,

    // TX interface (from MAC to DMA) output from tx arbiter to MAC
    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           m_axis_if_tx_tdata,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           m_axis_if_tx_tkeep,
    output wire [IF_COUNT-1:0]                              m_axis_if_tx_tvalid,
    input  wire [IF_COUNT-1:0]                              m_axis_if_tx_tready,
    output wire [IF_COUNT-1:0]                              m_axis_if_tx_tlast,
    output wire [IF_COUNT*AXIS_IF_TX_ID_WIDTH-1:0]          m_axis_if_tx_tid,
    output wire [IF_COUNT*AXIS_IF_TX_DEST_WIDTH-1:0]        m_axis_if_tx_tdest,
    output wire [IF_COUNT*AXIS_IF_TX_USER_WIDTH-1:0]        m_axis_if_tx_tuser,

    // TX CPL from MAC
    input  wire [IF_COUNT*PTP_TS_WIDTH-1:0]                 s_axis_if_tx_cpl_ts,
    input  wire [IF_COUNT*TX_TAG_WIDTH-1:0]                 s_axis_if_tx_cpl_tag,
    input  wire [IF_COUNT-1:0]                              s_axis_if_tx_cpl_valid,
    output wire [IF_COUNT-1:0]                              s_axis_if_tx_cpl_ready,

    // TX CPL to DMA
    output wire [IF_COUNT*PTP_TS_WIDTH-1:0]                 m_axis_if_tx_cpl_ts,
    output wire [IF_COUNT*TX_TAG_WIDTH-1:0]                 m_axis_if_tx_cpl_tag,
    output wire [IF_COUNT-1:0]                              m_axis_if_tx_cpl_valid,
    input  wire [IF_COUNT-1:0]                              m_axis_if_tx_cpl_ready,

    // RX interface (from MAC to DMA) from MAC to rx splitter
    input  wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           s_axis_if_rx_tdata,
    input  wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           s_axis_if_rx_tkeep,
    input  wire [IF_COUNT-1:0]                              s_axis_if_rx_tvalid,
    output wire [IF_COUNT-1:0]                              s_axis_if_rx_tready,
    input  wire [IF_COUNT-1:0]                              s_axis_if_rx_tlast,
    input  wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]          s_axis_if_rx_tid,
    input  wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]        s_axis_if_rx_tdest,
    input  wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]        s_axis_if_rx_tuser,

    // RX interface (from DMA to MAC) from rx splitter to host DMA
    output wire [IF_COUNT*AXIS_IF_DATA_WIDTH-1:0]           m_axis_if_rx_tdata,
    output wire [IF_COUNT*AXIS_IF_KEEP_WIDTH-1:0]           m_axis_if_rx_tkeep,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tvalid,
    input  wire [IF_COUNT-1:0]                              m_axis_if_rx_tready,
    output wire [IF_COUNT-1:0]                              m_axis_if_rx_tlast,
    output wire [IF_COUNT*AXIS_IF_RX_ID_WIDTH-1:0]          m_axis_if_rx_tid,
    output wire [IF_COUNT*AXIS_IF_RX_DEST_WIDTH-1:0]        m_axis_if_rx_tdest,
    output wire [IF_COUNT*AXIS_IF_RX_USER_WIDTH-1:0]        m_axis_if_rx_tuser
);

// ---------------------------------------------------------------- rate cap
// THE RATE CAP THAT REPLACED TDMA
//
//   Every node transmits over the whole round now. What keeps (N-1) of them
//   from swamping one receiver is that each holds its own rate at or below
//   R/(N-1): one frame-time of transmission out of every (N-1).
//
//   So after each fragment, stay quiet for (N-2) frame-times:
//
//      frame_ns  = 4096 * 8 / 100               = 327.7 ns at 100G
//      gap_ns    = frame_ns * (N-2)             = 327.7 at N = 3
//      gap_cycles= gap_ns * 250 MHz / 1000      = 82
//
//   At N = 2 this is zero, which is correct: one peer, nothing to share with.
//
//   Derived here rather than in ssr_tx_engine because this is where the line rate
//   and the system clock are both known, and because it has to be checked
//   against the round length, which ssr_tx_engine also does not know.
localparam integer SSR_FRAME_BYTES_LOCAL = RAM_BUFF_SLOT_BYTES;          // a slot IS a frame
localparam integer SSR_FRAG_BYTES_LOCAL  = RAM_BUFF_SLOT_BYTES - 64;     // less its header row
localparam integer SSR_FRAME_BITS_LOCAL  = SSR_FRAME_BYTES_LOCAL * 8;
localparam integer SYS_CLK_MHZ           = P_SYS_CLOCK_FREQ_HZ / 1_000_000;
localparam integer SSR_FRAME_NS          = SSR_FRAME_BITS_LOCAL / P_LINE_RATE_GBPS;
localparam integer SSR_CTRL_NS           = (64 * 8 + P_LINE_RATE_GBPS - 1) / P_LINE_RATE_GBPS;

localparam integer P_PACE_GAP_CYCLES =
    (SSR_FRAME_BITS_LOCAL * (P_NODE_COUNT - 2) * SYS_CLK_MHZ
     + (P_LINE_RATE_GBPS * 1000 - 1)) / (P_LINE_RATE_GBPS * 1000);

localparam integer PACE_GAP_NS = (P_PACE_GAP_CYCLES * 1000) / SYS_CLK_MHZ;
localparam integer PAY_GAP_NS  = (P_PAY_GAP_CYCLES  * 1000) / SYS_CLK_MHZ;

// THE TRANSMIT WINDOW OF A ROUND (docs/count_ack.md section 5)
//
//   A fragment of round R may START, on our clock, in
//
//     [TX_PAY_START_NS, TX_PAY_CUTOFF_NS]
//
//   The start is our control frame plus the skew gap: payload never goes out
//   ahead of the round's ack vector. The cutoff is the latest start whose
//   last beat is still counted at every peer before that peer's boundary -
//   one frame on the wire, one propagation, the peer's clock up to g ahead,
//   and the staging settle. A fragment counted later would not be in the
//   receiver's ack while it is in ours, and we would lose the round.
//
//   Nothing is planned inside that window: whatever the proposal buffer holds
//   goes out, paced, up to P_FRAGS_PER_ROUND. What is still there at the
//   cutoff goes out next round.
localparam integer TX_START_NS      = P_PROP_DEAD_NS + P_GUARD_NS + P_PRESENT_SETTLE_NS;
localparam integer TX_PAY_START_NS  = TX_START_NS + SSR_CTRL_NS + PAY_GAP_NS;
localparam integer TX_PAY_CUTOFF_NS = P_SLOT_DURATION_NS - SSR_FRAME_NS - P_PROP_DEAD_NS
                                    - P_GUARD_NS - P_PRESENT_SETTLE_NS;
// Where the last of a full round's paced fragments starts.
localparam integer TX_LAST_START_NS = TX_PAY_START_NS
                                    + (P_FRAGS_PER_ROUND - 1) * (SSR_FRAME_NS + PACE_GAP_NS);

initial begin
    // A full round's budget of paced fragments has to fit before the cutoff,
    // or P_FRAGS_PER_ROUND - which sizes the host regions - promises a round
    // the link cannot carry.
    if (TX_LAST_START_NS > TX_PAY_CUTOFF_NS) begin
        $error("a round's paced payload does not fit in a round: the last of %0d fragments would start at %0d ns, past the transmit cutoff at %0d ns of a %0d ns round. Reduce P_FRAGS_PER_ROUND or raise P_SLOT_DURATION_NS.",
               P_FRAGS_PER_ROUND, TX_LAST_START_NS, TX_PAY_CUTOFF_NS, P_SLOT_DURATION_NS);
        $finish;
    end

    // The rate cap only works if everyone obeys it, and it is derived from
    // N here. A cluster of 2 needs no pacing at all.
    if (P_NODE_COUNT < 2) begin
        $error("P_NODE_COUNT (%0d) must be at least 2", P_NODE_COUNT);
        $finish;
    end
end

// ---------------------------------------------------------------- host layout
// A node's region in the host payload ring holds one round's fragments, a
// page each: P_FRAGS_PER_ROUND pages, rounded up to a power of two so the
// address is a shift. Five pages is 20 KiB, so 32 KiB, so 15.
//
// This is the TRANSMIT budget applied to the receive side: every node in the
// cluster is built with the same P_FRAGS_PER_ROUND, and ssr_rx_engine refuses a
// frag_idx at or past it, so no frame can be addressed outside its region.
localparam integer P_REGION_SHIFT = $clog2(P_FRAGS_PER_ROUND * RAM_BUFF_SLOT_BYTES);

initial begin
    // The staging RAM is one ram_sel's address space.
    if (P_PAY_SLOT_COUNT * RAM_BUFF_SLOT_BYTES > (1 << RAM_ADDR_WIDTH)) begin
        $error("ssr_dataplane: %0d staging slots of %0d bytes do not fit a %0d-bit RAM (instance %m)",
               P_PAY_SLOT_COUNT, RAM_BUFF_SLOT_BYTES, RAM_ADDR_WIDTH);
        $finish;
    end
    // At P_PAY_SLOT_COUNT it must be possible to hold a whole round's
    // arrivals from every peer while PCIe is slow: (N-1) peers x
    // P_FRAGS_PER_ROUND frames. Fewer slots means STAGE_FULL under normal
    // load, which is a design error, not a fault.
    if (P_PAY_SLOT_COUNT < (P_NODE_COUNT - 1) * P_FRAGS_PER_ROUND) begin
        $error("ssr_dataplane: %0d staging slots cannot hold one round of %0d peers x %0d fragments (instance %m)",
               P_PAY_SLOT_COUNT, P_NODE_COUNT - 1, P_FRAGS_PER_ROUND);
        $finish;
    end
end

// Kept equal to ssr_packet.vh's SSR_ETHERTYPE and ssr_rx_engine's P_ETHERTYPE.
localparam [15:0] SSR_ETHERTYPE_PARAM = 16'h88B5;

// The proposal ring: DMA reads land in ssr_proposal_buffer's RAM.
localparam RAM_SEL_PROP = 0;
localparam DMA_TAG_PROP = 0;

// The two writers each have a DMA path of their own - pages on the data DMA,
// the verdict record on the control DMA - and each path has its own RAM read
// port, so neither needs a ram_sel to find its bytes, and each path reports
// completions on its own status stream, so their tags cannot collide: the
// payload writer owns tags 0..P_DMA_TAG_COUNT-1 on the data DMA, the verdict
// writer tag 0 on the control DMA.
localparam [RAM_SEL_WIDTH-1:0] RAM_SEL_PAYLOAD  = 0;
localparam [RAM_SEL_WIDTH-1:0] RAM_SEL_VERDICT  = 0;
localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_PAY_BASE = 0;
localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_VERDICT  = 0;

initial begin
    if (P_DMA_TAG_COUNT > (1 << DMA_TAG_WIDTH)) begin
        $error("ssr_dataplane: %0d payload tags do not fit %0d tag bits (instance %m)",
               P_DMA_TAG_COUNT, DMA_TAG_WIDTH);
        $finish;
    end
    if (SSR_IF_INDEX >= IF_COUNT) begin
        $error("ssr_dataplane: SSR_IF_INDEX (%0d) names no interface, IF_COUNT is %0d (instance %m)",
               SSR_IF_INDEX, IF_COUNT);
        $finish;
    end
end

// --------------------------------------------------------------
//                 Tx Modules
// --------------------------------------------------------------

// The two receive windows: the levels that say a frame arriving now belongs to
// the round the core is currently counting. They differ because the two frame
// kinds have different deadlines - a control frame must be in before the
// evaluation instant, a payload frame may arrive at any point in the round -
// and ssr_rx_engine selects between them with the frame's own KIND field.
//
// ssr_rx_engine consumes both COMBINATIONALLY - see the note on the core's
// filter-state exports; a register here would open exactly the boundary window
// the guard time exists to close.
wire rx_ctrl_window_from_core;
// Not a window: "the protocol is running". Payload is admitted on this plus the
// round_id in the frame header, with no time bound at all.
wire rx_pay_window_from_core;
wire round_start_pulse;
wire round_commit_pulse;
wire core_ctrl_end_pulse;      // the evaluation instant: round R is decided here, in round R+1


// --------------------------------------------------------------
//                 Rx Modules
// --------------------------------------------------------------
wire [31:0] rxdmx_dma_frames;

wire [AXIS_IF_DATA_WIDTH-1:0]           axis_cons_rx_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]           axis_cons_rx_tkeep;
wire                                    axis_cons_rx_tvalid;
wire                                    axis_cons_rx_tready;
wire                                    axis_cons_rx_tlast;
wire [AXIS_IF_RX_ID_WIDTH-1:0]          axis_cons_rx_tid;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]        axis_cons_rx_tdest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]        axis_cons_rx_tuser;

// ssr_rx_engine -> ssr_core: "this peer is trusted for this round", nothing
// else. Everything the filter needs comes back the other way (the core's
// run / round / sound set, and our own ack vector from ssr_presence_tracker).
wire        rx_valid;
wire [7:0]  rx_node_id;

// ssr_rx_engine -> ssr_payload_stage: the payload, tagged with whose it is.
wire        rx_pl_sof, rx_pl_valid, rx_pl_last, rx_pl_ready;
wire        rx_pl_commit, rx_pl_drop;
wire [7:0]  rx_pl_node_id;
wire [63:0] rx_pl_round_id;
wire [15:0] rx_pl_len;
wire [AXIS_IF_DATA_WIDTH-1:0] rx_pl_data;

wire [15:0] rx_pl_frag_idx;
// The header beat, valid with rx_pl_sof. ssr_payload_stage stages it as beat 0 of
// the slot; it has no other consumer.
wire [AXIS_IF_DATA_WIDTH-1:0] rx_pl_hdr_data;

// Our ack vector about the previous round, from ssr_presence_tracker: what our
// control frame carries, and what a peer's must equal to be trusted.
wire [63:0] pres_prev_ack;

wire [31:0] rx_frame_count, rx_accept_count, rx_ctrl_count, rx_ack_disagree_count;
wire [31:0] rx_foreign_count, rx_malformed_count;
wire [31:0] rx_window_drop_count, rx_ctrl_late_count, rx_member_drop_count, rx_sound_drop_count;
wire [31:0] rx_run_drop_count, rx_round_drop_count, rx_stall_count;

// ---- speculative delivery: the counters the delivery block reads ----
wire [31:0] stage_push_count, stage_full_count, stage_oversize_count;
wire [31:0] stage_overlap_count, stage_len_mismatch_count;
wire [31:0] pay_desc_count, pay_cpl_count, pay_err_count, pay_starve_count, pay_stray_count;
wire [$clog2(P_DMA_TAG_COUNT+1)-1:0] pay_high_water;
wire [P_ROUND_DEPTH-1:0] pay_unit_idle;
wire [31:0] pres_late_count, pres_err_count, pres_err_miss_count;
wire [63:0] verdict_seq;
wire [31:0] verdict_record_count, verdict_err_count, verdict_overflow_count, verdict_stale_count;

// ---- ssr_tx_mux: the last SSR completion, and its counters ----
wire [PTP_TS_WIDTH-1:0] ssr_cpl_ts;
wire [95:0]             ssr_cpl_ts_96 = ssr_cpl_ts;   // zero-extended for TX_CPL_TS_0..2
wire [31:0] ssr_cpl_count, mux_dma_frames;

// --------------------------------------------------------------
//                 Consensus Core
// --------------------------------------------------------------

wire [63:0] current_round_id;
wire system_halt;

// ---------------------------------------------------------------- the SSR lane
// The IF streams are IF_COUNT lanes wide, one per interface. SSR sits on lane
// SSR_IF_INDEX: its tx, completion and rx streams are cut out into the lane_*
// wires below, which ssr_tx_mux and ssr_rx_demux connect to. Every other lane
// is wired straight through, as if the app block were not there.
//
//   lane_s_* : into SSR on that lane    (host frames, MAC completions, MAC rx)
//   lane_m_* : out of SSR on that lane  (to the MAC, to the host)
wire [AXIS_IF_DATA_WIDTH-1:0]        lane_s_tx_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]        lane_s_tx_tkeep;
wire                                 lane_s_tx_tvalid;
wire                                 lane_s_tx_tready;
wire                                 lane_s_tx_tlast;
wire [AXIS_IF_TX_ID_WIDTH-1:0]       lane_s_tx_tid;
wire [AXIS_IF_TX_DEST_WIDTH-1:0]     lane_s_tx_tdest;
wire [AXIS_IF_TX_USER_WIDTH-1:0]     lane_s_tx_tuser;

wire [AXIS_IF_DATA_WIDTH-1:0]        lane_m_tx_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]        lane_m_tx_tkeep;
wire                                 lane_m_tx_tvalid;
wire                                 lane_m_tx_tready;
wire                                 lane_m_tx_tlast;
wire [AXIS_IF_TX_ID_WIDTH-1:0]       lane_m_tx_tid;
wire [AXIS_IF_TX_DEST_WIDTH-1:0]     lane_m_tx_tdest;
wire [AXIS_IF_TX_USER_WIDTH-1:0]     lane_m_tx_tuser;

wire [PTP_TS_WIDTH-1:0]              lane_s_tx_cpl_ts;
wire [TX_TAG_WIDTH-1:0]              lane_s_tx_cpl_tag;
wire                                 lane_s_tx_cpl_valid;
wire                                 lane_s_tx_cpl_ready;

wire [PTP_TS_WIDTH-1:0]              lane_m_tx_cpl_ts;
wire [TX_TAG_WIDTH-1:0]              lane_m_tx_cpl_tag;
wire                                 lane_m_tx_cpl_valid;
wire                                 lane_m_tx_cpl_ready;

wire [AXIS_IF_DATA_WIDTH-1:0]        lane_s_rx_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]        lane_s_rx_tkeep;
wire                                 lane_s_rx_tvalid;
wire                                 lane_s_rx_tready;
wire                                 lane_s_rx_tlast;
wire [AXIS_IF_RX_ID_WIDTH-1:0]       lane_s_rx_tid;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]     lane_s_rx_tdest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]     lane_s_rx_tuser;

wire [AXIS_IF_DATA_WIDTH-1:0]        lane_m_rx_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0]        lane_m_rx_tkeep;
wire                                 lane_m_rx_tvalid;
wire                                 lane_m_rx_tready;
wire                                 lane_m_rx_tlast;
wire [AXIS_IF_RX_ID_WIDTH-1:0]       lane_m_rx_tid;
wire [AXIS_IF_RX_DEST_WIDTH-1:0]     lane_m_rx_tdest;
wire [AXIS_IF_RX_USER_WIDTH-1:0]     lane_m_rx_tuser;

genvar n;
generate
for (n = 0; n < IF_COUNT; n = n + 1) begin : g_if_lane
    if (n == SSR_IF_INDEX) begin : g_ssr
        assign lane_s_tx_tdata = s_axis_if_tx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH];
        assign m_axis_if_tx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH] = lane_m_tx_tdata;
        assign lane_s_tx_tkeep = s_axis_if_tx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH];
        assign m_axis_if_tx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH] = lane_m_tx_tkeep;
        assign lane_s_tx_tvalid = s_axis_if_tx_tvalid[n];
        assign m_axis_if_tx_tvalid[n] = lane_m_tx_tvalid;
        assign s_axis_if_tx_tready[n] = lane_s_tx_tready;
        assign lane_m_tx_tready = m_axis_if_tx_tready[n];
        assign lane_s_tx_tlast = s_axis_if_tx_tlast[n];
        assign m_axis_if_tx_tlast[n] = lane_m_tx_tlast;
        assign lane_s_tx_tid = s_axis_if_tx_tid[n*AXIS_IF_TX_ID_WIDTH +: AXIS_IF_TX_ID_WIDTH];
        assign m_axis_if_tx_tid[n*AXIS_IF_TX_ID_WIDTH +: AXIS_IF_TX_ID_WIDTH] = lane_m_tx_tid;
        assign lane_s_tx_tdest = s_axis_if_tx_tdest[n*AXIS_IF_TX_DEST_WIDTH +: AXIS_IF_TX_DEST_WIDTH];
        assign m_axis_if_tx_tdest[n*AXIS_IF_TX_DEST_WIDTH +: AXIS_IF_TX_DEST_WIDTH] = lane_m_tx_tdest;
        assign lane_s_tx_tuser = s_axis_if_tx_tuser[n*AXIS_IF_TX_USER_WIDTH +: AXIS_IF_TX_USER_WIDTH];
        assign m_axis_if_tx_tuser[n*AXIS_IF_TX_USER_WIDTH +: AXIS_IF_TX_USER_WIDTH] = lane_m_tx_tuser;
        assign lane_s_tx_cpl_ts = s_axis_if_tx_cpl_ts[n*PTP_TS_WIDTH +: PTP_TS_WIDTH];
        assign m_axis_if_tx_cpl_ts[n*PTP_TS_WIDTH +: PTP_TS_WIDTH] = lane_m_tx_cpl_ts;
        assign lane_s_tx_cpl_tag = s_axis_if_tx_cpl_tag[n*TX_TAG_WIDTH +: TX_TAG_WIDTH];
        assign m_axis_if_tx_cpl_tag[n*TX_TAG_WIDTH +: TX_TAG_WIDTH] = lane_m_tx_cpl_tag;
        assign lane_s_tx_cpl_valid = s_axis_if_tx_cpl_valid[n];
        assign m_axis_if_tx_cpl_valid[n] = lane_m_tx_cpl_valid;
        assign s_axis_if_tx_cpl_ready[n] = lane_s_tx_cpl_ready;
        assign lane_m_tx_cpl_ready = m_axis_if_tx_cpl_ready[n];
        assign lane_s_rx_tdata = s_axis_if_rx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH];
        assign m_axis_if_rx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH] = lane_m_rx_tdata;
        assign lane_s_rx_tkeep = s_axis_if_rx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH];
        assign m_axis_if_rx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH] = lane_m_rx_tkeep;
        assign lane_s_rx_tvalid = s_axis_if_rx_tvalid[n];
        assign m_axis_if_rx_tvalid[n] = lane_m_rx_tvalid;
        assign s_axis_if_rx_tready[n] = lane_s_rx_tready;
        assign lane_m_rx_tready = m_axis_if_rx_tready[n];
        assign lane_s_rx_tlast = s_axis_if_rx_tlast[n];
        assign m_axis_if_rx_tlast[n] = lane_m_rx_tlast;
        assign lane_s_rx_tid = s_axis_if_rx_tid[n*AXIS_IF_RX_ID_WIDTH +: AXIS_IF_RX_ID_WIDTH];
        assign m_axis_if_rx_tid[n*AXIS_IF_RX_ID_WIDTH +: AXIS_IF_RX_ID_WIDTH] = lane_m_rx_tid;
        assign lane_s_rx_tdest = s_axis_if_rx_tdest[n*AXIS_IF_RX_DEST_WIDTH +: AXIS_IF_RX_DEST_WIDTH];
        assign m_axis_if_rx_tdest[n*AXIS_IF_RX_DEST_WIDTH +: AXIS_IF_RX_DEST_WIDTH] = lane_m_rx_tdest;
        assign lane_s_rx_tuser = s_axis_if_rx_tuser[n*AXIS_IF_RX_USER_WIDTH +: AXIS_IF_RX_USER_WIDTH];
        assign m_axis_if_rx_tuser[n*AXIS_IF_RX_USER_WIDTH +: AXIS_IF_RX_USER_WIDTH] = lane_m_rx_tuser;
    end else begin : g_pass
        assign m_axis_if_tx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH] = s_axis_if_tx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH];
        assign m_axis_if_tx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH] = s_axis_if_tx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH];
        assign m_axis_if_tx_tvalid[n] = s_axis_if_tx_tvalid[n];
        assign s_axis_if_tx_tready[n] = m_axis_if_tx_tready[n];
        assign m_axis_if_tx_tlast[n] = s_axis_if_tx_tlast[n];
        assign m_axis_if_tx_tid[n*AXIS_IF_TX_ID_WIDTH +: AXIS_IF_TX_ID_WIDTH] = s_axis_if_tx_tid[n*AXIS_IF_TX_ID_WIDTH +: AXIS_IF_TX_ID_WIDTH];
        assign m_axis_if_tx_tdest[n*AXIS_IF_TX_DEST_WIDTH +: AXIS_IF_TX_DEST_WIDTH] = s_axis_if_tx_tdest[n*AXIS_IF_TX_DEST_WIDTH +: AXIS_IF_TX_DEST_WIDTH];
        assign m_axis_if_tx_tuser[n*AXIS_IF_TX_USER_WIDTH +: AXIS_IF_TX_USER_WIDTH] = s_axis_if_tx_tuser[n*AXIS_IF_TX_USER_WIDTH +: AXIS_IF_TX_USER_WIDTH];
        assign m_axis_if_tx_cpl_ts[n*PTP_TS_WIDTH +: PTP_TS_WIDTH] = s_axis_if_tx_cpl_ts[n*PTP_TS_WIDTH +: PTP_TS_WIDTH];
        assign m_axis_if_tx_cpl_tag[n*TX_TAG_WIDTH +: TX_TAG_WIDTH] = s_axis_if_tx_cpl_tag[n*TX_TAG_WIDTH +: TX_TAG_WIDTH];
        assign m_axis_if_tx_cpl_valid[n] = s_axis_if_tx_cpl_valid[n];
        assign s_axis_if_tx_cpl_ready[n] = m_axis_if_tx_cpl_ready[n];
        assign m_axis_if_rx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH] = s_axis_if_rx_tdata[n*AXIS_IF_DATA_WIDTH +: AXIS_IF_DATA_WIDTH];
        assign m_axis_if_rx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH] = s_axis_if_rx_tkeep[n*AXIS_IF_KEEP_WIDTH +: AXIS_IF_KEEP_WIDTH];
        assign m_axis_if_rx_tvalid[n] = s_axis_if_rx_tvalid[n];
        assign s_axis_if_rx_tready[n] = m_axis_if_rx_tready[n];
        assign m_axis_if_rx_tlast[n] = s_axis_if_rx_tlast[n];
        assign m_axis_if_rx_tid[n*AXIS_IF_RX_ID_WIDTH +: AXIS_IF_RX_ID_WIDTH] = s_axis_if_rx_tid[n*AXIS_IF_RX_ID_WIDTH +: AXIS_IF_RX_ID_WIDTH];
        assign m_axis_if_rx_tdest[n*AXIS_IF_RX_DEST_WIDTH +: AXIS_IF_RX_DEST_WIDTH] = s_axis_if_rx_tdest[n*AXIS_IF_RX_DEST_WIDTH +: AXIS_IF_RX_DEST_WIDTH];
        assign m_axis_if_rx_tuser[n*AXIS_IF_RX_USER_WIDTH +: AXIS_IF_RX_USER_WIDTH] = s_axis_if_rx_tuser[n*AXIS_IF_RX_USER_WIDTH +: AXIS_IF_RX_USER_WIDTH];
    end
end
endgenerate

// ==============================================================
//                      SSR CORE LOGIC
// ==============================================================

// ssr_core (rtl/ssr_core.v): the CSR block, the PTP round generator, the
// consensus pipeline and the halt record.
//
// PTP: the round number is derived from the ToD, {sec[47:0], ns[31:0],
// fns[15:0]}, already synchronised to clk by mqnic_ptp. i_ptp_time_valid is
// tied high because nothing upstream currently reports PTP lock - ssr_core.v treats
// a loss of validity as a timing fault and halts, so wiring a real lock signal
// here is what turns that protection on. TODO.
wire [47:0] core_ptp_tod_sec = ptp_sync_ts_tod[95:48];
wire [31:0] core_ptp_tod_ns  = ptp_sync_ts_tod[47:16];

wire        core_tx_start_pulse;   // the whole transmit interface from the core
wire [63:0] core_tx_round_id;
wire [31:0] core_tx_run_id;
wire        core_tx_pay_open;      // the transmit cutoff, as a level
wire        core_rx_accepted;
wire [31:0] core_rx_run_id;
wire [7:0]  core_rx_sound_set;
wire        core_commit_valid;
wire [63:0] core_commit_round_id;
wire [7:0]  core_commit_set;
// Nothing upstream reports PTP lock yet; see the note above.
wire        core_ptp_time_valid = 1'b1;
// For the registers.
wire        core_activate_taken, core_timing_armed, core_config_excludes_self;
wire [7:0]  core_cur_membership;
wire [3:0]  core_halt_reason;
wire [63:0] core_halt_round_id, core_round_count, core_commit_count;
wire [7:0]  core_halt_witness, core_halt_membership, core_halt_sound_set, core_halt_prev_sound_set;
wire [31:0] core_halt_count, core_time_fault_count;

ssr_core #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_NODE_ID(P_NODE_ID),
    .ROUND_LENGTH_NS(P_SLOT_DURATION_NS),
    .GUARD_TIME_NS(P_GUARD_NS),
    .CTRL_PERIOD_NS(P_CTRL_PERIOD_NS),
    .PROP_DEAD_NS(P_PROP_DEAD_NS),
    .PRESENT_SETTLE_NS(P_PRESENT_SETTLE_NS),
    .TX_PAY_CUTOFF_NS(TX_PAY_CUTOFF_NS)
) core_inst (
    .clk(clk),
    .rst(rst),
    .i_enable(csr_core_enable),
    .i_reboot(csr_core_reboot),
    .i_activate_pending(csr_activate_pending),
    .o_activate_taken(core_activate_taken),
    .i_cfg_run_id(csr_cfg_run_id),
    .i_cfg_membership(csr_cfg_membership),
    .i_cfg_effective_round(csr_cfg_effective_round),

    .i_ptp_tod_sec(core_ptp_tod_sec),
    .i_ptp_tod_ns(core_ptp_tod_ns),
    .i_ptp_time_valid(core_ptp_time_valid),
    .i_ptp_step(ptp_sync_ts_tod_step),

    .o_round_id(current_round_id),
    .o_round_start_pulse(round_start_pulse),
    .o_round_boundary_pulse(round_commit_pulse),
    .o_ctrl_end_pulse(core_ctrl_end_pulse),
    .o_tx_start_pulse(core_tx_start_pulse),
    .o_rx_ctrl_window(rx_ctrl_window_from_core),
    .o_rx_pay_enable(rx_pay_window_from_core),

    .o_tx_round_id(core_tx_round_id),
    .o_tx_run_id(core_tx_run_id),
    .o_tx_pay_open(core_tx_pay_open),

    // The filter's state, out to ssr_rx_engine. All three change only at a round
    // boundary and the receive window is a guard time clear of both edges, so
    // ssr_rx_engine reads them combinationally.
    .o_rx_run_id(core_rx_run_id),
    .o_rx_sound_set(core_rx_sound_set),

    .i_rx_valid(rx_valid),
    .i_rx_node_id(rx_node_id),
    .o_rx_accepted(core_rx_accepted),

    .o_commit_valid(core_commit_valid),
    .o_commit_round_id(core_commit_round_id),
    .o_commit_set(core_commit_set),

    .o_halt(system_halt),
    .o_time_fault(),

    .o_timing_armed(core_timing_armed),
    .o_config_excludes_self(core_config_excludes_self),
    .o_cur_membership(core_cur_membership),
    .o_halt_reason(core_halt_reason),
    .o_halt_round_id(core_halt_round_id),
    .o_halt_witness(core_halt_witness),
    .o_halt_membership(core_halt_membership),
    .o_halt_sound_set(core_halt_sound_set),
    .o_halt_prev_sound_set(core_halt_prev_sound_set),
    .o_round_count(core_round_count),
    .o_commit_count(core_commit_count),
    .o_halt_count(core_halt_count),
    .o_time_fault_count(core_time_fault_count)
);

// ==============================================================
//                          TX datapath
// ==============================================================

// ssr_proposal_dma_reader <-> ssr_proposal_buffer: reserve a slot for a read, report
// its completion, learn when slots commit (in ring order).
localparam integer PROP_SLOT_PTR_W = $clog2(RAM_BUFF_SLOT_COUNT);
wire                            proposal_resv_ready;
wire [PROP_SLOT_PTR_W-1:0]      proposal_resv_slot;
wire [RAM_ADDR_WIDTH-1:0]       proposal_resv_addr;
wire                            proposal_resv;
wire                            proposal_done;
wire [PROP_SLOT_PTR_W-1:0]      proposal_done_slot;
wire                            proposal_commit;
wire                            proposal_settled;
wire                            proposal_rewind;
wire                            proposal_flush;
wire                            proposal_hold;
wire [31:0]                     proposal_consumer;   // -> the verdict record
wire                            prop_idle, prop_error, prop_pending;
wire [3:0]                      prop_error_code;
wire [31:0]                     prop_fetch, prop_inflight, prop_reads, prop_read_errors;

// proposal -> ssr_tx_engine/sink
wire [RAM_SEG_DATA_WIDTH-1:0]                   proposal_buf_rd_data;   // one beat = one RAM segment
wire [RAM_SEG_BE_WIDTH-1:0]                     proposal_buf_rd_be;
wire                                            proposal_buf_rd_valid;
wire                                            proposal_buf_rd_ready;
wire                                            proposal_buf_tx_last;
wire [DMA_LEN_WIDTH-1:0]                        proposal_buf_tx_len;

// One frame per round: a 64-byte header beat followed by the proposal slot,
// row for row. The length and the end of the payload both come from
// ssr_proposal_buffer, so this instance carries no slot geometry of its own.
// The tag on SSR's frames: top bit clear (Corundum's own frames all have it
// set, and it ignores completions without it), the bit below set. ssr_tx_mux.
localparam [15:0] SSR_TX_CPL_TAG = 1 << (TX_TAG_WIDTH-2);

wire [AXIS_IF_DATA_WIDTH-1:0] ssr_tx_tdata;
wire [AXIS_IF_KEEP_WIDTH-1:0] ssr_tx_tkeep;
wire                          ssr_tx_tvalid, ssr_tx_tready, ssr_tx_tlast;
wire [AXIS_IF_TX_USER_WIDTH-1:0] ssr_tx_tuser;

wire [31:0] tx_ctrl_frame_count, tx_pay_frame_count, tx_empty_count;
wire [31:0] tx_overrun_count, tx_missed_count;
wire [31:0] tx_len_mismatch_count, tx_oversize_count;

// One of our own fragments left: ssr_presence_tracker counts it as ack[self].
wire        ssr_local_sent;
wire [63:0] ssr_local_sent_round;

ssr_tx_engine #(
    .P_NODE_ID(P_NODE_ID),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_MAX_PAYLOAD_BYTES(SSR_FRAG_BYTES_LOCAL),
    .P_FRAGS_PER_ROUND(P_FRAGS_PER_ROUND),
    .P_PAY_GAP_CYCLES(P_PAY_GAP_CYCLES),
    .P_PACE_GAP_CYCLES(P_PACE_GAP_CYCLES),
    .AXIS_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .AXIS_KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .AXIS_USER_WIDTH(AXIS_IF_TX_USER_WIDTH),
    .P_TX_CPL_TAG(SSR_TX_CPL_TAG),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH)
) tx_engine_inst (
    .clk(clk),
    .rst(rst),

    .i_tx_start_pulse(core_tx_start_pulse),
    .i_tx_round_id(core_tx_round_id),
    .i_tx_run_id(core_tx_run_id),
    .i_tx_pay_open(core_tx_pay_open),
    .i_tx_ack(pres_prev_ack),

    .i_buf_rd_data(proposal_buf_rd_data),
    .i_buf_rd_valid(proposal_buf_rd_valid),
    .o_buf_rd_ready(proposal_buf_rd_ready),
    .i_buf_tx_last(proposal_buf_tx_last),
    .i_buf_tx_len(proposal_buf_tx_len),

    .m_axis_tdata(ssr_tx_tdata),
    .m_axis_tkeep(ssr_tx_tkeep),
    .m_axis_tvalid(ssr_tx_tvalid),
    .m_axis_tready(ssr_tx_tready),
    .m_axis_tlast(ssr_tx_tlast),
    .m_axis_tuser(ssr_tx_tuser),

    .o_local_sent(ssr_local_sent),
    .o_local_sent_round(ssr_local_sent_round),

    .o_ctrl_frame_count(tx_ctrl_frame_count),
    .o_pay_frame_count(tx_pay_frame_count),
    .o_empty_count(tx_empty_count),
    .o_overrun_count(tx_overrun_count),
    .o_missed_count(tx_missed_count),
    .o_len_mismatch_count(tx_len_mismatch_count),
    .o_oversize_count(tx_oversize_count)
);


ssr_tx_mux #(
    .AXIS_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .AXIS_KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .AXIS_ID_WIDTH(AXIS_IF_TX_ID_WIDTH),
    .AXIS_DEST_WIDTH(AXIS_IF_TX_DEST_WIDTH),
    .TX_TAG_WIDTH(TX_TAG_WIDTH),
    .AXIS_USER_WIDTH(AXIS_IF_TX_USER_WIDTH),
    .PTP_TS_WIDTH(PTP_TS_WIDTH),
    .P_SSR_TAG(SSR_TX_CPL_TAG)
) ssr_tx_mux_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_ssr_tdata(ssr_tx_tdata),
    .s_axis_ssr_tkeep(ssr_tx_tkeep),
    .s_axis_ssr_tvalid(ssr_tx_tvalid),
    .s_axis_ssr_tready(ssr_tx_tready),
    .s_axis_ssr_tlast(ssr_tx_tlast),
    .s_axis_ssr_tuser(ssr_tx_tuser),
    .s_axis_ssr_tid({AXIS_IF_TX_ID_WIDTH{1'b0}}),
    .s_axis_ssr_tdest({AXIS_IF_TX_DEST_WIDTH{1'b0}}),

    .s_axis_dma_tdata(lane_s_tx_tdata),
    .s_axis_dma_tkeep(lane_s_tx_tkeep),
    .s_axis_dma_tvalid(lane_s_tx_tvalid),
    .s_axis_dma_tready(lane_s_tx_tready),
    .s_axis_dma_tlast(lane_s_tx_tlast),
    .s_axis_dma_tuser(lane_s_tx_tuser),
    .s_axis_dma_tid(lane_s_tx_tid),
    .s_axis_dma_tdest(lane_s_tx_tdest),

    .m_axis_tx_tdata(lane_m_tx_tdata),
    .m_axis_tx_tkeep(lane_m_tx_tkeep),
    .m_axis_tx_tvalid(lane_m_tx_tvalid),
    .m_axis_tx_tready(lane_m_tx_tready),
    .m_axis_tx_tlast(lane_m_tx_tlast),
    .m_axis_tx_tuser(lane_m_tx_tuser),
    .m_axis_tx_tid(lane_m_tx_tid),
    .m_axis_tx_tdest(lane_m_tx_tdest),

    .s_axis_tx_cpl_ts(lane_s_tx_cpl_ts),
    .s_axis_tx_cpl_tag(lane_s_tx_cpl_tag),
    .s_axis_tx_cpl_valid(lane_s_tx_cpl_valid),
    .s_axis_tx_cpl_ready(lane_s_tx_cpl_ready),

    .m_axis_tx_cpl_ts(lane_m_tx_cpl_ts),
    .m_axis_tx_cpl_tag(lane_m_tx_cpl_tag),
    .m_axis_tx_cpl_valid(lane_m_tx_cpl_valid),
    .m_axis_tx_cpl_ready(lane_m_tx_cpl_ready),

    .o_ssr_cpl_ts(ssr_cpl_ts),
    .o_ssr_cpl_count(ssr_cpl_count),
    .o_ssr_cpl_overrun(),              // i_ssr_cpl_ack is unwired, so this would only count completions
    .i_ssr_cpl_ack(1'b0),

    .o_ssr_frame_count(),              // = TX_CTRL_FRAMES + TX_PAY_FRAMES
    .o_dma_frame_count(mux_dma_frames)
);


// ------------------------------------------------
//      instance of proposal DMA reader
// ------------------------------------------------
ssr_proposal_dma_reader #(
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),

    .RAM_SEL_PROP(RAM_SEL_PROP),
    .DMA_TAG_PROP(DMA_TAG_PROP),
    .PROPOSAL_SLOT_BYTES(RAM_BUFF_SLOT_BYTES),
    .PROPOSAL_SLOT_COUNT(RAM_BUFF_SLOT_COUNT),
    .MAX_INFLIGHT(P_PROP_MAX_INFLIGHT)
)
proposal_dma_reader_inst (
    .clk(clk),
    .rst(rst),

    .i_enable(csr_prop_enable),
    .i_flush(csr_prop_flush),
    .i_clear_error(csr_prop_clear_error),
    .i_ring_base(csr_prop_base),
    .i_depth_log2(csr_prop_depth_log2),
    .i_producer(csr_prop_producer),

    .o_idle(prop_idle),
    .o_error(prop_error),
    .o_pending(prop_pending),
    .o_error_code(prop_error_code),
    .o_fetch(prop_fetch),
    .o_inflight(prop_inflight),
    .o_reads(prop_reads),
    .o_read_errors(prop_read_errors),

    // DMA read descriptor output interface
    .m_axis_dma_read_desc_dma_addr(m_axis_data_dma_read_desc_dma_addr),
    .m_axis_dma_read_desc_ram_sel(m_axis_data_dma_read_desc_ram_sel),
    .m_axis_dma_read_desc_ram_addr(m_axis_data_dma_read_desc_ram_addr),
    .m_axis_dma_read_desc_len(m_axis_data_dma_read_desc_len),
    .m_axis_dma_read_desc_tag(m_axis_data_dma_read_desc_tag),
    .m_axis_dma_read_desc_valid(m_axis_data_dma_read_desc_valid),
    .m_axis_dma_read_desc_ready(m_axis_data_dma_read_desc_ready),

    // DMA read descriptor status input interface
    .s_axis_dma_read_desc_status_tag(s_axis_data_dma_read_desc_status_tag),
    .s_axis_dma_read_desc_status_error(s_axis_data_dma_read_desc_status_error),
    .s_axis_dma_read_desc_status_valid(s_axis_data_dma_read_desc_status_valid),

    // ssr_proposal_buffer's reader side
    .i_resv_ready(proposal_resv_ready),
    .i_resv_slot(proposal_resv_slot),
    .i_resv_addr(proposal_resv_addr),
    .o_resv(proposal_resv),
    .o_done(proposal_done),
    .o_done_slot(proposal_done_slot),
    .i_commit(proposal_commit),
    .i_settled(proposal_settled),
    .o_rewind(proposal_rewind),
    .o_flush(proposal_flush),
    .o_hold(proposal_hold),

    .o_consumer(proposal_consumer)
);

// -------------------------------------------------
//     instance of proposal buffer
// -------------------------------------------------
ssr_proposal_buffer #(
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),

    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_SEL_PROP(RAM_SEL_PROP),

    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE),

    .PROPOSAL_SLOT_BYTES(RAM_BUFF_SLOT_BYTES),
    .PROPOSAL_SLOT_COUNT(RAM_BUFF_SLOT_COUNT)
)
proposal_buffer_inst (
    .clk(clk),
    .rst(rst),

    // Direct DMA RAM write endpoint
    .dma_ram_wr_cmd_sel(data_dma_ram_wr_cmd_sel),
    .dma_ram_wr_cmd_be(data_dma_ram_wr_cmd_be),
    .dma_ram_wr_cmd_addr(data_dma_ram_wr_cmd_addr),
    .dma_ram_wr_cmd_data(data_dma_ram_wr_cmd_data),
    .dma_ram_wr_cmd_valid(data_dma_ram_wr_cmd_valid),
    .dma_ram_wr_cmd_ready(data_dma_ram_wr_cmd_ready),
    .dma_ram_wr_done(data_dma_ram_wr_done),

    // The reader's side
    .o_resv_ready(proposal_resv_ready),
    .o_resv_slot(proposal_resv_slot),
    .o_resv_addr(proposal_resv_addr),
    .i_resv(proposal_resv),
    .i_done(proposal_done),
    .i_done_slot(proposal_done_slot),
    .o_commit(proposal_commit),
    .o_settled(proposal_settled),
    .i_rewind(proposal_rewind),
    .i_flush(proposal_flush),
    .i_hold(proposal_hold),

    // Stream to ssr_tx_engine/sink
    .o_buf_rd_data(proposal_buf_rd_data),
    .o_buf_rd_be(proposal_buf_rd_be),
    .o_buf_rd_valid(proposal_buf_rd_valid),
    .i_buf_rd_ready(proposal_buf_rd_ready),
    .o_buf_tx_last(proposal_buf_tx_last),
    .o_buf_tx_len(proposal_buf_tx_len),
    .o_buf_slot_count()                  // nothing plans a round any more
);

// ==============================================================
//                          RX datapath
// ==============================================================
//
//   port -> ssr_rx_demux -> ssr_rx_engine -+-> ssr_core      trusted peers
//                                      +-> ssr_presence_tracker    fragment counts
//                                      +-> ssr_payload_stage       the bytes
//                                             |
//                                             v
//                                      ssr_payload_dma_writer -> host pages
//   ssr_core -> ssr_verdict_dma_writer -> host record
//
// ssr_rx_engine replaced consensus_rx, which used to parse the frame AND hand the
// core a run id and a round id for the core to re-check. The core now exports
// the filter's state instead and ssr_rx_engine applies it once, on the header beat:
// one arbiter, one rejection ladder, one counter per reason.
//
// Everything after ssr_rx_engine is speculative delivery (docs/speculative_delivery.md):
// a payload frame is DMA'd to the host the moment it lands, a round and a
// control period before the round is decided (round R is decided at round
// R+1's control deadline), and the decision follows as a 64-byte record
// fenced behind the pages.

ssr_rx_engine #(
    .P_NODE_ID(P_NODE_ID),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_MAX_PAYLOAD_BYTES(SSR_FRAG_BYTES_LOCAL),  // == SSR_FRAG_BYTES, checked inside
    .P_FRAGS_PER_ROUND(P_FRAGS_PER_ROUND),       // frag_idx past this would leave the region
    .P_ETHERTYPE(P_ETHERNET_TYPE),
    .AXIS_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .AXIS_KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .AXIS_USER_WIDTH(AXIS_IF_RX_USER_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH)
) rx_engine_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_tdata(axis_cons_rx_tdata),
    .s_axis_tkeep(axis_cons_rx_tkeep),
    .s_axis_tvalid(axis_cons_rx_tvalid),
    .s_axis_tready(axis_cons_rx_tready),
    .s_axis_tlast(axis_cons_rx_tlast),
    .s_axis_tuser(axis_cons_rx_tuser),

    // The filter's state, straight from the core with no register in between.
    .i_rx_ctrl_window(rx_ctrl_window_from_core),
    .i_rx_pay_enable(rx_pay_window_from_core),
    .i_rx_run_id(core_rx_run_id),
    .i_rx_round_id(current_round_id),
    .i_rx_sound_set(core_rx_sound_set),
    .i_rx_self_ack(pres_prev_ack),

    .o_rx_valid(rx_valid),
    .o_rx_node_id(rx_node_id),

    .o_pl_sof(rx_pl_sof),
    .o_pl_node_id(rx_pl_node_id),
    .o_pl_round_id(rx_pl_round_id),
    .o_pl_len(rx_pl_len),
    .o_pl_frag_idx(rx_pl_frag_idx),
    .o_pl_hdr_data(rx_pl_hdr_data),
    .o_pl_valid(rx_pl_valid),
    .o_pl_data(rx_pl_data),
    .o_pl_last(rx_pl_last),
    .i_pl_ready(rx_pl_ready),
    .o_pl_commit(rx_pl_commit),
    .o_pl_drop(rx_pl_drop),

    .o_frame_count(rx_frame_count),
    .o_accept_count(rx_accept_count),
    .o_ctrl_count(rx_ctrl_count),
    .o_foreign_count(rx_foreign_count),
    .o_malformed_count(rx_malformed_count),
    .o_window_drop_count(rx_window_drop_count),
    .o_ctrl_late_count(rx_ctrl_late_count),
    .o_member_drop_count(rx_member_drop_count),
    .o_sound_drop_count(rx_sound_drop_count),
    .o_run_drop_count(rx_run_drop_count),
    .o_round_drop_count(rx_round_drop_count),
    .o_ack_disagree_count(rx_ack_disagree_count),
    .o_stall_count(rx_stall_count)
);

// ---------------------------------------------------------------- staging
// A frame lands here whole - header row and payload rows - in one slot of a
// small ring, and leaves as one DMA write descriptor. The slot is not reused
// until that descriptor's completion comes back: Corundum's write engine reads
// the RAM asynchronously after accepting the descriptor.
localparam integer PAY_SLOT_PTR_W = (P_PAY_SLOT_COUNT > 1) ? $clog2(P_PAY_SLOT_COUNT) : 1;

wire                        stage_staged;      // a frame was stored, on its commit cycle
wire                        stage_head_valid;
wire [RAM_ADDR_WIDTH-1:0]   stage_head_addr;
wire [DMA_LEN_WIDTH-1:0]    stage_head_len;
wire [63:0]                 stage_head_round_id;
wire [7:0]                  stage_head_node_id;
wire [15:0]                 stage_head_frag_idx;
wire [PAY_SLOT_PTR_W-1:0]   stage_head_slot;
wire                        stage_head_pop;
wire                        stage_desc_done;
wire [PAY_SLOT_PTR_W-1:0]   stage_done_slot;

ssr_payload_stage #(
    .AXIS_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_BE_WIDTH(RAM_SEG_BE_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .RAM_PIPELINE(RAM_PIPELINE),
    .PAY_SLOT_BYTES(RAM_BUFF_SLOT_BYTES),
    .PAY_SLOT_COUNT(P_PAY_SLOT_COUNT)
) payload_stage_inst (
    .clk(clk),
    .rst(rst),

    .i_pl_sof(rx_pl_sof),
    .i_pl_node_id(rx_pl_node_id),
    .i_pl_round_id(rx_pl_round_id),
    .i_pl_len(rx_pl_len),
    .i_pl_frag_idx(rx_pl_frag_idx),
    .i_pl_hdr_data(rx_pl_hdr_data),
    .i_pl_valid(rx_pl_valid),
    .i_pl_data(rx_pl_data),
    .o_pl_ready(rx_pl_ready),
    .i_pl_commit(rx_pl_commit),
    .i_pl_drop(rx_pl_drop),

    .o_staged(stage_staged),

    .o_head_valid(stage_head_valid),
    .o_head_addr(stage_head_addr),
    .o_head_len(stage_head_len),
    .o_head_round_id(stage_head_round_id),
    .o_head_node_id(stage_head_node_id),
    .o_head_frag_idx(stage_head_frag_idx),
    .o_head_slot(stage_head_slot),
    .i_head_pop(stage_head_pop),
    .i_desc_done(stage_desc_done),
    .i_done_slot(stage_done_slot),

    .o_push_count(stage_push_count),
    .o_full_count(stage_full_count),
    .o_oversize_count(stage_oversize_count),
    .o_overlap_count(stage_overlap_count),
    .o_len_mismatch_count(stage_len_mismatch_count),

    // the data DMA's RAM read port: only pages are read through it
    // (data_dma_ram_rd_cmd_sel is always RAM_SEL_PAYLOAD and not looked at)
    .dma_ram_rd_cmd_addr(data_dma_ram_rd_cmd_addr),
    .dma_ram_rd_cmd_valid(data_dma_ram_rd_cmd_valid),
    .dma_ram_rd_cmd_ready(data_dma_ram_rd_cmd_ready),
    .dma_ram_rd_resp_data(data_dma_ram_rd_resp_data),
    .dma_ram_rd_resp_valid(data_dma_ram_rd_resp_valid),
    .dma_ram_rd_resp_ready(data_dma_ram_rd_resp_ready)
);

// ---------------------------------------------------------------- pages out
// The payload writer owns the data DMA's write side outright.

wire        pay_err_valid;
wire [63:0] pay_err_round_id;
wire [7:0]  pay_err_node;

ssr_payload_dma_writer #(
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .P_RAM_SEL(RAM_SEL_PAYLOAD),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_REGION_SHIFT(P_REGION_SHIFT),
    .P_HOST_DEPTH_LOG2(P_HOST_DEPTH_LOG2),
    .TAG_COUNT(P_DMA_TAG_COUNT),
    .TAG_BASE(DMA_TAG_PAY_BASE),
    .UNIT_COUNT(P_ROUND_DEPTH),
    .SLOT_PTR_W(PAY_SLOT_PTR_W)
) payload_dma_writer_inst (
    .clk(clk),
    .rst(rst),

    .i_enable(csr_pay_enable),
    .i_ring_base(csr_payload_base),

    .i_head_valid(stage_head_valid),
    .i_head_addr(stage_head_addr),
    .i_head_len(stage_head_len),
    .i_head_round_id(stage_head_round_id),
    .i_head_node_id(stage_head_node_id),
    .i_head_frag_idx(stage_head_frag_idx),
    .i_head_slot(stage_head_slot),
    .o_head_pop(stage_head_pop),

    .o_desc_done(stage_desc_done),
    .o_done_slot(stage_done_slot),

    .o_err_valid(pay_err_valid),
    .o_err_round_id(pay_err_round_id),
    .o_err_node(pay_err_node),
    .o_unit_idle(pay_unit_idle),

    .m_axis_dma_write_desc_dma_addr(m_axis_data_dma_write_desc_dma_addr),
    .m_axis_dma_write_desc_ram_sel(m_axis_data_dma_write_desc_ram_sel),
    .m_axis_dma_write_desc_ram_addr(m_axis_data_dma_write_desc_ram_addr),
    .m_axis_dma_write_desc_len(m_axis_data_dma_write_desc_len),
    .m_axis_dma_write_desc_tag(m_axis_data_dma_write_desc_tag),
    .m_axis_dma_write_desc_valid(m_axis_data_dma_write_desc_valid),
    .m_axis_dma_write_desc_ready(m_axis_data_dma_write_desc_ready),

    .s_axis_dma_write_desc_status_tag(s_axis_data_dma_write_desc_status_tag),
    .s_axis_dma_write_desc_status_error(s_axis_data_dma_write_desc_status_error),
    .s_axis_dma_write_desc_status_valid(s_axis_data_dma_write_desc_status_valid),

    .o_desc_count(pay_desc_count),
    .o_cpl_count(pay_cpl_count),
    .o_err_count(pay_err_count),
    .o_starve_count(pay_starve_count),
    .o_stray_count(pay_stray_count),
    .o_high_water(pay_high_water)
);

// ---------------------------------------------------------------- presence
wire [63:0]  verdict_q_round_id;
wire         verdict_q_hit;
wire [7:0]   verdict_q_present;
wire [127:0] verdict_q_frag_count;

ssr_presence_tracker #(
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_NODE_ID(P_NODE_ID),
    .P_ROUND_DEPTH(P_ROUND_DEPTH)
) presence_tracker_inst (
    .clk(clk),
    .rst(rst),

    // Pure timing, not the protocol-gated boundary: the round a node is
    // activated in has to be open too, and that boundary is the one on which
    // the core leaves S_WAIT_ACTIVATE.
    .i_open(round_start_pulse),
    .i_open_round_id(current_round_id),

    .i_local_sent(ssr_local_sent),
    .i_local_round_id(ssr_local_sent_round),

    .i_pl_sof(rx_pl_sof),
    .i_pl_node_id(rx_pl_node_id),
    .i_pl_round_id(rx_pl_round_id),
    .i_pl_frag_idx(rx_pl_frag_idx),
    .i_pl_commit(stage_staged),      // stored, not merely received

    .i_err_valid(pay_err_valid),
    .i_err_round_id(pay_err_round_id),
    .i_err_node(pay_err_node),

    .o_prev_ack(pres_prev_ack),

    .i_qb_round_id(verdict_q_round_id),
    .o_qb_hit(verdict_q_hit),
    .o_qb_present(verdict_q_present),
    .o_qb_frag_count(verdict_q_frag_count),

    .o_late_count(pres_late_count),
    .o_err_count(pres_err_count),
    .o_err_miss_count(pres_err_miss_count)
);

// ---------------------------------------------------------------- verdict
// The verdict writer owns the control DMA's write side: see the port list for
// why the record goes there and not on the data DMA with the pages.

ssr_verdict_dma_writer #(
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_SEG_ADDR_WIDTH(RAM_SEG_ADDR_WIDTH),
    .P_RAM_SEL(RAM_SEL_VERDICT),
    .P_TAG(DMA_TAG_VERDICT),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_NODE_ID(P_NODE_ID),
    .UNIT_COUNT(P_ROUND_DEPTH),
    .P_HOST_DEPTH_LOG2(P_VERDICT_DEPTH_LOG2)
) verdict_dma_writer_inst (
    .clk(clk),
    .rst(rst),

    .i_enable(csr_ver_enable),
    .i_ring_base(csr_verdict_base),

    .i_commit_valid(core_commit_valid),
    .i_commit_round_id(core_commit_round_id),
    .i_commit_set(core_commit_set),
    .i_run_id(core_tx_run_id),
    .i_prop_consumer(proposal_consumer),

    .i_unit_idle(pay_unit_idle),

    .o_q_round_id(verdict_q_round_id),
    .i_q_hit(verdict_q_hit),
    .i_q_present(verdict_q_present),
    .i_q_frag_count(verdict_q_frag_count),

    .m_axis_dma_write_desc_dma_addr(m_axis_ctrl_dma_write_desc_dma_addr),
    .m_axis_dma_write_desc_ram_sel(m_axis_ctrl_dma_write_desc_ram_sel),
    .m_axis_dma_write_desc_ram_addr(m_axis_ctrl_dma_write_desc_ram_addr),
    .m_axis_dma_write_desc_len(m_axis_ctrl_dma_write_desc_len),
    .m_axis_dma_write_desc_tag(m_axis_ctrl_dma_write_desc_tag),
    .m_axis_dma_write_desc_valid(m_axis_ctrl_dma_write_desc_valid),
    .m_axis_dma_write_desc_ready(m_axis_ctrl_dma_write_desc_ready),

    .s_axis_dma_write_desc_status_tag(s_axis_ctrl_dma_write_desc_status_tag),
    .s_axis_dma_write_desc_status_error(s_axis_ctrl_dma_write_desc_status_error),
    .s_axis_dma_write_desc_status_valid(s_axis_ctrl_dma_write_desc_status_valid),

    // the control DMA's RAM read port: the record register answers it
    .dma_ram_rd_cmd_addr(ctrl_dma_ram_rd_cmd_addr),
    .dma_ram_rd_cmd_valid(ctrl_dma_ram_rd_cmd_valid),
    .dma_ram_rd_cmd_ready(ctrl_dma_ram_rd_cmd_ready),
    .dma_ram_rd_resp_data(ctrl_dma_ram_rd_resp_data),
    .dma_ram_rd_resp_valid(ctrl_dma_ram_rd_resp_valid),
    .dma_ram_rd_resp_ready(ctrl_dma_ram_rd_resp_ready),

    .o_seq(verdict_seq),
    .o_record_count(verdict_record_count),
    .o_err_count(verdict_err_count),
    .o_overflow_count(verdict_overflow_count),
    .o_stale_count(verdict_stale_count)
);

// ---------------------------------------------------------------- immediates
// Neither writer uses the immediate field: the bytes always come from RAM.
assign m_axis_data_dma_write_desc_imm      = {DMA_IMM_WIDTH{1'b0}};
assign m_axis_data_dma_write_desc_imm_en   = 1'b0;
assign m_axis_ctrl_dma_write_desc_imm      = {DMA_IMM_WIDTH{1'b0}};
assign m_axis_ctrl_dma_write_desc_imm_en   = 1'b0;


// The receive counterpart of ssr_tx_mux: it takes SSR's own frames out of the
// interface's receive stream and passes EVERYTHING ELSE straight to the host.
//
// This replaced consensus_rx_splitter, which recognised a second ethertype
// (0x88B6) as a second "application" and dropped everything it did not know.
// Since that second output was wired here, to m_axis_if_rx - the host path - a
// plain ping to this interface was discarded at the app boundary with no back
// pressure and no counter moving. There is one SSR ethertype; the rest of the
// world belongs to the host.
ssr_rx_demux #(
    .AXIS_IF_DATA_WIDTH(AXIS_IF_DATA_WIDTH),
    .AXIS_IF_KEEP_WIDTH(AXIS_IF_KEEP_WIDTH),
    .AXIS_IF_RX_USER_WIDTH(AXIS_IF_RX_USER_WIDTH),
    .AXIS_IF_RX_ID_WIDTH(AXIS_IF_RX_ID_WIDTH),
    .AXIS_IF_RX_DEST_WIDTH(AXIS_IF_RX_DEST_WIDTH),
    .P_SSR_ETHERTYPE(SSR_ETHERTYPE_PARAM)
) ssr_rx_demux_inst (
    .clk(clk),
    .rst(rst),

    .s_axis_rx_tdata(lane_s_rx_tdata),
    .s_axis_rx_tkeep(lane_s_rx_tkeep),
    .s_axis_rx_tvalid(lane_s_rx_tvalid),
    .s_axis_rx_tready(lane_s_rx_tready),
    .s_axis_rx_tlast(lane_s_rx_tlast),
    .s_axis_rx_tid(lane_s_rx_tid),
    .s_axis_rx_tdest(lane_s_rx_tdest),
    .s_axis_rx_tuser(lane_s_rx_tuser),

    .m_axis_ssr_tdata(axis_cons_rx_tdata),
    .m_axis_ssr_tkeep(axis_cons_rx_tkeep),
    .m_axis_ssr_tvalid(axis_cons_rx_tvalid),
    .m_axis_ssr_tready(axis_cons_rx_tready),
    .m_axis_ssr_tlast(axis_cons_rx_tlast),
    .m_axis_ssr_tid(axis_cons_rx_tid),
    .m_axis_ssr_tdest(axis_cons_rx_tdest),
    .m_axis_ssr_tuser(axis_cons_rx_tuser),

    .m_axis_dma_tdata(lane_m_rx_tdata),
    .m_axis_dma_tkeep(lane_m_rx_tkeep),
    .m_axis_dma_tvalid(lane_m_rx_tvalid),
    .m_axis_dma_tready(lane_m_rx_tready),
    .m_axis_dma_tlast(lane_m_rx_tlast),
    .m_axis_dma_tid(lane_m_rx_tid),
    .m_axis_dma_tdest(lane_m_rx_tdest),
    .m_axis_dma_tuser(lane_m_rx_tuser),

    .o_ssr_frame_count(),              // = RX_FRAMES
    .o_dma_frame_count(rxdmx_dma_frames)
);

// ==============================================================
//                          Registers
// ==============================================================
// ssr_csr holds every register the host can see and decodes the bus once; its
// header is the map. Settings go down to the modules below as csr_* wires,
// their state comes back up as the i_* inputs here.
wire        csr_core_enable, csr_core_reboot, csr_activate_pending;
wire [31:0] csr_cfg_run_id;
wire [7:0]  csr_cfg_membership;
wire [63:0] csr_cfg_effective_round;
wire        csr_prop_enable, csr_prop_flush, csr_prop_clear_error;
wire [4:0]  csr_prop_depth_log2;
wire [63:0] csr_prop_base;
wire [31:0] csr_prop_producer;
wire        csr_pay_enable, csr_ver_enable;
wire [63:0] csr_payload_base, csr_verdict_base;

// DLV_STATUS's two bytes.
wire [7:0]  csr_unit_idle  = pay_unit_idle;
wire [7:0]  csr_high_water = pay_high_water;

// Events a correct design never produces, one FAULT bit each (ssr_csr's
// header lists them). The modules keep the exact counts for simulation.
wire [7:0]  csr_fault = {1'b0,
                         pay_stray_count != 0,
                         stage_len_mismatch_count != 0,
                         stage_overlap_count != 0,
                         stage_oversize_count != 0,
                         tx_oversize_count != 0,
                         tx_len_mismatch_count != 0,
                         rx_foreign_count != 0};

ssr_csr #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .REG_STRB_WIDTH(REG_STRB_WIDTH),
    .P_NODE_ID(P_NODE_ID),
    .P_NODE_COUNT(P_NODE_COUNT),
    .P_ROUND_NS(P_SLOT_DURATION_NS),
    .P_REGION_SHIFT(P_REGION_SHIFT),
    .P_HOST_DEPTH_LOG2(P_HOST_DEPTH_LOG2),
    .P_VERDICT_DEPTH_LOG2(P_VERDICT_DEPTH_LOG2),
    .P_PAGE_BYTES(RAM_BUFF_SLOT_BYTES)
) csr_inst (
    .clk(clk),
    .rst(rst),

    .reg_wr_addr(reg_wr_addr),
    .reg_wr_data(reg_wr_data),
    .reg_wr_strb(reg_wr_strb),
    .reg_wr_en(reg_wr_en),
    .reg_wr_wait(reg_wr_wait),
    .reg_wr_ack(reg_wr_ack),
    .reg_rd_addr(reg_rd_addr),
    .reg_rd_en(reg_rd_en),
    .reg_rd_data(reg_rd_data),
    .reg_rd_wait(reg_rd_wait),
    .reg_rd_ack(reg_rd_ack),

    .i_fault(csr_fault),

    .o_core_enable(csr_core_enable),
    .o_core_reboot(csr_core_reboot),
    .o_activate_pending(csr_activate_pending),
    .i_activate_taken(core_activate_taken),
    .o_cfg_run_id(csr_cfg_run_id),
    .o_cfg_membership(csr_cfg_membership),
    .o_cfg_effective_round(csr_cfg_effective_round),
    .i_halt(system_halt),
    .i_timing_armed(core_timing_armed),
    .i_ptp_time_valid(core_ptp_time_valid),
    .i_config_excludes_self(core_config_excludes_self),
    .i_round_id(current_round_id),
    .i_cur_run_id(core_rx_run_id),
    .i_cur_sound_set(core_rx_sound_set),
    .i_cur_membership(core_cur_membership),
    .i_halt_reason(core_halt_reason),
    .i_halt_round_id(core_halt_round_id),
    .i_halt_witness(core_halt_witness),
    .i_halt_membership(core_halt_membership),
    .i_halt_sound_set(core_halt_sound_set),
    .i_halt_prev_sound_set(core_halt_prev_sound_set),
    .i_round_count(core_round_count),
    .i_commit_count(core_commit_count),
    .i_halt_count(core_halt_count),
    .i_time_fault_count(core_time_fault_count),

    .o_prop_enable(csr_prop_enable),
    .o_prop_flush(csr_prop_flush),
    .o_prop_clear_error(csr_prop_clear_error),
    .o_prop_depth_log2(csr_prop_depth_log2),
    .o_prop_base(csr_prop_base),
    .o_prop_producer(csr_prop_producer),
    .i_prop_idle(prop_idle),
    .i_prop_error(prop_error),
    .i_prop_pending(prop_pending),
    .i_prop_error_code(prop_error_code),
    .i_prop_consumer(proposal_consumer),
    .i_prop_fetch(prop_fetch),
    .i_prop_inflight(prop_inflight),
    .i_prop_reads(prop_reads),
    .i_prop_read_errors(prop_read_errors),

    .o_pay_enable(csr_pay_enable),
    .o_ver_enable(csr_ver_enable),
    .o_payload_base(csr_payload_base),
    .o_verdict_base(csr_verdict_base),
    .i_unit_idle(csr_unit_idle),
    .i_tag_high_water(csr_high_water),
    .i_verdict_seq(verdict_seq),

    .i_tx_ctrl_frames(tx_ctrl_frame_count),
    .i_tx_pay_frames(tx_pay_frame_count),
    .i_tx_empty(tx_empty_count),
    .i_tx_overrun(tx_overrun_count),
    .i_tx_missed(tx_missed_count),
    .i_tx_host_frames(mux_dma_frames),
    .i_tx_cpl_count(ssr_cpl_count),
    .i_tx_cpl_ts(ssr_cpl_ts_96),

    .i_rx_frames(rx_frame_count),
    .i_rx_accept(rx_accept_count),
    .i_rx_ctrl(rx_ctrl_count),
    .i_rx_malformed(rx_malformed_count),
    .i_rx_ctrl_late(rx_ctrl_late_count),
    .i_rx_window_drop(rx_window_drop_count),
    .i_rx_member_drop(rx_member_drop_count),
    .i_rx_sound_drop(rx_sound_drop_count),
    .i_rx_run_drop(rx_run_drop_count),
    .i_rx_round_drop(rx_round_drop_count),
    .i_rx_stall(rx_stall_count),
    .i_rx_host_frames(rxdmx_dma_frames),
    .i_rx_ack_disagree(rx_ack_disagree_count),

    .i_stage_push(stage_push_count),
    .i_stage_full(stage_full_count),
    .i_pay_desc(pay_desc_count),
    .i_pay_cpl(pay_cpl_count),
    .i_pay_err(pay_err_count),
    .i_pay_starve(pay_starve_count),
    .i_pres_late(pres_late_count),
    .i_pres_err(pres_err_count),
    .i_pres_err_miss(pres_err_miss_count),
    .i_verdict_records(verdict_record_count),
    .i_verdict_err(verdict_err_count),
    .i_verdict_overflow(verdict_overflow_count),
    .i_verdict_stale(verdict_stale_count)
);

endmodule
