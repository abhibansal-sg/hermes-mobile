"""GET /api/plugins/hermes-mobile/attachments/{name} — uploaded image byte serve.

The mobile app uploads bytes via ``POST /upload`` and receives a server-local
``~/.hermes/uploads/<opaque>.<ext>`` path. The chat transcript can only render a
sent-image thumbnail if the app can fetch those already-uploaded bytes back by
opaque filename, under the same dashboard-token auth gate as upload.
"""

from __future__ import annotations

import sys

import pytest

_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


@pytest.fixture
def api_module(monkeypatch, tmp_path):
    """Mounted plugin API module with hermetic HERMES_HOME."""
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


def test_attachment_fetch_returns_image_bytes_and_content_type(client, api_module, monkeypatch, tmp_path):
    upload_dir = tmp_path / "uploads"
    upload_dir.mkdir()
    name = "abcdef0123456789abcdef0123456789.png"
    image_bytes = b"\x89PNG\r\n\x1a\nthumbnail-bytes"
    (upload_dir / name).write_bytes(image_bytes)
    monkeypatch.setattr(api_module, "_UPLOAD_DIR", upload_dir)

    resp = client.get(f"/api/plugins/hermes-mobile/attachments/{name}")

    assert resp.status_code == 200, resp.text
    assert resp.content == image_bytes
    assert resp.headers["content-type"].startswith("image/png")


def test_attachment_fetch_requires_auth(api_module, monkeypatch, tmp_path):
    from starlette.testclient import TestClient
    from hermes_cli.web_server import app

    upload_dir = tmp_path / "uploads"
    upload_dir.mkdir()
    name = "abcdef0123456789abcdef0123456789.jpg"
    (upload_dir / name).write_bytes(b"jpg")
    monkeypatch.setattr(api_module, "_UPLOAD_DIR", upload_dir)

    resp = TestClient(app).get(f"/api/plugins/hermes-mobile/attachments/{name}")

    assert resp.status_code == 401


@pytest.mark.parametrize("bad_name", ["../secret.png", "..", "a/b.png", "a..b.png"])
def test_attachment_fetch_rejects_traversal_names(client, api_module, monkeypatch, tmp_path, bad_name):
    upload_dir = tmp_path / "uploads"
    upload_dir.mkdir()
    monkeypatch.setattr(api_module, "_UPLOAD_DIR", upload_dir)

    resp = client.get(f"/api/plugins/hermes-mobile/attachments/{bad_name}")

    assert resp.status_code in {400, 404}
    if resp.status_code == 400:
        assert resp.json()["detail"] == "Invalid attachment name"


def test_attachment_fetch_missing_file_404(client, api_module, monkeypatch, tmp_path):
    upload_dir = tmp_path / "uploads"
    upload_dir.mkdir()
    monkeypatch.setattr(api_module, "_UPLOAD_DIR", upload_dir)

    resp = client.get("/api/plugins/hermes-mobile/attachments/missing.png")

    assert resp.status_code == 404
