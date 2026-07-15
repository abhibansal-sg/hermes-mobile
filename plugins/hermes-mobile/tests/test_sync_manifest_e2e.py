"""Real plugin router + real SessionDB + real manifest journal smoke test."""

from __future__ import annotations

import sys

import pytest

_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


def test_manifest_e2e_survives_real_sqlite_reopen(monkeypatch, tmp_path):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))

    from hermes_state import SessionDB

    db = SessionDB(home / "state.db")
    db.create_session("stored-e2e", source="cli", cwd="/tmp/project")
    db.set_session_title("stored-e2e", "E2E session")
    db.append_message("stored-e2e", role="user", content="hello from e2e", timestamp=100.0)
    db.close()

    from hermes_cli import web_server
    from hermes_cli.web_server import app, _SESSION_HEADER_NAME, _SESSION_TOKEN
    from starlette.testclient import TestClient

    web_server._get_dashboard_plugins(force_rescan=True)
    web_server._mount_plugin_api_routes()
    assert _API_MODULE_NAME in sys.modules

    client = TestClient(app)
    client.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    first = client.get("/api/plugins/hermes-mobile/sync/manifest", params={"scope": "all"})
    assert first.status_code == 200, first.text
    seed = first.json()
    assert seed["sessions"]["upserts"][0]["id"] == "stored-e2e"
    assert seed["transcript_heads"][0]["message_count"] == 1

    second = client.get(
        "/api/plugins/hermes-mobile/sync/manifest",
        params={"scope": "all", "cursor": seed["next_cursor"]},
    )
    assert second.status_code == 200, second.text
    delta = second.json()
    assert delta["sessions"] == {"upserts": [], "tombstones": []}
    assert delta["revision"] == seed["revision"]
    assert (home / "mobile" / "sync-manifest.sqlite3").exists()
