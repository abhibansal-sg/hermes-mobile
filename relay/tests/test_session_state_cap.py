"""SessionStore LRU bound — regression for the soak T7 I6 finding.

The relay-soak marathon (T7, RELAY-SOAK-SPEC.md I6) streams through one fresh
session after another for hours. On origin/main the SessionStore._states map
lazily creates a SessionState per ever-seen session and NEVER evicts
(``drop()`` has no caller), so RSS grows monotonically with the total number
of unique sessions — sub-threshold per hour (~8 MiB/h measured at marathon
intensity) yet unbounded over a relay's service lifetime: the "owned-session
lifecycle leak" suspect class the soak was built to pin down.

The fix caps the registry LRU (completed states evict least-recently-used
first; IN_PROGRESS states are pinned mid-turn). These tests FAIL on the
unbounded origin/main implementation (the store simply holds every session)
and PASS with the bound.

Eviction is correct-by-construction because:
* reconnect-window recovery rides the per-connection replay ring, not this
  store (downstream.py PhoneConnection.replay);
* phones reconcile snapshots by item_id as a UNION, so an evicted session's
  later snapshot heals with live frames — it never voids the phone's copy;
* cold reads go to the gateway REST (downstream.py OPEN/HISTORY ->
  rest_history), never through this store.
"""

from __future__ import annotations

import pytest

from hermes_relay.session_state import (
    DEFAULT_SESSION_STORE_CAPACITY,
    SessionStore,
)
from hermes_relay.types import Frame, FrameKind, Item, ItemStatus, ItemType


def _completed_item_frame(sid: str, n: int) -> Frame:
    """A completed agentMessage item frame for ``sid`` (a finished turn)."""
    item = Item(
        item_id=f"{sid}:agent-{n}",
        type=ItemType.AGENT_MESSAGE,
        status=ItemStatus.COMPLETED,
        ord=n,
        body={"text": f"done {n}"},
    )
    return Frame.with_item(sid=sid, kind=FrameKind.ITEM_COMPLETED, item=item)


def _in_progress_item_frame(sid: str) -> Frame:
    """An IN_PROGRESS agentMessage item frame (a turn mid-stream)."""
    item = Item(
        item_id=f"{sid}:agent-live",
        type=ItemType.AGENT_MESSAGE,
        status=ItemStatus.IN_PROGRESS,
        ord=0,
        body={"text": "streaming..."},
    )
    return Frame.with_item(sid=sid, kind=FrameKind.ITEM_STARTED, item=item)


def test_completed_states_evict_lru_beyond_capacity() -> None:
    """32 completed sessions through a cap-8 store leave <= 8 states, with the
    MOST-recently-used survivors and the oldest evicted (fail-before: 32)."""
    store = SessionStore(capacity=8)
    sids = [f"sess-{i:03d}" for i in range(32)]
    for sid in sids:
        store.apply(_completed_item_frame(sid, 0))

    assert len(store._states) <= 8, (
        f"store holds {len(store._states)} completed session states — "
        "unbounded growth (the soak I6 leak)"
    )
    # The newest sessions survive; the oldest are gone.
    assert sids[-1] in store
    assert sids[-8] in store
    assert sids[0] not in store
    # Evicted states' snapshots rebuild empty (no crash); phones union-heal.
    snap = store.snapshot(sids[0])
    assert snap["items"] == []


def test_lru_touch_protects_recently_used_sessions() -> None:
    """Reading an OLD session moves it to the MRU tail so the flood evicts a
    newer-but-untouched one instead."""
    store = SessionStore(capacity=4)
    for i in range(4):
        store.apply(_completed_item_frame(f"sess-{i:03d}", 0))
    # Touch the OLDEST session, then add one more.
    store.get("sess-000")
    store.apply(_completed_item_frame("sess-new", 0))
    assert "sess-000" in store, "recently-used session must survive"
    assert "sess-001" not in store, "the untouched session evicts instead"
    assert len(store._states) == 4


def test_in_progress_states_are_pinned() -> None:
    """A mid-stream session is NEVER evicted, even as the oldest entry — its
    snapshot must stay foldable while the turn runs."""
    store = SessionStore(capacity=4)
    store.apply(_in_progress_item_frame("sess-live"))
    for i in range(20):
        store.apply(_completed_item_frame(f"sess-{i:03d}", 0))
    assert "sess-live" in store, "an IN_PROGRESS turn's state was evicted"
    st = store._states["sess-live"]
    assert any(it.status == ItemStatus.IN_PROGRESS for it in st.items.values())


def test_default_capacity_is_bounded_and_overridable(monkeypatch) -> None:
    """The default cap is finite; HERMES_RELAY_SESSION_STORE_CAPACITY overrides
    it; 0 restores the legacy unbounded behavior."""
    assert DEFAULT_SESSION_STORE_CAPACITY > 0
    store = SessionStore()
    assert store.capacity == DEFAULT_SESSION_STORE_CAPACITY

    monkeypatch.setenv("HERMES_RELAY_SESSION_STORE_CAPACITY", "16")
    assert SessionStore().capacity == 16

    monkeypatch.setenv("HERMES_RELAY_SESSION_STORE_CAPACITY", "bogus")
    assert SessionStore().capacity == DEFAULT_SESSION_STORE_CAPACITY

    unbounded = SessionStore(capacity=0)
    for i in range(64):
        unbounded.apply(_completed_item_frame(f"sess-{i:03d}", 0))
    assert len(unbounded._states) == 64, "capacity=0 must not evict"


def test_marathon_flood_stays_bounded_at_default_cap() -> None:
    """The soak reproducer at scale: more unique sessions than the default cap
    leave exactly the cap's worth of states (fail-before: len == 4200)."""
    store = SessionStore()  # default cap
    n = DEFAULT_SESSION_STORE_CAPACITY + 104
    for i in range(n):
        store.apply(_completed_item_frame(f"sess-{i:05d}", 0))
    assert len(store._states) == DEFAULT_SESSION_STORE_CAPACITY


def test_drop_and_session_ids_still_work() -> None:
    """The existing public surface is unchanged by the LRU bound."""
    store = SessionStore(capacity=8)
    store.apply(_completed_item_frame("sess-a", 0))
    assert "sess-a" in store.session_ids()
    assert store.drop("sess-a") is True
    assert store.drop("sess-a") is False
    assert "sess-a" not in store
