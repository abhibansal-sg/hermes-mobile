"""Tests for Lane 2 — the Reframer (raw gateway events -> item envelope).

Drives :meth:`Reframer.reframe` with recorded / fabricated raw-event sequences
and asserts (a) the emitted item-envelope frames (protocol §2/§3), (b) that
``*.complete`` payloads are AUTHORITATIVE (replace accumulated deltas), and
(c) snapshot correctness from the shared :class:`SessionStore`.

The real fixture ``fixtures/ws_events_raw.json`` is the exact WS event stream
the R0 spike recorded off a STOCK gateway (two turns, two sessions, reasoning +
message deltas). No network, no gateway — pure function of the event stream.
"""

from __future__ import annotations

import asyncio
import json
import os

import pytest

from hermes_relay.bus import TOPIC_GATEWAY_EVENTS, TOPIC_RELAY_FRAMES, EventBus
from hermes_relay.reframer import Reframer
from hermes_relay.session_state import SessionStore
from hermes_relay.types import (
    Frame,
    FrameKind,
    GatewayEvent,
    ItemStatus,
    ItemType,
)

_FIXTURE = os.path.join(os.path.dirname(__file__), "fixtures", "ws_events_raw.json")


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #


def _rf() -> Reframer:
    return Reframer(EventBus(), SessionStore())


def _ev(type_, sid="s1", **payload) -> GatewayEvent:
    return GatewayEvent(type=type_, session_id=sid, payload=payload)


def _drive(rf: Reframer, events) -> list[Frame]:
    out: list[Frame] = []
    for e in events:
        out.extend(rf.reframe(e))
    return out


def _kinds(frames):
    return [f.kind for f in frames]


def _first(frames, kind):
    return next(f for f in frames if f.kind == kind)


def _load_fixture():
    with open(_FIXTURE, encoding="utf-8") as fh:
        raw = json.load(fh)
    return [
        GatewayEvent(type=e["type"], session_id=e.get("session_id"), payload=e.get("payload") or {})
        for e in raw
    ]


# --------------------------------------------------------------------------- #
# message / agentMessage lifecycle
# --------------------------------------------------------------------------- #


def test_message_start_opens_turn_without_item():
    rf = _rf()
    frames = rf.reframe(_ev("message.start"))
    assert _kinds(frames) == [FrameKind.TURN_STARTED]
    assert frames[0].turn  # a turn id was synthesized


def test_message_lifecycle_completed_is_authoritative():
    rf = _rf()
    frames = _drive(
        rf,
        [
            _ev("message.start"),
            _ev("message.delta", text="Par"),
            _ev("message.delta", text="is"),
            _ev(
                "message.complete",
                text="Paris is the capital of France.",
                usage={"total": 42, "input": 10, "output": 32},
            ),
        ],
    )
    kinds = _kinds(frames)
    # turn.started, item.started(agentMessage), 2x item.delta,
    # item.completed(agentMessage), item.completed(usage), turn.completed
    assert kinds[0] == FrameKind.TURN_STARTED
    assert FrameKind.ITEM_STARTED in kinds
    assert kinds.count(FrameKind.ITEM_DELTA) == 2
    assert kinds[-1] == FrameKind.TURN_COMPLETED

    started = _first(frames, FrameKind.ITEM_STARTED)
    assert started.body["type"] == ItemType.AGENT_MESSAGE
    assert started.body["status"] == ItemStatus.IN_PROGRESS

    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["type"] == ItemType.AGENT_MESSAGE
    assert completed.body["status"] == ItemStatus.COMPLETED
    # AUTHORITATIVE: full text, not the "Par"+"is" the deltas accumulated.
    assert completed.body["body"]["text"] == "Paris is the capital of France."
    # item.completed reuses the SAME item_id the deltas targeted.
    assert completed.body["item_id"] == started.body["item_id"]

    turn_done = _first(frames, FrameKind.TURN_COMPLETED)
    assert turn_done.body["usage"]["total"] == 42


def test_usage_emitted_as_footer_item():
    rf = _rf()
    frames = _drive(
        rf,
        [
            _ev("message.start"),
            _ev("message.delta", text="hi"),
            _ev("message.complete", text="hi", usage={"total": 5}),
        ],
    )
    usage_items = [
        f for f in frames if f.kind == FrameKind.ITEM_COMPLETED and f.body["type"] == ItemType.USAGE
    ]
    assert len(usage_items) == 1
    assert usage_items[0].body["body"]["total"] == 5
    # footer sorts after the agentMessage
    agent = _first(frames, FrameKind.ITEM_STARTED)
    assert usage_items[0].body["ord"] > agent.body["ord"]


def test_message_complete_without_deltas_still_materializes_item():
    rf = _rf()
    frames = _drive(rf, [_ev("message.start"), _ev("message.complete", text="whole answer")])
    completed = [f for f in frames if f.kind == FrameKind.ITEM_COMPLETED]
    assert len(completed) == 1
    assert completed[0].body["body"]["text"] == "whole answer"
    assert completed[0].body["status"] == ItemStatus.COMPLETED


# --------------------------------------------------------------------------- #
# reasoning lifecycle + ordering
# --------------------------------------------------------------------------- #


def test_reasoning_lifecycle_authoritative():
    rf = _rf()
    frames = _drive(
        rf,
        [
            _ev("reasoning.delta", text="Think"),
            _ev("reasoning.delta", text="ing..."),
            _ev("reasoning.available", text="Full reasoning trace."),
        ],
    )
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["type"] == ItemType.REASONING
    assert completed.body["body"]["text"] == "Full reasoning trace."
    assert completed.body["status"] == ItemStatus.COMPLETED


def test_reasoning_sorts_before_agent_message():
    rf = _rf()
    _drive(
        rf,
        [
            _ev("message.start"),
            _ev("reasoning.delta", text="r"),
            _ev("message.delta", text="a"),
            _ev("reasoning.available", text="reasoning"),
            _ev("message.complete", text="answer", usage={"total": 1}),
        ],
    )
    items = rf._store.get("s1").ordered_items()
    types = [it.type for it in items]
    # reasoning first, then agentMessage, then usage footer
    assert types == [ItemType.REASONING, ItemType.AGENT_MESSAGE, ItemType.USAGE]


# --------------------------------------------------------------------------- #
# tools — generic + special renders + never-drop
# --------------------------------------------------------------------------- #


def test_tool_generic_reuses_tool_id_as_item_id():
    rf = _rf()
    frames = _drive(
        rf,
        [
            _ev("message.start"),
            _ev("tool.start", tool_id="tc_1", name="read_file", context="read app.py"),
            _ev(
                "tool.complete",
                tool_id="tc_1",
                name="read_file",
                args={"path": "app.py"},
                result="file contents",
                duration_s=0.12,
            ),
        ],
    )
    started = _first(frames, FrameKind.ITEM_STARTED)
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert started.body["item_id"] == "tc_1"
    assert completed.body["item_id"] == "tc_1"
    assert started.body["type"] == ItemType.TOOL_CALL
    assert completed.body["type"] == ItemType.TOOL_CALL
    assert completed.body["body"]["args"] == {"path": "app.py"}
    assert completed.body["body"]["result"] == "file contents"
    assert completed.body["body"]["duration_s"] == 0.12


def test_tool_inline_diff_becomes_file_change():
    rf = _rf()
    frames = _drive(
        rf,
        [
            _ev(
                "tool.complete",
                tool_id="tc_2",
                name="patch",
                args={"path": "x.py"},
                result="ok",
                inline_diff="- old\n+ new",
            )
        ],
    )
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["type"] == ItemType.FILE_CHANGE
    assert completed.body["body"]["inline_diff"] == "- old\n+ new"


def test_tool_browser_family_becomes_browser():
    rf = _rf()
    frames = _drive(rf, [_ev("tool.start", tool_id="b1", name="browser_snapshot", context="snap")])
    started = _first(frames, FrameKind.ITEM_STARTED)
    assert started.body["type"] == ItemType.BROWSER


def test_tool_image_family_becomes_image():
    rf = _rf()
    frames = _drive(rf, [_ev("tool.start", tool_id="im1", name="image_generate")])
    started = _first(frames, FrameKind.ITEM_STARTED)
    assert started.body["type"] == ItemType.IMAGE


def test_unknown_tool_name_is_generic_tool_call():
    rf = _rf()
    frames = _drive(rf, [_ev("tool.complete", tool_id="z9", name="some_future_tool_2027", result="ok")])
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["type"] == ItemType.TOOL_CALL
    assert completed.body["item_id"] == "z9"


def test_idless_tool_start_and_complete_correlate_by_name():
    """An id-LESS tool.start/complete pair must land on ONE card. Synthesizing a
    fresh id on both would orphan an in-progress card that never completes."""
    rf = _rf()
    frames = _drive(
        rf,
        [
            _ev("message.start"),
            _ev("tool.start", name="mystery_tool", context="working"),   # NO tool_id
            _ev("tool.complete", name="mystery_tool", result="ok"),      # NO tool_id
        ],
    )
    started = _first(frames, FrameKind.ITEM_STARTED)
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert started.body["item_id"] == completed.body["item_id"]  # same card
    assert started.body["status"] == ItemStatus.IN_PROGRESS
    assert completed.body["status"] == ItemStatus.COMPLETED
    # the completion reused the started item's ord (no duplicate slot).
    assert started.body["ord"] == completed.body["ord"]


def test_idless_tools_distinct_names_do_not_crosstalk():
    rf = _rf()
    frames = _drive(
        rf,
        [
            _ev("tool.start", name="alpha"),
            _ev("tool.start", name="beta"),
            _ev("tool.complete", name="beta", result="b"),
            _ev("tool.complete", name="alpha", result="a"),
        ],
    )
    ids = {f.body["body"]["name"]: f.body["item_id"]
           for f in frames if f.kind == FrameKind.ITEM_COMPLETED}
    starts = {f.body["body"]["name"]: f.body["item_id"]
              for f in frames if f.kind == FrameKind.ITEM_STARTED}
    assert ids["alpha"] == starts["alpha"]
    assert ids["beta"] == starts["beta"]
    assert ids["alpha"] != ids["beta"]


def test_idless_tool_complete_without_start_gets_fresh_id():
    rf = _rf()
    frames = _drive(rf, [_ev("tool.complete", name="lonely", result="done")])
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["item_id"]  # a non-empty synthesized id
    assert completed.body["status"] == ItemStatus.COMPLETED


def test_tool_complete_without_start_still_completes():
    rf = _rf()
    frames = _drive(rf, [_ev("tool.complete", tool_id="solo", name="write_file", result="wrote")])
    completed = [f for f in frames if f.kind == FrameKind.ITEM_COMPLETED]
    assert len(completed) == 1
    assert completed[0].body["item_id"] == "solo"
    assert completed[0].body["status"] == ItemStatus.COMPLETED


def test_failed_tool_becomes_error_item():
    rf = _rf()
    frames = _drive(
        rf,
        [_ev("tool.complete", tool_id="e1", name="terminal", result={"error": "boom"})],
    )
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["type"] == ItemType.ERROR
    assert completed.body["status"] == ItemStatus.FAILED


# --------------------------------------------------------------------------- #
# forward-compat: unknown top-level event is never dropped
# --------------------------------------------------------------------------- #


def test_unknown_event_type_becomes_generic_tool_call():
    rf = _rf()
    frames = _drive(rf, [_ev("some.brand.new.event", foo="bar")])
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["type"] == ItemType.TOOL_CALL
    assert completed.body["body"]["event_type"] == "some.brand.new.event"
    assert completed.body["body"]["payload"] == {"foo": "bar"}


def test_session_less_and_metadata_events_are_ignored():
    rf = _rf()
    # gateway.ready has no session_id; session.info is per-session metadata.
    assert rf.reframe(GatewayEvent(type="gateway.ready", session_id=None, payload={})) == []
    assert rf.reframe(_ev("session.info", model="glm-4.6")) == []


# --------------------------------------------------------------------------- #
# error / status / title / interactive
# --------------------------------------------------------------------------- #


def test_error_event_is_failed_error_item():
    rf = _rf()
    frames = _drive(rf, [_ev("error", message="agent init failed: boom")])
    completed = _first(frames, FrameKind.ITEM_COMPLETED)
    assert completed.body["type"] == ItemType.ERROR
    assert completed.body["status"] == ItemStatus.FAILED
    assert completed.body["body"]["message"] == "agent init failed: boom"


def test_status_update_is_status_frame():
    rf = _rf()
    frames = _drive(rf, [_ev("status.update", kind="compacting", text="Summarizing…")])
    assert _kinds(frames) == [FrameKind.STATUS]
    assert frames[0].body == {"kind": "compacting", "text": "Summarizing…"}


def test_thinking_delta_is_ephemeral_status_not_item():
    rf = _rf()
    frames = _drive(rf, [_ev("thinking.delta", text="(o_o) formulating...")])
    assert _kinds(frames) == [FrameKind.STATUS]
    assert frames[0].body["kind"] == "thinking"
    # no items accumulated
    assert rf._store.get("s1").ordered_items() == []


def test_session_title_is_title_frame():
    rf = _rf()
    frames = _drive(rf, [_ev("session.title", session_id="s1", title="My chat")])
    assert _kinds(frames) == [FrameKind.TITLE]
    assert frames[0].body == {"title": "My chat"}


def test_approval_and_clarify_are_interactive_frames():
    rf = _rf()
    approval = rf.reframe(_ev("approval.request", command="rm -rf /", choices=["once", "deny"]))
    clarify = rf.reframe(_ev("clarify.request", question="Which file?", choices=["a", "b"]))
    assert approval[0].kind == FrameKind.APPROVAL_REQUEST
    assert approval[0].body["choices"] == ["once", "deny"]
    assert clarify[0].kind == FrameKind.CLARIFY_REQUEST
    assert clarify[0].body["question"] == "Which file?"


# --------------------------------------------------------------------------- #
# snapshot correctness (resume-as-items)
# --------------------------------------------------------------------------- #


def test_snapshot_reflects_authoritative_items():
    rf = _rf()
    _drive(
        rf,
        [
            _ev("message.start"),
            _ev("reasoning.delta", text="r1"),
            _ev("reasoning.available", text="final reasoning"),
            _ev("message.delta", text="par"),
            _ev("message.complete", text="Paris.", usage={"total": 9}),
        ],
    )
    snap = rf._store.snapshot("s1", cursor=1421)
    assert snap["cursor"] == 1421
    items = snap["items"]
    by_type = {it["type"]: it for it in items}
    assert by_type[ItemType.REASONING]["body"]["text"] == "final reasoning"
    assert by_type[ItemType.AGENT_MESSAGE]["body"]["text"] == "Paris."
    assert by_type[ItemType.USAGE]["body"]["total"] == 9
    # all completed
    assert all(it["status"] == ItemStatus.COMPLETED for it in items)


# --------------------------------------------------------------------------- #
# real recorded fixture
# --------------------------------------------------------------------------- #


def test_real_fixture_replays_without_error_and_is_authoritative():
    rf = _rf()
    events = _load_fixture()
    frames = _drive(rf, events)
    assert frames  # produced output

    # The fixture holds two turns across two sessions.
    sids = {e.session_id for e in events if e.session_id}
    assert len(sids) >= 2

    # Expected authoritative text/reasoning per session = the message.complete
    # / reasoning.available payloads recorded on the wire (not hardcoded).
    expected_text = {
        e.session_id: e.payload.get("text")
        for e in events
        if e.type == "message.complete"
    }
    expected_reasoning = {
        e.session_id: e.payload.get("text")
        for e in events
        if e.type == "reasoning.available"
    }

    for sid in sids:
        items = rf._store.get(sid).ordered_items()
        if not items:
            continue
        agent = [it for it in items if it.type == ItemType.AGENT_MESSAGE]
        for a in agent:
            assert a.status == ItemStatus.COMPLETED
            assert a.body["text"] == expected_text[sid]
        reasoning = [it for it in items if it.type == ItemType.REASONING]
        for r in reasoning:
            assert r.status == ItemStatus.COMPLETED
            assert r.body["text"] == expected_reasoning[sid]
        # reasoning sorts before the agent answer within a turn
        if reasoning and agent:
            assert reasoning[0].ord < agent[0].ord


def test_real_fixture_two_sessions_isolated():
    rf = _rf()
    _drive(rf, _load_fixture())
    # each session accumulated its own turn; no cross-contamination
    s1 = rf._store.get("3d62926c").ordered_items()
    s2 = rf._store.get("83940538").ordered_items()
    assert s1 and s2
    # synthesized item ids are session-scoped — no id leaks across sessions
    assert all(it.item_id.startswith("3d62926c:") for it in s1)
    assert all(it.item_id.startswith("83940538:") for it in s2)


# --------------------------------------------------------------------------- #
# run() pump wiring over the bus
# --------------------------------------------------------------------------- #


def test_run_pump_publishes_frames_to_relay_topic():
    async def scenario():
        bus = EventBus()
        rf = Reframer(bus, SessionStore())
        out_sub = bus.subscribe(TOPIC_RELAY_FRAMES)
        task = asyncio.create_task(rf.run())
        await asyncio.sleep(0)  # let run() subscribe

        for e in [
            _ev("message.start"),
            _ev("message.delta", text="hi"),
            _ev("message.complete", text="hi", usage={"total": 3}),
        ]:
            bus.publish(TOPIC_GATEWAY_EVENTS, e)

        collected = []
        try:
            for _ in range(6):
                collected.append(await asyncio.wait_for(out_sub.get(), timeout=1.0))
        except asyncio.TimeoutError:
            pass
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass
        return collected

    frames = asyncio.run(scenario())
    kinds = [f.kind for f in frames]
    assert FrameKind.TURN_STARTED in kinds
    assert FrameKind.ITEM_COMPLETED in kinds
    assert FrameKind.TURN_COMPLETED in kinds
