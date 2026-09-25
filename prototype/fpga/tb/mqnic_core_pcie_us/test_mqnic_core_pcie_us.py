# SPDX-License-Identifier: BSD-2-Clause-Views
# Copyright (c) 2021-2023 The Regents of the University of California

import logging
import os
import struct
import sys

import scapy.utils
from scapy.layers.l2 import Ether
from scapy.layers.inet import IP, UDP

import cocotb
from cocotb.log import SimLog
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, Timer

from cocotbext.axi import AxiStreamBus
from cocotbext.axi import AxiSlave, AxiBus, SparseMemoryRegion
from cocotbext.eth import EthMac
from cocotbext.pcie.core import RootComplex
from cocotbext.pcie.xilinx.us import UltraScalePlusPcieDevice

try:
    import mqnic
    import ssr_dataplane as ssr
    import ssr_sim_harness as ssr_sim
    import ssr_packet
except ImportError:
    # attempt import from current directory
    sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
    try:
        import mqnic
        import ssr_dataplane as ssr
        import ssr_sim_harness as ssr_sim
        import ssr_packet
    finally:
        del sys.path[0]


class TB(object):
    def __init__(self, dut, msix_count=32):
        self.dut = dut

        self.log = SimLog("cocotb.tb")
        self.log.setLevel(logging.DEBUG)

        # PCIe
        self.rc = RootComplex()

        self.rc.max_payload_size = 0x1  # 256 bytes
        self.rc.max_read_request_size = 0x2  # 512 bytes

        self.dev = UltraScalePlusPcieDevice(
            # configuration options
            pcie_generation=3,
            # pcie_link_width=16,
            user_clk_frequency=250e6,
            alignment="dword",
            cq_straddle=len(dut.pcie_if_inst.pcie_us_if_cq_inst.rx_req_tlp_valid_reg) > 1,
            cc_straddle=len(dut.pcie_if_inst.pcie_us_if_cc_inst.out_tlp_valid) > 1,
            rq_straddle=len(dut.pcie_if_inst.pcie_us_if_rq_inst.out_tlp_valid) > 1,
            rc_straddle=len(dut.pcie_if_inst.pcie_us_if_rc_inst.rx_cpl_tlp_valid_reg) > 1,
            rc_4tlp_straddle=len(dut.pcie_if_inst.pcie_us_if_rc_inst.rx_cpl_tlp_valid_reg) > 2,
            pf_count=1,
            max_payload_size=1024,
            enable_client_tag=True,
            enable_extended_tag=True,
            enable_parity=False,
            enable_rx_msg_interface=False,
            enable_sriov=False,
            enable_extended_configuration=False,

            pf0_msi_enable=False,
            pf0_msi_count=32,
            pf1_msi_enable=False,
            pf1_msi_count=1,
            pf2_msi_enable=False,
            pf2_msi_count=1,
            pf3_msi_enable=False,
            pf3_msi_count=1,
            pf0_msix_enable=True,
            pf0_msix_table_size=msix_count-1,
            pf0_msix_table_bir=0,
            pf0_msix_table_offset=0x00010000,
            pf0_msix_pba_bir=0,
            pf0_msix_pba_offset=0x00018000,
            pf1_msix_enable=False,
            pf1_msix_table_size=0,
            pf1_msix_table_bir=0,
            pf1_msix_table_offset=0x00000000,
            pf1_msix_pba_bir=0,
            pf1_msix_pba_offset=0x00000000,
            pf2_msix_enable=False,
            pf2_msix_table_size=0,
            pf2_msix_table_bir=0,
            pf2_msix_table_offset=0x00000000,
            pf2_msix_pba_bir=0,
            pf2_msix_pba_offset=0x00000000,
            pf3_msix_enable=False,
            pf3_msix_table_size=0,
            pf3_msix_table_bir=0,
            pf3_msix_table_offset=0x00000000,
            pf3_msix_pba_bir=0,
            pf3_msix_pba_offset=0x00000000,

            # signals
            # Clock and Reset Interface
            user_clk=dut.clk,
            user_reset=dut.rst,
            # user_lnk_up
            # sys_clk
            # sys_clk_gt
            # sys_reset
            # phy_rdy_out

            # Requester reQuest Interface
            rq_bus=AxiStreamBus.from_prefix(dut, "m_axis_rq"),
            pcie_rq_seq_num0=dut.s_axis_rq_seq_num_0,
            pcie_rq_seq_num_vld0=dut.s_axis_rq_seq_num_valid_0,
            pcie_rq_seq_num1=dut.s_axis_rq_seq_num_1,
            pcie_rq_seq_num_vld1=dut.s_axis_rq_seq_num_valid_1,
            # pcie_rq_tag0
            # pcie_rq_tag1
            # pcie_rq_tag_av
            # pcie_rq_tag_vld0
            # pcie_rq_tag_vld1

            # Requester Completion Interface
            rc_bus=AxiStreamBus.from_prefix(dut, "s_axis_rc"),

            # Completer reQuest Interface
            cq_bus=AxiStreamBus.from_prefix(dut, "s_axis_cq"),
            # pcie_cq_np_req
            # pcie_cq_np_req_count

            # Completer Completion Interface
            cc_bus=AxiStreamBus.from_prefix(dut, "m_axis_cc"),

            # Transmit Flow Control Interface
            # pcie_tfc_nph_av=dut.pcie_tfc_nph_av,
            # pcie_tfc_npd_av=dut.pcie_tfc_npd_av,

            # Configuration Management Interface
            cfg_mgmt_addr=dut.cfg_mgmt_addr,
            cfg_mgmt_function_number=dut.cfg_mgmt_function_number,
            cfg_mgmt_write=dut.cfg_mgmt_write,
            cfg_mgmt_write_data=dut.cfg_mgmt_write_data,
            cfg_mgmt_byte_enable=dut.cfg_mgmt_byte_enable,
            cfg_mgmt_read=dut.cfg_mgmt_read,
            cfg_mgmt_read_data=dut.cfg_mgmt_read_data,
            cfg_mgmt_read_write_done=dut.cfg_mgmt_read_write_done,
            # cfg_mgmt_debug_access

            # Configuration Status Interface
            # cfg_phy_link_down
            # cfg_phy_link_status
            # cfg_negotiated_width
            # cfg_current_speed
            cfg_max_payload=dut.cfg_max_payload,
            cfg_max_read_req=dut.cfg_max_read_req,
            # cfg_function_status
            # cfg_vf_status
            # cfg_function_power_state
            # cfg_vf_power_state
            # cfg_link_power_state
            # cfg_err_cor_out
            # cfg_err_nonfatal_out
            # cfg_err_fatal_out
            # cfg_local_error_out
            # cfg_local_error_valid
            # cfg_rx_pm_state
            # cfg_tx_pm_state
            # cfg_ltssm_state
            cfg_rcb_status=dut.cfg_rcb_status,
            # cfg_obff_enable
            # cfg_pl_status_change
            # cfg_tph_requester_enable
            # cfg_tph_st_mode
            # cfg_vf_tph_requester_enable
            # cfg_vf_tph_st_mode

            # Configuration Received Message Interface
            # cfg_msg_received
            # cfg_msg_received_data
            # cfg_msg_received_type

            # Configuration Transmit Message Interface
            # cfg_msg_transmit
            # cfg_msg_transmit_type
            # cfg_msg_transmit_data
            # cfg_msg_transmit_done

            # Configuration Flow Control Interface
            cfg_fc_ph=dut.cfg_fc_ph,
            cfg_fc_pd=dut.cfg_fc_pd,
            cfg_fc_nph=dut.cfg_fc_nph,
            cfg_fc_npd=dut.cfg_fc_npd,
            cfg_fc_cplh=dut.cfg_fc_cplh,
            cfg_fc_cpld=dut.cfg_fc_cpld,
            cfg_fc_sel=dut.cfg_fc_sel,

            # Configuration Control Interface
            # cfg_hot_reset_in
            # cfg_hot_reset_out
            # cfg_config_space_enable
            # cfg_dsn
            # cfg_bus_number
            # cfg_ds_port_number
            # cfg_ds_bus_number
            # cfg_ds_device_number
            # cfg_ds_function_number
            # cfg_power_state_change_ack
            # cfg_power_state_change_interrupt
            cfg_err_cor_in=dut.status_error_cor,
            cfg_err_uncor_in=dut.status_error_uncor,
            # cfg_flr_in_process
            # cfg_flr_done
            # cfg_vf_flr_in_process
            # cfg_vf_flr_func_num
            # cfg_vf_flr_done
            # cfg_pm_aspm_l1_entry_reject
            # cfg_pm_aspm_tx_l0s_entry_disable
            # cfg_req_pm_transition_l23_ready
            # cfg_link_training_enable

            # Configuration Interrupt Controller Interface
            # cfg_interrupt_int
            # cfg_interrupt_sent
            # cfg_interrupt_pending
            # cfg_interrupt_msi_enable
            # cfg_interrupt_msi_mmenable
            # cfg_interrupt_msi_mask_update
            # cfg_interrupt_msi_data
            # cfg_interrupt_msi_select
            # cfg_interrupt_msi_int
            # cfg_interrupt_msi_pending_status
            # cfg_interrupt_msi_pending_status_data_enable
            # cfg_interrupt_msi_pending_status_function_num
            # cfg_interrupt_msi_sent
            # cfg_interrupt_msi_fail
            cfg_interrupt_msix_enable=dut.cfg_interrupt_msix_enable,
            cfg_interrupt_msix_mask=dut.cfg_interrupt_msix_mask,
            cfg_interrupt_msix_vf_enable=dut.cfg_interrupt_msix_vf_enable,
            cfg_interrupt_msix_vf_mask=dut.cfg_interrupt_msix_vf_mask,
            cfg_interrupt_msix_address=dut.cfg_interrupt_msix_address,
            cfg_interrupt_msix_data=dut.cfg_interrupt_msix_data,
            cfg_interrupt_msix_int=dut.cfg_interrupt_msix_int,
            cfg_interrupt_msix_vec_pending=dut.cfg_interrupt_msix_vec_pending,
            cfg_interrupt_msix_vec_pending_status=dut.cfg_interrupt_msix_vec_pending_status,
            cfg_interrupt_msix_sent=dut.cfg_interrupt_msix_sent,
            cfg_interrupt_msix_fail=dut.cfg_interrupt_msix_fail,
            # cfg_interrupt_msi_attr
            # cfg_interrupt_msi_tph_present
            # cfg_interrupt_msi_tph_type
            # cfg_interrupt_msi_tph_st_tag
            cfg_interrupt_msi_function_number=dut.cfg_interrupt_msi_function_number,

            # Configuration Extend Interface
            # cfg_ext_read_received
            # cfg_ext_write_received
            # cfg_ext_register_number
            # cfg_ext_function_number
            # cfg_ext_write_data
            # cfg_ext_write_byte_enable
            # cfg_ext_read_data
            # cfg_ext_read_data_valid
        )

        # self.dev.log.setLevel(logging.DEBUG)

        self.rc.make_port().connect(self.dev)

        self.driver = mqnic.Driver()

        self.dev.functions[0].configure_bar(0, 2**len(dut.core_pcie_inst.axil_ctrl_araddr), ext=True, prefetch=True)
        if hasattr(dut.core_pcie_inst, 'pcie_app_ctrl'):
            self.dev.functions[0].configure_bar(2, 2**len(dut.core_pcie_inst.axil_app_ctrl_araddr), ext=True, prefetch=True)

        core_inst = dut.core_pcie_inst.core_inst

        # Ethernet
        self.port_mac = []

        eth_int_if_width = len(core_inst.m_axis_tx_tdata) / len(core_inst.m_axis_tx_tvalid)
        eth_clock_period = 6.4
        eth_speed = 10e9

        if eth_int_if_width == 64:
            # 10G
            eth_clock_period = 6.4
            eth_speed = 10e9
        elif eth_int_if_width == 128:
            # 25G
            eth_clock_period = 2.56
            eth_speed = 25e9
        elif eth_int_if_width == 512:
            # 100G
            eth_clock_period = 3.102
            eth_speed = 100e9

        for iface in core_inst.iface:
            for k in range(len(iface.port)):
                cocotb.start_soon(Clock(iface.port[k].port_rx_clk, eth_clock_period, units="ns").start())
                cocotb.start_soon(Clock(iface.port[k].port_tx_clk, eth_clock_period, units="ns").start())

                iface.port[k].port_rx_rst.setimmediatevalue(0)
                iface.port[k].port_tx_rst.setimmediatevalue(0)

                mac = EthMac(
                    tx_clk=iface.port[k].port_tx_clk,
                    tx_rst=iface.port[k].port_tx_rst,
                    tx_bus=AxiStreamBus.from_prefix(iface.interface_inst.port[k].port_inst.port_tx_inst, "m_axis_tx"),
                    tx_ptp_time=iface.port[k].port_tx_ptp_ts_tod if core_inst.PTP_TS_FMT_TOD.value else iface.port[k].port_tx_ptp_ts_rel,
                    tx_ptp_ts=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_ts,
                    tx_ptp_ts_tag=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_tag,
                    tx_ptp_ts_valid=iface.interface_inst.port[k].port_inst.port_tx_inst.s_axis_tx_cpl_valid,
                    rx_clk=iface.port[k].port_rx_clk,
                    rx_rst=iface.port[k].port_rx_rst,
                    rx_bus=AxiStreamBus.from_prefix(iface.interface_inst.port[k].port_inst.port_rx_inst, "s_axis_rx"),
                    rx_ptp_time=iface.port[k].port_rx_ptp_ts_tod if core_inst.PTP_TS_FMT_TOD.value else iface.port[k].port_rx_ptp_ts_rel,
                    ifg=12, speed=eth_speed
                )

                self.port_mac.append(mac)

        dut.eth_tx_status.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_tx_fc_quanta_clk_en.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_rx_status.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)
        dut.eth_rx_lfc_req.setimmediatevalue(0)
        dut.eth_rx_pfc_req.setimmediatevalue(0)
        dut.eth_rx_fc_quanta_clk_en.setimmediatevalue(2**len(core_inst.m_axis_tx_tvalid)-1)

        # DDR
        self.ddr_group_size = core_inst.DDR_GROUP_SIZE.value
        self.ddr_ram = []
        self.ddr_axi_if = []
        if hasattr(core_inst, 'ddr'):
            ram = None
            for i, ch in enumerate(core_inst.ddr.dram_if_inst.ch):
                cocotb.start_soon(Clock(ch.ch_clk, 3.332, units="ns").start())
                ch.ch_rst.setimmediatevalue(0)
                ch.ch_status.setimmediatevalue(1)

                if i % self.ddr_group_size == 0:
                    ram = SparseMemoryRegion()
                    self.ddr_ram.append(ram)
                self.ddr_axi_if.append(AxiSlave(AxiBus.from_prefix(ch, "axi_ch"), ch.ch_clk, ch.ch_rst, target=ram))

        # HBM
        self.hbm_group_size = core_inst.HBM_GROUP_SIZE.value
        self.hbm_ram = []
        self.hbm_axi_if = []
        if hasattr(core_inst, 'hbm'):
            ram = None
            for i, ch in enumerate(core_inst.hbm.dram_if_inst.ch):
                cocotb.start_soon(Clock(ch.ch_clk, 2.222, units="ns").start())
                ch.ch_rst.setimmediatevalue(0)
                ch.ch_status.setimmediatevalue(1)

                if i % self.hbm_group_size == 0:
                    ram = SparseMemoryRegion()
                    self.hbm_ram.append(ram)
                self.hbm_axi_if.append(AxiSlave(AxiBus.from_prefix(ch, "axi_ch"), ch.ch_clk, ch.ch_rst, target=ram))

        dut.ctrl_reg_wr_wait.setimmediatevalue(0)
        dut.ctrl_reg_wr_ack.setimmediatevalue(0)
        dut.ctrl_reg_rd_data.setimmediatevalue(0)
        dut.ctrl_reg_rd_wait.setimmediatevalue(0)
        dut.ctrl_reg_rd_ack.setimmediatevalue(0)

        # The PTP clock at the period the core was built for (1024/165 ns on
        # the AU200), so the PHC's increment and the clock agree.
        ptp_clk_period = int(dut.PTP_CLK_PERIOD_NS_NUM.value) / int(dut.PTP_CLK_PERIOD_NS_DENOM.value)
        cocotb.start_soon(Clock(dut.ptp_clk, round(ptp_clk_period, 3), units="ns").start())
        dut.ptp_rst.setimmediatevalue(0)
        cocotb.start_soon(Clock(dut.ptp_sample_clk, 8, units="ns").start())

        dut.s_axis_stat_tdata.setimmediatevalue(0)
        dut.s_axis_stat_tid.setimmediatevalue(0)
        dut.s_axis_stat_tvalid.setimmediatevalue(0)

        self.loopback_enable = False
        cocotb.start_soon(self._run_loopback())

    async def init(self):

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(0)
            mac.tx.reset.setimmediatevalue(0)

        self.dut.ptp_rst.setimmediatevalue(0)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(0)

        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(1)
            mac.tx.reset.setimmediatevalue(1)

        self.dut.ptp_rst.setimmediatevalue(1)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(1)

        await FallingEdge(self.dut.rst)
        await Timer(100, 'ns')

        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

        for mac in self.port_mac:
            mac.rx.reset.setimmediatevalue(0)
            mac.tx.reset.setimmediatevalue(0)

        self.dut.ptp_rst.setimmediatevalue(0)

        for ram in self.ddr_axi_if + self.ddr_axi_if:
            ram.write_if.reset.setimmediatevalue(0)

        await self.rc.enumerate()

    async def _run_loopback(self):
        while True:
            await RisingEdge(self.dut.clk)

            if self.loopback_enable:
                for mac in self.port_mac:
                    if not mac.tx.empty():
                        await mac.rx.send(await mac.tx.recv())

@cocotb.test()
async def run_test_nic(dut):

    tb = TB(dut, msix_count=2**len(dut.core_pcie_inst.irq_index))

    await tb.init()

    tb.log.info("Init driver")
    await tb.driver.init_pcie_dev(tb.rc.find_device(tb.dev.functions[0].pcie_id))
    for interface in tb.driver.interfaces:
        await interface.ndevs[0].open()

    tb.log.info("Init complete")

    tb.log.info("Send and receive single packet")

    for interface in tb.driver.interfaces:
        data = bytearray([x % 256 for x in range(1024)])

        await interface.ndevs[0].start_xmit(data, 0)

        pkt = await tb.port_mac[interface.index*interface.port_count].tx.recv()
        tb.log.info("Packet: %s", pkt)

        await tb.port_mac[interface.index*interface.port_count].rx.send(pkt)

        pkt = await interface.ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if interface.if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.log.info("RX and TX checksum tests")

    payload = bytes([x % 256 for x in range(256)])
    eth = Ether(src='5A:51:52:53:54:55', dst='DA:D1:D2:D3:D4:D5')
    ip = IP(src='192.168.1.100', dst='192.168.1.101')
    udp = UDP(sport=1, dport=2)
    test_pkt = eth / ip / udp / payload

    if tb.driver.interfaces[0].if_feature_tx_csum:
        test_pkt2 = test_pkt.copy()
        test_pkt2[UDP].chksum = scapy.utils.checksum(bytes(test_pkt2[UDP]))

        await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt2.build(), 0, 34, 6)
    else:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt.build(), 0)

    pkt = await tb.port_mac[0].tx.recv()
    tb.log.info("Packet: %s", pkt)

    await tb.port_mac[0].rx.send(pkt)

    pkt = await tb.driver.interfaces[0].ndevs[0].recv()

    tb.log.info("Packet: %s", pkt)
    if tb.driver.interfaces[0].if_feature_rx_csum:
        assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff
    assert Ether(pkt.data).build() == test_pkt.build()

    tb.log.info("Queue mapping offset test")

    data = bytearray([x % 256 for x in range(1024)])

    tb.loopback_enable = True

    for k in range(4):
        await tb.driver.interfaces[0].set_rx_queue_map_indir_table(0, 0, tb.driver.interfaces[0].ndevs[0].rxq[k].index)

        await tb.driver.interfaces[0].ndevs[0].start_xmit(data, 0)

        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff
        assert pkt.queue == tb.driver.interfaces[0].ndevs[0].rxq[k].index

    tb.loopback_enable = False

    await tb.driver.interfaces[0].ndevs[0].update_rx_queue_map_indir_table()

    tb.log.info("Queue mapping RSS mask test")

    await tb.driver.interfaces[0].set_rx_queue_map_rss_mask(0, 0x00000003)

    tb.loopback_enable = True

    queues = set()

    for k in range(64):
        payload = bytes([x % 256 for x in range(256)])
        eth = Ether(src='5A:51:52:53:54:55', dst='DA:D1:D2:D3:D4:D5')
        ip = IP(src='192.168.1.100', dst='192.168.1.101')
        udp = UDP(sport=1, dport=k+0)
        test_pkt = eth / ip / udp / payload

        if tb.driver.interfaces[0].if_feature_tx_csum:
            test_pkt2 = test_pkt.copy()
            test_pkt2[UDP].chksum = scapy.utils.checksum(bytes(test_pkt2[UDP]))

            await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt2.build(), 0, 34, 6)
        else:
            await tb.driver.interfaces[0].ndevs[0].start_xmit(test_pkt.build(), 0)

    for k in range(64):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        queues.add(pkt.queue)

    assert len(queues) == 4

    tb.loopback_enable = False

    await tb.driver.interfaces[0].set_rx_queue_map_rss_mask(0, 0xffffffff)

    tb.log.info("Multiple small packets")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(60)]) for k in range(count)]

    tb.loopback_enable = True

    for p in pkts:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        assert pkt.data == pkts[k]
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    tb.log.info("Multiple TX queues")

    count = 1024

    pkts = [bytearray([(x+k) % 256 for x in range(60)]) for k in range(count)]

    tb.loopback_enable = True

    for k in range(len(pkts)):
        await tb.driver.interfaces[0].ndevs[0].start_xmit(pkts[k], k % tb.driver.interfaces[0].ndevs[0].txq_count)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    tb.log.info("Multiple large packets")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

    tb.loopback_enable = True

    for p in pkts:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        assert pkt.data == pkts[k]
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    tb.log.info("Jumbo frames")

    count = 64

    pkts = [bytearray([(x+k) % 256 for x in range(9014)]) for k in range(count)]

    tb.loopback_enable = True

    for p in pkts:
        await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

    for k in range(count):
        pkt = await tb.driver.interfaces[0].ndevs[0].recv()

        tb.log.info("Packet: %s", pkt)
        assert pkt.data == pkts[k]
        if tb.driver.interfaces[0].if_feature_rx_csum:
            assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

    tb.loopback_enable = False

    if len(tb.driver.interfaces) > 1:
        tb.log.info("All interfaces")

        count = 64

        pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

        tb.loopback_enable = True

        for k, p in enumerate(pkts):
            await tb.driver.interfaces[k % len(tb.driver.interfaces)].ndevs[0].start_xmit(p, 0)

        for k in range(count):
            pkt = await tb.driver.interfaces[k % len(tb.driver.interfaces)].ndevs[0].recv()

            tb.log.info("Packet: %s", pkt)
            assert pkt.data == pkts[k]
            if tb.driver.interfaces[0].if_feature_rx_csum:
                assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        tb.loopback_enable = False

    if len(tb.driver.interfaces[0].ndevs) > 1:
        tb.log.info("All interface 0 netdevs")

        for ndev in tb.driver.interfaces[0].ndevs:
            if not ndev.port_up:
                await ndev.open()

        count = 64

        pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

        tb.loopback_enable = True

        queues = set()

        for k, p in enumerate(pkts):
            await tb.driver.interfaces[0].ndevs[k % len(tb.driver.interfaces[0].ndevs)].start_xmit(p, 0)

        for k in range(count):
            pkt = await tb.driver.interfaces[0].ndevs[k % len(tb.driver.interfaces[0].ndevs)].recv()

            tb.log.info("Packet: %s", pkt)
            assert pkt.data == pkts[k]
            if tb.driver.interfaces[0].if_feature_rx_csum:
                assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        tb.loopback_enable = False

    if tb.driver.interfaces[0].if_feature_lfc:
        tb.log.info("Test LFC pause frame RX")

        await tb.driver.interfaces[0].ports[0].set_lfc_ctrl(mqnic.MQNIC_PORT_LFC_CTRL_TX_LFC_EN | mqnic.MQNIC_PORT_LFC_CTRL_RX_LFC_EN)
        await tb.driver.hw_regs.read_dword(0)

        lfc_xoff = Ether(src='DA:D1:D2:D3:D4:D5', dst='01:80:C2:00:00:01', type=0x8808) / struct.pack('!HH', 0x0001, 2000)

        await tb.port_mac[0].rx.send(bytes(lfc_xoff))

        count = 16

        pkts = [bytearray([(x+k) % 256 for x in range(1514)]) for k in range(count)]

        tb.loopback_enable = True

        for p in pkts:
            await tb.driver.interfaces[0].ndevs[0].start_xmit(p, 0)

        for k in range(count):
            pkt = await tb.driver.interfaces[0].ndevs[0].recv()

            tb.log.info("Packet: %s", pkt)
            assert pkt.data == pkts[k]
            if tb.driver.interfaces[0].if_feature_rx_csum:
                assert pkt.rx_checksum == ~scapy.utils.checksum(bytes(pkt.data[14:])) & 0xffff

        tb.loopback_enable = False


# =============================================================================
# SSR: the dataplane end to end inside Corundum
# =============================================================================
#
# These tests run the SSR app block through the real mqnic core: the real PCIe
# DMA engine (cocotbext-pcie's root complex behind it), the real interface and
# port pipelines, the cocotbext-eth MAC model on the port. Two modelled peers
# (ssr_sim_harness) put their frames on SSR's port at a real peer's transmit
# instant; the driver model (ssr_dataplane) does what a driver would.
#
# The exhaustive version of the protocol - the rejection ladder rung by rung,
# the fence under held completions, DMA errors, stale records - is
# tb/ssr_dataplane's tb_ssr_dataplane.v against the wrapper alone, in minutes.
# What is proved here is that the wrapper is wired into Corundum and that
# Corundum's DMA engine, its DMA RAM, its transmit/receive pipelines and its
# MAC agree with the models that bench used:
#
#   run_test_ssr_dataplane     bring-up, steady state: peer pages byte for
#                              byte, our proposals as fragments, the arrival
#                              budget through Corundum's receive path
#   run_test_ssr_backlog       24 proposals across three doorbells and a ring
#                              wrap: in order, <= 5 a round, every byte
#   run_test_ssr_short_peer    a peer one fragment short: ACK_DISAGREE, its
#                              prefix committed, out of the sound set, its
#                              later frames on the sound rung
#   run_test_ssr_halt_recover  both peers silent: halt (reason, witness,
#                              silent and deaf), then the driver's recovery:
#                              reboot, a fresh run id, records resume
#   run_test_ssr_nic_coexist   host traffic on both interfaces while the
#                              protocol runs: the other interface untouched,
#                              SSR's shared with the host, no round lost
#
# Every test brings the whole NIC up (~30 us of simulation); a round is 4 us
# and simulates in about four seconds of wall time.

SSR_RUN_ID = 0x77
SSR_NODE_ID = 0                 # the RTL's P_NODE_ID
SSR_MACS = ("02:00:00:00:00:01", "02:00:00:00:00:02", "02:00:00:00:00:03")
SSR_PEERS = (1, 2)
SSR_PEER_FRAGS = 2              # fragments per peer per round, by default
SSR_ROUND_NS = 4000
SSR_CTRL_WINDOW_NS = 646        # P_CTRL_PERIOD_NS: a control frame past it is late


def ssr_peer_stream(node: int, marker: int, frags: int = SSR_PEER_FRAGS) -> bytes:
    """A peer's payload for one round: `frags` full fragments whose bytes say
    which node and which marker they belong to."""
    one = bytes(((node << 4) ^ marker ^ i) & 0xFF for i in range(ssr_packet.FRAG_BYTES))
    return one * frags


class SSRBench:
    """One node of a three-node cluster, running: the NIC, its driver, the SSR
    driver with its rings, and the two peers on the port."""

    def __init__(self, dut):
        self.dut = dut
        self.tb = TB(dut, msix_count=2**len(dut.core_pcie_inst.irq_index))
        self.log = self.tb.log
        self.dp = dut.core_pcie_inst.core_inst.app.app_block_inst.ssr_dataplane_inst
        self.dev = ssr.SSRDevice()
        self.harness = None
        self.arrivals = []          # (round_id, ns into the round) of every SSR header at ssr_rx_engine
        self._watcher = None

    async def bringup(self, *, run_id=SSR_RUN_ID, peer_frags=SSR_PEER_FRAGS, settle_rounds=3):
        tb = self.tb
        await tb.init()
        tb.log.info("Init driver")
        await tb.driver.init_pcie_dev(tb.rc.find_device(tb.dev.functions[0].pcie_id))
        for interface in tb.driver.interfaces:
            await interface.ndevs[0].open()

        # The SSR driver: probe, configure, rings, delivery on BEFORE joining.
        tb.log.info("Init SSR driver")
        await self.dev.probe(tb.driver)
        ident = await self.dev.read_identity()
        tb.log.info("SSR identity: %s", ident)
        assert ident.node_id == SSR_NODE_ID and ident.node_count == 3 and ident.round_ns == SSR_ROUND_NS
        await self.dev.open()
        await self.dev.start()
        g = self.dev.delivery.geometry
        tb.log.info("delivery geometry: %s", g)
        assert g.node_count == 3 and g.page_bytes == ssr_packet.FRAME_BYTES
        assert await self.dev.delivery.read_fault() == 0

        # The peers, on SSR's port (interface SSR_IF_INDEX = 0, port 0).
        self.harness = ssr_sim.SSRSimHarness(
            dut_port=tb.port_mac[0],
            round_start_pulse=self.dp.round_start_pulse,
            round_id=self.dp.current_round_id,
            run_id=self.dp.core_rx_run_id,
            cluster_config=ssr_sim.ClusterConfig(num_nodes=3, mac_addresses=SSR_MACS,
                                                 rtl_node_id=SSR_NODE_ID))
        for node in SSR_PEERS:
            self.harness.peer_payload[node] = ssr_peer_stream(node, 0, peer_frags)
        self.harness.start()
        self._watcher = cocotb.start_soon(self._watch_arrivals())

        # Join. The PHC starts at 0 s, so the driver's default effective round
        # (0x100) is a millisecond away: join a few rounds from now.
        now_round = await self.dev.consensus.read_round_id()
        await self.dev.consensus.activate(run_id=run_id, membership=0b111, effective_round=now_round + 8)
        await self.dev.consensus.wait_running()
        tb.log.info("%s", await self.dev.consensus._diagnose())
        # The first round after activation primes the pipeline; the peers'
        # frames for the round before it were dropped for their run. Let that
        # pass before any counter is judged.
        await self.rounds(settle_rounds)
        tb.log.info("settled: %s", await self.dev.consensus._diagnose())
        assert not await self.dev.consensus.read_halt()
        return self

    async def _watch_arrivals(self):
        dut, dp = self.dut, self.dp
        last_start = cocotb.utils.get_sim_time("ns")
        in_frame = False
        while True:
            await RisingEdge(dut.clk)
            if int(dp.round_start_pulse.value):
                last_start = cocotb.utils.get_sim_time("ns")
            v = int(dp.axis_cons_rx_tvalid.value) and int(dp.axis_cons_rx_tready.value)
            if v and not in_frame:
                self.arrivals.append((int(dp.current_round_id.value),
                                      cocotb.utils.get_sim_time("ns") - last_start))
            if v:
                in_frame = not int(dp.axis_cons_rx_tlast.value)

    async def rounds(self, n: int):
        for _ in range(n):
            await RisingEdge(self.dp.round_start_pulse)

    async def quiet(self):
        """A quiet point in the next round: the peers' frames have all arrived
        (by ~1.8 us), the next boundary is 1.8 us away - long enough for a
        batch of register reads, so a counter snapshot is not taken with a
        frame in flight."""
        await RisingEdge(self.dp.round_start_pulse)
        await Timer(2200, units="ns")

    def round_id(self) -> int:
        return int(self.dp.current_round_id.value)

    async def rx_counters(self):
        return await self.dev.consensus.read_rx_counters()

    async def tx_counters(self):
        return await self.dev.consensus.read_tx_counters()

    @staticmethod
    def delta(after: dict, before: dict) -> dict:
        return {k: after[k] - before[k] for k in after}

    async def next_record(self, *, round_id=None, within=12):
        """The next delivered round, or the one deciding round_id (bounded)."""
        for _ in range(within):
            d = await self.dev.delivery.recv()
            self.log.info("verdict seq %d: round %d run 0x%x commit 0x%02x present 0x%02x frags %s consumer %d",
                          d.record.seq, d.record.round_id, d.record.run_id, d.record.commit_set,
                          d.record.present_set, d.record.frag_counts[:3], d.record.proposal_consumer)
            if round_id is None or d.record.round_id == round_id:
                return d
            assert d.record.round_id < round_id, f"round {round_id} was never delivered (saw {d.record.round_id})"
        raise AssertionError(f"no record for round {round_id} within {within}")

    def check_peer_pages(self, delivered, node: int, stream: bytes, frags: int = SSR_PEER_FRAGS):
        rec = delivered.record
        assert rec.frag_counts[node] == frags, f"node {node}: frag_count {rec.frag_counts[node]}, expected {frags}"
        got = b"".join(delivered.pages[node])
        assert got == stream[:frags * ssr_packet.FRAG_BYTES], f"node {node}'s pages do not match what it sent"

    async def collect_fragments(self, n: int, *, limit: int = 400):
        """The next n fragments the RTL node transmits: (round_id, frag_idx, payload),
        checked for run id, node id, length and per-round numbering."""
        out = []
        last = None
        for _ in range(limit):
            frame = await self.harness.recv()
            assert frame.node_id == SSR_NODE_ID and frame.run_id == self.dev.consensus._last_run_id
            if frame.is_ctrl:
                assert frame.length == 0 and frame.frag_idx == 0
                continue
            assert frame.length == ssr_packet.FRAG_BYTES
            assert all(a == 0 for a in frame.ack), "a fragment carries no ack"
            want = 0 if last is None or last[0] != frame.round_id else last[1] + 1
            assert frame.frag_idx == want, f"round {frame.round_id} fragment {frame.frag_idx}, expected {want}"
            assert frame.frag_idx < 5, "P_FRAGS_PER_ROUND is 5"
            last = (frame.round_id, frame.frag_idx)
            out.append((frame.round_id, frame.frag_idx, frame.payload))
            if len(out) == n:
                return out
        raise AssertionError(f"only {len(out)} of {n} fragments left the port")

    async def drain_records(self) -> int:
        """Read every record already in the ring; the last seq read, or -1."""
        last = -1
        while True:
            try:
                d = await self.dev.delivery.recv(timeout_polls=20)
            except ssr.SSRTimeoutError:
                return last
            last = d.record.seq

    async def finish(self):
        assert await self.dev.delivery.read_fault() == 0, "an internal contract broke (FAULT)"
        assert self.harness.late_rtl_fragments == 0, "an RTL fragment left the port after the peers' acks about its round"
        self.harness.stop()
        if self._watcher:
            self._watcher.cancel()
        await self.dev.close()


@cocotb.test()
async def run_test_ssr_dataplane(dut):
    """Bring-up and steady state. Peer pages land byte for byte and every round
    is decided and delivered; our proposals leave as fragments and the records
    say so; control frames arrive inside the control window through Corundum's
    receive path; nothing is dropped on the way."""
    b = await SSRBench(dut).bringup()
    dev, harness, tb = b.dev, b.harness, b.tb

    # The receive budget through Corundum: peers transmit at 332 ns, their
    # control frames must reach ssr_rx_engine before 646 ns. The peers send
    # both control frames first, so the first two arrivals of a round are them.
    await b.quiet()
    rx0 = await b.rx_counters()
    b.arrivals.clear()
    await b.rounds(3)
    await b.quiet()
    by_round = {}
    for rid, ns in b.arrivals:
        by_round.setdefault(rid, []).append(round(ns))
    tb.log.info("SSR frame headers at ssr_rx_engine, ns into their round: %s", by_round)
    full = [v for v in by_round.values() if len(v) == 2 + 2 * SSR_PEER_FRAGS]
    assert len(full) >= 2, f"expected whole rounds of 2 control + {2*SSR_PEER_FRAGS} payload frames: {by_round}"
    for v in full:
        assert v[0] >= ssr_sim.TX_START_NS and v[1] < SSR_CTRL_WINDOW_NS, \
            f"control frames must land in [332, 646): {v}"
    d = b.delta(await b.rx_counters(), rx0)
    tb.log.info("rx counters over 4 steady rounds: %s", d)
    assert d["rx_ctrl"] == 8 and d["rx_accept"] == 8 + 8 * SSR_PEER_FRAGS and d["rx_frames"] == d["rx_accept"]
    for k in ("rx_malformed", "rx_ctrl_late", "rx_window_drop", "rx_member_drop", "rx_sound_drop",
              "rx_run_drop", "rx_round_drop", "rx_ack_disagree", "rx_host_frames"):
        assert d[k] == 0, f"{k} moved in steady state: {d}"

    # Rounds are decided and delivered: record + pages, byte for byte.
    for _ in range(4):
        delivered = await b.next_record()
        rec = delivered.record
        assert rec.run_id == SSR_RUN_ID and rec.node_count == 3 and rec.self_index == SSR_NODE_ID
        assert rec.commit_set == 0b111 and rec.present_set == 0b111 and delivered.lost_nodes == []
        for node in SSR_PEERS:
            b.check_peer_pages(delivered, node, ssr_peer_stream(node, 0))
        assert rec.frag_counts[SSR_NODE_ID] == 0, "nothing proposed yet"
    # and the records are one per round, in order
    seq0 = rec.seq
    nxt = await b.next_record()
    assert nxt.record.seq == seq0 + 1 and nxt.record.round_id == rec.round_id + 1

    # Our own proposals: three pieces, one doorbell, three fragments on the
    # wire carrying exactly those bytes, beats 1..63 of each entry.
    await b.quiet()
    tx0 = await b.tx_counters()
    pieces = [bytes((0xA0 + i + j) & 0xFF for j in range(ssr_packet.FRAG_BYTES)) for i in range(3)]
    res = await dev.proposal.propose(pieces)
    assert res.count == 3 and res.consumer == dev.proposal.producer
    frags = await b.collect_fragments(3)
    for i, (_, _, payload) in enumerate(frags):
        assert payload == pieces[i], f"fragment {i} carried the wrong bytes"
    # The records of the rounds they went out in count them, and carry the
    # proposal ring's consumer: the host's flow control without an MMIO read.
    ours = 0
    for _ in range(8):
        delivered = await b.next_record()
        ours += delivered.record.frag_counts[SSR_NODE_ID]
        if ours >= 3:
            break
    assert ours == 3, f"the records committed {ours} of our fragments, expected 3"
    assert delivered.record.proposal_consumer == dev.proposal.producer
    await b.quiet()
    dt = b.delta(await b.tx_counters(), tx0)
    tb.log.info("tx counters: %s", dt)
    assert dt["tx_pay_frames"] == 3 and dt["tx_overrun"] == 0 and dt["tx_missed"] == 0
    assert dt["tx_cpl_count"] == dt["tx_ctrl_frames"] + dt["tx_pay_frames"], \
        "every SSR frame's transmit completion must come back to the mux"

    # A peer that proposes nothing is still in, with zero fragments.
    await harness.midround()
    harness.peer_payload[2] = b""
    await harness.midround()
    empty_round = b.round_id()
    harness.peer_payload[2] = ssr_peer_stream(2, 0)
    delivered = await b.next_record(round_id=empty_round)
    rec = delivered.record
    assert rec.frag_counts[2] == 0 and rec.frag_counts[1] == SSR_PEER_FRAGS
    assert rec.commit_set == 0b111 and rec.present_set == 0b111
    assert 2 not in delivered.pages

    # Nothing was dropped on the way.
    counters = await dev.delivery.read_counters()
    tb.log.info("delivery counters: %s", counters)
    assert counters["pay_err"] == 0 and counters["stage_full"] == 0 and counters["pres_late"] == 0
    assert counters["verdict_overflow"] == 0 and counters["verdict_stale"] == 0 and counters["verdict_err"] == 0
    assert counters["verdict_records"] >= dev.delivery._next_seq
    assert not await dev.consensus.read_halt()
    await b.finish()


@cocotb.test()
async def run_test_ssr_backlog(dut):
    """A backlog deeper than a round, across three doorbells and a wrap of the
    16-entry proposal ring: every entry leaves as exactly one fragment, in
    posting order, at most five a round, with its bytes intact; the records
    count all of them and the ring's consumer catches up."""
    b = await SSRBench(dut).bringup()
    dev, tb = b.dev, b.tb

    total = 24
    pieces = [bytes(((0x10 * (i + 1)) + j) & 0xFF for j in range(ssr_packet.FRAG_BYTES)) for i in range(total)]
    await b.quiet()
    tx0 = await b.tx_counters()
    posted = 0
    for batch in (8, 8, 8):
        # wait=True returns once the NIC has read the entries, which for the
        # third batch means once the first has drained through the 8-slot
        # buffer: the ring is 16 deep, so this crosses the wrap.
        res = await dev.proposal.propose(pieces[posted:posted + batch])
        assert res.count == batch
        posted += batch
    assert dev.proposal.producer == total

    frags = await b.collect_fragments(total)
    per_round = {}
    for i, (rid, idx, payload) in enumerate(frags):
        assert payload == pieces[i], f"fragment {i} (round {rid} idx {idx}) carried the wrong bytes"
        per_round[rid] = per_round.get(rid, 0) + 1
    tb.log.info("fragments per round: %s", per_round)
    assert max(per_round.values()) <= 5
    assert sorted(per_round) == list(range(min(per_round), max(per_round) + 1)), \
        "a backlog drains in consecutive rounds"

    ours = 0
    for _ in range(12):
        delivered = await b.next_record()
        ours += delivered.record.frag_counts[SSR_NODE_ID]
        assert delivered.record.commit_set == 0b111 and delivered.record.present_set == 0b111
        if ours >= total:
            break
    assert ours == total, f"the records committed {ours} of our fragments, expected {total}"
    assert delivered.record.proposal_consumer == total
    assert await dev.proposal.read_consumer() == total
    assert await dev.proposal.read_status() & ssr.ProposalStatus.IDLE
    await b.quiet()
    dt = b.delta(await b.tx_counters(), tx0)
    assert dt["tx_pay_frames"] == total and dt["tx_overrun"] == 0 and dt["tx_missed"] == 0
    assert (await dev.delivery.read_counters())["pres_late"] == 0
    await b.finish()


@cocotb.test()
async def run_test_ssr_short_peer(dut):
    """A peer that delivers one fragment fewer than it says it sent (its own
    transmit path lost the last one). In the next round its ack differs from
    ours - ACK_DISAGREE - and it is no witness; the other peer's agrees, two
    of three is a quorum: the round commits with the short peer's PREFIX and
    the sound set shrinks to the two of us. The short peer sends a control
    frame only in the round after (a real one, with no witness, would halt
    there) and then falls silent; when it speaks again its frames land on the
    sound rung and the set does not grow back."""
    b = await SSRBench(dut).bringup()
    dev, harness, tb = b.dev, b.harness, b.tb
    victim, other = 2, 1
    assert await dev.consensus.read_sound_set() == 0b111
    await b.quiet()
    rx0 = await b.rx_counters()

    await harness.midround()
    harness.peer_short[victim] = SSR_PEER_FRAGS - 1        # S: one fragment short
    await harness.midround()
    short_round = b.round_id()
    harness.peer_short[victim] = None
    harness.peer_payload[victim] = b""                      # S+1: its control frame, nothing else
    await harness.midround()
    harness.peer_enabled[victim] = False                    # silent from S+2 on
    harness.excluded.add(victim)                            # and the survivor stops counting it
    tb.log.info("short round %d", short_round)

    delivered = await b.next_record(round_id=short_round)
    rec = delivered.record
    assert rec.commit_set == 0b111 & ~(1 << victim), f"commit_set 0x{rec.commit_set:02x}: the short peer must leave the sound set"
    assert rec.frag_counts[victim] == SSR_PEER_FRAGS - 1, f"frag_count {rec.frag_counts[victim]}: the prefix everybody holds"
    assert rec.present_set == 0b111, "the page it did send reached the host"
    assert rec.departed_nodes() == [victim]
    b.check_peer_pages(delivered, victim, ssr_peer_stream(victim, 0), frags=SSR_PEER_FRAGS - 1)
    b.check_peer_pages(delivered, other, ssr_peer_stream(other, 0))

    nxt = await b.next_record(round_id=short_round + 1)
    assert nxt.record.commit_set == 0b111 & ~(1 << victim) and nxt.record.frag_counts[victim] == 0
    assert nxt.record.frag_counts[other] == SSR_PEER_FRAGS

    await b.quiet()
    assert await dev.consensus.read_sound_set() == 0b111 & ~(1 << victim)
    assert not await dev.consensus.read_halt(), "losing one node of three must not halt the other two"
    d = b.delta(await b.rx_counters(), rx0)
    tb.log.info("rx counters since the short round: %s", d)
    assert d["rx_ack_disagree"] == 1, "exactly one disagreeing control frame"
    assert d["rx_malformed"] == 0 and d["rx_sound_drop"] == 0 and d["rx_ctrl_late"] == 0

    # The departed peer speaks again: believing it would GROW the sound set,
    # so every frame of its round is dropped at the sound rung. The survivor's
    # acks say 0 for it, as a real survivor's would, so nothing else moves.
    rx1 = await b.rx_counters()
    await harness.midround()
    harness.peer_enabled[victim] = True
    harness.peer_payload[victim] = ssr_peer_stream(victim, 1)
    await harness.midround()
    harness.peer_enabled[victim] = False
    await b.quiet()
    d = b.delta(await b.rx_counters(), rx1)
    tb.log.info("rx counters over the departed peer's round: %s", d)
    assert d["rx_sound_drop"] == 1 + SSR_PEER_FRAGS, f"its control frame and fragments must all land on the sound rung: {d}"
    assert d["rx_ack_disagree"] == 0
    assert await dev.consensus.read_sound_set() == 0b111 & ~(1 << victim), "the sound set grew back"
    assert not await dev.consensus.read_halt()
    delivered = await b.next_record()
    assert delivered.record.commit_set == 0b111 & ~(1 << victim) and delivered.record.frag_counts[victim] == 0
    await b.finish()


@cocotb.test()
async def run_test_ssr_halt_recover(dut):
    """Both peers fall silent: at the next evaluation we are our only witness,
    one of three is no quorum, the node halts - and a halted node is silent
    and deaf. Then what a driver does about it: read the halt record, reboot,
    activate a FRESH run id; the node rejoins, the peers follow its run id,
    records resume with their seq where it left off."""
    b = await SSRBench(dut).bringup()
    dev, harness, tb = b.dev, b.harness, b.tb

    await b.next_record()
    assert await dev.consensus.read_halt_count() == 0

    await harness.midround()
    for node in SSR_PEERS:
        harness.peer_enabled[node] = False
    assert await dev.consensus.wait_halt(timeout_polls=400), "the node should halt within a few rounds"
    hrec = await dev.consensus.read_halt_record()
    tb.log.info("halt record: %s", hrec)
    assert hrec.reason == ssr.HALT_NO_AGREED_ROW
    assert hrec.witness == 1 << SSR_NODE_ID, "nobody but ourselves agreed"
    assert hrec.sound_set_before == 0b111 and hrec.membership == 0b111
    assert await dev.consensus.read_halt_count() == 1
    status = await dev.consensus.read_status()
    assert status & ssr.CoreStatus.HALTED
    last_seq = await b.drain_records()          # the rounds decided before the halt
    assert last_seq >= 0

    # Silent: no SSR frame leaves the port for three rounds. Deaf: the peers'
    # frames (they speak again) land on the window rungs, not in the protocol.
    while not harness._received.empty():
        harness._received.get_nowait()
    await b.quiet()
    tx0 = await b.tx_counters()
    rx0 = await b.rx_counters()
    await harness.midround()
    for node in SSR_PEERS:
        harness.peer_enabled[node] = True
    await b.rounds(2)
    await b.quiet()
    assert harness._received.empty(), "a halted node transmitted"
    dt = b.delta(await b.tx_counters(), tx0)
    assert dt["tx_ctrl_frames"] == 0 and dt["tx_pay_frames"] == 0
    dr = b.delta(await b.rx_counters(), rx0)
    tb.log.info("rx counters while halted: %s", dr)
    assert dr["rx_accept"] == 0 and dr["rx_ctrl"] == 0
    assert dr["rx_ctrl_late"] + dr["rx_window_drop"] == dr["rx_frames"] and dr["rx_frames"] > 0

    # Recovery. A fresh run id: the old one has spoken for rounds it cannot
    # take back. The peers read the run id out of the RTL, so they follow.
    now_round = await dev.consensus.read_round_id()
    hrec2 = await dev.consensus.recover(run_id=SSR_RUN_ID + 1, membership=0b111, effective_round=now_round + 8)
    assert hrec2 == hrec
    await dev.consensus.wait_running(run_id=SSR_RUN_ID + 1)
    tb.log.info("recovered: %s", await dev.consensus._diagnose())
    assert not await dev.consensus.read_halt()
    assert await dev.consensus.read_sound_set() == 0b111
    await b.rounds(3)

    for k in range(3):
        delivered = await b.next_record()
        rec = delivered.record
        assert rec.run_id == SSR_RUN_ID + 1, f"record run 0x{rec.run_id:x} after recovery"
        assert rec.commit_set == 0b111 and rec.present_set == 0b111
        for node in SSR_PEERS:
            b.check_peer_pages(delivered, node, ssr_peer_stream(node, 0))
        if k == 0:
            assert rec.seq == last_seq + 1, f"seq {rec.seq} after the halt, {last_seq} before: the sequence must continue"
    assert await dev.consensus.read_halt_count() == 1
    # and the node proposes again under the new run
    pieces = [bytes((0xC0 + j) & 0xFF for j in range(ssr_packet.FRAG_BYTES))]
    await dev.proposal.propose(pieces)
    frags = await b.collect_fragments(1)
    assert frags[0][2] == pieces[0]
    await b.finish()


@cocotb.test()
async def run_test_ssr_nic_coexist(dut):
    """The NIC stays a NIC while the protocol runs. Interface 1 is not SSR's:
    host frames, jumbo included, cross it untouched in both directions and
    their completions come back. Interface 0 is shared: host frames go out
    through ssr_tx_mux between SSR's, host-bound frames come in through
    ssr_rx_demux. Meanwhile every round still commits and nothing lands on a
    rejection rung."""
    b = await SSRBench(dut).bringup()
    dev, harness, tb = b.dev, b.harness, b.tb
    if0, if1 = tb.driver.interfaces[0], tb.driver.interfaces[1]
    await b.quiet()
    rx0 = await b.rx_counters()
    tx0 = await b.tx_counters()
    seq0 = dev.delivery._next_seq

    async def host_tx_other():
        # more than TX_DESC_TABLE_SIZE (32) frames, so the driver depends on
        # its completions coming back; and a jumbo frame among them
        pkts = [bytearray([(x + k) % 256 for x in range(1514)]) for k in range(40)]
        pkts.insert(20, bytearray([x % 256 for x in range(9014)]))
        for p in pkts:
            await if1.ndevs[0].start_xmit(p, 0)
        for k, p in enumerate(pkts):
            frame = await tb.port_mac[1].tx.recv()
            assert bytes(frame.data) == bytes(p), f"interface 1 frame {k} altered on the way out"
            await tb.port_mac[1].rx.send(frame)
        for k, p in enumerate(pkts):
            pkt = await if1.ndevs[0].recv()
            assert pkt.data == p, f"interface 1 frame {k} altered on the way back"
        return len(pkts)

    async def host_tx_shared():
        pkts = [bytearray([(x + 7 * k) % 256 for x in range(1514)]) for k in range(8)]
        for p in pkts:
            await if0.ndevs[0].start_xmit(p, 0)
        for k, p in enumerate(pkts):
            raw = await harness.recv_host()
            assert raw == bytes(p), f"host frame {k} on SSR's interface altered by ssr_tx_mux"
        return len(pkts)

    async def host_rx_shared():
        n = 4
        pkts = []
        for k in range(n):
            payload = bytes([(x + k) % 256 for x in range(256)])
            pkt = Ether(src='5A:51:52:53:54:55', dst='DA:D1:D2:D3:D4:D5') / IP(src='192.168.1.100', dst='192.168.1.101') / UDP(sport=1, dport=2 + k) / payload
            pkts.append(pkt)
            await tb.port_mac[0].rx.send(bytes(pkt))
        for k, pkt in enumerate(pkts):
            got = await if0.ndevs[0].recv()
            assert Ether(got.data).build() == pkt.build(), f"host-bound frame {k} altered by ssr_rx_demux"
        return n

    t_other = cocotb.start_soon(host_tx_other())
    t_shared = cocotb.start_soon(host_tx_shared())
    t_rx = cocotb.start_soon(host_rx_shared())
    # the protocol, meanwhile
    for _ in range(6):
        delivered = await b.next_record()
        assert delivered.record.commit_set == 0b111 and delivered.record.present_set == 0b111
        for node in SSR_PEERS:
            b.check_peer_pages(delivered, node, ssr_peer_stream(node, 0))
    n_other = await t_other
    n_shared = await t_shared
    n_rx = await t_rx
    tb.log.info("host traffic: %d frames on interface 1, %d out and %d in on SSR's", n_other, n_shared, n_rx)

    await b.quiet()
    d = b.delta(await b.rx_counters(), rx0)
    dt = b.delta(await b.tx_counters(), tx0)
    tb.log.info("rx %s\ntx %s", d, dt)
    assert d["rx_host_frames"] == n_rx, "the demux must hand every host-bound frame to the host, and only those"
    assert dt["tx_host_frames"] == n_shared, "the mux must pass every host frame on SSR's interface, and only those"
    assert dt["tx_cpl_count"] == dt["tx_ctrl_frames"] + dt["tx_pay_frames"], "SSR's completions consumed, the host's not"
    for k in ("rx_malformed", "rx_ctrl_late", "rx_window_drop", "rx_sound_drop", "rx_run_drop",
              "rx_round_drop", "rx_ack_disagree", "rx_member_drop"):
        assert d[k] == 0, f"{k} moved under host traffic: {d}"
    assert dev.delivery._next_seq - seq0 == 6
    assert not await dev.consensus.read_halt()
    await b.finish()
