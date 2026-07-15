"""ABH-361: Live Activity end frames on non-happy turn death paths."""

from __future__ import annotations

import json

from tests.plugins.hermes_mobile.conftest import load_plugin_module


_VALID_TOKEN = "a" * 64
_VALID_TOKEN_2 = "b" * 64


def _isolate_home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    return tmp_path


def _assert_terminal_end_call(call, session_id: str, *, elapsed_seconds: int | None = None):
    called_session_id, content_state, end = call
    assert called_session_id == session_id
    assert end is True
    assert set(content_state.keys()) == {
        "phase",
        "toolName",
        "elapsedSeconds",
        "needsApproval",
    }
    assert content_state["phase"] == "done"
    assert content_state["toolName"] is None
    assert isinstance(content_state["elapsedSeconds"], int)
    assert content_state["elapsedSeconds"] >= 0
    if elapsed_seconds is not None:
        assert content_state["elapsedSeconds"] == elapsed_seconds
    assert content_state["needsApproval"] is False


def _arm_live_activity(monkeypatch, push):
    class _Cfg:
        def is_armed(self):
            return True

    monkeypatch.setattr(push.APNsConfig, "from_env", classmethod(lambda cls: _Cfg()))


def test_message_complete_emits_terminal_end_frame_through_live_activity_hook(
    monkeypatch, tmp_path
):
    _isolate_home(monkeypatch, tmp_path)
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    push = load_plugin_module("push_engine")
    _arm_live_activity(monkeypatch, push)
    push.register_live_activity_token("complete-sid", _VALID_TOKEN, env="sandbox")
    session = {"session_key": "stored-session-key", "_push_turn_started": 10.0}
    monkeypatch.setattr(push, "_gw_sessions", lambda: {"complete-sid": session})
    monkeypatch.setattr(push.time, "time", lambda: 15.0)
    monkeypatch.setattr(push, "notify", lambda *args, **kwargs: 0)

    calls: list[tuple[str, dict, bool]] = []

    def fake_notify(session_id, content_state, *, end=False):
        calls.append((session_id, content_state, end))
        return True

    def fake_enqueue(event, sid, payload, *, event_time=None, turn_started=None):
        push._process_push_event(
            event,
            sid,
            payload,
            event_time=event_time,
            turn_started=turn_started,
        )

    monkeypatch.setattr(push, "notify_live_activity", fake_notify)
    monkeypatch.setattr(push, "_enqueue_push_event", fake_enqueue)

    push.handle_gateway_event("message.complete", "complete-sid", {"text": "done"})

    assert len(calls) == 1
    _assert_terminal_end_call(calls[0], "complete-sid", elapsed_seconds=5)


def test_session_finalize_emits_end_frame_before_registry_cleanup(monkeypatch, tmp_path):
    home = _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    push.register_live_activity_token("runtime-sid", _VALID_TOKEN, env="sandbox")

    calls: list[tuple[str, dict, bool]] = []
    token_present_during_notify = []

    def fake_notify(session_id, content_state, *, end=False):
        token_present_during_notify.append(push.live_activity_token_for(session_id) is not None)
        calls.append((session_id, content_state, end))
        return True

    monkeypatch.setattr(push, "notify_live_activity", fake_notify)

    push.handle_gateway_event(
        "session.finalize",
        "runtime-sid",
        {"session_id": "agent-session-id", "session_key": "stored-session-key"},
    )

    assert token_present_during_notify == [True]
    assert len(calls) == 1
    _assert_terminal_end_call(calls[0], "runtime-sid", elapsed_seconds=0)
    assert json.loads((home / "live_activity_tokens.json").read_text()) == {}


def test_session_deleted_emits_end_frame_before_registry_cleanup(monkeypatch, tmp_path):
    home = _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    push.register_live_activity_token("stored-sid", _VALID_TOKEN, env="sandbox")

    calls: list[tuple[str, dict, bool]] = []
    token_present_during_notify = []

    def fake_notify(session_id, content_state, *, end=False):
        token_present_during_notify.append(push.live_activity_token_for(session_id) is not None)
        calls.append((session_id, content_state, end))
        return True

    monkeypatch.setattr(push, "notify_live_activity", fake_notify)

    push.handle_gateway_event("session.deleted", "stored-sid", None)

    assert token_present_during_notify == [True]
    assert len(calls) == 1
    _assert_terminal_end_call(calls[0], "stored-sid", elapsed_seconds=0)
    assert json.loads((home / "live_activity_tokens.json").read_text()) == {}


def test_startup_sweep_ends_tokens_for_dead_sessions_only(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    push.register_live_activity_token("dead-sid", _VALID_TOKEN, env="sandbox")
    push.register_live_activity_token("live-sid", _VALID_TOKEN_2, env="sandbox")

    calls: list[tuple[str, dict, bool]] = []
    monkeypatch.setattr(push, "_gw_sessions", lambda: {"live-sid": {}})
    monkeypatch.setattr(
        push,
        "notify_live_activity",
        lambda session_id, content_state, *, end=False: calls.append(
            (session_id, content_state, end)
        )
        or True,
    )

    assert push.sweep_dead_live_activity_tokens() == 1

    assert len(calls) == 1
    _assert_terminal_end_call(calls[0], "dead-sid", elapsed_seconds=0)
    assert push.live_activity_token_for("dead-sid") is None
    assert push.live_activity_token_for("live-sid") == (_VALID_TOKEN_2, "sandbox")
