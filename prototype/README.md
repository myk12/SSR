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
├── kernel/               mqnic_app_ssr.ko: rings, /dev/ssrN, ioctls (fpga/docs/host_driver.md)
├── control/              the control plane
│   ├── ssr_dev.c/.h      the user-space library over /dev/ssrN (bench uses it too)
│   ├── ssrd.cpp          the per-node daemon: control ioctls + ptp4l/phc2sys, one gRPC service
│   ├── ssrctl.cpp        the shell that drives every ssrd (ssr_control.proto is the wire)
│   └── Makefile          builds ssrd and ssrctl (host-local build directory)
├── bench/                measuring the system: ssr_bench.c, and the scripts, results and
│                         plots that will grow around it
└── testbed/              what SSR asks of the testbed: manifest.yaml (endpoints, the two L2
                          domains, PTP) in logical ids; render-cfg.py writes ssr.cfg's node
                          sections from ncs-fabric's resolved topology
```
Every build (kernel, control, bench) goes to `/var/tmp/$USER/ssr/<hostname>/`: the
tree is shared over NFS and the kernel module is per host kernel.

## The pieces

**`fpga/rtl/`** — `ssr_dataplane.v` is the top; `ssr_csr.v` is the register page
(its header comment is the register map; `kernel/ssr_regs.h` copies it and
`tb/mqnic_core_pcie_us/ssr_dataplane.py` mirrors it). One bitstream serves the
whole cluster: node id, node count, quorum, source MAC, round length and the
instants of a round are registers (the 0x040 block) that ssrd writes from
`ssr.cfg` before the first activation. The FPGA derives nothing; it publishes its
own constants (BUILD, LIMITS) and ssrd does the arithmetic.

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

**`control/`** — flat, one file each: `ssr_dev.c` is the C library both paths
(kernel-mediated and zero-copy) go through; `ssrd.cpp` is the per-node daemon:
a gRPC service over `/dev/ssrN` that keeps no state of its own (every reply is
the driver's status) and owns the ptp4l and phc2sys that keep the NIC's PHC and
the host clock in step; `ssrctl.cpp` fans commands out to every ssrd, refuses to
start until the clocks agree, and picks the cluster's start round from one
node's `CUR_ROUND`; `ssr_control.proto` is the wire. Both read `ssr.cfg`, one
file for the whole cluster: port 0 (`ssr_iface`) is the protocol's and nothing
else's, port 1 (`ctl_iface`) carries PTP, gRPC and everything else.

**`bench/`** — `ssr_bench.c` measures commit latency on either data path. Scripts,
raw results and plots go next to it as they appear; `make -C bench` builds it.

## Bring-up, in order

Each step fails on its own if the previous one is wrong.

1. `make -C fpga` (Vivado), flash with `fpga/utils/mqnic-fw`, reboot or rescan PCIe.
2. `insmod mqnic.ko`: `dmesg` shows `Application ID: 0x53535201` and the
   auxiliary device `mqnic.app_53535201.0`.
3. `insmod mqnic_app_ssr.ko`: the scratch test, then
   `SSR node 0 of 3, round 4000 ns, ...`, then `/dev/ssr0 ready`.
4. PTP: `ptp4l` on the mqnic interface on every node (round ids are ToD /
   round length; the clocks have to agree before anyone activates).
5. `ssr-bench --enable --monitor 5` shows `status 0x06` and the round advancing 250000/s
   (done 2026-09-26). Then `--activate` on one node with `--membership 1`: it cannot
   commit (QUORUM is N/2+1 = 2 of the *physical* cluster, `ssr_core.v`), so it halts with
   reason 1 at its first evaluation - but on the way it proves activation, the proposal
   DMA reads, the control and payload frames leaving, and the halt record. Then three nodes.

`fpga/docs/host_driver.md` §5 has the commands.
