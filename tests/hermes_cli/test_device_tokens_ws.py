"""W3A-S → ABH-88 de-patch (W2b) — the WS token-auth SEAM in web_server.

This file now covers the SEAM SHAPE only: ``_ws_auth_ok``'s additive
``?token=`` OR-branch, the ``_ws_token_identity`` / ``_ws_active_identity``
helpers, and registry-miss fall-through — exercised with FAKE authenticators
and validators registered directly in
``hermes_cli.dashboard_auth.token_auth``. The end-to-end device-registry
flows (issue → WS accept → revoke → live-cut, plus the socket index) moved to
``tests/plugins/hermes_mobile/test_device_tokens_ws.py``.

MIGRATION SAFETY FIRST: the shared ``?token=`` still passes _ws_auth_ok
unchanged, with and without authenticators registered. The token-registry
branch is purely additive — it can only ACCEPT an extra credential, never
reject the shared token. These exercise _ws_auth_ok at the unit level (the
starlette TestClient WS path has a pre-existing regression unrelated to this
work, per the existing test_dashboard_auth_ws_auth.py note).
"""

from __future__ import annotations

from types import SimpleNamespace

import pytest

from hermes_cli import web_server
from hermes_cli.dashboard_auth import token_auth

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_FAKE_TOKEN = "fake-device-token-abcdefgh"
_FAKE_IDENTITY = {
    "device_id": "dev_fake1",
    "device_name": "My Phone",
    "token_prefix": _FAKE_TOKEN[:8],
}


@pytest.fixture
def clean_registries():
    """Snapshot + restore the token_auth seam registries around each test."""
    before = (
        list(token_auth.TOKEN_AUTHENTICATORS),
        list(token_auth.IDENTITY_VALIDATORS),
        list(token_auth.SOCKET_OBSERVERS),
    )
    yield
    token_auth.TOKEN_AUTHENTICATORS[:] = before[0]
    token_auth.IDENTITY_VALIDATORS[:] = before[1]
    token_auth.SOCKET_OBSERVERS[:] = before[2]


@pytest.fixture
def fake_auth(clean_registries):
    """Register a fake authenticator/validator pair for _FAKE_TOKEN.

    Yields the ``revoked`` set: adding a device_id to it makes the validator
    report the identity inactive (the seam-level analogue of revocation).
    """
    revoked: set = set()

    def _authenticate(token):
        if token == _FAKE_TOKEN:
            return dict(_FAKE_IDENTITY)
        return None

    def _validate(identity):
        return identity.get("device_id") not in revoked

    token_auth.TOKEN_AUTHENTICATORS.append(_authenticate)
    token_auth.IDENTITY_VALIDATORS.append(_validate)
    yield revoked


@pytest.fixture
def loopback():
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    yield
    web_server.app.state.bound_host = prev_host
    web_server.app.state.auth_required = prev_required


def _fake_ws(*, query: dict, client_host: str = "127.0.0.1", path: str = "/api/ws"):
    """Stand-in for starlette.WebSocket good enough for _ws_auth_ok, WITH a
    mutable ``.state`` so the device-token stash can be asserted."""

    class _QP:
        def __init__(self, q):
            self._q = q

        def get(self, k, default=""):
            return self._q.get(k, default)

    return SimpleNamespace(
        query_params=_QP(query),
        client=SimpleNamespace(host=client_host),
        url=SimpleNamespace(path=path),
        state=SimpleNamespace(),
    )


# ===========================================================================
# LEGACY-TOKEN REGRESSION — runs first.
# ===========================================================================


def test_aaa_shared_token_still_passes_ws_auth(loopback):
    ws = _fake_ws(query={"token": web_server._SESSION_TOKEN})
    assert web_server._ws_auth_ok(ws) is True


def test_aab_shared_token_still_passes_with_authenticator_registered(
    loopback, fake_auth
):
    ws = _fake_ws(query={"token": web_server._SESSION_TOKEN})
    assert web_server._ws_auth_ok(ws) is True


def test_aac_wrong_token_still_rejected(loopback):
    ws = _fake_ws(query={"token": "not-a-token"})
    assert web_server._ws_auth_ok(ws) is False


# ===========================================================================
# Seam shape: registered-token acceptance + identity stash + validators
# ===========================================================================


def test_registered_token_passes_ws_auth_and_stashes_identity(loopback, fake_auth):
    ws = _fake_ws(query={"token": _FAKE_TOKEN})
    assert web_server._ws_auth_ok(ws) is True
    # Identity stashed on the connection state for the audit + live-cut paths.
    assert ws.state.device["device_id"] == _FAKE_IDENTITY["device_id"]
    assert ws.state.device["device_name"] == "My Phone"
    assert ws.state.device["token_prefix"] == _FAKE_TOKEN[:8]


def test_registry_miss_falls_through_to_reject(loopback, fake_auth):
    # An authenticator IS registered, but the token matches nothing — the
    # branch falls through to the same rejection as before the seam existed.
    ws = _fake_ws(query={"token": "some-other-token"})
    assert web_server._ws_auth_ok(ws) is False


def test_authenticator_exception_is_swallowed(loopback, clean_registries):
    def _broken(token):
        raise RuntimeError("boom")

    def _good(token):
        return dict(_FAKE_IDENTITY) if token == _FAKE_TOKEN else None

    token_auth.TOKEN_AUTHENTICATORS.append(_broken)
    token_auth.TOKEN_AUTHENTICATORS.append(_good)
    # The broken authenticator neither crashes the gate nor blocks the next one.
    assert web_server._ws_auth_ok(_fake_ws(query={"token": _FAKE_TOKEN})) is True
    # ...and the shared token is untouched by the broken authenticator.
    assert (
        web_server._ws_auth_ok(_fake_ws(query={"token": web_server._SESSION_TOKEN}))
        is True
    )


def test_no_authenticators_means_no_extra_acceptance(loopback, clean_registries):
    """KEY behavioral point of the de-patch: with nothing wired, a would-be
    device token is just an unknown token."""
    token_auth.TOKEN_AUTHENTICATORS[:] = []
    ws = _fake_ws(query={"token": _FAKE_TOKEN})
    assert web_server._ws_auth_ok(ws) is False


def test_ws_token_identity_helper_returns_none_for_shared(loopback, fake_auth):
    # The helper itself never matches the shared token (it's not a registry
    # token), even with an authenticator registered.
    assert web_server._ws_token_identity(web_server._SESSION_TOKEN) is None
    assert web_server._ws_token_identity("") is None
    # ...while a registered token resolves to its identity dict.
    identity = web_server._ws_token_identity(_FAKE_TOKEN)
    assert identity is not None
    assert identity["device_id"] == _FAKE_IDENTITY["device_id"]


# ===========================================================================
# _ws_active_identity + _close_if_ws_device_revoked (validator seam)
# ===========================================================================


def test_ws_active_identity_returns_dict_while_valid(loopback, fake_auth):
    ws = _fake_ws(query={"token": _FAKE_TOKEN})
    assert web_server._ws_auth_ok(ws) is True
    active = web_server._ws_active_identity(ws)
    assert isinstance(active, dict)
    assert active["device_id"] == _FAKE_IDENTITY["device_id"]


def test_ws_active_identity_none_for_shared_token_socket(loopback, fake_auth):
    # Shared-token sockets carry no ws.state.device → never an active identity.
    ws = _fake_ws(query={"token": web_server._SESSION_TOKEN})
    assert web_server._ws_auth_ok(ws) is True
    assert web_server._ws_active_identity(ws) is None


@pytest.mark.asyncio
async def test_revoked_identity_cuts_socket_with_4401(loopback, fake_auth):
    revoked = fake_auth
    ws = _fake_ws(query={"token": _FAKE_TOKEN})
    assert web_server._ws_auth_ok(ws) is True

    closed = {}

    async def close(code=1000, reason=""):
        closed["code"] = code
        closed["reason"] = reason

    ws.close = close

    # Still active → no cut.
    assert await web_server._close_if_ws_device_revoked(ws) is False
    assert closed == {}

    # Validator now reports the identity revoked → active None → 4401 cut.
    revoked.add(_FAKE_IDENTITY["device_id"])
    assert web_server._ws_active_identity(ws) is None
    assert await web_server._close_if_ws_device_revoked(ws) is True
    assert closed == {"code": 4401, "reason": "device revoked"}


@pytest.mark.asyncio
async def test_close_if_revoked_is_noop_for_shared_token_socket(loopback, fake_auth):
    ws = _fake_ws(query={"token": web_server._SESSION_TOKEN})
    assert web_server._ws_auth_ok(ws) is True
    # No ws.state.device → never closed, even with validators registered.
    assert await web_server._close_if_ws_device_revoked(ws) is False
