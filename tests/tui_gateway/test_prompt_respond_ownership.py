"""STR-92/ABH-415 — WS clarify/terminal.read/sudo/secret .respond methods must
enforce the same device-token scope floor + session-ownership check that
approval.respond already has (ABH-402), routed through the shared
``_respond()`` helper in ``tui_gateway/server.py``.
"""

from __future__ import annotations

import threading
from types import SimpleNamespace

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module
from tui_gateway import server as gateway
from tui_gateway.transport import bind_transport, reset_transport


device_tokens = load_plugin_module("device_tokens")


RESPOND_METHODS = [
    ("clarify.respond", "answer"),
    ("terminal.read.respond", "text"),
    ("sudo.respond", "password"),
    ("secret.respond", "value"),
]


class _Transport:
    def __init__(self, ws: object) -> None:
        self._ws = ws

    def write(self, obj: dict) -> bool:
        return True

    def close(self) -> None:
        return None


@pytest.fixture(autouse=True)
def clean_state(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    pending_ids: list[str] = []
    yield pending_ids
    for rid in pending_ids:
        gateway._pending.pop(rid, None)
        gateway._pending_prompt_payloads.pop(rid, None)
        gateway._answers.pop(rid, None)
    device_tokens._reset_for_tests()


def _device_identity(device: dict, scopes: list[str]) -> dict:
    return {
        "device_id": device["device_id"],
        "device_name": device["device_name"],
        "scopes": scopes,
    }


def _own_session(session_id: str, device: dict) -> None:
    """Correlate *session_id* to *device* via a live WS socket, matching how
    the real device_tokens session index is populated (ABH-402 pattern)."""
    ws = object()
    transport = _Transport(ws)
    device_tokens.register_ws_socket(device["device_id"], ws)
    assert device_tokens.record_session_transport(session_id, transport) == {
        "device_id": device["device_id"]
    }


def _make_pending(session_id: str, pending_ids: list[str]) -> tuple[str, threading.Event]:
    rid = f"rid-{session_id}"
    ev = threading.Event()
    gateway._pending[rid] = (session_id, ev)
    pending_ids.append(rid)
    return rid, ev


def _call_respond_as(device: dict | None, method: str, params: dict) -> dict:
    fake_ws = SimpleNamespace(state=SimpleNamespace(device=device))
    token = bind_transport(_Transport(fake_ws))
    try:
        return gateway._methods[method]("rid-call", params)
    finally:
        reset_transport(token)


@pytest.mark.parametrize("method,key", RESPOND_METHODS)
def test_owner_device_with_approve_scope_can_respond(clean_state, method, key):
    owner = device_tokens.issue(device_name="Owner Phone")
    _own_session("session-owner", owner)
    rid, ev = _make_pending("session-owner", clean_state)

    out = _call_respond_as(
        _device_identity(owner, ["chat", "approve"]),
        method,
        {"request_id": rid, key: "the-answer"},
    )

    assert out["result"] == {"status": "ok"}
    assert gateway._answers[rid] == "the-answer"
    assert ev.is_set()


@pytest.mark.parametrize("method,key", RESPOND_METHODS)
def test_non_owner_device_hijack_is_denied(clean_state, method, key):
    """The stated exploit: a non-owner device supplies another session's
    request_id and must be denied without setting the event or _answers."""
    owner = device_tokens.issue(device_name="Owner Phone")
    intruder = device_tokens.issue(device_name="Intruder Phone")
    _own_session("session-victim", owner)
    rid, ev = _make_pending("session-victim", clean_state)

    out = _call_respond_as(
        _device_identity(intruder, ["chat", "approve"]),
        method,
        {"request_id": rid, key: "malicious"},
    )

    assert out["error"]["code"] == 4030
    assert out["error"]["message"] == "device does not own this session"
    assert rid not in gateway._answers
    assert not ev.is_set()


@pytest.mark.parametrize("method,key", RESPOND_METHODS)
def test_chat_only_scope_is_denied_even_for_owner(clean_state, method, key):
    """Scope floor: a chat-only device token must be denied even when it
    otherwise owns the session — approve scope is required regardless."""
    owner = device_tokens.issue(device_name="Owner Phone")
    _own_session("session-owner-chat", owner)
    rid, ev = _make_pending("session-owner-chat", clean_state)

    out = _call_respond_as(
        _device_identity(owner, ["chat"]),
        method,
        {"request_id": rid, key: "malicious"},
    )

    assert out["error"]["code"] == 4030
    assert out["error"]["message"] == "device token lacks approve scope"
    assert rid not in gateway._answers
    assert not ev.is_set()


@pytest.mark.parametrize("method,key", RESPOND_METHODS)
def test_no_device_transport_keeps_host_trusted_behavior(clean_state, method, key):
    """Shared-token / internal (no ws.state.device) callers must remain
    backwards compatible — legacy trusted behavior, no ownership check."""
    rid, ev = _make_pending("session-shared", clean_state)

    shared = _call_respond_as(None, method, {"request_id": rid, key: "ok-shared"})
    assert shared["result"] == {"status": "ok"}
    assert gateway._answers[rid] == "ok-shared"
    assert ev.is_set()

    rid2, ev2 = _make_pending("session-internal", clean_state)
    internal = gateway._methods[method]("rid-internal", {"request_id": rid2, key: "ok-internal"})
    assert internal["result"] == {"status": "ok"}
    assert gateway._answers[rid2] == "ok-internal"
    assert ev2.is_set()


@pytest.mark.parametrize("method,key", RESPOND_METHODS)
def test_unknown_request_id_still_errors_before_device_checks(clean_state, method, key):
    owner = device_tokens.issue(device_name="Owner Phone")

    out = _call_respond_as(
        _device_identity(owner, ["chat", "approve"]),
        method,
        {"request_id": "no-such-rid", key: "x"},
    )

    assert out["error"]["code"] == 4009
