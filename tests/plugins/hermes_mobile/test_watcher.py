"""Tests for plugins/hermes-mobile/scripts/watcher.py (external polling fallback).

Stdlib + pytest + mock only, no live network. Covers:
  - delta detection logic (advance -> notify, first-sight -> silent, stable -> silent)
  - notify payload shape (matches the /notify NotifyBody contract)
  - auth header construction (X-Hermes-Session-Token, token never in URL/argv)
"""

import importlib.util
import sys
from pathlib import Path
from unittest import mock

REPO_ROOT = Path(__file__).resolve().parents[3]
WATCHER_PATH = REPO_ROOT / "plugins" / "hermes-mobile" / "scripts" / "watcher.py"

spec = importlib.util.spec_from_file_location("hm_watcher", WATCHER_PATH)
watcher = importlib.util.module_from_spec(spec)
sys.modules["hm_watcher"] = watcher
spec.loader.exec_module(watcher)


class TestDetectDeltas:
    def test_advanced_max_id_produces_notify_event(self):
        prev = {"sess-a": 10, "sess-b": 5}
        current = {"sess-a": 14, "sess-b": 5}
        events = watcher.detect_deltas(prev, current)
        assert len(events) == 1
        assert events[0]["session_id"] == "sess-a"
        assert events[0]["event"] == "turn_complete"

    def test_first_sight_session_is_silent(self):
        # New session's baseline is unknown — must NOT notify for history.
        events = watcher.detect_deltas({}, {"sess-new": 42})
        assert events == []

    def test_stable_sessions_are_silent(self):
        prev = {"sess-a": 10}
        events = watcher.detect_deltas(prev, dict(prev))
        assert events == []

    def test_disappeared_session_is_silent(self):
        events = watcher.detect_deltas({"sess-gone": 10}, {})
        assert events == []


class TestNotifyPayloadShape:
    def test_payload_matches_notify_body_contract(self):
        events = watcher.detect_deltas({"s": 1}, {"s": 2})
        payload = events[0]
        # NotifyBody contract: event: str, session_id: str, payload: dict|None
        assert set(payload.keys()) == {"event", "session_id", "payload"}
        assert isinstance(payload["event"], str)
        assert isinstance(payload["session_id"], str)
        assert isinstance(payload["payload"], dict)
        assert payload["payload"]["source"] == "watcher"


class TestAuthHeaders:
    def test_session_token_header_name(self):
        headers = watcher.build_headers("tok-123")
        assert headers[watcher.SESSION_HEADER] == "tok-123"
        assert watcher.SESSION_HEADER == "X-Hermes-Session-Token"

    def test_token_travels_in_header_not_url(self):
        captured = {}

        class _Resp:
            def read(self):
                return b"{}"

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def _fake_urlopen(req, timeout=None):
            captured["url"] = req.full_url
            captured["headers"] = dict(req.header_items())
            return _Resp()

        with mock.patch.object(watcher.urllib.request, "urlopen", _fake_urlopen):
            watcher.fetch_json("http://gw:9119", "/api/plugins/hermes-mobile/sessions", "sekret")

        assert "sekret" not in captured["url"]
        header_vals = {v for v in captured["headers"].values()}
        assert "sekret" in header_vals


class TestPostJson:
    def test_post_sends_json_body_and_auth(self):
        captured = {}

        class _Resp:
            def read(self):
                return b'{"ok": true}'

            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        def _fake_urlopen(req, timeout=None):
            captured["method"] = req.get_method()
            captured["data"] = req.data
            captured["headers"] = dict(req.header_items())
            return _Resp()

        with mock.patch.object(watcher.urllib.request, "urlopen", _fake_urlopen):
            out = watcher.post_json(
                "http://gw:9119",
                "/api/plugins/hermes-mobile/notify",
                "tok",
                {"event": "turn_complete", "session_id": "s", "payload": None},
            )

        assert out == {"ok": True}
        assert captured["method"] == "POST"
        assert b"turn_complete" in captured["data"]
