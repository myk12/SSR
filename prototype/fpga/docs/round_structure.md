# Round Structure: Control Period + Payload Period

> Module and file names in this record predate the `ssr_` prefix; `commit_path.md` §0 maps them to today's.

**Status:** design record. **Implemented, with one large deviation, and
superseded in part by `docs/count_ack.md`** (count acks): the announcement
(`frag_count` in the control frame, §7.1, §11.0), the 1-bit row (§6, §11.1,
group K) and the present set as "whole proposal received" are gone. The
control frame now carries an 8-byte vector of fragment counts about the
previous round, a node sends fragments mid-round until a transmit cutoff, and
a peer is a witness when its vector equals ours. The bullets below are amended
to match. See `docs/commit_path.md` (§3, §7, §10), the wiring record, which is
authoritative where the two disagree:

* **There is no TDMA and no transmit window at all**, not even inside the
  control period. Every node transmits at `TX_START_OFFSET_NS = PROP_DEAD + g +
  settle`, and what keeps `(N−1)` senders from swamping one receiver is a
  per-node **rate cap**: after every fragment `tx_engine` stays quiet for
  `(N−2)` frame-times (`P_PACE_GAP_CYCLES`, derived in `ssr_dataplane`). The
  sub-slots of §2.1, the payload window and `PAY_ADMIT_MARGIN_NS` of §8.1 are
  gone. The one transmit bound is the cutoff (`TX_PAY_CUTOFF_NS = 3341`,
  `o_tx_pay_open`); the elaboration check is that a full round's paced
  fragments start before it. `GUARD_TIME_NS = 50`, `CTRL_PERIOD_NS = 646`,
  `PROP_DEAD_NS = 250`, `PRESENT_SETTLE_NS = 32`, `ROUND_LENGTH_NS = 4000`,
  `P_FRAGS_PER_ROUND = 5`.
* The receive side has one deadline, `o_rx_ctrl_window = [0, CTRL_PERIOD)`,
  with no lower bound, and payload is admitted on `o_rx_pay_enable`
  ("the protocol is running") plus the frame's `round_id`.
* The control frame announces nothing (neither `total_len` nor, as built
  first, `frag_count`); it carries the ack vector at header offset 36, and a
  payload frame carries only `frag_idx`. A frame is a page (§7.2 is
  superseded by `docs/commit_path.md` §3).
* `presence_tracker` keeps per-node prefix counts, not a present set, and
  the core reads nothing from it: `rx_engine` compares each peer's vector with
  ours and hands the core a "trusted" pulse (§11.1 is superseded).
* §4's evaluation instant **is now as built**: `core.v` decides round R at
  round R+1's control deadline (`o_ctrl_end_pulse` = `CTRL_PERIOD_NS` plus
  eight settle cycles), not at the boundary into R+2. The boundary only shifts
  the pipeline. Commit lag is one round; `tb_core_protocol` asserts it.

**Supersedes:** the single-period TDMA round formerly implemented in
`consensus_core` (`ROUND_LENGTH_NS` / `GUARD_TIME_NS` / `TX_SUBSLOT_NS` /
`TX_ADMIT_MARGIN_NS`).

This document describes splitting one SSR round into two periods with different
jobs, different transmit disciplines, and different sizing rules:

```text
|<------------------- one round = Tc + Tp --------------------->|
|<------ Tc: control period ----->|<---- Tp: payload period ---->|
| dead |  N control frames | slack|  all nodes transmit at once  |
| zone |   (one beat each) |      |    (incast absorbed by Tp)   |
```

The control period carries the protocol's evidence — one 64-byte frame per
node, containing that node's **ack vector** for the previous round. The payload
period carries bulk data and nothing else. The control period is *fixed*; the
payload period is the single tuning knob for the latency/throughput trade-off.

The result:

* Commit latency becomes **`2·Tc + Tp`** instead of `2·(Tc + Tp)` — approaching
  a 2× reduction as `Tp` grows.
* Commit lag drops from **two rounds to one round plus `Tc`**.
* The per-node TDMA sub-slot disappears, and with it `TX_SUBSLOT_NS`.
* Transmit stays **one engine on one pulse**: `tx_engine` plays the whole round
  out from a single "go" and orders the frames itself (§10). `ssr_tx_mux` is
  unchanged.
* Propagation delay `T_prop` stops being paid twice per round. It is absorbed
  by a single dead zone at the top of each control period.

Sections 1–5 derive the structure and the numbers. Sections 6–11 are the RTL
change list, module by module. Section 12 is the test plan. Section 13 lists
what this design deliberately does *not* solve.

---

## 1. What is wrong with the single-period round

The round today is one undifferentiated window. `consensus_core` computes

```verilog
localparam integer TX_START_OFFSET_NS = GUARD_TIME_NS + P_NODE_ID * TX_SUBSLOT_NS;
localparam integer TX_END_OFFSET_NS   = TX_START_OFFSET_NS + TX_SUBSLOT_NS;
localparam integer RX_START_OFFSET_NS = GUARD_TIME_NS;
localparam integer RX_END_OFFSET_NS   = ROUND_LENGTH_NS - GUARD_TIME_NS;
```

so with the shipped defaults (`ROUND_LENGTH_NS = 4000`, `GUARD_TIME_NS = 200`,
`TX_SUBSLOT_NS = 400`, `P_NODE_COUNT = 3`) node *k* transmits one frame — header
plus payload, evidence and data fused — in the 400 ns window starting at
`200 + 400k` ns. Three things follow, and all three are costs.

### 1.1 Serialised TDMA caps the egress duty cycle at 1/N

Each node owns one sub-slot out of `N`. Its transmitter is therefore idle for
`(N−1)/N` of every round no matter how the round is sized. With
`PROPOSAL_SLOT_BYTES = 1024` and a 4 µs round, the actual committed throughput
is

```text
N · P / round = 3 · 1024 B / 4000 ns = 0.77 GB/s
```

against a 100 Gbps (12.5 GB/s) link. The link is 94 % idle.

### 1.2 T_prop is paid twice, inside a window sized for one frame

A frame's last bit leaves the sender at the end of its sub-slot and arrives
`T_prop` later — cable plus PHY plus FEC plus, if present, a switch. On an
Alveo U200 with a 100G CMAC and RS-FEC, `T_prop` is roughly 250 ns
direct-attach and 700 ns through a store-and-forward switch. The 400 ns
sub-slot is therefore *almost entirely* propagation headroom: the 1088 bytes
actually on the wire take 87 ns. Widening the payload does not widen the
propagation term, but the current structure has no place to put that
observation — every sub-slot carries the full `T_prop` margin, so the cost is
paid `N` times per round.

### 1.3 The evidence and the data are locked to the same period

Because the row byte rides in the same frame as the payload, a node cannot
report what it received until it also has something to send, and the receiver
cannot act on the row until the whole frame has landed. The commit decision is
consequently gated on the *payload* arriving, not on the *evidence* arriving —
which is why the current commit lag is two full rounds:

```text
round R      node k transmits payload for round R
round R+1    node k transmits its row describing round R (fused with R+1's payload)
round R+2    at the boundary, all round-R rows are finally in hand -> commit R
```

`commit_assembler`'s header comment states this contract explicitly:
`o_commit_round_id` lags `o_round_id` by exactly two, every time.

The evidence is 64 bytes. The payload is kilobytes. Holding the 64-byte
decision hostage to the kilobyte transfer is the whole problem.

---

## 2. The structure

Split the round at a fixed offset `Tc`. All offsets below are measured from the
round boundary on the node's local PTP clock; all nodes share that clock, so all
nodes see the same offsets.

```text
t = 0                                     t = Tc                    t = Tc+Tp
|                                         |                                 |
|<---------- CONTROL PERIOD (Tc) -------->|<----- PAYLOAD PERIOD (Tp) ------>|
|                                         |                                 |
| [dead zone] [tx ctrl] ...... [rx done]  | [all N nodes transmit at once]   |
|  T_prop      1 beat          2T_prop    |  (N-1)·(H+P)·8/R of RX incast    |
|     ^           ^                ^      |                     ^            |
|     |           |                |      |                     |            |
|  last bit of    |         every peer's  |            our own payload's     |
|  round R-1's    |         ack vector    |            last bit leaves at    |
|  payload has    |         is in hand    |            t = Tc+Tp, arrives    |
|  arrived        |         -> EVALUATE   |            in the NEXT round's   |
|                 |            COMMIT     |            dead zone             |
|          our ack vector                 |
|          for round R-1 goes out         |
```

Two transmit events per node per round:

| | control frame | payload frame |
|---|---|---|
| when | `t = T_prop + settle`, once | `t = Tc` onward, once per fragment |
| size | 64 B, exactly one 512-bit beat | `64 + SSR_FRAG_BYTES` = 4 160 B |
| how many | exactly one per round | `ceil(total_len / SSR_FRAG_BYTES)` |
| contains | `row` = ack vector for round R−1 | bulk data for round R |
| discipline | all nodes at once | all nodes at once |
| deadline | **hard** — must land by `t = Tc` | none inside the period |
| started by | `i_tx_start_pulse` | our own control frame leaving, + a skew gap |
| consumer | `consensus_core` | `payload_stage` → host |

### 2.1 Why the control period does not need TDMA sub-slots

The reflex is to keep sub-slots so the control frames cannot collide. They
cannot usefully collide. A control frame is one beat — 64 bytes, 88 bytes on
the wire with FCS, preamble/SFD and IFG, **7.04 ns at 100 Gbps**. If all `N−1`
peers transmit simultaneously, the `N−1` frames serialise at *our* receive MAC
(on a mesh) or at the switch egress port facing us (on a switch). Either way the
total occupancy is `(N−1)·7.04 ns` — which is *exactly* what sequencing them
into sub-slots would also cost.

TDMA buys nothing here and costs a parameter, a per-node offset computation, and
a class of bugs (`TX_MISSED_COUNT`, `TX_OVERRUN_COUNT`) that exists only because
a frame can miss its sub-slot. Simultaneous transmission is strictly simpler.
The incast buffer required is `(N−1) · 64 B` = 448 bytes at `N = 8`.

### 2.2 Why the payload period can also transmit simultaneously

This is the point where an earlier iteration of this design was wrong, so it is
worth stating carefully.

A full mesh with all nodes transmitting simultaneously **does** create incast:
`N−1` senders converge on one receiver, and on an Alveo U200 with 2×100G the
aggregate ingress (200 Gbps) already exceeds the internal datapath
(512 b @ 250 MHz = 128 Gbps). Incast is real and it serialises.

The insight is that **serialisation is not a problem when the period has no
tight deadline inside it.** The payload period's only requirement is that the
last bit of the last payload has arrived before the *next* round's evaluation
instant — and the next round's dead zone already provides exactly `T_prop` of
slack for precisely that. So the payload period only has to be long enough to
absorb the serialisation:

```text
Tp  >=  (N-1) · (H + P) · 8 / R
```

Nothing inside `Tp` needs to complete early. No node is waiting on another
node's payload during `Tp`. The receiver's MAC and the assembler simply drain
the incast at line rate, in whatever order the switch or the internal arbiter
chooses, and the round ends when the clock says so.

This is what makes the split worth doing: the *deadline-bearing* traffic
(evidence) and the *bandwidth-bearing* traffic (data) get periods sized by
completely different rules.

---

## 3. Timing derivation

Symbols:

| symbol | meaning | typical |
|---|---|---|
| `R` | link rate | 100 Gbps |
| `N` | node count | 3 |
| `P` | payload bytes per node per round | tunable |
| `H` | SSR header, `SSR_HDR_BYTES` | 64 B |
| `T_prop` | cable + PHY + FEC + switch, one way | 250 ns mesh, 700 ns switched |
| `t_ctrl` | one control frame on the wire, `(H+24)·8/R` | 7.04 ns |
| `g` | PTP sync error + clock-domain slack | 50 ns |
| `settle` | assembler present-set settle time | 32 ns (8 cycles @ 250 MHz) |

### 3.1 The dead zone

At round R's boundary a node cannot yet know who it heard from in round R−1.
Round R−1's payload period ended at that boundary, so the last bit of a peer's
round-R−1 payload left that peer at `t = 0⁻` and arrives here at `t = T_prop`.
`commit_assembler` then needs a few cycles to run the frame's `i_pl_commit` and
update `slot_present` — that is `settle`.

```text
CTRL_TX_OFFSET_NS = T_prop + g + settle
```

Before this instant the ack vector is not yet knowable. This is the dead zone,
and it is irreducible: it is the physical flight time of the thing being acked.

### 3.2 The control period

Our control frame goes out at `CTRL_TX_OFFSET_NS`. Peers' control frames go out
at the same instant on their clocks (± `g`), fly for `T_prop`, and serialise at
our receiver for `(N−1)·t_ctrl`. The last one therefore lands at

```text
Tc  =  2·T_prop  +  (N-1)·t_ctrl  +  2g  +  settle
```

`T_prop` appears **twice**: once for the payload being acked to arrive, once for
the ack itself to arrive. There is no way to overlap them — the second depends
on the first.

At `t = Tc`, every node holds every sound node's row for round R−1. This is the
**evaluation instant**. It replaces the round boundary as the point at which
`consensus_core` shifts its pipeline and decides.

### 3.3 The payload period

```text
Tp  =  (N-1) · (H + P) · 8 / R  +  g
```

The `+g` covers clock skew between the earliest and latest starting transmitter.
Note there is no `T_prop` term: the flight of the last payload bit is absorbed
by the *next* round's dead zone, by construction. That is the structural reason
the dead zone is `T_prop` and not something smaller.

### 3.4 Round length and the commit instant

```text
ROUND_LENGTH_NS  =  Tc + Tp
CTRL_PERIOD_NS   =  Tc
```

Both are elaboration-time constants, as `ROUND_LENGTH_NS` is today. `round_id`
remains a pure function of PTP time-of-day —
`round_id = sec·ROUNDS_PER_SECOND + ns / ROUND_LENGTH_NS` — unchanged. The only
new derived quantity is the intra-round offset comparison at `CTRL_PERIOD_NS`.

---

## 4. Why the latency is `2·Tc + Tp`

Trace one proposal. A proposal is ready in `proposal_buffer` at the round R
boundary.

```text
round R                            round R+1
|<--- Tc --->|<------ Tp ------>|<--- Tc --->|<------ Tp ------>|
|            |    payload for   |            |
|            |    round R is    |            |
|            |    transmitted   |            |
|            |                  |  every     |
|            |                  |  node's    |
|            |                  |  ack for   |
|            |                  |  round R   |
|            |                  |  arrives   |
|            |                  |            |
0 -----------+------------------+------------+
                                             ^
                                       COMMIT round R
                                       at t = Tc + Tp + Tc
```

At round R+1's evaluation instant every node holds every sound node's row
describing round R. A quorum of identical rows is the agreed row. The commit
set for round R is decided, and the payload it names has been sitting in
`commit_assembler` since the end of round R.

```text
latency = Tc + Tp + Tc = 2·Tc + Tp
```

Contrast with an unsplit round of the same length, where the row describing
round R can only be sent in round R+1's single period and can only be acted on
at round R+2's boundary:

```text
latency_unsplit = 2·(Tc + Tp)
```

The saving is exactly `Tp`, and the ratio `2(Tc+Tp)/(2Tc+Tp)` tends to 2 as
`Tp` grows.

**The commit lag in round units changes from 2 to 1.** `commit_assembler`'s
contract — "`o_commit_round_id` lags `o_round_id` by exactly two" — becomes
"lags by exactly one, and the verdict arrives at `ctrl_end_pulse`, not at the
round boundary." The `P_ROUND_DEPTH >= 3` elaboration check can relax to `>= 2`;
keeping 4 is still recommended (power of two, and it leaves eviction headroom).

---

## 5. Numbers

`R = 100 Gbps`, `N = 3`, `T_prop = 250 ns`, `g = 50 ns`, `settle = 32 ns`
⇒ `Tc = 646 ns`, fixed for all rows below.

| `P` (B/node) | `Tp` (ns) | round (µs) | latency (µs) | throughput (GB/s) | % of ceiling |
|---:|---:|---:|---:|---:|---:|
| 512    | 146    | 0.79  | 1.44  | 1.94  | 10 % |
| 1 024  | 228    | 0.87  | 1.52  | 3.51  | 19 % |
| 2 048  | 392    | 1.04  | 1.68  | 5.92  | 32 % |
| 4 096  | 719    | 1.37  | 2.01  | 9.00  | 48 % |
| 8 192  | 1 375  | 2.02  | 2.67  | 12.16 | 65 % |
| 16 384 | 2 686  | 3.33  | 3.98  | 14.75 | 79 % |
| 32 768 | 5 307  | 5.95  | 6.60  | 16.51 | 88 % |
| 65 536 | 10 550 | 11.20 | 11.84 | 17.56 | 94 % |

Throughput here is **committed bytes per second across the whole group**,
`N·P/round`. The ceiling is `N/(N−1)·R/8 = 18.75 GB/s` at `N = 3`: each node
receives `N−1` payloads per round at line rate, and the group commits `N`
payloads in that time.

For reference, the current implementation sits at **0.77 GB/s and 8.00 µs**.
Even the 512-byte row above is 2.5× the throughput at a fifth of the latency,
because the 4 µs round is mostly idle.

### 5.1 Saving versus not splitting

| `P` | split (`2Tc+Tp`) | unsplit (`2(Tc+Tp)`) | saving | ratio |
|---:|---:|---:|---:|---:|
| 1 024  | 1.52 µs | 1.75 µs  | 0.23 µs | 1.15× |
| 8 192  | 2.67 µs | 4.04 µs  | 1.37 µs | 1.52× |
| 32 768 | 6.60 µs | 11.91 µs | 5.31 µs | 1.80× |

The split is worth little at small `P` and close to 2× at large `P`. It is
therefore *most* valuable exactly in the regime the throughput table says we
should be operating in.

### 5.2 `T_prop` sensitivity (`P = 8192`)

| `T_prop` | `Tc` | round | latency | throughput |
|---:|---:|---:|---:|---:|
| 50 ns (loopback / same board) | 246 ns  | 1.62 µs | 1.87 µs | 15.16 GB/s |
| 100 ns | 346 ns  | 1.72 µs | 2.07 µs | 14.28 GB/s |
| **250 ns (direct-attach mesh)** | **646 ns** | **2.02 µs** | **2.67 µs** | **12.16 GB/s** |
| 400 ns | 946 ns  | 2.32 µs | 3.27 µs | 10.59 GB/s |
| 700 ns (through a switch) | 1 546 ns | 2.92 µs | 4.47 µs | 8.41 GB/s |

`Tc` is `2·T_prop` plus loose change. Every nanosecond of propagation costs two
nanoseconds of fixed round overhead and, through `2·Tc`, four nanoseconds of
commit latency. **This is the strongest single argument for direct-attach copper
in a full mesh over a switched fabric**, and it is worth measuring `T_prop`
empirically on the U200 before fixing `CTRL_PERIOD_NS`: the TX completion
timestamp already captured by `ssr_tx_mux` (`o_ssr_cpl_ts`, CSR `0x040..0x048`)
plus an RX-side timestamp gives it directly.

### 5.3 Node-count scaling (`P = 8192`, `T_prop = 250 ns`)

| `N` | `Tc` | `Tp` | round | latency | throughput | ceiling |
|---:|---:|---:|---:|---:|---:|---:|
| 3 | 646 ns | 1 375 ns | 2.02 µs | 2.67 µs | 12.16 GB/s | 18.75 |
| 4 | 653 ns | 2 037 ns | 2.69 µs | 3.34 µs | 12.18 GB/s | 16.67 |
| 5 | 660 ns | 2 700 ns | 3.36 µs | 4.02 µs | 12.19 GB/s | 15.62 |
| 8 | 681 ns | 4 687 ns | 5.37 µs | 6.05 µs | 12.21 GB/s | 14.29 |

Throughput is essentially flat in `N` at fixed per-node payload, because `Tp`
and the committed bytes both scale with `N`. What scales badly is **latency**,
linearly in `N`. The control period barely moves (`(N−1)·7.04 ns`), which is the
point of section 2.1.

---

## 6. The single ack vector

The row byte's meaning changes, and this is the only semantic change to the
protocol in this document.

**Today:** the row is set from `consensus_core`'s `current_stage_proposals_reg`,
which is written on `rx_accept` — that is, when a frame's *header* clears the
rejection ladder. A node whose payload is truncated mid-frame still gets its bit
set.

**Proposed:** the row is `commit_assembler`'s `slot_present[R−1]` — the bitmap
of nodes whose payload landed **whole** for round R−1.

```verilog
// commit_assembler.v, present today, currently internal only
reg [7:0] slot_present [0:P_ROUND_DEPTH-1];   // nodes whose payload landed whole
```

One vector, used for both purposes:

* it is broadcast as the control frame's `row` byte, and
* it is the node's own row in `previous_stage_rows_reg[P_NODE_ID]`, and
* it is the `proposals` term in `eval_commit_set_valid`.

An earlier draft of this design proposed **two** vectors — a `liveness_vec`
attesting to control-frame receipt, driving the sound set, and a `data_vec`
attesting to payload receipt, driving the commit set — on the grounds that a
single lost payload would otherwise evict a node permanently, since the sound
set is shrink-only.

**That proposal is withdrawn.** Eviction on a lost payload is the intended
behaviour. The premise of SSR is a datacenter fabric with excellent timing and
negligible loss; a node that fails to deliver its payload on schedule *has*
failed the round, and the control plane — not the dataplane — is responsible for
bringing it back. Fail-fast is easier to reason about than fail-degraded, and
two vectors would introduce a state the protocol does not want to have: a node
that is alive but not contributing.

What the single vector buys:

| | two vectors | one vector |
|---|---|---|
| control frame payload | 2 × N bits | 1 × N bit (one byte, fits `SSR_OFF_ROW`) |
| core internals | two intersection paths | one |
| `eval_commit_set_valid` | must reconcile two vectors | reads the same vector |
| sound-set derivation | needs an "alive but silent" transitional state | no transitional state |
| assembler → core | must distinguish "frame arrived" from "payload whole" | one bitmap |

The last row is the concrete payoff. The known defect that
`current_stage_proposals_reg` is derived from header acceptance rather than
payload completion is fixed by *deleting* that register and routing
`slot_present` back to the core. No second path, no new distinction in
`rx_engine`.

The single vector answers "did node k's payload arrive whole?". It cannot
answer "how much was there supposed to be?", and §7.1 is where that comes from.

A useful corollary: the "heard but empty" case (a peer sends a header-only frame
with `length == 0`) is now unambiguously **not present**. Under the current
frame format, `length == 0` is load-bearing — it means "committed, proposed
nothing" — but that distinction belongs to the *payload* frame, and a payload
frame with `length == 0` sets no `slot_present` bit because no beats arrived.
This is cleaner than the status quo and it makes the existing bench test `C2`
assert a sharper property.

---

## 7. Frame format changes (`ssr_packet.vh`)

The frame carries no version or type field today; it is identified solely by
ethertype `0x88B5`. Two frame kinds now exist and must be distinguishable
**from the frame itself**, not from the window it arrived in — a payload frame
whose flight straddles the round boundary (section 8.2) arrives during the next
round's dead zone, and classifying by window would misfile it.

Take one byte from the 34-byte reserved region at offsets 30–63:

```verilog
localparam integer SSR_OFF_KIND     = 30;   // was reserved
localparam integer SSR_W_KIND       = 8;

localparam [7:0]   SSR_KIND_CTRL    = 8'd1;
localparam [7:0]   SSR_KIND_PAYLOAD = 8'd2;
```

Field use by kind:

| field | control frame | payload frame |
|---|---|---|
| `node_id` @14 | sender | sender |
| `row` @15 | **ack vector for round R−1** | ignored, transmit as 0 |
| `total_len` @32 | **announcement for round R** | repeat of the announcement |
| `frag_off` @36 | 0 | this fragment's offset |
| `run_id` @16 | current run | current run |
| `round_id` @20 | R | R |
| `length` @28 | 0 | `P` |
| `kind` @30 | `SSR_KIND_CTRL` | `SSR_KIND_PAYLOAD` |

### 7.1 The control frame announces the payload period

Once "nothing to propose" means "no payload frame at all" (§10.3), a receiver
seeing no payload from node k cannot tell **"it had nothing to send"** from
**"it sent something and I lost all of it"**. `ssr_commit.vh` needs those
separated — the first is `commit_set[k] & present_set[k]` with `length[k] == 0`
("committed, proposed nothing"), the second is
`commit_set[k] & ~present_set[k]` ("decided in, bytes never arrived").

So the control frame carries `total_len` as well as `row`. Two facts with
opposite time senses in one 64-byte frame:

```text
row        the ack vector for round R-1     evidence,     backward-looking
total_len  what I am about to send in R     announcement, forward-looking
```

The timing works because the control frame goes out at `t ≈ 332 ns` and the
payload period starts at `t = Tc ≈ 646 ns` — by the time we announce, we have
already decided. `tx_engine` reads `proposal_buffer`'s slot count once, at that
instant, and nothing but `tx_engine` removes slots, so the announcement cannot
become a lie before the payload period opens.

A node lying about `total_len` costs itself the round and nothing else: the
receiver waits for bytes that never come and marks it not-present. Fail-fast,
no safety consequence, so this needs no validation beyond a counter.

`total_len` rides in **both** kinds — the control frame announces it, and every
fragment repeats it so the copy of the header the host reads at the top of a
region is self-describing on its own (`docs/speculative_delivery.md` §2.1). A
disagreement between the announcement and a fragment's claim is a detectable
fault and gets a counter.

### 7.2 The header

The header stays 64 bytes, one beat, `SSR_HDR_BYTES` unchanged — so the
"beat *k* of the frame is buffer row *k−1* byte-for-byte, no barrel shifter"
property that the whole RX path depends on is preserved.

`tb/mqnic_core_pcie_us/ssr_packet.py` mirrors this header and must be updated in
the same commit.

---

## 8. `consensus_core` changes

### 8.1 Parameters

Removed:

```verilog
parameter integer TX_SUBSLOT_NS     = 400;   // delete - no per-node sub-slots
```

Added / repurposed:

```verilog
parameter integer ROUND_LENGTH_NS   = 4000;  // now Tc + Tp
parameter integer CTRL_PERIOD_NS    = 646;   // Tc
parameter integer PROP_DEAD_NS      = 250;   // T_prop
parameter integer PRESENT_SETTLE_NS = 32;    // tracker settle after the last i_pl_commit
parameter integer GUARD_TIME_NS     = 50;    // g (was 200)

// TX_ADMIT_MARGIN_NS survives, and has to GROW. i_tx_window gates the START of
// a frame and nothing else - there is no mid-frame abort, by design - so a
// frame admitted at the last instant of a period runs past the end of it by its
// own transmission time. With jumbo fragmentation that time is no longer
// negligible:
//
//     control frame    64 B  ->   7.4 ns at 100G
//     payload frame  4160 B -> 334.7 ns at 100G,  83.7 ns at 400G
//
// So the payload window must close one whole frame before the round boundary,
// or the last fragment spills into the next round's dead zone and delays our
// own control frame - the one piece of traffic that has a hard deadline.
parameter integer PAY_ADMIT_MARGIN_NS  = 400;  // >= one max frame at line rate (4160 B = 335 ns)
```

An earlier draft of this document deleted `TX_ADMIT_MARGIN_NS` along with the
sub-slots. That was wrong: the sub-slots went away, the reason for an admission
margin did not, and fragmentation made it six times larger than it used to be.

Derived offsets replacing the current six:

```verilog
// TRANSMIT: one pulse, one window. tx_engine plays out the whole round from
// these two, so the core no longer computes a payload transmit offset at all.
localparam integer CTRL_TX_OFFSET_NS = PROP_DEAD_NS + GUARD_TIME_NS + PRESENT_SETTLE_NS;
localparam integer PAY_TX_END_NS     = ROUND_LENGTH_NS - PAY_ADMIT_MARGIN_NS;  // closes early
//   o_tx_start_pulse at CTRL_TX_OFFSET_NS
//   o_tx_window      [CTRL_TX_OFFSET_NS, PAY_TX_END_NS)

// RECEIVE: two windows, because the two kinds have different admissible
// intervals, and CTRL_PERIOD_NS is now purely the EVALUATION instant.
localparam integer CTRL_RX_END_NS    = CTRL_PERIOD_NS;
localparam integer PAY_RX_END_NS     = ROUND_LENGTH_NS + PROP_DEAD_NS;         // straddles!
```

The asymmetry is the point. Transmit needs one decision per round — "go" — and
the ordering inside the round is `tx_engine`'s business (§10). Receive needs
two windows because a frame's kind determines when it may legitimately arrive,
and a payload frame's flight straddles the boundary while a control frame's
does not.

Note the asymmetry between `PAY_TX_END_NS` and `PAY_RX_END_NS`: we stop
*admitting* payload frames one frame-time before the boundary, but we keep
*accepting* them one `T_prop` past it. Both are the same fact seen from the two
ends of a cable.

New elaboration checks, in the spirit of the existing ones:

```verilog
if (CTRL_PERIOD_NS <= CTRL_TX_OFFSET_NS)                $error("control period too short for the dead zone");
if (CTRL_PERIOD_NS >= ROUND_LENGTH_NS)                  $error("no payload period left");
if (PROP_DEAD_NS >= CTRL_PERIOD_NS)                     $error("dead zone swallows the control period");
```

### 8.2 New pulses and windows

| signal | offset | purpose |
|---|---|---|
| `o_round_start_pulse` | 0 | unchanged; pure timing, opens the round |
| `o_tx_start_pulse` | `CTRL_TX_OFFSET_NS` | latch `i_present_set`; `tx_engine` plays out the whole round from here |
| `o_ctrl_end_pulse` | `CTRL_PERIOD_NS` | **the evaluation instant** |
| `o_tx_window` | `[CTRL_TX_OFFSET_NS, PAY_TX_END_NS)` | the one transmit window |
| `o_ctrl_window` | `[PROP_DEAD_NS, CTRL_PERIOD_NS)` | **receive** side: accept control frames |
| `o_pay_window` | `[CTRL_PERIOD_NS, ROUND_LENGTH_NS) ∪ [0, PROP_DEAD_NS)` | **receive** side: accept payload frames |

`o_pay_window` deliberately straddles the round boundary: a payload frame sent
at the very end of round R is still in flight `T_prop` into round R+1. Two
consequences:

1. `o_rx_window` as a single signal is no longer sufficient. `rx_engine` needs
   both windows, because the two kinds have different admissible intervals.
2. The expected round id differs by window. `consensus_core` exports it
   pre-computed so `rx_engine` stays arithmetic-free:

```verilog
// during the straddle, a payload frame legitimately carries the PREVIOUS round id
wire in_straddle = (round_offset_ns < PROP_DEAD_NS);
assign o_rx_ctrl_round_id = round_id_reg;
assign o_rx_pay_round_id  = in_straddle ? (round_id_reg - 64'd1) : round_id_reg;
```

This is the single most easily-missed detail in the whole design. Without it,
the last payload frame of every round is dropped by the `ROUND` rung of the
rejection ladder and `slot_present` is systematically short by one bit — which
would look exactly like a flaky peer.

### 8.3 The FSM moves its evaluation instant

Every transition currently gated on `round_start_pulse_reg` moves to
`ctrl_end_pulse_reg`. This is a substitution, not a restructuring — the
`S_IDLE / S_WAIT_ACTIVATE / S_RUN / S_HALT` states, `activation_due`,
`activation_includes_self`, and the `config_excludes_self` path are all
unchanged.

The transitions that are deliberately **immediate** stay immediate, for exactly
the reasons already documented in `core.v`:

```verilog
if (timing_lost && (state_reg == S_RUN)) state_reg <= S_HALT;   // unchanged
if (protocol_stop)                       state_reg <= S_IDLE;   // unchanged
if (control_reboot_pulse)                /* clears run/sound/membership */    // unchanged
if (rst)                                 state_reg <= S_IDLE;   // unchanged
```

Activation still takes effect at a period boundary, but that boundary is now
`ctrl_end_pulse`, so a node joins at the same instant everyone else evaluates.

### 8.4 The pipeline collapses from two stages to one

This is the largest simplification in the design.

Today the core carries `current_stage_*` and `previous_stage_*` because the
proposals bitmap is *accumulated over a whole round* (one `rx_accept` at a time)
and must be held for another whole round before the rows describing that round
arrive. Hence two stages.

Under the new structure the proposals bitmap arrives as a **single snapshot**
from the assembler at `tx_start_pulse`, already complete. The accumulation
disappears and so does the extra stage:

```verilog
// DELETE:
//   reg [7:0]  current_stage_proposals_reg;
//   reg [7:0]  previous_stage_proposals_reg;
//   reg [7:0]  current_stage_rows_reg [0:7];   (if present)
//   reg        current_stage_valid_reg;
//   the rx_accept accumulation at lines ~916-919

// ADD:
input  wire [7:0]  i_present_set;     // from commit_assembler, for round_id-1
input  wire        i_present_valid;

reg [7:0] own_row_reg;                // our ack vector for round R-1
reg       own_row_valid_reg;

always @(posedge clk) begin
    if (tx_start_pulse_reg) begin
        own_row_reg       <= i_present_set & MEMBER_MASK;
        own_row_valid_reg <= i_present_valid;
        o_tx_row          <= i_present_set & MEMBER_MASK;   // what we broadcast
        previous_stage_rows_reg[P_NODE_ID] <= i_present_set & MEMBER_MASK;
    end
end
```

The evaluation block is then textually unchanged except that
`previous_stage_proposals_reg` is replaced by `own_row_reg`:

```verilog
wire       eval_agreed_row_valid  = !eval_row_self_missing
                                 && (eval_local_row != 8'd0)
                                 && (eval_witness_count >= QUORUM[3:0]);
wire [7:0] eval_agreed_row        = eval_local_row;
wire [7:0] eval_sound_set         = eval_witness_mask;
wire       eval_commit_set_valid  = eval_agreed_row_valid
                                 && ((eval_agreed_row & ~own_row_reg) == 8'd0);   // was previous_stage_proposals_reg
wire       eval_sound_set_shrinks = ((eval_sound_set & current_sound_set_reg) == eval_sound_set);
```

`eval_local_row` becomes `current_sound_set_reg[P_NODE_ID] ? own_row_reg : 8'd0`.

All six halt reasons keep their codes and their priority order. `HALT_NONE`
through `HALT_TIME_FAULT` are unchanged, so the CSR `HALT_REASON` encoding and
the host driver do not move.

### 8.5 New commit output timing

```verilog
o_commit_round_id <= round_id_reg - 64'd1;   // lag 1, was previous_stage_round_id_reg (lag 2)
```

asserted on `ctrl_end_pulse`, not on `round_start_pulse`.

---

## 9. `rx_engine` changes

### 9.1 A new rung: KIND

The ladder gains one rung, between `WINDOW` and `MEMBER`. `WINDOW` answers
"is any window open?"; `KIND` answers "is it *this frame's* window?".

| # | rung | condition | counter |
|---|---|---|---|
| 1 | FOREIGN | `!hdr_is_ssr` | `o_foreign_count` |
| 2 | MALFORMED | `!hdr_geom_ok` | `o_malformed_count` |
| 3 | WINDOW | `!(i_ctrl_window \|\| i_pay_window)` | `o_window_drop_count` |
| 4 | **KIND** | **`!hdr_kind_ok`** | **`o_kind_drop_count`** *(new)* |
| 5 | MEMBER | `!hdr_node_ok` | `o_member_drop_count` |
| 6 | SOUND | `!hdr_sound_ok` | `o_sound_drop_count` |
| 7 | RUN | `!hdr_run_ok` | `o_run_drop_count` |
| 8 | ROUND | `!hdr_round_ok` | `o_round_drop_count` |

```verilog
wire hdr_is_ctrl = (hdr_kind == SSR_KIND_CTRL);
wire hdr_is_pay  = (hdr_kind == SSR_KIND_PAYLOAD);
wire hdr_kind_ok = (hdr_is_ctrl && i_ctrl_window) || (hdr_is_pay && i_pay_window);
// note these are the RECEIVE windows; the transmit side has only one (section 8.2)

// the ROUND rung now compares against the kind-appropriate expectation
wire [63:0] hdr_round_expect = hdr_is_ctrl ? i_rx_ctrl_round_id : i_rx_pay_round_id;
wire        hdr_round_ok     = (hdr_round_id == hdr_round_expect);
```

A control frame carrying `length != 0`, or a payload frame carrying
`length == 0` when one was expected, is a `MALFORMED` case and should be charged
there, not to `KIND`.

### 9.2 Output routing by kind

```verilog
// evidence -> consensus_core, control frames only
o_rx_valid   <= accept && hdr_is_ctrl;
o_rx_node_id <= hdr_node_id;
o_rx_row     <= hdr_row;

// payload -> commit_assembler, payload frames only
o_pl_sof     <= accept && hdr_is_pay;
```

A control frame must **not** raise `o_pl_sof`. Today `o_pl_sof` is raised even
for header-only frames (with `o_pl_commit` firing on the same cycle); under the
new structure that behaviour would open — and immediately evict — a round slot
once per round per peer.

`i_rx_window` is replaced by `i_ctrl_window` / `i_pay_window`. Both must remain
**combinational reads of the core's state**, for the reason the module header
already gives: these are TDMA-timed guard signals, and a pipeline register
reopens the race the guard exists to close.

---

## 10. `tx_engine`: one engine, a fixed order

An earlier draft of this section split the control frame into its own `ctrl_tx`
module with a third input on `ssr_tx_mux`. **That is withdrawn.** The two frames
share a module, and the round is a *sequence* through one FSM:

```text
t = CTRL_TX_OFFSET_NS    one control frame        always, first
t = Tc onward            zero or more fragments   until the plan is done
t = PAY_TX_END_NS        the window closes        whatever is left is abandoned
```

### 10.1 Why the split was wrong

The control frame is already the module's header-only path:
`S_IDLE → S_HDR → S_IDLE` with `has_payload_reg = 0`. Nothing new was needed.

Two of the three arguments for splitting do not survive contact:

* *"It couples the deadline-bearing frame to the bulk engine's readiness."* Only
  if the two frames race for the FSM. As a **sequence** the control frame is
  emitted before anything looks at `proposal_buffer`, so the deadline is never
  hostage to the bulk path.
* *"It drags irrelevant machinery into the critical path."* Sharing a module is
  not sharing a path — the control frame never touches `i_buf_rd_*`,
  `payload_space` or the holding register. And the argument contradicted §10.4's
  own reasoning for keeping the RX ladder in one place: one header composer is
  better than two, for exactly the reason one parser is.

Only the third survives, and it is not architectural: the counters have to be
split by kind, which is six lines.

The split would also have cost a third `ssr_tx_mux` input and a priority
arbiter. With one SSR source the existing "SSR wins an idle mux" policy is
already correct, and `ssr_tx_mux` needs **no change at all**.

### 10.2 What changes in the module

```verilog
// ONE pulse and ONE window for the whole round.
input wire i_tx_start_pulse;     // at CTRL_TX_OFFSET_NS
input wire i_tx_window;          // [CTRL_TX_OFFSET_NS, PAY_TX_END_NS)

// how many whole slots proposal_buffer holds, read once at the control frame
input wire [7:0] i_buf_slot_count;

reg is_ctrl_reg;                 // which kind is on the wire
reg [31:0]           total_len_reg;   // this round's plan, decided at the control frame
reg [FRAG_CNT_W-1:0] frags_reg, frag_idx_reg;
reg                  pay_run_reg;     // our control frame is out and we owe fragments
reg [15:0]           gap_cnt_reg;     // the skew gap, see 10.2.1
```

`pay_run_reg` is set when **our own control frame's header beat is accepted** —
not by a second pulse. That is what makes the order structural: there is no
instant at which a fragment could be admitted before the round's ack vector has
left, and no second pulse that could be missed while the FSM was busy. (An
earlier two-pulse draft had exactly that bug, and the bench found it.)

### 10.2.1 The gap before the payload is not padding

`tx_engine` waits `P_PAY_GAP_CYCLES` after its own control frame before starting
a fragment. This is not slack; removing it is a correctness bug at *other*
nodes.

Every node aims its control frame at the same absolute instant, but clocks
differ by up to ±`g`. Take A early by `g` and B late by `g`:

```text
A control frame on the wire   [-g,  -g + t_ctrl]
B control frame on the wire   [+g,  +g + t_ctrl]
```

If A began its payload the moment its own control frame was out, at `-g +
t_ctrl`, it would be pushing a whole fragment onto the fabric before B had even
*started* its control frame — and at a switch egress port those bytes can queue
**ahead** of B's control frame, which then lands ~335 ns late at a third node
and eats most of that node's `Tc`.

So the gap has to cover the whole skew spread, `2g + t_ctrl`, not just `g`:

```text
2·50 + 7.4 = 107.4 ns = 27 cycles at 250 MHz  ->  P_PAY_GAP_CYCLES = 32 (128 ns)
```

Cost: 128 ns per round — 6.3 % of a 2 µs round, 1.1 % of an 11 µs one. The
alternative is sizing `Tc` to absorb a whole fragment instead, which costs
**0.67 µs of commit latency every round**.

This is also why a one-transmitter bench cannot assert the property: the damage
happens at someone else's receiver. `tb_tx_engine_rounds` R7 measures the gap
directly instead, which is the only local evidence there is.

One proposal slot is one fragment, enforced at elaboration
(`P_MAX_PAYLOAD_BYTES == SSR_FRAG_BYTES`), so the fragment count is a count of
slots and the byte count is a shift. `P_FRAGS_PER_ROUND` caps it so a deep queue
cannot make one round overrun its payload period.

Counters split by kind: `o_ctrl_frame_count` / `o_pay_frame_count` and
`o_ctrl_missed_count` / `o_pay_missed_count`. `o_empty_count` changes meaning
from "a frame that went out empty" to "a round that deliberately sent no payload
frame at all".

### 10.3 The unconditional empty frame is retired

`tx_engine`'s header says a frame goes out every round no matter what, because
a silent node looks dead and gets evicted. The control frame now carries that
proof, so:

> **Nothing to propose means no payload frame at all.**

That removes the `length == 0` special case from the payload path entirely. But
it creates a new ambiguity, and §7.1 is how it is resolved.

### 10.4 Two non-obvious things the bench found

`tb_tx_engine_rounds` drives the two windows by hand (it cannot use the real
core until step 5). Fifty checks, nine one-sided negative controls. Two results
worth recording:

**A second pulse is a thing that can be lost.** The two-pulse draft latched
`i_pay_tx_pulse` only inside the accept branch, so a pulse arriving while the
control frame was on the wire was swallowed and the round sent no payload at
all. Collapsing to one pulse removes the failure mode rather than guarding it —
`pay_run_reg` is now set by a frame completing, which cannot be missed.

**Abandoning a fragment mid-slot desyncs `proposal_buffer`.** When the window
closes mid-fragment, `tx_engine` stops asking for rows, but `proposal_buffer`'s
head only advances on a slot's *last* beat — so `tx_beat_index_reg` is left
partway through that slot and the next round resumes in the middle of it. The
bench asserts the resulting `len_mismatch` rather than tolerating it. **The fix
is a flush input on `proposal_buffer`** that resets the read index at
`i_tx_end_pulse`; until it exists, `o_len_mismatch_count` is the evidence.

### 10.5 The receive side stays shared, deliberately

On transmit the two frames are *composed* independently, so a shared FSM only
has to order them. On receive they arrive on one wire and must be parsed by one
header decoder before anyone can tell them apart — splitting would duplicate the
parser and the rejection ladder, which `docs/rx_datapath.md` §2 argues at length
should exist in exactly one place. `rx_engine` keeps one ladder with a `KIND`
rung (§9.1) and forks only at the accept path.

---

## 11. `commit_assembler` and `ssr_dataplane` changes

### 11.0 Arming the expectation from the control frame

`slot_present[rsel][k]` used to be a single bit set when node k's one frame
landed. With fragmentation it becomes "every fragment of what k announced has
arrived", which needs an expectation established **before** the payload period:

```verilog
reg [31:0] slot_expect [0:P_ROUND_DEPTH*SSRC_MAX_NODES-1];  // bytes announced
reg [31:0] slot_got    [0:P_ROUND_DEPTH*SSRC_MAX_NODES-1];  // bytes landed whole
reg [SSR_MAX_FRAGS-1:0] slot_fmask [0:P_ROUND_DEPTH*SSRC_MAX_NODES-1];
```

Armed on a **control frame** — one per peer per round, so the whole table for a
round is armed during the control period, before a single payload byte arrives:

```verilog
if (i_ctrl_valid) begin          // from rx_engine's accept path, kind == CTRL
    slot_expect[idx] <= i_ctrl_total_len;
    slot_got   [idx] <= 32'd0;
    slot_fmask [idx] <= {SSR_MAX_FRAGS{1'b0}};
end
```

Our own node is armed the same way, from `tx_engine`'s `o_local_announce`
(§10.2) — our control frame never comes back off the wire, and without this our
own presence would be unknowable.

Presence is then a comparison, evaluated whenever a fragment commits:

```verilog
wire present = (slot_expect[idx] == 32'd0)      // announced nothing: trivially complete
            || (slot_got[idx] == slot_expect[idx]);
```

Two things fall out that are worth stating:

* **`total_len == 0` is present, not absent.** That is the whole reason the
  announcement exists; see §7.1.
* **A fragment bitmap, not just a byte counter.** The counter alone cannot tell
  a duplicate fragment from a new one, and would let two copies of fragment 3
  satisfy an expectation that fragment 5 never met. At `SSR_MAX_FRAGS = 64` the
  mask is 64 bits per (round, node) — 2 Kib at depth 4 and 8 nodes, which is
  nothing next to being unable to distinguish those two cases.

### 11.1 Export the present set

`slot_present` exists and is correct; it is simply not visible outside the
module. Add a combinational lookup port:

```verilog
    // ---- present-set query, to consensus_core ---------------------------
    input  wire [63:0]  i_present_round,      // the round being queried (round_id-1)
    output wire [7:0]   o_present_set,
    output wire         o_present_valid
```

```verilog
wire [ROUND_SEL_BITS-1:0] pq_rsel  = i_present_round[ROUND_SEL_BITS-1:0];
wire                      pq_held  = slot_valid[pq_rsel]
                                  && (slot_round_id[pq_rsel] == i_present_round);
assign o_present_valid = pq_held;
assign o_present_set   = pq_held
                       ? (slot_present[pq_rsel] & ((8'd1 << P_NODE_COUNT) - 8'd1))
                       : 8'd0;
```

The core registers this on `tx_start_pulse`; the assembler side stays
combinational so there is no extra round of latency to budget for. If timing
closure on the U200 objects to the array read plus the comparator in one cycle,
move the registration into the assembler and fire it from a `tx_start_pulse`
delayed by one cycle — `PRESENT_SETTLE_NS` already has the slack.

### 11.2 Relax the depth check

```verilog
if (P_ROUND_DEPTH < 2) begin            // was < 3
    $error("commit_assembler: P_ROUND_DEPTH = %0d, but a round commits one control period after it is received (instance %m)",
           P_ROUND_DEPTH);
```

and update the module header's "WHY THIS MODULE EXISTS AT ALL" paragraph, which
currently reads "a payload arrives two rounds before anyone knows whether its
round commits … `o_commit_round_id` lags `o_round_id` by exactly two, every
time." Under this design it lags by exactly one, and the verdict arrives at
`ctrl_end_pulse` rather than at the boundary. The module's *reason* for existing
is unchanged — the payload still has to be parked, addressable by round and by
node, until the verdict exists.

### 11.3 New CSRs

Free offsets in `RBB_COMMON`: `0x0a4` (vacated when `ASM_ARB_STALL_COUNT` was
removed), `0x088`, `0x08c`, and `0x0b8` onward.

| offset | name | source |
|---|---|---|
| `0x02c` | *(existing `ETHERNET_PORT`)* | — |
| `0x088` | `RX_KIND_DROP` | `rx_engine.o_kind_drop_count` |
| `0x08c` | `RX_CTRL_ACCEPT_COUNT` | control frames accepted |
| `0x0a4` | `ASM_PRESENT_SET` | `{24'b0, o_present_set}`, live |
| `0x0b8` | `CTRL_PERIOD_NS` | parameter read-back |
| `0x0bc` | `PROP_DEAD_NS` | parameter read-back |
| `0x0c0` | `TX_CTRL_FRAME_COUNT` | control frames transmitted |
| `0x0c4` | `TX_PAY_FRAME_COUNT` | payload frames transmitted |

`ROUND_LENGTH_NS` at `0x028` keeps its meaning (`Tc + Tp`), so nothing the host
driver already reads changes.

### 11.4 `proposal_buffer` blocks variable `P`

Worth stating plainly because it is easy to miss: `buf_tx_len` is hardwired.

```verilog
assign buf_tx_len = PROPOSAL_SLOT_BYTES_LEN;   // proposal_buffer.v ~line 196
```

`PROPOSAL_SLOT_BYTES` defaults to 1024 and must be a power of two. So the whole
throughput table in section 5 is reachable only by re-elaborating with a larger
`PROPOSAL_SLOT_BYTES` — which is fine for a research prototype, but it means
`P` is a **synthesis-time** constant, not a runtime one. Making it runtime-tunable
is a separate change to `proposal_buffer` and `proposal_dma_reader` and is
explicitly out of scope here.

### 11.5 Memory cost of larger `P`

`P_ROUND_DEPTH = 4`, `N = 3`:

| stride | `store_peers` | `store_self` | commit slot |
|---:|---:|---:|---:|
| 1 KiB  | 8 KiB (≈2 BRAM36)   | 4 KiB (LUTRAM) | 3.1 KiB |
| 8 KiB  | 64 KiB (≈14 BRAM36) | 32 KiB | 24.1 KiB |
| 32 KiB | 256 KiB (≈57 BRAM36)| 128 KiB | 96.1 KiB |

The U200 has ~2 160 BRAM36 and 960 URAM, so even 32 KiB strides are a rounding
error in BRAM terms — but `store_self` is `ram_style = "distributed"` and 128 KiB
of LUT RAM is *not* affordable. **Above roughly 4 KiB of stride, `store_self`
must move to block RAM too**, which gives back the arbitration-free property's
LUT saving but keeps its more important property (one writer per memory, so
`o_pl_ready` can stay tied high).

> **Superseded by `docs/speculative_delivery.md`.** That design deletes both
> stores, so this table and the LUT-RAM constraint stop applying. On-chip
> storage becomes a 4-frame staging ring sized by DMA turnaround rather than by
> `P_ROUND_DEPTH × N`. If speculative delivery lands first, skip this section.

### 11.6 The ceiling today is the commit RAM, then PCIe

Two ceilings sit below the Ethernet-side limit, and the nearer one is not PCIe.

**The elaboration wall.** `ssr_dataplane.v` sizes the commit slot as a power of
two inside one `RAM_SEL`'s 64 KiB address space and requires at least two slots:

```verilog
localparam integer SSR_COMMIT_USED_BYTES = 64 + P_NODE_COUNT*P_COMMIT_PAYLOAD_STRIDE;
localparam integer SSR_COMMIT_SLOT_BYTES = 1 << $clog2(SSR_COMMIT_USED_BYTES);
localparam integer SSR_COMMIT_SLOT_COUNT = (1 << RAM_ADDR_WIDTH) / SSR_COMMIT_SLOT_BYTES;
// if (SSR_COMMIT_SLOT_COUNT < 2) $error(...); $finish;
```

So the largest stride that **builds at all** is `(2^15 − 64)/N`:

| `N` | max stride |
|---:|---:|
| 3 | 10 901 B (10.65 KiB) |
| 5 | 6 540 B (6.39 KiB) |
| 8 | 4 088 B (3.99 KiB) |

**PCIe.** The Alveo U200 is Gen3 ×16: 15.75 GB/s raw, ~13 GB/s usable per
direction. `commit_dma_writer` pushes the whole slot — `64 + N·P` bytes, *our
own payload included* — so upstream traffic is `N·P` per round, which is exactly
the throughput figure in section 5. That runs out at `P = 16 KiB`.

Taken together, `P` above ~10 KiB is unreachable on this board as the design
stands, which makes most of section 5's table aspirational.

> **Both ceilings are removed by `docs/speculative_delivery.md`.** Deleting the
> commit slot removes the elaboration wall entirely, and not DMA-ing our own
> payload back drops upstream traffic from `N·P` to `(N−1)·P` — which, because
> PCIe is full duplex and the proposal fetch travels downstream, leaves headroom
> out to `P = 128 KiB`. Read that document before sizing `P` from this section.

---

## 12. Test plan

The existing 35 tests in `tb/ssr_dataplane/tb_ssr_dataplane.v` (groups A–H) stay
meaningful, with two mechanical updates:

* `exp_rung` grows from 7 to 8 entries, and every `expect_rung` call site with a
  rung index ≥ 4 shifts by one. The `initial` zeroing loop bound changes from 7
  to 8 — this array is `integer`, so leaving it uninitialised makes `if (X)` take
  the else branch and the tests **pass silently**. The loop is load-bearing.
* `send_peer_frame` gains a `kind` argument and the peer driver sends two frames
  per round instead of one.

New groups:

### Group H2 — the two transmit engines

| test | stimulus | expectation |
|---|---|---|
| H2a | steady state, 50 rounds | exactly one control frame per round, `tx_engine.o_missed_count == 0` |
| H2b | a host DMA frame admitted just before the round boundary | the control frame is delayed but still goes out inside its window — `PAY_ADMIT_MARGIN_NS` is what leaves room for it |
| H2c | a payload fragment forced to start at `PAY_TX_END_NS` | it finishes before the boundary — this is what `PAY_ADMIT_MARGIN_NS` sizes |
| H2d | `PAY_ADMIT_MARGIN_NS` deliberately set to 0 | the last fragment spills past the boundary and `tx_engine.o_missed_count` rises — the failure must be **visible**, not silent |
| H2e | negative control: remove the skew gap | the payload starts inside the window in which a late peer is still sending its control frame — measured, since the damage lands at another node |

H2d is the one that earns its place. An admission margin that is too small does
not corrupt anything — it quietly costs the node a round now and then, which
looks exactly like a flaky peer. The counter is the only thing that tells the
two apart.

### Group I — period separation

| test | stimulus | expectation |
|---|---|---|
| I1 | control frame injected during the payload window | `KIND` rung, `o_kind_drop_count++`, protocol undisturbed |
| I2 | payload frame injected during the control window | `KIND` rung |
| I3 | control frame with `length != 0` | `MALFORMED` rung, not `KIND` |
| I4 | control frame arrives → does **not** raise `o_pl_sof` | `ASM_EVICT_COUNT` stays 0 across 20 rounds |

### Group J — boundary straddle

The highest-value group, because 8.2 is where the design is most likely to be
implemented wrong.

| test | stimulus | expectation |
|---|---|---|
| J1 | peer payload whose last beat lands 1 cycle *after* `round_start_pulse` | accepted; `slot_present[R]` bit set for that peer |
| J2 | the same, `PROP_DEAD_NS − 1` ns after the boundary | accepted |
| J3 | the same, `PROP_DEAD_NS + 1` ns after the boundary | `ROUND` rung drop, `slot_present` bit clear |
| J4 | negative control: disable the `in_straddle` adjustment | J1 and J2 must **fail** |

J4 is the test that proves the other three are load-bearing. Without it, an
implementation that simply widened the round-id tolerance to `±1` unconditionally
would pass J1–J3 while silently accepting genuinely stale frames.

### Group K — present set drives the row

| test | stimulus | expectation |
|---|---|---|
| K1 | peer 2's payload truncated (`i_pl_drop`) | `slot_present[R][2]` clear → our next control frame's `row` has bit 2 clear |
| K2 | peer 2 announces `total_len = 0` and sends no payload frame | bit 2 **set**, `length[2] = 0` — "proposed nothing", not "lost" |
| K2b | peer 2 announces `total_len > 0` and sends no payload frame | bit 2 **clear** — these two must not look alike (§7.1) |
| K2c | peer 2 announces 3 fragments, sends 2 | bit 2 clear |
| K2d | peer 2 sends fragment 3 twice and never sends 5 | bit 2 clear — the byte counter alone would say complete |
| K3 | peer 2 sends control but no payload for one round | bit 2 clear; sound set shrinks at the *next* evaluation, not this one |
| K4 | negative control: drive the row from `rx_accept` instead of `slot_present` | K1 and K2 must **fail** |

Note the one-round lag in K3 — the same trap that broke `H1` during the bench
rewrite. A frame's row describes the *previous* round, so a stimulus and the
claim about it must never change on the same round boundary.

### Group L — incast absorption

| test | stimulus | expectation |
|---|---|---|
| L1 | all `N−1` peers drive payload beats back-to-back with no gaps for a whole `Tp` | no beat lost, `o_pl_ready` never deasserts, `RX_STALL_COUNT` stays 0 |
| L2 | L1 at `P = P_PAYLOAD_STRIDE` exactly | no `ASM_OVERSIZE_COUNT` |
| L3 | L1 with `Tp` deliberately set 1 beat too short | last payload straddles past `PROP_DEAD_NS` → `ROUND` drop, and the test asserts that this is *detected*, not silently absorbed |

L3 is the sizing check: it proves `Tp` is genuinely the binding constraint and
that undersizing it fails loudly.

### Group M — latency and lag

| test | stimulus | expectation |
|---|---|---|
| M1 | steady state, 50 rounds | `o_commit_round_id == round_id − 1` on every commit |
| M2 | measure cycles from `ctrl_end_pulse` to `o_commit_valid` | constant, and reported in the log |
| M3 | measure wall-clock from proposal enqueue to commit | within one round of `2·Tc + Tp` |

M3 is the headline number this whole document exists to produce, so it should be
printed unconditionally, not just asserted.

---

## 13. Deliberately not solved here

* **Recovery of an evicted node.** Out of scope by design (section 6). The
  control plane re-admits nodes via the existing activation path
  (`REG_CONTROL` bit 1 → `control_activate_pulse` → `activate_pending_reg`,
  fenced by `config_membership`, `config_effective_round` and `config_run_id`),
  which is unchanged.
* **Runtime-variable `P`.** Blocked on `proposal_buffer` (section 11.4).
* **Automatic `T_prop` calibration.** `CTRL_PERIOD_NS` is an elaboration-time
  constant sized from a measured `T_prop`. Measuring it at run time and adapting
  would be a genuinely different protocol.
* **Mixing payload sizes across nodes.** All nodes use the same `P`. The commit
  slot's per-node `length[k]` table already supports heterogeneity, but the
  `Tp` derivation assumes uniformity.
* **More than 8 nodes.** The row is one byte and `SSRC_MAX_NODES` is 8, unchanged.

---

## 14. Migration order

The change set touches five modules and the frame format, so it cannot land as
one commit without a long red window. Suggested order, each step leaving the
regression green:

1. **`ssr_packet.vh` + `ssr_packet.py`**: add `SSR_OFF_KIND` and the two kind
   codes. Transmit `SSR_KIND_PAYLOAD` unconditionally; ignore the field on
   receive. No behaviour change. Bench unaffected.
2. **`commit_assembler`**: add the present-set query port, leave it unread.
   Add a bench assertion that `o_present_set` matches a shadow model. This is
   the step that de-risks section 6 before anything depends on it.
3. **`consensus_core`**: swap `previous_stage_proposals_reg` for `i_present_set`
   *while keeping the single-period round*. Commit lag stays 2. This isolates
   the semantic change (section 6) from the timing change (sections 2–4), so if
   the regression goes red, only one thing changed. Add group K here.
4. **`tx_engine`**: the control-frame-then-fragments sequence, the `total_len`
   announcement, and the skew gap, driven by hand rather than by the core.
   `ssr_tx_mux` needs nothing. *(done — `tb_tx_engine_rounds`, 37 checks, nine
   one-sided negative controls, `make tb_tx_rounds`.)*
5. **`consensus_core` + `rx_engine`**: the two periods, the single transmit
   pulse and window, the two receive windows, the admission margin, the
   straddle adjustment and the `KIND` rung — these genuinely cannot be
   separated, and this is the step that makes `tb_tx_engine` and
   `tb_ssr_dataplane` compile again. Add groups H2, I, J, L.
6. **CSRs, docs, and the lag-1 contract update.** Add group M.

Step 3 is the one worth doing first even if the rest is deferred: it fixes a
real defect (the row attesting to header receipt rather than payload receipt)
independently of any timing work.
