# SSR on the AU200: parameters as built vs. as assumed

Status: audit 2026-09-23; **every A and B item is fixed** (same day). Each
item below keeps the finding as it was written and ends with what was done.
The RTL defaults, `tb_ssr_dataplane`, the unit benches and the cocotb Makefile
now all use the AU200 column of the table below.

## What changed, in one place

| item | fix |
|---|---|
| A1 | `fpga/config.tcl`: `APP_DMA_ENABLE = 1`, `APP_AXIS_IF_ENABLE = 1` |
| A2 | a RAM row holds **two beats**: one beat = one 512-bit segment. Beat k of a slot is segment k % 2 of the slot's row k / 2. No width adapter. |
| A3 | the core's time comes from `ptp_sync_ts_tod` (96-bit ToD); the app block declares the two sync ports 96 and 64 bits wide; `PTP_SIM` is gone; the ToD step flag reaches `ssr_core` |
| A4 | `SSR_IF_INDEX` (a localparam in the app block, default 0) picks SSR's lane; every other lane is wired straight through |
| A5 | (found by the cocotb run once A1-A4 were in) SSR's frames are tagged `0x4000`, not `0x8000`; `ssr_tx_mux` takes a completion as SSR's only on that exact tag |
| B1 | payload tags `0..P_DMA_TAG_COUNT-1`, checked against `DMA_TAG_WIDTH` at elaboration (the verdict, since moved to the control DMA, has tag 0 there) |
| B2 | no zero-width replication in the `ram_sel` constants; since the verdict moved to the control DMA both are 0 and the demux is gone |
| B3 | `TX_CPL_TS_0..2` are the `PTP_TS_WIDTH`-bit completion timestamp zero-extended to 96 bits |
| B4 | the app block passes `P_SYS_CLOCK_FREQ_HZ` from `CLK_PERIOD_NS_NUM/DENOM` |
| B5 | benches and cocotb run the AU200 geometry; `tb_ssr_dataplane` runs two interfaces and checks the other one is untouched (A3 test + a per-cycle monitor); `make elab` also elaborates `mqnic_app_block` on its AU200 defaults |

## Where the real values come from

The bitstream is Corundum's `fpga_100g` design for the AU200, built by
`fpga/Makefile`:

1. `fpga/corundum/fpga/mqnic/Alveo/fpga_100g/rtl/fpga_au200.v` - parameter defaults
   and local constants (PTP clock, `PTP_TS_FMT_TOD`, `TX_TAG_WIDTH`, Ethernet
   widths).
2. `fpga/config.tcl` - sets Vivado generics that override (1). It is
   Corundum's `fpga_AU200/config.tcl` with seven lines changed (APP_ID and
   the six `APP_*` enables, see A1). `AXIS_PCIE_DATA_WIDTH` is read from the
   PCIe IP: 512 (Gen3 x16).
3. `fpga/corundum/fpga/common/rtl/mqnic_core_pcie.v` and `mqnic_core.v` - derive
   what the app block actually receives: RAM segment widths, `ram_sel` width,
   DMA tag width, the interface stream widths.

Derived values that matter to SSR, with `IF_COUNT = 2`, `PORTS_PER_IF = 1`,
the app DMA enabled, `TX_QUEUE_INDEX_WIDTH = 13` and `RX_QUEUE_INDEX_WIDTH = 8`:

| app block parameter | formula (Corundum) | AU200 |
|---|---|---|
| `RAM_SEG_COUNT` | `TLP_SEG_COUNT*2` | 2 |
| `RAM_SEG_DATA_WIDTH` | `TLP_DATA_WIDTH*2/RAM_SEG_COUNT` | **512** (a RAM row is 1024 bits, 128 B) |
| `RAM_ADDR_WIDTH` | `clog2(max(TX_RAM_SIZE, RX_RAM_SIZE))` | 17 |
| `RAM_SEG_ADDR_WIDTH` | `RAM_ADDR_WIDTH - clog2(SEG_COUNT*SEG_BE)` | 10 |
| `RAM_SEL_WIDTH` | `IF_RAM_SEL_WIDTH` | **1** |
| `DMA_TAG_WIDTH` | `16 - clog2(IF_COUNT + app_dma) - 1` | **13** |
| `DMA_ADDR_WIDTH`, `DMA_LEN_WIDTH`, `DMA_IMM_ENABLE` | | 64, 16, 0 |
| `PTP_TS_FMT_TOD`, `PTP_TS_WIDTH` | `fpga_au200.v` | **0, 48** |
| `PTP_CLK_PERIOD_NS` | `fpga_au200.v` | 1024/165 (6.21 ns) |
| `CLK_PERIOD_NS` (core `clk`) | | 4 (250 MHz) |
| `AXIS_IF_DATA_WIDTH` / `KEEP` | | 512 / 64 |
| `AXIS_IF_TX_ID_WIDTH` | `TX_QUEUE_INDEX_WIDTH` | 13 |
| `AXIS_IF_TX_DEST_WIDTH` | `clog2(PORTS_PER_IF)+4` | 4 |
| `AXIS_IF_TX_USER_WIDTH` | `TX_TAG_WIDTH+1` | 17 |
| `AXIS_IF_RX_ID_WIDTH` | | 1 |
| `AXIS_IF_RX_DEST_WIDTH` | `RX_QUEUE_INDEX_WIDTH+1` | 9 |
| `AXIS_IF_RX_USER_WIDTH` | `PTP_TS_WIDTH+1` | 49 |
| `AXIL_APP_CTRL_DATA/ADDR_WIDTH` | | 32 / 24 (BAR2, 16 MiB) |

## The three configurations side by side (as audited, before the fixes)

"tb" is `tb/ssr_dataplane/tb_ssr_dataplane.v` (what every SSR check so far was
run against); "cocotb" is `tb/mqnic_core_pcie_us/Makefile` (Corundum's generic
`mqnic_core_pcie_us` test, not the AU200's).

| parameter | AU200 build | tb | cocotb | SSR RTL assumes |
|---|---|---|---|---|
| `APP_DMA_ENABLE` | **0** in `fpga/config.tcl` | (1) | 1 | 1 |
| `APP_AXIS_IF_ENABLE` | **0** in `fpga/config.tcl` | (1) | **0** | 1 |
| `APP_CTRL_ENABLE` | 1 | (1) | **0** | 1 |
| `APP_AXIS_DIRECT/SYNC_ENABLE` | 0 | - | 0 | unused (passthrough) |
| `IF_COUNT` | **2** | 1 | 1 | 1 |
| `RAM_SEG_DATA_WIDTH` (row) | **512 (1024-bit row)** | 256 (512-bit row) | 512 | row = one 512-bit beat |
| `RAM_SEL_WIDTH` | **1** | 4 | 1 | always 0: one reader per RAM port |
| `RAM_ADDR_WIDTH` | 17 | 16 | 17 | >= 16 |
| `DMA_TAG_WIDTH` | **13** | 16 | 14 | pages 0..15 (data DMA), verdict 0 (control DMA) |
| `DMA_IMM_ENABLE` | 0 | - | 1 | 0 (unused) |
| `PTP_TS_FMT_TOD` / `PTP_TS_WIDTH` | **0 / 48** | 1 / 96 | 0 / 48 | 96-bit ToD |
| `PTP_SIM` (ours) | **1** (default, the app block does not set it) | 0 | 1 | 0 on hardware |
| `AXIS_IF_TX_ID_WIDTH` | 13 | 12 | 13 | parameterised |
| `AXIS_IF_RX_DEST_WIDTH` | 9 | 8 | 9 | parameterised |
| `AXIS_IF_RX_USER_WIDTH` | 49 | 97 | 49 | parameterised, uses bit 0 |
| `PTP_CLK_PERIOD_NS` | 1024/165 | - | 32/5 | not used by SSR |
| `DDR_ENABLE` / `HBM_ENABLE` | 0 / 0 | - | 1 / 1 | not used by SSR |
| `TX_FIFO_DEPTH` | 131072 | - | 32768 | not used by SSR |
| `AXIS_ETH_*_PIPELINE` | 4 | - | 0-2 | not used by SSR |

## A. Blocking: the design does not work on the board as it stands

**A1. The build turns SSR's two paths off.** *Fixed in `fpga/config.tcl`.* `fpga/config.tcl` sets
`APP_DMA_ENABLE = 0` and `APP_AXIS_IF_ENABLE = 0` (Corundum's own AU200
config has them at 1). With DMA off, `mqnic_core` never connects the app
block's data DMA descriptors or RAM ports: no proposal read, no page, no
record. With the IF path off, `mqnic_interface` routes traffic around the app
block: SSR never sees a frame and never sends one. The cocotb Makefile has
`APP_AXIS_IF_ENABLE = 0` as well, so that test could not have passed either.

**A2. A DMA RAM row is 1024 bits, not 512.** `RAM_SEG_DATA_WIDTH` follows
the PCIe TLP width, 512 on Gen3 x16, so a row is 2 x 512 = 128 bytes: two
Ethernet beats. Every SSR RAM-side module assumes a row is exactly one 64-byte
frame beat: `ssr_proposal_buffer` (streams rows 1..63), `ssr_tx_engine`,
`ssr_rx_engine` / `ssr_payload_stage` (a beat lands in a row, the header in
row 0), `ssr_verdict_dma_writer` (the 64-byte record is one row). All four
have an elaboration check that refuses it; the cocotb build stops there at
time 0. A 4 KiB slot is 32 rows, not 64, and the frame header is half of row
0. This is the largest item: the RAM-facing side of four modules changes.

*Fixed, with two beats per row.* A beat is one segment: beat k of a slot is
segment `k % RAM_SEG_COUNT` of row `slot_base_row + k / RAM_SEG_COUNT`. Each
segment of Corundum's RAM has its own command and response ports, so a writer
drives the one segment its beat goes to, and a reader asks the segment holding
the next beat and takes the responses in beat order (each segment answers in
order). No width conversion anywhere, and the host-visible layout is
unchanged: a slot is still 4 KiB, 64 beats, header in beat 0.

- `ssr_payload_stage`: the write goes to segment `beat % 2`; the header beat
  (beat 0) is segment 0 of the slot's first row.
- `ssr_proposal_buffer`: commands go to segment `cmd_beat % 2`, the stream is
  taken from segment `out_beat % 2`; a flush drains both segments. (The
  in-flight counter's popcount became a function behind an `assign`: as an
  `always @*` it could start X and hold an abort open forever - the ring bench
  caught it.)
- `ssr_tx_engine` / `ssr_rx_engine`: the buffer beat is one segment wide; the
  checks now say "a beat is one segment".
- `ssr_verdict_dma_writer`: the 64-byte record is one segment; every segment
  answers with it.

**A3. The ToD never reaches `ssr_core`.** The round number is computed from
PTP seconds and nanoseconds. On the board:

- `mqnic_ptp` produces `ptp_sync_ts_tod` as 96 bits, `{sec[47:0], ns[31:0], fns[15:0]}`,
  and `ptp_sync_ts_rel` as 64 bits, `{ns[47:0], fns[15:0]}`.
- The app block declares both ports `[PTP_TS_WIDTH-1:0]`, and with
  `PTP_TS_FMT_TOD = 0` that is 48 bits: the seconds are cut off at the port.
- `ssr_dataplane` reads its time from `ptp_sync_ts_rel`, not `ptp_sync_ts_tod`,
  in both branches, and `PTP_SIM` defaults to 1 because the app block never
  sets it. With `PTP_SIM = 1` it takes "seconds" from `rel[47:32]` and "ns"
  from `rel[31:16]`, which on real hardware are two halves of the nanosecond
  count. `PTP_SIM = 0` would index `rel[95:48]`, past the end of a 48-bit port.
- The bench hides this: it instantiates the wrapper with `PTP_TS_FMT_TOD = 1`,
  `PTP_SIM = 0` and feeds a 96-bit ToD into the *rel* port.

Every node would compute a different, wrong round id; nothing would ever be
accepted by `ssr_rx_engine`'s round check.

*Fixed.* `ssr_dataplane` reads seconds from `ptp_sync_ts_tod[95:48]` and
nanoseconds from `[47:16]`, whatever `PTP_TS_FMT_TOD` is (that parameter only
describes the interface timestamps). The app block declares
`ptp_sync_ts_tod` as 96 bits and `ptp_sync_ts_rel` as 64, which is what
`mqnic_ptp` drives (`mqnic_core`'s own wire is `[96:0]`; the unused top bit
is dropped with a width warning). `PTP_SIM` is removed. `ptp_sync_ts_tod_step`
now drives `ssr_core`'s `i_ptp_step`, so a stepped clock halts the node as
the core was designed to. The bench feeds a 96-bit ToD to the ToD port and a
separate 64-bit relative time to the rel port.

**A4. `IF_COUNT = 2` is not handled.** The AU200 has two QSFP28 cages, one
interface each. The app block's IF streams are `IF_COUNT` lanes wide, and
`ssr_dataplane` connects the whole bus to single-lane ports of `ssr_tx_mux`
and `ssr_rx_demux`. Verilog truncates: interface 0 is wired by accident,
interface 1's outputs are undriven and its `tready` is lost, so the second
port's normal host traffic stops. What is needed: a parameter naming the SSR
interface, that lane through the mux/demux, every other lane passed straight
through.

*Fixed.* `ssr_dataplane` takes `SSR_IF_INDEX` and cuts that lane's tx,
completion and rx streams out into `lane_*` wires for `ssr_tx_mux` /
`ssr_rx_demux`; a generate loop wires every other lane input-to-output.
`mqnic_core` cannot pass a new parameter to the app block, so the choice is
a localparam in `mqnic_app_block_ssr_dataplane.v` (0 = the first QSFP28 cage).
`tb_ssr_dataplane` runs `IF_COUNT = 2`: the node-0 build puts SSR on lane 0,
the node-1 build on lane 1, and test A3 plus a per-cycle monitor check that the
other lane leaves exactly as it came in, including an SSR-tagged completion
and a 0x88B5 frame on it.

**A5. SSR's transmit tag was Corundum's.** *Found after the audit, by the
cocotb test on the AU200 parameters; fixed.* `ssr_tx_mux` marked SSR frames
with tag bit 15 and swallowed every completion with that bit set, on the
assumption that the interface only allocates low tag bits. It does not:
Corundum's `tx_engine` tags every host frame `{1, descriptor index}` - bit 15
set - and acts only on completions with bit 15 set. So every host completion
on SSR's interface was swallowed, the transmit descriptor table never
drained, and host transmit on that port stopped after a handful of frames
(the NIC test stalled at 8 of 64 packets). `tb_ssr_dataplane` had not seen it
because its host frames were tagged `0x0100 + f`, which is not what Corundum
sends. Now SSR's frames carry `0x4000` (bit 15 clear, so Corundum would ignore
the completion even if it leaked; bit 14 set, which a 5-bit descriptor index
never reaches), the mux matches that exact tag, and the bench tags its host
frames `0x8000 | f` like Corundum.

## B. Wrong but currently harmless, or fragile

**B1. DMA tag constants do not fit 13 bits.** `DMA_TAG_PAY_BASE = 16'h4000`
and `DMA_TAG_VERDICT = 16'h4100` are declared `[DMA_TAG_WIDTH-1:0]` and
silently truncate to `0x0000` and `0x0100`. They still do not collide
(payload tags 0x000-0x00F, verdict 0x100; proposal tags are on the separate
read-status stream), so it works by accident. The comment "the top bit is
left clear: Corundum's own queues use it" is also wrong: the app's DMA tag
space is its own, and `dma_if_mux` adds the port bits above it. The
constants should be derived from `DMA_TAG_WIDTH` and checked.

*Fixed.* Payload tags `0..15`, verdict tag `16`, an elaboration check that
`P_DMA_TAG_COUNT + 1` fits `DMA_TAG_WIDTH`, and the comment corrected.
*Later:* the verdict moved to the control DMA, which has its own status
stream, so its tag is 0 there and the check is `P_DMA_TAG_COUNT` alone
(`commit_path.md` §5.2).

**B2. `RAM_SEL_WIDTH = 1`.** The read demux needs one bit, so it fits, and
`dma_ram_demux_rd` accepts `S_RAM_SEL_WIDTH = 0`. But `RAM_SEL_PAYLOAD` /
`RAM_SEL_VERDICT` are written as `{1'b1, {(RAM_SEL_WIDTH-1){1'b0}}}`, a
zero-width replication at width 1. Icarus accepts it; Verilog-2001 does not
allow it, so Vivado may refuse it. The tb never builds with width 1.

*Fixed.* `RAM_SEL_PAYLOAD = 0`, `RAM_SEL_VERDICT = 1 << (RAM_SEL_WIDTH-1)`;
the demux's `ram_rd_cmd_sel` output (zero bits wide here) is left
unconnected. Every bench now builds with a 1-bit `ram_sel`.
*Later:* with the verdict on the control DMA each RAM read port has one
reader, `dma_ram_demux_rd` is gone and both constants are 0.

**B3. TX completion timestamp.** `s_axis_if_tx_cpl_ts` is 48 bits on the
board, the relative format `{ns[31:0], fns[15:0]}`. `TX_CPL_TS_0..2` assume a
96-bit ToD: `TX_CPL_TS_2` will read 0 and the other two hold a different
format from what the docs and B3 describe.

*Fixed.* The registers are documented as the `PTP_TS_WIDTH`-bit timestamp
zero-extended to 96 bits, and test B3 checks exactly that at 48 bits.

**B4. `P_SYS_CLOCK_FREQ_HZ = 250 MHz` is a separate constant.** It is right
for the AU200, but it is not derived from `CLK_PERIOD_NS_NUM/DENOM`, which
the app block receives and does not pass on.

*Fixed.* The app block passes
`P_SYS_CLOCK_FREQ_HZ = (1000 * CLK_PERIOD_NS_DENOM / CLK_PERIOD_NS_NUM) * 1 MHz`.

**B5. The benches do not run the board's geometry.** The tb uses 256-bit
segments, 4-bit `ram_sel`, 16-bit tags, 96-bit PTP and one interface. The
cocotb test uses one interface, the IF path off, BAR2 off, DDR and HBM on,
`DMA_IMM_ENABLE = 1` and a 6.4 ns PTP clock. Neither is the AU200. The
simplest fix is one source of truth: the tb and the cocotb Makefile take
their values from the table above (the cocotb Makefile could copy
Corundum's `fpga_100g/tb/fpga_core/Makefile`, which is the AU200's).

*Fixed.* Every bench uses the AU200 column; the RTL defaults are the AU200
values too, so a module instantiated on its defaults is the board's. The
cocotb Makefile now has `IF_COUNT = 2`, the IF path and BAR2 on, DDR and HBM
off, `DMA_IMM_ENABLE = 0`, `TX_FIFO_DEPTH = 131072`,
Ethernet pipelines 4 and the 1024/165 ns PTP clock (the Python TB now runs
`ptp_clk` at the core's own period). `MAC_CTRL_ENABLE` stays 1 there: the
AU200 has it 0 because its CMAC handles pause frames, and the sim has no
CMAC. That is the one deliberate difference; `HBM_CH` is `fpga_core.v`'s
default of 32 (the AU200 has no HBM, `fpga_au200.v` only passes
`HBM_ENABLE = 0`). On these parameters `run_test_ssr_dataplane` passes end to
end (it is what found A5), and since 2026-09-25 so do the other four SSR
tests (`commit_path.md` §12, the cocotb item).

## C. Already consistent

Core clock 250 MHz; `AXIS_IF_DATA_WIDTH` 512 and one port per interface (the
SSR stream is the interface stream, no width conversion); `TX_TAG_WIDTH` 16,
so `ssr_tx_mux`'s bit-15 SSR tag fits; `AXIS_IF_TX_DEST_WIDTH` 4;
`DMA_ADDR_WIDTH` 64 and `DMA_LEN_WIDTH` 16; `DMA_IMM_ENABLE` 0 (SSR does not
use immediates); BAR2 (`APP_CTRL_ENABLE = 1`) with a 24-bit window, which is
the register space SSR decodes; `MAX_TX_SIZE` / `MAX_RX_SIZE` 9214, above the
4096-byte SSR frame; `RAM_ADDR_WIDTH` 17 holds both SSR RAMs (32 + 64 KiB).
All the IF-side ID/DEST/USER widths are parameters in SSR and follow
whatever the core passes.

## D. Outside the RTL, for bring-up

- The switch and every link must carry 4 100-byte frames (the 4 096-byte SSR
  frame plus FCS): jumbo frames on.
- `ETH_RS_FEC_ENABLE = 1`: the switch ports must run RS-FEC too.
- With two interfaces the driver creates two netdevs; SSR's interface must be
  the one cabled to the SSR switch.
- `fpga/Makefile` now lists every SSR source (it listed two of fourteen
  before the rename).
