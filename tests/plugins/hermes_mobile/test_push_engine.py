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
    needsApproval). A rename on the server would silently fail to decode."""
    cs = {"phase": "thinking", "toolName": None, "elapsedSeconds": 0,
          "needsApproval": False}
    p = pn.build_live_activity_payload(cs)
    assert set(p["aps"]["content-state"].keys()) == {
        "phase", "toolName", "elapsedSeconds", "needsApproval"
    }


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
    assert pn.notify_live_activity("sess-1", cs) is True
    assert len(fake.calls) == 1
    call = fake.calls[0]
    assert call["path"] == f"/3/device/{_VALID_TOKEN}"
    assert call["headers"]["apns-push-type"] == "liveactivity"
    sent = json.loads(call["content"])
    assert sent["aps"]["event"] == "update"
    assert sent["aps"]["content-state"] == cs


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
def test_notify_live_activity_does_not_prune_on_bad_device_token(
    monkeypatch, isolated_home
):
    _arm_push(monkeypatch, isolated_home)
    pn.register_live_activity_token("sess-1", _VALID_TOKEN)
    fake = _FakeConn(status_code=400, text='{"reason":"BadDeviceToken"}')
    import httpx
    monkeypatch.setattr(httpx, "Client", lambda **kw: fake)
    assert pn.notify_live_activity("sess-1", {"phase": "x"}) is False
    assert pn.live_activity_token_for("sess-1") == (_VALID_TOKEN, "production")


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

def test_notify_relay_on_routes_to_relay_client(monkeypatch):
    relay = load_plugin_module("relay_client")
    calls = []

    def fake_send_event_background(**kwargs):
        calls.append(kwargs)

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(relay, "send_event_background", fake_send_event_background)

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
    }]


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
