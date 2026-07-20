"""B9/A5 — the relay ``attach`` upstream method (REST-free photo/file attach).

A relay-only phone cannot reach the gateway's ``POST /api/upload`` REST route,
so the composer ``+`` attach flow rides the relay WS instead: the phone inlines
the bytes as a ``data:`` URL and the relay translates ``attach`` onto the
gateway's base64 RPCs (``file.attach`` / ``image.attach_bytes``), resolving the
session exactly like SUBMIT (absent -> create; foreign -> resume + adopt the
live id; owned -> remap).

Hermetic: stdlib + pytest + unittest.mock only, NO network. Mirrors
``test_downstream.py``'s FakeWS / AsyncMock-gateway pattern (relays the
DownstreamServer under test through the REAL ``handle_upstream``).
"""

from __future__ import annotations

import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from hermes_relay.bus import EventBus
from hermes_relay.downstream import DownstreamConfig, DownstreamServer
from hermes_relay.session_state import SessionStore
from hermes_relay.types import UpstreamMethod, UpstreamRequest


class FakeWS:
    """Records every message the relay writes to the phone socket."""

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, msg: str) -> None:
        self.sent.append(msg)

    @property
    def frames(self) -> list[dict]:
        return [json.loads(m) for m in self.sent]


def _server():
    gw = MagicMock()
    gw.session_create = AsyncMock(return_value="sNew")
    gw.session_resume = AsyncMock(return_value={"ok": True})
    gw.file_attach = AsyncMock(return_value={
        "attached": True,
        "name": "notes.txt",
        "path": "/gw/.hermes/desktop-attachments/notes.txt",
        "ref_path": "notes.txt",
        "ref_text": "@file:notes.txt",
        "uploaded": True,
    })
    gw.image_attach_bytes = AsyncMock(return_value={
        "attached": True,
        "path": "/gw/images/upload_1.jpg",
        "count": 1,
    })
    gw.owns = MagicMock(return_value=False)
    gw.wait_ready = AsyncMock(return_value=True)
    gw.live_id_for = MagicMock(side_effect=lambda s: s)
    srv = DownstreamServer(DownstreamConfig(), EventBus(), gw, SessionStore())
    return srv, gw


async def _handle(srv, params, conn=None):
    conn = conn or srv.register(FakeWS())
    return await srv.handle_upstream(
        conn, UpstreamRequest(method=UpstreamMethod.ATTACH, params=params, id=7)
    )


_DATA_URL = "data:text/plain;base64,aGVybWVz"


def test_attach_is_a_ratified_upstream_method():
    assert UpstreamMethod.ATTACH == "attach"
    assert UpstreamMethod.ATTACH in UpstreamMethod.ALL


async def test_attach_file_maps_to_file_attach_rpc_and_merges_session_id():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, {
        "session_id": "s9", "kind": "file",
        "name": "notes.txt", "data_url": _DATA_URL,
    })
    gw.file_attach.assert_awaited_once_with("s9", name="notes.txt", data_url=_DATA_URL)
    gw.image_attach_bytes.assert_not_awaited()
    # The gateway result is passed through AND enriched with the resolved
    # session id + kind, so the phone can adopt/verify the target session.
    assert res["session_id"] == "s9"
    assert res["kind"] == "file"
    assert res["ref_text"] == "@file:notes.txt"
    assert res["attached"] is True


async def test_attach_image_maps_to_image_attach_bytes_rpc():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, {
        "session_id": "s9", "kind": "image",
        "name": "dot.jpg", "data_url": "data:image/jpeg;base64,/9j/AA",
    })
    gw.image_attach_bytes.assert_awaited_once_with(
        "s9", data_url="data:image/jpeg;base64,/9j/AA", filename="dot.jpg"
    )
    gw.file_attach.assert_not_awaited()
    assert res["session_id"] == "s9"
    assert res["kind"] == "image"
    assert res["attached"] is True
    assert res["path"] == "/gw/images/upload_1.jpg"


async def test_attach_without_session_id_creates_then_attaches():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, {"kind": "file", "name": "n.txt", "data_url": _DATA_URL})
    gw.session_create.assert_awaited_once()
    gw.file_attach.assert_awaited_once_with(
        "sNew", name="n.txt", data_url=_DATA_URL
    )
    assert res["session_id"] == "sNew"
    gw.session_resume.assert_not_awaited()


async def test_attach_resumes_foreign_session_and_adopts_live_id():
    srv, gw = _server()
    await srv.start()
    gw.owns = MagicMock(return_value=False)
    gw.session_resume = AsyncMock(return_value={"session_id": "live-1"})
    res = await _handle(srv, {
        "session_id": "origin-1", "kind": "file",
        "name": "n.txt", "data_url": _DATA_URL,
    })
    gw.session_resume.assert_awaited_once_with("origin-1")
    # The bytes land on the LIVE id the gateway remapped to, not the origin —
    # same drive semantics as SUBMIT (dormant-origin bug class).
    gw.file_attach.assert_awaited_once_with(
        "live-1", name="n.txt", data_url=_DATA_URL
    )
    assert res["session_id"] == "live-1"


async def test_attach_owned_session_remaps_through_live_id_for():
    srv, gw = _server()
    await srv.start()
    gw.owns = MagicMock(return_value=True)
    gw.live_id_for = MagicMock(return_value="live-2")
    res = await _handle(srv, {
        "session_id": "origin-2", "kind": "image",
        "name": "p.jpg", "data_url": "data:image/jpeg;base64,xx",
    })
    gw.session_resume.assert_not_awaited()
    gw.live_id_for.assert_called_once_with("origin-2")
    gw.image_attach_bytes.assert_awaited_once_with(
        "live-2", data_url="data:image/jpeg;base64,xx", filename="p.jpg"
    )
    assert res["session_id"] == "live-2"


async def test_attach_foregrounds_the_session():
    srv, gw = _server()
    await srv.start()
    conn = srv.register(FakeWS())
    await srv.handle_upstream(
        conn, UpstreamRequest(UpstreamMethod.ATTACH, {
            "session_id": "s9", "kind": "file",
            "name": "n.txt", "data_url": _DATA_URL,
        }, id=7)
    )
    # Attaching from the composer is interactive — the chat is on screen (§6),
    # so the Notifier foreground gate must see it exactly like SUBMIT/OPEN.
    assert "s9" in conn.foreground_sessions


async def test_attach_unknown_kind_raises():
    srv, gw = _server()
    await srv.start()
    with pytest.raises(ValueError, match="unknown kind"):
        await _handle(srv, {"session_id": "s9", "kind": "pdf", "data_url": _DATA_URL})
    gw.file_attach.assert_not_awaited()
    gw.image_attach_bytes.assert_not_awaited()


async def test_attach_missing_data_url_raises():
    srv, gw = _server()
    await srv.start()
    with pytest.raises(ValueError, match="data_url required"):
        await _handle(srv, {"session_id": "s9", "kind": "file", "name": "n.txt"})
    gw.file_attach.assert_not_awaited()


async def test_attach_waits_for_gateway_readiness():
    srv, gw = _server()
    await srv.start()
    gw.wait_ready = AsyncMock(return_value=False)  # gateway not up yet
    with pytest.raises(ConnectionError):
        await _handle(srv, {
            "session_id": "s9", "kind": "file",
            "name": "n.txt", "data_url": _DATA_URL,
        })
    gw.file_attach.assert_not_awaited()
