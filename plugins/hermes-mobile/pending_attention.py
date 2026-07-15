"""Revisioned, authorization-partitioned pending-attention reconciliation.

The live waiter owners expose lock-safe public snapshots.  This plugin keeps
the HTTP-facing cursor journal at the edge, where mobile-specific retention
and visibility policy belong.
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import threading
import time
import uuid
from collections import deque
from dataclasses import dataclass, field
from typing import Callable

SERVER_INSTANCE_ID = uuid.uuid4().hex
MAX_CHANGES = 512

_cursor_secret = secrets.token_bytes(32)
_lock = threading.RLock()


class InvalidCursor(ValueError):
    """The cursor is malformed or was not issued for this visibility."""


@dataclass
class _VisibilityState:
    revision: int = 0
    floor_revision: int = 0
    current: dict[str, dict] = field(default_factory=dict)
    changes: deque[dict] = field(default_factory=deque)


_states: dict[str, _VisibilityState] = {}


def capture_pending_attention() -> list[dict]:
    """Capture both waiter owners through their public snapshot interfaces."""
    from tools.approval import pending_approval_snapshot
    from tui_gateway.server import (
        attention_session_identities,
        pending_prompt_snapshot,
    )

    identities = attention_session_identities()
    runtime_by_stored: dict[str, list[str]] = {}
    for item in identities:
        stored_id = str(item.get("stored_session_id") or "")
        runtime_id = str(item.get("session_id") or "")
        if stored_id and runtime_id:
            runtime_by_stored.setdefault(stored_id, []).append(runtime_id)
    records = []
    for source in pending_approval_snapshot():
        item = dict(source)
        stored_id = str(item.get("stored_session_id") or "")
        candidates = sorted(set(runtime_by_stored.get(stored_id, []))) or [stored_id]
        item["session_id"] = candidates[0]
        item["_candidate_session_ids"] = candidates
        records.append(item)
    records.extend(pending_prompt_snapshot())
    return records


def _visibility_digest(visibility: str) -> str:
    return hashlib.sha256(visibility.encode("utf-8")).hexdigest()[:16]


def _signature(instance_id: str, revision: int, visibility: str) -> str:
    body = f"{instance_id}:{revision}:{visibility}".encode("utf-8")
    return hmac.new(_cursor_secret, body, hashlib.sha256).hexdigest()[:32]


def _cursor(revision: int, visibility: str) -> str:
    return ".".join(
        (
            "pa1",
            SERVER_INSTANCE_ID,
            str(revision),
            _visibility_digest(visibility),
            _signature(SERVER_INSTANCE_ID, revision, visibility),
        )
    )


def _parse_cursor(cursor: str, visibility: str) -> tuple[str, int | None]:
    if not isinstance(cursor, str) or len(cursor.encode("utf-8")) > 512:
        raise InvalidCursor("invalid pending-attention cursor")
    parts = cursor.split(".")
    if len(parts) != 5 or parts[0] != "pa1":
        raise InvalidCursor("invalid pending-attention cursor")
    instance_id, raw_revision, visibility_digest, signature = parts[1:]
    if instance_id != SERVER_INSTANCE_ID:
        return "foreign_instance", None
    if visibility_digest != _visibility_digest(visibility):
        return "foreign_scope", None
    try:
        revision = int(raw_revision)
    except ValueError as exc:
        raise InvalidCursor("invalid pending-attention cursor") from exc
    if revision < 0 or not hmac.compare_digest(
        signature, _signature(instance_id, revision, visibility)
    ):
        raise InvalidCursor("invalid pending-attention cursor")
    return "valid", revision


def _safe_record(source: dict) -> dict:
    """Copy only the frozen display-safe record schema from an owner."""
    detail = source.get("detail") if isinstance(source.get("detail"), dict) else {}
    safe_detail: dict = {}
    if source.get("kind") == "approval":
        safe_detail["description"] = str(detail.get("description") or "")[:500]
    else:
        safe_detail["question"] = str(detail.get("question") or "")[:500]
    raw_choices = detail.get("choices")
    safe_detail["choices"] = (
        [str(choice)[:100] for choice in raw_choices[:20]]
        if isinstance(raw_choices, list)
        else []
    )
    return {
        "id": str(source.get("id") or ""),
        "request_id": str(source.get("request_id") or ""),
        "kind": "clarify" if source.get("kind") == "clarify" else "approval",
        "session_id": str(source.get("session_id") or ""),
        "stored_session_id": str(source.get("stored_session_id") or ""),
        "safe_title": str(source.get("safe_title") or "Input required")[:100],
        "detail": safe_detail,
        "destructive": bool(source.get("destructive")),
        "created_at": float(source.get("created_at") or 0.0),
        "expires_at": (
            float(source["expires_at"])
            if source.get("expires_at") is not None
            else None
        ),
        "status": str(source.get("status") or "pending"),
    }


def _append_change(state: _VisibilityState, change: dict) -> None:
    while len(state.changes) >= MAX_CHANGES:
        dropped = state.changes.popleft()
        state.floor_revision = max(state.floor_revision, int(dropped["revision"]))
    state.changes.append(change)


def _reconcile(state: _VisibilityState, records: list[dict], now: float) -> None:
    incoming = {
        item["id"]: item
        for item in (_safe_record(source) for source in records)
        if item["id"] and item["request_id"] and item["session_id"]
    }
    for record_id in sorted(incoming):
        item = incoming[record_id]
        previous = state.current.get(record_id)
        comparable_previous = (
            {key: value for key, value in previous.items() if key != "revision"}
            if previous is not None
            else None
        )
        if comparable_previous == item:
            continue
        state.revision += 1
        revised = dict(item, revision=state.revision)
        state.current[record_id] = revised
        _append_change(
            state,
            {"operation": "upsert", "revision": state.revision, "record": revised},
        )

    for record_id in sorted(set(state.current) - set(incoming)):
        previous = state.current.pop(record_id)
        state.revision += 1
        expires_at = previous.get("expires_at")
        status = (
            "expired"
            if expires_at is not None and expires_at <= now
            else "resolved_elsewhere"
        )
        tombstone = {
            "id": record_id,
            "request_id": previous["request_id"],
            "kind": previous["kind"],
            "session_id": previous["session_id"],
            "stored_session_id": previous["stored_session_id"],
            "status": status,
            "deleted_at": now,
            "revision": state.revision,
        }
        _append_change(
            state,
            {"operation": "tombstone", "revision": state.revision, "record": tombstone},
        )


def build_pending_attention(
    *,
    cursor: str | None,
    visibility: str,
    visibility_check: Callable[[str], bool],
) -> dict:
    """Build a full snapshot or bounded delta for one auth visibility."""
    with _lock:
        # Capture inside the journal lock so two concurrent fetches cannot
        # reconcile newer owner state and then overwrite it with an older
        # snapshot captured before the first fetch acquired this lock.
        captured = []
        for source in capture_pending_attention():
            candidates = source.get("_candidate_session_ids")
            if not isinstance(candidates, list):
                candidates = [str(source.get("session_id") or "")]
            visible_session_id = next(
                (
                    str(session_id)
                    for session_id in candidates
                    if session_id and visibility_check(str(session_id))
                ),
                "",
            )
            if not visible_session_id:
                continue
            record = dict(source)
            record["session_id"] = visible_session_id
            record.pop("_candidate_session_ids", None)
            captured.append(record)
        now = time.time()
        state = _states.setdefault(visibility, _VisibilityState())
        _reconcile(state, captured, now)

        reset_reason = None
        requested_revision: int | None = None
        if cursor is None:
            reset_reason = "initial_snapshot"
        else:
            cursor_kind, requested_revision = _parse_cursor(cursor, visibility)
            if cursor_kind != "valid":
                reset_reason = cursor_kind
            elif requested_revision < state.floor_revision:
                reset_reason = "cursor_too_old"
            elif requested_revision > state.revision:
                reset_reason = "cursor_ahead"

        if reset_reason is not None:
            upserts = sorted(
                state.current.values(),
                key=lambda item: (item["revision"], item["id"]),
            )
            tombstones: list[dict] = []
        else:
            assert requested_revision is not None
            latest: dict[str, dict] = {}
            for change in state.changes:
                if int(change["revision"]) > requested_revision:
                    latest[change["record"]["id"]] = change
            ordered = sorted(latest.values(), key=lambda item: int(item["revision"]))
            upserts = [
                item["record"]
                for item in ordered
                if item["operation"] == "upsert"
            ]
            tombstones = [
                item["record"] for item in ordered if item["operation"] == "tombstone"
            ]

        return {
            "server_instance_id": SERVER_INSTANCE_ID,
            "cursor": _cursor(state.revision, visibility),
            "reset": reset_reason is not None,
            "reset_reason": reset_reason,
            "upserts": upserts,
            "tombstones": tombstones,
        }


def _reset_for_tests(*, server_instance_id: str | None = None) -> None:
    """Reset process-local journal state for focused tests."""
    global SERVER_INSTANCE_ID, _cursor_secret
    with _lock:
        _states.clear()
        _cursor_secret = secrets.token_bytes(32)
        SERVER_INSTANCE_ID = server_instance_id or uuid.uuid4().hex
