"""hermes-mobile plugin — per-session replay ring (WS-2.3 resumable stream).

Standalone data structure for STR-1066 (parent STR-1056; spec
``docs/RESUMABLE-STREAM-PROTOCOL.md`` §2/§3). This module owns ONLY the
in-memory replay buffer and the resume-decision logic. It does **not** wire
itself into ``tui_gateway/server.py`` (the seq-assignment / ``write_json``
append site is a fenced follow-up); it exposes the shapes that fenced path
will later call.

What it is
----------
Per live session, a bounded FIFO ring of the last emitted event frames, each
stored as ``(seq, frame_json)``. It reuses the proven drop-oldest bounded-deque
discipline from :class:`broadcast._BcastState` but is **per-session** (owner
truth), distinct from the existing **per-transport** mirror backlog in
``broadcast.py``. The mirror backlog stays; this ring is the replay source of
truth.

The three caps (spec §2.2)
--------------------------
Eviction is drop-oldest, triggered when ANY cap is exceeded:

* **per-session frame count** — default 512 frames.
* **per-session bytes** — default 4 MiB; bounds a session that emits a few
  giant frames (e.g. a large tool result).
* **aggregate bytes** — default 128 MiB process-wide; when the sum of all
  rings exceeds this, whole rings are dropped OLDEST-session-first (LRU by
  last activity). A dropped session's next resume is a cold full refetch,
  which is correct and safe.

Floor / head (spec §2.3, §3.2)
------------------------------
* ``head`` — the highest ``seq`` ever appended for the session.
* ``floor`` — the oldest ``seq`` still replayable. Evicting the oldest frame
  ``seq=K`` advances the floor to ``K+1``. The floor is the load-bearing value
  for the resume decision: a client whose ``resume_from`` is older than the
  floor missed frames the ring already evicted and must full-refetch.

Config is injectable (:class:`ReplayRingConfig`) and defaulted to the spec
values, so tests construct rings with tiny caps. This module reads NO
environment variables and introduces NO user-facing ``HERMES_*`` settings —
the config.yaml → internal bridge is the fenced parent's job.

Nothing here persists to disk: it is a live-process replay convenience; the
durable transcript in the DB (REST backfill) remains the source of record. A
gateway restart therefore means every client cold-refetches — exactly today's
behavior — and the ring is crash-safe by construction.
"""

from __future__ import annotations

import collections
import json
import threading
from dataclasses import dataclass
from typing import Any, Iterable

# --- Spec §2.2 defaults ---------------------------------------------------
_DEFAULT_FRAMES = 512
_DEFAULT_SESSION_BYTES = 4 * 1024 * 1024  # 4 MiB / session
_DEFAULT_TOTAL_BYTES = 128 * 1024 * 1024  # 128 MiB process-wide


@dataclass(frozen=True)
class ReplayRingConfig:
    """Injectable caps for the replay manager (spec §2.2).

    All three caps are enforced simultaneously; the ring evicts oldest when
    frame count OR per-session bytes is exceeded, and drops oldest *sessions*
    when aggregate bytes is exceeded. Defaults mirror the protocol spec. The
    fenced parent will bridge ``mobile.resume.ring_frames`` /
    ``mobile.resume.ring_bytes`` / ``mobile.resume.ring_total_bytes`` from
    config.yaml into these fields at load; this module stays env-var-free.
    """

    frames: int = _DEFAULT_FRAMES
    session_bytes: int = _DEFAULT_SESSION_BYTES
    total_bytes: int = _DEFAULT_TOTAL_BYTES

    def __post_init__(self) -> None:
        if self.frames < 1:
            raise ValueError("frames cap must be >= 1")
        if self.session_bytes < 1:
            raise ValueError("session_bytes cap must be >= 1")
        if self.total_bytes < 1:
            raise ValueError("total_bytes cap must be >= 1")


# Resume-decision kinds (spec §3.2). See :class:`ReplayDecision`.
CURRENT = "current"   # R >= head: nothing to replay, attach live (count 0)
REPLAY = "replay"     # floor <= R+1 <= head: replay [R+1 .. head] (count H-R)
FALLBACK = "fallback"  # R+1 < floor OR no ring: the ONE sanctioned full refetch


@dataclass(frozen=True)
class ReplayDecision:
    """Outcome of a ``resume_from`` decision (spec §3.2).

    ``frames`` is the ordered list of ``frame_json`` strings to replay
    (ascending seq, contiguous ``from_seq .. to_seq``); it is non-empty only
    for :data:`REPLAY`. ``count`` mirrors the wire ``replay.count`` field:
    ``0`` when current, ``head - resume_from`` when replaying, and ``-1`` for
    the full-refetch fallback.
    """

    kind: str
    from_seq: int
    to_seq: int
    count: int
    frames: "list[str]"

    @property
    def is_replay(self) -> bool:
        return self.kind == REPLAY

    @property
    def is_fallback(self) -> bool:
        return self.kind == FALLBACK

    @property
    def is_current(self) -> bool:
        return self.kind == CURRENT


class _SessionRing:
    """A single session's bounded (seq, frame_json) deque.

    Mirrors :class:`broadcast._BcastState`: a ``collections.deque`` with
    drop-oldest overflow. Entries are ``(seq, frame_json, nbytes)`` in append
    (== seq) order. ``head`` is the highest seq appended; ``floor`` is the
    oldest seq still held. ``last_touch`` is a monotonic tick used for the
    aggregate LRU drop — deterministic, no wall clock.
    """

    __slots__ = ("entries", "floor", "head", "nbytes", "last_touch")

    def __init__(self) -> None:
        self.entries: "collections.deque[tuple[int, str, int]]" = (
            collections.deque()
        )
        self.floor = 0  # oldest replayable seq (set on first append)
        self.head = 0   # highest seq appended
        self.nbytes = 0  # sum of entry byte sizes
        self.last_touch = 0


def _frame_to_json(frame: Any) -> str:
    """Normalize a frame to its ``frame_json`` string form.

    The fenced parent passes the already-serialized wire string; tests and
    ergonomic callers may pass a ``dict``. Bytes are decoded as UTF-8. The
    stored form is always a ``str`` (spec: the ring stores ``frame_json``).
    """
    if isinstance(frame, str):
        return frame
    if isinstance(frame, (bytes, bytearray)):
        return bytes(frame).decode("utf-8")
    return json.dumps(frame, ensure_ascii=False)


class ReplayRingManager:
    """Per-session replay rings with three-way cap eviction (spec §2/§3).

    Thread-safe: all mutation and read-decision paths take a single re-entrant
    lock. The append path is hot but the critical section is small (deque
    ops + int math), matching the broadcast engine's lock discipline. The
    fenced ``write_json`` seam will call :meth:`append` under the session's
    own write lock; the ``session.resume`` handler will call :meth:`decide`.
    """

    def __init__(self, config: "ReplayRingConfig | None" = None) -> None:
        self._cfg = config or ReplayRingConfig()
        self._rings: "dict[str, _SessionRing]" = {}
        self._agg_bytes = 0
        self._tick = 0
        self._lock = threading.RLock()

    # -- config -----------------------------------------------------------

    @property
    def config(self) -> ReplayRingConfig:
        return self._cfg

    def _next_tick(self) -> int:
        self._tick += 1
        return self._tick

    # -- append / eviction -------------------------------------------------

    def append(self, session_key: str, seq: int, frame: Any) -> None:
        """Append ``(seq, frame_json)`` to the session ring, lazily creating it.

        Enforces all three caps after the append: evicts oldest frames while
        the per-session frame-count OR byte cap is exceeded (advancing the
        floor), then drops oldest *sessions* while the aggregate byte cap is
        exceeded. The just-appended frame is never evicted — a single frame
        larger than the per-session byte cap is retained alone (dropping it
        would lose the newest emitted event).
        """
        frame_json = _frame_to_json(frame)
        nbytes = len(frame_json.encode("utf-8"))
        with self._lock:
            ring = self._rings.get(session_key)
            if ring is None:  # lazy create on first emit (spec §2.4)
                ring = _SessionRing()
                self._rings[session_key] = ring

            ring.entries.append((seq, frame_json, nbytes))
            ring.nbytes += nbytes
            self._agg_bytes += nbytes
            if seq > ring.head:
                ring.head = seq
            if len(ring.entries) == 1:
                ring.floor = seq
            ring.last_touch = self._next_tick()

            self._evict_session(ring)
            self._evict_aggregate(session_key)

    def _evict_session(self, ring: _SessionRing) -> None:
        """Drop-oldest until this ring is within the per-session caps.

        Never evicts the sole remaining (newest) frame. After each eviction
        the floor advances to the new oldest entry's seq (== evicted+1 under
        the monotonic-by-1 seq contract; computed from the actual entry to
        stay correct even if a caller ever violated contiguity)."""
        cfg = self._cfg
        while len(ring.entries) > 1 and (
            len(ring.entries) > cfg.frames or ring.nbytes > cfg.session_bytes
        ):
            _seq, _frame, old_nbytes = ring.entries.popleft()
            ring.nbytes -= old_nbytes
            self._agg_bytes -= old_nbytes
            ring.floor = ring.entries[0][0]

    def _evict_aggregate(self, keep_key: str) -> None:
        """Drop whole rings, oldest session first, until under the aggregate cap.

        LRU by ``last_touch``. The just-touched session (``keep_key``) has the
        newest tick, so it is dropped last; it is only ever the final survivor
        if it alone exceeds the aggregate cap, in which case it is retained
        (we cannot both honor the cap and keep the live session's newest
        frames — the byte cap already bounds a single session). Dropped
        sessions become full-refetch fallback candidates on their next
        resume."""
        cfg = self._cfg
        while self._agg_bytes > cfg.total_bytes and len(self._rings) > 1:
            lru_key = min(
                self._rings, key=lambda k: self._rings[k].last_touch
            )
            if lru_key == keep_key:
                # Newest by construction; only reachable if it is the sole
                # over-budget ring, which the len>1 guard already excludes.
                break
            self._drop_locked(lru_key)

    # -- resume decision ---------------------------------------------------

    def decide(self, session_key: str, resume_from: int) -> ReplayDecision:
        """Resolve a client's ``resume_from`` against the ring (spec §3.2).

        ``resume_from`` (``R``) is the client's last-seen seq. Returns:

        * :data:`CURRENT` when ``R >= head`` — nothing to replay, attach live.
        * :data:`REPLAY` when ``floor <= R+1 <= head`` — replay ``[R+1 .. head]``
          as ordered original frames, then attach live.
        * :data:`FALLBACK` when ``R+1 < floor`` or the session has no ring
          (dropped / orphan-reaped) — the one sanctioned full refetch.

        A resume is activity, so the session's LRU position is refreshed here
        too, keeping an actively-resuming client from being aggregate-evicted.
        """
        with self._lock:
            ring = self._rings.get(session_key)
            if ring is None:
                return ReplayDecision(FALLBACK, resume_from + 1, resume_from, -1, [])

            ring.last_touch = self._next_tick()
            head, floor = ring.head, ring.floor
            nxt = resume_from + 1

            if resume_from >= head:  # case 1: current or ahead
                return ReplayDecision(CURRENT, nxt, resume_from, 0, [])
            if nxt >= floor:  # case 2: gap is inside the ring
                frames = [f for (s, f, _n) in ring.entries if s >= nxt]
                return ReplayDecision(REPLAY, nxt, head, head - resume_from, frames)
            # case 3: older than the floor — evicted, must full-refetch
            return ReplayDecision(FALLBACK, nxt, head, -1, [])

    # -- lifecycle: drop / orphan-reap (spec §2.4) -------------------------

    def _drop_locked(self, session_key: str) -> bool:
        ring = self._rings.pop(session_key, None)
        if ring is None:
            return False
        self._agg_bytes -= ring.nbytes
        return True

    def drop(self, session_key: str) -> bool:
        """Drop a single session's ring (orphan-reap / idle-reap hook).

        This is the shape the fenced ``_schedule_ws_orphan_reap`` path will
        call when a session goes fully idle. Returns ``True`` if a ring was
        present. Idempotent: dropping an absent session is a no-op returning
        ``False``. The session's next resume becomes a cold full refetch.
        """
        with self._lock:
            return self._drop_locked(session_key)

    def reap_orphans(self, active_keys: Iterable[str]) -> "list[str]":
        """Drop every ring whose session is not in ``active_keys``.

        Bulk orphan-reap shape for the fenced parent: pass the set of
        session keys with a live transport; rings for all others are dropped
        and their keys returned. Order of the returned list is arbitrary.
        """
        active = set(active_keys)
        with self._lock:
            stale = [k for k in self._rings if k not in active]
            for k in stale:
                self._drop_locked(k)
            return stale

    # -- introspection (tests / observability) ----------------------------

    def has_ring(self, session_key: str) -> bool:
        with self._lock:
            return session_key in self._rings

    def floor(self, session_key: str) -> "int | None":
        with self._lock:
            ring = self._rings.get(session_key)
            return None if ring is None else ring.floor

    def head(self, session_key: str) -> "int | None":
        with self._lock:
            ring = self._rings.get(session_key)
            return None if ring is None else ring.head

    def frame_count(self, session_key: str) -> int:
        with self._lock:
            ring = self._rings.get(session_key)
            return 0 if ring is None else len(ring.entries)

    def session_bytes(self, session_key: str) -> int:
        with self._lock:
            ring = self._rings.get(session_key)
            return 0 if ring is None else ring.nbytes

    def aggregate_bytes(self) -> int:
        with self._lock:
            return self._agg_bytes

    def session_count(self) -> int:
        with self._lock:
            return len(self._rings)


# ---------------------------------------------------------------------------
# Optional module-level default manager.
#
# Mirrors broadcast.py's module-state style so the fenced parent can call a
# thin function surface without threading a manager instance through the
# server. Tests construct ReplayRingManager directly with injected caps and do
# NOT touch this singleton, so there is no cross-test global-state leakage.
# ---------------------------------------------------------------------------

_default_manager: "ReplayRingManager | None" = None
_default_lock = threading.Lock()


def get_default() -> ReplayRingManager:
    """Lazily create and return the process-wide default manager."""
    global _default_manager
    with _default_lock:
        if _default_manager is None:
            _default_manager = ReplayRingManager()
        return _default_manager


def reset_default() -> None:
    """Drop the default manager (test-hygiene / reconfiguration hook)."""
    global _default_manager
    with _default_lock:
        _default_manager = None
