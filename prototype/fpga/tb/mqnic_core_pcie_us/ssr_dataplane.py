#!/usr/bin/env python3
"""
Cocotb driver model for the SSR Corundum application dataplane.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from enum import IntFlag, IntEnum
from typing import Any

from cocotb.log import SimLog
from cocotb.triggers import Timer
from cocotb.utils import get_sim_time

import mqnic
import ssr_verdict
import ssr_packet


# ----------------------------------------------------------
# The register map: rtl/ssr_csr.v, one 4 KiB page. kernel/ssr_regs.h and this
# block are copies of its header; keep all three in step.
# ----------------------------------------------------------

SSR_RB_TYPE     = 0x53535201
SSR_RB_VERSION  = 0x00000200

# identity and build geometry
REG_TYPE        = 0x000
REG_VERSION     = 0x004
REG_NEXT_PTR    = 0x008
REG_SCRATCH     = 0x00C
REG_NODE        = 0x010   # [7:0] this node's id, [15:8] node count
REG_ROUND_NS    = 0x014
REG_GEOMETRY    = 0x018   # node_count | region_shift<<8 | pay_depth_log2<<16 | ver_depth_log2<<24
REG_PAGE_BYTES  = 0x01C
REG_FAULT       = 0x020   # sticky: an internal contract broke (ssr_csr.v, FAULT BITS)

# consensus (ssr_core)
REG_CORE_CONTROL      = 0x100   # bit 0 enable; W bit 1 activate, bit 2 reboot (one-shot)
REG_CORE_STATUS       = 0x104   # bit 0 halted, 1 timing armed, 2 time valid, 3 activation pending, 4 excludes self
REG_CFG_RUN_ID        = 0x108
REG_CFG_MEMBERSHIP    = 0x10C
REG_CFG_EFF_ROUND_LO  = 0x110
REG_CFG_EFF_ROUND_HI  = 0x114
REG_CUR_ROUND_LO      = 0x118
REG_CUR_ROUND_HI      = 0x11C
REG_CUR_RUN_ID        = 0x120
REG_CUR_SOUND_SET     = 0x124
REG_CUR_MEMBERSHIP    = 0x128
REG_HALT_REASON       = 0x140
REG_HALT_ROUND_LO     = 0x144
REG_HALT_ROUND_HI     = 0x148
REG_HALT_WITNESS      = 0x14C   # who agreed with us in the failed evaluation
REG_HALT_MEMBERSHIP   = 0x150
REG_HALT_SOUND_SET    = 0x154

# the proposal ring (ssr_proposal_dma_reader). The host owns a ring of
# 2**depth_log2 entries of one page each. To propose it writes entries at its
# producer index and then writes the new index to PRODUCER: one MMIO write, the
# doorbell. CONSUMER says how many entries are whole on the NIC; an entry below
# it may be overwritten. The same value is in every verdict record
# (proposal_consumer), so a driver need not read it here.
REG_PROP_CONTROL      = 0x200   # bit 0 enable; W bit 1 flush, bit 2 clear error (one-shot)
REG_PROP_STATUS       = 0x204   # bit 0 enabled, 1 idle, 2 error, 3 pending
REG_PROP_ERROR_CODE   = 0x208
REG_PROP_DEPTH_LOG2   = 0x20C
REG_PROP_BASE_LO      = 0x210
REG_PROP_BASE_HI      = 0x214
REG_PROP_PRODUCER     = 0x218
REG_PROP_CONSUMER     = 0x21C
REG_PROP_FETCH        = 0x220
REG_PROP_INFLIGHT     = 0x224

# delivery: two host rings - pages as they arrive, verdict records when a round
# is decided
REG_DLV_CONTROL       = 0x300   # bit 0 payload DMA, bit 1 verdict DMA
REG_DLV_STATUS        = 0x304   # [7:0] unit_idle, [15:8] tag high water
REG_PAY_BASE_LO       = 0x308
REG_PAY_BASE_HI       = 0x30C
REG_VER_BASE_LO       = 0x310
REG_VER_BASE_HI       = 0x314
REG_SEQ_LO            = 0x318
REG_SEQ_HI            = 0x31C

# counters, all read-only and free-running
REG_ROUND_COUNT_LO    = 0x400
REG_ROUND_COUNT_HI    = 0x404
REG_COMMIT_COUNT_LO   = 0x408
REG_COMMIT_COUNT_HI   = 0x40C
REG_HALT_COUNT        = 0x410
REG_TIME_FAULT_COUNT  = 0x414

TX_COUNTERS = {
    "tx_ctrl_frames": 0x440, "tx_pay_frames": 0x444, "tx_empty": 0x448, "tx_overrun": 0x44C,
    "tx_missed": 0x450, "tx_host_frames": 0x454, "tx_cpl_count": 0x458,
}
REG_TX_CPL_TS_0       = 0x45C
REG_TX_CPL_TS_1       = 0x460
REG_TX_CPL_TS_2       = 0x464
RX_COUNTERS = {
    "rx_frames": 0x480, "rx_accept": 0x484, "rx_ctrl": 0x488, "rx_malformed": 0x48C,
    "rx_ctrl_late": 0x490, "rx_window_drop": 0x494, "rx_member_drop": 0x498,
    "rx_sound_drop": 0x49C, "rx_run_drop": 0x4A0, "rx_round_drop": 0x4A4,
    "rx_stall": 0x4A8, "rx_host_frames": 0x4AC, "rx_ack_disagree": 0x4B0,
}
REG_PROP_READS        = 0x4C0
REG_PROP_READ_ERRORS  = 0x4C4
DLV_COUNTERS = {
    "stage_push": 0x500, "stage_full": 0x504, "pay_desc": 0x508, "pay_cpl": 0x50C,
    "pay_err": 0x510, "pay_starve": 0x514, "pres_late": 0x51C,
    "pres_err": 0x520, "pres_err_miss": 0x524, "verdict_records": 0x528,
    "verdict_err": 0x52C, "verdict_overflow": 0x530, "verdict_stale": 0x534,
}

CORE_CTRL_ENABLE   = 0x1
CORE_CTRL_ACTIVATE = 0x2
CORE_CTRL_REBOOT   = 0x4

# ----------------------------------------------------------
#           Helper functions
# ----------------------------------------------------------

def _validate_u32(value: int, name: str) -> None:
    if not (0 <= value <= 0xFFFFFFFF):
        raise ValueError(f"{name} must be a 32-bit unsigned integer, got {value}")

def _validate_u64(value: int, name: str) -> None:
    if not (0 <= value <= 0xFFFFFFFFFFFFFFFF):
        raise ValueError(f"{name} must be a 64-bit unsigned integer, got {value}")

async def poll_register(read_func: Callable[[], Any], condition_func: Callable[[Any], bool], *, timeout_polls: int = 10000, what: str = "register") -> Any:
    for poll_count in range(timeout_polls):
        value = await read_func()
        if condition_func(value):
            return value
        await Timer(100, units="ns")  # wait before next poll
    raise SSRTimeoutError(f"Timeout while polling {what} after {timeout_polls} polls")

# ----------------------------------------------------------
#                   Bit definitions
# ----------------------------------------------------------
class ProposalControl(IntFlag):
    ENABLE      = 1 << 0     # a level
    FLUSH       = 1 << 1     # one-shot
    CLEAR_ERROR = 1 << 2     # one-shot

class ProposalStatus(IntFlag):
    ENABLED     = 1 << 0
    IDLE        = 1 << 1     # no read in flight
    ERROR       = 1 << 2
    PENDING     = 1 << 3     # a flush or clear_error not yet carried out

class DeliveryControl(IntFlag):
    PAYLOAD     = 1 << 0
    VERDICT     = 1 << 1

class CoreStatus(IntFlag):
    HALTED           = 1 << 0
    TIMING_ARMED     = 1 << 1
    TIME_VALID       = 1 << 2
    ACTIVATE_PENDING = 1 << 3     # a configuration waits for its effective round
    EXCLUDES_SELF    = 1 << 4     # the last activation named a membership without this node

# HALT_REASON (ssr_core)
HALT_NONE            = 0
HALT_NO_AGREED_ROW   = 1     # fewer than a quorum of witnesses
HALT_NO_SOUND_SET    = 3
HALT_SELF_EXCLUDED   = 4
HALT_SOUND_SET_GREW  = 5
HALT_TIME_FAULT      = 6


@dataclass(frozen=True)
class HaltRecord:
    """The HALT_* registers: what the failed evaluation saw."""
    reason: int
    round_id: int
    witness: int        # who agreed with us, ourselves included
    membership: int
    sound_set: int      # the set the evaluation produced
    sound_set_before: int

# ----------------------------------------------------------
#                   Data structures
# ----------------------------------------------------------
class SSRDeviceState(IntEnum):
    UNINITIALIZED = 0
    PROBED  = 1
    OPENED  = 2
    RUNNING = 3

@dataclass(frozen=True)
class SSRIdentity:
    """What the bitstream says about itself (NODE, ROUND_NS)."""
    node_id: int
    node_count: int
    round_ns: int

@dataclass(frozen=True)
class DeliveryGeometry:
    """What the driver reads out of GEOMETRY / PAGE_BYTES instead of being
    built against the bitstream's parameters."""
    node_count: int
    region_shift: int
    pay_depth_log2: int
    ver_depth_log2: int
    page_bytes: int

    @property
    def region_bytes(self) -> int:
        return 1 << self.region_shift

    @property
    def slot_bytes(self) -> int:
        """One round's worth of regions: N * REGION."""
        return self.node_count * self.region_bytes

    @property
    def payload_ring_bytes(self) -> int:
        return self.slot_bytes << self.pay_depth_log2

    @property
    def verdict_ring_bytes(self) -> int:
        return ssr_verdict.RECORD_BYTES << self.ver_depth_log2


@dataclass(frozen=True)
class DeliveredRound:
    """A decided round as the host sees it: the record, and the pages the
    record says may be read - already checked against their own headers."""
    record: ssr_verdict.VerdictRecord
    pages: dict[int, list[bytes]]      # node -> [payload of frag 0, frag 1, ...]
    lost_nodes: list[int]
    sim_time_ns: float = 0.0

# ----------------------------------------------------------
#           Error
# ----------------------------------------------------------
class SSRError(Exception):
    """SSR auxiliary driver error"""

class SSRStateError(SSRError):
    """SSR auxiliary driver state error"""

class SSRProbeError(SSRError):
    """SSR auxiliary driver probe error"""

class SSRTimeoutError(SSRError):
    """SSR auxiliary driver timeout error"""

class SSRHardwareError(SSRError):
    """SSR auxiliary driver hardware error"""

# ----------------------------------------------------------
#       Utility functions
# ----------------------------------------------------------

# -----------------------------------------------------------------------------
#                   Proposal queue
# -----------------------------------------------------------------------------
@dataclass(frozen=True)
class ProposalResult:
    first: int          # absolute index of the first entry posted
    count: int
    consumer: int       # CONSUMER when propose() returned


class ProposalRing:
    """
    Host -> NIC. A ring of one-page entries in host memory, read by the NIC.

    Proposing is: wait for room (producer - consumer < depth), write the
    entries at the producer index, ring the doorbell. The NIC reads up to four
    entries at a time and sends them in ring order.
    """
    def __init__(self, device: "SSRDevice") -> None:
        self.device = device
        self.log = SimLog("cocotb.ssr_dataplane.proposal_ring")

        self.rb = device._rb
        self._opened = False

        self._slot_len = 0
        self._depth_log2 = 0
        self._region: Any = None
        self._producer = 0          # free-running, like the NIC's own indices

    def _require_open(self) -> None:
        if not self._opened:
            raise SSRStateError("ProposalRing is not opened")

    @property
    def slot_len(self) -> int:
        self._require_open()
        return self._slot_len

    @property
    def depth(self) -> int:
        self._require_open()
        return 1 << self._depth_log2

    @property
    def producer(self) -> int:
        return self._producer

    # ---- registers ------------------------------------------------------------
    async def read_status(self) -> ProposalStatus:
        return ProposalStatus(int(await self.rb.read_dword(REG_PROP_STATUS)) & 0xF)

    async def read_consumer(self) -> int:
        return int(await self.rb.read_dword(REG_PROP_CONSUMER))

    async def read_fetch(self) -> int:
        return int(await self.rb.read_dword(REG_PROP_FETCH))

    async def read_error_code(self) -> int:
        return int(await self.rb.read_dword(REG_PROP_ERROR_CODE))

    async def _control(self, bits: ProposalControl) -> None:
        await self.rb.write_dword(REG_PROP_CONTROL, int(bits))

    async def _wait_not_pending(self, timeout_polls: int = 10000) -> None:
        await poll_register(lambda: self.rb.read_dword(REG_PROP_STATUS),
                            lambda x: not (x & ProposalStatus.PENDING),
                            timeout_polls=timeout_polls, what="proposal flush / clear_error")

    # ---- lifecycle --------------------------------------------------------------
    async def open(self, *, depth_log2: int = 4) -> None:
        self.log.info("Opening ProposalRing")
        if self._opened:
            raise RuntimeError("ProposalRing is already opened")
        if not 1 <= depth_log2 <= 16:
            raise ValueError("depth_log2 must be 1..16")

        # An entry is a page: PAGE_BYTES.
        self._slot_len = int(await self.rb.read_dword(REG_PAGE_BYTES))
        if self._slot_len != ssr_packet.FRAME_BYTES:
            raise RuntimeError(f"ProposalRing entry is {self._slot_len} bytes, expected {ssr_packet.FRAME_BYTES}")

        self._depth_log2 = depth_log2
        self._region = self.device.alloc_dma_region(self._slot_len << depth_log2, fill=0x00)
        base = self._region.get_absolute_address(0)
        if base & (self._slot_len - 1):
            raise RuntimeError("the proposal ring must be page aligned")

        await self.rb.write_dword(REG_PROP_BASE_LO, base & 0xFFFFFFFF)
        await self.rb.write_dword(REG_PROP_BASE_HI, (base >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(REG_PROP_DEPTH_LOG2, depth_log2)
        # Start from wherever the NIC is: after a reset both are 0, but a
        # re-open must not re-send or skip.
        self._producer = await self.read_consumer()
        await self.rb.write_dword(REG_PROP_PRODUCER, self._producer)
        await self._control(ProposalControl.ENABLE)

        self._opened = True
        self.log.info("ProposalRing opened: %d entries of %d bytes at 0x%x", 1 << depth_log2, self._slot_len, base)

    async def close(self) -> None:
        self._require_open()
        await self._control(ProposalControl(0))
        self._opened = False
        self._region = None

    def _on_parent_reset(self) -> None:
        self._opened = False
        self._region = None

    # ---- the entry layout ---------------------------------------------------
    # An entry has the same shape as the frame it becomes (ssr_packet.vh, "A
    # PROPOSAL ENTRY HAS THE SAME SHAPE AS A FRAME"): slot_len bytes, of which
    # the first OFF_PAYLOAD (64) are left empty for ssr_tx_engine's header and the
    # rest carry one piece of at most FRAG_BYTES (4032). The host therefore
    # cuts its byte stream at 4032, not at 4096; the 64 bytes are padding on
    # purpose, so that a proposal entry, a wire frame and a delivered page are
    # one layout.
    @staticmethod
    def pieces_of(stream: bytes) -> list[bytes]:
        """Cut a byte stream into the <= FRAG_BYTES pieces that go into entries."""
        return ssr_packet.fragment(bytes(stream))

    def build_entry(self, piece: bytes) -> bytes:
        """One slot-sized entry: an empty header beat, the piece at OFF_PAYLOAD,
        zero-padded to the slot. A piece longer than FRAG_BYTES does not fit."""
        self._require_open()
        if not 1 <= len(piece) <= ssr_packet.FRAG_BYTES:
            raise ValueError(f"a proposal piece carries 1..{ssr_packet.FRAG_BYTES} bytes, not {len(piece)}")
        entry = bytearray(self._slot_len)
        entry[ssr_packet.OFF_PAYLOAD:ssr_packet.OFF_PAYLOAD + len(piece)] = piece
        return bytes(entry)

    # ---- high-level API -----------------------------------------------------
    async def propose(self, pieces: list[bytes], *,
                      wait: bool = True,
                      timeout_polls: int = 10000) -> ProposalResult:
        """Post one entry per piece and ring the doorbell. Each piece is
        1..FRAG_BYTES bytes and goes out as one fragment (a short piece is
        zero-padded on the wire; the application frames its own proposals
        inside the stream). With wait, return once every entry is on the NIC
        (CONSUMER has passed them) - not once they are on the wire."""
        self._require_open()
        if not pieces:
            raise ValueError("No pieces provided for proposal")
        depth = 1 << self._depth_log2
        if len(pieces) > depth:
            raise ValueError(f"{len(pieces)} pieces do not fit a ring of {depth}")

        # Room: producer - consumer < depth, counted mod 2**32.
        consumer = await poll_register(
            self.read_consumer,
            lambda c: ((self._producer - c) & 0xFFFFFFFF) + len(pieces) <= depth,
            timeout_polls=timeout_polls, what="room in the proposal ring")

        first = self._producer
        for i, piece in enumerate(pieces):
            off = ((first + i) & (depth - 1)) * self._slot_len
            self._region[off:off + self._slot_len] = self.build_entry(piece)
        self._producer = (first + len(pieces)) & 0xFFFFFFFF
        await self.rb.write_dword(REG_PROP_PRODUCER, self._producer)

        if wait:
            consumer = await poll_register(
                self.read_consumer,
                lambda c: ((self._producer - c) & 0xFFFFFFFF) == 0,
                timeout_polls=timeout_polls, what="proposal reads")
            status = await self.read_status()
            if status & ProposalStatus.ERROR:
                raise SSRHardwareError(f"proposal read failed: status={status}, "
                                       f"code={await self.read_error_code()}, consumer={consumer}")
        return ProposalResult(first=first, count=len(pieces), consumer=consumer)

    async def propose_stream(self, stream: bytes, **kw) -> ProposalResult:
        """The application's byte stream for a round, cut at FRAG_BYTES."""
        return await self.propose(self.pieces_of(stream), **kw)

    async def clear_error(self) -> None:
        """After a failed read: the NIC re-reads the failed entry and every
        entry after it, in order. Nothing to re-post."""
        self._require_open()
        await self._control(ProposalControl.ENABLE | ProposalControl.CLEAR_ERROR)
        await self._wait_not_pending()

    async def flush(self) -> None:
        """Drop every posted entry that is not yet on the wire. Costs the round
        in progress if it had announced fragments; do it with the core stopped.
        Entries posted before this returns are flushed too."""
        self._require_open()
        await self._control(ProposalControl.ENABLE | ProposalControl.FLUSH)
        await self._wait_not_pending()


# -----------------------------------------------------------------------------
#                   Delivery
# -----------------------------------------------------------------------------
class Delivery:
    """
    NIC -> host, speculatively. Two rings in host memory, both allocated here
    and handed to the hardware by base address:

      - the PAYLOAD ring: one region per (round mod D, node), one page per
        fragment, written as fragments ARRIVE, a round and a control period
        before anyone knows whether the round commits;
      - the VERDICT ring: one 64-byte record per decided round, written after
        every page of that round has landed (the hardware's fence), saying
        which regions may be read.

    The host polls the verdict ring for the next seq. A record is the ONLY
    permission to read a region; a page carries its frame header on top so it
    can be checked against the record rather than trusted.
    """
    def __init__(self, device: "SSRDevice") -> None:
        self.device = device
        self.log = SimLog("cocotb.ssr_dataplane.delivery")
        self.rb = device._rb

        self._opened = False
        self._geometry: DeliveryGeometry | None = None
        self._pay_region: Any = None
        self._ver_region: Any = None
        self._next_seq = 0

    def _require_open(self) -> None:
        if not self._opened:
            raise SSRStateError("Delivery is not opened")

    @property
    def geometry(self) -> DeliveryGeometry:
        self._require_open()
        assert self._geometry is not None
        return self._geometry

    async def read_geometry(self) -> DeliveryGeometry:
        g = int(await self.rb.read_dword(REG_GEOMETRY))
        page = int(await self.rb.read_dword(REG_PAGE_BYTES))
        return DeliveryGeometry(node_count=g & 0xFF, region_shift=(g >> 8) & 0xFF,
                                pay_depth_log2=(g >> 16) & 0xFF, ver_depth_log2=(g >> 24) & 0xFF,
                                page_bytes=page)

    async def read_seq(self) -> int:
        lo = int(await self.rb.read_dword(REG_SEQ_LO))
        hi = int(await self.rb.read_dword(REG_SEQ_HI))
        return (hi << 32) | lo

    async def read_counters(self) -> dict[str, int]:
        return {name: int(await self.rb.read_dword(reg)) for name, reg in DLV_COUNTERS.items()}

    async def read_fault(self) -> int:
        """FAULT: non-zero means an internal contract broke somewhere."""
        return int(await self.rb.read_dword(REG_FAULT))

    async def open(self) -> None:
        """Read the geometry, allocate both rings, program their bases. The
        enables stay off until start()."""
        if self._opened:
            raise RuntimeError("Delivery is already opened")

        self._geometry = await self.read_geometry()
        g = self._geometry
        if g.page_bytes != ssr_packet.FRAME_BYTES:
            raise RuntimeError(f"PAGE_BYTES {g.page_bytes} does not match ssr_packet.FRAME_BYTES {ssr_packet.FRAME_BYTES}")
        if g.node_count == 0 or g.region_shift < 12:
            raise RuntimeError(f"implausible delivery geometry: {g}")

        self._pay_region = self.device.alloc_dma_region(g.payload_ring_bytes, fill=0x00)
        self._ver_region = self.device.alloc_dma_region(g.verdict_ring_bytes, fill=0x00)
        pay_base = self._pay_region.get_absolute_address(0)
        ver_base = self._ver_region.get_absolute_address(0)
        if pay_base & (g.page_bytes - 1) or ver_base & (ssr_verdict.RECORD_BYTES - 1):
            raise RuntimeError("ring bases must be page / record aligned")

        await self.rb.write_dword(REG_PAY_BASE_LO, pay_base & 0xFFFFFFFF)
        await self.rb.write_dword(REG_PAY_BASE_HI, (pay_base >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(REG_VER_BASE_LO, ver_base & 0xFFFFFFFF)
        await self.rb.write_dword(REG_VER_BASE_HI, (ver_base >> 32) & 0xFFFFFFFF)

        self._next_seq = await self.read_seq()
        self._opened = True
        self.log.info("Delivery opened: %s, payload ring %d bytes at 0x%x, verdict ring %d bytes at 0x%x, next seq %d",
                      g, g.payload_ring_bytes, pay_base, g.verdict_ring_bytes, ver_base, self._next_seq)

    async def start(self) -> None:
        self._require_open()
        await self.rb.write_dword(REG_DLV_CONTROL, int(DeliveryControl.PAYLOAD | DeliveryControl.VERDICT))

    async def stop(self) -> None:
        self._require_open()
        await self.rb.write_dword(REG_DLV_CONTROL, 0)

    async def close(self) -> None:
        if self._opened:
            await self.stop()
        self._opened = False
        self._pay_region = None
        self._ver_region = None

    def _on_parent_reset(self) -> None:
        self._opened = False
        self._pay_region = None
        self._ver_region = None

    # ---- reading what the hardware wrote ----
    def read_record(self, seq: int) -> ssr_verdict.VerdictRecord:
        self._require_open()
        off = ssr_verdict.record_offset(seq, verdict_depth_log2=self.geometry.ver_depth_log2)
        return ssr_verdict.decode(bytes(self._ver_region[off:off + ssr_verdict.RECORD_BYTES]))

    def read_page(self, round_id: int, node: int, frag_idx: int) -> bytes:
        """The whole page: 64 bytes of frame header, then the payload."""
        self._require_open()
        g = self.geometry
        off = ssr_verdict.page_offset(round_id, node, frag_idx, node_count=g.node_count,
                                     region_shift=g.region_shift, host_depth_log2=g.pay_depth_log2)
        return bytes(self._pay_region[off:off + g.page_bytes])

    def read_payload(self, round_id: int, node: int, frag_idx: int, *, verify: bool = True) -> bytes:
        """The payload of one fragment, checked against the header on its page."""
        page = self.read_page(round_id, node, frag_idx)
        hdr = ssr_packet.decode(page)
        if verify:
            if hdr.kind != ssr_packet.KIND_PAYLOAD or hdr.round_id != round_id \
                    or hdr.node_id != node or hdr.frag_idx != frag_idx:
                raise SSRHardwareError(
                    f"page (round {round_id}, node {node}, frag {frag_idx}) carries a header for "
                    f"kind {hdr.kind} round {hdr.round_id} node {hdr.node_id} frag {hdr.frag_idx}")
        return page[ssr_packet.OFF_PAYLOAD:ssr_packet.OFF_PAYLOAD + hdr.length]

    async def recv(self, *, timeout_polls: int = 10000, interval_ns: int = 200) -> DeliveredRound:
        """Wait for the next verdict record and assemble the round it decides:
        pages 0..frag_count[k]-1 of every node whose copy here is intact.
        Committed pages whose DMA failed are reported as lost."""
        self._require_open()
        seq = self._next_seq
        for _ in range(timeout_polls):
            rec = self.read_record(seq)
            # The ring entry is stale until the hardware's seq catches up; the
            # record's own seq field is the freshness proof.
            if rec.seq == seq and (await self.read_seq()) > seq:
                break
            await Timer(interval_ns, units="ns")
        else:
            raise SSRTimeoutError(f"no verdict record with seq {seq} after {timeout_polls} polls")

        pages: dict[int, list[bytes]] = {}
        for node in rec.readable_nodes():
            if node == rec.self_index:
                continue    # our own region is never written: the host proposed those bytes
            pages[node] = [self.read_payload(rec.round_id, node, f) for f in range(rec.frag_counts[node])]
        self._next_seq = seq + 1
        return DeliveredRound(record=rec, pages=pages, lost_nodes=rec.lost_nodes(),
                              sim_time_ns=get_sim_time("ns"))

# -----------------------------------------------------------------------------
#            Consensus core
# -----------------------------------------------------------------------------
class ConsensusCore:
    """ssr_core, through its registers in ssr_csr (0x100, 0x140)."""
    def __init__(self, device: "SSRDevice") -> None:
        self.device = device
        self.log = SimLog("cocotb.ssr_dataplane.ssr_core")
        self.rb = device._rb
        self._last_run_id = 0

    async def read_status(self) -> CoreStatus:
        return CoreStatus(int(await self.rb.read_dword(REG_CORE_STATUS)) & 0x1F)

    async def read_halt(self) -> bool:
        return bool(await self.read_status() & CoreStatus.HALTED)

    async def read_run_id(self) -> int:
        return int(await self.rb.read_dword(REG_CUR_RUN_ID))

    async def read_sound_set(self) -> int:
        return int(await self.rb.read_dword(REG_CUR_SOUND_SET)) & 0xFF

    async def read_round_id(self) -> int:
        lo = int(await self.rb.read_dword(REG_CUR_ROUND_LO))
        hi = int(await self.rb.read_dword(REG_CUR_ROUND_HI))
        return (hi << 32) | lo

    async def read_commit_count(self) -> int:
        lo = int(await self.rb.read_dword(REG_COMMIT_COUNT_LO))
        hi = int(await self.rb.read_dword(REG_COMMIT_COUNT_HI))
        return (hi << 32) | lo

    async def read_halt_reason(self) -> int:
        return int(await self.rb.read_dword(REG_HALT_REASON))

    async def read_halt_record(self) -> HaltRecord:
        lo = int(await self.rb.read_dword(REG_HALT_ROUND_LO))
        hi = int(await self.rb.read_dword(REG_HALT_ROUND_HI))
        sound = int(await self.rb.read_dword(REG_HALT_SOUND_SET))
        return HaltRecord(reason=await self.read_halt_reason(), round_id=(hi << 32) | lo,
                          witness=int(await self.rb.read_dword(REG_HALT_WITNESS)) & 0xFF,
                          membership=int(await self.rb.read_dword(REG_HALT_MEMBERSHIP)) & 0xFF,
                          sound_set=sound & 0xFF, sound_set_before=(sound >> 8) & 0xFF)

    async def read_halt_count(self) -> int:
        return int(await self.rb.read_dword(REG_HALT_COUNT))

    async def read_round_count(self) -> int:
        lo = int(await self.rb.read_dword(REG_ROUND_COUNT_LO))
        hi = int(await self.rb.read_dword(REG_ROUND_COUNT_HI))
        return (hi << 32) | lo

    async def read_tx_counters(self) -> dict[str, int]:
        return {name: int(await self.rb.read_dword(reg)) for name, reg in TX_COUNTERS.items()}

    async def read_rx_counters(self) -> dict[str, int]:
        return {name: int(await self.rb.read_dword(reg)) for name, reg in RX_COUNTERS.items()}

    async def activate(self, *, run_id: int, membership: int, effective_round: int = 0x100) -> None:
        """Install a configuration and activate at the next boundary at or
        after effective_round. CONTROL = enable | activate; activate is a
        pulse, enable is a level."""
        _validate_u32(run_id, "run_id")
        _validate_u32(membership, "membership")
        await self.rb.write_dword(REG_CFG_RUN_ID, run_id)
        await self.rb.write_dword(REG_CFG_MEMBERSHIP, membership)
        await self.rb.write_dword(REG_CFG_EFF_ROUND_LO, effective_round & 0xFFFFFFFF)
        await self.rb.write_dword(REG_CFG_EFF_ROUND_HI, (effective_round >> 32) & 0xFFFFFFFF)
        await self.rb.write_dword(REG_CORE_CONTROL, CORE_CTRL_ENABLE | CORE_CTRL_ACTIVATE)
        self._last_run_id = run_id
        self.log.info("ConsensusCore activation requested: run_id=0x%x membership=0x%02x effective round %d",
                      run_id, membership, effective_round)

    async def reboot(self) -> None:
        await self.rb.write_dword(REG_CORE_CONTROL, CORE_CTRL_ENABLE | CORE_CTRL_REBOOT)

    async def disable(self) -> None:
        await self.rb.write_dword(REG_CORE_CONTROL, 0)

    async def wait_running(self, *, run_id: int | None = None, timeout_polls: int = 10000) -> None:
        """Running: the run id the config named is installed (the one given, or
        the last activate()'s), the activation is no longer pending and the
        node is not halted."""
        want = self._last_run_id if run_id is None else run_id
        try:
            await poll_register(lambda: self.rb.read_dword(REG_CUR_RUN_ID),
                                lambda x: int(x) == want,
                                timeout_polls=timeout_polls, what=f"activation of run 0x{want:x}")
            await poll_register(lambda: self.rb.read_dword(REG_CORE_STATUS),
                                lambda x: not (int(x) & CoreStatus.ACTIVATE_PENDING),
                                timeout_polls=timeout_polls, what="activation no longer pending")
        except SSRTimeoutError as exc:
            raise SSRTimeoutError(f"ConsensusCore never activated run 0x{want:x}") from exc
        await self.assert_not_halted()

    async def recover(self, *, run_id: int, membership: int, effective_round: int) -> HaltRecord:
        """What a driver does after a halt: read the halt record, reboot the
        core (clears the halt, drops the pipeline), install a FRESH run id and
        activate. The caller decides run_id and membership from the record."""
        rec = await self.read_halt_record()
        await self.reboot()
        await self.activate(run_id=run_id, membership=membership, effective_round=effective_round)
        return rec

    async def wait_halt(self, *, timeout_polls: int = 10000) -> bool:
        try:
            await poll_register(lambda: self.rb.read_dword(REG_CORE_STATUS),
                                lambda x: int(x) & CoreStatus.HALTED,
                                timeout_polls=timeout_polls, what="consensus halt")
            return True
        except SSRTimeoutError:
            return False

    async def assert_not_halted(self) -> None:
        if await self.read_halt():
            raise SSRHardwareError(f"ConsensusCore is halted, reason {await self.read_halt_reason()}")

    async def _diagnose(self) -> str:
        return (f"ConsensusCore: status={await self.read_status()!r} run_id={await self.read_run_id()} "
                f"sound_set=0x{await self.read_sound_set():02x} round={await self.read_round_id()} "
                f"commits={await self.read_commit_count()} halt_reason={await self.read_halt_reason()}")

# -----------------------------------------------------------------------------
#               Top-level SSR auxiliary-driver model
# -----------------------------------------------------------------------------

class SSRDevice:
    """
    Cocotb model of the SSR auxiliary application driver.
    """

    def __init__(self) -> None:
        self.log = SimLog("cocotb.ssr_dataplane")

        self._state = SSRDeviceState.UNINITIALIZED

        # Resources borrowed from the already initialized parent MQNIC driver.
        self.mdev: Any = None
        self.mem_pool: Any = None
        self.app_hw_regs: Any = None
        self._reg_blks: Any = None

        # SSR child objects created by probe().
        self._proposal: ProposalRing | None = None
        self._delivery: Delivery | None = None

        self._bound = False
        self._consensus: ConsensusCore | None = None

    @property
    def state(self) -> SSRDeviceState:
        return self._state

    @property
    def proposal(self) -> ProposalRing:
        if self._proposal is None:
            raise RuntimeError("ProposalRing is not initialized")
        return self._proposal

    @property
    def delivery(self) -> Delivery:
        if self._delivery is None:
            raise RuntimeError("Delivery is not initialized")
        return self._delivery
    
    @property
    def consensus(self) -> ConsensusCore:
        if self._consensus is None:
            raise RuntimeError("ConsensusCore is not initialized")
        return self._consensus

    def _require_state(self, *allowed_states: SSRDeviceState) -> None:
        if self._state not in allowed_states:
            raise RuntimeError(
                f"SSR auxiliary driver is in state {self._state.name}, "
                f"but one of {[s.name for s in allowed_states]} is required"
            )

    async def probe(self, mqnic_driver: Any) -> None:
        """
        Probe the SSR auxiliary device and bind it to the parent MQNIC driver.
            1. Bind to the parent MQNIC device
            2. Enumerate the register blocks in the application BAR
            3. Validate the SSR identity and features
            4. Create the ProposalRing, Delivery and ConsensusCore objects
        """
        self.log.info("Probing SSR auxiliary device")
        self._require_state(SSRDeviceState.UNINITIALIZED)

        assert mqnic_driver is not None, "parent mqnic driver is required"
        assert mqnic_driver.initialized, "parent mqnic driver must be initialized"
        assert mqnic_driver.app_hw_regs is not None, "parent mqnic driver must expose an application BAR"

        self.mdev = mqnic_driver
        self._mem_pool = mqnic_driver.pool      # the parent driver's DMA memory pool
        self._app_hw_regs = mqnic_driver.app_hw_regs
        self.log.info("SSR auxiliary driver bound successfully")

        # enumerate the register blocks in the application BAR
        self.log.info("Enumerating SSR application register blocks")
        self._reg_blks = mqnic.RegBlockList()
        await self._reg_blks.enumerate_reg_blocks(self._app_hw_regs)

        # find the SSR register block and validate its identity
        self._rb = self._reg_blks.find(SSR_RB_TYPE, SSR_RB_VERSION)
        if self._rb is None:
            raise RuntimeError(
                f"SSR register block not found in application BAR; "
                f"expected type=0x{SSR_RB_TYPE:08x}, version=0x{SSR_RB_VERSION:08x}"
            )

        self._proposal = ProposalRing(self)
        self._delivery = Delivery(self)
        self._consensus = ConsensusCore(self)

        self._state = SSRDeviceState.PROBED

    async def open(self) -> None:
        """
        Open the SSR auxiliary device:
            1. Acquire control of the proposal and commit DMA engines
            2. Allocate DMA buffers
            3. Configure the proposal and commit DMA engines
            4. Initialize the producer/consumer index
            5. Make sure the hardware is ready to accept proposals and generate commits
        """
        self.log.info("Opening SSR auxiliary device")
        self._require_state(SSRDeviceState.PROBED)

        await self._proposal.open()
        await self._delivery.open()

        self._state = SSRDeviceState.OPENED

    async def reset(self) -> None:
        """
        Reset the SSR auxiliary device:
            1. Stop the proposal and commit DMA engines
            2. Release DMA buffers
            3. Release control of the proposal and commit DMA engines
            4. Re-acquire control of the proposal and commit DMA engines
            5. Re-allocate DMA buffers
            6. Re-configure the proposal and commit DMA engines
            7. Re-initialize the producer/consumer index
            8. Make sure the hardware is ready to accept proposals and generate commits
        """
        self._require_state(SSRDeviceState.OPENED,
                            SSRDeviceState.PROBED,
                            SSRDeviceState.RUNNING,
                            SSRDeviceState.UNINITIALIZED)


        self._state = SSRDeviceState.UNINITIALIZED

    async def start(self) -> None:
        """Turn delivery on. Done BEFORE the core is activated, the way a
        driver would post its rings before joining the cluster: a node whose
        host is not taking delivery stops calling its peers present and halts."""
        self._require_state(SSRDeviceState.OPENED)
        await self._delivery.start()
        self._state = SSRDeviceState.RUNNING

    async def stop(self) -> None:
        self._require_state(SSRDeviceState.RUNNING)
        await self._delivery.stop()
        self._state = SSRDeviceState.OPENED

    async def close(self) -> None:
        """Stop the core, stop delivery, disable the proposal ring, drop the
        rings. The device is back to PROBED: open() may be called again."""
        self._require_state(SSRDeviceState.OPENED, SSRDeviceState.RUNNING)
        await self._consensus.disable()
        if self._state == SSRDeviceState.RUNNING:
            await self._delivery.stop()
        await self._proposal.close()
        await self._delivery.close()
        self._state = SSRDeviceState.PROBED

    async def remove(self) -> None:
        """
        Remove the SSR auxiliary device:
            1. Stop the proposal and commit DMA engines
            2. Release DMA buffers
            3. Release control of the proposal and commit DMA engines
            4. Unbind from the parent MQNIC driver
        """
        self._require_state(SSRDeviceState.PROBED)


        self._state = SSRDeviceState.UNINITIALIZED

    async def read_identity(self) -> SSRIdentity:
        """Who this node is and how long a round is. These are build-time
        parameters of the bitstream; the driver reads them, it cannot set them."""
        node = int(await self._rb.read_dword(REG_NODE))
        return SSRIdentity(node_id=node & 0xFF, node_count=(node >> 8) & 0xFF,
                           round_ns=int(await self._rb.read_dword(REG_ROUND_NS)))

    def alloc_dma_region(self, size: int, fill: int = 0x00) -> Any:
        """
        Allocate a DMA region of the given size and fill it with the specified byte value.
        """
        if self._mem_pool is None:
            raise RuntimeError("DMA pool is not initialized")

        region = self._mem_pool.alloc_region(size)
        if region is None:
            raise RuntimeError("Failed to allocate DMA region")

        region[:] = bytes([fill] * size)
        return region
