"""Bounded compact-turn projection from public SessionDB ledgers.

This module never reads the raw transcript wholesale. New authoritative turns
come from ``session_turns``/``session_turn_inputs`` and terminal content is
resolved by one stable display origin. Historical sessions whose ledger is not
complete remain honestly partial until a checkpointed backfill proves them.
"""

from __future__ import annotations

import base64
import hashlib
import json
from dataclasses import dataclass
from typing import Any, Optional


SCHEMA_VERSION = 1
PROJECTION_VERSION = 1
MAX_TURNS_PER_PAGE = 100
MAX_INPUTS_PER_TURN = 1000
MAX_TOMBSTONES_PER_PAGE = 1000
MAX_OPERATIONS_PER_TURN = 1000
MAX_OPERATIONS_PER_PAGE = 5000


class TurnProjectionError(ValueError):
    """A cursor or source ledger cannot produce an integrity-safe page."""


@dataclass(frozen=True)
class TurnCursor:
    session_id: str
    display_revision: int
    accepted_at: float
    turn_id: str


def _encode_cursor(cursor: TurnCursor) -> str:
    raw = json.dumps(
        {
            "v": 1,
            "s": cursor.session_id,
            "r": cursor.display_revision,
            "a": cursor.accepted_at,
            "t": cursor.turn_id,
        },
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _decode_cursor(value: str, *, session_id: str, display_revision: int) -> TurnCursor:
    try:
        padded = value + "=" * (-len(value) % 4)
        payload = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
        cursor = TurnCursor(
            session_id=str(payload["s"]),
            display_revision=int(payload["r"]),
            accepted_at=float(payload["a"]),
            turn_id=str(payload["t"]),
        )
    except (KeyError, TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise TurnProjectionError("invalid turn cursor") from exc
    if payload.get("v") != 1 or cursor.session_id != session_id:
        raise TurnProjectionError("turn cursor belongs to a different session")
    if cursor.display_revision != display_revision:
        raise TurnProjectionError("turn cursor display revision changed")
    if not cursor.turn_id:
        raise TurnProjectionError("invalid turn cursor")
    return cursor


def _project_input(item: dict[str, Any]) -> dict[str, Any]:
    return {
        "input_id": str(item["input_id"]),
        "client_message_id": item.get("client_message_id"),
        "ordinal": int(item["ordinal"]),
        "input_kind": str(item["input_kind"]),
        "content": item.get("content"),
        "created_at": float(item["accepted_at"]),
    }


def _terminal_content(db: Any, session_id: str, row: dict[str, Any]) -> Optional[dict[str, Any]]:
    origin_id = row.get("terminal_message_origin_id")
    if origin_id is None:
        return None
    message = db.get_display_message_by_origin(session_id, int(origin_id))
    if (
        message is None
        or message.get("role") != "assistant"
        or message.get("tool_calls")
    ):
        return None
    return {
        "message_id": str(origin_id),
        "content": message.get("content"),
        "created_at": float(message.get("timestamp") or row.get("terminal_at") or 0),
    }


def _group_operations(turn_id: str, operations: list[dict[str, Any]]) -> list[dict[str, Any]]:
    groups: list[dict[str, Any]] = []
    for operation in operations:
        category = str(operation["category"])
        if not groups or groups[-1]["category"] != category:
            digest = hashlib.sha256(
                f"{turn_id}\0{category}\0{operation['operation_id']}".encode("utf-8")
            ).hexdigest()[:24]
            groups.append(
                {
                    "group_id": f"group_{digest}",
                    "ordinal": len(groups),
                    "category": category,
                    "display_label": str(operation["safe_label"]),
                    "operation_count": 0,
                    "state": "completed",
                    "started_at": operation.get("started_at"),
                    "completed_at": operation.get("completed_at"),
                    "detail_available": True,
                }
            )
        group = groups[-1]
        group["operation_count"] += 1
        group["completed_at"] = operation.get("completed_at")
        state = str(operation["state"])
        if state == "running":
            group["state"] = "running"
        elif state == "failed" and group["state"] != "running":
            group["state"] = "failed"
        elif state == "interrupted" and group["state"] == "completed":
            group["state"] = "interrupted"
    return groups


def _project_turn(
    db: Any,
    session_id: str,
    row: dict[str, Any],
    *,
    server_revision: int,
) -> tuple[dict[str, Any], int]:
    inputs = db.get_turn_inputs(
        session_id,
        str(row["turn_id"]),
        limit=MAX_INPUTS_PER_TURN + 1,
    )
    if len(inputs) > MAX_INPUTS_PER_TURN:
        raise TurnProjectionError("turn input count exceeds projection bound")
    operations = db.get_turn_operations(
        session_id,
        str(row["turn_id"]),
        limit=MAX_OPERATIONS_PER_TURN + 1,
    )
    if len(operations) > MAX_OPERATIONS_PER_TURN:
        raise TurnProjectionError("turn operation count exceeds projection bound")
    terminal_at = row.get("terminal_at")
    started_at = row.get("started_at")
    elapsed_ms = None
    timing_quality = "unknown"
    if started_at is not None and terminal_at is not None:
        elapsed_ms = max(0, int((float(terminal_at) - float(started_at)) * 1000))
        timing_quality = "exact"
    projected = {
        "turn_id": str(row["turn_id"]),
        "client_message_id": row.get("primary_client_message_id"),
        "inputs": [_project_input(item) for item in inputs],
        "state": str(row["state"]),
        "accepted_at": float(row["accepted_at"]),
        "started_at": float(started_at) if started_at is not None else None,
        "completed_at": float(terminal_at) if terminal_at is not None else None,
        "elapsed_ms": elapsed_ms,
        "timing_quality": timing_quality,
        "authority_state": "authoritative",
        "server_revision": server_revision,
        "final": _terminal_content(db, session_id, row),
        "activity_groups": _group_operations(str(row["turn_id"]), operations),
    }
    return projected, len(operations)


def build_turn_page(
    db: Any,
    *,
    session_id: str,
    before: Optional[str] = None,
    after_revision: int = 0,
    limit: int = 30,
) -> dict[str, Any]:
    """Build one complete, boundary-aligned page with bounded source reads."""
    safe_limit = max(1, min(int(limit), MAX_TURNS_PER_PAGE))
    status = db.get_turn_ledger_status(session_id)
    display_revision = int(status["display_revision"])
    cursor = None
    if before:
        cursor = _decode_cursor(
            before,
            session_id=session_id,
            display_revision=display_revision,
        )
    rows = db.get_turns(
        session_id,
        before_accepted_at=cursor.accepted_at if cursor else None,
        before_turn_id=cursor.turn_id if cursor else None,
        limit=safe_limit + 1,
    )
    has_older = len(rows) > safe_limit
    page_rows = rows[:safe_limit]
    turns = []
    operation_count = 0
    for row in reversed(page_rows):
        turn, count = _project_turn(
            db,
            session_id,
            row,
            server_revision=display_revision,
        )
        operation_count += count
        if operation_count > MAX_OPERATIONS_PER_PAGE:
            raise TurnProjectionError("page operation count exceeds projection bound")
        turns.append(turn)
    tombstones = db.get_turn_tombstones(
        session_id,
        after_revision=max(0, int(after_revision)),
        limit=MAX_TOMBSTONES_PER_PAGE + 1,
    )
    if len(tombstones) > MAX_TOMBSTONES_PER_PAGE:
        raise TurnProjectionError("turn tombstone count exceeds projection bound")
    previous_cursor = None
    if has_older and page_rows:
        oldest = page_rows[-1]
        previous_cursor = _encode_cursor(
            TurnCursor(
                session_id=session_id,
                display_revision=display_revision,
                accepted_at=float(oldest["accepted_at"]),
                turn_id=str(oldest["turn_id"]),
            )
        )
    coverage_complete = bool(
        status["coverage_complete"] and status["display_lineage_complete"]
    )
    return {
        "schema_version": SCHEMA_VERSION,
        "projection_version": PROJECTION_VERSION,
        "stored_session_id": session_id,
        "source_head_id": display_revision,
        "coverage_complete": coverage_complete,
        "projection_pending": not coverage_complete,
        "reset": False,
        "turns": turns,
        "tombstones": [
            {
                "turn_id": str(item["turn_id"]),
                "state": str(item["state"]),
                "server_revision": int(item["display_revision"]),
                "deleted_at": float(item["updated_at"]),
            }
            for item in tombstones
        ],
        "previous_cursor": previous_cursor,
        "has_older": has_older,
    }
