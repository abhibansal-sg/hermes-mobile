"""Session search excludes autonomous machinery sources."""

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


class _FakeConn:
    def close(self):
        pass


class _RecordingSearchDB:
    instances = []

    def __init__(self, *args, **kwargs):
        self.read_only = kwargs.get("read_only")
        self._fts_enabled = False
        self._conn = _FakeConn()
        self.captured_kwargs = None
        self.instances.append(self)

    def _fts_table_exists(self, name):
        assert name == "messages_fts"
        return True

    def search_messages(self, **kwargs):
        self.captured_kwargs = kwargs
        return []


def test_session_search_excludes_cron_subagent_and_tool_sources(client, monkeypatch, tmp_path):
    state_db = tmp_path / "state.db"
    state_db.touch()
    _RecordingSearchDB.instances = []

    monkeypatch.setattr("hermes_state.DEFAULT_DB_PATH", state_db)
    monkeypatch.setattr("hermes_state.SessionDB", _RecordingSearchDB)

    response = client.get("/api/plugins/hermes-mobile/sessions/search?q=needle")

    assert response.status_code == 200, response.text
    assert _RecordingSearchDB.instances, "SessionDB must be opened"
    db = _RecordingSearchDB.instances[-1]
    assert db.read_only is True
    assert db.captured_kwargs is not None
    assert db.captured_kwargs["exclude_sources"] == ["cron", "subagent", "tool"]
    assert "cron" in db.captured_kwargs["exclude_sources"]
    assert "subagent" in db.captured_kwargs["exclude_sources"]
    assert "tool" in db.captured_kwargs["exclude_sources"]
