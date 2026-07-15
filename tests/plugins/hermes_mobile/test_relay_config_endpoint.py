"""ABH-282 — relay push mode config route.

Tests the additive ``/relay/config`` plugin route used by the iOS Relay Push
settings panel. The route exposes relay URL + token presence/prefix only, writes
through the relay client's existing env/.env storage, and remains auth-gated like
other hermes-mobile plugin control routes.
"""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tests.plugins.hermes_mobile.conftest import load_plugin_module

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"
_TOKEN_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}

relay = load_plugin_module("relay_client")


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


def test_get_relay_config_masks_token_and_exposes_push_kinds(client, relay_env):
    relay.set_relay_config(
        relay_url="https://relay.example.test/root/",
        registration_token="registration-token-secret",
        hermes_home=relay_env,
    )

    response = client.get(f"{_PREFIX}/relay/config", headers=_TOKEN_HEADER)

    assert response.status_code == 200
    body = response.json()
    assert body == {
        "relay_url": "https://relay.example.test/root",
        "registration_token_set": True,
        "registration_token_prefix": "registra",
        "push_kinds": ["replies", "attention", "proactive"],
    }
    assert "registration-token-secret" not in response.text


def test_put_relay_config_writes_and_round_trips_without_echoing_token(client, relay_env):
    response = client.put(
        f"{_PREFIX}/relay/config",
        headers=_TOKEN_HEADER,
        json={
            "relay_url": "https://relay.example.test",
            "registration_token": "new-registration-token",
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["relay_url"] == "https://relay.example.test"
    assert body["registration_token_set"] is True
    assert body["registration_token_prefix"] == "new-regi"
    assert body["push_kinds"] == ["replies", "attention", "proactive"]
    assert "new-registration-token" not in response.text

    assert relay.relay_url(hermes_home=relay_env) == "https://relay.example.test"
    assert relay.relay_registration_token(hermes_home=relay_env) == "new-registration-token"


def test_put_relay_config_rejects_non_https_url(client, relay_env):
    response = client.put(
        f"{_PREFIX}/relay/config",
        headers=_TOKEN_HEADER,
        json={"relay_url": "http://relay.example.test", "registration_token": "secret"},
    )

    assert response.status_code == 400
    assert response.json()["error"] == "relay_url must use https"
    assert relay.relay_url(hermes_home=relay_env) is None
    assert relay.relay_registration_token(hermes_home=relay_env) is None


def test_put_relay_config_can_clear_values(client, relay_env):
    relay.set_relay_config(
        relay_url="https://relay.example.test",
        registration_token="registration-token-secret",
        hermes_home=relay_env,
    )

    response = client.put(
        f"{_PREFIX}/relay/config",
        headers=_TOKEN_HEADER,
        json={"relay_url": "", "registration_token": ""},
    )

    assert response.status_code == 200
    assert response.json() == {
        "relay_url": None,
        "registration_token_set": False,
        "registration_token_prefix": None,
        "push_kinds": ["replies", "attention", "proactive"],
    }
    assert relay.relay_url(hermes_home=relay_env) is None
    assert relay.relay_registration_token(hermes_home=relay_env) is None


def test_relay_config_requires_auth(client):
    response = client.get(f"{_PREFIX}/relay/config")

    assert response.status_code == 401
