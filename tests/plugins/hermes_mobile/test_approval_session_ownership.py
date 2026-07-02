"""ABH-258 — device ownership for mobile approval + Live Activity REST paths."""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tests.plugins.hermes_mobile.conftest import load_plugin_module
from tui_gateway import server as gateway

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"
_SHARED_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}
_LA_TOKEN = "a" * 64
_LA_TOKEN_2 = "b" * 64


device_tokens = load_plugin_module("device_tokens")


class _Transport:
    def __init__(self, ws: object) -> None:
        self._ws = ws


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    yield tmp_path
    device_tokens._reset_for_tests()


@pytest.fixture
def client():
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_port = getattr(web_server.app.state, "bound_port", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    c = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    yield c
    web_server.app.state.bound_host = prev_host
    web_server.app.state.bound_port = prev_port
    web_server.app.state.auth_required = prev_required


@pytest.fixture
def devices(home, wired_token_auth):
    owner = device_tokens.issue(device_name="Owner Phone")
    intruder = device_tokens.issue(device_name="Other Phone")
    return owner, intruder


@pytest.fixture(autouse=True)
def clean_gateway_sessions():
    touched: list[str] = []
    yield touched
    for sid in touched:
        gateway._sessions.pop(sid, None)


def _own_session(session_id: str, device_id: str, clean_gateway_sessions) -> None:
    ws = object()
    transport = _Transport(ws)
    device_tokens.register_ws_socket(device_id, ws)
    gateway._sessions[session_id] = {
        "session_key": f"stored-{session_id}",
        "transport": transport,
    }
    clean_gateway_sessions.append(session_id)
    device_tokens.record_session_transport(session_id, transport)


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


def test_approval_respond_requires_device_to_own_session(
    client, devices, clean_gateway_sessions, monkeypatch
):
    owner, intruder = devices
    _own_session("owned-session", owner["device_id"], clean_gateway_sessions)
    captured = _patch_resolver(monkeypatch)

    denied = client.post(
        f"{_PREFIX}/approvals/respond",
        json={"session_id": "owned-session", "choice": "approve"},
        headers={"X-Hermes-Session-Token": intruder["token"]},
    )
    allowed = client.post(
        f"{_PREFIX}/approvals/respond",
        json={"session_id": "owned-session", "choice": "approve"},
        headers={"X-Hermes-Session-Token": owner["token"]},
    )
    shared = client.post(
        f"{_PREFIX}/approvals/respond",
        json={"session_id": "owned-session", "choice": "deny"},
        headers=_SHARED_HEADER,
    )

    assert denied.status_code == 403
    assert denied.json() == {"detail": "Device token does not own session"}
    assert allowed.status_code == 200
    assert shared.status_code == 200
    assert [call["choice"] for call in captured] == ["once", "deny"]
    assert captured[0]["audit"]["device_id"] == owner["device_id"]
    assert captured[1]["audit"]["credential"] == "shared"


def test_live_activity_register_requires_device_to_own_session(
    client, devices, clean_gateway_sessions
):
    owner, intruder = devices
    push_engine = load_plugin_module("push_engine")
    _own_session("owned-la", owner["device_id"], clean_gateway_sessions)

    denied = client.post(
        f"{_PREFIX}/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "owned-la", "env": "sandbox"},
        headers={"X-Hermes-Session-Token": intruder["token"]},
    )
    allowed = client.post(
        f"{_PREFIX}/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "owned-la", "env": "sandbox"},
        headers={"X-Hermes-Session-Token": owner["token"]},
    )
    shared = client.post(
        f"{_PREFIX}/push/live-activity",
        json={"token": _LA_TOKEN_2, "session_id": "owned-la", "env": "sandbox"},
        headers=_SHARED_HEADER,
    )

    assert denied.status_code == 403
    assert denied.json() == {"detail": "Device token does not own session"}
    assert allowed.status_code == 200
    assert shared.status_code == 200
    assert push_engine.live_activity_token_for("owned-la") == (_LA_TOKEN_2, "sandbox")


def test_live_activity_unregister_requires_device_to_own_session(
    client, devices, clean_gateway_sessions
):
    owner, intruder = devices
    push_engine = load_plugin_module("push_engine")
    _own_session("owned-la-delete", owner["device_id"], clean_gateway_sessions)
    assert push_engine.register_live_activity_token(
        "owned-la-delete", _LA_TOKEN, env="sandbox", device_id=owner["device_id"]
    )

    denied = client.request(
        "DELETE",
        f"{_PREFIX}/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "owned-la-delete"},
        headers={"X-Hermes-Session-Token": intruder["token"]},
    )
    assert denied.status_code == 403
    assert denied.json() == {"detail": "Device token does not own session"}
    assert push_engine.live_activity_token_for("owned-la-delete") == (_LA_TOKEN, "sandbox")

    allowed = client.request(
        "DELETE",
        f"{_PREFIX}/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "owned-la-delete"},
        headers={"X-Hermes-Session-Token": owner["token"]},
    )

    assert allowed.status_code == 200
    assert allowed.json()["removed"] is True
    assert push_engine.live_activity_token_for("owned-la-delete") is None

    assert push_engine.register_live_activity_token(
        "owned-la-delete", _LA_TOKEN, env="sandbox", device_id=owner["device_id"]
    )
    shared = client.request(
        "DELETE",
        f"{_PREFIX}/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "owned-la-delete"},
        headers=_SHARED_HEADER,
    )
    assert shared.status_code == 200
    assert shared.json()["removed"] is True
