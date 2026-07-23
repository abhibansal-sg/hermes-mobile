"""ABH-394: per-kind push alerts for turn errors and background completions."""

from __future__ import annotations

import sys
import types

from tests.plugins.hermes_mobile.conftest import load_plugin_module
from tools import approval as approval_module


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


def test_push_registry_persists_authenticated_device_binding(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    assert push.register_token(_VALID_TOKEN, env="sandbox", device_id="device-1")
    assert push.registry_entries()[0]["device_id"] == "device-1"

    # Re-registration is the only legacy-row backfill path.
    assert push.register_token(_VALID_TOKEN, env="production", device_id="device-2")
    entries = push.registry_entries()
    assert len(entries) == 1 and entries[0]["device_id"] == "device-2"


def test_recipient_filter_excludes_only_selected_device(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    assert push.register_token("a" * 64, env="sandbox", device_id="phone-1")
    assert push.register_token("b" * 64, env="sandbox", device_id="phone-2")

    assert push.recipients_for_event(
        "turn_complete", excluding_device_ids={"phone-1"}
    ) == {"sandbox": ["b" * 64]}


def test_live_relay_claim_suppresses_duplicate_in_process_alert(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    push._RELAY_OWNER_UNTIL = 0.0
    calls = []
    monkeypatch.setattr(push, "_push_hook", lambda *args: calls.append(args))

    assert push.claim_relay_notification_ownership(15) == 15
    push.handle_gateway_event("message.complete", "sid", {"text": "done"})

    assert push.relay_owns_notifications()
    assert calls == []
    push._RELAY_OWNER_UNTIL = 0.0


def test_live_relay_claim_keeps_local_interrupt_cleanup(monkeypatch, tmp_path):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    monkeypatch.setattr(push, "_RELAY_OWNER_UNTIL", 0.0)
    calls = []
    monkeypatch.setattr(push, "_push_hook", lambda *args: calls.append(args))

    push.claim_relay_notification_ownership(15)
    push.handle_gateway_event("session.interrupt", "sid", None)

    assert calls == [("session.interrupt", "sid", None)]


def test_relay_notification_claim_expires_to_plugin_fallback(
    monkeypatch, tmp_path
):
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    now = [100.0]
    monkeypatch.setattr(push.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(push, "_RELAY_OWNER_UNTIL", 0.0)

    push.claim_relay_notification_ownership(15)
    assert push.relay_owns_notifications() is True

    now[0] = 116.0
    assert push.relay_owns_notifications() is False


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


def test_relay_notify_skips_event_kind_not_in_registered_prefs(monkeypatch, tmp_path):
    """STR-1132/STR-1135: relay notify honors per-event toggles.

    Relay mode + a token registered for ``["approval"]`` + ``notify("clarify")``
    must NOT enqueue relay delivery and must return 0.
    """
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    relay = load_plugin_module("relay_client")

    relay_calls = []

    def fake_send_event_background(**kwargs):
        relay_calls.append(kwargs)

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(relay, "send_event_background", fake_send_event_background)

    assert push.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])

    result = push.notify(
        "clarify",
        "Question",
        "Need input",
        {"session_id": "sess-clarify", "source": "telegram"},
    )

    assert result == 0
    assert relay_calls == []


def test_relay_notify_emits_for_event_kind_in_registered_prefs(monkeypatch, tmp_path):
    """STR-1132/STR-1135: relay notify emits for an opted-in event kind.

    Relay mode + a token registered for ``["approval"]`` + ``notify("approval")``
    must call ``send_event_background`` and return 1; the emitted relay kind
    stays ``attention``.
    """
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    relay = load_plugin_module("relay_client")

    relay_calls = []

    def fake_send_event_background(**kwargs):
        relay_calls.append(kwargs)

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(relay, "send_event_background", fake_send_event_background)

    assert push.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])

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


def test_relay_notify_falls_open_for_unknown_event_type(monkeypatch, tmp_path):
    """STR-1132/STR-1135: unknown event types preserve the legacy relay path.

    An event type outside ``PUSH_EVENT_KINDS`` is not subject to per-event
    gating: relay delivery is enqueued unconditionally (legacy fall-open),
    even when registered prefs would exclude known kinds.
    """
    _isolate_home(monkeypatch, tmp_path)
    push = load_plugin_module("push_engine")
    relay = load_plugin_module("relay_client")

    relay_calls = []

    def fake_send_event_background(**kwargs):
        relay_calls.append(kwargs)

    monkeypatch.setenv("HERMES_MOBILE_RELAY_URL", "https://relay.example.test")
    monkeypatch.setattr(relay, "send_event_background", fake_send_event_background)

    # No registered recipient wants this (unknown) kind, yet the legacy relay
    # path must still kick it off.
    assert push.register_token(_VALID_TOKEN, env="sandbox", events=["approval"])

    result = push.notify(
        "custom_admin_kind",
        "Admin",
        "Manual blast",
        {"session_id": "sess-admin", "source": "internal"},
    )

    assert result == 1
    assert len(relay_calls) == 1


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
