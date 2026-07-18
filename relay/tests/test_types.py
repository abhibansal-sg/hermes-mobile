"""Contract tests for the shared wire/item types (the frozen surface)."""

from __future__ import annotations

import pytest

from hermes_relay.types import (
    Frame,
    FrameKind,
    GatewayEvent,
    Item,
    ItemStatus,
    ItemType,
    UpstreamMethod,
    UpstreamRequest,
)


def test_item_round_trip():
    item = Item(item_id="i1", type=ItemType.AGENT_MESSAGE, ord=3, summary="hi", body={"text": "yo"})
    assert Item.from_dict(item.to_dict()) == item


def test_frame_with_item_carries_body():
    item = Item(item_id="i1", type=ItemType.TOOL_CALL, ord=0, body={"name": "grep"})
    f = Frame.with_item("sid-1", FrameKind.ITEM_STARTED, item, turn="t1")
    assert f.sid == "sid-1"
    assert f.kind == FrameKind.ITEM_STARTED
    assert f.turn == "t1"
    assert f.seq is None
    assert f.body["item_id"] == "i1"
    assert f.body["type"] == ItemType.TOOL_CALL


def test_frame_to_wire_requires_seq():
    f = Frame(sid="s", kind=FrameKind.STATUS, body={"kind": "compacting", "text": "…"})
    with pytest.raises(ValueError):
        f.to_wire()
    f.seq = 42
    wire = f.to_wire()
    assert wire == {"seq": 42, "sid": "s", "turn": None, "kind": FrameKind.STATUS, "body": f.body}
    # from_wire is the inverse
    assert Frame.from_wire(wire).seq == 42


def test_item_delta_frame_shape():
    f = Frame.item_delta("s", "i9", {"text": "chunk"}, turn="t")
    assert f.kind == FrameKind.ITEM_DELTA
    assert f.body == {"item_id": "i9", "patch": {"text": "chunk"}}


def test_gateway_event_from_rpc_params():
    ev = GatewayEvent.from_rpc_params(
        {"type": "message.delta", "session_id": "abc", "payload": {"text": "hi"}}
    )
    assert ev.type == "message.delta"
    assert ev.session_id == "abc"
    assert ev.payload == {"text": "hi"}


def test_upstream_request_parse():
    req = UpstreamRequest.from_wire({"id": 7, "method": "submit", "params": {"text": "go"}})
    assert req.id == 7
    assert req.method == UpstreamMethod.SUBMIT
    assert req.params == {"text": "go"}


def test_enum_membership_sets_are_frozen():
    assert FrameKind.SNAPSHOT in FrameKind.ALL
    assert ItemType.TOOL_CALL in ItemType.ALL
    assert UpstreamMethod.RESYNC in UpstreamMethod.ALL
    assert ItemStatus.COMPLETED == "completed"
