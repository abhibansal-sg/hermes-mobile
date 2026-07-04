"""ABH-400 transcript window paging for the mobile session message route."""

from __future__ import annotations

import asyncio
import importlib.util
import sys
import types
from pathlib import Path

from tests.plugins.hermes_mobile.conftest import load_plugin_module

REPO_ROOT = Path(__file__).resolve().parents[3]
_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


def _rows(count: int):
    return [
        {"id": i, "role": "user" if i % 2 else "assistant", "content": f"m{i}"}
        for i in range(1, count + 1)
    ]


def _load_api():
    load_plugin_module("device_tokens")
    if _API_MODULE_NAME not in sys.modules:
        api_path = REPO_ROOT / "plugins" / "hermes-mobile" / "dashboard" / "api.py"
        spec = importlib.util.spec_from_file_location(_API_MODULE_NAME, api_path)
        assert spec and spec.loader, f"cannot load mobile dashboard api at {api_path}"
        mod = importlib.util.module_from_spec(spec)
        sys.modules[_API_MODULE_NAME] = mod
        spec.loader.exec_module(mod)
    return sys.modules[_API_MODULE_NAME]


def _request():
    return types.SimpleNamespace(
        app=types.SimpleNamespace(state=types.SimpleNamespace(auth_required=True)),
        state=types.SimpleNamespace(
            session=None,
            device={"scopes": ["approve"]},
            token_authenticated=True,
        ),
        headers={},
        query_params={},
    )


class _ExistingPath:
    def exists(self) -> bool:
        return True


class _FakeSessionDB:
    rows = []

    def __init__(self, read_only: bool = False):
        assert read_only is True
        self._conn = types.SimpleNamespace(close=lambda: None)

    def get_messages(self, session_id: str):
        assert session_id == "s1"
        return list(self.rows)


def _install_fake_state(monkeypatch, rows):
    _FakeSessionDB.rows = rows
    fake_state = types.SimpleNamespace(
        SessionDB=_FakeSessionDB,
        DEFAULT_DB_PATH=_ExistingPath(),
    )
    monkeypatch.setitem(sys.modules, "hermes_state", fake_state)


def test_page_messages_returns_tail_window_and_backward_cursor():
    transcript_sync = load_plugin_module("transcript_sync")
    page = transcript_sync.page_messages(_rows(10), limit=3, before=None)

    assert [m["id"] for m in page.messages] == [8, 9, 10]
    assert page.oldest_id == 8
    assert page.has_more_before is True

    older = transcript_sync.page_messages(_rows(10), limit=3, before=8)
    assert [m["id"] for m in older.messages] == [5, 6, 7]
    assert older.oldest_id == 5
    assert older.has_more_before is True


def test_session_messages_delta_no_new_params_is_byte_identical(monkeypatch):
    api = _load_api()
    rows = _rows(6)
    _install_fake_state(monkeypatch, rows)
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: True)

    result = asyncio.run(api.session_messages_delta("s1", _request()))

    assert result == {
        "session_id": "s1",
        "is_delta": False,
        "prefix_count": 6,
        "max_id": 6,
        "shape": "full",
        "messages": rows,
    }


def test_session_messages_delta_limit_before_pages_without_changing_cursor(monkeypatch):
    api = _load_api()
    rows = _rows(10)
    _install_fake_state(monkeypatch, rows)
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: True)

    tail = asyncio.run(api.session_messages_delta("s1", _request(), limit=4))
    assert [m["id"] for m in tail["messages"]] == [7, 8, 9, 10]
    assert tail["prefix_count"] == 10
    assert tail["max_id"] == 10
    assert tail["page"]["oldest_id"] == 7
    assert tail["page"]["has_more_before"] is True

    older = asyncio.run(api.session_messages_delta("s1", _request(), limit=4, before=7))
    assert [m["id"] for m in older["messages"]] == [3, 4, 5, 6]
    assert older["prefix_count"] == 10
    assert older["max_id"] == 10
    assert older["page"]["oldest_id"] == 3
    assert older["page"]["has_more_before"] is True
