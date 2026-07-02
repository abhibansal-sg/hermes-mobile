"""Push / Live Activity gateway-event intake tests (hermes-mobile plugin).

Moved verbatim from ``tests/test_tui_gateway_server.py`` in the ABH-88
de-patch (W1). The code under test lives in
``plugins/hermes-mobile/push_engine.py`` (formerly the push block in
``tui_gateway/server.py`` + ``hermes_cli/push_notify.py``); only the API
names were adapted:

* ``server._push_hook`` / ``server._process_push_event`` /
  ``server._live_activity_hook`` → the same names on the plugin module.
* ``hermes_cli.push_notify.notify`` etc. → the plugin module's own
  ``notify`` / ``notify_live_activity`` / ``live_activity_token_for`` /
  ``APNsConfig`` (the registry/sender code moved into the same module).

Tests that stash sessions in ``server._sessions`` keep doing exactly that —
the engine reads the gateway session table live via ``_gw_sessions()``.
"""

import sys
import threading
import time
import types

import pytest

from tui_gateway import server


def _session(agent=None, **extra):
    return {
        "agent": agent if agent is not None else types.SimpleNamespace(),
        "session_key": "session-key",
        "history": [],
        "history_lock": threading.Lock(),
        "history_version": 0,
        "running": False,
        "attached_images": [],
        "image_counter": 0,
        "cols": 80,
        "slash_worker": None,
        "show_reasoning": False,
        "tool_progress_mode": "all",
        **extra,
    }


class _FakeRelayClient:
    class RelayConfigurationError(RuntimeError):
        pass

    def __init__(self, *, configured: bool) -> None:
        self.configured = configured
        self.events = []

    def relay_url_configured(self) -> bool:
        return self.configured

    def relay_client(self):
        return self

    async def send_event(self, **kwargs):
        self.events.append(kwargs)


class _FakePushEngine:
    def __init__(self, *, direct_available: bool, accepted: int = 1) -> None:
        self.direct_available = direct_available
        self.accepted = accepted
        self.direct_calls = 0

    def direct_apns_test_push_available(self) -> bool:
        return self.direct_available

    def send_direct_apns_test_push(self) -> int:
        self.direct_calls += 1
        return self.accepted


def _push_test_client(monkeypatch, push_engine, relay_client):
    fastapi = pytest.importorskip("fastapi")
    testclient = pytest.importorskip("fastapi.testclient")

    api = sys.modules["hermes_dashboard_plugin_hermes-mobile"]
    monkeypatch.setattr(api, "_has_dashboard_api_auth", lambda request: True)
    monkeypatch.setattr(api, "_device_has_scope", lambda request, scope: True)

    def _fake_plugin_module(name: str):
        if name == "push_engine":
            return push_engine
        if name == "relay_client":
            return relay_client
        raise AssertionError(f"unexpected plugin module: {name}")

    monkeypatch.setattr(api, "_plugin_module", _fake_plugin_module)
    app = fastapi.FastAPI()
    app.include_router(api.router)
    return testclient.TestClient(app)


def test_relay_test_push_uses_direct_apns_when_configured(monkeypatch):
    push = _FakePushEngine(direct_available=True, accepted=1)
    relay = _FakeRelayClient(configured=False)
    client = _push_test_client(monkeypatch, push, relay)

    resp = client.post("/relay/test-push")

    assert resp.status_code == 200
    assert resp.json() == {
        "ok": True,
        "transport": "direct_apns",
        "detail": "sent via direct APNs",
    }
    assert push.direct_calls == 1
    assert relay.events == []


def test_relay_test_push_reports_no_push_configured_without_transport(monkeypatch):
    push = _FakePushEngine(direct_available=False)
    relay = _FakeRelayClient(configured=False)
    client = _push_test_client(monkeypatch, push, relay)

    resp = client.post("/relay/test-push")

    assert resp.status_code == 200
    body = resp.json()
    assert body == {
        "ok": False,
        "transport": "none",
        "detail": "no push configured",
    }
    assert "relay URL is not configured" not in body["detail"]
    assert push.direct_calls == 0
    assert relay.events == []


def test_relay_test_push_keeps_relay_path_when_relay_configured(monkeypatch):
    push = _FakePushEngine(direct_available=False)
    relay = _FakeRelayClient(configured=True)
    client = _push_test_client(monkeypatch, push, relay)

    resp = client.post("/relay/test-push")

    assert resp.status_code == 200
    assert resp.json() == {
        "ok": True,
        "transport": "relay",
        "detail": "sent via relay",
    }
    assert push.direct_calls == 0
    assert len(relay.events) == 1
    assert relay.events[0]["source"] == "relay_test_push"


# ===========================================================================
# F2-S S2 — push hook category + approval payload enrichment.
# These monkeypatch the push_engine senders so no APNs traffic is generated.
# ===========================================================================

def _capture_notify(monkeypatch, pn):
    """Patch push_engine.notify and return the captured-calls list."""
    calls = []

    def _fake_notify(event_type, title, body, payload=None, *, category=None):
        calls.append({
            "event_type": event_type, "title": title, "body": body,
            "payload": payload, "category": category,
        })
        return 1

    monkeypatch.setattr(pn, "notify", _fake_notify)
    # Live Activity hook is disarmed (no LA token) so it stays a no-op; make
    # the armed-check cheap and deterministic regardless of env.
    monkeypatch.setattr(pn, "live_activity_token_for", lambda sid: None)
    return calls


def test_push_hook_stamps_and_enqueues_without_sending(monkeypatch, push_engine):
    enqueued = []

    def _fake_enqueue(event, sid, payload, event_time=None, turn_started=None):
        enqueued.append(
            {
                "event": event,
                "sid": sid,
                "payload": payload,
                "event_time": event_time,
                "turn_started": turn_started,
            }
        )

    monkeypatch.setattr(push_engine, "_enqueue_push_event", _fake_enqueue)
    monkeypatch.setattr(
        push_engine,
        "_process_push_event",
        lambda *a, **k: pytest.fail("_push_hook must not send inline"),
    )

    server._sessions["sid_async"] = {"session_key": "stored"}
    try:
        push_engine._push_hook("message.start", "sid_async", None)
        push_engine._push_hook("approval.request", "sid_async", {"description": "check"})
        assert isinstance(server._sessions["sid_async"].get("_push_turn_started"), float)
    finally:
        server._sessions.pop("sid_async", None)

    assert len(enqueued) == 2
    assert enqueued[0]["event"] == "message.start"
    assert enqueued[0]["event_time"] is not None
    assert enqueued[0]["turn_started"] == enqueued[0]["event_time"]
    assert enqueued[1]["event"] == "approval.request"
    assert enqueued[1]["turn_started"] == enqueued[0]["event_time"]


def test_push_hook_message_start_snapshot_prevents_stale_elapsed(monkeypatch, push_engine):
    captured = []

    def _fake_enqueue(event, sid, payload, event_time=None, turn_started=None):
        captured.append((event, event_time, turn_started))

    monkeypatch.setattr(push_engine, "_enqueue_push_event", _fake_enqueue)
    server._sessions["sid_elapsed"] = {
        "session_key": "stored",
        "_push_turn_started": 10.0,
    }
    try:
        push_engine._push_hook("message.start", "sid_elapsed", None)
    finally:
        server._sessions.pop("sid_elapsed", None)

    assert captured[0][0] == "message.start"
    assert captured[0][1] == captured[0][2]
    assert captured[0][2] != 10.0


def test_push_hook_kanban_worker_suppresses_intake_except_approval(
    monkeypatch, push_engine
):
    """ABH-204: a kanban worker's internal turn/tool/status/message-complete
    events must not enqueue a phone push, but its approval requests still do.

    Drives _push_hook directly so the assertion is about intake (enqueue), not
    about the downstream _process_push_event guard (which stays as
    defense-in-depth). HERMES_KANBAN_TASK pins the worker env; teardown clears
    the session table.
    """
    monkeypatch.setenv("HERMES_KANBAN_TASK", "t_abc")

    enqueued = []

    def _fake_enqueue(event, sid, payload, event_time=None, turn_started=None):
        enqueued.append(event)

    monkeypatch.setattr(push_engine, "_enqueue_push_event", _fake_enqueue)
    monkeypatch.setattr(
        push_engine,
        "_process_push_event",
        lambda *a, **k: pytest.fail("_push_hook must not process inline"),
    )

    server._sessions["sid_worker"] = {
        "session_key": "kw",
        "_push_turn_started": time.time() - 100,
    }
    try:
        # Worker internal events are suppressed at intake.
        push_engine._push_hook("message.start", "sid_worker", None)
        push_engine._push_hook("tool.start", "sid_worker", {"name": "edit_file"})
        push_engine._push_hook("tool.complete", "sid_worker", {"name": "edit_file"})
        push_engine._push_hook("status.update", "sid_worker", {"kind": "process"})
        push_engine._push_hook(
            "message.complete", "sid_worker", {"text": "All done"}
        )
        # Approval requests still enqueue even for a worker.
        push_engine._push_hook(
            "approval.request", "sid_worker", {"command": "rm -rf /"}
        )
    finally:
        server._sessions.pop("sid_worker", None)

    assert enqueued == ["approval.request"]


def test_push_hook_kanban_worker_suppression_is_env_gated(monkeypatch, push_engine):
    """ABH-204: suppression only applies when HERMES_KANBAN_TASK is set — a
    normal user session's message.complete still enqueues."""
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)

    enqueued = []

    def _fake_enqueue(event, sid, payload, event_time=None, turn_started=None):
        enqueued.append(event)

    monkeypatch.setattr(push_engine, "_enqueue_push_event", _fake_enqueue)
    server._sessions["sid_user"] = {
        "session_key": "ku",
        "_push_turn_started": time.time() - 100,
    }
    try:
        push_engine._push_hook(
            "message.complete", "sid_user", {"text": "All done"}
        )
    finally:
        server._sessions.pop("sid_user", None)

    assert enqueued == ["message.complete"]


def test_push_hook_approval_enriched_and_categorized(monkeypatch, push_engine):
    calls = _capture_notify(monkeypatch, push_engine)
    server._sessions["sid_appr"] = {"session_key": "stored-key-1"}
    try:
        push_engine._process_push_event(
            "approval.request",
            "sid_appr",
            {"description": "rm -rf /", "command": "rm -rf /",
             "pattern_keys": ["rm_rf"]},
        )
    finally:
        server._sessions.pop("sid_appr", None)

    assert len(calls) == 1
    c = calls[0]
    assert c["event_type"] == "approval"
    assert c["category"] == "HERMES_APPROVAL"
    p = c["payload"]
    assert p["session_id"] == "sid_appr"
    assert p["stored_session_id"] == "stored-key-1"
    assert p["destructive"] is True
    assert p["approval_title"] == "rm -rf /"


def test_push_hook_approval_destructive_false_without_pattern(monkeypatch, push_engine):
    calls = _capture_notify(monkeypatch, push_engine)
    server._sessions["sid_appr2"] = {"session_key": "k2"}
    try:
        push_engine._process_push_event(
            "approval.request", "sid_appr2",
            {"description": "do thing", "target": "the thing"},
        )
    finally:
        server._sessions.pop("sid_appr2", None)
    assert calls[0]["payload"]["destructive"] is False
    assert calls[0]["payload"]["approval_title"] == "the thing"


def test_push_hook_clarify_category(monkeypatch, push_engine):
    calls = _capture_notify(monkeypatch, push_engine)
    push_engine._process_push_event("clarify.request", "sid_c", {"question": "Which file?"})
    assert calls[0]["event_type"] == "clarify"
    assert calls[0]["category"] == "HERMES_CLARIFY"
    assert calls[0]["body"] == "Which file?"


def test_push_hook_bounds_and_scrubs_lock_screen_body(monkeypatch, push_engine):
    calls = _capture_notify(monkeypatch, push_engine)
    raw = "token=secret-value-1234567890\n" + ("x" * 300)
    push_engine._process_push_event("clarify.request", "sid_c", {"question": raw})
    body = calls[0]["body"]
    assert len(body) <= push_engine._PUSH_TEXT_MAX
    assert "\n" not in body
    assert "secret-value" not in body
    assert body.startswith("token=[redacted]")


def test_push_hook_turn_complete_category_for_long_turn(monkeypatch, push_engine):
    calls = _capture_notify(monkeypatch, push_engine)
    server._sessions["sid_t"] = {"session_key": "kt"}
    # Stamp a turn start well past the 30s long-turn threshold.
    server._sessions["sid_t"]["_push_turn_started"] = time.time() - 100
    try:
        push_engine._process_push_event(
            "message.complete", "sid_t", {"text": "All done\nmore"}
        )
    finally:
        server._sessions.pop("sid_t", None)
    assert len(calls) == 1
    assert calls[0]["event_type"] == "turn_complete"
    assert calls[0]["category"] == "HERMES_TURN"
    assert calls[0]["body"] == "All done"


def test_push_hook_turn_complete_skipped_for_short_turn(monkeypatch, push_engine):
    calls = _capture_notify(monkeypatch, push_engine)
    server._sessions["sid_short"] = {"session_key": "ks"}
    server._sessions["sid_short"]["_push_turn_started"] = time.time() - 2
    try:
        push_engine._process_push_event("message.complete", "sid_short", {"text": "quick"})
    finally:
        server._sessions.pop("sid_short", None)
    assert calls == []


def test_process_push_event_does_not_clear_newer_turn_start(monkeypatch, push_engine):
    calls = _capture_notify(monkeypatch, push_engine)
    old_started = time.time() - 120
    newer_started = time.time()
    server._sessions["sid_race"] = {
        "session_key": "kr",
        "_push_turn_started": newer_started,
    }
    try:
        push_engine._process_push_event(
            "message.complete",
            "sid_race",
            {"text": "Old turn finished"},
            event_time=old_started + 90,
            turn_started=old_started,
        )
        assert server._sessions["sid_race"]["_push_turn_started"] == newer_started
    finally:
        server._sessions.pop("sid_race", None)
    assert calls[0]["event_type"] == "turn_complete"


# ===========================================================================
# ABH-204 — a dispatched kanban worker's internal turns must NOT push a phone
# alert, but its approval requests must still push. Normal user-session push
# behavior is unchanged when HERMES_KANBAN_TASK is absent.
# ===========================================================================

def test_worker_long_turn_complete_produces_no_alert_push(monkeypatch, push_engine):
    # HERMES_KANBAN_TASK set ⇒ this process is a dispatched kanban worker.
    monkeypatch.setenv("HERMES_KANBAN_TASK", "t_abc")
    calls = _capture_notify(monkeypatch, push_engine)
    server._sessions["sid_worker"] = {"session_key": "kw"}
    # Stamp a turn start well past the 30s long-turn threshold.
    server._sessions["sid_worker"]["_push_turn_started"] = time.time() - 100
    try:
        push_engine._process_push_event(
            "message.complete", "sid_worker", {"text": "All done\nmore"}
        )
    finally:
        server._sessions.pop("sid_worker", None)
    # No alert push for a worker's internal turn completion.
    assert calls == []


def test_worker_approval_request_still_pushes(monkeypatch, push_engine):
    monkeypatch.setenv("HERMES_KANBAN_TASK", "t_abc")
    calls = _capture_notify(monkeypatch, push_engine)
    server._sessions["sid_wa"] = {"session_key": "kwa"}
    try:
        push_engine._process_push_event(
            "approval.request",
            "sid_wa",
            {"description": "rm -rf /", "command": "rm -rf /",
             "pattern_keys": ["rm_rf"]},
        )
    finally:
        server._sessions.pop("sid_wa", None)
    # Worker approval requests must still push with HERMES_APPROVAL category.
    assert len(calls) == 1
    assert calls[0]["event_type"] == "approval"
    assert calls[0]["category"] == "HERMES_APPROVAL"


def test_non_worker_long_turn_complete_still_pushes(monkeypatch, push_engine):
    # HERMES_KANBAN_TASK absent ⇒ normal user session; behavior unchanged.
    monkeypatch.delenv("HERMES_KANBAN_TASK", raising=False)
    calls = _capture_notify(monkeypatch, push_engine)
    server._sessions["sid_user"] = {"session_key": "ku"}
    server._sessions["sid_user"]["_push_turn_started"] = time.time() - 100
    try:
        push_engine._process_push_event(
            "message.complete", "sid_user", {"text": "All done\nmore"}
        )
    finally:
        server._sessions.pop("sid_user", None)
    assert len(calls) == 1
    assert calls[0]["event_type"] == "turn_complete"
    assert calls[0]["category"] == "HERMES_TURN"
    assert calls[0]["body"] == "All done"


# ===========================================================================
# F2-S S3 — Live Activity gateway hook (update on tool/status, end on
# complete/interrupt, >=3s throttle, final always sent, armed/no-op guard).
# ===========================================================================

def _capture_live_activity(monkeypatch, pn, *, armed=True, has_token=True):
    """Patch the LA-relevant push_engine surface; return captured LA calls."""
    la_calls = []

    class _Cfg:
        def is_armed(self):
            return armed

    monkeypatch.setattr(pn.APNsConfig, "from_env", classmethod(lambda cls: _Cfg()))
    monkeypatch.setattr(
        pn, "live_activity_token_for",
        lambda sid: ((("a" * 64), "sandbox") if has_token else None),
    )

    def _fake_la(session_id, content_state, *, end=False):
        la_calls.append({"sid": session_id, "cs": content_state, "end": end})
        return True

    monkeypatch.setattr(pn, "notify_live_activity", _fake_la)
    # Keep alert notify a no-op so message.complete etc. don't error.
    monkeypatch.setattr(pn, "notify", lambda *a, **k: 0)
    return la_calls


def test_live_activity_hook_noop_when_disarmed(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine, armed=False)
    server._sessions["sid_la"] = {"session_key": "k"}
    try:
        push_engine._live_activity_hook("tool.start", "sid_la", {"name": "edit_file"})
    finally:
        server._sessions.pop("sid_la", None)
    assert la == []


def test_live_activity_hook_noop_when_no_token(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine, has_token=False)
    server._sessions["sid_la"] = {"session_key": "k"}
    try:
        push_engine._live_activity_hook("tool.start", "sid_la", {"name": "edit_file"})
    finally:
        server._sessions.pop("sid_la", None)
    assert la == []


def test_live_activity_hook_tool_start_update(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    server._sessions["sid_la"] = {"session_key": "k",
                                  "_push_turn_started": time.time() - 5}
    try:
        push_engine._live_activity_hook("tool.start", "sid_la", {"name": "edit_file"})
    finally:
        server._sessions.pop("sid_la", None)
    assert len(la) == 1
    cs = la[0]["cs"]
    assert cs["phase"] == "tool"
    assert cs["toolName"] == "edit_file"
    assert cs["elapsedSeconds"] >= 5
    assert cs["needsApproval"] is False
    assert la[0]["end"] is False
    # content-state uses the exact Swift Codable field names.
    assert set(cs.keys()) == {"phase", "toolName", "elapsedSeconds", "needsApproval"}


def test_live_activity_hook_end_on_message_complete(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    server._sessions["sid_la"] = {"session_key": "k",
                                  "_push_turn_started": time.time() - 5}
    try:
        # Drive through the queued worker helper so we exercise the send path.
        push_engine._process_push_event("message.complete", "sid_la", {"text": "done"})
    finally:
        server._sessions.pop("sid_la", None)
    end_calls = [c for c in la if c["end"]]
    assert len(end_calls) == 1
    assert end_calls[0]["cs"]["phase"] == "done"


def test_live_activity_hook_end_on_interrupt(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    server._sessions["sid_la"] = {"session_key": "k"}
    try:
        push_engine._live_activity_hook("session.interrupt", "sid_la", None)
    finally:
        server._sessions.pop("sid_la", None)
    assert len(la) == 1
    assert la[0]["end"] is True


def test_live_activity_hook_dedupes_interrupt_then_complete_for_same_turn(
    monkeypatch, push_engine
):
    la = _capture_live_activity(monkeypatch, push_engine)
    started = time.time() - 5
    server._sessions["sid_la"] = {
        "session_key": "k",
        "_push_turn_started": started,
    }
    try:
        push_engine._live_activity_hook(
            "session.interrupt",
            "sid_la",
            None,
            turn_started=started,
        )
        push_engine._live_activity_hook(
            "message.complete",
            "sid_la",
            {"text": "interrupted"},
            turn_started=started,
        )
    finally:
        server._sessions.pop("sid_la", None)

    end_calls = [c for c in la if c["end"]]
    assert len(end_calls) == 1


def test_live_activity_hook_drops_stale_end_after_new_turn(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    old_started = time.time() - 30
    newer_started = time.time()
    server._sessions["sid_la"] = {
        "session_key": "k",
        "_push_turn_started": newer_started,
    }
    try:
        push_engine._live_activity_hook(
            "message.complete",
            "sid_la",
            {"text": "old turn"},
            turn_started=old_started,
        )
    finally:
        server._sessions.pop("sid_la", None)

    assert la == []


def test_live_activity_hook_throttles_within_3s(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    server._sessions["sid_la"] = {"session_key": "k",
                                  "_push_turn_started": time.time()}
    try:
        # First update goes through; second within 3s is throttled.
        push_engine._live_activity_hook("tool.start", "sid_la", {"name": "a"})
        push_engine._live_activity_hook("tool.complete", "sid_la", {"name": "a"})
        assert len(la) == 1
        # The end frame ALWAYS goes through despite the throttle window.
        push_engine._live_activity_hook("session.interrupt", "sid_la", None)
        assert len(la) == 2
        assert la[-1]["end"] is True
    finally:
        server._sessions.pop("sid_la", None)


def test_live_activity_hook_approval_bypasses_throttle(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    now = time.time()
    server._sessions["sid_la"] = {
        "session_key": "k",
        "_push_turn_started": now,
        "_la_last_update": now,
    }
    try:
        push_engine._live_activity_hook(
            "approval.request", "sid_la", {"command": "rm -rf /"}
        )
    finally:
        server._sessions.pop("sid_la", None)
    assert len(la) == 1
    assert la[0]["cs"]["phase"] == "waiting"
    assert la[0]["cs"]["needsApproval"] is True


def test_live_activity_hook_blocked_status_bypasses_throttle(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    now = time.time()
    server._sessions["sid_la"] = {
        "session_key": "k",
        "_push_turn_started": now,
        "_la_last_update": now,
    }
    try:
        push_engine._live_activity_hook(
            "status.update", "sid_la", {"kind": "blocked", "text": "blocked"}
        )
    finally:
        server._sessions.pop("sid_la", None)
    assert len(la) == 1
    assert la[0]["cs"]["phase"] == "waiting"


def test_live_activity_hook_status_kind_uses_user_phase(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    server._sessions["sid_la"] = {
        "session_key": "k",
        "_push_turn_started": time.time(),
    }
    try:
        push_engine._live_activity_hook(
            "status.update", "sid_la", {"kind": "process", "text": "Running"}
        )
    finally:
        server._sessions.pop("sid_la", None)
    assert len(la) == 1
    assert la[0]["cs"]["phase"] == "thinking"
    assert la[0]["cs"]["phase"] != "process"


def test_live_activity_hook_approval_needs_approval_flag(monkeypatch, push_engine):
    la = _capture_live_activity(monkeypatch, push_engine)
    server._sessions["sid_la"] = {"session_key": "k",
                                  "_push_turn_started": time.time()}
    try:
        push_engine._live_activity_hook("approval.request", "sid_la",
                                        {"command": "rm -rf /"})
    finally:
        server._sessions.pop("sid_la", None)
    assert la[0]["cs"]["needsApproval"] is True
    assert la[0]["cs"]["phase"] == "waiting"


# ===========================================================================
# Session-boundary integration — the gateway's synthetic "session.finalize" /
# "session.deleted" events (S2 seam) must trigger Live Activity unregistration
# in the plugin. Driven through the same server RPC paths the originals used,
# with the plugin's handle_gateway_event wired via the wired_gateway fixture.
# ===========================================================================


def test_session_close_unregisters_live_activity_runtime(monkeypatch, wired_gateway):
    server_mod, _ws, pn, _bc = wired_gateway
    removed = []

    def _fake_unregister(session_id):
        removed.append(session_id)
        return True

    monkeypatch.setattr(pn, "unregister_live_activity_token", _fake_unregister)
    monkeypatch.setattr(server_mod, "_notify_session_boundary", lambda *a, **k: None)
    agent = types.SimpleNamespace(session_id="stored-session")
    server_mod._sessions["sid-la-close"] = _session(
        agent=agent, _runtime_sid="sid-la-close"
    )

    try:
        resp = server_mod.handle_request(
            {
                "id": "1",
                "method": "session.close",
                "params": {"session_id": "sid-la-close"},
            }
        )
        assert resp["result"]["closed"] is True
    finally:
        server_mod._sessions.pop("sid-la-close", None)

    # The finalize event passes the runtime sid plus the stored session id /
    # session key, so the runtime sid must be among the unregistered ids.
    assert "sid-la-close" in removed


def test_session_delete_unregisters_live_activity_id(monkeypatch, wired_gateway):
    server_mod, _ws, pn, _bc = wired_gateway
    removed = []

    class _DB:
        def delete_session(self, sid, sessions_dir=None):
            return sid == "old-2"

    monkeypatch.setattr(server_mod, "_get_db", lambda: _DB())
    monkeypatch.setattr(
        pn,
        "unregister_live_activity_token",
        lambda session_id: removed.append(session_id) or True,
    )

    resp = server_mod.handle_request(
        {"id": "1", "method": "session.delete", "params": {"session_id": "old-2"}}
    )

    assert resp["result"] == {"deleted": "old-2", "evicted": False}
    assert removed == ["old-2"]
