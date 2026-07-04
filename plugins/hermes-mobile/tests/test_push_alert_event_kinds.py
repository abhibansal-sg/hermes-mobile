"""ABH-394: per-kind push alerts for turn errors and background completions."""

from __future__ import annotations

import sys
import types

from tests.plugins.hermes_mobile.conftest import load_plugin_module


_VALID_TOKEN = "a" * 64


def _isolate_home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    return tmp_path


def _run_push_events_inline(monkeypatch, push):
    def fake_enqueue(event, sid, payload, *, event_time=None, turn_started=None):
        push._process_push_event(
            event,
            sid,
            payload,
            event_time=event_time,
            turn_started=turn_started,
        )

    monkeypatch.setattr(push, "_gw_sessions", lambda: {})
    monkeypatch.setattr(push, "_enqueue_push_event", fake_enqueue)


def test_error_event_notifies_turn_error_kind(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    _run_push_events_inline(monkeypatch, push)

    calls = []
    monkeypatch.setattr(
        push,
        "notify",
        lambda *args, **kwargs: calls.append((args, kwargs)) or 1,
    )

    push.handle_gateway_event("error", "sid-error", {"message": "boom\nsecond line"})

    assert len(calls) == 1
    args, kwargs = calls[0]
    assert args == (
        "turn_error",
        "Hermes hit an error",
        "boom",
        {"session_id": "sid-error"},
    )
    assert kwargs == {"category": "HERMES_ERROR"}


def test_background_complete_event_notifies_background_done_kind(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    _run_push_events_inline(monkeypatch, push)

    calls = []
    monkeypatch.setattr(
        push,
        "notify",
        lambda *args, **kwargs: calls.append((args, kwargs)) or 1,
    )

    push.handle_gateway_event(
        "background.complete",
        "sid-bg",
        {"task_id": "t1", "text": "done\nmore detail"},
    )

    assert len(calls) == 1
    args, kwargs = calls[0]
    assert args == (
        "background_done",
        "Background job finished",
        "done",
        {"session_id": "sid-bg", "task_id": "t1"},
    )
    assert kwargs == {"category": "HERMES_TURN"}


def test_new_push_kinds_respect_registered_events_subset(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    _run_push_events_inline(monkeypatch, push)

    class _Cfg:
        enabled = True
        topic = "com.example.HermesMobile"
        host = "api.push.apple.com"
        key_file = "dummy.p8"
        key_id = "KEYID"
        team_id = "TEAMID"

        def is_armed(self):
            return True

    class _FakeClient:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

    monkeypatch.setattr(push.APNsConfig, "from_env", classmethod(lambda cls: _Cfg()))
    monkeypatch.setattr(push, "_get_provider_jwt", lambda config: "provider.jwt")
    monkeypatch.setitem(sys.modules, "httpx", types.SimpleNamespace(Client=_FakeClient))

    sent_tokens = []
    monkeypatch.setattr(
        push,
        "_send_one",
        lambda conn, **kwargs: sent_tokens.append(kwargs["device_token"]) or (200, ""),
    )

    assert push.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])

    push.handle_gateway_event("error", "sid-error", {"message": "boom"})
    push.handle_gateway_event(
        "background.complete",
        "sid-bg",
        {"task_id": "t1", "text": "done"},
    )

    assert sent_tokens == []
    assert push.recipients_for_event("turn_error") == {}
    assert push.recipients_for_event("background_done") == {}
