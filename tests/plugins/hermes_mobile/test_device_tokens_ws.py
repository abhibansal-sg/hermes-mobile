"""W3A-S — WS device-token acceptance end-to-end through the real plugin
registry, plus the live-WS-cut socket index.

Moved from ``tests/hermes_cli/test_device_tokens_ws.py`` in the ABH-88
de-patch (W2b): the device-token registry now lives in
``plugins/hermes-mobile/device_tokens.py`` and is only consulted by
``web_server`` once the plugin wires it into the
``hermes_cli.dashboard_auth.token_auth`` seam — hence ``wired_token_auth`` on
every test that sends a device token through the gates. The seam-shape tests
(fake authenticators) stayed behind in
``tests/hermes_cli/test_device_tokens_ws.py``.

MIGRATION SAFETY FIRST: the shared ``?token=`` still passes _ws_auth_ok
unchanged, with and without device tokens issued. The device branch is purely
additive — it can only ACCEPT an extra credential, never reject the shared
token. These exercise _ws_auth_ok at the unit level (the starlette TestClient
WS path has a pre-existing regression unrelated to this work, per the
existing test_dashboard_auth_ws_auth.py note) plus the live-cut index
directly.
"""

from __future__ import annotations

from types import SimpleNamespace
from urllib.parse import urlencode

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from hermes_cli import web_server
from tests.plugins.hermes_mobile.conftest import load_plugin_module

device_tokens = load_plugin_module("device_tokens")

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    yield tmp_path
    device_tokens._reset_for_tests()


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


@pytest.fixture
def dashboard_ws_enabled(monkeypatch, loopback):
    monkeypatch.setattr(web_server, "_DASHBOARD_EMBEDDED_CHAT_ENABLED", True)
    client = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    try:
        yield client
    finally:
        close = getattr(client, "close", None)
        if close is not None:
            close()


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


def _ws_url(path: str, token: str, **params: str) -> str:
    return f"{path}?{urlencode({'token': token, **params})}"


_WS_HEADERS = {"host": "127.0.0.1:8080", "origin": "http://127.0.0.1:8080"}


def _revoke_device(client: TestClient, device_id: str) -> dict:
    r = client.delete(
        f"/api/plugins/hermes-mobile/devices/{device_id}",
        headers={"X-Hermes-Session-Token": web_server._SESSION_TOKEN},
    )
    assert r.status_code == 200
    return r.json()


# ===========================================================================
# LEGACY-TOKEN REGRESSION — runs first.
# ===========================================================================


def test_aab_shared_token_still_passes_after_device_issued(
    loopback, home, wired_token_auth
):
    device_tokens.issue(device_name="x")
    ws = _fake_ws(query={"token": web_server._SESSION_TOKEN})
    assert web_server._ws_auth_ok(ws) is True


# ===========================================================================
# Device-token WS acceptance + stash + revoke
# ===========================================================================


def test_device_token_passes_ws_auth_and_stashes_identity(
    loopback, home, wired_token_auth
):
    issued = device_tokens.issue(device_name="My Phone")
    ws = _fake_ws(query={"token": issued["token"]})
    assert web_server._ws_auth_ok(ws) is True
    # Identity stashed on the connection state for the audit + live-cut paths.
    assert ws.state.device["device_id"] == issued["device_id"]
    assert ws.state.device["device_name"] == "My Phone"
    assert ws.state.device["token_prefix"] == issued["token"][:8]


def test_device_token_not_accepted_without_wiring(loopback, home):
    """KEY de-patch behavior: with the plugin NOT wired into the token-auth
    seam, a freshly issued device token is just an unknown token."""
    from hermes_cli.dashboard_auth import token_auth

    before = (
        list(token_auth.TOKEN_AUTHENTICATORS),
        list(token_auth.IDENTITY_VALIDATORS),
        list(token_auth.SOCKET_OBSERVERS),
    )
    token_auth.TOKEN_AUTHENTICATORS[:] = []
    token_auth.IDENTITY_VALIDATORS[:] = []
    token_auth.SOCKET_OBSERVERS[:] = []
    try:
        issued = device_tokens.issue(device_name="x")
        ws = _fake_ws(query={"token": issued["token"]})
        assert web_server._ws_auth_ok(ws) is False
    finally:
        token_auth.TOKEN_AUTHENTICATORS[:] = before[0]
        token_auth.IDENTITY_VALIDATORS[:] = before[1]
        token_auth.SOCKET_OBSERVERS[:] = before[2]


def test_revoked_device_token_fails_ws_auth(loopback, home, wired_token_auth):
    issued = device_tokens.issue(device_name="x")
    ws = _fake_ws(query={"token": issued["token"]})
    assert web_server._ws_auth_ok(ws) is True
    device_tokens.revoke(issued["device_id"])
    ws2 = _fake_ws(query={"token": issued["token"]})
    assert web_server._ws_auth_ok(ws2) is False


# ===========================================================================
# Live-WS-cut index
# ===========================================================================


def test_index_register_deregister(home):
    sock = object()
    device_tokens.register_ws_socket("dev_1", sock)
    assert device_tokens.get_device_sockets("dev_1") == [sock]
    device_tokens.deregister_ws_socket("dev_1", sock)
    assert device_tokens.get_device_sockets("dev_1") == []
    # Idempotent deregister.
    device_tokens.deregister_ws_socket("dev_1", sock)


def test_shared_token_socket_is_never_indexed(home):
    # A device with no live socket → empty index → revoke closes nothing.
    issued = device_tokens.issue(device_name="x")
    assert device_tokens.get_device_sockets(issued["device_id"]) == []


def test_revoke_endpoint_closes_live_socket_with_4401(loopback, home):
    """DELETE /api/plugins/hermes-mobile/devices/{id} (the revoke route's
    post-de-patch home) closes a registered live socket with 4401 and
    reports sockets_closed >= 1. TestClient drives the async route on its own
    loop, so the awaited ws.close() runs."""
    from fastapi.testclient import TestClient

    issued = device_tokens.issue(device_name="x")

    closed = {}

    class _FakeWS:
        async def close(self, code=1000, reason=""):
            closed["code"] = code
            closed["reason"] = reason

    sock = _FakeWS()
    device_tokens.register_ws_socket(issued["device_id"], sock)

    client = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    r = client.delete(
        f"/api/plugins/hermes-mobile/devices/{issued['device_id']}",
        headers={"X-Hermes-Session-Token": web_server._SESSION_TOKEN},
    )
    assert r.status_code == 200
    body = r.json()
    assert body["revoked"] is True
    assert body["sockets_closed"] == 1
    assert closed["code"] == 4401
    assert closed["reason"] == "device revoked"
    # Socket deregistered after the cut.
    assert device_tokens.get_device_sockets(issued["device_id"]) == []


def test_console_device_token_socket_is_live_cut_and_deregistered(
    dashboard_ws_enabled, home, wired_token_auth
):
    issued = device_tokens.issue(device_name="console")

    with dashboard_ws_enabled.websocket_connect(
        _ws_url("/api/console", issued["token"]),
        headers=_WS_HEADERS,
    ) as conn:
        ready = conn.receive_json()
        assert ready["type"] == "ready"
        assert len(device_tokens.get_device_sockets(issued["device_id"])) == 1

        body = _revoke_device(dashboard_ws_enabled, issued["device_id"])
        assert body["revoked"] is True
        assert body["sockets_closed"] == 1

        with pytest.raises(WebSocketDisconnect) as exc:
            conn.receive_json()
        assert exc.value.code == 4401

    assert device_tokens.get_device_sockets(issued["device_id"]) == []


@pytest.mark.parametrize(
    ("path", "reader"),
    [
        ("/api/pub", "text"),
        ("/api/events", "text"),
    ],
)
def test_pub_events_device_token_socket_is_live_cut_and_deregistered(
    dashboard_ws_enabled, home, wired_token_auth, path, reader
):
    issued = device_tokens.issue(device_name=path.rsplit("/", 1)[-1])

    with dashboard_ws_enabled.websocket_connect(
        _ws_url(path, issued["token"], channel="mobile-live-cut"),
        headers=_WS_HEADERS,
    ) as conn:
        assert len(device_tokens.get_device_sockets(issued["device_id"])) == 1

        body = _revoke_device(dashboard_ws_enabled, issued["device_id"])
        assert body["revoked"] is True
        assert body["sockets_closed"] == 1

        with pytest.raises(WebSocketDisconnect) as exc:
            if reader == "text":
                conn.receive_text()
        assert exc.value.code == 4401

    assert device_tokens.get_device_sockets(issued["device_id"]) == []


def test_shared_token_pub_socket_is_not_indexed_or_cut(
    dashboard_ws_enabled, home, wired_token_auth
):
    issued = device_tokens.issue(device_name="shared-control")

    with dashboard_ws_enabled.websocket_connect(
        _ws_url("/api/pub", web_server._SESSION_TOKEN, channel="shared-token"),
        headers=_WS_HEADERS,
    ) as conn:
        assert device_tokens.get_device_sockets(issued["device_id"]) == []

        body = _revoke_device(dashboard_ws_enabled, issued["device_id"])
        assert body["revoked"] is True
        assert body["sockets_closed"] == 0

        conn.send_text('{"type":"still-open"}')

    assert device_tokens.get_device_sockets(issued["device_id"]) == []


def test_events_missing_channel_does_not_leak_device_socket(
    dashboard_ws_enabled, home, wired_token_auth
):
    issued = device_tokens.issue(device_name="missing-channel")

    with pytest.raises(WebSocketDisconnect) as exc:
        with dashboard_ws_enabled.websocket_connect(
            _ws_url("/api/events", issued["token"]),
            headers=_WS_HEADERS,
        ):
            pass
    assert exc.value.code == 4400
    assert device_tokens.get_device_sockets(issued["device_id"]) == []
