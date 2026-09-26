# Commit Path — As Wired

Everything from a frame arriving on the wire to the host being told it may read
the bytes. `docs/rx_datapath.md` covers frame parsing; `docs/round_structure.md`
is the design record for the round timing; `docs/speculative_delivery.md` is the
design record for delivery; `docs/count_ack.md` is the design record for what
the control frame carries (a vector of fragment counts about the previous
round) and for the transmit cutoff. The first two were written before the RTL
and say so at the top; **this file is the git-tracked wiring record of what is
built**, and where it and the design records disagree, this file is right.

A visual walkthrough of the same material — block diagrams, the frame byte map,
the fence timing, the host memory geometry — is published as the **SSR Commit
Path** artifact.

---


## 0. Names

Every SSR RTL file and module is `ssr_<name>`, one module per file, file name =
module name. The prefix is not decoration: Corundum has its own `tx_engine`
and `rx_engine`, and the mqnic build (Vivado and the cocotb test) compiles
both sets in one file list. Instances inside `ssr_dataplane` drop the prefix
(`ssr_tx_engine` is `tx_engine_inst`), so waveform paths are short. Benches are
`tb_ssr_<unit>` and `make <bench>` runs one.

| before | now |
|---|---|
| `core.v` / `consensus_core` (`consensus_core_inst`) | `ssr_core` (`core_inst`) |
| `tx_engine`, `rx_engine` | `ssr_tx_engine`, `ssr_rx_engine` |
| `proposal_dma_reader`, `proposal_buffer` | `ssr_proposal_dma_reader`, `ssr_proposal_buffer` |
| `payload_stage`, `payload_dma_writer`, `dma_tag_pool` | `ssr_payload_stage`, `ssr_payload_dma_writer`, `ssr_dma_tag_pool` |
| `presence_tracker`, `verdict_dma_writer` | `ssr_presence_tracker`, `ssr_verdict_dma_writer` |
| `ssr_commit.vh` (`SSRC_*`), `ssr_commit.py` | `ssr_verdict.vh` (`SSRV_*`), `ssr_verdict.py` |
| `syn/vivado/consensus_core.tcl` | `syn/vivado/ssr_core.tcl` |
| `RBB_PROPOSAL_QUEUE`, `ProposalQueue` | `RBB_PROPOSAL`, `ProposalRing` |
| `proposal_buffer`'s `buf_*` stream ports | `o_buf_*`, `i_buf_rd_ready` |
| `tb_rx_ladder`, `tb_tx_engine_rounds`, `tb_proposal_ring`, ... | `tb_ssr_rx_engine`, `tb_ssr_tx_engine`, `tb_ssr_proposal_ring`, ... |

`ssr_tx_mux`, `ssr_rx_demux`, `ssr_dataplane` and `ssr_packet.vh` already had
the prefix. `mqnic_app_block_ssr_dataplane.v` keeps Corundum's naming rule
(the module must be `mqnic_app_block`). The older design records (`round_structure.md`,
`speculative_delivery.md`, `rx_datapath.md`, `ring_buffer.md`) use the names
of their time.

## 1. The stations

```text
  port RX ──► ssr_rx_demux ──┬─(0x88B5)──► ssr_rx_engine ──┬──(pl_* beats)──► ssr_payload_stage
                             └─(all else)──► host DMA  │                        │
                                                       │                 (one descriptor
                                                       │                    per frame)
                                                       │                        ▼
                                                       │              ssr_payload_dma_writer ◄─► ssr_dma_tag_pool
                                                       │                        │              (fence)
                                                       │   m_axis_data_dma_write_desc_*         │
                                                       │                        ▼              │
                                                       │                mqnic DMA engine       │
                                                       │                 │            │        │
                                          (frag_idx,   │      (data DMA: stage · ctrl: record) │
                                           staged)     ▼                 │            ▼        │
  ssr_tx_engine (o_local_sent) ─────────────────► ssr_presence_tracker           │       host DRAM     │
                                                  ▲      ▲               │      payload ring   │
                                         (round   │      │ (query B)     │                     │
                                          open)   │      │               │                     │
                                           ssr_core ── commit ──► ssr_verdict_dma_writer ◄───┘
                                                                              │
                                                                              ▼
                                                                          host DRAM
                                                                         verdict ring
```

The protocol itself is a small loop beside that picture. The tracker's counts
for the round just ended are our **ack vector** (§3.1); it goes out in our next
control frame, and a peer's control frame is only believed if its vector is
identical:

```text
  ssr_presence_tracker ── o_prev_ack ──┬──► ssr_tx_engine   the ack field of our control frame
   (our counts for R)                  └──► ssr_rx_engine   a peer's ack must equal it (the last rung)
  ssr_rx_engine ── trusted(k) ──► ssr_core ── witnesses ≥ quorum ──► commit (R, new sound set)
```

Two things about the first picture surprise people.

**The bytes travel backwards.** The descriptor travels *outward* to the DMA
engine; the bytes travel *back inward*. There is no path from an AXI-Stream beat
into a PCIe TLP — Corundum's DMA write engine is handed `ram_sel` + `ram_addr`
and reads the bytes out of on-chip RAM itself, *after* accepting the descriptor.
Nothing pushes payload toward PCIe; the engine pulls it.

**The payload does not wait for the verdict.** A frame is DMA'd to the host the
moment it lands, a round and a control period before anyone knows whether the
round commits: round R is decided at round R+1's control deadline
(`o_ctrl_end_pulse`, `CTRL_PERIOD_NS` plus a few settle cycles), the instant
every ack vector about R is in and none can still arrive.
The verdict is a separate 64-byte write that arrives afterwards and tells the
host which of those pages it is allowed to look at. The dataplane never buffers
a round's payload waiting for a decision, so on-chip storage stops scaling with
`N × P × depth`.

| station | file | bench |
|---|---|---|
| `ssr_rx_demux` | `rtl/ssr_rx_demux.v` | `make tb_ssr_rx_demux` |
| `ssr_rx_engine` | `rtl/ssr_rx_engine.v` | `make tb_ssr_rx_engine` |
| `ssr_payload_stage` | `rtl/ssr_payload_stage.v` | `make tb_ssr_payload_stage` |
| `ssr_payload_dma_writer` | `rtl/ssr_payload_dma_writer.v` | `make tb_ssr_payload_dma_writer` |
| `ssr_dma_tag_pool` | `rtl/ssr_dma_tag_pool.v` | `make tb_ssr_dma_tag_pool` |
| `ssr_presence_tracker` | `rtl/ssr_presence_tracker.v` | `make tb_ssr_presence_tracker` |
| `ssr_core` | `rtl/ssr_core.v` | `make tb_ssr_core_timing tb_ssr_core_protocol` |
| `ssr_verdict_dma_writer` | `rtl/ssr_verdict_dma_writer.v` | `make tb_ssr_verdict_dma_writer` |
| `ssr_tx_engine` | `rtl/ssr_tx_engine.v` | `make tb_ssr_tx_engine` |
| the wrapper | `rtl/ssr_dataplane.v` | `make elab`, `make tb_ssr_dataplane` |

`make regress` runs all of them in about three minutes, most of it `tb_ssr_dataplane`. `make elab` builds the
whole wrapper with no stimulus and runs every parameter check; it is first
because it is cheap and the wrapper has broken silently before (§11).
`tb_ssr_dataplane` is last: the wrapper unmodified, surrounded by a CSR bus, a
DMA engine model on each side with a host memory model behind the write side,
a port model, and two peers on the receive port sending a control frame and
their fragments every round. A peer's control frame carries the ack vector a
real peer would compute, from what the peers sent and what the port monitor
saw this node send, so a peer is trusted exactly when a real one would be.
9 242 checks in nine groups - bring-up, transmit (including a proposal posted
mid-round and the cutoff), receive, the demux, the rejection ladder and its ack
rung, delivery under pressure (delivery off, the fence under held completions,
a failed page), proposal DMA faults, and protocol failure (a short peer, the
halt, the reboot, and a host that stops taking delivery). Its one-sided
negative controls are listed in its header.

The commit path uses both of the app block's DMA interfaces. Pages ride the
**data** DMA (`m_axis_data_dma_write_desc_*`, `data_dma_ram_rd_*`); the verdict
record rides the **control** DMA (`m_axis_ctrl_dma_write_desc_*`,
`ctrl_dma_ram_rd_*`), because Corundum gives control priority over data (§5.2).
The control DMA's read side and RAM write port are unused and tied off in
`mqnic_app_block_ssr_dataplane.v`.

---

## 2. Station 1 — `ssr_rx_demux`

The counterpart of `ssr_tx_mux`, and named for it. `ssr_tx_mux` merges this
node's frames *into* the interface transmit stream; `ssr_rx_demux` splits this
node's frames *out of* the interface receive stream. They are the only two
places SSR touches the interface's own datapath.

```text
    ssr_tx_mux    {SSR, host} ──► port
    ssr_rx_demux   port ──► {SSR, host}
```

One ethertype is taken (`0x88B5` → `ssr_rx_engine`); **everything else passes
through to the host untouched** — ARP, ICMP, TCP, a neighbour's LLDP, anything.

This replaced `consensus_rx_splitter` (since deleted), which recognised a
second ethertype `0x88B6` for a second application and *dropped* everything it
did not recognise, with `tready` held high so the beats vanished with no back
pressure and no counter anywhere. A plain ping to this interface was silently
discarded at the app boundary.

**The route is a property of the frame, not of the beat.** Byte 12 of a header
is an ethertype; byte 12 of a payload row is payload. The route is decided on the
first beat and held to `tlast`. A payload frame is 64 beats, so 63 of them
depend on that latch.

One counter, `RX_HOST_FRAMES` (`0x4AC`), counted at `tlast` so a frame counts
once and only when taken. The frames it takes for SSR are `RX_FRAMES`
(`0x480`), counted by `ssr_rx_engine`.

---

## 3. Station 2 — `ssr_rx_engine`, and what a frame says

**A frame is a page.** `rtl/ssr_packet.vh`, all multi-byte fields big-endian:

```text
 0   dst_mac        6 B
 6   src_mac        6 B
12   ethertype      2 B   0x88B5
14   node_id        1 B   ─┐
15   reserved       1 B    │  0 (was the 1-bit row)
16   run_id         4 B    │
20   round_id       8 B    │
28   length         2 B    │  THIS frame's payload bytes: 0 on CTRL, 1..4032 on a fragment
30   kind           1 B    │  1 = CTRL, 2 = PAYLOAD
31   flags          1 B    │  reserved, no bits defined
32   frag_idx       2 B    │  which fragment of the round this is (0 on CTRL)
34   reserved       2 B    │  0 (was frag_count, the announcement)
36   ack[0..7]      8 B   ─┘  CTRL only, 0 on a fragment: one byte per node, about the PREVIOUS round
44   reserved      20 B
64   payload        up to SSR_FRAG_BYTES = 4032
```

`ack[k]` sits at byte `36 + k`, so on the 512-bit bus the whole vector is
`tdata[36*8 +: 64]` with node k at `[8k +: 8]` and no byte swapping. Nothing
on the wire says how many fragments a round has; a payload frame carries only
its `frag_idx`.

`SSR_FRAME_BYTES = 4096`: 64 bytes of header and 4032 of payload, exactly one
OS page. `SSR_MAX_FRAGS = 64`, so 252 KiB per node per round.

**Index, not offset.** A node's payload for one round is a run of proposal
entries, one per fragment, and a frame says *which* one by index. 4032 is not
a power of two, so a byte offset would need a divide to turn into a page
number; an index is a compare and a shift. Fragments are numbered 0, 1, 2 ...
in the order they leave. **A proposal never spans two entries**: an entry
holds one or more whole proposals, so a proposal is at most 4032 bytes. The
cluster can commit a *prefix* of a node's fragments (§3.1), and this rule is
what keeps a committed prefix from ending in half a proposal. The fabric does
not know where a proposal begins, so it cannot check this; it is the
application's rule (`ssr_packet.vh`).

`(round_id, node_id, frag_idx)` is enough to compute the host page at the
frame's **first beat**. Nothing has to be buffered to know where it goes.

`kind` splits the two frame types at the ladder:

* A `SSR_KIND_CTRL` frame is the round's protocol message — one per node, sent
  first, `length = 0`, no payload beats. It carries the sender's **ack
  vector** about the previous round (§3.1). It must arrive inside
  `i_rx_ctrl_window`, which is `[0, CTRL_PERIOD_NS)` of the round. After the
  other rungs (geometry, window, member, sound set, run, round) it meets one
  more, the last, `ACK_DISAGREE`: `ack == i_rx_self_ack`, our own vector about
  the same round, read combinationally from `ssr_presence_tracker`. A frame
  that fails it is counted in `RX_ACK_DISAGREE` (0x4B0) - a protocol event, not
  a fault, and not in `FAULT`. A frame that passes gives `ssr_core` one pulse,
  `o_rx_valid` with `o_rx_node_id`: **node k is trusted for this round**.
  Nothing else about the frame reaches the core.
* A `SSR_KIND_PAYLOAD` frame is bulk data: `frag_idx < P_FRAGS_PER_ROUND`,
  `0 < length <= 4032`. It is admitted on `i_rx_pay_enable` — "the protocol is
  running" — plus the `round_id` in its header. There is no receive-side time
  bound: the sender's transmit cutoff and rate cap (§10) are what guarantee it
  arrives inside the round. It fans out as beats to `ssr_payload_stage`
  (`o_pl_*`, with the header beat itself on `o_pl_hdr_data`), and its tag
  (`o_pl_sof`: node, round, `frag_idx`) goes to `ssr_presence_tracker`, which
  counts it once `ssr_payload_stage` says it was stored (`o_staged`, §4).

**Only the control frame reaches the core, and only as one bit.** Raising
`o_rx_valid` on every fragment would make a peer a witness five times over.

`o_pl_sof` coincides with payload beat 0; `o_pl_commit` / `o_pl_drop` never
coincide with a beat. `ssr_payload_stage` depends on both.

### 3.1 The control frame carries the ack vector

Each round opens with one control frame per node, before any payload. It looks
back only: node i's control frame at the top of round R+1 carries, for round R,

```text
ack[k]  (k != i)   how many of k's round-R fragments i holds, as a contiguous prefix
ack[i]             how many round-R fragments i sent
```

That is `ssr_presence_tracker`'s counts for R (`o_prev_ack`), final at the
boundary into R+1 (§7), latched by `ssr_tx_engine` with its start pulse.
Nothing announces what a round will send: a node sends whatever its proposal
buffer offers, whenever it offers it, until the transmit cutoff (§10), and
reports the count afterwards.

**Equal vectors are the whole protocol.** A peer whose vector equals ours is a
witness; if a quorum (ourselves included) are witnesses, round R commits, and
what is committed of each node k is `ack[k]` - the same value at every node
that commits, because two quorums share a node and that node broadcast one
vector. Data completeness needs no rule of its own: `ack_k[k] == ack_self[k]`
("k sent what I hold of it") is one coordinate of the equality. Since the
comparison is the rx engine's last rung, `ssr_core` never sees a count. An
idle node sends a vector with its own byte 0 and is a witness like any other.
The consequence is that a node's round is no longer all-or-nothing: if k is
short everywhere (it crashed mid-round, or its last fragment was lost at every
receiver), the others agree on the prefix they hold and commit that, and k,
having no witness, drops out. `docs/count_ack.md` §2-3 has the argument, §5
the timing.

---

## 4. Station 3 — `ssr_payload_stage`

A frame-sized ring: `P_PAY_SLOT_COUNT = 16` slots × 4096 B = **64 KiB,
constant** — the whole address space of one `ram_sel`. It does not scale with
`N`, `P` or round depth, because a slot holds one *frame*, not one round's
worth of one node's payload. It is a staging buffer for the DMA engine to read
out of, not a store. The elaboration check requires at least
`(N−1) × P_FRAGS_PER_ROUND` slots — a whole round's arrivals from every peer —
so PCIe falling behind for a round costs nothing.

**A frame lands whole, header beat first.** The header beat is latched at
`i_pl_sof` and written to the slot's beat 0 on commit; the payload beats go to
beats 1..n as they arrive. So the slot is byte-for-byte the frame, and the one
descriptor that leaves is `64 + length` bytes from the slot's beat 0 to one host
page. (On the AU200 a DMA RAM row is two 512-bit segments, so two beats: beat
k of a slot is segment k % 2 of the slot's row k / 2. Each segment has its
own command port, so a beat is one write to one segment.) There is no second descriptor and no header-page state machine: the
header simply travels with its payload.

**A slot is released on completion, not on pop.** Corundum's write engine
reads the staging RAM asynchronously after accepting a descriptor, so a slot
popped is a slot the engine may still be reading. Three pointers:

```text
tail   next free slot to write          advanced by commit
head   next slot to hand to the writer  advanced by pop   (o_head_valid = unissued > 0)
free   oldest slot not yet released     advanced when slot_popped && !slot_pend
```

`slot_pend[s]` is set on pop and cleared by `i_desc_done / i_done_slot` from the
writer; completions come back in any order, and `free` only moves past a slot
that has both been popped and completed. `slot_count = tail − free` is what
gates the wire.

A frame that `ssr_rx_engine` drops after its beats are written (`i_pl_drop`) is
un-written by not advancing `tail`. A control frame occupies no slot.

`o_staged` pulses on the commit cycle of a frame that WAS stored - it had a
slot, a legal length, and will leave as a page. `ssr_presence_tracker` counts
that, not `ssr_rx_engine`'s own commit, so a frame the ring had no room for is
never counted in our ack for a host that will never see it. The consequence
is deliberate: a host that stops taking delivery past the ring's capacity
makes this node's ack fall short of what its peers hold, no peer's vector
matches its own, and it halts on `HALT_NO_AGREED_ROW` at that round's decision
rather than promise pages it cannot deliver (H4 in the integration bench).

Counters: `STAGE_PUSH`, `STAGE_FULL` (dropped, no free slot — a design error
under normal load, see the check above). An oversize tag, a start of frame
while one is open, and beats that disagree with the tag each set a `FAULT` bit
(§9); none of them can happen past `ssr_rx_engine`.

---

## 5. Station 4 — `ssr_payload_dma_writer`, and the read demux

Thin, and stateless between pop and descriptor: when the head has a frame, the
tag pool has a tag, the block is enabled and the output register is free, pop
it, compute the host address (§6), borrow a tag keyed on `round mod
P_ROUND_DEPTH` with `{round_id, node, slot}` as its meta, and offer the
descriptor. On the completion with that tag: give the tag back, tell
`ssr_payload_stage` the slot (`o_desc_done`), and if the engine reported an error
tell `ssr_presence_tracker` the `(round_id, node)` (`o_err_*`). The round rides
whole in the meta - 64 bits per tag - so a late error can never be charged to
a round that has since taken the same slot. Several descriptors are in flight at once —
that is the whole point of the path, and why `ssr_dma_tag_pool` exists.

Tags `DMA_TAG_PAY_BASE = 0` .. `P_DMA_TAG_COUNT − 1` (0..15), on the data
DMA. The verdict writer's tag is 0 too, but on the control DMA, which reports
on its own status stream, so the two cannot be confused. A data-DMA completion
with any other tag is ignored and sets `FAULT.PAY_STRAY`. The app's DMA tag space is its
own - 13 bits on the AU200; `dma_if_mux` adds the port bits above it - so
nothing else shares these numbers.

### 5.1 Two DMA paths, one RAM port each

Each of the app block's two DMA paths has its own descriptor stream, its own
status stream and its own RAM ports, so each writer gets a whole path and no
`ram_sel` decode is needed anywhere:

| bus | direction | wired to | serves |
|---|---|---|---|
| `data_dma_ram_wr_cmd_*` | engine writes into app RAM | `ssr_proposal_buffer` | data DMA **read** descriptors — the proposal fetch |
| `data_dma_ram_rd_cmd_*` | engine reads out of app RAM | `ssr_payload_stage` | data DMA **write** descriptors — pages |
| `ctrl_dma_ram_rd_cmd_*` | engine reads out of app RAM | `ssr_verdict_dma_writer` | control DMA **write** descriptors — verdict records |

```text
RAM_SEL_PAYLOAD = 0     data DMA: ssr_payload_stage's RAM is the only thing on the port
RAM_SEL_VERDICT = 0     ctrl DMA: the record register is the only thing on the port
RAM_SEL_PROP    = 0     data DMA read side: ssr_proposal_buffer
```

The wrapper does not look at any `*_ram_rd_cmd_sel`. (Before the verdict moved
to the control DMA, both readers sat behind the one data read port and
Corundum's `dma_ram_demux_rd` split it on the top bit of `ram_sel`.)

### 5.2 Why the verdict is on the control DMA

Inside `mqnic_core`, each path is first merged across the interfaces and the
app, round-robin (`dma_if_mux_ctrl_inst`, `dma_if_mux_data_inst`, "interface
DMA mux (round-robin)"). The two paths are then merged into the one PCIe DMA
engine with **control first** (`dma_if_mux_inst`, `ARB_TYPE_ROUND_ROBIN(0)`,
`ARB_LSB_HIGH_PRIORITY(1)`, port 0 = control; "data/control DMA mux
(priority)"). Corundum's own control traffic - descriptor fetches, completion
and event writes - is small and latency-bound, like a verdict; its data traffic
is packets.

So on the data DMA a verdict would take its round-robin turn behind the NIC's
own receive-packet writes on every interface. On the control DMA it waits only
for the operation already inside the write engine, which takes one descriptor
at a time and is not preempted (`dma_if_pcie_wr`, `REQ_STATE_IDLE`).

The priority does **not** replace the fence. A verdict on the control DMA would
overtake any page of its round still waiting at the mux, so
`ssr_verdict_dma_writer` still issues the record only once the round's unit is
idle - every page descriptor of the round has completed. The priority shortens
the wait after the fence opens; the fence decides when it opens.

---

## 6. Where the bytes land

```text
host_addr(R, k, f) = payload_base
                   + ((R mod D_HOST) · N + k) << REGION_SHIFT
                   + (f << 12)

REGION_SHIFT = clog2(P_FRAGS_PER_ROUND · 4096)      15 at 5 fragments
D_HOST       = 1 << P_HOST_DEPTH_LOG2               256 rounds, 1 ms
```

`R mod D_HOST` is a bit slice. `· N` is a constant multiply by a small
integer — a shift and an add or two. `f << 12` is wiring. All of it is on the
head interface the cycle it is popped.

```text
region for (R, k):
    page f      [64 B frame header][up to 4032 B payload]     f = 0 .. P_FRAGS_PER_ROUND-1
                committed: f < frag_count[k] of R's verdict record (§8)
```

**Every page says what it is.** The frame header rides on top of the page it
arrived in — `round_id`, `node_id`, `frag_idx`, `length` — so the host can
check a page against the verdict record rather than trust it blindly, and a
page can be handed onward to anything that works in pages (`mmap`, an io_uring
registered buffer, a GPU or RDMA region) with its provenance attached. *How
many* of a region's pages count is only in the verdict record: a page past
`frag_count[k]` may hold bytes that arrived but were not agreed on.

**`REGION` is the transmit budget applied to the receive side.** Every node in
the cluster is built with the same `P_FRAGS_PER_ROUND`, and `ssr_rx_engine`
refuses a `frag_idx` at or past it (`SSR_MAX_FRAGS` is the format's ceiling;
the budget is the bound), so no frame can be addressed outside its region.

**Our own region (`k == P_NODE_ID`) is never written** — the host already has
its own proposal, and `ssr_tx_engine`'s local echo has no consumer.

Worked geometry at `N = 3`, `D_HOST = 256`:

| `P_FRAGS_PER_ROUND` | payload / node / round | `REGION` | `SLOT = N·REGION` | pinned |
|---:|---:|---:|---:|---:|
| 2 | 8 064 B | 8 KiB | 24 KiB | 6 MiB |
| **5** | **20 160 B** | **32 KiB** | **96 KiB** | **24 MiB** |
| 8 | 32 256 B | 32 KiB | 96 KiB | 24 MiB |
| 16 | 64 512 B | 64 KiB | 192 KiB | 48 MiB |

`D_HOST` is a host-memory depth, so it can be 256 or 1024 rather than the 4 we
keep on chip. A round's region cannot be overwritten underneath a reader with
a thousand rounds of margin.

### 6.1 Why 4096

Because it is an OS page, and a frame that is exactly a page lands in exactly
one page: one IOMMU translation, one descriptor, no header page and no second
descriptor for it. Two costs pull against each other in choosing the fragment
size — 88 bytes of wire overhead per frame favours big fragments, the last
fragment's arrival time favours small ones — and the optimum is near
`sqrt(88 · (N−1) · bytes_per_round)`, about 3.4 KB at `N = 3`. 4096 is the
page beside it.

The frame is 4 096 bytes, so the fabric needs an MTU of about 4 100. The
testbed's Tofino2 is cut-through, so the frame does not add its own
serialisation to `T_prop`; on a store-and-forward switch it would add 328 ns at
100G.

---

## 7. Station 5 — `ssr_presence_tracker`, and the fence

How many of each node's fragments we hold, per round. It is the only place in
the design that knows a count: our ack vector comes out of here, and so do the
verdict record's `frag_count`s.

```text
open(R)                 core's round start pulse: R's slot is cleared and becomes the open round
fragment(k, R, i)       staged, R open, i == count[k]: count[k]++    R not open: PRES_LATE
                        (i != count[k], a gap or a repeat: not counted)
sent(R)                 our own fragment admitted (o_local_sent), R open: count[self]++
error(R, k)             failed[k] = 1                                R not held: PRES_ERR_MISS
o_prev_ack              count[0..7] of the round before the open one, one byte each
```

* **A round opens on `ssr_core`'s `o_round_start_pulse`**, the *ungated* one
  (pure timing), so the round a node activates in is open too - the
  protocol-gated boundary pulse does not fire on the activation boundary. Only
  the open round counts; a fragment for any other round is charged to
  `PRES_LATE`. `ssr_rx_engine` already refuses a payload frame from another
  round, so what could still be late here is a fragment admitted just before
  the boundary and stored just after it; the transmit cutoff (§10) is sized so
  that does not happen.
* **The count is a prefix.** A fragment counts only if its `frag_idx` is the
  next one expected from that node. On one link frames stay in order, so a gap
  is a loss; counting past it would let one loss and one duplicate add up to
  "all of them". Fragments after a gap are still staged and DMA'd, because
  placement is by `frag_idx`, but no agreed prefix will ever cover them.
* **Our own fragments count when `ssr_tx_engine` admits them** (`o_local_sent`,
  one pulse per fragment): our bytes are already in our own host memory,
  nothing has to land. That is `ack[self]`.
* **R's counts are final at the boundary into R+1**, and three readers see the
  one value: `ssr_tx_engine` puts it in our control frame (`i_tx_ack`),
  `ssr_rx_engine` compares every peer's ack against it through R+1's control
  period (`i_rx_self_ack`), and query B hands it to the verdict writer after
  that. `o_prev_ack` is a register re-read every cycle rather than a snapshot,
  so a fragment counted on the boundary cycle itself is in it.
* `P_ROUND_DEPTH = 4` slots by `R mod 4`, holding the full id. Opening a round
  clears its slot, which is the only eviction; there is no timer and no
  eviction counter. Depth must be ≥ 2 — R's ack is sent, and R decided, in
  R+1; 4 leaves two rounds of slack for a verdict held behind a slow PCIe.
  A DMA error report names its round and is looked up like a fragment: for a
  round no longer held it misses (`PRES_ERR_MISS`) instead of landing on the
  round that now occupies the slot.
* **A DMA error does not change a count.** It sets `failed[k]`, which the
  verdict record reports as `present_set[k] = 0`. The ack reports what
  arrived on the wire; `present_set` reports whether this host's copy is
  intact.
* **Query B** (combinational): `ssr_verdict_dma_writer` asks for the round it
  is describing and gets the counts and `present` (= no DMA error) per node.
  A miss reads as nobody present and zero counts.

**`ssr_core` never sees a count.** For the round it is about to decide it keeps
a witness mask: our own bit, set at the boundary, and one bit per trusted
pulse from `ssr_rx_engine` during the control period. At the deadline:

```text
witness      = witness mask & current sound set & MEMBER_MASK
commit       if we are in our own sound set and popcount(witness) >= QUORUM
sound set'   = witness                 (shrink-only check unchanged)
o_commit_set = sound set'              what was committed is our ack for R, read from the tracker
```

There are no peer rows, no present row and no `o_tx_row` any more, and
`HALT_REASON` 2 (commit set invalid) is retired: what is committed is our own
vector, which we hold by definition. The core's one new output is
`o_tx_pay_open`, the transmit cutoff as a level (§10).
`tb_ssr_core_protocol` stands a small model in for everything between two
cores - each node's control frame doubles as its one fragment, a receiver
counts it, and a vector equal to the receiver's own gives the core a trusted
pulse. Its negative controls are in its header (a core that never sets a
witness bit halts every node in Test 0).

### 7.1 The fence

> A verdict record for round R may not be issued until every payload descriptor
> for round R has reported **completion** — not been issued, *completed*.

Payload writes and the verdict write are separate PCIe posted writes with
different tags and may complete in any order. A verdict that becomes visible
before its pages have landed makes the host read a page still being written,
or one still holding round `R − D_HOST`'s bytes.

It fails in the worst way available: never at low load, because there the
pages drain long before the verdict exists. It appears only when the DMA
engine is queued — the regime this design exists to enter.

`ssr_dma_tag_pool` implements it. `unit_out[u]` counts descriptors in flight for
unit `u = R mod UNIT_COUNT`, incremented on allocation and decremented on
completion in whatever order completions return; `o_unit_idle[u]` is the
verdict writer's `fence_open`.

A completion **error** is discovered before the verdict is issued, so the
node's present bit is withdrawn (`failed`) and the host sees
`frag_count[k] > 0` with `present_set[k]` clear — committed, but this host's
copy is lost: a loss to count, not a zero to read. The cluster's decision is
not affected; the ack had already reported what arrived on the wire.

Deliberately **not** used: a footer or sentinel written at the end of the
region. It relies on PCIe write ordering inside a region the host may be
reading with different cache behaviour, and a sentinel value is
indistinguishable from payload that happens to contain it.

---

## 8. Station 6 — the verdict record

`rtl/ssr_verdict.vh` (Python mirror `tb/mqnic_core_pcie_us/ssr_verdict.py`):

```text
 0   round_id       8 B   the round decided - NOT the round it was written in
 8   seq            8 B   record number from 0 at reset; the ring index and the freshness proof
16   run_id         4 B
20   commit_set     1 B   ─┐  the sound set after this decision: who is still in
21   present_set    1 B    │  this host's copy of k's pages is intact (no DMA error)
22   node_count     1 B    │
23   self_index     1 B    │  which region is the host's own
24   frag_count[8] 16 B   ─┘  2 B each: the COMMITTED PREFIX of node k
40   proposal_consumer 4 B    the proposal ring's CONSUMER when written (§13)
44   reserved      20 B
```

The layout is unchanged from before count acks; what the fields mean is not.
Three fields answer three questions:

* `frag_count[k]` is what the protocol decided: pages `0 .. frag_count[k]−1`
  of k's region. It is our ack about the round, and every node that commits
  the round commits exactly these counts. Our own entry is what we sent.
* `present_set[k]` is a fact about bytes on *this* host. The protocol never
  sees it.
* `commit_set[k]` is who is still in. It **does not gate reads**; it tells
  "idle" from "gone" for a zero count, and "last pages" for a non-zero one.

**The host reads node k's pages `0 .. frag_count[k]−1` where
`present_set[k]`.**

| `present_set[k]` | `frag_count[k]` | `commit_set[k]` | meaning |
|---|---|---|---|
| 1 | n > 0 | 1 | read pages 0..n−1 |
| 1 | n > 0 | 0 | read pages 0..n−1; k left the sound set in this round and these are its last |
| 1 | 0 | 1 | nothing of k's this round: alive, proposed nothing |
| 1 | 0 | 0 | nothing: k is gone |
| 0 | any | any | count a loss, **not** read — this host's copy failed a DMA |

A committed prefix ends on a ring-entry boundary, and a proposal never spans
two entries (§3), so the host never sees half a proposal.

The record goes to `verdict_base + (seq mod D_V) · 64`, `D_V = 1 <<
P_VERDICT_DEPTH_LOG2`. A 64-byte record is one PCIe write, so it lands whole;
the host polls the next entry for a `seq` it has not seen.

`ssr_verdict_dma_writer` is one state machine with one record in flight: queue the
decision (`i_commit_valid`, depth 4 — a fifth in a burst is `VERDICT_OVERFLOW`
and a gap the host will see in `seq`), wait for `unit_idle[R mod 4]`, read the
tracker, compose, issue, wait for the completion, pop. The record is a 512-bit
**register**, not a RAM: the module answers the engine's segmented read port
itself, whatever address the command names, and the descriptor always says
`ram_addr 0, len 64`.

---

## 9. The registers (`rtl/ssr_csr.v`)

Every register the host can see is in one module, `ssr_csr`, in one 4 KiB
page, decoded once. No other module has a register bus: a setting goes down to
its module as an input port, and whatever the host may read comes back as an
output port. `ssr_csr.v`'s header is the map; `kernel/ssr_regs.h` and
`tb/mqnic_core_pcie_us/ssr_dataplane.py` copy it.

```text
0x000  identity   TYPE VERSION NEXT_PTR SCRATCH
                  NODE ([7:0] id, [15:8] count)  ROUND_NS
                  GEOMETRY ([7:0] node_count, [15:8] region_shift,
                            [23:16] payload ring depth log2, [31:24] verdict ring depth log2)
                  PAGE_BYTES (4096)  FAULT
0x100  consensus  CORE_CONTROL CORE_STATUS CFG_RUN_ID CFG_MEMBERSHIP CFG_EFF_ROUND_LO/HI
                  CUR_ROUND_LO/HI CUR_RUN_ID CUR_SOUND_SET CUR_MEMBERSHIP
0x140  halt       HALT_REASON (2 retired) HALT_ROUND_LO/HI HALT_WITNESS (0x14C)
                  HALT_MEMBERSHIP HALT_SOUND_SET
0x200  proposal   PROP_CONTROL PROP_STATUS PROP_ERROR_CODE PROP_DEPTH_LOG2
                  PROP_BASE_LO/HI PROP_PRODUCER PROP_CONSUMER PROP_FETCH PROP_INFLIGHT
0x300  delivery   DLV_CONTROL (bit 0 payload DMA, bit 1 verdict DMA)
                  DLV_STATUS ([7:0] unit_idle, [15:8] tag high water)
                  PAY_BASE_LO/HI VER_BASE_LO/HI SEQ_LO/HI
0x400  counters   ROUND / COMMIT / HALT / TIME_FAULT
0x440             TX_CTRL_FRAMES TX_PAY_FRAMES TX_EMPTY TX_OVERRUN TX_MISSED
                  TX_HOST_FRAMES TX_CPL_COUNT TX_CPL_TS_0..2
0x480             RX_FRAMES RX_ACCEPT RX_CTRL RX_MALFORMED RX_CTRL_LATE, the five
                  drop rungs, RX_STALL RX_HOST_FRAMES RX_ACK_DISAGREE (0x4B0)
0x4C0             PROP_READS PROP_READ_ERRORS
0x500             STAGE_PUSH STAGE_FULL PAY_DESC PAY_CPL PAY_ERR PAY_STARVE
                  (0x518 unused) PRES_LATE PRES_ERR PRES_ERR_MISS
                  VERDICT_RECORDS VERDICT_ERR VERDICT_OVERFLOW VERDICT_STALE
```

`HALT_WITNESS` is who agreed with us in the evaluation that failed, ourselves
included. The peers' vectors are not kept: they never reach the core, and our
own for that round stays in the tracker for a few rounds. `RX_ACK_DISAGREE`
counts peer control frames whose ack differed from ours; it is a protocol
statistic, not a fault, and is not in `FAULT`.

**FAULT** replaces seven counters that a correct design keeps at zero: a
non-SSR frame reaching `ssr_rx_engine`, the transmit buffer's length and last
beat disagreeing, an oversize slot, an oversize or overlapping or mis-sized
frame in the stage, a completion for no live tag. Each is one sticky bit ("at
least once since reset"); the modules keep the exact counts for simulation.

Bring-up order for delivery: write both bases, then `DLV_CONTROL = 3`. With it
0 the stage fills and `STAGE_FULL` counts; nothing is written to the host.

**What went, and why.** The map used to be four 4 KiB blocks decoded on
`addr[23:12]`, two of them decoded inside `ssr_core` and
`ssr_proposal_dma_reader` and two in the wrapper. Removed with it:

* a writable `REPLICA_ID` / `REPLICA_NUM` / `ROUND_LENGTH_NS` / `ETHERNET_PORT`,
  a 7-entry MAC table, and a `CONTROL` / `ERROR` / `STATUS.config_valid` that
  drove nothing - the node id, the node count and the round are parameters,
  and the core already reported them read-only (now `NODE` and `ROUND_NS`);
* a `MAGIC` / `VERSION` / `FEATURES` per block, and `PROP_SLOT_BYTES`
  (= `PAGE_BYTES`);
* `ssr_core`'s `i_enable` port, tied high beside a `CONTROL.enable` register;
* `RX_DMX_SSR_FRAMES` (= `RX_FRAMES`), `TX_MUX_SSR_FRAMES`
  (= `TX_CTRL_FRAMES + TX_PAY_FRAMES`), `PRES_OPEN`, and `TX_CPL_OVERRUN`,
  whose acknowledge was never wired, so it only counted completions;
* with count acks: `HALT_SELF_ROW` (0x14C, now `HALT_WITNESS`), the
  observation matrix `HALT_ROWS_LO/HI` (0x158/0x15C) and `PRES_EVICT` (0x518).
  There are no rows to record, and opening a round is the tracker's only
  eviction.

---

## 10. The round geometry, and where 5 fragments comes from

There is **no TDMA**. Every node transmits at the same instant,
`TX_START_OFFSET_NS = PROP_DEAD + g + settle = 332`, and what keeps `(N−1)` of
them from swamping one receiver is that each holds its own rate at or below
`R/(N−1)`: after each fragment, `ssr_tx_engine` stays quiet for `(N−2)`
frame-times (`P_PACE_GAP_CYCLES`, derived in `ssr_dataplane` from the line
rate and the clock: 82 cycles at `N = 3`, 100G, 250 MHz). Pacing is per
fragment, so a switch's transient is bounded by `(N−2)` frames, and at `N = 2`
the gap is zero.

**Nothing is planned; there is one transmit bound, the cutoff.** After its
control frame and the skew gap, `ssr_tx_engine` sends a fragment whenever the
proposal buffer offers a whole slot (it takes the slot's first beat the cycle
it admits it), paced, up to `P_FRAGS_PER_ROUND` a round, and only while
`ssr_core`'s `o_tx_pay_open` is high. A fragment of round R may start, on our
clock, in

```text
TX_PAY_START_NS  = TX_START + t_ctrl + PAY_GAP                     = 332 + 6 + 128          = 466
TX_PAY_CUTOFF_NS = ROUND − frame − T_prop − g − settle             = 4000 − 327 − 250 − 50 − 32 = 3341
```

The cutoff is the latest start whose fragment is still stored at every peer
before that peer's boundary, even with the peer's clock `g` ahead. That is
what makes the tracker's counts for R final at the boundary (§7): a fragment
counted by the sender but not by its receivers would put the sender's vector
out of agreement and lose it the round. A slot still in the buffer at the
cutoff goes out next round; nothing is dropped. Paced starts land at 466,
1121, 1776, 2431 and 3086; the next (3741) is past the cutoff, so the budget is
still 5. (`ssr_dataplane` derives `TX_PAY_CUTOFF_NS` and passes it to
`ssr_core`, which raises `o_tx_pay_open` from the boundary to the cutoff,
gated like every protocol output.)

```verilog
parameter P_SLOT_DURATION_NS   = 4000;   // the round
parameter P_GUARD_NS           = 50;     // g
parameter P_CTRL_PERIOD_NS     = 646;    // Tc, the control deadline
parameter P_PROP_DEAD_NS       = 250;    // T_prop
parameter P_PRESENT_SETTLE_NS  = 32;
parameter P_FRAGS_PER_ROUND    = 5;
parameter P_PAY_GAP_CYCLES     = 32;     // skew gap after the control frame
```

`Tc = 2·T_prop + (N−1)·t_ctrl + 2g + settle = 500 + 10.2 + 100 + 32 = 642 → 646`.

**The binding constraint is the receive side.** We send one node's payload and
receive `(N−1)` of them on one 100G link, from `Tc` until one propagation past
the boundary:

```text
span      = (ROUND + T_prop) − Tc  = 4250 − 646     = 3604 ns
capacity  = 3604 ns × 12.5 B/ns                     = 45 050 B
per peer  = 45 050 / (N−1)                          = 22 525 B
          = 5 frames of 4096 B        →  P_FRAGS_PER_ROUND = 5
```

So 5 × 4032 = 20 160 B of payload per node per round, 40 Gbps per node at
250 000 rounds/s, latency `2·Tc + Tp` = 4.65 µs from the start of R to its
decision at R+1's control deadline (`ssr_core.v` evaluates there, not at the
boundary into R+2 — that boundary evaluation was a leftover of the
single-period core and cost 3.35 µs for nothing). Measured instead from a
proposal reaching the FPGA's buffer, for an arrival uniform over the round, it
is about 3.3 µs mean and 5.3 µs worst: anything that arrives before the cutoff
goes out in the round it arrived in. (With the announcement, a proposal that
missed the control frame at 332 ns waited a whole round: 6.3 µs mean, 8.3 µs
worst.) Raising the fragment count means raising the round length with it; the
throughput barely moves, because both settle against the same link, and the
latency grows in step.

### 10.1 The checks that hold this together

`ssr_dataplane` refuses to elaborate if a full round's budget of paced
fragments does not start before the cutoff:

```text
TX_LAST_START_NS = TX_PAY_START + 4·(frame + PACE_GAP)   <= TX_PAY_CUTOFF_NS
                 = 466 + 4·(327 + 328) = 3086             <= 3341
```

plus `P_NODE_COUNT >= 2`, the staging ring's size and capacity (§4), and
`P_DMA_TAG_COUNT` fitting the app's tag width. `ssr_core.v` checks
`CTRL_PERIOD > TX_START + PROP_DEAD` (a control frame can be in time),
`CTRL_PERIOD < ROUND`, `PROP_DEAD < CTRL_PERIOD`, and that the cutoff lies
between our control frame and the end of the round. `ssr_presence_tracker`,
`ssr_verdict_dma_writer`, `ssr_payload_stage` and `ssr_rx_engine` each check their own
geometry against `ssr_packet.vh`.

The receive side has **one** window, `o_rx_ctrl_window = [0, CTRL_PERIOD)`,
with no lower bound — a lower bound rejected early peers — and payload has
none at all (`o_rx_pay_enable = protocol_active`). Naming that a window would
invite someone to put a time bound back into it, which is exactly what the
rate cap and the sender's cutoff made unnecessary.

**Open: the cutoff assumes the port is ours.** A fragment admitted at the
cutoff can still wait behind a host frame already in `ssr_tx_mux` (SSR wins
only at frame boundaries); a 9 KB jumbo frame at 100G is more than the margin,
and the fragment then lands after a peer's boundary and costs this node its
round. Not built: either subtract one maximum host frame from the cutoff, or
have `ssr_tx_mux` start no host frame in the last MTU-time before it
(`docs/count_ack.md` §10).

---

## 11. What the trace turned up

Findings from converting the path, kept because each one changed a design
decision. In order found.

* **The commit RAM capped the payload stride, and capped it low.** The old
  commit slot was `64 + N·stride` rounded to a power of two inside one 64 KiB
  `ram_sel`, with at least two slots required — a hard elaboration wall at
  10.6 KiB per node at `N = 3`. Speculative delivery removes it: the verdict
  record is 64 bytes and the guard is gone with the module.
* **Nothing on the host side depended on the old commit queue.**
  `kernel/commit_queue.c` and `host/src/agent_dataplane_backend.cpp` were
  0 bytes, `ssr_regs.h` had no `0x2000` offsets. Replacing the arm / capacity /
  disarm-when-full / ping-pong CSR model with two bases and an enable broke
  nothing.
* **`ssr_dataplane` had not elaborated since the `ssr_tx_engine` rework** — a slot
  size that failed a check, a port with no source, a counter that no longer
  existed. `tb_ssr_dataplane` is out of the regression, so the break sat for
  days. `make elab` now runs first.
* **The sub-slots had to go.** `ssr_core.v` placed each node's transmit window
  400 ns wide, closing 100 ns early; one 4 KiB frame is 328 ns. Two benches
  asserted the property that went away, and `tb_ssr_core_protocol`'s network model
  was last-write-wins on simultaneous `tx_start` — it delivered one node's row
  (the control frame then carried a 1-bit row) and lost two, which the
  protocol correctly read as two peers going silent. Then the window itself
  went, replaced by the rate cap.
* **`ssr_payload_stage` released a slot on pop.** Corundum's write engine reads
  the RAM after accepting the descriptor, so a released slot could be
  overwritten under the engine. Three pointers and completion-driven release.
* **`ssr_payload_stage` lost beat 0.** `o_pl_sof` coincides with beat 0 and the
  header used a single write port on the same cycle; the bench had driven sof a
  cycle early and hidden it. The header is now written on commit.
* **The header page was a second descriptor, a state machine and 49 % of the
  slot.** Making the frame exactly a page removed all three (§6).
* **A function that reads a module array is only re-evaluated when its
  arguments change.** `ssr_presence_tracker`'s slot lookup, written as a function
  and used in a continuous assignment, never noticed a slot opening. Written
  out as wires.
* **The verdict record's response is one cycle wide** when the engine is ready;
  a bench that looked for it after the fact missed it every time. Caught on
  the handshake edge instead.
* **`ssr_tx_engine` never truncates a frame**, so the "abandoned fragment desyncs
  `ssr_proposal_buffer`" worry was unfounded: a start pulse during a frame is only
  counted (`TX_OVERRUN`), the frame finishes, and the slots the round did not
  get to simply go out in the next one under its round id. No flush needed.
* **A one-node integration bench cannot let a short peer stay in the sound
  set.** The short peer's own ack byte claims one more fragment than anyone
  holds, so its vector is the odd one out: it is no witness, the others commit
  the prefix they hold, and the set shrinks to the rest - which is the
  protocol working. The bench's H1 asserts exactly that instead of avoiding
  it. (Before count acks the short peer counted itself present and the others
  did not; the outcome was the same, except that none of its fragments were
  committed.)

With count acks (`docs/count_ack.md` §10):

* **The transmit window reopened before the control frame.** `pay_run_reg`
  was cleared only by the next start pulse, but `o_tx_pay_open` rises again at
  the boundary, a whole dead zone earlier, so a slot waiting there went out
  stamped with the round that had just ended: every receiver dropped it, and
  the sender halted. `tb_ssr_dataplane` B6 caught it under port back pressure;
  `pay_run_reg` is now also cleared whenever the level is low, and
  `tb_ssr_tx_engine` R5 pins it.
* **Sound sets may legitimately differ between nodes.** If a node's control
  frame in R+1 reaches nobody, the others drop it at R's decision while it,
  still hearing them, keeps them; both sides commit the same vector for R. So
  `tb_ssr_core_protocol`'s agreement monitor compares committed vectors, not
  `o_commit_set`. With bit rows this was hidden, because the sound set and
  the committed row were the same value.

---

## 12. What is left

`tb_ssr_dataplane` now has a group I: a 280-round soak that checks every
page and every record across both host-ring wraps (I1), one page's completion
parked for four rounds so its record goes out stale while the rounds behind it
are untouched (I2), and a control frame taken on the deadline's last admitted
cycle whose sender is still a witness (I3 - the control for
`CTRL_END_SETTLE_CYCLES`). Count acks added B7 in its present form (a backlog
posted after the cutoff: nothing more that round, then five, then three), B8
(a proposal posted mid-round goes out in that round), E14 (the ack rung), and
reworked C2 (a peer that sends nothing is a witness with a zero count) and H1
(a short peer: no witness, its prefix committed, out of the sound set). The
bench is generic over the RTL's node id and the regression runs it as node 0
and as node 1 (`SSR_TB_NODE_ID`); node 2 is a target for a full rotation.

Since the earlier version: the evaluation moved from the boundary into R+2 to
the control deadline of R+1 (`round_structure.md` §4, now as built);
`tb_ssr_core_protocol` asserts a commit lag of exactly one round and an offset
just past `CTRL_PERIOD_NS`. A proposal entry is formally a frame-shaped 4 KiB
block (`ssr_packet.vh`, "A PROPOSAL ENTRY HAS THE SAME SHAPE AS A FRAME").
The proposal path itself was rebuilt as a ring with a doorbell (§13).

**Considered and not done: immediate-write verdicts.** `dma_if_pcie_wr`
can carry the 64-byte record in the descriptor (`IMM_WIDTH` up to the TLP
width, 512 bits on the AU200), which would delete the verdict writer's
read-port responder. It costs `DMA_IMM_ENABLE = 1, DMA_IMM_WIDTH = 512` on the
core: a 32 × 512-bit `op_table_imm`, two 512-bit pipeline registers and a
1 024-bit mux in the TLP data path, for a saving of one 512-bit responder now
that the verdict has a read port of its own (the control DMA's) and needs no
`dma_ram_demux_rd`. Not worth a rework on its own. If `DMA_IMM_ENABLE` is ever turned on for
another reason, switch the verdict over then: the price is paid, the
simplification is free. Batched verdicts were also considered and rejected:
records are consecutive and self-contained, so the host already batches by
reading up to the newest `seq`, and each record carries its own commit set.

Everything in the earlier version of this list is done: the echo ports are
gone from `ssr_tx_engine`, `ssr_rx_engine` bounds `frag_count` by the budget
(now `frag_idx`, since there is no `frag_count` on the wire), the DMA
error names its round, the five pre-fragmentation benches are retired
and `tb_ssr_dataplane` is rewritten and in the regression.

* **The cocotb end-to-end test** (`tb/mqnic_core_pcie_us`): `ssr_packet.py`,
  `ssr_verdict.py` and `ssr_sim_harness.py` mirror the frame, the record and
  the peers; `ssr_dataplane.py` has a `Delivery` driver model (read the
  geometry, allocate both rings, program the bases, enable, poll the verdict
  ring by `seq`, read pages back through their own headers) and `ssr_core.v`'s
  real register map; `run_test_ssr_dataplane` in `test_mqnic_core_pcie_us.py`
  drives it through the real PCIe DMA engine and MAC. The Python is
  import-checked and its frame builder is unit-checked. It could not compile
  while our transmit and receive engines were called `tx_engine` and
  `rx_engine`, the same module names as Corundum's own; with every SSR module
  now `ssr_<name>` (§0) it compiles (cocotb 1.9, Icarus 12). It then stopped
  at time 0 on our own elaboration checks, because this configuration (the
  AU200's, 512-bit PCIe) has a 1024-bit DMA RAM row and SSR assumed a row was
  one beat. That is settled: a row holds two beats, one per segment, and the
  Makefile now builds the AU200's own parameters (`docs/au200_parameters.md`).
  `ProposalRing` in `ssr_dataplane.py` is rewritten for the ring (§13).
  **It runs end to end and passes**, with count acks: the node joins, four
  rounds are decided and delivered with both peers' pages byte for byte, our
  three proposals leave as fragments (possibly split across two rounds, each
  numbering its own from 0) and the records' own `frag_count`s sum to three,
  a peer that sends nothing stays in with a zero count, and no counter shows
  a drop. The harness's peers compute their ack vectors from what they sent
  and what they saw the RTL node send. `run_test_nic` passes too. Getting there turned
  up one RTL bug - SSR's transmit tag (au200_parameters.md, A5), which also
  stalled Corundum's own `run_test_nic` - and four in the Python, none of
  which had ever executed: the driver model took its DMA pool from the wrong
  object, did not accept a MAC as a string, and read our own (never written)
  payload region back; and the peer harness read the run id on the
  activation boundary's own edge, got the old one, and sent a whole round the
  RTL dropped - so our row for it named nobody, the peers' named everyone
  (these were bit rows), and the node halted on its first decision. The test
  now also joins a few
  rounds after the PHC's current round instead of at round 0x100, which is a
  millisecond of simulation from a PHC that starts at 0 s.

  *Later (2026-09-25):* the one test became a suite of five, all passing,
  each bringing the whole NIC up (a round simulates in about four seconds):
  `run_test_ssr_dataplane` (steady state; also that both peers' control
  frames, sent at a real peer's 332 ns, reach `ssr_rx_engine` inside the 646 ns
  window through Corundum's receive path - they land at ~400 ns),
  `run_test_ssr_backlog` (24 proposals over three doorbells and a wrap of
  the 16-entry ring: 5, 5, 5, 5, 4 a round, every byte, the records sum to
  24), `run_test_ssr_short_peer` (`tb_ssr_dataplane`'s H1 through Corundum:
  ACK_DISAGREE once, the prefix committed, the sound set 0b011, its later
  frames on the sound rung), `run_test_ssr_halt_recover` (both peers silent:
  halt reason 1, witness = self; silent and deaf for three rounds; then the
  driver's `recover()` - halt record, reboot, a fresh run id - and records
  resume with the next `seq`) and `run_test_ssr_nic_coexist` (41 host frames,
  a jumbo among them, loop through interface 1 untouched while 8 go out and 4
  come in on SSR's own interface; no round lost, no rung touched). The peers
  now transmit at TX_START_NS rather than 20 ns into the round, their acks
  say 0 for a node they have excluded (`harness.excluded`), and the harness
  flags any RTL fragment that leaves the port after the peers' acks about its
  round were built (none does). `ssr_dataplane.py` gained the halt record,
  `recover()`, the tx/rx counter readers and a `wait_running(run_id)` that
  waits for the run it was asked for; `CoreStatus` has all five bits.
* **The kernel driver** (`kernel/ssr_*.c`) is a probe, a scratch
  self-test and read-only sysfs (`identity`, `core_status`, `fault`,
  `scratch`). `ssr_regs.h` carries the whole map (§9) and the record layout,
  so a driver that allocates the two rings with `dma_alloc_coherent`,
  programs them, and exposes the verdict ring to user space has its constants;
  it does not exist yet.

---

## 13. The proposal ring (the commit path run backwards)

The delivery side has a fixed geometry in host memory and addresses that are
a shift; the proposal side now has the same shape. It replaced a batch
interface (base, stride, count, START, poll DONE) whose buffer read one row
every four cycles: a fragment took ~1 µs on the wire, only three fitted in a
round, and `ssr_tx_engine` - which then announced `min(slots, 5)` at the
control frame - broke its own announcement every round it had more than three
to send. (There is no announcement any more, but the rate still matters: the
budget of five only fits before the cutoff at line rate.)

```text
 host memory: ring of 2^d entries, 4 KiB each      NIC
 ┌────┬────┬────┬────┬ ─ ─ ┬────┐
 │ e0 │ e1 │ e2 │ e3 │     │    │   PRODUCER  (doorbell, host writes)
 └────┴────┴────┴────┴ ─ ─ ┴────┘   FETCH     (reads issued)
   entry i at base + ((i mod 2^d) << 12)       CONSUMER  (whole in the buffer, in order)
```

**Host.** Program `RING_BASE`, `RING_DEPTH_LOG2`, `CONTROL.enable` once. To
propose: write entries at the producer index, then write the new index to
`PRODUCER` - one posted MMIO write. An entry below `CONSUMER` may be
overwritten; `CONSUMER` is also in every verdict record (`proposal_consumer`,
offset 40), which the host is polling anyway, so the fast path has no MMIO
read.

**`ssr_proposal_dma_reader`.** Issues a read for entry `FETCH` whenever
`FETCH != PRODUCER`, the buffer has a free slot and fewer than
`MAX_INFLIGHT` (4) reads are out. The tag is `DMA_TAG_PROP | slot`, so a
completion names its slot without a table. A read of 4 KiB takes a
microsecond or more; four in flight keep up with five entries a round.

**`ssr_proposal_buffer`.** Eight slots and three pointers, because completions
come back in any order:

| range | state |
|---|---|
| `[head, commit)` | committed: whole, in ring order, counted in `buf_slot_count` |
| `[commit, resv)` | reserved: a read was issued; a done bit per slot says which landed |

`commit` walks forward over done bits and stops at the first slot whose read
has not completed, so entries become transmittable in the order the host
posted them. The transmit side issues RAM commands for beats 1..63 back to
back - each to the segment that holds it - and streams the responses: **one
beat per cycle**, 64 cycles a frame. `ssr_tx_engine` takes the first beat on
the cycle it admits the fragment, before the header goes out, so a fragment is
64 back-to-back beats.

**Errors.** A failed read sets `STATUS.error` and never sets its done bit, so
`commit` - and `CONSUMER` - stop exactly on the failed entry; nothing new is
read. `CONTROL.clear_error` waits for the reads in flight, gives back every
reserved slot and sets `FETCH = CONSUMER`: the failed entry and everything
after it are read again, in order. The host re-posts nothing.

**Flush.** `CONTROL.flush` drops every entry not yet on the wire:
`CONSUMER = FETCH = PRODUCER`, reserved and committed slots are dropped, and
a head slot whose readout had started but whose first beat had not gone out is
aborted (its RAM responses are drained, from both segments). A slot with beats
on the wire finishes. The flush is carried out once no read is in flight; until then
`STATUS.pending` is set and no new slot starts, and an entry posted meanwhile
is flushed too - so the host waits for `pending` to clear. It costs the round
in progress nothing: an entry that was not sent is simply not counted, and
`ssr_tx_engine` admits a fragment only on the cycle it takes the slot's first
beat, so a flush cannot pull a slot out from under a header already composed
for it. (Before count acks a flush could break the round's announcement.)

**Tests.** `tb_ssr_proposal_ring` (the two modules against a ring and a read
engine that completes out of order): doorbell, wrap, reads in flight, one beat
per cycle, back pressure, error and rewind, flush in its three cases, with a
negative control for each. `tb_ssr_dataplane`'s transmit monitor checks,
every round, that fragments are numbered 0, 1, 2 ... within the budget, that
the next control frame's `ack[self]` is how many went out, and that no SSR
frame has a gap; B7 posts a backlog of eight just after the cutoff and checks
that nothing more starts in that round, then five, then three. Making the
buffer read one beat at a time again fails B7 (fewer than five in the round,
and gaps), which is the defect this replaced.

## 14. On the AU200

Everything above runs on the board's own parameters now
(`docs/au200_parameters.md` has the derivation and the list of what changed):

- **Two beats a RAM row.** The DMA RAM follows the PCIe width: two 512-bit
  segments, a 1024-bit row. A beat is one segment - beat k of a slot is
  segment k % 2 of row k / 2 - so every SSR RAM port reads or writes one
  segment per beat, and the host-visible layout (a 4 KiB slot, 64 beats,
  header in beat 0) did not change.
- **One interface of two.** The app block's streams are two lanes wide.
  `SSR_IF_INDEX` (a localparam in `mqnic_app_block_ssr_dataplane.v`,
  default 0) picks SSR's; the other is wired straight through and stays a
  normal NIC port. `tb_ssr_dataplane` checks that lane every cycle.
- **Time from the ToD.** The core reads seconds and nanoseconds from
  `ptp_sync_ts_tod` (96 bits); the interface timestamps are 48 bits, so
  `TX_CPL_TS_2` reads 0.
- **Tags and ram_sel.** 13-bit app DMA tags: pages 0..15 on the data DMA,
  the verdict 0 on the control DMA. `ram_sel` is 1 bit and always 0: each
  path's RAM read port has one reader, so there is nothing to select.
- **The verdict on the control DMA.** Corundum merges the control and data
  paths into the one PCIe engine with control first, so a record no longer
  waits behind the NIC's own packet writes (§5.2). This removed the wrapper's
  descriptor mux and `dma_ram_demux_rd`.
- **The build.** `fpga/config.tcl` turns on the app DMA and the interface
  streams, which it had off.
- **SSR's transmit tag is `0x4000`.** Corundum tags every host frame with the
  top bit set and ignores completions without it, so SSR must leave the top bit
  clear; `ssr_tx_mux` consumes only completions tagged exactly `0x4000`. (It
  used the top bit before, which swallowed the host's completions on SSR's
  port.)
