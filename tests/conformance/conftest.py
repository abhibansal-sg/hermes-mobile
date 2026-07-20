"""Shared plumbing for the wire-conformance suite (A2/N1).

Adds ``relay/`` to ``sys.path`` (the relay is not an installed package — it is
imported in-place, exactly as ``relay/tests`` does), loads the shared
``wire_contract.json`` fixture once, and provides the fake gateway/WS the
behavioral tests drive ``handle_upstream`` through. No network, no live
gateway — the suite NEVER touches 9119 or any socket.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
RELAY_DIR = REPO_ROOT / "relay"
CONTRACT_PATH = Path(__file__).resolve().parent / "wire_contract.json"

if str(RELAY_DIR) not in sys.path:
    sys.path.insert(0, str(RELAY_DIR))


@pytest.fixture(scope="session")
def contract() -> dict[str, Any]:
    """The shared wire contract — the single source of truth both pytest and
    XCTest assert against."""
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


class FakeGateway:
    """Records every call ``handle_upstream`` makes; supplies canned results.

    Mirrors the ``GatewayClient`` surface the downstream server consumes —
    enough to drive every upstream method end-to-end without a socket.
    """

    def __init__(self, history_messages: int = 60) -> None:
        self.calls: list[tuple[str, dict[str, Any]]] = []
        self._history = [
            {"role": "user" if i % 2 == 0 else "assistant", "text": f"m{i}"}
            for i in range(history_messages)
        ]

    async def wait_ready(self, timeout: float = 10.0) -> bool:
        return True

    def owns(self, session_id: str) -> bool:
        return False  # forces the resume-then-drive path (the interesting one)

    def live_id_for(self, session_id: str) -> str:
        return session_id

    async def session_list(self, limit: int = 200) -> list[dict[str, Any]]:
        self.calls.append(("session.list", {"limit": limit}))
        return [{"session_id": "sess-1"}]

    async def rest_history(self, session_id: str) -> list[dict[str, Any]]:
        self.calls.append(("rest_history", {"session_id": session_id}))
        return list(self._history)

    async def session_create(self, **kwargs: Any) -> str:
        self.calls.append(("session.create", dict(kwargs)))
        return "sess-new"

    async def session_resume(self, session_id: str, **kwargs: Any) -> dict[str, Any]:
        self.calls.append(("session.resume", {"session_id": session_id, **kwargs}))
        return {"session_id": session_id, "resumed": session_id, "message_count": 4}

    async def prompt_submit(self, session_id: str, text: str) -> dict[str, Any]:
        self.calls.append(("prompt.submit", {"session_id": session_id, "text": text}))
        return {"status": "ok"}

    async def approval_respond(
        self, session_id: str, request_id: str, decision: str, *, resolve_all: bool = False
    ) -> dict[str, Any]:
        self.calls.append(
            (
                "approval.respond",
                {
                    "session_id": session_id,
                    "request_id": request_id,
                    "choice": decision,
                    "all": resolve_all,
                },
            )
        )
        return {"resolved": 1}

    async def clarify_respond(self, session_id: str, request_id: str, text: str) -> dict[str, Any]:
        self.calls.append(
            (
                "clarify.respond",
                {"session_id": session_id, "request_id": request_id, "answer": text},
            )
        )
        return {"status": "ok"}

    async def session_interrupt(self, session_id: str) -> dict[str, Any]:
        self.calls.append(("session.interrupt", {"session_id": session_id}))
        return {"status": "ok"}

    async def session_steer(self, session_id: str, text: str) -> dict[str, Any]:
        self.calls.append(("session.steer", {"session_id": session_id, "text": text}))
        return {"status": "queued", "text": text}

    async def file_attach(
        self, session_id: str, *, name: str, data_url: str, timeout: float = 90.0
    ) -> dict[str, Any]:
        self.calls.append(
            ("file.attach", {"session_id": session_id, "name": name, "data_url": data_url})
        )
        return {
            "attached": True,
            "name": name,
            "path": f"/gw/.hermes/desktop-attachments/{name}",
            "ref_path": name,
            "ref_text": f"@file:{name}",
            "uploaded": True,
        }

    async def image_attach_bytes(
        self, session_id: str, *, data_url: str, filename: str = "", timeout: float = 90.0
    ) -> dict[str, Any]:
        self.calls.append(
            (
                "image.attach_bytes",
                {"session_id": session_id, "content_base64": data_url, "filename": filename},
            )
        )
        return {"attached": True, "path": "/gw/images/upload_1.jpg", "count": 1}


class FakeWS:
    """Minimal phone socket: records JSON replies (RPC results)."""

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, data: str) -> None:
        self.sent.append(data)


@pytest.fixture()
def server_stack():
    """A DownstreamServer wired to a FakeGateway + one registered PhoneConnection.

    The replay ring is built from the verbatim plugins/hermes-mobile module via
    the plugin bridge — the same code path production uses — so the local
    ack/resync control frames are exercised for real.
    """
    from hermes_relay.bus import EventBus
    from hermes_relay.downstream import DownstreamConfig, DownstreamServer
    from hermes_relay.session_state import SessionStore

    gateway = FakeGateway()
    server = DownstreamServer(
        DownstreamConfig(), EventBus(), gateway, SessionStore(), durable=None
    )
    import asyncio

    asyncio.run(server.start())  # builds the replay ring (no sockets bound)
    ws = FakeWS()
    conn = server.register(ws)
    yield server, conn, gateway
    server.unregister(conn)


# Values used to synthesize a payload from an EXTRACTED key set (the "what iOS
# actually sends" behavioral test). Every key any current builder can emit has
# a typed sample here; a new key without a sample fails loudly (KeyError) so
# the table stays complete.
SAMPLE_VALUES: dict[str, Any] = {
    "session_id": "sess-1",
    "request_id": "req-1",
    "prompt": "Hello from the phone",
    "text": "staging",
    "decision": "approve",
    "approved": True,
    "response": "staging",
    "client_message_id": "cmid-1",
    "through": 7,
    "last_seq": 0,
    "limit": 50,
    "all": True,
    "title": "New chat",
    "model": "claude-test",
    "provider": "anthropic",
    # B9/A5 attach: inlined-bytes payload keys.
    "kind": "file",
    "name": "notes.txt",
    "data_url": "data:text/plain;base64,aGVybWVz",
    # push.register / push.unregister (§6a): a 64-hex APNs-shaped token so the
    # relay's real push_engine normalizer accepts the behavioral drive.
    "token": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "platform": "ios",
    "env": "production",
    "events": ["approval", "turn_complete"],
    # QA-2 R1c: the phone's stable per-install identity for one-token-per-device
    # dedup (the relay replaces a device's old entry on a rotated token).
    "device_id": "conformance-device-1",
}
