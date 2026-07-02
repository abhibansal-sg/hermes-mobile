"""hermes-mobile plugin — multi-client event fan-out engine.

Moved from ``tui_gateway/server.py`` (``_broadcast_enabled`` /
``_broadcast_event``) and ``tui_gateway/ws.py`` (live-transport registry +
per-transport broadcast queue/drain) in the ABH-88 de-patch (W1).

The gateway exposes two tiny seams (see CONTRACT-DEPATCH.md):

* **S1a** ``tui_gateway.server._EVENT_FANOUT_SUBSCRIBERS`` — after the owning
  transport's write, ``write_json`` calls each subscriber with
  ``(obj, sid, owner_transport)``. :func:`on_owner_write` is this plugin's
  subscriber; it checks the ``HERMES_GATEWAY_BROADCAST`` opt-in and mirrors
  the frame to every other live transport.
* **S1b** ``tui_gateway.ws.TRANSPORT_OBSERVERS`` — ``handle_ws`` calls each
  observer with ``("connect" | "disconnect", transport)``.
  :func:`on_transport` maintains the live registry and clears per-transport
  broadcast state on disconnect.

The per-transport bounded queue/drain machinery is the former
``WSTransport.broadcast()`` / ``_drain_broadcast()`` pair, ported to module
functions operating on an external per-transport state record (the stock
``WSTransport`` keeps only its owner-write path). Delivery uses the
transport's own ``_safe_send`` on its owning event loop, so ordering and
failure semantics are unchanged.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import threading
import weakref
from typing import Any

from utils import is_truthy_value

_log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Live-transport registry (former ws.py cluster A)
# ---------------------------------------------------------------------------

# Mutated on the loop thread (connect/disconnect) and iterated from pool
# threads, hence the lock.
_live_lock = threading.Lock()
_live_transports: "set[Any]" = set()


def live_transports() -> "list[Any]":
    """Snapshot of currently-connected WS transports (broadcast fan-out)."""
    with _live_lock:
        return [t for t in _live_transports if not t._closed]


def _session_ids_for_transport(transport: Any) -> "list[str]":
    sessions = _gw_sessions()
    return [
        sid
        for sid, session in sessions.items()
        if isinstance(sid, str)
        and isinstance(session, dict)
        and session.get("transport") is transport
    ]


def _record_mobile_session_transport(session_id: str, transport: Any) -> None:
    try:
        from . import device_tokens

        device_tokens.record_session_transport(session_id, transport)
    except Exception:
        _log.debug("mobile session/device correlation failed", exc_info=True)


def _clear_mobile_session_transport(session_id: str = "", transport: Any = None) -> None:
    try:
        from . import device_tokens

        device_tokens.clear_session_transport(session_id, transport)
    except Exception:
        _log.debug("mobile session/device correlation clear failed", exc_info=True)


def on_transport(action: str, transport: Any) -> None:
    """S1b transport-lifecycle observer (wired by :func:`activate`)."""
    if action == "connect":
        with _live_lock:
            _live_transports.add(transport)
        for sid in _session_ids_for_transport(transport):
            _record_mobile_session_transport(sid, transport)
    elif action == "disconnect":
        for sid in _session_ids_for_transport(transport):
            _clear_mobile_session_transport(sid, transport)
        _clear_mobile_session_transport(transport=transport)
        with _live_lock:
            _live_transports.discard(transport)
        _bcast_states.pop(transport, None)


# ---------------------------------------------------------------------------
# Per-transport bounded broadcast backlog (former WSTransport broadcast path)
# ---------------------------------------------------------------------------

def _broadcast_queue_max() -> int:
    """Per-transport bounded broadcast backlog (frames).

    Caps memory for a chronically slow broadcast client. Overridable via
    ``HERMES_GATEWAY_BROADCAST_QUEUE_MAX`` for tuning; defaults to 256, which at
    a few KB/frame bounds a wedged client to well under ~1 MB while comfortably
    absorbing a normal streaming turn's delta burst.
    """
    raw = os.environ.get("HERMES_GATEWAY_BROADCAST_QUEUE_MAX")
    if raw:
        try:
            val = int(raw)
            if val > 0:
                return val
        except (TypeError, ValueError):
            pass
    return 256


class _BcastState:
    """Per-transport broadcast backlog (formerly ``WSTransport._bcast_*``)."""

    __slots__ = ("queue", "lock", "drain_scheduled", "dropped", "max")

    def __init__(self) -> None:
        import collections

        self.queue: "collections.deque[dict]" = collections.deque()
        self.lock = threading.Lock()
        self.drain_scheduled = False
        self.dropped = 0  # frames coalesced away since the last gap marker
        self.max = _broadcast_queue_max()


# Keyed by transport identity; entries vanish with the transport (and are
# proactively dropped on the disconnect observer).
_bcast_states: "weakref.WeakKeyDictionary[Any, _BcastState]" = (
    weakref.WeakKeyDictionary()
)
_bcast_states_lock = threading.Lock()


def _state_for(transport: Any) -> _BcastState:
    with _bcast_states_lock:
        state = _bcast_states.get(transport)
        if state is None:
            state = _BcastState()
            _bcast_states[transport] = state
        return state


def enqueue(transport: Any, obj: dict) -> bool:
    """Enqueue a mirror frame for delivery, never blocking the caller.

    This is the non-owner fan-out path (the former ``WSTransport.broadcast``).
    It appends to a per-transport bounded FIFO backlog and schedules a single
    drain coroutine on the owning loop. The emitting/agent thread therefore
    never waits on a slow mirror client, and per-client ordering is
    preserved because exactly one drain task pops the deque in FIFO order.

    Overflow policy — **drop-oldest with a single coalesced gap marker**:
    when the backlog is full we evict the oldest queued frame and bump a
    coalesced-drop counter. The next successfully-drained frame carries a
    ``broadcast_gap`` marker (count of dropped frames) so the client knows a
    gap occurred and can reconcile via its REST backfill path. We keep the
    *newest* frames (most useful current state) rather than the oldest, and
    we degrade only the slow client rather than disconnecting it — a phone
    on bad cellular should recover, not get kicked, and the app already
    backfills missed transcript text over REST.

    Returns ``False`` if the transport is already closed, else ``True``
    (best-effort: actual on-wire delivery happens asynchronously).
    """
    if transport._closed:
        return False

    # Snapshot the loop; if it has gone away there is nothing to drain onto.
    loop = transport._loop
    if loop is None:
        return False

    state = _state_for(transport)
    with state.lock:
        if len(state.queue) >= state.max:
            # Drop-oldest: evict the stalest frame, coalesce into a gap.
            try:
                state.queue.popleft()
            except IndexError:  # pragma: no cover - guarded by len check
                pass
            state.dropped += 1
        state.queue.append(obj)
        need_schedule = not state.drain_scheduled
        if need_schedule:
            state.drain_scheduled = True

    if not need_schedule:
        return True

    # Fire-and-forget: schedule the drain task and DO NOT wait on the
    # future. A wedged client's drain stalls only its own loop task, never
    # the emitting thread.
    try:
        on_loop = asyncio.get_running_loop() is loop
    except RuntimeError:
        on_loop = False

    if on_loop:
        loop.create_task(_drain_broadcast(transport, state))
        return True

    from agent.async_utils import safe_schedule_threadsafe

    fut = safe_schedule_threadsafe(_drain_broadcast(transport, state), loop)
    if fut is None:
        # Loop is gone/closed: undo the scheduled flag so a later frame can
        # retry, and treat the transport as dead.
        with state.lock:
            state.drain_scheduled = False
        transport._closed = True
        return False
    return True


async def _drain_broadcast(transport: Any, state: _BcastState) -> None:
    """Drain the per-transport broadcast backlog in FIFO order on the loop.

    Runs as a single task per transport (the ``drain_scheduled`` flag
    serializes drains), so frames leave in enqueue order. Each frame is
    sent with the same ``_safe_send`` used everywhere else; a send failure
    closes the transport and abandons the rest of the backlog.
    """
    try:
        while True:
            with state.lock:
                if transport._closed or not state.queue:
                    state.drain_scheduled = False
                    return
                obj = state.queue.popleft()
                dropped = state.dropped
                state.dropped = 0

            if dropped:
                # Coalesced gap marker: annotate the next delivered frame so
                # the client can detect the gap and backfill. We copy to
                # avoid mutating the shared object other listeners hold.
                obj = {**obj, "broadcast_gap": dropped}

            await transport._safe_send(json.dumps(obj, ensure_ascii=False))
            if transport._closed:
                # Send failed; stop draining and let the backlog be GC'd.
                with state.lock:
                    state.queue.clear()
                    state.drain_scheduled = False
                return
    except Exception as exc:  # pragma: no cover - defensive
        transport._closed = True
        with state.lock:
            state.queue.clear()
            state.drain_scheduled = False
        _log.warning(
            "ws broadcast drain failed peer=%s error=%s",
            getattr(transport, "_peer", "?"),
            exc,
        )


# ---------------------------------------------------------------------------
# Fan-out (former server.py ``_broadcast_enabled`` / ``_broadcast_event``)
# ---------------------------------------------------------------------------

def _broadcast_enabled() -> bool:
    """Opt-in multi-client event fan-out (hermes-mobile plugin).

    When HERMES_GATEWAY_BROADCAST is truthy, session-scoped event frames are
    mirrored to every connected WS client in addition to the owning
    transport, so a phone and a desktop watching the same backend both see
    live streaming regardless of which one submitted the prompt.
    """
    return is_truthy_value(os.environ.get("HERMES_GATEWAY_BROADCAST"))


def _gw_sessions() -> dict:
    """Live gateway session table (lazy; empty when no gateway is loaded)."""
    try:
        from tui_gateway import server as _server

        return _server._sessions
    except Exception:  # pragma: no cover - gateway absent (tests, CLI-only)
        return {}


def _broadcast_event(obj: dict, sid: str, exclude: Any) -> None:
    """Best-effort mirror of *obj* to all live WS transports except *exclude*.

    Frames are enriched with ``stored_session_id`` so clients can correlate
    events from a foreign runtime session with the stored session they have
    open (two clients resuming the same stored session get distinct runtime
    ids).
    """
    listeners = live_transports()
    if not listeners:
        return
    stored_key = (_gw_sessions().get(sid) or {}).get("session_key")
    if stored_key:
        params = dict(obj.get("params") or {})
        params.setdefault("stored_session_id", stored_key)
        obj = {**obj, "params": params}
    for listener in listeners:
        if listener is exclude:
            continue
        try:
            # Non-blocking, per-client isolated delivery: enqueue onto the
            # transport's bounded ordered backlog drained on the ws loop. A slow
            # mirror client (phone on bad cellular) degrades only itself and
            # never stalls this emit thread or the owning transport's frame.
            enqueue(listener, obj)
        except Exception:
            _log.debug("broadcast write failed", exc_info=True)


def on_owner_write(obj: dict, sid: str, owner: Any) -> None:
    """S1a write_json fan-out subscriber (wired by :func:`activate`)."""
    _record_mobile_session_transport(sid, owner)
    if _broadcast_enabled():
        _broadcast_event(obj, sid, exclude=owner)


# ---------------------------------------------------------------------------
# Seam wiring
# ---------------------------------------------------------------------------

def activate() -> None:
    """Wire the fan-out engine into the gateway's S1 seams."""
    from . import _append_unique
    from tui_gateway import server as _server
    from tui_gateway import ws as _ws

    _append_unique(_server, "_EVENT_FANOUT_SUBSCRIBERS", on_owner_write, "broadcast")
    _append_unique(_ws, "TRANSPORT_OBSERVERS", on_transport, "broadcast")
