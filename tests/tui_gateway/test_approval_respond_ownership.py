"""ABH-402 — WS approval.respond must be scoped to the owning device session."""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module
from tui_gateway import server as gateway
from tui_gateway.transport import bind_transport, reset_transport


device_tokens = load_plugin_module("device_tokens")


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
    touched: list[str] = []
    yield touched
    for sid in touched:
        gateway._sessions.pop(sid, None)
    device_tokens._reset_for_tests()


def _device_identity(device: dict) -> dict:
    return {
        "device_id": device["device_id"],
        "device_name": device["device_name"],
        "scopes": ["chat", "approve"],
    }


def _own_session(session_id: str, device: dict, clean_state: list[str]) -> None:
    ws = object()
    transport = _Transport(ws)
    device_tokens.register_ws_socket(device["device_id"], ws)
    assert device_tokens.record_session_transport(session_id, transport) == {
        "device_id": device["device_id"]
    }
    gateway._sessions[session_id] = {
        "session_key": f"stored-{session_id}",
        "transport": transport,
    }
    clean_state.append(session_id)


def _call_approval_as(device: dict | None, params: dict) -> dict:
    fake_ws = SimpleNamespace(
        state=SimpleNamespace(device=_device_identity(device) if device is not None else None)
    )
    token = bind_transport(_Transport(fake_ws))
    try:
        return gateway._methods["approval.respond"]("rid-1", params)
    finally:
        reset_transport(token)


def _patch_resolver(monkeypatch):
    import tools.approval as approval

    captured: list[dict] = []

    def _fake(session_key, choice, resolve_all=False, audit=None):
        captured.append(
            {
                "session_key": session_key,
                "choice": choice,
                "resolve_all": resolve_all,
                "audit": audit,
            }
        )
        return 1

    monkeypatch.setattr(approval, "resolve_gateway_approval", _fake)
    return captured


def test_device_cannot_respond_for_session_it_does_not_own(
    clean_state, monkeypatch
):
    owner = device_tokens.issue(device_name="Owner Phone")
    intruder = device_tokens.issue(device_name="Other Phone")
    _own_session("session-b", owner, clean_state)
    captured = _patch_resolver(monkeypatch)

    out = _call_approval_as(
        intruder,
        {"session_id": "session-b", "choice": "approve"},
    )

    assert out["error"]["code"] == 4030
    assert out["error"]["message"] == "device does not own this session"
    assert captured == []


def test_device_that_owns_session_can_respond(clean_state, monkeypatch):
    owner = device_tokens.issue(device_name="Owner Phone")
    _own_session("session-a", owner, clean_state)
    captured = _patch_resolver(monkeypatch)

    out = _call_approval_as(
        owner,
        {"session_id": "session-a", "choice": "approve", "all": True},
    )

    assert out["result"] == {"resolved": 1}
    assert captured == [
        {
            "session_key": "stored-session-a",
            "choice": "once",
            "resolve_all": True,
            "audit": {
                "credential": "device",
                "device_id": owner["device_id"],
                "device_name": owner["device_name"],
                "token_prefix": None,
                "session_id": "session-a",
                "session_key": "stored-session-a",
            },
        }
    ]


def test_no_device_transport_keeps_host_trusted_behavior(clean_state, monkeypatch):
    owner = device_tokens.issue(device_name="Owner Phone")
    _own_session("session-shared", owner, clean_state)
    captured = _patch_resolver(monkeypatch)

    shared = _call_approval_as(
        None,
        {"session_id": "session-shared", "choice": "deny"},
    )
    internal = gateway._methods["approval.respond"](
        "rid-2", {"session_id": "session-shared", "choice": "approve"}
    )

    assert shared["result"] == {"resolved": 1}
    assert internal["result"] == {"resolved": 1}
    assert [call["choice"] for call in captured] == ["deny", "once"]
    assert captured[0]["audit"]["credential"] == "shared"
    assert captured[0]["audit"]["device_id"] is None
    assert captured[1]["audit"]["credential"] == "internal"
    assert captured[1]["audit"]["device_id"] is None
