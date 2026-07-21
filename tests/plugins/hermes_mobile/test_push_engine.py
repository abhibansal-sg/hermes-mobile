"""Unit tests for the hermes-mobile plugin push engine (pure builders +
token registry).

Formerly ``tests/test_push_notify.py`` covering ``hermes_cli.push_notify``;
the module moved verbatim to ``plugins/hermes-mobile/push_engine.py`` in the
ABH-88 de-patch (W1), and its FastAPI router moved to the plugin's
``dashboard/api.py`` (mounted under ``/api/plugins/hermes-mobile``).

The JWT signing test needs PyJWT + cryptography; it skips cleanly when either
is absent. The header / payload shaping tests and the registry tests are pure
Python and always run. No network is touched.
"""

from __future__ import annotations

import importlib
import importlib.util
import json
import logging
import os
import sys
import time
from pathlib import Path

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

pn = load_plugin_module("push_engine")


# ---------------------------------------------------------------------------
# Dependency probe — used to skip the ES256 signing test when deps are absent.
# ---------------------------------------------------------------------------

def _crypto_available() -> bool:
    try:
        import jwt  # noqa: F401
        import cryptography  # noqa: F401
    except ImportError:
        return False
    return True


requires_crypto = pytest.mark.skipif(
    not _crypto_available(),
    reason="PyJWT + cryptography not installed (push_notify deps); "
    "install with: pip install 'pyjwt[crypto]' cryptography",
)


# A throwaway P-256 (prime256v1) EC private key in PKCS#8 PEM form. APNs .p8
# keys are exactly this shape. Used only to exercise the ES256 signer; it
# signs nothing real.
_TEST_P8 = """-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQg1hYLXg6ZokAKk5EQ
KdPbFdgVQZt8EANGPgIxWZRZ6OWhRANCAATHXIVnt3FYKPpMdBzWANvKlAvltBMd
rgeF7LqiW089/a+ahSAnYJEd2q1FtY0I9JWk/4BkLpXnmRNnPMhrV+UU
-----END PRIVATE KEY-----"""


# ---------------------------------------------------------------------------
# build_provider_jwt (ES256)
# ---------------------------------------------------------------------------

@requires_crypto
def test_build_provider_jwt_es256_claims_and_header():
    import jwt

    iat = 1_700_000_000
    token = pn.build_provider_jwt(
        key_pem=_TEST_P8,
        key_id="ABC1234567",
        team_id="TEAM987654",
        issued_at=iat,
    )
    assert isinstance(token, str) and token.count(".") == 2

    header = jwt.get_unverified_header(token)
    assert header["alg"] == "ES256"
    assert header["kid"] == "ABC1234567"

    # Decode without verifying the signature (we only assert claim shaping).
    claims = jwt.decode(token, options={"verify_signature": False})
    assert claims["iss"] == "TEAM987654"
    assert claims["iat"] == iat
    # APNs derives expiry from iat — no exp claim should be emitted.
    assert "exp" not in claims


@requires_crypto
def test_build_provider_jwt_defaults_iat_to_now():
    import jwt

    before = int(time.time())
    token = pn.build_provider_jwt(
        key_pem=_TEST_P8, key_id="K", team_id="T"
    )
    after = int(time.time())
    claims = jwt.decode(token, options={"verify_signature": False})
    assert before <= claims["iat"] <= after


def test_build_provider_jwt_raises_dependency_error_when_jwt_absent(monkeypatch):
    """If PyJWT can't be imported, the builder raises PushDependencyError
    carrying the pip hint — never a bare ImportError."""
    import builtins

    real_import = builtins.__import__

    def fake_import(name, *args, **kwargs):
        if name == "jwt":
            raise ImportError("no jwt")
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", fake_import)
    with pytest.raises(pn.PushDependencyError) as exc:
        pn.build_provider_jwt(key_pem=_TEST_P8, key_id="K", team_id="T")
    assert "pip install" in str(exc.value)


# ---------------------------------------------------------------------------
# build_push_headers
# ---------------------------------------------------------------------------

def test_build_push_headers_defaults():
    headers = pn.build_push_headers(provider_jwt="JWT", topic="ai.hermes.app")
    assert headers["authorization"] == "bearer JWT"
    assert headers["apns-topic"] == "ai.hermes.app"
    assert headers["apns-push-type"] == "alert"
    assert headers["apns-priority"] == "10"
    assert headers["apns-expiration"] == "0"
    assert "apns-collapse-id" not in headers


def test_build_push_headers_collapse_id_truncated_to_64_bytes():
    long_id = "x" * 100
    headers = pn.build_push_headers(
        provider_jwt="JWT", topic="t", collapse_id=long_id
    )
    assert len(headers["apns-collapse-id"]) == 64


def test_correlated_event_identity_is_stable_and_gateway_scoped(monkeypatch, tmp_path):
    monkeypatch.setattr(pn, "_registry_path", lambda: tmp_path / "push_tokens.json")
    payload = {"request_id": "clarify-17", "question": "Which file?"}

    first = pn.enrich_correlated_event("clarify.request", "runtime-1", payload)
    second = pn.enrich_correlated_event("clarify.request", "runtime-1", dict(payload))

    assert first["event_id"] == second["event_id"]
    assert first["gateway_scope"] == second["gateway_scope"]
    assert first["event_id"].startswith("evt_")
    assert first["gateway_scope"].startswith("gw_")


def test_approval_identity_is_server_supplied_without_random_fallback(monkeypatch, tmp_path):
    monkeypatch.setattr(pn, "_registry_path", lambda: tmp_path / "push_tokens.json")
    monkeypatch.setattr(
        pn, "_active_turn_identity", lambda _sid: ("turn-stable", "tool-call-stable")
    )

    enriched = pn.enrich_correlated_event(
        "approval.request", "runtime-2", {"command": "rm -rf build"}
    )

    assert enriched["approval_id"] == "turn-stable:tool-call-stable"
    assert enriched["turn_id"] == "turn-stable"
    assert enriched["event_id"] == pn.enrich_correlated_event(
        "approval.request", "runtime-2", {"command": "rm -rf build"}
    )["event_id"]


@pytest.mark.parametrize(
    ("event", "payload", "identity_key"),
    [
        ("approval.request", {"command": "same"}, "approval_id"),
        ("clarify.request", {"question": "same"}, "request_id"),
        ("message.complete", {"text": "same"}, "turn_id"),
    ],
)
def test_correlated_events_have_stable_transport_identity(event, payload, identity_key):
    enriched = pn.enrich_correlated_event(event, "runtime-1", payload)
    assert enriched["event_id"].startswith("evt_")
    assert enriched["gateway_scope"].startswith("gw_")
    assert enriched[identity_key]
    assert pn.enrich_correlated_event(event, "runtime-1", dict(payload)) == enriched


def test_build_push_headers_custom_priority_and_expiration():
    headers = pn.build_push_headers(
        provider_jwt="JWT", topic="t", priority=5, expiration=1234
    )
    assert headers["apns-priority"] == "5"
    assert headers["apns-expiration"] == "1234"


# ---------------------------------------------------------------------------
# build_alert_payload
# ---------------------------------------------------------------------------

def test_build_alert_payload_shape():
    p = pn.build_alert_payload(
        title="Approval needed",
        body="Hermes wants to run rm -rf",
        event_type="approval.request",
    )
    assert p["aps"]["alert"] == {
        "title": "Approval needed",
        "body": "Hermes wants to run rm -rf",
    }
    assert p["aps"]["sound"] == "default"
    assert p["hermes"]["event_type"] == "approval.request"
    # Round-trips through JSON cleanly (must be serialisable for the wire).
    assert json.loads(json.dumps(p)) == p


def test_build_alert_payload_merges_custom_payload_under_hermes():
    p = pn.build_alert_payload(
        title="t",
        body="b",
        event_type="turn.complete",
        payload={"session_id": "s-123", "stored_id": "abc"},
    )
    assert p["hermes"]["event_type"] == "turn.complete"
    assert p["hermes"]["session_id"] == "s-123"
    assert p["hermes"]["stored_id"] == "abc"
    # Custom payload must NOT leak into the reserved aps envelope.
    assert set(p["aps"].keys()) <= {"alert", "sound", "badge"}


def test_build_alert_payload_badge_optional():
    without = pn.build_alert_payload(title="t", body="b", event_type="e")
    assert "badge" not in without["aps"]
    withbadge = pn.build_alert_payload(title="t", body="b", event_type="e", badge=3)
    assert withbadge["aps"]["badge"] == 3


# ---------------------------------------------------------------------------
# APNsConfig env gating
# ---------------------------------------------------------------------------

def test_config_not_armed_when_disabled(monkeypatch, tmp_path):
    key = tmp_path / "AuthKey.p8"
    key.write_text(_TEST_P8)
    monkeypatch.delenv("HERMES_PUSH_ENABLED", raising=False)
    monkeypatch.setenv("HERMES_APNS_KEY_FILE", str(key))
    monkeypatch.setenv("HERMES_APNS_KEY_ID", "K")
    monkeypatch.setenv("HERMES_APNS_TEAM_ID", "T")
    cfg = pn.APNsConfig.from_env()
    assert cfg.is_armed() is False


def test_config_not_armed_when_key_file_missing(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_PUSH_ENABLED", "1")
    monkeypatch.setenv("HERMES_APNS_KEY_FILE", str(tmp_path / "nope.p8"))
    monkeypatch.setenv("HERMES_APNS_KEY_ID", "K")
    monkeypatch.setenv("HERMES_APNS_TEAM_ID", "T")
    cfg = pn.APNsConfig.from_env()
    assert cfg.is_armed() is False


def test_config_armed_when_all_present(monkeypatch, tmp_path):
    key = tmp_path / "AuthKey.p8"
    key.write_text(_TEST_P8)
    monkeypatch.setenv("HERMES_PUSH_ENABLED", "true")
    monkeypatch.setenv("HERMES_APNS_KEY_FILE", str(key))
    monkeypatch.setenv("HERMES_APNS_KEY_ID", "ABC1234567")
    monkeypatch.setenv("HERMES_APNS_TEAM_ID", "TEAM987654")
    monkeypatch.delenv("HERMES_APNS_TOPIC", raising=False)
    cfg = pn.APNsConfig.from_env()
    assert cfg.is_armed() is True
    assert cfg.topic == pn.DEFAULT_TOPIC
    assert cfg.host == "api.push.apple.com"


def test_config_sandbox_host(monkeypatch):
    monkeypatch.setenv("HERMES_APNS_USE_SANDBOX", "1")
    cfg = pn.APNsConfig.from_env()
    assert cfg.host == "api.sandbox.push.apple.com"


def test_provider_jwt_cache_includes_team_id(monkeypatch, tmp_path):
    key = tmp_path / "AuthKey.p8"
    key.write_text(_TEST_P8)
    calls = []

    def _fake_build_provider_jwt(**kwargs):
        calls.append(kwargs)
        return f"{kwargs['key_id']}:{kwargs['team_id']}:{len(calls)}"

    monkeypatch.setattr(pn, "build_provider_jwt", _fake_build_provider_jwt)
    with pn._jwt_lock:
        pn._cached_jwt = None
        pn._cached_jwt_at = 0.0
        pn._cached_jwt_kid = None
        pn._cached_jwt_team_id = None

    cfg_a = pn.APNsConfig(
        key_file=str(key),
        key_id="ABC1234567",
        team_id="TEAM111111",
        topic=pn.DEFAULT_TOPIC,
        use_sandbox=False,
        enabled=True,
    )
    cfg_b = pn.APNsConfig(
        key_file=str(key),
        key_id="ABC1234567",
        team_id="TEAM222222",
        topic=pn.DEFAULT_TOPIC,
        use_sandbox=False,
        enabled=True,
    )

    assert pn._get_provider_jwt(cfg_a) == "ABC1234567:TEAM111111:1"
    assert pn._get_provider_jwt(cfg_a) == "ABC1234567:TEAM111111:1"
    assert pn._get_provider_jwt(cfg_b) == "ABC1234567:TEAM222222:2"
    assert [c["team_id"] for c in calls] == ["TEAM111111", "TEAM222222"]


# ---------------------------------------------------------------------------
# Token registry — isolated under HERMES_HOME → tmp_path.
# ---------------------------------------------------------------------------

@pytest.fixture()
def isolated_home(monkeypatch, tmp_path):
    """Point the token registry at a throwaway HERMES_HOME for the test."""
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    # config caches nothing for get_hermes_home, but be safe across reloads.
    return tmp_path


_VALID_TOKEN = "a" * 64
_VALID_TOKEN_2 = "b" * 64


def test_register_and_list_token(isolated_home):
    assert pn.register_token(_VALID_TOKEN, platform="ios") is True
    assert _VALID_TOKEN in pn.registered_tokens()
    registry = isolated_home / "push_tokens.json"
    assert registry.is_file()
    entries = json.loads(registry.read_text())
    assert entries[0]["token"] == _VALID_TOKEN
    assert entries[0]["platform"] == "ios"


def test_alert_registry_is_0600(isolated_home):
    """W3a: the alert push_tokens.json must be owner-only (0600) like the LA
    registry — this chmod was historically missing from _save_registry."""
    import stat as _stat
    pn.register_token(_VALID_TOKEN, platform="ios")
    registry = isolated_home / "push_tokens.json"
    mode = _stat.S_IMODE(registry.stat().st_mode)
    assert mode == 0o600


def test_alert_registry_uses_atomic_0600_writer(isolated_home, monkeypatch):
    calls = []
    real_writer = pn.atomic_json_write

    def spy(path, data, **kwargs):
        calls.append((path, kwargs))
        return real_writer(path, data, **kwargs)

    monkeypatch.setattr(pn, "atomic_json_write", spy)

    assert pn.register_token(_VALID_TOKEN, platform="ios") is True

    assert calls
    assert calls[-1][0] == isolated_home / "push_tokens.json"
    assert calls[-1][1]["mode"] == 0o600


def test_register_is_idempotent(isolated_home):
    pn.register_token(_VALID_TOKEN)
    pn.register_token(_VALID_TOKEN)
    assert pn.registered_tokens().count(_VALID_TOKEN) == 1


def test_register_rejects_malformed_token(isolated_home):
    assert pn.register_token("not-hex-zz") is False
    assert pn.register_token("short") is False
    assert pn.registered_tokens() == []


def test_register_normalizes_case_and_spaces(isolated_home):
    spaced = ("AB" * 32)
    pretty = " ".join(spaced[i:i + 8] for i in range(0, len(spaced), 8))
    assert pn.register_token(pretty) is True
    assert pn.registered_tokens() == [spaced.lower()]


def test_unregister_token(isolated_home):
    pn.register_token(_VALID_TOKEN)
    pn.register_token(_VALID_TOKEN_2)
    assert pn.unregister_token(_VALID_TOKEN) is True
    assert pn.registered_tokens() == [_VALID_TOKEN_2]
    # Removing a token that isn't there is a no-op returning False.
    assert pn.unregister_token(_VALID_TOKEN) is False


def test_drop_tokens_prunes_stale(isolated_home):
    pn.register_token(_VALID_TOKEN)
    pn.register_token(_VALID_TOKEN_2)
    pn._drop_tokens([_VALID_TOKEN])
    assert pn.registered_tokens() == [_VALID_TOKEN_2]


def test_corrupt_registry_treated_as_empty(isolated_home):
    (isolated_home / "push_tokens.json").write_text("{ not json")
    assert pn.registered_tokens() == []
    # And a subsequent register heals the file.
    assert pn.register_token(_VALID_TOKEN) is True
    assert pn.registered_tokens() == [_VALID_TOKEN]


# ---------------------------------------------------------------------------
# notify() no-op when disarmed (no network, no deps required).
# ---------------------------------------------------------------------------

def test_notify_noop_when_disabled(monkeypatch, isolated_home):
    monkeypatch.delenv("HERMES_PUSH_ENABLED", raising=False)
    pn.register_token(_VALID_TOKEN)
    # Returns 0 and never touches the network because config is not armed.
    assert pn.notify("turn.complete", "Done", "Your turn finished", {}) == 0


# ---------------------------------------------------------------------------
# Plugin dashboard API routes (skips cleanly if FastAPI is unavailable).
#
# The old engine ``router`` (mounted at /api/push/*) was removed in the
# ABH-88 de-patch; the routes are re-declared in the plugin's
# ``dashboard/api.py`` and mounted by the dashboard at
# ``/api/plugins/hermes-mobile`` (so /api/plugins/hermes-mobile/push/register
# etc.). Here we mount the router bare and hit the /push/* paths directly,
# stubbing the api module's lazy ``_has_dashboard_api_auth`` wrapper.
# ---------------------------------------------------------------------------

_API_PY = Path(__file__).resolve().parents[3] / "plugins" / "hermes-mobile" / "dashboard" / "api.py"

requires_fastapi = pytest.mark.skipif(
    importlib.util.find_spec("fastapi") is None,
    reason="fastapi not installed",
)


def _load_dashboard_api():
    """Load plugins/hermes-mobile/dashboard/api.py as a standalone module."""
    name = "hermes_mobile_dashboard_api"
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, _API_PY)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture()
def push_api_client(monkeypatch):
    """(client, api_module) over the plugin api router, auth granted."""
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    api = _load_dashboard_api()
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: True)
    app = FastAPI()
    app.include_router(api.router)
    return TestClient(app), api


@requires_fastapi
def test_push_routes_declared_on_plugin_router():
    api = _load_dashboard_api()
    paths = {r.path for r in api.router.routes}
    assert "/push/register" in paths
    # F2-S: Live Activity registration routes are mounted on the same router.
    assert "/push/live-activity" in paths


@requires_fastapi
def test_push_register_route_registers_token(push_api_client, isolated_home):
    client, _api = push_api_client
    resp = client.post("/push/register", json={"token": _VALID_TOKEN})
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    # api._plugin_module("push_engine") is the SAME module object as pn.
    assert _VALID_TOKEN in pn.registered_tokens()


@requires_fastapi
def test_push_register_route_rejects_malformed_token(push_api_client, isolated_home):
    client, _api = push_api_client
    resp = client.post("/push/register", json={"token": "not-hex-zz"})
    assert resp.status_code == 400
    assert pn.registered_tokens() == []


@requires_fastapi
def test_push_register_route_unregister(push_api_client, isolated_home):
    client, _api = push_api_client
    client.post("/push/register", json={"token": _VALID_TOKEN})
    resp = client.request(
        "DELETE", "/push/register", json={"token": _VALID_TOKEN}
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "removed": True}
    assert pn.registered_tokens() == []


@requires_fastapi
def test_push_live_activity_route_register_and_unregister(
    push_api_client, isolated_home
):
    client, _api = push_api_client
    resp = client.post(
        "/push/live-activity",
        json={"token": _VALID_TOKEN, "session_id": "sess-1", "env": "sandbox"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True}
    assert pn.live_activity_token_for("sess-1") == (_VALID_TOKEN, "sandbox")

    resp = client.request(
        "DELETE",
        "/push/live-activity",
        json={"token": _VALID_TOKEN, "session_id": "sess-1"},
    )
    assert resp.status_code == 200
    assert resp.json() == {"ok": True, "removed": True}
    assert pn.live_activity_token_for("sess-1") is None


@requires_fastapi
def test_push_live_activity_route_rejects_malformed(push_api_client, isolated_home):
    client, _api = push_api_client
    resp = client.post(
        "/push/live-activity", json={"token": "nope-zz", "session_id": "sess-1"}
    )
    assert resp.status_code == 400
    assert pn.live_activity_token_for("sess-1") is None


@requires_fastapi
def test_push_routes_401_without_dashboard_auth(monkeypatch, isolated_home):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    api = _load_dashboard_api()
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: False)
    app = FastAPI()
    app.include_router(api.router)
    client = TestClient(app)

    assert client.post(
        "/push/register", json={"token": _VALID_TOKEN}
    ).status_code == 401
    assert client.request(
        "DELETE", "/push/register", json={"token": _VALID_TOKEN}
    ).status_code == 401
    assert client.post(
        "/push/live-activity", json={"token": _VALID_TOKEN, "session_id": "s"}
    ).status_code == 401
    assert client.request(
        "DELETE",
        "/push/live-activity",
        json={"token": _VALID_TOKEN, "session_id": "s"},
    ).status_code == 401
    # Nothing leaked into the registries.
    assert pn.registered_tokens() == []
    assert pn.live_activity_token_for("s") is None


# ===========================================================================
# ABH-204 — _is_kanban_worker() env detection (worker turn-complete suppression)
# ===========================================================================

def test_is_kanban_worker_true_when_task_env_set(monkeypatch):
    monkeypatch.setenv("HERMES_KANBAN_TASK", "t_abc")
    assert pn._is_kanban_worker() is True


def test_is_kanban_worker_false_when_task_env_absent(monkeypatch):
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    assert pn._is_kanban_worker() is False


# ===========================================================================
# F2-S S2 — aps.category on build_alert_payload
# ===========================================================================

def test_build_alert_payload_sets_category_when_given():
    p = pn.build_alert_payload(
        title="t", body="b", event_type="approval", category="HERMES_APPROVAL"
    )
    assert p["aps"]["category"] == "HERMES_APPROVAL"


def test_build_alert_payload_omits_category_by_default():
    p = pn.build_alert_payload(title="t", body="b", event_type="turn_complete")
    assert "category" not in p["aps"]


# ===========================================================================
# F2-S S3 — Live Activity payload + headers
# ===========================================================================

def test_live_activity_topic_suffix():
    assert pn.live_activity_topic("ai.hermes.app") == (
        "ai.hermes.app.push-type.liveactivity"
    )


def test_build_live_activity_headers():
    h = pn.build_live_activity_headers(provider_jwt="JWT", topic="ai.hermes.app")
    assert h["authorization"] == "bearer JWT"
    assert h["apns-push-type"] == "liveactivity"
    assert h["apns-topic"] == "ai.hermes.app.push-type.liveactivity"
    assert h["apns-priority"] == "10"

    routine = pn.build_live_activity_headers(
        provider_jwt="JWT", topic="ai.hermes.app", priority=5
    )
    assert routine["apns-priority"] == "5"
    assert routine["apns-expiration"] == "0"


def test_build_live_activity_payload_update():
    cs = {"phase": "tool", "toolName": "edit_file", "elapsedSeconds": 12,
          "needsApproval": False}
    p = pn.build_live_activity_payload(cs, timestamp=1_700_000_000)
    assert p["aps"]["event"] == "update"
    assert p["aps"]["timestamp"] == 1_700_000_000
    assert p["aps"]["content-state"] == cs
    assert "dismissal-date" not in p["aps"]
    # Round-trips through JSON cleanly.
    assert json.loads(json.dumps(p)) == p


def test_build_live_activity_payload_end_carries_dismissal_date():
    cs = {"phase": "done", "toolName": None, "elapsedSeconds": 99,
          "needsApproval": False}
    p = pn.build_live_activity_payload(cs, end=True, timestamp=1_700_000_000)
    assert p["aps"]["event"] == "end"
    assert p["aps"]["dismissal-date"] == 1_700_000_000


def test_live_activity_content_state_field_names_match_swift():
    """Guard: the content-state must carry the exact Codable field names from
    HermesTurnAttributes.ContentState (phase/toolName/elapsedSeconds/
    needsApproval/startedAtEpochSeconds). A rename on the server would silently
    fail to decode."""
    cs = {"phase": "thinking", "toolName": None, "elapsedSeconds": 0,
          "needsApproval": False, "startedAtEpochSeconds": 1_700_000_000}
    p = pn.build_live_activity_payload(cs)
    assert set(p["aps"]["content-state"].keys()) == {
        "phase", "toolName", "elapsedSeconds", "needsApproval",
        "startedAtEpochSeconds",
    }
    assert p["aps"]["content-state"]["startedAtEpochSeconds"] == 1_700_000_000


# ===========================================================================
# F2-S S3 — Live Activity token registry (keyed by session_id, upsert, prune)
# ===========================================================================

def test_la_register_and_lookup(isolated_home):
    assert pn.register_live_activity_token("sess-1", _VALID_TOKEN, env="sandbox") is True
    reg = pn.live_activity_token_for("sess-1")
    assert reg == (_VALID_TOKEN, "sandbox")
    registry = isolated_home / "live_activity_tokens.json"
    assert registry.is_file()
    data = json.loads(registry.read_text())
    assert data["sess-1"]["token"] == _VALID_TOKEN


def test_la_register_is_0600(isolated_home):
    import stat as _stat
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    registry = isolated_home / "live_activity_tokens.json"
    mode = _stat.S_IMODE(registry.stat().st_mode)
    assert mode == 0o600


def test_la_registry_uses_atomic_0600_writer(isolated_home, monkeypatch):
    calls = []
    real_writer = pn.atomic_json_write

    def spy(path, data, **kwargs):
        calls.append((path, kwargs))
        return real_writer(path, data, **kwargs)

    monkeypatch.setattr(pn, "atomic_json_write", spy)

    assert pn.register_live_activity_token("sess-1", _VALID_TOKEN) is True

    assert calls
    assert calls[-1][0] == isolated_home / "live_activity_tokens.json"
    assert calls[-1][1]["mode"] == 0o600


def test_la_register_upserts_on_rotation(isolated_home):
    pn.register_live_activity_token("sess-1", _VALID_TOKEN, env="sandbox")
    # Same session_id, rotated token → replaces, not appends.
    pn.register_live_activity_token("sess-1", _VALID_TOKEN_2, env="production")
    reg = pn.live_activity_token_for("sess-1")
    assert reg == (_VALID_TOKEN_2, "production")
    data = json.loads((isolated_home / "live_activity_tokens.json").read_text())
    assert list(data.keys()) == ["sess-1"]


def test_la_register_rejects_malformed(isolated_home):
    assert pn.register_live_activity_token("sess-1", "nope-zz") is False
    assert pn.register_live_activity_token("", _VALID_TOKEN) is False
    assert pn.live_activity_token_for("sess-1") is None


def test_la_unregister(isolated_home):
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    assert pn.unregister_live_activity_token("sess-1") is True
    assert pn.live_activity_token_for("sess-1") is None
    # Removing a session that isn't there is a no-op returning False.
    assert pn.unregister_live_activity_token("sess-1") is False


def test_la_drop_token_prunes(isolated_home):
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    pn.register_live_activity_token("sess-2", _VALID_TOKEN_2)
    pn._drop_la_token("sess-1")
    assert pn.live_activity_token_for("sess-1") is None
    assert pn.live_activity_token_for("sess-2") is not None


def test_la_prune_stale_tokens_by_age(isolated_home, monkeypatch):
    monkeypatch.setattr(pn.time, "time", lambda: 200.0)
    pn.register_live_activity_token("old", _VALID_TOKEN)
    pn.register_live_activity_token("fresh", _VALID_TOKEN_2)
    path = isolated_home / "live_activity_tokens.json"
    data = json.loads(path.read_text())
    data["old"]["registered_at"] = 100.0
    data["fresh"]["registered_at"] = 190.0
    path.write_text(json.dumps(data))

    assert pn.prune_live_activity_tokens(max_age_seconds=50, now=200.0) == 1
    assert pn.live_activity_token_for("old") is None
    assert pn.live_activity_token_for("fresh") == (_VALID_TOKEN_2, "production")


def test_la_lookup_prunes_expired_token(isolated_home, monkeypatch):
    monkeypatch.setattr(pn, "_LA_REGISTRY_MAX_AGE_SECONDS", 50)
    monkeypatch.setattr(pn.time, "time", lambda: 200.0)
    pn.register_live_activity_token("old", _VALID_TOKEN)
    path = isolated_home / "live_activity_tokens.json"
    data = json.loads(path.read_text())
    data["old"]["registered_at"] = 100.0
    path.write_text(json.dumps(data))

    assert pn.live_activity_token_for("old") is None
    assert json.loads(path.read_text()) == {}


def test_la_corrupt_registry_treated_as_empty(isolated_home):
    (isolated_home / "live_activity_tokens.json").write_text("{ not json")
    assert pn.live_activity_token_for("sess-1") is None
    # And register heals the file.
    assert pn.register_live_activity_token("sess-1", _VALID_TOKEN) is True


# ===========================================================================
# F2-S S3 — notify_live_activity() sender (mocked transport, no network)
# ===========================================================================

class _FakeResp:
    def __init__(self, status_code: int, text: str = ""):
        self.status_code = status_code
        self.text = text


class _FakeConn:
    """Captures the single POST a Live Activity send makes."""

    def __init__(self, status_code: int = 200, text: str = ""):
        self._status = status_code
        self._text = text
        self.calls = []

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def post(self, path, content=None, headers=None):
        self.calls.append({"path": path, "content": content, "headers": headers})
        return _FakeResp(self._status, self._text)


def _arm_push(monkeypatch, tmp_path):
    key = tmp_path / "AuthKey.p8"
    key.write_text(_TEST_P8)
    monkeypatch.setenv("HERMES_PUSH_ENABLED", "1")
    monkeypatch.setenv("HERMES_APNS_KEY_FILE", str(key))
    monkeypatch.setenv("HERMES_APNS_KEY_ID", "ABC1234567")
    monkeypatch.setenv("HERMES_APNS_TEAM_ID", "TEAM987654")


def test_notify_live_activity_noop_when_disarmed(monkeypatch, isolated_home):
    monkeypatch.delenv("HERMES_PUSH_ENABLED", raising=False)
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    assert pn.notify_live_activity("sess-1", {"phase": "x"}) is False


def test_notify_live_activity_noop_when_no_token(monkeypatch, isolated_home, tmp_path):
    _arm_push(monkeypatch, isolated_home)
    # No token registered for this session → silent no-op.
    assert pn.notify_live_activity("sess-unknown", {"phase": "x"}) is False


@requires_crypto
def test_notify_live_activity_sends_update(monkeypatch, isolated_home):
    _arm_push(monkeypatch, isolated_home)
    pn.register_live_activity_token("sess-1", _VALID_TOKEN, env="sandbox")
    fake = _FakeConn(status_code=200)

    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)

    cs = {"phase": "tool", "toolName": "edit_file", "elapsedSeconds": 5,
          "needsApproval": False}
    assert pn.notify_live_activity("sess-1", cs, priority=5) is True
    assert len(fake.calls) == 1
    call = fake.calls[0]
    assert call["path"] == f"/3/device/{_VALID_TOKEN}"
    assert call["headers"]["apns-push-type"] == "liveactivity"
    assert call["headers"]["apns-priority"] == "5"
    sent = json.loads(call["content"])
    assert sent["aps"]["event"] == "update"
    assert sent["aps"]["content-state"] == cs


@requires_crypto
@pytest.mark.parametrize(
    ("environment", "host"),
    [
        ("sandbox", pn._APNS_HOST_SANDBOX),
        ("production", pn._APNS_HOST_PROD),
    ],
)
def test_live_activity_budget_and_terminal_dates_are_valid_in_each_apns_environment(
    monkeypatch, isolated_home, environment, host
):
    _arm_push(monkeypatch, isolated_home)
    pn.register_live_activity_token("sess-budget", _VALID_TOKEN, env=environment)
    fake = _FakeConn(status_code=200)
    client_kwargs = []

    import httpx

    def _client(**kwargs):
        client_kwargs.append(kwargs)
        return fake

    monkeypatch.setattr(httpx, "Client", _client)
    state = {
        "phase": "thinking",
        "toolName": None,
        "elapsedSeconds": 8,
        "needsApproval": False,
        "startedAtEpochSeconds": 1_700_000_000,
    }

    assert pn.notify_live_activity("sess-budget", state, priority=5) is True
    assert pn.notify_live_activity(
        "sess-budget", {**state, "phase": "done"}, end=True, priority=10
    ) is True

    assert [call["headers"]["apns-priority"] for call in fake.calls] == ["5", "10"]
    assert all(call["headers"]["apns-expiration"] == "0" for call in fake.calls)
    assert all(kwargs["base_url"] == f"https://{host}:{pn._APNS_PORT}"
               for kwargs in client_kwargs)
    update_aps = json.loads(fake.calls[0]["content"])["aps"]
    end_aps = json.loads(fake.calls[1]["content"])["aps"]
    assert "dismissal-date" not in update_aps
    assert end_aps["dismissal-date"] == end_aps["timestamp"]


@requires_crypto
def test_notify_live_activity_end_event(monkeypatch, isolated_home):
    _arm_push(monkeypatch, isolated_home)
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    fake = _FakeConn(status_code=200)
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)
    cs = {"phase": "done", "toolName": None, "elapsedSeconds": 9,
          "needsApproval": False}
    assert pn.notify_live_activity("sess-1", cs, end=True) is True
    sent = json.loads(fake.calls[0]["content"])
    assert sent["aps"]["event"] == "end"
    assert "dismissal-date" in sent["aps"]


@requires_crypto
def test_notify_live_activity_prunes_on_410(monkeypatch, isolated_home):
    _arm_push(monkeypatch, isolated_home)
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    fake = _FakeConn(status_code=410, text="")
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)
    assert pn.notify_live_activity("sess-1", {"phase": "x"}) is False
    # Dead token was pruned.
    assert pn.live_activity_token_for("sess-1") is None


@requires_crypto
def test_notify_live_activity_prunes_on_bad_device_token(
    monkeypatch, isolated_home
):
    """QA-2 R1 contract change (supersedes the QA-1 410-only rule): a Live
    Activity token APNs rejects with 400 BadDeviceToken is dead forever and is
    pruned — re-sending it on every progress tick was the same re-hammer loop
    as the alert path (relay.log: same dead tokens on every notify window)."""
    _arm_push(monkeypatch, isolated_home)
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    fake = _FakeConn(status_code=400, text='{"reason":"BadDeviceToken"}')
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)
    assert pn.notify_live_activity("sess-1", {"phase": "x"}) is False
    assert pn.live_activity_token_for("sess-1") is None


# ===========================================================================
# F2-S S4 — per-event preferences (registry storage + recipient filtering)
# ===========================================================================

def test_register_token_stores_events(isolated_home):
    pn.register_token(_VALID_TOKEN, events=["approval", "clarify"])
    entries = json.loads((isolated_home / "push_tokens.json").read_text())
    assert entries[0]["events"] == ["approval", "clarify"]


def test_register_token_normalizes_events(isolated_home):
    # Unknown kinds dropped, dupes removed, order preserved.
    pn.register_token(_VALID_TOKEN, events=["bogus", "turn_complete", "turn_complete"])
    entries = json.loads((isolated_home / "push_tokens.json").read_text())
    assert entries[0]["events"] == ["turn_complete"]


def test_register_token_none_events_means_all(isolated_home):
    pn.register_token(_VALID_TOKEN)  # events=None
    entries = json.loads((isolated_home / "push_tokens.json").read_text())
    # No "events" key persisted → legacy "all events" behaviour.
    assert "events" not in entries[0]


def test_register_token_reregister_replaces_events(isolated_home):
    pn.register_token(_VALID_TOKEN, events=["approval"])
    pn.register_token(_VALID_TOKEN, events=["turn_complete"])
    entries = json.loads((isolated_home / "push_tokens.json").read_text())
    assert entries[0]["events"] == ["turn_complete"]
    # Re-registering with None clears the prefs (back to all).
    pn.register_token(_VALID_TOKEN, events=None)
    entries = json.loads((isolated_home / "push_tokens.json").read_text())
    assert "events" not in entries[0]


def test_recipients_for_event_filters_by_pref(isolated_home):
    pn.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])
    pn.register_token(_VALID_TOKEN_2, env="sandbox", events=["turn_complete"])
    approval_recips = pn.recipients_for_event("approval")
    flat = [t for toks in approval_recips.values() for t in toks]
    assert _VALID_TOKEN in flat
    assert _VALID_TOKEN_2 not in flat


def test_recipients_for_event_legacy_entries_get_all(isolated_home):
    # Legacy entry (no events key) receives every event kind.
    pn.register_token(_VALID_TOKEN, env="sandbox")  # no prefs
    for kind in ("approval", "clarify", "turn_complete"):
        flat = [t for toks in pn.recipients_for_event(kind).values() for t in toks]
        assert _VALID_TOKEN in flat


def test_recipients_for_event_empty_list_opts_out(isolated_home):
    pn.register_token(_VALID_TOKEN, env="sandbox", events=[])
    for kind in ("approval", "clarify", "turn_complete"):
        flat = [t for toks in pn.recipients_for_event(kind).values() for t in toks]
        assert _VALID_TOKEN not in flat


@requires_crypto
def test_notify_respects_event_prefs(monkeypatch, isolated_home):
    """notify() only sends to tokens opted into the event kind."""
    _arm_push(monkeypatch, isolated_home)
    pn.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])
    pn.register_token(_VALID_TOKEN_2, env="sandbox", events=["turn_complete"])

    sent_tokens = []

    class _MultiConn(_FakeConn):
        def post(self, path, content=None, headers=None):
            sent_tokens.append(path.rsplit("/", 1)[-1])
            return _FakeResp(200)

    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: _MultiConn())

    pn.notify("approval", "t", "b", {"session_id": "s"}, category="HERMES_APPROVAL")
    assert _VALID_TOKEN in sent_tokens
    assert _VALID_TOKEN_2 not in sent_tokens


@requires_crypto
def test_notify_passes_category_to_payload(monkeypatch, isolated_home):
    _arm_push(monkeypatch, isolated_home)
    pn.register_token(_VALID_TOKEN, env="sandbox")
    captured = {}

    class _CapConn(_FakeConn):
        def post(self, path, content=None, headers=None):
            captured["body"] = json.loads(content)
            return _FakeResp(200)

    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: _CapConn())
    pn.notify("approval", "t", "b", {"session_id": "s"}, category="HERMES_APPROVAL")
    assert captured["body"]["aps"]["category"] == "HERMES_APPROVAL"


# ===========================================================================
# ABH-208 Slice B — relay push transport selection (relay-on vs direct-off)
# ===========================================================================

def _reset_relay_async_observability(relay) -> None:
    with relay._delivery_failure_lock:
        setattr(relay, "_delivery_failure_count", 0)
    with relay._recent_lock:
        relay._recent.clear()


def _wait_for_relay_failure_log(
    relay, caplog, needle: str, *, expected: int = 1
) -> list[logging.LogRecord]:
    deadline = time.time() + 2.0
    while time.time() < deadline:
        matching = [record for record in caplog.records if needle in record.getMessage()]
        if relay.relay_delivery_failure_count() >= expected and matching:
            return matching
        time.sleep(0.01)
    raise AssertionError(
        "timed out waiting for relay background failure log "
        f"{needle!r}; failures={relay.relay_delivery_failure_count()}"
    )


def test_notify_relay_on_routes_to_relay_client(monkeypatch, isolated_home):
    relay = load_plugin_module("relay_client")
    calls = []

    def fake_send_event_background(**kwargs):
        calls.append(kwargs)

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(relay, "send_event_background", fake_send_event_background)
    # Relay notify now gates known event types on the per-event registry,
    # mirroring direct APNs; register a recipient that opts into "approval".
    pn.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])

    assert pn.notify(
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


@pytest.mark.parametrize(
    ("exc", "level", "needle"),
    [
        (
            "config",
            logging.ERROR,
            "relay push is misconfigured: HERMES_MOBILE_RELAY_URL",
        ),
        (
            "attestation",
            logging.WARNING,
            "relay requires device re-enrollment via App Attest",
        ),
    ],
)
def test_notify_relay_logs_static_failures_distinctly(monkeypatch, caplog, isolated_home, exc, level, needle):
    relay = load_plugin_module("relay_client")
    error = (
        relay.RelayConfigurationError("bad relay URL")
        if exc == "config"
        else relay.NeedsAttestation("attestation required")
    )

    class FailingClient:
        async def send_event(self, **kwargs):
            raise error

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(relay, "relay_client", lambda hermes_home=None: FailingClient())
    _reset_relay_async_observability(relay)
    # Relay notify gates known event types on the per-event registry; register
    # a recipient that opts into "approval" so delivery is actually attempted.
    pn.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])

    with caplog.at_level(logging.WARNING, logger="hermes_mobile.relay"):
        assert pn.notify(
            "approval",
            "t",
            f"body-{exc}",
            {"session_id": f"sess-{exc}"},
        ) == 1
        matching = _wait_for_relay_failure_log(relay, caplog, needle)

    assert relay.relay_delivery_failure_count() == 1
    assert matching[-1].levelno == level


@pytest.mark.parametrize(
    ("exc", "level", "needle"),
    [
        (
            "config",
            logging.ERROR,
            "relay push is misconfigured: HERMES_MOBILE_RELAY_URL",
        ),
        (
            "attestation",
            logging.WARNING,
            "relay requires device re-enrollment via App Attest",
        ),
    ],
)
def test_notify_live_activity_relay_logs_static_failures_distinctly(
    monkeypatch, caplog, exc, level, needle
):
    relay = load_plugin_module("relay_client")
    error = (
        relay.RelayConfigurationError("bad relay URL")
        if exc == "config"
        else relay.NeedsAttestation("attestation required")
    )

    class FailingClient:
        async def send_event(self, **kwargs):
            raise error

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(relay, "relay_client", lambda hermes_home=None: FailingClient())
    _reset_relay_async_observability(relay)

    with caplog.at_level(logging.WARNING, logger="hermes_mobile.relay"):
        assert pn.notify_live_activity(f"sess-live-{exc}", {"phase": "waiting"}) is True
        matching = _wait_for_relay_failure_log(relay, caplog, needle)

    assert relay.relay_delivery_failure_count() == 1
    assert matching[-1].levelno == level


def test_notify_relay_off_uses_existing_direct_apns_path(monkeypatch, isolated_home):
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    pn.register_token(_VALID_TOKEN, env="sandbox")
    monkeypatch.setattr(pn, "_get_provider_jwt", lambda config: "JWT")

    fake = _FakeConn(status_code=200)
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)

    assert pn.notify("turn_complete", "Done", "Finished", {"session_id": "sess-1"}) == 1
    assert fake.calls[0]["path"] == f"/3/device/{_VALID_TOKEN}"
    assert fake.calls[0]["headers"]["apns-push-type"] == "alert"


def test_notify_live_activity_relay_on_routes_to_relay_client(monkeypatch):
    relay = load_plugin_module("relay_client")
    calls = []

    def fake_send_live_activity_background(**kwargs):
        calls.append(kwargs)

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(
        relay, "send_live_activity_background", fake_send_live_activity_background
    )
    content_state = {
        "phase": "waiting", "toolName": None, "elapsedSeconds": 4,
        "needsApproval": True,
    }

    assert pn.notify_live_activity("sess-1", content_state, end=True) is True
    assert calls == [{
        "session_id": "sess-1",
        "content_state": content_state,
        "end": True,
    }]


def test_notify_live_activity_relay_off_uses_existing_direct_apns_path(
    monkeypatch, isolated_home
):
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    pn.register_live_activity_token("sess-1", _VALID_TOKEN, env="sandbox")
    monkeypatch.setattr(pn, "_get_provider_jwt", lambda config: "JWT")

    fake = _FakeConn(status_code=200)
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)
    content_state = {
        "phase": "tool", "toolName": "terminal", "elapsedSeconds": 5,
        "needsApproval": False,
    }

    assert pn.notify_live_activity("sess-1", content_state) is True
    assert fake.calls[0]["path"] == f"/3/device/{_VALID_TOKEN}"
    assert fake.calls[0]["headers"]["apns-push-type"] == "liveactivity"


# ===========================================================================
# STR-987 — turn-complete attention gate + 4h apns-expiration
#
# The message.complete branch of _process_push_event now pushes based on
# whether a live client WS still holds the session foregrounded, NOT on turn
# duration. A locked/off/backgrounded phone drops its WS (no ``transport``),
# so a quick turn that finishes after the phone is off still banners.
# ===========================================================================


class _LiveTransport:
    """Stub gateway transport whose ``_closed`` mirrors a live/dead WS."""

    def __init__(self, closed: bool = False):
        self._closed = closed


def _drive_message_complete(monkeypatch, session, *, turn_started=995.0):
    """Run the message.complete branch with a captured ``notify`` and the
    given session dict installed as the live gateway session for ``sid``.

    Returns the list of ``notify`` call arg-tuples (``(args, kwargs)``).
    """
    calls = []

    def _capture_notify(*args, **kwargs):
        calls.append((args, kwargs))
        return 1

    sid = "sess-attn"
    monkeypatch.setattr(pn, "notify", _capture_notify)
    monkeypatch.setattr(pn, "_gw_sessions", lambda: {sid: session})
    # Silence the Live Activity hook (armed check is a no-op, but keep it inert).
    monkeypatch.setattr(pn, "_live_activity_hook", lambda *a, **k: None)
    pn._process_push_event(
        "message.complete",
        sid,
        {"text": "All done."},
        event_time=1000.0,
        turn_started=turn_started,
    )
    return calls


def test_attention_gate_pushes_when_no_transport_even_for_quick_turn(monkeypatch):
    # (a) No WS attached (locked/off phone) => push, even for a 5s turn that
    # the old 30s duration gate would have suppressed.
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    calls = _drive_message_complete(monkeypatch, {}, turn_started=995.0)
    assert len(calls) == 1
    args, kwargs = calls[0]
    assert args[0] == "turn_complete"
    assert kwargs.get("expiration") == 14400


def test_attention_gate_pushes_when_transport_closed(monkeypatch):
    # (a') A transport that reports _closed=True is a dead WS — treat as
    # backgrounded and push.
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    session = {"transport": _LiveTransport(closed=True)}
    calls = _drive_message_complete(monkeypatch, session)
    assert len(calls) == 1
    assert calls[0][0][0] == "turn_complete"


def test_attention_gate_suppresses_when_ws_foregrounded(monkeypatch):
    # (b) A live WS (_closed=False) means the user is watching — no push.
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    session = {"transport": _LiveTransport(closed=False)}
    calls = _drive_message_complete(monkeypatch, session)
    assert calls == []


def test_attention_gate_suppresses_for_kanban_worker(monkeypatch):
    # (c) A dispatched worker never banners, even with no transport attached.
    monkeypatch.setattr(pn, "_is_kanban_worker", lambda: True)
    calls = _drive_message_complete(monkeypatch, {})
    assert calls == []


def test_attention_gate_clears_turn_start_stamp_regardless_of_push(monkeypatch):
    # Registry hygiene: a foregrounded turn still drops its own start stamp so
    # the session table doesn't leak stale timers.
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    session = {"transport": _LiveTransport(closed=False), "_push_turn_started": 995.0}
    calls = _drive_message_complete(monkeypatch, session, turn_started=995.0)
    assert calls == []  # foregrounded → suppressed
    assert "_push_turn_started" not in session  # …but stamp was still popped


def test_turn_complete_notify_sets_4h_apns_expiration(monkeypatch, isolated_home):
    # (d) The turn_complete send plumbs expiration=14400 all the way to the
    # APNs headers.
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    pn.register_token(_VALID_TOKEN, env="sandbox", events=["turn_complete"])
    monkeypatch.setattr(pn, "_get_provider_jwt", lambda config: "JWT")

    fake = _FakeConn(status_code=200)
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)

    assert pn.notify(
        "turn_complete", "Hermes finished", "All done.",
        {"session_id": "sess-1"}, category="HERMES_TURN", expiration=14400,
    ) == 1
    assert fake.calls[0]["headers"]["apns-expiration"] == "14400"


def test_notify_uses_event_identity_as_apns_collapse_id(monkeypatch, isolated_home):
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    pn.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])
    monkeypatch.setattr(pn, "_get_provider_jwt", lambda config: "JWT")
    fake = _FakeConn(status_code=200)
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)

    event_id = "evt_0123456789abcdef"
    assert pn.notify(
        "approval",
        "Approval required",
        "Review this",
        {"session_id": "sess-1", "event_id": event_id},
        category="HERMES_APPROVAL",
        collapse_id=event_id,
    ) == 1
    assert fake.calls[0]["headers"]["apns-collapse-id"] == event_id


def test_time_sensitive_notify_keeps_zero_apns_expiration(monkeypatch, isolated_home):
    # (d') Approval and other time-sensitive sends keep the default 0 window.
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    pn.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])
    monkeypatch.setattr(pn, "_get_provider_jwt", lambda config: "JWT")

    fake = _FakeConn(status_code=200)
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)

    assert pn.notify(
        "approval", "Approval required", "Review this", {"session_id": "sess-1"},
        category="HERMES_APPROVAL",
    ) == 1
    assert fake.calls[0]["headers"]["apns-expiration"] == "0"


# ---------------------------------------------------------------------------
# QA-2 R1 — per-env APNs routing, dead-token eviction (400 BadDeviceToken +
# 410 Unregistered), and one-token-per-device dedup.
#
# Root cause on main 1fcffe3d5: eviction was 410-ONLY (400 BadDeviceToken was
# logged and re-hammered forever — relay.log showed the same three dead tokens
# on every notify window), and dedup was token-string-only (iOS sent no
# device_id, so every re-sign/reinstall appended → 5 entries per phone).
# The env routing itself already existed (QA-1 B14) — those tests PIN it.
# ---------------------------------------------------------------------------

def test_apns_reason_parses_reason_json():
    """Pure parser: APNs error bodies are {"reason": "..."}; anything else → None."""
    assert pn._apns_reason('{"reason":"BadDeviceToken"}') == "BadDeviceToken"
    assert pn._apns_reason('{"reason":"Unregistered"}') == "Unregistered"
    assert pn._apns_reason("") is None
    assert pn._apns_reason("<html>nope</html>") is None
    assert pn._apns_reason('["array"]') is None
    assert pn._apns_reason('{"reason":""}') is None
    assert pn._apns_reason('{"other":"x"}') is None


def test_is_dead_token_eviction_matrix():
    """The eviction decision: 410 always; 400 ONLY for BadDeviceToken/Unregistered.

    TopicDisallowed/BadPath/MissingTopic are server CONFIG errors — the token
    is fine and must be KEPT; 429/5xx are transient.
    """
    # Dead — evict.
    assert pn._is_dead_token(410, None) is True
    assert pn._is_dead_token(410, "Unregistered") is True
    assert pn._is_dead_token(400, "BadDeviceToken") is True
    assert pn._is_dead_token(400, "Unregistered") is True
    # Alive — keep.
    assert pn._is_dead_token(400, "TopicDisallowed") is False
    assert pn._is_dead_token(400, "BadPath") is False
    assert pn._is_dead_token(400, "MissingTopic") is False
    assert pn._is_dead_token(400, None) is False  # unparseable body: keep
    assert pn._is_dead_token(403, "TopicDisallowed") is False
    assert pn._is_dead_token(405, "MethodNotAllowed") is False
    assert pn._is_dead_token(429, "TooManyRequests") is False
    assert pn._is_dead_token(500, "InternalServerError") is False


class _PerTokenFakeConn:
    """httpx.Client stand-in scripted per device-token path (QA-2 R1)."""

    def __init__(self, responses):
        self._responses = responses  # {"/3/device/<token>": (status, text)}
        self.posts = []

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False

    def post(self, path, content=None, headers=None):
        self.posts.append(path)
        status, text = self._responses.get(path, (200, ""))
        return _FakeResp(status, text)


@requires_crypto
def test_notify_evicts_400_bad_device_token_and_410_keeps_config_errors(
    monkeypatch, isolated_home
):
    """QA-2 R1 killer regression: a 400 BadDeviceToken evicts exactly like 410;
    a 400 TopicDisallowed (server misconfig, token fine) must NOT evict."""
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    monkeypatch.delenv("HERMES_APNS_USE_SANDBOX", raising=False)
    _arm_push(monkeypatch, isolated_home)

    dead_410 = "d1" * 32
    dead_bad = "d2" * 32
    misconfigured = "d3" * 32
    healthy = "d4" * 32
    for tok in (dead_410, dead_bad, misconfigured, healthy):
        assert pn.register_token(tok, env="production")

    conn = _PerTokenFakeConn({
        f"/3/device/{dead_410}": (410, '{"reason":"Unregistered"}'),
        f"/3/device/{dead_bad}": (400, '{"reason":"BadDeviceToken"}'),
        f"/3/device/{misconfigured}": (400, '{"reason":"TopicDisallowed"}'),
        f"/3/device/{healthy}": (200, ""),
    })
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: conn)

    accepted = pn.notify("turn_complete", "Hermes finished", "Your turn finished", {})
    assert accepted == 1

    remaining = pn.registered_tokens()
    assert dead_410 not in remaining       # 410 Unregistered → evicted (pre-existing)
    assert dead_bad not in remaining       # QA-2 R1: 400 BadDeviceToken → evicted
    assert misconfigured in remaining      # config error: token fine → KEPT
    assert healthy in remaining


@requires_crypto
def test_notify_bad_device_token_eviction_is_logged(monkeypatch, isolated_home, caplog):
    """A1 evidence contract: every eviction lands in the log with token tail + reason."""
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    dead = "ab" * 32
    pn.register_token(dead, env="sandbox")

    conn = _PerTokenFakeConn({f"/3/device/{dead}": (400, '{"reason":"BadDeviceToken"}')})
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: conn)

    with caplog.at_level(logging.INFO, logger=pn._log.name):
        assert pn.notify("turn_complete", "Hermes finished", "done", {}) == 0
    eviction_logs = [
        r.getMessage() for r in caplog.records
        if "evicting dead token" in r.getMessage()
    ]
    assert eviction_logs, f"no eviction logged; records: {[r.getMessage() for r in caplog.records]}"
    assert any("BadDeviceToken" in msg and dead[-6:] in msg for msg in eviction_logs)
    assert pn.registered_tokens() == []


@requires_crypto
def test_notify_routes_sandbox_and_production_tokens_to_distinct_hosts(
    monkeypatch, isolated_home
):
    """PIN (pre-existing QA-1 B14 behavior): one notify() sends each token to
    its OWN env's APNs host — sandbox and production entries in one registry."""
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    monkeypatch.delenv("HERMES_APNS_USE_SANDBOX", raising=False)
    _arm_push(monkeypatch, isolated_home)

    sandbox_token = "ab" * 32
    prod_token = "cd" * 32
    pn.register_token(sandbox_token, env="sandbox")
    pn.register_token(prod_token, env="production")

    conns = {}

    def fake_client(**kwargs):
        base = kwargs.get("base_url")
        if base not in conns:
            conns[base] = _PerTokenFakeConn({})
        return conns[base]

    import httpx
    monkeypatch.setattr(httpx, "Client", fake_client)

    assert pn.notify("turn_complete", "Hermes finished", "done", {}) == 2

    sandbox_url = f"https://{pn._APNS_HOST_SANDBOX}:{pn._APNS_PORT}"
    prod_url = f"https://{pn._APNS_HOST_PROD}:{pn._APNS_PORT}"
    assert set(conns) == {sandbox_url, prod_url}
    assert conns[sandbox_url].posts == [f"/3/device/{sandbox_token}"]
    assert conns[prod_url].posts == [f"/3/device/{prod_token}"]


# -- device-id dedup: ONE token per device (QA-2 R1c) -----------------------

def test_register_device_id_replaces_rotated_token(isolated_home):
    """Same device_id + a NEW token REPLACES the old entry (APNs token rotation
    on reinstall/re-sign) instead of appending — the registry converges to one
    row per device."""
    first = "aa" * 32
    second = "bb" * 32
    assert pn.register_token(first, env="sandbox", device_id="device-ONE") is True
    assert pn.register_token(second, env="production", device_id="device-ONE") is True

    entries = pn.registry_entries()
    assert len(entries) == 1, f"expected 1 entry per device, got {entries}"
    assert entries[0]["token"] == second
    assert entries[0]["env"] == "production"     # refreshed, not stale
    assert entries[0]["device_id"] == "device-ONE"
    assert pn.registered_tokens() == [second]


def test_register_same_token_with_device_id_collapses_legacy_duplicates(isolated_home):
    """Re-registering an EXISTING token with a device_id collapses any stale
    duplicate rows for that device (pre-dedup accumulation → the phone's 5
    entries converge on its next register)."""
    token = "cc" * 32
    stale = "dd" * 32
    registry = isolated_home / "push_tokens.json"
    registry.write_text(json.dumps([
        {"token": token, "platform": "ios", "env": "production", "device_id": "dev-X",
         "registered_at": 1.0},
        {"token": stale, "platform": "ios", "env": "production", "device_id": "dev-X",
         "registered_at": 2.0},
    ]))

    assert pn.register_token(token, env="sandbox", device_id="dev-X") is True
    entries = pn.registry_entries()
    assert len(entries) == 1
    assert entries[0]["token"] == token
    assert entries[0]["env"] == "sandbox"         # env refreshed on re-register
    assert entries[0]["device_id"] == "dev-X"


def test_register_distinct_devices_with_ids_keep_separate_entries(isolated_home):
    """Different device_ids never collapse into each other (two phones stay two
    entries)."""
    assert pn.register_token("aa" * 32, device_id="phone-1") is True
    assert pn.register_token("bb" * 32, device_id="phone-2") is True
    entries = pn.registry_entries()
    assert {e["device_id"] for e in entries} == {"phone-1", "phone-2"}
    assert len(entries) == 2


def test_register_without_device_id_keeps_legacy_token_only_dedup(isolated_home):
    """Legacy clients (no device_id) keep the token-string-only semantics:
    distinct tokens APPEND (no identity to dedup on)."""
    assert pn.register_token("aa" * 32) is True
    assert pn.register_token("bb" * 32) is True
    assert len(pn.registered_tokens()) == 2


def test_device_id_registration_evicts_null_device_id_legacy_rows(isolated_home):
    """QA-3 S13: a device_id-keyed registration converges the registry by
    evicting legacy null-device_id rows for the platform. The build-116 registry
    held 3 null-id iOS rows (2 production + 1 sandbox) that QA-2's device-keyed
    eviction could never reach (no device_id to match); Apple 200s the stale
    tokens into the void so they never aged out. Once build 117 registers with
    a real device_id, fan-out must post to exactly ONE token."""
    legacy_prod_a = "11" * 32
    legacy_prod_b = "22" * 32
    legacy_sandbox = "33" * 32
    registry = isolated_home / "push_tokens.json"
    registry.write_text(json.dumps([
        {"token": legacy_prod_a, "platform": "ios", "env": "production"},
        {"token": legacy_prod_b, "platform": "ios", "env": "production"},
        {"token": legacy_sandbox, "platform": "ios", "env": "sandbox"},
    ]))

    phone_token = "ee" * 32
    assert pn.register_token(
        phone_token, platform="ios", env="sandbox", device_id="phone-install-1"
    ) is True

    entries = pn.registry_entries()
    # Exactly one entry for the phone; the three legacy null-id rows are gone.
    assert len(entries) == 1, f"expected registry to converge to 1, got {entries}"
    assert entries[0]["token"] == phone_token
    assert entries[0]["device_id"] == "phone-install-1"
    assert pn.registered_tokens() == [phone_token]


def test_device_id_registration_eviction_is_platform_scoped(isolated_home):
    """A device_id-keyed iOS registration must NOT evict null-id rows for other
    platforms (an android null-id row stays put — it belongs to a different
    device population with its own pending upgrade)."""
    registry = isolated_home / "push_tokens.json"
    registry.write_text(json.dumps([
        {"token": "11" * 32, "platform": "ios", "env": "production"},
        {"token": "22" * 32, "platform": "android", "env": "production"},
    ]))
    assert pn.register_token(
        "ee" * 32, platform="ios", env="sandbox", device_id="ios-install-1"
    ) is True
    entries = pn.registry_entries()
    platforms = {e["platform"] for e in entries}
    assert "android" in platforms, "android null-id row must survive an iOS registration"
    ios_entries = [e for e in entries if e["platform"] == "ios"]
    assert len(ios_entries) == 1
    assert ios_entries[0]["device_id"] == "ios-install-1"


def test_device_id_refresh_in_place_also_evicts_null_legacy(isolated_home):
    """The refresh-in-place branch (exact-token match) also converges the
    registry: re-registering the SAME token WITH a device_id evicts the
    null-id rows that a prior legacy register of that token wrote."""
    token = "aa" * 32
    legacy_other = "bb" * 32
    # Legacy registers (no device_id): two null-id rows.
    assert pn.register_token(token, env="production") is True
    assert pn.register_token(legacy_other, env="production") is True
    # Build 117 re-registers the same token, now with a device_id.
    assert pn.register_token(token, env="sandbox", device_id="phone-1") is True
    entries = pn.registry_entries()
    # The other null-id legacy row is evicted too (one phone → one row).
    assert len(entries) == 1
    assert entries[0]["token"] == token
    assert entries[0]["device_id"] == "phone-1"


def test_distinct_device_ids_preserved_after_null_eviction(isolated_home):
    """Eviction only kills NULL-id rows; entries stamped with OTHER device_ids
    (other phones) stay — the registry keeps one row per device, not one row
    globally."""
    registry = isolated_home / "push_tokens.json"
    registry.write_text(json.dumps([
        {"token": "11" * 32, "platform": "ios", "env": "production"},            # null-id legacy
        {"token": "22" * 32, "platform": "ios", "env": "sandbox",
         "device_id": "other-phone"},                                            # a real other phone
    ]))
    assert pn.register_token(
        "ee" * 32, platform="ios", env="sandbox", device_id="this-phone"
    ) is True
    entries = pn.registry_entries()
    ids = {e.get("device_id") for e in entries}
    assert ids == {"other-phone", "this-phone"}, f"got {ids}"
    assert all(e.get("device_id") for e in entries), "no null-id rows may survive"


@requires_crypto
def test_live_activity_evicts_400_bad_device_token(monkeypatch, isolated_home):
    """QA-2 R1: the Live Activity send path prunes on 400 BadDeviceToken too
    (was 410-only) — a dead activity token re-sent every progress tick was the
    same re-hammer loop."""
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    token = "11" * 32
    assert pn.register_live_activity_token("sess-dead", token, env="sandbox")

    conn = _PerTokenFakeConn({f"/3/device/{token}": (400, '{"reason":"BadDeviceToken"}')})
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: conn)

    ok = pn.notify_live_activity(
        "sess-dead",
        {"phase": "tool", "toolName": "edit_file", "elapsedSeconds": 3,
         "needsApproval": False},
    )
    assert ok is False
    assert pn.live_activity_token_for("sess-dead") is None  # pruned


@requires_crypto
def test_manifest_invalidation_evicts_400_bad_device_token(monkeypatch, isolated_home):
    """QA-2 R1: the manifest-invalidation silent-push path prunes dead tokens
    with the same rule (was 410-only)."""
    monkeypatch.delenv("HERMES_MOBILE_RELAY_URL", raising=False)
    _arm_push(monkeypatch, isolated_home)
    dead = "22" * 32
    alive = "33" * 32
    pn.register_token(dead, env="sandbox")
    pn.register_token(alive, env="sandbox")

    conn = _PerTokenFakeConn({
        f"/3/device/{dead}": (400, '{"reason":"BadDeviceToken"}'),
        f"/3/device/{alive}": (200, ""),
    })
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: conn)

    accepted = pn._notify_direct_manifest_invalidation("all", 7, "test")
    assert accepted == 1
    assert pn.registered_tokens() == [alive]
