"""Lane 3 — DownstreamServer + ReplayRing: the relay<->phone WS server.

This is the phone-facing side. It:

* accepts phone WS connections (and an HTTP fallback for cold reads, §1);
* subscribes ``TOPIC_RELAY_FRAMES``, stamps each :class:`Frame` with the next
  monotonic **per-connection** ``seq`` (protocol §4), appends it to the bounded
  :class:`ReplayRingManager` (reused verbatim from
  ``plugins/hermes-mobile/replay_ring.py``), and sends it to the phone;
* handles upstream JSON-RPC (protocol §1/§5) by translating to
  :class:`~hermes_relay.gateway_client.GatewayClient` calls;
* handles the reliability control frames locally: ``ack{through}`` drops acked
  frames from the ring; ``resync{last_seq}`` runs :meth:`ReplayRingManager.decide`
  and either replays ``[n+1..head]`` or sends a fresh ``snapshot`` (from
  :class:`SessionStore`) then resumes live.

Two seq facts from the protocol that shape this lane:
* ``seq`` is monotonic **per phone-connection**, NOT per session — so the ring
  key is the connection, and every session's frames share one seq spine.
* ``completed``-is-authoritative means a dropped delta is self-healing; the ring
  only needs to cover the reconnect window, and a ring miss falls back to a
  SessionStore snapshot the phone reconciles by ``item_id``.

INTERFACE THE LANE IMPLEMENTS: :meth:`serve` (accept loop), the per-connection
:class:`PhoneConnection` send/replay path, and :meth:`handle_upstream` (the §5
RPC translation). It OWNS the ring; the Reframer/GatewayClient never touch it.

Reuse note (per lane brief "reuse/adapt replay_ring head/floor/decide"): the
per-connection ring is the ``ReplayRingManager`` imported **verbatim** through
:mod:`hermes_relay.plugin_bridge` (no fork, no core patch), keyed by the
connection id. It natively gives us head/floor/``decide`` (REPLAY vs FALLBACK).
The one operation the phone spine needs that the per-*session* manager does not
expose — ``ack{through}`` eviction of acked frames — is realized on top of the
manager's public API only (``decide`` + ``drop`` + re-``append`` of the unacked
tail); ``replay_ring.py`` itself is never modified.
"""

from __future__ import annotations

import asyncio
import json
import logging
import uuid
from dataclasses import dataclass
from typing import Any, Optional

from . import plugin_bridge
from .bus import TOPIC_RELAY_FRAMES, EventBus
from .gateway_client import GatewayClient
from .session_state import SessionStore
from .types import Frame, FrameKind, UpstreamMethod, UpstreamRequest

_log = logging.getLogger(__name__)


@dataclass
class DownstreamConfig:
    """Phone-facing server bind + ring parameters."""

    host: str = "127.0.0.1"
    port: int = 8765
    # Ring caps are passed through to ReplayRingConfig; defaults there mirror
    # the resumable-stream spec (512 frames / 4 MiB / 128 MiB aggregate).
    ring_frames: Optional[int] = None
    ring_session_bytes: Optional[int] = None
    ring_total_bytes: Optional[int] = None
    ack_interval_hint_s: float = 5.0
    max_message_bytes: int = 8 * 1024 * 1024


def build_ring(cfg: DownstreamConfig) -> Any:
    """Construct the reused ``ReplayRingManager`` with the config's caps.

    Imported verbatim from ``plugins/hermes-mobile/replay_ring.py`` via the
    plugin bridge — the SAME module the gateway plugin ships, not a copy.
    """
    rr = plugin_bridge.import_replay_ring()
    kw: dict[str, int] = {}
    if cfg.ring_frames is not None:
        kw["frames"] = cfg.ring_frames
    if cfg.ring_session_bytes is not None:
        kw["session_bytes"] = cfg.ring_session_bytes
    if cfg.ring_total_bytes is not None:
        kw["total_bytes"] = cfg.ring_total_bytes
    return rr.ReplayRingManager(rr.ReplayRingConfig(**kw))


class PhoneConnection:
    """One connected phone: the seq spine + replay ring for this socket.

    ``seq`` is per-connection, so each PhoneConnection owns its own head
    counter and a ring key. The ring itself is the reused ReplayRingManager
    (one manager may back many connections, keyed by connection id).
    """

    def __init__(self, conn_id: str, ws: Any, ring: Any) -> None:
        self.conn_id = conn_id
        self._ws = ws
        self._ring = ring  # plugins/hermes-mobile replay_ring.ReplayRingManager
        self._head_seq = 0
        # Highest seq the phone has confirmed (ack watermark). Frames at/below
        # this are dropped from the ring; a resync at/above it needs no replay.
        self._acked_through = 0
        # Sessions this connection has streamed at least one frame for — the
        # set a FALLBACK resync rebuilds snapshots for.
        self.seen_sids: set[str] = set()
        # Sessions this phone currently holds foregrounded (gates Notifier §6).
        self.foreground_sessions: set[str] = set()

    # -- introspection (tests / diagnostics) -----------------------------
    @property
    def head_seq(self) -> int:
        return self._head_seq

    @property
    def acked_through(self) -> int:
        return self._acked_through

    def next_seq(self) -> int:
        """Allocate the next monotonic per-connection seq."""
        self._head_seq += 1
        return self._head_seq

    async def send_frame(self, frame: Frame) -> int:
        """Stamp seq, append to the ring, and write the frame to the socket.

        The ``Frame`` object arrives shared off the bus (one Reframer output
        fanned out to every connection), so we must NOT mutate ``frame.seq`` —
        each connection stamps its OWN per-connection seq into a private wire
        dict. Returns the stamped seq.
        """
        seq = self.next_seq()
        wire = {
            "seq": seq,
            "sid": frame.sid,
            "turn": frame.turn,
            "kind": frame.kind,
            "body": frame.body,
        }
        wire_json = json.dumps(wire, ensure_ascii=False)
        # Buffer BEFORE sending: even if the socket write fails, the frame is
        # replayable on the phone's next resync.
        self._ring.append(self.conn_id, seq, wire_json)
        if frame.sid:
            self.seen_sids.add(frame.sid)
        await self._ws.send(wire_json)
        return seq

    async def replay(self, last_seq: int, store: SessionStore) -> None:
        """Handle ``resync``: ring.decide(last_seq) -> replay or snapshot.

        REPLAY -> resend the ring's ``[last_seq+1 .. head]`` frames verbatim.
        FALLBACK -> build a per-session ``snapshot`` from ``store`` and send it,
        then resume live. CURRENT -> nothing to replay.
        """
        if last_seq >= self._head_seq:
            return  # CURRENT: phone is at or ahead of head; attach live only.

        decision = self._ring.decide(self.conn_id, last_seq)
        if decision.is_replay:
            for frame_json in decision.frames:
                await self._ws.send(frame_json)
            return

        # FALLBACK (gap below floor, or the ring was dropped): the phone missed
        # frames the ring already evicted. Hand it a fresh per-session snapshot
        # rebuilt from accumulated item state; it reconciles by item_id and then
        # resumes live off the ongoing fan-out. Each snapshot is itself a
        # sequenced downstream frame the phone will ack.
        await self._send_snapshots(store)

    async def _send_snapshots(self, store: SessionStore) -> None:
        for sid in sorted(self.seen_sids):
            body = store.snapshot(sid, cursor=self._head_seq)
            await self.send_frame(Frame(sid=sid, kind=FrameKind.SNAPSHOT, body=body))

    def ack(self, through_seq: int) -> None:
        """Handle ``ack{through}``: drop ring frames at/below ``through_seq``.

        Implemented on the verbatim manager's public API: ``decide(through)``
        yields the unacked tail ``[through+1 .. head]``; we drop the whole ring
        and re-append only that tail, advancing the floor to ``through+1`` and
        reclaiming the acked frames. A FALLBACK verdict means ``through`` is a
        stale/duplicate ack for already-evicted frames — leave the ring intact.
        """
        if through_seq <= self._acked_through:
            return  # stale / duplicate ack; nothing new to reclaim.

        decision = self._ring.decide(self.conn_id, through_seq)
        if decision.is_fallback:
            # ``through`` is older than the current floor: those frames are gone
            # already, and the live [floor..head] frames must be kept.
            self._acked_through = max(self._acked_through, through_seq)
            return

        # REPLAY -> keep the unacked tail; CURRENT (through >= head) -> tail empty.
        self._ring.drop(self.conn_id)
        for frame_json in decision.frames:
            seq = json.loads(frame_json)["seq"]
            self._ring.append(self.conn_id, seq, frame_json)
        self._acked_through = through_seq


class DownstreamServer:
    """The relay<->phone WS server + upstream RPC translator."""

    def __init__(
        self,
        config: DownstreamConfig,
        bus: EventBus,
        gateway: GatewayClient,
        store: SessionStore,
    ) -> None:
        self._cfg = config
        self._bus = bus
        self._gateway = gateway
        self._store = store
        self._ring = None  # set in start(): reused ReplayRingManager
        self._conns: dict[str, PhoneConnection] = {}
        self._server = None
        self._sub = None
        self._fanout_task: Optional[asyncio.Task] = None
        self._stop = asyncio.Event()

    async def start(self) -> None:
        """Build the reused replay ring and bind the phone-facing WS server."""
        if self._ring is None:
            self._ring = build_ring(self._cfg)

    async def serve(self) -> None:
        """Accept loop: register each phone connection, pump frames to it.

        Also starts the fan-out task that reads ``TOPIC_RELAY_FRAMES`` and
        forwards each frame to every connection's :meth:`PhoneConnection.send_frame`.
        """
        import websockets  # lazy: unit tests exercise the pieces without a socket

        await self.start()
        self._stop.clear()
        self._sub = self._bus.subscribe(TOPIC_RELAY_FRAMES)
        self._fanout_task = asyncio.create_task(self._fanout_loop())
        self._server = await websockets.serve(
            self._serve_conn,
            self._cfg.host,
            self._cfg.port,
            max_size=self._cfg.max_message_bytes,
        )
        try:
            await self._stop.wait()
        finally:
            await self.close()

    def register(self, ws: Any) -> PhoneConnection:
        """Register a new phone socket, returning its :class:`PhoneConnection`."""
        conn_id = f"conn-{uuid.uuid4().hex[:12]}"
        conn = PhoneConnection(conn_id, ws, self._ring)
        self._conns[conn_id] = conn
        return conn

    def unregister(self, conn: PhoneConnection) -> None:
        self._conns.pop(conn.conn_id, None)
        if self._ring is not None:
            self._ring.drop(conn.conn_id)

    async def _serve_conn(self, ws: Any) -> None:
        """Per-socket handler: read upstream RPCs, reply with JSON-RPC results."""
        conn = self.register(ws)
        try:
            async for raw in ws:
                await self._on_upstream_raw(conn, raw)
        except Exception:  # pragma: no cover - transport teardown
            _log.debug("phone connection %s dropped", conn.conn_id, exc_info=True)
        finally:
            self.unregister(conn)

    async def _on_upstream_raw(self, conn: PhoneConnection, raw: Any) -> None:
        """Parse one upstream message and dispatch it, replying if it has an id."""
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            return
        req = UpstreamRequest.from_wire(payload)
        try:
            result = await self.handle_upstream(conn, req)
        except Exception as exc:  # translate to a JSON-RPC error
            if req.id is not None:
                await conn._ws.send(
                    json.dumps(
                        {
                            "jsonrpc": "2.0",
                            "id": req.id,
                            "error": {"code": -32000, "message": str(exc)},
                        }
                    )
                )
            return
        if req.id is not None:
            await conn._ws.send(
                json.dumps({"jsonrpc": "2.0", "id": req.id, "result": result})
            )

    async def _fanout_loop(self) -> None:
        """Read ``TOPIC_RELAY_FRAMES`` and mirror every frame to every phone."""
        assert self._sub is not None
        while not self._stop.is_set():
            frame = await self._sub.get()
            await self._dispatch(frame)

    async def _dispatch(self, frame: Frame) -> None:
        """Fan one Reframer frame out to every connection (per-connection seq)."""
        for conn in list(self._conns.values()):
            try:
                await conn.send_frame(frame)
            except Exception:  # a slow/broken socket must not stall the others
                _log.debug("send to %s failed", conn.conn_id, exc_info=True)

    async def close(self) -> None:
        self._stop.set()
        if self._fanout_task is not None:
            self._fanout_task.cancel()
            try:
                await self._fanout_task
            except (asyncio.CancelledError, Exception):  # pragma: no cover
                pass
            self._fanout_task = None
        if self._sub is not None:
            self._bus.unsubscribe(self._sub)
            self._sub = None
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    # -- upstream (phone -> relay -> gateway), protocol §5 ---------------
    async def handle_upstream(self, conn: PhoneConnection, req: UpstreamRequest) -> Any:
        """Translate one phone JSON-RPC request and return its JSON-RPC result.

        * ``list``      -> gateway.session_list
        * ``open``/``history`` -> gateway.rest_history (store-read; R0 correction)
        * ``submit``    -> session_create/resume (+own) -> prompt_submit
        * ``resume``    -> session_resume (own idle/foreign)
        * ``approve``   -> approval_respond
        * ``clarify``   -> clarify_respond
        * ``interrupt`` -> session_interrupt
        * ``ack``       -> conn.ack (LOCAL, no gateway hop)
        * ``resync``    -> conn.replay (LOCAL, no gateway hop)
        """
        method = req.method
        p = req.params

        # -- local reliability control frames (never hit the gateway) --------
        if method == UpstreamMethod.ACK:
            conn.ack(int(p.get("through", 0)))
            return None
        if method == UpstreamMethod.RESYNC:
            await conn.replay(int(p.get("last_seq", 0)), self._store)
            return None

        # -- reads -----------------------------------------------------------
        if method == UpstreamMethod.LIST:
            return {"sessions": await self._gateway.session_list(int(p.get("limit", 200)))}

        if method in (UpstreamMethod.OPEN, UpstreamMethod.HISTORY):
            sid = p["session_id"]
            conn.foreground_sessions.add(sid)  # phone is now watching it (§6)
            return {"session_id": sid, "messages": await self._gateway.rest_history(sid)}

        # -- drive (become owner) --------------------------------------------
        if method == UpstreamMethod.SUBMIT:
            text = p["text"]
            sid = p.get("session_id")
            if sid:
                # Send into an existing (idle/foreign) session: resume to own it
                # first if we do not already, then drive the turn (§5).
                if not self._gateway.owns(sid):
                    await self._gateway.session_resume(sid)
                await self._gateway.prompt_submit(sid, text)
            else:
                # Brand-new chat: create + own, then drive (§5).
                sid = await self._gateway.session_create(
                    title=p.get("title", "New chat"),
                    model=p.get("model"),
                    provider=p.get("provider"),
                )
                await self._gateway.prompt_submit(sid, text)
            conn.foreground_sessions.add(sid)
            return {"session_id": sid}

        if method == UpstreamMethod.RESUME:
            sid = p["session_id"]
            result = await self._gateway.session_resume(sid)
            conn.foreground_sessions.add(sid)
            return {"session_id": sid, "result": result}

        # -- interactive gates + stop (pass-through) -------------------------
        if method == UpstreamMethod.APPROVE:
            return await self._gateway.approval_respond(
                p["session_id"], p["request_id"], p["decision"]
            )
        if method == UpstreamMethod.CLARIFY:
            return await self._gateway.clarify_respond(
                p["session_id"], p["request_id"], p["text"]
            )
        if method == UpstreamMethod.INTERRUPT:
            return await self._gateway.session_interrupt(p["session_id"])

        raise ValueError(f"unknown upstream method: {method!r}")

    # -- foreground tracking (feeds Notifier §6 gate) --------------------
    def session_has_live_phone(self, session_id: str) -> bool:
        """True iff any connected phone holds ``session_id`` foregrounded.

        The Notifier calls this to skip a push when the user is already watching
        (protocol §6): a foregrounded session on a live WS suppresses APNs.
        """
        return any(session_id in c.foreground_sessions for c in self._conns.values())
