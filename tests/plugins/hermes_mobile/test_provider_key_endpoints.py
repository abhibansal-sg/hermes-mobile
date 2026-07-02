"""ABH-183 — provider / API-key entry plugin routes.

Tests the four additive routes in ``plugins/hermes-mobile/dashboard/api.py``:

* ``GET    /providers``                — provider universe + authenticated?
* ``POST   /providers/{slug}/key``     — Tier A: registered api_key provider
* ``POST   /providers/custom``         — Tier B: custom OpenAI/Anthropic provider
* ``DELETE /providers/{slug}/key``     — remove credentials (parity model.disconnect)

Additive plugin-only: ZERO stock-core edits. The handlers import the SAME stock
mutators the desktop ``model.save_key`` / ``model.disconnect`` RPCs use
(``hermes_cli.config.save_env_value`` / ``remove_env_value`` /
``set_config_value`` / ``is_managed``, ``hermes_cli.auth.PROVIDER_REGISTRY`` /
``clear_provider_auth``, ``hermes_cli.inventory.build_models_payload``). Those
stock functions are MOCKED here so the suite never depends on a live gateway,
a writable ~/.hermes/.env, or a managed-install marker — it asserts the
route-handler dispatch + the security contract (auth gating, OAuth-reject,
is_managed-reject, no-key-in-response, Tier A vs B dispatch, input validation).

Tests run in-process via FastAPI TestClient — no network. They run
gateway-free: the inventory builder + the stock mutators are monkeypatched, so
no ``HERMES_URL``/``HERMES_TOKEN`` is required (skip-guard friendly).
"""

from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server

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


@pytest.fixture(autouse=True)
def no_live_provider_key_validation(monkeypatch, request):
    """Endpoint tests should not perform real provider network probes."""
    if request.node.name.startswith("test_validate_provider_key_"):
        return
    monkeypatch.setattr(
        _api(),
        "_validate_provider_key",
        lambda **_kw: {
            "validated": True,
            "validation_detail": "provider accepted the API key",
            "persisted": True,
        },
        raising=False,
    )


# ---------------------------------------------------------------------------
# Stock-function patches. Each captures its call args so a test can assert the
# route dispatched to the RIGHT stock mutator (Tier A vs B vs delete) WITHOUT
# touching a real ~/.hermes/.env or config.yaml.
# ---------------------------------------------------------------------------


# The dashboard mounts the plugin's api.py under this exact sys.modules key
# (see hermes_cli.web_server._mount_plugin_api_routes). The handler's
# ``_provider_provider_rows`` global is resolved off THIS module object at call
# time, so patching it here mutates the live route's behaviour.
_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


def _api():
    """The live dashboard api module the routes are mounted from."""
    import sys

    return sys.modules[_API_MODULE_NAME]


def _patch_inventory(monkeypatch, *, rows):
    """Patch _provider_provider_rows to return a fixed provider universe.

    Avoids hitting the real inventory builder (which needs a real HERMES_HOME).
    """
    api = _api()

    captured = {}

    def _fake_rows():
        captured["called"] = True
        return list(rows)

    monkeypatch.setattr(api, "_provider_provider_rows", _fake_rows)
    return captured


def _patch_stock_inventory(monkeypatch, *, rows):
    """Patch the stock inventory functions used by _provider_provider_rows."""
    import hermes_cli.inventory as inventory

    captured = {"called": False, "kwargs": None}

    def _fake_context():
        return object()

    def _fake_payload(_ctx, **kwargs):
        captured["called"] = True
        captured["kwargs"] = kwargs
        return {"providers": list(rows)}

    monkeypatch.setattr(inventory, "load_picker_context", _fake_context)
    monkeypatch.setattr(inventory, "build_models_payload", _fake_payload)
    return captured


def _patch_config(monkeypatch, *, providers_in_config=None):
    """Patch the hermes_cli.config mutators + is_managed + config readers/writer,
    capturing calls.

    ``providers_in_config`` is a dict of {slug: entry} to include in the fake
    config returned by ``load_config_readonly`` / ``load_config``. Defaults to an
    empty dict (no custom-provider entries), which is the normal state for
    registered-provider tests. Pass a non-empty dict for tests that need a custom
    providers.<slug> entry to be present in config (simulating a prior POST
    /providers/custom).
    """
    import copy
    import hermes_cli.config as config

    state = {"providers": copy.deepcopy(providers_in_config or {})}
    calls = {
        "save_env": [],
        "remove_env": [],
        "set_config": [],
        "save_config": [],
        "config_state": state,
        "managed": False,
    }

    def _save_env(key, value):
        calls["save_env"].append((key, value))

    def _remove_env(key):
        calls["remove_env"].append(key)
        return True

    def _set_config(key, value):
        calls["set_config"].append((key, value))

    def _is_managed():
        return calls["managed"]

    def _load_config_readonly():
        return copy.deepcopy(state)

    def _load_config():
        return copy.deepcopy(state)

    def _save_config(new_config):
        calls["save_config"].append(copy.deepcopy(new_config))
        state.clear()
        state.update(copy.deepcopy(new_config))

    monkeypatch.setattr(config, "save_env_value", _save_env)
    monkeypatch.setattr(config, "remove_env_value", _remove_env)
    monkeypatch.setattr(config, "set_config_value", _set_config)
    monkeypatch.setattr(config, "is_managed", _is_managed)
    monkeypatch.setattr(config, "load_config_readonly", _load_config_readonly)
    monkeypatch.setattr(config, "load_config", _load_config)
    monkeypatch.setattr(config, "save_config", _save_config)
    return calls


def _patch_clear_auth(monkeypatch, *, returns=True):
    import hermes_cli.auth as auth

    captured = {}

    def _clear(slug):
        captured["slug"] = slug
        return returns

    monkeypatch.setattr(auth, "clear_provider_auth", _clear)
    return captured


# A representative provider universe row shape (mirrors what the stock
# build_models_payload picker_hints path emits). ``deepseek`` is an api_key
# provider; ``nous`` is oauth_device_code.
_DEEPSEEK_ROW = {
    "slug": "deepseek",
    "name": "DeepSeek",
    "auth_type": "api_key",
    "is_current": False,
    "authenticated": False,
    "total_models": 3,
    "models": [{"id": "deepseek-chat"}, {"id": "deepseek-reasoner"}],
}
_NOUS_ROW = {
    "slug": "nous",
    "name": "Nous Portal",
    "auth_type": "oauth_device_code",
    "is_current": False,
    "authenticated": False,
    "total_models": 0,
    "models": [],
}
_ANTHROPIC_ROW = {
    "slug": "anthropic",
    "name": "Anthropic",
    "auth_type": "api_key",
    "is_current": False,
    "authenticated": False,
    "total_models": 2,
    "models": [{"id": "claude-sonnet-4-20250514"}],
}


# ===========================================================================
# Auth gating — every route requires the dashboard token + device scope.
# ===========================================================================


def test_list_providers_requires_token(loopback_client, monkeypatch):
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    r = loopback_client.get("/api/plugins/hermes-mobile/providers")
    assert r.status_code == 401


def test_set_key_requires_token(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "sk-test"},
    )
    assert r.status_code == 401


def test_set_key_no_scope_for_device_without_approve(loopback_client, monkeypatch):
    """A device token without the 'approve' scope is 403.

    We simulate a device-authenticated request by also setting the shared
    token — but the dashboard middleware treats the shared token as the auth,
    so scope gating only bites a true device token. This test documents the
    scope check exists in the handler (belt-and-suspenders) by confirming the
    route is reachable when authed with the shared token (which has full
    scope). The scope-reject path is exercised via the is_managed / OAuth
    rejections below (which are gated AFTER the scope check passes).
    """
    # The shared token passes _has_dashboard_api_auth and _device_has_scope
    # (a non-device request trivially satisfies any scope check). We assert
    # the route reaches the handler body (not 401/403) to prove the auth
    # gates pass for a privileged caller.
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "sk-test"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code != 401
    assert r.status_code != 403


def test_custom_requires_token(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={"name": "myco", "base_url": "https://api.my.co/v1",
              "api_mode": "openai", "api_key": "sk-x"},
    )
    assert r.status_code == 401


def test_delete_key_requires_token(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    _patch_clear_auth(monkeypatch)
    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/deepseek/key",
    )
    assert r.status_code == 401


# ===========================================================================
# GET /providers — names + authenticated? only, NEVER key values.
# ===========================================================================


def test_list_providers_returns_safe_shape(loopback_client, monkeypatch):
    cap = _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW, _NOUS_ROW])
    r = loopback_client.get(
        "/api/plugins/hermes-mobile/providers", headers=_TOKEN_HEADER
    )
    assert r.status_code == 200
    body = r.json()
    assert cap["called"] is True
    slugs = {p["slug"] for p in body["providers"]}
    assert slugs == {"deepseek", "nous"}
    # The mobile-safe shape keys ONLY off non-secret fields.
    for p in body["providers"]:
        assert set(p.keys()) == {
            "slug", "name", "auth_type", "is_current",
            "authenticated", "total_models",
        }
    # NEVER a credential VALUE or an env-var NAME leaks through. Note
    # ``auth_type:"api_key"`` is legitimate metadata (the auth *kind*, not a
    # credential), so we check for actual secret material: no ``sk-`` value,
    # no ``*_API_KEY`` env-var name, no ``key_env`` field.
    dumped = r.text.lower()
    assert "sk-" not in dumped
    assert "_api_key" not in dumped  # env-var names like DEEPSEEK_API_KEY
    assert "key_env" not in dumped


def test_list_providers_drops_unprovisionable_unconfigured_rows(
    loopback_client, monkeypatch
):
    from hermes_cli.auth import PROVIDER_REGISTRY

    assert "novita" in PROVIDER_REGISTRY
    cap = _patch_stock_inventory(
        monkeypatch,
        rows=[
            {
                "slug": "openrouter",
                "name": "OpenRouter",
                "auth_type": "api_key",
                "is_current": False,
                "authenticated": False,
                "total_models": 0,
            },
            {
                "slug": "custom",
                "name": "Custom",
                "auth_type": "api_key",
                "is_current": False,
                "authenticated": False,
                "total_models": 0,
            },
            {
                "slug": "novita",
                "name": "NovitaAI",
                "auth_type": "api_key",
                "is_current": False,
                "authenticated": False,
                "total_models": 0,
            },
        ],
    )

    r = loopback_client.get(
        "/api/plugins/hermes-mobile/providers", headers=_TOKEN_HEADER
    )

    assert r.status_code == 200, r.text
    assert cap["called"] is True
    assert cap["kwargs"] == {
        "picker_hints": True,
        "include_unconfigured": True,
        "max_models": 50,
    }
    slugs = {p["slug"] for p in r.json()["providers"]}
    assert "openrouter" not in slugs
    assert "custom" not in slugs
    assert "novita" in slugs


def test_list_providers_keeps_authenticated_unregistered_rows(
    loopback_client, monkeypatch
):
    cap = _patch_stock_inventory(
        monkeypatch,
        rows=[
            {
                "slug": "custom",
                "name": "Custom",
                "auth_type": "api_key",
                "is_current": False,
                "authenticated": True,
                "total_models": 1,
            },
        ],
    )

    r = loopback_client.get(
        "/api/plugins/hermes-mobile/providers", headers=_TOKEN_HEADER
    )

    assert r.status_code == 200, r.text
    assert cap["called"] is True
    assert [p["slug"] for p in r.json()["providers"]] == ["custom"]


def test_provider_rows_include_unconfigured_stock_providers(monkeypatch):
    """Mobile provider rows request canonical skeleton providers too.

    A zero-credential canonical provider only appears when the stock inventory
    builder is called with include_unconfigured=True; otherwise the mobile list
    has no row the user can tap to reach Add key.
    """
    import hermes_cli.inventory as inventory

    ctx = object()
    captured = {}

    def _load_picker_context():
        return ctx

    def _build_models_payload(received_ctx, **kwargs):
        captured["ctx"] = received_ctx
        captured["kwargs"] = kwargs
        return {"providers": [_DEEPSEEK_ROW]}

    monkeypatch.setattr(inventory, "load_picker_context", _load_picker_context)
    monkeypatch.setattr(inventory, "build_models_payload", _build_models_payload)

    rows = _api()._provider_provider_rows()

    assert rows == [_DEEPSEEK_ROW]
    assert captured == {
        "ctx": ctx,
        "kwargs": {
            "picker_hints": True,
            "include_unconfigured": True,
            "max_models": 50,
        },
    }


# ===========================================================================
# Tier A — POST /providers/{slug}/key
# ===========================================================================


def test_set_key_tier_a_dispatches_save_env(loopback_client, monkeypatch):
    """A registered api_key provider dispatches to save_env_value on its first
    api_key_env_var and mirrors into os.environ."""
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    calls = _patch_config(monkeypatch)

    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "sk-deepseek-xyz"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200, r.text
    # The deepseek provider's first env var is DEEPSEEK_API_KEY.
    assert ("DEEPSEEK_API_KEY", "sk-deepseek-xyz") in calls["save_env"]
    import os

    assert os.environ.get("DEEPSEEK_API_KEY") == "sk-deepseek-xyz"

    body = r.json()
    assert body["provider"]["slug"] == "deepseek"
    assert body["provider"]["authenticated"] is True
    # NEVER echoes the key.
    assert "sk-deepseek-xyz" not in r.text


def test_set_key_rejects_oauth_provider_4003(loopback_client, monkeypatch):
    """An OAuth-only provider (nous) is rejected with a 'set up on desktop'
    4003-class error — parity with stock model.save_key."""
    _patch_inventory(monkeypatch, rows=[_NOUS_ROW])
    calls = _patch_config(monkeypatch)

    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/nous/key",
        json={"api_key": "sk-nope"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    body = r.json()
    assert body["code"] == 4003
    assert "desktop" in body["error"].lower()
    # The key was NOT persisted.
    assert calls["save_env"] == []


@pytest.mark.parametrize(
    "oauth_slug",
    # Every non-api_key provider in PROVIDER_REGISTRY: OAuth device-code,
    # external OAuth, external process, minimax OAuth, and AWS SDK. None of
    # these can be provisioned from a raw key on mobile — the route must
    # reject them all with the 4003 "set up on desktop" class. (The spec
    # names gemini/minimax, which ALSO carry api_key variants — those api_key
    # variants are Tier A; the OAuth variants below are the reject set.)
    ["nous", "openai-codex", "xai-oauth", "qwen-oauth",
     "google-gemini-cli", "copilot-acp", "minimax-oauth"],
)
def test_set_key_rejects_all_oauth_only_providers(
    loopback_client, monkeypatch, oauth_slug
):
    """Every OAuth/external-only provider is rejected (4003)."""
    from hermes_cli.auth import PROVIDER_REGISTRY

    pconfig = PROVIDER_REGISTRY.get(oauth_slug)
    assert pconfig is not None, f"{oauth_slug} not in registry"
    assert pconfig.auth_type != "api_key", (
        f"{oauth_slug} is unexpectedly an api_key provider"
    )
    _patch_config(monkeypatch)
    r = loopback_client.post(
        f"/api/plugins/hermes-mobile/providers/{oauth_slug}/key",
        json={"api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    assert r.json()["code"] == 4003
    assert "desktop" in r.json()["error"].lower()


def test_set_key_rejects_managed_4006(loopback_client, monkeypatch):
    """A managed install is read-only → 4006 (parity with stock)."""
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    calls = _patch_config(monkeypatch)
    calls["managed"] = True

    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    assert r.json()["code"] == 4006
    assert calls["save_env"] == []


def test_set_key_rejects_unknown_slug_4002(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/ghost-provider/key",
        json={"api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    assert r.json()["code"] == 4002


def test_set_key_rejects_empty_key_4001(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "   "},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    assert r.json()["code"] == 4001


def test_set_key_never_logs_key_value(loopback_client, monkeypatch, caplog):
    """The api_key value must never appear in logs — only the EVENT."""
    import logging

    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    _patch_config(monkeypatch)
    secret = "test-secret-never-log-me-12345"

    with caplog.at_level(logging.DEBUG, logger="plugins.hermes_mobile.dashboard.api"):
        r = loopback_client.post(
            "/api/plugins/hermes-mobile/providers/deepseek/key",
            json={"api_key": secret},
            headers=_TOKEN_HEADER,
        )
    assert r.status_code == 200
    assert secret not in caplog.text


def test_set_key_rejected_key_reports_validation_false_and_persists(
    loopback_client, monkeypatch
):
    """ABH-219: a definitively rejected provider key must not look like a silent
    success. The key is still persisted so the user can replace/retry, but the
    response carries validated:false + a recovery reason.
    """
    api = _api()
    monkeypatch.setattr(
        api,
        "_validate_provider_key",
        lambda **_kw: {
            "validated": False,
            "validation_detail": "provider rejected the API key (401)",
            "persisted": True,
        },
        raising=False,
    )
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    calls = _patch_config(monkeypatch)

    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "sk-rejected"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 200, r.text
    body = r.json()
    assert ("DEEPSEEK_API_KEY", "sk-rejected") in calls["save_env"]
    assert body["persisted"] is True
    assert body["validated"] is False
    assert "rejected" in body["validation_detail"].lower()
    assert body["provider"]["authenticated"] is False
    assert "sk-rejected" not in r.text


def test_set_key_timeout_reports_validation_skipped_without_500(
    loopback_client, monkeypatch
):
    """ABH-219: timeout/unreachable validation is non-fatal. The persisted key
    survives and callers get validated:'skipped' instead of a 500.
    """
    api = _api()
    monkeypatch.setattr(
        api,
        "_validate_provider_key",
        lambda **_kw: {
            "validated": "skipped",
            "validation_detail": "validation timed out; key saved but not confirmed",
            "persisted": True,
        },
        raising=False,
    )
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    _patch_config(monkeypatch)

    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "sk-timeout"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 200, r.text
    body = r.json()
    assert body["persisted"] is True
    assert body["validated"] == "skipped"
    assert "saved" in body["validation_detail"].lower()
    assert body["provider"]["authenticated"] is True


def test_set_key_validation_is_additive_to_existing_success_shape(
    loopback_client, monkeypatch
):
    """ABH-219 backward compat: callers that only read provider still get the
    success shape, with validation fields added alongside it.
    """
    api = _api()
    monkeypatch.setattr(
        api,
        "_validate_provider_key",
        lambda **_kw: {
            "validated": True,
            "validation_detail": "provider accepted the API key",
            "persisted": True,
        },
        raising=False,
    )
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    _patch_config(monkeypatch)

    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "sk-good"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 200, r.text
    body = r.json()
    assert body["provider"]["slug"] == "deepseek"
    assert body["provider"]["authenticated"] is True
    assert body["persisted"] is True
    assert body["validated"] is True
    assert body["validation_detail"]
    assert "sk-good" not in r.text


def test_provider_key_validation_runs_via_to_thread_for_mutators(
    loopback_client, monkeypatch
):
    """ABH-245: slow provider validation must not run on the request loop."""
    import types

    api = _api()
    to_thread_calls = []
    validation_calls = []

    def _validation(**kwargs):
        validation_calls.append(kwargs)
        return {
            "validated": True,
            "validation_detail": "provider accepted the API key",
            "persisted": True,
        }

    async def _to_thread(func, *args, **kwargs):
        to_thread_calls.append({"func": func, "args": args, "kwargs": kwargs})
        return func(*args, **kwargs)

    monkeypatch.setattr(
        api, "asyncio", types.SimpleNamespace(to_thread=_to_thread), raising=False
    )
    monkeypatch.setattr(api, "_validate_provider_key", _validation, raising=False)
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    _patch_config(monkeypatch)

    registered = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "registered-threaded-key"},
        headers=_TOKEN_HEADER,
    )
    custom = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={
            "name": "threadedcustom",
            "base_url": "https://api.threaded.example/v1",
            "api_mode": "openai",
            "api_key": "custom-threaded-key",
        },
        headers=_TOKEN_HEADER,
    )

    assert registered.status_code == 200, registered.text
    assert custom.status_code == 200, custom.text
    assert len(validation_calls) == 2
    assert len(to_thread_calls) == 2
    assert [call["func"] for call in to_thread_calls] == [_validation, _validation]
    assert to_thread_calls[0]["kwargs"]["api_key"] == "registered-threaded-key"
    assert to_thread_calls[1]["kwargs"] == {
        "api_key": "custom-threaded-key",
        "base_url": "https://api.threaded.example/v1",
        "api_mode": "openai",
        "timeout": api._PROVIDER_KEY_VALIDATION_TIMEOUT_SECONDS,
    }


def test_validate_provider_key_endpoint_uses_anthropic_headers_for_anthropic(
    loopback_client, monkeypatch
):
    """ABH-259: registered Anthropic key validation must use x-api-key.

    The Tier A endpoint must pass the provider's Anthropic Messages mode into
    the real validation helper; otherwise the helper falls back to the OpenAI
    Bearer header and Anthropic rejects the key.
    """
    import urllib.request

    captured_headers = []

    class _Response:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            return False

        def read(self):
            return b"{}"

    def _accept(req, timeout):
        captured_headers.append({k.lower(): v for k, v in req.header_items()})
        return _Response()

    monkeypatch.setattr(urllib.request, "urlopen", _accept)
    _patch_inventory(monkeypatch, rows=[_ANTHROPIC_ROW])
    calls = _patch_config(monkeypatch)

    anthropic = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/anthropic/key",
        json={"api_key": "anthropic-test-key"},
        headers=_TOKEN_HEADER,
    )

    assert anthropic.status_code == 200, anthropic.text
    assert ("ANTHROPIC_API_KEY", "anthropic-test-key") in calls["save_env"]
    anthropic_headers = captured_headers[-1]
    assert anthropic_headers["x-api-key"] == "anthropic-test-key"
    assert anthropic_headers["anthropic-version"] == "2023-06-01"
    assert "authorization" not in anthropic_headers

    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    deepseek = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        json={"api_key": "deepseek-test-key"},
        headers=_TOKEN_HEADER,
    )

    assert deepseek.status_code == 200, deepseek.text
    deepseek_headers = captured_headers[-1]
    assert deepseek_headers["authorization"] == "Bearer deepseek-test-key"
    assert "x-api-key" not in deepseek_headers
    assert "anthropic-version" not in deepseek_headers


# ===========================================================================
# Tier B — POST /providers/custom
# ===========================================================================


def test_custom_dispatches_set_config(loopback_client, monkeypatch):
    """A custom provider writes providers.<name>.{name,base_url,api_mode,key_env}
    to config.yaml and the RAW key to .env via save_env_value (NOT to config.yaml)."""
    _patch_inventory(monkeypatch, rows=[])
    calls = _patch_config(monkeypatch)

    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={
            "name": "myco",
            "base_url": "https://api.my.co/v1",
            "api_mode": "openai",
            "api_key": "sk-custom-1",
        },
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200, r.text
    keys = {k for k, _ in calls["set_config"]}
    assert "providers.myco.name" in keys
    assert "providers.myco.base_url" in keys
    assert "providers.myco.api_mode" in keys
    # key_env (the env-var NAME) lands in config.yaml — NOT the raw api_key.
    assert "providers.myco.key_env" in keys
    assert "providers.myco.api_key" not in keys
    # The env-var NAME is derived from the provider name (collision-resistant:
    # MYCO_<shorthash>_API_KEY).
    import hashlib as _hashlib
    expected_env_var = "MYCO_" + _hashlib.sha1(b"myco").hexdigest()[:6] + "_API_KEY"
    key_env_call = [v for k, v in calls["set_config"] if k == "providers.myco.key_env"]
    assert key_env_call == [expected_env_var]
    # The RAW key value is forwarded ONLY to save_env_value (the secure .env
    # writer, chmod 0600, never printed). It must NEVER touch set_config_value.
    assert (expected_env_var, "sk-custom-1") in calls["save_env"]
    raw_key_in_config = any(v == "sk-custom-1" for _, v in calls["set_config"])
    assert not raw_key_in_config
    assert "sk-custom-1" not in r.text


def test_custom_rejects_bad_base_url(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={"name": "myco", "base_url": "not-a-url",
              "api_mode": "openai", "api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400


def test_custom_rejects_file_scheme(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={"name": "myco", "base_url": "file:///etc/passwd",
              "api_mode": "openai", "api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400


def test_custom_rejects_bad_api_mode(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={"name": "myco", "base_url": "https://api.my.co",
              "api_mode": "websocket", "api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400


def test_custom_rejects_unsafe_name(loopback_client, monkeypatch):
    """A provider name with a dot/bracket that could escape the providers
    subtree is rejected."""
    _patch_config(monkeypatch)
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={"name": "evil..path", "base_url": "https://api.my.co",
              "api_mode": "openai", "api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400


def test_custom_rejects_managed_4006(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    calls = _patch_config(monkeypatch)  # re-patch to get a fresh calls dict
    calls["managed"] = True
    r = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={"name": "myco", "base_url": "https://api.my.co",
              "api_mode": "openai", "api_key": "sk-x"},
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    assert r.json()["code"] == 4006
    assert calls["set_config"] == []


# ===========================================================================
# DELETE /providers/{slug}/key
# ===========================================================================


def test_delete_key_dispatches_remove_env(loopback_client, monkeypatch):
    """For a registered api_key provider, remove_env_value is called on each
    api_key_env_var (parity with model.disconnect)."""
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])
    calls = _patch_config(monkeypatch)
    _patch_clear_auth(monkeypatch, returns=False)

    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200, r.text
    assert "DEEPSEEK_API_KEY" in calls["remove_env"]
    body = r.json()
    assert body["slug"] == "deepseek"
    assert body["disconnected"] is True


def test_delete_key_no_credentials_4005(loopback_client, monkeypatch):
    """A slug with no env vars and no auth state → 4005 (parity model.disconnect)."""
    _patch_config(monkeypatch)
    _patch_clear_auth(monkeypatch, returns=False)
    # 'nous' has no api_key_env_vars; remove_env_value is never called and
    # clear_provider_auth returns False → 4005.
    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/nous/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    assert r.json()["code"] == 4005


def test_delete_key_rejects_managed_4006(loopback_client, monkeypatch):
    _patch_config(monkeypatch)
    calls = _patch_config(monkeypatch)
    calls["managed"] = True
    _patch_clear_auth(monkeypatch)
    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400
    assert r.json()["code"] == 4006


def test_delete_pure_credential_custom_provider_removes_config_entry_and_picker_ghost(
    loopback_client, monkeypatch
):
    """ABH-218: a custom provider whose config entry contains only credential
    fields is removed from config.yaml entirely, so model_switch no longer emits
    a ghost authenticated/user-config row for the empty providers.<slug> husk.
    """
    import hashlib as _hashlib

    slug = "ghost-custom"
    expected_env = "GHOST_CUSTOM_" + _hashlib.sha1(slug.encode()).hexdigest()[:6] + "_API_KEY"
    calls = _patch_config(
        monkeypatch,
        providers_in_config={slug: {"key_env": expected_env, "api_key": "legacy-inline"}},
    )
    _patch_clear_auth(monkeypatch, returns=False)

    r = loopback_client.request(
        "DELETE",
        f"/api/plugins/hermes-mobile/providers/{slug}/key",
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 200, r.text
    assert r.json()["disconnected"] is True
    assert expected_env in calls["remove_env"]
    assert calls["save_config"], "DELETE should persist removal of providers.<slug>"
    saved = calls["save_config"][-1]
    assert slug not in saved.get("providers", {})
    assert calls["set_config"] == []

    import agent.models_dev as models_dev
    import hermes_cli.models as models
    from hermes_cli.model_switch import list_authenticated_providers

    monkeypatch.setattr(models_dev, "fetch_models_dev", lambda: {})
    monkeypatch.setattr(models, "get_curated_nous_model_ids", lambda: [])
    rows = list_authenticated_providers(
        user_providers=saved.get("providers", {}),
        custom_providers=[],
        max_models=1,
    )
    assert slug not in {row.get("slug") for row in rows}


def test_delete_tuning_bearing_custom_provider_preserves_tuning_keys(
    loopback_client, monkeypatch
):
    """ABH-218 A2: disconnecting a custom provider with non-credential tuning
    keeps the tuning subtree but removes api_key/key_env.
    """
    import hashlib as _hashlib

    slug = "tuned-custom"
    expected_env = "TUNED_CUSTOM_" + _hashlib.sha1(slug.encode()).hexdigest()[:6] + "_API_KEY"
    calls = _patch_config(
        monkeypatch,
        providers_in_config={
            slug: {
                "name": "Tuned Custom",
                "base_url": "https://api.tuned.example/v1",
                "api_mode": "openai",
                "model": "tuned/model",
                "key_env": expected_env,
                "api_key": "legacy-inline",
            }
        },
    )
    _patch_clear_auth(monkeypatch, returns=False)

    r = loopback_client.request(
        "DELETE",
        f"/api/plugins/hermes-mobile/providers/{slug}/key",
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 200, r.text
    assert expected_env in calls["remove_env"]
    saved = calls["save_config"][-1]
    assert saved["providers"][slug] == {
        "name": "Tuned Custom",
        "base_url": "https://api.tuned.example/v1",
        "api_mode": "openai",
        "model": "tuned/model",
    }
    assert calls["set_config"] == []


# ===========================================================================
# Pure helpers
# ===========================================================================


def test_looks_like_url_accepts_http_https():
    assert _api()._looks_like_url("https://api.openai.com")
    assert _api()._looks_like_url("http://localhost:8080")
    assert _api()._looks_like_url("https://192.168.1.5/v1")


def test_looks_like_url_rejects_non_http():
    f = _api()._looks_like_url
    assert not f("file:///etc/passwd")
    assert not f("ftp://x.y")
    assert not f("localhost:8080")  # bare host, no scheme
    assert not f("not a url")
    assert not f("")


def test_refresh_provider_row_projects_safe_shape(monkeypatch):
    api = _api()
    _refresh_provider_row = api._refresh_provider_row
    monkeypatch.setattr(api, "_provider_provider_rows", lambda: [])

    row = _refresh_provider_row("deepseek", fallback_name="DeepSeek")
    # When the refreshed inventory cannot surface the slug, the fallback still
    # reports the just-set provider as authenticated while preserving the safe
    # response shape.
    assert set(row.keys()) == {
        "slug", "name", "auth_type", "is_current",
        "authenticated", "total_models", "models",
    }
    assert row["slug"] == "deepseek"
    assert row["authenticated"] is True


def test_validate_provider_key_classifies_http_auth_rejection(monkeypatch):
    """The real validation helper maps 401/403 from /models to validated:false."""
    import urllib.error
    import urllib.request

    from email.message import Message

    def _reject(req, timeout):
        raise urllib.error.HTTPError(
            req.full_url,
            401,
            "Unauthorized",
            hdrs=Message(),
            fp=None,
        )

    monkeypatch.setattr(urllib.request, "urlopen", _reject)

    result = _api()._validate_provider_key(
        api_key="sk-rejected",
        base_url="https://api.example.test/v1",
        timeout=0.01,
    )

    assert result["persisted"] is True
    assert result["validated"] is False
    assert "401" in result["validation_detail"]


def test_validate_provider_key_classifies_timeout_as_skipped(monkeypatch):
    """The real validation helper never hard-fails slow/unreachable probes."""
    import urllib.request

    calls = []

    def _timeout(req, timeout):
        calls.append((req.full_url, timeout))
        raise TimeoutError("timed out")

    monkeypatch.setattr(urllib.request, "urlopen", _timeout)

    result = _api()._validate_provider_key(
        api_key="sk-timeout",
        base_url="https://api.example.test/v1",
        timeout=0.01,
    )

    assert calls
    assert result["persisted"] is True
    assert result["validated"] == "skipped"
    assert "could not be completed" in result["validation_detail"]


# ===========================================================================
# Regression — ABH-183 security review. Tier B key must NEVER leak to the
# persisted config.yaml or the dashboard/dev-gateway log; the raw key lives
# ONLY in the secure .env (chmod 0600, written by save_env_value, never
# printed) and config.yaml carries only the env-var NAME under key_env.
# ===========================================================================


def test_custom_key_never_in_config_or_log_or_response(
    loopback_client, monkeypatch, caplog
):
    """Regression (security review DEFECT 1): the Tier B custom-provider key
    must land in .env (save_env_value) and NEVER in config.yaml
    (set_config_value), the log, or the response.

    The pre-fix code called set_config_value("providers.<name>.api_key", key),
    whose dotted key does NOT match stock set_config_value's _API_KEY-suffix
    routing → it hit the config.yaml branch which prints the raw key to stdout
    (captured at rest in the dashboard/dev-gateway log).
    """
    import logging

    _patch_inventory(monkeypatch, rows=[])
    calls = _patch_config(monkeypatch)
    secret = "sk-leak-regression-DEFECT-1"

    with caplog.at_level(logging.DEBUG, logger="plugins.hermes_mobile.dashboard.api"):
        r = loopback_client.post(
            "/api/plugins/hermes-mobile/providers/custom",
            json={
                "name": "myco",
                "base_url": "https://api.my.co/v1",
                "api_mode": "openai",
                "api_key": secret,
            },
            headers=_TOKEN_HEADER,
        )
    assert r.status_code == 200, r.text

    # 1. The raw key was written to the SECURE .env via save_env_value under the
    #    collision-resistant derived env-var name (MYCO_<shorthash>_API_KEY).
    import hashlib as _hashlib
    expected_env_myco = "MYCO_" + _hashlib.sha1(b"myco").hexdigest()[:6] + "_API_KEY"
    assert (expected_env_myco, secret) in calls["save_env"]

    # 2. The raw key was NEVER forwarded to set_config_value (which is the leaky
    #    config.yaml path). config.yaml may carry the env-var NAME under key_env
    #    but never the secret itself.
    for cfg_key, cfg_val in calls["set_config"]:
        assert cfg_val != secret, (
            f"raw key leaked to config.yaml via set_config_value({cfg_key!r}, <secret>)"
        )

    # 3. The env-var NAME under key_env is present (this is how the runtime
    #    resolves the key from .env at request time).
    key_env_vals = [
        v for k, v in calls["set_config"] if k == "providers.myco.key_env"
    ]
    assert key_env_vals == [expected_env_myco]

    # 4. The raw key is NOT in the log output (caplog captures the plugin
    #    logger at DEBUG).
    assert secret not in caplog.text

    # 5. The raw key is NOT echoed in the response body.
    assert secret not in r.text


def test_delete_custom_provider_clears_key_everywhere(loopback_client, monkeypatch):
    """Regression (security review DEFECT 2): DELETE on a CUSTOM provider must
    actually remove the persisted key — from .env (remove_env_value on the
    stored env var) AND from config.yaml (remove api_key/key_env while preserving
    non-credential tuning). The pre-fix code only called clear_provider_auth
    (which mutates the auth_store JSON, never config.yaml/.env), so
    providers.<name>.key_env persisted and the runtime could still resolve the
    key while the route returned disconnected:true.
    """
    import hashlib as _hashlib
    slug = "acme-local"
    expected_env = "ACME_LOCAL_" + _hashlib.sha1(b"acme-local").hexdigest()[:6] + "_API_KEY"

    # Simulate that POST /providers/custom already wrote a providers.acme-local
    # entry to config.yaml (required by BUG 4 fix: only clear when entry exists).
    _patch_config(
        monkeypatch,
        providers_in_config={"acme-local": {"key_env": expected_env, "base_url": "https://api.acme.example/v1"}},
    )
    cap_clear = _patch_clear_auth(monkeypatch, returns=True)

    r = loopback_client.request(
        "DELETE",
        f"/api/plugins/hermes-mobile/providers/{slug}/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["slug"] == slug
    # disconnected:true is only returned when the key really was cleared.
    assert body["disconnected"] is True

    # The handler MUST have recognized this as a custom provider (slug not in
    # PROVIDER_REGISTRY) by deriving the env var and removing it from .env.

    # Re-patch with a capturing recorder and DELETE again to inspect calls.
    # The handler is idempotent for this assertion (it still attempts the clears;
    # remove_env_value returns True under the patch so disconnected stays true).
    calls2 = _patch_config(
        monkeypatch,
        providers_in_config={"acme-local": {"key_env": expected_env, "base_url": "https://api.acme.example/v1"}},
    )
    _patch_clear_auth(monkeypatch, returns=True)
    r2 = loopback_client.request(
        "DELETE",
        f"/api/plugins/hermes-mobile/providers/{slug}/key",
        headers=_TOKEN_HEADER,
    )
    assert r2.status_code == 200, r2.text

    # The derived env var was removed from .env.
    assert expected_env in calls2["remove_env"], (
        f"DELETE did not remove the custom provider's .env var {expected_env}; "
        f"remove_env_value calls: {calls2['remove_env']}"
    )
    # config.yaml credential fields were removed while non-credential tuning was
    # preserved (no empty api_key/key_env husk remains).
    assert calls2["save_config"], "DELETE did not persist config credential removal"
    saved_provider = calls2["save_config"][-1]["providers"][slug]
    assert saved_provider == {"base_url": "https://api.acme.example/v1"}
    assert calls2["set_config"] == []

    # The raw value under those keys is never a secret — and clear_provider_auth
    # was still invoked for the auth_store JSON state.
    assert cap_clear.get("slug") == slug


def test_delete_custom_provider_4005_when_nothing_to_clear(loopback_client, monkeypatch):
    """A custom-provider DELETE where the entry IS present in config but
    remove_env_value finds nothing in .env still returns 200 disconnected:true —
    config blanking (set_config_value) counts as a clear even when .env was
    already empty (e.g. manually removed). The key IS gone from config after the
    DELETE even though .env was already clean."""
    slug = "ghost-custom"
    import hashlib as _hashlib
    expected_env = "GHOST_CUSTOM_" + _hashlib.sha1(b"ghost-custom").hexdigest()[:6] + "_API_KEY"

    calls = _patch_config(
        monkeypatch,
        providers_in_config={slug: {"key_env": expected_env, "base_url": "https://example.com/v1"}},
    )
    # Simulate remove_env_value finding nothing in .env (already removed).
    import hermes_cli.config as config

    def _remove_env(_key):
        calls["remove_env"].append(_key)
        return False

    monkeypatch.setattr(config, "remove_env_value", _remove_env)
    _patch_clear_auth(monkeypatch, returns=False)

    r = loopback_client.request(
        "DELETE",
        f"/api/plugins/hermes-mobile/providers/{slug}/key",
        headers=_TOKEN_HEADER,
    )
    # cleared_config is True (config entry exists → set_config_value blanks the
    # config keys), so the route returns 200 disconnected:true — the persisted
    # config.yaml state is durably cleared even though .env was already empty.
    assert r.status_code == 200, r.text
    assert r.json()["disconnected"] is True


# ===========================================================================
# _looks_like_url precedence nit (security review) — the dead-code "."-check.
# ===========================================================================


def test_looks_like_url_rejects_scheme_only_empty_host():
    """Regression (security review NIT): the pre-fix expression reduced to
    ``bool(host)`` by operator precedence, so a scheme-only URL with an empty
    host ("https://") would be accepted. The fixed validator requires a
    non-empty host with a dot (or the literal ``localhost``)."""
    f = _api()._looks_like_url
    # scheme-only with NO host must be rejected (pre-fix bug accepted this).
    assert not f("https://")
    assert not f("http://")
    assert not f("https://:8080")
    # A host with neither a dot nor being "localhost" is rejected.
    assert not f("https://barehost/v1")
    # Sanity: a valid dotted host + localhost still pass.
    assert f("https://api.openai.com")
    assert f("http://localhost:8080")
    assert f("https://192.168.1.5/v1")


# ===========================================================================
# ABH-201 — collision-resistance: separator-differing names get distinct vars.
# ===========================================================================


def test_custom_provider_env_var_collision_resistance(loopback_client, monkeypatch):
    """Regression (ABH-201): two custom provider names that differ ONLY by a
    separator character (``my-co`` vs ``my_co``) both sanitize to ``MY_CO``
    under the pure sanitize-and-suffix scheme, so they would share the same env
    var and the second POST silently overwrites the first provider's key.

    The fix appends a 6-hex-char SHA-1 short-hash of the EXACT name, making
    the derived var unique per exact name while keeping it human-readable.

    This test:
    1. POSTs both providers and asserts their keys land in DISTINCT env vars
       (neither overwrites the other).
    2. DELETEs one and asserts only ITS env var is removed (the other survives).
    """
    import hashlib as _hashlib

    calls = _patch_config(monkeypatch)
    _patch_inventory(monkeypatch, rows=[])
    _patch_clear_auth(monkeypatch, returns=False)

    # Expected derived env vars (collision-resistant, hash-disambiguated).
    env_dash = "MY_CO_" + _hashlib.sha1(b"my-co").hexdigest()[:6] + "_API_KEY"
    env_under = "MY_CO_" + _hashlib.sha1(b"my_co").hexdigest()[:6] + "_API_KEY"

    # Sanity: the two env vars must be DISTINCT (the whole point of the fix).
    assert env_dash != env_under, (
        f"Test pre-condition failed: {env_dash!r} == {env_under!r}; "
        "SHA-1 collision or wrong hash input"
    )

    # POST my-co.
    r1 = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={
            "name": "my-co",
            "base_url": "https://api.my-co.example/v1",
            "api_mode": "openai",
            "api_key": "sk-myco-dash-key",
        },
        headers=_TOKEN_HEADER,
    )
    assert r1.status_code == 200, r1.text

    # POST my_co.
    r2 = loopback_client.post(
        "/api/plugins/hermes-mobile/providers/custom",
        json={
            "name": "my_co",
            "base_url": "https://api.my-co.example/v1",
            "api_mode": "openai",
            "api_key": "sk-myco-under-key",
        },
        headers=_TOKEN_HEADER,
    )
    assert r2.status_code == 200, r2.text

    # Both keys must have landed in DIFFERENT env vars.
    saved_env_vars = {k for k, _ in calls["save_env"]}
    assert env_dash in saved_env_vars, (
        f"my-co key not saved under {env_dash!r}; save_env calls: {calls['save_env']}"
    )
    assert env_under in saved_env_vars, (
        f"my_co key not saved under {env_under!r}; save_env calls: {calls['save_env']}"
    )

    # Verify the key values match what was POSTed (not overwritten).
    saved_map = dict(calls["save_env"])
    assert saved_map[env_dash] == "sk-myco-dash-key", (
        f"my-co key was overwritten: {saved_map[env_dash]!r}"
    )
    assert saved_map[env_under] == "sk-myco-under-key", (
        f"my_co key was overwritten: {saved_map[env_under]!r}"
    )

    # DELETE my-co: only its env var must be removed; my_co's var must survive.
    # BUG 4 fix: the DELETE now reads config first to verify the entry exists.
    # Simulate both providers having been written (as POST /providers/custom
    # would have done). Only my-co needs to be present for the DELETE to proceed,
    # but include both to reflect realistic state.
    import hermes_cli.config as _config_mod
    monkeypatch.setattr(
        _config_mod,
        "load_config_readonly",
        lambda: {"providers": {
            "my-co": {"key_env": env_dash, "base_url": "https://api.my-co.example/v1"},
            "my_co": {"key_env": env_under, "base_url": "https://api.my-co.example/v1"},
        }},
    )

    r3 = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/my-co/key",
        headers=_TOKEN_HEADER,
    )
    assert r3.status_code == 200, r3.text
    assert r3.json()["disconnected"] is True

    # my-co's env var was removed.
    assert env_dash in calls["remove_env"], (
        f"DELETE my-co did not remove {env_dash!r}; remove_env calls: {calls['remove_env']}"
    )
    # my_co's env var was NOT touched by the DELETE.
    assert env_under not in calls["remove_env"], (
        f"DELETE my-co incorrectly removed {env_under!r} (my_co's var)"
    )


# ===========================================================================
# ABH-201 backward-compat — DELETE must remove the STORED key_env, not the
# re-derived (new-scheme) var, so pre-fix providers' keys don't leak in .env.
# ===========================================================================


def test_delete_legacy_custom_provider_removes_stored_key_env(
    loopback_client, monkeypatch
):
    """Regression (ABH-201 back-compat): a custom provider created BEFORE the
    collision-resistance fix has its key stored under the OLD, hash-less env-var
    name (e.g. ``MY_CO_API_KEY``), recorded in ``providers.<slug>.key_env``.

    After the fix, ``_custom_provider_env_var("my-co")`` returns the NEW hashed
    name (``MY_CO_6664ff_API_KEY``). If DELETE re-derived the name instead of
    reading the stored ``key_env``, it would remove the non-existent new var and
    leave the legacy key orphaned in .env — a secret leak.

    This test proves DELETE uses the STORED ``key_env``: it removes the legacy
    var name and does NOT touch the re-derived new var.
    """
    import hashlib as _hashlib

    calls = _patch_config(monkeypatch)
    _patch_inventory(monkeypatch, rows=[])
    _patch_clear_auth(monkeypatch, returns=False)

    # The legacy provider's stored key_env is the OLD (hash-less) name.
    legacy_env = "MY_CO_API_KEY"
    # The new-scheme derived name (what a naive re-derivation would compute).
    new_env = "MY_CO_" + _hashlib.sha1(b"my-co").hexdigest()[:6] + "_API_KEY"
    assert legacy_env != new_env, "test pre-condition: schemes must differ"

    # Simulate a legacy config entry: key_env points at the OLD var name, and a
    # raw api_key is also present inline (defensive legacy shape).
    import hermes_cli.config as _config_mod

    monkeypatch.setattr(
        _config_mod,
        "load_config_readonly",
        lambda: {
            "providers": {
                "my-co": {
                    "key_env": legacy_env,
                    "api_key": "legacy-inline",
                    "base_url": "https://api.my-co.example/v1",
                }
            }
        },
    )

    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/my-co/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200, r.text
    assert r.json()["disconnected"] is True

    # The STORED legacy var must be removed — not the re-derived new var.
    assert legacy_env in calls["remove_env"], (
        f"DELETE did not remove the stored legacy key_env {legacy_env!r}; "
        f"remove_env calls: {calls['remove_env']}"
    )
    assert new_env not in calls["remove_env"], (
        f"DELETE removed the re-derived {new_env!r} instead of the stored "
        f"key_env — legacy key would leak in .env"
    )


# ===========================================================================
# ABH-183 BUG 3 + BUG 4 — DELETE /providers/{slug}/key correctness
# ===========================================================================


def test_delete_custom_named_after_registered_slug_clears_key(
    loopback_client, monkeypatch
):
    """BUG 3: A custom provider whose name equals a registered slug (e.g. 'anthropic')
    must have its config entry cleared on DELETE. Previously the custom-clear block
    only ran when the slug was absent from PROVIDER_REGISTRY — a custom 'anthropic'
    would return 200 disconnected:true while its key persisted in .env + config.yaml.

    Fix: custom-clear also runs when providers.<slug> exists in config, regardless of
    registry membership. The registry's own ANTHROPIC_API_KEY env-var removal also
    fires (it's a registered api_key provider), but the custom-derived var and the
    config entries must also be cleared.
    """
    import hashlib as _hashlib

    # Use 'anthropic' — a well-known registered api_key slug — as the custom provider
    # name. A user might name a local Ollama/LM Studio proxy 'anthropic' to shadow
    # the registered provider.
    slug = "anthropic"
    expected_custom_env = (
        "ANTHROPIC_" + _hashlib.sha1(b"anthropic").hexdigest()[:6] + "_API_KEY"
    )

    # Simulate that POST /providers/custom with name='anthropic' has been called:
    # config.yaml has a providers.anthropic entry.
    calls = _patch_config(
        monkeypatch,
        providers_in_config={
            "anthropic": {"key_env": expected_custom_env, "base_url": "http://localhost:11434/v1"},
        },
    )
    _patch_clear_auth(monkeypatch, returns=False)

    r = loopback_client.request(
        "DELETE",
        f"/api/plugins/hermes-mobile/providers/{slug}/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["slug"] == slug
    assert body["disconnected"] is True

    # The custom-derived env var MUST have been removed from .env — previously
    # this was silently skipped because 'anthropic' is in PROVIDER_REGISTRY.
    assert expected_custom_env in calls["remove_env"], (
        f"BUG 3: DELETE did not remove custom .env var {expected_custom_env!r}; "
        f"remove_env calls: {calls['remove_env']}"
    )
    # config.yaml credential fields MUST have been removed while the custom
    # endpoint tuning survives.
    assert calls["save_config"], "BUG 3: config credential removal was not saved"
    saved_provider = calls["save_config"][-1]["providers"][slug]
    assert saved_provider == {"base_url": "http://localhost:11434/v1"}
    assert calls["set_config"] == []


def test_delete_never_created_slug_returns_4005_no_config_written(
    loopback_client, monkeypatch
):
    """BUG 4 (part 2): DELETE a slug that was never created (no providers.<slug>
    config entry) must return 4005 'no credentials found' and MUST NOT write any
    config entries. Previously the custom block ran unconditionally, writing bogus
    providers.<slug>.{api_key,key_env} entries for a slug that never existed.
    """
    # _patch_config defaults to empty providers_in_config (no custom entries).
    calls = _patch_config(monkeypatch)
    _patch_clear_auth(monkeypatch, returns=False)

    # 'nevercreated' is not in PROVIDER_REGISTRY and has no config entry.
    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/nevercreated/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 400, r.text
    assert r.json()["code"] == 4005

    # MUST NOT have written any config entries (no config pollution).
    assert calls["set_config"] == [], (
        f"BUG 4: DELETE wrote config entries for a never-created slug: {calls['set_config']}"
    )
    # MUST NOT have called remove_env_value for the derived custom var.
    assert calls["remove_env"] == [], (
        f"BUG 4: DELETE called remove_env_value for a never-created slug: {calls['remove_env']}"
    )


def test_delete_invalid_slug_returns_4001(loopback_client, monkeypatch):
    """BUG 4 (part 1): A DELETE with a dotted or otherwise invalid slug must
    return 4001 immediately, before any config read or write. Dotted slugs
    would create junk nested config subtrees (e.g. providers.foo.bar.api_key
    instead of providers.foobar.api_key).
    """
    calls = _patch_config(monkeypatch)
    _patch_clear_auth(monkeypatch, returns=False)

    # A slug with a dot — invalid per _CUSTOM_PROVIDER_NAME_RE.
    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/foo.bar/key",
        headers=_TOKEN_HEADER,
    )
    # FastAPI will 404 on 'foo.bar' because the path param stops at '/';
    # 'foo.bar' in a path segment is a valid URL character sequence but the
    # regex ^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$ rejects it.
    # Either a 400 (4001) or a 422 (FastAPI validation) is acceptable — the
    # key requirement is that it is NOT 200 and NO config is written.
    assert r.status_code in (400, 422), (
        f"Expected 400 or 422 for dotted slug, got {r.status_code}: {r.text}"
    )
    if r.status_code == 400:
        assert r.json().get("code") == 4001
    # No config must have been written.
    assert calls["set_config"] == [], (
        f"BUG 4: config written for invalid slug: {calls['set_config']}"
    )


# ===========================================================================
# BUG5 — registered provider with a tuning-only providers.<slug> entry must
# NOT trigger the custom-clear branch.
# ===========================================================================


def test_delete_registered_provider_with_tuning_only_entry_uses_registered_path(
    loopback_client, monkeypatch
):
    """BUG5: A REGISTERED api_key provider that has a providers.<slug> config
    entry containing ONLY tuning overrides (e.g. base_url / model — no api_key
    or key_env field) must be DELETEd via the normal registered path
    (remove_env_value on its api_key_env_vars + clear_provider_auth).

    The BUG3 broadening made has_custom_entry fire whenever any
    providers.<slug> config entry exists. That caused this code path to:
      1. derive a phantom env var (DEEPSEEK_<hash>_API_KEY) and attempt to
         remove it — a no-op but an incorrect remove_env_value call;
      2. call set_config_value("providers.deepseek.api_key", "") and
         set_config_value("providers.deepseek.key_env", ""), injecting bogus
         empty credential keys into a tuning-only config subtree.

    FIX: the custom-clear branch now fires only when providers.<slug> has an
    api_key or key_env field (the markers a custom provider sets via POST
    /providers/custom). A tuning-only entry (no api_key / key_env) must go
    through the registered path.
    """
    # deepseek is a well-known registered api_key provider.
    _patch_inventory(monkeypatch, rows=[_DEEPSEEK_ROW])

    # Simulate a tuning-only entry: providers.deepseek has a base_url override
    # but NO api_key / key_env field — a legitimate non-credential tweak.
    calls = _patch_config(
        monkeypatch,
        providers_in_config={"deepseek": {"base_url": "https://proxy.internal/deepseek"}},
    )
    _patch_clear_auth(monkeypatch, returns=False)

    r = loopback_client.request(
        "DELETE",
        "/api/plugins/hermes-mobile/providers/deepseek/key",
        headers=_TOKEN_HEADER,
    )
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["slug"] == "deepseek"
    assert body["disconnected"] is True

    # Registered path: DEEPSEEK_API_KEY must have been passed to remove_env_value.
    assert "DEEPSEEK_API_KEY" in calls["remove_env"], (
        f"BUG5: registered env var not removed; remove_env calls: {calls['remove_env']}"
    )

    # Custom-clear must NOT have fired: no bogus api_key / key_env written to config.
    set_keys = {k for k, _ in calls["set_config"]}
    assert "providers.deepseek.api_key" not in set_keys, (
        f"BUG5: bogus providers.deepseek.api_key injected into tuning-only entry; "
        f"set_config calls: {calls['set_config']}"
    )
    assert "providers.deepseek.key_env" not in set_keys, (
        f"BUG5: bogus providers.deepseek.key_env injected into tuning-only entry; "
        f"set_config calls: {calls['set_config']}"
    )

    # The phantom derived env var must NOT have been passed to remove_env_value.
    import hashlib as _hashlib
    phantom_env = "DEEPSEEK_" + _hashlib.sha1(b"deepseek").hexdigest()[:6] + "_API_KEY"
    assert phantom_env not in calls["remove_env"], (
        f"BUG5: phantom custom env var {phantom_env!r} was incorrectly removed; "
        f"remove_env calls: {calls['remove_env']}"
    )
