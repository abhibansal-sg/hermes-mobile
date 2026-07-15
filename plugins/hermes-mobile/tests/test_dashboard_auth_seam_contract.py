"""Regression: the plugin's auth helpers must not delegate to removed core symbols.

ROOT CAUSE this guards against (2026-07-03 outage): the big upstream catch-up
refactored core auth out of ``hermes_cli.web_server`` and into
``hermes_cli/dashboard_auth/*``. The hermes-mobile dashboard plugin
(``plugins/hermes-mobile/dashboard/api.py``) still delegated its four auth
helpers to ``_web()._has_dashboard_api_auth`` / ``_is_device_auth`` /
``_request_device`` / ``_device_has_scope``. When those core symbols vanished,
EVERY authenticated dashboard + WebSocket call raised ``AttributeError`` -> 500,
taking down BOTH the desktop app and the mobile app at once (they share this one
plugin). The fix inlines the four helpers so the plugin owns its auth logic and
depends on core only for the stable ``_has_valid_session_token`` seam.

These tests assert:
1. The four helpers resolve and evaluate WITHOUT AttributeError against the
   current core ``web_server`` — i.e. they no longer call the removed
   ``_web()._<sym>`` internals (that call would raise the moment core drops them).
2. Device scope enforcement holds (scoped device denied a scope it lacks,
   allowed one it has; a shared-token / no-device request is unrestricted).
3. A no-credentials request in gated mode is rejected.
"""

from __future__ import annotations

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
    """The plugin dashboard api module (owns the four auth helpers)."""
    load_plugin_module("device_tokens")  # ensure plugin package is importable
    if _API_MODULE_NAME not in sys.modules:
        api_path = REPO_ROOT / "plugins" / "hermes-mobile" / "dashboard" / "api.py"
        spec = importlib.util.spec_from_file_location(_API_MODULE_NAME, api_path)
        assert spec and spec.loader, f"cannot load mobile dashboard api at {api_path}"
        mod = importlib.util.module_from_spec(spec)
        sys.modules[_API_MODULE_NAME] = mod
        spec.loader.exec_module(mod)
    return sys.modules[_API_MODULE_NAME]


def _make_request(*, auth_required=False, session=None, device=None,
                  token_authenticated=False):
    """A minimal Starlette-ish Request stub carrying only the state the helpers read.

    The helpers touch ``request.app.state.auth_required`` and
    ``request.state.{session,device,token_authenticated}`` — nothing else — so a
    stub is faithful and keeps the test free of a full ASGI app.
    """
    app = types.SimpleNamespace(state=types.SimpleNamespace(auth_required=auth_required))
    state = types.SimpleNamespace(
        session=session,
        device=device,
        token_authenticated=token_authenticated,
    )
    # ``headers`` / ``query_params`` are only consulted on the loopback fallback
    # path when it reaches core ``_has_valid_session_token``. Empty containers
    # mean "no shared token supplied" -> the fallback returns False cleanly.
    return types.SimpleNamespace(
        app=app,
        state=state,
        headers={},
        query_params={},
    )


# ---------------------------------------------------------------------------
# 1. The four helpers resolve without AttributeError (the outage signature).
# ---------------------------------------------------------------------------

def test_four_helpers_resolve_without_attributeerror(api):
    """The exact class of failure that took both apps down must not recur.

    Under the old delegating implementation these calls raised
    ``AttributeError: module 'hermes_cli.web_server' has no attribute
    '_has_dashboard_api_auth'`` the moment the core refactor landed. The inlined
    versions evaluate purely against request state, so they return cleanly.
    """
    req = _make_request(auth_required=True, device={"scopes": ["dashboard:read"]})

    # None of these may raise AttributeError against the current core web_server.
    assert api._has_dashboard_api_auth(req) is True
    assert api._is_device_auth(req) is True
    assert api._request_device(req) == {"scopes": ["dashboard:read"]}
    assert api._device_has_scope(req, "dashboard:read") is True


def test_helpers_do_not_delegate_to_removed_core_symbols(api):
    """Prove independence: helpers still work even if core drops the old symbols.

    We shadow the (currently-present) core internals with a poisoned module that
    raises on attribute access for the four removed names. If a helper still
    delegated via ``_web()._<sym>`` it would blow up here. ``_has_valid_session_token``
    stays intact because the inline fix legitimately borrows that stable seam.
    """
    from hermes_cli import web_server as real_web

    removed = {
        "_has_dashboard_api_auth",
        "_is_device_auth",
        "_request_device",
        "_device_has_scope",
    }

    class _PoisonedWeb:
        def __getattr__(self, name):
            if name in removed:
                raise AttributeError(
                    f"module 'hermes_cli.web_server' has no attribute '{name}'"
                )
            return getattr(real_web, name)

    original_web = api._web
    api._web = lambda: _PoisonedWeb()  # type: ignore[assignment]
    try:
        # Loopback path exercises _has_valid_session_token (allowed) but never
        # the removed symbols.
        loopback = _make_request(auth_required=False)
        # Should not raise AttributeError for any removed symbol.
        api._has_dashboard_api_auth(loopback)

        gated = _make_request(auth_required=True, device={"scopes": ["x"]})
        assert api._has_dashboard_api_auth(gated) is True
        assert api._is_device_auth(gated) is True
        assert api._request_device(gated) == {"scopes": ["x"]}
        assert api._device_has_scope(gated, "x") is True
    finally:
        api._web = original_web  # type: ignore[assignment]


# ---------------------------------------------------------------------------
# 2. Device scope enforcement holds (this is NOT an auth bypass).
# ---------------------------------------------------------------------------

def test_scoped_device_denied_missing_scope(api):
    req = _make_request(auth_required=True, device={"scopes": ["dashboard:read"]})
    assert api._device_has_scope(req, "dashboard:read") is True
    assert api._device_has_scope(req, "admin") is False


def test_device_with_no_scopes_denied_any_scope(api):
    req = _make_request(auth_required=True, device={"scopes": []})
    assert api._device_has_scope(req, "dashboard:read") is False


def test_shared_token_request_is_unrestricted(api):
    """A non-device (shared-token / browser) request has no scope ceiling.

    ``_request_device`` returns None, so ``_device_has_scope`` returns True for
    any scope — this preserves the legacy host-trusted behaviour and is exactly
    why the fix is not an auth bypass: scope gating only applies to device tokens.
    """
    req = _make_request(auth_required=True, session={"user": "browser"})
    assert api._request_device(req) is None
    assert api._is_device_auth(req) is False
    assert api._device_has_scope(req, "admin") is True


# ---------------------------------------------------------------------------
# 3. No-credentials rejection.
# ---------------------------------------------------------------------------

def test_no_credentials_gated_request_rejected(api):
    """Gated mode with no session/device/token attached must fail the auth gate."""
    req = _make_request(auth_required=True)  # nothing attached
    assert api._has_dashboard_api_auth(req) is False
    assert api._is_device_auth(req) is False


def test_bearer_token_authenticated_flag_accepted(api):
    """The additive ``token_authenticated`` branch admits bearer-auth requests."""
    req = _make_request(auth_required=True, token_authenticated=True)
    assert api._has_dashboard_api_auth(req) is True
