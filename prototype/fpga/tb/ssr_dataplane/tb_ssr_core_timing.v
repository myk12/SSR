`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_core_timing - exercises SECTION 1 (CSR) and SECTION 2 (timing) of ssr_core.v
 *
 * Three instances with different P_NODE_ID share the same PTP time source and
 * the same CSR write bus (writes are broadcast; only node 0's read port is
 * used). This is what makes the cross-node checks meaningful: the whole point
 * of deriving round_id from absolute time is that all three must agree without
 * ever talking to each other.
 *
 * The nodes are deliberately never activated, so the SECTION 3 FSM stays in
 * S_IDLE and every protocol-gated output is held low. The window and pulse
 * checks therefore tap the ungated SECTION 2 registers by hierarchical
 * reference. That keeps this bench answering exactly one question - is the
 * timing right - so a SECTION 3 regression cannot make it fail, and vice versa.
 * Protocol behaviour lives in tb_ssr_core_protocol.
 */
module tb_ssr_core_timing;

localparam integer CLK_PERIOD_NS       = 4;      // 250 MHz
localparam integer NODE_COUNT          = 3;
localparam integer ROUND_LENGTH_NS     = 4000;
localparam integer GUARD_TIME_NS       = 50;
localparam integer CTRL_PERIOD_NS      = 646;
localparam integer PROP_DEAD_NS        = 250;
localparam integer PRESENT_SETTLE_NS   = 32;
// Derived the same way ssr_core.v derives them, so the bench checks the intent and
// not a number copied from the DUT.
localparam integer TX_OPEN_NS  = PROP_DEAD_NS + GUARD_TIME_NS + PRESENT_SETTLE_NS;
// round_offset_ns is registered and so is every window level, so an edge lands
// up to two cycles after the instant it belongs to. Named, not absorbed into a
// tolerance, so a test that needs exactness says so.
localparam integer LEVEL_LATENCY_NS = 3 * CLK_PERIOD_NS;
localparam integer ROUNDS_PER_SECOND   = 1_000_000_000 / ROUND_LENGTH_NS;
localparam integer ARM_CYCLES          = 100;    // bit-serial arming: 2 x 34 cycles plus one retry

// The core has no register bus of its own; each node's registers are an
// ssr_csr in front of it, as in ssr_dataplane. Offsets are ssr_csr's map.
localparam [23:0] REG_MAGIC                      = 24'h000;   // TYPE
localparam [23:0] REG_VERSION                    = 24'h004;
localparam [23:0] REG_CONTROL                    = 24'h100;
localparam [23:0] REG_STATUS                     = 24'h104;
localparam [23:0] REG_ROUND_LENGTH_NS            = 24'h014;
localparam [23:0] REG_CONFIG_RUN_ID              = 24'h108;
localparam [23:0] REG_CONFIG_MEMBERSHIP          = 24'h10C;
localparam [23:0] REG_CONFIG_EFFECTIVE_ROUND_LOW = 24'h110;
localparam [23:0] REG_CURRENT_ROUND_ID_LOW       = 24'h118;
localparam [23:0] REG_TIME_FAULT_COUNT           = 24'h414;
localparam [23:0] REG_UNMAPPED                   = 24'h0F0;
localparam [23:0] REG_NODE                       = 24'h010;

// -------------------------------------------------------------------------
// clock / reset
// -------------------------------------------------------------------------
reg clk = 1'b0;
reg rst = 1'b1;
always #(CLK_PERIOD_NS/2.0) clk = ~clk;

// -------------------------------------------------------------------------
// PTP time model: advances CLK_PERIOD_NS per cycle, nanoseconds carry into
// seconds at 1e9. time_advancing lets a test freeze time while it presets a
// new {seconds, nanoseconds} pair.
// -------------------------------------------------------------------------
reg [47:0] time_seconds     = 48'd0;
reg [31:0] time_nanoseconds = 32'd0;
reg        time_valid       = 1'b1;
reg        time_step        = 1'b0;
reg        time_advancing   = 1'b0;

always @(posedge clk) begin
    if (time_advancing) begin
        if (time_nanoseconds + CLK_PERIOD_NS >= 32'd1_000_000_000) begin
            time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS - 32'd1_000_000_000;
            time_seconds     <= time_seconds + 48'd1;
        end else begin
            time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS;
        end
    end
end

reg enable_input = 1'b0;

// -------------------------------------------------------------------------
// CSR bus (writes broadcast to all nodes, reads taken from node 0)
// -------------------------------------------------------------------------
reg  [23:0] csr_write_addr   = 24'd0;
reg  [31:0] csr_write_data   = 32'd0;
reg  [3:0]  csr_write_strobe = 4'hF;
reg         csr_write_enable = 1'b0;
reg  [23:0] csr_read_addr    = 24'd0;
reg         csr_read_enable  = 1'b0;

wire        csr_write_ack [0:NODE_COUNT-1];
wire        csr_read_ack  [0:NODE_COUNT-1];
wire [31:0] csr_read_data [0:NODE_COUNT-1];

// -------------------------------------------------------------------------
// DUTs
// -------------------------------------------------------------------------
wire [63:0] round_id         [0:NODE_COUNT-1];
wire        round_start      [0:NODE_COUNT-1];
wire        tx_start         [0:NODE_COUNT-1];
wire        ctrl_window      [0:NODE_COUNT-1];
wire        tx_window        [0:NODE_COUNT-1];

wire        time_fault       [0:NODE_COUNT-1];
wire [31:0] time_fault_count [0:NODE_COUNT-1];

genvar node_index;
generate
for (node_index = 0; node_index < NODE_COUNT; node_index = node_index + 1) begin : g_node
    // this node's registers
    wire        csr_enable, csr_reboot, csr_pending, activate_taken;
    wire [31:0] cfg_run_id;
    wire [7:0]  cfg_membership;
    wire [63:0] cfg_effective_round;
    wire        timing_armed, excludes_self;
    wire [7:0]  cur_membership, halt_witness, halt_membership, halt_sound_set, halt_prev_sound_set;
    wire [3:0]  halt_reason;
    wire [63:0] halt_round_id, round_count, commit_count;
    wire [31:0] halt_count;
    wire        halt_w;


    ssr_csr #(
        .P_NODE_ID(node_index), .P_NODE_COUNT(NODE_COUNT), .P_ROUND_NS(ROUND_LENGTH_NS)
    ) csr (
        .clk(clk), .rst(rst),
        .reg_wr_addr(csr_write_addr), .reg_wr_data(csr_write_data),
        .reg_wr_strb(4'hF), .reg_wr_en(csr_write_enable),
        .reg_wr_wait(), .reg_wr_ack(csr_write_ack[node_index]),
        .reg_rd_addr(csr_read_addr), .reg_rd_en(csr_read_enable),
        .reg_rd_data(csr_read_data[node_index]), .reg_rd_wait(),
        .reg_rd_ack(csr_read_ack[node_index]),
        .i_fault(8'd0),
        .o_core_enable(csr_enable), .o_core_reboot(csr_reboot),
        .o_activate_pending(csr_pending), .i_activate_taken(activate_taken),
        .o_cfg_run_id(cfg_run_id), .o_cfg_membership(cfg_membership),
        .o_cfg_effective_round(cfg_effective_round),
        .i_halt(halt_w), .i_timing_armed(timing_armed), .i_ptp_time_valid(time_valid),
        .i_config_excludes_self(excludes_self), .i_round_id(round_id[node_index]),
        .i_cur_run_id(dut.current_run_id_reg), .i_cur_sound_set(dut.current_sound_set_reg),
        .i_cur_membership(cur_membership),
        .i_halt_reason(halt_reason), .i_halt_round_id(halt_round_id),
        .i_halt_witness(halt_witness), .i_halt_membership(halt_membership),
        .i_halt_sound_set(halt_sound_set), .i_halt_prev_sound_set(halt_prev_sound_set),
        .i_round_count(round_count),
        .i_commit_count(commit_count), .i_halt_count(halt_count),
        .i_time_fault_count(time_fault_count[node_index]),
        // not in this bench: the proposal ring, delivery, the datapath counters
        .i_prop_idle('0), .i_prop_error('0), .i_prop_pending('0), .i_prop_error_code('0),
        .i_prop_consumer('0), .i_prop_fetch('0), .i_prop_inflight('0), .i_prop_reads('0),
        .i_prop_read_errors('0), .i_unit_idle('0), .i_tag_high_water('0), .i_verdict_seq('0),
        .i_tx_ctrl_frames('0), .i_tx_pay_frames('0), .i_tx_empty('0), .i_tx_overrun('0),
        .i_tx_missed('0), .i_tx_host_frames('0), .i_tx_cpl_count('0), .i_tx_cpl_ts('0), .i_rx_frames('0),
        .i_rx_accept('0), .i_rx_ctrl('0), .i_rx_malformed('0), .i_rx_ctrl_late('0),
        .i_rx_window_drop('0), .i_rx_member_drop('0), .i_rx_sound_drop('0), .i_rx_run_drop('0),
        .i_rx_round_drop('0), .i_rx_stall('0), .i_rx_host_frames('0), .i_rx_ack_disagree('0), .i_stage_push('0),
        .i_stage_full('0), .i_pay_desc('0), .i_pay_cpl('0), .i_pay_err('0), .i_pay_starve('0),
        .i_pres_late('0), .i_pres_err('0), .i_pres_err_miss('0),
        .i_verdict_records('0), .i_verdict_err('0), .i_verdict_overflow('0), .i_verdict_stale('0)
    );

    ssr_core #(
        .P_NODE_COUNT(NODE_COUNT),
        .P_NODE_ID(node_index),
        .ROUND_LENGTH_NS(ROUND_LENGTH_NS), .GUARD_TIME_NS(GUARD_TIME_NS),
        .CTRL_PERIOD_NS(CTRL_PERIOD_NS), .PROP_DEAD_NS(PROP_DEAD_NS),
        .PRESENT_SETTLE_NS(PRESENT_SETTLE_NS)
    ) dut (
        .clk(clk), .rst(rst), .i_enable(enable_input && csr_enable),
        .i_reboot(csr_reboot), .i_activate_pending(csr_pending),
        .o_activate_taken(activate_taken),
        .i_cfg_run_id(cfg_run_id), .i_cfg_membership(cfg_membership),
        .i_cfg_effective_round(cfg_effective_round),

        .i_ptp_tod_sec(time_seconds), .i_ptp_tod_ns(time_nanoseconds),
        .i_ptp_time_valid(time_valid), .i_ptp_step(time_step),


        .o_round_id(round_id[node_index]),
        .o_round_start_pulse(round_start[node_index]),
        .o_round_boundary_pulse(),
        .o_tx_start_pulse(), .o_rx_ctrl_window(), .o_rx_pay_enable(),

        .o_tx_round_id(), .o_tx_run_id(), .o_tx_pay_open(),

        .i_rx_valid(1'b0), .i_rx_node_id(8'd0),

        .o_commit_valid(), .o_commit_round_id(), .o_commit_set(),

        .o_halt(halt_w),
        .o_time_fault(time_fault[node_index]),
        .o_timing_armed(timing_armed), .o_config_excludes_self(excludes_self),
        .o_cur_membership(cur_membership),
        .o_halt_reason(halt_reason), .o_halt_round_id(halt_round_id),
        .o_halt_witness(halt_witness), .o_halt_membership(halt_membership),
        .o_halt_sound_set(halt_sound_set), .o_halt_prev_sound_set(halt_prev_sound_set),
        .o_round_count(round_count),
        .o_commit_count(commit_count), .o_halt_count(halt_count),
        .o_time_fault_count(time_fault_count[node_index])
    );

    // Ungated SECTION 2 taps: the module ports are ANDed with protocol_active,
    // which is low here because these nodes are never activated.
    assign tx_start[node_index]  = dut.tx_start_pulse_reg;
    assign tx_window[node_index]   = dut.tx_active_previous_reg;
    assign ctrl_window[node_index] = dut.rx_ctrl_window_previous_reg;
end
endgenerate

// -------------------------------------------------------------------------
// check helpers
// -------------------------------------------------------------------------
integer error_count = 0;
integer check_count = 0;

task check(input condition, input string message);
begin
    check_count = check_count + 1;
    if (!condition) begin
        $display("[%0t] ERROR: %0s", $realtime, message);
        error_count = error_count + 1;
    end
end
endtask

reg csr_last_acked = 1'b0;

task csr_write(input [23:0] address, input [31:0] data);
    integer poll_count;
begin
    @(negedge clk);
    csr_write_addr   = address;
    csr_write_data   = data;
    csr_write_strobe = 4'hF;
    csr_write_enable = 1'b1;
    csr_last_acked   = 1'b0;
    poll_count = 0;
    while (!csr_last_acked && poll_count < 16) begin
        @(posedge clk);
        #0.1;
        if (csr_write_ack[0]) csr_last_acked = 1'b1;
        poll_count = poll_count + 1;
    end
    @(negedge clk);
    csr_write_enable = 1'b0;
end
endtask

reg [31:0] csr_read_value = 32'd0;

task csr_read(input [23:0] address);
    integer poll_count;
begin
    @(negedge clk);
    csr_read_addr   = address;
    csr_read_enable = 1'b1;
    csr_last_acked  = 1'b0;
    csr_read_value  = 32'hDEAD_BEEF;
    poll_count = 0;
    while (!csr_last_acked && poll_count < 16) begin
        @(posedge clk);
        #0.1;
        if (csr_read_ack[0]) begin
            csr_last_acked = 1'b1;
            csr_read_value = csr_read_data[0];
        end
        poll_count = poll_count + 1;
    end
    @(negedge clk);
    csr_read_enable = 1'b0;
end
endtask

task set_time(input [47:0] seconds, input [31:0] nanoseconds);
begin
    time_advancing = 1'b0;
    @(negedge clk);
    time_seconds     = seconds;
    time_nanoseconds = nanoseconds;
    @(negedge clk);
    time_advancing = 1'b1;
end
endtask

// -------------------------------------------------------------------------
// continuous monitors
// -------------------------------------------------------------------------
reg [63:0] previous_round_id     = 64'd0;
reg        previous_round_valid  = 1'b0;
real       last_round_start_time = 0.0;
integer    rounds_observed       = 0;
integer    monitor_index;
integer    active_tx_window_count;

always @(posedge clk) begin
    // (a) round_id strictly +1 and (b) every round exactly ROUND_LENGTH_NS wide,
    //     including the one that spans the second rollover.
    if (round_start[0]) begin
        rounds_observed = rounds_observed + 1;
        if (previous_round_valid) begin
            check(round_id[0] == previous_round_id + 64'd1,
                  $sformatf("round_id %0d -> %0d (expected +1)",
                            previous_round_id, round_id[0]));
            check(($realtime - last_round_start_time) == ROUND_LENGTH_NS,
                  $sformatf("round width %0.1f ns, expected %0d",
                            $realtime - last_round_start_time, ROUND_LENGTH_NS));
        end
        previous_round_id     = round_id[0];
        last_round_start_time = $realtime;
        previous_round_valid  = 1'b1;
    end

    // (c) all nodes must agree on round_id at all times
    if (enable_input && !rst) begin
        for (monitor_index = 1; monitor_index < NODE_COUNT; monitor_index = monitor_index + 1)
            check(round_id[monitor_index] == round_id[0],
                  $sformatf("node %0d round_id %0d != node0 %0d",
                            monitor_index, round_id[monitor_index], round_id[0]));
    end

    // (d) EVERY node's transmit window is the same window
    //
    //   This used to assert the opposite - at most one node open at a time,
    //   the TDMA sub-slot invariant. The sub-slots are gone: all nodes share
    //   one control period and one payload period, so the windows are either
    //   all open or all shut, and a node out of step with the others is now
    //   the fault worth catching.
    active_tx_window_count = 0;
    for (monitor_index = 0; monitor_index < NODE_COUNT; monitor_index = monitor_index + 1)
        if (tx_window[monitor_index])
            active_tx_window_count = active_tx_window_count + 1;
    check(active_tx_window_count == 0 || active_tx_window_count == NODE_COUNT,
          $sformatf("%0d of %0d nodes assert tx_window - the windows must move together",
                    active_tx_window_count, NODE_COUNT));
end

// -------------------------------------------------------------------------
// main
// -------------------------------------------------------------------------
integer    test_node_index;
reg [63:0] expected_round_id;
reg [31:0] round_offset_ns;
reg [31:0] fault_count_before;

initial begin
    $dumpfile("build/tb_ssr_core_timing.vcd");
    $dumpvars(0, tb_ssr_core_timing);

    // ------------- reset, park just before a second rollover -------------
    rst = 1'b1; enable_input = 1'b0; time_advancing = 1'b0;
    repeat (10) @(posedge clk);
    // 40 us short of the rollover == 10 rounds, so Test 2 needs ~10k cycles
    // instead of the 250M it would take from nanoseconds = 0.
    set_time(48'd7, 32'd999_960_000);
    rst = 1'b0;
    repeat (5) @(posedge clk);

    check(round_start[0] === 1'b0, "no round_start while disabled");

    // ---------------------- Test 0: CSR identity ----------------------
    $display("[%0t] Test 0: CSR identity and access rules", $realtime);

    csr_read(REG_MAGIC);
    check(csr_last_acked && csr_read_value == 32'h53535201,
          $sformatf("TYPE = %08h, expected 53535201", csr_read_value));
    csr_read(REG_VERSION);
    check(csr_last_acked && csr_read_value == 32'h00000200,
          $sformatf("VERSION = %08h", csr_read_value));
    csr_read(REG_ROUND_LENGTH_NS);
    check(csr_last_acked && csr_read_value == ROUND_LENGTH_NS,
          $sformatf("ROUND_LENGTH_NS = %0d, expected %0d",
                    csr_read_value, ROUND_LENGTH_NS));
    csr_read(REG_NODE);
    check(csr_last_acked && csr_read_value[7:0] == 8'd0, "node0 NODE.id should be 0");
    check(csr_read_value[15:8] == NODE_COUNT, "NODE.count mismatch");

    // unmapped address must not acknowledge
    csr_read(REG_UNMAPPED);
    check(!csr_last_acked, "read of an unmapped address must not ack");
    csr_write(REG_UNMAPPED, 32'h1234_5678);
    check(!csr_last_acked, "write to an unmapped address must not ack");

    // config is writable while disabled
    csr_write(REG_CONFIG_RUN_ID, 32'h0000_0042);
    check(csr_last_acked, "CONFIG_RUN_ID write should ack");
    csr_read(REG_CONFIG_RUN_ID);
    check(csr_read_value == 32'h0000_0042,
          $sformatf("CONFIG_RUN_ID readback %08h", csr_read_value));

    csr_write(REG_CONFIG_MEMBERSHIP, 32'h0000_0007);
    csr_read(REG_CONFIG_MEMBERSHIP);
    check(csr_read_value == 32'h0000_0007, "CONFIG_MEMBERSHIP readback");

    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW, 32'h0000_0100);
    csr_read(REG_CONFIG_EFFECTIVE_ROUND_LOW);
    check(csr_read_value == 32'h0000_0100, "CONFIG_EFFECTIVE_ROUND_LOW readback");

    // ---------------------- Test 1: arm and absolute round_id ------------
    $display("[%0t] Test 1: arm, absolute round_id, cross-node agreement", $realtime);

    // Enable the timing only. No activate: SECTION 3 stays in S_IDLE and the
    // checks below read the ungated taps.
    enable_input = 1'b1;
    csr_write(REG_CONTROL, 32'h0000_0001);       // enable
    // Arming is bit-serial now: the product and the quotient each take 34
    // cycles, and a result that straddled a boundary is retried. Allow ~100.
    repeat (ARM_CYCLES) @(posedge clk);

    csr_read(REG_STATUS);
    check(csr_read_value[1] === 1'b1, "STATUS.armed should be set after enable");
    check(csr_read_value[2] === 1'b1, "STATUS.ptp_time_valid should be set");

    expected_round_id = 48'd7 * ROUNDS_PER_SECOND
                      + (32'd999_960_000 / ROUND_LENGTH_NS);
    check(round_id[0] == expected_round_id,
          $sformatf("armed round_id %0d, expected %0d",
                    round_id[0], expected_round_id));

    csr_read(REG_CURRENT_ROUND_ID_LOW);
    check(csr_read_value == round_id[0][31:0],
          "CURRENT_ROUND_ID_LOW should mirror o_round_id");

    // A config is locked once ARMED, not merely once enabled - that distinction
    // is what lets a running cluster stage its next configuration. Park the
    // effective round far in the future so that arming does not also activate,
    // which would take this bench out of the pure-timing regime it needs.
    csr_write(REG_CONFIG_EFFECTIVE_ROUND_LOW, 32'hFFFF_FFFF);
    csr_write(REG_CONTROL, 32'h0000_0003);       // enable | activate -> armed
    repeat (4) @(posedge clk);

    csr_write(REG_CONFIG_RUN_ID, 32'h0000_00FF);
    csr_read(REG_CONFIG_RUN_ID);
    check(csr_read_value == 32'h0000_0042,
          $sformatf("armed CONFIG_RUN_ID must be write-locked, read back %08h",
                    csr_read_value));

    csr_read(REG_STATUS);
    check(csr_read_value[3] === 1'b1, "STATUS.activate_pending should be set while armed");

    csr_write(REG_CONTROL, 32'h0000_0005);       // enable | reboot -> disarm
    repeat (4) @(posedge clk);
    csr_write(REG_CONFIG_RUN_ID, 32'h0000_0042); // writable again once disarmed
    csr_read(REG_CONFIG_RUN_ID);
    check(csr_read_value == 32'h0000_0042, "CONFIG_RUN_ID writable again once disarmed");

    // ---------------------- Test 2: cross the second boundary ------------
    $display("[%0t] Test 2: cross the second rollover", $realtime);
    // The always-block monitor checks width and continuity through the rollover.
    wait (time_seconds == 48'd8);
    repeat (3 * ROUND_LENGTH_NS / CLK_PERIOD_NS) @(posedge clk);

    check(round_id[0] >= 48'd8 * ROUNDS_PER_SECOND &&
          round_id[0] <= 48'd8 * ROUNDS_PER_SECOND + 64'd4,
          $sformatf("round_id %0d not realigned to second 8 (base %0d)",
                    round_id[0], 48'd8 * ROUNDS_PER_SECOND));
    check(rounds_observed > 10, "expected to observe many rounds by now");

    // ---------------------- Test 3: TX window placement ------------------
    $display("[%0t] Test 3: one window, the same for every node", $realtime);

    // EVERY NODE OPENS AT THE SAME INSTANT. That is the defining property of
    // the round structure that replaced the sub-slots: separation inside the
    // control period comes from propagation and guard time, not from each node
    // being handed a different offset. The old test asserted the opposite -
    // node k starting at GUARD + k*TX_SUBSLOT_NS - so this is the same test
    // inverted, and it is the one that would catch a silent revert.
    for (test_node_index = 0; test_node_index < NODE_COUNT;
         test_node_index = test_node_index + 1) begin
        @(posedge tx_start[test_node_index]);
        #0.1;
        round_offset_ns = time_nanoseconds % ROUND_LENGTH_NS;
        check(round_offset_ns >= TX_OPEN_NS &&
              round_offset_ns <  TX_OPEN_NS + CLK_PERIOD_NS + 1,
              $sformatf("node %0d tx_start at offset %0d, expected ~%0d (same for every node)",
                        test_node_index, round_offset_ns, TX_OPEN_NS));
    end

    // THE TRANSMIT LEVEL RUNS TO THE ROUND BOUNDARY AND NOWHERE ELSE.
    //   There is no transmit window any more - the rate cap in ssr_tx_engine is
    //   what keeps the receivers safe, not a time bound. So the level that
    //   carries the start pulse simply stays up until the round ends.
    @(posedge tx_window[0]);
    @(negedge tx_window[0]);
    #0.1;
    round_offset_ns = time_nanoseconds % ROUND_LENGTH_NS;
    //   Both the offset and the level are registered, so the fall lands a
    //   couple of cycles into the new round rather than exactly on the
    //   boundary. LEVEL_LATENCY_NS names that instead of hiding it in a
    //   tolerance - what the test is asserting is "at the boundary", and
    //   anything materially earlier is a transmit window.
    check(round_offset_ns < LEVEL_LATENCY_NS,
          $sformatf("the transmit level fell at offset %0d of a %0d ns round; it must fall at the round boundary (within %0d ns of register latency) and not before - anything earlier is a transmit window that should not exist",
                    round_offset_ns, ROUND_LENGTH_NS, LEVEL_LATENCY_NS));

    // A peer's control frame leaves at TX_OPEN_NS on its clock and lands one
    // propagation later, so the deadline has to be past that.
    check(CTRL_PERIOD_NS > TX_OPEN_NS + PROP_DEAD_NS,
          $sformatf("CTRL_PERIOD_NS %0d must be past a peer's control frame arrival %0d",
                    CTRL_PERIOD_NS, TX_OPEN_NS + PROP_DEAD_NS));

    // The control window has no lower bound: a peer whose clock runs slightly
    // ahead of ours must not have its control frame rejected for being early.
    //
    // It is open from the register latency onward rather than from offset 0.
    // Those few ns are unreachable in practice - a peer's control frame leaves
    // at TX_OPEN_NS on its own clock and arrives a propagation later, so it
    // would take a clock error of most of a round to land there - but the test
    // says "open at the top of the round", not "open at some offset".
    @(posedge round_start[0]);
    repeat (3) @(posedge clk);
    #0.1;
    round_offset_ns = time_nanoseconds % ROUND_LENGTH_NS;
    check(ctrl_window[0] === 1'b1,
          $sformatf("the control window must be open at offset %0d, near the top of the round - a lower bound would reject an early peer",
                    round_offset_ns));
    check(round_offset_ns < CTRL_PERIOD_NS,
          "this check is only meaningful inside the control period");

    // ---------------------- Test 4: PTP step -----------------------------
    $display("[%0t] Test 4: PTP step is treated as a fault", $realtime);

    fault_count_before = time_fault_count[0];
    set_time(48'd20, 32'd500_000);        // jump the second field forward by 12
    repeat (4) @(posedge clk);
    check(time_fault_count[0] > fault_count_before,
          "a PTP step must be counted as a time fault");

    csr_read(REG_TIME_FAULT_COUNT);
    check(csr_read_value == time_fault_count[0],
          "TIME_FAULT_COUNT should mirror the counter");

    previous_round_valid = 1'b0;          // restart continuity tracking
    repeat (3 * ROUND_LENGTH_NS / CLK_PERIOD_NS) @(posedge clk);

    csr_read(REG_STATUS);
    check(csr_read_value[1] === 1'b1, "should re-arm after the step");
    check(round_id[0] >= 48'd20 * ROUNDS_PER_SECOND,
          $sformatf("round_id %0d should realign to second 20", round_id[0]));

    // also exercise the explicit step flag
    fault_count_before = time_fault_count[0];
    @(negedge clk); time_step = 1'b1;
    @(negedge clk); time_step = 1'b0;
    repeat (4) @(posedge clk);
    check(time_fault_count[0] > fault_count_before,
          "i_ptp_step must raise a time fault");
    previous_round_valid = 1'b0;
    repeat (2 * ROUND_LENGTH_NS / CLK_PERIOD_NS) @(posedge clk);

    // ---------------------- Test 5: disable / re-enable ------------------
    $display("[%0t] Test 5: disable and re-enable", $realtime);

    csr_write(REG_CONTROL, 32'h0000_0000);       // clear enable
    repeat (6) @(posedge clk);
    csr_read(REG_STATUS);
    check(csr_read_value[1] === 1'b0, "armed must drop when disabled");
    check(tx_window[0] === 1'b0, "tx_window must drop when disabled");
    previous_round_valid = 1'b0;

    csr_write(REG_CONTROL, 32'h0000_0001);
    repeat (ARM_CYCLES) @(posedge clk);
    csr_read(REG_STATUS);
    check(csr_read_value[1] === 1'b1, "should re-arm after re-enable");

    // config is writable again once disabled
    csr_write(REG_CONTROL, 32'h0000_0000);
    csr_write(REG_CONFIG_RUN_ID, 32'h0000_0099);
    csr_read(REG_CONFIG_RUN_ID);
    check(csr_read_value == 32'h0000_0099,
          "CONFIG_RUN_ID writable again while disabled");
    csr_write(REG_CONTROL, 32'h0000_0001);
    previous_round_valid = 1'b0;

    repeat (4 * ROUND_LENGTH_NS / CLK_PERIOD_NS) @(posedge clk);

    // ---------------------------- summary --------------------------------
    $display("--------------------------------------------------");
    $display("rounds observed : %0d", rounds_observed);
    $display("checks          : %0d", check_count);
    $display("errors          : %0d", error_count);
    $display("--------------------------------------------------");
    if (error_count == 0) $display("[%0t] ALL TESTS PASSED", $realtime);
    else                  $display("[%0t] %0d FAILURES", $realtime, error_count);
    $finish;
end

initial begin
    #20_000_000;
    $display("[%0t] TIMEOUT", $realtime);
    $finish;
end

endmodule

`resetall
