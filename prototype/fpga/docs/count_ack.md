# Count Acks: Sending Mid-Round

**Status:** design record, **implemented** (§10 lists what was built and what the
benches found). Where this disagrees with `round_structure.md` §6–7 or
`speculative_delivery.md`, this record wins. The open decisions of §9 are settled:
a proposal never spans ring entries, and the halt record keeps the witness mask.

**In one paragraph.** Today a node announces at the top of round R how many fragments it
will send in R, and a proposal arriving after that announcement waits for R+1. This record
drops the announcement. A node sends whatever arrives, whenever it arrives, until a cutoff
near the end of the round. The control frame at the top of R+1 then reports what happened
in R, as a vector of counts: how many fragments I hold from each peer, and how many I sent.
The protocol rule is unchanged: a node is a witness when its row equals mine, a quorum of
witnesses commits my row. The only difference is that a row is now 8 counts rather than
8 bits. Data completeness needs no rule of its own, because it is part of that equality.
That equality is tested in `ssr_rx_engine`'s ladder, so the core never sees a count. It
only learns "node k is trusted for this round". The decision point is unchanged: R is
decided at R+1's control deadline. Mean
arrival-to-decision latency drops from about 6.3 µs to 3.3 µs.

| | today | this record |
|---|---|---|
| the row about R | 8 bits: "I hold k's whole proposal" | 8 × u8: "I hold the first `c[k]` fragments of k", `c[self]` = sent |
| announcement for R | `frag_count` in R's control frame | none |
| when R's payload may start | only if it was in the buffer at R's control frame | any time in `[466, 3341]` ns of R |
| who checks completeness | tracker: `count >= expected` | the witness test (row equality) |
| what is committed for node k | all announced fragments, or none | the agreed prefix `c[k]` |
| worst / mean arrival → decision | 8.3 / 6.3 µs | 5.3 / 3.3 µs |

---

## 1. Why

The announcement is what made "sent nothing" distinguishable from "sent something and lost
it all" (`round_structure.md` §7.1). It has a cost: `ssr_tx_engine` reads
`i_buf_slot_count` once, at the control frame, and that number is the whole of the
round's plan. Anything the host DMAs into the proposal buffer after about 332 ns waits a
full round:

```text
round R                                          round R+1                  round R+2
|ctrl@332|----------- payload -----------|      |ctrl|---- payload ----|      |ctrl|dec@678
    ^ plan fixed here
          ^ proposal arrives at 400 ns: not in R's plan
                                                 announced + sent in R+1 ─────────► decided
```

That costs 3.7 µs of dead waiting for most arrivals. The announcement was only ever
needed because the receiver had nothing else to count against. If the count arrives
afterwards, inside the row, the receiver never needs a forecast.

## 2. The idea

Node i's control frame at the top of R+1 carries a vector `a_i` about round R:

```text
a_i[k]  (k != i)   how many of k's round-R fragments i holds, as a contiguous prefix
a_i[i]             how many round-R fragments i sent
```

Everyone broadcasts one such vector, so every node sees the same matrix. The core then
does exactly what it does today, with vectors in place of bits:

```text
witness(k)  = a_k == a_self                  (k's row, as received, equals mine)
agreed      = a_self, if |witnesses| >= QUORUM
commit      = for every k, the first agreed[k] fragments of k's round-R region
sound set   = witnesses
```

Timeline, one round:

```text
0      332  466                                     3341        4000 = boundary R→R+1
|dead | C  |gap| F0 ··pace·· F1 ··· F2 ··· F3 ··· F4 |  no new F  |
       ^ control frame of R: carries a_self about R−1
            ^ payload of R may start: whatever the buffer holds, paced
                                                     ^ last admission
                                                                  ^ the tracker's counts
                                                                    for R are final: a_self
R+1:   332: control frame carries a_self about R    678: R decided
```

What each node sends in R is known to itself by the boundary, and what it holds from
everyone else is also known by the boundary. So the row about R can be computed at the
boundary and broadcast at 332 ns, the same instant as today. That is why no extra round
appears.

## 3. The completeness check is the witness test

It is tempting to add a rule: "compare k's claimed send count with what I received from
k, and reject k if they differ." This rule is not needed, because it is one coordinate of
the equality the core already tests. `a_k[k]` is k's send count, `a_self[k]` is what I
hold from k, and `a_k == a_self` includes `a_k[k] == a_self[k]`.

The whole vector has to be compared, not just that coordinate:

**The single-coordinate check is unsafe.** Take 3 nodes. In R, A sends 2 fragments;
B gets both, C loses the second.

```text
a_A = [2, x, y]   a_B = [2, x, y]   a_C = [1, x, y]
```

At C, B's self-claim matches what C got from B, so a check of only `a_B[B]` passes. A's
self-claim of 2 fails against C's 1, so C rejects A. C still sees B plus itself, which is
a quorum, so C commits. But C holds one fragment of A where A and B hold two. With the
full-vector test C sees `a_B != a_C`, has no quorum and halts. A and B commit two
fragments. This is today's fail-fast, unchanged.

**The completeness verdict has to come from the rows, not from a local check.** Suppose
A's second fragment is lost at *every* receiver, for example because A's own transmit
path dropped it.

```text
a_A = [2, x, y]   a_B = [1, x, y]   a_C = [1, x, y]
```

- **Full-vector test:** B and C agree with each other and commit the first fragment of A.
  A has no witness, drops out of both sound sets and halts. Only A pays.
- **Bit rows plus a local "claim ≠ received" check:** B and C each reject A locally.
  Nothing in any row says so, so the agreed row still names A. Every node must then halt
  (nobody holds what the row promises), or commit different amounts. One bad sender takes
  down the cluster.

**Safety** is the usual quorum-intersection argument, now over vectors:

- Two nodes that commit R each have a quorum whose rows equal their own.
- The two quorums share a node m. Because m broadcast one frame, it has one vector, so
  both committers' vectors equal m's and therefore each other.
- Each committer's vector is what it holds, so every committer holds exactly `agreed[k]`
  fragments of every k.

Nothing in the argument needs k's own claim to be believed. The claim only decides
whether k itself is a witness.

**Why prefix counts.** `c[k]` counts fragment `frag_idx == c[k]` and nothing past a gap.
Otherwise one lost fragment plus one duplicated fragment would count as "all of them".
On one link frames arrive in order, so a gap means loss, and fragments after it are
ignored for counting. They are still DMA'd, because placement is by `frag_idx`, but no
agreed prefix will ever cover them.

### 3.1 What changes semantically: a prefix can be committed

Today a node's round is all-or-nothing. Here, the agreed `c[k]` can be smaller than what
k sent, as in the second example above, or when k crashes mid-round after its first few
fragments reached everyone. The cluster then commits that prefix.

This is the only semantic change, and it is forced. With mid-round sending, "how much k
meant to send" is not a fact anyone else can know, so the only thing the cluster can
agree on is what it holds. From the cluster's point of view, a committed prefix looks
exactly like k having had fewer entries to send. In every such case k is not a witness,
so k halts or has already crashed. A healthy node's round is still all-or-nothing in
practice.

**The consequence for the application:** a committed prefix ends on a fragment boundary,
which is a proposal-ring entry boundary. If a proposal may span two ring entries, the
last committed entry of a node that left the sound set can hold a half proposal. The
cleanest rule is that **a proposal never spans ring entries** (at most 4032 B, one or
more whole proposals per entry). The alternative is for the host to discard a trailing
partial proposal from a node that is no longer in the sound set. See §9.

## 4. Where the comparison lives

There are two correct placements. Both compare the whole vector.

**(X) In the core, as today.** `ssr_rx_engine` forwards each control frame's vector and
the core stores N peer rows. Its existing loop compares each peer row to its own. The
rows grow from 8 to 64 bits: 8 × 64 flops plus 8 comparators of 64 bits each.

**(Y) In the receive ladder.** `ssr_rx_engine` compares an accepted control frame's
vector against our own row for the same round, which it reads from the tracker. A
mismatch is one more rung, `ACK_DISAGREE`, with its own counter. A control frame that
clears every rung (run, round, sound set, and now the ack) means one thing to the core:
**node k is trusted for this round**. The core ORs those pulses into a witness mask and
checks quorum.

**This record takes (Y).** It is the same pattern the ladder already follows: the
receive filter lives in `ssr_rx_engine` and nowhere else, and it reads its inputs
combinationally (run, round, sound set). "Does this row match mine" is one more such
test. The core ends up with the simplest possible rule: witnesses = who was trusted,
commit if there is a quorum. The rx engine gains no state, only a 64-bit compare.

**The core never handles a count.** Our own vector has three users, and the tracker can
feed each of them directly, so nothing passes through the core:

| user | what it needs | from |
|---|---|---|
| `ssr_tx_engine` | the `ack` field of our control frame in R+1 | tracker: counts for R |
| `ssr_rx_engine` | the vector a peer's ack must equal | tracker: counts for R |
| `ssr_verdict_dma_writer` | `frag_count[k]` of the committed round | tracker query B, as today |

This works because the counts for R are final at the boundary into R+1. The rx round
filter drops anything later, the cutoff (§5) makes sure nothing legitimate is later, and
a DMA error does not touch counts (§7). The tracker holds R's slot for 4 rounds, so the
same value is read every time with no latch. In the other direction, the core tells the
tracker only when a round opens (the boundary pulse), which it already emits.

Details that make (Y) exact:

- **Our row for the round being evaluated.** A peer's control frame for R+1 carries its
  ack about R. The rung compares it with the tracker's counts for R (`i_rx_round_id − 1`).
  These are stable for the whole control period, like the other filter inputs.
- **The rung goes last, and applies to control frames only.** It comes after run, round
  and sound set, so the existing counters keep their meaning. Payload frames never reach
  it.
- **A disagreeing frame is valid evidence, not a bad frame.** Its counter is a protocol
  statistic and does **not** go into FAULT.
- **What the core loses:**
  - The peer-row storage, the compare loop and `eval_row_self_missing`, which has no
    meaning for counts.
  - The peer rows in the halt record (`HALT_ROWS_*`). These would be 8 × 64 bits anyway.
    The halt record keeps the witness mask. Our own vector for the halted round can still
    be read from the tracker. If peer vectors are needed for debugging, the rx engine can
    latch the last disagreeing vector per peer, as a diagnostic only.

## 5. Timing

**Admission window.** A fragment of round R may **start** on our clock during
`[TX_PAY_START_NS, TX_PAY_CUTOFF_NS]`:

```text
TX_PAY_START_NS  = TX_START_NS + SSR_CTRL_NS + PAY_GAP_NS
                 = 332 + 6 + 128                                   = 466
TX_PAY_CUTOFF_NS = ROUND_LENGTH_NS − SSR_FRAME_NS − PROP_DEAD_NS − GUARD_TIME_NS − PRESENT_SETTLE_NS
                 = 4000 − 327 − 250 − 50 − 32                      = 3341
```

- **The start** is today's: payload never goes ahead of our own control frame and the
  skew gap (`ssr_tx_engine` banner, "the gap before the payload is not padding").
- **The cutoff** guarantees that a fragment started at the cutoff is staged at every peer
  before that peer's boundary, even when that peer's clock is `g` ahead. That is what
  makes the tracker's counts final when the core samples them. A fragment started later
  would land after the sample. The sender would count it and the receivers would not, so
  their rows would disagree and the sender would lose its round.
- **Beyond the cutoff:** once it passes, nothing more is admitted for R. What is left in
  the buffer goes out in R+1, and nothing is dropped.

**Capacity is unchanged.** Paced starts land at 466, 1121, 1776, 2431 and 3086, and the
next one (3741) is past the cutoff. That is 5 fragments, the same `P_FRAGS_PER_ROUND` as
today. The `LAST_ARRIVAL_NS` elaboration check in `ssr_dataplane` becomes
`TX_PAY_CUTOFF_NS ≥ TX_PAY_START_NS` plus "`P_FRAGS_PER_ROUND` paced starts fit before
the cutoff".

**The window is a single admission bound, not TDMA.** There is still no per-node slot.
`ssr_tx_engine` needs one more input from the core, an `o_tx_pay_open` level. Today it
needs none, because the plan fixed the end of the round. Without a plan, something has
to.

**Latency.** Measured from "the proposal is in the FPGA buffer" to R's decision at R+1's
678 ns, for an arrival uniform over the round, ignoring queueing behind other fragments:

| | best | mean | worst |
|---|---|---|---|
| today (plan fixed at 332 ns) | 4.35 µs | 6.35 µs | 8.35 µs |
| count acks (cutoff 3341 ns) | 1.34 µs | 3.34 µs | 5.34 µs |

The decision instant does not move. What moves is the fraction of the round in which an
arrival still makes it into the current round: from 332/4000 to 3341/4000.

## 6. Frame format (`ssr_packet.vh`)

| field | today | this record |
|---|---|---|
| `row` @15, 1 B | bit row (control frame) | reserved, 0 |
| `frag_count` @34, 2 B | announcement / repeat | reserved, 0 |
| `ack` @36, 8 B | reserved | **control frame:** `a[0..7]`, one byte per node; payload frame: 0 |
| `frag_idx` @32 | fragment index | unchanged: the prefix count needs it |

- **One byte per entry** is enough: `P_FRAGS_PER_ROUND ≤ SSR_MAX_FRAGS = 64`. Entries
  for nodes at or above `P_NODE_COUNT` are 0.
- **A payload frame no longer repeats a count**, because none is known when it is sent.
  The host page header stays self-describing about *which* fragment it is (`frag_idx`),
  and *how many* are meaningful comes from the verdict record.
- **Receiver geometry check:** `frag_idx < frag_count` becomes
  `frag_idx < P_FRAGS_PER_ROUND`.

## 7. Module change list

**`ssr_tx_engine`**
- Delete the plan (`frags_reg`, `plan_frags`, `i_buf_slot_count`) and the local
  announcement (`o_local_announce/_round/_count`).
- After our control frame and the skew gap: while `i_tx_pay_open`, the buffer holds a
  whole slot and `frag_idx < P_FRAGS_PER_ROUND`, send a fragment, then pace.
- New output: `o_local_sent`, one pulse per fragment sent, with `(round, frag_idx)`.
- The control frame's `ack` (`i_tx_ack`, 64 bits) comes from the tracker's counts for
  the previous round, instead of `i_tx_row` from the core.
- `o_empty_count` becomes "rounds in which we sent no fragment".

**`ssr_rx_engine`**
- The control frame outputs to the core become one `(node)` pulse meaning "trusted for
  this round". The row and the announcement outputs go away.
- New combinational input `i_rx_self_ack` (64 bits, from the tracker) and a new last rung
  for control frames, `ack != i_rx_self_ack`, counted in `o_ack_disagree_count`.
- The geometry check drops `frag_count`.

**`ssr_presence_tracker` → counts only**
- No announcement, no `expected`, no `announced`. The core's boundary pulse opens R's
  slot and clears its counts.
- `count[k]` increments on a staged fragment of k only if `frag_idx == count[k]`.
  `count[self]` increments on `o_local_sent`.
- Query A becomes the 64-bit count vector of the previous round, fed to both tx
  (`ack`) and rx (the rung). Query B returns counts plus the per-node `failed` bit, for
  the verdict record.
- The open, evict and late counters lose their meaning. Payload is filtered to the
  current round upstream, so "late" cannot happen here. They go.

**`ssr_core`**
- No counts in or out: `i_present_row`, `o_present_round_id` and `o_tx_row` go.
- Delete the peer-row storage and the compare loop. On an rx "trusted" pulse, set the
  witness bit. Self is always a witness of itself.
- Evaluation: `agreed_valid = popcount(witness) >= QUORUM`. The sound set is the witness
  mask. The shrink-only check is unchanged.
- The commit output carries the round and the new sound set. What was committed is our
  own vector for that round, which the verdict writer reads from the tracker.
- New level `o_tx_pay_open`, high from the round boundary to `TX_PAY_CUTOFF_NS`, gated
  by `protocol_active`. The start of the window needs no level: `ssr_tx_engine` only
  sends payload after its own control frame and the skew gap.
- `HALT_COMMIT_SET_INVALID` stays unreachable, as it effectively is today.

**Verdict record (`ssr_verdict.vh`)**
- `frag_count[k]` becomes the **committed prefix**. It can be read from tracker query B
  as today, because counts are final at the boundary and the round filter stops anything
  later.
- `commit_set` **stays**, but its meaning changes to the sound set after this round (who
  is still in).
  - Its old job, "whose data is in this commit", is now done by `frag_count`: every
    member's agreed prefix is committed, and it may be 0.
  - Its new job is the one thing the counts cannot say. A node with
    `frag_count[k] > 0` and `commit_set[k] = 0` left in this round, and this is its last
    prefix (§3.1). With `frag_count[k] = 0`, the field tells "alive, proposed nothing"
    apart from "gone".
- The host rule becomes: read pages `0 .. frag_count[k]−1` of node k where
  `present_set[k]`. `commit_set` does not gate the read.
- A DMA error still clears `present_set[k]`, and the row does not see it. The row reports
  what arrived on the wire, and `present_set` reports whether this host's copy is intact.
  This merges today's two cases, before and after the row sample, into the "after" case.

**Around it**
- `ssr_dataplane`: the new timing localparams and the elaboration checks of §5.
- `ssr_csr`: `RX_ACK_DISAGREE` at 0x4B0. The tracker counters are gone. The halt record
  swaps `HALT_ROWS_*` for the witness mask.
- `ssr_packet.py`, `ssr_verdict.py`, `ssr_regs.h` and the `mqnic_app_ssr.ko` sysfs
  dump: mirrors.
- `round_structure.md` §6–7, `commit_path.md` §3.1 and §7, and the dataplane guide and
  walkthrough: rewrite the "announcement" passages when this lands.

## 8. Test plan

| test | stimulus | expected |
|---|---|---|
| mid-round arrival | a proposal enters the buffer at ~2 µs of R | sent in R, committed at R+1's 678 ns; latency < 3 µs |
| cutoff | a proposal enters just before / just after `TX_PAY_CUTOFF_NS` | before: sent in R; after: sent in R+1; nothing lost |
| capacity | a deep buffer | exactly 5 fragments per round, paced, last one staged at every peer before its boundary |
| idle round | nobody sends | all vectors are 0 and equal; commits with empty prefixes, not a halt |
| one receiver loses a fragment | drop A's F1 at C only | A and B commit 2 of A's; C sees `ACK_DISAGREE` from both, then halts |
| sender short everywhere | drop A's F1 at every receiver | B and C commit 1 of A's; A has no witness and halts |
| gap, then more | drop A's F1 at C, deliver F2 | C counts 1, not 2 (prefix) |
| crash mid-round | A stops after F1, sends no control frame | B and C commit A's prefix of 2; A leaves the sound set |
| **negative control** | compare only the self coordinate in the rung | the "one receiver loses a fragment" case: C commits a count it does not hold; the bench must catch it |
| **negative control** | cutoff moved up by one frame time | the last fragment lands after a peer's sample; that sender loses its round |

## 9. Decisions

1. **Proposal atomicity (§3.1):** a proposal never spans ring entries. It is the
   application's rule, stated in `ssr_packet.vh`; the fabric does not check it.
2. **Halt diagnostics:** the halt record keeps the witness mask (`HALT_WITNESS`, 0x14C).
   Peer vectors are not latched.
3. **Verdict `commit_set`:** kept, meaning the sound set after the decision.

## 10. As built

**Modules.** Everything in §7 was done as written, with these specifics:

- `ssr_presence_tracker` opens a round on `ssr_core`'s **ungated** `o_round_start_pulse`,
  so the round a node activates in is open too (the protocol-gated boundary pulse
  does not fire on the activation boundary). Only the open round counts; anything
  for another round goes to `PRES_LATE`. `o_prev_ack` is re-read every cycle rather
  than latched, so a fragment counted on the boundary cycle itself is in it.
- `ssr_tx_engine` admits a fragment only when the buffer is already offering the
  slot's first beat, and takes that beat the same cycle, so a flush cannot pull the
  slot away from a composed header.
- `ssr_core` has no peer rows and no present row. `HALT_REASON` 2 (commit set
  invalid) is retired.
- `ssr_csr`: `HALT_SELF_ROW` became `HALT_WITNESS` (0x14C); `HALT_ROWS_LO/HI`
  (0x158/0x15C) and `PRES_EVICT` (0x518) are gone; `RX_ACK_DISAGREE` is 0x4B0.
- `ssr_proposal_buffer`'s `o_buf_slot_count` is unconnected in `ssr_dataplane`;
  nothing plans a round.

**What the benches found.**

- **The window reopened before the control frame.** `pay_run_reg` used to be
  cleared only by the next start pulse. The pay level rises again at the boundary,
  a whole dead zone earlier, so a slot waiting there went out stamped with the
  round that had just ended: every receiver drops it, and the sender halts.
  `tb_ssr_dataplane` B6 caught it under port back pressure. The fix is one line
  (`pay_run_reg` is cleared whenever the level is low), and `tb_ssr_tx_engine` R5
  now pins it.
- **Sound sets may legitimately differ between nodes.** If a node's control frame
  in R+1 reaches nobody, the others drop it at R's decision while it, still hearing
  them, keeps them. Both sides commit the same vector for R. So
  `tb_ssr_core_protocol`'s agreement monitor compares committed vectors, not
  `o_commit_set`. The old bit-row design hid this, because there the sound set and
  the committed row were the same value.

**Benches.**

- `tb_ssr_dataplane`'s peers compute their acks from what they and the DUT put on
  the wire, so a peer is trusted exactly when a real one would be.
- New dataplane tests: B7 (nothing starts after the cutoff; then 5, then 3), B8 (a
  mid-round proposal goes out in its round), E14 (the ack rung), H1 (a short peer:
  no witness, its prefix committed, out of the sound set), I3 (a control frame on
  the deadline's last cycle still makes a witness).
- The cocotb harness models acks the same way.

**Open: the cutoff assumes the port is ours.** A fragment admitted at the cutoff can
still wait behind a host frame already in `ssr_tx_mux` (SSR wins only at frame
boundaries). A 9 KB jumbo frame is about 0.74 µs at 100G, more than the margin
between the cutoff and a peer's boundary. The fragment then lands late, the peers
do not count it, and this node loses its round. There are two ways out:

- Subtract one maximum host frame from `TX_PAY_CUTOFF_NS`. At a 9 KB MTU that costs
  one fragment per round.
- Have `ssr_tx_mux` start no host frame in the last MTU-time before the cutoff.

Neither is built. Today the exposure is bounded by host MTU and only matters when
host traffic shares the SSR port. (2026-09-25: the host will not use SSR's
interface in the first deployment, so this stays open.)

**Open: the ack comparison does not mask the sound set.** `ssr_rx_engine`
accepts a control frame only if its whole 64-bit ack equals ours, byte for
byte, including the bytes of nodes no longer in the sound set. In the round a
node is dropped, its fragments that arrive before the deadline are still
counted (the sound rung only closes at the evaluation, ~676 ns), and two
survivors may have counted a different number of them by then. Their bytes
for the dropped node then differ, one of them finds no witness, and it halts
for nothing. `tb_ssr_dataplane` H1 and cocotb's `run_test_ssr_short_peer` step
around it by having the dropped node send only its control frame in that
round. The fix is small: mask the compared vector by the current sound set
(in the ladder, or in the tracker's `o_prev_ack`), and add the negative
control. Deferred until the first bitstream is on the board.
