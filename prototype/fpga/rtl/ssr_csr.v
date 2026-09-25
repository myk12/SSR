`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_csr - every register the host can see, in one place.
 *
 * WHAT IT DOES
 *   Decodes the application's register bus once and holds every writable
 *   register. The modules behind it have no register bus of their own: a
 *   setting reaches them as a plain input port, and whatever the host may read
 *   comes back as a plain output port. So the whole software interface is the
 *   one case statement below, and kernel/ssr_regs.h is a copy of this table.
 *
 * THE MAP (offsets in the application's register space; one 4 KiB page)
 *
 *   0x000  identity and build geometry
 *     0x000 TYPE            RO 0x53535201 ("SSR" + 1), the Corundum rb type
 *     0x004 VERSION         RO 0x00000200 (this map)
 *     0x008 NEXT_PTR        RO 0: no further register blocks
 *     0x00C SCRATCH         RW nothing reads it; a bus sanity check
 *     0x010 NODE            RO [7:0] this node's id, [15:8] node count
 *     0x014 ROUND_NS        RO round length
 *     0x018 GEOMETRY        RO [7:0] node count, [15:8] region shift,
 *                              [23:16] payload ring depth log2, [31:24] verdict ring depth log2
 *     0x01C PAGE_BYTES      RO 4096: a proposal entry, a frame and a host page
 *     0x020 FAULT           RO sticky since reset, one bit per event that a
 *                              correct design never produces (see FAULT BITS)
 *
 *   0x100  consensus (ssr_core)
 *     0x100 CORE_CONTROL    RW bit 0 enable (a level); W bit 1 activate, bit 2 reboot (one-shot)
 *     0x104 CORE_STATUS     RO bit 0 halted, 1 timing armed, 2 PTP time valid,
 *                              3 activation pending, 4 last activation named a
 *                              membership without this node
 *     0x108 CFG_RUN_ID      RW  \
 *     0x10C CFG_MEMBERSHIP  RW   | the next configuration; ignored while an
 *     0x110 CFG_EFF_ROUND_LO RW  | activation is pending, so a 64-bit round
 *     0x114 CFG_EFF_ROUND_HI RW /  written as two halves is never seen torn
 *     0x118 CUR_ROUND_LO    RO the round in progress
 *     0x11C CUR_ROUND_HI    RO
 *     0x120 CUR_RUN_ID      RO
 *     0x124 CUR_SOUND_SET   RO
 *     0x128 CUR_MEMBERSHIP  RO the membership the last activation installed
 *     0x140 HALT_REASON     RO 0 none, 1 no agreed row (no quorum of witnesses),
 *                              2 reserved, 3 no sound set, 4 self excluded,
 *                              5 sound set grew, 6 time fault
 *     0x144 HALT_ROUND_LO   RO the round whose evaluation failed
 *     0x148 HALT_ROUND_HI   RO
 *     0x14C HALT_WITNESS    RO who agreed with us in that evaluation, ourselves included
 *     0x150 HALT_MEMBERSHIP RO
 *     0x154 HALT_SOUND_SET  RO [7:0] the set it produced, [15:8] the set before it
 *
 *   0x200  the proposal ring (ssr_proposal_dma_reader)
 *     0x200 PROP_CONTROL    RW bit 0 enable (a level); W bit 1 flush, bit 2 clear error (one-shot)
 *     0x204 PROP_STATUS     RO bit 0 enabled, 1 idle (no read in flight), 2 error,
 *                              3 a flush / clear is pending
 *     0x208 PROP_ERROR_CODE RO the failed read's status
 *     0x20C PROP_DEPTH_LOG2 RW <= 16 (larger writes are clamped)
 *     0x210 PROP_BASE_LO    RW
 *     0x214 PROP_BASE_HI    RW
 *     0x218 PROP_PRODUCER   RW the doorbell: entries the host has posted
 *     0x21C PROP_CONSUMER   RO entries whole on the NIC
 *     0x220 PROP_FETCH      RO reads issued
 *     0x224 PROP_INFLIGHT   RO
 *
 *   0x300  delivery to the host (payload stage, writers, presence, verdict)
 *     0x300 DLV_CONTROL     RW bit 0 payload DMA, bit 1 verdict DMA
 *     0x304 DLV_STATUS      RO [7:0] fence units idle, [15:8] tag high water
 *     0x308 PAY_BASE_LO     RW
 *     0x30C PAY_BASE_HI     RW
 *     0x310 VER_BASE_LO     RW
 *     0x314 VER_BASE_HI     RW
 *     0x318 SEQ_LO          RO the next verdict record's seq
 *     0x31C SEQ_HI          RO
 *
 *   0x400  counters, all RO, in pipeline order
 *     0x400 ROUND_COUNT_LO   0x404 ROUND_COUNT_HI   0x408 COMMIT_COUNT_LO
 *     0x40C COMMIT_COUNT_HI  0x410 HALT_COUNT       0x414 TIME_FAULT_COUNT
 *     0x440 TX_CTRL_FRAMES   0x444 TX_PAY_FRAMES    0x448 TX_EMPTY
 *     0x44C TX_OVERRUN       0x450 TX_MISSED        0x454 TX_HOST_FRAMES
 *     0x458 TX_CPL_COUNT     0x45C TX_CPL_TS_0      0x460 TX_CPL_TS_1
 *     0x464 TX_CPL_TS_2
 *     0x480 RX_FRAMES        0x484 RX_ACCEPT        0x488 RX_CTRL
 *     0x48C RX_MALFORMED     0x490 RX_CTRL_LATE     0x494 RX_WINDOW_DROP
 *     0x498 RX_MEMBER_DROP   0x49C RX_SOUND_DROP    0x4A0 RX_RUN_DROP
 *     0x4A4 RX_ROUND_DROP    0x4A8 RX_STALL         0x4AC RX_HOST_FRAMES
 *     0x4B0 RX_ACK_DISAGREE  a peer's ack vector differed from ours: it was
 *                            not a witness that round (a protocol event, not a fault)
 *     0x4C0 PROP_READS       0x4C4 PROP_READ_ERRORS
 *     0x500 STAGE_PUSH       0x504 STAGE_FULL       0x508 PAY_DESC
 *     0x50C PAY_CPL          0x510 PAY_ERR          0x514 PAY_STARVE
 *                            0x51C PRES_LATE        0x520 PRES_ERR
 *     0x524 PRES_ERR_MISS    0x528 VERDICT_RECORDS  0x52C VERDICT_ERR
 *     0x530 VERDICT_OVERFLOW 0x534 VERDICT_STALE
 *
 * FAULT BITS
 *   Each bit is "this event has happened at least once since reset". None of
 *   them can happen in a correct design; a set bit is a bug to find, and the
 *   module named keeps the exact count for simulation.
 *     0 RX_FOREIGN          ssr_rx_engine got a frame that is not 0x88B5 (ssr_rx_demux let it through)
 *     1 TX_LEN_MISMATCH     ssr_tx_engine: the buffer's length and its last beat disagreed
 *     2 TX_OVERSIZE         ssr_tx_engine: a slot longer than a fragment
 *     3 STAGE_OVERSIZE      ssr_payload_stage: a tag longer than a page
 *     4 STAGE_OVERLAP       ssr_payload_stage: a start of frame while one was open
 *     5 STAGE_LEN_MISMATCH  ssr_payload_stage: the beats disagreed with the tag
 *     6 PAY_STRAY           ssr_dma_tag_pool: a completion for no live tag
 *     7 (reserved, 0)
 *
 * THE BUS
 *   Corundum's reg_* interface. Every access is answered one cycle after it is
 *   presented; an address this table does not name is not acknowledged (the
 *   bus then times out), so a stray address is loud rather than silently zero.
 *   Nothing here waits, so *_wait are tied low.
 */

module ssr_csr #
(
    parameter integer REG_ADDR_WIDTH       = 24,
    parameter integer REG_DATA_WIDTH       = 32,
    parameter integer REG_STRB_WIDTH       = REG_DATA_WIDTH / 8,

    parameter integer P_NODE_ID            = 0,
    parameter integer P_NODE_COUNT         = 3,
    parameter integer P_ROUND_NS           = 4000,
    parameter integer P_REGION_SHIFT       = 15,
    parameter integer P_HOST_DEPTH_LOG2    = 8,
    parameter integer P_VERDICT_DEPTH_LOG2 = 8,
    parameter integer P_PAGE_BYTES         = 4096
)
(
    input  wire                         clk,
    input  wire                         rst,

    input  wire [REG_ADDR_WIDTH-1:0]    reg_wr_addr,
    input  wire [REG_DATA_WIDTH-1:0]    reg_wr_data,
    input  wire [REG_STRB_WIDTH-1:0]    reg_wr_strb,
    input  wire                         reg_wr_en,
    output wire                         reg_wr_wait,
    output reg                          reg_wr_ack = 1'b0,
    input  wire [REG_ADDR_WIDTH-1:0]    reg_rd_addr,
    input  wire                         reg_rd_en,
    output reg  [REG_DATA_WIDTH-1:0]    reg_rd_data = {REG_DATA_WIDTH{1'b0}},
    output wire                         reg_rd_wait,
    output reg                          reg_rd_ack = 1'b0,

    input  wire [7:0]                   i_fault,

    // ---- ssr_core ------------------------------------------------------
    output reg                          o_core_enable = 1'b0,
    output reg                          o_core_reboot = 1'b0,          // one cycle
    output reg                          o_activate_pending = 1'b0,
    input  wire                         i_activate_taken,              // the core consumed it
    output reg  [31:0]                  o_cfg_run_id = 32'd0,
    output reg  [7:0]                   o_cfg_membership = 8'd0,
    output reg  [63:0]                  o_cfg_effective_round = 64'd0,

    input  wire                         i_halt,
    input  wire                         i_timing_armed,
    input  wire                         i_ptp_time_valid,
    input  wire                         i_config_excludes_self,
    input  wire [63:0]                  i_round_id,
    input  wire [31:0]                  i_cur_run_id,
    input  wire [7:0]                   i_cur_sound_set,
    input  wire [7:0]                   i_cur_membership,
    input  wire [3:0]                   i_halt_reason,
    input  wire [63:0]                  i_halt_round_id,
    input  wire [7:0]                   i_halt_witness,
    input  wire [7:0]                   i_halt_membership,
    input  wire [7:0]                   i_halt_sound_set,
    input  wire [7:0]                   i_halt_prev_sound_set,
    input  wire [63:0]                  i_round_count,
    input  wire [63:0]                  i_commit_count,
    input  wire [31:0]                  i_halt_count,
    input  wire [31:0]                  i_time_fault_count,

    // ---- ssr_proposal_dma_reader ---------------------------------------
    output reg                          o_prop_enable = 1'b0,
    output reg                          o_prop_flush = 1'b0,           // one cycle
    output reg                          o_prop_clear_error = 1'b0,     // one cycle
    output reg  [4:0]                   o_prop_depth_log2 = 5'd0,
    output reg  [63:0]                  o_prop_base = 64'd0,
    output reg  [31:0]                  o_prop_producer = 32'd0,

    input  wire                         i_prop_idle,
    input  wire                         i_prop_error,
    input  wire                         i_prop_pending,
    input  wire [3:0]                   i_prop_error_code,
    input  wire [31:0]                  i_prop_consumer,
    input  wire [31:0]                  i_prop_fetch,
    input  wire [31:0]                  i_prop_inflight,
    input  wire [31:0]                  i_prop_reads,
    input  wire [31:0]                  i_prop_read_errors,

    // ---- delivery ------------------------------------------------------
    output reg                          o_pay_enable = 1'b0,
    output reg                          o_ver_enable = 1'b0,
    output reg  [63:0]                  o_payload_base = 64'd0,
    output reg  [63:0]                  o_verdict_base = 64'd0,

    input  wire [7:0]                   i_unit_idle,
    input  wire [7:0]                   i_tag_high_water,
    input  wire [63:0]                  i_verdict_seq,

    // ---- counters ------------------------------------------------------
    input  wire [31:0]                  i_tx_ctrl_frames,
    input  wire [31:0]                  i_tx_pay_frames,
    input  wire [31:0]                  i_tx_empty,
    input  wire [31:0]                  i_tx_overrun,
    input  wire [31:0]                  i_tx_missed,
    input  wire [31:0]                  i_tx_host_frames,
    input  wire [31:0]                  i_tx_cpl_count,
    input  wire [95:0]                  i_tx_cpl_ts,

    input  wire [31:0]                  i_rx_frames,
    input  wire [31:0]                  i_rx_accept,
    input  wire [31:0]                  i_rx_ctrl,
    input  wire [31:0]                  i_rx_malformed,
    input  wire [31:0]                  i_rx_ctrl_late,
    input  wire [31:0]                  i_rx_window_drop,
    input  wire [31:0]                  i_rx_member_drop,
    input  wire [31:0]                  i_rx_sound_drop,
    input  wire [31:0]                  i_rx_run_drop,
    input  wire [31:0]                  i_rx_round_drop,
    input  wire [31:0]                  i_rx_stall,
    input  wire [31:0]                  i_rx_host_frames,
    input  wire [31:0]                  i_rx_ack_disagree,

    input  wire [31:0]                  i_stage_push,
    input  wire [31:0]                  i_stage_full,
    input  wire [31:0]                  i_pay_desc,
    input  wire [31:0]                  i_pay_cpl,
    input  wire [31:0]                  i_pay_err,
    input  wire [31:0]                  i_pay_starve,
    input  wire [31:0]                  i_pres_late,
    input  wire [31:0]                  i_pres_err,
    input  wire [31:0]                  i_pres_err_miss,
    input  wire [31:0]                  i_verdict_records,
    input  wire [31:0]                  i_verdict_err,
    input  wire [31:0]                  i_verdict_overflow,
    input  wire [31:0]                  i_verdict_stale
);

localparam [31:0] RB_TYPE    = 32'h53535201;
localparam [31:0] RB_VERSION = 32'h00000200;

initial begin
    if (REG_DATA_WIDTH != 32 || REG_STRB_WIDTH != 4 || REG_ADDR_WIDTH < 12) begin
        $error("ssr_csr: the register bus must be 32 bits wide with at least 12 address bits (instance %m)");
        $finish;
    end
end

assign reg_wr_wait = 1'b0;
assign reg_rd_wait = 1'b0;

// The page is the whole map: an address outside it is not ours.
wire                wr_here = (reg_wr_addr >> 12) == 0;
wire                rd_here = (reg_rd_addr >> 12) == 0;
wire [11:0]         wr_off  = {reg_wr_addr[11:2], 2'b00};
wire [11:0]         rd_off  = {reg_rd_addr[11:2], 2'b00};
wire [31:0]         d       = reg_wr_data;

reg  [31:0] scratch_reg = 32'd0;
reg  [7:0]  fault_reg   = 8'd0;

always @(posedge clk) begin
    reg_wr_ack         <= 1'b0;
    reg_rd_ack         <= 1'b0;
    o_core_reboot      <= 1'b0;
    o_prop_flush       <= 1'b0;
    o_prop_clear_error <= 1'b0;

    fault_reg <= fault_reg | i_fault;

    // The core has taken the activation. Before the write decode, so that a
    // CONTROL write on the same cycle - a newer request - wins.
    if (i_activate_taken) o_activate_pending <= 1'b0;

    // ------------------------------------------------------------ write
    if (reg_wr_en && !reg_wr_ack && wr_here) begin
        reg_wr_ack <= 1'b1;
        case (wr_off)
            12'h00C: scratch_reg <= d;

            12'h100: begin
                o_core_enable <= d[0];
                if (d[1]) o_activate_pending <= 1'b1;
                if (d[2]) begin
                    o_core_reboot      <= 1'b1;
                    o_activate_pending <= 1'b0;
                end
            end
            // A configuration may be rewritten until it is armed, never after.
            12'h108: if (!o_activate_pending) o_cfg_run_id                 <= d;
            12'h10C: if (!o_activate_pending) o_cfg_membership             <= d[7:0];
            12'h110: if (!o_activate_pending) o_cfg_effective_round[31:0]  <= d;
            12'h114: if (!o_activate_pending) o_cfg_effective_round[63:32] <= d;

            12'h200: begin
                o_prop_enable      <= d[0];
                o_prop_flush       <= d[1];
                o_prop_clear_error <= d[2];
            end
            12'h20C: o_prop_depth_log2  <= (d > 32'd16) ? 5'd16 : d[4:0];
            12'h210: o_prop_base[31:0]  <= d;
            12'h214: o_prop_base[63:32] <= d;
            12'h218: o_prop_producer    <= d;

            12'h300: begin
                o_pay_enable <= d[0];
                o_ver_enable <= d[1];
            end
            12'h308: o_payload_base[31:0]  <= d;
            12'h30C: o_payload_base[63:32] <= d;
            12'h310: o_verdict_base[31:0]  <= d;
            12'h314: o_verdict_base[63:32] <= d;

            // read-only registers take the write and ignore it
            12'h000, 12'h004, 12'h008, 12'h010, 12'h014, 12'h018, 12'h01C, 12'h020,
            12'h104, 12'h118, 12'h11C, 12'h120, 12'h124, 12'h128,
            12'h204, 12'h208, 12'h21C, 12'h220, 12'h224,
            12'h304, 12'h318, 12'h31C: ;

            default: reg_wr_ack <= 1'b0;
        endcase
    end

    // ------------------------------------------------------------ read
    if (reg_rd_en && !reg_rd_ack && rd_here) begin
        reg_rd_ack <= 1'b1;
        case (rd_off)
            12'h000: reg_rd_data <= RB_TYPE;
            12'h004: reg_rd_data <= RB_VERSION;
            12'h008: reg_rd_data <= 32'd0;
            12'h00C: reg_rd_data <= scratch_reg;
            12'h010: reg_rd_data <= {16'd0, P_NODE_COUNT[7:0], P_NODE_ID[7:0]};
            12'h014: reg_rd_data <= P_ROUND_NS;
            12'h018: reg_rd_data <= {P_VERDICT_DEPTH_LOG2[7:0], P_HOST_DEPTH_LOG2[7:0],
                                     P_REGION_SHIFT[7:0], P_NODE_COUNT[7:0]};
            12'h01C: reg_rd_data <= P_PAGE_BYTES;
            12'h020: reg_rd_data <= {24'd0, fault_reg};

            12'h100: reg_rd_data <= {31'd0, o_core_enable};
            12'h104: reg_rd_data <= {27'd0, i_config_excludes_self, o_activate_pending,
                                     i_ptp_time_valid, i_timing_armed, i_halt};
            12'h108: reg_rd_data <= o_cfg_run_id;
            12'h10C: reg_rd_data <= {24'd0, o_cfg_membership};
            12'h110: reg_rd_data <= o_cfg_effective_round[31:0];
            12'h114: reg_rd_data <= o_cfg_effective_round[63:32];
            12'h118: reg_rd_data <= i_round_id[31:0];
            12'h11C: reg_rd_data <= i_round_id[63:32];
            12'h120: reg_rd_data <= i_cur_run_id;
            12'h124: reg_rd_data <= {24'd0, i_cur_sound_set};
            12'h128: reg_rd_data <= {24'd0, i_cur_membership};
            12'h140: reg_rd_data <= {28'd0, i_halt_reason};
            12'h144: reg_rd_data <= i_halt_round_id[31:0];
            12'h148: reg_rd_data <= i_halt_round_id[63:32];
            12'h14C: reg_rd_data <= {24'd0, i_halt_witness};
            12'h150: reg_rd_data <= {24'd0, i_halt_membership};
            12'h154: reg_rd_data <= {16'd0, i_halt_prev_sound_set, i_halt_sound_set};

            12'h200: reg_rd_data <= {31'd0, o_prop_enable};
            12'h204: reg_rd_data <= {28'd0, i_prop_pending, i_prop_error, i_prop_idle, o_prop_enable};
            12'h208: reg_rd_data <= {28'd0, i_prop_error_code};
            12'h20C: reg_rd_data <= {27'd0, o_prop_depth_log2};
            12'h210: reg_rd_data <= o_prop_base[31:0];
            12'h214: reg_rd_data <= o_prop_base[63:32];
            12'h218: reg_rd_data <= o_prop_producer;
            12'h21C: reg_rd_data <= i_prop_consumer;
            12'h220: reg_rd_data <= i_prop_fetch;
            12'h224: reg_rd_data <= i_prop_inflight;

            12'h300: reg_rd_data <= {30'd0, o_ver_enable, o_pay_enable};
            12'h304: reg_rd_data <= {16'd0, i_tag_high_water, i_unit_idle};
            12'h308: reg_rd_data <= o_payload_base[31:0];
            12'h30C: reg_rd_data <= o_payload_base[63:32];
            12'h310: reg_rd_data <= o_verdict_base[31:0];
            12'h314: reg_rd_data <= o_verdict_base[63:32];
            12'h318: reg_rd_data <= i_verdict_seq[31:0];
            12'h31C: reg_rd_data <= i_verdict_seq[63:32];

            12'h400: reg_rd_data <= i_round_count[31:0];
            12'h404: reg_rd_data <= i_round_count[63:32];
            12'h408: reg_rd_data <= i_commit_count[31:0];
            12'h40C: reg_rd_data <= i_commit_count[63:32];
            12'h410: reg_rd_data <= i_halt_count;
            12'h414: reg_rd_data <= i_time_fault_count;

            12'h440: reg_rd_data <= i_tx_ctrl_frames;
            12'h444: reg_rd_data <= i_tx_pay_frames;
            12'h448: reg_rd_data <= i_tx_empty;
            12'h44C: reg_rd_data <= i_tx_overrun;
            12'h450: reg_rd_data <= i_tx_missed;
            12'h454: reg_rd_data <= i_tx_host_frames;
            12'h458: reg_rd_data <= i_tx_cpl_count;
            12'h45C: reg_rd_data <= i_tx_cpl_ts[31:0];
            12'h460: reg_rd_data <= i_tx_cpl_ts[63:32];
            12'h464: reg_rd_data <= i_tx_cpl_ts[95:64];

            12'h480: reg_rd_data <= i_rx_frames;
            12'h484: reg_rd_data <= i_rx_accept;
            12'h488: reg_rd_data <= i_rx_ctrl;
            12'h48C: reg_rd_data <= i_rx_malformed;
            12'h490: reg_rd_data <= i_rx_ctrl_late;
            12'h494: reg_rd_data <= i_rx_window_drop;
            12'h498: reg_rd_data <= i_rx_member_drop;
            12'h49C: reg_rd_data <= i_rx_sound_drop;
            12'h4A0: reg_rd_data <= i_rx_run_drop;
            12'h4A4: reg_rd_data <= i_rx_round_drop;
            12'h4A8: reg_rd_data <= i_rx_stall;
            12'h4AC: reg_rd_data <= i_rx_host_frames;
            12'h4B0: reg_rd_data <= i_rx_ack_disagree;

            12'h4C0: reg_rd_data <= i_prop_reads;
            12'h4C4: reg_rd_data <= i_prop_read_errors;

            12'h500: reg_rd_data <= i_stage_push;
            12'h504: reg_rd_data <= i_stage_full;
            12'h508: reg_rd_data <= i_pay_desc;
            12'h50C: reg_rd_data <= i_pay_cpl;
            12'h510: reg_rd_data <= i_pay_err;
            12'h514: reg_rd_data <= i_pay_starve;
            12'h51C: reg_rd_data <= i_pres_late;
            12'h520: reg_rd_data <= i_pres_err;
            12'h524: reg_rd_data <= i_pres_err_miss;
            12'h528: reg_rd_data <= i_verdict_records;
            12'h52C: reg_rd_data <= i_verdict_err;
            12'h530: reg_rd_data <= i_verdict_overflow;
            12'h534: reg_rd_data <= i_verdict_stale;

            default: begin
                reg_rd_ack  <= 1'b0;
                reg_rd_data <= 32'd0;
            end
        endcase
    end

    if (rst) begin
        reg_wr_ack            <= 1'b0;
        reg_rd_ack            <= 1'b0;
        scratch_reg           <= 32'd0;
        fault_reg             <= 8'd0;
        o_core_enable         <= 1'b0;
        o_core_reboot         <= 1'b0;
        o_activate_pending    <= 1'b0;
        o_cfg_run_id          <= 32'd0;
        o_cfg_membership      <= 8'd0;
        o_cfg_effective_round <= 64'd0;
        o_prop_enable         <= 1'b0;
        o_prop_flush          <= 1'b0;
        o_prop_clear_error    <= 1'b0;
        o_prop_depth_log2     <= 5'd0;
        o_prop_base           <= 64'd0;
        o_prop_producer       <= 32'd0;
        o_pay_enable          <= 1'b0;
        o_ver_enable          <= 1'b0;
        o_payload_base        <= 64'd0;
        o_verdict_base        <= 64'd0;
    end
end

endmodule

`resetall
