"""Focused contracts for the relay-owned alert path and ActivityKit fallback."""

from __future__ import annotations

import json
import stat
import time

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module


push = load_plugin_module("push_engine")
_TOKEN = "a" * 64


@pytest.fixture()
def isolated_home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    return tmp_path


def test_correlated_event_identity_is_stable_and_gateway_scoped(
    monkeypatch, tmp_path
):
    monkeypatch.setattr(
        push, "_la_registry_path", lambda: tmp_path / "live_activity_tokens.json"
    )
    payload = {"request_id": "clarify-17", "question": "Which file?"}

    first = push.enrich_correlated_event("clarify.request", "runtime-1", payload)
    second = push.enrich_correlated_event(
        "clarify.request", "runtime-1", dict(payload)
    )

    assert first == second
    assert first["event_id"].startswith("evt_")
    assert first["gateway_scope"].startswith("gw_")


def test_notify_queues_exactly_one_relay_event_without_local_registry(monkeypatch):
    relay = load_plugin_module("relay_client")
    calls = []
    monkeypatch.setattr(
        relay, "send_event_background", lambda **kwargs: calls.append(kwargs)
    )

    assert push.notify(
        "approval",
        "Approval needed",
        "Review in Hermes",
        {"session_id": "sess-1", "source": "telegram"},
        category="HERMES_APPROVAL",
    ) == 1
    assert calls == [{
        "kind": "attention",
        "session_id": "sess-1",
        "title": "Approval needed",
        "body": "Review in Hermes",
        "source": "telegram",
        "event_type": "approval",
        "category": "HERMES_APPROVAL",
        "payload": {"session_id": "sess-1", "source": "telegram"},
    }]
    assert not hasattr(push, "register_token")
    assert not hasattr(push, "registered_tokens")


def test_notify_is_nonfatal_when_relay_queue_fails(monkeypatch):
    relay = load_plugin_module("relay_client")

    def fail(**_kwargs):
        raise RuntimeError("relay unavailable")

    monkeypatch.setattr(relay, "send_event_background", fail)
    assert push.notify("turn_complete", "Done", "Finished") == 0


def test_live_activity_headers_and_payload_match_activitykit_contract():
    headers = push.build_live_activity_headers(
        provider_jwt="JWT", topic="ai.hermes.app", priority=5
    )
    assert headers == {
        "authorization": "bearer JWT",
        "apns-topic": "ai.hermes.app.push-type.liveactivity",
        "apns-push-type": "liveactivity",
        "apns-priority": "5",
        "apns-expiration": "0",
    }

    state = {
        "phase": "tool",
        "toolName": "terminal",
        "elapsedSeconds": 4,
        "needsApproval": False,
        "startedAtEpochSeconds": 1_700_000_000,
    }
    payload = push.build_live_activity_payload(
        state, end=True, timestamp=1_700_000_010
    )
    assert payload == {
        "aps": {
            "timestamp": 1_700_000_010,
            "event": "end",
            "content-state": state,
            "dismissal-date": 1_700_000_010,
        }
    }


def test_live_activity_registry_upserts_and_is_owner_only(isolated_home):
    assert push.register_live_activity_token(
        "sess-1", _TOKEN, env="sandbox", device_id="phone-1"
    )
    rotated = "b" * 64
    assert push.register_live_activity_token(
        "sess-1", rotated, env="production", device_id="phone-1"
    )

    assert push.live_activity_token_for("sess-1") == (rotated, "production")
    assert push.live_activity_device_for("sess-1") == "phone-1"
    path = isolated_home / "live_activity_tokens.json"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert list(json.loads(path.read_text())) == ["sess-1"]


def test_live_activity_registry_rejects_bad_token_and_prunes_age(
    isolated_home, monkeypatch
):
    assert not push.register_live_activity_token("sess-1", "not-hex")
    monkeypatch.setattr(time, "time", lambda: 100.0)
    assert push.register_live_activity_token("sess-1", _TOKEN)
    assert push.prune_live_activity_tokens(max_age_seconds=10, now=111.0) == 1
    assert push.live_activity_token_for("sess-1") is None


class _Config:
    enabled = True
    key_file = "unused.p8"
    key_id = "KEY"
    team_id = "TEAM"
    topic = "ai.hermes.app"
    host = "api.push.apple.com"

    def is_armed(self):
        return True


class _Response:
    def __init__(self, status: int, text: str = ""):
        self.status_code = status
        self.text = text


class _Client:
    def __init__(self, status: int, text: str = ""):
        self.status = status
        self.text = text
        self.calls = []

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def post(self, path, content=None, headers=None):
        self.calls.append((path, json.loads(content), headers))
        return _Response(self.status, self.text)


def _arm_direct_live_activity(monkeypatch, client):
    monkeypatch.setattr(
        push.APNsConfig, "from_env", classmethod(lambda _cls: _Config())
    )
    monkeypatch.setattr(push, "_get_provider_jwt", lambda _config: "JWT")
    import httpx

    monkeypatch.setattr(httpx, "Client", lambda **_kwargs: client)


def test_direct_live_activity_sender_is_the_only_retained_apns_path(
    monkeypatch, isolated_home
):
    client = _Client(200)
    _arm_direct_live_activity(monkeypatch, client)
    assert push.register_live_activity_token("sess-1", _TOKEN, env="sandbox")
    state = {
        "phase": "tool",
        "toolName": "terminal",
        "elapsedSeconds": 5,
        "needsApproval": False,
    }

    assert push.notify_live_activity("sess-1", state)
    path, payload, headers = client.calls[0]
    assert path == f"/3/device/{_TOKEN}"
    assert payload["aps"]["content-state"] == state
    assert headers["apns-push-type"] == "liveactivity"


@pytest.mark.parametrize(
    ("status", "reason", "removed"),
    [
        (410, "Unregistered", True),
        (400, "BadDeviceToken", True),
        (400, "TopicDisallowed", False),
    ],
)
def test_direct_live_activity_prunes_only_dead_tokens(
    monkeypatch, isolated_home, status, reason, removed
):
    client = _Client(status, json.dumps({"reason": reason}))
    _arm_direct_live_activity(monkeypatch, client)
    assert push.register_live_activity_token("sess-1", _TOKEN, env="sandbox")

    assert not push.notify_live_activity(
        "sess-1",
        {
            "phase": "tool",
            "toolName": "terminal",
            "elapsedSeconds": 1,
            "needsApproval": False,
        },
    )
    assert (push.live_activity_token_for("sess-1") is None) is removed


def test_live_activity_stays_on_activitykit_apns_when_alert_relay_is_configured(
    monkeypatch, isolated_home
):
    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    client = _Client(200)
    _arm_direct_live_activity(monkeypatch, client)
    assert push.register_live_activity_token("sess-1", _TOKEN, env="production")
    state = {"phase": "waiting", "needsApproval": True}

    assert push.notify_live_activity("sess-1", state, end=True)
    path, payload, headers = client.calls[0]
    assert path == f"/3/device/{_TOKEN}"
    assert payload["aps"]["event"] == "end"
    assert payload["aps"]["content-state"] == state
    assert headers["apns-push-type"] == "liveactivity"
