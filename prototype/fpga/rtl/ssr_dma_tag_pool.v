`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ssr_dma_tag_pool - outstanding DMA descriptor tracking, with a per-unit fence
 *
 * WHY THIS MODULE EXISTS AT ALL
 *   Under speculative delivery (docs/speculative_delivery.md) a round's payload
 *   goes to host memory as several independent DMA writes, and the verdict
 *   record describing that round must not become visible to the host until all
 *   of them have landed.
 *
 * WHAT A "UNIT" IS
 *   Whatever the caller wants to fence on. For the payload path it is the round
 *   slot index (round_id mod P_ROUND_DEPTH), so o_unit_idle[rsel] means "every
 *   payload write for the round in slot rsel has completed". The pool does not
 *   care what the number means; it only counts.
 *
 * THE TAG
 *   Tags handed out are TAG_BASE with the low $clog2(TAG_COUNT) bits replaced by
 *   the descriptor id. A completion is ours when the bits above the id match
 *   TAG_BASE. That lets several pools (payload, verdict, anything else) share
 *   one DMA engine's status stream without a central allocator - give each pool
 *   a distinct TAG_BASE with disjoint id ranges.
 *
 * TIMING CONTRACT - read this before wiring it up
 *   - o_alloc_ready / o_alloc_tag are COMBINATIONAL. Assert i_alloc_valid in the
 *     same cycle you put o_alloc_tag on the descriptor, so the count rises
 *     before anyone can observe the fence as open.
 *   - The descriptor handshake may stall afterwards. That is fine: the tag is
 *     already allocated and the unit is already non-idle, which is the
 *     conservative direction. The caller must not allocate a second tag for the
 *     same descriptor while waiting for it to fire.
 *   - o_cpl_hit / o_cpl_unit / o_cpl_meta / o_cpl_error are COMBINATIONAL,
 *     valid in the same cycle as i_cpl_valid. The caller uses them to act on the
 *     completion (for the payload path: clear present_set[k] on an error).
 *   - o_unit_idle is REGISTERED, so it reflects a completion from the NEXT
 *     cycle. A fence that samples it in the same cycle as i_cpl_valid sees the
 *     old, still-busy value - which is again the conservative direction.
 *
 * WHAT IT DOES NOT DO
 *   No retry. A descriptor that completes with an error is freed like any other
 *   and its error is reported once, on o_cpl_error. Deciding what an error means
 *   belongs to whoever owns the unit.
 */

module ssr_dma_tag_pool #
(
    // Number of descriptors that may be outstanding at once. Power of two.
    parameter integer TAG_COUNT   = 8,

    // Width of the DMA engine's tag field.
    parameter integer TAG_WIDTH   = 16,

    // Tags issued are TAG_BASE with the low ID bits replaced by the id.
    // The bits ABOVE the id must be unique per pool sharing a status stream.
    parameter [15:0]  TAG_BASE    = 16'h0000,

    // Number of independent fence units. Power of two.
    parameter integer UNIT_COUNT  = 4,

    // Caller payload carried with each tag and handed back on completion.
    // For the payload path this is the sending node id.
    parameter integer META_WIDTH  = 8,

    // ---- derived; do not override -----------------------------------------
    // These are parameters rather than localparams only because the port list
    // is elaborated before the module body, so a localparam cannot size a port.
    parameter integer ID_W        = (TAG_COUNT  > 1) ? $clog2(TAG_COUNT)  : 1,
    parameter integer UNIT_SEL_W  = (UNIT_COUNT > 1) ? $clog2(UNIT_COUNT) : 1,
    parameter integer TAG_CNT_W   = $clog2(TAG_COUNT + 1)
)
(
    input  wire                         clk,
    input  wire                         rst,

    // ---- allocate ---------------------------------------------------------
    input  wire                         i_alloc_valid,
    input  wire [UNIT_SEL_W-1:0]        i_alloc_unit,
    input  wire [META_WIDTH-1:0]        i_alloc_meta,
    output wire                         o_alloc_ready,
    output wire [TAG_WIDTH-1:0]         o_alloc_tag,

    // ---- completion -------------------------------------------------------
    input  wire                         i_cpl_valid,
    input  wire [TAG_WIDTH-1:0]         i_cpl_tag,
    input  wire [3:0]                   i_cpl_error,
    output wire                         o_cpl_hit,
    output wire [UNIT_SEL_W-1:0]        o_cpl_unit,
    output wire [META_WIDTH-1:0]        o_cpl_meta,
    output wire                         o_cpl_error,

    // ---- the fence --------------------------------------------------------
    output wire [UNIT_COUNT-1:0]        o_unit_idle,

    // ---- counters ---------------------------------------------------------
    output wire [31:0]                  o_alloc_count,
    output wire [31:0]                  o_cpl_count,
    output wire [31:0]                  o_err_count,
    output wire [31:0]                  o_stray_count,   // a completion we never issued
    output wire [31:0]                  o_starve_count,  // alloc asked for while full
    output wire [TAG_CNT_W-1:0]         o_high_water     // most ever outstanding
);

// ---------------------------------------------------------------- geometry
localparam [TAG_WIDTH-1:0] ID_MASK  = (TAG_COUNT - 1);
localparam [TAG_WIDTH-1:0] BASE_HI  = TAG_BASE[TAG_WIDTH-1:0] & ~ID_MASK;

initial begin
    if (TAG_COUNT == 0 || (TAG_COUNT & (TAG_COUNT - 1))) begin
        $error("ssr_dma_tag_pool: TAG_COUNT = %0d is not a non-zero power of two (instance %m)", TAG_COUNT);
        $finish;
    end
    if (UNIT_COUNT == 0 || (UNIT_COUNT & (UNIT_COUNT - 1))) begin
        $error("ssr_dma_tag_pool: UNIT_COUNT = %0d is not a non-zero power of two (instance %m)", UNIT_COUNT);
        $finish;
    end
    if (ID_W > TAG_WIDTH) begin
        $error("ssr_dma_tag_pool: TAG_COUNT = %0d needs %0d tag bits but TAG_WIDTH is %0d (instance %m)",
               TAG_COUNT, ID_W, TAG_WIDTH);
        $finish;
    end
    if ((TAG_BASE[TAG_WIDTH-1:0] & ID_MASK) != 0) begin
        $error("ssr_dma_tag_pool: TAG_BASE = %h has bits set inside the id field (instance %m)", TAG_BASE);
        $finish;
    end
end

// ---------------------------------------------------------------- state
reg [TAG_COUNT-1:0]   busy_reg = {TAG_COUNT{1'b0}};
reg [UNIT_SEL_W-1:0]  unit_tab [0:TAG_COUNT-1];
reg [META_WIDTH-1:0]  meta_tab [0:TAG_COUNT-1];
reg [TAG_CNT_W-1:0]   unit_out [0:UNIT_COUNT-1];

reg [31:0] alloc_count_reg  = 32'd0;
reg [31:0] cpl_count_reg    = 32'd0;
reg [31:0] err_count_reg    = 32'd0;
reg [31:0] stray_count_reg  = 32'd0;
reg [31:0] starve_count_reg = 32'd0;
reg [TAG_CNT_W-1:0] high_water_reg = {TAG_CNT_W{1'b0}};
reg [TAG_CNT_W-1:0] live_reg       = {TAG_CNT_W{1'b0}};

// Arrays power up as X in simulation, and `if (X)` takes the else branch, so an
// uninitialised table turns a real failure into a silent pass. Cost here is
// nothing: Xilinx initialises distributed RAM anyway.
integer init_i;
initial begin
    for (init_i = 0; init_i < TAG_COUNT; init_i = init_i + 1) begin
        unit_tab[init_i] = {UNIT_SEL_W{1'b0}};
        meta_tab[init_i] = {META_WIDTH{1'b0}};
    end
    for (init_i = 0; init_i < UNIT_COUNT; init_i = init_i + 1)
        unit_out[init_i] = {TAG_CNT_W{1'b0}};
end

// ---------------------------------------------------------------- allocate
// Lowest free id wins. The loop runs downwards so the last write - the lowest
// index - is the one that sticks, which is Verilog's last-write-wins acting as
// a priority encoder.
//
// This is a FUNCTION called from a continuous assignment, not an `always @*`
// block, and that is deliberate. `always @*` has no initial event: it does not
// run until something in its inferred sensitivity list changes. busy_reg starts
// at zero and stays there until the first allocation, so an `always @*` version
// leaves o_alloc_ready at X for the whole of a quiet start-up - and `if (X)`
// takes the else branch, so a caller checking `alloc_ready` before allocating
// gets a silent wrong answer instead of a visible failure. A continuous
// assignment evaluates at time zero and on every argument change.
function [ID_W:0] pick_free(input [TAG_COUNT-1:0] busy);
    integer fi;
begin
    pick_free = {(ID_W+1){1'b0}};
    for (fi = TAG_COUNT-1; fi >= 0; fi = fi - 1)
        if (!busy[fi]) pick_free = {1'b1, fi[ID_W-1:0]};
end
endfunction

wire [ID_W:0]   pick        = pick_free(busy_reg);
wire            alloc_avail = pick[ID_W];
wire [ID_W-1:0] alloc_id    = pick[ID_W-1:0];

assign o_alloc_ready = alloc_avail;
assign o_alloc_tag   = BASE_HI | {{(TAG_WIDTH-ID_W){1'b0}}, alloc_id};

wire alloc_fire = i_alloc_valid && o_alloc_ready;

// ---------------------------------------------------------------- completion
wire [ID_W-1:0] cpl_id     = i_cpl_tag[ID_W-1:0];
wire            cpl_is_ours = i_cpl_valid && ((i_cpl_tag & ~ID_MASK) == BASE_HI);

assign o_cpl_hit   = cpl_is_ours && busy_reg[cpl_id];
assign o_cpl_unit  = unit_tab[cpl_id];
assign o_cpl_meta  = meta_tab[cpl_id];
assign o_cpl_error = o_cpl_hit && (i_cpl_error != 4'd0);

// A completion carrying our TAG_BASE for an id we do not have outstanding. It
// means the tag space is being shared with something that does not respect
// TAG_BASE, or a completion arrived twice. Either is a wiring bug, so it gets a
// counter rather than being ignored.
wire cpl_stray = cpl_is_ours && !busy_reg[cpl_id];

// ---------------------------------------------------------------- the fence
// A generate of continuous assignments rather than an `always @*` over the
// array, for the same reason as pick_free above, and because `@*` on an array
// is sensitive to every word of it - Icarus says so out loud.
genvar gu;
generate
    for (gu = 0; gu < UNIT_COUNT; gu = gu + 1) begin : g_unit_idle
        assign o_unit_idle[gu] = (unit_out[gu] == {TAG_CNT_W{1'b0}});
    end
endgenerate

// ---------------------------------------------------------------- sequential
integer uj;
always @(posedge clk) begin
    if (rst) begin
        busy_reg         <= {TAG_COUNT{1'b0}};
        alloc_count_reg  <= 32'd0;
        cpl_count_reg    <= 32'd0;
        err_count_reg    <= 32'd0;
        stray_count_reg  <= 32'd0;
        starve_count_reg <= 32'd0;
        high_water_reg   <= {TAG_CNT_W{1'b0}};
        live_reg         <= {TAG_CNT_W{1'b0}};
        for (uj = 0; uj < UNIT_COUNT; uj = uj + 1)
            unit_out[uj] <= {TAG_CNT_W{1'b0}};
    end else begin
        if (alloc_fire) begin
            busy_reg[alloc_id] <= 1'b1;
            unit_tab[alloc_id] <= i_alloc_unit;
            meta_tab[alloc_id] <= i_alloc_meta;
            alloc_count_reg    <= alloc_count_reg + 32'd1;
        end

        if (i_alloc_valid && !o_alloc_ready)
            starve_count_reg <= starve_count_reg + 32'd1;

        if (o_cpl_hit) begin
            busy_reg[cpl_id] <= 1'b0;
            cpl_count_reg    <= cpl_count_reg + 32'd1;
            if (o_cpl_error)
                err_count_reg <= err_count_reg + 32'd1;
        end

        if (cpl_stray)
            stray_count_reg <= stray_count_reg + 32'd1;

        // Per-unit outstanding counts. Allocation and completion can land on the
        // same unit in the same cycle; then the count must not move.
        for (uj = 0; uj < UNIT_COUNT; uj = uj + 1) begin
            case ({alloc_fire && (i_alloc_unit == uj[UNIT_SEL_W-1:0]),
                   o_cpl_hit  && (o_cpl_unit   == uj[UNIT_SEL_W-1:0])})
                2'b10:   unit_out[uj] <= unit_out[uj] + 1'b1;
                2'b01:   unit_out[uj] <= unit_out[uj] - 1'b1;
                default: unit_out[uj] <= unit_out[uj];
            endcase
        end

        // High-water mark, for sizing TAG_COUNT from a real run rather than a guess.
        case ({alloc_fire, o_cpl_hit})
            2'b10: begin
                live_reg <= live_reg + 1'b1;
                if ((live_reg + 1'b1) > high_water_reg) high_water_reg <= live_reg + 1'b1;
            end
            2'b01:   live_reg <= live_reg - 1'b1;
            default: live_reg <= live_reg;
        endcase
    end
end

assign o_alloc_count  = alloc_count_reg;
assign o_cpl_count    = cpl_count_reg;
assign o_err_count    = err_count_reg;
assign o_stray_count  = stray_count_reg;
assign o_starve_count = starve_count_reg;
assign o_high_water   = high_water_reg;

endmodule

`resetall
