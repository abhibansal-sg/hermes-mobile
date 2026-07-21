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
import hmac
import json
import logging
import uuid
from collections import OrderedDict
from dataclasses import dataclass
from typing import Any, Optional

from . import plugin_bridge
from .bus import TOPIC_RELAY_FRAMES, EventBus
from .gateway_client import GatewayClient
from .durable_state import DurableState
from .session_state import SessionStore
from .types import (
    Frame,
    FrameKind,
    Item,
    ItemStatus,
    ItemType,
    UpstreamMethod,
    UpstreamRequest,
)

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
    # HTTP health/status path served on the SAME phone-facing port (a plain GET,
    # not a WS upgrade). ``None`` disables the surface entirely.
    health_path: Optional[str] = "/healthz"
    # Bearer token gating the health/control routes (healthz + the durable
    # /attention/pending and /sync/manifest siblings) and the WS handshake. The
    # iOS client already sends the gateway token as a bearer credential; reuse
    # it rather than adding a second secret or config surface. Empty disables.
    auth_token: str = ""


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
        # The session this phone currently holds foregrounded (gates Notifier §6).
        # A mobile client shows ONE chat at a time, so this is set-REPLACE, never
        # accumulate: navigating to another chat clears the previous one and an
        # explicit ``foreground{session_id:null}`` (app backgrounded) clears it
        # entirely. Kept as a set so :meth:`DownstreamServer.session_has_live_phone`
        # stays a simple membership test.
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

    def set_foreground(self, sid: Optional[str]) -> None:
        """Declare the single session this phone now holds foregrounded (§6).

        REPLACE semantics (a mobile phone views one chat at a time): opening or
        driving a new chat clears the previous one, so a session the user has
        navigated away from stops suppressing its own completion/error pushes.
        ``None`` (app backgrounded / chat closed) clears the foreground set,
        re-enabling pushes for everything. NOTE: a pure background REST
        ``history`` sync must NOT call this — reading is not foregrounding.
        """
        self.foreground_sessions = {sid} if sid else set()

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
        if last_seq > self._head_seq:
            # ``last_seq`` is HIGHER than anything this connection has ever sent.
            # seq is per-connection, so this can only be a leftover watermark from
            # a PRIOR connection (a reconnect on a fresh socket): this connection's
            # ring cannot replay a foreign seq space, and the CURRENT short-circuit
            # below would wrongly return with no catch-up at all, stranding the
            # phone on stale content until it manually REST-refetches. Hand it a
            # snapshot of every known session instead, which it reconciles by
            # item_id and then resumes live on THIS connection's seq spine.
            # ``seen_sids`` is still empty on a just-opened socket, so snapshot the
            # whole store, not just this connection's (as-yet-empty) seen set.
            await self._send_snapshots(store, sids=store.session_ids())
            return
        if last_seq >= self._head_seq:
            return  # CURRENT: phone is at head on THIS connection; attach live.

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

    async def _send_snapshots(
        self, store: SessionStore, sids: Optional[list[str]] = None
    ) -> None:
        """Send a fresh per-session ``snapshot`` for each of ``sids``.

        Defaults to this connection's ``seen_sids`` (an intra-connection ring
        miss). A caller recovering a reconnect passes an explicit list (e.g.
        ``store.session_ids()``), because a just-opened socket has not streamed a
        frame yet and its ``seen_sids`` is empty.
        """
        target = sids if sids is not None else sorted(self.seen_sids)
        for sid in target:
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
        durable: Optional[DurableState] = None,
        push_engine: Any = None,
    ) -> None:
        self._cfg = config
        self._bus = bus
        self._gateway = gateway
        self._store = store
        self._durable = durable
        # Injected push_engine module (plugin_bridge.import_push_engine()); the
        # ``push.register``/``push.unregister`` token registry RPCs (§6) write
        # into it. Resolved lazily on first use when not injected; tests inject
        # a real module under a tmp HERMES_HOME.
        self._push = push_engine
        self._ring = None  # set in start(): reused ReplayRingManager
        self._conns: dict[str, PhoneConnection] = {}
        self._server = None
        self._sub = None
        self._fanout_task: Optional[asyncio.Task] = None
        self._stop = asyncio.Event()
        # SUBMIT idempotency: client_message_id -> resolved (live) session_id.
        # The durable outbox retries a submit whose RPC result was lost to a
        # socket flap AFTER the relay already ran ``prompt_submit`` (the phone
        # marks the row ``transport_ambiguous`` and the next wake resubmits the
        # SAME job). This server object outlives any single phone connection, so
        # the retry — which arrives on a FRESH PhoneConnection after reconnect —
        # is recognized here and replays the prior result instead of driving a
        # second turn. Bounded (LRU) so it can never grow without limit.
        self._submit_dedup: "OrderedDict[str, str]" = OrderedDict()
        self._submit_dedup_cap = 1024

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
            process_request=self._process_request,
        )
        try:
            await self._stop.wait()
        finally:
            await self.close()

    async def _process_request(self, connection: Any, request: Any) -> Any:
        """Serve a plain-HTTP health/status probe on the phone-facing port.

        websockets calls this before the WS handshake for every inbound request.
        A GET to the configured ``health_path`` is answered with a JSON status
        body (HTTP 200) and never upgraded; anything else returns ``None`` so the
        normal WS handshake proceeds. Kept defensive: a probe must never take down
        the accept loop, so any failure falls through to the WS path.
        """
        health = self._cfg.health_path
        try:
            from http import HTTPStatus

            raw_path = getattr(request, "path", "") or ""
            path = raw_path.split("?", 1)[0]
            token = self._cfg.auth_token
            supplied = (getattr(request, "headers", {}) or {}).get("Authorization", "")
            if token and not hmac.compare_digest(supplied, f"Bearer {token}"):
                return connection.respond(HTTPStatus.UNAUTHORIZED, "Unauthorized\n")
            if health and path == health:
                body = json.dumps(self.status(), ensure_ascii=False) + "\n"
                return connection.respond(HTTPStatus.OK, body)
            if path == "/attention/pending" and self._durable is not None:
                from urllib.parse import parse_qs, urlsplit

                cursor = parse_qs(urlsplit(raw_path).query).get("cursor", [None])[0]
                body = json.dumps(self._durable.pending_attention(cursor)) + "\n"
                return connection.respond(HTTPStatus.OK, body)
            if path == "/sync/manifest" and self._durable is not None:
                from urllib.parse import parse_qs, urlsplit

                query = parse_qs(urlsplit(raw_path).query)
                try:
                    sessions = await self._gateway.session_list(100_000)
                except Exception:
                    _log.warning("sync manifest gateway snapshot failed", exc_info=True)
                    return connection.respond(HTTPStatus.SERVICE_UNAVAILABLE, "Unavailable\n")
                body = json.dumps(self._durable.sync_manifest(
                    query.get("profile", ["all"])[0],
                    query.get("cursor", [None])[0], sessions,
                )) + "\n"
                return connection.respond(HTTPStatus.OK, body)
            if path in ("/approve", "/clarify"):
                # R4 L4 (GAP-10, B6/B7): one-shot gate answer over the HTTP
                # control sibling — the cold notification banner action path.
                return await self._answer_gate_http(connection, request, raw_path, path)
            return None
        except Exception:  # pragma: no cover - a broken probe must not stall serve
            _log.debug("health probe failed", exc_info=True)
            return None

    async def _answer_gate_http(
        self, connection: Any, request: Any, raw_path: str, path: str
    ) -> Any:
        """One-shot ``/approve`` / ``/clarify`` answer on the phone-facing port.

        R4 L4 — the cold-tap gap (GAP-10, B6/B7): a notification banner
        APPROVE/DENY/REPLY action fires while the phone holds NO relay socket,
        and on the daily-driver's GW-UNREACH topology the gateway REST answer
        is unreachable too — the agent stays blocked until the user opens the
        app. The relay already owns these sessions and holds a live gateway
        RPC path: answer through it (the same ``approval_respond`` /
        ``clarify_respond`` translation as the WS methods, durable-resolution
        included, §5).

        Wire shape: params ride the QUERY STRING
        (``/approve?session_id=…&request_id=…&decision=…``,
        ``/clarify?session_id=…&request_id=…&text=…`` — URL-encoded). This
        port's websockets handshake parser rejects non-GET methods BEFORE
        ``process_request`` runs (a POST never reaches here on the deployed
        websockets>=14), so the query string — this port's existing
        ``/attention/pending`` + ``/sync/manifest`` house style — is the
        transport that actually survives to this handler. A JSON body is
        ALSO honored when the request object exposes one (harness fakes;
        forward-compat if a websockets version grows body support): query
        keys win on conflict. Same bearer auth as every route on this port.
        Responses are JSON: ``{"ok": true, "result": …}`` on success;
        ``{"ok": false, "error": …}`` with 400 (missing/invalid params), 502
        (gateway answer failed — sanitized, §6b: no raw codes) or 503 (relay
        gateway not ready). A probe here must never stall the accept loop.
        """
        from http import HTTPStatus
        from urllib.parse import parse_qs, urlsplit

        params: dict[str, Any] = {
            key: values[0] for key, values in parse_qs(urlsplit(raw_path).query).items()
        }
        body = getattr(request, "body", None)
        if isinstance(body, (bytes, bytearray)):
            body = bytes(body).decode("utf-8", errors="replace")
        if isinstance(body, str) and body.strip():
            try:
                parsed = json.loads(body)
            except ValueError:
                return connection.respond(
                    HTTPStatus.BAD_REQUEST,
                    json.dumps({"ok": False, "error": "invalid JSON body"}) + "\n",
                )
            if isinstance(parsed, dict):
                params.update(parsed)

        if not await self._gateway.wait_ready(timeout=5.0):
            return connection.respond(
                HTTPStatus.SERVICE_UNAVAILABLE,
                json.dumps({"ok": False, "error": "relay gateway not ready"}) + "\n",
            )
        try:
            if path == "/approve":
                sid = str(params["session_id"])
                request_id = str(params.get("request_id") or "")
                decision = str(params["decision"])
                raw_all = params.get("all", False)
                resolve_all = (
                    raw_all
                    if isinstance(raw_all, bool)
                    else str(raw_all).lower() in ("1", "true", "yes")
                )
                result = await self._gateway.approval_respond(
                    sid, request_id, decision, resolve_all=resolve_all
                )
                if self._durable is not None:
                    self._durable.resolve_attention(
                        request_id=None if resolve_all else request_id or None,
                        session_id=sid, kind="approval",
                    )
            else:  # /clarify
                sid = str(params["session_id"])
                request_id = str(params.get("request_id") or "")
                text = str(params.get("text") or "")
                result = await self._gateway.clarify_respond(sid, request_id, text)
                if self._durable is not None:
                    self._durable.resolve_attention(
                        request_id=request_id or None,
                        session_id=sid, kind="clarify",
                    )
        except KeyError as exc:
            return connection.respond(
                HTTPStatus.BAD_REQUEST,
                json.dumps({"ok": False, "error": f"missing required param {exc}"}) + "\n",
            )
        except Exception:
            _log.warning("HTTP gate answer (%s) failed", path, exc_info=True)
            return connection.respond(
                HTTPStatus.BAD_GATEWAY,
                json.dumps({"ok": False, "error": "gateway answer failed"}) + "\n",
            )
        return connection.respond(
            HTTPStatus.OK,
            json.dumps({"ok": True, "result": result}, ensure_ascii=False) + "\n",
        )

    def status(self) -> dict[str, Any]:
        """A JSON-serialisable snapshot of the phone-facing server's live state."""
        conns = [
            {
                "conn_id": c.conn_id,
                "head_seq": c.head_seq,
                "acked_through": c.acked_through,
                "foreground": sorted(c.foreground_sessions),
                "seen_sessions": len(c.seen_sids),
            }
            for c in list(self._conns.values())
        ]
        owned = getattr(self._gateway, "owned_sessions", None)
        try:
            owned_list = sorted(owned) if owned else []
        except TypeError:  # a non-iterable stand-in (e.g. a bare mock) — skip
            owned_list = []
        return {
            "listen": f"{self._cfg.host}:{self._cfg.port}",
            "connections": len(conns),
            "phones": conns,
            "owned_sessions": owned_list,
            "ring_ready": self._ring is not None,
            "serving": self._server is not None,
        }

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
        """Read ``TOPIC_RELAY_FRAMES`` and mirror every frame to every phone.

        Guards the SILENT-LOSS hole: the per-subscriber bus queue is bounded and
        drops the OLDEST message on overflow (bus.py), and ``seq`` is stamped
        per-connection HERE — downstream of that drop. So a dropped authoritative
        ``item.completed`` would leave the phone with a perfectly CONTIGUOUS seq
        stream (no gap to trigger a resync) yet stale content. We can't recover
        the dropped Frame, but the Reframer already folded it into the shared
        SessionStore BEFORE publishing (upstream of the drop), so the store still
        holds the authoritative item. Detect the drop via the subscription's
        drop counter and heal every connection with a fresh snapshot.
        """
        assert self._sub is not None
        seen_dropped = self._sub.dropped
        while not self._stop.is_set():
            frame = await self._sub.get()
            await self._dispatch(frame)
            if self._sub.dropped != seen_dropped:
                seen_dropped = self._sub.dropped
                await self._heal_after_drop()

    async def _heal_after_drop(self) -> None:
        """A bus overflow silently dropped frame(s) before they were seq-stamped.

        Hand every connection a fresh snapshot for each session it has seen; the
        phone reconciles by ``item_id`` and recovers any lost authoritative
        ``item.completed``. Snapshots are themselves sequenced frames on each
        connection's spine, so the recovery is reliable end-to-end.
        """
        for conn in list(self._conns.values()):
            try:
                await conn._send_snapshots(self._store)
            except Exception:  # a broken socket must not stall the heal for others
                _log.debug("post-drop heal to %s failed", conn.conn_id, exc_info=True)

    async def _dispatch(self, frame: Frame) -> None:
        """Fan one Reframer frame out to every connection (per-connection seq)."""
        if self._durable is not None:
            self._durable.observe_frame(frame)
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

    def _push_engine(self) -> Any:
        """The reused ``push_engine`` module (lazily resolved, cached).

        ``push.register``/``push.unregister`` write the SAME registry the
        Notifier's ``push_engine.notify`` reads — one source of tokens for the
        relay-fired push path. Import failures surface as JSON-RPC errors to
        the phone (registry unavailable), never as a server crash.
        """
        if self._push is None:
            self._push = plugin_bridge.import_push_engine()
        return self._push

    def _remember_submit(self, cmid: str, sid: str) -> None:
        """Record ``client_message_id -> resolved session_id`` for SUBMIT dedup,
        evicting the oldest entry once the bounded LRU is full."""
        self._submit_dedup[cmid] = sid
        self._submit_dedup.move_to_end(cmid)
        while len(self._submit_dedup) > self._submit_dedup_cap:
            self._submit_dedup.popitem(last=False)

    def _user_message_item_id(
        self, sid: str, cmid: Optional[str], text: str
    ) -> str:
        """The stable ``item_id`` for the SUBMIT-synthesized ``userMessage`` item.

        With a ``client_message_id`` the id derives from ``(sid, cmid)`` ALONE,
        so an ambiguous-flap retry — which arrives on a FRESH connection after
        the relay already ran ``prompt_submit`` — maps to the SAME item and the
        fold replaces by id instead of duplicating the bubble (mirrors the
        SUBMIT dedup). WITHOUT one (a client that sends no cmid) the id is
        salted with the count of PRIOR same-text userMessage items already
        accumulated for the session: two sends of identical text stay two
        distinct items, yet a deterministic submit sequence yields identical
        ids on every run — the E2E flap-chaos scenario (f) compares runs
        byte-for-byte and a connection/seq-salted id would diverge across the
        clean and chaos runs.
        """
        if cmid is not None:
            key = f"cmid:{sid}:{cmid}"
        else:
            state = self._store.get(sid)
            same_text = sum(
                1
                for it in state.items.values()
                if it.type == ItemType.USER_MESSAGE and it.body.get("text") == text
            )
            key = f"nth:{sid}:{same_text}:{text}"
        return f"{sid}:u-{uuid.uuid5(uuid.NAMESPACE_URL, 'hermes-relay:' + key).hex[:16]}"

    def _emit_user_message_item(
        self, conn: PhoneConnection, sid: str, cmid: Optional[str], text: str
    ) -> None:
        """Synthesize, fold, and fan out a COMPLETED ``userMessage`` item for the
        prompt this SUBMIT just drove (QA-1 B5/B13).

        The Reframer maps ONLY agent events — without this the relay emits no
        user item anywhere, so the phone has nothing on the wire to reconcile
        its optimistic user echo against (the bubble never lands live) and a
        cold-resume snapshot omits the prompt entirely. The item is folded into
        the SessionStore (snapshots carry it) and published exactly like a
        Reframer frame (the fan-out stamps per-connection seq and rings it).
        Idempotent per ``item_id``: a retry re-publishes the SAME item (healing
        a fresh phone connection whose store lacks it) without allocating a
        second ord or duplicating the bubble. The ord is allocated at SUBMIT,
        so the turn's agent items (allocated later) render BELOW the prompt.
        """
        state = self._store.get(sid)
        item_id = self._user_message_item_id(sid, cmid, text)
        item = state.items.get(item_id)
        if item is None:
            body: dict[str, Any] = {"text": text}
            if cmid is not None:
                body["client_message_id"] = cmid
            item = Item(
                item_id=item_id,
                type=ItemType.USER_MESSAGE,
                status=ItemStatus.COMPLETED,
                ord=state.allocate_ord(),
                body=body,
            )
        frame = Frame.with_item(sid=sid, kind=FrameKind.ITEM_COMPLETED, item=item)
        state.apply(frame)
        self._bus.publish(TOPIC_RELAY_FRAMES, frame)

    def _seed_history_user_rows(self, sid: str, messages: list) -> None:
        """R4 L6 — fold ``rest_history`` USER rows into the store as completed
        ``userMessage`` items when seeding an EMPTY store (OPEN/HISTORY on a
        session the stream has not touched since relay startup).

        The reframer maps agent events only, so a foreign turn's prompt has no
        item in the accumulated state — a resync FALLBACK snapshot would drop
        it (the phone's cold-open paint has it from its own read; the snapshot
        fallback did not). Seeding closes that hole: the snapshot now carries
        foreign prompts in the same item shape as the SUBMIT-synthesized rows.

        Seed, never co-author (contract I3): a NON-empty store is never
        reseeded — once the stream has spoken, it alone writes. Item ids are
        deterministic per ``(sid, nth-user-row, text)`` so a repeated seed of
        the same batch converges on the same ids (contract I21); the
        empty-store gate means a store is seeded at most once per relay
        lifetime anyway.
        """
        state = self._store.get(sid)
        if state.items:
            return  # the stream already owns this session — cache is seed only
        nth = 0
        for row in messages:
            if not isinstance(row, dict) or row.get("role") != "user":
                continue
            content = row.get("content")
            if not isinstance(content, str) or not content:
                content = row.get("text")  # some REST shapes key the text field
            if not isinstance(content, str) or not content:
                continue
            item_id = (
                f"{sid}:h-"
                f"{uuid.uuid5(uuid.NAMESPACE_URL, f'hermes-relay:hist:{sid}:{nth}:{content}').hex[:16]}"
            )
            nth += 1
            stripped = content.strip()
            item = Item(
                item_id=item_id,
                type=ItemType.USER_MESSAGE,
                status=ItemStatus.COMPLETED,
                ord=state.allocate_ord(),
                summary=stripped.splitlines()[0][:120] if stripped else "",
                body={"text": content},
            )
            state.apply(Frame.with_item(sid=sid, kind=FrameKind.ITEM_COMPLETED, item=item))

    # -- upstream (phone -> relay -> gateway), protocol §5 ---------------
    async def handle_upstream(self, conn: PhoneConnection, req: UpstreamRequest) -> Any:
        """Translate one phone JSON-RPC request and return its JSON-RPC result.

        * ``list``      -> gateway.session_list (L1: +order/cwd_prefix/
          exclude_source/min_messages pass-through)
        * ``open``/``history`` -> gateway.rest_history (store-read; R0 correction)
        * ``submit``    -> session_create/resume (+own) -> prompt_submit
          (L2: +truncate_before_user_ordinal, +cwd on create)
        * ``branch``    -> session_create (+cwd) -> prompt_submit seed (L2, B13)
        * ``resume``    -> session_resume (own idle/foreign)
        * ``approve``   -> approval_respond
        * ``clarify``   -> clarify_respond
        * ``interrupt`` -> session_interrupt
        * ``steer``     -> session_steer (live-turn steering; QA-2 R11)
        * ``attach``    -> file_attach / image_attach_bytes (bytes inlined)
        * ``ack``       -> conn.ack (LOCAL, no gateway hop)
        * ``resync``    -> conn.replay (LOCAL, no gateway hop)
        * ``push.register``/``push.unregister`` -> the relay's OWN push token
          registry (LOCAL, no gateway hop; the Notifier reads this same
          registry — protocol §6)
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
        if method == UpstreamMethod.FOREGROUND:
            # Phone declares which chat it is looking at (or null when the app is
            # backgrounded / the chat is closed). This is the authoritative §6
            # signal; the passive OPEN/SUBMIT/RESUME tracking is only a fallback.
            conn.set_foreground(p.get("session_id"))
            return None
        if method == UpstreamMethod.PUSH_REGISTER:
            # Relay-local APNs token registration (protocol §6). In relay mode
            # the phone's gateway-direct REST register can never reach the
            # relay-owned session's notifier (off-LAN phones can't hit the
            # gateway REST at all; on-LAN ones write the gateway's registry,
            # a different HERMES_HOME than this process). Registering OVER THE
            # RELAY SOCKET writes the registry the relay Notifier actually
            # reads — one transport, one registry, no shared-home coincidence.
            push = self._push_engine()
            # The registry's parent may not exist yet in a fresh service env
            # (the gateway side relies on ~/.hermes already being there);
            # push_engine swallows persist errors, so create it here or the
            # register would "succeed" in memory and lose the token on restart.
            try:
                from pathlib import Path

                Path(push._registry_path()).parent.mkdir(parents=True, exist_ok=True)
            except OSError:  # pragma: no cover - best-effort dir hygiene
                _log.debug("push.register: registry dir create failed", exc_info=True)
            events = p.get("events")
            presented_device_id = p.get("device_id")
            ok = push.register_token(
                str(p.get("token") or ""),
                platform=str(p.get("platform") or "ios"),
                env=str(p.get("env") or ""),
                events=list(events) if isinstance(events, list) else None,
                device_id=presented_device_id,
            )
            if not ok:
                raise ValueError("invalid device token")
            # QA-3 S13: log the presented device_id (masked) so a missing/null
            # id — the root cause of non-converging fan-out — is visible without
            # exposing the id (non-secret, but masked for log hygiene).
            masked = (
                "…" + str(presented_device_id)[-6:]
                if isinstance(presented_device_id, str)
                and presented_device_id.strip()
                else "<none>"
            )
            _log.info(
                "push.register: device token registered over relay "
                "(platform=%s env=%s device_id=%s)",
                str(p.get("platform") or "ios"),
                str(p.get("env") or "") or "<default>",
                masked,
            )
            return {"registered": True}
        if method == UpstreamMethod.PUSH_UNREGISTER:
            removed = self._push_engine().unregister_token(str(p.get("token") or ""))
            return {"unregistered": bool(removed)}

        # -- gateway-readiness gate ------------------------------------------
        # Every method below this point hits the gateway. After a relay restart
        # the phone reconnects to the downstream server immediately, but the
        # relay's gateway connection might not be up yet. Without this gate a
        # submit/resume arriving in that window fails with "gateway not
        # connected" and the outbox retains the job with no further wake. Wait
        # (bounded) for the gateway to come up; if it doesn't, raise so the
        # phone's outbox retains the job and retries on the next wake.
        if not await self._gateway.wait_ready(timeout=10.0):
            raise ConnectionError("relay gateway not ready")

        # -- reads -----------------------------------------------------------
        if method == UpstreamMethod.LIST:
            # R4 L1 (GAP-1, the central blocker): the phone's drawer / project
            # session list rides THIS RPC, so the gateway REST list's filters
            # must pass through — recency order (the drawer default), a cwd
            # prefix (project-scoped list, B10), a source exclusion and a
            # minimum-message bound. Each is OPTIONAL: absent params are never
            # sent, so a pre-L1 phone (limit only) drives the byte-identical
            # pre-L1 gateway call.
            # Explicit per-key reads (the conformance AST extractor keys off
            # literal ``p.get("…")`` sites — the contract mirrors live code).
            filters: dict[str, Any] = {}
            order = p.get("order")
            if isinstance(order, str) and order:
                filters["order"] = order
            cwd_prefix = p.get("cwd_prefix")
            if isinstance(cwd_prefix, str) and cwd_prefix:
                filters["cwd_prefix"] = cwd_prefix
            exclude_source = p.get("exclude_source")
            if isinstance(exclude_source, str) and exclude_source:
                filters["exclude_source"] = exclude_source
            min_messages = p.get("min_messages")
            if isinstance(min_messages, int) and not isinstance(min_messages, bool):
                filters["min_messages"] = min_messages
            return {
                "sessions": await self._gateway.session_list(
                    int(p.get("limit", 200)), **filters
                )
            }

        if method in (UpstreamMethod.OPEN, UpstreamMethod.HISTORY):
            sid = p["session_id"]
            # OPEN = user brought this chat on screen -> foreground it (§6).
            # HISTORY = background store sync -> must NOT foreground, else a mere
            # sync would permanently gag that session's completion/error pushes.
            if method == UpstreamMethod.OPEN:
                conn.set_foreground(sid)
            messages = await self._gateway.rest_history(sid)
            if method == UpstreamMethod.HISTORY:
                # The phone may bound the read with ``limit`` (its history RPC
                # sends it); the gateway REST path takes no limit, so honor it
                # here, keeping the MOST RECENT messages (the store-read returns
                # oldest-first). A missing/invalid limit returns the full list.
                limit = p.get("limit")
                if isinstance(limit, int) and limit >= 0:
                    messages = messages[-limit:] if limit else []
            # R4 L6: fold the history's USER rows into the store (seed, not
            # co-author — empty store only) so a resync snapshot carries
            # foreign prompts.
            self._seed_history_user_rows(sid, messages)
            return {"session_id": sid, "messages": messages}

        # -- drive (become owner) --------------------------------------------
        if method == UpstreamMethod.SUBMIT:
            # The iOS app sends "prompt"; the protocol doc says "text". Accept both.
            text = p.get("prompt") or p.get("text") or ""
            sid = p.get("session_id")
            cmid = p.get("client_message_id")
            # R4 L2 (B13): regenerate/edit-and-resend rides SUBMIT with the
            # gateway's own truncate point — forwarded only when the phone
            # sends it, so an ordinary send is the byte-identical pre-L2 call.
            submit_kwargs: dict[str, Any] = {}
            truncate = p.get("truncate_before_user_ordinal")
            if isinstance(truncate, int) and not isinstance(truncate, bool):
                submit_kwargs["truncate_before_user_ordinal"] = truncate
            # Idempotent re-drive: a prior submit with this client_message_id
            # already ran ``prompt_submit`` but its RPC result was lost to a
            # socket flap, so the outbox is resubmitting the SAME job. Replay the
            # resolved session id WITHOUT driving a second turn (§5 dedup).
            if cmid is not None and cmid in self._submit_dedup:
                self._submit_dedup.move_to_end(cmid)
                prior = self._submit_dedup[cmid]
                conn.set_foreground(prior)  # still the chat on screen (§6)
                # Re-emit the userMessage item: the retry arrives on a FRESH
                # phone connection whose render store may lack it (the original
                # frame was lost to the flap). Idempotent — same item_id folds
                # onto the same row (no second bubble, no second ord).
                self._emit_user_message_item(conn, prior, cmid, text)
                return {"session_id": prior, "deduplicated": True}
            if sid:
                # Drive an existing (idle / foreign / terminal) session. Resuming
                # REACTIVATES it, and the stock gateway may hand back a DISTINCT
                # live session id (echoing the requested id as ``resumed``). The
                # turn MUST be submitted to THAT live id, not the origin id — the
                # R0/E2E finding: prompt.submit to the origin id targets a dormant
                # session and the turn silently never runs. So take the live id
                # the resume returns and drive it (§5).
                if not self._gateway.owns(sid):
                    resumed = await self._gateway.session_resume(sid)
                    if isinstance(resumed, dict):
                        sid = resumed.get("session_id") or sid
                else:
                    # Already owned: a prior resume may have remapped the origin
                    # id to a live id — resolve so a repeat submit to the origin
                    # id still drives the live turn.
                    sid = self._gateway.live_id_for(sid)
                # R4 L6: mark the prompt phone-origin BEFORE the await so the
                # reframer's message.start emission skips it under either
                # ordering (the SUBMIT synthesis below is this turn's user row).
                if text:
                    self._store.mark_local_prompt(sid, text)
                await self._gateway.prompt_submit(sid, text, **submit_kwargs)
            else:
                # Brand-new chat: create + own, then drive (§5). R4 L2 (B10):
                # ``cwd`` threads a project working directory into the created
                # session (the surviving projects fix — L5-lean dropped the
                # relay projects path; projects stay on the control REST).
                cwd = p.get("cwd")
                sid = await self._gateway.session_create(
                    title=p.get("title", "New chat"),
                    model=p.get("model"),
                    provider=p.get("provider"),
                    cwd=cwd if isinstance(cwd, str) and cwd else None,
                )
                if text:
                    self._store.mark_local_prompt(sid, text)  # R4 L6 (see above)
                await self._gateway.prompt_submit(sid, text, **submit_kwargs)
            # Emit the prompt itself as a completed ``userMessage`` item (QA-1
            # B5/B13): the Reframer maps only AGENT events, so without this the
            # phone has no wire item to reconcile its optimistic echo against
            # and snapshots omit the prompt. Rides on the RESOLVED (live /
            # created) sid so the item lands on the session the turn drives.
            self._emit_user_message_item(conn, sid, cmid, text)
            # Record the resolved (live) id under the client message id BEFORE
            # returning, so a retry that races the RPC result back over a flapped
            # socket is deduped rather than driving a second turn.
            if cmid is not None:
                self._remember_submit(cmid, sid)
            conn.set_foreground(sid)  # driving a chat brings it on screen (§6)
            return {"session_id": sid}

        if method == UpstreamMethod.BRANCH:
            # R4 L2 (B13): conversation BRANCH = a SEEDED create. Before L2 this
            # was DEAD in relay mode (handle_upstream raised unknown-method) — a
            # silent functional regression vs the gateway-direct seam, which the
            # contract deletes in X4/X7. Create the new session (optionally in
            # the origin's project via ``cwd``), drive the seed prompt into it
            # with the same userMessage synthesis as SUBMIT, and return the new
            # id. Optional params ride through exactly like SUBMIT's (truncate
            # for branch-from-a-point, title/model/provider/cwd on create).
            origin = p.get("session_id")
            text = p.get("prompt") or p.get("text") or ""
            cwd = p.get("cwd")
            submit_kwargs: dict[str, Any] = {}
            truncate = p.get("truncate_before_user_ordinal")
            if isinstance(truncate, int) and not isinstance(truncate, bool):
                submit_kwargs["truncate_before_user_ordinal"] = truncate
            sid = await self._gateway.session_create(
                title=p.get("title") or f"Branch — {origin or 'new chat'}",
                model=p.get("model"),
                provider=p.get("provider"),
                cwd=cwd if isinstance(cwd, str) and cwd else None,
            )
            if text:
                self._store.mark_local_prompt(sid, text)  # R4 L6 (see SUBMIT)
            await self._gateway.prompt_submit(sid, text, **submit_kwargs)
            self._emit_user_message_item(
                conn, sid, p.get("client_message_id"), text
            )
            conn.set_foreground(sid)  # the branched chat comes on screen (§6)
            return {"session_id": sid, "origin": origin}

        if method == UpstreamMethod.RESUME:
            origin = p["session_id"]
            result = await self._gateway.session_resume(origin)
            # Surface the LIVE id (same reactivation semantics as SUBMIT): the
            # gateway may assign a distinct live id, and the phone must drive/
            # foreground THAT id, not the origin.
            live = (result.get("session_id") if isinstance(result, dict) else None) or origin
            conn.set_foreground(live)  # resuming brings it on screen (§6)
            return {"session_id": live, "origin": origin, "result": result}

        # -- interactive gates + stop (pass-through) -------------------------
        if method == UpstreamMethod.APPROVE:
            # ``decision`` is the phone's chosen gate answer (once/session/always/
            # deny/approve); the gateway maps it onto its ``choice`` param. ``all``
            # (optional) applies the decision to every matching pending approval.
            result = await self._gateway.approval_respond(
                p["session_id"],
                p.get("request_id", ""),
                p["decision"],
                resolve_all=bool(p.get("all", False)),
            )
            if self._durable is not None:
                self._durable.resolve_attention(
                    request_id=None if p.get("all") else p.get("request_id") or None,
                    session_id=p["session_id"], kind="approval",
                )
            return result
        if method == UpstreamMethod.CLARIFY:
            result = await self._gateway.clarify_respond(
                p["session_id"], p.get("request_id", ""), p["text"]
            )
            if self._durable is not None:
                self._durable.resolve_attention(
                    request_id=p.get("request_id") or None,
                    session_id=p["session_id"], kind="clarify",
                )
            return result
        if method == UpstreamMethod.INTERRUPT:
            return await self._gateway.session_interrupt(p["session_id"])
        if method == UpstreamMethod.STEER:
            # QA-2 R11: live-turn steering over the relay. The phone sends
            # ``session_id`` + ``text``; the gateway's ``session.steer`` injects
            # the text into the running turn's next context window and returns
            # ``{status: queued|rejected, text}`` — passed through verbatim so
            # the phone maps the disposition identically to the direct path
            # (``rejected`` keeps the user's text so they can queue it instead).
            return await self._gateway.session_steer(
                p["session_id"], str(p.get("text") or "")
            )

        # -- attachments (B9/A5): REST-free, bytes inlined by the phone ------
        if method == UpstreamMethod.ATTACH:
            # The phone cannot reach the gateway's ``POST /api/upload`` REST
            # route on a relay-only reach, so it inlines the bytes as a
            # ``data:<mime>;base64,`` URL and the relay drives the gateway's
            # base64 RPCs: ``file.attach`` (arbitrary files → ``@file:`` ref)
            # or ``image.attach_bytes`` (photos → vision tile). Session
            # resolution mirrors SUBMIT's drive semantics: no ``session_id``
            # → create (+own); foreign/idle → resume (adopt the LIVE id the
            # gateway may remap to); already owned → remap through
            # ``live_id_for`` so the bytes land on the live session, not a
            # dormant origin id.
            kind = p.get("kind")
            if kind not in ("file", "image"):
                raise ValueError(f"attach: unknown kind {kind!r}")
            data_url = p.get("data_url") or ""
            if not data_url:
                raise ValueError("attach: data_url required")
            sid = p.get("session_id")
            if sid:
                if not self._gateway.owns(sid):
                    resumed = await self._gateway.session_resume(sid)
                    if isinstance(resumed, dict):
                        sid = resumed.get("session_id") or sid
                else:
                    sid = self._gateway.live_id_for(sid)
            else:
                sid = await self._gateway.session_create(title=p.get("title", "New chat"))
            name = p.get("name") or ""
            if kind == "file":
                result = await self._gateway.file_attach(sid, name=name, data_url=data_url)
            else:
                result = await self._gateway.image_attach_bytes(
                    sid, data_url=data_url, filename=name
                )
            # Attaching from the composer is an interactive, on-screen action —
            # foreground the chat (§6) exactly like SUBMIT/OPEN do.
            conn.set_foreground(sid)
            if isinstance(result, dict):
                return {"session_id": sid, "kind": kind, **result}
            return {"session_id": sid, "kind": kind, "attached": True}

        raise ValueError(f"unknown upstream method: {method!r}")

    # -- foreground tracking (feeds Notifier §6 gate) --------------------
    def session_has_live_phone(self, session_id: str) -> bool:
        """True iff any connected phone holds ``session_id`` foregrounded.

        The Notifier calls this to skip a push when the user is already watching
        (protocol §6): a foregrounded session on a live WS suppresses APNs.
        """
        return any(session_id in c.foreground_sessions for c in self._conns.values())
