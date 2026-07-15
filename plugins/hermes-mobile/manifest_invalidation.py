"""Durable, coalesced sync-manifest invalidation publisher.

The manifest endpoint and this publisher share this journal.  Mutations advance
the journal atomically before a best-effort silent push is scheduled.
"""

from __future__ import annotations

import json
import logging
import threading
from pathlib import Path
from typing import Callable

from utils import atomic_json_write

log = logging.getLogger(__name__)

REASONS = frozenset(
    {"sessions", "attention", "active_turns", "transcript", "widget", "push_registry"}
)
EVENT_REASONS = {
    "session.created": ("sessions", "widget"),
    "session.updated": ("sessions", "widget"),
    "session.info": ("sessions", "widget"),
    "session.archived": ("sessions", "widget"),
    "session.deleted": ("sessions", "transcript", "widget"),
    "approval.request": ("attention", "active_turns", "widget"),
    "approval.resolved": ("attention", "active_turns", "widget"),
    "clarify.request": ("attention", "active_turns", "widget"),
    "clarify.resolved": ("attention", "active_turns", "widget"),
    "prompt.added": ("attention", "active_turns", "widget"),
    "prompt.removed": ("attention", "active_turns", "widget"),
    "message.start": ("active_turns", "widget"),
    "message.complete": ("active_turns", "transcript", "sessions", "widget"),
    "session.interrupt": ("active_turns", "widget"),
    "message.added": ("transcript", "sessions"),
    "transcript.updated": ("transcript", "sessions"),
    "widget.updated": ("widget",),
    "push.registered": ("push_registry",),
    "push.unregistered": ("push_registry",),
}


def _home() -> Path:
    try:
        from hermes_cli.config import get_hermes_home

        return Path(get_hermes_home())
    except Exception:
        return Path.home() / ".hermes"


class InvalidationPublisher:
    def __init__(
        self,
        path: Path | None = None,
        sender: Callable[[str, int, str], object] | None = None,
        coalesce_seconds: float = 0.05,
    ) -> None:
        self.path = path or (_home() / "mobile_manifest_revisions.json")
        self.sender = sender or self._default_sender
        self.coalesce_seconds = coalesce_seconds
        self._lock = threading.Lock()
        self._pending: dict[str, tuple[int, str]] = {}
        self._timer: threading.Timer | None = None

    @staticmethod
    def _default_sender(scope: str, revision: int, reason: str) -> object:
        from .push_engine import notify_manifest_invalidation

        return notify_manifest_invalidation(scope, revision, reason)

    def _read(self) -> dict:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if isinstance(data, dict) and isinstance(data.get("revisions"), dict):
                return data
        except (OSError, ValueError, TypeError):
            pass
        return {"high_water": 0, "revisions": {}}

    def revision(self, scope: str = "all") -> int:
        with self._lock:
            return int(self._read()["revisions"].get(scope, 0))

    def invalidate(self, scope: str, reason: str) -> int:
        if scope != "all" and not scope.startswith("profile:"):
            raise ValueError("invalid manifest scope")
        if reason not in REASONS:
            raise ValueError("invalid manifest invalidation reason")
        with self._lock:
            state = self._read()
            revision = int(state.get("high_water", 0)) + 1
            state["high_water"] = revision
            state["revisions"][scope] = revision
            self.path.parent.mkdir(parents=True, exist_ok=True)
            atomic_json_write(self.path, state, mode=0o600)
            previous = self._pending.get(scope)
            pending_reason = reason if previous is None else "coalesced"
            self._pending[scope] = (revision, pending_reason)
            if self._timer is None:
                self._timer = threading.Timer(self.coalesce_seconds, self.flush)
                self._timer.daemon = True
                self._timer.start()
            return revision

    def flush(self) -> None:
        with self._lock:
            pending, self._pending = self._pending, {}
            self._timer = None
        for scope, (revision, reason) in pending.items():
            try:
                self.sender(scope, revision, reason)
            except Exception:
                log.warning("manifest invalidation push failed", exc_info=True)


_publisher = InvalidationPublisher()


def invalidate(scope: str, reason: str) -> int:
    return _publisher.invalidate(scope, reason)


def handle_gateway_event(event: str, _sid: str, payload: dict | None = None) -> int | None:
    reasons = EVENT_REASONS.get(event)
    if reasons is None:
        return None
    data = payload if isinstance(payload, dict) else {}
    profile = data.get("profile")
    scope = f"profile:{profile}" if isinstance(profile, str) and profile else "all"
    revision = None
    for reason in reasons:
        revision = invalidate(scope, reason)
    return revision
