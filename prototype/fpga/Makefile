# SPDX-License-Identifier: BSD-2-Clause-Views
# Compilation Corundum NIC with SSR application

BUILD_DIR := $(CURDIR)/build

ifeq ($(IN_BUILD),1)

# ============================================================
# Inner build section: real Vivado build runs inside build/
# ============================================================

# Project paths
FPGA_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
PROJECT_ROOT := $(abspath $(FPGA_DIR)/..)

# Corundum paths
CORUNDUM_ROOT ?= $(FPGA_DIR)/corundum/
CORUNDUM_BOARD ?= $(CORUNDUM_ROOT)/fpga/mqnic/Alveo/fpga_100g
CORUNDUM_COMMON ?= $(CORUNDUM_ROOT)/fpga/common
CORUNDUM_LIB ?= $(CORUNDUM_ROOT)/fpga/lib/
SSR_APP_DIR := $(PROJECT_ROOT)/fpga/

# Local paths
LOCAL_RTL_DIR := $(FPGA_DIR)/rtl
LOCAL_CONFIG_TCL := $(FPGA_DIR)/config.tcl

#FPGA settings
FPGA_PART = xcu200-fsgd2104-2-e
FPGA_TOP = fpga
FPGA_ARCH = virtexuplus

#Files for synthesis
SYN_FILES = $(CORUNDUM_BOARD)/rtl/fpga_au200.v
SYN_FILES += $(CORUNDUM_BOARD)/rtl/fpga_core.v
SYN_FILES += $(CORUNDUM_BOARD)/rtl/debounce_switch.v
SYN_FILES += $(CORUNDUM_BOARD)/rtl/sync_signal.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_core_pcie_us.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_core_pcie.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_core.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_dram_if.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_interface.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_interface_tx.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_interface_rx.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_port.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_port_tx.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_port_rx.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_egress.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_ingress.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_l2_egress.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_l2_ingress.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_rx_queue_map.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_ptp.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_ptp_clock.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_ptp_perout.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_rb_clk_info.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_port_map_mac_axis.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/cpl_write.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/cpl_op_mux.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/desc_fetch.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/desc_op_mux.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/queue_manager.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/cpl_queue_manager.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/tx_fifo.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/rx_fifo.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/tx_req_mux.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/tx_engine.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/rx_engine.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/tx_checksum.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/rx_hash.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/rx_checksum.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/rb_drp.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/cmac_gty_wrapper.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/cmac_gty_ch_wrapper.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/stats_counter.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/stats_collect.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/stats_pcie_if.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/stats_pcie_tlp.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/stats_dma_if_pcie.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/stats_dma_latency.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mqnic_tx_scheduler_block_rr.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/tx_scheduler_rr.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/cmac_pad.v
SYN_FILES += $(CORUNDUM_COMMON)/rtl/mac_ts_insert.v

# Application-specific files: the app block, the SSR wrapper and every
# module it instantiates (the same list as tb/ssr_dataplane's SSR_DATAPLANE_SRC).
# Every SSR module is ssr_<name>: Corundum has its own tx_engine and rx_engine
# in this same list.
SYN_FILES += $(SSR_APP_DIR)/rtl/mqnic_app_block_ssr_dataplane.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_dataplane.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_csr.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_core.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_tx_engine.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_rx_engine.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_tx_mux.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_rx_demux.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_proposal_dma_reader.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_proposal_buffer.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_payload_stage.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_payload_dma_writer.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_dma_tag_pool.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_presence_tracker.v
SYN_FILES += $(SSR_APP_DIR)/rtl/ssr_verdict_dma_writer.v
INC_FILES += $(SSR_APP_DIR)/rtl/ssr_packet.vh
INC_FILES += $(SSR_APP_DIR)/rtl/ssr_verdict.vh

# Library files
SYN_FILES += $(CORUNDUM_LIB)/eth/rtl/ptp_td_phc.v
SYN_FILES += $(CORUNDUM_LIB)/eth/rtl/ptp_td_leaf.v
SYN_FILES += $(CORUNDUM_LIB)/eth/rtl/ptp_td_rel2tod.v
SYN_FILES += $(CORUNDUM_LIB)/eth/rtl/ptp_perout.v
SYN_FILES += $(CORUNDUM_LIB)/eth/rtl/lfsr.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axi_vfifo_raw.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axi_vfifo_raw_rd.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axi_vfifo_raw_wr.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_cdc.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_cdc_rd.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_cdc_wr.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_interconnect.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_crossbar.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_crossbar_addr.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_crossbar_rd.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_crossbar_wr.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_reg_if.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_reg_if_rd.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_reg_if_wr.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_register_rd.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/axil_register_wr.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/arbiter.v
SYN_FILES += $(CORUNDUM_LIB)/axi/rtl/priority_encoder.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_adapter.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_arb_mux.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_async_fifo.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_async_fifo_adapter.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_demux.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_fifo.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_fifo_adapter.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_pipeline_fifo.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/axis_register.v
SYN_FILES += $(CORUNDUM_LIB)/axis/rtl/sync_reset.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_axil_master.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_tlp_demux.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_tlp_demux_bar.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_tlp_mux.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_tlp_fifo.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_tlp_fifo_raw.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_msix.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/irq_rate_limit.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_if_pcie.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_if_pcie_rd.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_if_pcie_wr.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_if_mux.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_if_mux_rd.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_if_mux_wr.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_if_desc_mux.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_ram_demux_rd.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_ram_demux_wr.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_psdpram.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_client_axis_sink.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/dma_client_axis_source.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_us_if.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_us_if_rc.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_us_if_rq.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_us_if_cc.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_us_if_cq.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pcie_us_cfg.v
SYN_FILES += $(CORUNDUM_LIB)/pcie/rtl/pulse_merge.v

# XDC files
XDC_FILES = $(CORUNDUM_BOARD)/fpga_au200.xdc
XDC_FILES += $(CORUNDUM_BOARD)/placement_au200.xdc
XDC_FILES += $(CORUNDUM_BOARD)/cfgmclk.xdc
XDC_FILES += $(CORUNDUM_BOARD)/boot.xdc
XDC_FILES += $(CORUNDUM_LIB)/axi/syn/vivado/axil_cdc.tcl
XDC_FILES += $(CORUNDUM_LIB)/axi/syn/vivado/axi_vfifo_raw.tcl
XDC_FILES += $(CORUNDUM_LIB)/axi/syn/vivado/axi_vfifo_raw_rd.tcl
XDC_FILES += $(CORUNDUM_LIB)/axi/syn/vivado/axi_vfifo_raw_wr.tcl
XDC_FILES += $(CORUNDUM_LIB)/axis/syn/vivado/axis_async_fifo.tcl
XDC_FILES += $(CORUNDUM_LIB)/axis/syn/vivado/sync_reset.tcl
XDC_FILES += $(CORUNDUM_LIB)/eth/syn/vivado/ptp_td_leaf.tcl
XDC_FILES += $(CORUNDUM_LIB)/eth/syn/vivado/ptp_td_rel2tod.tcl
XDC_FILES += $(CORUNDUM_COMMON)/syn/vivado/mqnic_port.tcl
XDC_FILES += $(CORUNDUM_COMMON)/syn/vivado/mqnic_ptp_clock.tcl
XDC_FILES += $(CORUNDUM_COMMON)/syn/vivado/mqnic_rb_clk_info.tcl
XDC_FILES += $(CORUNDUM_COMMON)/syn/vivado/rb_drp.tcl
XDC_FILES += $(CORUNDUM_COMMON)/syn/vivado/cmac_gty_wrapper.tcl
XDC_FILES += $(CORUNDUM_COMMON)/syn/vivado/cmac_gty_ch_wrapper.tcl

# Application-specific constraints
XDC_FILES += $(SSR_APP_DIR)/syn/vivado/ssr_core.tcl

# IP
IP_TCL_FILES = $(CORUNDUM_BOARD)/ip/pcie4_uscale_plus_0.tcl
IP_TCL_FILES += $(CORUNDUM_BOARD)/ip/cmac_usplus.tcl
IP_TCL_FILES += $(CORUNDUM_BOARD)/ip/cmac_gty.tcl
IP_TCL_FILES += $(CORUNDUM_BOARD)/ip/cms.tcl
IP_TCL_FILES += $(CORUNDUM_BOARD)/ip/ddr4_0.tcl

# Configuration
CONFIG_TCL_FILES = $(LOCAL_CONFIG_TCL)

include $(CORUNDUM_BOARD)/common/vivado.mk

program: $(FPGA_TOP).bit
	@echo "------------------------------------------------"
	@echo "🚀 Programming FPGA with $(FPGA_TOP).bit..."
	@echo "------------------------------------------------"
	echo "open_hw" > program.tcl
	echo "connect_hw_server" >> program.tcl
	echo "open_hw_target" >> program.tcl
	echo "current_hw_device [lindex [get_hw_devices] 0]" >> program.tcl
	echo "refresh_hw_device -update_hw_probes false [lindex [get_hw_devices] 0]" >> program.tcl
	echo "set_property PROGRAM.FILE {$(FPGA_TOP).bit} [current_hw_device]" >> program.tcl
	echo "exit" >> program.tcl
	vivado -nojournal -nolog -mode batch -source program.tcl
else
# ============================================================
# Outer build section: this is the Makefile that gets called by the user
# ============================================================

.PHONY: all clean program clean distclean

all: fpga

fpga:
	mkdir -p $(BUILD_DIR)
	ln -sf ../Makefile $(BUILD_DIR)/Makefile
	$(MAKE) -C $(BUILD_DIR) -f ../Makefile IN_BUILD=1 fpga

program:
	mkdir -p $(BUILD_DIR)
	ln -sf ../Makefile $(BUILD_DIR)/Makefile
	$(MAKE) -C $(BUILD_DIR) -f ../Makefile IN_BUILD=1 program

clean:
	if [ -d $(BUILD_DIR) ]; \
		then ln -sf ../Makefile $(BUILD_DIR)/Makefile; \
		fi
	if [ -f $(BUILD_DIR)/Makefile ]; then \
		$(MAKE) -C $(BUILD_DIR) -f ../Makefile IN_BUILD=1 clean; \
	fi

distclean: clean
	rm -rf $(BUILD_DIR)

endif
