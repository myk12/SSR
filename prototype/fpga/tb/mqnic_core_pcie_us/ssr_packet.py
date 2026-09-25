"""SSR wire format - Python mirror of rtl/ssr_packet.vh.

Both files describe the same bytes. They have disagreed three ways before (a
64-bit run_id in the old consensus_tx, a 32-bit one here, different field orders
in both), which is why the layout now lives in exactly two places that name each
other. Change one, change the other.

A FRAME IS A PAGE: 64 bytes of header and up to 4032 of payload, 4096 in all,
so that a fragment lands in exactly one host page with its header on top.

    offset  size  field
    ------  ----  -----------------------------------------------------------
         0     6  destination MAC
         6     6  source MAC
        12     2  ethertype - 0x88B5, IEEE 802 local experimental. The frame is
                  identified by this alone; there is no magic or version field.
    ---------------- consensus header ----------------
        14     1  node_id      sender's replica id
        15     1  reserved, 0  (was the row)
        16     4  run_id       fences configurations; a mismatch is dropped
        20     8  round_id     the round this frame belongs to
        28     2  length       THIS frame's payload bytes. Zero on a control
                               frame, 1..4032 on a fragment.
        30     1  kind         1 = CTRL (one per node per round, first),
                               2 = PAYLOAD (a fragment)
        31     1  flags        reserved, no bits defined
        32     2  frag_idx     which fragment of the round this is (0 on CTRL)
        34     2  reserved, 0  (was frag_count)
        36     8  ack[0..7]    CONTROL FRAME ONLY: the sender's ack vector about
                               the PREVIOUS round, one byte per node - how many
                               of node k's fragments it holds (a prefix), and
                               for itself how many it sent. docs/count_ack.md.
    ---------------- reserved ----------------
        44    20  zero. Padding that pushes the payload to a beat boundary.
    ---------------- payload ----------------
        64     N  up to FRAG_BYTES (4032)

Multi-byte fields are network byte order.

INDEX, NOT OFFSET
    A node's payload for one round is a run of proposal entries, one per
    fragment, and a frame says which by index. A proposal never spans two
    entries: the cluster may commit a prefix of a node's fragments, and a
    prefix must not end in half a proposal.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass

ETHERTYPE = 0x88B5

OFF_DST_MAC = 0
OFF_SRC_MAC = 6
OFF_ETHERTYPE = 12
OFF_NODE_ID = 14
OFF_RUN_ID = 16
OFF_ROUND_ID = 20
OFF_LENGTH = 28
OFF_KIND = 30
OFF_FLAGS = 31
OFF_FRAG_IDX = 32
OFF_ACK = 36            # 8 single bytes, node k at OFF_ACK + k
ACK_BYTES = 8
OFF_RESERVED = 44
OFF_PAYLOAD = 64

KIND_CTRL = 1
KIND_PAYLOAD = 2

ETH_HEADER_BYTES = 14
# node_id B, reserved B, run_id I, round_id Q, length H, kind B, flags B,
# frag_idx H, reserved H, ack 8s
CONSENSUS_HEADER = struct.Struct("!BBIQHBBHH8s")
CONSENSUS_HEADER_BYTES = CONSENSUS_HEADER.size          # 30
HEADER_USED_BYTES = ETH_HEADER_BYTES + CONSENSUS_HEADER_BYTES   # 44 carry fields
HEADER_BEAT_BYTES = 64
HEADER_BYTES = HEADER_BEAT_BYTES

FRAME_BYTES = 4096                      # one page
FRAG_BYTES = FRAME_BYTES - OFF_PAYLOAD  # 4032 of payload
MAX_FRAGS = 64                          # the format's ceiling; the cluster's
                                        # P_FRAGS_PER_ROUND is the real bound

# Ethernet pads to 60 bytes before the FCS.
MIN_FRAME_BYTES = 60

assert OFF_PAYLOAD == HEADER_BYTES
assert HEADER_USED_BYTES == OFF_RESERVED
assert CONSENSUS_HEADER_BYTES == 30


@dataclass
class SSRFrame:
    dst_mac: bytes
    src_mac: bytes
    eth_type: int

    node_id: int
    run_id: int
    round_id: int
    kind: int
    frag_idx: int
    ack: tuple[int, ...]        # ACK_BYTES entries; all zero on a fragment
    payload: bytes

    @property
    def length(self) -> int:
        return len(self.payload)

    @property
    def is_ctrl(self) -> bool:
        return self.kind == KIND_CTRL


def encode_consensus_header(*, node_id: int, run_id: int, round_id: int, length: int,
                            kind: int, frag_idx: int, ack=()) -> bytes:
    """The 30 field bytes only. Callers that build a whole frame must pad the
    header out to HEADER_BEAT_BYTES - see encode_header_beat."""
    ack = list(ack) + [0] * (ACK_BYTES - len(ack))
    if len(ack) != ACK_BYTES or not all(0 <= a <= 0xFF for a in ack):
        raise ValueError(f"ack must be at most {ACK_BYTES} bytes, got {ack}")
    return CONSENSUS_HEADER.pack(node_id, 0, run_id, round_id, length, kind, 0,
                                 frag_idx, 0, bytes(ack))


def encode_header_beat(*, dst_mac: bytes, src_mac: bytes, node_id: int, run_id: int,
                       round_id: int, length: int, kind: int, frag_idx: int, ack=()) -> bytes:
    """One complete 64-byte header beat, reserved bytes zeroed."""
    beat = (bytes(dst_mac) + bytes(src_mac) + ETHERTYPE.to_bytes(2, "big")
            + encode_consensus_header(node_id=node_id, run_id=run_id, round_id=round_id,
                                      length=length, kind=kind, frag_idx=frag_idx, ack=ack))
    assert len(beat) == HEADER_USED_BYTES
    return beat + b"\x00" * (HEADER_BEAT_BYTES - HEADER_USED_BYTES)


def encode_ctrl_frame(*, dst_mac: bytes, src_mac: bytes, node_id: int, run_id: int,
                      round_id: int, ack) -> bytes:
    """A control frame: the header beat alone, carrying the sender's ack
    vector about the previous round (ack[k] = fragments of node k it holds,
    its own entry = fragments it sent)."""
    return encode_header_beat(dst_mac=dst_mac, src_mac=src_mac, node_id=node_id,
                              run_id=run_id, round_id=round_id, length=0, kind=KIND_CTRL,
                              frag_idx=0, ack=ack)


def encode_payload_frame(*, dst_mac: bytes, src_mac: bytes, node_id: int, run_id: int,
                         round_id: int, frag_idx: int, payload: bytes) -> bytes:
    """One fragment: the header beat and 1..FRAG_BYTES of payload. No ack."""
    if not 1 <= len(payload) <= FRAG_BYTES:
        raise ValueError(f"a fragment carries 1..{FRAG_BYTES} bytes, not {len(payload)}")
    if not 0 <= frag_idx < MAX_FRAGS:
        raise ValueError(f"frag_idx {frag_idx} outside [0, {MAX_FRAGS})")
    return encode_header_beat(dst_mac=dst_mac, src_mac=src_mac, node_id=node_id,
                              run_id=run_id, round_id=round_id, length=len(payload),
                              kind=KIND_PAYLOAD, frag_idx=frag_idx) + bytes(payload)


def fragment(stream: bytes) -> list[bytes]:
    """Cut a node's payload for one round into FRAG_BYTES pieces (one proposal
    entry each; a real application puts whole proposals in each)."""
    return [stream[i:i + FRAG_BYTES] for i in range(0, len(stream), FRAG_BYTES)]


def decode_consensus_header(raw: bytes) -> tuple:
    """-> (node_id, run_id, round_id, length, kind, flags, frag_idx, ack)"""
    (node_id, _r0, run_id, round_id, length, kind, flags, frag_idx, _r1,
     ack) = CONSENSUS_HEADER.unpack(raw[:CONSENSUS_HEADER_BYTES])
    return node_id, run_id, round_id, length, kind, flags, frag_idx, tuple(ack)


def decode(frame: bytes) -> SSRFrame:
    """Parse a frame (or the first 64 bytes of a host page, which is the same
    thing: the header rides on top of the page it arrived in)."""
    if len(frame) < HEADER_BYTES:
        raise ValueError(f"frame is {len(frame)} bytes, shorter than its header")
    eth_type = int.from_bytes(frame[OFF_ETHERTYPE:OFF_ETHERTYPE + 2], "big")
    (node_id, run_id, round_id, length, kind, _flags,
     frag_idx, ack) = decode_consensus_header(frame[ETH_HEADER_BYTES:])
    return SSRFrame(dst_mac=bytes(frame[OFF_DST_MAC:OFF_DST_MAC + 6]),
                    src_mac=bytes(frame[OFF_SRC_MAC:OFF_SRC_MAC + 6]),
                    eth_type=eth_type, node_id=node_id, run_id=run_id,
                    round_id=round_id, kind=kind, frag_idx=frag_idx, ack=ack,
                    payload=bytes(frame[OFF_PAYLOAD:OFF_PAYLOAD + length]))
