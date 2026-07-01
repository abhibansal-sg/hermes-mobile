"""Unit tests for the hermes-mobile opt-in push relay client.

Slice B adapts Fetch's relay client but keeps Hermes direct APNs mode as the
default. These tests pin the adaptation deltas: no hosted default, Hermes env
prefix/path/app body, owner-only credential writes, 401 re-mint, attestation
surfacing, dedupe, and our push-kind taxonomy mapping.
"""

from __future__ import annotations

import asyncio
import json
import stat
from pathlib import Path

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

relay = load_plugin_module("relay_client")


class _FakeResponse:
    def __init__(self, status_code: int = 200, data: dict | None = None, text: str = ""):
        self.status_code = status_code
        self._data = data or {}
        self.text = text

    def json(self):
        return self._data

    def raise_for_status(self) -> None:
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}: {self.text}")


class _FakeAsyncClient:
    responses: list[_FakeResponse] = []
    calls: list[dict] = []

    def __init__(self, **kwargs):
        self.kwargs = kwargs

    async def __aenter__(self):
        return self

    async def __aexit__(self, *args):
        return False

    async def get(self, url, **kwargs):
        self.calls.append({"method": "GET", "url": url, **kwargs})
        return self.responses.pop(0)

    async def post(self, url, headers=None, json=None, **kwargs):
        self.calls.append({"method": "POST", "url": url, "headers": headers or {}, "json": json, **kwargs})
        return self.responses.pop(0)


def _install_fake_httpx(monkeypatch, responses: list[_FakeResponse]) -> type[_FakeAsyncClient]:
    _FakeAsyncClient.responses = responses
    _FakeAsyncClient.calls = []
    monkeypatch.setattr(relay.httpx, "AsyncClient", _FakeAsyncClient)
    return _FakeAsyncClient


def test_relay_url_is_opt_in_and_uses_hermes_env_path(monkeypatch, tmp_path):
    relay._client_singletons.clear()
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    assert relay.DEFAULT_RELAY_URL is None
    assert relay.relay_url_configured(hermes_home=tmp_path) is False

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setenv("HERMES_MOBILE_RELAY_REGISTRATION_TOKEN", "reg-token")

    client = relay.relay_client(hermes_home=tmp_path)

    assert client.relay_url == "https://relay.example.test"
    assert client.credentials_path == tmp_path / "push" / "relay.json"
    assert client.registration_token == "reg-token"


def test_push_kind_mapping_covers_all_hermes_event_kinds():
    assert relay.RELAY_PUSH_KINDS == ("replies", "attention", "proactive")
    assert relay.map_push_kind("approval") == "attention"
    assert relay.map_push_kind("clarify") == "attention"
    assert relay.map_push_kind("turn_complete") == "replies"
    for hermes_kind in ("approval", "clarify", "turn_complete"):
        assert relay.map_push_kind(hermes_kind) in relay.RELAY_PUSH_KINDS


def test_write_credentials_is_atomic_owner_only(tmp_path):
    path = tmp_path / "push" / "relay.json"
    client = relay.RelayClient(relay_url="https://relay", credentials_path=path)

    client._write_credentials(
        relay.RelayCredentials(
            relay_url="https://relay",
            agent_id="agent-1",
            agent_secret="secret-1",
            pairing="pair-1",
        )
    )

    mode = stat.S_IMODE(path.stat().st_mode)
    assert mode == 0o600
    assert json.loads(path.read_text()) == {
        "agent_id": "agent-1",
        "agent_secret": "secret-1",
        "pairing": "pair-1",
        "relay_url": "https://relay",
    }
    assert not path.with_suffix(".tmp").exists()


def test_write_credentials_remains_owner_only_when_final_chmod_fails(monkeypatch, tmp_path):
    path = tmp_path / "push" / "relay.json"
    client = relay.RelayClient(relay_url="https://relay", credentials_path=path)

    def chmod_fails(*args, **kwargs):
        raise OSError("simulated chmod failure")

    monkeypatch.setattr(relay.os, "chmod", chmod_fails)
    old_umask = relay.os.umask(0o022)
    try:
        client._write_credentials(
            relay.RelayCredentials(
                relay_url="https://relay",
                agent_id="agent-1",
                agent_secret="secret-1",
                pairing="pair-1",
            )
        )
    finally:
        relay.os.umask(old_umask)

    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert json.loads(path.read_text())["agent_secret"] == "secret-1"


def test_credentials_registration_posts_hermes_app_and_token(monkeypatch, tmp_path):
    fake = _install_fake_httpx(
        monkeypatch,
        [_FakeResponse(200, {"agent_id": "new-agent", "agent_secret": "new-secret", "pairing_secret": "pair"})],
    )
    client = relay.RelayClient(
        relay_url="https://relay",
        credentials_path=tmp_path / "push" / "relay.json",
        registration_token="reg-token",
    )

    creds = asyncio.run(client._credentials())

    assert creds.agent_id == "new-agent"
    assert creds.agent_secret == "new-secret"
    assert creds.pairing == "pair"
    assert fake.calls[0]["url"] == "https://relay/v1/agents/register"
    assert fake.calls[0]["headers"] == {"X-Hermes-Relay-Registration-Token": "reg-token"}
    assert fake.calls[0]["json"] == {"app": "hermes-ios"}


def test_authenticated_post_401_clears_and_remints_once(monkeypatch, tmp_path):
    fake = _install_fake_httpx(
        monkeypatch,
        [
            _FakeResponse(401, text="revoked"),
            _FakeResponse(200, {"agent_id": "new-agent", "agent_secret": "new-secret"}),
            _FakeResponse(200, {}),
        ],
    )
    path = tmp_path / "push" / "relay.json"
    client = relay.RelayClient(relay_url="https://relay", credentials_path=path)
    client._write_credentials(
        relay.RelayCredentials("https://relay", "old-agent", "old-secret")
    )

    asyncio.run(client.send_event(kind="attention", session_id="s", title="t", body="b"))

    event_posts = [call for call in fake.calls if call["url"].endswith("/v1/push/events")]
    assert [call["headers"]["X-Hermes-Agent-Id"] for call in event_posts] == ["old-agent", "new-agent"]
    assert json.loads(path.read_text())["agent_id"] == "new-agent"


def test_credentials_raise_needs_attestation(monkeypatch, tmp_path):
    _install_fake_httpx(
        monkeypatch,
        [_FakeResponse(400, {"detail": "attestation required"}, text="attestation required")],
    )
    client = relay.RelayClient(relay_url="https://relay", credentials_path=tmp_path / "push" / "relay.json")

    with pytest.raises(relay.NeedsAttestation):
        asyncio.run(client._credentials())


def test_dedupe_window(monkeypatch):
    relay._recent.clear()
    monkeypatch.setattr(relay.time, "time", lambda: 100.0)

    assert relay._is_duplicate("same") is False
    assert relay._is_duplicate("same") is True

    monkeypatch.setattr(relay.time, "time", lambda: 111.0)
    assert relay._is_duplicate("same") is False
