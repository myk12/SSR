# RX Datapath Design Notes

> Module and file names in this record predate the `ssr_` prefix; `commit_path.md` §0 maps them to today's.

**Status:** design notes from before speculative delivery and count acks; the
reasoning about the filter, the ladder and `round_id` still holds, the stations
do not. **Superseded in part by `docs/count_ack.md`**: the control frame no
longer carries a row (header byte 15 is reserved zero) but an 8-byte ack
vector about the previous round at offset 36, and the ladder of §3 has one
more rung, last and for control frames only, `ACK_DISAGREE` (`RX_ACK_DISAGREE`,
0x4B0): an accepted control frame only tells the core "node k is trusted". The
round ring, commit buffer and eviction of §10-11 are gone with speculative
delivery. For what is built see `docs/commit_path.md` §3.

Why the receive path is shaped the way it is. The module headers carry the
*contracts* a reader needs in order to use or modify them; this file carries the
*reasons*, including the arrangements that were tried and abandoned.

```text
port ─► consensus_rx_splitter ─► rx_engine ─┬─► consensus_core    (the row)
                                            └─► commit_assembler (the payload)
                                                      │
                                    commit_buffer ◄───┘
                                          │
                                    commit_dma_writer ─► host
```

Sections 1-8 cover `rx_engine`. Sections 9 onward cover constraints that span
the path - where the round number comes from, and what the round ring does when
it wraps. The remaining stations are walked in the same order as the diagram.

---

## 1. What a frame carries, and why it splits

An SSR frame carries two facts with completely different lifetimes:

```text
row      (header byte 15)  "here is who I heard from in the PREVIOUS round"
payload  (beats 1..N)      bytes this node is proposing for THIS round
```

The row is evidence. `consensus_core` records it, and the verdict it feeds into
lands **two round boundaries later** — a node's row describes the previous
round, so round R's commit set cannot be computed until round R+1's rows have
arrived. The payload has to sit somewhere addressable until that verdict exists.

Every design decision below follows from those two lifetimes being different.
`rx_engine` is the point where they separate.

---

## 2. The filter lives in rx_engine, not in consensus_core

A frame counts when the protocol is running, the sender is a peer we still
believe, and the frame names the run and round we are actually in:

```text
i_rx_window      the protocol is running AND we are inside the receive window
hdr_node_ok      sender is in range and is not us
hdr_sound_ok     sender has not been dropped from the sound set
hdr_run_ok       same run
hdr_round_ok     same round
```

All of that state belongs to `consensus_core`. It is read from there directly,
so this is **one rule reading one set of registers** rather than a copy that has
to be kept in step.

### What this replaced

The previous arrangement presented each header to the core and read back a
verdict on the next cycle. Three costs:

1. One cycle of receive bandwidth per frame, purely for the round trip.
2. A cross-module combinational path in the middle of the frame path.
3. Six distinct failure modes collapsed into one counter — on hardware that
   reduces to "some frames were rejected", which names nothing.

It was also only half true. "The protocol is running" already arrived on
`i_rx_window` and was applied locally, so the rule was split across the module
boundary and lived nowhere in particular.

`consensus_core` now keeps only a bounds check on the array that the incoming
node id indexes. It records the row and takes no further decision.

### The core's state is read combinationally, and must stay that way

All four pieces move only at a round boundary, and the receive window is
`GUARD_TIME_NS` clear of both edges, so no frame can arrive while they move.

A pipeline register on that path would reopen exactly the window the guard time
exists to close: a frame arriving just after a boundary would be judged against
the previous round's run id and sound set. If this path ever needs to be
registered for timing closure, the guard time has to grow to cover it.

---

## 3. The rejection ladder

Seven tests in a fixed order, each with its own counter. A frame is charged to
the **first** test it fails and to no other, which is what makes a non-zero
counter name a fault instead of merely reporting that one happened.

| # | test | a non-zero counter means |
|---|------|--------------------------|
| 1 | `hdr_is_ssr` | the splitter is not doing what it claims |
| 2 | `hdr_geom_ok` | MAC or line trouble, or a peer's transmit side is wrong |
| 3 | `i_rx_window` | the window and the transmit sub-slots have drifted, or we halted |
| 4 | `hdr_node_ok` | misconfiguration, or someone else on the same ethertype |
| 5 | `hdr_sound_ok` | a node that was declared dead is transmitting again |
| 6 | `hdr_run_ok` | cluster configuration is not synchronised |
| 7 | `hdr_round_ok` | **late or early arrival — the one hazard TDMA does not remove** |

The order runs from "can we parse this at all" to "should we believe it". Test 3
sits before the membership tests on purpose: charging a frame to the wrong round
is worse than losing it, so anything arriving outside the window is dropped
before its contents are considered at all.

Counter 7 is the one to watch on hardware. Everything else TDMA removes by
construction; arrival timing is what is actually being tested by running the
protocol on real links.

### Why the counters are kept

They were questioned as defensive programming. The numbers:

```text
rx_engine flip-flops          462 total
  ten counters                320   (69%)
  frame geometry + state       34
  output registers            108

XCKU040                   484,800 FF   →  320 FF = 0.07%
XCU200                  2,364,480 FF   →  320 FF = 0.014%
```

`rx_engine` uses no BRAM at all, so it contributes nothing to the memory
pressure that actually matters (see the commit-side sizing).

The decisive argument is what the alternative costs. On a board there is no
waveform. Without counters, locating a fault means building a bitstream with an
ILA, and an ILA capturing a 512-bit bus to a depth of 1024 is **64 KiB of
BRAM — the entire commit RAM**. Ten counters are about forty slices. They are a
debugging instrument three orders of magnitude cheaper than the alternative, and
for a research prototype they are also the measurement apparatus: "what was the
frame loss rate" and "why did round R not commit" are answered here or not at
all.

### Why the geometry checks are kept

`hdr_geom_ok` is four conditions:

```text
hdr_full                       the header beat is a full 64 bytes
!hdr_bad_user                  the MAC did not flag the frame (tuser bit 0)
hdr_len_ok                     length <= P_MAX_PAYLOAD_BYTES
tlast == (length == 0)         tlast agrees with the declared length
```

These are not defence against an adversary. They are defence against the
experiment silently producing wrong numbers, which is the worst failure mode in
research code — not a crash, a plausible-looking wrong result.

A frame with a bad FCS that is accepted contributes a garbage row to the
evaluation, which produces a wrong commit set, which produces experiment data
that is wrong with no indication that it is. `!hdr_bad_user` is one AND gate.

`hdr_len_ok` bounds the length against the assembler's per-node region. Without
it a corrupt length walks the assembler's write pointer past the end of one
node's region and into the next one's — silent cross-contamination between
nodes' payloads, again with no indication.

---

## 4. Ordering comes from addressing, not from timing

Every payload beat is tagged with the `node_id` and `round_id` taken **from the
frame itself**, so `commit_assembler` can place it without depending on frames
arriving in any particular order.

TDMA does make them arrive in node order. A sub-slot is 400 ns; the differential
delay between two ports of one switch is a few nanoseconds, so producing an
inversion would take roughly 80 m of cable-length mismatch.

Relying on that would put a timing assumption underneath a correctness property,
and it would weaken quietly every time the sub-slot shrank or the port was
shared. The tag costs a few flops and removes the assumption entirely.

---

## 5. The payload is forwarded before the frame is known to be whole

The header is judged on its own beat, so an accepted frame streams with no
bubble. What is *not* known at that point is whether the frame ends where the
header's length promised. That verdict arrives at the end, as `o_pl_commit` or
`o_pl_drop`.

This means a dropped frame abandons bytes the assembler has already written.
That is deliberate, and it is the same shape as the transmit side, where
`proposal_dma_reader` fills a slot and only afterwards raises
`tail_slot_commit`:

```text
writing into a RAM that is then abandoned   costs nothing
stalling a receive path                     costs frames
```

The abandoned bytes are never readable: the assembler only marks a node present
on `o_pl_commit`, so a dropped frame's region reads as zero in the emitted slot.

---

## 6. A frame is always consumed to its tlast

Every rejection path still eats the remaining beats (`S_DROP`). Stopping
mid-frame would leave the parser to resynchronise on a payload beat, and then
every frame after it is misparsed — a single bad frame would become a permanent
fault.

This is why each rung of the ladder ends with the same line:

```verilog
if (!s_axis_tlast) state_reg <= S_DROP;
```

A single-beat frame needs no drop state; anything longer does.

---

## 7. The local proposal is not handled here

A node's own payload cannot come back off the wire — the frame is a broadcast
and the sender does not receive it. It arrives instead from `tx_engine`'s local
echo.

That injection belongs in `commit_assembler`, next to the per-round storage it
has to be merged into, not in a frame parser. It is also why `hdr_node_ok`
rejects a frame claiming to come from us: our own row is the one input the
evaluation has to be able to trust, and nothing on the wire may overwrite it.

---

## 8. Things deliberately not built

**A per-beat keep mask.** `rx_engine` used to compute `hdr_tail` and a keep mask
for the final payload beat, mirroring `tx_engine`'s `offered_keep`. It had no
consumer: the assembler places bytes by the length in the tag, and the slot
format publishes that same length to the host. The mask cost a 65-bit variable
shifter and 64 flops to carry a result nowhere, and was removed along with a
write-only `length_reg`, for 80 flops in total.

`o_pl_len` is authoritative. If a future consumer needs byte granularity within
the final beat, it derives it from the length rather than from a second signal
that can disagree.

**A `default` arm on the state machine.** Two bits encode three states; the
fourth encoding is unreachable and synthesis prunes the arm. It was removed as
noise rather than kept as protection against an event (a single-event upset)
that this design does not otherwise defend against anywhere.

**A parser that reads the payload out of the header beat.** The first version
was a single-beat parser with a 32-byte payload baked into the header beat. That
stopped being possible once the header was padded to a full 64 bytes:
`SSR_OFF_PAYLOAD + P_PAYLOAD_BYTES > 64` made its own elaboration assertion fire
on every build. The padding exists so that frame beat *k* is commit-slot row
*k−1* byte for byte, which is what removes the barrel shifter from both the
transmit and the receive side.

---

## 9. round_id is a pure function of time-of-day, and cannot be truncated

`core.v` SECTION 2 derives the round number from the PTP clock rather than
counting boundaries:

```text
round_id = tod_sec * ROUNDS_PER_SECOND + tod_ns / ROUND_LENGTH_NS
```

That choice is what removes the resync protocol: every node agrees by
construction whenever it was enabled, the value cannot drift because it is
recomputed at every boundary, and a node that reboots re-derives it from the
clock. `ROUND_LENGTH_NS` must divide 1e9 so the second rollover lands exactly on
a boundary, which an elaboration assertion enforces.

### It is dense within a run, and jumps between runs

Inside one run the value increments by exactly one per boundary. It jumps in two
situations, and both change the run id as well:

- the node halts and is later re-activated - time kept flowing, rounds kept
  happening, and the node rejoins at whatever round the clock says;
- a PTP step, a second jump, or time moving backwards raises `o_time_fault`, the
  scheduler disarms, and the FSM halts. Recovery is deliberately manual: the
  control plane must re-activate with a fresh run id, or the node would rejoin
  reusing round ids it has already spoken for.

The sparseness is harmless to `commit_assembler` because `round_id % depth` is
only a hash that picks a slot; identity is settled by the full-width comparison
`slot_round_id[rsel] == round_id` that follows it. A jump simply evicts up to
`P_ROUND_DEPTH` stale slots over the next few rounds, which is correct - those
rounds were abandoned.

### Why 64 bits is load-bearing, not over-provisioning

The obvious saving - carry fewer bits, since only three rounds are ever in
flight - does not survive contact with the numbers. Time-of-day carries the
epoch:

```text
tod_sec           ~1.79e9        (2026, TAI)
ROUNDS_PER_SECOND  250,000       (a 4 us round)
round_id          ~4.47e14       -> 49 bits
```

So 32 bits is short by seventeen, not "good for 4.7 hours". Truncating the
value *inside* the assembler is a different proposal and also fails, for a
second reason: the module receives `i_run_id` but never compares it - the value
is only copied into the slot header. Nothing invalidates stale slots when the
run changes; they are cleared lazily, when a new round happens to land on them.
Full-width round ids make that safe because the ids never repeat. With a
truncated internal id, a stale slot from before a halt can alias a live round
after it, the identity check passes, and two rounds are merged into one slot -
precisely the outcome the eviction logic exists to prevent.

The cheaper shape, if the flops are ever wanted back, is to add the missing
invalidation - clear every slot when `i_run_id` changes, about six lines - and
only then truncate. That trades an implicit dependency for explicit logic, which
is the right direction, but it is a change to working code and not a free win.

---

## 10. The ring wraps by construction, and one wrap is unsafe

`rsel = round_id % P_ROUND_DEPTH` is a direct-mapped index with a single way, so
round R+4 *always* takes round R's slot. The question is never whether the slot
collides; it is whether the previous occupant has finished.

### The normal margin is two rounds

```text
round R      frames arrive, slot opened
round R+2    verdict for R arrives (the measured lag), emit begins
round R+4    round R+4's first frame evicts the slot
```

Two rounds - 2000 cycles at a 4 us round and 250 MHz - against an emit that
takes about 112. Roughly eighteen times over.

### Eviction itself is clean

Eviction clears the present mask, the length table and the taken bit, and
replaces the round id. It does **not** scrub the RAM. The old bytes remain, but
nothing can read them: the emit side only reads a region whose present bit is
set, and the new round sets present bits only for frames it actually receives.
A round is therefore abandoned whole rather than merged, which is the property
the host depends on.

### Three ways a slot is evicted before its verdict

Only the third is a fault:

| cause | why no verdict | expected |
|---|---|---|
| the round did not reach agreement | `o_commit_valid` pulses only when `eval_commits`; a round that does not commit produces no verdict at all | yes |
| halt and re-activation | the rounds in flight are abandoned; up to `P_ROUND_DEPTH` evictions follow each re-activation | yes |
| `commit_buffer` was full when the verdict arrived | the verdict is counted `busy` and **discarded** - it never comes again - so the slot is still untaken when the ring wraps | **no** |

On hardware this gives two distinguishable fingerprints: `o_busy_count` and
`o_evict_count` rising together two rounds apart is the host failing to drain
the commit ring; `o_evict_count` rising alone is rounds failing to agree.

### The unsafe wrap: eviction underneath an emit in progress

Accepting a verdict snapshots `job_rsel`, `job_round`, `job_set` and `job_run`.
It does **not** snapshot the two arrays the emit side keeps reading:

```verilog
wire em_present = slot_present[job_rsel][em_node];
wire [NODE_BEAT_BITS-1:0] em_valid_beats =
        beats_of(slot_len[job_rsel*SSRC_MAX_NODES + em_node]);
```

and the header beat reads them live as well. If the write side evicts
`job_rsel` while the emit is still running, `slot_present[job_rsel]` goes to
zero, `em_real` goes false, and every remaining beat is emitted as zeros - after
a header that already went out carrying the pre-eviction present set and
lengths. The host receives a slot claiming a node delivered 1024 bytes,
followed by 1024 bytes of zeros: not a crash, not a counter, a plausible-looking
wrong result.

Reaching it requires the emit to stall for more than two rounds, which requires
`commit_buffer` to stay full for that long. That state is not hypothetical -
`tb_ssr_dataplane` reaches it whenever the commit ring is left unarmed
(`bufslots=16, cinready=0, emit=1`). The margin, not a mechanism, is what
currently protects the datapath, and the margin disappears in exactly the
scenario hardware meets first: a host that stops keeping up.

**The fix is to snapshot both arrays at accept time**, alongside the fields
already snapshotted - `job_present` at 8 bits and `job_len` at
`P_NODE_COUNT * 16`, so 56 flops at three nodes. The emit side then reads
nothing the write side owns, the two halves are fully decoupled, and the
`@* is sensitive to all N words in array` warnings go with it. It also makes
`job_*` mean one coherent thing: a complete snapshot of one verdict.

---

## 11. The store is two memories, because the two writers never overlap

`commit_assembler` used to hold one array, `store[round][node][beat]`, written
by both sources - the wire side through `i_pl_*` and our own echo through
`i_local_*`. One array means one write port, so the two had to be arbitrated:
the echo cannot be held (tx_engine has already put the frame on the wire), so
it won, and the wire side was stalled for that cycle through `o_pl_ready`.
`o_arb_stall_count` counted how often it happened.

That arbitration was solving a problem that does not exist. The echo writes our
own node's region and nothing else - its node index is `P_NODE_ID`, fixed at
elaboration. The wire side writes some other node's region and nothing else -
`rx_engine` has already rejected any frame whose `node_id` is our own, because
a node does not accept its own broadcast back. So the two address sets are
disjoint *by construction*, not by TDMA scheduling: a node id cannot
simultaneously be `P_NODE_ID` and not be.

Once that is admitted, the store can be split along the line that already
exists:

```
store_self  [P_ROUND_DEPTH            * NODE_BEATS]   written only by the echo
store_peers [P_ROUND_DEPTH * (N-1)    * NODE_BEATS]   written only by the wire
```

with `peer_index(node)` compressing the node id into `0..N-2` by skipping our
own:

```
node <  P_NODE_ID  ->  node
node >  P_NODE_ID  ->  node - 1
```

Each memory now has exactly one writer, so there is no port to arbitrate. The
consequences:

- `o_pl_ready` is tied high. The wire side can never be stalled by the local
  echo, which removes a back-pressure path from `commit_assembler` all the way
  up through `rx_engine` to the MAC.
- `o_arb_stall_count`, its register, its increment and CSR `0x0a4` are gone.
  A counter for an impossible event is worse than no counter: it invites
  someone to read it and conclude something from the zero.
- The emit side gains a 2:1 select (`em_is_self ? store_self : store_peers`)
  but loses nothing, because the read path already had a 512-bit mux -
  `em_real ? store[...] : 0` - and the tool merges them.

**The cost is not zero, it is a trade.** `store_self` is
`P_ROUND_DEPTH * NODE_BEATS` = 4 x 16 = 64 rows of 512 bits = 32 Kib. As BRAM
that is a rounding error; as distributed RAM (`ram_style = "distributed"`) it is
about 512 LUT6. The declaration asks for distributed precisely because it is
small and because keeping it out of BRAM leaves `store_peers` as the only block
RAM in the module. `store_peers` shrank from `P_ROUND_DEPTH * N` to
`P_ROUND_DEPTH * (N-1)` regions - at three nodes, 12 KiB to 8 KiB - so the BRAM
count did not go up either.

### What the bench can and cannot catch here

An address function is easy to test wrongly. Applying *any* bijective
permutation to `peer_addr` - including dropping the `-1` in `peer_index`, or
XOR-ing the low bit - leaves `tb_commit_assembler` at zero errors, because the
write side and the read side call the same function and a consistently permuted
store returns consistent data. The permutation is only observable when two live
entries alias onto one another, and the bench's round sequencing does not
always produce that.

The controls that do bite are **one-sided**: perturb only `em_peer_addr` (230
errors) or point the self read at `store_peers` (119 errors). Those are the ones
worth keeping in mind when this code is touched again - a green run after
changing an address function proves much less than it looks like it does.

### `i_local_last` is now unused

The echo's frame boundary was only ever used to clear `lo_open`, which nothing
read. The length is known at `i_local_sof` and `lo_beat` counts from there, so
the assembler never needs to be told the echo ended. The port is still on the
module because `tx_engine` drives it and `tb_tx_engine` checks it; it is an
unconnected input, not a used one.
