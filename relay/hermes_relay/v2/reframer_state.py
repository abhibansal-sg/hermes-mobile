"""Bounded metadata-only state for the HRP/2 Gateway Reframer.

HRP/2 checkpoints and item bodies live durably in :class:`RelayStorage`; the
legacy in-memory SessionStore must not duplicate them or repeatedly concatenate
streamed text.  This adapter retains only enough short-lived metadata to pair a
start with its completion and allocate process-local ordinals.  The durable V2
projection assigns the real session ordering coordinate.
"""

from __future__ import annotations

from collections import OrderedDict

from ..session_state import SessionState, SessionStore
from ..types import Frame, FrameKind, Item


DEFAULT_MAX_ACTIVE_REFRAMER_SESSIONS = 1_024
DEFAULT_MAX_OPEN_ITEMS_PER_SESSION = 4_096


class V2ReframerSessionState(SessionState):
    """Open-item metadata only; never retains streamed or completed bodies."""

    def __init__(self, sid: str, *, max_open_items: int) -> None:
        super().__init__(sid=sid)
        self.max_open_items = max_open_items

    def apply(self, frame: Frame) -> None:
        if frame.turn:
            self.last_turn = frame.turn
        if frame.kind == FrameKind.ITEM_STARTED:
            item = Item.from_dict(frame.body)
            if item.item_id not in self.items:
                if len(self.order) >= self.max_open_items:
                    oldest = self.order.pop(0)
                    self.items.pop(oldest, None)
                self.order.append(item.item_id)
            if item.ord >= self._next_ord:
                self._next_ord = item.ord + 1
            # Reframer only reads identity/status/ord. Avoid retaining prompt,
            # tool result, reasoning, or cumulative text bodies in memory.
            self.items[item.item_id] = Item(
                item_id=item.item_id,
                type=item.type,
                status=item.status,
                ord=item.ord,
                summary="",
                body={},
            )
        elif frame.kind == FrameKind.ITEM_COMPLETED:
            item = Item.from_dict(frame.body)
            if item.ord >= self._next_ord:
                self._next_ord = item.ord + 1
            self.items.pop(item.item_id, None)
            try:
                self.order.remove(item.item_id)
            except ValueError:
                pass
        # Deltas belong only to RelayStorage's revisioned V2 projection.


class V2ReframerStore(SessionStore):
    """LRU-bounded registry of currently active Reframer sessions."""

    transient = True

    def __init__(
        self,
        *,
        max_sessions: int = DEFAULT_MAX_ACTIVE_REFRAMER_SESSIONS,
        max_open_items: int = DEFAULT_MAX_OPEN_ITEMS_PER_SESSION,
    ) -> None:
        if max_sessions <= 0 or max_open_items <= 0:
            raise ValueError("V2 Reframer state bounds must be positive")
        self.max_sessions = max_sessions
        self.max_open_items = max_open_items
        self._states: OrderedDict[str, V2ReframerSessionState] = OrderedDict()

    def get(self, sid: str) -> V2ReframerSessionState:
        state = self._states.get(sid)
        if state is None:
            if len(self._states) >= self.max_sessions:
                self._states.popitem(last=False)
            state = V2ReframerSessionState(
                sid,
                max_open_items=self.max_open_items,
            )
            self._states[sid] = state
        else:
            self._states.move_to_end(sid)
        return state


__all__ = [
    "DEFAULT_MAX_ACTIVE_REFRAMER_SESSIONS",
    "DEFAULT_MAX_OPEN_ITEMS_PER_SESSION",
    "V2ReframerSessionState",
    "V2ReframerStore",
]
