"""GET /api/plugins/hermes-mobile/projects — read-only projects overview.

Mirrors the desktop's projects tab by proxying the gateway's
``_discover_repos_payload`` and reshaping to ``{id, label, root,
session_count}``. These tests assert the three acceptance contracts:

1. Auth-enforced — 401 without a session token.
2. Sane shape — every entry has exactly the four contract keys with the
   right types.
3. Junk-filtered — ~/.hermes and the bare home dir never surface, even
   when the upstream payload accidentally includes them.
"""

from __future__ import annotations

import sys
from pathlib import Path

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


def _patch_discover(monkeypatch, repos):
    """Make the gateway proxy return *repos* without touching real state.db."""
    import tui_gateway.server as tgs

    def _fake(db, *, conn=None, backfill=True):
        return repos

    monkeypatch.setattr(tgs, "_discover_repos_payload", _fake)
    # SessionDB instantiation should never reach disk in these tests.
    monkeypatch.setattr(
        "hermes_state.SessionDB", lambda *a, **kw: object(), raising=False
    )


def test_projects_requires_auth(api_module, monkeypatch, tmp_path):
    """No session token → 401 (same belt-and-suspenders as other routes).

    Uses the ``api_module`` fixture (not a bare ``TestClient``) so the plugin
    routes are mounted against the isolated HERMES_HOME — without this, the
    module-level ``_mount_plugin_api_routes()`` at web_server import time
    runs against the real profile config and the disabled-plugin gate drops
    the route, yielding a false 404 instead of the expected 401.
    """
    from starlette.testclient import TestClient

    from hermes_cli.web_server import app

    _patch_discover(monkeypatch, [])
    resp = TestClient(app).get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 401


def test_projects_shape_and_mapping(client, monkeypatch):
    """Each entry has exactly {id, label, root, session_count} with correct
    types, and session_count maps from the upstream ``sessions`` field."""
    _patch_discover(
        monkeypatch,
        [
            {
                "root": "/Users/alice/code/widget-app",
                "label": "widget-app",
                "sessions": 7,
                "last_active": 1700000000.0,
            },
            {
                "root": "/srv/empty-repo",
                "label": "",
                "sessions": 0,
                "last_active": 0.0,
            },
        ],
    )

    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert isinstance(data, list)
    assert len(data) == 2

    for entry in data:
        assert set(entry.keys()) == {"id", "label", "root", "session_count"}
        assert isinstance(entry["id"], str) and entry["id"]
        assert isinstance(entry["label"], str) and entry["label"]
        assert isinstance(entry["root"], str) and entry["root"]
        assert isinstance(entry["session_count"], int)

    # session_count maps from upstream ``sessions``.
    by_root = {e["root"]: e for e in data}
    assert by_root["/Users/alice/code/widget-app"]["session_count"] == 7
    assert by_root["/srv/empty-repo"]["session_count"] == 0
    # empty-label upstream → label falls back to basename.
    assert by_root["/srv/empty-repo"]["label"] == "empty-repo"


def test_projects_junk_filtered(client, monkeypatch, tmp_path):
    """~/.hermes subtree and bare home never surface, even if upstream leaks.

    The junk filter compares against ``HERMES_HOME`` (isolated to a temp dir
    by the conftest) and the real ``~``. We inject both as upstream repo roots
    and assert only the legitimate project survives.
    """
    import os

    hermes_home = os.environ["HERMES_HOME"]
    bare_home = os.path.expanduser("~")

    valid = str(tmp_path / "real-project")
    _patch_discover(
        monkeypatch,
        [
            {"root": hermes_home, "label": "hermes-home", "sessions": 3, "last_active": 0.0},
            {"root": bare_home, "label": "home", "sessions": 1, "last_active": 0.0},
            {"root": str(Path(hermes_home) / "skills"), "label": "skills", "sessions": 2, "last_active": 0.0},
            {
                "root": valid,
                "label": "real-project",
                "sessions": 5,
                "last_active": 0.0,
            },
        ],
    )

    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    roots = {e["root"] for e in resp.json()}
    assert hermes_home not in roots
    assert bare_home not in roots
    assert str(Path(hermes_home) / "skills") not in roots
    assert valid in roots
    assert len(resp.json()) == 1


def test_projects_empty_state(client, monkeypatch):
    """No repos upstream → 200 with an empty array (not 500, not null)."""
    _patch_discover(monkeypatch, [])
    resp = client.get("/api/plugins/hermes-mobile/projects")
    assert resp.status_code == 200, resp.text
    assert resp.json() == []
