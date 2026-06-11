"""POST /api/plugins/hermes-mobile/upload — attachment upload bridge.

Moved from ``tests/hermes_cli/test_web_server.py`` in the ABH-88 de-patch
(W1): the handler body moved verbatim to
``plugins/hermes-mobile/dashboard/api.py``, mounted at
``/api/plugins/hermes-mobile/`` by ``web_server._mount_plugin_api_routes()``
at import time. The upload knobs (``_UPLOAD_DIR``,
``_MAX_ATTACHMENT_UPLOAD_BYTES``) now live on the plugin api module
(``sys.modules["hermes_dashboard_plugin_hermes-mobile"]``).
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest


@pytest.fixture
def api_module():
    """The mounted plugin api module (importing web_server mounts it)."""
    from hermes_cli import web_server  # noqa: F401 — triggers the mount

    return sys.modules["hermes_dashboard_plugin_hermes-mobile"]


@pytest.fixture
def client(_isolate_hermes_home):
    try:
        from starlette.testclient import TestClient
    except ImportError:
        pytest.skip("fastapi/starlette not installed")

    from hermes_cli.web_server import app, _SESSION_HEADER_NAME, _SESSION_TOKEN

    c = TestClient(app)
    c.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    return c


def test_upload_attachment_succeeds_under_cap(
    client, api_module, monkeypatch, tmp_path
):
    upload_dir = tmp_path / "uploads"
    monkeypatch.setattr(api_module, "_UPLOAD_DIR", upload_dir)
    monkeypatch.setattr(api_module, "_MAX_ATTACHMENT_UPLOAD_BYTES", 16)

    resp = client.post(
        "/api/plugins/hermes-mobile/upload",
        files={"file": ("sample.png", b"abc", "image/png")},
    )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["size"] == 3
    stored = Path(body["path"])
    assert stored.parent == upload_dir
    assert stored.read_bytes() == b"abc"


def test_upload_attachment_rejects_over_cap_without_storing(
    client, api_module, monkeypatch, tmp_path
):
    upload_dir = tmp_path / "uploads"
    monkeypatch.setattr(api_module, "_UPLOAD_DIR", upload_dir)
    monkeypatch.setattr(api_module, "_MAX_ATTACHMENT_UPLOAD_BYTES", 4)

    resp = client.post(
        "/api/plugins/hermes-mobile/upload",
        files={"file": ("sample.png", b"abcde", "image/png")},
    )

    assert resp.status_code == 413
    assert not upload_dir.exists()
