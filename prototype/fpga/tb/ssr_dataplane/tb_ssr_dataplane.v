`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * tb_ssr_dataplane - the integration bench for the ssr_dataplane wrapper.
 *
 * ============================================================================
 *                          WHAT THIS BENCH IS
 * ============================================================================
 *   ssr_dataplane.v is instantiated UNMODIFIED, with every module it contains
 *   inside it. Nothing here is hand-wired from parts. What surrounds it is the
 *   four things Corundum would provide and nothing else:
 *
 *     - a CSR bus, so the DUT is configured the way the driver configures it
 *     - a DMA engine model on both directions, driven by the DUT's own
 *       descriptors, reading and writing the DUT's own RAM ports - and a host
 *       memory model behind the write side, so a page and a verdict record
 *       are checked where the host would read them
 *     - an Ethernet port model that returns one completion per frame
 *     - two peer nodes putting real frames on the receive port: one control
 *       frame and then their fragments, every round. The control frame carries
 *       the peer's ack vector about the round before (docs/count_ack.md),
 *       computed from what the peers sent and what the port monitor saw this
 *       node send - so a peer is trusted exactly when a real one would be
 *
 *   Every check is made at one of those four boundaries. Nothing reaches into
 *   the DUT to sample an internal signal as an expected value; the hierarchical
 *   references that do exist (dut.current_round_id and friends) are there to
 *   TIME the stimulus, because a real cluster's clocks are disciplined together
 *   and modelling that agreement separately would be modelling the wrong thing.
 *
 * ============================================================================
 *                          COVERAGE MAP
 * ============================================================================
 *   ssr_dataplane.v (the wrapper itself)
 *   ssr_csr.v (every register)
 *       identity, geometry, SCRATCH, reset values ... A0, A2
 *       the delivery settings ....................... A1, F1, F2
 *       FAULT stays 0 ............................... B2, C1, E3, the end of the run
 *       pages on the data DMA, records on the
 *       control DMA, each read through its path's
 *       own RAM port ................................ C1 (every capture)
 *       completion tag routing ...................... B3, B4
 *       the SSR lane of IF_COUNT = 2, and the other
 *       lane wired straight through ................. J1, and a monitor on
 *                                                    every cycle (section 14b)
 *       time from the 96-bit ToD port ............... A1 (rounds turn), every
 *                                                    round-id check
 *
 *   ssr_core.v (ssr_core: timing + protocol)
 *       activation, round advance ................... A1
 *       round / run / sound-set readback ............ A2
 *       a control frame taken on the deadline's
 *       last cycle still makes a witness ............ I3
 *       a peer whose ack disagrees is no witness .... E14, H1
 *       the sound set shrinks when a peer disagrees   H1
 *       halt, halt record, reboot ................... H2, H3
 *
 *   ssr_proposal_dma_reader.v / ssr_proposal_buffer.v
 *       the ring: doorbell, address walk, wrap ...... B2 (every descriptor, continuous)
 *       reads in flight, completing out of order .... B7 (and every read)
 *       entries leave in ring order, beats 1..63 .... B2 (monitor, continuous)
 *       a backlog at the full rate: 5, then 3 ....... B7
 *       CONSUMER, in the CSR and the verdict record . B2, C1, G1
 *       a read that fails: stop, rewind, re-read .... G1, G2
 *       flush of posted-but-unread entries .......... G3
 *       (the buffer side of flush, and the stream
 *       under back pressure: tb_ssr_proposal_ring)
 *
 *   ssr_tx_engine.v
 *       control frame first, then paced fragments ... B1, B2 (monitor)
 *       frag_idx 0, 1, 2 ... in every round ......... every fragment (monitor)
 *       ack[self] is what the round before sent ..... every control frame (monitor)
 *       a proposal posted mid-round goes out in it .. B8
 *       nothing starts after the cutoff ............. B7
 *       no gap inside a frame ....................... every frame (monitor)
 *       the port back-pressures mid frame ........... B6
 *
 *   ssr_tx_mux.v
 *       a host frame crosses untouched .............. B4
 *       host and SSR contend, never interleave ...... B5
 *       SSR completions consumed, host forwarded .... B3, B4
 *
 *   ssr_rx_demux.v
 *       0x88B5 reaches ssr_rx_engine .................... C1
 *       anything else reaches the host, whole ....... D1, D2
 *
 *   ssr_rx_engine.v
 *       accept: a trusted peer to the core,
 *       payload to the stage ........................ C1
 *       malformed: every geometry rule .............. E1-E5, E12, E13
 *       the ack rung ................................ E14, H1
 *       member / sound / run / round drops .......... E6-E9, H1
 *       a late control frame ........................ E10
 *       payload while halted ........................ H2
 *
 *   ssr_payload_stage.v / ssr_payload_dma_writer.v / ssr_dma_tag_pool.v
 *       a frame becomes one page, header on top ..... C1
 *       host address = base + region + page ......... C1
 *       ... for 280 rounds, across the ring wrap .... I1
 *       ... with the RTL as node 1 (region k term,
 *       self_index, our own region untouched) ....... the node1 build, every test
 *       the stage holds frames while delivery is off  F1
 *       ... and fills, and the node halts, past it .. H4
 *       a page DMA that returns an error ............ F4
 *
 *   ssr_presence_tracker.v
 *       a peer that sends nothing counts 0 .......... C2
 *       a peer short one fragment: its prefix ....... H1
 *       a failed page withdraws presence ............ F4
 *       no late fragments over a long run ........... I1
 *       a round evicted before its record: stale .... I2
 *
 *   ssr_verdict_dma_writer.v
 *       one record per decision, every field ........ C1
 *       seq advances, addresses walk the ring ....... C1, C2
 *       the fence: no record before its pages ....... F3 (and every record)
 *       ... including one page parked for 4 rounds
 *       while everything else completes ............. I2
 *       the queue overflows when disabled ........... F2
 *       seq wraps the verdict ring .................. I1
 *
 * ============================================================================
 * HOW THE RECEIVE PORT IS DRIVEN
 * ============================================================================
 *   ONE process owns s_axis_if_rx: the peer driver in SECTION 13. Two processes
 *   driving one AXI-Stream is a race that shows up as a corrupted frame a long
 *   way downstream, so a test that wants to put a frame of its own on the wire
 *   fills in the inj_* request registers and waits. The driver sends it after
 *   the real peers have spoken - or, for E10, after the control deadline - and
 *   clears the request.
 *
 *   The peers stay ON for almost the whole run. At three nodes the core halts
 *   on its first decision without a quorum of matching ack vectors, so a bench
 *   that turned them on late would spend every earlier test talking to a halted
 *   core.
 *
 * ============================================================================
 * NEGATIVE CONTROLS (edit the RTL, never this file)
 * ============================================================================
 *   (re-run on the AU200 geometry, SSR_TB_SOAK_ROUNDS=12; the counts are from that run)
 *   ssr_verdict_dma_writer: fence_open = 1'b1                   12 errors: F3, and the
 *                                                           engine's own fence check
 *   ssr_presence_tracker: count a fragment whatever its index   ... C2/E11: an injected
 *   (drop the prefix term)                                  repeat is counted, the
 *                                                           vectors disagree, the
 *                                                           node halts
 *   ssr_rx_engine: drop the ack rung (hdr_ack_ok = 1)       E14, H1
 *   ssr_payload_dma_writer: drop "+ page_off" from host_addr    95 errors: every page after
 *                                                           frag 0 lands on frag 0
 *   ssr_dataplane: the verdict writer's status valid from   2 errors: I2 - a page's
 *   the data DMA, not the control DMA                       completion ends the record
 *                                                           early, the stale count is off
 *   ssr_dataplane: tracker fed rx_pl_commit, not o_staged   3 errors: H4 - the node
 *                                                           keeps running on frames
 *                                                           it dropped
 *   core: CTRL_END_SETTLE_CYCLES = 1                        I3 fails: the control
 *                                                           frame taken on the
 *                                                           deadline's last cycle is
 *                                                           missed, and the peer
 *                                                           leaves the sound set
 *   ssr_proposal_buffer: a RAM command only when the pipeline   B7: fewer than 5 in the
 *   is empty (the old one-beat-at-a-time readout)           round, gaps - the defect
 *                                                           the ring fixed
 *   ssr_tx_engine: no first-beat load at admission           B7: a one-cycle gap after
 *   (drop pay_accepted from payload_space)                  every header (monitor)
 *   ssr_tx_engine: pay_run_reg not cleared at the cutoff    B6: a fragment admitted at
 *                                                           the boundary carries the
 *                                                           round that just ended; the
 *                                                           peers disagree, the node
 *                                                           halts
 *   ssr_proposal_dma_reader: one read in flight                 B7: 3 then 5, not 5 then 3
 *   ssr_proposal_dma_reader: flush leaves CONSUMER              G3
 *   ssr_dataplane: .i_prop_consumer(32'd0)                  C1
 *   -- the AU200 geometry --
 *   ssr_payload_stage: every beat to segment 0              64 errors: C1, every page
 *                                                           wrong from beat 1 on
 *   ssr_proposal_buffer: every beat read from segment 0     B2: the payload is the
 *                                                           wrong beats of the entry
 *   ssr_dataplane: core seconds from ptp_sync_ts_rel        A1: the node never
 *                                                           activates (the watchdog);
 *                                                           A2 also checks the round
 *                                                           against the ToD
 *   ssr_dataplane: the other lane's tx tuser tied to 0      J1 and the lane monitor
 *   ssr_dataplane: SSR lane fixed at 0 (node1 build,        9 errors: the lane monitor,
 *   SSR_IF = 1)                                             and no SSR traffic at all
 *   ssr_tx_mux: completion is SSR's on tag bit 15           218 errors: SSR completions
 *   (the old rule)                                          leak, host ones are eaten
 *   ssr_rx_demux: every frame is SSR's (is_ssr_first = 1)   27 errors: D1, D2 and the
 *                                                           ladder counts, and FAULT
 *                                                           (RX_FOREIGN) at E3 and at
 *                                                           the end of the run
 *
 * BUILD KNOBS
 *   -DSSR_TB_NODE_ID=k        the RTL plays node k (0, 1 or 2); every peer id
 *                             in the bench is derived from it. `make
 *                             tb_ssr_dataplane_node1` is in the regression.
 *   -DSSR_TB_SOAK_ROUNDS=n    length of I1; below 260 the ring-wrap checks
 *                             are skipped (the rotated builds run it short).
 *   -DSSR_TB_IF=i             SSR on interface i of two (default 0). The
 *                             node1 build uses 1, so both lanes are covered.
 *
 * GEOMETRY: the AU200 build's - two interfaces, a DMA RAM row of two 512-bit
 * segments (two beats a row), 13-bit app DMA tags, a 1-bit ram_sel, 48-bit
 * interface timestamps, a 96-bit ToD. docs/au200_parameters.md.
 */

module tb_ssr_dataplane;

// ############################################################################
//              SECTION 1 - GEOMETRY AND CONFIGURATION
// ############################################################################

localparam integer CLK_PERIOD_NS   = 4; // 250 MHz, the same as the DUT's own clock.

localparam integer NODE_COUNT      = 3;
// Which of the three nodes the RTL plays is a build-time knob:
// `iverilog -DSSR_TB_NODE_ID=1`. The region index in every host address has
// a k term, the record has a self_index, our own region is the one never
// written, and ssr_rx_engine refuses our own id - none of which a node-0 build
// can tell from a constant. Every peer id below is derived from this.
`ifndef SSR_TB_NODE_ID
`define SSR_TB_NODE_ID 0
`endif
localparam integer NODE_ID         = `SSR_TB_NODE_ID;
localparam integer PEER_A          = (NODE_ID == 0) ? 1 : 0;   // the lower peer id
localparam integer PEER_B          = (NODE_ID == 2) ? 1 : 2;   // the higher peer id
localparam [7:0]   ALL_MEMBERS     = 8'b0000_0111;
localparam [7:0]   SELF_BIT        = 8'd1 << NODE_ID;
localparam [7:0]   PEER_A_BIT      = 8'd1 << PEER_A;
localparam [7:0]   PEER_B_BIT      = 8'd1 << PEER_B;
localparam integer ROUND_LENGTH_NS = 4000;
localparam integer GUARD_TIME_NS   = 50;
localparam integer CTRL_PERIOD_NS  = 646;
localparam integer FRAGS_PER_ROUND = 5;

// One round in clock cycles, the unit almost every wait in this bench uses.
localparam integer ROUND_CYCLES    = ROUND_LENGTH_NS/CLK_PERIOD_NS;   // 1000
localparam integer CTRL_CYCLES     = CTRL_PERIOD_NS/CLK_PERIOD_NS;    // 161

// How long the peer driver will wait for the control window before giving up
// on the round. A node that is not running never opens one.
localparam integer WINDOW_WAIT_MAX = 32;

// AXI-Stream related configuration.
localparam integer AXIS_DATA_WIDTH = 512;
localparam integer AXIS_KEEP_WIDTH = AXIS_DATA_WIDTH/8;
// Every width below is the AU200 build's (docs/au200_parameters.md).
localparam integer TX_TAG_WIDTH    = 16;
localparam integer AXIS_TX_USER_WIDTH = TX_TAG_WIDTH + 1;   // 17
// The interface timestamps: 48-bit relative time on the AU200. The core's
// own time comes from the 96-bit ToD port, which is a separate thing.
localparam integer PTP_TS_WIDTH    = 48;
localparam integer AXIS_TX_ID_WIDTH   = 13;
localparam integer AXIS_TX_DEST_WIDTH = 4;
localparam integer AXIS_RX_ID_WIDTH   = 1;
localparam integer AXIS_RX_DEST_WIDTH = 9;
localparam integer AXIS_RX_USER_WIDTH = PTP_TS_WIDTH + 1;   // 49

// Two interfaces, one per QSFP28 cage. SSR runs on lane SSR_IF; the other one
// is a plain NIC port and must come out of the app block exactly as it went
// in (J1, and a monitor on every cycle). `-DSSR_TB_IF=1` moves SSR to the
// second lane; the node1 build does, so both placements are in the regression.
`ifndef SSR_TB_IF
`define SSR_TB_IF 0
`endif
localparam integer IF_COUNT = 2;
localparam integer SSR_IF   = `SSR_TB_IF;
localparam integer OTHER_IF = 1 - SSR_IF;

// AXI-Lite CSR bus configuration.
localparam integer REG_ADDR_WIDTH = 24;
localparam integer REG_DATA_WIDTH = 32;

// DMA and RAM configuration.
localparam integer DMA_ADDR_WIDTH = 64;
localparam integer DMA_IMM_WIDTH  = 32;
localparam integer DMA_LEN_WIDTH  = 16;
localparam integer DMA_TAG_WIDTH  = 13;
localparam integer RAM_SEL_WIDTH  = 1;
localparam integer RAM_ADDR_WIDTH = 17;
// A RAM row is two 512-bit segments side by side, so two beats: beat k of a
// slot is segment k%2 of the slot's row k/2.
localparam integer RAM_SEG_COUNT  = 2;
localparam integer RAM_SEG_DATA_WIDTH = 512;
localparam integer RAM_SEG_BE_WIDTH   = RAM_SEG_DATA_WIDTH/8;
localparam integer RAM_SEG_ADDR_WIDTH = RAM_ADDR_WIDTH - $clog2(RAM_SEG_COUNT*RAM_SEG_BE_WIDTH);

// A proposal slot IS a frame IS a page.
localparam integer SLOT_BYTES = 4096;
localparam integer SLOT_COUNT = 8;
localparam integer BEAT_BYTES = RAM_SEG_BE_WIDTH;                 // 64: a beat is a segment
localparam integer ROW_BYTES  = RAM_SEG_COUNT*RAM_SEG_BE_WIDTH;   // 128
localparam integer SLOT_BEATS = SLOT_BYTES/BEAT_BYTES;            // 64
localparam integer SLOT_ROWS  = SLOT_BYTES/ROW_BYTES;             // 32
localparam integer FRAG_BYTES = SLOT_BYTES - BEAT_BYTES;          // 4032
localparam integer FRAG_BEATS = SLOT_BEATS - 1;                   // 63

// Speculative delivery geometry, mirroring the wrapper's own arithmetic.
// Recomputed here rather than read out of the DUT so that a change to either
// side has to be made on both; A2 then checks the two agree.
localparam integer PAY_SLOT_COUNT    = 16;
localparam integer ROUND_DEPTH       = 4;
localparam integer HOST_DEPTH_LOG2   = 8;
localparam integer VERDICT_DEPTH_LOG2= 8;
localparam integer REGION_SHIFT      = $clog2(FRAGS_PER_ROUND * SLOT_BYTES);   // 15
localparam integer REGION_PAGES      = (1 << REGION_SHIFT) / SLOT_BYTES;      // 8

// Transmit tags. Corundum's tx_engine tags every host frame {1, descriptor
// index}: the TOP bit set, the index in the low 5 bits, and it acts only on a
// completion with the top bit set. SSR's frames carry 0x4000 - top bit clear -
// and ssr_tx_mux takes a completion as SSR's only on that exact tag.
localparam [15:0]  SSR_TX_CPL_TAG = 16'h4000;
// Pages go on the data DMA with tags 0..15, the verdict record on the control
// DMA with tag 0. Each path has its own status stream and its own RAM read
// port, so the tags cannot collide and neither needs a ram_sel.
localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_PAY_BASE = 0;
localparam [DMA_TAG_WIDTH-1:0] DMA_TAG_VERDICT  = 0;
localparam [RAM_SEL_WIDTH-1:0] RAM_SEL_PAYLOAD  = 1'b0;
localparam [RAM_SEL_WIDTH-1:0] RAM_SEL_VERDICT  = 1'b0;

// Host memory. The three regions are far apart so a descriptor pointed at the
// wrong one is obvious in the log.
localparam [63:0] PROP_RING_BASE = 64'h0000_0000_2000_0000; // the proposal ring, read by the NIC
localparam integer PROP_DEPTH_LOG2 = 4;                      // 16 entries: the B and G tests wrap it
localparam [63:0] PAYLOAD_BASE = 64'h0000_0009_0000_0000;   // the payload ring
localparam [63:0] VERDICT_BASE = 64'h0000_000A_0000_0000;   // the verdict ring

localparam [15:0] SSR_ETHERTYPE_TB = 16'h88B5;   // -> ssr_rx_engine
localparam [15:0] DMA_ETHERTYPE_TB = 16'h88B6;   // -> the host
localparam [15:0] JUNK_ETHERTYPE   = 16'h0800;   // -> the host too, now

localparam [47:0] BCAST_MAC = 48'hFF_FF_FF_FF_FF_FF;

localparam [31:0] RUN_ID_A = 32'h0000_0077;
localparam [31:0] RUN_ID_B = 32'h0000_0078;   // the run after the reboot in H3

`include "ssr_packet.vh"
`include "ssr_verdict.vh"


// ############################################################################
//                      SECTION 2 - REGISTER MAP
// ############################################################################
// ssr_csr's map, one 4 KiB page (rtl/ssr_csr.v has the table).

// ---- identity and geometry ----
localparam [23:0] REG_TYPE             = 24'h000;
localparam [23:0] REG_VERSION          = 24'h004;
localparam [23:0] REG_SCRATCH          = 24'h00C;
localparam [23:0] REG_NODE             = 24'h010;
localparam [23:0] REG_ROUND_NS         = 24'h014;
localparam [23:0] REG_GEOMETRY         = 24'h018;
localparam [23:0] REG_PAGE_BYTES       = 24'h01C;
localparam [23:0] REG_FAULT            = 24'h020;

// ---- consensus (ssr_core) ----
localparam [23:0] REG_CORE_CONTROL     = 24'h100;
localparam [23:0] REG_CORE_STATUS      = 24'h104;
localparam [23:0] REG_CFG_RUN_ID       = 24'h108;
localparam [23:0] REG_CFG_MEMBERSHIP   = 24'h10C;
localparam [23:0] REG_CFG_EFF_ROUND_LO = 24'h110;
localparam [23:0] REG_CFG_EFF_ROUND_HI = 24'h114;
localparam [23:0] REG_CUR_ROUND_LO     = 24'h118;
localparam [23:0] REG_CUR_ROUND_HI     = 24'h11C;
localparam [23:0] REG_CUR_RUN_ID       = 24'h120;
localparam [23:0] REG_CUR_SOUND_SET    = 24'h124;
localparam [23:0] REG_HALT_REASON      = 24'h140;
localparam [23:0] REG_HALT_WITNESS     = 24'h14C;
localparam [23:0] REG_HALT_SOUND_SET   = 24'h154;

// ---- the proposal ring (ssr_proposal_dma_reader) ----
localparam [23:0] REG_PROP_CONTROL     = 24'h200;
localparam [23:0] REG_PROP_STATUS      = 24'h204;
localparam [23:0] REG_PROP_ERROR_CODE  = 24'h208;
localparam [23:0] REG_PROP_DEPTH_LOG2  = 24'h20C;
localparam [23:0] REG_PROP_BASE_LO     = 24'h210;
localparam [23:0] REG_PROP_BASE_HI     = 24'h214;
localparam [23:0] REG_PROP_PRODUCER    = 24'h218;
localparam [23:0] REG_PROP_CONSUMER    = 24'h21C;
localparam [23:0] REG_PROP_FETCH       = 24'h220;

// ---- delivery ----
localparam [23:0] REG_DLV_CONTROL      = 24'h300;
localparam [23:0] REG_DLV_STATUS       = 24'h304;
localparam [23:0] REG_PAY_BASE_LO      = 24'h308;
localparam [23:0] REG_PAY_BASE_HI      = 24'h30C;
localparam [23:0] REG_VER_BASE_LO      = 24'h310;
localparam [23:0] REG_VER_BASE_HI      = 24'h314;
localparam [23:0] REG_SEQ_LO           = 24'h318;
localparam [23:0] REG_SEQ_HI           = 24'h31C;

// ---- counters ----
localparam [23:0] REG_ROUND_COUNT_LO   = 24'h400;
localparam [23:0] REG_COMMIT_COUNT_LO  = 24'h408;
localparam [23:0] REG_HALT_COUNT       = 24'h410;
localparam [23:0] REG_TX_CTRL_FRAMES   = 24'h440;
localparam [23:0] REG_TX_PAY_FRAMES    = 24'h444;
localparam [23:0] REG_TX_EMPTY         = 24'h448;
localparam [23:0] REG_TX_OVERRUN       = 24'h44C;
localparam [23:0] REG_TX_MISSED        = 24'h450;
localparam [23:0] REG_TX_HOST_FRAMES   = 24'h454;
localparam [23:0] REG_TX_CPL_COUNT     = 24'h458;
localparam [23:0] REG_TX_CPL_TS_0      = 24'h45C;
localparam [23:0] REG_TX_CPL_TS_1      = 24'h460;
localparam [23:0] REG_TX_CPL_TS_2      = 24'h464;
localparam [23:0] REG_RX_FRAMES        = 24'h480;
localparam [23:0] REG_RX_ACCEPT        = 24'h484;
localparam [23:0] REG_RX_CTRL          = 24'h488;
localparam [23:0] REG_RX_MALFORMED     = 24'h48C;
localparam [23:0] REG_RX_CTRL_LATE     = 24'h490;
localparam [23:0] REG_RX_WINDOW_DROP   = 24'h494;
localparam [23:0] REG_RX_MEMBER_DROP   = 24'h498;
localparam [23:0] REG_RX_SOUND_DROP    = 24'h49C;
localparam [23:0] REG_RX_RUN_DROP      = 24'h4A0;
localparam [23:0] REG_RX_ROUND_DROP    = 24'h4A4;
localparam [23:0] REG_RX_STALL         = 24'h4A8;
localparam [23:0] REG_RX_HOST_FRAMES   = 24'h4AC;
localparam [23:0] REG_RX_ACK_DISAGREE  = 24'h4B0;
localparam [23:0] REG_PROP_READS       = 24'h4C0;
localparam [23:0] REG_PROP_READ_ERRORS = 24'h4C4;
localparam [23:0] REG_STAGE_PUSH       = 24'h500;
localparam [23:0] REG_STAGE_FULL       = 24'h504;
localparam [23:0] REG_PAY_DESC         = 24'h508;
localparam [23:0] REG_PAY_CPL          = 24'h50C;
localparam [23:0] REG_PAY_ERR          = 24'h510;
localparam [23:0] REG_PAY_STARVE       = 24'h514;
localparam [23:0] REG_PRES_LATE        = 24'h51C;
localparam [23:0] REG_PRES_ERR         = 24'h520;
localparam [23:0] REG_PRES_ERR_MISS    = 24'h524;
localparam [23:0] REG_VERDICT_RECORDS  = 24'h528;
localparam [23:0] REG_VERDICT_ERR      = 24'h52C;
localparam [23:0] REG_VERDICT_OVERFLOW = 24'h530;
localparam [23:0] REG_VERDICT_STALE    = 24'h534;

localparam [31:0] PROP_CTRL_ENABLE      = 32'h0000_0001;
localparam [31:0] PROP_CTRL_FLUSH       = 32'h0000_0002;
localparam [31:0] PROP_CTRL_CLEAR_ERROR = 32'h0000_0004;
// STATUS bits
localparam integer PROP_ST_IDLE    = 1;
localparam integer PROP_ST_ERROR   = 2;
localparam integer PROP_ST_PENDING = 3;


localparam [31:0] DLV_CTRL_PAYLOAD = 32'h0000_0001;
localparam [31:0] DLV_CTRL_VERDICT = 32'h0000_0002;
localparam [31:0] DLV_CTRL_BOTH    = 32'h0000_0003;


localparam [31:0] CORE_CTRL_ENABLE   = 32'h0000_0001;
localparam [31:0] CORE_CTRL_ACTIVATE = 32'h0000_0003;   // enable | activate
localparam [31:0] CORE_CTRL_REBOOT   = 32'h0000_0005;   // enable | reboot


// ############################################################################
//              SECTION 3 - CLOCK, RESET, TIME OF DAY
// ############################################################################

reg clk = 1'b0, rst = 1'b1;
always #(CLK_PERIOD_NS/2.0) clk = ~clk;

reg [47:0] time_seconds     = 48'd11;
reg [31:0] time_nanoseconds = 32'd0;
reg        time_advancing   = 1'b0;
always @(posedge clk) if (time_advancing) begin
    if (time_nanoseconds + CLK_PERIOD_NS >= 32'd1_000_000_000) begin
        time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS - 32'd1_000_000_000;
        time_seconds     <= time_seconds + 48'd1;
    end else time_nanoseconds <= time_nanoseconds + CLK_PERIOD_NS;
end

// What mqnic_ptp drives, synchronised to clk:
//   ptp_sync_ts_tod  96 bits {sec[47:0], ns[31:0], fns[15:0]} - the core's time
//   ptp_sync_ts_rel  64 bits {ns[47:0], fns[15:0]}            - not used by SSR
// and the interface timestamps (completions, rx tuser) are PTP_TS_WIDTH = 48
// bits of relative time, {ns[31:0], fns[15:0]}.
wire [95:0]             ptp_ts_tod = {time_seconds, time_nanoseconds, 16'd0};
wire [47:0]             ptp_ns_all = time_seconds * 48'd1_000_000_000 + time_nanoseconds;
wire [63:0]             ptp_ts_rel = {ptp_ns_all, 16'd0};
wire [PTP_TS_WIDTH-1:0] port_ts    = {time_nanoseconds, 16'd0};


// ############################################################################
//              SECTION 4 - SCOREBOARD PRIMITIVES
// ############################################################################

integer checks = 0, errors = 0;

// Where the run is, for the waveform. test_number steps at every banner;
// test_name holds the banner's title as ASCII. It is a packed vector rather
// than a `string` because Icarus does not dump string variables into a VCD
// or FST: add tb_ssr_dataplane.test_name and set its format to ASCII.
// 160 characters is longer than any title (the longest is ~110).
integer         test_number = 0;
reg [8*160-1:0] test_name   = "(reset)";

task check(input condition, input string message);
begin
    checks = checks + 1;
    if (!condition) begin
        errors = errors + 1;
        $display("[%0t] ERROR: %0s", $realtime, message);
    end
end
endtask

task banner(input string title);
begin
    test_number = test_number + 1;
    $sformat(test_name, "%0s", title);   // a string cannot be assigned to a vector directly
    $display("");
    $display("[%0t] ---- %0s", $realtime, title);
end
endtask

task wait_rounds(input integer n);
begin
    repeat (n*ROUND_CYCLES) @(posedge clk);
end
endtask

// Land in the quiet middle of a round: the peers have spoken and the next
// boundary is half a round away.
task goto_midround;
begin
    @(posedge dut.round_start_pulse);
    repeat (ROUND_CYCLES/2) @(posedge clk);
end
endtask


// ############################################################################
//                          SECTION 5 - CSR BUS
// ############################################################################

reg  [REG_ADDR_WIDTH-1:0] csr_addr  = 24'd0;
reg  [REG_DATA_WIDTH-1:0] csr_wdata = 32'd0;
reg                       csr_wr_en = 1'b0;
reg                       csr_rd_en = 1'b0;
wire [REG_DATA_WIDTH-1:0] csr_rdata;
wire                      csr_wr_ack, csr_rd_ack, csr_wr_wait, csr_rd_wait;

task csr_write(input [23:0] a, input [31:0] d);
    integer g;
begin
    @(negedge clk); csr_addr = a; csr_wdata = d; csr_wr_en = 1'b1; g = 0;
    while (g < 32) begin @(posedge clk); #0.1; if (csr_wr_ack) g = 99; else g = g + 1; end
    @(negedge clk); csr_wr_en = 1'b0;
    if (g != 99) begin
        errors = errors + 1;
        $display("[%0t] ERROR: CSR write to %06h never acked", $realtime, a);
    end
end
endtask

task csr_read(input [23:0] a, output [31:0] d);
    integer g;
begin
    @(negedge clk); csr_addr = a; csr_rd_en = 1'b1; g = 0; d = 32'hDEAD_BEEF;
    while (g < 32) begin @(posedge clk); #0.1; if (csr_rd_ack) begin d = csr_rdata; g = 99; end else g = g + 1; end
    @(negedge clk); csr_rd_en = 1'b0;
    if (g != 99) begin
        errors = errors + 1;
        $display("[%0t] ERROR: CSR read from %06h never acked", $realtime, a);
    end
end
endtask

task csr_expect(input [23:0] a, input [31:0] want, input string name);
    reg [31:0] got;
begin
    csr_read(a, got);
    check(got == want, $sformatf("%0s reads %0d, expected %0d", name, got, want));
end
endtask


// ############################################################################
//                          SECTION 6 - DUT SIGNALS
// ############################################################################

// ---- proposal DMA read (wrapper -> engine) ----
wire [DMA_ADDR_WIDTH-1:0] rd_desc_dma_addr;
wire [RAM_SEL_WIDTH-1:0]  rd_desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0] rd_desc_ram_addr;
wire [DMA_LEN_WIDTH-1:0]  rd_desc_len;
wire [DMA_TAG_WIDTH-1:0]  rd_desc_tag;
wire                      rd_desc_valid;
reg                       rd_desc_ready = 1'b1;

reg  [DMA_TAG_WIDTH-1:0]  rd_status_tag   = {DMA_TAG_WIDTH{1'b0}};
reg  [3:0]                rd_status_error = 4'd0;
reg                       rd_status_valid = 1'b0;

// ---- data DMA write (wrapper -> engine): pages ----
wire [DMA_ADDR_WIDTH-1:0] wr_desc_dma_addr;
wire [RAM_SEL_WIDTH-1:0]  wr_desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0] wr_desc_ram_addr;
wire [DMA_LEN_WIDTH-1:0]  wr_desc_len;
wire [DMA_TAG_WIDTH-1:0]  wr_desc_tag;
wire                      wr_desc_valid;
reg                       wr_desc_ready = 1'b1;

reg  [DMA_TAG_WIDTH-1:0]  wr_status_tag   = {DMA_TAG_WIDTH{1'b0}};
reg  [3:0]                wr_status_error = 4'd0;
reg                       wr_status_valid = 1'b0;

// ---- control DMA write (wrapper -> engine): verdict records ----
wire [DMA_ADDR_WIDTH-1:0] cwr_desc_dma_addr;
wire [RAM_SEL_WIDTH-1:0]  cwr_desc_ram_sel;
wire [RAM_ADDR_WIDTH-1:0] cwr_desc_ram_addr;
wire [DMA_LEN_WIDTH-1:0]  cwr_desc_len;
wire [DMA_TAG_WIDTH-1:0]  cwr_desc_tag;
wire                      cwr_desc_valid;
reg                       cwr_desc_ready = 1'b1;

reg  [DMA_TAG_WIDTH-1:0]  cwr_status_tag   = {DMA_TAG_WIDTH{1'b0}};
reg  [3:0]                cwr_status_error = 4'd0;
reg                       cwr_status_valid = 1'b0;

// ---- the segmented RAM write port, used by the proposal engine ----
reg  [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      wr_sel   = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_BE_WIDTH-1:0]   wr_be    = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] wr_data  = {RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] wr_addr  = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT-1:0]                    wr_valid = {RAM_SEG_COUNT{1'b0}};
wire [RAM_SEG_COUNT-1:0]                    wr_ready, wr_done;

// ---- the two segmented RAM read ports, used by the write engine ----
// The data DMA's (cram_*) reads pages from the staging RAM; the control DMA's
// (ccram_*) reads the verdict record. ram_sel is driven as the descriptor
// carried it, 0 on both; the wrapper does not look at it.
reg  [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      cram_rd_sel   = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] cram_rd_addr  = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT-1:0]                    cram_rd_valid = {RAM_SEG_COUNT{1'b0}};
wire [RAM_SEG_COUNT-1:0]                    cram_rd_ready;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] cram_rd_data;
wire [RAM_SEG_COUNT-1:0]                    cram_rd_resp_valid;

reg  [RAM_SEG_COUNT*RAM_SEL_WIDTH-1:0]      ccram_rd_sel   = {RAM_SEG_COUNT*RAM_SEL_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH-1:0] ccram_rd_addr  = {RAM_SEG_COUNT*RAM_SEG_ADDR_WIDTH{1'b0}};
reg  [RAM_SEG_COUNT-1:0]                    ccram_rd_valid = {RAM_SEG_COUNT{1'b0}};
wire [RAM_SEG_COUNT-1:0]                    ccram_rd_ready;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] ccram_rd_data;
wire [RAM_SEG_COUNT-1:0]                    ccram_rd_resp_valid;

// ---- transmit: host -> wrapper ----
reg  [AXIS_DATA_WIDTH-1:0]    host_tx_tdata  = {AXIS_DATA_WIDTH{1'b0}};
reg  [AXIS_KEEP_WIDTH-1:0]    host_tx_tkeep  = {AXIS_KEEP_WIDTH{1'b0}};
reg                           host_tx_tvalid = 1'b0;
wire                          host_tx_tready;
reg                           host_tx_tlast  = 1'b0;
reg  [AXIS_TX_ID_WIDTH-1:0]   host_tx_tid    = {AXIS_TX_ID_WIDTH{1'b0}};
reg  [AXIS_TX_DEST_WIDTH-1:0] host_tx_tdest  = {AXIS_TX_DEST_WIDTH{1'b0}};
reg  [AXIS_TX_USER_WIDTH-1:0] host_tx_tuser  = {AXIS_TX_USER_WIDTH{1'b0}};

// ---- transmit: wrapper -> port ----
wire [AXIS_DATA_WIDTH-1:0]    port_tx_tdata;
wire [AXIS_KEEP_WIDTH-1:0]    port_tx_tkeep;
wire                          port_tx_tvalid;
reg                           port_tx_tready = 1'b1;
wire                          port_tx_tlast;
wire [AXIS_TX_ID_WIDTH-1:0]   port_tx_tid;
wire [AXIS_TX_DEST_WIDTH-1:0] port_tx_tdest;
wire [AXIS_TX_USER_WIDTH-1:0] port_tx_tuser;

// ---- completions ----
reg  [PTP_TS_WIDTH-1:0]  port_cpl_ts    = {PTP_TS_WIDTH{1'b0}};
reg  [TX_TAG_WIDTH-1:0]  port_cpl_tag   = {TX_TAG_WIDTH{1'b0}};
reg                      port_cpl_valid = 1'b0;
wire                     port_cpl_ready;

wire [PTP_TS_WIDTH-1:0]  if_cpl_ts;
wire [TX_TAG_WIDTH-1:0]  if_cpl_tag;
wire                     if_cpl_valid;
reg                      if_cpl_ready = 1'b1;

// ---- receive: port -> wrapper ----
reg  [AXIS_DATA_WIDTH-1:0]    peer_tdata  = {AXIS_DATA_WIDTH{1'b0}};
reg  [AXIS_KEEP_WIDTH-1:0]    peer_tkeep  = {AXIS_KEEP_WIDTH{1'b0}};
reg                           peer_tvalid = 1'b0;
reg                           peer_tlast  = 1'b0;
reg  [AXIS_RX_USER_WIDTH-1:0] peer_tuser  = {AXIS_RX_USER_WIDTH{1'b0}};
wire                          peer_tready;

// ---- receive: wrapper -> host (the demux's other route) ----
wire [AXIS_DATA_WIDTH-1:0]    hostrx_tdata;
wire [AXIS_KEEP_WIDTH-1:0]    hostrx_tkeep;
wire                          hostrx_tvalid;
reg                           hostrx_tready = 1'b1;
wire                          hostrx_tlast;



// ---- the other interface: a plain NIC port the app block must not touch ----
// o<group>_s_* go into the app block on lane OTHER_IF, o<group>_m_* come out.
reg  [AXIS_DATA_WIDTH-1:0]       otx_s_tdata = 0;
reg  [AXIS_KEEP_WIDTH-1:0]       otx_s_tkeep = 0;
reg                              otx_s_tvalid = 0;
wire                             otx_s_tready;
reg                              otx_s_tlast = 0;
reg  [AXIS_TX_ID_WIDTH-1:0]      otx_s_tid = 0;
reg  [AXIS_TX_DEST_WIDTH-1:0]    otx_s_tdest = 0;
reg  [AXIS_TX_USER_WIDTH-1:0]    otx_s_tuser = 0;
wire [AXIS_DATA_WIDTH-1:0]       otx_m_tdata;
wire [AXIS_KEEP_WIDTH-1:0]       otx_m_tkeep;
wire                             otx_m_tvalid;
reg                              otx_m_tready = 0;
wire                             otx_m_tlast;
wire [AXIS_TX_ID_WIDTH-1:0]      otx_m_tid;
wire [AXIS_TX_DEST_WIDTH-1:0]    otx_m_tdest;
wire [AXIS_TX_USER_WIDTH-1:0]    otx_m_tuser;
reg  [PTP_TS_WIDTH-1:0]          ocpl_s_ts = 0;
reg  [TX_TAG_WIDTH-1:0]          ocpl_s_tag = 0;
reg                              ocpl_s_valid = 0;
wire                             ocpl_s_ready;
wire [PTP_TS_WIDTH-1:0]          ocpl_m_ts;
wire [TX_TAG_WIDTH-1:0]          ocpl_m_tag;
wire                             ocpl_m_valid;
reg                              ocpl_m_ready = 0;
reg  [AXIS_DATA_WIDTH-1:0]       orx_s_tdata = 0;
reg  [AXIS_KEEP_WIDTH-1:0]       orx_s_tkeep = 0;
reg                              orx_s_tvalid = 0;
wire                             orx_s_tready;
reg                              orx_s_tlast = 0;
reg  [AXIS_RX_ID_WIDTH-1:0]      orx_s_tid = 0;
reg  [AXIS_RX_DEST_WIDTH-1:0]    orx_s_tdest = 0;
reg  [AXIS_RX_USER_WIDTH-1:0]    orx_s_tuser = 0;
wire [AXIS_DATA_WIDTH-1:0]       orx_m_tdata;
wire [AXIS_KEEP_WIDTH-1:0]       orx_m_tkeep;
wire                             orx_m_tvalid;
reg                              orx_m_tready = 0;
wire                             orx_m_tlast;
wire [AXIS_RX_ID_WIDTH-1:0]      orx_m_tid;
wire [AXIS_RX_DEST_WIDTH-1:0]    orx_m_tdest;
wire [AXIS_RX_USER_WIDTH-1:0]    orx_m_tuser;

// ---- the IF_COUNT-lane buses the DUT sees ----
// The SSR lane carries the bench's host/port/peer signals above; the other
// lane carries o*_ above.
wire [IF_COUNT*AXIS_DATA_WIDTH-1:0]   dut_s_axis_if_tx_tdata;
wire [IF_COUNT*AXIS_KEEP_WIDTH-1:0]   dut_s_axis_if_tx_tkeep;
wire [IF_COUNT-1:0]                   dut_s_axis_if_tx_tvalid;
wire [IF_COUNT-1:0]                   dut_s_axis_if_tx_tready;
wire [IF_COUNT-1:0]                   dut_s_axis_if_tx_tlast;
wire [IF_COUNT*AXIS_TX_ID_WIDTH-1:0]  dut_s_axis_if_tx_tid;
wire [IF_COUNT*AXIS_TX_DEST_WIDTH-1:0] dut_s_axis_if_tx_tdest;
wire [IF_COUNT*AXIS_TX_USER_WIDTH-1:0] dut_s_axis_if_tx_tuser;
wire [IF_COUNT*AXIS_DATA_WIDTH-1:0]   dut_m_axis_if_tx_tdata;
wire [IF_COUNT*AXIS_KEEP_WIDTH-1:0]   dut_m_axis_if_tx_tkeep;
wire [IF_COUNT-1:0]                   dut_m_axis_if_tx_tvalid;
wire [IF_COUNT-1:0]                   dut_m_axis_if_tx_tready;
wire [IF_COUNT-1:0]                   dut_m_axis_if_tx_tlast;
wire [IF_COUNT*AXIS_TX_ID_WIDTH-1:0]  dut_m_axis_if_tx_tid;
wire [IF_COUNT*AXIS_TX_DEST_WIDTH-1:0] dut_m_axis_if_tx_tdest;
wire [IF_COUNT*AXIS_TX_USER_WIDTH-1:0] dut_m_axis_if_tx_tuser;
wire [IF_COUNT*PTP_TS_WIDTH-1:0]      dut_s_axis_if_tx_cpl_ts;
wire [IF_COUNT*TX_TAG_WIDTH-1:0]      dut_s_axis_if_tx_cpl_tag;
wire [IF_COUNT-1:0]                   dut_s_axis_if_tx_cpl_valid;
wire [IF_COUNT-1:0]                   dut_s_axis_if_tx_cpl_ready;
wire [IF_COUNT*PTP_TS_WIDTH-1:0]      dut_m_axis_if_tx_cpl_ts;
wire [IF_COUNT*TX_TAG_WIDTH-1:0]      dut_m_axis_if_tx_cpl_tag;
wire [IF_COUNT-1:0]                   dut_m_axis_if_tx_cpl_valid;
wire [IF_COUNT-1:0]                   dut_m_axis_if_tx_cpl_ready;
wire [IF_COUNT*AXIS_DATA_WIDTH-1:0]   dut_s_axis_if_rx_tdata;
wire [IF_COUNT*AXIS_KEEP_WIDTH-1:0]   dut_s_axis_if_rx_tkeep;
wire [IF_COUNT-1:0]                   dut_s_axis_if_rx_tvalid;
wire [IF_COUNT-1:0]                   dut_s_axis_if_rx_tready;
wire [IF_COUNT-1:0]                   dut_s_axis_if_rx_tlast;
wire [IF_COUNT*AXIS_RX_ID_WIDTH-1:0]  dut_s_axis_if_rx_tid;
wire [IF_COUNT*AXIS_RX_DEST_WIDTH-1:0] dut_s_axis_if_rx_tdest;
wire [IF_COUNT*AXIS_RX_USER_WIDTH-1:0] dut_s_axis_if_rx_tuser;
wire [IF_COUNT*AXIS_DATA_WIDTH-1:0]   dut_m_axis_if_rx_tdata;
wire [IF_COUNT*AXIS_KEEP_WIDTH-1:0]   dut_m_axis_if_rx_tkeep;
wire [IF_COUNT-1:0]                   dut_m_axis_if_rx_tvalid;
wire [IF_COUNT-1:0]                   dut_m_axis_if_rx_tready;
wire [IF_COUNT-1:0]                   dut_m_axis_if_rx_tlast;
wire [IF_COUNT*AXIS_RX_ID_WIDTH-1:0]  dut_m_axis_if_rx_tid;
wire [IF_COUNT*AXIS_RX_DEST_WIDTH-1:0] dut_m_axis_if_rx_tdest;
wire [IF_COUNT*AXIS_RX_USER_WIDTH-1:0] dut_m_axis_if_rx_tuser;

assign dut_s_axis_if_tx_tdata[SSR_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] = host_tx_tdata;
assign dut_s_axis_if_tx_tdata[OTHER_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] = otx_s_tdata;
assign dut_s_axis_if_tx_tkeep[SSR_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH] = host_tx_tkeep;
assign dut_s_axis_if_tx_tkeep[OTHER_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH] = otx_s_tkeep;
assign dut_s_axis_if_tx_tvalid[SSR_IF] = host_tx_tvalid;
assign dut_s_axis_if_tx_tvalid[OTHER_IF] = otx_s_tvalid;
assign host_tx_tready = dut_s_axis_if_tx_tready[SSR_IF];
assign otx_s_tready = dut_s_axis_if_tx_tready[OTHER_IF];
assign dut_s_axis_if_tx_tlast[SSR_IF] = host_tx_tlast;
assign dut_s_axis_if_tx_tlast[OTHER_IF] = otx_s_tlast;
assign dut_s_axis_if_tx_tid[SSR_IF*AXIS_TX_ID_WIDTH +: AXIS_TX_ID_WIDTH] = host_tx_tid;
assign dut_s_axis_if_tx_tid[OTHER_IF*AXIS_TX_ID_WIDTH +: AXIS_TX_ID_WIDTH] = otx_s_tid;
assign dut_s_axis_if_tx_tdest[SSR_IF*AXIS_TX_DEST_WIDTH +: AXIS_TX_DEST_WIDTH] = host_tx_tdest;
assign dut_s_axis_if_tx_tdest[OTHER_IF*AXIS_TX_DEST_WIDTH +: AXIS_TX_DEST_WIDTH] = otx_s_tdest;
assign dut_s_axis_if_tx_tuser[SSR_IF*AXIS_TX_USER_WIDTH +: AXIS_TX_USER_WIDTH] = host_tx_tuser;
assign dut_s_axis_if_tx_tuser[OTHER_IF*AXIS_TX_USER_WIDTH +: AXIS_TX_USER_WIDTH] = otx_s_tuser;
assign port_tx_tdata = dut_m_axis_if_tx_tdata[SSR_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH];
assign otx_m_tdata = dut_m_axis_if_tx_tdata[OTHER_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH];
assign port_tx_tkeep = dut_m_axis_if_tx_tkeep[SSR_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH];
assign otx_m_tkeep = dut_m_axis_if_tx_tkeep[OTHER_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH];
assign port_tx_tvalid = dut_m_axis_if_tx_tvalid[SSR_IF];
assign otx_m_tvalid = dut_m_axis_if_tx_tvalid[OTHER_IF];
assign dut_m_axis_if_tx_tready[SSR_IF] = port_tx_tready;
assign dut_m_axis_if_tx_tready[OTHER_IF] = otx_m_tready;
assign port_tx_tlast = dut_m_axis_if_tx_tlast[SSR_IF];
assign otx_m_tlast = dut_m_axis_if_tx_tlast[OTHER_IF];
assign port_tx_tid = dut_m_axis_if_tx_tid[SSR_IF*AXIS_TX_ID_WIDTH +: AXIS_TX_ID_WIDTH];
assign otx_m_tid = dut_m_axis_if_tx_tid[OTHER_IF*AXIS_TX_ID_WIDTH +: AXIS_TX_ID_WIDTH];
assign port_tx_tdest = dut_m_axis_if_tx_tdest[SSR_IF*AXIS_TX_DEST_WIDTH +: AXIS_TX_DEST_WIDTH];
assign otx_m_tdest = dut_m_axis_if_tx_tdest[OTHER_IF*AXIS_TX_DEST_WIDTH +: AXIS_TX_DEST_WIDTH];
assign port_tx_tuser = dut_m_axis_if_tx_tuser[SSR_IF*AXIS_TX_USER_WIDTH +: AXIS_TX_USER_WIDTH];
assign otx_m_tuser = dut_m_axis_if_tx_tuser[OTHER_IF*AXIS_TX_USER_WIDTH +: AXIS_TX_USER_WIDTH];
assign dut_s_axis_if_tx_cpl_ts[SSR_IF*PTP_TS_WIDTH +: PTP_TS_WIDTH] = port_cpl_ts;
assign dut_s_axis_if_tx_cpl_ts[OTHER_IF*PTP_TS_WIDTH +: PTP_TS_WIDTH] = ocpl_s_ts;
assign dut_s_axis_if_tx_cpl_tag[SSR_IF*TX_TAG_WIDTH +: TX_TAG_WIDTH] = port_cpl_tag;
assign dut_s_axis_if_tx_cpl_tag[OTHER_IF*TX_TAG_WIDTH +: TX_TAG_WIDTH] = ocpl_s_tag;
assign dut_s_axis_if_tx_cpl_valid[SSR_IF] = port_cpl_valid;
assign dut_s_axis_if_tx_cpl_valid[OTHER_IF] = ocpl_s_valid;
assign port_cpl_ready = dut_s_axis_if_tx_cpl_ready[SSR_IF];
assign ocpl_s_ready = dut_s_axis_if_tx_cpl_ready[OTHER_IF];
assign if_cpl_ts = dut_m_axis_if_tx_cpl_ts[SSR_IF*PTP_TS_WIDTH +: PTP_TS_WIDTH];
assign ocpl_m_ts = dut_m_axis_if_tx_cpl_ts[OTHER_IF*PTP_TS_WIDTH +: PTP_TS_WIDTH];
assign if_cpl_tag = dut_m_axis_if_tx_cpl_tag[SSR_IF*TX_TAG_WIDTH +: TX_TAG_WIDTH];
assign ocpl_m_tag = dut_m_axis_if_tx_cpl_tag[OTHER_IF*TX_TAG_WIDTH +: TX_TAG_WIDTH];
assign if_cpl_valid = dut_m_axis_if_tx_cpl_valid[SSR_IF];
assign ocpl_m_valid = dut_m_axis_if_tx_cpl_valid[OTHER_IF];
assign dut_m_axis_if_tx_cpl_ready[SSR_IF] = if_cpl_ready;
assign dut_m_axis_if_tx_cpl_ready[OTHER_IF] = ocpl_m_ready;
assign dut_s_axis_if_rx_tdata[SSR_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] = peer_tdata;
assign dut_s_axis_if_rx_tdata[OTHER_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH] = orx_s_tdata;
assign dut_s_axis_if_rx_tkeep[SSR_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH] = peer_tkeep;
assign dut_s_axis_if_rx_tkeep[OTHER_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH] = orx_s_tkeep;
assign dut_s_axis_if_rx_tvalid[SSR_IF] = peer_tvalid;
assign dut_s_axis_if_rx_tvalid[OTHER_IF] = orx_s_tvalid;
assign peer_tready = dut_s_axis_if_rx_tready[SSR_IF];
assign orx_s_tready = dut_s_axis_if_rx_tready[OTHER_IF];
assign dut_s_axis_if_rx_tlast[SSR_IF] = peer_tlast;
assign dut_s_axis_if_rx_tlast[OTHER_IF] = orx_s_tlast;
assign dut_s_axis_if_rx_tid[SSR_IF*AXIS_RX_ID_WIDTH +: AXIS_RX_ID_WIDTH] = {AXIS_RX_ID_WIDTH{1'b0}};
assign dut_s_axis_if_rx_tid[OTHER_IF*AXIS_RX_ID_WIDTH +: AXIS_RX_ID_WIDTH] = orx_s_tid;
assign dut_s_axis_if_rx_tdest[SSR_IF*AXIS_RX_DEST_WIDTH +: AXIS_RX_DEST_WIDTH] = {AXIS_RX_DEST_WIDTH{1'b0}};
assign dut_s_axis_if_rx_tdest[OTHER_IF*AXIS_RX_DEST_WIDTH +: AXIS_RX_DEST_WIDTH] = orx_s_tdest;
assign dut_s_axis_if_rx_tuser[SSR_IF*AXIS_RX_USER_WIDTH +: AXIS_RX_USER_WIDTH] = peer_tuser;
assign dut_s_axis_if_rx_tuser[OTHER_IF*AXIS_RX_USER_WIDTH +: AXIS_RX_USER_WIDTH] = orx_s_tuser;
assign hostrx_tdata = dut_m_axis_if_rx_tdata[SSR_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH];
assign orx_m_tdata = dut_m_axis_if_rx_tdata[OTHER_IF*AXIS_DATA_WIDTH +: AXIS_DATA_WIDTH];
assign hostrx_tkeep = dut_m_axis_if_rx_tkeep[SSR_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH];
assign orx_m_tkeep = dut_m_axis_if_rx_tkeep[OTHER_IF*AXIS_KEEP_WIDTH +: AXIS_KEEP_WIDTH];
assign hostrx_tvalid = dut_m_axis_if_rx_tvalid[SSR_IF];
assign orx_m_tvalid = dut_m_axis_if_rx_tvalid[OTHER_IF];
assign dut_m_axis_if_rx_tready[SSR_IF] = hostrx_tready;
assign dut_m_axis_if_rx_tready[OTHER_IF] = orx_m_tready;
assign hostrx_tlast = dut_m_axis_if_rx_tlast[SSR_IF];
assign orx_m_tlast = dut_m_axis_if_rx_tlast[OTHER_IF];
assign orx_m_tid = dut_m_axis_if_rx_tid[OTHER_IF*AXIS_RX_ID_WIDTH +: AXIS_RX_ID_WIDTH];
assign orx_m_tdest = dut_m_axis_if_rx_tdest[OTHER_IF*AXIS_RX_DEST_WIDTH +: AXIS_RX_DEST_WIDTH];
assign orx_m_tuser = dut_m_axis_if_rx_tuser[OTHER_IF*AXIS_RX_USER_WIDTH +: AXIS_RX_USER_WIDTH];


// ############################################################################
//                          SECTION 7 - DUT
// ############################################################################

ssr_dataplane #(
    .REG_ADDR_WIDTH(REG_ADDR_WIDTH),
    .REG_DATA_WIDTH(REG_DATA_WIDTH),
    .IF_COUNT(IF_COUNT),
    .SSR_IF_INDEX(SSR_IF),
    .PORTS_PER_IF(1),
    .PTP_TS_ENABLE(1),
    .PTP_TS_FMT_TOD(0),
    .PTP_TS_WIDTH(PTP_TS_WIDTH),
    .TX_TAG_WIDTH(TX_TAG_WIDTH),
    .DMA_ADDR_WIDTH(DMA_ADDR_WIDTH),
    .DMA_LEN_WIDTH(DMA_LEN_WIDTH),
    .DMA_TAG_WIDTH(DMA_TAG_WIDTH),
    .RAM_SEL_WIDTH(RAM_SEL_WIDTH),
    .RAM_ADDR_WIDTH(RAM_ADDR_WIDTH),
    .RAM_SEG_COUNT(RAM_SEG_COUNT),
    .RAM_SEG_DATA_WIDTH(RAM_SEG_DATA_WIDTH),
    .RAM_BUFF_SLOT_BYTES(SLOT_BYTES),
    .RAM_BUFF_SLOT_COUNT(SLOT_COUNT),
    .AXIS_IF_DATA_WIDTH(AXIS_DATA_WIDTH),
    .AXIS_IF_TX_ID_WIDTH(AXIS_TX_ID_WIDTH),
    .AXIS_IF_TX_DEST_WIDTH(AXIS_TX_DEST_WIDTH),
    .AXIS_IF_TX_USER_WIDTH(AXIS_TX_USER_WIDTH),
    .AXIS_IF_RX_ID_WIDTH(AXIS_RX_ID_WIDTH),
    .AXIS_IF_RX_DEST_WIDTH(AXIS_RX_DEST_WIDTH),
    .AXIS_IF_RX_USER_WIDTH(AXIS_RX_USER_WIDTH),
    .P_NODE_ID(NODE_ID),
    .P_NODE_COUNT(NODE_COUNT),
    .P_SLOT_DURATION_NS(ROUND_LENGTH_NS),
    .P_GUARD_NS(GUARD_TIME_NS),
    .P_CTRL_PERIOD_NS(CTRL_PERIOD_NS),
    .P_FRAGS_PER_ROUND(FRAGS_PER_ROUND),
    .P_PAY_SLOT_COUNT(PAY_SLOT_COUNT),
    .P_ROUND_DEPTH(ROUND_DEPTH),
    .P_HOST_DEPTH_LOG2(HOST_DEPTH_LOG2),
    .P_VERDICT_DEPTH_LOG2(VERDICT_DEPTH_LOG2)
) dut (
    .clk(clk),
    .rst(rst),

    .reg_wr_addr(csr_addr), .reg_wr_data(csr_wdata), .reg_wr_strb(4'hF),
    .reg_wr_en(csr_wr_en), .reg_wr_wait(csr_wr_wait), .reg_wr_ack(csr_wr_ack),
    .reg_rd_addr(csr_addr), .reg_rd_en(csr_rd_en),
    .reg_rd_data(csr_rdata), .reg_rd_wait(csr_rd_wait), .reg_rd_ack(csr_rd_ack),

    .m_axis_data_dma_read_desc_dma_addr(rd_desc_dma_addr),
    .m_axis_data_dma_read_desc_ram_sel(rd_desc_ram_sel),
    .m_axis_data_dma_read_desc_ram_addr(rd_desc_ram_addr),
    .m_axis_data_dma_read_desc_len(rd_desc_len),
    .m_axis_data_dma_read_desc_tag(rd_desc_tag),
    .m_axis_data_dma_read_desc_valid(rd_desc_valid),
    .m_axis_data_dma_read_desc_ready(rd_desc_ready),

    .s_axis_data_dma_read_desc_status_tag(rd_status_tag),
    .s_axis_data_dma_read_desc_status_error(rd_status_error),
    .s_axis_data_dma_read_desc_status_valid(rd_status_valid),

    .m_axis_data_dma_write_desc_dma_addr(wr_desc_dma_addr),
    .m_axis_data_dma_write_desc_ram_sel(wr_desc_ram_sel),
    .m_axis_data_dma_write_desc_ram_addr(wr_desc_ram_addr),
    .m_axis_data_dma_write_desc_imm(),
    .m_axis_data_dma_write_desc_imm_en(),
    .m_axis_data_dma_write_desc_len(wr_desc_len),
    .m_axis_data_dma_write_desc_tag(wr_desc_tag),
    .m_axis_data_dma_write_desc_valid(wr_desc_valid),
    .m_axis_data_dma_write_desc_ready(wr_desc_ready),

    .s_axis_data_dma_write_desc_status_tag(wr_status_tag),
    .s_axis_data_dma_write_desc_status_error(wr_status_error),
    .s_axis_data_dma_write_desc_status_valid(wr_status_valid),

    .data_dma_ram_wr_cmd_sel(wr_sel),
    .data_dma_ram_wr_cmd_be(wr_be),
    .data_dma_ram_wr_cmd_addr(wr_addr),
    .data_dma_ram_wr_cmd_data(wr_data),
    .data_dma_ram_wr_cmd_valid(wr_valid),
    .data_dma_ram_wr_cmd_ready(wr_ready),
    .data_dma_ram_wr_done(wr_done),

    .data_dma_ram_rd_cmd_sel(cram_rd_sel),
    .data_dma_ram_rd_cmd_addr(cram_rd_addr),
    .data_dma_ram_rd_cmd_valid(cram_rd_valid),
    .data_dma_ram_rd_cmd_ready(cram_rd_ready),
    .data_dma_ram_rd_resp_data(cram_rd_data),
    .data_dma_ram_rd_resp_valid(cram_rd_resp_valid),
    .data_dma_ram_rd_resp_ready({RAM_SEG_COUNT{1'b1}}),

    .m_axis_ctrl_dma_write_desc_dma_addr(cwr_desc_dma_addr),
    .m_axis_ctrl_dma_write_desc_ram_sel(cwr_desc_ram_sel),
    .m_axis_ctrl_dma_write_desc_ram_addr(cwr_desc_ram_addr),
    .m_axis_ctrl_dma_write_desc_imm(),
    .m_axis_ctrl_dma_write_desc_imm_en(),
    .m_axis_ctrl_dma_write_desc_len(cwr_desc_len),
    .m_axis_ctrl_dma_write_desc_tag(cwr_desc_tag),
    .m_axis_ctrl_dma_write_desc_valid(cwr_desc_valid),
    .m_axis_ctrl_dma_write_desc_ready(cwr_desc_ready),

    .s_axis_ctrl_dma_write_desc_status_tag(cwr_status_tag),
    .s_axis_ctrl_dma_write_desc_status_error(cwr_status_error),
    .s_axis_ctrl_dma_write_desc_status_valid(cwr_status_valid),

    .ctrl_dma_ram_rd_cmd_sel(ccram_rd_sel),
    .ctrl_dma_ram_rd_cmd_addr(ccram_rd_addr),
    .ctrl_dma_ram_rd_cmd_valid(ccram_rd_valid),
    .ctrl_dma_ram_rd_cmd_ready(ccram_rd_ready),
    .ctrl_dma_ram_rd_resp_data(ccram_rd_data),
    .ctrl_dma_ram_rd_resp_valid(ccram_rd_resp_valid),
    .ctrl_dma_ram_rd_resp_ready({RAM_SEG_COUNT{1'b1}}),

    .ptp_clk(clk), .ptp_rst(rst), .ptp_sample_clk(clk),
    .ptp_td_sd(1'b0), .ptp_pps(1'b0), .ptp_pps_str(1'b0),
    .ptp_sync_locked(1'b1),
    .ptp_sync_ts_rel(ptp_ts_rel), .ptp_sync_ts_rel_step(1'b0),
    .ptp_sync_ts_tod(ptp_ts_tod), .ptp_sync_ts_tod_step(1'b0),
    .ptp_sync_pps(1'b0), .ptp_sync_pps_str(1'b0),
    .ptp_perout_locked(1'b0), .ptp_perout_error(1'b0), .ptp_perout_pulse(1'b0),

    .s_axis_if_tx_tdata(dut_s_axis_if_tx_tdata),
    .s_axis_if_tx_tkeep(dut_s_axis_if_tx_tkeep),
    .s_axis_if_tx_tvalid(dut_s_axis_if_tx_tvalid),
    .s_axis_if_tx_tready(dut_s_axis_if_tx_tready),
    .s_axis_if_tx_tlast(dut_s_axis_if_tx_tlast),
    .s_axis_if_tx_tid(dut_s_axis_if_tx_tid),
    .s_axis_if_tx_tdest(dut_s_axis_if_tx_tdest),
    .s_axis_if_tx_tuser(dut_s_axis_if_tx_tuser),

    .m_axis_if_tx_tdata(dut_m_axis_if_tx_tdata),
    .m_axis_if_tx_tkeep(dut_m_axis_if_tx_tkeep),
    .m_axis_if_tx_tvalid(dut_m_axis_if_tx_tvalid),
    .m_axis_if_tx_tready(dut_m_axis_if_tx_tready),
    .m_axis_if_tx_tlast(dut_m_axis_if_tx_tlast),
    .m_axis_if_tx_tid(dut_m_axis_if_tx_tid),
    .m_axis_if_tx_tdest(dut_m_axis_if_tx_tdest),
    .m_axis_if_tx_tuser(dut_m_axis_if_tx_tuser),

    .s_axis_if_tx_cpl_ts(dut_s_axis_if_tx_cpl_ts),
    .s_axis_if_tx_cpl_tag(dut_s_axis_if_tx_cpl_tag),
    .s_axis_if_tx_cpl_valid(dut_s_axis_if_tx_cpl_valid),
    .s_axis_if_tx_cpl_ready(dut_s_axis_if_tx_cpl_ready),

    .m_axis_if_tx_cpl_ts(dut_m_axis_if_tx_cpl_ts),
    .m_axis_if_tx_cpl_tag(dut_m_axis_if_tx_cpl_tag),
    .m_axis_if_tx_cpl_valid(dut_m_axis_if_tx_cpl_valid),
    .m_axis_if_tx_cpl_ready(dut_m_axis_if_tx_cpl_ready),

    .s_axis_if_rx_tdata(dut_s_axis_if_rx_tdata),
    .s_axis_if_rx_tkeep(dut_s_axis_if_rx_tkeep),
    .s_axis_if_rx_tvalid(dut_s_axis_if_rx_tvalid),
    .s_axis_if_rx_tready(dut_s_axis_if_rx_tready),
    .s_axis_if_rx_tlast(dut_s_axis_if_rx_tlast),
    .s_axis_if_rx_tid(dut_s_axis_if_rx_tid),
    .s_axis_if_rx_tdest(dut_s_axis_if_rx_tdest),
    .s_axis_if_rx_tuser(dut_s_axis_if_rx_tuser),

    .m_axis_if_rx_tdata(dut_m_axis_if_rx_tdata),
    .m_axis_if_rx_tkeep(dut_m_axis_if_rx_tkeep),
    .m_axis_if_rx_tvalid(dut_m_axis_if_rx_tvalid),
    .m_axis_if_rx_tready(dut_m_axis_if_rx_tready),
    .m_axis_if_rx_tlast(dut_m_axis_if_rx_tlast),
    .m_axis_if_rx_tid(dut_m_axis_if_rx_tid), .m_axis_if_rx_tdest(dut_m_axis_if_rx_tdest), .m_axis_if_rx_tuser(dut_m_axis_if_rx_tuser)
);


// ############################################################################
//          SECTION 8 - HOST MEMORY MODEL: THE PROPOSAL RING AND ITS READ ENGINE
// ############################################################################
// The host side of the proposal path, as a driver does it: write entries into
// the ring, then write the new producer index to PRODUCER (the doorbell).
//
// A proposal entry is one page. The host writes its payload from offset 64 and
// leaves beat 0 to ssr_tx_engine; this model fills every beat, beat 0 included,
// with a pattern the transmit monitor can recognise - so a frame that carried
// beat 0 would be caught, not merely one that carried the wrong entry. The pattern is
// a function of the entry's ABSOLUTE index (how many entries the host had
// posted before it), not of its ring position, so a wrapped ring that sent a
// stale entry fails.
//
// The read engine keeps every accepted descriptor in a table with its own
// random latency and completes whichever expires first - so, as with the real
// PCIe read engine, completions come back out of order.

// One 64-byte beat of an entry.
function [AXIS_DATA_WIDTH-1:0] host_word(input integer entry, input integer beat);
    integer lane;
    reg [7:0] e8, r8, l8;
begin
    host_word = {AXIS_DATA_WIDTH{1'b0}};
    e8 = 8'hA0 + entry[7:0];
    r8 = beat[7:0];
    for (lane = 0; lane < AXIS_DATA_WIDTH/32; lane = lane + 1) begin
        l8 = lane[7:0];
        host_word[lane*32 +: 32] = {8'h5A, l8, r8, e8};
    end
end
endfunction

// ---- the ring, as the host keeps it ----
// ring_seq[pos] is the absolute index of the entry last written at ring
// position pos: what the read engine finds there.
integer ring_seq [0:(1<<PROP_DEPTH_LOG2)-1];
integer posted = 0;                 // the host's producer index

// Entries go out in posting order - the order the ring is read in, however
// the reads complete - so the host fills the transmit monitor's queue as it
// posts. A flush takes entries back out of it (G3).
integer exp_q [0:255];
integer exp_head = 0, exp_tail = 0;

task post(input integer n);
    integer i;
begin
    for (i = 0; i < n; i = i + 1) begin
        ring_seq[(posted + i) % (1 << PROP_DEPTH_LOG2)] = posted + i;
        exp_q[exp_tail % 256] = posted + i;
        exp_tail = exp_tail + 1;
    end
    posted = posted + n;
    csr_write(REG_PROP_PRODUCER, posted);
end
endtask

// ---- the read engine ----
localparam integer ET = 16;
reg [DMA_ADDR_WIDTH-1:0] et_addr [0:ET-1];
reg [RAM_ADDR_WIDTH-1:0] et_ram  [0:ET-1];
reg [DMA_TAG_WIDTH-1:0]  et_tag  [0:ET-1];
integer                  et_left [0:ET-1];
reg                      et_busy [0:ET-1];
integer dma_latency = 6;                       // the write engine's (section 14)
integer rd_lat_min = 100, rd_lat_span = 200;   // 0.4..1.2 us, a PCIe read's latency
integer rd_force_error_entry = -1;             // this absolute entry's read fails
integer rd_inflight = 0, rd_inflight_max = 0;
integer descs_seen = 0;
integer fetch_expect = 0;                      // the entry the next descriptor must be for
integer et_i, rd_seed = 11;
initial for (et_i = 0; et_i < ET; et_i = et_i + 1) et_busy[et_i] = 1'b0;

// Accept: check the descriptor, park it with a latency.
always @(posedge clk) if (!rst) begin : rd_accept
    integer f;
    for (et_i = 0; et_i < ET; et_i = et_i + 1)
        if (et_busy[et_i] && et_left[et_i] > 0) et_left[et_i] = et_left[et_i] - 1;
    if (rd_desc_valid && rd_desc_ready) begin
        check(rd_desc_len == SLOT_BYTES[DMA_LEN_WIDTH-1:0],
              $sformatf("descriptor len %0d, expected %0d", rd_desc_len, SLOT_BYTES));
        check(rd_desc_ram_sel == 0, "proposal descriptors must select RAM_SEL_PROP");
        // The ring is read in order: entry fetch_expect, at its ring position.
        check(rd_desc_dma_addr == PROP_RING_BASE + ((fetch_expect % (1 << PROP_DEPTH_LOG2)) << 12),
              $sformatf("descriptor for %h, expected entry %0d at %h", rd_desc_dma_addr, fetch_expect,
                        PROP_RING_BASE + ((fetch_expect % (1 << PROP_DEPTH_LOG2)) << 12)));
        fetch_expect = fetch_expect + 1;
        f = -1;
        for (et_i = ET-1; et_i >= 0; et_i = et_i - 1) if (!et_busy[et_i]) f = et_i;
        et_addr[f] = rd_desc_dma_addr;
        et_ram[f]  = rd_desc_ram_addr;
        et_tag[f]  = rd_desc_tag;
        et_left[f] = rd_lat_min + ({$random(rd_seed)} % rd_lat_span);
        et_busy[f] = 1'b1;
        descs_seen  = descs_seen + 1;
        rd_inflight = rd_inflight + 1;
        if (rd_inflight > rd_inflight_max) rd_inflight_max = rd_inflight;
    end
end

// Complete: the expired read writes its 32 rows (64 beats) into the RAM, then
// its status. Like the real engine it writes whole rows: both segments at once,
// beat 2r in segment 0 and beat 2r+1 in segment 1.
initial begin : proposal_dma_engine
    integer f, seq, row;
    reg [RAM_SEG_ADDR_WIDTH-1:0] row_v;
    forever begin
        @(negedge clk);
        f = -1;
        for (et_i = ET-1; et_i >= 0; et_i = et_i - 1) if (et_busy[et_i] && et_left[et_i] == 0) f = et_i;
        if (!rst && f >= 0) begin
            seq = ring_seq[(et_addr[f] - PROP_RING_BASE) >> 12];
            if (seq == rd_force_error_entry) begin
                rd_force_error_entry = -1;
                rd_status_error = 4'd1;
            end else begin
                rd_status_error = 4'd0;
                for (row = 0; row < SLOT_ROWS; row = row + 1) begin
                    row_v    = et_ram[f] / ROW_BYTES + row;
                    wr_addr  = {RAM_SEG_COUNT{row_v}};
                    wr_data  = {host_word(seq, 2*row + 1), host_word(seq, 2*row)};
                    wr_be    = {RAM_SEG_COUNT*RAM_SEG_BE_WIDTH{1'b1}};
                    wr_valid = {RAM_SEG_COUNT{1'b1}};
                    @(negedge clk);
                end
                wr_valid = {RAM_SEG_COUNT{1'b0}};
            end
            rd_status_tag   = et_tag[f];
            rd_status_valid = 1'b1;
            et_busy[f]      = 1'b0;
            rd_inflight     = rd_inflight - 1;
            @(negedge clk);
            rd_status_valid = 1'b0;
            rd_status_error = 4'd0;
        end
    end
end

// The ring, programmed once at start-up (A1).
task prop_ring_setup;
begin
    csr_write(REG_PROP_BASE_LO,    PROP_RING_BASE[31:0]);
    csr_write(REG_PROP_BASE_HI,    PROP_RING_BASE[63:32]);
    csr_write(REG_PROP_DEPTH_LOG2, PROP_DEPTH_LOG2);
    csr_write(REG_PROP_CONTROL,    PROP_CTRL_ENABLE);
end
endtask

// Wait for a flush or clear_error to be carried out (STATUS.pending clears).
task prop_wait_not_pending;
    integer guard;
    reg [31:0] st;
begin
    guard = 0;
    st = 32'h8;
    while (st[PROP_ST_PENDING] && guard < 2000) begin csr_read(REG_PROP_STATUS, st); guard = guard + 1; end
    check(!st[PROP_ST_PENDING], "a proposal flush / clear_error was never carried out");
end
endtask


// ############################################################################
//                  SECTION 9 - HOST TRANSMIT FRAMES
// ############################################################################

localparam integer HOST_FRAME_BEATS = 3;
localparam [AXIS_KEEP_WIDTH-1:0] HOST_LAST_KEEP = {{(AXIS_KEEP_WIDTH-16){1'b0}}, {16{1'b1}}};

function [AXIS_DATA_WIDTH-1:0] host_frame_word(input integer f, input integer beat);
    integer lane;
begin
    host_frame_word = {AXIS_DATA_WIDTH{1'b0}};
    for (lane = 0; lane < AXIS_DATA_WIDTH/32; lane = lane + 1)
        host_frame_word[lane*32 +: 32] = {8'hC3, lane[7:0], beat[7:0], f[7:0]};
end
endfunction

function [TX_TAG_WIDTH-1:0] host_tag(input integer f);
    host_tag = 16'h8000 | f[7:0];       // as Corundum tags a host frame: top bit set
endfunction

integer host_frames_sent = 0;
integer host_exp_q [0:255];
integer host_exp_head = 0, host_exp_tail = 0;

task send_host_frame(input integer f);
    integer b;
begin
    host_exp_q[host_exp_tail % 256] = f;
    host_exp_tail = host_exp_tail + 1;
    for (b = 0; b < HOST_FRAME_BEATS; b = b + 1) begin
        @(negedge clk);
        host_tx_tdata  = host_frame_word(f, b);
        host_tx_tkeep  = (b == HOST_FRAME_BEATS-1) ? HOST_LAST_KEEP : {AXIS_KEEP_WIDTH{1'b1}};
        host_tx_tlast  = (b == HOST_FRAME_BEATS-1);
        host_tx_tuser  = {host_tag(f), 1'b0};
        host_tx_tvalid = 1'b1;
        @(posedge clk);
        while (!host_tx_tready) @(posedge clk);
    end
    @(negedge clk);
    host_tx_tvalid = 1'b0;
    host_tx_tlast  = 1'b0;
    host_frames_sent = host_frames_sent + 1;
end
endtask


// ############################################################################
//                      SECTION 10 - PORT MODEL
// ############################################################################

reg     tx_bp_enable = 1'b0;
integer tx_bp_seed   = 32'h1234_5678;

always @(posedge clk) begin
    if (rst || !tx_bp_enable) port_tx_tready <= 1'b1;
    else                      port_tx_tready <= (({$random(tx_bp_seed)} % 5) != 0);
end

localparam integer CPL_DEPTH = 32;
reg [TX_TAG_WIDTH-1:0] cpl_q_tag [0:CPL_DEPTH-1];
reg [PTP_TS_WIDTH-1:0] cpl_q_ts  [0:CPL_DEPTH-1];
integer cpl_head = 0, cpl_tail = 0;

reg [PTP_TS_WIDTH-1:0] last_ssr_cpl_ts_model = {PTP_TS_WIDTH{1'b0}};
integer ssr_cpl_model_count = 0;
integer host_cpl_model_count = 0;

always @(posedge clk) if (!rst && port_tx_tvalid && port_tx_tready && port_tx_tlast) begin
    cpl_q_tag[cpl_tail % CPL_DEPTH] = port_tx_tuser[TX_TAG_WIDTH:1];
    cpl_q_ts [cpl_tail % CPL_DEPTH] = port_ts;
    cpl_tail = cpl_tail + 1;
end

initial begin : port_cpl_driver
    forever begin
        @(negedge clk);
        if (!rst && cpl_head != cpl_tail) begin
            repeat (4) @(negedge clk);
            port_cpl_tag   = cpl_q_tag[cpl_head % CPL_DEPTH];
            port_cpl_ts    = cpl_q_ts [cpl_head % CPL_DEPTH];
            port_cpl_valid = 1'b1;
            if (port_cpl_tag == SSR_TX_CPL_TAG) begin
                last_ssr_cpl_ts_model = port_cpl_ts;
                ssr_cpl_model_count   = ssr_cpl_model_count + 1;
            end else begin
                host_cpl_model_count  = host_cpl_model_count + 1;
            end
            @(posedge clk);
            while (!port_cpl_ready) @(posedge clk);
            @(negedge clk);
            port_cpl_valid = 1'b0;
            cpl_head = cpl_head + 1;
        end
    end
end


// ############################################################################
//                  SECTION 11 - TRANSMIT FRAME MONITOR
// ############################################################################
// Every frame that leaves the port is checked here. An SSR frame is either a
// control frame - one beat, length 0, frag_idx 0 - or a fragment: length 4032,
// 63 beats that are beats 1..63 of the next committed slot, never beat 0.
//
// Two properties of the transmit path are checked here too, on every round of
// every test:
//   - fragments of a round are numbered 0, 1, 2 ... in order, within the
//     budget, and the NEXT round's control frame reports how many there were
//     as ack[self]. That count is what every peer compares its own against.
//   - an SSR frame, once started, has a beat on the port every cycle
//     (tvalid never drops mid-frame). A frame with gaps takes longer than
//     ssr_tx_engine budgeted, and could miss the cutoff.

reg [AXIS_DATA_WIDTH-1:0] seen = {AXIS_DATA_WIDTH{1'b0}};
integer ssr_frames = 0, ssr_payload_frames = 0, ssr_ctrl_frames = 0, ssr_payload_beats = 0;
integer ssr_empty_ctrl = 0;
integer host_frames_out = 0;
integer beat_in_frame = 0;
integer cur_entry = -1, cur_host = -1;
integer payload_beat;
reg [15:0] frame_len_reg, frame_idx_reg;
reg [63:0] last_ctrl_round;
reg        frame_is_ssr = 1'b0;
reg        frame_is_ctrl = 1'b0;
integer    frags_this_round = 0;       // fragments since the last control frame
integer    last_round_frags = 0;       // ... as they stood when the next control frame went out
reg [63:0] last_frags_round = 64'd0;   // ... and the round they belonged to
integer    ssr_tx_bubbles = 0;         // cycles an SSR frame had no beat mid-frame
event      ev_ctrl_frame;              // a control frame just went out (B7, B8)
reg [63:0] ctrl_ack;

// What this node put on the wire, by round: the peers' model of ack[us].
// Zeroed at each of our boundaries by the peer driver (SECTION 13).
integer    dut_frags [0:15];

function [15:0] rd16(input integer off);
    rd16 = {seen[off*8 +: 8], seen[(off+1)*8 +: 8]};
endfunction
function [31:0] rd32(input integer off);
    rd32 = {seen[off*8 +: 8], seen[(off+1)*8 +: 8], seen[(off+2)*8 +: 8], seen[(off+3)*8 +: 8]};
endfunction
function [63:0] rd64(input integer off);
    rd64 = {seen[off*8 +: 8], seen[(off+1)*8 +: 8], seen[(off+2)*8 +: 8], seen[(off+3)*8 +: 8],
            seen[(off+4)*8 +: 8], seen[(off+5)*8 +: 8], seen[(off+6)*8 +: 8], seen[(off+7)*8 +: 8]};
endfunction

always @(posedge clk) begin
    if (!rst && beat_in_frame != 0 && frame_is_ssr && !port_tx_tvalid) begin
        if (ssr_tx_bubbles < 40)
            $display("  [%0t] SSR frame %0d has a gap on payload beat %0d", $time, ssr_frames, beat_in_frame - 1);
        ssr_tx_bubbles = ssr_tx_bubbles + 1;
    end
    if (!rst && port_tx_tvalid && port_tx_tready) begin
        if (beat_in_frame == 0) begin
            frame_is_ssr = (port_tx_tuser[TX_TAG_WIDTH:1] == SSR_TX_CPL_TAG);
            seen = port_tx_tdata;

            if (frame_is_ssr) begin
                ssr_frames    = ssr_frames + 1;
                frame_len_reg = rd16(SSR_OFF_LENGTH);
                frame_idx_reg = rd16(SSR_OFF_FRAG_IDX);
                frame_is_ctrl = (seen[SSR_OFF_KIND*8 +: 8] == SSR_KIND_CTRL);

                check(port_tx_tkeep == {AXIS_KEEP_WIDTH{1'b1}}, "an SSR header beat is full");
                check(port_tx_tuser[0] === 1'b0, "SSR frames must not be marked bad");
                check(rd16(SSR_OFF_ETHERTYPE) == SSR_ETHERTYPE, "ethertype");
                check(seen[SSR_OFF_NODE_ID*8 +: 8] == NODE_ID[7:0], "node_id");
                check(rd64(SSR_OFF_ROUND_ID) == dut.core_tx_round_id, "round_id must match the core");
                check(rd32(SSR_OFF_RUN_ID) == dut.core_tx_run_id, "run_id must match the core");
                check(seen[SSR_OFF_RESERVED*8 +: (SSR_OFF_PAYLOAD-SSR_OFF_RESERVED)*8] == 0,
                      "header padding must be zero");
                check(seen[15*8 +: 8] == 8'd0 && seen[34*8 +: 16] == 16'd0,
                      "the retired row and frag_count bytes must be zero");

                if (frame_is_ctrl) begin
                    ssr_ctrl_frames = ssr_ctrl_frames + 1;
                    ctrl_ack = seen[SSR_OFF_ACK*8 +: 64];
                    // ack[self] is what we sent in the round before. Checked
                    // only across consecutive rounds: after a halt the round
                    // before was never ours to report.
                    if (ssr_ctrl_frames > 1 && rd64(SSR_OFF_ROUND_ID) == last_ctrl_round + 64'd1)
                        check(ctrl_ack[NODE_ID*8 +: 8] == frags_this_round[7:0],
                              $sformatf("round %0d's control frame says we sent %0d in round %0d; %0d went out",
                                        rd64(SSR_OFF_ROUND_ID), ctrl_ack[NODE_ID*8 +: 8], last_ctrl_round, frags_this_round));
                    check(ctrl_ack[63:NODE_COUNT*8] == 0, "ack bytes past the cluster are zero");
                    // The count TX_EMPTY keeps: a round that ended with nothing sent.
                    if (ssr_ctrl_frames > 1 && frags_this_round == 0) ssr_empty_ctrl = ssr_empty_ctrl + 1;
                    last_round_frags = frags_this_round;
                    last_frags_round = last_ctrl_round;
                    frags_this_round = 0;
                    last_ctrl_round = rd64(SSR_OFF_ROUND_ID);
                    check(frame_len_reg == 16'd0, "a control frame carries no payload");
                    check(frame_idx_reg == 16'd0, "a control frame has frag_idx 0");
                    check(port_tx_tlast === 1'b1, "a control frame ends on the header beat");
                    cur_entry = -1;
                    -> ev_ctrl_frame;
                end else begin
                    ssr_payload_frames = ssr_payload_frames + 1;
                    frags_this_round   = frags_this_round + 1;
                    check(seen[SSR_OFF_KIND*8 +: 8] == SSR_KIND_PAYLOAD, "kind must be CTRL or PAYLOAD");
                    check(seen[SSR_OFF_ACK*8 +: 64] == 64'd0, "a payload frame carries no ack");
                    check(frame_len_reg == FRAG_BYTES[15:0],
                          $sformatf("length %0d, expected %0d", frame_len_reg, FRAG_BYTES));
                    check(frame_idx_reg == frags_this_round - 1,
                          $sformatf("fragment %0d of the round is numbered %0d", frags_this_round - 1, frame_idx_reg));
                    check(frame_idx_reg < FRAGS_PER_ROUND[15:0], "frag_idx must be within the round's budget");
                    check(rd64(SSR_OFF_ROUND_ID) == last_ctrl_round, "a fragment carries its control frame's round");
                    dut_frags[last_ctrl_round % 16] = dut_frags[last_ctrl_round % 16] + 1;
                    check(port_tx_tlast === 1'b0, "a frame with a payload cannot end on the header");
                    if (exp_head == exp_tail) begin
                        check(1'b0, "an SSR frame carried a payload but no slot was committed");
                        cur_entry = -1;
                    end else begin
                        cur_entry = exp_q[exp_head % 256];
                        exp_head  = exp_head + 1;
                    end
                end
            end else begin
                host_frames_out = host_frames_out + 1;
                if (host_exp_head == host_exp_tail) begin
                    check(1'b0, "a host frame left the port that the bench never sent");
                    cur_host = -1;
                end else begin
                    cur_host = host_exp_q[host_exp_head % 256];
                    host_exp_head = host_exp_head + 1;
                    check(port_tx_tuser[TX_TAG_WIDTH:1] == host_tag(cur_host),
                          "host frame tag was not preserved through the mux");
                    check(port_tx_tdata === host_frame_word(cur_host, 0),
                          "host frame beat 0 corrupted");
                end
            end
            beat_in_frame = port_tx_tlast ? 0 : 1;
        end else begin
            if (frame_is_ssr) begin
                payload_beat      = beat_in_frame - 1;
                ssr_payload_beats = ssr_payload_beats + 1;
                check(port_tx_tkeep == {AXIS_KEEP_WIDTH{1'b1}}, "an SSR payload beat is full");
                // Beat k of the payload is BEAT k+1 of the slot: beat 0 is the
                // host's header space and must never go on the wire.
                if (cur_entry >= 0)
                    check(port_tx_tdata === host_word(cur_entry, payload_beat + 1),
                          $sformatf("SSR frame %0d payload beat %0d does not match entry a%0h beat %0d",
                                    ssr_frames, payload_beat, 8'hA0 + cur_entry, payload_beat + 1));
                if (port_tx_tlast)
                    check(payload_beat == FRAG_BEATS-1,
                          $sformatf("SSR frame ended on payload beat %0d, expected %0d",
                                    payload_beat, FRAG_BEATS-1));
            end else begin
                if (cur_host >= 0)
                    check(port_tx_tdata === host_frame_word(cur_host, beat_in_frame),
                          $sformatf("host frame %0d beat %0d corrupted", cur_host, beat_in_frame));
                if (port_tx_tlast) begin
                    check(beat_in_frame == HOST_FRAME_BEATS-1, "host frame ended on the wrong beat");
                    check(port_tx_tkeep == HOST_LAST_KEEP, "host frame tkeep was not preserved");
                end
            end
            beat_in_frame = port_tx_tlast ? 0 : beat_in_frame + 1;
        end
    end
end


// ############################################################################
//                  SECTION 12 - COMPLETION MONITOR
// ############################################################################

integer if_cpl_seen = 0;
reg [TX_TAG_WIDTH-1:0] last_if_cpl_tag = {TX_TAG_WIDTH{1'b0}};

always @(posedge clk) if (!rst && if_cpl_valid && if_cpl_ready) begin
    if_cpl_seen = if_cpl_seen + 1;
    last_if_cpl_tag = if_cpl_tag;
    check(if_cpl_tag !== SSR_TX_CPL_TAG,
          $sformatf("completion for tag %04h reached the interface; SSR completions must be consumed",
                    if_cpl_tag));
end


// ############################################################################
//                  SECTION 13 - RECEIVE PORT DRIVER
// ############################################################################
// ONE process owns s_axis_if_rx. See the note at the top of the file.

// ---- the bytes a peer sends ----
// A function of (node, round, fragment, beat), so a page holding the wrong
// node's, round's or fragment's bytes fails loudly.
function [AXIS_DATA_WIDTH-1:0] peer_word(input integer node, input [63:0] round,
                                         input integer frag, input integer beat);
    integer lane;
begin
    peer_word = {AXIS_DATA_WIDTH{1'b0}};
    for (lane = 0; lane < AXIS_DATA_WIDTH/32; lane = lane + 1)
        peer_word[lane*32 +: 32] = {node[7:0], round[7:0], frag[3:0], beat[7:0] ^ lane[7:0], lane[7:0]} ^ 32'h3C3C_0000;
end
endfunction

// ---- a record of the last frame put on the wire ----
localparam integer RXREC_MAX = 8;
reg [AXIS_DATA_WIDTH-1:0] rxrec_data [0:RXREC_MAX-1];
reg [AXIS_KEEP_WIDTH-1:0] rxrec_keep [0:RXREC_MAX-1];
integer rxrec_beats = 0;

// ---- the one task that drives the port ----
// declared_len is what the header SAYS and beats is what actually follows it,
// so a frame that lies about its own length is one call.
task send_rx_frame(input [15:0] ethertype,
                   input [7:0]  node,
                   input [7:0]  kind,
                   input [63:0] ack,
                   input [31:0] run,
                   input [63:0] round,
                   input [15:0] declared_len,
                   input [15:0] frag_idx,
                   input integer beats,
                   input        keep_full,
                   input        bad_user);
    integer k;
    reg [AXIS_DATA_WIDTH-1:0] hdr;
    reg [AXIS_KEEP_WIDTH-1:0] hdr_keep;
begin
    hdr = {AXIS_DATA_WIDTH{1'b0}};
    hdr[SSR_OFF_DST_MAC  *8 +: 48] = {BCAST_MAC[7:0],  BCAST_MAC[15:8],  BCAST_MAC[23:16],
                                      BCAST_MAC[31:24], BCAST_MAC[39:32], BCAST_MAC[47:40]};
    hdr[SSR_OFF_SRC_MAC  *8 +: 48] = {8'h02, 8'h00, 8'h00, 8'h00, 8'h00, node};
    hdr[SSR_OFF_ETHERTYPE*8 +: 16] = {ethertype[7:0], ethertype[15:8]};
    hdr[SSR_OFF_NODE_ID  *8 +:  8] = node;
    hdr[SSR_OFF_RUN_ID   *8 +: 32] = {run[7:0], run[15:8], run[23:16], run[31:24]};
    hdr[SSR_OFF_ROUND_ID *8 +: 64] = {round[7:0], round[15:8], round[23:16], round[31:24],
                                      round[39:32], round[47:40], round[55:48], round[63:56]};
    hdr[SSR_OFF_LENGTH   *8 +: 16] = {declared_len[7:0], declared_len[15:8]};
    hdr[SSR_OFF_KIND     *8 +:  8] = kind;
    hdr[SSR_OFF_FRAG_IDX *8 +: 16] = {frag_idx[7:0], frag_idx[15:8]};
    hdr[SSR_OFF_ACK      *8 +: 64] = ack;     // eight single bytes, node k at +k

    hdr_keep = keep_full ? {AXIS_KEEP_WIDTH{1'b1}}
                         : {{(AXIS_KEEP_WIDTH-32){1'b0}}, {32{1'b1}}};

    rxrec_data[0] = hdr;
    rxrec_keep[0] = hdr_keep;
    rxrec_beats   = 1;

    @(negedge clk);
    peer_tdata  = hdr;
    peer_tkeep  = hdr_keep;
    peer_tuser  = {{(AXIS_RX_USER_WIDTH-1){1'b0}}, bad_user};
    peer_tvalid = 1'b1;
    peer_tlast  = (beats == 0);
    @(posedge clk);
    while (!peer_tready) @(posedge clk);
    inj_hdr_offset_ns = dut.core_inst.round_offset_ns;

    for (k = 0; k < beats; k = k + 1) begin
        @(negedge clk);
        peer_tdata = peer_word(node, round, frag_idx, k);
        peer_tkeep = {AXIS_KEEP_WIDTH{1'b1}};
        peer_tlast = (k == beats-1);
        if (k+1 < RXREC_MAX) begin
            rxrec_data[k+1] = peer_tdata;
            rxrec_keep[k+1] = peer_tkeep;
            rxrec_beats     = k+2;
        end
        @(posedge clk);
        while (!peer_tready) @(posedge clk);
    end

    @(negedge clk);
    peer_tvalid = 1'b0;
    peer_tlast  = 1'b0;
end
endtask

// A peer's control frame: one beat, carrying its ack vector.
task send_peer_ctrl(input integer node, input [63:0] round, input [31:0] run,
                    input [63:0] ack);
begin
    send_rx_frame(SSR_ETHERTYPE_TB, node[7:0], SSR_KIND_CTRL, ack, run, round,
                  16'd0, 16'd0, 0, 1'b1, 1'b0);
end
endtask

// A peer's fragment: a full page's worth of payload.
task send_peer_frag(input integer node, input [63:0] round, input [31:0] run,
                    input integer frag);
begin
    send_rx_frame(SSR_ETHERTYPE_TB, node[7:0], SSR_KIND_PAYLOAD, 64'd0, run, round,
                  FRAG_BYTES[15:0], frag[15:0], FRAG_BEATS, 1'b1, 1'b0);
end
endtask

// ---- the peers ----
reg       peers_enabled  = 1'b1;
reg [7:0] peer_mask      = ~SELF_BIT;     // which node ids actually transmit (everyone but us)
reg [7:0] peer_zero_mask = 8'd0;          // ... of those, which send no fragment
reg [7:0] peer_short_mask= 8'd0;          // ... of those, which deliver one fewer than they believe they sent
integer   peer_frags     = 2;             // fragments per peer per round
reg [63:0] peer_ack_xor [0:7];            // flipped into a peer's ack: a peer that disagrees
integer   pr_i;
initial for (pr_i = 0; pr_i < 8; pr_i = pr_i + 1) peer_ack_xor[pr_i] = 64'd0;

// ---- the peers' view of each round (docs/count_ack.md) ----
//   peer_deliv  fragments a peer actually put on the wire: what every other
//               node - us included - holds of it
//   peer_claim  fragments the peer believes it sent: its own ack byte. The
//               two differ only for a short peer (H1).
// Indexed node*16 + round%16, and zeroed at each of our boundaries for the
// round that opens, so a round in which a peer was silent reads 0.
integer   peer_deliv [0:127];
integer   peer_claim [0:127];
initial for (pr_i = 0; pr_i < 128; pr_i = pr_i + 1) begin peer_deliv[pr_i] = 0; peer_claim[pr_i] = 0; end
initial for (pr_i = 0; pr_i < 16; pr_i = pr_i + 1) dut_frags[pr_i] = 0;

// Peer j's ack vector about round r: its own claim, what the other peer
// delivered, and what the port monitor saw us send. Exactly our own vector
// when nothing was lost - which is what makes a healthy peer a witness.
function [63:0] model_ack(input integer j, input [63:0] r);
    integer k;
begin
    model_ack = 64'd0;
    for (k = 0; k < NODE_COUNT; k = k + 1)
        model_ack[k*8 +: 8] = (k == NODE_ID) ? dut_frags[r % 16]
                            : (k == j)       ? peer_claim[k*16 + r % 16]
                            :                  peer_deliv[k*16 + r % 16];
end
endfunction

// Whether we will find peer j's ack about round r different from ours - the
// ack rung's verdict, predicted, for the receive counter model (SECTION 17).
function peer_disagrees(input integer j, input [63:0] r);
begin
    peer_disagrees = (peer_ack_xor[j] != 64'd0)
                  || (peer_claim[j*16 + r % 16] != peer_deliv[j*16 + r % 16]);
end
endfunction

wire [31:0] core_run_id = dut.core_rx_run_id;

integer peer_n, peer_f, peer_send;
integer peer_guard = 0;
integer peer_frames_sent = 0;     // every frame, control and payload
integer peer_ctrl_sent = 0;
integer peer_ctrl_disagree = 0;   // ... of the control frames, those whose ack we disagree with
reg [63:0] peer_round_sent;

// ---- the injection slot ----
reg         inj_req      = 1'b0;
reg         inj_late     = 1'b0;      // send after the control deadline
reg         inj_edge     = 1'b0;      // send so the header beat is taken on the LAST cycle inside the deadline
reg         inj_early    = 1'b0;      // send right after the peers' control frames, well inside the deadline
integer     inj_hdr_offset_ns = -1;   // where in the round the last injected header beat was taken
reg [15:0]  inj_ethertype = SSR_ETHERTYPE_TB;
reg [7:0]   inj_node      = PEER_A[7:0];
reg [7:0]   inj_kind      = SSR_KIND_PAYLOAD;
reg [63:0]  inj_ack       = 64'd0;
reg         inj_ack_model = 1'b0;     // carry the sending peer's model ack, XOR inj_ack
reg [31:0]  inj_run       = 32'd0;
reg         inj_run_core  = 1'b1;
reg [63:0]  inj_round     = 64'd0;
reg         inj_round_core= 1'b1;
integer     inj_round_off = 0;
reg [15:0]  inj_len       = FRAG_BYTES[15:0];
reg [15:0]  inj_frag_idx  = 16'd0;
integer     inj_beats     = FRAG_BEATS;
reg         inj_keep_full = 1'b1;
reg         inj_bad_user  = 1'b0;
integer     inj_sent_count= 0;

task do_injection;
    reg [31:0] use_run;
    reg [63:0] use_round;
begin
    use_run   = inj_run_core   ? core_run_id : inj_run;
    use_round = inj_round_core ? (dut.current_round_id + inj_round_off) : inj_round;
    send_rx_frame(inj_ethertype, inj_node, inj_kind,
                  inj_ack_model ? (model_ack(inj_node, dut.current_round_id - 64'd1) ^ inj_ack) : inj_ack,
                  use_run, use_round,
                  inj_len, inj_frag_idx, inj_beats, inj_keep_full, inj_bad_user);
    inj_sent_count = inj_sent_count + 1;
    inj_req        = 1'b0;
end
endtask

always @(posedge clk) begin : peer_driver
    if (!rst && dut.round_start_pulse) begin
        // A new round: nothing has been sent in it yet, by anyone.
        dut_frags[dut.current_round_id % 16] = 0;
        for (peer_n = 0; peer_n < NODE_COUNT; peer_n = peer_n + 1) begin
            peer_deliv[peer_n*16 + dut.current_round_id % 16] = 0;
            peer_claim[peer_n*16 + dut.current_round_id % 16] = 0;
        end

        // Wait for the control window rather than counting cycles: a node that
        // is not running never opens one, and the wait is bounded so the peers
        // stay silent for that round and are back at the top before the next.
        peer_guard = 0;
        while (!dut.rx_ctrl_window_from_core && peer_guard < WINDOW_WAIT_MAX) begin
            @(posedge clk);
            peer_guard = peer_guard + 1;
        end

        if (peers_enabled && dut.rx_ctrl_window_from_core) begin
            peer_round_sent = dut.current_round_id;
            // Control frames first, all of them, inside the deadline, each
            // carrying its sender's ack vector about the round before.
            for (peer_n = 0; peer_n < NODE_COUNT; peer_n = peer_n + 1)
                if (peer_n != NODE_ID && peer_mask[peer_n]) begin
                    send_peer_ctrl(peer_n, peer_round_sent, core_run_id,
                                   model_ack(peer_n, peer_round_sent - 64'd1) ^ peer_ack_xor[peer_n]);
                    peer_frames_sent = peer_frames_sent + 1;
                    peer_ctrl_sent   = peer_ctrl_sent + 1;
                    if (peer_disagrees(peer_n, peer_round_sent - 64'd1))
                        peer_ctrl_disagree = peer_ctrl_disagree + 1;
                end
            if (inj_req && inj_early) do_injection;
            // Then the fragments, peer by peer. One stream carries them in
            // turn; the rate cap is the peers' business and does not matter
            // to a receiver fed by one port model.
            for (peer_n = 0; peer_n < NODE_COUNT; peer_n = peer_n + 1)
                if (peer_n != NODE_ID && peer_mask[peer_n] && !peer_zero_mask[peer_n]) begin
                    peer_send = peer_short_mask[peer_n] ? peer_frags - 1 : peer_frags;
                    peer_claim[peer_n*16 + peer_round_sent % 16] = peer_frags;
                    peer_deliv[peer_n*16 + peer_round_sent % 16] = peer_send;
                    for (peer_f = 0; peer_f < peer_send; peer_f = peer_f + 1) begin
                        send_peer_frag(peer_n, peer_round_sent, core_run_id, peer_f);
                        peer_frames_sent = peer_frames_sent + 1;
                    end
                end
        end

        if (inj_req && !inj_late && !inj_edge && !inj_early) do_injection;

        // I3: a control frame whose header beat is taken a few cycles before
        // the deadline. It must count - the settle after the deadline exists
        // so that exactly this peer still lands among the witnesses.
        // The window ssr_rx_engine judges against is the core's one-cycle-delayed
        // copy, so the last edge a header is admitted on is the one where the
        // level itself drops (offset >= CTRL_PERIOD_NS for the first time).
        // Leave the wait one cycle earlier; the beat goes out at the negedge
        // and is taken on that edge.
        if (inj_req && inj_edge) begin
            while (dut.core_inst.round_offset_ns < CTRL_PERIOD_NS - CLK_PERIOD_NS
                   && dut.core_inst.state_reg == 2'd2)
                @(posedge clk);
            do_injection;
        end

        // E10: a control frame after the deadline. The peers' own frames have
        // long since gone, so this is the only thing on the wire.
        if (inj_req && inj_late) begin
            while (dut.rx_ctrl_window_from_core && dut.core_inst.state_reg == 2'd2)
                @(posedge clk);
            repeat (4) @(posedge clk);
            do_injection;
        end
    end
end

task inj_defaults;
begin
    inj_late      = 1'b0;
    inj_edge      = 1'b0;
    inj_early     = 1'b0;
    inj_ethertype = SSR_ETHERTYPE_TB;
    inj_node      = PEER_A[7:0];
    inj_kind      = SSR_KIND_PAYLOAD;
    inj_ack       = 64'd0;
    inj_ack_model = 1'b0;
    inj_run_core  = 1'b1;
    inj_run       = 32'd0;
    inj_round_core= 1'b1;
    inj_round_off = 0;
    inj_round     = 64'd0;
    inj_len       = FRAG_BYTES[15:0];
    inj_frag_idx  = 16'd0;
    inj_beats     = FRAG_BEATS;
    inj_keep_full = 1'b1;
    inj_bad_user  = 1'b0;
end
endtask


// ############################################################################
//                  SECTION 14 - HOST RECEIVE SINK
// ############################################################################

integer hostrx_frames = 0;
integer hostrx_beat   = 0;
integer hostrx_last_beats = 0;

always @(posedge clk) if (!rst && hostrx_tvalid && hostrx_tready) begin
    if (hostrx_beat < RXREC_MAX) begin
        check(hostrx_tdata === rxrec_data[hostrx_beat],
              $sformatf("host RX frame beat %0d does not match what was sent", hostrx_beat));
        check(hostrx_tkeep === rxrec_keep[hostrx_beat],
              $sformatf("host RX frame beat %0d tkeep was not preserved", hostrx_beat));
    end
    if (hostrx_tlast) begin
        hostrx_frames     = hostrx_frames + 1;
        hostrx_last_beats = hostrx_beat + 1;
        hostrx_beat       = 0;
    end else begin
        hostrx_beat = hostrx_beat + 1;
    end
end



// ############################################################################
//              SECTION 14b - THE OTHER INTERFACE
// ############################################################################
// Lane OTHER_IF must leave the app block exactly as it came in, on every
// cycle of the run, in both directions and on every sideband: the app block
// is wiring there. A cycle where any output differs from its input is counted;
// J1 puts traffic on the lane that SSR would claim if it were on its lane.
integer oth_mismatch = 0;
integer oth_tx_frames = 0, oth_rx_frames = 0, oth_cpls = 0;

always @(posedge clk) if (!rst) begin
    if (otx_m_tdata !== otx_s_tdata || otx_m_tkeep !== otx_s_tkeep || otx_m_tvalid !== otx_s_tvalid ||
        otx_m_tlast !== otx_s_tlast || otx_m_tid !== otx_s_tid || otx_m_tdest !== otx_s_tdest ||
        otx_m_tuser !== otx_s_tuser || otx_s_tready !== otx_m_tready ||
        ocpl_m_ts !== ocpl_s_ts || ocpl_m_tag !== ocpl_s_tag || ocpl_m_valid !== ocpl_s_valid ||
        ocpl_s_ready !== ocpl_m_ready ||
        orx_m_tdata !== orx_s_tdata || orx_m_tkeep !== orx_s_tkeep || orx_m_tvalid !== orx_s_tvalid ||
        orx_m_tlast !== orx_s_tlast || orx_m_tid !== orx_s_tid || orx_m_tdest !== orx_s_tdest ||
        orx_m_tuser !== orx_s_tuser || orx_s_tready !== orx_m_tready) begin
        if (oth_mismatch < 10)
            $display("[%0t] ERROR: interface %0d (not SSR's) was altered by the app block", $realtime, OTHER_IF);
        oth_mismatch = oth_mismatch + 1;
    end
    if (otx_m_tvalid && otx_m_tready && otx_m_tlast) oth_tx_frames = oth_tx_frames + 1;
    if (orx_m_tvalid && orx_m_tready && orx_m_tlast) oth_rx_frames = oth_rx_frames + 1;
    if (ocpl_m_valid && ocpl_m_ready)                oth_cpls      = oth_cpls + 1;
end

// ############################################################################
//      SECTION 15 - THE DMA WRITE ENGINE AND THE HOST MEMORY MODEL
// ############################################################################
// Corundum's write engine accepts a descriptor, reads the bytes out of the
// app's RAM through the read port, writes them to the host and reports the
// tag done. This model does the same, with the two things the checks need:
//
//   - the bytes are READ THROUGH THE WRAPPER'S READ PORT with the descriptor's
//     own ram_sel, so the demux and the ram_addr are under test, and land in a
//     host memory model where the tests read them back
//   - descriptors are queued, not serialised, and completed with a latency
//     the tests can hold. That is what makes the fence observable: a verdict
//     descriptor must never be offered while a page of its round is still
//     outstanding, and the model checks that on every verdict.

// ---- big-endian readers over a beat ----
function [7:0]  cb8 (input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    cb8 = d[off*8 +: 8];
endfunction
function [15:0] cb16(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    cb16 = {d[off*8 +: 8], d[(off+1)*8 +: 8]};
endfunction
function [31:0] cb32(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    cb32 = {d[off*8 +: 8], d[(off+1)*8 +: 8], d[(off+2)*8 +: 8], d[(off+3)*8 +: 8]};
endfunction
function [63:0] cb64(input [AXIS_DATA_WIDTH-1:0] d, input integer off);
    cb64 = {d[off*8 +: 8], d[(off+1)*8 +: 8], d[(off+2)*8 +: 8], d[(off+3)*8 +: 8],
            d[(off+4)*8 +: 8], d[(off+5)*8 +: 8], d[(off+6)*8 +: 8], d[(off+7)*8 +: 8]};
endfunction

// ---- the host memory model: a cache of recent pages and records ----
localparam integer PG_MAX  = 64;
localparam integer REC_MAX = 16;
reg [63:0]                pg_key   [0:PG_MAX-1];
reg                       pg_valid [0:PG_MAX-1];
reg [AXIS_DATA_WIDTH-1:0] pg_data  [0:PG_MAX*SLOT_BEATS-1];
integer pg_next = 0;
reg [63:0]                rec_key  [0:REC_MAX-1];
reg                       rec_valid[0:REC_MAX-1];
reg [AXIS_DATA_WIDTH-1:0] rec_data [0:REC_MAX-1];
integer rec_next = 0;

integer hm_i;
initial begin
    for (hm_i = 0; hm_i < PG_MAX;  hm_i = hm_i + 1) pg_valid[hm_i]  = 1'b0;
    for (hm_i = 0; hm_i < REC_MAX; hm_i = hm_i + 1) rec_valid[hm_i] = 1'b0;
end

function integer pg_find(input [63:0] page_addr);
    integer i;
begin
    pg_find = -1;
    for (i = 0; i < PG_MAX; i = i + 1)
        if (pg_valid[i] && pg_key[i] == page_addr) pg_find = i;
end
endfunction

function integer rec_find(input [63:0] addr);
    integer i;
begin
    rec_find = -1;
    for (i = 0; i < REC_MAX; i = i + 1)
        if (rec_valid[i] && rec_key[i] == addr) rec_find = i;
end
endfunction

// ---- descriptor queues: data (pages) and control (verdict records) ----
// Like Corundum's engine, the model takes one descriptor at a time and, when
// both queues hold one, takes the control descriptor first (mqnic_core.v,
// "data/control DMA mux (priority)").
localparam integer WQ = 64;
reg [DMA_ADDR_WIDTH-1:0] wq_addr [0:WQ-1];
reg [RAM_ADDR_WIDTH-1:0] wq_ram  [0:WQ-1];
reg [DMA_LEN_WIDTH-1:0]  wq_len  [0:WQ-1];
reg [DMA_TAG_WIDTH-1:0]  wq_tag  [0:WQ-1];
integer wq_wr = 0, wq_rd = 0;
reg [DMA_ADDR_WIDTH-1:0] vq_addr [0:WQ-1];
reg [RAM_ADDR_WIDTH-1:0] vq_ram  [0:WQ-1];
reg [DMA_TAG_WIDTH-1:0]  vq_tag  [0:WQ-1];
integer vq_wr = 0, vq_rd = 0;

integer page_descs = 0, verdict_descs = 0;      // since reset
integer page_descs_at_mark = 0;                 // tests snapshot these
integer verdict_descs_at_mark = 0;

// Pages of each round still not completed, by R mod 256. Decoded from the
// descriptor address, which is the only thing a real engine sees.
integer out_by_ridx [0:255];
integer snap_out    [0:255];
integer verdict_fence_faults = 0;
integer ridx_i;
initial for (ridx_i = 0; ridx_i < 256; ridx_i = ridx_i + 1) out_by_ridx[ridx_i] = 0;

function integer addr_ridx(input [63:0] a);
    reg [63:0] off;
begin
    off = a - PAYLOAD_BASE;
    addr_ridx = (off >> REGION_SHIFT) / NODE_COUNT;
end
endfunction
function integer addr_node(input [63:0] a);
    reg [63:0] off;
begin
    off = a - PAYLOAD_BASE;
    addr_node = (off >> REGION_SHIFT) % NODE_COUNT;
end
endfunction
function integer addr_frag(input [63:0] a);
    reg [63:0] off;
begin
    off = a - PAYLOAD_BASE;
    addr_frag = (off >> 12) % REGION_PAGES;
end
endfunction

integer wr_force_error = 0;       // the next N page descriptors fail
reg     cpl_hold = 1'b0;          // hold every completion (the fence test)
integer wr_error_node = -1;       // ... only for pages of this node (-1: any)
integer wr_error_delay = 0;       // extra cycles before a failed completion

// Park ONE page's completion while everything behind it goes on completing:
// the way a single TLP can be starved on a real fabric while its neighbours
// are not. The parked page stays outstanding for the fence until released.
// (cpl_hold and wr_error_delay both stall the whole queue, which is a
// different, harsher case - the stage fills and the node halts, H4.)
integer park_req   = 0;           // park the next N page completions ...
integer park_node  = -1;          // ... of this node (-1: any)
reg     park_release = 1'b0;      // level: let the parked completion go
reg     parked     = 1'b0;
reg [DMA_TAG_WIDTH-1:0] parked_tag  = 16'd0;
integer parked_ridx = 0;

// Accept descriptors into the queues every cycle they are offered.
always @(posedge clk) if (!rst && wr_desc_valid && wr_desc_ready) begin
    wq_addr[wq_wr % WQ] = wr_desc_dma_addr;
    wq_ram [wq_wr % WQ] = wr_desc_ram_addr;
    wq_len [wq_wr % WQ] = wr_desc_len;
    wq_tag [wq_wr % WQ] = wr_desc_tag;
    wq_wr = wq_wr + 1;
    page_descs = page_descs + 1;
    check(wr_desc_ram_sel == RAM_SEL_PAYLOAD, "a page descriptor selects the staging RAM");
    check(wr_desc_tag >= DMA_TAG_PAY_BASE && wr_desc_tag < DMA_TAG_PAY_BASE + 16'd16,
          "a page descriptor carries a pool tag");
    check(wr_desc_len == SLOT_BYTES[DMA_LEN_WIDTH-1:0], "a full fragment is one page");
    check(wr_desc_dma_addr[11:0] == 12'd0, "a page lands page-aligned");
    out_by_ridx[addr_ridx(wr_desc_dma_addr) % 256] = out_by_ridx[addr_ridx(wr_desc_dma_addr) % 256] + 1;
end

always @(posedge clk) if (!rst && cwr_desc_valid && cwr_desc_ready) begin
    // After the block above: a page accepted on the same edge is already in
    // flight when the verdict is offered, and the engine would take the
    // verdict first - so it counts against the fence.
    #0;
    vq_addr[vq_wr % WQ] = cwr_desc_dma_addr;
    vq_ram [vq_wr % WQ] = cwr_desc_ram_addr;
    vq_tag [vq_wr % WQ] = cwr_desc_tag;
    vq_wr = vq_wr + 1;
    verdict_descs = verdict_descs + 1;
    // The fence, as the engine sees it: at the moment the verdict is
    // offered, which pages are still in flight. Judged once the record's
    // round is known, below.
    for (ridx_i = 0; ridx_i < 256; ridx_i = ridx_i + 1) snap_out[ridx_i] = out_by_ridx[ridx_i];
    check(cwr_desc_ram_sel == RAM_SEL_VERDICT, "a verdict descriptor selects the record register");
    check(cwr_desc_tag == DMA_TAG_VERDICT, "a verdict descriptor carries the verdict tag");
    check(cwr_desc_len == SSRV_RECORD_BYTES[DMA_LEN_WIDTH-1:0], "a verdict descriptor is one record");
    check(cwr_desc_ram_addr == 0, "a verdict descriptor reads beat 0 of the record register");
end

// Read n beats from beat0 on through one of the wrapper's two read ports
// (ctrl = 1: the control DMA's), the way the engine does: a row at a time, a command only to the
// segments that hold wanted beats, each segment handshaken on its own, the
// responses collected per segment as they come. Beat k is segment k%2 of row
// k/2, so a page is 32 two-segment rows and a record is segment 0 of row 0.
reg [AXIS_DATA_WIDTH-1:0] rr_buf [0:SLOT_BEATS-1];
integer rr_got0, rr_got1;
reg     rr_ctrl = 1'b0;
wire [RAM_SEG_COUNT-1:0]                    rr_cmd_ready  = rr_ctrl ? ccram_rd_ready      : cram_rd_ready;
wire [RAM_SEG_COUNT-1:0]                    rr_resp_valid = rr_ctrl ? ccram_rd_resp_valid : cram_rd_resp_valid;
wire [RAM_SEG_COUNT*RAM_SEG_DATA_WIDTH-1:0] rr_resp_data  = rr_ctrl ? ccram_rd_data       : cram_rd_data;

task rr_cmd(input ctrl, input [RAM_SEG_COUNT-1:0] v);
begin
    if (ctrl) ccram_rd_valid = v; else cram_rd_valid = v;
end
endtask

task ram_read_beats(input ctrl, input integer beat0, input integer n);
    integer row, g, want0, want1, first0, first1;
    reg [RAM_SEG_ADDR_WIDTH-1:0] r;
    reg [RAM_SEG_COUNT-1:0] pend;
begin
    // segment s answers for beats beat0.. with k%2 == s, in order
    first0 = beat0 + (beat0 % 2);          // first even beat
    first1 = beat0 + 1 - (beat0 % 2);      // first odd beat
    want0  = (first0 < beat0 + n) ? (beat0 + n - first0 + 1) / 2 : 0;
    want1  = (first1 < beat0 + n) ? (beat0 + n - first1 + 1) / 2 : 0;
    rr_got0 = 0; rr_got1 = 0;
    rr_ctrl = ctrl;
    fork
        begin : producer
            for (row = beat0 / 2; row <= (beat0 + n - 1) / 2; row = row + 1) begin
                pend[0] = (2*row     >= beat0) && (2*row     < beat0 + n);
                pend[1] = (2*row + 1 >= beat0) && (2*row + 1 < beat0 + n);
                r = row;
                @(negedge clk);
                if (ctrl) begin
                    ccram_rd_sel  = {RAM_SEG_COUNT{RAM_SEL_VERDICT}};
                    ccram_rd_addr = {RAM_SEG_COUNT{r}};
                end else begin
                    cram_rd_sel   = {RAM_SEG_COUNT{RAM_SEL_PAYLOAD}};
                    cram_rd_addr  = {RAM_SEG_COUNT{r}};
                end
                rr_cmd(ctrl, pend);
                @(posedge clk);
                pend = pend & ~rr_cmd_ready;
                while (pend != 0) begin
                    @(negedge clk); rr_cmd(ctrl, pend);
                    @(posedge clk); pend = pend & ~rr_cmd_ready;
                end
            end
            @(negedge clk);
            rr_cmd(ctrl, {RAM_SEG_COUNT{1'b0}});
        end
        begin : consumer
            g = 0;
            while ((rr_got0 < want0 || rr_got1 < want1) && g < 4*n + 64) begin
                @(posedge clk); #0.1;
                if (rr_resp_valid[0] && rr_got0 < want0) begin
                    rr_buf[first0 + 2*rr_got0 - beat0] = rr_resp_data[0 +: RAM_SEG_DATA_WIDTH];
                    rr_got0 = rr_got0 + 1;
                end
                if (rr_resp_valid[1] && rr_got1 < want1) begin
                    rr_buf[first1 + 2*rr_got1 - beat0] = rr_resp_data[RAM_SEG_DATA_WIDTH +: RAM_SEG_DATA_WIDTH];
                    rr_got1 = rr_got1 + 1;
                end
                g = g + 1;
            end
            check(rr_got0 == want0 && rr_got1 == want1, "the read port did not answer every beat");
        end
    join
end
endtask

// The engine: pop, read, write to the host model, complete. Control first.
integer e_slot, e_beats, e_r, e_ridx;
reg [AXIS_DATA_WIDTH-1:0] e_row;
reg [63:0] e_addr, e_rec_round;
reg [3:0]  e_err;
reg [DMA_TAG_WIDTH-1:0] e_tag;

initial begin : write_dma_engine
    forever begin
        @(negedge clk);
        // A parked completion goes out on release, ahead of whatever the
        // queues hold - it was accepted long before.
        if (!rst && parked && park_release) begin
            out_by_ridx[parked_ridx] = out_by_ridx[parked_ridx] - 1;
            wr_status_tag   = parked_tag;
            wr_status_error = 4'd0;
            wr_status_valid = 1'b1;
            parked = 1'b0;
            @(negedge clk);
            wr_status_valid = 1'b0;
        end
        if (!rst && vq_rd != vq_wr) begin
            // a verdict record, on the control DMA
            e_addr = vq_addr[vq_rd % WQ];
            e_tag  = vq_tag [vq_rd % WQ];
            ram_read_beats(1'b1, vq_ram[vq_rd % WQ] / BEAT_BYTES, 1);
            e_row  = rr_buf[0];
            e_slot = rec_next % REC_MAX;
            rec_key[e_slot]   = e_addr;
            rec_data[e_slot]  = e_row;
            rec_valid[e_slot] = 1'b1;
            rec_next = rec_next + 1;
            // The fence: no page of this record's round may have been
            // outstanding when the descriptor was offered.
            e_rec_round = cb64(e_row, SSRV_OFF_ROUND_ID);
            if (snap_out[e_rec_round[7:0]] != 0) begin
                verdict_fence_faults = verdict_fence_faults + 1;
                check(1'b0, $sformatf("verdict for round %0d was offered with %0d of its pages still in flight",
                                      e_rec_round, snap_out[e_rec_round[7:0]]));
            end
            repeat (dma_latency) @(posedge clk);
            while (cpl_hold) @(posedge clk);
            @(negedge clk);
            cwr_status_tag   = e_tag;
            cwr_status_error = 4'd0;
            cwr_status_valid = 1'b1;
            @(negedge clk);
            cwr_status_valid = 1'b0;
            vq_rd = vq_rd + 1;
        end else if (!rst && wq_rd != wq_wr) begin
            // a page, on the data DMA
            e_addr = wq_addr[wq_rd % WQ];
            e_tag  = wq_tag [wq_rd % WQ];
            e_beats = (wq_len[wq_rd % WQ] + BEAT_BYTES - 1) / BEAT_BYTES;
            e_err  = 4'd0;
            ram_read_beats(1'b0, wq_ram[wq_rd % WQ] / BEAT_BYTES, e_beats);
            e_slot = pg_next % PG_MAX; pg_next = pg_next + 1;
            pg_key[e_slot]   = e_addr;
            for (e_r = 0; e_r < e_beats; e_r = e_r + 1)
                pg_data[e_slot*SLOT_BEATS + e_r] = rr_buf[e_r];
            for (e_r = e_beats; e_r < SLOT_BEATS; e_r = e_r + 1)
                pg_data[e_slot*SLOT_BEATS + e_r] = {AXIS_DATA_WIDTH{1'b0}};
            pg_valid[e_slot] = 1'b1;
            if (wr_force_error > 0 && (wr_error_node < 0 || addr_node(e_addr) == wr_error_node)) begin
                e_err = 4'd2;
                wr_force_error = wr_force_error - 1;
                repeat (wr_error_delay) @(posedge clk);
            end

            repeat (dma_latency) @(posedge clk);
            while (cpl_hold) @(posedge clk);
            @(negedge clk);
            if (!parked && park_req > 0 && (park_node < 0 || addr_node(e_addr) == park_node)) begin
                // Parked: the bytes are in the host model, the completion is
                // not. It stays counted as outstanding for the fence.
                parked      = 1'b1;
                parked_tag  = e_tag;
                parked_ridx = addr_ridx(e_addr) % 256;
                park_req    = park_req - 1;
            end else begin
                e_ridx = addr_ridx(e_addr) % 256;
                out_by_ridx[e_ridx] = out_by_ridx[e_ridx] - 1;
                wr_status_tag   = e_tag;
                wr_status_error = e_err;
                wr_status_valid = 1'b1;
                @(negedge clk);
                wr_status_valid = 1'b0;
                wr_status_error = 4'd0;
            end
            wq_rd = wq_rd + 1;
        end
    end
end

task wait_verdicts(input integer want, input integer max_rounds);
    integer g;
begin
    g = 0;
    while (rec_next < want && g < max_rounds) begin
        wait_rounds(1);
        g = g + 1;
    end
    check(rec_next >= want, $sformatf("only %0d verdict records within %0d rounds, wanted %0d", rec_next, max_rounds, want));
end
endtask


// ############################################################################
//              SECTION 16 - RECORD AND PAGE DECODERS
// ############################################################################

// The most recent record, unpacked.
reg [63:0] rec_round, rec_seq, rec_addr;
reg [31:0] rec_run, rec_pcons;
reg [7:0]  rec_set, rec_pres, rec_nodes, rec_self;
reg [15:0] rec_fc [0:7];
integer    rec_k;
integer    rec_scan;

task decode_last_record;
begin
    decode_record(rec_next - 1);
end
endtask

// Record number n (0-based, in arrival order), unpacked into rec_*.
task decode_record(input integer n);
    integer s;
begin
    s = n % REC_MAX;
    rec_addr  = rec_key[s];
    rec_round = cb64(rec_data[s], SSRV_OFF_ROUND_ID);
    rec_seq   = cb64(rec_data[s], SSRV_OFF_SEQ);
    rec_run   = cb32(rec_data[s], SSRV_OFF_RUN_ID);
    rec_set   = cb8 (rec_data[s], SSRV_OFF_COMMIT_SET);
    rec_pres  = cb8 (rec_data[s], SSRV_OFF_PRESENT_SET);
    rec_nodes = cb8 (rec_data[s], SSRV_OFF_NODE_COUNT);
    rec_self  = cb8 (rec_data[s], SSRV_OFF_SELF_INDEX);
    rec_pcons = cb32(rec_data[s], SSRV_OFF_PROP_CONSUMER);
    for (rec_k = 0; rec_k < 8; rec_k = rec_k + 1)
        rec_fc[rec_k] = cb16(rec_data[s], SSRV_OFF_FRAG_COUNTS + 2*rec_k);
end
endtask

// Where page f of node k's region for round R must be.
function [63:0] page_addr(input [63:0] round, input integer node, input integer frag);
    reg [63:0] region;
begin
    region    = (round % (1 << HOST_DEPTH_LOG2)) * NODE_COUNT + node;
    page_addr = PAYLOAD_BASE + (region << REGION_SHIFT) + (frag << 12);
end
endfunction

// Check one page in the host model against what the peer sent.
task check_page(input [63:0] round, input integer node, input integer frag, input string ctx);
    integer s, b;
    reg [AXIS_DATA_WIDTH-1:0] hdr;
begin
    s = pg_find(page_addr(round, node, frag));
    check(s >= 0, $sformatf("%0s: page (round %0d, node %0d, frag %0d) never reached the host", ctx, round, node, frag));
    if (s >= 0) begin
        hdr = pg_data[s*SLOT_BEATS];
        check(cb64(hdr, SSR_OFF_ROUND_ID) == round,       $sformatf("%0s: page header round", ctx));
        check(cb8 (hdr, SSR_OFF_NODE_ID)  == node[7:0],   $sformatf("%0s: page header node", ctx));
        check(cb16(hdr, SSR_OFF_FRAG_IDX) == frag[15:0],  $sformatf("%0s: page header frag_idx", ctx));
        check(cb8 (hdr, SSR_OFF_KIND)     == SSR_KIND_PAYLOAD, $sformatf("%0s: page header kind", ctx));
        check(cb16(hdr, SSR_OFF_LENGTH)   == FRAG_BYTES[15:0], $sformatf("%0s: page header length", ctx));
        for (b = 0; b < FRAG_BEATS; b = b + 1)
            if (pg_data[s*SLOT_BEATS + 1 + b] !== peer_word(node, round, frag, b)) begin
                check(1'b0, $sformatf("%0s: page (round %0d, node %0d, frag %0d) beat %0d is wrong", ctx, round, node, frag, b+1));
                b = FRAG_BEATS;
            end
        checks = checks + 1;
    end
end
endtask


// ############################################################################
//              SECTION 17 - THE RECEIVE COUNTER MODEL
// ############################################################################
// Group E checks the rejection ladder by arithmetic: after every injection the
// bench knows exactly what every counter should read.

integer inj_parsed   = 0;
integer inj_accepted = 0;

localparam integer RUNG_FOREIGN   = 0;
localparam integer RUNG_MALFORMED = 1;
localparam integer RUNG_WINDOW    = 2;
localparam integer RUNG_MEMBER    = 3;
localparam integer RUNG_SOUND     = 4;
localparam integer RUNG_RUN       = 5;
localparam integer RUNG_ROUND     = 6;
localparam integer RUNG_CTRL_LATE = 7;
localparam integer RUNG_ACK       = 8;   // ACK_DISAGREE: a control frame whose ack is not ours

integer exp_rung [0:8];
integer rung_i;

task rx_verify(input string ctx);
begin
    csr_expect(REG_RX_FRAMES,     peer_frames_sent + inj_parsed,   $sformatf("%0s: RX_FRAME_COUNT", ctx));
    csr_expect(REG_RX_ACCEPT,    peer_frames_sent - peer_ctrl_disagree + inj_accepted,
               $sformatf("%0s: RX_ACCEPT_COUNT", ctx));
    csr_expect(REG_RX_ACK_DISAGREE, exp_rung[RUNG_ACK] + peer_ctrl_disagree,
               $sformatf("%0s: RX_ACK_DISAGREE", ctx));
    // RUNG_FOREIGN has no counter: a non-SSR frame reaching ssr_rx_engine is a
    // FAULT bit, checked at the end of the run.
    csr_expect(REG_RX_MALFORMED, exp_rung[RUNG_MALFORMED], $sformatf("%0s: RX_MALFORMED_COUNT", ctx));
    csr_expect(REG_RX_WINDOW_DROP,    exp_rung[RUNG_WINDOW],    $sformatf("%0s: RX_WINDOW_DROP", ctx));
    csr_expect(REG_RX_MEMBER_DROP,    exp_rung[RUNG_MEMBER],    $sformatf("%0s: RX_MEMBER_DROP", ctx));
    csr_expect(REG_RX_SOUND_DROP,     exp_rung[RUNG_SOUND],     $sformatf("%0s: RX_SOUND_DROP", ctx));
    csr_expect(REG_RX_RUN_DROP,       exp_rung[RUNG_RUN],       $sformatf("%0s: RX_RUN_DROP", ctx));
    csr_expect(REG_RX_ROUND_DROP,     exp_rung[RUNG_ROUND],     $sformatf("%0s: RX_ROUND_DROP", ctx));
    csr_expect(REG_RX_CTRL_LATE, exp_rung[RUNG_CTRL_LATE], $sformatf("%0s: RX_CTRL_LATE", ctx));
end
endtask

task inject_and_settle;
    integer g;
begin
    inj_req = 1'b1;
    g = 0;
    while (inj_req && g < 4*ROUND_CYCLES) begin @(posedge clk); g = g + 1; end
    if (inj_req) begin
        errors = errors + 1;
        $display("[%0t] ERROR: the injected frame was never sent", $realtime);
        inj_req = 1'b0;
    end
    @(posedge dut.round_start_pulse);
    repeat (ROUND_CYCLES/2) @(posedge clk);
end
endtask

task expect_rung(input integer rung, input integer also_accepted, input string ctx);
begin
    inj_parsed = inj_parsed + 1;
    if (also_accepted) inj_accepted = inj_accepted + 1;
    exp_rung[rung] = exp_rung[rung] + 1;
    inject_and_settle;
    rx_verify(ctx);
end
endtask


// ############################################################################
//                      SECTION 18 - TEST BODIES
// ############################################################################

integer n, k;
reg [31:0] rd, rd0, rd1, rd2;
reg [95:0]             csr_ts;
reg [PTP_TS_WIDTH-1:0] model_ts;
integer frames_before, cpl_before, if_cpl_before, mux_dma_before;
integer descs_before, hostrx_before, entries_armed;
integer t_node, t_frag, round_guard;
reg [31:0] snap_a, snap_b, snap_c;
reg [63:0] want_addr, prev_seq;
integer pages_before, verdicts_before;


// ============================================================================
//                          GROUP A - BRING-UP
// ============================================================================

task test_A0_block_decode;
begin
    banner("A0  one register page: identity, geometry, a scratch register, delivery off at reset");

    csr_read(REG_TYPE, rd);
    check(rd == 32'h53535201, $sformatf("TYPE %08h, expected 53535201", rd));
    csr_read(REG_VERSION, rd);
    check(rd == 32'h00000200, $sformatf("VERSION %08h, expected 00000200", rd));

    csr_write(REG_SCRATCH, 32'hA5A5_1234);
    csr_read(REG_SCRATCH, rd);
    check(rd == 32'hA5A5_1234, "SCRATCH must read back what was written");

    // What the host is built without and has to read: who it is, how long a
    // round is, how big a page is.
    csr_read(REG_NODE, rd);
    check(rd[7:0] == NODE_ID[7:0] && rd[15:8] == NODE_COUNT[7:0],
          $sformatf("NODE %08h, expected id %0d count %0d", rd, NODE_ID, NODE_COUNT));
    csr_expect(REG_ROUND_NS,   ROUND_LENGTH_NS, "ROUND_NS");
    csr_expect(REG_PAGE_BYTES, SLOT_BYTES,      "PAGE_BYTES");
    csr_expect(REG_FAULT,      32'd0,           "FAULT at reset");

    csr_read(REG_DLV_CONTROL, rd);
    check(rd == 32'd0, "delivery CONTROL must reset to 0: nothing is written to the host until told");
    csr_read(REG_CORE_CONTROL, rd);
    check(rd == 32'd0, "core CONTROL must reset to 0");
end
endtask

task test_A1_activate;
begin
    banner("A1  the core comes up through the CSR and starts turning rounds");

    // Delivery is programmed the way a driver would at start-up: both rings,
    // then both enables.
    csr_write(REG_PAY_BASE_LO, PAYLOAD_BASE[31:0]);
    csr_write(REG_PAY_BASE_HI, PAYLOAD_BASE[63:32]);
    csr_write(REG_VER_BASE_LO, VERDICT_BASE[31:0]);
    csr_write(REG_VER_BASE_HI, VERDICT_BASE[63:32]);
    csr_write(REG_DLV_CONTROL,     DLV_CTRL_BOTH);
    csr_expect(REG_PAY_BASE_HI, PAYLOAD_BASE[63:32], "PAYLOAD_BASE_HI");
    csr_expect(REG_VER_BASE_LO, VERDICT_BASE[31:0],  "VERDICT_BASE_LO");
    csr_expect(REG_DLV_CONTROL,     DLV_CTRL_BOTH,       "delivery CONTROL");

    // The proposal ring: base, depth, enable. After this, proposing is
    // writing entries and ringing PRODUCER.
    prop_ring_setup;
    csr_expect(REG_PROP_DEPTH_LOG2, PROP_DEPTH_LOG2, "proposal RING_DEPTH_LOG2");
    csr_expect(REG_PROP_BASE_LO,    PROP_RING_BASE[31:0], "proposal RING_BASE_LO");

    csr_write(REG_CFG_RUN_ID,  RUN_ID_A);
    csr_write(REG_CFG_MEMBERSHIP,  32'h0000_0007);
    csr_write(REG_CFG_EFF_ROUND_LO, 32'h0000_0100);
    csr_write(REG_CORE_CONTROL,     CORE_CTRL_ACTIVATE);

    wait (dut.core_inst.state_reg == 2'd2);
    wait_rounds(3);
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "the core must not be halted after activation");
    check(rd[1] == 1'b1, "timing should be armed");
    check(rd[2] == 1'b1, "the PTP time base should read valid");
end
endtask

task test_A2_geometry_and_state;
    reg [31:0] round_lo_a, round_lo_b;
    reg [63:0] tod_round;
begin
    banner("A2  the geometry and run state a driver reads back");

    // The driver is built with none of these numbers; it reads them. If they
    // disagree with the bench's own arithmetic then every page check in group
    // C is looking in the wrong place.
    csr_read(REG_GEOMETRY, rd);
    check(rd[7:0]   == NODE_COUNT[7:0],        $sformatf("GEOMETRY node_count %0d", rd[7:0]));
    check(rd[15:8]  == REGION_SHIFT[7:0],      $sformatf("GEOMETRY region_shift %0d, expected %0d", rd[15:8], REGION_SHIFT));
    check(rd[23:16] == HOST_DEPTH_LOG2[7:0],   $sformatf("GEOMETRY payload depth log2 %0d", rd[23:16]));
    check(rd[31:24] == VERDICT_DEPTH_LOG2[7:0],$sformatf("GEOMETRY verdict depth log2 %0d", rd[31:24]));
    csr_expect(REG_CUR_RUN_ID, RUN_ID_A, "CURRENT_RUN_ID");
    csr_read(REG_CUR_SOUND_SET, rd);
    check(rd[NODE_COUNT-1:0] == 3'b111,
          $sformatf("CURRENT_SOUND_SET %02h, every node should still be believed", rd[7:0]));

    csr_read(REG_CUR_ROUND_LO, round_lo_a);
    tod_round = (time_seconds * 64'd1_000_000_000 + time_nanoseconds) / ROUND_LENGTH_NS;
    csr_read(REG_CUR_ROUND_HI, rd);
    check({rd, round_lo_a} != 64'd0, "CURRENT_ROUND_ID should not be zero on a live node");
    // The round is the ToD's, and nothing else's. Everything else in the bench
    // times itself off the DUT's own round, so this is the one check that the
    // core reads the 96-bit ToD port - {sec, ns, fns} - and reads it right.
    // (A CSR read takes a few cycles, so the round may have just turned.)
    check({rd, round_lo_a} == tod_round || {rd, round_lo_a} + 64'd1 == tod_round,
          $sformatf("CURRENT_ROUND_ID %0d, the ToD says %0d", {rd, round_lo_a}, tod_round));
    wait_rounds(2);
    csr_read(REG_CUR_ROUND_LO, round_lo_b);
    check(round_lo_b != round_lo_a, "CURRENT_ROUND_ID did not advance over two rounds");
end
endtask


// ============================================================================
//                      GROUP B - THE TRANSMIT PATH
// ============================================================================

task test_B1_empty_queue;
begin
    banner("B1  an empty queue still speaks every round: a control frame, and nothing after it");

    frames_before = ssr_ctrl_frames;
    wait_rounds(2);
    check(ssr_ctrl_frames > frames_before, "no control frame reached the port with an empty queue");
    check(ssr_empty_ctrl > 0, "rounds with an empty queue should end with nothing sent");
    check(ssr_payload_frames == 0, "no payload frame should have gone out with nothing queued");

    csr_expect(REG_TX_CTRL_FRAMES,  ssr_ctrl_frames, "TX_CTRL_FRAMES");
    csr_expect(REG_TX_EMPTY, ssr_empty_ctrl,  "TX_EMPTY_COUNT");
    csr_expect(REG_TX_PAY_FRAMES,   32'd0,           "TX_PAY_FRAMES");
end
endtask

task test_B2_proposal_reaches_the_port;
begin
    banner("B2  four proposals posted to the ring go out as four fragments, beats 1..63 each");

    descs_before  = descs_seen;
    entries_armed = 4;
    post(entries_armed);
    wait_rounds(6);

    check(descs_seen == descs_before + entries_armed,
          $sformatf("expected %0d descriptors, saw %0d", entries_armed, descs_seen - descs_before));
    csr_read(REG_PROP_STATUS, rd);
    check(rd[PROP_ST_IDLE] == 1'b1 && rd[PROP_ST_ERROR] == 1'b0, "the reads should complete without error");
    csr_expect(REG_PROP_READS,    descs_seen, "proposal READS");
    csr_expect(REG_PROP_CONSUMER, posted,     "proposal CONSUMER");
    csr_expect(REG_PROP_FETCH,    posted,     "proposal FETCH");

    check(ssr_payload_frames == 4,
          $sformatf("%0d frames carried a payload, expected exactly 4", ssr_payload_frames));
    check(ssr_payload_beats == ssr_payload_frames*FRAG_BEATS,
          $sformatf("%0d payload beats for %0d frames, expected %0d",
                    ssr_payload_beats, ssr_payload_frames, ssr_payload_frames*FRAG_BEATS));
    check(exp_head == exp_tail, "every committed slot left as a fragment");

    csr_read(REG_TX_CTRL_FRAMES, rd);
    csr_read(REG_TX_PAY_FRAMES, rd2);
    check(rd + rd2 == ssr_frames, $sformatf("TX_CTRL_FRAMES + TX_PAY_FRAMES = %0d, the monitor saw %0d SSR frames",
                                            rd + rd2, ssr_frames));
    csr_expect(REG_TX_PAY_FRAMES,  4,          "TX_PAY_FRAMES");
    csr_expect(REG_FAULT, 32'd0, "FAULT (TX_LEN_MISMATCH and friends)");
end
endtask

task test_B3_completions;
begin
    banner("B3  SSR completions are consumed and the transmit timestamp is published");

    check(ssr_cpl_model_count > 0, "the port model never returned an SSR completion");
    check(if_cpl_seen == 0,
          $sformatf("%0d completions reached the interface before any host frame was sent", if_cpl_seen));
    csr_expect(REG_TX_CPL_COUNT, ssr_cpl_model_count, "TX_CPL_COUNT");

    cpl_before = ssr_cpl_model_count;
    wait (ssr_cpl_model_count > cpl_before);
    model_ts = last_ssr_cpl_ts_model;
    repeat (4) @(posedge clk);
    csr_read(REG_TX_CPL_TS_0, rd0);
    csr_read(REG_TX_CPL_TS_1, rd1);
    csr_read(REG_TX_CPL_TS_2, rd2);
    // PTP_TS_WIDTH bits, zero-extended to 96: on the AU200 the 48-bit
    // relative timestamp, so TX_CPL_TS_2 and the top half of _1 read 0.
    csr_ts = {rd2, rd1, rd0};
    check(csr_ts == {{(96-PTP_TS_WIDTH){1'b0}}, model_ts},
          $sformatf("TX_CPL_TS reads %024h, the port reported %024h", csr_ts, model_ts));
    check(model_ts != {PTP_TS_WIDTH{1'b0}}, "the captured timestamp should not be zero");
end
endtask

task test_B4_host_frame_crosses;
begin
    banner("B4  a host frame crosses the mux untouched and its completion is forwarded");

    if_cpl_before = if_cpl_seen;
    csr_read(REG_TX_HOST_FRAMES, mux_dma_before);
    check(mux_dma_before == 0, "no host frame should have crossed the mux yet");

    for (n = 0; n < 4; n = n + 1) begin
        send_host_frame(n);
        repeat (20) @(posedge clk);
    end
    wait_rounds(2);

    check(host_frames_out == 4, $sformatf("%0d host frames reached the port, expected 4", host_frames_out));
    csr_expect(REG_TX_HOST_FRAMES, 4, "TX_MUX_DMA_FRAMES");
    check(if_cpl_seen - if_cpl_before == 4,
          $sformatf("%0d host completions were forwarded, expected 4", if_cpl_seen - if_cpl_before));
    check(last_if_cpl_tag == host_tag(3),
          $sformatf("last forwarded completion carried tag %04h, expected %04h", last_if_cpl_tag, host_tag(3)));
end
endtask

task test_B5_contention;
begin
    banner("B5  host and SSR frames contend for the port and are never interleaved");

    post(4);
    fork
        begin : host_pressure
            for (n = 4; n < 24; n = n + 1) send_host_frame(n);
        end
        begin : run_rounds
            wait_rounds(6);
        end
    join
    wait_rounds(4);

    check(host_frames_out == 24, $sformatf("%0d host frames reached the port, expected 24", host_frames_out));
    check(host_exp_head == host_exp_tail,
          $sformatf("%0d host frames were sent but never left the port", host_exp_tail - host_exp_head));
    csr_expect(REG_TX_HOST_FRAMES, 24, "TX_MUX_DMA_FRAMES");

    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "the core must still be running");
    csr_expect(REG_FAULT, 32'd0, "FAULT (TX_LEN_MISMATCH and friends)");
    csr_expect(REG_TX_CPL_COUNT, ssr_cpl_model_count, "TX_CPL_COUNT");
    check(if_cpl_seen == host_cpl_model_count,
          $sformatf("%0d host completions forwarded, the port returned %0d", if_cpl_seen, host_cpl_model_count));
end
endtask

task test_B6_port_back_pressure;
begin
    banner("B6  the port back-pressures mid frame and nothing is lost or corrupted");

    frames_before  = ssr_payload_frames;
    tx_bp_enable   = 1'b1;
    post(4);
    fork
        begin : bp_host
            for (n = 24; n < 34; n = n + 1) send_host_frame(n);
        end
        begin : bp_rounds
            wait_rounds(6);
        end
    join
    wait_rounds(4);
    tx_bp_enable = 1'b0;
    wait_rounds(2);

    check(ssr_payload_frames >= frames_before + 4,
          $sformatf("only %0d payload frames went out under back pressure, expected 4",
                    ssr_payload_frames - frames_before));
    check(host_exp_head == host_exp_tail,
          $sformatf("%0d host frames were sent under back pressure but never left the port",
                    host_exp_tail - host_exp_head));
    check(host_frames_out == 34, $sformatf("%0d host frames reached the port, expected 34", host_frames_out));
    csr_expect(REG_FAULT, 32'd0, "FAULT (TX_LEN_MISMATCH and friends)");
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "the core must still be running after back pressure");
end
endtask

task test_B7_proposal_backlog;
    integer per [0:7];
    integer n_rounds, total;
begin
    banner("B7  a backlog posted after the cutoff: nothing more that round, then five, then three");

    // Eight entries, posted just after this round's transmit cutoff. Nothing
    // may start in this round any more - a fragment started now could land
    // after a peer's boundary - so the round must end with what it had.
    // The next round then sends FIVE, the full budget, which the old proposal
    // path could not keep: at a quarter of line rate only three fragments
    // fitted in a round. The round after sends the other three.
    descs_before  = descs_seen;
    frames_before = ssr_payload_frames;
    entries_armed = SLOT_COUNT;
    @(posedge dut.round_start_pulse);
    wait (dut.core_tx_pay_open == 1'b1);
    wait (dut.core_tx_pay_open == 1'b0);                 // the cutoff
    post(entries_armed);

    @(ev_ctrl_frame);                                    // the round we posted in is over
    check(last_round_frags == 0,
          $sformatf("%0d fragments started after the cutoff of round %0d", last_round_frags, last_frags_round));

    n_rounds = 0; total = 0; round_guard = 0;
    while (total < entries_armed && round_guard < 12) begin
        @(ev_ctrl_frame);
        round_guard = round_guard + 1;
        if (n_rounds < 8) per[n_rounds] = last_round_frags;
        n_rounds = n_rounds + 1;
        total = total + last_round_frags;
    end
    wait_rounds(2);

    check(descs_seen == descs_before + entries_armed,
          $sformatf("%0d of %0d backlog descriptors were posted", descs_seen - descs_before, entries_armed));
    check(n_rounds == 2 && per[0] == FRAGS_PER_ROUND && per[1] == entries_armed - FRAGS_PER_ROUND,
          $sformatf("the backlog went out as %0d rounds (%0d, %0d, ...), expected %0d then %0d",
                    n_rounds, per[0], n_rounds > 1 ? per[1] : 0, FRAGS_PER_ROUND, entries_armed - FRAGS_PER_ROUND));
    check(exp_head == exp_tail, $sformatf("%0d committed slots never left as a frame", exp_tail - exp_head));
    check(ssr_payload_frames == frames_before + entries_armed,
          $sformatf("%0d fragments for %0d entries", ssr_payload_frames - frames_before, entries_armed));
    check(ssr_tx_bubbles == 0, $sformatf("%0d cycles with a gap inside an SSR frame", ssr_tx_bubbles));
    check(rd_inflight_max > 1, $sformatf("proposal reads were never in flight together (max %0d)", rd_inflight_max));
    csr_expect(REG_TX_OVERRUN, 32'd0, "TX_OVERRUN_COUNT");
    csr_expect(REG_TX_MISSED,  32'd0, "TX_MISSED_COUNT");
end
endtask

task test_B8_posted_mid_round;
    reg [63:0] post_round;
begin
    banner("B8  a proposal posted in the middle of a round goes out in that round");

    // The reason there is no announcement any more (docs/count_ack.md): what
    // the host posts after this round's control frame is not held for the
    // next one. A microsecond in, two entries: read in 0.4..1.2 us, then two
    // paced fragments, both well before the cutoff.
    frames_before = ssr_payload_frames;
    @(posedge dut.round_start_pulse);
    post_round = dut.current_round_id;
    wait (dut.core_inst.round_offset_ns >= 1000);
    post(2);
    @(ev_ctrl_frame);                                    // round post_round is over
    check(last_frags_round == post_round && last_round_frags == 2,
          $sformatf("round %0d sent %0d fragments (monitor: round %0d); both proposals posted in it should have gone in it",
                    post_round, last_round_frags, last_frags_round));
    check(ssr_payload_frames == frames_before + 2, "two fragments, and no more");
    check(exp_head == exp_tail, "every posted entry left");
    wait_verdicts(rec_next + 2, 6);
    // Its record says so: our own frag_count for that round is 2.
    rec_scan = (rec_next > 4) ? rec_next - 4 : 0;
    rec_round = 0;
    while (rec_scan < rec_next && rec_round != post_round) begin
        decode_record(rec_scan);
        rec_scan = rec_scan + 1;
    end
    check(rec_round == post_round && rec_fc[NODE_ID] == 16'd2,
          $sformatf("the record for round %0d says we sent %0d", post_round, rec_fc[NODE_ID]));
end
endtask


// ============================================================================
//                  GROUP C - THE RECEIVE PATH, ACCEPTED
// ============================================================================

task test_C1_pages_and_a_record;
begin
    banner("C1  a peer's fragments become host pages, and the decision becomes a record");

    // The whole receive half in one test: two peers each send a control frame
    // and two fragments every round; each fragment is staged and DMA'd to its
    // page; at the next round's control deadline the core decides the round
    // and the verdict record follows, after the fence. Everything is checked in the host
    // memory model, which is the last place the bytes exist before they are
    // the host's.
    wait_verdicts(rec_next + 2, 12);
    decode_last_record;

    check(rec_addr == VERDICT_BASE + (rec_seq % (1 << VERDICT_DEPTH_LOG2)) * SSRV_RECORD_BYTES,
          $sformatf("record %0d landed at %h, expected ring entry seq mod D", rec_seq, rec_addr));
    check(rec_run == RUN_ID_A, $sformatf("record run_id %08h, the run is %08h", rec_run, RUN_ID_A));
    check(rec_nodes == NODE_COUNT[7:0], "record node_count must describe the cluster");
    check(rec_self == NODE_ID[7:0], "record self_index must be this node");
    check(rec_round != 64'd0, "a decided round id should not be zero this late in the run");
    check(rec_set == 8'b111,  $sformatf("commit_set (the sound set) %02h does not name all three nodes", rec_set));
    check(rec_pres == 8'b111, $sformatf("present_set %02h says a node's pages did not all reach the host", rec_pres));
    for (t_node = 0; t_node < NODE_COUNT; t_node = t_node + 1) if (t_node != NODE_ID)
        check(rec_fc[t_node] == peer_frags[15:0],
              $sformatf("node %0d frag_count %0d, the peer sent %0d", t_node, rec_fc[t_node], peer_frags));
    check(rec_fc[NODE_ID] == 16'd0, "our own frag_count this round should be 0: nothing was queued");
    // Every proposal posted so far is out, so the record's consumer is the
    // host's producer: the host can reuse the whole ring without an MMIO read.
    check(rec_pcons == posted, $sformatf("record proposal_consumer %0d, the host has posted %0d", rec_pcons, posted));
    for (t_node = NODE_COUNT; t_node < 8; t_node = t_node + 1)
        check(rec_fc[t_node] == 16'd0, "frag_count entries past the cluster are zero");

    // ---- the pages, byte for byte, header on top ----
    for (t_node = 0; t_node < NODE_COUNT; t_node = t_node + 1) if (t_node != NODE_ID)
        for (t_frag = 0; t_frag < peer_frags; t_frag = t_frag + 1)
            check_page(rec_round, t_node, t_frag, "C1");
    check(pg_find(page_addr(rec_round, NODE_ID, 0)) < 0, "our own region must never be written");

    // ---- the fence held on every record so far ----
    check(verdict_fence_faults == 0, "a verdict overtook its pages");

    // ---- nothing was dropped on the way ----
    // Read in the quiet middle of a round: every frame of the round has
    // arrived and every page of it has been described.
    goto_midround;
    csr_expect(REG_FAULT,         32'd0, "FAULT: no foreign frame, stage or tag contract broken");
    csr_expect(REG_RX_MALFORMED, 32'd0, "RX_MALFORMED_COUNT");
    csr_expect(REG_RX_ROUND_DROP,     32'd0, "RX_ROUND_DROP");
    csr_expect(REG_RX_CTRL_LATE, 32'd0, "RX_CTRL_LATE");
    csr_expect(REG_RX_CTRL,      peer_ctrl_sent - peer_ctrl_disagree, "RX_CTRL_COUNT");
    csr_expect(REG_RX_ACK_DISAGREE, peer_ctrl_disagree, "RX_ACK_DISAGREE: every peer agreed");
    csr_expect(REG_STAGE_FULL,      32'd0, "STAGE_FULL");
    csr_expect(REG_PAY_ERR,         32'd0, "PAY_ERR");
    csr_expect(REG_PRES_LATE,       32'd0, "PRES_LATE");
    csr_expect(REG_VERDICT_STALE,       32'd0, "VERDICT_STALE");
    csr_expect(REG_VERDICT_OVERFLOW,    32'd0, "VERDICT_OVERFLOW");
    csr_read(REG_PAY_DESC, rd);
    check(rd == page_descs, $sformatf("PAY_DESC reads %0d, the engine saw %0d page descriptors", rd, page_descs));
    csr_read(REG_VERDICT_RECORDS, rd);
    check(rd == rec_next, $sformatf("VERDICT_RECORDS reads %0d, the engine wrote %0d", rd, rec_next));
    csr_read(REG_SEQ_LO, rd);
    check(rd == rec_next, $sformatf("SEQ reads %0d, expected %0d", rd, rec_next));

    csr_read(REG_ROUND_COUNT_LO,  rd0);
    csr_read(REG_COMMIT_COUNT_LO, rd1);
    check(rd0 > 32'd0, "ROUND_COUNT should have advanced");
    check(rd1 > 32'd0, "COMMIT_COUNT should have advanced - the node is deciding nothing");
end
endtask

task test_C2_sends_nothing;
begin
    banner("C2  a peer that sends nothing is still a witness: a zero count, and no page");

    peer_zero_mask[PEER_B] = 1'b1;
    wait_rounds(4);
    wait_verdicts(rec_next + 1, 8);
    decode_last_record;

    check(rec_set[PEER_B],  "the empty peer agreed with us, so it stays in the sound set");
    check(rec_pres[PEER_B], "nothing of the empty peer's failed to reach the host");
    check(rec_fc[PEER_B] == 16'd0, $sformatf("the empty peer sent nothing but the record says %0d fragments", rec_fc[PEER_B]));
    check(pg_find(page_addr(rec_round, PEER_B, 0)) < 0, "the empty peer wrote no page this round");

    // ... and the peer that did send is untouched by its neighbour's silence.
    check(rec_fc[PEER_A] == peer_frags[15:0], "the other peer's frag_count changed when one went empty");
    for (t_frag = 0; t_frag < peer_frags; t_frag = t_frag + 1)
        check_page(rec_round, PEER_A, t_frag, "C2");

    // seq is monotone and the ring address follows it.
    prev_seq = rec_seq;
    wait_verdicts(rec_next + 1, 8);
    decode_last_record;
    check(rec_seq == prev_seq + 1, $sformatf("seq went %0d -> %0d", prev_seq, rec_seq));
    check(rec_addr == VERDICT_BASE + (rec_seq % (1 << VERDICT_DEPTH_LOG2)) * SSRV_RECORD_BYTES,
          "the next record is at the next ring entry");

    peer_zero_mask[PEER_B] = 1'b0;
    wait_rounds(3);
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "an empty round from a peer should not have halted the node");
end
endtask

// ============================================================================
//                  GROUP D - THE RECEIVE DEMUX
// ============================================================================

task test_D1_host_route;
begin
    banner("D1  a host-bound frame is forwarded whole, all four beats of it");

    hostrx_before = hostrx_frames;
    inj_defaults;
    inj_ethertype = DMA_ETHERTYPE_TB;
    inj_beats     = 3;
    inj_len       = 3*BEAT_BYTES;
    inject_and_settle;

    check(hostrx_frames == hostrx_before + 1,
          $sformatf("%0d frames reached the host RX port, expected 1", hostrx_frames - hostrx_before));
    check(hostrx_last_beats == 4,
          $sformatf("the forwarded frame was %0d beats, expected 4 (header + 3 payload)", hostrx_last_beats));
    rx_verify("D1");
end
endtask

task test_D2_unknown_ethertype_goes_to_the_host;
begin
    banner("D2  an unknown ethertype is the host's, not ours: forwarded, never dropped");

    hostrx_before = hostrx_frames;
    inj_defaults;
    inj_ethertype = JUNK_ETHERTYPE;
    inj_beats     = 1;
    inj_len       = BEAT_BYTES;
    inject_and_settle;

    check(hostrx_frames == hostrx_before + 1, "a plain IP frame must reach the host");
    check(hostrx_last_beats == 2, "and reach it whole");
    rx_verify("D2");
end
endtask


// ============================================================================
//              GROUP E - THE ssr_rx_engine REJECTION LADDER
// ============================================================================

task test_E0_baseline;
begin
    banner("E0  the counter model agrees with the hardware before anything is broken");
    rx_verify("E0");
end
endtask

task test_E1_length_past_the_limit;
begin
    banner("E1  malformed: a fragment declaring more payload than a page holds");
    inj_defaults;
    inj_len   = FRAG_BYTES + 1;
    inj_beats = FRAG_BEATS + 1;
    expect_rung(RUNG_MALFORMED, 0, "E1");
end
endtask

task test_E2_zero_length_payload;
begin
    banner("E2  malformed: a payload frame with length 0");
    inj_defaults;
    inj_len   = 16'd0;
    inj_beats = 2;
    expect_rung(RUNG_MALFORMED, 0, "E2");
end
endtask

task test_E3_frame_shorter_than_its_length;
begin
    banner("E3  malformed: the frame ends before the length the header promised");
    // Charged AFTER the header was accepted: accept AND malformed move, and
    // the staged slot is abandoned.
    inj_defaults;
    inj_len   = FRAG_BYTES[15:0];
    inj_beats = 10;
    expect_rung(RUNG_MALFORMED, 1, "E3");
    csr_expect(REG_FAULT, 32'd0, "FAULT: a dropped frame is not a length mismatch");
end
endtask

task test_E4_short_header_beat;
begin
    banner("E4  malformed: a header beat that is not a whole 64 bytes");
    inj_defaults;
    inj_kind      = SSR_KIND_CTRL;
    inj_keep_full = 1'b0;
    inj_len       = 16'd0;
    inj_beats     = 0;
    expect_rung(RUNG_MALFORMED, 0, "E4");
end
endtask

task test_E5_mac_flagged_the_frame;
begin
    banner("E5  malformed: the MAC marked the frame bad");
    inj_defaults;
    inj_bad_user = 1'b1;
    expect_rung(RUNG_MALFORMED, 0, "E5");
end
endtask

task test_E6_node_out_of_range;
begin
    banner("E6  member drop: a node id outside the cluster");
    inj_defaults;
    inj_node = NODE_COUNT[7:0];
    expect_rung(RUNG_MEMBER, 0, "E6");
end
endtask

task test_E7_frame_claiming_to_be_us;
begin
    banner("E7  member drop: a frame claiming to come from this node");
    inj_defaults;
    inj_node = NODE_ID[7:0];
    expect_rung(RUNG_MEMBER, 0, "E7");
end
endtask

task test_E8_wrong_run;
begin
    banner("E8  run drop: a frame from a different run of the protocol");
    inj_defaults;
    inj_run_core = 1'b0;
    inj_run      = RUN_ID_A ^ 32'h0000_00FF;
    expect_rung(RUNG_RUN, 0, "E8");
end
endtask

task test_E9_wrong_round;
begin
    banner("E9  round drop: a fragment for a round that is not the one in progress");
    inj_defaults;
    inj_round_off = 1;
    expect_rung(RUNG_ROUND, 0, "E9");
end
endtask

task test_E10_late_control_frame;
begin
    banner("E10 a control frame after the deadline is counted late and dropped");
    // The one time bound left in the receive path. The peers' own control
    // frames went inside the deadline; this one is sent once it has passed.
    inj_defaults;
    inj_kind     = SSR_KIND_CTRL;
    inj_ack_model= 1'b1;             // in every way a good control frame, but late
    inj_len      = 16'd0;
    inj_beats    = 0;
    inj_late     = 1'b1;
    expect_rung(RUNG_CTRL_LATE, 0, "E10");
    inj_late     = 1'b0;
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "a late control frame must not halt the node");
end
endtask

task test_E11_good_frame_after_all_that;
begin
    banner("E11 a well-formed fragment is still accepted after every rejection");
    // A repeat of the peer's fragment 0: the ladder accepts it and the page is
    // written again, byte for byte the same. The tracker does NOT count it -
    // the peer already delivered fragment 0, and a count is a prefix - so our
    // ack for the round is unchanged and the peers still agree with us.
    inj_defaults;
    inj_frag_idx = 16'd0;
    inj_parsed   = inj_parsed + 1;
    inj_accepted = inj_accepted + 1;
    inject_and_settle;
    rx_verify("E11");
end
endtask

task test_E12_control_frame_with_a_payload;
begin
    banner("E12 malformed: a control frame that carries payload beats");
    inj_defaults;
    inj_kind     = SSR_KIND_CTRL;
    inj_len      = 16'd0;
    inj_beats    = 2;
    expect_rung(RUNG_MALFORMED, 0, "E12");
end
endtask

task test_E13_fragment_past_the_budget;
begin
    banner("E13 malformed: frag_idx at or past the round's budget, and at the format's ceiling");
    // The host region of (round, node) is FRAGS_PER_ROUND pages; one past it
    // is the next node's first page.
    inj_defaults;
    inj_frag_idx = FRAGS_PER_ROUND[15:0];
    expect_rung(RUNG_MALFORMED, 0, "E13a");
    inj_defaults;
    inj_frag_idx = SSR_MAX_FRAGS[15:0] - 16'd1;
    expect_rung(RUNG_MALFORMED, 0, "E13b");
end
endtask

task test_E14_ack_disagrees;
begin
    banner("E14 a control frame whose ack differs from ours: counted, and no witness");
    // A second control frame from a peer, inside the deadline, carrying the
    // peer's ack with one byte off. Everything else about it is right, so only
    // the ack rung can refuse it. The peer's own frame this round agreed, so
    // the peer stays a witness and the node runs on.
    inj_defaults;
    inj_kind      = SSR_KIND_CTRL;
    inj_node      = PEER_A[7:0];
    inj_len       = 16'd0;
    inj_beats     = 0;
    inj_early     = 1'b1;
    inj_ack_model = 1'b1;
    inj_ack       = 64'h0000_0000_0000_0001;   // node 0's byte, one off
    inj_parsed = inj_parsed + 1;
    exp_rung[RUNG_ACK] = exp_rung[RUNG_ACK] + 1;
    inject_and_settle;
    rx_verify("E14");
    csr_read(REG_CUR_SOUND_SET, rd);
    check(rd[PEER_A] == 1'b1, "the peer's own frame agreed: it is still in the sound set");
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "a stray disagreeing frame is not a reason to halt");
end
endtask


// ============================================================================
//              GROUP F - DELIVERY UNDER PRESSURE
// ============================================================================

task test_F1_payload_delivery_off;
begin
    banner("F1  with payload delivery off the stage holds the frames; back on, they all go out");

    // A driver that has not posted its ring yet. Frames are still received
    // and staged - three rounds of them fit in the sixteen slots - and nothing
    // is written until the enable comes. Then every staged frame leaves, in
    // order, and fresh rounds are whole.
    //
    // NOT tested here, because it is destructive: leave delivery off past the
    // stage's capacity and frames are DROPPED (STAGE_FULL). A dropped frame is
    // not staged, so ssr_presence_tracker does not count it, so this node's ack
    // falls short of what the peers hold - and it halts on HALT_NO_AGREED_ROW,
    // because nobody's vector matches its own. That is the honest outcome
    // (H4): a node whose host has stopped taking delivery cannot keep
    // promising to deliver.
    csr_read(REG_STAGE_FULL, snap_a);
    csr_write(REG_DLV_CONTROL, DLV_CTRL_VERDICT);        // payload off, verdicts on
    repeat (40) @(posedge clk);                          // a descriptor already offered is still taken
    pages_before = page_descs;
    wait_rounds(3);
    check(page_descs == pages_before, $sformatf("%0d page descriptors were issued with payload delivery off", page_descs - pages_before));
    csr_expect(REG_STAGE_FULL, snap_a, "STAGE_FULL: three rounds fit in the stage");
    csr_read(REG_DLV_STATUS, rd);
    check(rd[3:0] == 4'b1111, "with nothing issued, every unit is idle");
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "the protocol keeps running while the host is late");

    csr_write(REG_DLV_CONTROL, DLV_CTRL_BOTH);
    wait_rounds(4);
    check(page_descs >= pages_before + 3*2*peer_frags, "the staged frames and the new ones went out");
    csr_expect(REG_STAGE_FULL, snap_a, "STAGE_FULL never moved");
    wait_verdicts(rec_next + 1, 6);
    decode_last_record;
    check(rec_pres == 8'b111, $sformatf("present_set %02h after recovery", rec_pres));
    for (t_node = 0; t_node < NODE_COUNT; t_node = t_node + 1) if (t_node != NODE_ID)
        for (t_frag = 0; t_frag < peer_frags; t_frag = t_frag + 1)
            check_page(rec_round, t_node, t_frag, "F1");
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "still running");
end
endtask

task test_F2_verdict_delivery_off;
begin
    banner("F2  with verdict delivery off the decisions queue, the fifth overflows, and seq shows the gap");

    csr_read(REG_VERDICT_OVERFLOW, snap_a);
    csr_read(REG_SEQ_LO, snap_b);
    verdicts_before = verdict_descs;
    csr_write(REG_DLV_CONTROL, DLV_CTRL_PAYLOAD);        // verdicts off
    wait_rounds(8);                                       // eight decisions into a four-deep queue
    check(verdict_descs == verdicts_before, "no record may be written while verdict delivery is off");
    csr_read(REG_VERDICT_OVERFLOW, rd);
    check(rd > snap_a, $sformatf("VERDICT_OVERFLOW is still %0d; decisions should have been dropped", rd));
    csr_expect(REG_SEQ_LO, snap_b, "SEQ does not move while off");

    csr_write(REG_DLV_CONTROL, DLV_CTRL_BOTH);
    wait_verdicts(rec_next + 4, 6);
    decode_last_record;
    check(rec_seq >= snap_b + 4, "the queued decisions went out in order once re-enabled");
    // The gap: the round decided by the latest record is well past the one
    // that last got a record before the stop.
    csr_read(REG_VERDICT_OVERFLOW, snap_c);
    wait_rounds(2);
    csr_expect(REG_VERDICT_OVERFLOW, snap_c, "VERDICT_OVERFLOW stops once the writer is back");
end
endtask

task test_F3_the_fence;
begin
    banner("F3  the fence: while a round's pages are held in flight, its verdict waits");

    // The engine model holds every completion. Pages are accepted and read
    // but never complete, so unit_out never returns to zero and the verdict
    // writer must not offer a record. The check is the engine's own: a verdict
    // offered with pages of its round outstanding is a fault.
    // A verdict for a round whose pages completed BEFORE the hold may still
    // go out during it - that is the fence doing exactly its job - so the
    // count of verdicts is not the check; the engine's own judgement of each
    // one against the pages outstanding when it was offered is.
    goto_midround;
    cpl_hold = 1'b1;
    wait_rounds(2);
    check(verdict_fence_faults == 0, "a verdict was offered for a round with pages held in flight");
    csr_read(REG_DLV_STATUS, rd);
    check(rd[3:0] != 4'b1111, $sformatf("STATUS unit_idle %04b: with completions held, units should be busy", rd[3:0]));
    csr_read(REG_PAY_STARVE, snap_a);
    $display("        PAY_STARVE = %0d while held (sixteen tags, all in flight)", snap_a);

    cpl_hold = 1'b0;
    wait_verdicts(rec_next + 6, 12);
    check(verdict_fence_faults == 0, "a verdict overtook its pages");
    decode_last_record;
    check(rec_pres == 8'b111, $sformatf("present_set %02h once the completions were released", rec_pres));
    wait_rounds(2);
    csr_read(REG_DLV_STATUS, rd);
    check(rd[3:0] == 4'b1111, "every unit idle again");
end
endtask

task test_F4_page_write_error;
begin
    banner("F4  a page DMA that fails: the slot is released, presence is withdrawn, the host sees the loss");

    // One of node 2's pages fails, and the failure is reported a round late.
    // The ack reports what arrived on the wire, not what reached the host, so
    // the cluster commits node 2's pages all the same, and the record says
    // frag_count[2] > 0 with present_set[2] clear: committed, but this host's
    // copy is lost - exactly the disagreement the two fields exist to express.
    csr_read(REG_PAY_ERR,    snap_a);
    csr_read(REG_PRES_ERR,   snap_b);
    csr_read(REG_STAGE_FULL, snap_c);
    goto_midround;
    @(posedge dut.round_start_pulse);
    rec_round      = dut.current_round_id;      // the round whose page will fail
    wr_error_node  = PEER_B;
    wr_error_delay = ROUND_CYCLES + ROUND_CYCLES/2;
    wr_force_error = 1;
    round_guard = 0;
    while (wr_force_error > 0 && round_guard < 4) begin wait_rounds(1); round_guard = round_guard + 1; end
    check(wr_force_error == 0, "the engine never consumed the forced error");
    wr_error_node = -1;
    wr_error_delay = 0;

    // The round is decided at the control deadline of the round after it, so
    // its record may already be the latest one by the time the forced error
    // has been consumed: look at that first, then wait for newer ones.
    // Its record is fenced behind the failing completion, so it lands late
    // and the next round's record can land in the same round: scan every
    // record from here on rather than only the latest.
    want_addr = rec_round;
    round_guard = 0;
    rec_scan = (rec_next > 0) ? rec_next - 1 : 0;
    rec_round = 0;
    while (rec_round != want_addr && round_guard < 8) begin
        while (rec_scan < rec_next && rec_round != want_addr) begin
            decode_record(rec_scan);
            rec_scan = rec_scan + 1;
        end
        if (rec_round != want_addr) begin
            wait_verdicts(rec_next + 1, 4);
            round_guard = round_guard + 1;
        end
    end
    check(rec_round == want_addr, $sformatf("never saw the record for the round with the failed page (%0d)", want_addr));
    if (rec_round == want_addr) begin
        check(rec_set[PEER_B] && rec_fc[PEER_B] == peer_frags[15:0],
              "the ack reports the wire: the peer's pages are committed");
        check(!rec_pres[PEER_B], "but its page did not reach the host: the peer is not present");
        check(rec_pres[PEER_A] && rec_pres[NODE_ID], "the other nodes are unaffected");
    end
    csr_expect(REG_PAY_ERR,  snap_a + 32'd1, "PAY_ERR");
    csr_expect(REG_PRES_ERR, snap_b + 32'd1, "PRES_ERR");
    csr_expect(REG_PRES_ERR_MISS, 32'd0, "PRES_ERR_MISS (the round was still held)");
    check(verdict_fence_faults == 0, "the fence held across the late failure");

    // The slot was released regardless: the stage keeps taking frames.
    wait_verdicts(rec_next + 1, 6);
    decode_last_record;
    check(rec_pres == 8'b111, $sformatf("present_set %02h on the round after the failure", rec_pres));
    csr_expect(REG_STAGE_FULL, snap_c, "STAGE_FULL unchanged by a failed page");
end
endtask


// ============================================================================
//              GROUP G - DMA FAULTS ON THE PROPOSAL SIDE
// ============================================================================

task test_G1_read_error;
    integer bad;
begin
    banner("G1  a failed proposal read: reported, CONSUMER stops on it, nothing behind it goes out");

    // Three entries; the middle one's read fails. The first goes out; the
    // third is read but must wait - entries leave in ring order - and no new
    // read is issued while the error stands.
    descs_before  = descs_seen;
    frames_before = ssr_payload_frames;
    bad = posted + 1;
    rd_force_error_entry = bad;
    post(3);
    wait_rounds(4);

    check(rd_force_error_entry == -1, "the bench should have consumed its forced error");
    check(descs_seen == descs_before + 3, $sformatf("%0d reads, expected 3", descs_seen - descs_before));
    csr_read(REG_PROP_STATUS, rd);
    check(rd[PROP_ST_ERROR] == 1'b1, "STATUS.error should be set");
    check(rd[PROP_ST_IDLE]  == 1'b1, "no read should be left in flight");
    csr_expect(REG_PROP_ERROR_CODE,  32'd1, "proposal ERROR_CODE (the engine's status)");
    csr_expect(REG_PROP_READ_ERRORS, 32'd1, "proposal READ_ERRORS");
    csr_expect(REG_PROP_CONSUMER,    bad,   "proposal CONSUMER (stops on the failed entry)");
    check(ssr_payload_frames == frames_before + 1,
          $sformatf("%0d fragments went out, expected 1 (the entry before the failed one)",
                    ssr_payload_frames - frames_before));
    check(exp_tail - exp_head == 2, "two entries (the failed one and the one behind it) still to go");

    // The verdict record tells the host the same thing without an MMIO read.
    wait_verdicts(rec_next + 1, 6);
    decode_last_record;
    check(rec_pcons == bad, $sformatf("record proposal_consumer %0d, expected %0d", rec_pcons, bad));
end
endtask

task test_G2_recovers_after_the_error;
    integer cons;
begin
    banner("G2  clear_error re-reads the failed entry and everything after it, in order");

    csr_read(REG_PROP_CONSUMER, cons);
    descs_before = descs_seen;
    fetch_expect = cons;                                 // the rewind: fetch goes back to CONSUMER
    csr_write(REG_PROP_CONTROL, PROP_CTRL_ENABLE | PROP_CTRL_CLEAR_ERROR);
    prop_wait_not_pending;
    csr_read(REG_PROP_STATUS, rd);
    check(rd[PROP_ST_ERROR] == 1'b0, "the error bit should have cleared");

    round_guard = 0;
    while (exp_head != exp_tail && round_guard < 12) begin
        wait_rounds(1);
        round_guard = round_guard + 1;
    end
    check(exp_head == exp_tail, "the failed entry and the one behind it went out");
    check(descs_seen == descs_before + (posted - cons),
          $sformatf("%0d reads after the clear, expected %0d", descs_seen - descs_before, posted - cons));
    csr_expect(REG_PROP_CONSUMER, posted, "proposal CONSUMER after the retry");
end
endtask

task test_G3_flush;
    integer frames_b, descs_b;
begin
    banner("G3  flush drops what was posted but not yet read; what is posted after goes out");

    // With the reader disabled nothing is read, so the three entries are
    // posted-but-unfetched: exactly what a flush discards. (The buffer side
    // of flush - committed slots, a slot half on the wire - is
    // tb_ssr_proposal_ring's P4..P6.)
    frames_b = ssr_payload_frames;
    descs_b  = descs_seen;
    csr_write(REG_PROP_CONTROL, 32'd0);
    post(3);
    wait_rounds(2);
    check(descs_seen == descs_b, "nothing is read while the reader is disabled");
    csr_write(REG_PROP_CONTROL, PROP_CTRL_FLUSH);        // enable stays 0
    prop_wait_not_pending;
    csr_expect(REG_PROP_CONSUMER, posted, "CONSUMER jumps to PRODUCER");
    csr_expect(REG_PROP_FETCH,    posted, "FETCH jumps to PRODUCER");
    exp_tail     = exp_tail - 3;                         // the host knows those three are gone
    fetch_expect = posted;

    csr_write(REG_PROP_CONTROL, PROP_CTRL_ENABLE);
    post(2);
    round_guard = 0;
    while (exp_head != exp_tail && round_guard < 12) begin
        wait_rounds(1);
        round_guard = round_guard + 1;
    end
    wait_rounds(1);
    check(descs_seen == descs_b + 2, $sformatf("%0d reads, expected 2", descs_seen - descs_b));
    check(ssr_payload_frames == frames_b + 2,
          $sformatf("%0d fragments, expected 2 (the flushed three never went out)", ssr_payload_frames - frames_b));
end
endtask


// ============================================================================
//          GROUP I - THE LONG RUN: RING WRAP, STALE, THE DEADLINE EDGE
// ============================================================================

// Every record and every page of every round, for long enough that both host
// rings wrap: the payload ring by round (256), the verdict ring by seq (256).
// A wrapped ring is the one place an address collision can hide - the page
// for R+256 lands exactly where R's did, and only the 64-bit round in the
// header on the page, and the seq in the record, tell them apart.
// 280 wraps both rings with margin. A build knob, because the node-1 build in
// the regression has nothing new to learn from the wrap and runs it short.
`ifndef SSR_TB_SOAK_ROUNDS
`define SSR_TB_SOAK_ROUNDS 280
`endif
localparam integer SOAK_ROUNDS = `SSR_TB_SOAK_ROUNDS;
localparam integer SOAK_WRAPS  = (SOAK_ROUNDS >= 260);   // long enough to see both rings wrap

task test_I1_soak_across_the_ring_wrap;
    reg [63:0] first_round, first_addr, prev_round, prev_seq;
    integer    r, wrapped_pages, wrapped_records;
    reg [31:0] late_a, full_a, stale_a, over_a, err_a, commit_a, commit_b;
begin
    banner($sformatf("I1  %0d rounds straight: every page, every record, across both ring wraps", SOAK_ROUNDS));

    csr_read(REG_PRES_LATE,    late_a);
    csr_read(REG_STAGE_FULL,   full_a);
    csr_read(REG_VERDICT_STALE, stale_a);
    csr_read(REG_VERDICT_OVERFLOW, over_a);
    csr_read(REG_PAY_ERR,      err_a);
    csr_read(REG_COMMIT_COUNT_LO, commit_a);

    wait_verdicts(rec_next + 1, 4);
    decode_last_record;
    first_round = rec_round;
    first_addr  = rec_addr;
    prev_round  = rec_round;
    prev_seq    = rec_seq;
    wrapped_pages = 0; wrapped_records = 0;

    for (r = 0; r < SOAK_ROUNDS; r = r + 1) begin
        wait_verdicts(rec_next + 1, 4);
        decode_last_record;
        // Consecutive, and the record says what a healthy round says.
        if (rec_round != prev_round + 64'd1)
            check(1'b0, $sformatf("I1: record for round %0d follows %0d", rec_round, prev_round));
        if (rec_seq != prev_seq + 64'd1)
            check(1'b0, $sformatf("I1: seq %0d follows %0d", rec_seq, prev_seq));
        if (rec_set != ALL_MEMBERS || rec_pres != ALL_MEMBERS)
            check(1'b0, $sformatf("I1: round %0d commit %02h present %02h", rec_round, rec_set, rec_pres));
        if (rec_fc[PEER_A] != peer_frags[15:0] || rec_fc[PEER_B] != peer_frags[15:0])
            check(1'b0, $sformatf("I1: round %0d frag counts %0d %0d", rec_round, rec_fc[PEER_A], rec_fc[PEER_B]));
        // Every page, at its address, with its own round in its header.
        for (t_frag = 0; t_frag < peer_frags; t_frag = t_frag + 1) begin
            check_page(rec_round, PEER_A, t_frag, "I1");
            check_page(rec_round, PEER_B, t_frag, "I1");
        end
        // The wraps, when they come: same address as 256 ago, new contents.
        if (rec_round == first_round + 64'd256) begin
            wrapped_pages = 1;
            check(page_addr(rec_round, PEER_A, 0) == page_addr(first_round, PEER_A, 0),
                  "I1: round R+256 must reuse round R's pages");
        end
        if (rec_addr == first_addr && rec_round != first_round) begin
            wrapped_records = wrapped_records + 1;
            check(rec_seq == prev_seq + 64'd1 && rec_seq[7:0] == first_addr[13:6],
                  $sformatf("I1: the verdict ring wrapped to %016h with seq %0d", rec_addr, rec_seq));
        end
        prev_round = rec_round;
        prev_seq   = rec_seq;
    end
    if (SOAK_WRAPS) begin
        check(wrapped_pages == 1,   "I1: the payload ring never wrapped - the soak is too short");
        check(wrapped_records >= 1, "I1: the verdict ring never wrapped - the soak is too short");
    end else
        $display("        (%0d rounds: too short for either ring to wrap; the wrap checks are skipped)", SOAK_ROUNDS);
    check(verdict_fence_faults == 0, "I1: a verdict overtook its pages somewhere in the soak");

    // Nothing late, nothing dropped, nothing stale, all the way.
    csr_expect(REG_PRES_LATE,        late_a,  "I1: PRES_LATE (no fragment counted after its round closed)");
    csr_expect(REG_STAGE_FULL,       full_a,  "I1: STAGE_FULL");
    csr_expect(REG_VERDICT_STALE,    stale_a, "I1: VERDICT_STALE");
    csr_expect(REG_VERDICT_OVERFLOW, over_a,  "I1: VERDICT_OVERFLOW");
    csr_expect(REG_PAY_ERR,          err_a,   "I1: PAY_ERR");
    csr_read(REG_COMMIT_COUNT_LO, commit_b);
    check(commit_b - commit_a >= SOAK_ROUNDS, $sformatf("I1: COMMIT_COUNT advanced by %0d", commit_b - commit_a));
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "I1: still running");
end
endtask

// One page's completion is parked for four and a half rounds while every
// other page completes on time. The fence holds that round's record back;
// meanwhile the tracker's slot for the round is taken by round R+4, so when
// the record is finally built the tracker no longer holds R: the record goes
// out STALE - commit_set as decided, present_set and the counts zero - and
// the rounds behind it are unaffected.
task test_I2_stale_record;
    reg [63:0] park_round;
    reg [31:0] stale_a, over_a;
    integer    saved_frags;
begin
    banner("I2  a page held past the tracker's memory: the record is stale, not wrong");

    // Fewer pages per round, so a slot stuck behind the parked one does not
    // fill the stage (release is in order: the parked slot pins free_ptr).
    // Changed in the quiet half of a round, when the driver is not sending.
    goto_midround;
    saved_frags = peer_frags;
    peer_frags  = 1;
    wait_rounds(2);
    csr_read(REG_VERDICT_STALE,    stale_a);
    csr_read(REG_VERDICT_OVERFLOW, over_a);

    @(posedge dut.round_start_pulse);
    park_round = dut.current_round_id;
    park_node  = PEER_A;
    park_req   = 1;
    // R+4's boundary opens its slot over R; release half a round later,
    // before R+4's own commit would push a fifth entry into the 4-deep queue.
    repeat (4) @(posedge dut.round_start_pulse);
    repeat (ROUND_CYCLES/2) @(posedge clk);
    check(parked, "I2: the engine never parked a page of the chosen round");
    check(park_req == 0, "I2: exactly one page was parked");
    csr_expect(REG_VERDICT_OVERFLOW, over_a, "I2: the queue held the four rounds behind the fence");
    park_release = 1'b1;
    wait_rounds(1);
    park_release = 1'b0;

    // Find R's record: it is stale.
    rec_scan = (rec_next > 8) ? rec_next - 8 : 0;
    rec_round = 0;
    while (rec_scan < rec_next && rec_round != park_round) begin
        decode_record(rec_scan);
        rec_scan = rec_scan + 1;
    end
    check(rec_round == park_round, $sformatf("I2: no record for the parked round %0d", park_round));
    if (rec_round == park_round) begin
        check(rec_set == ALL_MEMBERS, $sformatf("I2: commit_set %02h - the decision was taken with every page present", rec_set));
        check(rec_pres == 8'd0,      $sformatf("I2: present_set %02h - the tracker had forgotten the round, so nothing is claimed", rec_pres));
        check(rec_fc[PEER_A] == 0 && rec_fc[PEER_B] == 0 && rec_fc[NODE_ID] == 0, "I2: a stale record claims no pages");
        // The round after it, decided a round later, still had its tracker slot.
        decode_record(rec_scan);
        check(rec_round == park_round + 64'd1 && rec_pres == ALL_MEMBERS,
              $sformatf("I2: the record behind the stale one is round %0d present %02h", rec_round, rec_pres));
    end
    csr_expect(REG_VERDICT_STALE, stale_a + 32'd1, "I2: VERDICT_STALE");
    check(verdict_fence_faults == 0, "I2: the stale record still waited for its page");
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "I2: still running - one slow page is not a protocol event");

    goto_midround;
    peer_frags = saved_frags;
    wait_verdicts(rec_next + 3, 6);
    decode_last_record;
    check(rec_pres == ALL_MEMBERS, "I2: back to normal");
end
endtask

// A control frame whose header beat lands a few cycles before the deadline is
// in time, and its sender is among the witnesses when the round before is
// decided a few cycles after the deadline. That gap is CTRL_END_SETTLE_CYCLES,
// and this is the case it exists for. Missed, the round would still commit -
// two witnesses of three - but without the peer, and the peer would leave the
// sound set; that is what the checks look at.
task test_I3_control_frame_at_the_deadline;
    reg [63:0] edge_round;
begin
    banner("I3  a control frame taken just inside the deadline counts: its sender is a witness");

    goto_midround;
    // For one round the peer sends nothing on its own; the bench injects its
    // control frame, with the right ack, at the edge instead.
    peer_mask[PEER_A] = 1'b0;
    inj_defaults;
    inj_kind      = SSR_KIND_CTRL;
    inj_node      = PEER_A[7:0];
    inj_ack_model = 1'b1;
    inj_len       = 16'd0;
    inj_beats     = 0;
    inj_edge      = 1'b1;
    inj_parsed    = inj_parsed + 1;
    inj_accepted  = inj_accepted + 1;
    inj_req       = 1'b1;
    @(posedge dut.round_start_pulse);
    edge_round = dut.current_round_id;
    round_guard = 0;
    while (inj_req && round_guard < ROUND_CYCLES) begin @(posedge clk); round_guard = round_guard + 1; end
    check(!inj_req, "I3: the edge injection never went out");
    inj_edge = 1'b0;
    peer_mask[PEER_A] = 1'b1;
    // ssr_rx_engine judges the header against a one-cycle-delayed window, so a
    // beat taken on the deadline cycle itself is still inside it.
    check(inj_hdr_offset_ns <= CTRL_PERIOD_NS + CLK_PERIOD_NS && inj_hdr_offset_ns >= CTRL_PERIOD_NS - CLK_PERIOD_NS,
          $sformatf("I3: the header beat was taken at %0d ns into the round, wanted within a cycle or two of %0d", inj_hdr_offset_ns, CTRL_PERIOD_NS));
    $display("        header beat taken at %0d ns; deadline %0d ns; evaluated at %0d ns",
             inj_hdr_offset_ns, CTRL_PERIOD_NS, CTRL_PERIOD_NS + 8*CLK_PERIOD_NS);

    // Not late; the round before is decided WITH the peer; and the edge round
    // itself commits the peer's zero fragments.
    goto_midround;
    rx_verify("I3");
    rec_scan = (rec_next > 6) ? rec_next - 6 : 0;
    rec_round = 0;
    while (rec_scan < rec_next && rec_round != edge_round - 64'd1) begin
        decode_record(rec_scan);
        rec_scan = rec_scan + 1;
    end
    check(rec_round == edge_round - 64'd1, $sformatf("I3: no record for round %0d", edge_round - 64'd1));
    if (rec_round == edge_round - 64'd1)
        check(rec_set == ALL_MEMBERS,
              $sformatf("I3: the round decided at the edge left the sound set at %02h - the edge frame was not a witness", rec_set));
    decode_record(rec_scan);
    check(rec_round == edge_round, $sformatf("I3: no record for round %0d", edge_round));
    if (rec_round == edge_round) begin
        check(rec_set == ALL_MEMBERS && rec_pres == ALL_MEMBERS,
              $sformatf("I3: commit %02h present %02h after the edge round", rec_set, rec_pres));
        check(rec_fc[PEER_A] == 16'd0, "I3: the peer sent nothing in the edge round");
        check(rec_fc[PEER_B] == peer_frags[15:0], "I3: the other peer is unaffected");
    end
    csr_read(REG_CUR_SOUND_SET, rd);
    check(rd[NODE_COUNT-1:0] == 3'b111, $sformatf("I3: sound set %02h - nobody should have left", rd[7:0]));
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "I3: still running");
end
endtask


// ============================================================================
//                  GROUP H - PROTOCOL FAILURE AND RECOVERY
// ============================================================================

task test_H1_short_peer_leaves_the_sound_set;
    reg [63:0] short_round;
begin
    banner("H1  a peer that delivered one fragment fewer than it says: no witness, its prefix committed, out of the sound set");

    // In round S node 2 puts one fragment fewer on the wire than it believes it
    // sent - its own transmit path lost the last one. Everyone else holds the
    // same prefix, so in S+1 node 1's ack and ours agree and node 2's does not:
    // ACK_DISAGREE, and node 2 is no witness. Two of three is a quorum, so S
    // commits - with node 2's PREFIX, the one fragment everybody holds - and
    // the sound set shrinks to {0,1}. Node 2, with no witness of its own,
    // would halt there; the bench has it send nothing in S+1 and fall silent
    // after, and proves the sound rung with one injected frame.
    csr_read(REG_CUR_SOUND_SET, rd);
    check(rd[PEER_B] == 1'b1, "the peer about to go short should still be in the sound set");
    snap_a = peer_ctrl_disagree;

    // The knobs are turned in the quiet middle of the round BEFORE the one
    // they are for, so the driver never sees one change under it.
    goto_midround;
    peer_short_mask[PEER_B] = 1'b1;                     // S: one fragment short
    @(posedge dut.round_start_pulse);
    short_round = dut.current_round_id;
    repeat (ROUND_CYCLES/2) @(posedge clk);
    peer_short_mask[PEER_B] = 1'b0;
    peer_zero_mask[PEER_B]  = 1'b1;                     // S+1: its control frame, nothing else
    @(posedge dut.round_start_pulse);
    repeat (ROUND_CYCLES/2) @(posedge clk);
    peer_zero_mask[PEER_B]  = 1'b0;
    peer_mask[PEER_B]       = 1'b0;                     // silent from S+2 on

    check(peer_ctrl_disagree == snap_a + 1, "the bench expected exactly one disagreeing control frame");
    // S was decided at S+1's deadline, so its record may already be in.
    wait_verdicts(rec_next + 1, 4);
    rec_scan = (rec_next > 4) ? rec_next - 4 : 0;
    rec_round = 0;
    while (rec_scan < rec_next && rec_round != short_round) begin
        decode_record(rec_scan);
        rec_scan = rec_scan + 1;
    end
    check(rec_round == short_round, $sformatf("never saw the record for round %0d", short_round));
    if (rec_round == short_round) begin
        check(rec_set  == (ALL_MEMBERS & ~PEER_B_BIT), $sformatf("commit_set %02h: the short peer must leave the sound set", rec_set));
        check(rec_fc[PEER_B] == peer_frags - 1, $sformatf("frag_count %0d: the prefix everybody holds is %0d", rec_fc[PEER_B], peer_frags - 1));
        check(rec_pres == ALL_MEMBERS, $sformatf("present_set %02h: the page it did send reached the host", rec_pres));
        check(rec_fc[PEER_A] == peer_frags[15:0], "the other peer is unaffected");
        check_page(rec_round, PEER_A, 0, "H1");
        check_page(rec_round, PEER_B, 0, "H1 (the one fragment the short peer delivered is a committed page)");
        check(pg_find(page_addr(rec_round, PEER_B, peer_frags - 1)) < 0, "the fragment the short peer never sent has no page");
    end

    wait_rounds(2);
    csr_read(REG_CUR_SOUND_SET, rd);
    check(rd[PEER_B] == 1'b0, $sformatf("CURRENT_SOUND_SET %02h still believes the short peer", rd[7:0]));
    check(rd[NODE_ID] == 1'b1 && rd[PEER_A] == 1'b1, "we and the other peer should still be believed");
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "losing one node of three should not halt the other two");
    csr_expect(REG_RX_MALFORMED, exp_rung[RUNG_MALFORMED], "RX_MALFORMED_COUNT (a short peer is not malformed)");
    rx_verify("H1");

    wait_verdicts(rec_next + 1, 6);
    decode_last_record;
    check(rec_set == (ALL_MEMBERS & ~PEER_B_BIT) && rec_fc[PEER_B] == 16'd0,
          $sformatf("record commit %02h, frag_count %0d for the departed peer", rec_set, rec_fc[PEER_B]));

    // Node 2 comes back: believing it again would GROW the sound set, so its
    // frame is dropped at the sound rung.
    inj_defaults;
    inj_node = PEER_B[7:0];
    expect_rung(RUNG_SOUND, 0, "H1");
    csr_read(REG_CUR_SOUND_SET, rd);
    check(rd[PEER_B] == 1'b0, "the sound set grew back - it must only ever shrink");
end
endtask

task test_H2_halt;
begin
    banner("H2  losing the quorum halts the node, and a halted node hears nothing");

    csr_expect(REG_HALT_COUNT, 32'd0, "HALT_COUNT before the halt");

    peer_mask = 8'd0;
    round_guard = 0;
    csr_read(REG_CORE_STATUS, rd);
    while (rd[0] == 1'b0 && round_guard < 30) begin
        wait_rounds(1);
        csr_read(REG_CORE_STATUS, rd);
        round_guard = round_guard + 1;
    end
    check(rd[0] == 1'b1, $sformatf("the node was still running after %0d rounds with no peers", round_guard));

    csr_read(REG_HALT_REASON, rd);
    check(rd != 32'd0, "a halt should record why");
    $display("        HALT_REASON = %0d", rd);
    csr_expect(REG_HALT_COUNT, 32'd1, "HALT_COUNT");

    // A halted node admits no payload - that is the window rung, reached the
    // other way round from a running node.
    inj_defaults;
    expect_rung(RUNG_WINDOW, 0, "H2");

    frames_before = ssr_frames;
    wait_rounds(3);
    check(ssr_frames == frames_before, $sformatf("%0d frames left the port while halted", ssr_frames - frames_before));
end
endtask

task test_H3_reboot;
begin
    banner("H3  a reboot starts a new run and the datapath comes all the way back");

    csr_write(REG_CORE_CONTROL, CORE_CTRL_REBOOT);
    wait_rounds(2);

    peer_mask   = ~SELF_BIT;
    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "the reboot should have cleared the halt");

    csr_write(REG_CFG_RUN_ID,  RUN_ID_B);
    csr_write(REG_CFG_MEMBERSHIP,  32'h0000_0007);
    csr_write(REG_CFG_EFF_ROUND_LO, 32'h0000_0100);
    csr_write(REG_CORE_CONTROL,     CORE_CTRL_ACTIVATE);
    wait_rounds(2);

    round_guard = 0;
    while (dut.core_inst.state_reg != 2'd2 && round_guard < 30) begin
        wait_rounds(1);
        round_guard = round_guard + 1;
    end
    wait_rounds(4);

    csr_read(REG_CORE_STATUS, rd);
    check(rd[0] == 1'b0, "the node should be running again after the reboot");
    csr_expect(REG_CUR_RUN_ID, RUN_ID_B, "CURRENT_RUN_ID after the reboot");
    csr_read(REG_CUR_SOUND_SET, rd);
    check(rd[NODE_COUNT-1:0] == 3'b111,
          $sformatf("CURRENT_SOUND_SET %02h; a reboot should believe everyone again", rd[7:0]));

    wait_verdicts(rec_next + 2, 10);
    decode_last_record;
    check(rec_run == RUN_ID_B, $sformatf("record run_id %08h after the reboot, expected %08h", rec_run, RUN_ID_B));
    check(rec_pres == 8'b111, $sformatf("present_set %02h; both peers should be whole again", rec_pres));
    for (t_node = 0; t_node < NODE_COUNT; t_node = t_node + 1) if (t_node != NODE_ID)
        for (t_frag = 0; t_frag < peer_frags; t_frag = t_frag + 1)
            check_page(rec_round, t_node, t_frag, "H3");
    check(verdict_fence_faults == 0, "the fence held for the whole run");

    rx_verify("H3");
end
endtask


task test_H4_host_stops_taking_delivery;
begin
    banner("H4  a host that stops taking delivery: the stage fills, and the node halts rather than lie");

    // The destructive half of F1. Delivery off for longer than the stage can
    // hold: frames are dropped (STAGE_FULL), a dropped frame is not staged so
    // it is not counted, this node's ack falls short of what both peers hold,
    // nobody agrees with it and it halts (no agreed row). A node that cannot
    // deliver must not keep promising to; the alternative is a record that
    // commits pages that never reached the host.
    csr_read(REG_STAGE_FULL, snap_a);
    csr_expect(REG_HALT_COUNT, 32'd1, "HALT_COUNT before (H2's halt)");
    csr_write(REG_DLV_CONTROL, DLV_CTRL_VERDICT);        // payload off
    round_guard = 0;
    csr_read(REG_CORE_STATUS, rd);
    while (rd[0] == 1'b0 && round_guard < 16) begin
        wait_rounds(1);
        csr_read(REG_CORE_STATUS, rd);
        round_guard = round_guard + 1;
    end
    csr_read(REG_STAGE_FULL, rd1);
    check(rd1 > snap_a, $sformatf("STAGE_FULL is still %0d; the stage should have overflowed", rd1));
    check(rd[0] == 1'b1, $sformatf("the node was still running %0d rounds after the stage filled", round_guard));
    csr_read(REG_HALT_REASON, rd);
    check(rd == 32'd1, $sformatf("HALT_REASON %0d, expected 1 (no agreed row)", rd));
    csr_expect(REG_HALT_COUNT, 32'd2, "HALT_COUNT");
    csr_write(REG_DLV_CONTROL, DLV_CTRL_BOTH);
end
endtask



// ============================================================================
//                  GROUP J - THE OTHER INTERFACE
// ============================================================================
// Last, so that adding it moved no other test's start time. The per-cycle
// monitor (section 14b) has been watching the lane for the whole run; this
// puts traffic on it that SSR would claim if it were on its lane.

task test_J1_the_other_interface;
    reg [31:0] mux_dma0;
    integer b, tx0, rx0, c0, host_out0;
begin
    banner($sformatf("J1  interface %0d is not SSR's: SSR-looking traffic on it passes straight through", OTHER_IF));
    csr_read(REG_TX_HOST_FRAMES, mux_dma0);
    tx0 = oth_tx_frames; rx0 = oth_rx_frames; c0 = oth_cpls; host_out0 = host_frames_out;

    // transmit: a frame with SSR's own tag, under back pressure
    otx_m_tready = 1'b0;
    for (b = 0; b < 3; b = b + 1) begin
        @(negedge clk);
        otx_s_tdata  = host_frame_word(200 + b, b);
        otx_s_tkeep  = {AXIS_KEEP_WIDTH{1'b1}};
        otx_s_tlast  = (b == 2);
        otx_s_tid    = 13'h1ABC;
        otx_s_tdest  = 4'h5;
        otx_s_tuser  = {SSR_TX_CPL_TAG, 1'b0};
        otx_s_tvalid = 1'b1;
        repeat (2) @(posedge clk);
        #0.1 check(otx_s_tready === 1'b0, "the other lane's tready follows its own port, held low");
        @(negedge clk); otx_m_tready = 1'b1;
        @(posedge clk); #0.1 otx_m_tready = 1'b0;
    end
    @(negedge clk); otx_s_tvalid = 1'b0; otx_s_tlast = 1'b0; otx_m_tready = 1'b1;

    // its completion, with SSR's tag: forwarded, not consumed
    @(negedge clk);
    ocpl_s_ts = 48'h1234_5678_9ABC; ocpl_s_tag = SSR_TX_CPL_TAG; ocpl_s_valid = 1'b1;
    ocpl_m_ready = 1'b0;
    repeat (3) @(posedge clk);
    #0.1 check(ocpl_s_ready === 1'b0, "the other lane's completion waits for its own consumer");
    @(negedge clk); ocpl_m_ready = 1'b1;
    @(posedge clk);
    @(negedge clk); ocpl_s_valid = 1'b0;

    // receive: a 0x88B5 frame, which on SSR's lane would go to ssr_rx_engine
    for (b = 0; b < 2; b = b + 1) begin
        @(negedge clk);
        orx_s_tdata  = host_frame_word(210, b);
        if (b == 0) begin
            orx_s_tdata[12*8 +: 8] = SSR_ETHERTYPE_TB[15:8];
            orx_s_tdata[13*8 +: 8] = SSR_ETHERTYPE_TB[7:0];
        end
        orx_s_tkeep  = {AXIS_KEEP_WIDTH{1'b1}};
        orx_s_tlast  = (b == 1);
        orx_s_tid    = 1'b1;
        orx_s_tdest  = 9'h1A5;
        orx_s_tuser  = {48'hCAFE_0000_0001, 1'b0};
        orx_s_tvalid = 1'b1;
        orx_m_tready = (b == 1);
        @(posedge clk);
        while (!(orx_s_tvalid && orx_s_tready)) begin
            @(negedge clk); orx_m_tready = 1'b1;
            @(posedge clk);
        end
    end
    @(negedge clk); orx_s_tvalid = 1'b0; orx_s_tlast = 1'b0; orx_m_tready = 1'b1;
    repeat (10) @(posedge clk);

    check(oth_tx_frames == tx0 + 1, "the frame left the other interface's port");
    check(oth_cpls      == c0 + 1,  "its completion reached the other interface");
    check(oth_rx_frames == rx0 + 1, "the 0x88B5 frame reached the other interface's host");
    check(oth_mismatch  == 0,       "the other interface came out exactly as it went in");
    check(host_frames_out == host_out0, "nothing crossed onto SSR's port");
    // SSR's own counters saw none of it: the mux counted no host frame, and
    // the completion with SSR's tag was not consumed as one of ours.
    // (The node is halted by now - H4 - so its own completions are quiet.)
    repeat (ROUND_CYCLES) @(posedge clk);
    csr_expect(REG_TX_HOST_FRAMES,   mux_dma0,            "TX_MUX_DMA_FRAMES");
    csr_expect(REG_TX_CPL_COUNT, ssr_cpl_model_count, "TX_CPL_COUNT");
end
endtask

// ############################################################################
//                      SECTION 19 - MAIN SEQUENCE
// ############################################################################

integer dump_after_us = 0;
integer dump_for_us   = 0;

initial begin : waveform_control
    if ($test$plusargs("dump") || $test$plusargs("dump_edge")) begin
        // +fst: the same dump in FST, for `vvp -fst`. About a tenth of the
        // size and what Surfer/GTKWave open fastest; the whole run fits.
        if ($test$plusargs("fst")) $dumpfile("build/tb_ssr_dataplane.fst");
        else                       $dumpfile("build/tb_ssr_dataplane.vcd");
        if ($test$plusargs("dump_edge")) $dumpvars(1, tb_ssr_dataplane);
        else                             $dumpvars(0, tb_ssr_dataplane);
        if ($value$plusargs("dump_after=%d", dump_after_us)) begin
            $dumpoff;
            #(dump_after_us * 1000);
            $dumpon;
        end
        if ($value$plusargs("dump_for=%d", dump_for_us)) begin
            #(dump_for_us * 1000);
            $dumpoff;
        end
    end
end

initial begin : main_sequence
    for (rung_i = 0; rung_i < 9; rung_i = rung_i + 1) exp_rung[rung_i] = 0;

    $display("=========================================================");
    $display(" tb_ssr_dataplane  node=%0d/%0d  page=%0dB  frags/round=%0d  peers send %0d  round=%0dns",
             NODE_ID, NODE_COUNT, SLOT_BYTES, FRAGS_PER_ROUND, peer_frags, ROUND_LENGTH_NS);
    $display("=========================================================");

    rst = 1'b1; time_advancing = 1'b0;
    repeat (10) @(posedge clk);
    time_advancing = 1'b1;
    rst = 1'b0;
    repeat (5) @(posedge clk);

    test_A0_block_decode;
    test_A1_activate;
    test_A2_geometry_and_state;

    test_B1_empty_queue;
    test_B2_proposal_reaches_the_port;
    test_B3_completions;
    test_B4_host_frame_crosses;
    test_B5_contention;
    test_B6_port_back_pressure;
    test_B7_proposal_backlog;
    test_B8_posted_mid_round;

    test_C1_pages_and_a_record;
    test_C2_sends_nothing;

    test_D1_host_route;
    test_D2_unknown_ethertype_goes_to_the_host;

    test_E0_baseline;
    test_E1_length_past_the_limit;
    test_E2_zero_length_payload;
    test_E3_frame_shorter_than_its_length;
    test_E4_short_header_beat;
    test_E5_mac_flagged_the_frame;
    test_E6_node_out_of_range;
    test_E7_frame_claiming_to_be_us;
    test_E8_wrong_run;
    test_E9_wrong_round;
    test_E10_late_control_frame;
    test_E11_good_frame_after_all_that;
    test_E12_control_frame_with_a_payload;
    test_E13_fragment_past_the_budget;
    test_E14_ack_disagrees;

    test_F1_payload_delivery_off;
    test_F2_verdict_delivery_off;
    test_F3_the_fence;
    test_F4_page_write_error;

    test_G1_read_error;
    test_G2_recovers_after_the_error;
    test_G3_flush;
    test_I1_soak_across_the_ring_wrap;
    test_I2_stale_record;
    test_I3_control_frame_at_the_deadline;

    test_H1_short_peer_leaves_the_sound_set;
    test_H2_halt;
    test_H3_reboot;
    test_H4_host_stops_taking_delivery;

    test_J1_the_other_interface;

    // FAULT is sticky: one read at the end covers every test before it.
    csr_expect(REG_FAULT, 32'd0, "FAULT at the end of the run: an internal contract broke somewhere");

    test_name = "(done)";
    $display("");
    $display("==================================================");
    $display("  transmit : ssr ctrl=%0d payload=%0d (%0d beats)  host=%0d",
             ssr_ctrl_frames, ssr_payload_frames, ssr_payload_beats, host_frames_out);
    $display("  proposal : %0d descriptors", descs_seen);
    $display("  receive  : %0d peer frames (%0d control), %0d injected, %0d forwarded to the host",
             peer_frames_sent, peer_ctrl_sent, inj_sent_count, hostrx_frames);
    $display("  delivery : %0d pages, %0d verdict records, %0d fence faults",
             page_descs, rec_next, verdict_fence_faults);
    $display("  cpl      : ssr=%0d consumed, host=%0d forwarded", ssr_cpl_model_count, if_cpl_seen);
    $display("  checks   : %0d", checks);
    $display("  errors   : %0d", errors);
    $display("==================================================");
    if (errors == 0) $display("[%0t] ALL TESTS PASSED", $realtime);
    else             $display("[%0t] %0d FAILURES", $realtime, errors);
    $finish;
end

initial begin
    #8000000;
    $display("ERROR: timeout");
    $display("  errors   : %0d", errors + 1);
    $finish;
end

endmodule

`default_nettype wire
