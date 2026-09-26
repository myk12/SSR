# The SSR Prototype

SSR runs on a Corundum NIC. The FPGA is a timing tag plus the correctness checks
(the *dataplane*); everything that decides anything runs on the host (the
*control plane*). This directory is the whole prototype:

```text
prototype/
├── fpga/                 the dataplane and everything needed to build and test it
│   ├── rtl/              the SSR application block (ssr_dataplane.v and its modules)
│   ├── tb/ssr_dataplane/     Icarus benches, one per module + the whole dataplane
│   ├── tb/mqnic_core_pcie_us/  cocotb end-to-end tests inside the full Corundum core
│   ├── syn/vivado/       constraints
│   ├── docs/             the design records and the guide (start with dataplane_guide.html)
│   ├── Makefile, config.tcl  the AU200 bitstream build
│   ├── corundum/         the Corundum submodule (RTL, the mqnic driver, the utils)
│   └── utils -> corundum/utils   mqnic-fw and friends, for flashing and inspection
├── kernel/               mqnic_app_ssr.ko: rings, /dev/ssrN, ioctls (docs/host_driver.md)
└── host/                 the control plane (gRPC coordinator + agent), the user-space
                          library over /dev/ssrN, and ssr-bench
```

## The pieces

**`fpga/rtl/`** — `ssr_dataplane.v` is the top; `ssr_csr.v` is the register page
(its header comment is the register map; `kernel/ssr_regs.h` copies it and
`tb/mqnic_core_pcie_us/ssr_dataplane.py` mirrors it). Node id, cluster size and
round length are bitstream parameters: software reads them, it does not set them.

**`fpga/tb/`** — `make -C fpga/tb/ssr_dataplane regress` runs every Icarus bench
(~3 min). `make -C fpga/tb/mqnic_core_pcie_us` runs the cocotb tests through the
Corundum core, PCIe and DMA included (slow: a 4 µs round is ~4 s wall).

**`fpga/docs/`** — `dataplane_guide.html` is the tour; the `.md` files are the
design records it summarises (`count_ack.md` is the current word on the round
structure where the older ones disagree). `au200_parameters.md` is what the
bitstream was built with. `host_driver.md` is the host side.

**`kernel/`** — one module, four files: `ssr_main.c` (probe, identity),
`ssr_rings.c` (the three DMA rings), `ssr_datapath.c` (`write()`/`read()`/`mmap()`
and the poller), `ssr_control.c` (ioctls, sysfs). `ssr_uapi.h` is the ABI.
`make -C kernel modules` builds the patched `mqnic.ko` from the submodule first.

**`host/`** — `ssr-coordinator` and `ssr-agent` (gRPC, `proto/ssr_control.proto`);
`--device /dev/ssr0` puts the agent on real hardware, otherwise it drives a mock.
`lib/ssr_dev.c` is the C library both paths (kernel-mediated and zero-copy) go
through; `apps/ssr_bench.c` measures commit latency on either.

## Bring-up, in order

Each step fails on its own if the previous one is wrong.

1. `make -C fpga` (Vivado), flash with `fpga/utils/mqnic-fw`, reboot or rescan PCIe.
2. `insmod mqnic.ko`: `dmesg` shows `Application ID: 0x53535201` and the
   auxiliary device `mqnic.app_53535201.0`.
3. `insmod mqnic_app_ssr.ko`: the scratch test, then
   `SSR node 0 of 3, round 4000 ns, ...`, then `/dev/ssr0 ready`.
4. PTP: `ptp4l` on the mqnic interface on every node (round ids are ToD /
   round length; the clocks have to agree before anyone activates).
5. `ssr-bench --monitor 5` shows `TIME_VALID`; then `--activate` on one node with
   `--membership 1` commits its own proposals; then three nodes.

`fpga/docs/host_driver.md` §5 has the commands.
