"""SSR verdict record - Python mirror of rtl/ssr_verdict.vh.

Both files describe the same bytes, the same way ssr_packet.py and
ssr_packet.vh do. Change one, change the other.

Under speculative delivery the host does not receive a round's payload when
the round is decided. It receives it as it ARRIVES: every fragment is DMA'd
into the host's payload ring the moment it lands, a round and a control period
before anyone knows whether the round will commit. What arrives at decision time is this
record - 64 bytes that say which of those pages the host may now read.

    offset  size  field
    ------  ----  -----------------------------------------------------------
         0     8  round_id      the round this record decides. NOT the round in
                               which it was written - ssr_core decides
                               round R at round R+1's control deadline.
         8     8  seq           record number, from 0 at reset, never repeating.
                               The proof a ring entry is new, and its index.
        16     4  run_id        fences configurations, same value as the frames
        20     1  commit_set    bitmap: the SOUND SET this decision left in force,
                               who is still in. It does not gate reads.
        21     1  present_set   bitmap: this host's copy of node k's pages is
                               intact (no DMA error for this round)
        22     1  node_count    the cluster size this record was built for
        23     1  self_index    this node's index: which region is its own
        24    16  frag_count[0..7]  2 bytes each: the COMMITTED PREFIX - pages
                               0..frag_count[k]-1 of node k's region are decided
        40     4  proposal_consumer  the proposal ring's consumer index
    ---------------- reserved ----------------
        44    20  zero.

Multi-byte fields are network byte order.

WHERE THE PAGES ARE
    Node k's region for round R is at

        payload_base + ((R mod D_HOST) * N + k) << REGION_SHIFT

    and page f of it is at + (f << 12). Every page carries the frame header it
    arrived with in its first 64 bytes and the payload from offset 64. D_HOST,
    N and REGION_SHIFT come from the GEOMETRY register (ssr_csr, 0x018).

READ PAGES 0 .. frag_count[k]-1 OF NODE k WHERE present_set[k].
    frag_count is the protocol's decision: the prefix of each node's
    fragments a quorum agreed it holds (docs/count_ack.md). present_set is a
    fact about bytes on this host: a page DMA of node k's failed. The ack
    reports the wire, so such a node is committed all the same - committed but
    not present, a loss the host should count rather than read as zero.
    commit_set says who is still in: a node with a non-zero count outside it
    left in this round, and those pages are its last.
    readable_nodes() is the intended accessor; lost_nodes() is the fault.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

OFF_ROUND_ID = 0
OFF_SEQ = 8
OFF_RUN_ID = 16
OFF_COMMIT_SET = 20
OFF_PRESENT_SET = 21
OFF_NODE_COUNT = 22
OFF_SELF_INDEX = 23
OFF_FRAG_COUNTS = 24      # 2 bytes per node, node k at OFF_FRAG_COUNTS + 2*k
OFF_PROP_CONSUMER = 40    # u32: the proposal ring's consumer index (flow control)
OFF_RESERVED = 44

RESERVED_BYTES = 20
RECORD_BYTES = 64

PAGE_BYTES = 4096
PAGE_PAYLOAD_OFFSET = 64  # the frame header sits on top of every page

# The count table is fixed at eight entries so the record stays one beat
# whatever the cluster size.
MAX_NODES = 8

# round_id Q, seq Q, run_id I, commit_set B, present_set B, node_count B,
# self_index B, then 8 counts H, then proposal_consumer I
RECORD_FIELDS = struct.Struct("!QQIBBBB" + "H" * MAX_NODES + "I")
RECORD_USED_BYTES = RECORD_FIELDS.size          # 44

assert RECORD_USED_BYTES == OFF_RESERVED
assert OFF_RESERVED + RESERVED_BYTES == RECORD_BYTES


@dataclass
class VerdictRecord:
    round_id: int
    seq: int
    run_id: int
    commit_set: int
    present_set: int
    node_count: int
    self_index: int
    frag_counts: tuple[int, ...]    # MAX_NODES entries
    proposal_consumer: int = 0      # the proposal ring's consumer when written

    def readable_nodes(self) -> list[int]:
        """Nodes with committed pages that reached this host."""
        return [n for n in range(self.node_count)
                if self.frag_counts[n] > 0 and (self.present_set >> n) & 1]

    def lost_nodes(self) -> list[int]:
        """Nodes with committed pages this host's copy of is broken. A
        non-empty list is a fault to count, not a set of empty proposals."""
        return [n for n in range(self.node_count)
                if self.frag_counts[n] > 0 and not (self.present_set >> n) & 1]

    def departed_nodes(self) -> list[int]:
        """Nodes whose committed pages here are their last: they left the
        sound set in this round."""
        return [n for n in range(self.node_count)
                if self.frag_counts[n] > 0 and not (self.commit_set >> n) & 1]


def region_offset(round_id: int, node: int, *, node_count: int,
                  region_shift: int, host_depth_log2: int) -> int:
    """Byte offset of node's region for round_id inside the payload ring."""
    region_index = (round_id % (1 << host_depth_log2)) * node_count + node
    return region_index << region_shift


def page_offset(round_id: int, node: int, frag_idx: int, **geometry) -> int:
    """Byte offset of one page inside the payload ring."""
    return region_offset(round_id, node, **geometry) + (frag_idx << 12)


def record_offset(seq: int, *, verdict_depth_log2: int) -> int:
    """Byte offset of record seq inside the verdict ring."""
    return (seq % (1 << verdict_depth_log2)) * RECORD_BYTES


def encode(*, round_id: int, seq: int, run_id: int, commit_set: int,
           present_set: int, node_count: int, self_index: int,
           frag_counts, proposal_consumer: int = 0) -> bytes:
    """One complete 64-byte record, reserved bytes zeroed."""
    counts = list(frag_counts) + [0] * (MAX_NODES - len(frag_counts))
    if len(counts) != MAX_NODES:
        raise ValueError(f"at most {MAX_NODES} counts, got {len(frag_counts)}")
    rec = RECORD_FIELDS.pack(round_id, seq, run_id, commit_set, present_set,
                             node_count, self_index, *counts, proposal_consumer)
    assert len(rec) == RECORD_USED_BYTES
    return rec + b"\x00" * RESERVED_BYTES


def decode(raw: bytes) -> VerdictRecord:
    """Parse a record straight out of the host ring."""
    if len(raw) < RECORD_BYTES:
        raise ValueError(f"record is {len(raw)} bytes, shorter than {RECORD_BYTES}")

    fields = RECORD_FIELDS.unpack(raw[:RECORD_USED_BYTES])
    round_id, seq, run_id, commit_set, present_set, node_count, self_index = fields[:7]
    frag_counts = fields[7:7 + MAX_NODES]
    proposal_consumer = fields[7 + MAX_NODES]

    if node_count > MAX_NODES:
        raise ValueError(f"record claims {node_count} nodes, the format holds {MAX_NODES}")

    return VerdictRecord(round_id=round_id, seq=seq, run_id=run_id,
                         commit_set=commit_set, present_set=present_set,
                         node_count=node_count, self_index=self_index,
                         frag_counts=frag_counts, proposal_consumer=proposal_consumer)
