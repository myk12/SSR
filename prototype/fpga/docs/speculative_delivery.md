# Speculative Delivery: Payload to Host Memory Before the Verdict

> Module and file names in this record predate the `ssr_` prefix; `commit_path.md` §0 maps them to today's.

**Status:** design record. **Implemented, and superseded in part by
`docs/count_ack.md`** (count acks): the announcement (`frag_count` on the
wire), the 1-bit row and the present set as "node k's whole proposal arrived"
are gone, and with them the four-quadrant host contract of §2.2 and §7. The
record layout is unchanged, but `frag_count[k]` is now the committed prefix of
node k, `present_set[k]` means only "no DMA error for this host's copy", and
`commit_set` is the sound set after the decision and does not gate reads: the
host reads pages `0 .. frag_count[k]−1` where `present_set[k]`
(`docs/commit_path.md` §8). The tracker of §3.2 keeps per-node prefix counts,
not present bits. See `docs/commit_path.md`, the wiring record, which is
authoritative where the two disagree. The build also deviated from this text
in four places:

* **A frame is a page.** `SSR_FRAME_BYTES = 4096` = 64 B header + 4032 B
  payload, and the header rides on top of the page it arrived in. There is no
  separate header page (§2.1.2), no second descriptor per fragment, and
  `frag_idx` (an index) replaced `frag_off` (bytes); `total_len` became
  `frag_count` and then, with count acks, went from the wire altogether.
* **`payload_stage` releases a slot on DMA completion, not on pop** — the
  engine reads the RAM after accepting the descriptor (§3.1).
* **The verdict record** carries `seq` (8 B), `self_index` and
  `frag_count[0..7]` instead of `stride` and `length[0..7]` (§2.2, §9); it is a
  register, not a RAM, answered straight onto the engine's read port.
* **No TDMA and no transmit window** anywhere in the timing (see
  `docs/round_structure.md`'s own status note).

**Orthogonal to:** `docs/round_structure.md` (the control-period / payload-period
split). The two can land in either order; neither depends on the other.
**Supersedes:** the on-chip store-until-verdict path — `commit_assembler`'s
`store_self` / `store_peers` / emit FSM, and `commit_buffer`'s 64 KiB payload
RAM.

Today a peer's payload lands in FPGA block RAM, waits for the consensus verdict,
and is only then assembled into a slot and DMA'd to the host. This document
replaces that with:

* peer payload is **DMA'd to host memory as it arrives**, before anyone knows
  whether the round commits;
* the verdict is a **64-byte completion record pushed to a host-memory queue**,
  written only after the payload it describes is known to have landed;
* the host reads the completion queue out of its own DRAM and, on seeing round
  R committed, reads payload it already has.

```text
                    ┌──────────── today ─────────────┐
 rx_engine ─► commit_assembler ─► commit_buffer ─► commit_dma_writer ─► host
              (depth·N·P on chip)   (64 KiB)         (after the verdict)

                    ┌────────── proposed ────────────┐
            ┌► payload_stage ─► payload_dma_writer ─────────────► host payload ring
 rx_engine ─┤   (8 frames, 64 KiB    (as frames arrive)                  ▲
            │    fixed - MTU-sized)                                      │
            │                                                            │ fence
            └► presence_tracker ─► consensus_core ─► verdict_dma ─────────┘
                  (~68 bits)                          (64 B, after the fence)
```

Sections 1–3 are the case. Sections 4–7 are the mechanism, including the one
correctness hazard that this design introduces. Sections 8–11 are the RTL change
list. Section 12 is the test plan.

---

## 1. Why

### 1.1 On-chip memory stops scaling with `P`

`commit_assembler` holds `P_ROUND_DEPTH × N × P_PAYLOAD_STRIDE` bytes, and
`commit_buffer` holds another `SSR_COMMIT_SLOT_BYTES × SSR_COMMIT_SLOT_COUNT`.
Both scale with the payload size, and the payload size is exactly the knob
`docs/round_structure.md` §5 says we want to turn up.

| `P` | assembler | `commit_buffer` | total today | proposed staging | ratio |
|---:|---:|---:|---:|---:|---:|
| 1 KiB   | 12 KiB    | 64 KiB | 76 KiB    | 64 KiB | 1.2× |
| 8 KiB   | 96 KiB    | 64 KiB | 160 KiB   | 64 KiB | 2.5× |
| 32 KiB  | 384 KiB   | 64 KiB | 448 KiB   | 64 KiB | 7.0× |
| 128 KiB | 1 536 KiB | 64 KiB | 1 600 KiB | 64 KiB | 25× |
| 256 KiB | 3 MiB     | 64 KiB | *will not fit* | 64 KiB | — |

The proposed column does not move, which is the entire point: it is 64 KiB at
every payload size, the same as today's `commit_buffer` alone.

**Be honest about what this is.** It is not "zero on-chip storage". Corundum's
DMA write engine (`dma_if_pcie_us`) is given a descriptor naming a *segmented
on-chip RAM* (`ram_sel` + `ram_addr`) and reads the bytes out of it; there is no
path that streams AXI-Stream beats straight into a PCIe TLP. So a staging RAM is
unavoidable.

What changes is what **sizes** it. Today it is sized by `P_ROUND_DEPTH × N` —
by how long the protocol has to hold data. In the proposed design it is sized by
the **MTU and the DMA turnaround** — by how big one frame can be and how long
PCIe takes to drain it — which is a constant, and grows with neither the round
depth, the node count, nor the payload size. §2.1.1 is what makes that true.

### 1.2 There is a hard elaboration wall today, and it is closer than §11.6 said

`ssr_dataplane.v` computes:

```verilog
localparam integer SSR_COMMIT_USED_BYTES = 64 + P_NODE_COUNT*P_COMMIT_PAYLOAD_STRIDE;
localparam integer SSR_COMMIT_SLOT_BYTES = 1 << $clog2(SSR_COMMIT_USED_BYTES);
localparam integer SSR_COMMIT_SLOT_COUNT = (1 << RAM_ADDR_WIDTH) / SSR_COMMIT_SLOT_BYTES;
// and then: if (SSR_COMMIT_SLOT_COUNT < 2) $error(...); $finish;
```

The commit RAM is one `RAM_SEL`'s entire 16-bit address space — 64 KiB — and the
slot must be a power of two, so the rounding up to a power of two wastes almost
half of it. The largest stride that still elaborates is:

| `N` | max `P_COMMIT_PAYLOAD_STRIDE` | |
|---:|---:|---|
| 3 | 10 901 B | **10.65 KiB** |
| 5 | 6 540 B | 6.39 KiB |
| 8 | 4 088 B | 3.99 KiB |

Above that, `SSR_COMMIT_SLOT_COUNT` reaches 1 or 0 and the build **fails to
elaborate**. `docs/round_structure.md` §11.6 said the U200's sweet spot was
"8–16 KiB, limited by PCIe Gen3 ×16". That was optimistic in one direction and
pessimistic in another: the PCIe limit is real but avoidable (§1.3), and the
elaboration wall at 10.65 KiB is a harder stop that arrives sooner. Both of
§11.5 and §11.6 need correcting once this design lands.

### 1.3 PCIe: the upstream direction stops being the bottleneck

`commit_dma_writer` sends the **whole commit slot** to the host — header plus
one region per node, `SSR_COMMIT_USED_BYTES = 64 + N·P`. That includes *our own*
payload, which the host handed us through the proposal path minutes of
nanoseconds earlier. We DMA it back.

Under speculative delivery our own payload never enters the RX path at all —
there is no store, so `tx_engine`'s local echo has nothing to write and the
bytes are simply never sent host-ward. Upstream traffic drops from `N·P` to
`(N−1)·P` per round, a 1/N saving that is free rather than engineered.

It matters more than 1/N looks, because PCIe is full duplex and the two
directions carry different things:

* **host → device (downstream):** the proposal fetch, `P` bytes per round.
* **device → host (upstream):** peer payload, `(N−1)·P` bytes per round.

Each direction gets its own ~13 GB/s on Gen3 ×16. With `N = 3`, `T_prop = 250 ns`
and the round lengths from `docs/round_structure.md` §5:

| `P` | round | committed | old upstream `N·P` | new upstream `(N−1)·P` | new downstream `P` |
|---:|---:|---:|---|---|---|
| 4 KiB | 1.37 µs | 9.00 GB/s | 9.05 ✅ | 6.05 ✅ | 3.00 ✅ |
| 8 KiB | 2.02 µs | 12.16 GB/s | 12.19 ✅ | 8.14 ✅ | 4.05 ✅ |
| 16 KiB | 3.33 µs | 14.75 GB/s | 14.77 ❌ | 9.85 ✅ | 4.92 ✅ |
| 32 KiB | 5.95 µs | 16.51 GB/s | 16.52 ❌ | 11.02 ✅ | 5.50 ✅ |
| 128 KiB | 21.68 µs | 18.14 GB/s | 18.14 ❌ | 12.09 ✅ | 6.05 ✅ |

The old column runs out of PCIe at 16 KiB. The new one has headroom all the way
to 128 KiB, at which point the binding constraint is the Ethernet-side ceiling
`N/(N−1)·R/8 = 18.75 GB/s` — the protocol's own limit, which is where we want
the bottleneck to be.

### 1.4 The bulk transfer leaves the critical path

Today the order is: payload lands on chip → wait for the verdict → assemble →
DMA `N·P` bytes → host can read. At `P = 8 KiB`, `N = 3` that last step is
24 KiB of PCIe, roughly 1.9 µs of transfer plus descriptor and completion
turnaround, **all of it after the verdict**.

Under speculative delivery the bulk transfer happens *during* the round, in
parallel with the protocol. What remains on the critical path after the verdict
is one 64-byte completion record. The protocol-level latency
(`2·Tc + Tp` from `docs/round_structure.md` §4) is unchanged; what shrinks is
the gap between "the FPGA decided" and "the application can read the bytes".

### 1.5 What this is, architecturally

The dataplane stops being a **store** and becomes a **sequencer**: it assigns
`round_id` from absolute time, frames and broadcasts, tracks who delivered, and
decides. The data lives at the endpoints and is confirmed after the fact.

This is the same structural move as in-network sequencing with endpoint
speculation — Speculative Paxos (NSDI'15), NOPaxos (OSDI'16), Eris (SOSP'17).
SSR goes further than those: they need a designated sequencer node or switch,
whereas SSR's sequence number is a pure function of PTP time-of-day
(`round_id = sec·ROUNDS_PER_SECOND + ns/ROUND_LENGTH_NS`), so there is no
sequencer to elect, fail over, or bottleneck on.

**It is not a data bypass.** The dataplane still sees every payload byte,
because `present_set` — the single ack vector settled in
`docs/round_structure.md` §6 — means "this node's payload arrived *whole*", and
only a module that counts the beats and checks `tlast` against `length` can say
that. The dataplane still needs line-rate *throughput*; it no longer needs
*capacity*. That distinction is the whole design.

---

## 2. Host memory layout

Two separate host-memory regions, both device-written, both plain DMA targets.

### 2.1 The payload ring

A flat array of `D_HOST` slots, each `N × P` bytes, at a host-physical base the
driver programs:

```text
payload_ring_base
 ├─ slot (R   mod D_HOST) ─┬─ node 0 region   P bytes
 │                         ├─ node 1 region   P bytes
 │                         └─ node 2 region   P bytes
 ├─ slot (R+1 mod D_HOST) ─┬─ ...
```

```text
host_addr(R, k, frag_off) = payload_ring_base
                          + (R mod D_HOST) · SLOT      // SLOT   = N · REGION
                          + k              · REGION    // REGION = 1 << clog2(4096 + P)
                          + 4096 + frag_off            // one header page at the top
```

`R`, `k` and `frag_off` all come straight out of the SSR frame header
(`SSR_OFF_ROUND_ID`, `SSR_OFF_NODE_ID`, `SSR_OFF_FRAG_OFF`), so the address is
computable at the frame's first beat. Nothing has to be buffered to know where
it goes.

**`REGION` is rounded up to a power of two; `SLOT` is not.** `k · REGION` is a
shift. `(R mod D) · SLOT` would also be a shift if `SLOT` were rounded up, but
`N` is a small elaboration constant, so `N · REGION` is a shift plus a couple of
adds — at `N = 3`, `x·(3·2^17) = (x + (x<<1)) << 17`. Rounding `SLOT` up instead
would waste 25 % of the ring at `N = 3` (128 MiB instead of 96 MiB at
`D_HOST = 256`, `P = 64 KiB`) to save two adders. Host DRAM is plentiful, but
not free enough to spend a quarter of it on that.

**Each region begins with the frame's own 64-byte header**, in a page of its
own, so a node's region is a self-describing record *and* every payload
fragment is page-aligned (§2.1.2):

```text
region for (R, k):
    page 0        [64 B SSR header][4 032 B unused]
                   node_id, run_id, round_id, length, total_len, frag_off
    page 1..n     payload, one fragment per page
```

That header is not composed — it is the header off the wire, staged rather than
discarded. Only fragment 0 delivers it. The host can therefore read a node's
payload without consulting anything else, and the verdict record only has to add
the one thing the header cannot know yet: whether the round committed.

### 2.1.1 A round's payload is many frames

A node's payload for one round is larger than any Ethernet frame can carry —
62.5 KB at 50 Gbps for 10 µs, against a 9 KB jumbo MTU — so it goes out as
several frames carrying the same `round_id` and `node_id`:

| P per node per round | frames at `SSR_FRAG_BYTES` = 4096 |
|---:|---:|
| 8 KiB | 2 |
| 64 KiB | 16 |
| 128 KiB | 32 |
| 256 KiB | 64 — the `SSR_MAX_FRAGS` ceiling |

Three header fields carry it (`ssr_packet.vh`):

```verilog
localparam integer SSR_OFF_LENGTH    = 28;   // 2 B — THIS fragment's payload
localparam integer SSR_OFF_TOTAL_LEN = 32;   // 4 B — this node's whole round
localparam integer SSR_OFF_FRAG_OFF  = 36;   // 4 B — where this fragment starts
localparam integer SSR_FRAG_BYTES    = 4096; // power of two, so frag_off is a shift
```

**Why 4096.** Two costs pull against each other: 88 bytes of wire overhead per
frame favours big fragments, while `PAY_ADMIT_MARGIN_NS` — one whole frame time
of dead air at the end of every round — favours small ones. Balancing them:

```text
SSR_FRAG_BYTES* = sqrt( 88 · (N−1) · total_len )  =  3396 at N=3, 64 KiB
```

4096 is the power of two beside it. Against 8192 it halves the admission margin
(335 ns instead of 663, which is a third of a 2 µs round); against 1024 it cuts
the DMA descriptor rate from 10.4 M/s to 2.7 M/s and lifts the `SSR_MAX_FRAGS`
ceiling from 64 KiB to 256 KiB per node per round. The optimum grows as
`sqrt(N−1)`, so a bigger cluster wants a bigger fragment — an elaboration
constant, so a re-synthesis rather than a redesign.

It is also exactly one OS page, which §2.1.2 makes load-bearing rather than a
coincidence. The frame is 4 160 bytes, so the fabric needs an MTU of about
4 200 — note that *any* fragment above ~1 436 B needs a non-default MTU, because
our header is 64 B, so the real choice is "standard 1500" or "some jumbo value"
and 4 200 is a mild one. The testbed's Tofino2 is cut-through, so the frame does
not add its own serialisation to `T_prop`; on a store-and-forward switch it
would add 335 ns at 100G.

`present_set[k]` becomes "every fragment of `total_len` arrived". One lost
fragment costs that node the round, which is the same fail-fast rule as a single
lost frame (§7). With `total_len == length` this degenerates to the single-frame
case with no special casing.

### 2.1.2 One fragment is one page, and the layout has to respect that

`SSR_FRAG_BYTES = 4096` is exactly an OS page. That is worth keeping, and the
layout in §2.1 as first written **throws it away**: with the 64-byte header at
the top of the region, payload lands at `64 + k·4096`, so every fragment
straddles a page boundary instead of filling one.

What page alignment is worth here:

* **IOMMU.** A 4 KiB write inside one page touches one translation; the same
  write straddling two touches two. It doubles the IOTLB working set of the
  payload ring for nothing.
* **Zero-copy onward.** A page-aligned fragment can be handed to anything that
  works in pages — `mmap` to another process, an io_uring registered buffer, a
  GPU or RDMA region. This tree already routes a second ethertype (`0x88B6`) to
  a separate DMA application, so "the payload goes somewhere else next" is not
  hypothetical.

The fix is to give the header its own page:

```text
region for (R, k):
    page 0        [64 B SSR header][4 032 B unused]
    page 1..n     payload, one fragment per page, every one page-aligned

host_addr(R, k, frag_off) = payload_ring_base
                          + (R mod D_HOST) · SLOT
                          + k              · REGION
                          + 4096 + frag_off
```

**The wasted 4 032 bytes cost nothing.** `REGION` is rounded up to a power of
two, and `total_len` is itself a power of two at least as large as one
fragment, so `4096 + total_len` and `64 + total_len` round to the *same* power
of two for every size we can configure. The header page is free.

What it does cost is **one extra descriptor per (round, node)**: fragment 0's
header and its payload are adjacent in the staging slot but no longer adjacent
in host memory, so they need separate descriptors. At `N = 3` that is two extra
descriptors per round, about 0.17 M/s on top of 2.7 M/s. The tag pool already
handles several descriptors per round slot, so the fence needs no change.

**`payload_stage` sequences the two itself** rather than pushing the knowledge
outward. Its head presents the header descriptor first, then the payload
descriptor, and only the second pop releases the slot:

```verilog
wire head_need_hdr = stage_frag0[head_ptr_reg] && !hdr_done_reg;

assign o_head_is_hdr     = head_need_hdr;
assign o_head_addr       = head_slot_base + (head_need_hdr ? 0 : 64);
assign o_head_len        = head_need_hdr ? 64 : stage_len[head_ptr_reg];
assign o_head_region_off = head_need_hdr ? 0  : stage_reg_off[head_ptr_reg];

wire slot_release = pop_fire && !head_need_hdr;   // only the last one frees it
```

`payload_dma_writer` just pops descriptors and never learns that a page layout
exists. *(Implemented — `make tb_pay_stage`, 83 checks, eight one-sided negative
controls including reverting to the packed 64-byte layout.)*

The alternative was to drop the in-region header entirely and let the verdict
record be the only description. Simpler still, and the host has to read the
verdict record anyway before it may touch a region (§7) — but it gives up being
able to dump the ring and read it, and being able to interpret payload at all if
the completion queue is ever lost or desynced. The header page keeps both for
the price of one descriptor.

Worked geometry at `N = 3`, one fragment per page:

| `P_total` | frags | `REGION` | `SLOT = N·REGION` | pinned at `D_HOST = 256` |
|---:|---:|---:|---:|---:|
| 8 KiB | 2 | 16 KiB | 48 KiB | 12 MiB |
| 32 KiB | 8 | 64 KiB | 192 KiB | 48 MiB |
| **64 KiB** | **16** | **128 KiB** | **384 KiB** | **96 MiB** |
| 256 KiB | 64 | 512 KiB | 1.5 MiB | 384 MiB |

`D_HOST` is a host-memory depth, so it can be 256 or 1024 rather than the 8 we
can afford on chip. That incidentally retires the "unsafe wrap" hazard
documented in `docs/rx_datapath.md` §10: a round's region cannot be overwritten
underneath a reader when there are a thousand rounds of margin.

**Our own region (`k == P_NODE_ID`) is never written.** It is left untouched;
see §6 for how the host finds its own proposal instead.

### 2.2 The verdict completion queue

A ring of 64-byte records — the existing `ssr_commit.vh` commit header, byte for
byte, with the payload regions removed:

```verilog
localparam integer SSRC_OFF_ROUND_ID    = 0;    // 8 B
localparam integer SSRC_OFF_RUN_ID      = 8;    // 4 B
localparam integer SSRC_OFF_COMMIT_SET  = 12;   // 1 B
localparam integer SSRC_OFF_NODE_COUNT  = 13;   // 1 B
localparam integer SSRC_OFF_STRIDE      = 14;   // 2 B
localparam integer SSRC_OFF_LENGTHS     = 16;   // 2 B per node, node k at +2k
localparam integer SSRC_OFF_PRESENT_SET = 32;   // 1 B
localparam integer SSRC_OFF_RESERVED    = 33;   // 31 B
localparam integer SSRC_OFF_PAYLOAD     = 64;   // <-- no longer a payload, just the record size
```

One record is one 64-byte cacheline-aligned write. The four-quadrant contract in
`ssr_commit.vh`'s header comment carries over **unchanged**, and is now the sole
authority on what the host may read:

| | meaning |
|---|---|
| `commit_set[k] & present_set[k]` | node k's region in the payload ring is valid — read it |
| `commit_set[k] & ~present_set[k]` | decided in, but the bytes never arrived whole — count the loss, **do not read** |
| `~commit_set[k] & present_set[k]` | bytes arrived for a round that did not include k — **do not read** |
| `length[k] == 0`, `commit_set[k]` set | committed, proposed nothing |

Two fields get new meaning in the reserved region:

```verilog
localparam integer SSRC_OFF_SEQ         = 33;   // 4 B, monotonically increasing record sequence
localparam integer SSRC_OFF_SELF_INDEX  = 37;   // 4 B, proposal batch index consumed this round (§6)
```

`SSRC_OFF_SEQ` is what the host polls on (§5).

### 2.3 Why two regions and not one

Keeping payload and verdict in separate rings is what makes §4's ordering fence
expressible at all. If the verdict were a header at the front of the payload
slot, "write the header only after the payload has landed" would mean a
back-write into a region the device has already moved past, and the host would
have no way to distinguish "header not written yet" from "header is zero".
Separate rings with a monotone sequence number in the verdict record make the
handshake explicit.

---

## 3. What stays on chip

### 3.1 The payload staging ring

A ring of whole frames, written by `rx_engine`'s beat stream and drained by the
DMA write engine.

```text
depth  PAY_SLOT_COUNT = 8
slot   64 + SSR_FRAG_BYTES bytes, rounded up to a power of two = 8 KiB
total  64 KiB, and it is a CONSTANT
```

**The slot is sized by the MTU, never by `P`.** That is what §2.1.1 buys: a
512 KiB round payload and an 8 KiB one stage identically, because both arrive as
frames bounded by `SSR_FRAG_BYTES`. On-chip storage is therefore independent of
the round depth, the node count *and* the payload size — it is set by the MTU
and the DMA turnaround, and by nothing else.

Eight is a double-buffering depth, not a protocol depth: a 4 160-byte frame is
~335 ns on a 100G wire and PCIe turnaround is 1–2 µs, so up to six frames can be
in flight and eight leaves margin.

Beat 0 of every slot is the frame header (§2.1), so a fragment's payload gets
one beat fewer than the slot holds.

Frames on one RX port are **serialised by the MAC**, never interleaved, so a
ring of frame-sized slots written sequentially is sufficient. This is
structurally the same object as today's `commit_buffer`, and the implementation
should be a re-parameterised copy of it plus per-slot metadata (§8.2).

Block RAM, not LUT RAM; the `ram_style = "distributed"` special case for
`store_self` in `commit_assembler` disappears along with the module. 64 KiB is
about 0.7 % of the U200's block RAM — the same size as today's `commit_buffer`,
so the net BRAM change is zero — and it does not move when `P` does.

### 3.2 The presence tracker

Everything that survives from `commit_assembler` is metadata:

```verilog
reg [63:0] slot_round_id [0:P_ROUND_DEPTH-1];
reg        slot_valid    [0:P_ROUND_DEPTH-1];
reg [7:0]  slot_present  [0:P_ROUND_DEPTH-1];
reg [15:0] slot_len      [0:P_ROUND_DEPTH*SSRC_MAX_NODES-1];
reg [7:0]  slot_taken;
```

At `P_ROUND_DEPTH = 4`, `N = 3` that is a few hundred flip-flops. The two
payload memories, `self_addr`, `peer_addr`, `peer_index`, and the whole
`E_IDLE / E_HDR / E_FETCH / E_BEAT / E_PAD` emit FSM are deleted.

Note the pleasant coincidence: these are exactly the registers
`docs/round_structure.md` §11.1 wanted to expose through a query port so the
core could use `slot_present` as its ack vector. In this design they stop being
a side-channel of a storage module and become the module's entire purpose.

---

## 4. The ordering fence

**This is the one new correctness hazard the design introduces, and it is the
part most likely to be got wrong.**

The payload writes and the verdict write are separate PCIe posted writes. They
may carry different tags, take different paths through the DMA engine, and
complete out of order. If the verdict record for round R becomes visible to the
host before all of round R's payload writes have landed, the host reads a
region that is still being written — or still holds round `R − D_HOST`'s bytes.

The failure mode is nasty in exactly the way that matters: it never reproduces
at low load, because at low load the payload write has long since drained before
the verdict is issued. It appears only when the DMA engine is queued, which is
precisely the regime the whole design exists to enter.

### 4.1 The rule

> A verdict record for round R may not be issued until every payload descriptor
> for round R has reported completion.

Not "has been issued" — **has reported completion**, i.e.
`s_axis_dma_write_desc_status_valid` has come back with that descriptor's tag.
Corundum's write status means the data has been accepted by the PCIe hard block
in order, which is the ordering point we need.

### 4.2 Why this does not exist today, and has to be built

From the current `commit_dma_writer`:

```verilog
wire dma_write_status_match = s_axis_dma_write_desc_status_valid
                           && s_axis_dma_write_desc_status_tag == DMA_TAG_COMMIT_VALUE;
```

`DMA_TAG_COMMIT_VALUE` is a **constant** (parameter `DMA_TAG_COMMIT`, default 0)
used for every descriptor. The module's own source flags this:

```verilog
dma_write_desc_tag_next = DMA_TAG_COMMIT_VALUE; // TODO: use a unique tag for each write to avoid confusion with other DMA writes
```

It works today only because the FSM is strictly serial —
`STATE_ISSUE_DMA → STATE_WAIT_DMA → STATE_POP_SLOT` — so there is never more
than one descriptor outstanding. There is no tag table, no outstanding counter,
and no notion of "a unit of work spanning several descriptors". All three have
to be built.

### 4.3 The mechanism

Per-descriptor tags, allocated from a small free list:

```text
DMA_TAG_WIDTH = 16, so there is plenty of tag space.

tag layout:  [15]  = 0 payload / 1 verdict
             [7:0] = descriptor id, index into the outstanding table
```

An outstanding table indexed by descriptor id, plus a per-round counter:

```verilog
reg [ROUND_SEL_BITS-1:0] out_rsel  [0:MAX_OUTSTANDING-1];  // which round this descriptor serves
reg                      out_busy  [0:MAX_OUTSTANDING-1];
reg [3:0]                pay_outstanding [0:P_ROUND_DEPTH-1];   // descriptors still in flight for this round
```

* issuing a payload descriptor for round R: allocate an id, set
  `out_rsel[id] = rsel(R)`, `out_busy[id] = 1`, `pay_outstanding[rsel]++`.
* completion with tag `id`: `pay_outstanding[out_rsel[id]]--`,
  `out_busy[id] = 0`.
* the verdict for round R may be issued when
  `pay_outstanding[rsel(R)] == 0 && verdict_pending[rsel(R)]`.

`MAX_OUTSTANDING` only needs to cover `N−1` frames plus a little slack; 8 is
generous and makes the table a trivial distributed-RAM array.

### 4.4 What happens when a payload write errors

`s_axis_dma_write_desc_status_error != 0` on a payload descriptor means those
bytes are not in host memory. The round is not wrong, it is *incomplete*, and
the design already has the vocabulary for that: **clear that node's
`slot_present` bit** before the verdict is issued. The host then sees
`commit_set[k] & ~present_set[k]`, counts a loss, and does not read the region —
exactly the contract in §2.2.

This is better than the current behaviour, which on a DMA error declines to pop
the commit slot and silently re-idles through `STATE_ERROR` with no way out.

Note the ordering subtlety: the error is discovered at *completion* time, which
by §4.1 is before the verdict is issued. The fence is what makes this fix
possible at all.

### 4.5 What we deliberately do not do

No footer/magic-value trick — "write the payload, then write a sentinel at the
end of the region and let the host spin on it" — because it relies on PCIe write
ordering within a region that the host may be reading with different cache
behaviour, and because a sentinel value is indistinguishable from payload that
happens to contain that value. The completion fence costs a few hundred
nanoseconds and is unambiguous.

---

## 5. Push, do not poll

The original sketch had the host poll a dataplane register holding the current
committed round. That register would be read over PCIe as an MMIO read, which is
a **round trip**:

| | latency |
|---|---|
| PCIe MMIO read (host → device → host) | ~1 000–2 000 ns |
| host DRAM read of a line a DMA write just invalidated | ~80–200 ns |

MMIO reads also do not pipeline — the CPU stalls on each one — and a tight poll
loop burns a core issuing them. At a 2 µs round, a 1–2 µs poll is most of a
round; the latency saved in §1.4 would be handed straight back.

So the verdict is **pushed**. This is not a novel arrangement: it is exactly how
Corundum's own `mqnic` driver learns about completed packets — a completion
queue in host memory, never an MMIO read per packet.

The host-side loop:

```c
for (;;) {
    volatile struct ssr_verdict *v = &cq[head & (CQ_DEPTH - 1)];
    uint32_t seq = READ_ONCE(v->seq);
    if (seq != expected_seq) { cpu_relax(); continue; }   /* DRAM read, cheap */
    smp_rmb();                       /* do not hoist the payload reads above this */
    process(v);                      /* payload is already in our memory */
    head++; expected_seq++;
}
```

`seq` (`SSRC_OFF_SEQ`) rather than a valid flag, so a stale record from a
previous wrap cannot be mistaken for a fresh one.

A device register holding the current round is still worth keeping for
**debug and bring-up** — it is how the bench and a human check liveness — but it
must not be on the host's steady-state path.

---

## 6. How the host finds its own payload

Our own region in the payload ring is never written, so the host has to locate
its own proposal for round R somewhere else. It already has it: the proposal it
submitted lives in its own proposal batch buffer at
`prop_base + n·prop_stride`, where `n` is the batch entry index.

What is missing is the map from round R to entry `n`. `proposal_dma_reader`
exposes `REG_DMA_ACTIVE_INDEX` (0x120), but that is a live counter, not a
per-round record, and nothing in the path today ties a round number to a
proposal entry.

Two options, and the doc should ship the first with the second as hardening:

### 6.1 Derive it (zero hardware cost)

`proposal_buffer` pops in FIFO order and `tx_engine` consumes exactly one slot
per payload frame — and only when the buffer is non-empty, in which case
`length[P_NODE_ID] != 0` in the verdict record. So the host can walk the
completion queue in order and maintain its own cursor:

```c
if (v->length[self] != 0)
    my_proposal = prop_base + (n++) * prop_stride;
```

This is correct as long as the host processes every verdict record in sequence,
which it must do anyway to use `seq`. Cost: nothing.

### 6.2 Carry it explicitly (hardening)

Put the consumed proposal index in the verdict record at `SSRC_OFF_SELF_INDEX`.
The plumbing is: `proposal_buffer` exports `head_ptr_reg` alongside
`buf_rd_valid`; `tx_engine` latches it at `start_accepted` and emits it with the
local echo (`o_local_prop_index` beside the existing `o_local_round_id`); the
presence tracker stores it per round and the verdict DMA writes it out.

Roughly 20 lines, and it makes the host's bookkeeping stateless. Worth doing
once §6.1 has proved the rest of the design, not before — it is the kind of
plumbing that is easy to add later and annoying to debug while everything else
is also new.

---

## 7. What the host must never do

Speculative delivery means host memory legitimately contains bytes from rounds
that did not commit, and from nodes that turned out not to be sound. The
contract is one sentence:

> A region of the payload ring may be read only after a verdict record naming
> that round has been consumed, and only for nodes with both `commit_set[k]` and
> `present_set[k]` set.

Regions for aborted rounds are never cleaned up; they are overwritten `D_HOST`
rounds later. There is no cost to leaving them, and zeroing them would be
`(N−1)·P` bytes of PCIe traffic to accomplish nothing.

One assumption to state plainly in the paper: **the dataplane writes host memory
on behalf of nodes that may later be judged unsound.** For a research prototype
on a trusted fabric this is fine; it is the same trust model as any NIC DMA-ing
received packets before the host has inspected them. It is worth a sentence in
the threat model rather than a silent assumption.

---

## 8. Module change list

### 8.1 `commit_assembler` → `presence_tracker`

| | |
|---|---|
| deleted | `store_self`, `store_peers`, `self_addr()`, `peer_addr()`, `peer_index()`, the `E_IDLE/E_HDR/E_FETCH/E_BEAT/E_PAD` FSM, `em_real`/`em_present` zero-fill, `hdr_bits` composition, `o_commit_data/be/valid/last` |
| kept | `slot_round_id`, `slot_valid`, `slot_present`, `slot_len`, `slot_taken`, the eviction rules, `o_evict_count`, `o_missing_count`, `o_oversize_count` |
| added | the present-set query port from `docs/round_structure.md` §11.1; a verdict record output (`o_vr_*`) instead of a slot stream; `i_pay_dma_done` / `i_pay_dma_error` from the payload DMA writer |

Roughly 60 % of the module is deleted. `o_pl_ready` stays tied high — there is
still exactly one writer to the metadata, and now no memory to arbitrate for.

Note `o_busy_count` ("a verdict arrived while still emitting") loses its meaning
and should be removed; the equivalent hazard is now "a verdict is fenced waiting
on payload completions", which deserves its own counter (§9).

### 8.2 `commit_buffer` → `payload_stage`

Keep the structure, change the contents. It is already a ring of fixed-size
slots in a `dma_psdpram` with head/tail pointers and a `head_slot_*` /
`commit_in_*` handshake; that is exactly what is needed.

Changes:

* `COMMIT_SLOT_BYTES` → `1 << $clog2(64 + SSR_FRAG_BYTES)` = 16 KiB,
  `COMMIT_SLOT_COUNT` → 8. **Sized by the MTU, not by `P`.**
* Stage the 64-byte header as beat 0 of every slot, from a new `i_pl_hdr_data`
  input valid with `i_pl_sof`. Fragment 0's descriptor starts at the slot base
  and carries it; every later fragment starts one beat in and leaves it behind.
* Add per-slot metadata, which it currently has none of:
  ```verilog
  reg [63:0] stage_round_id [0:SLOTS-1];
  reg [7:0]  stage_node_id  [0:SLOTS-1];
  reg [15:0] stage_len      [0:SLOTS-1];   // header included iff fragment 0
  reg [31:0] stage_reg_off  [0:SLOTS-1];   // offset inside the node's host region
  reg        stage_frag0    [0:SLOTS-1];
  ```
  captured at `i_pl_sof`, exported alongside `head_slot_addr` so the DMA writer
  can compute the host address with shifts and one add.
* Remove the dead `dma_ram_rd_cmd_sel` input (declared, never referenced).
* `head_slot_len` should actually be honoured downstream this time — see 8.3.

### 8.3 `commit_dma_writer` → split in two

The current module is one serial FSM that does descriptor composition,
ping-pong buffer management, and completion handling. Under speculative delivery
those jobs separate.

**`payload_dma_writer`** (new): drains `payload_stage`, one descriptor per
frame, multiple outstanding.

```verilog
dma_addr = payload_ring_base
         + ((o_head_round_id & (D_HOST-1)) * SLOT_BYTES)  // N * REGION, a shift + adds
         + ( o_head_node_id               << REGION_SH)   // per-node region
         +   o_head_region_off;                           // 0, or 4096 + frag_off
ram_sel  = RAM_SEL_PAYLOAD;
ram_addr = o_head_addr;      // payload_stage already picked the right start
len      = o_head_len;       // honoured, not hardcoded
tag      = o_alloc_tag;      // from dma_tag_pool
```

Note there is no fragment-0 special case here. `payload_stage` presents the
header and payload as two successive head entries (§2.1.2), so the writer issues
one descriptor per pop and stops when `o_head_valid` drops.

`REGION` is a power of two so `node_id << REGION_SH` is a shift; `SLOT` is
`N · REGION`, which for a small compile-time `N` is that shift plus a couple of
adds (§2.1). `o_head_region_off` already folds in the header page and the
fragment offset, so the writer does no arithmetic on either -
`payload_stage` decided both at `i_pl_sof`.

The `× (N·P)` and `× P` multiplies want `N·P` and `P` to be powers of two so
they synthesise as shifts. `P` already must be a power of two
(`proposal_buffer` enforces it); `N·P` is not, so either round the host slot up
to `1 << $clog2(N·P)` (wasting `(2^⌈log2 N⌉ − N)/2^⌈log2 N⌉` of host memory,
which is free) or pay for a small multiplier. **Round it up** — host DRAM is the
one resource we have in abundance.

**`verdict_dma_writer`** (new, small): takes verdict records from the presence
tracker, applies the §4 fence, writes 64 bytes into the completion queue,
increments `seq`. Keeps the arm/capacity/ping-pong CSR model of today's
`commit_dma_writer` if that is convenient for the driver, but a plain ring with
a producer index is simpler and the records are tiny.

**Shared:** the outstanding-tag table of §4.3. Cleanest as its own little module
(`dma_tag_pool`) instantiated once and used by both writers, because the fence
needs to see completions from the payload side while the verdict side is the one
that waits.

### 8.4 `ssr_rx_demux`

The receive counterpart of `ssr_tx_mux`, and the only other place SSR touches
the interface's own datapath:

```text
ssr_tx_mux    {SSR, host} ──► port
ssr_rx_demux   port ──► {SSR, host}
```

One ethertype is taken for `rx_engine`; **everything else passes through to the
host untouched**. It replaced `consensus_rx_splitter`, which recognised a second
ethertype (`0x88B6`) as a second "application" and dropped what it did not know
— and since that second output was wired to `m_axis_if_rx`, the host path, a
plain ping to this interface was discarded at the app boundary with `tready`
held high, so nothing back-pressured and no counter moved.

The route is decided on the first beat and held to `tlast`. That was already
true and is now load-bearing: with fragmentation a frame is 65 beats, so 64 of
them depend on the latch — byte 12 of a header is an ethertype, byte 12 of a
payload row is payload. *(Built — `make tb_rx_demux`, 26 checks, six one-sided
negative controls.)*

### 8.5 `rx_engine`

Almost unchanged, which is the point. `o_pl_sof / o_pl_valid / o_pl_data /
o_pl_last / o_pl_commit / o_pl_drop` now fan out to two consumers instead of
one. Three signals are added: `o_pl_total_len` and `o_pl_frag_off` from the new
header fields, and `o_pl_hdr_data` - the raw header beat, which `rx_engine`
already holds during `S_HDR` and today simply discards. Passing it on costs one
register and is what makes each host region self-describing.

The two consumers: `payload_stage` takes the beats, `presence_tracker` takes the metadata and
the verdict. Both are always ready, so `o_pl_ready` stays tied high and
`RX_STALL_COUNT` should stay at zero.

### 8.5 `tx_engine`

The local echo (`o_local_sof / o_local_valid / o_local_data / o_local_last`)
loses its consumer for the data beats — nothing stores our own payload any more.

**Keep `o_local_sof`, `o_local_round_id`, `o_local_len`; delete
`o_local_valid`, `o_local_data`, `o_local_last`.** The presence tracker still
needs to know that *we* proposed in round R (to set `slot_present[P_NODE_ID]`
and `slot_len[R][P_NODE_ID]`), but it no longer needs the bytes.

That also finally retires `i_local_last`, which `docs/rx_datapath.md` §11 notes
is already an unused input kept only because `tb_tx_engine` checks it.

### 8.6 `ssr_dataplane`

* New `RAM_SEL_PAYLOAD` for the staging RAM; `RAM_SEL_COMMIT` is reused by the
  verdict queue, which now needs almost no address space.
* `SSR_COMMIT_USED_BYTES` becomes `SSRC_HDR_BYTES` (64). `SSR_COMMIT_SLOT_BYTES`
  and `SSR_COMMIT_SLOT_COUNT` and the `< 2` guard all go away — with them, the
  elaboration wall of §1.2.
* `P_COMMIT_PAYLOAD_STRIDE` keeps its name and meaning, but is no longer bounded
  by the commit RAM.

---

## 9. CSRs

Free offsets in `RBB_COMMON`: `0x088`, `0x08c`, `0x0a4`, `0x0b8` onward. Note
`docs/round_structure.md` §11.3 also claims `0x088`, `0x08c` and `0x0a4`; if both
designs land, the round-structure ones move to `0x0d0+`.

| offset | name | meaning |
|---|---|---|
| `0x0a4` | `ASM_PRESENT_SET` | live `slot_present` for the round being acked |
| `0x0b8` | `PAY_DESC_COUNT` | payload descriptors issued |
| `0x0bc` | `PAY_DESC_ERROR` | payload descriptors that completed with an error |
| `0x0c0` | `PAY_STAGE_FULL` | frames dropped because the staging ring was full |
| `0x0c4` | `VR_COUNT` | verdict records written |
| `0x0c8` | `VR_FENCE_WAIT` | cycles a verdict spent waiting on the fence |
| `0x0cc` | `VR_SEQ` | current sequence number (debug/bring-up only) |
| `0x0d0` | `CUR_COMMIT_ROUND_LO` | last committed round (debug/bring-up only, **not** the host's steady-state path — §5) |
| `0x0d4` | `CUR_COMMIT_ROUND_HI` | |

`PAY_STAGE_FULL` is the one to watch during bring-up: it is non-zero exactly
when PCIe cannot keep up with the wire, which is the failure this whole design
is trying to move the boundary of. It should be zero in every passing test and
its being non-zero should fail the regression, not warn.

`VR_FENCE_WAIT` measures how much §4's correctness costs. If it is large, the
tag pool is too small or `MAX_OUTSTANDING` needs raising.

New register block for the host rings, at `RBB_COMMIT_QUEUE` (0x002000), which
is currently entirely decoded inside `commit_dma_writer`:

| offset | name |
|---|---|
| `0x300` | `PAY_RING_BASE_LO` |
| `0x304` | `PAY_RING_BASE_HI` |
| `0x308` | `PAY_RING_DEPTH` (`D_HOST`, power of two) |
| `0x30c` | `PAY_RING_SLOT_BYTES` (RO, `1 << clog2(N·P)`) |
| `0x310` | `PAY_RING_NODE_STRIDE` (RO, `P`) |
| `0x314` | `PAY_RING_CONTROL` (bit0 arm) |
| `0x320` | `VR_CQ_BASE_LO` |
| `0x324` | `VR_CQ_BASE_HI` |
| `0x328` | `VR_CQ_DEPTH` |
| `0x32c` | `VR_CQ_CONTROL` (bit0 arm) |

Offsets `0x000–0x218` in that block are in use by the existing
`commit_dma_writer` map; `0x300+` is free.

---

## 10. Failure modes

| what | how it shows up | what the host does |
|---|---|---|
| peer's payload truncated on the wire | `i_pl_drop`, `slot_present[k]` clear | `commit_set[k] & ~present_set[k]` → count a loss |
| payload DMA completes with an error | `slot_present[k]` cleared at completion (§4.4) | same as above — indistinguishable to the host, correctly so |
| staging ring full | frame dropped, `PAY_STAGE_FULL++`, `slot_present[k]` clear | same as above; the counter is the real signal |
| verdict DMA error | `VR_CQ` gap: `seq` skips | host must treat a skipped `seq` as "that round's fate is unknown" and resynchronise from the debug register |
| round evicted before its verdict | `ASM_EVICT_COUNT++`, no verdict record | host's `seq` does not advance for that round; there is simply no record |

The fourth row is the only one without a clean answer, and it is worth being
explicit that it is a **reporting** gap, not a safety gap: the protocol has
already decided, and the sound set on every node is consistent. Only this host's
knowledge of the decision is lost. Recovery is to read the debug registers and
resync — the same control-plane path that handles an evicted node.

---

## 11. Latency accounting

For the record, since §1.4's claim should be checkable:

```text
verdict available in the FPGA          t = 0        (ctrl_end_pulse, or the round boundary)
fence satisfied                        t + F        F = time for the last payload completion
verdict descriptor issued              t + F + d    d = descriptor issue, tens of ns
64 B lands in host DRAM                t + F + d + W   W = one small PCIe write, ~300-600 ns
host's poll loop notices               + 80-200 ns  (DRAM read, §5)
```

`F` is zero in the common case — the payload writes for round R were issued
during round R and have long completed by the time the verdict exists at the end
of round R+1's control period. `F` is non-zero only when PCIe is backed up,
which is exactly when it *should* delay the verdict.

Compare with today: the verdict is followed by `N·P` bytes of PCIe, ~1.9 µs of
transfer at `P = 8 KiB` plus turnaround, and the host learns about it by
interrupt or by polling the commit-buffer completed count.

---

## 12. Test plan

`tb/ssr_dataplane/tb_ssr_dataplane.v` gains a host-memory model — it already has
one for the commit path (`SECTION 15`, the `cd_*` descriptor recorder and the
`slot_cap` readback) and the same shape extends: record every payload descriptor
and replay it into a sparse host-memory model, then check the model.

The bench's existing `cd_reset` bookkeeping discipline applies to the new
recorders too: an index rewound per test, a lifetime counter that is never
rewound, and every array read guarded by `k < n`.

### Group N — host address arithmetic

| test | stimulus | expectation |
|---|---|---|
| N1 | one peer frame, round R, node k | exactly one payload descriptor, `dma_addr == base + (R mod D)·slotB + k·P` |
| N2 | `N−1` peers in one round | `N−1` descriptors, addresses distinct and in the right regions |
| N3 | round `R + D_HOST` | wraps to the same slot as R |
| N4 | our own node | **no** descriptor is ever issued for `k == P_NODE_ID` |
| N5 | negative control: permute the node→offset map on both the write and the check side | must **fail**, or the test proves nothing |

N5 is the lesson from `docs/rx_datapath.md` §11: a bijective permutation applied
to both sides of an address check is invisible. The negative control has to be
one-sided.

### Group N2 — fragmentation

| test | stimulus | expectation |
|---|---|---|
| N2a | one node's round payload as three fragments | three descriptors; only the first carries the header; region offsets 0, 64+f1, 64+f2 |
| N2b | fragments of two nodes interleaved on the wire | each lands in its own region, undisturbed |
| N2c | the middle fragment dropped (`i_pl_drop`) | that node's `present_set` bit stays clear for the round |
| N2d | fragments arriving out of order | still land correctly - the address comes from `frag_off`, not arrival order |
| N2e | negative control: every fragment claims `frag_off == 0` | N2a must **fail** |
| N2f | negative control: `region_off` forced to 0 | N2a must **fail** - every fragment would overwrite the top of the region |

N2e and N2f are the ones that matter. A bug in either is invisible at
`total_len == length` - the single-fragment case every other test uses - and
silently corrupts every multi-fragment round. Both already exist as bench
negative controls on `payload_stage`; they move up to the integration bench
when the path is wired.

### Group O — the ordering fence

The highest-value group.

| test | stimulus | expectation |
|---|---|---|
| O1 | normal round | the verdict descriptor is issued strictly after the last payload completion for that round |
| O2 | `dma_latency` raised so payload completions lag past the verdict instant | the verdict is **held**, `VR_FENCE_WAIT` rises, ordering still holds |
| O3 | completions returned **out of order** (tag 2 before tag 1) | the fence still waits for both |
| O4 | payload completion returns an error | `present_set[k]` is clear in the verdict record that follows |
| O5 | negative control: remove the fence | O1 and O2 must **fail** |

O3 matters because the bench's current DMA model returns completions in issue
order. It has to be taught not to, or the fence is never actually exercised —
an in-order model would let a broken fence pass.

### Group P — staging ring pressure

| test | stimulus | expectation |
|---|---|---|
| P1 | `N−1` peers back to back at line rate, `dma_latency` nominal | `PAY_STAGE_FULL == 0`, `RX_STALL_COUNT == 0` |
| P2 | `dma_latency` raised until the ring fills | `PAY_STAGE_FULL` rises; the affected node's `present_set` bit is clear; **the node does not halt** |
| P3 | P2 sustained for 20 rounds, then relieved | recovers without a reboot |

P2 is the test that the design degrades the way §10 claims: PCIe falling behind
costs a node its round, not the protocol its safety.

### Group Q — the completion queue

| test | stimulus | expectation |
|---|---|---|
| Q1 | 50 rounds | `seq` increments by exactly 1 per record, no gaps |
| Q2 | CQ wraps | a stale record is never mistaken for fresh — the host model checks `seq`, not a valid bit |
| Q3 | record contents | `round_id`, `run_id`, `commit_set`, `present_set`, `length[]` match the core's and the tracker's state exactly |
| Q4 | an aborted round | **no** record is written, and `seq` does not advance |

### Existing groups

Group F (`test_F1_ring_address_sequence`, `test_F2_ping_pong`, the error tests)
targets `commit_dma_writer`'s buffer management. Those tests move to
`verdict_dma_writer` if it keeps the arm/capacity model, or are replaced by
Group Q if it moves to a plain producer-index ring. Decide that before writing
the RTL, because it determines whether Group F is edited or deleted.

---

## 13. Migration order

Each step should leave the regression green.

1. **`payload_stage`**: re-parameterise `commit_buffer` and add the per-slot
   metadata, instantiated but not yet wired to anything. Unit bench only.
   *(done - `rtl/payload_stage.v`, `tb/ssr_dataplane/tb_payload_stage.v`,
   `make tb_pay_stage`: 63 checks, 8 one-sided negative controls. Reshaped once,
   when fragmentation moved the slot size from `P` to the MTU.)*
2. **`dma_tag_pool`**: the outstanding-tag table of §4.3, standalone, with a
   unit bench that includes out-of-order completions. This is the piece with no
   precedent in the tree and it should exist before anything depends on it.
   *(done - `rtl/dma_tag_pool.v`, `tb/ssr_dataplane/tb_dma_tag_pool.v`,
   `make tb_tag_pool`)*
3. **`payload_dma_writer`**: address arithmetic and multi-outstanding issue,
   writing into the bench's host model. Add group N. Still in parallel with the
   old path — both run, only the old one is believed.
4. **`presence_tracker`**: strip `commit_assembler` down. Add the fence and the
   verdict record output. Add groups O and Q.
5. **Cut over**: delete the old `commit_assembler` store and
   `commit_dma_writer`'s payload path; `tx_engine` loses the local echo data
   beats. Add group P. Remove the `SSR_COMMIT_SLOT_COUNT < 2` guard and confirm
   `P = 32 KiB` now elaborates.
6. **Corrections**: `docs/round_structure.md` §11.5 and §11.6,
   `docs/rx_datapath.md` §10 and §11, and the CSR offset collision in §9.

Step 2 is the one to do carefully. Everything downstream assumes the fence is
correct, and a fence that is subtly wrong produces a bug that only appears under
load and looks like a peer problem.

---

## 14. Deliberately not solved here

* **Chunked DMA.** One descriptor per frame is enough because fragmentation
  already bounds a frame at `SSR_FRAG_BYTES`. Sub-frame chunking would shrink
  the staging ring further (a descriptor every 4 KiB puts it at
  `O(chunk × outstanding)` ≈ 64 KiB) but buys nothing the MTU has not already
  bought, and costs partial-frame bookkeeping.
* **An MTU below the fragment size.** `SSR_FRAG_BYTES = 8192` assumes jumbo. On
  a 1500-byte path it must drop to 1408 or so, which works but multiplies the
  frame count by six and with it the per-round descriptor count. The testbed is
  jumbo on a Tofino2, so this is a configuration note, not a design limit.
* **Reordered or duplicated fragments.** Presence is tracked as a fragment
  bitmap, so out-of-order arrival is tolerated, but a duplicate that overwrites
  a region already written is not detected. On a TDMA fabric with in-order
  delivery from one sender this cannot happen; on anything else it would need a
  sequence check.
* **Runtime-variable `P`.** Still blocked on `proposal_buffer`'s hardwired
  `buf_tx_len` (`docs/round_structure.md` §11.4).
* **Host-side NUMA and IOMMU placement.** The payload ring is a large pinned
  region and where it lives relative to the consuming core matters at these
  rates. That is a driver question.
* **Interrupt coalescing.** The design assumes a polling host. An interrupt mode
  would need a moderation scheme, and at 2 µs rounds interrupts are the wrong
  tool.
* **More than one RX port.** Frames are assumed serialised by a single MAC
  (§3.1). Two 100G ports feeding one staging ring would interleave frames and
  break the frame-sized-slot assumption.
