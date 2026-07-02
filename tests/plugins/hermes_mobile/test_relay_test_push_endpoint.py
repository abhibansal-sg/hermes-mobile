"""ABH-284 — relay test-push verification route.

The confirmation route must exercise the real relay delivery path synchronously
and surface truthful success/failure details instead of returning a fire-and-
forget success.
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
    def __init__(self, *, error: Exception | None = None):
        self.error = error
        self.calls: list[dict] = []

    async def send_event(self, **kwargs):
        self.calls.append(kwargs)
        if self.error is not None:
            raise self.error


def test_relay_test_push_requires_auth(client):
    response = client.post(f"{_PREFIX}/relay/test-push")

    assert response.status_code == 401


def test_relay_test_push_requires_approve_scope(client, relay_env, wired_token_auth):
    relay.set_relay_config(relay_url="https://relay.example.test", hermes_home=relay_env)
    issued = device_tokens.issue(device_name="Chat Only")
    registry_path = relay_env / "device_tokens.json"
    registry = json.loads(registry_path.read_text(encoding="utf-8"))
    registry[issued["device_id"]]["scopes"] = ["chat"]
    registry_path.write_text(json.dumps(registry), encoding="utf-8")

    response = client.post(
        f"{_PREFIX}/relay/test-push",
        headers={"X-Hermes-Session-Token": issued["token"]},
    )

    assert response.status_code == 403


def test_relay_test_push_400_when_relay_not_configured(client):
    response = client.post(f"{_PREFIX}/relay/test-push", headers=_TOKEN_HEADER)

    assert response.status_code == 400
    assert response.json() == {"ok": False, "detail": "relay URL is not configured"}


def test_relay_test_push_sends_real_event_and_returns_delivered(client, relay_env, monkeypatch):
    relay.set_relay_config(relay_url="https://relay.example.test", hermes_home=relay_env)
    fake = _FakeRelayClient()
    monkeypatch.setattr(relay, "relay_client", lambda: fake)

    response = client.post(f"{_PREFIX}/relay/test-push", headers=_TOKEN_HEADER)

    assert response.status_code == 200
    assert response.json() == {"ok": True, "detail": "Test push delivered"}
    assert fake.calls == [
        {
            "kind": "attention",
            "session_id": None,
            "title": "Hermes test push",
            "body": "Relay push delivery test from Hermes Mobile settings.",
            "source": "relay_test_push",
        }
    ]


def test_relay_test_push_surfaces_real_delivery_error(client, relay_env, monkeypatch):
    relay.set_relay_config(relay_url="https://relay.example.test", hermes_home=relay_env)
    monkeypatch.setattr(
        relay,
        "relay_client",
        lambda: _FakeRelayClient(error=TimeoutError("relay timed out")),
    )

    response = client.post(f"{_PREFIX}/relay/test-push", headers=_TOKEN_HEADER)

    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is False
    assert "TimeoutError" in body["detail"]
    assert "relay timed out" in body["detail"]
