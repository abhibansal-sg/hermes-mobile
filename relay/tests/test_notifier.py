"""Tests for Lane 4 — the Notifier (owned-session APNs, foreground-gated).

All hermetic: a fake ``push_engine`` records ``notify()`` calls (NO real APNs,
NO network), a fake gateway answers ``owns()``, and the §6 foreground gate is a
plain callable the test flips. Covers the mandated matrix:

* turn_complete fires when the phone is absent, suppressed when foregrounded;
* approval always notifies (even foregrounded — a blocking gate);
* error fires when absent, suppressed when foregrounded;
* unowned / non-push-worthy frames are ignored;
* dedupe (one banner per turn; distinct approvals each ring);
* the run() pump drives observe() off the bus.
"""

from __future__ import annotations

import asyncio

import pytest

from hermes_relay.bus import EventBus, TOPIC_RELAY_FRAMES
from hermes_relay.notifier import Notifier, NotifierConfig
from hermes_relay.types import Frame, FrameKind, Item, ItemStatus, ItemType


# --------------------------------------------------------------------------- #
# Fakes                                                                        #
# --------------------------------------------------------------------------- #
class FakePush:
    """Records every notify() call — the mock APNs sender (no network)."""

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def notify(self, event_type, title, body, payload=None, *, category=None,
               expiration=0, collapse_id=None) -> int:
        self.calls.append(
            {
                "event_type": event_type,
                "title": title,
                "body": body,
                "payload": payload,
                "category": category,
                "expiration": expiration,
                "collapse_id": collapse_id,
            }
        )
        return 1


class FakeGateway:
    """Minimal ownership oracle standing in for GatewayClient.owns()."""

    def __init__(self, owned: set[str] | None = None) -> None:
        self._owned = set(owned or ())

    def own(self, sid: str) -> None:
        self._owned.add(sid)

    def owns(self, sid: str) -> bool:
        return sid in self._owned


# --------------------------------------------------------------------------- #
# Builders                                                                     #
# --------------------------------------------------------------------------- #
def _agent_completed(sid, item_id="m1", turn="t1", text="Paris is the capital."):
    return Frame.with_item(
        sid,
        FrameKind.ITEM_COMPLETED,
        Item(item_id, ItemType.AGENT_MESSAGE, ItemStatus.COMPLETED, 0, body={"text": text}),
        turn,
    )


def _error_completed(sid, item_id="e1", turn="t1", message="Boom: the tool exploded"):
    return Frame.with_item(
        sid,
        FrameKind.ITEM_COMPLETED,
        Item(item_id, ItemType.ERROR, ItemStatus.FAILED, 0, body={"message": message}),
        turn,
    )


def _approval(sid, request_id="a1", turn="t1", title="Run rm -rf?", description="Delete build/"):
    return Frame(
        sid=sid,
        kind=FrameKind.APPROVAL_REQUEST,
        body={"request_id": request_id, "title": title, "description": description},
        turn=turn,
    )


def _make(*, owned=("s1",), foreground=(), push=None, config=None):
    fg = set(foreground)
    gw = FakeGateway(set(owned))
    push = push or FakePush()
    notifier = Notifier(
        config or NotifierConfig(),
        EventBus(),
        gw,  # type: ignore[arg-type]
        is_foregrounded=lambda sid: sid in fg,
        push_engine=push,
    )
    return notifier, push, gw, fg


# --------------------------------------------------------------------------- #
# turn_complete                                                                #
# --------------------------------------------------------------------------- #
def test_turn_complete_fires_when_phone_absent():
    notifier, push, _, _ = _make(owned=("s1",), foreground=())
    desc = notifier.observe(_agent_completed("s1", text="Paris is the capital."))
    assert desc is not None
    assert desc["event_type"] == "turn_complete"
    assert desc["sid"] == "s1"
    assert desc["title"] == "Hermes finished"
    assert desc["body"] == "Paris is the capital."
    assert desc["category"] == "HERMES_TURN"
    assert desc["expiration"] == 14400
    assert desc["payload"]["session_id"] == "s1"
    assert desc["payload"]["turn_id"] == "t1"
    # delegated to the reused push_engine.notify with the same shape
    assert len(push.calls) == 1
    call = push.calls[0]
    assert call["event_type"] == "turn_complete"
    assert call["category"] == "HERMES_TURN"
    assert call["expiration"] == 14400
    assert notifier.metrics.fired == 1


def test_turn_complete_suppressed_when_foregrounded():
    notifier, push, _, _ = _make(owned=("s1",), foreground=("s1",))
    desc = notifier.observe(_agent_completed("s1"))
    assert desc is None
    assert push.calls == []
    assert notifier.metrics.suppressed_foreground == 1
    assert notifier.metrics.fired == 0


def test_turn_complete_body_falls_back_to_default():
    notifier, _, _, _ = _make()
    frame = Frame.with_item(
        "s1", FrameKind.ITEM_COMPLETED,
        Item("m9", ItemType.AGENT_MESSAGE, ItemStatus.COMPLETED, 0, body={}), "t1",
    )
    desc = notifier.observe(frame)
    assert desc["body"] == "Turn finished"


# --------------------------------------------------------------------------- #
# approval — always notifies                                                   #
# --------------------------------------------------------------------------- #
def test_approval_always_notifies_even_foregrounded():
    notifier, push, _, _ = _make(owned=("s1",), foreground=("s1",))
    desc = notifier.observe(_approval("s1", title="Run rm -rf?", description="Delete build/"))
    assert desc is not None
    assert desc["event_type"] == "approval"
    assert desc["title"] == "Run rm -rf?"
    assert desc["body"] == "Delete build/"
    assert desc["category"] == "HERMES_APPROVAL"
    assert desc["expiration"] == 0
    assert len(push.calls) == 1
    assert notifier.metrics.suppressed_foreground == 0


def test_approval_default_text_when_fields_missing():
    notifier, _, _, _ = _make()
    desc = notifier.observe(Frame(sid="s1", kind=FrameKind.APPROVAL_REQUEST, body={}, turn="t1"))
    assert desc["title"] == "Approval required"
    assert desc["body"] == "Review this approval in Hermes"


# --------------------------------------------------------------------------- #
# error                                                                        #
# --------------------------------------------------------------------------- #
def test_error_fires_when_absent_and_suppressed_when_foregrounded():
    notifier, push, _, _ = _make(owned=("s1",), foreground=())
    desc = notifier.observe(_error_completed("s1", message="Boom: the tool exploded\nstack..."))
    assert desc["event_type"] == "turn_error"
    assert desc["title"] == "Hermes hit an error"
    assert desc["body"] == "Boom: the tool exploded"  # first line only
    assert desc["category"] == "HERMES_ERROR"
    assert desc["expiration"] == 0

    notifier2, push2, _, _ = _make(owned=("s1",), foreground=("s1",))
    assert notifier2.observe(_error_completed("s1")) is None
    assert push2.calls == []
    assert notifier2.metrics.suppressed_foreground == 1


# --------------------------------------------------------------------------- #
# clarify — blocking, always notifies (like approval)                          #
# --------------------------------------------------------------------------- #
def _clarify(sid, request_id="c1", turn="t1", question="Which bucket, staging or prod?"):
    return Frame(
        sid=sid,
        kind=FrameKind.CLARIFY_REQUEST,
        body={"request_id": request_id, "question": question},
        turn=turn,
    )


def test_clarify_fires_even_when_foregrounded():
    notifier, push, _, _ = _make(owned=("s1",), foreground=("s1",))
    desc = notifier.observe(_clarify("s1", question="Which bucket, staging or prod?"))
    assert desc is not None
    assert desc["event_type"] == "clarify"
    assert desc["title"] == "Hermes has a question"
    assert desc["body"] == "Which bucket, staging or prod?"
    assert desc["category"] == "HERMES_CLARIFY"
    assert desc["expiration"] == 0            # blocking -> no store-and-forward window
    assert len(push.calls) == 1
    assert notifier.metrics.suppressed_foreground == 0   # bypassed the §6 gate


def test_clarify_default_text_and_dedupe_per_request():
    notifier, push, _, _ = _make(owned=("s1",))
    assert notifier.observe(Frame(sid="s1", kind=FrameKind.CLARIFY_REQUEST, body={}, turn="t1"))[
        "body"
    ] == "Hermes needs your input to continue"
    # a distinct request rings again; the SAME request id does not.
    notifier2, push2, _, _ = _make(owned=("s1",))
    notifier2.observe(_clarify("s1", request_id="cA"))
    notifier2.observe(_clarify("s1", request_id="cA"))    # dup
    notifier2.observe(_clarify("s1", request_id="cB"))    # distinct
    assert [c["event_type"] for c in push2.calls] == ["clarify", "clarify"]
    assert notifier2.metrics.suppressed_dedupe == 1


def test_clarify_unowned_never_pushes():
    notifier, push, _, _ = _make(owned=(), foreground=())
    assert notifier.observe(_clarify("s1")) is None
    assert push.calls == []
    assert notifier.metrics.skipped_unowned == 1


# --------------------------------------------------------------------------- #
# task_complete — taskList item.completed, foreground-gated                    #
# --------------------------------------------------------------------------- #
def _tasklist_completed(sid, item_id="s1:tasks", turn="t1", summary="Tasks 3/3", all_complete=True):
    return Frame.with_item(
        sid,
        FrameKind.ITEM_COMPLETED,
        Item(
            item_id,
            ItemType.TASK_LIST,
            ItemStatus.COMPLETED,
            0,
            summary=summary,
            body={"tasks": [], "counts": {"total": 3}, "all_complete": all_complete},
        ),
        turn,
    )


def test_task_complete_fires_when_phone_absent():
    notifier, push, _, _ = _make(owned=("s1",), foreground=())
    desc = notifier.observe(_tasklist_completed("s1", summary="Tasks 3/3"))
    assert desc is not None
    assert desc["event_type"] == "task_complete"
    assert desc["title"] == "Hermes finished its tasks"
    assert desc["body"] == "Tasks 3/3"
    assert desc["category"] == "HERMES_TURN"
    assert desc["expiration"] == 14400        # store-and-forward like turn_complete
    assert len(push.calls) == 1
    assert notifier.metrics.fired == 1


def test_task_complete_suppressed_when_foregrounded():
    notifier, push, _, _ = _make(owned=("s1",), foreground=("s1",))
    assert notifier.observe(_tasklist_completed("s1")) is None
    assert push.calls == []
    assert notifier.metrics.suppressed_foreground == 1


def test_task_complete_and_turn_complete_both_fire_in_one_turn():
    """Same turn, distinct event types -> distinct dedupe identities."""
    notifier, push, _, _ = _make(owned=("s1",), foreground=())
    notifier.observe(_tasklist_completed("s1", turn="t1"))
    notifier.observe(_agent_completed("s1", turn="t1", text="all set"))
    assert {c["event_type"] for c in push.calls} == {"task_complete", "turn_complete"}


def test_task_complete_unowned_never_pushes():
    notifier, push, _, _ = _make(owned=(), foreground=())
    assert notifier.observe(_tasklist_completed("s1")) is None
    assert push.calls == []
    assert notifier.metrics.skipped_unowned == 1


# --------------------------------------------------------------------------- #
# ownership + non-push-worthy                                                  #
# --------------------------------------------------------------------------- #
def test_unowned_session_never_pushes():
    notifier, push, _, _ = _make(owned=(), foreground=())
    assert notifier.observe(_agent_completed("s1")) is None
    assert notifier.observe(_approval("s1")) is None
    assert push.calls == []
    assert notifier.metrics.skipped_unowned == 2


@pytest.mark.parametrize(
    "frame",
    [
        Frame.with_item("s1", FrameKind.ITEM_STARTED,
                        Item("m1", ItemType.AGENT_MESSAGE, ItemStatus.IN_PROGRESS, 0), "t1"),
        Frame.item_delta("s1", "m1", {"text": "x"}),
        Frame.with_item("s1", FrameKind.ITEM_COMPLETED,
                        Item("tool1", ItemType.TOOL_CALL, ItemStatus.COMPLETED, 0, body={"result": "ok"}), "t1"),
        Frame(sid="s1", kind=FrameKind.STATUS, body={"text": "thinking"}, turn="t1"),
        Frame(sid="s1", kind=FrameKind.TURN_COMPLETED, body={}, turn="t1"),
    ],
)
def test_non_pushworthy_frames_ignored(frame):
    notifier, push, _, _ = _make(owned=("s1",))
    assert notifier.observe(frame) is None
    assert push.calls == []
    assert notifier.metrics.skipped_not_pushworthy >= 1


# --------------------------------------------------------------------------- #
# dedupe                                                                       #
# --------------------------------------------------------------------------- #
def test_dedupe_one_banner_per_turn():
    notifier, push, _, _ = _make(owned=("s1",))
    # two agentMessage items in the SAME turn -> one push
    assert notifier.observe(_agent_completed("s1", item_id="m1", turn="t1")) is not None
    assert notifier.observe(_agent_completed("s1", item_id="m2", turn="t1")) is None
    assert len(push.calls) == 1
    assert notifier.metrics.suppressed_dedupe == 1
    # a NEW turn rings again
    assert notifier.observe(_agent_completed("s1", item_id="m3", turn="t2")) is not None
    assert len(push.calls) == 2


def test_dedupe_distinct_approvals_each_ring():
    notifier, push, _, _ = _make(owned=("s1",))
    assert notifier.observe(_approval("s1", request_id="a1", turn="t1")) is not None
    assert notifier.observe(_approval("s1", request_id="a2", turn="t1")) is not None
    # same request id repeated -> deduped
    assert notifier.observe(_approval("s1", request_id="a1", turn="t1")) is None
    assert len(push.calls) == 2


def test_dedupe_lru_evicts_oldest():
    cfg = NotifierConfig(dedupe_capacity=2)
    notifier, push, _, _ = _make(owned=("s1",), config=cfg)
    notifier.observe(_agent_completed("s1", turn="t1"))
    notifier.observe(_agent_completed("s1", turn="t2"))
    notifier.observe(_agent_completed("s1", turn="t3"))  # evicts t1
    assert len(push.calls) == 3
    # t1 no longer remembered -> rings again
    assert notifier.observe(_agent_completed("s1", turn="t1")) is not None
    assert len(push.calls) == 4


# --------------------------------------------------------------------------- #
# disabled                                                                     #
# --------------------------------------------------------------------------- #
def test_disabled_notifier_is_dark():
    cfg = NotifierConfig(enabled=False)
    notifier, push, _, _ = _make(owned=("s1",), config=cfg)
    assert notifier.observe(_agent_completed("s1")) is None
    assert notifier.observe(_approval("s1")) is None
    assert push.calls == []


# --------------------------------------------------------------------------- #
# run() pump over the bus                                                      #
# --------------------------------------------------------------------------- #
async def test_run_pump_observes_bus_frames():
    bus = EventBus()
    push = FakePush()
    gw = FakeGateway({"s1"})
    notifier = Notifier(
        NotifierConfig(), bus, gw,  # type: ignore[arg-type]
        is_foregrounded=lambda sid: False, push_engine=push,
    )
    task = asyncio.create_task(notifier.run())
    # wait until the pump has subscribed
    for _ in range(100):
        if bus.subscriber_count(TOPIC_RELAY_FRAMES) == 1:
            break
        await asyncio.sleep(0.01)
    assert bus.subscriber_count(TOPIC_RELAY_FRAMES) == 1

    bus.publish(TOPIC_RELAY_FRAMES, _agent_completed("s1", turn="t1"))
    bus.publish(TOPIC_RELAY_FRAMES, _approval("s1", request_id="a1", turn="t1"))
    bus.publish(TOPIC_RELAY_FRAMES, _agent_completed("s2", turn="t9"))  # unowned

    for _ in range(100):
        if notifier.metrics.fired >= 2:
            break
        await asyncio.sleep(0.01)

    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

    kinds = sorted(c["event_type"] for c in push.calls)
    assert kinds == ["approval", "turn_complete"]
    assert notifier.metrics.skipped_unowned == 1


async def test_run_pump_fires_clarify_and_task_complete():
    """End-to-end over the bus: a clarify.request and a taskList item.completed
    both reach the reused push_engine through the run() pump."""
    bus = EventBus()
    push = FakePush()
    gw = FakeGateway({"s1"})
    notifier = Notifier(
        NotifierConfig(), bus, gw,  # type: ignore[arg-type]
        is_foregrounded=lambda sid: sid == "s1",  # foregrounded: gates task, not clarify
        push_engine=push,
    )
    task = asyncio.create_task(notifier.run())
    for _ in range(100):
        if bus.subscriber_count(TOPIC_RELAY_FRAMES) == 1:
            break
        await asyncio.sleep(0.01)

    bus.publish(TOPIC_RELAY_FRAMES, _clarify("s1", request_id="c1", turn="t1"))
    # task-complete is suppressed while foregrounded (proves the gate)...
    bus.publish(TOPIC_RELAY_FRAMES, _tasklist_completed("s1", turn="t1"))

    for _ in range(100):
        if notifier.metrics.fired >= 1 and notifier.metrics.suppressed_foreground >= 1:
            break
        await asyncio.sleep(0.01)

    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

    assert [c["event_type"] for c in push.calls] == ["clarify"]  # clarify bypassed the gate
    assert notifier.metrics.suppressed_foreground == 1           # task_complete gated


async def test_run_swallows_observe_errors(monkeypatch):
    bus = EventBus()
    notifier = Notifier(
        NotifierConfig(), bus, FakeGateway({"s1"}),  # type: ignore[arg-type]
        is_foregrounded=lambda sid: False, push_engine=FakePush(),
    )

    boom_calls = {"n": 0}

    def boom(_frame):
        boom_calls["n"] += 1
        raise RuntimeError("kaboom")

    monkeypatch.setattr(notifier, "observe", boom)
    task = asyncio.create_task(notifier.run())
    for _ in range(100):
        if bus.subscriber_count(TOPIC_RELAY_FRAMES) == 1:
            break
        await asyncio.sleep(0.01)
    bus.publish(TOPIC_RELAY_FRAMES, _agent_completed("s1"))
    for _ in range(100):
        if boom_calls["n"] >= 1:
            break
        await asyncio.sleep(0.01)
    # pump survived the raising observe()
    assert not task.done()
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
