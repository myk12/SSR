`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_core - time, the two-round pipeline, the evaluation and the halt.
 *
 * It never sees a count. ssr_rx_engine tells it, per peer per round, only
 * whether that peer is TRUSTED - its control frame cleared every rung,
 * including "its ack vector equals ours" (docs/count_ack.md). The core counts
 * those against a quorum; the vectors themselves live in ssr_presence_tracker.
 *
 * It has no register bus. The control plane's settings arrive on the i_cfg_*
 * / i_enable / i_reboot / i_activate_pending ports and everything software may
 * read leaves on o_* ports; ssr_csr holds the registers and the map
 * (CFG_* at 0x040, CORE_* at 0x100, HALT_* at 0x140, the round / commit /
 * halt counters at 0x400).
 *
 * NOTHING ABOUT THE CLUSTER OR THE ROUND IS A PARAMETER HERE. Node id, node
 * count, quorum, round length and the three instants of a round (control
 * frame out, control deadline, payload cutoff) arrive on i_cfg_* ports from
 * ssr_csr's 0x040 block, final numbers that ssrd derived from ssr.cfg. The
 * FPGA derives nothing and checks nothing about them; the elaboration
 * checks that used to live here are ssrd's now. They must be still while
 * the core is enabled - ssr_csr refuses writes then - because the timing
 * below reads them every cycle.
 */

module ssr_core (
    input wire                              clk,
    input wire                              rst,
    // ---- the control plane (ssr_csr) -----------------------------------
    // i_enable is a level: low stops the clock work and the protocol. Reboot
    // forgets the halt and the installed run. An activation is requested by
    // holding i_activate_pending; the core takes it at the first round start at
    // or past i_cfg_effective_round and says so on o_activate_taken. ssr_csr
    // keeps the i_cfg_* values still while the request is pending.
    input wire                              i_enable,
    input wire                              i_reboot,
    input wire                              i_activate_pending,
    output wire                             o_activate_taken,
    input wire [31:0]                       i_cfg_run_id,
    input wire [7:0]                        i_cfg_membership,
    input wire [63:0]                       i_cfg_effective_round,

    // ---- the cluster and the round (ssr_csr 0x040) ----------------------
    input wire [7:0]                        i_cfg_node_id,
    input wire [7:0]                        i_cfg_node_count,
    input wire [3:0]                        i_cfg_quorum,
    input wire [31:0]                       i_cfg_round_ns,
    input wire [31:0]                       i_cfg_rounds_per_sec,   // 1e9 / i_cfg_round_ns
    input wire [31:0]                       i_cfg_tx_start_ns,      // control frame out
    input wire [31:0]                       i_cfg_ctrl_deadline_ns, // control frames in by; evaluate
    input wire [31:0]                       i_cfg_pay_cutoff_ns,    // no fragment starts after

    // PTP timestamp interface
    input wire [47:0]                       i_ptp_tod_sec,
    input wire [31:0]                       i_ptp_tod_ns,
    input wire                              i_ptp_time_valid,
    input wire                              i_ptp_step,

    // Timing signals
    output wire [63:0]                      o_round_id,
    output wire                             o_round_start_pulse,
    output wire                             o_round_boundary_pulse,
    output wire                             o_tx_start_pulse,
    // The evaluation instant: a few cycles after the control deadline, once
    // the last control frame admitted under it has landed its trust. Round R is
    // decided here, in round R+1 - not at the boundary into R+2.
    output wire                             o_ctrl_end_pulse,

    // One window and one enable, selected by the frame's own KIND field in
    // ssr_rx_engine. The control frame has a deadline; payload does not.
    output wire                             o_rx_ctrl_window,
    output wire                             o_rx_pay_enable,

    output reg [63:0]                       o_tx_round_id,
    output reg [31:0]                       o_tx_run_id,
    // High from the round boundary to TX_PAY_CUTOFF_NS: ssr_tx_engine may start
    // a fragment only while it is. Gated like every protocol output.
    output wire                             o_tx_pay_open,

    // ---- the receive filter's state, exported for ssr_rx_engine --------------
    // WHY THE FILTER LIVES IN ssr_rx_engine AND NOT HERE
    //   An earlier arrangement had ssr_rx_engine present each header and read back
    //   a verdict on o_rx_accepted. It cost a cycle of receive bandwidth (the
    //   header had to stand for a whole cycle to be answered combinationally),
    //   it put a cross-module combinational round trip in the frame path, and
    //   it lumped every rejection into one counter.
    //
    //   Worse, it was already only half true: "protocol_active" was exported on
    //   the receive windows and ssr_rx_engine gated on them locally, so the rule was split
    //   across the boundary rather than living in one place.
    //
    //   These three outputs plus o_round_id and the receive windows are the complete
    //   state the filter needs. They are the registers themselves, not a copy,
    //   so there is nothing here that can drift out of step with them.
    //
    //   All three change only at a round boundary, and the receive window is
    //   GUARD_TIME_NS clear of both edges, so a frame never arrives while they
    //   are moving. ssr_rx_engine must therefore consume them combinationally - a
    //   pipeline register on this path would open exactly the boundary window
    //   the guard time exists to close.
    output wire [31:0]                      o_rx_run_id,     // the run frames must claim
    output wire [7:0]                       o_rx_sound_set,  // whose control frames are still believed

    // ---- trusted peers, from ssr_rx_engine ---------------------------------
    // One pulse per peer control frame that cleared every rung, the last of
    // which is "its ack vector equals ours". That makes the peer a WITNESS for
    // the round being decided; nothing else about the frame reaches this module.
    input wire                              i_rx_valid,
    input wire [7:0]                        i_rx_node_id,

    // High on the cycle a witness bit was actually set. Purely an observation
    // point - the decision was taken upstream.
    output wire                             o_rx_accepted,

    // The decision. o_commit_set is the SOUND SET it leaves in force - who is
    // still in. What was committed of each node is our own ack vector for that
    // round, which ssr_verdict_dma_writer reads from ssr_presence_tracker.
    output reg                              o_commit_valid,
    output reg [63:0]                       o_commit_round_id,
    output reg [7:0]                        o_commit_set,

    output wire                             o_halt,
    output wire                             o_time_fault,

    // ---- for the registers (ssr_csr) -----------------------------------
    output wire                             o_timing_armed,
    output wire                             o_config_excludes_self,
    output wire [7:0]                       o_cur_membership,
    // The halt record: captured at the decision, cleared only by a reboot.
    output wire [3:0]                       o_halt_reason,
    output wire [63:0]                      o_halt_round_id,
    output wire [7:0]                       o_halt_witness,
    output wire [7:0]                       o_halt_membership,
    output wire [7:0]                       o_halt_sound_set,
    output wire [7:0]                       o_halt_prev_sound_set,
    output wire [63:0]                      o_round_count,
    output wire [63:0]                      o_commit_count,
    output wire [31:0]                      o_halt_count,
    output wire [31:0]                      o_time_fault_count
);

// THE EVALUATION INSTANT
//   Every ack vector about round R is on the wire in round R+1's control
//   period and nothing admitted after the control deadline can add a witness -
//   ssr_rx_engine drops a late control frame outright. So the witnesses for R
//   are complete at the control deadline of R+1, and that is where R is decided:
//
//     latency = Tc + Tp + Tc = 2*Tc + Tp        (docs/round_structure.md 4)
//
//   rather than at the boundary into R+2, which would add the whole payload
//   period for nothing. The pulse is the deadline plus a few cycles: the last
//   header beat is judged against a one-cycle-delayed window, ssr_rx_engine
//   registers its pulse, and this module sets the bit on the next edge, so the
//   last witness lands on the edge after the deadline's falling edge is seen:
//   a settle of 1 misses it, 2 catches it, 8 leaves a margin of six cycles.
//   tb_ssr_dataplane I3 presents a header on that last cycle; build with
//   this at 1 and I3 must fail - that is the control for this number. ssr_csr
//   publishes it in BUILD so ssrd can keep the deadline clear of the boundary.
localparam integer CTRL_END_SETTLE_CYCLES = 8;

// ================================================================
//              SECTION 1:  State published to the registers
// ================================================================
// Forward declarations from SECTION 2 / 3
wire        timing_armed;
wire [63:0] current_round_id;
wire [31:0] time_fault_count;
wire [63:0] round_count;

// SECTION 3 state
reg [31:0]  current_run_id_reg     = 32'd0;
reg [7:0]   current_sound_set_reg  = 8'd0;
reg [7:0]   installed_membership_reg = 8'd0;

// SECTION 3 takes the activation request once round_id reaches the effective
// round; ssr_csr drops the request when it sees this.
wire        protocol_activate_consumed;

// SECTION 4 halt record
reg [3:0]   halt_reason_reg          = 4'd0;
reg [63:0]  halt_round_id_reg        = 64'd0;
reg [7:0]   halt_witness_reg         = 8'd0;
reg [7:0]   halt_membership_reg      = 8'd0;
reg [7:0]   halt_sound_set_reg       = 8'd0;
reg [7:0]   halt_previous_sound_set_reg  = 8'd0;
reg [63:0]  commit_count_reg         = 64'd0;
reg [31:0]  halt_count_reg           = 32'd0;
// Set when an activation was consumed but the named config did not include this
// node. Without it that path is silent and looks identical to "never activated".
reg         config_excludes_self_reg = 1'b0;

assign o_activate_taken       = protocol_activate_consumed;
assign o_timing_armed         = timing_armed;
assign o_config_excludes_self = config_excludes_self_reg;
assign o_cur_membership       = installed_membership_reg;
assign o_halt_reason          = halt_reason_reg;
assign o_halt_round_id        = halt_round_id_reg;
assign o_halt_witness         = halt_witness_reg;
assign o_halt_membership      = halt_membership_reg;
assign o_halt_sound_set       = halt_sound_set_reg;
assign o_halt_prev_sound_set  = halt_previous_sound_set_reg;
assign o_round_count          = round_count;
assign o_commit_count         = commit_count_reg;
assign o_halt_count           = halt_count_reg;

// ================================================================
//          SECTION 2: Timing and Round Generation
// ================================================================
//
//  round_id = sec * ROUNDS_PER_SECOND + ns / ROUND_LENGTH_NS
//
//  round_id is a pure function of absolute PTP time, therefore:
//    - every node agrees by construction, regardless of when it was enabled
//    - it is recomputed from the clock at every boundary, so it cannot drift
//      and PTP frequency adjustment (slew) is absorbed automatically
//    - a node that halts and reboots re-derives it without any resync protocol
//
//  ROUND_LENGTH_NS must divide 1e9 so that the second rollover coincides exactly
//  with a round boundary; otherwise every second ends with a short round and
//  the TDMA sub-slots may not fit inside it.
//
//  A PTP step, a loss of lock, or time moving backwards is treated as a fault:
//  the scheduler disarms and raises o_time_fault so the FSM can halt. Recovery
//  is deliberately NOT automatic - the control plane must re-activate with a
//  fresh run_id, otherwise the node would rejoin reusing round_ids it has
//  already spoken for.
// ================================================================
reg [47:0]      previous_second_reg = 48'd0;
reg             second_valid_reg = 1'b0;
reg             timing_armed_reg = 1'b0;
reg [63:0]      round_id_reg = 64'd0;
reg [31:0]      next_boundary_ns_reg = 32'd0;
reg [31:0]      round_base_ns_reg = 32'd0;
reg             round_start_pulse_reg = 1'b0;
reg [31:0]      time_fault_count_reg = 32'd0;
reg             time_fault_previous_reg = 1'b0;
reg [63:0]      round_count_reg = 64'd0;

wire timing_running = i_enable && i_ptp_time_valid;

// second counter: normal increment vs jump
wire second_changed     = second_valid_reg && (i_ptp_tod_sec != previous_second_reg);
wire second_advanced    = timing_running && second_changed && (i_ptp_tod_sec == previous_second_reg + 48'd1);
wire second_jumped      = timing_running && second_changed && (i_ptp_tod_sec != previous_second_reg + 48'd1);

// round boundary detection
wire round_boundary_hit = timing_running && timing_armed_reg && (i_ptp_tod_ns >= next_boundary_ns_reg);

// Time faults. i_ptp_step is Corundum's own "the timestamp was stepped" flag;
// the backward check is a belt-and-braces fallback.
wire time_moved_backward = timing_running && timing_armed_reg && (i_ptp_tod_ns < round_base_ns_reg) && !second_changed;
wire time_fault  = timing_running && (i_ptp_step || second_jumped || time_moved_backward);

// ---- Second base and position in the second: two small sequential units ----
//
//  round_id = sec * ROUNDS_PER_SECOND + ns / ROUND_LENGTH_NS
//
// Written combinationally, the multiply is a 48 x 18-bit constant product and
// the divide a 32-bit division by a constant that is not a power of two: a
// compressor tree and a restoring divider, both deep, both on the arming
// path, both feeding registers the timing engine sees as ordinary 4 ns paths.
// Neither value is needed more than once per second (the product) or once
// per activation (the quotient), so both are computed bit-serially instead:
// one adder each, 34 cycles per result, running continuously. Each result is
// tagged with the seconds value it was computed from; the consumers check the
// tag, so a result that straddled a rollover is simply not used.
//
// The product: shift-and-add over the bits of i_cfg_rounds_per_sec. Bits
// shifted past 64 fall off, which is exactly the mod-2^64 arithmetic the old
// expression had. The multiplicand was a constant once; a register costs the
// same here, the loop already loads it into mul_b_reg and shifts.
localparam integer SEQ_STEPS = 32;

reg [5:0]  mul_step_reg = 6'd0;
reg [63:0] mul_a_reg = 64'd0;           // sec, shifted left one bit per step
reg [31:0] mul_b_reg = 32'd0;           // rounds per second, shifted right
reg [63:0] mul_acc_reg = 64'd0;
reg [47:0] mul_sec_reg = 48'd0;         // the sec this product is for
reg [63:0] second_base_reg = 64'd0;     // the last complete product
reg [47:0] second_base_sec_reg = 48'd0; // and the sec it belongs to
reg        second_base_valid_reg = 1'b0;
reg [63:0] next_second_base_reg = 64'd0;

always @(posedge clk) begin
    if (mul_step_reg == 6'd0) begin
        mul_a_reg    <= {16'd0, i_ptp_tod_sec};
        mul_b_reg    <= i_cfg_rounds_per_sec;
        mul_acc_reg  <= 64'd0;
        mul_sec_reg  <= i_ptp_tod_sec;
        mul_step_reg <= 6'd1;
    end else if (mul_step_reg <= SEQ_STEPS) begin
        if (mul_b_reg[0]) mul_acc_reg <= mul_acc_reg + mul_a_reg;
        mul_a_reg    <= mul_a_reg << 1;
        mul_b_reg    <= mul_b_reg >> 1;
        mul_step_reg <= mul_step_reg + 6'd1;
    end else begin
        second_base_reg       <= mul_acc_reg;
        second_base_sec_reg   <= mul_sec_reg;
        second_base_valid_reg <= 1'b1;
        mul_step_reg          <= 6'd0;
    end
    next_second_base_reg <= second_base_reg + {32'd0, i_cfg_rounds_per_sec};
    if (rst) begin
        mul_step_reg          <= 6'd0;
        second_base_valid_reg <= 1'b0;
    end
end

// The quotient: a restoring divider, one bit per step. It also yields the
// remainder, so the round's base (ns - remainder) needs no multiply back.
reg [5:0]  div_step_reg = 6'd0;
reg [31:0] div_ns_reg = 32'd0;          // the ns sampled for this division
reg [47:0] div_sec_reg = 48'd0;         // and the sec at that moment
reg [31:0] div_n_reg = 32'd0;           // numerator bits, brought down MSB first
reg [31:0] div_q_reg = 32'd0;
reg [32:0] div_r_reg = 33'd0;
reg [31:0] pos_q_reg = 32'd0;           // results: ns / round length
reg [31:0] pos_base_reg = 32'd0;        // the round's first ns
reg [47:0] pos_sec_reg = 48'd0;
reg        pos_valid_reg = 1'b0;

wire [32:0] div_r_next = {div_r_reg[31:0], div_n_reg[31]};

always @(posedge clk) begin
    if (div_step_reg == 6'd0) begin
        div_ns_reg   <= i_ptp_tod_ns;
        div_sec_reg  <= i_ptp_tod_sec;
        div_n_reg    <= i_ptp_tod_ns;
        div_q_reg    <= 32'd0;
        div_r_reg    <= 33'd0;
        div_step_reg <= 6'd1;
    end else if (div_step_reg <= SEQ_STEPS) begin
        if (div_r_next >= {1'b0, i_cfg_round_ns}) begin
            div_r_reg <= div_r_next - {1'b0, i_cfg_round_ns};
            div_q_reg <= {div_q_reg[30:0], 1'b1};
        end else begin
            div_r_reg <= div_r_next;
            div_q_reg <= {div_q_reg[30:0], 1'b0};
        end
        div_n_reg    <= div_n_reg << 1;
        div_step_reg <= div_step_reg + 6'd1;
    end else begin
        pos_q_reg     <= div_q_reg;
        pos_base_reg  <= div_ns_reg - div_r_reg[31:0];
        pos_sec_reg   <= div_sec_reg;
        pos_valid_reg <= 1'b1;
        div_step_reg  <= 6'd0;
    end
    if (rst) begin
        div_step_reg  <= 6'd0;
        pos_valid_reg <= 1'b0;
    end
end

// A position is usable for arming when both results belong to the second we
// are in now and the round it names has not ended yet (the division is up to
// 34 cycles old; if a boundary passed meanwhile, the next result is used).
wire position_ready = second_base_valid_reg && pos_valid_reg
                   && (second_base_sec_reg == i_ptp_tod_sec)
                   && (pos_sec_reg == i_ptp_tod_sec)
                   && (i_ptp_tod_ns >= pos_base_reg)
                   && (i_ptp_tod_ns < pos_base_reg + i_cfg_round_ns);

always @(posedge clk) begin
    previous_second_reg     <= i_ptp_tod_sec;
    second_valid_reg        <= 1'b1;
    round_start_pulse_reg   <= 1'b0;
    time_fault_previous_reg <= time_fault;

    if (rst) begin
        previous_second_reg     <= 48'd0;
        second_valid_reg    <= 1'b0;
        timing_armed_reg    <= 1'b0;
        round_id_reg        <= 64'd0;
        next_boundary_ns_reg    <= 32'd0;
        round_base_ns_reg       <= 32'd0;
        time_fault_count_reg    <= 32'd0;
        round_count_reg         <= 64'd0;
        time_fault_previous_reg <= 1'b0;
    end
    else if (!timing_running) begin
        timing_armed_reg    <= 1'b0;
        round_id_reg        <= 64'd0;
        next_boundary_ns_reg   <= 32'd0;
        round_base_ns_reg      <= 32'd0;
    end
    else if (time_fault) begin
        // Give up the current alignment. Count only the rising edge so a
        // sustained fault (e.g. loss of lock) does not inflate the counter.
        timing_armed_reg <= 1'b0;
        if (!time_fault_previous_reg) time_fault_count_reg <= time_fault_count_reg + 32'd1;
    end
    else if (!timing_armed_reg && !second_changed && position_ready) begin
        // Align to absolute time. The round we land in is a partial one, so no
        // round_start is emitted for it; the first pulse comes from the next
        // natural boundary. position_ready guarantees the product and the
        // quotient were both computed from the second we are in and that the
        // round they name is still in progress - arming takes up to ~70 cycles
        // after enable, never a wrong value.
        timing_armed_reg     <= 1'b1;
        round_id_reg         <= second_base_reg + {32'd0, pos_q_reg};
        round_base_ns_reg    <= pos_base_reg;
        next_boundary_ns_reg <= pos_base_reg + i_cfg_round_ns;
    end
    else if (second_advanced) begin
        // Second rollover. Because the round length divides 1e9 (ssrd checks) this
        // is also a round boundary, so realigning here costs nothing and cancels any drift. The
        // realignment uses the product of the second just ended, which has been
        // stable for a whole second; if the multiplier happens to be mid-way
        // through a fresh one, round_id + 1 is the same number.
        round_id_reg        <= (second_base_sec_reg == previous_second_reg)
                             ? next_second_base_reg : round_id_reg + 64'd1;
        round_base_ns_reg   <= 32'd0;
        next_boundary_ns_reg    <= i_cfg_round_ns;
        round_start_pulse_reg   <= 1'b1;
        round_count_reg     <= round_count_reg + 64'd1;
    end
    else if (round_boundary_hit) begin
        round_id_reg            <= round_id_reg + 64'd1;
        round_base_ns_reg       <= next_boundary_ns_reg;
        next_boundary_ns_reg    <= next_boundary_ns_reg + i_cfg_round_ns;
        round_start_pulse_reg   <= 1'b1;
        round_count_reg         <= round_count_reg + 64'd1;
    end
end

// ---------------- windows: offset -> level -> edge pulse ----------------
wire [31:0] round_offset_ns = i_ptp_tod_ns - round_base_ns_reg;

// One level per round, rising once at the dead zone's end. Its rising edge is
// o_tx_start_pulse and that is the only thing it is for - there is no transmit
// window to gate anything with.
wire tx_active          = timing_armed_reg && (round_offset_ns >= i_cfg_tx_start_ns);
// The control deadline. No lower bound: it used to open at the guard time,
// which rejected a valid frame from a peer whose clock runs slightly ahead.
// The round_id in the header says which round a frame belongs to; the
// deadline only says whether it is still in time.
wire rx_ctrl_window_active = timing_armed_reg && (round_offset_ns < i_cfg_ctrl_deadline_ns);
// The transmit cutoff: fragments of this round may start until here. A level,
// not a pulse - ssr_tx_engine checks it before every fragment.
wire tx_pay_open_active    = timing_armed_reg && (round_offset_ns < i_cfg_pay_cutoff_ns);

reg tx_active_previous_reg = 1'b0;
reg rx_ctrl_window_previous_reg = 1'b0;
reg tx_start_pulse_reg = 1'b0;
// The deadline's falling edge, then a short shift register to let the last
// admitted witness land before the mask is read.
// One bit wider than the settle so the shift is well formed at a settle of 1.
reg  [CTRL_END_SETTLE_CYCLES:0] ctrl_end_shift_reg = {(CTRL_END_SETTLE_CYCLES+1){1'b0}};
wire ctrl_end_edge      = rx_ctrl_window_previous_reg && !rx_ctrl_window_active;
wire ctrl_end_pulse_reg = ctrl_end_shift_reg[CTRL_END_SETTLE_CYCLES-1];

always @(posedge clk) begin
    if (rst || !timing_running) begin
        tx_active_previous_reg      <= 1'b0;
        rx_ctrl_window_previous_reg <= 1'b0;
        tx_start_pulse_reg          <= 1'b0;
        ctrl_end_shift_reg          <= {(CTRL_END_SETTLE_CYCLES+1){1'b0}};
    end else begin
        tx_active_previous_reg      <= tx_active;
        rx_ctrl_window_previous_reg <= rx_ctrl_window_active;
        ctrl_end_shift_reg <= {ctrl_end_shift_reg[CTRL_END_SETTLE_CYCLES-1:0], ctrl_end_edge};

        // One edge, once per round. There is no closing edge to detect because
        // there is no transmit window to close - ssr_tx_engine ends its round by
        // running out of fragments, and the next start pulse is what abandons
        // anything it still owed.
        tx_start_pulse_reg <= tx_active && !tx_active_previous_reg;
    end
end

// Driven by the SECTION 3 FSM. Gates every protocol-visible output, so a halted
// or not-yet-activated node stays silent on the wire.
wire protocol_active;

assign timing_armed   = timing_armed_reg;
assign current_round_id    = round_id_reg;
assign time_fault_count = time_fault_count_reg;
assign round_count = round_count_reg;

assign o_round_id             = round_id_reg;
assign o_round_start_pulse    = round_start_pulse_reg;                      // pure timing
assign o_round_boundary_pulse = round_start_pulse_reg && protocol_active;   // protocol boundary
// The whole transmit interface: one pulse per round. A halted or not-yet-
// activated node emits none, so it stays silent on the wire.
assign o_tx_start_pulse     = tx_start_pulse_reg && protocol_active;
// The control deadline, gated the same way.
assign o_rx_ctrl_window     = rx_ctrl_window_previous_reg && protocol_active;
// The evaluation instant, for whoever wants to measure from it.
assign o_ctrl_end_pulse     = ctrl_end_pulse_reg && protocol_active;
// Payload has no deadline. This is not a window - it is "the protocol is
// running", and ssr_rx_engine admits a payload frame on that plus the round_id in
// its header. Naming it a window would invite someone to put a time bound back
// into it, which is exactly what the rate cap made unnecessary.
assign o_rx_pay_enable      = protocol_active;
assign o_tx_pay_open        = tx_pay_open_active && protocol_active;
assign o_time_fault         = time_fault;
assign o_time_fault_count   = time_fault_count_reg;

// ================================================================
//              SECTION 3:  Consensus Logic
// ================================================================
//
//  Two-round pipeline, mirroring Node.advance_round in sim/protocol/node.py.
//  A stage is one round's worth of evidence and lives through exactly two
//  communication rounds:
//
//    round N     as CURRENT   fragments are counted (ssr_presence_tracker);
//                             at its end the counts are our ack vector for N
//    round N+1   as PREVIOUS  collects WITNESSES for round N: peers whose round
//                             N+1 control frame carried a vector equal to ours
//    deadline of N+1          judged: commits or halts
//
//  Two rounds is the floor, not a tuning constant: a node cannot know whom it
//  heard in round N until N is over, and its peers cannot learn that until N+1.
//  The judgement itself is one cycle of combinational logic and lands inside the
//  guard band, ~GUARD_TIME_NS before anyone transmits, so it costs no round.
//  After activation this shows up as two boundaries that shift and skip before
//  the first real evaluation.
//
//  What travels in a round N+1 control frame is the RAW OBSERVATION of round N -
//  how many fragments of each node the sender actually holds - not anything the
//  evaluation derived. That is the whole safety argument: two nodes whose
//  vectors are equal hold identical fragments, so quorum intersection pins what
//  is committed (docs/count_ack.md section 3). Broadcasting a derived value
//  instead would make every node emit the same thing even when their receptions
//  differed, which hides asymmetric loss from everyone except its victim.
//
//  At every round boundary the pipeline shifts one place, and at every control
//  deadline exactly one evaluation runs. That single evaluation feeds the halt
//  decision, the sound-set update and the commit output.
//
//  Bitmaps are 8 bits wide throughout to match the ports; only the low
//  P_NODE_COUNT bits are ever populated.
// ================================================================

// Naming rule in this module: the "current_" prefix is reserved for state that
// changes every round - current_stage, current_sound_set. Anything that only
// moves when the control plane reconfigures carries "installed_" or "config_".
// Getting that wrong reads as a safety bug even when the logic is right, which
// is exactly what happened to installed_membership_reg when it was called
// current_membership_reg.
wire [7:0] MEMBER_MASK = (8'd1 << i_cfg_node_count[3:0]) - 8'd1;
wire [2:0] SELF        = i_cfg_node_id[2:0];

localparam [3:0] HALT_NONE              = 4'd0;
localparam [3:0] HALT_NO_AGREED_ROW     = 4'd1;
localparam [3:0] HALT_COMMIT_SET_INVALID= 4'd2;
localparam [3:0] HALT_NO_SOUND_SET      = 4'd3;
localparam [3:0] HALT_SELF_EXCLUDED     = 4'd4;
localparam [3:0] HALT_SOUND_SET_GREW    = 4'd5;
localparam [3:0] HALT_TIME_FAULT        = 4'd6;

localparam [1:0] S_IDLE          = 2'd0;   // disabled, or waiting for the timing to arm
localparam [1:0] S_WAIT_ACTIVATE = 2'd1;   // armed, waiting for round_id >= effective round
localparam [1:0] S_RUN           = 2'd2;   // participating
localparam [1:0] S_HALT          = 2'd3;   // ambiguity detected; silent until rebooted

reg [1:0] state_reg = S_IDLE;

// ------------------ pipeline registers ------------------

reg [63:0] current_stage_round_id_reg  = 64'd0;
reg [63:0] previous_stage_round_id_reg = 64'd0;

reg        current_stage_valid_reg  = 1'b0;
reg        previous_stage_valid_reg = 1'b0;

// Who has been a witness for the PREVIOUS stage so far: ourselves, set at the
// boundary, and every peer ssr_rx_engine has trusted since.
reg [7:0]  previous_stage_witness_reg = 8'd0;

// ------------------ the evaluation ------------------
// Combinational, evaluated continuously; sampled once per round, at the
// control deadline (ctrl_end_pulse_reg), which is when the PREVIOUS stage's
// witnesses are complete. Nothing else reads it for the rest of the round, so
// there is no reason to pipeline this.
//
// current_sound_set_reg decides WHOSE TRUST COUNTS here: a witness outside it
// is masked off, so the witness set is contained in the current sound set by
// construction rather than by an argument about what the receive path does. It
// must never decide how many witnesses are needed - that is QUORUM, and
// conflating the two is the bug this module already shipped once.
wire [7:0] eval_witness_mask  = previous_stage_witness_reg & current_sound_set_reg & MEMBER_MASK;

function [3:0] popcount8(input [7:0] v);
    integer k;
begin
    popcount8 = 4'd0;
    for (k = 0; k < 8; k = k + 1) popcount8 = popcount8 + {3'd0, v[k]};
end
endfunction
wire [3:0] eval_witness_count = popcount8(eval_witness_mask);

// Our own vector is agreed once a quorum of members - ourselves included -
// broadcast one identical to it. We must still believe ourselves: a node the
// last evaluation dropped from its own sound set has nothing to agree on.
// The quorum is the control plane's number (N/2+1 of the physical cluster,
// ssrd); this module only compares against it.
wire       eval_agreed_row_valid = current_sound_set_reg[SELF]
                                && (eval_witness_count >= i_cfg_quorum);

// The witnesses ARE the sound set: both are "members whose vector equals
// ours", so popcount(sound_set) == witness_count >= quorum by construction.
wire [7:0] eval_sound_set = eval_witness_mask;

// The sound set may shrink but never grow: that monotonicity is what keeps two
// partitions from both believing they hold the agreement.
//
// Mind which of the two is newer. current_sound_set_reg is not written until the
// end of this boundary, so right here it still holds the value derived at the
// PREVIOUS boundary, while eval_sound_set is the newer of the two. The test
// therefore reads "new must be contained in old", despite the word "current"
// sitting on the right-hand side.
wire eval_sound_set_shrinks =
        ((eval_sound_set & current_sound_set_reg) == eval_sound_set);

reg [3:0] eval_halt_reason;
always @* begin
    if      (!eval_agreed_row_valid)                eval_halt_reason = HALT_NO_AGREED_ROW;
    // HALT_COMMIT_SET_INVALID (2) is retired: what is committed is our own
    // vector, which we hold by definition. The code stays reserved.
    //
    // The last three are defensive: none can fire once agreed_row_valid holds.
    //   NO_SOUND_SET   - a quorum of witnesses is not empty.
    //   SELF_EXCLUDED  - we are in our own sound set and witness ourselves.
    //   SOUND_SET_GREW - the witness mask is ANDed with current_sound_set_reg.
    // Kept because an unreachable check costing a handful of gates is worth
    // having when the thing it guards is the safety argument.
    else if (eval_sound_set == 8'd0)                eval_halt_reason = HALT_NO_SOUND_SET;
    else if (!eval_sound_set[SELF])                 eval_halt_reason = HALT_SELF_EXCLUDED;
    else if (!eval_sound_set_shrinks)               eval_halt_reason = HALT_SOUND_SET_GREW;
    else                                            eval_halt_reason = HALT_NONE;
end

wire eval_runs   = previous_stage_valid_reg;
wire eval_halts  = eval_runs && (eval_halt_reason != HALT_NONE);
wire eval_commits = eval_runs && (eval_halt_reason == HALT_NONE);

// ------------------------------------------------------------- activation
// Cold start and reconfiguration are the same event: wait until absolute time
// reaches the round the control plane named, then install and go.
// S_RUN is here too: a running node must be able to take a new membership at
// the round the control plane picked, without being stopped first. Requiring a
// stop would mean the cluster has to halt in order to reconfigure.
//
// S_HALT is deliberately absent. A halted node has to be rebooted before it can
// rejoin; letting an activation lift it straight out of S_HALT would be the
// automatic recovery this design rules out everywhere else.
wire activation_due = ((state_reg == S_WAIT_ACTIVATE) || (state_reg == S_RUN))
                   && i_activate_pending
                   && (round_id_reg >= i_cfg_effective_round);

// A config that does not name this node is not something to activate into; the
// node would have to halt on its first evaluation anyway.
wire activation_includes_self = i_cfg_membership[SELF];

// No cross-config overlap rule is needed: with a fixed quorum universe, a group
// that splits off under a new config and the group that stays under the old one
// draw their quorums from the same set, so at most one of them can ever reach
// quorum. A config too small to hold a quorum simply halts its own members.
wire activation_fires = activation_due && activation_includes_self;

assign protocol_activate_consumed = round_start_pulse_reg && activation_due;

// -------------------------------------------------------------- timing loss
// A step, a backward jump or a lost lock all mean the same thing: this node can
// no longer say which round it is in. Recovery is never automatic - the control
// plane must reactivate with a fresh run_id, otherwise the node rejoins reusing
// round_ids it has already spoken for.
wire timing_lost = time_fault || !i_ptp_time_valid;

// Software deliberately stopping us is a clean shutdown to S_IDLE. Note this is
// NOT !timing_running: that also covers !i_ptp_time_valid, which is a fault and
// must reach S_HALT instead. Folding the two together would turn every PTP
// unlock into a silent, auto-recovering restart.
wire protocol_stop = i_reboot || !i_enable;

// ---------------------------------------------------------------- receive
// Node.receive's rule - sender inside the current sound set, matching run,
// matching round, protocol running, and now an ack vector equal to ours - is
// applied by ssr_rx_engine. It is NOT repeated here: two copies of a dynamic
// rule that must agree is precisely the failure this arrangement avoids.
//
// What survives here is a bounds check on this module's own storage: the
// witness mask is indexed by the node id, and a pulse naming ourselves would
// count us twice. It is a comparison against two registers, so it costs
// nothing and cannot drift.
wire        rx_node_in_range = (i_rx_node_id < i_cfg_node_count) && (i_rx_node_id != i_cfg_node_id);
wire [2:0]  rx_index         = i_rx_node_id[2:0];
wire        rx_accept        = i_rx_valid && rx_node_in_range;

// --------------------------------------------------------------- sequential

always @(posedge clk) begin
    o_commit_valid <= 1'b0;

    // ---- a trusted peer -------------------------------------------------
    // A round-N control frame carries the sender's vector about round N-1, so
    // its trust lands in PREVIOUS, and PREVIOUS is evaluated at this round's
    // control deadline, once no more of them can arrive. Getting this split
    // wrong shifts the whole protocol by a round.
    if (rx_accept) begin
        previous_stage_witness_reg[rx_index] <= 1'b1;
    end

    // ---- round boundary -------------------------------------------------
    // Written after the receive block on purpose: a packet landing exactly on
    // the boundary cycle is ambiguous about which round it belongs to, so the
    // shift overwrites it and the packet is dropped. RX is gated to the receive
    // window anyway, which is GUARD_TIME_NS clear of both edges.
    if (round_start_pulse_reg) begin
        // Activation is checked ahead of the state machine so there is exactly
        // one install site, reachable from both S_WAIT_ACTIVATE (cold start) and
        // S_RUN (live reconfiguration). It takes priority over the boundary
        // evaluation below: evidence gathered under the outgoing config must not
        // be judged under the incoming one.
        if (activation_fires) begin
            current_run_id_reg      <= i_cfg_run_id;
            installed_membership_reg <= i_cfg_membership[7:0] & MEMBER_MASK;
            current_sound_set_reg  <= i_cfg_membership[7:0] & MEMBER_MASK;

            // Reset the pipeline: nothing from before this config may be
            // evaluated under it. Costs the usual two priming rounds.
            previous_stage_valid_reg <= 1'b0;
            current_stage_valid_reg  <= 1'b1;
            current_stage_round_id_reg   <= round_id_reg;
            previous_stage_witness_reg <= 8'd0;

            o_tx_round_id  <= round_id_reg;
            o_tx_run_id    <= i_cfg_run_id;

            config_excludes_self_reg <= 1'b0;
            state_reg <= S_RUN;
        end
        else if (activation_due) begin
            // Named config excludes this node: swallow the request and go quiet
            // rather than activating into a certain halt. Flagged in STATUS so
            // this is distinguishable from "never activated".
            config_excludes_self_reg <= 1'b1;
            state_reg <= S_IDLE;
        end
        else begin
        case (state_reg)
            S_IDLE: begin
                if (i_activate_pending) state_reg <= S_WAIT_ACTIVATE;
            end

            S_WAIT_ACTIVATE: ;   // waiting for round_id to reach the effective round

            S_RUN: begin
                // The boundary only SHIFTS. The stage retiring here was
                // evaluated at this round's control deadline (below); if it
                // was not - it was never valid, or the settle pulse was lost to
                // a re-arm - it is simply overwritten. Nothing is decided at a
                // boundary any more.
                previous_stage_valid_reg      <= current_stage_valid_reg;
                previous_stage_round_id_reg   <= current_stage_round_id_reg;
                // The stage becoming PREVIOUS starts with one witness: us.
                // Our vector about it is ssr_presence_tracker's, and goes out
                // in our control frame this round without passing through here.
                previous_stage_witness_reg    <= (8'd1 << SELF);

                o_tx_round_id  <= round_id_reg;
                o_tx_run_id    <= current_run_id_reg;

                // Open a fresh CURRENT for the round we are entering.
                // Nothing to seed: its counts are ssr_presence_tracker's.
                current_stage_valid_reg      <= 1'b1;
                current_stage_round_id_reg   <= round_id_reg;
            end

            S_HALT: ;   // stay put; only a reboot leaves this state
        endcase
        end
    end

    // ---- the evaluation: the control deadline of the round after -------
    // Written after the boundary block so that, should the two ever land on
    // one cycle (the elaboration check above says they cannot), the decision
    // is what stands. The eval_* wires read PREVIOUS - the round before this
    // one - whose witnesses are complete now: every vector about it came in
    // this round's control period, and the deadline has passed. Once evaluated
    // the stage is spent; the boundary will overwrite it.
    if (ctrl_end_pulse_reg && (state_reg == S_RUN) && eval_runs) begin
        previous_stage_valid_reg <= 1'b0;

        if (eval_halts) begin
            state_reg      <= S_HALT;
            halt_count_reg <= halt_count_reg + 32'd1;

            // Freeze who agreed with us. By the time software reads it the
            // pipeline has shifted several times over.
            halt_reason_reg         <= eval_halt_reason;
            halt_round_id_reg       <= previous_stage_round_id_reg;
            halt_witness_reg        <= previous_stage_witness_reg;
            halt_membership_reg     <= installed_membership_reg;
            halt_sound_set_reg      <= eval_sound_set;
            halt_previous_sound_set_reg <= current_sound_set_reg;
        end else if (eval_commits) begin
            // The sound set derived here is in force from this cycle: a
            // peer that just left it has the rest of its fragments for the
            // round in progress refused by ssr_rx_engine (RX_SOUND_DROP), which
            // is right - it is out.
            current_sound_set_reg <= eval_sound_set;
            commit_count_reg      <= commit_count_reg + 64'd1;

            o_commit_valid    <= 1'b1;
            o_commit_round_id <= previous_stage_round_id_reg;
            o_commit_set      <= eval_sound_set;
        end
    end

    // ---- asynchronous transitions --------------------------------------
    // Checked outside the boundary case so they take effect immediately rather
    // than waiting up to a full round.
    if (timing_lost && (state_reg == S_RUN)) begin
        state_reg               <= S_HALT;
        halt_count_reg          <= halt_count_reg + 32'd1;
        halt_reason_reg         <= HALT_TIME_FAULT;
        halt_round_id_reg       <= round_id_reg;
        halt_witness_reg        <= 8'd0;
        halt_membership_reg     <= installed_membership_reg;
        halt_sound_set_reg      <= current_sound_set_reg;
        halt_previous_sound_set_reg <= current_sound_set_reg;
    end

    // Reboot is the control plane's way of saying "forget everything"; ssr_csr
    // drops the activation request with it.
    if (protocol_stop) begin
        state_reg              <= S_IDLE;
        current_stage_valid_reg  <= 1'b0;
        previous_stage_valid_reg <= 1'b0;
        o_commit_valid         <= 1'b0;
    end

    if (i_reboot) begin
        halt_reason_reg        <= HALT_NONE;
        config_excludes_self_reg <= 1'b0;
        current_run_id_reg     <= 32'd0;
        current_sound_set_reg  <= 8'd0;
        installed_membership_reg <= 8'd0;
    end

    if (rst) begin
        state_reg              <= S_IDLE;
        o_tx_round_id          <= 64'd0;
        o_tx_run_id            <= 32'd0;
        o_commit_valid         <= 1'b0;
        o_commit_round_id      <= 64'd0;
        o_commit_set           <= 8'd0;
        current_run_id_reg     <= 32'd0;
        current_sound_set_reg  <= 8'd0;
        installed_membership_reg <= 8'd0;

        current_stage_valid_reg  <= 1'b0;
        previous_stage_valid_reg <= 1'b0;
        previous_stage_witness_reg <= 8'd0;

        halt_reason_reg         <= HALT_NONE;
        halt_round_id_reg       <= 64'd0;
        halt_witness_reg        <= 8'd0;
        halt_membership_reg     <= 8'd0;
        halt_sound_set_reg      <= 8'd0;
        halt_previous_sound_set_reg <= 8'd0;
        commit_count_reg        <= 64'd0;
        halt_count_reg          <= 32'd0;
        config_excludes_self_reg <= 1'b0;
    end
end

assign o_rx_accepted   = rx_accept;
assign o_rx_run_id     = current_run_id_reg;
assign o_rx_sound_set  = current_sound_set_reg;
assign protocol_active = (state_reg == S_RUN);
assign o_halt          = (state_reg == S_HALT);

// ================================================================
//  SECTION 4:           Halt Logic
// ================================================================
// The halt record is captured at the moment of the decision, above - by the
// time software gets round to reading it, the pipeline that produced it has
// already shifted away. It is published read-only (ssr_csr, HALT_* at 0x140)
// and cleared only by a reboot.
//
// The record carries the witness mask (HALT_WITNESS): which peers agreed with
// us in the round that failed, ourselves included. It does not say what the
// others disagreed about - their vectors never reach this module. The halting
// node's own vector for that round is still in ssr_presence_tracker for a few
// rounds; add a latch of the disagreeing vectors in ssr_rx_engine only if the
// repair path turns out to need them.

endmodule

`resetall
