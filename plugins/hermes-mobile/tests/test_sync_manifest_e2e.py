"""Real plugin router + real SessionDB + real manifest journal smoke test."""

from __future__ import annotations

import sys
import json
import os
import subprocess
import textwrap
from pathlib import Path

import pytest

_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


def _json_shape(value):
    """Describe the JSON wire shape while ignoring generated identity values."""
    if isinstance(value, dict):
        return {key: _json_shape(item) for key, item in sorted(value.items())}
    if isinstance(value, list):
        return [None] if not value else [_json_shape(value[0])]
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if value is None:
        return "null"
    return "string"


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

    # web_server owns process-global route/plugin caches. Exercise it in a
    # fresh process so this E2E proves cold external discovery and cannot pass
    # or fail based on another test's import order.
    result_path = tmp_path / "manifest-result.json"
    script = textwrap.dedent(
        """
        import json, os, sys
        from pathlib import Path
        from hermes_cli import web_server
        from hermes_cli.web_server import app, _SESSION_HEADER_NAME, _SESSION_TOKEN
        from starlette.testclient import TestClient

        web_server._get_dashboard_plugins(force_rescan=True)
        web_server._mount_plugin_api_routes()
        client = TestClient(app)
        client.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
        first = client.get(
            "/api/plugins/hermes-mobile/sync/manifest",
            params={"scope": "all"},
        )
        seed = first.json()
        second = client.get(
            "/api/plugins/hermes-mobile/sync/manifest",
            params={"scope": "all", "resume_cursor": seed.get("resume_cursor")},
        )
        Path(os.environ["RESULT_PATH"]).write_text(
            json.dumps({
                "module_loaded": "hermes_dashboard_plugin_hermes-mobile" in sys.modules,
                "first_status": first.status_code,
                "seed": seed,
                "second_status": second.status_code,
                "delta": second.json(),
            }),
            encoding="utf-8",
        )
        """
    )
    env = dict(os.environ)
    env["HERMES_HOME"] = str(home)
    env["RESULT_PATH"] = str(result_path)
    completed = subprocess.run(
        [sys.executable, "-c", script],
        cwd=Path(__file__).resolve().parents[3],
        env=env,
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    assert completed.returncode == 0, completed.stderr
    result = json.loads(result_path.read_text(encoding="utf-8"))
    assert result["module_loaded"] is True
    assert result["first_status"] == 200, result["seed"]
    seed = result["seed"]
    assert seed["schema_version"] == 2
    assert seed["gateway_id"].startswith("gw_")
    assert seed["profile_authorities"][0]["profile_id"].startswith("pf_")
    assert seed["sessions"]["upserts"][0]["id"] == "stored-e2e"
    assert seed["transcript_heads"][0]["message_count"] == 1

    fixture_path = Path(__file__).parent / "fixtures" / "sync_manifest_v2_complete.json"
    fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
    assert _json_shape(seed) == _json_shape(fixture)

    assert result["second_status"] == 200, result["delta"]
    delta = result["delta"]
    assert delta["sessions"] == {"upserts": [], "tombstones": []}
    assert delta["revision"] == seed["revision"]
    assert (home / "mobile" / "sync-manifest.sqlite3").exists()
