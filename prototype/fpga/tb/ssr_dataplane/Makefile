# ==============================================================================
# SSR dataplane - simulation benches (Icarus Verilog)
# ==============================================================================
#
# NAMING
#   Every SSR RTL file and module is ssr_<name>, one module per file, file name
#   = module name (Corundum has its own tx_engine, rx_engine, ...; the prefix is
#   what keeps the two apart in one file list). A bench is tb_ssr_<unit>, and
#   its make target is its own name:
#
#       make tb_ssr_tx_engine          one bench
#       make regress                   everything, ~3 min

CORUNDUM_DIR = ../../corundum
RTL_DIR      = ../../rtl
TB_DIR       = .
BUILD_DIR    = build

PSDPRAM      = $(CORUNDUM_DIR)/fpga/lib/pcie/rtl/dma_psdpram.v

# -g2012: SystemVerilog constructs the benches use; -I: ssr_packet.vh, ssr_verdict.vh
IV_FLAGS = -g2012 -Wall -I $(RTL_DIR)

# ==============================================================================
# Unit benches: one module (or one pair) each, driven by hand. Each has
# <bench>_SRC, the RTL it compiles against; the rule is shared.
# ==============================================================================

# ssr_core: the PTP round generator (section 2), through its registers in ssr_csr.
tb_ssr_core_timing_SRC = $(RTL_DIR)/ssr_core.v $(RTL_DIR)/ssr_csr.v

# ssr_dma_tag_pool: outstanding-descriptor tracking with a per-unit fence. A
# fence that is subtly wrong produces a bug that only appears under load and
# looks like a peer problem, so it is tested on its own.
tb_ssr_dma_tag_pool_SRC = $(RTL_DIR)/ssr_dma_tag_pool.v

# ssr_payload_stage: the landing ring for peer payload on its way to host
# memory. Driven by hand because the cases it exists to survive - the ring
# filling because PCIe fell behind the wire, a frame declared bad after its
# beats are written - cannot be produced on demand by a three-node loop.
tb_ssr_payload_stage_SRC = $(RTL_DIR)/ssr_payload_stage.v $(PSDPRAM)

# ssr_payload_dma_writer: the stage's head becomes a DMA write descriptor, and
# the completion becomes the slot release. A small tag pool makes starvation,
# out-of-order completion and a DMA error all reachable.
tb_ssr_payload_dma_writer_SRC = $(RTL_DIR)/ssr_payload_dma_writer.v $(RTL_DIR)/ssr_dma_tag_pool.v

# ssr_presence_tracker: which nodes delivered every fragment they announced.
# The row ssr_core broadcasts comes out of here, so a count that is off by one
# is a protocol bug; announcements, fragments, evictions and DMA errors are
# driven by hand, including in the same cycle.
tb_ssr_presence_tracker_SRC = $(RTL_DIR)/ssr_presence_tracker.v

# ssr_verdict_dma_writer: the 64-byte record that tells the host a round is
# decided, written only after every page of that round has landed. The fence,
# the ring wrap and the queue overflow are all driven by hand.
tb_ssr_verdict_dma_writer_SRC = $(RTL_DIR)/ssr_verdict_dma_writer.v

# ssr_tx_engine's per-round frame sequence: the one start pulse, control frame
# first, then paced fragments, nothing when there is nothing to propose. The
# timing against the real core is tb_ssr_dataplane's.
tb_ssr_tx_engine_SRC = $(RTL_DIR)/ssr_tx_engine.v

# ssr_rx_engine's header ladder, driven directly off the bus so it can be given
# frames a real transmitter would never send. Against real peers: group E of
# tb_ssr_dataplane.
tb_ssr_rx_engine_SRC = $(RTL_DIR)/ssr_rx_engine.v

# ssr_rx_demux: the receive counterpart of ssr_tx_mux.
tb_ssr_rx_demux_SRC = $(RTL_DIR)/ssr_rx_demux.v

# The proposal path: ssr_proposal_dma_reader + ssr_proposal_buffer against a
# host ring and a read engine that completes out of order.
tb_ssr_proposal_ring_SRC = $(RTL_DIR)/ssr_proposal_dma_reader.v $(RTL_DIR)/ssr_csr.v $(RTL_DIR)/ssr_proposal_buffer.v $(PSDPRAM)

UNIT_BENCHES = tb_ssr_core_timing tb_ssr_dma_tag_pool tb_ssr_payload_stage \
               tb_ssr_payload_dma_writer tb_ssr_presence_tracker \
               tb_ssr_verdict_dma_writer tb_ssr_tx_engine tb_ssr_rx_engine \
               tb_ssr_rx_demux tb_ssr_proposal_ring

# ssr_core's consensus pipeline and FSM (section 3), at 3 and 5 nodes: several
# protocol properties are vacuous at 3 (a 3-member quorum is 2 and cannot
# shrink below 2).
tb_ssr_core_protocol_SRC   = $(RTL_DIR)/ssr_core.v $(RTL_DIR)/ssr_csr.v
CORE_PROTOCOL_NODE_COUNTS = 3 5

# ==============================================================================
# The wrapper: ssr_dataplane with every module it instantiates. This is also
# the file list `make elab` compiles, so it is the one place that says what
# ssr_dataplane is made of.
# ==============================================================================
SSR_DATAPLANE_SRC = $(RTL_DIR)/ssr_dataplane.v \
                    $(RTL_DIR)/ssr_csr.v \
                    $(RTL_DIR)/ssr_core.v \
                    $(RTL_DIR)/ssr_tx_engine.v \
                    $(RTL_DIR)/ssr_rx_engine.v \
                    $(RTL_DIR)/ssr_tx_mux.v \
                    $(RTL_DIR)/ssr_rx_demux.v \
                    $(RTL_DIR)/ssr_proposal_dma_reader.v \
                    $(RTL_DIR)/ssr_proposal_buffer.v \
                    $(RTL_DIR)/ssr_payload_stage.v \
                    $(RTL_DIR)/ssr_payload_dma_writer.v \
                    $(RTL_DIR)/ssr_dma_tag_pool.v \
                    $(RTL_DIR)/ssr_presence_tracker.v \
                    $(RTL_DIR)/ssr_verdict_dma_writer.v \
                    $(PSDPRAM)
SSR_DATAPLANE_TB  = $(TB_DIR)/tb_ssr_dataplane.v

# mqnic_app_block as the AU200 build compiles it: the wrapper above plus
# Corundum's AXI-Lite register interface. `make elab` elaborates it on its own
# defaults, which are the AU200's.
APP_BLOCK_SRC = $(RTL_DIR)/mqnic_app_block_ssr_dataplane.v $(SSR_DATAPLANE_SRC) \
                $(CORUNDUM_DIR)/fpga/lib/axi/rtl/axil_reg_if.v \
                $(CORUNDUM_DIR)/fpga/lib/axi/rtl/axil_reg_if_rd.v \
                $(CORUNDUM_DIR)/fpga/lib/axi/rtl/axil_reg_if_wr.v

# ==============================================================================
# Targets
# ==============================================================================

.PHONY: all regress clean elab $(UNIT_BENCHES) tb_ssr_core_protocol \
        tb_ssr_dataplane tb_ssr_dataplane_wave tb_ssr_dataplane_fst

all: regress

# WAVEFORMS FROM tb_ssr_dataplane. Running the bench on its own writes
# build/tb_ssr_dataplane.vcd; the regression does not (a full dump is large).
#
#   make tb_ssr_dataplane                        full hierarchy, whole run
#   make tb_ssr_dataplane SSR_WAVE=+dump_edge    DUT boundary only
#   make tb_ssr_dataplane SSR_WAVE=              no waveform at all
#   make tb_ssr_dataplane_wave FROM=176 FOR=14   one test, see below
#   make tb_ssr_dataplane_fst                    whole run as FST, for Surfer
SSR_WAVE ?= +dump

regress: SSR_WAVE :=
regress: elab tb_ssr_core_timing tb_ssr_core_protocol tb_ssr_dma_tag_pool \
         tb_ssr_payload_stage tb_ssr_payload_dma_writer tb_ssr_presence_tracker \
         tb_ssr_verdict_dma_writer tb_ssr_tx_engine tb_ssr_rx_demux tb_ssr_rx_engine \
         tb_ssr_proposal_ring tb_ssr_dataplane tb_ssr_dataplane_node1
	@echo "=================================================="
	@echo "🟢 regression suite complete"
	@echo "=================================================="

# Elaborate ssr_dataplane with every module it instantiates, and run its
# parameter checks. No stimulus: this catches a port that has no driver, a
# parameter that no longer fits, or a module missing from the list, all of
# which the unit benches cannot see because they never build the wrapper.
# Then the same for mqnic_app_block, on its (AU200) defaults.
elab: | $(BUILD_DIR)
	@echo "------------------------------------------------"
	@echo "Elaborating ssr_dataplane and mqnic_app_block..."
	@echo "------------------------------------------------"
	@printf '`timescale 1ns/1ps\nmodule elab_top; initial begin #1; $$display("  ssr_dataplane: ELABORATED OK"); $$finish; end endmodule\n' > $(BUILD_DIR)/elab_top.v
	iverilog $(IV_FLAGS) -s ssr_dataplane -s elab_top -o $(BUILD_DIR)/elab.out $(SSR_DATAPLANE_SRC) $(BUILD_DIR)/elab_top.v
	vvp $(BUILD_DIR)/elab.out
	@printf '`timescale 1ns/1ps\nmodule elab_app_top; initial begin #1; $$display("  mqnic_app_block (AU200 defaults): ELABORATED OK"); $$finish; end endmodule\n' > $(BUILD_DIR)/elab_app_top.v
	iverilog $(IV_FLAGS) -s mqnic_app_block -s elab_app_top -o $(BUILD_DIR)/elab_app.out $(APP_BLOCK_SRC) $(BUILD_DIR)/elab_app_top.v
	vvp $(BUILD_DIR)/elab_app.out

# One rule for every unit bench: compile <bench>.v against <bench>_SRC, run it.
$(UNIT_BENCHES): %: | $(BUILD_DIR)
	@echo "------------------------------------------------"
	@echo "Running $@ ..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/$@.out $($@_SRC) $(TB_DIR)/$@.v
	vvp $(BUILD_DIR)/$@.out

tb_ssr_core_protocol: | $(BUILD_DIR)
	@for n in $(CORE_PROTOCOL_NODE_COUNTS); do \
		echo "------------------------------------------------"; \
		echo "Running $@, NODE_COUNT=$$n"; \
		echo "------------------------------------------------"; \
		iverilog $(IV_FLAGS) -DSSR_TB_NODE_COUNT=$$n -o $(BUILD_DIR)/$@_$$n.out \
			$($@_SRC) $(TB_DIR)/$@.v || exit 1; \
		vvp $(BUILD_DIR)/$@_$$n.out || exit 1; \
	done

tb_ssr_dataplane: | $(BUILD_DIR)
	@echo "------------------------------------------------"
	@echo "Running tb_ssr_dataplane (the wrapper, ~1.5 min) ..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/$@.out $(SSR_DATAPLANE_TB) $(SSR_DATAPLANE_SRC)
	vvp $(BUILD_DIR)/$@.out $(SSR_WAVE)

# The same bench with the RTL playing node 1 (or 2) instead of node 0. The
# host address has a node term, the record a self_index, our own region is the
# one never written and ssr_rx_engine refuses our own id: a node-0 build cannot
# tell any of those apart from a constant. node1 is in the regression. The soak
# (I1) runs short in the rotated builds - SOAK_ROUNDS=280 to run it whole.
# The rotated builds also put SSR on the second interface (SSR_IF=1), so the
# regression runs both lane placements.
SOAK_ROUNDS ?= 12
SSR_IF      ?= 1
tb_ssr_dataplane_node%: | $(BUILD_DIR)
	@echo "------------------------------------------------"
	@echo "Running tb_ssr_dataplane as node $*, SSR on interface $(SSR_IF) ..."
	@echo "------------------------------------------------"
	iverilog $(IV_FLAGS) -DSSR_TB_NODE_ID=$* -DSSR_TB_IF=$(SSR_IF) -DSSR_TB_SOAK_ROUNDS=$(SOAK_ROUNDS) -o $(BUILD_DIR)/tb_ssr_dataplane_node$*.out $(SSR_DATAPLANE_TB) $(SSR_DATAPLANE_SRC)
	vvp $(BUILD_DIR)/tb_ssr_dataplane_node$*.out $(SSR_WAVE)

# A VCD of part of the run. DUMP picks what to record (dump = everything,
# dump_edge = the DUT boundary) and FROM/FOR (microseconds) pick when; each
# test prints its start time in its banner, in picoseconds.
DUMP ?= dump_edge
FROM ?=
FOR  ?=
tb_ssr_dataplane_wave: | $(BUILD_DIR)
	iverilog $(IV_FLAGS) -o $(BUILD_DIR)/tb_ssr_dataplane.out $(SSR_DATAPLANE_TB) $(SSR_DATAPLANE_SRC)
	vvp $(BUILD_DIR)/tb_ssr_dataplane.out +$(DUMP) \
	    $(if $(FROM),+dump_after=$(FROM),) $(if $(FOR),+dump_for=$(FOR),)
	@ls -lh $(BUILD_DIR)/tb_ssr_dataplane.vcd

# The whole run, every signal, as one FST file for Surfer or GTKWave.
#   make tb_ssr_dataplane_fst [NODE_ID=1]  ->  build/tb_ssr_dataplane.fst
NODE_ID ?= 0
tb_ssr_dataplane_fst: | $(BUILD_DIR)
	iverilog $(IV_FLAGS) -DSSR_TB_NODE_ID=$(NODE_ID) -o $(BUILD_DIR)/tb_ssr_dataplane_fst.out $(SSR_DATAPLANE_TB) $(SSR_DATAPLANE_SRC)
	vvp $(BUILD_DIR)/tb_ssr_dataplane_fst.out -fst +dump +fst
	@ls -lh $(BUILD_DIR)/tb_ssr_dataplane.fst

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

clean:
	rm -rf $(BUILD_DIR)
