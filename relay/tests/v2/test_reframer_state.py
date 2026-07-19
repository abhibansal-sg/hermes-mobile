from __future__ import annotations

from hermes_relay.bus import EventBus
from hermes_relay.reframer import Reframer
from hermes_relay.types import Frame, FrameKind, GatewayEvent, RawEvent
from hermes_relay.v2.reframer_state import V2ReframerStore


def test_v2_reframer_state_never_accumulates_delta_or_completed_bodies() -> None:
    store = V2ReframerStore(max_sessions=2, max_open_items=2)
    state = store.get("session")
    state.apply(
        Frame(
            sid="session",
            kind=FrameKind.ITEM_STARTED,
            body={
                "item_id": "item",
                "type": "agentMessage",
                "status": "in_progress",
                "ord": 0,
                "summary": "private",
                "body": {"text": ""},
            },
        )
    )
    for _ in range(10_000):
        state.apply(
            Frame.item_delta("session", "item", {"text": "private chunk"})
        )
    assert state.items["item"].body == {}
    state.apply(
        Frame(
            sid="session",
            kind=FrameKind.ITEM_COMPLETED,
            body={
                "item_id": "item",
                "type": "agentMessage",
                "status": "completed",
                "ord": 0,
                "summary": "private",
                "body": {"text": "private full body"},
            },
        )
    )
    assert state.items == {}


def test_v2_reframer_drops_terminal_turn_state_and_bounds_active_sessions() -> None:
    store = V2ReframerStore(max_sessions=2)
    reframer = Reframer(EventBus(), store, max_contexts=2)
    frames = reframer.reframe(
        GatewayEvent(
            type=RawEvent.MESSAGE_COMPLETE,
            session_id="done",
            payload={"text": "private"},
        )
    )
    assert any(frame.kind == FrameKind.TURN_COMPLETED for frame in frames)
    assert "done" not in store
    assert "done" not in reframer._ctx

    store.get("one")
    store.get("two")
    store.get("three")
    assert store.session_ids() == ["two", "three"]
