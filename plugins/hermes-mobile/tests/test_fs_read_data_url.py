"""GET /api/plugins/hermes-mobile/fs/read?format=data_url — W25 files-phase-1.

The mobile file viewer's Share / Save to Files actions need the raw bytes of a
file, including BINARY files that have no UTF-8 ``content`` form. ``format=data_url``
inlines the bytes (within the 1 MB read cap) as a ``data:<mime>;base64,…`` field,
additively — ``content``/``encoding`` are unchanged, and the field is omitted when
the param is absent.
"""

from __future__ import annotations

import base64
import sys

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

    from hermes_cli.web_server import app, _SESSION_HEADER_NAME, _SESSION_TOKEN

    c = TestClient(app)
    c.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    return c


@pytest.fixture
def live_session(monkeypatch, tmp_path):
    """Register a live gateway session whose cwd is a hermetic tmp workspace."""
    try:
        from tui_gateway import server as gw
    except Exception:  # pragma: no cover - gateway import optional in some envs
        pytest.skip("tui_gateway not importable")

    workspace = tmp_path / "workspace"
    workspace.mkdir()
    sid = "fs-read-data-url-sid"
    monkeypatch.setitem(gw._sessions, sid, {"cwd": str(workspace)})
    return sid, workspace


_PREFIX = "/api/plugins/hermes-mobile"


def test_binary_file_returns_data_url_only_with_format(client, live_session):
    sid, workspace = live_session
    payload = bytes(range(256))  # not valid UTF-8 → binary
    (workspace / "blob.bin").write_bytes(payload)

    # Without the param: binary, no bytes inlined.
    plain = client.get(f"{_PREFIX}/fs/read", params={"session_id": sid, "path": "blob.bin"})
    assert plain.status_code == 200, plain.text
    body = plain.json()
    assert body["encoding"] == "binary"
    assert body["content"] is None
    assert "data_url" not in body

    # With format=data_url: bytes inlined, decodes back to the original.
    dl = client.get(
        f"{_PREFIX}/fs/read",
        params={"session_id": sid, "path": "blob.bin", "format": "data_url"},
    )
    assert dl.status_code == 200, dl.text
    body = dl.json()
    assert body["encoding"] == "binary"
    assert body["content"] is None
    data_url = body["data_url"]
    assert data_url.startswith("data:")
    assert ";base64," in data_url
    b64 = data_url.split(";base64,", 1)[1]
    assert base64.b64decode(b64) == payload


def test_text_file_keeps_content_and_adds_data_url(client, live_session):
    sid, workspace = live_session
    text = "col_a,col_b\n1,2\n"
    (workspace / "data.csv").write_text(text)

    dl = client.get(
        f"{_PREFIX}/fs/read",
        params={"session_id": sid, "path": "data.csv", "format": "data_url"},
    )
    assert dl.status_code == 200, dl.text
    body = dl.json()
    assert body["encoding"] == "utf-8"
    assert body["content"] == text
    b64 = body["data_url"].split(";base64,", 1)[1]
    assert base64.b64decode(b64).decode("utf-8") == text


def test_missing_file_still_404s_with_format(client, live_session):
    sid, _workspace = live_session
    resp = client.get(
        f"{_PREFIX}/fs/read",
        params={"session_id": sid, "path": "nope.bin", "format": "data_url"},
    )
    assert resp.status_code == 404, resp.text
