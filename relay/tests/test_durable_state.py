import sqlite3
from pathlib import Path

from hermes_relay.durable_state import DurableState
from hermes_relay.types import Frame, FrameKind


def test_database_connections_are_closed(tmp_path: Path, monkeypatch):
    real_connect = sqlite3.connect
    opened = 0
    closed = 0

    class TrackingConnection(sqlite3.Connection):
        def close(self):
            nonlocal closed
            closed += 1
            super().close()

    def connect(*args, **kwargs):
        nonlocal opened
        opened += 1
        return real_connect(*args, **kwargs, factory=TrackingConnection)

    monkeypatch.setattr("hermes_relay.durable_state.sqlite3.connect", connect)
    state = DurableState(tmp_path / "state.sqlite3")
    for _ in range(20):
        state.current_revision()

    assert opened == closed == 20


def _approval(request_id="a1"):
    return Frame(
        sid="s1", kind=FrameKind.APPROVAL_REQUEST,
        body={"id": request_id, "description": "Review change", "destructive": True},
    )


def test_attention_snapshot_delta_and_restart(tmp_path: Path):
    path = tmp_path / "state.sqlite3"
    state = DurableState(path)
    state.observe_frame(_approval())

    initial = state.pending_attention(None)
    assert initial["reset"] is True
    assert initial["upserts"][0]["id"] == "approval:a1"
    assert initial["upserts"][0]["destructive"] is True

    restarted = DurableState(path)
    assert restarted.pending_attention(initial["cursor"])["upserts"] == []
    restarted.resolve_attention(request_id="a1", session_id="s1", kind="approval")
    delta = state.pending_attention(initial["cursor"])
    assert delta["reset"] is False
    assert delta["upserts"] == []
    assert delta["tombstones"][0]["status"] == "resolved_elsewhere"


def test_turn_completion_expires_session_attention(tmp_path: Path):
    state = DurableState(tmp_path / "state.sqlite3")
    state.observe_frame(_approval())
    cursor = state.pending_attention(None)["cursor"]
    state.observe_frame(Frame(sid="s1", kind=FrameKind.TURN_COMPLETED))
    assert state.pending_attention(cursor)["tombstones"][0]["status"] == "expired"


def test_push_outbox_retries_and_survives_restart(tmp_path: Path):
    path = tmp_path / "state.sqlite3"
    state = DurableState(path)
    descriptor = {"collapse_id": "s1:approval:a1", "expiration": 0, "title": "Review"}
    assert state.enqueue_push(descriptor, now=100) is True
    assert state.enqueue_push(descriptor, now=100) is False
    due = state.due_pushes(now=100)
    assert len(due) == 1
    state.finish_push(due[0]["_event_id"], False, due[0]["_attempts"], now=100)
    assert DurableState(path).due_pushes(now=101) == []
    retried = DurableState(path).due_pushes(now=102)
    assert len(retried) == 1 and retried[0]["_attempts"] == 1
    state.finish_push(retried[0]["_event_id"], True, retried[0]["_attempts"], now=102)
    assert DurableState(path).due_pushes(now=1000) == []


def test_sync_manifest_persists_session_deltas_attention_and_active_turns(tmp_path: Path):
    path = tmp_path / "state.sqlite3"
    state = DurableState(path)
    state.observe_frame(_approval())
    state.observe_frame(Frame(sid="s1", kind=FrameKind.TURN_STARTED, turn="t1"))
    first = state.sync_manifest(
        "all", None,
        [{"id": "s1", "title": "One", "message_count": 2, "profile": "default"}],
    )
    assert first["reset"] is True
    assert first["sessions"][0]["title"] == "One"
    assert first["attention"][0]["id"] == "approval:a1"
    assert first["active_turns"][0]["session_id"] == "s1"
    assert first["transcript_heads"] == {"s1": 2}

    restarted = DurableState(path)
    unchanged = restarted.sync_manifest(
        "all", first["cursor"],
        [{"id": "s1", "title": "One", "message_count": 2, "profile": "default"}],
    )
    assert unchanged["reset"] is False and unchanged["sessions"] == []
    removed = restarted.sync_manifest("all", unchanged["cursor"], [])
    assert removed["tombstones"] == [{"id": "s1"}]
