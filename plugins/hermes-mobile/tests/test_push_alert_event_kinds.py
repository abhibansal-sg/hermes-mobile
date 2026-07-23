"""ABH-394: per-kind push alerts for turn errors and background completions."""

from __future__ import annotations

from tests.plugins.hermes_mobile.conftest import load_plugin_module
from tools import approval as approval_module


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
    assert kwargs == {"category": "HERMES_ERROR", "excluding_device_ids": set()}


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
    assert kwargs == {"category": "HERMES_TURN", "excluding_device_ids": set()}


def test_notify_queues_one_relay_event_without_local_registry(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    relay = load_plugin_module("relay_client")

    relay_calls = []

    def fake_send_event_background(**kwargs):
        relay_calls.append(kwargs)

    monkeypatch.setattr(relay, "send_event_background", fake_send_event_background)

    result = push.notify(
        "approval",
        "Approval needed",
        "Review in Hermes",
        {"session_id": "sess-approval", "source": "telegram"},
    )

    assert result == 1
    assert len(relay_calls) == 1
    assert relay_calls[0]["kind"] == "attention"
    assert relay_calls[0]["session_id"] == "sess-approval"


def test_desktop_owner_does_not_suppress_phone_completion(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    session = {"session_key": "stored-1", "transport": object()}
    monkeypatch.setattr(push, "_gw_sessions", lambda: {"runtime-1": session})
    monkeypatch.setattr(push, "_foreground_phone_devices", lambda *_args: set())
    calls = []
    monkeypatch.setattr(
        push, "notify", lambda *args, **kwargs: calls.append((args, kwargs)) or 1
    )

    push._process_push_event("message.complete", "runtime-1", {"text": "done"})

    assert len(calls) == 1
    assert calls[0][0][0] == "turn_complete"
    assert calls[0][1]["excluding_device_ids"] == set()


def test_completion_excludes_only_foreground_phone(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    session = {"session_key": "stored-1"}
    monkeypatch.setattr(push, "_gw_sessions", lambda: {"runtime-1": session})
    monkeypatch.setattr(
        push, "_foreground_phone_devices", lambda *_args: {"phone-1"}
    )
    calls = []
    monkeypatch.setattr(
        push, "notify", lambda *args, **kwargs: calls.append((args, kwargs)) or 1
    )

    push._process_push_event("message.complete", "runtime-1", {"text": "done"})

    assert calls[0][1]["excluding_device_ids"] == {"phone-1"}


def test_approval_push_originates_from_stock_hook(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    monkeypatch.setattr(
        push,
        "_gw_sessions",
        lambda: {"runtime-1": {"session_key": "stored-1"}},
    )
    monkeypatch.setattr(
        approval_module,
        "pending_approval_snapshot",
        lambda: [{
            "stored_session_id": "stored-1",
            "request_id": "request-1",
            "detail": {
                "description": "Delete the selected file",
                "choices": ["once", "deny"],
            },
        }],
    )
    calls = []
    monkeypatch.setattr(
        push, "_push_hook", lambda *args, **kwargs: calls.append((args, kwargs))
    )

    push.handle_approval_request(
        session_key="stored-1",
        surface="gateway",
        command="rm file --token secret-value",
        description="Delete file using token secret-value",
    )

    assert calls[0][0][0:2] == ("approval.request", "runtime-1")
    assert calls[0][0][2]["request_id"] == "request-1"
    assert calls[0][0][2]["description"] == "Delete the selected file"
