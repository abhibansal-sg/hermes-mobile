"""Lane 3 tests — DownstreamServer + ReplayRing seq/ack/replay spine.

Hermetic: stdlib + pytest + unittest.mock only, NO network. The phone socket is
a :class:`FakeWS` that records what the relay writes; the gateway is an
``AsyncMock``. The replay ring is the REAL reused ``ReplayRingManager`` imported
through :mod:`hermes_relay.plugin_bridge` (same module the gateway plugin ships).

Coverage the lane brief calls out:
* seq monotonicity (per-connection stamping);
* ring buffering + drop-on-ack;
* resync-replay vs resync-snapshot (gap-too-big);
* a dropped-then-replayed sequence reconciles gap-free.
"""

from __future__ import annotations

import asyncio
import json
from unittest.mock import AsyncMock, MagicMock

import pytest

from hermes_relay import plugin_bridge
from hermes_relay.bus import TOPIC_RELAY_FRAMES
from hermes_relay.downstream import (
    DownstreamConfig,
    DownstreamServer,
    PhoneConnection,
    build_ring,
)
from hermes_relay.bus import EventBus
from hermes_relay.session_state import SessionStore
from hermes_relay.types import (
    Frame,
    FrameKind,
    Item,
    ItemStatus,
    ItemType,
    UpstreamMethod,
    UpstreamRequest,
)


class FakeWS:
    """Records every message the relay writes to the phone socket."""

    def __init__(self) -> None:
        self.sent: list[str] = []

    async def send(self, msg: str) -> None:
        self.sent.append(msg)

    @property
    def frames(self) -> list[dict]:
        """Parsed downstream frames written to this socket, in order."""
        return [json.loads(m) for m in self.sent]


def _ring(frames=None):
    rr = plugin_bridge.import_replay_ring()
    cfg = rr.ReplayRingConfig(frames=frames) if frames else rr.ReplayRingConfig()
    return rr.ReplayRingManager(cfg)


def _conn(ring=None, ws=None, conn_id="connA"):
    return PhoneConnection(conn_id, ws or FakeWS(), ring or _ring())


def _status(text):
    return Frame(sid="s1", kind=FrameKind.STATUS, body={"kind": "info", "text": text})


# ---------------------------------------------------------------------------
# seq monotonicity + ring buffering
# ---------------------------------------------------------------------------


async def test_seq_is_monotonic_per_connection():
    ws = FakeWS()
    conn = _conn(ws=ws)
    seqs = [await conn.send_frame(_status(f"m{i}")) for i in range(5)]
    assert seqs == [1, 2, 3, 4, 5]
    # the wire frames carry the same ascending seqs, in order.
    assert [f["seq"] for f in ws.frames] == [1, 2, 3, 4, 5]
    assert conn.head_seq == 5


async def test_each_connection_has_its_own_seq_spine():
    ring = _ring()
    a, b = _conn(ring=ring, conn_id="A"), _conn(ring=ring, conn_id="B")
    await a.send_frame(_status("x"))
    await a.send_frame(_status("y"))
    await b.send_frame(_status("z"))
    # b's seq starts at 1 independently of a — seq is per-connection.
    assert a.head_seq == 2 and b.head_seq == 1
    assert ring.head("A") == 2 and ring.head("B") == 1


async def test_send_frame_buffers_into_ring():
    ring = _ring()
    conn = _conn(ring=ring)
    for i in range(5):
        await conn.send_frame(_status(f"m{i}"))
    assert ring.frame_count("connA") == 5
    assert ring.floor("connA") == 1
    assert ring.head("connA") == 5


async def test_send_does_not_mutate_the_shared_frame():
    """A frame fanned out to many conns must not have its seq clobbered."""
    frame = _status("shared")
    a = _conn(conn_id="A")
    b = _conn(conn_id="B")
    await a.send_frame(frame)
    await b.send_frame(frame)
    assert frame.seq is None  # the shared object is never stamped in place


# ---------------------------------------------------------------------------
# drop-on-ack
# ---------------------------------------------------------------------------


async def test_ack_drops_acked_frames_and_advances_floor():
    ring = _ring()
    conn = _conn(ring=ring)
    for i in range(5):
        await conn.send_frame(_status(f"m{i}"))
    conn.ack(3)
    # frames 1..3 reclaimed; unacked tail 4,5 retained.
    assert ring.floor("connA") == 4
    assert ring.head("connA") == 5
    assert ring.frame_count("connA") == 2
    assert conn.acked_through == 3


async def test_full_ack_empties_the_ring():
    ring = _ring()
    conn = _conn(ring=ring)
    for i in range(3):
        await conn.send_frame(_status(f"m{i}"))
    conn.ack(3)  # through == head -> everything acked
    assert ring.frame_count("connA") == 0
    assert conn.acked_through == 3


async def test_stale_ack_is_ignored():
    ring = _ring()
    conn = _conn(ring=ring)
    for i in range(5):
        await conn.send_frame(_status(f"m{i}"))
    conn.ack(3)
    conn.ack(2)  # older than the watermark -> no-op
    assert ring.floor("connA") == 4
    assert conn.acked_through == 3


# ---------------------------------------------------------------------------
# resync: replay vs snapshot
# ---------------------------------------------------------------------------


async def test_resync_replays_missing_tail_gap_free():
    ring = _ring()
    live = FakeWS()
    conn = _conn(ring=ring, ws=live)
    for i in range(5):
        await conn.send_frame(_status(f"m{i}"))  # seq 1..5 on the live socket

    # Phone reconnects on a NEW socket having last seen seq 2.
    resync = FakeWS()
    conn._ws = resync
    store = SessionStore()
    await conn.replay(2, store)

    replayed = [f["seq"] for f in resync.frames]
    assert replayed == [3, 4, 5]  # contiguous, gap-free, no re-send of 1,2


async def test_resync_current_replays_nothing():
    conn = _conn()
    for i in range(3):
        await conn.send_frame(_status(f"m{i}"))
    resync = FakeWS()
    conn._ws = resync
    await conn.replay(3, SessionStore())  # last_seq == head
    assert resync.sent == []


async def test_resync_snapshot_when_gap_too_big():
    ring = _ring(frames=3)  # tiny ring so early frames evict
    live = FakeWS()
    conn = _conn(ring=ring, ws=live)

    # Build accumulated item state so the snapshot has content to reconcile.
    store = SessionStore()
    store.apply(
        Frame.with_item(
            "s1",
            FrameKind.ITEM_COMPLETED,
            Item("m1", ItemType.AGENT_MESSAGE, ItemStatus.COMPLETED, 0, body={"text": "hi"}),
            turn="t1",
        )
    )
    for i in range(5):  # seq 1..5, floor evicts to 3
        await conn.send_frame(Frame(sid="s1", kind=FrameKind.STATUS, body={"text": str(i)}))
    assert ring.floor("connA") == 3

    resync = FakeWS()
    conn._ws = resync
    await conn.replay(1, store)  # 1+1=2 is below floor 3 -> FALLBACK snapshot

    snaps = [f for f in resync.frames if f["kind"] == FrameKind.SNAPSHOT]
    assert len(snaps) == 1
    snap = snaps[0]
    assert snap["sid"] == "s1"
    assert snap["body"]["items"][0]["item_id"] == "m1"
    # the snapshot is itself sequenced (a new frame the phone will ack).
    assert snap["seq"] == 6


async def test_dropped_then_replayed_reconciles_gap_free():
    """End-to-end reliability: a dropped frame is recovered contiguously."""
    ring = _ring()
    live = FakeWS()
    conn = _conn(ring=ring, ws=live)
    for i in range(5):
        await conn.send_frame(_status(f"m{i}"))

    # Phone confirms 1,2 then the link drops (it never saw 3,4,5).
    conn.ack(2)
    resync = FakeWS()
    conn._ws = resync
    await conn.replay(2, SessionStore())

    # Reassemble what the phone ends up holding: the acked prefix + the replay.
    phone_seen = [1, 2] + [f["seq"] for f in resync.frames]
    assert phone_seen == [1, 2, 3, 4, 5]  # contiguous, no gap, no dup


# ---------------------------------------------------------------------------
# upstream RPC translation (protocol §5)
# ---------------------------------------------------------------------------


def _server():
    gw = MagicMock()
    gw.session_list = AsyncMock(return_value=[{"id": "s1"}, {"id": "s2"}])
    gw.session_create = AsyncMock(return_value="sNew")
    gw.session_resume = AsyncMock(return_value={"ok": True})
    gw.rest_history = AsyncMock(return_value=[{"role": "user", "text": "hi"}])
    gw.prompt_submit = AsyncMock(return_value={"turn": "t1"})
    gw.approval_respond = AsyncMock(return_value={"ok": True})
    gw.clarify_respond = AsyncMock(return_value={"ok": True})
    gw.session_interrupt = AsyncMock(return_value={"ok": True})
    gw.owns = MagicMock(return_value=False)
    srv = DownstreamServer(DownstreamConfig(), EventBus(), gw, SessionStore())
    return srv, gw


async def _handle(srv, method, params, conn=None):
    conn = conn or srv.register(FakeWS())
    return await srv.handle_upstream(conn, UpstreamRequest(method=method, params=params, id=7))


async def test_list_maps_to_session_list():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, UpstreamMethod.LIST, {})
    gw.session_list.assert_awaited_once()
    assert res["sessions"] == [{"id": "s1"}, {"id": "s2"}]


async def test_open_and_history_are_rest_store_reads():
    srv, gw = _server()
    await srv.start()
    for method in (UpstreamMethod.OPEN, UpstreamMethod.HISTORY):
        gw.rest_history.reset_mock()
        res = await _handle(srv, method, {"session_id": "s9"})
        gw.rest_history.assert_awaited_once_with("s9")
        assert res["messages"] == [{"role": "user", "text": "hi"}]
    # OPEN/HISTORY are the REST store-read path (R0 correction), never a
    # session.resume — resuming a foreign session to read it would reactivate it.
    gw.session_resume.assert_not_awaited()


async def test_submit_new_chat_creates_then_submits():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, UpstreamMethod.SUBMIT, {"text": "hello", "title": "T"})
    gw.session_create.assert_awaited_once()
    gw.prompt_submit.assert_awaited_once_with("sNew", "hello")
    gw.session_resume.assert_not_awaited()
    assert res == {"session_id": "sNew"}


async def test_submit_into_existing_resumes_to_own_then_submits():
    srv, gw = _server()
    gw.owns = MagicMock(return_value=False)
    await srv.start()
    res = await _handle(srv, UpstreamMethod.SUBMIT, {"text": "more", "session_id": "s5"})
    gw.session_resume.assert_awaited_once_with("s5")
    gw.prompt_submit.assert_awaited_once_with("s5", "more")
    gw.session_create.assert_not_awaited()
    assert res == {"session_id": "s5"}


async def test_submit_into_owned_session_skips_resume():
    srv, gw = _server()
    gw.owns = MagicMock(return_value=True)
    await srv.start()
    await _handle(srv, UpstreamMethod.SUBMIT, {"text": "more", "session_id": "s5"})
    gw.session_resume.assert_not_awaited()
    gw.prompt_submit.assert_awaited_once_with("s5", "more")


async def test_resume_owns_idle_session():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, UpstreamMethod.RESUME, {"session_id": "s5"})
    gw.session_resume.assert_awaited_once_with("s5")
    assert res["session_id"] == "s5"


async def test_approve_clarify_interrupt_pass_through():
    srv, gw = _server()
    await srv.start()
    await _handle(srv, UpstreamMethod.APPROVE, {"session_id": "s1", "request_id": "r", "decision": "allow"})
    gw.approval_respond.assert_awaited_once_with("s1", "r", "allow")
    await _handle(srv, UpstreamMethod.CLARIFY, {"session_id": "s1", "request_id": "r", "text": "yes"})
    gw.clarify_respond.assert_awaited_once_with("s1", "r", "yes")
    await _handle(srv, UpstreamMethod.INTERRUPT, {"session_id": "s1"})
    gw.session_interrupt.assert_awaited_once_with("s1")


async def test_ack_and_resync_are_local_no_gateway_hop():
    srv, gw = _server()
    await srv.start()
    conn = srv.register(FakeWS())
    for i in range(3):
        await conn.send_frame(_status(f"m{i}"))
    # ack is local
    assert await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.ACK, {"through": 2})) is None
    assert conn.acked_through == 2
    # resync is local
    conn._ws = FakeWS()
    assert await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.RESYNC, {"last_seq": 2})) is None
    # no gateway method was ever awaited for these two.
    for m in (gw.session_list, gw.prompt_submit, gw.rest_history, gw.session_resume):
        m.assert_not_awaited()


async def test_unknown_method_raises():
    srv, _ = _server()
    await srv.start()
    with pytest.raises(ValueError):
        await _handle(srv, "bogus", {})


# ---------------------------------------------------------------------------
# fan-out + foreground gate
# ---------------------------------------------------------------------------


async def test_dispatch_fans_out_with_independent_seq_per_conn():
    srv, _ = _server()
    await srv.start()
    a = srv.register(FakeWS())
    b = srv.register(FakeWS())
    await srv._dispatch(_status("hi"))
    await srv._dispatch(_status("there"))
    assert a.head_seq == 2 and b.head_seq == 2
    assert [f["seq"] for f in a._ws.frames] == [1, 2]
    assert [f["seq"] for f in b._ws.frames] == [1, 2]


async def test_session_has_live_phone_reflects_foreground():
    srv, _ = _server()
    await srv.start()
    conn = srv.register(FakeWS())
    assert srv.session_has_live_phone("s1") is False
    await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.OPEN, {"session_id": "s1"}))
    assert srv.session_has_live_phone("s1") is True
    srv.unregister(conn)
    assert srv.session_has_live_phone("s1") is False


# ---------------------------------------------------------------------------
# F2 — cross-reconnect resync must snapshot, not silently no-op
# ---------------------------------------------------------------------------


def _completed_item_store(sid="s1", item_id="m1", text="final answer"):
    store = SessionStore()
    store.apply(
        Frame.with_item(
            sid,
            FrameKind.ITEM_COMPLETED,
            Item(item_id, ItemType.AGENT_MESSAGE, ItemStatus.COMPLETED, 0, body={"text": text}),
            turn="t1",
        )
    )
    return store


async def test_resync_on_fresh_reconnect_sends_snapshot():
    """A phone reconnecting on a NEW socket presents a last_seq from the PRIOR
    connection's seq space. The fresh connection's head is 0 (< last_seq), which
    used to hit the CURRENT short-circuit and return NOTHING — stranding the
    phone on stale content. It must instead get a snapshot of known sessions."""
    store = _completed_item_store()
    conn = _conn()  # brand-new connection: head 0, empty ring, empty seen_sids
    await conn.replay(7, store)  # last_seq 7 is from a previous connection
    snaps = [f for f in conn._ws.frames if f["kind"] == FrameKind.SNAPSHOT]
    assert len(snaps) == 1
    assert snaps[0]["sid"] == "s1"
    assert snaps[0]["body"]["items"][0]["item_id"] == "m1"
    assert snaps[0]["body"]["items"][0]["body"]["text"] == "final answer"
    # the snapshot is itself sequenced on the NEW connection's spine.
    assert snaps[0]["seq"] == 1
    assert conn.head_seq == 1


async def test_resync_brand_new_connection_last_seq_zero_is_noop():
    """A truly fresh phone (last_seq 0, head 0) has nothing to catch up on — it
    bootstraps via list/history, so resync stays a no-op (no empty snapshots)."""
    conn = _conn()
    await conn.replay(0, _completed_item_store())
    assert conn._ws.sent == []


# ---------------------------------------------------------------------------
# F1 — a bus-dropped authoritative frame is healed by a snapshot
# ---------------------------------------------------------------------------


class _DropSub:
    """A fake bus subscription that reports a drop after a chosen frame.

    Models bus.py's drop-oldest overflow: ``dropped`` bumps while the fanout
    loop is parked, so the loop must notice it on the next iteration and heal.
    """

    def __init__(self, frames, drop_after_index):
        self._frames = list(frames)
        self._drop_after = drop_after_index
        self._i = 0
        self.dropped = 0

    async def get(self):
        if self._i >= len(self._frames):
            await asyncio.Event().wait()  # park forever until cancelled
        frame = self._frames[self._i]
        if self._i == self._drop_after:
            self.dropped += 1  # a frame was silently dropped before this one
        self._i += 1
        return frame


async def test_bus_drop_heals_connection_with_snapshot():
    srv, _ = _server()
    await srv.start()
    # The Reframer folds the authoritative item into the SHARED store BEFORE the
    # bus (upstream of any drop), so the store still holds it after a drop.
    srv._store.apply(
        Frame.with_item(
            "s1",
            FrameKind.ITEM_COMPLETED,
            Item("m1", ItemType.AGENT_MESSAGE, ItemStatus.COMPLETED, 0, body={"text": "authoritative"}),
            turn="t1",
        )
    )
    conn = srv.register(FakeWS())
    # Frame 0 streams normally (populating seen_sids for s1); the bus drops a
    # frame right before frame 1, which the loop detects and heals.
    srv._sub = _DropSub([_status("delta-a"), _status("delta-b")], drop_after_index=1)
    task = asyncio.create_task(srv._fanout_loop())
    for _ in range(200):
        await asyncio.sleep(0)
        if any(f["kind"] == FrameKind.SNAPSHOT for f in conn._ws.frames):
            break
    srv._stop.set()
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass

    snaps = [f for f in conn._ws.frames if f["kind"] == FrameKind.SNAPSHOT]
    assert len(snaps) == 1  # exactly one heal for the one drop event
    assert snaps[0]["sid"] == "s1"
    assert snaps[0]["body"]["items"][0]["item_id"] == "m1"
    assert snaps[0]["body"]["items"][0]["body"]["text"] == "authoritative"


async def test_no_drop_means_no_heal_snapshot():
    srv, _ = _server()
    await srv.start()
    srv._store.apply(
        Frame.with_item(
            "s1", FrameKind.ITEM_COMPLETED,
            Item("m1", ItemType.AGENT_MESSAGE, ItemStatus.COMPLETED, 0, body={"text": "x"}), turn="t1",
        )
    )
    conn = srv.register(FakeWS())
    srv._sub = _DropSub([_status("a"), _status("b")], drop_after_index=-1)  # never drops
    task = asyncio.create_task(srv._fanout_loop())
    for _ in range(50):
        await asyncio.sleep(0)
    srv._stop.set()
    task.cancel()
    try:
        await task
    except asyncio.CancelledError:
        pass
    assert [f["kind"] for f in conn._ws.frames] == [FrameKind.STATUS, FrameKind.STATUS]


# ---------------------------------------------------------------------------
# F3 — foreground gate: history never gags; replace-not-accumulate; explicit method
# ---------------------------------------------------------------------------


async def test_history_read_does_not_foreground_session():
    srv, _ = _server()
    await srv.start()
    conn = srv.register(FakeWS())
    await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.HISTORY, {"session_id": "s1"}))
    # A background store sync must NOT foreground the session (else it would
    # permanently suppress that session's completion/error pushes).
    assert srv.session_has_live_phone("s1") is False


async def test_open_replaces_previous_foreground():
    srv, _ = _server()
    await srv.start()
    conn = srv.register(FakeWS())
    await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.OPEN, {"session_id": "s1"}))
    assert srv.session_has_live_phone("s1") is True
    # Navigating to another chat clears the first — s1 is no longer gagged.
    await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.OPEN, {"session_id": "s2"}))
    assert srv.session_has_live_phone("s2") is True
    assert srv.session_has_live_phone("s1") is False


async def test_explicit_foreground_method_sets_and_clears():
    srv, gw = _server()
    await srv.start()
    conn = srv.register(FakeWS())
    r = await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.FOREGROUND, {"session_id": "s1"}))
    assert r is None  # local, no gateway hop
    assert srv.session_has_live_phone("s1") is True
    # null clears (app backgrounded) -> pushes re-enabled.
    await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.FOREGROUND, {"session_id": None}))
    assert srv.session_has_live_phone("s1") is False
    gw.session_list.assert_not_awaited()


async def test_submit_and_resume_replace_foreground():
    srv, gw = _server()
    gw.owns = MagicMock(return_value=True)
    await srv.start()
    conn = srv.register(FakeWS())
    await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.OPEN, {"session_id": "s1"}))
    await srv.handle_upstream(conn, UpstreamRequest(UpstreamMethod.SUBMIT, {"text": "hi", "session_id": "s2"}))
    assert srv.session_has_live_phone("s1") is False
    assert srv.session_has_live_phone("s2") is True
