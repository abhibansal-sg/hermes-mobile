"""Python phone-driver — the device stand-in.

Speaks the ratified relay<->phone protocol (RELAY-PHONE-PROTOCOL.md):

* downstream: ``{seq, sid, turn, kind, body}`` frames, demuxed by ``kind``;
* upstream:   JSON-RPC-2.0 ``{jsonrpc, id, method, params}`` for ``submit``,
  ``approve``, ``clarify``, ``list``, ``history``, ``open``, ``interrupt``,
  ``ack``, ``resync``, ``foreground``.

This is the same wire shape the iOS ``RelayClient`` produces. Keeping the driver
in Python lets us assert byte-identity deterministically (scenario f) and run
chaos flaps without depending on a simulator.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Optional

import websockets

_log = logging.getLogger("e2e.phone")


@dataclass
class PhoneFrame:
    """One downstream frame the phone received."""

    seq: int
    sid: str
    turn: Optional[str]
    kind: str
    body: dict[str, Any]
    t: float = field(default_factory=time.monotonic)

    @classmethod
    def from_wire(cls, d: dict[str, Any]) -> "PhoneFrame":
        return cls(
            seq=int(d.get("seq") or 0),
            sid=d.get("sid", ""),
            turn=d.get("turn"),
            kind=d.get("kind", ""),
            body=dict(d.get("body") or {}),
        )


class PhoneDriver:
    """One persistent WS to the relay downstream port.

    Records every frame received and every upstream RPC sent. Provides helpers
    for the ratified methods plus ``wait_for(kind, …)`` for scenario assertions.
    """

    def __init__(self, url: str, *, token: str = "") -> None:
        # The relay's downstream WS path. The iOS client passes the gateway
        # token as a Bearer header; we replicate that for the health/WS auth
        # gate the relay enables on its downstream port.
        self._url = url
        self._token = token
        self._ws: Optional[Any] = None
        self._id = 0
        self._pending: dict[int, "asyncio.Future[dict[str, Any]]"] = {}
        self.frames: list[PhoneFrame] = []
        self.sent: list[dict[str, Any]] = []
        self._reader: Optional[asyncio.Task] = None
        self._closed = asyncio.Event()

    # -- lifecycle --------------------------------------------------------
    async def connect(self) -> None:
        headers = {"Authorization": f"Bearer {self._token}"} if self._token else None
        self._ws = await websockets.connect(
            self._url, max_size=8 * 1024 * 1024, additional_headers=headers,
        )
        self._reader = asyncio.create_task(self._read_loop())

    async def close(self) -> None:
        self._closed.set()
        if self._reader is not None:
            self._reader.cancel()
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

    async def _read_loop(self) -> None:
        ws = self._ws
        if ws is None:
            return
        try:
            async for raw in ws:
                for line in str(raw).splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError:
                        continue
                    if "id" in msg and msg["id"] in self._pending:
                        fut = self._pending.pop(msg["id"])
                        if not fut.done():
                            fut.set_result(msg)
                    elif "kind" in msg:
                        # downstream frame
                        self.frames.append(PhoneFrame.from_wire(msg))
        except Exception as e:  # noqa: BLE001
            _log.debug("phone reader stopped: %r", e)

    # -- upstream ---------------------------------------------------------
    async def _call(self, method: str, params: dict[str, Any], *, timeout: float = 30.0) -> dict[str, Any]:
        assert self._ws is not None, "phone not connected"
        self._id += 1
        rid = self._id
        frame = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
        fut: "asyncio.Future[dict[str, Any]]" = asyncio.get_event_loop().create_future()
        self._pending[rid] = fut
        self.sent.append({"method": method, "params": params, "id": rid})
        await self._ws.send(json.dumps(frame))
        return await asyncio.wait_for(fut, timeout=timeout)

    # The ratified protocol methods. Each maps 1:1 to the iOS RelayClient call.
    async def submit(
        self, *, text: str, session_id: Optional[str] = None,
        title: Optional[str] = None, client_message_id: Optional[str] = None,
        model: Optional[str] = None, provider: Optional[str] = None,
    ) -> dict[str, Any]:
        params: dict[str, Any] = {"text": text}
        if session_id is not None:
            params["session_id"] = session_id
        if title is not None:
            params["title"] = title
        if client_message_id is not None:
            params["client_message_id"] = client_message_id
        if model is not None:
            params["model"] = model
        if provider is not None:
            params["provider"] = provider
        return await self._call("submit", params)

    async def resume(self, session_id: str) -> dict[str, Any]:
        return await self._call("resume", {"session_id": session_id})

    async def open_session(self, session_id: str) -> dict[str, Any]:
        # `open` = bring the chat on screen (foreground) + cold read.
        return await self._call("open", {"session_id": session_id})

    async def list_sessions(self, *, limit: int = 200) -> dict[str, Any]:
        return await self._call("list", {"limit": limit})

    async def history(self, session_id: str) -> dict[str, Any]:
        return await self._call("history", {"session_id": session_id})

    async def approve(
        self, *, session_id: str, request_id: str, decision: str = "once",
        all_: bool = False,
    ) -> dict[str, Any]:
        return await self._call("approve", {
            "session_id": session_id, "request_id": request_id,
            "decision": decision, "all": all_,
        })

    async def clarify(
        self, *, session_id: str, request_id: str, text: str,
    ) -> dict[str, Any]:
        return await self._call("clarify", {
            "session_id": session_id, "request_id": request_id, "text": text,
        })

    async def interrupt(self, session_id: str) -> dict[str, Any]:
        return await self._call("interrupt", {"session_id": session_id})

    async def ack(self, through: int) -> None:
        # ack is a notification (no id, no response).
        assert self._ws is not None
        frame = {"jsonrpc": "2.0", "method": "ack", "params": {"through": through}}
        self.sent.append({"method": "ack", "params": {"through": through}, "id": None})
        await self._ws.send(json.dumps(frame))

    async def resync(self, last_seq: int) -> None:
        assert self._ws is not None
        frame = {"jsonrpc": "2.0", "method": "resync", "params": {"last_seq": last_seq}}
        self.sent.append({"method": "resync", "params": {"last_seq": last_seq}, "id": None})
        await self._ws.send(json.dumps(frame))

    async def foreground(self, session_id: Optional[str]) -> None:
        assert self._ws is not None
        frame = {"jsonrpc": "2.0", "method": "foreground",
                 "params": {"session_id": session_id}}
        self.sent.append({"method": "foreground",
                          "params": {"session_id": session_id}, "id": None})
        await self._ws.send(json.dumps(frame))

    # -- downstream assertions -------------------------------------------
    def frames_for(self, sid: str) -> list[PhoneFrame]:
        return [f for f in self.frames if f.sid == sid]

    def frames_of_kind(self, kind: str, *, sid: Optional[str] = None) -> list[PhoneFrame]:
        out = [f for f in self.frames if f.kind == kind]
        if sid is not None:
            out = [f for f in out if f.sid == sid]
        return out

    # -- item-vs-frame disambiguation ------------------------------------
    # The downstream envelope (RELAY-PHONE-PROTOCOL.md §1/§3) is
    # ``{seq, sid, turn, kind, body}`` where for item.* frames ``body`` is the
    # FULL ITEM dict (``{item_id, type, status, ord, summary, body}``).
    # The item's own type-specific body is therefore at
    # ``frame.body["body"]``. These helpers keep tests honest about which layer
    # they are reading.

    @staticmethod
    def item_body(frame: PhoneFrame) -> dict[str, Any]:
        """The item's inner body dict (``frame.body['body']`` for item frames)."""
        return dict(frame.body.get("body") or {})

    @staticmethod
    def item_type(frame: PhoneFrame) -> str:
        """The item's ``type`` (``frame.body['type']`` for item frames)."""
        return str(frame.body.get("type") or "")

    @staticmethod
    def delta_patch(frame: PhoneFrame) -> dict[str, Any]:
        """The ``patch`` of an item.delta frame (``frame.body['patch']``)."""
        return dict(frame.body.get("patch") or {})

    async def wait_for(
        self, kind: str, *, sid: Optional[str] = None, timeout: float = 30.0,
        predicate: Optional[Any] = None,
    ) -> PhoneFrame:
        """Wait until a matching frame lands in the log; return it."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for f in reversed(self.frames):
                if f.kind != kind:
                    continue
                if sid is not None and f.sid != sid:
                    continue
                if predicate is not None and not predicate(f):
                    continue
                return f
            await asyncio.sleep(0.02)
        raise asyncio.TimeoutError(
            f"phone: no frame kind={kind} sid={sid} within {timeout}s"
            f" (have {len(self.frames)} frames;"
            f" kinds={sorted({f.kind for f in self.frames})})"
        )

    async def wait_for_n(
        self, kind: str, n: int, *, sid: Optional[str] = None, timeout: float = 30.0,
    ) -> list[PhoneFrame]:
        """Wait until at least n frames of this kind are in the log."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            matched = self.frames_of_kind(kind, sid=sid)
            if len(matched) >= n:
                return matched
            await asyncio.sleep(0.02)
        raise asyncio.TimeoutError(
            f"phone: wanted {n} frames kind={kind} sid={sid}, have {len(self.frames_of_kind(kind, sid=sid))}"
        )


def fresh_client_message_id() -> str:
    """A stable-enough id for an outbox row (used by A3 dedupe assertions)."""
    return f"cmid-{uuid.uuid4().hex[:12]}"


# ---------------------------------------------------------------------------
# QA-1 A9 render-conformance fixture recording.
# ---------------------------------------------------------------------------
# The render gate (apps/ios/HermesMobileTests/RenderConformanceTests.swift)
# replays REAL relay frame streams through the iOS render lane
# (RelayItemStore -> ChatStore) and asserts render-model invariants. The
# fixtures it replays are recorded HERE — the phone driver already captures
# every downstream frame verbatim, so a fixture is simply the ordered frame
# log for a session plus the replay metadata the XCTest side needs (the
# submit that drove the turn, and the cached/REST history the phone's GRDB
# transcript cache would have painted before any relay frame landed).
#
# Fixtures are byte-stable across runs when the scenario uses a FIXED session
# id + fixed gate request_ids + deterministic mock-gateway scripts: the relay
# stamps dense seqs from 1 per fresh relay process (the conftest starts one
# per test), and reframer item ids derive from the session id. The one random
# element a script may introduce (e.g. the tasklist script's ``todo-<hex>``
# tool id) is normalized via ``sanitize`` before writing.


def render_fixture(
    driver: PhoneDriver,
    *,
    name: str,
    session_id: str,
    description: str = "",
    submit: Optional[dict[str, Any]] = None,
    cached_history: Optional[list[dict[str, Any]]] = None,
    open_result_messages: Optional[list[dict[str, Any]]] = None,
    settled: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    """Serialize the frames the phone recorded for ``session_id`` as a fixture.

    The frame entries are the EXACT downstream envelopes the relay put on the
    wire (``{seq, sid, turn, kind, body}``), in arrival order — the XCTest
    side replays them byte-for-byte through the real decoders.
    """
    frames = [
        {
            "seq": f.seq,
            "sid": f.sid,
            "turn": f.turn,
            "kind": f.kind,
            "body": f.body,
        }
        for f in driver.frames_for(session_id)
    ]
    fixture: dict[str, Any] = {
        "name": name,
        "description": description,
        "recorded_by": "tests/e2e_daily_driver/test_z_record_render_fixtures.py",
        "replayed_by": "apps/ios/HermesMobileTests/RenderConformanceTests.swift",
        "protocol": "docs/RELAY-PHONE-PROTOCOL.md",
        "session_id": session_id,
        "submit": submit,
        # The transcript the GRDB cache paints BEFORE any relay frame lands
        # (seedTranscriptCacheFirst). Relay frames never carry this history,
        # so the fixture records what the render lane must PRESERVE.
        "cached_history": cached_history or [],
        # The relay `open` RPC RESULT carries the same REST history
        # (downstream.py) — recorded for the contract that the relay path
        # seeds from it; qa1/base discards it.
        "open_result_messages": open_result_messages or [],
        "frames": frames,
        "settled": settled or {},
    }
    return fixture


def write_render_fixture(
    fixture: dict[str, Any],
    path,
    *,
    sanitize: Optional[Any] = None,
) -> None:
    """Write a fixture as pretty JSON; ``sanitize(text) -> text`` normalizes
    any non-deterministic ids (e.g. the tasklist script's random tool id) so
    the committed fixture is byte-stable across recordings."""
    text = json.dumps(fixture, indent=2, ensure_ascii=False, sort_keys=False) + "\n"
    if sanitize is not None:
        text = sanitize(text)
    path = __import__("pathlib").Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    _log.info("recorded render fixture %s (%d frames)", path.name,
              len(fixture.get("frames") or []))
