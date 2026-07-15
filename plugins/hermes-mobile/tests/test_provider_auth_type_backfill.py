"""Provider rows keep their provisioning auth_type after authentication.

ABH-268 regression: stock inventory only stamped auth_type on unauthenticated
skeleton rows. Authenticated registered api_key providers (e.g. anthropic) then
serialized to iOS with auth_type:"", making ProviderListView treat taps as a
no-op instead of reopening the key form for rotation.
"""

from __future__ import annotations

import asyncio
import importlib.util
import sys
import types
from pathlib import Path

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

REPO_ROOT = Path(__file__).resolve().parents[3]
_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


@pytest.fixture
def api():
    """The plugin dashboard api module."""
    load_plugin_module("device_tokens")  # ensure plugin package is importable
    if _API_MODULE_NAME not in sys.modules:
        api_path = REPO_ROOT / "plugins" / "hermes-mobile" / "dashboard" / "api.py"
        spec = importlib.util.spec_from_file_location(_API_MODULE_NAME, api_path)
        assert spec and spec.loader, f"cannot load mobile dashboard api at {api_path}"
        mod = importlib.util.module_from_spec(spec)
        sys.modules[_API_MODULE_NAME] = mod
        spec.loader.exec_module(mod)
    return sys.modules[_API_MODULE_NAME]


def _make_request():
    return types.SimpleNamespace(
        app=types.SimpleNamespace(state=types.SimpleNamespace(auth_required=True)),
        state=types.SimpleNamespace(
            session=None,
            device={"scopes": ["approve"]},
            token_authenticated=True,
        ),
        headers={},
        query_params={},
    )


def test_authenticated_registered_api_key_provider_serializes_auth_type(api, monkeypatch):
    """An authenticated anthropic row missing inventory auth_type is backfilled.

    This exercises the mobile serialization path, not just the raw helper: iOS
    receives auth_type=="api_key" so ProviderAuthType(rawValue:) succeeds and
    canProvision stays true for tap-to-rotate.
    """
    from hermes_cli import inventory
    from hermes_cli.auth import PROVIDER_REGISTRY

    assert PROVIDER_REGISTRY["anthropic"].auth_type == "api_key"

    def fake_build_models_payload(ctx, **kwargs):
        assert kwargs["picker_hints"] is True
        assert kwargs["include_unconfigured"] is True
        return {
            "providers": [
                {
                    "slug": "anthropic",
                    "name": "Anthropic",
                    "authenticated": True,
                    "models": [{"id": "claude-sonnet"}],
                    "total_models": 1,
                    # Deliberately no auth_type: this is the ABH-268 bug shape.
                }
            ]
        }

    monkeypatch.setattr(inventory, "load_picker_context", lambda: object())
    monkeypatch.setattr(inventory, "build_models_payload", fake_build_models_payload)
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: True)
    monkeypatch.setattr(api, "_device_has_scope", lambda request, scope: True)

    result = asyncio.run(api.list_providers(_make_request()))

    assert result == {
        "providers": [
            {
                "slug": "anthropic",
                "name": "Anthropic",
                "auth_type": "api_key",
                "is_current": False,
                "authenticated": True,
                "total_models": 1,
            }
        ]
    }
