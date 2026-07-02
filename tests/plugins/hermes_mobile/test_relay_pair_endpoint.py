"""ABH-283 — relay pairing endpoint.

Tests the additive ``POST /relay/pair`` plugin route used by the iOS Relay
settings panel. The route mints a relay pairing tuple through relay_client,
requires dashboard auth + approve scope, refuses to run before a relay URL is
configured, and never exposes the raw agent secret.
"""

from __future__ import annotations

import os
import sys

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tests.plugins.hermes_mobile.conftest import load_plugin_module

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"
_TOKEN_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}
_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"

relay = load_plugin_module("relay_client")


class _FakeRelayClient:
    async def relay_pairing(self):
        return "https://relay.example.test/root", "agent_123", "pair_secret_456"


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


def _api():
    return sys.modules[_API_MODULE_NAME]


def test_post_relay_pair_returns_pairing_tuple_without_agent_secret(
    client, relay_env, monkeypatch
):
    relay.set_relay_config(
        relay_url="https://relay.example.test/root",
        registration_token="registration-token-secret",
        hermes_home=relay_env,
    )
    monkeypatch.setattr(relay, "relay_client", lambda hermes_home=None: _FakeRelayClient())

    response = client.post(f"{_PREFIX}/relay/pair", headers=_TOKEN_HEADER)

    assert response.status_code == 200, response.text
    assert response.json() == {
        "kind": "relay",
        "relay": "https://relay.example.test/root",
        "agent": "agent_123",
        "pairing": "pair_secret_456",
    }
    assert "agent_secret" not in response.text
    assert "registration-token-secret" not in response.text


def test_post_relay_pair_requires_auth(client):
    response = client.post(f"{_PREFIX}/relay/pair")

    assert response.status_code == 401


def test_post_relay_pair_requires_approve_scope(client, monkeypatch):
    monkeypatch.setattr(_api(), "_has_dashboard_api_auth", lambda _request: True)
    monkeypatch.setattr(_api(), "_device_has_scope", lambda _request, _scope: False)

    response = client.post(f"{_PREFIX}/relay/pair", headers=_TOKEN_HEADER)

    assert response.status_code == 403


def test_post_relay_pair_rejects_missing_relay_url(client, monkeypatch):
    calls = []
    monkeypatch.setattr(relay, "relay_client", lambda hermes_home=None: calls.append(True))

    response = client.post(f"{_PREFIX}/relay/pair", headers=_TOKEN_HEADER)

    assert response.status_code == 400
    assert response.json()["code"] == 4001
    assert "relay URL" in response.json()["error"]
    assert calls == []
