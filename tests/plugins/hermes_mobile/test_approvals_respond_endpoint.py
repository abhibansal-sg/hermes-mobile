"""F2-S S1 — REST POST /api/plugins/hermes-mobile/approvals/respond.

A notification-action mirror of the WS ``approval.respond`` RPC so the iOS app
can resolve a pending approval from a background URLSession. Auth mirrors
``.../upload`` (the standard dashboard session token). The body mirrors the WS
params. Tests run entirely in-process via FastAPI TestClient — no network, no
real approval queue (resolve_gateway_approval is patched per the contract's
"never 500 on a moot approval" semantics).

ABH-88 de-patch (W1): the route moved verbatim from ``hermes_cli/web_server.py``
into ``plugins/hermes-mobile/dashboard/api.py``, auto-mounted at
``/api/plugins/hermes-mobile/`` when web_server is imported. The push engine
(formerly ``hermes_cli.push_notify``) is now the plugin's ``push_engine``.
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tui_gateway import server as gateway

from tests.plugins.hermes_mobile.conftest import load_plugin_module

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_TOKEN_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}


@pytest.fixture
def loopback_client():
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_port = getattr(web_server.app.state, "bound_port", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    client = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    yield client
    web_server.app.state.bound_host = prev_host
    web_server.app.state.bound_port = prev_port
    web_server.app.state.auth_required = prev_required


@pytest.fixture
def session(monkeypatch):
    """Register a runtime session in the gateway and clean it up after."""
    sid = "runtime-sid-1"
    gateway._sessions[sid] = {"session_key": "stored-key-1"}
    yield sid
    gateway._sessions.pop(sid, None)


def _patch_resolver(monkeypatch, *, returns=None, raises=False):
    """Patch tools.approval.resolve_gateway_approval and capture its args."""
    import tools.approval as approval
    captured = {}

    def _fake(session_key, choice, resolve_all=False, audit=None):
        captured["session_key"] = session_key
        captured["choice"] = choice
        captured["resolve_all"] = resolve_all
        captured["audit"] = audit
        if raises:
            raise RuntimeError("boom")
        return returns

    monkeypatch.setattr(approval, "resolve_gateway_approval", _fake)
    return captured


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def test_respond_requires_token(loopback_client, session):
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/approvals/respond",
        json={"session_id": session, "choice": "approve"},
    )
    assert r.status_code == 401


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

def test_respond_approve_resolves(loopback_client, session, monkeypatch):
    captured = _patch_resolver(monkeypatch, returns=1)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/approvals/respond",
        json={"session_id": session, "choice": "approve"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    assert r.json() == {"resolved": True}
    # "approve" maps to the gateway's "once" decision.
    assert captured["choice"] == "once"
    assert captured["session_key"] == "stored-key-1"
    assert captured["resolve_all"] is False


def test_respond_deny_maps_to_deny(loopback_client, session, monkeypatch):
    captured = _patch_resolver(monkeypatch, returns=1)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/approvals/respond",
        json={"session_id": session, "choice": "deny"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    assert captured["choice"] == "deny"


def test_respond_all_flag_forwarded(loopback_client, session, monkeypatch):
    captured = _patch_resolver(monkeypatch, returns=2)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/approvals/respond",
        json={"session_id": session, "choice": "approve", "all": True},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    assert captured["resolve_all"] is True


# ---------------------------------------------------------------------------
# Moot approval — resolved:false, never 500
# ---------------------------------------------------------------------------

def test_respond_nothing_pending_returns_resolved_false(
    loopback_client, session, monkeypatch
):
    _patch_resolver(monkeypatch, returns=0)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/approvals/respond",
        json={"session_id": session, "choice": "approve"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    assert r.json() == {"resolved": False}


def test_respond_resolver_error_is_resolved_false_not_500(
    loopback_client, session, monkeypatch
):
    """A moot/already-handled approval must never surface as a 500."""
    _patch_resolver(monkeypatch, raises=True)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/approvals/respond",
        json={"session_id": session, "choice": "approve"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    assert r.json() == {"resolved": False}


# ---------------------------------------------------------------------------
# Unknown session — 404
# ---------------------------------------------------------------------------

def test_respond_unknown_session_404(loopback_client, monkeypatch):
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/approvals/respond",
        json={"session_id": "ghost", "choice": "approve"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 404


def test_respond_session_without_key_404(loopback_client, monkeypatch):
    gateway._sessions["no-key"] = {}
    try:
        r = loopback_client.post(
            "/api/plugins/hermes-mobile/approvals/respond",
            json={"session_id": "no-key", "choice": "approve"},
            headers=_TOKEN_HEADER,
        )
        assert r.status_code == 404
    finally:
        gateway._sessions.pop("no-key", None)


# ===========================================================================
# F2-S S3/S4 — push router endpoints mounted on the app:
#   POST/DELETE /api/push/live-activity  and  events on /api/push/register
# ===========================================================================

_LA_TOKEN = "a" * 64


@pytest.fixture
def isolated_home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    return tmp_path


def test_register_live_activity_endpoint(loopback_client, isolated_home):
    pn = load_plugin_module("push_engine")
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "s-1", "env": "sandbox"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    assert r.json()["ok"] is True
    assert pn.live_activity_token_for("s-1") == (_LA_TOKEN, "sandbox")


def test_register_live_activity_rejects_bad_token(loopback_client, isolated_home):
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/push/live-activity",
        json={"token": "bad-zz", "session_id": "s-1"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400


def test_unregister_live_activity_endpoint(loopback_client, isolated_home):
    pn = load_plugin_module("push_engine")
    pn.register_live_activity_token("s-1", _LA_TOKEN)
    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "s-1"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    assert r.json()["removed"] is True
    assert pn.live_activity_token_for("s-1") is None


def test_live_activity_endpoint_requires_token(loopback_client, isolated_home):
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/push/live-activity",
        json={"token": _LA_TOKEN, "session_id": "s-1"},
    )
    assert r.status_code == 401


def test_register_endpoint_persists_events(loopback_client, isolated_home):
    import json
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/push/register",
        json={"token": _LA_TOKEN, "env": "sandbox",
              "events": ["approval", "turn_complete"]},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    entries = json.loads((isolated_home / "push_tokens.json").read_text())
    assert entries[0]["events"] == ["approval", "turn_complete"]


def test_register_endpoint_events_optional(loopback_client, isolated_home):
    import json
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/push/register",
        json={"token": _LA_TOKEN, "env": "sandbox"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200
    entries = json.loads((isolated_home / "push_tokens.json").read_text())
    assert "events" not in entries[0]
