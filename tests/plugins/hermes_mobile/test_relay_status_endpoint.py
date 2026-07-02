"""ABH-285 — relay status recovery route.

The recovery route is intentionally truthful: it must not report ``ok`` when
relay delivery failures have been observed, and it must surface the current
unimplemented tunnel-status sentinel as ``unknown`` rather than pretending the
relay is healthy.
"""

from __future__ import annotations

import json
import os

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tests.plugins.hermes_mobile.conftest import load_plugin_module

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"
_TOKEN_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}

relay = load_plugin_module("relay_client")
device_tokens = load_plugin_module("device_tokens")


@pytest.fixture(autouse=True)
def relay_env(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    monkeypatch.delenv("HERMES_MOBILE_RELAY_REGISTRATION_TOKEN", raising=False)
    monkeypatch.setattr(relay, "_delivery_failure_count", 0)
    relay._client_singletons.clear()
    yield tmp_path
    relay._client_singletons.clear()
    os.environ.pop("HERMES_MOBILE_RELAY_URL", None)
    os.environ.pop("HERMES_MOBILE_RELAY_REGISTRATION_TOKEN", None)


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


class _FakeRelayClient:
    def __init__(self, status: dict):
        self.status = status
        self.calls = 0

    async def tunnel_status(self) -> dict:
        self.calls += 1
        return self.status


def test_relay_status_requires_auth(client):
    response = client.get(f"{_PREFIX}/relay/status")

    assert response.status_code == 401


def test_relay_status_requires_approve_scope(client, relay_env, wired_token_auth):
    relay.set_relay_config(relay_url="https://relay.example.test", hermes_home=relay_env)
    issued = device_tokens.issue(device_name="Chat Only")
    registry_path = relay_env / "device_tokens.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    registry[issued["device_id"]]["scopes"] = ["chat"]
    registry_path.write_text(json.dumps(registry), encoding="utf-8")

    response = client.get(
        f"{_PREFIX}/relay/status",
        headers={"X-Hermes-Session-Token": issued["token"]},
    )

    assert response.status_code == 403


def test_relay_status_400_when_relay_not_configured(client):
    response = client.get(f"{_PREFIX}/relay/status", headers=_TOKEN_HEADER)

    assert response.status_code == 400
    assert response.json() == {
        "configured": False,
        "health": "unconfigured",
        "delivery_failure_count": 0,
        "detail": "relay URL is not configured",
    }


def test_relay_status_reports_unknown_for_unimplemented_tunnel_status(
    client, relay_env, monkeypatch
):
    relay.set_relay_config(relay_url="https://relay.example.test", hermes_home=relay_env)
    fake = _FakeRelayClient({"ok": False, "reason": "tunnel_status_unimplemented"})
    monkeypatch.setattr(relay, "relay_client", lambda: fake)

    response = client.get(f"{_PREFIX}/relay/status", headers=_TOKEN_HEADER)

    assert response.status_code == 200
    assert response.json() == {
        "configured": True,
        "health": "unknown",
        "delivery_failure_count": 0,
        "tunnel_status": {"ok": False, "reason": "tunnel_status_unimplemented"},
    }
    assert fake.calls == 1


def test_relay_status_reports_failing_when_delivery_failures_exist(
    client, relay_env, monkeypatch
):
    relay.set_relay_config(relay_url="https://relay.example.test", hermes_home=relay_env)
    relay._record_delivery_failure()
    fake = _FakeRelayClient({"ok": True, "agent_online": True})
    monkeypatch.setattr(relay, "relay_client", lambda: fake)

    response = client.get(f"{_PREFIX}/relay/status", headers=_TOKEN_HEADER)

    assert response.status_code == 200
    body = response.json()
    assert body["configured"] is True
    assert body["delivery_failure_count"] == 1
    assert body["health"] == "failing"
    assert body["health"] != "ok"
    assert body["tunnel_status"] == {"ok": True, "agent_online": True}
