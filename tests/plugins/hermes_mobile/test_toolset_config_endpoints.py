"""ABH-224 — mobile plugin toolset credential routes.

Tests the additive hermes-mobile plugin routes:

* ``GET /toolsets/{name}/config`` — provider matrix + env-var is_set state
* ``PUT /toolsets/{name}/config`` — set/clear a provider env-var credential

The handlers mirror the desktop toolset-config panel but stay plugin-only.
Stock config/toolset helpers are monkeypatched so the tests never need a live
Hermes gateway, real ~/.hermes/.env writes, Nous subscription state, or a
managed-install marker.
"""

from __future__ import annotations

import os

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"
_TOKEN_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}
_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


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


def _api():
    """The live dashboard api module the plugin routes are mounted from."""
    import sys

    return sys.modules[_API_MODULE_NAME]


_KAGI_PROVIDER = {
    "name": "Kagi",
    "badge": "paid",
    "tag": "Search API",
    "env_vars": [
        {
            "key": "KAGI_API_KEY",
            "prompt": "Kagi API key",
            "url": "https://kagi.com/settings?p=api",
        }
    ],
    "web_backend": "kagi",
}
_NO_KEY_PROVIDER = {
    "name": "DuckDuckGo",
    "badge": "free",
    "tag": "No API key needed",
    "env_vars": [],
    "web_backend": "duckduckgo",
}


def _patch_toolset_helpers(
    monkeypatch,
    *,
    providers=None,
    env=None,
    active_provider="Kagi",
    managed=False,
):
    """Patch stock toolset/config helpers and capture mutator dispatch."""
    import copy

    import hermes_cli.config as config
    import hermes_cli.tools_config as tools_config

    env_state = dict(env or {})
    rows = copy.deepcopy(providers or [_KAGI_PROVIDER, _NO_KEY_PROVIDER])
    calls = {
        "visible": [],
        "active": [],
        "save_env": [],
        "remove_env": [],
        "managed": managed,
        "env": env_state,
    }

    def _effective_toolsets():
        return [("web", "Web Search & Scraping", "web_search, web_extract")]

    def _visible(cat, cfg, *, force_fresh=False):
        calls["visible"].append(
            {"cat": copy.deepcopy(cat), "config": copy.deepcopy(cfg), "force_fresh": force_fresh}
        )
        return copy.deepcopy(rows)

    def _is_active(provider, cfg, *, force_fresh=False):
        calls["active"].append(
            {"provider": provider.get("name"), "force_fresh": force_fresh}
        )
        return provider.get("name") == active_provider

    def _load_config():
        return {"web": {"backend": "kagi"}}

    def _get_env(key):
        return env_state.get(key)

    def _save_env(key, value):
        calls["save_env"].append((key, value))
        env_state[key] = value

    def _remove_env(key):
        calls["remove_env"].append(key)
        env_state.pop(key, None)
        return True

    def _is_managed():
        return calls["managed"]

    monkeypatch.setattr(
        tools_config,
        "TOOL_CATEGORIES",
        {"web": {"name": "Web Search & Extract", "providers": []}},
    )
    monkeypatch.setattr(
        tools_config, "_get_effective_configurable_toolsets", _effective_toolsets
    )
    monkeypatch.setattr(tools_config, "_visible_providers", _visible)
    monkeypatch.setattr(tools_config, "_is_provider_active", _is_active)
    monkeypatch.setattr(config, "load_config", _load_config)
    monkeypatch.setattr(config, "get_env_value", _get_env)
    monkeypatch.setattr(config, "save_env_value", _save_env)
    monkeypatch.setattr(config, "remove_env_value", _remove_env)
    monkeypatch.setattr(config, "is_managed", _is_managed)
    monkeypatch.delenv("KAGI_API_KEY", raising=False)
    return calls


# ===========================================================================
# Auth gating
# ===========================================================================


def test_get_toolset_config_requires_token(loopback_client, monkeypatch):
    _patch_toolset_helpers(monkeypatch)

    r = loopback_client.get(f"{_PREFIX}/toolsets/web/config")

    assert r.status_code == 401


def test_put_toolset_config_requires_token(loopback_client, monkeypatch):
    _patch_toolset_helpers(monkeypatch)

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/web/config",
        json={"key": "KAGI_API_KEY", "value": "sk-secret"},
    )

    assert r.status_code == 401


def test_put_toolset_config_device_without_approve_scope_is_403(
    loopback_client, monkeypatch
):
    _patch_toolset_helpers(monkeypatch)
    monkeypatch.setattr(_api(), "_has_dashboard_api_auth", lambda _request: True)
    monkeypatch.setattr(_api(), "_device_has_scope", lambda _request, _scope: False)

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/web/config",
        json={"key": "KAGI_API_KEY", "value": "sk-secret"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 403


# ===========================================================================
# GET /toolsets/{name}/config
# ===========================================================================


def test_get_toolset_config_returns_is_set_matrix_without_secret(
    loopback_client, monkeypatch
):
    calls = _patch_toolset_helpers(
        monkeypatch, env={"KAGI_API_KEY": "sk-kagi-secret"}
    )

    r = loopback_client.get(f"{_PREFIX}/toolsets/web/config", headers=_TOKEN_HEADER)

    assert r.status_code == 200, r.text
    assert calls["visible"] and calls["visible"][0]["force_fresh"] is True
    body = r.json()
    assert body == {
        "name": "web",
        "has_category": True,
        "providers": [
            {
                "name": "Kagi",
                "badge": "paid",
                "tag": "Search API",
                "env_vars": [
                    {
                        "key": "KAGI_API_KEY",
                        "prompt": "Kagi API key",
                        "url": "https://kagi.com/settings?p=api",
                        "default": None,
                        "is_set": True,
                    }
                ],
                "post_setup": None,
                "requires_nous_auth": False,
                "is_active": True,
            },
            {
                "name": "DuckDuckGo",
                "badge": "free",
                "tag": "No API key needed",
                "env_vars": [],
                "post_setup": None,
                "requires_nous_auth": False,
                "is_active": False,
            },
        ],
        "active_provider": "Kagi",
    }
    assert "sk-kagi-secret" not in r.text


def test_get_toolset_config_unknown_toolset_is_4002(loopback_client, monkeypatch):
    _patch_toolset_helpers(monkeypatch)

    r = loopback_client.get(f"{_PREFIX}/toolsets/nope/config", headers=_TOKEN_HEADER)

    assert r.status_code == 400
    assert r.json()["code"] == 4002


# ===========================================================================
# PUT /toolsets/{name}/config
# ===========================================================================


def test_put_toolset_config_rejects_managed_installs_4006(
    loopback_client, monkeypatch
):
    calls = _patch_toolset_helpers(monkeypatch, managed=True)

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/web/config",
        json={"key": "KAGI_API_KEY", "value": "sk-secret"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 400
    assert r.json()["code"] == 4006
    assert calls["save_env"] == []
    assert calls["remove_env"] == []


def test_put_toolset_config_unknown_toolset_is_4002(loopback_client, monkeypatch):
    _patch_toolset_helpers(monkeypatch)

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/nope/config",
        json={"key": "KAGI_API_KEY", "value": "sk-secret"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 400
    assert r.json()["code"] == 4002


def test_put_toolset_config_requires_key_4001(loopback_client, monkeypatch):
    _patch_toolset_helpers(monkeypatch)

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/web/config",
        json={"value": "sk-secret"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 400
    assert r.json()["code"] == 4001


def test_put_toolset_config_rejects_key_outside_toolset_4001(
    loopback_client, monkeypatch
):
    calls = _patch_toolset_helpers(monkeypatch)

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/web/config",
        json={"key": "UNRELATED_API_KEY", "value": "sk-secret"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 400
    assert r.json()["code"] == 4001
    assert calls["save_env"] == []


def test_put_toolset_config_sets_env_and_returns_refreshed_safe_row(
    loopback_client, monkeypatch
):
    calls = _patch_toolset_helpers(monkeypatch)

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/web/config",
        json={"key": "KAGI_API_KEY", "value": "sk-kagi-secret"},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 200, r.text
    assert calls["save_env"] == [("KAGI_API_KEY", "sk-kagi-secret")]
    assert os.environ.get("KAGI_API_KEY") == "sk-kagi-secret"
    body = r.json()
    assert body["name"] == "web"
    assert body["providers"][0]["env_vars"][0]["is_set"] is True
    assert "sk-kagi-secret" not in r.text


def test_put_toolset_config_clears_env_and_returns_refreshed_safe_row(
    loopback_client, monkeypatch
):
    monkeypatch.setenv("KAGI_API_KEY", "sk-old-secret")
    calls = _patch_toolset_helpers(
        monkeypatch, env={"KAGI_API_KEY": "sk-old-secret"}
    )

    r = loopback_client.put(
        f"{_PREFIX}/toolsets/web/config",
        json={"key": "KAGI_API_KEY", "value": ""},
        headers=_TOKEN_HEADER,
    )

    assert r.status_code == 200, r.text
    assert calls["remove_env"] == ["KAGI_API_KEY"]
    assert "KAGI_API_KEY" not in os.environ
    body = r.json()
    assert body["providers"][0]["env_vars"][0]["is_set"] is False
    assert "sk-old-secret" not in r.text
