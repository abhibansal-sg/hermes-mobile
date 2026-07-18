"""Tests for the SessionState resume-as-items accumulator."""

from __future__ import annotations

from hermes_relay.session_state import SessionState, SessionStore
from hermes_relay.types import Frame, FrameKind, Item, ItemStatus, ItemType


def _started(sid, item_id, itype, ord_, turn="t1"):
    return Frame.with_item(sid, FrameKind.ITEM_STARTED, Item(item_id, itype, ItemStatus.IN_PROGRESS, ord_), turn)


def _completed(sid, item_id, itype, ord_, body, turn="t1"):
    return Frame.with_item(
        sid, FrameKind.ITEM_COMPLETED, Item(item_id, itype, ItemStatus.COMPLETED, ord_, body=body), turn
    )


def test_apply_started_then_delta_then_completed_authoritative():
    st = SessionState(sid="s1")
    st.apply(_started("s1", "m1", ItemType.AGENT_MESSAGE, 0))
    st.apply(Frame.item_delta("s1", "m1", {"text": "Par"}))
    st.apply(Frame.item_delta("s1", "m1", {"text": "is"}))
    # mid-stream snapshot reflects accumulated deltas
    assert st.items["m1"].body["text"] == "Paris"
    # completed replaces wholesale (authoritative)
    st.apply(_completed("s1", "m1", ItemType.AGENT_MESSAGE, 0, {"text": "Paris is the capital."}))
    assert st.items["m1"].status == ItemStatus.COMPLETED
    assert st.items["m1"].body["text"] == "Paris is the capital."


def test_ordering_by_ord():
    st = SessionState(sid="s1")
    st.apply(_started("s1", "b", ItemType.TOOL_CALL, 1))
    st.apply(_started("s1", "a", ItemType.AGENT_MESSAGE, 0))
    ordered = [it.item_id for it in st.ordered_items()]
    assert ordered == ["a", "b"]


def test_snapshot_body_shape():
    st = SessionState(sid="s1")
    st.apply(_completed("s1", "m1", ItemType.AGENT_MESSAGE, 0, {"text": "hi"}))
    snap = st.snapshot(cursor=1421)
    assert snap["cursor"] == 1421
    assert len(snap["items"]) == 1
    assert snap["items"][0]["item_id"] == "m1"


def test_delta_after_completed_is_ignored():
    st = SessionState(sid="s1")
    st.apply(_completed("s1", "m1", ItemType.AGENT_MESSAGE, 0, {"text": "final"}))
    st.apply(Frame.item_delta("s1", "m1", {"text": "LATE"}))
    assert st.items["m1"].body["text"] == "final"


def test_store_lazy_create_and_drop():
    store = SessionStore()
    assert "s1" not in store
    store.apply(_started("s1", "m1", ItemType.AGENT_MESSAGE, 0))
    assert "s1" in store
    assert store.drop("s1") is True
    assert store.drop("s1") is False
