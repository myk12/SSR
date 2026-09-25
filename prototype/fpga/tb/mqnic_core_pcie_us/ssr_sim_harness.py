"""The peers, on the port.

SSRSimHarness plays every node of the cluster except the one under test, the
way tb_ssr_dataplane's SECTION 13 does: at the transmit instant of every round
(TX_START_NS, 332 ns in, the same instant the RTL node sends) it puts each
peer's control frame, then each peer's fragments, onto the port's receive side
through the cocotbext-eth MAC model. It also collects everything the RTL node
transmits: SSR frames go to recv(), anything else to recv_host().

A control frame carries its sender's ACK VECTOR about the round before
(docs/count_ack.md): for each node, how many of its fragments the sender holds,
and for itself how many it sent. The harness computes it from what the peers
put on the wire and what it saw the RTL node send - so a peer agrees with the
RTL node exactly when a real one would, and a peer with peer_short set (it
delivers fewer fragments than it believes it sent) does not. A node in
`excluded` is one the surviving peers have dropped from their sound set: their
acks report 0 for it whatever it sends, as a real survivor's would.

The harness does not implement the protocol. It reads the round id and run id
out of the RTL - a real cluster's clocks are disciplined together, and
modelling that agreement separately would be modelling the wrong thing - and
builds the frames from scratch with ssr_packet.

    harness = SSRSimHarness(dut_port=tb.port_mac[0], ..., cluster_config=cfg)
    harness.peer_payload = {1: b"...", 2: b"..."}   # per round, per peer
    harness.start()

Knobs (peer_payload, peer_enabled, peer_short, peer_run_id, excluded) are read
when a round is built, at TX_START_NS into it. Change them in the quiet part
of the round before the one they are for - `await harness.midround()` - so a
build never sees a change under it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Sequence

import cocotb
from cocotb.log import SimLog
from cocotb.queue import Queue
from cocotb.triggers import RisingEdge, ReadOnly, Timer

import ssr_packet


def mac_bytes(mac: str) -> bytes:
    return bytes(int(b, 16) for b in mac.split(":"))


# Where in the round a real peer transmits: ssr_dataplane's TX_START_NS
# (P_PROP_DEAD_NS + P_GUARD_NS + P_PRESENT_SETTLE_NS = 250 + 50 + 32). Through
# Corundum's receive path a frame sent here reaches ssr_rx_engine some 70-100 ns
# later, well inside the 646 ns control window.
TX_START_NS = 332
ROUND_NS = 4000


@dataclass(frozen=True)
class ClusterConfig:
    num_nodes: int
    mac_addresses: Sequence[str]
    eth_type: int = ssr_packet.ETHERTYPE
    rtl_node_id: int = 0            # the node ID of the RTL node under test

    def __post_init__(self):
        if self.num_nodes != len(self.mac_addresses):
            raise ValueError("Number of nodes must match the length of mac_addresses")
        if self.num_nodes > 7:
            raise ValueError("Number of nodes must be <= 7")


class SSRSimHarness:
    def __init__(self, *,
                 dut_port: Any,
                 round_start_pulse: Any,
                 round_id: Any,
                 run_id: Any,
                 cluster_config: ClusterConfig,
                 tx_offset_ns: int = TX_START_NS,
                 frame_gap_ns: int = 0) -> None:
        self.log = SimLog("cocotb.SSRSimHarness")
        self._cfg = cluster_config
        self._dut_port = dut_port
        self._round_start_pulse = round_start_pulse
        self._round_id = round_id
        self._run_id = run_id
        self._tx_offset_ns = tx_offset_ns
        self._frame_gap_ns = frame_gap_ns

        peers = [n for n in range(cluster_config.num_nodes) if n != cluster_config.rtl_node_id]
        # What each peer sends, per round. A test changes these between rounds.
        self.peer_payload: dict[int, bytes] = {n: b"" for n in peers}
        self.peer_enabled: dict[int, bool] = {n: True for n in peers}
        # Deliver only this many fragments while believing all were sent.
        self.peer_short: dict[int, int | None] = {n: None for n in peers}
        # Send with this run id instead of the RTL's (a stale peer).
        self.peer_run_id: dict[int, int | None] = {n: None for n in peers}
        # Nodes the surviving peers no longer believe: their acks say 0 for them.
        self.excluded: set[int] = set()

        # The ack model's inputs, by round: what each peer sent (believed,
        # delivered) and how many fragments the RTL node put on the wire.
        self._peer_log: dict[int, dict[int, tuple[int, int]]] = {}
        self._rtl_sent: dict[int, int] = {}
        self._built_round = -1

        self._batches: Queue = Queue()
        self._received: Queue = Queue()
        self._host_received: Queue = Queue()
        self._running = False
        self._tasks: list = []
        self.rounds_sent = 0
        self.frames_sent = 0
        self.late_rtl_fragments = 0     # RTL fragments seen after their round's acks were built

    def start(self) -> None:
        if self._running:
            raise RuntimeError("Harness already running")
        self._running = True
        self._tasks.append(cocotb.start_soon(self._round_monitor()))
        self._tasks.append(cocotb.start_soon(self._send_frames()))
        self._tasks.append(cocotb.start_soon(self._recv_frames()))
        self.log.info("SSR simulation harness started")

    def stop(self) -> None:
        self._running = False
        for t in self._tasks:
            t.cancel()
        self._tasks = []

    # ---- building a round ----
    def ack_for(self, node: int, round_id: int) -> list[int]:
        """Peer `node`'s ack vector about round_id: its own belief, what every
        other peer delivered, what the RTL node sent, 0 for anyone excluded."""
        cfg = self._cfg
        log = self._peer_log.get(round_id, {})
        ack = []
        for k in range(cfg.num_nodes):
            if k == node:
                ack.append(log.get(k, (0, 0))[0])
            elif k in self.excluded:
                ack.append(0)
            elif k == cfg.rtl_node_id:
                ack.append(self._rtl_sent.get(round_id, 0))
            else:
                ack.append(log.get(k, (0, 0))[1])
        return ack

    def build_round(self, round_id: int, run_id: int) -> list[bytes]:
        """Every peer's control frame first - they all go inside the control
        deadline - then every peer's fragments."""
        cfg = self._cfg
        dst = mac_bytes(cfg.mac_addresses[cfg.rtl_node_id])
        ctrl: list[bytes] = []
        frags: list[bytes] = []
        log: dict[int, tuple[int, int]] = {}
        for node in sorted(self.peer_payload):
            if not self.peer_enabled[node]:
                continue
            src = mac_bytes(cfg.mac_addresses[node])
            rid = run_id if self.peer_run_id[node] is None else self.peer_run_id[node]
            ctrl.append(ssr_packet.encode_ctrl_frame(
                dst_mac=dst, src_mac=src, node_id=node, run_id=rid, round_id=round_id,
                ack=self.ack_for(node, round_id - 1)))
            pieces = ssr_packet.fragment(self.peer_payload[node])
            send = len(pieces) if self.peer_short[node] is None else self.peer_short[node]
            log[node] = (len(pieces), send)
            for idx in range(send):
                frags.append(ssr_packet.encode_payload_frame(
                    dst_mac=dst, src_mac=src, node_id=node, run_id=rid, round_id=round_id,
                    frag_idx=idx, payload=pieces[idx]))
        self._peer_log[round_id] = log
        self._built_round = round_id
        # Rounds far behind are no longer anyone's ack.
        for old in [r for r in self._peer_log if r < round_id - 8]:
            del self._peer_log[old]
        for old in [r for r in self._rtl_sent if r < round_id - 8]:
            del self._rtl_sent[old]
        return ctrl + frags

    async def midround(self) -> None:
        """The quiet middle of the next round: the peers have spoken, the RTL's
        fragments for it may still be leaving, the next build is ~2 us away.
        Change the knobs here."""
        await RisingEdge(self._round_start_pulse)
        await Timer(ROUND_NS // 2, units="ns")

    async def _round_monitor(self) -> None:
        while self._running:
            await RisingEdge(self._round_start_pulse)
            # Build at the transmit instant, not on the pulse: on the activation
            # boundary the core installs the new run id on that same edge, and
            # a peer that reads the old one sends a whole round the RTL drops
            # for its run. Every fragment the RTL admitted before the previous
            # round's cutoff has also long left the port by now, so the acks
            # about that round see all of them.
            await Timer(self._tx_offset_ns, units="ns")
            await ReadOnly()
            round_id = int(self._round_id.value)
            run_id = int(self._run_id.value)
            frames = self.build_round(round_id, run_id)
            self.rounds_sent += 1
            await self._batches.put(frames)

    async def _send_frames(self) -> None:
        while self._running:
            frames = await self._batches.get()
            for frame in frames:
                await self._dut_port.rx.send(frame)
                self.frames_sent += 1
                if self._frame_gap_ns > 0:
                    await Timer(self._frame_gap_ns, units="ns")

    async def _recv_frames(self) -> None:
        while self._running:
            frame = await self._dut_port.tx.recv()
            raw = bytes(frame.data) if hasattr(frame, "data") else bytes(frame)
            eth_type = int.from_bytes(raw[12:14], "big") if len(raw) >= 14 else 0
            if eth_type != self._cfg.eth_type:
                await self._host_received.put(raw)      # the host's own traffic
                continue
            try:
                decoded = ssr_packet.decode(raw)
            except Exception as e:
                self.log.warning("undecodable SSR frame from the DUT: %s", e)
                continue
            if not decoded.is_ctrl:
                self._rtl_sent[decoded.round_id] = self._rtl_sent.get(decoded.round_id, 0) + 1
                if decoded.round_id <= self._built_round - 1:
                    # The peers' acks about that round are already on the wire
                    # without this fragment: the RTL will find them short.
                    self.late_rtl_fragments += 1
                    self.log.warning("RTL fragment %d of round %d left the port after the "
                                     "peers' acks about that round were built",
                                     decoded.frag_idx, decoded.round_id)
            await self._received.put(decoded)

    async def recv(self) -> ssr_packet.SSRFrame:
        """The next SSR frame the RTL node transmitted."""
        return await self._received.get()

    async def recv_host(self) -> bytes:
        """The next non-SSR frame that left the port: the NIC's own traffic."""
        return await self._host_received.get()

    def rtl_fragments(self, round_id: int) -> int:
        """How many fragments the RTL node put on the wire for round_id."""
        return self._rtl_sent.get(round_id, 0)
