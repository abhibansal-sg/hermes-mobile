"""Regression coverage for bounded hermes-mobile debug-share requests."""

from __future__ import annotations

import sys
import time

import pytest

_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


@pytest.fixture
def api_module(monkeypatch, tmp_path):
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    from hermes_cli import web_server

    if _API_MODULE_NAME not in sys.modules:
        web_server._get_dashboard_plugins(force_rescan=True)
        web_server._mount_plugin_api_routes()
    return sys.modules[_API_MODULE_NAME]


@pytest.fixture
def client(api_module):
    try:
        from starlette.testclient import TestClient
    except ImportError:
        pytest.skip("fastapi/starlette not installed")

    from hermes_cli.web_server import _SESSION_HEADER_NAME, _SESSION_TOKEN, app

    c = TestClient(app)
    c.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    return c


def test_debug_share_timeout_returns_422(client, api_module, monkeypatch):
    monkeypatch.setattr(api_module, "_has_dashboard_api_auth", lambda _request: True)
    monkeypatch.setattr(api_module, "_device_has_scope", lambda _request, _scope: True)
    monkeypatch.setattr(api_module, "_DEBUG_SHARE_ROUTE_BUDGET_S", 0.01)

    def _slow_build_debug_share(*args, **kwargs):
        time.sleep(0.2)
        raise AssertionError("route should time out before upload completes")

    monkeypatch.setattr(api_module, "build_debug_share", _slow_build_debug_share)

    response = client.post("/api/plugins/hermes-mobile/debug-share")

    assert response.status_code == 422
    assert "did not finish within" in response.json()["detail"]
