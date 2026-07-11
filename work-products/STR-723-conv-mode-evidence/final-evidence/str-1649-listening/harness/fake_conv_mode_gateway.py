#!/usr/bin/env python3
"""Deterministic fake Hermes mobile gateway for STR-723 conversation-mode evidence.

Work-product harness only. Serves enough of the dashboard REST + JSON-RPC
surface for the iOS app to pair, resume a stored session (so SessionStore
binds activeRuntimeId and the composer's isConnected gate opens), and let
the client-side VoiceConversationController state machine drive the
conversation-mode UI. This harness does not simulate real STT/TTS audio —
conversation-mode state transitions (idle/listening/etc.) are the app's own
local state machine, not gateway-driven.

PROVENANCE (STR-1649 remediation): copied VERBATIM (no code changes) from
commit b2aa931bf ("STR-723: fix fake gateway WS ping timeout dropping
conversation-mode connection"), where it originally lived at
`work-products/STR-723-conv-mode-evidence/fake_conv_mode_gateway.py` on the
`paperclip/str-723-conv-mode-evidence-retry` branch (not an ancestor of this
branch's history, hence the copy rather than a cherry-pick). Reused here,
unmodified, as the STR-1649 Listening-state evidence capture's gateway
fixture — the app's `HERMES_URL`/`HERMES_TOKEN` DEBUG dev-bootstrap seam
(`ConnectionStore.bootstrap()`) points at this process; ZERO app source is
touched to reach the connected shell it enables.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import time
from pathlib import Path
from typing import Any

import websockets
from websockets.datastructures import Headers
from websockets.http11 import Response

RUNTIME_ID = "rt-str723-conv-mode"
STORED_ID = "stored-str723-conv-mode"

log_path: Path | None = None


def log(event: str, **data: Any) -> None:
    row = {"t": round(time.time(), 3), "event": event, **data}
    line = json.dumps(row, sort_keys=True)
    print(line, flush=True)
    if log_path is not None:
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")


def json_response(obj: Any, status: int = 200, reason: str = "OK") -> Response:
    body = json.dumps(obj).encode("utf-8")
    headers = Headers()
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = str(len(body))
    headers["Access-Control-Allow-Origin"] = "*"
    return Response(status, reason, headers, body)


def session_row() -> dict[str, Any]:
    now = time.time()
    return {
        "id": STORED_ID,
        "title": "STR-723 Conversation Mode Evidence",
        "preview": "Seeded conversation-mode evidence flow",
        "started_at": now - 60,
        "last_active": now,
        "message_count": 1,
        "source": "cli",
        "cwd": "/tmp/str723-fake",
    }


async def process_request(conn: Any, request: Any) -> Response | None:
    if request.headers.get("Upgrade", "").lower() == "websocket":
        return None

    path = request.path.split("?", 1)[0]
    method = getattr(request, "method", "GET")
    log("http", method=method, path=path)

    if path == "/api/status":
        return json_response({
            "version": "0.18.0-str723-fake",
            "hermes_home": "/tmp/str723-fake",
            "gateway_running": False,
            "active_sessions": 1,
            "auth_required": False,
        })
    if path == "/api/config":
        return json_response({
            "model": "ui-evidence-fake",
            "providers": {},
            "fallback_providers": [],
            "toolsets": [],
            "agent": {"max_turns": 90},
            "display": {},
        })
    if path == "/api/model/info":
        return json_response({
            "model": "ui-evidence-fake",
            "provider": "fake",
            "auto_context_length": 0,
            "config_context_length": 0,
            "effective_context_length": 0,
        })
    if path == "/api/analytics/usage":
        return json_response({"daily": [], "by_model": [], "totals": {}, "period_days": 30})
    if path == "/api/profiles":
        return json_response({"profiles": [{"name": "default", "is_default": True, "description": "Default"}]})
    if path == "/api/profiles/sessions":
        return json_response({"sessions": [session_row()], "total": 1, "limit": 50, "offset": 0, "profile_totals": {"default": 1}, "errors": []})
    if path == "/api/sessions":
        return json_response({"sessions": [session_row()], "total": 1, "limit": 50, "offset": 0})
    if path == f"/api/sessions/{STORED_ID}/messages":
        return json_response({"messages": []})
    if path == "/api/plugins/hermes-mobile/devices" or path == "/api/devices":
        return json_response({"devices": []})
    if path == "/api/plugins/hermes-mobile/fs/list":
        return json_response({"cwd": "/tmp/str723-fake", "path": "", "entries": []})
    if path == "/api/upload" and method == "POST":
        return json_response({"detail": "multipart field 'file' required"}, 400, "Bad Request")
    if path == "/api/fs/list":
        return json_response({"detail": "session_id required"}, 400, "Bad Request")

    return json_response({"detail": f"No such API endpoint: {path}"}, 404, "Not Found")


async def emit(ws: Any, event_type: str, payload: dict[str, Any] | None = None,
               *, session_id: str | None = RUNTIME_ID, stored_session_id: str | None = STORED_ID) -> None:
    params: dict[str, Any] = {"type": event_type, "payload": payload or {}}
    if session_id is not None:
        params["session_id"] = session_id
    if stored_session_id is not None:
        params["stored_session_id"] = stored_session_id
    frame = {"jsonrpc": "2.0", "method": "event", "params": params}
    await ws.send(json.dumps(frame))
    log("emit", type=event_type, payload=payload or {})


async def handler(ws: Any) -> None:
    try:
        await emit(ws, "gateway.ready", {"skin": {"name": "default"}}, session_id=None, stored_session_id=None)
        async for message in ws:
            log("ws_in", raw=message[:700])
            try:
                req = json.loads(message)
            except Exception:
                continue
            rid = req.get("id")
            method = req.get("method")
            result: Any = {"ok": True}
            if method in {"session.create", "session.resume"}:
                result = {
                    "session_id": RUNTIME_ID,
                    "stored_session_id": STORED_ID,
                    "message_count": 0,
                    "info": {"model": "ui-evidence-fake", "provider": "fake", "running": False},
                    "messages": [],
                }
            elif method == "prompt.submit":
                result = {"accepted": True}
            elif method == "session.list":
                result = {"sessions": [session_row()]}
            elif method == "session.status":
                result = {"running": False, "model": "ui-evidence-fake", "provider": "fake"}
            elif method == "config.get":
                result = {"model": "ui-evidence-fake", "provider": "fake"}
            elif method == "config.set":
                result = {"ok": True}
            elif method == "complete.path":
                result = {"items": []}
            if rid is not None:
                await ws.send(json.dumps({"jsonrpc": "2.0", "id": rid, "result": result}))
                log("ws_out", id=rid, method=method, result=result)
    finally:
        log("ws_closed")


async def main() -> None:
    global log_path
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9823)
    ap.add_argument("--log", required=True)
    args = ap.parse_args()
    log_path = Path(args.log)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text("", encoding="utf-8")
    async with websockets.serve(
        handler, args.host, args.port, process_request=process_request,
        ping_interval=None,  # disable server-initiated pings — sim WS round-trip lag was
                             # tripping the default 20s ping_timeout and closing the socket,
                             # which fired ComposerView's isConnected->voice.end() mid-flow.
    ):
        log("listening", host=args.host, port=args.port)
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
