# SSR — working notes for Claude

SSR is a synchronous state-machine-replication protocol on a Corundum NIC. The
position of this work, and the thing every design decision is measured against:
**a split architecture that minimises hardware.** The FPGA is a timing tag plus
the correctness checks (the *dataplane*); everything that decides anything —
run ids, membership, activation, recovery, clock sync — is host software (the
*control plane*). Concurrent independent work (scarHW/POPUC, arXiv 2608.24622)
offloads the whole protocol to the FPGA; we do not, on purpose. An APSys'26 short
paper exists; the target is OSDI'27 (abstract Dec 1 2026, paper Dec 8).

## The repository

```
syncons/
├── sim/               the protocol-level Python simulator (the APSys paper's evidence)
├── tests/             its pytest suite
├── docs/              protocol spec, reconfiguration, simulator architecture
└── prototype/         the hardware prototype — most work happens here
    ├── fpga/          RTL, benches, docs, the AU200 build; corundum/ is the submodule,
    │                  utils -> corundum/utils (mqnic-fw etc.)
    ├── kernel/        mqnic_app_ssr.ko (four files + ssr_drv.h; ssr_uapi.h is the ABI)
    └── host/          gRPC control plane (coordinator + agent), lib/ssr_dev.c, apps/ssr_bench.c
```

Read `prototype/README.md` for the directory map and the bring-up order, then
`prototype/fpga/docs/dataplane_guide.html` for the dataplane, `docs/host_driver.md`
for the host side. The design records (`count_ack.md`, `commit_path.md`,
`round_structure.md`, `speculative_delivery.md`, `rx_datapath.md`) explain the
alternatives that were rejected and why; where they disagree about the round
structure, `count_ack.md` is current. `au200_parameters.md` is what the bitstream
was built with.

## Where things stand (2026-09-26)

- **Dataplane**: complete, verified in Icarus (`make -C prototype/fpga/tb/ssr_dataplane regress`,
  ~3 min) and in cocotb through the full Corundum core (`make -C prototype/fpga/tb/mqnic_core_pcie_us`,
  five SSR tests + `run_test_nic`; slow, ~4 s wall per 4 µs round). Vivado closed
  timing at WNS +0.090 ns; bitstream git hash `951e9e00`, built 2026-09-25 14:01 UTC.
- **On the board** (`inet-p4lab-14`, kernel 6.1.157, card `b1:00.0` = `mqnic1`, PHC index 7;
  a second, older card `ca:00.0` = `mqnic0` is also present — do not confuse them):
  flashed and reloaded; mqnic reports `Application ID 0x53535201` and creates
  `mqnic.app_53535201.1`. **Our probe fails with "required BAR regions not present"**:
  the PCIe IP core has no BAR 2 (dmesg shows `Control BAR size` but no
  `Application BAR size`). Fix in progress: copy
  `fpga/corundum/fpga/mqnic/Alveo/fpga_100g/ip/pcie4_uscale_plus_0.tcl` to `fpga/ip/`,
  add `pf0_bar2_enabled/64bit/prefetchable {true}, scale Megabytes, size 16`, point
  `fpga/Makefile` `IP_TCL_FILES` at the copy, rebuild. Then `lspci -vv` must show
  `Region 2`, and the probe proceeds to the scratch self-test. **Superseded**: `config.tcl`'s
  `configure_bar` already enables BAR 2 from `APP_ENABLE`; the BAR was in the bitstream but
  unassigned after a hot reload — a host reboot fixed it. No IP tcl copy needed.
- **Probe progress on the board**: after a host reboot BAR 2 is assigned, mqnic maps it, the SSR
  register block is found, the scratch test and identity pass. The 24 MiB payload ring cannot
  come from the buddy allocator (max 4 MiB); the testbed kernel has no `CONFIG_DMA_CMA`, the
  IOMMU is off and the boot line is lab-managed (`update-grub` disabled), so `ssr_rings.c` now
  takes the ring with `alloc_contig_range()` (exported on 6.1) and `dma_map_page`. Untested on
  the board as of this note.
- **Kernel module**: builds on 6.1 and 6.8 (`vm_flags_set` and `class_create` have version guards).
- **Host**: `ssr-agent --device /dev/ssr0` uses `DeviceDataplaneBackend`; without it, the mock.
  `ssr-bench --mode copy|zc` measures commit latency on either path. Nothing on the host
  side has run against hardware yet.

## Next steps, in order

1. Rebuild with BAR 2, reflash (`fpga/utils/mqnic-fw -d b1:00.0 -w build/fpga.bit`, then `-b`),
   `insmod mqnic.ko`, `insmod mqnic_app_ssr.ko`, expect `SSR node 0 of 3, round 4000 ns` and `/dev/ssr0`.
2. `ssr-bench --monitor 5`; then one node alone, `--activate 0x77 --membership 1`, which must commit
   its own proposals; then three nodes.
3. PTP before any multi-node run: `ptp4l -i <mqnic1 if> -H -2` on every node, node 0 as GM.
   The core reads the PHC directly; a PTP *step* during a run is a `time_fault` and disarms
   the core (`ssr_core.v:365`), so sync first, then activate, and configure ptp4l to slew only.
4. Add a `ClockSync` component to the agent (not the driver): run/monitor ptp4l via
   `pmc GET TIME_STATUS_NP`, report synced-ness in GetStatus, coordinator gates Start on it.
5. Fix the time base of activation: `DeviceDataplaneBackend::start()` computes
   `effective_round = start_time_ns / round_ns` from a `CLOCK_REALTIME` (UTC) value, but the PHC
   is TAI (+37 s). Change the control plane to pass a **round number**: coordinator reads
   `GET_STATUS.cur_round` from one agent, adds a margin (e.g. 2500 rounds = 10 ms), broadcasts it.

## Known open items (recorded, deliberately deferred)

- The rx ack comparison is not masked by the sound set (`count_ack.md` §10) — exclusion-instant ambiguity.
- The cutoff / host-frame issue is moot while the host does not use that interface (`count_ack.md` §10).
- No interrupt from the app block; the `read()` path polls (`poll_us`, default 5 µs). The zc path does not care.
- A halted core does not wake `read()` waiters; only `GET_STATUS` / `--monitor` shows a halt.
- `membership` is built as a prefix `(1 << replica_num) - 1`; `RunConfig` has no node list yet.
- `node_id`, `node_count`, `round_length_ns` are bitstream parameters. Making `node_id` (+ src MAC) and
  `node_count` registers is cheap and gives one bitstream for the whole cluster; `round_length_ns` is
  a family of derived deadlines and a timing risk — decided to defer both until the board runs.
- The `mqnic_core_pcie_us` sim sets `MAC_CTRL_ENABLE=1` (only deviation from the AU200 build).

## How to work here

- **Git**: stage with `git add`; never `git commit` — the author commits. Don't push build
  directories (`build/`, `sim_build/`) or wave-viewer state files (Surfer's `*.ron`, `*.gtkw`).
- **Before changing RTL**: run the Icarus regress; for anything touching the DMA or the
  register map, also the cocotb tests. `kernel/ssr_regs.h` and `tb/mqnic_core_pcie_us/ssr_dataplane.py`
  mirror `rtl/ssr_csr.v`'s header comment — change all three together.
- **Corundum is a submodule** at `prototype/fpga/corundum` (name in `.gitmodules` is still
  `prototype/corundum`; that is fine). Don't edit files inside it; copy to `fpga/` and point the
  Makefile at the copy, as `config.tcl` does.
- **Style**: this is a research prototype. No defensive bloat, no speculative abstractions,
  no compatibility layers beyond what the testbed kernels need. Explain plainly in comments what
  a piece of code is for and why the alternative was rejected; the design records are the model.
- **Language**: reply to the author in Chinese; code, comments and docs in English.
- **Sim numbers** to sanity-check against: ~1100 ns/s of cocotb sim time; peers' control frames
  reach the rx engine ~400 ns into the round (window 646 ns); fragments 328 ns apart;
  arrival-to-decision mean 3.3 µs.
