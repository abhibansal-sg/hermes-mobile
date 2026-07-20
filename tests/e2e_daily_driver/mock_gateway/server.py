"""Scripted-echo mock gateway — deterministic upstream for the E2E gate.

Speaks the EXACT wire protocol the relay's :class:`GatewayClient` expects:

* WS endpoint ``/api/ws?token=…`` (line-delimited JSON-RPC 2.0 in both dirs)
* inbound requests are answered with ``{"jsonrpc":"2.0","id":N,"result":…}``
* gateway-initiated pushes are ``{"jsonrpc":"2.0","method":"event",
  "params":{"type","session_id","payload"}}``
* REST ``GET /api/sessions/{id}/messages`` returns the stored message list
  (the relay's R0-corrected store-read path).

It is **scripted**: each session is created with a *script* — an ordered list of
events to emit once a ``prompt.submit`` lands. Scripts are deterministic, so
scenario (f) can assert byte-identical transcript reconstruction across a chaos
run vs. a clean run.

The mock gateway lives IN-PROCESS (a ``websockets.serve`` task on an
OS-assigned loopback port), so the relay subprocess is the only forked thing.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Optional

import websockets
from websockets.server import WebSocketServerProtocol

_log = logging.getLogger("e2e.mock_gateway")

# Fixed e2e-only token. The relay's `--token-file` is pointed at this. NEVER a
# real gateway credential — it gates loopback-only test traffic.
E2E_TOKEN = "e2e-mock-gateway-token-fixed"

# Per-delta delay. Tiny but non-zero so the phone driver actually sees a stream
# (exercises seq stamping, ring append, and mid-stream flap windows).
DEFAULT_DELTA_DELAY_S = 0.01


# ---------------------------------------------------------------------------
# Script primitives — what to emit on each prompt.submit / approval / clarify.
# ---------------------------------------------------------------------------

@dataclass
class MockSession:
    """One in-memory session owned by the mock gateway."""

    sid: str
    title: str = "E2E session"
    source: str = "mobile-relay"
    model: str = "mock-model"
    provider: str = "mock"
    script: "Script | None" = None
    # History of completed user + agent messages (the REST /messages view).
    history: list[dict[str, Any]] = field(default_factory=list)
    # Pending interactive gates this session is blocked on (request_id -> kind).
    pending: dict[str, str] = field(default_factory=dict)
    # Index of the next script step to run when submit fires again (the script
    # may emit an interactive gate mid-run; the answer unblocks the rest).
    step: int = 0


# A script step is a callable that, given the session + a "send event" closure,
# runs to completion (may await). This lets a single script express "stream 3
# deltas, then ask approval, then on approve stream 2 more deltas, complete".
Step = Callable[[MockSession, "SendFn"], Awaitable[None]]
SendFn = Callable[[str, dict[str, Any]], Awaitable[None]]


def _ev(type_: str, sid: str, payload: Any) -> tuple[str, dict[str, Any]]:
    """Build a (sid, params) pair for the bus.send_event pattern."""
    return sid, {"type": type_, "session_id": sid, "payload": payload}


async def _emit_simple(sess: MockSession, send: SendFn) -> None:
    """Stream N word-deltas of a fixed sentence, then message.complete.

    Deterministic: identical input -> identical bytes across runs (A4).
    """
    text = (sess.script.kwargs.get("text") if sess.script else None) or (
        "Paris is the capital of France."
    )
    words = text.split()
    await send(sess.sid, {"type": "message.start", "session_id": sess.sid, "payload": None})
    for w in words:
        await send(sess.sid, {
            "type": "message.delta", "session_id": sess.sid,
            "payload": {"text": w + (" " if w is not words[-1] else "")},
        })
        await asyncio.sleep(sess.script.kwargs.get("delta_delay_s", DEFAULT_DELTA_DELAY_S) if sess.script else DEFAULT_DELTA_DELAY_S)
    await send(sess.sid, {
        "type": "message.complete", "session_id": sess.sid,
        "payload": {
            "text": text,
            "status": "complete",
            "usage": {"model": sess.model, "input": 1, "output": len(words), "total": len(words) + 1},
        },
    })
    sess.history.append({"role": "user", "content": sess.script.kwargs.get("last_prompt", "") if sess.script else ""})
    sess.history.append({"role": "assistant", "content": text})


async def _emit_approval(sess: MockSession, send: SendFn) -> None:
    """Stream one delta, emit approval.request, then BLOCK on the answer.

    The mock gateway parks here until an inbound ``approval.respond`` arrives
    for this request_id (the bus's pending gate). On approve, stream two more
    deltas + complete; on deny, emit error.

    The block is BOUNDED (default 8s): in the live-driven E2E mode the phone
    answers within milliseconds; in the in-process notifier drive (scenario g)
    no one answers, and the script should still terminate so the test can
    assert the approval.request push without hanging forever.
    """
    rid = sess.script.kwargs.get("request_id", f"appr-{uuid.uuid4().hex[:6]}") if sess.script else f"appr-{uuid.uuid4().hex[:6]}"
    sess.pending[rid] = "approval"
    title = (sess.script.kwargs.get("title") if sess.script else None) or "Run tool?"
    description = (sess.script.kwargs.get("description") if sess.script else None) or "Proceed?"
    await send(sess.sid, {"type": "message.start", "session_id": sess.sid, "payload": None})
    await send(sess.sid, {"type": "message.delta", "session_id": sess.sid, "payload": {"text": "About to "}})
    # The interactive gate. The phone sees this and must reply via the relay.
    await send(sess.sid, {
        "type": "approval.request", "session_id": sess.sid,
        "payload": {
            "request_id": rid,
            "title": title,
            "description": description,
            "command": "rm -rf build/",   # example, redacted upstream by the gateway in real life
            "choices": ["once", "session", "always", "deny"],
        },
    })
    # Park until the test driver answers (bounded — see docstring).
    wait_event = sess.script.kwargs.get("_wait_event") if sess.script else None
    decision = "once"
    if wait_event is not None:
        try:
            await asyncio.wait_for(wait_event.wait(), timeout=sess.script.kwargs.get("wait_timeout_s", 8.0))  # type: ignore[arg-type]
            decision = sess.script.kwargs.get("_decision") or "once"
        except asyncio.TimeoutError:
            # In-process drive (scenario g): no phone answers. Bail with a
            # default approve so the rest of the script is harmless.
            decision = "once"
    sess.pending.pop(rid, None)
    if decision == "deny":
        await send(sess.sid, {
            "type": "error", "session_id": sess.sid,
            "payload": {"message": "denied by user"},
        })
        return
    await send(sess.sid, {"type": "message.delta", "session_id": sess.sid, "payload": {"text": "run the tool. "}})
    await send(sess.sid, {"type": "message.delta", "session_id": sess.sid, "payload": {"text": "Done."}})
    await send(sess.sid, {
        "type": "message.complete", "session_id": sess.sid,
        "payload": {
            "text": "About to run the tool. Done.",
            "status": "complete",
            "usage": {"model": sess.model, "input": 1, "output": 2, "total": 3},
        },
    })


async def _emit_clarify(sess: MockSession, send: SendFn) -> None:
    """Emit clarify.request, block on the answer (bounded), then echo it back."""
    rid = sess.script.kwargs.get("request_id", f"clar-{uuid.uuid4().hex[:6]}") if sess.script else f"clar-{uuid.uuid4().hex[:6]}"
    sess.pending[rid] = "clarify"
    question = (sess.script.kwargs.get("question") if sess.script else None) or "Which color?"
    choices = (sess.script.kwargs.get("choices") if sess.script else None) or ["red", "green", "blue"]
    await send(sess.sid, {"type": "message.start", "session_id": sess.sid, "payload": None})
    await send(sess.sid, {
        "type": "clarify.request", "session_id": sess.sid,
        "payload": {"request_id": rid, "question": question, "choices": choices},
    })
    # Park until answered (bounded — see _emit_approval docstring).
    wait_event = sess.script.kwargs.get("_wait_event") if sess.script else None
    answer = "red"
    if wait_event is not None:
        try:
            await asyncio.wait_for(wait_event.wait(), timeout=sess.script.kwargs.get("wait_timeout_s", 8.0))  # type: ignore[arg-type]
            answer = sess.script.kwargs.get("_answer") or "red"
        except asyncio.TimeoutError:
            answer = "red"
    sess.pending.pop(rid, None)
    await send(sess.sid, {"type": "message.delta", "session_id": sess.sid, "payload": {"text": f"You chose {answer}. "}})
    await send(sess.sid, {"type": "message.delta", "session_id": sess.sid, "payload": {"text": "Noted."}})
    await send(sess.sid, {
        "type": "message.complete", "session_id": sess.sid,
        "payload": {
            "text": f"You chose {answer}. Noted.",
            "status": "complete",
            "usage": {"model": sess.model, "input": 1, "output": 2, "total": 3},
        },
    })


async def _emit_tasklist(sess: MockSession, send: SendFn) -> None:
    """Emit tool.start(name=todo) snapshot, then tool.complete with all_complete.

    Exercises the reframer's dedicated taskList lifecycle on a stable id.
    """
    tool_id = f"todo-{uuid.uuid4().hex[:6]}"
    pending_tasks = [
        {"id": "t1", "text": "First thing", "status": "in_progress"},
        {"id": "t2", "text": "Second thing", "status": "pending"},
        {"id": "t3", "text": "Third thing", "status": "pending"},
    ]
    await send(sess.sid, {"type": "message.start", "session_id": sess.sid, "payload": None})
    await send(sess.sid, {
        "type": "tool.start", "session_id": sess.sid,
        "payload": {"tool_id": tool_id, "name": "todo", "args": {"todos": pending_tasks}},
    })
    await asyncio.sleep(DEFAULT_DELTA_DELAY_S)
    # Update: t1 done, t2 in_progress.
    mid_tasks = [
        {"id": "t1", "text": "First thing", "status": "completed"},
        {"id": "t2", "text": "Second thing", "status": "in_progress"},
        {"id": "t3", "text": "Third thing", "status": "pending"},
    ]
    await send(sess.sid, {
        "type": "tool.complete", "session_id": sess.sid,
        "payload": {"tool_id": tool_id, "name": "todo", "todos": mid_tasks,
                    "duration_s": 0.01, "result": "ok"},
    })
    await asyncio.sleep(DEFAULT_DELTA_DELAY_S)
    # Final: all done.
    done_tasks = [
        {"id": "t1", "text": "First thing", "status": "completed"},
        {"id": "t2", "text": "Second thing", "status": "completed"},
        {"id": "t3", "text": "Third thing", "status": "completed"},
    ]
    await send(sess.sid, {
        "type": "tool.complete", "session_id": sess.sid,
        "payload": {"tool_id": tool_id, "name": "todo", "todos": done_tasks,
                    "duration_s": 0.02, "result": "ok"},
    })
    await send(sess.sid, {"type": "message.delta", "session_id": sess.sid, "payload": {"text": "All tasks done."}})
    await send(sess.sid, {
        "type": "message.complete", "session_id": sess.sid,
        "payload": {"text": "All tasks done.", "status": "complete",
                    "usage": {"model": sess.model, "input": 1, "output": 1, "total": 2}},
    })


_SCRIPTS = {
    "simple": _emit_simple,
    "approval": _emit_approval,
    "clarify": _emit_clarify,
    "tasklist": _emit_tasklist,
}


@dataclass
class Script:
    """A named, parametrized script for a session."""

    name: str
    kwargs: dict[str, Any] = field(default_factory=dict)

    @property
    def fn(self) -> Step:
        return _SCRIPTS[self.name]


# ---------------------------------------------------------------------------
# The mock gateway: WS + a tiny REST shim for /api/sessions/{id}/messages.
# ---------------------------------------------------------------------------


class MockGateway:
    """In-process scripted gateway. ``serve()`` runs the WS server task."""

    def __init__(self) -> None:
        self.sessions: dict[str, MockSession] = {}
        # Connections the relay has opened (one at a time, but support many).
        self._conns: set[WebSocketServerProtocol] = set()
        self._server: Any = None
        self._port: int = 0
        self._stop = asyncio.Event()
        # Per-session lock so two concurrent prompt.submits serialize cleanly.
        self._session_locks: dict[str, asyncio.Lock] = {}
        # Tracks every event emitted (for white-box test assertions).
        self.event_log: list[dict[str, Any]] = []
        # Tracks every RPC the relay sent (method + params).
        self.rpc_log: list[dict[str, Any]] = []
        # Tracks every approval.respond / clarify.respond the relay forwarded.
        self.respond_log: list[dict[str, Any]] = []

    # -- lifecycle --------------------------------------------------------
    async def start(self) -> None:
        self._server = await websockets.serve(
            self._handle, "127.0.0.1", 0, max_size=8 * 1024 * 1024,
            process_request=self._process_request,
        )
        # Read back the bound port.
        socks = self._server.sockets or self._server.server.sockets  # type: ignore[attr-defined]
        self._port = socks[0].getsockname()[1]
        _log.info("mock-gateway listening on 127.0.0.1:%s", self._port)

    async def stop(self) -> None:
        self._stop.set()
        if self._server is not None:
            self._server.close()
            await self._server.wait_closed()
            self._server = None

    @property
    def port(self) -> int:
        return self._port

    @property
    def token(self) -> str:
        return E2E_TOKEN

    # -- HTTP: websockets calls process_request before the WS upgrade -----
    async def _process_request(self, conn, request) -> Any:
        """Serve the REST history path; fall through to WS upgrade otherwise."""
        from http import HTTPStatus
        path = (request.path or "").split("?", 1)[0]
        # /api/sessions/{sid}/messages — the relay's R0-corrected store-read.
        if path.startswith("/api/sessions/") and path.endswith("/messages"):
            sid = path[len("/api/sessions/"):-len("/messages")]
            sess = self.sessions.get(sid)
            msgs = list(sess.history) if sess else []
            body = json.dumps({"session_id": sid, "messages": msgs}) + "\n"
            return conn.respond(HTTPStatus.OK, body)
        if path == "/healthz":
            return conn.respond(HTTPStatus.OK, '{"ok": true}\n')
        return None  # proceed to WS handshake

    # -- WS ---------------------------------------------------------------
    async def _handle(self, ws: WebSocketServerProtocol) -> None:
        self._conns.add(ws)
        # On connect the stock gateway pushes gateway.ready — emit it.
        await self._send_event(ws, {"type": "gateway.ready", "session_id": None, "payload": {}})
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
                    asyncio.create_task(self._dispatch(ws, msg))
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            self._conns.discard(ws)

    async def _send_event(self, ws: WebSocketServerProtocol, params: dict[str, Any]) -> None:
        frame = {"jsonrpc": "2.0", "method": "event", "params": params}
        await ws.send(json.dumps(frame))
        self.event_log.append({"t": time.monotonic(), **params})

    async def _broadcast(self, sid: str, params: dict[str, Any]) -> None:
        """Send an event to every live relay connection."""
        # The relay keeps a single multiplexed WS, but broadcast defensively.
        params = {"session_id": sid, **params}
        for ws in list(self._conns):
            try:
                await self._send_event(ws, params)
            except Exception:
                _log.debug("broadcast failed", exc_info=True)

    async def _dispatch(self, ws: WebSocketServerProtocol, msg: dict[str, Any]) -> None:
        """Handle one inbound JSON-RPC from the relay."""
        method = msg.get("method")
        params = msg.get("params") or {}
        rid = msg.get("id")
        self.rpc_log.append({"method": method, "params": params, "id": rid})

        result: Any = None
        error: Any = None

        if method == "session.list":
            result = {"sessions": [
                {"id": s.sid, "title": s.title, "source": s.source,
                 "message_count": len(s.history)}
                for s in self.sessions.values()
            ]}
        elif method == "session.create":
            sid = f"sess-{uuid.uuid4().hex[:8]}"
            script_name = params.get("title", "simple").split(":", 1)
            name = script_name[0] if script_name and script_name[0] in _SCRIPTS else "simple"
            sess = MockSession(
                sid=sid,
                title=params.get("title", "E2E session"),
                source=params.get("source", "mobile-relay"),
                model=params.get("model", "mock-model"),
                provider=params.get("provider", "mock"),
                script=Script(name=name, kwargs={}),
            )
            self.sessions[sid] = sess
            # Emit session.info (the relay ignores it but it's on the wire).
            await self._broadcast(sid, {"type": "session.info", "payload": {
                "model": sess.model, "provider": sess.provider, "tools": {}}})
            result = {"session_id": sid, "title": sess.title}
        elif method == "session.resume":
            sid = params.get("session_id", "")
            sess = self.sessions.get(sid)
            if sess is None:
                error = {"code": -32602, "message": f"unknown session {sid}"}
            else:
                # Stock gateway may hand back the SAME id (no remap for the mock).
                result = {"session_id": sid, "resumed": sid,
                          "message_count": len(sess.history)}
        elif method == "prompt.submit":
            sid = params.get("session_id", "")
            sess = self.sessions.get(sid)
            if sess is None:
                error = {"code": -32602, "message": f"unknown session {sid}"}
            else:
                if sess.script is not None:
                    sess.script.kwargs["last_prompt"] = params.get("text", "")
                # Ack the RPC fast; the stream is pushed asynchronously.
                result = {"ok": True, "session_id": sid}
                asyncio.create_task(self._run_script(sess))
        elif method == "approval.respond":
            sid = params.get("session_id", "")
            rid_q = params.get("request_id", "")
            choice = params.get("choice") or params.get("decision")
            sess = self.sessions.get(sid)
            self.respond_log.append({
                "kind": "approval", "session_id": sid, "request_id": rid_q,
                "choice": choice, "all": params.get("all"),
            })
            if sess is not None and sess.script is not None:
                sess.script.kwargs["_decision"] = choice
                ev = sess.script.kwargs.get("_wait_event")
                if ev is not None:
                    ev.set()
            result = {"ok": True}
        elif method == "clarify.respond":
            sid = params.get("session_id", "")
            rid_q = params.get("request_id", "")
            answer = params.get("answer") or params.get("text")
            sess = self.sessions.get(sid)
            self.respond_log.append({
                "kind": "clarify", "session_id": sid, "request_id": rid_q,
                "answer": answer,
            })
            if sess is not None and sess.script is not None:
                sess.script.kwargs["_answer"] = answer
                ev = sess.script.kwargs.get("_wait_event")
                if ev is not None:
                    ev.set()
            result = {"ok": True}
        elif method == "session.interrupt":
            result = {"ok": True}
        else:
            error = {"code": -32601, "message": f"method not found: {method}"}

        if rid is not None:
            resp = {"jsonrpc": "2.0", "id": rid}
            if error is not None:
                resp["error"] = error
            else:
                resp["result"] = result
            await ws.send(json.dumps(resp))

    async def _run_script(self, sess: MockSession) -> None:
        """Drive a session's script: emit its events on the bus."""
        lock = self._session_locks.setdefault(sess.sid, asyncio.Lock())
        async with lock:
            if sess.script is None:
                return
            # Each submit gets a fresh wait event (interactive scripts block).
            sess.script.kwargs["_wait_event"] = asyncio.Event()

            async def send(sid: str, params: dict[str, Any]) -> None:
                await self._broadcast(sid, params)

            try:
                await sess.script.fn(sess, send)
            except Exception:
                _log.exception("script %s failed", sess.script.name)


# ---------------------------------------------------------------------------
# Session-creation helper for tests.
# ---------------------------------------------------------------------------

async def create_scripted_session(
    gw: MockGateway, *, script: str, **kwargs: Any
) -> str:
    """Pre-create a session on the mock gateway with a chosen script.

    Returns the sid. Used by tests that need a known script on a known sid
    (e.g. chaos runs that re-submit after a flap).
    """
    sid = f"sess-{uuid.uuid4().hex[:8]}"
    sess = MockSession(
        sid=sid,
        title=script,
        script=Script(name=script, kwargs=dict(kwargs)),
    )
    gw.sessions[sid] = sess
    return sid
