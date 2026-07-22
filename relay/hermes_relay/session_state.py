"""Per-session item accumulator — the source of the resume-as-items snapshot.

The relay is stateless on the wire (deltas are fire-and-forget), but it must be
able to answer a phone's ``resync`` with a full ``snapshot`` of the current
items (protocol §3/§4) when the phone's ``last_seq`` has fallen below the
replay ring floor. :class:`SessionState` is that accumulated truth: it folds the
stream of :class:`~hermes_relay.types.Frame` objects the Reframer produces into
the current ordered item set per session, honoring the
``completed``-is-authoritative rule.

Ownership of the two coordinate systems:

* The **ReplayRing** (``plugins/hermes-mobile/replay_ring.py``) holds the last N
  *sequenced wire frames* for gap-free replay. Cheap, bounded, lossy by design.
* **SessionState** holds the *reconstructed items* so a cold resync (ring miss)
  can still hand the phone a coherent ``snapshot`` to reconcile by ``item_id``.

Both are kept; they answer different resume regimes (§4). This class is pure
in-memory bookkeeping — no I/O, no wire access — and is intentionally simple to
keep the Reframer and DownstreamServer lanes from colliding on item bookkeeping.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any, Optional

from .types import Frame, FrameKind, Item, ItemStatus

# R4 L6 — how long a phone-origin prompt marker stays armed (see
# ``SessionStore.mark_local_prompt``). A turn that never STARTS (the submit
# errored at the gateway) leaves its marker unconsumed; the TTL bounds how
# long it could mask a foreign turn carrying the identical text. message.start
# arrives seconds after a successful submit, so 120 s is wide and safe.
_LOCAL_PROMPT_TTL_S = 120.0


@dataclass
class SessionState:
    """Accumulated item set for ONE session, ordered by ``ord``.

    Apply frames as the Reframer emits them; read a :meth:`snapshot` on resync.
    ``last_turn`` tracks the most recent turn id seen (for the snapshot cursor).
    """

    sid: str
    items: dict[str, Item] = field(default_factory=dict)  # item_id -> Item
    order: list[str] = field(default_factory=list)        # item_id in first-seen order
    last_turn: Optional[str] = None
    _next_ord: int = 0

    # -- ord assignment ---------------------------------------------------
    def allocate_ord(self) -> int:
        """Return the next monotonic ``ord`` for a newly started item."""
        o = self._next_ord
        self._next_ord += 1
        return o

    # -- fold ------------------------------------------------------------
    def apply(self, frame: Frame) -> None:
        """Fold one downstream :class:`Frame` into the accumulated item set.

        * ``item.started``   — inserts/overwrites the item skeleton.
        * ``item.delta``     — best-effort append into the in-progress item body
          (the authoritative repaint still comes on ``item.completed``; this is
          only so a snapshot taken mid-stream is not empty).
        * ``item.completed`` — replaces the item wholesale (authoritative).
        Non-item frames (turn/status/title/approval/clarify/snapshot) update
        ``last_turn`` only; they are not ordered items.
        """
        if frame.turn:
            self.last_turn = frame.turn

        kind = frame.kind
        if kind in (FrameKind.ITEM_STARTED, FrameKind.ITEM_COMPLETED):
            item = Item.from_dict(frame.body)
            if item.item_id not in self.items:
                self.order.append(item.item_id)
                if item.ord >= self._next_ord:
                    self._next_ord = item.ord + 1
            self.items[item.item_id] = item
        elif kind == FrameKind.ITEM_DELTA:
            item_id = frame.body.get("item_id")
            patch = frame.body.get("patch") or {}
            item = self.items.get(item_id) if item_id else None
            if item is not None and item.status == ItemStatus.IN_PROGRESS:
                _merge_patch(item, patch)

    # -- read ------------------------------------------------------------
    def ordered_items(self) -> list[Item]:
        """Current items in ``ord`` order (stable, first-seen tiebreak)."""
        return sorted(
            (self.items[i] for i in self.order),
            key=lambda it: (it.ord, self.order.index(it.item_id)),
        )

    def snapshot(self, cursor: Any = None) -> dict[str, Any]:
        """Build the ``snapshot`` frame body (protocol §3): ``{items, cursor}``.

        ``cursor`` is opaque to the phone; the DownstreamServer typically passes
        the current head ``seq`` so the phone resumes live from the right point.
        """
        return {
            "items": [it.to_dict() for it in self.ordered_items()],
            "cursor": cursor if cursor is not None else self.last_turn,
        }


def _merge_patch(item: Item, patch: dict[str, Any]) -> None:
    """Apply an ``item.delta`` patch to an in-progress item body (best effort).

    Text-bearing fields (``text``/``delta``) append; everything else is a
    shallow overwrite. This is intentionally lenient — correctness is restored
    by the authoritative ``item.completed``; this only keeps a mid-stream
    snapshot non-empty.
    """
    for key, val in patch.items():
        if key in ("text", "delta") and isinstance(val, str):
            prev = item.body.get("text", "")
            item.body["text"] = (prev if isinstance(prev, str) else "") + val
        elif key == "summary" and isinstance(val, str):
            item.summary = item.summary + val if item.summary else val
        else:
            item.body[key] = val


class SessionStore:
    """Registry of :class:`SessionState` keyed by session id.

    A thin lazy-create map so the Reframer and DownstreamServer share one view
    of accumulated items. No locking: the relay runs a single asyncio loop and
    all folds happen on it.
    """

    def __init__(self) -> None:
        self._states: dict[str, SessionState] = {}
        # R4 L6 — phone-origin prompt markers: sid -> [(text, expiry_mono)].
        # Transient mapping state (never snapshotted, never folded): it
        # coordinates the two ``userMessage`` emitters so a turn gets exactly
        # ONE user row regardless of origin. The DownstreamServer already
        # synthesizes the user row for a turn THIS phone drove (cmid-keyed —
        # the optimistic-echo adopter, contract I8); the Reframer emits one
        # from ``message.start{prompt}`` for FOREIGN turns (amendment G2).
        # Downstream marks the prompt it is about to drive (BEFORE the
        # prompt.submit await); the Reframer consumes the marker on
        # message.start and skips its emission — correct under BOTH orderings
        # (the marker lands before either the RPC result or the event can).
        self._local_prompts: dict[str, list[tuple[str, float]]] = {}

    def get(self, sid: str) -> SessionState:
        st = self._states.get(sid)
        if st is None:
            st = SessionState(sid=sid)
            self._states[sid] = st
        return st

    def apply(self, frame: Frame) -> None:
        self.get(frame.sid).apply(frame)

    def snapshot(self, sid: str, cursor: Any = None) -> dict[str, Any]:
        return self.get(sid).snapshot(cursor=cursor)

    def session_ids(self) -> list[str]:
        """Every session id the store currently holds accumulated items for.

        Used by the DownstreamServer to snapshot a phone across a reconnect
        (fresh per-connection seq space), where the connection's own
        ``seen_sids`` is still empty because no frame has streamed on the new
        socket yet.
        """
        return list(self._states.keys())

    def drop(self, sid: str) -> bool:
        self._local_prompts.pop(sid, None)
        return self._states.pop(sid, None) is not None

    def __contains__(self, sid: str) -> bool:
        return sid in self._states

    # -- R4 L6: phone-origin prompt markers -------------------------------
    def mark_local_prompt(self, sid: str, text: str) -> None:
        """Arm the L6 marker: ``text`` is a prompt THIS phone is driving.

        Called by the DownstreamServer BEFORE its ``prompt_submit`` await, so
        the marker is in place whichever lands first — the RPC result (and the
        SUBMIT-synthesized user row) or the gateway's ``message.start`` event.
        TTL-bounded + lazily swept so a submit that never starts a turn (the
        gateway errored the RPC) cannot mask a later foreign turn carrying the
        same text forever. One live turn per session bounds the list size;
        the sweep keeps it honest.
        """
        now = time.monotonic()
        entries = self._local_prompts.setdefault(sid, [])
        entries[:] = [(t, exp) for (t, exp) in entries if exp > now]
        entries.append((text, now + _LOCAL_PROMPT_TTL_S))

    def take_local_prompt(self, sid: str, text: str) -> bool:
        """True (consuming the marker) iff ``text`` was marked phone-origin.

        Called by the Reframer on ``message.start{prompt}``: a hit means the
        turn belongs to this phone and the DownstreamServer's cmid-keyed
        synthesis is the user row — skip the foreign emission. A miss means a
        genuinely foreign turn — emit. Expired entries are swept on the way.
        """
        entries = self._local_prompts.get(sid)
        if not entries:
            return False
        now = time.monotonic()
        for i, (marked_text, expiry) in enumerate(entries):
            if expiry > now and marked_text == text:
                entries.pop(i)
                return True
        entries[:] = [(t, exp) for (t, exp) in entries if exp > now]
        return False
