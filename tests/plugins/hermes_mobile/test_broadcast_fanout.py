"""Multi-client broadcast fan-out tests (hermes-mobile plugin).

Moved verbatim from ``tests/test_tui_gateway_server.py`` in the ABH-88
de-patch (W1). The code under test lives in
``plugins/hermes-mobile/broadcast.py`` (formerly ``server._broadcast_event``
+ the ``WSTransport.broadcast()``/``_drain_broadcast()`` queue machinery in
``tui_gateway/ws.py``); only the API names were adapted:

* ``transport.broadcast(obj)``      → ``bc.enqueue(transport, obj)``
* ``t._bcast_queue`` / ``_bcast_dropped`` / ``_bcast_drain_scheduled`` /
  ``_bcast_max``                    → ``bc._state_for(t).queue`` / ``.dropped``
  / ``.drain_scheduled`` / ``.max``
* ``server._broadcast_event``       → ``bc._broadcast_event``
* ``ws.live_transports``            → ``bc.live_transports``

Tests that exercise the ``server.write_json`` fan-out use the
``wired_gateway`` fixture so the plugin's ``on_owner_write`` subscriber is
registered on the S1a seam (``server._EVENT_FANOUT_SUBSCRIBERS``).

# ===========================================================================
# F3 — non-blocking broadcast fan-out (head-of-line fix).
#
# The bug: the broadcast fan-out delivered each non-owner mirror copy via
# WSTransport.write, which blocks the emitting/pool thread up to
# _WS_WRITE_TIMEOUT_S (10s) per client. One slow client (phone on bad cellular)
# stalled the emit AND every other client, including the session owner.
#
# The fix: enqueue() appends onto a per-transport bounded ordered backlog
# drained by a single task on the ws loop. These tests prove: the emit
# thread never blocks on a slow client; other clients still receive promptly;
# per-client ordering is preserved; the drop-oldest+coalesced-gap overflow
# policy is bounded and observable; and the owner path / stored_session_id
# enrichment / broadcast gate are unchanged.
# ===========================================================================
"""

import json
import time

import asyncio as _f3_asyncio
import threading as _f3_threading

from tui_gateway import server
from tui_gateway import ws as gw_ws


class _F3FakeWS:
    """Mock starlette WebSocket whose send_text can be stalled on demand.

    Records every frame sent (in order). A threading.Event gate lets a test
    wedge a "slow client" so its drain blocks while other transports proceed.
    """

    def __init__(self, *, gate=None, peer_host="1.2.3.4", peer_port=5555):
        self.sent: list = []
        self._gate = gate  # threading.Event; if set-cleared, send_text waits
        self.close_calls: list[dict] = []
        self.client = type("C", (), {"host": peer_host, "port": peer_port})()

    async def accept(self):
        return None

    async def send_text(self, line: str):
        if self._gate is not None:
            # Block the drain coroutine until the test releases the gate. We
            # poll the threading.Event without holding the loop hostage to other
            # transports' tasks (each transport drains as its own task).
            while not self._gate.is_set():
                await _f3_asyncio.sleep(0.005)
        self.sent.append(json.loads(line))

    async def close(self, *args, **kwargs):
        self.close_calls.append({"args": args, "kwargs": kwargs})
        return None


class _F3Loop:
    """A real asyncio loop running in a background thread.

    Mirrors production: the loop owns the sockets; the emit/pool thread calls
    bc.enqueue() from OUTSIDE the loop thread.
    """

    def __init__(self):
        self.loop = _f3_asyncio.new_event_loop()
        self._thread = _f3_threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def _run(self):
        _f3_asyncio.set_event_loop(self.loop)
        self.loop.run_forever()

    def stop(self):
        self.loop.call_soon_threadsafe(self.loop.stop)
        self._thread.join(timeout=5)
        self.loop.close()


def _f3_wait_until(predicate, timeout=3.0, interval=0.01):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def test_f3_broadcast_emit_thread_never_blocks_on_slow_client(broadcast_engine):
    """A wedged mirror client must not stall the emitting thread."""
    bc = broadcast_engine
    rt = _F3Loop()
    try:
        slow_gate = _f3_threading.Event()  # left UNSET => slow client hangs
        slow_ws = _F3FakeWS(gate=slow_gate, peer_port=1)
        fast_ws = _F3FakeWS(peer_port=2)  # no gate => sends immediately
        slow = gw_ws.WSTransport(slow_ws, rt.loop, peer="slow")
        fast = gw_ws.WSTransport(fast_ws, rt.loop, peer="fast")

        frame = {"jsonrpc": "2.0", "method": "event",
                 "params": {"type": "message.delta", "session_id": "s"}}

        # Emit from a non-loop thread (as the pool/agent thread does). Time it:
        # enqueue must return effectively instantly even though slow is wedged.
        t0 = time.perf_counter()
        assert bc.enqueue(slow, frame) is True
        assert bc.enqueue(fast, frame) is True
        elapsed = time.perf_counter() - t0

        # Would be ~10s (or unbounded) under the old blocking write path.
        assert elapsed < 1.0, f"emit thread blocked for {elapsed:.2f}s"

        # The fast client receives promptly despite the slow client hanging.
        assert _f3_wait_until(lambda: len(fast_ws.sent) == 1)
        assert fast_ws.sent[0]["params"]["type"] == "message.delta"
        # Slow client has NOT received (its drain is wedged in send_text).
        assert slow_ws.sent == []

        # Release the slow client: it eventually drains its backlog.
        slow_gate.set()
        assert _f3_wait_until(lambda: len(slow_ws.sent) == 1)
    finally:
        rt.stop()


def test_f3_broadcast_preserves_per_client_ordering(broadcast_engine):
    """All frames for one transport arrive in enqueue order."""
    bc = broadcast_engine
    rt = _F3Loop()
    try:
        ws_obj = _F3FakeWS()
        t = gw_ws.WSTransport(ws_obj, rt.loop, peer="ordered")
        n = 50
        for i in range(n):
            assert bc.enqueue(t, {"seq": i}) is True
        assert _f3_wait_until(lambda: len(ws_obj.sent) == n, timeout=5.0)
        assert [f["seq"] for f in ws_obj.sent] == list(range(n))
    finally:
        rt.stop()


def test_f3_broadcast_overflow_drops_oldest_with_coalesced_gap(
    monkeypatch, broadcast_engine
):
    """A chronically slow client is bounded: drop-oldest + single gap marker."""
    bc = broadcast_engine
    monkeypatch.setenv("HERMES_GATEWAY_BROADCAST_QUEUE_MAX", "4")
    rt = _F3Loop()
    try:
        gate = _f3_threading.Event()  # keep the drain wedged while we overfill
        ws_obj = _F3FakeWS(gate=gate)
        t = gw_ws.WSTransport(ws_obj, rt.loop, peer="overflow")
        state = bc._state_for(t)  # fresh state reads the env override
        assert state.max == 4

        # Enqueue many more than the cap while the drain is wedged on frame 0.
        # The first popped frame (seq 0) is in flight inside send_text; the
        # backlog holds at most state.max frames, the rest drop-oldest.
        total = 20
        for i in range(total):
            assert bc.enqueue(t, {"seq": i}) is True

        # Memory is bounded: queue never exceeds the cap.
        assert len(state.queue) <= state.max
        # Oldest queued frames were evicted, so drops were recorded.
        assert state.dropped > 0

        # Release the drain; it sends what remains. The client must end on the
        # NEWEST frame (drop-oldest keeps current state) and see a coalesced gap
        # marker (count of dropped frames) on the first frame it drains after
        # the drops, never one marker per dropped frame.
        gate.set()
        assert _f3_wait_until(lambda: len(ws_obj.sent) >= 1, timeout=5.0)
        # Let the backlog fully flush.
        assert _f3_wait_until(
            lambda: len(state.queue) == 0 and not state.drain_scheduled,
            timeout=5.0,
        )

        seqs = [f["seq"] for f in ws_obj.sent]
        # Strictly increasing: ordering preserved even across drops.
        assert seqs == sorted(seqs)
        # The very newest frame was retained and delivered.
        assert seqs[-1] == total - 1
        # Far fewer than `total` frames were delivered (the rest were dropped).
        assert len(seqs) <= state.max + 1

        # Exactly one coalesced gap marker carries the total dropped count;
        # there is no per-dropped-frame marker storm.
        gap_frames = [f for f in ws_obj.sent if "broadcast_gap" in f]
        assert len(gap_frames) == 1
        dropped_reported = gap_frames[0]["broadcast_gap"]
        assert dropped_reported > 0
        # Every delivered seq plus the reported drops accounts for the frame 0
        # that was in flight when the gate held, i.e. nothing is silently lost
        # beyond what the gap marker advertises.
        assert dropped_reported + len(seqs) >= total - 1
    finally:
        rt.stop()


def test_f3_broadcast_one_slow_client_does_not_starve_a_fast_one(broadcast_engine):
    """Two clients: a wedged one must not delay frames to a healthy one."""
    bc = broadcast_engine
    rt = _F3Loop()
    try:
        slow_gate = _f3_threading.Event()
        slow_ws = _F3FakeWS(gate=slow_gate, peer_port=1)
        fast_ws = _F3FakeWS(peer_port=2)
        slow = gw_ws.WSTransport(slow_ws, rt.loop, peer="slow")
        fast = gw_ws.WSTransport(fast_ws, rt.loop, peer="fast")

        # Emit 10 frames to both (as _broadcast_event would, per listener).
        for i in range(10):
            bc.enqueue(slow, {"seq": i})
            bc.enqueue(fast, {"seq": i})

        # Fast client gets ALL frames in order while slow is still wedged.
        assert _f3_wait_until(lambda: len(fast_ws.sent) == 10, timeout=3.0)
        assert [f["seq"] for f in fast_ws.sent] == list(range(10))
        assert slow_ws.sent == []  # slow still blocked, isolated

        slow_gate.set()
        assert _f3_wait_until(lambda: len(slow_ws.sent) >= 1, timeout=5.0)
    finally:
        rt.stop()


def test_f3_broadcast_event_uses_nonblocking_path_and_keeps_owner_untouched(
    monkeypatch, wired_gateway
):
    """The write_json fan-out must use the non-blocking enqueue path on mirrors,
    leave the owner's write path alone, and preserve stored_session_id."""
    server_mod, _ws, _pn, bc = wired_gateway
    monkeypatch.setenv("HERMES_GATEWAY_BROADCAST", "1")

    class _Spy:
        def __init__(self):
            self.broadcasts = []
            self.writes = []
            self._closed = False

        def broadcast(self, obj):
            self.broadcasts.append(obj)
            return True

        def write(self, obj):
            self.writes.append(obj)
            return True

    owner = _Spy()
    mirror = _Spy()

    # The owning transport is registered on the session; the mirror is just a
    # live listener. live_transports() returns both. Route the engine's
    # enqueue() (the former transport.broadcast()) into the spy recorder.
    monkeypatch.setattr(bc, "live_transports", lambda: [owner, mirror])
    monkeypatch.setattr(bc, "enqueue", lambda t, obj: t.broadcast(obj))
    server_mod._sessions["f3_sid"] = {"session_key": "stored-f3", "transport": owner}
    try:
        frame = {"jsonrpc": "2.0", "method": "event",
                 "params": {"type": "message.delta", "session_id": "f3_sid"}}
        # Owner delivery happens in write_json via owner.write; the broadcast
        # fan-out (excluding the owner) goes through _broadcast_event.
        assert server_mod.write_json(frame) is True
    finally:
        server_mod._sessions.pop("f3_sid", None)

    # (a) Owner path unchanged: exactly one synchronous write to the owner.
    assert len(owner.writes) == 1
    assert owner.writes[0]["params"]["type"] == "message.delta"
    # Owner is excluded from the broadcast fan-out (no double delivery).
    assert owner.broadcasts == []

    # Mirror got the frame via the NON-BLOCKING enqueue path, never write().
    assert mirror.writes == []
    assert len(mirror.broadcasts) == 1
    # (d) stored_session_id enrichment unchanged on the mirrored frame.
    assert mirror.broadcasts[0]["params"]["stored_session_id"] == "stored-f3"


def test_f3_broadcast_gate_unchanged_when_disabled(monkeypatch, wired_gateway):
    """HERMES_GATEWAY_BROADCAST gate is honoured: no fan-out when unset."""
    server_mod, _ws, _pn, bc = wired_gateway
    monkeypatch.delenv("HERMES_GATEWAY_BROADCAST", raising=False)

    class _Spy:
        def __init__(self):
            self.broadcasts = []
            self.writes = []
            self._closed = False

        def broadcast(self, obj):
            self.broadcasts.append(obj)
            return True

        def write(self, obj):
            self.writes.append(obj)
            return True

    owner = _Spy()
    mirror = _Spy()
    monkeypatch.setattr(bc, "live_transports", lambda: [owner, mirror])
    monkeypatch.setattr(bc, "enqueue", lambda t, obj: t.broadcast(obj))
    server_mod._sessions["f3_sid2"] = {"session_key": "k", "transport": owner}
    try:
        frame = {"jsonrpc": "2.0", "method": "event",
                 "params": {"type": "message.delta", "session_id": "f3_sid2"}}
        assert server_mod.write_json(frame) is True
    finally:
        server_mod._sessions.pop("f3_sid2", None)

    # Owner still written; mirror gets NOTHING because the gate is off.
    assert len(owner.writes) == 1
    assert mirror.broadcasts == []
    assert mirror.writes == []


def test_f3_broadcast_returns_false_when_closed(broadcast_engine):
    """A closed transport refuses new broadcast frames (no resurrection)."""
    bc = broadcast_engine
    rt = _F3Loop()
    try:
        ws_obj = _F3FakeWS()
        t = gw_ws.WSTransport(ws_obj, rt.loop, peer="closed")
        t.close()
        assert bc.enqueue(t, {"seq": 0}) is False
        # Nothing queued or sent.
        assert len(bc._state_for(t).queue) == 0
        time.sleep(0.05)
        assert ws_obj.sent == []
    finally:
        rt.stop()


# ===========================================================================
# Batch G / ABH-52 — owner-write head-of-line fix (S7).
#
# DROPPED at the Phase-2 upstream rebase. Upstream's WSTransport converged on
# a fire-and-forget owner-write path (loop-thread writes never block; pool-
# thread writes are bounded by _WS_WRITE_TIMEOUT_S and evict the transport on
# timeout). A wedged owner therefore stalls one frame once, then is evicted —
# not the strict "never blocks" guarantee S7's bounded owner queue gave. We
# adopt upstream's transport contract here to keep the stock footprint minimal;
# S7 remains a strong standalone upstream-PR candidate (SEAM-LEDGER S7). The
# genuine "a slow mirror never starves a fast one" property is still covered by
# the plugin-side fan-out tests above (the broadcast engine keeps its own
# bounded per-transport drain), which are independent of the owner-write path.
# ===========================================================================
