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
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional

from hermes_constants import get_hermes_home


SCHEMA_VERSION = 1
PROJECTION_VERSION = 1
MAX_TURNS_PER_PAGE = 100
MAX_INPUTS_PER_TURN = 1000
MAX_TOMBSTONES_PER_PAGE = 1000
MAX_OPERATIONS_PER_TURN = 1000
MAX_OPERATIONS_PER_PAGE = 5000
MAX_BACKFILL_ROWS_PER_STEP = 500
MAX_BACKFILL_OPERATIONS_PER_TURN = 1000

_backfill_lock = threading.RLock()


class TurnProjectionError(ValueError):
    """A cursor or source ledger cannot produce an integrity-safe page."""


def _backfill_path() -> Path:
    path = get_hermes_home() / "mobile" / "turn-projection-backfill.sqlite3"
    path.parent.mkdir(parents=True, exist_ok=True)
    return path


def _open_backfill_db() -> sqlite3.Connection:
    conn = sqlite3.connect(_backfill_path(), timeout=10)
    conn.row_factory = sqlite3.Row
    conn.executescript(
        """
        PRAGMA journal_mode=WAL;
        PRAGMA foreign_keys=ON;
        CREATE TABLE IF NOT EXISTS backfill_state (
            session_id TEXT PRIMARY KEY,
            display_revision INTEGER NOT NULL,
            before_origin_id INTEGER,
            pending_final_origin_id INTEGER,
            pending_final_at REAL,
            pending_overflow INTEGER NOT NULL DEFAULT 0,
            scan_complete INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS backfill_operations (
            session_id TEXT NOT NULL,
            reverse_ordinal INTEGER NOT NULL,
            operation_id TEXT NOT NULL,
            tool_name TEXT NOT NULL,
            category TEXT NOT NULL,
            safe_label TEXT NOT NULL,
            state TEXT NOT NULL,
            started_at REAL,
            completed_at REAL,
            PRIMARY KEY (session_id, operation_id)
        );
        CREATE TABLE IF NOT EXISTS backfill_results (
            session_id TEXT NOT NULL,
            operation_id TEXT NOT NULL,
            completed_at REAL,
            PRIMARY KEY (session_id, operation_id)
        );
        """
    )
    return conn


def _reset_backfill(conn: sqlite3.Connection, session_id: str, revision: int) -> None:
    import time

    conn.execute("DELETE FROM backfill_operations WHERE session_id = ?", (session_id,))
    conn.execute("DELETE FROM backfill_results WHERE session_id = ?", (session_id,))
    conn.execute(
        "INSERT INTO backfill_state "
        "(session_id, display_revision, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(session_id) DO UPDATE SET "
        "display_revision = excluded.display_revision, before_origin_id = NULL, "
        "pending_final_origin_id = NULL, pending_final_at = NULL, "
        "pending_overflow = 0, scan_complete = 0, "
        "updated_at = excluded.updated_at",
        (session_id, int(revision), time.time()),
    )


def _clear_pending_boundary(conn: sqlite3.Connection, session_id: str) -> None:
    conn.execute("DELETE FROM backfill_operations WHERE session_id = ?", (session_id,))
    conn.execute("DELETE FROM backfill_results WHERE session_id = ?", (session_id,))
    conn.execute(
        "UPDATE backfill_state SET pending_final_origin_id = NULL, "
        "pending_final_at = NULL, pending_overflow = 0 WHERE session_id = ?",
        (session_id,),
    )


def _has_visible_content(content: Any) -> bool:
    if isinstance(content, str):
        return bool(content.strip())
    if isinstance(content, list):
        return bool(content)
    return content is not None


def _tool_name(call: Any) -> str:
    if not isinstance(call, dict):
        return "operation"
    function = call.get("function")
    if isinstance(function, dict) and function.get("name"):
        return str(function["name"])[:256]
    return str(call.get("name") or "operation")[:256]


def _tool_id(call: Any, *, origin_id: int, index: int) -> str:
    if isinstance(call, dict) and call.get("id"):
        return str(call["id"])[:256]
    digest = hashlib.sha256(f"{origin_id}\0{index}".encode()).hexdigest()[:24]
    return f"hist_op_{digest}"


def _safe_tool_metadata(name: str) -> tuple[str, str]:
    lowered = name.lower()
    if any(token in lowered for token in ("terminal", "shell", "exec", "command")):
        return "shell", "Ran terminal operations"
    if any(token in lowered for token in ("edit", "write", "patch")):
        return "edit", "Updated files"
    if any(token in lowered for token in ("test", "verify", "lint", "build")):
        return "test", "Verified changes"
    if any(token in lowered for token in ("browser", "web", "search", "fetch")):
        return "web", "Used web resources"
    if any(token in lowered for token in ("file", "read", "list", "directory")):
        return "files", "Inspected files"
    return "other", "Performed operations"


def _pending_operations(conn: sqlite3.Connection, session_id: str) -> list[dict[str, Any]]:
    rows = conn.execute(
        "SELECT operation_id, tool_name, category, safe_label, state, "
        "started_at, completed_at FROM backfill_operations "
        "WHERE session_id = ? ORDER BY reverse_ordinal DESC",
        (session_id,),
    ).fetchall()
    return [dict(row) for row in rows]


def advance_historical_backfill(
    db: Any,
    *,
    session_id: str,
    max_rows: int = MAX_BACKFILL_ROWS_PER_STEP,
) -> dict[str, Any]:
    """Advance one restart-safe historical projection batch.

    Each invocation reads at most ``max_rows`` canonical display rows. The
    plugin checkpoint contains only cursors, stable origins, result IDs, and
    safe operation headers. User/final content moves directly from the public
    display page into the authoritative turn ledger only after a complete
    boundary is proven.
    """
    import time

    bounded_rows = max(1, min(int(max_rows), MAX_BACKFILL_ROWS_PER_STEP))
    status = db.get_turn_ledger_status(session_id)
    if status["coverage_complete"] or not status["display_lineage_complete"]:
        return {"rows_scanned": 0, **status}
    with _backfill_lock:
        conn = _open_backfill_db()
        try:
            conn.execute("BEGIN IMMEDIATE")
            state = conn.execute(
                "SELECT * FROM backfill_state WHERE session_id = ?", (session_id,)
            ).fetchone()
            revision = int(status["display_revision"])
            if state is None or int(state["display_revision"]) != revision:
                _reset_backfill(conn, session_id, revision)
                state = conn.execute(
                    "SELECT * FROM backfill_state WHERE session_id = ?", (session_id,)
                ).fetchone()
            if bool(state["scan_complete"]):
                conn.commit()
                return {"rows_scanned": 0, **db.refresh_turn_ledger_coverage(session_id)}

            page = db.get_display_messages(
                session_id,
                before_origin_id=state["before_origin_id"],
                limit=bounded_rows,
            )
            if int(page["display_revision"]) != revision:
                _reset_backfill(conn, session_id, int(page["display_revision"]))
                conn.commit()
                return {"rows_scanned": 0, "coverage_complete": False, "reset": True}

            for message in reversed(page["messages"]):
                role = str(message.get("role") or "")
                origin_id = int(message["origin_id"])
                timestamp = float(message.get("timestamp") or 0)
                if role == "tool":
                    operation_id = str(message.get("tool_call_id") or "").strip()
                    if operation_id:
                        conn.execute(
                            "INSERT INTO backfill_results "
                            "(session_id, operation_id, completed_at) VALUES (?, ?, ?) "
                            "ON CONFLICT(session_id, operation_id) DO UPDATE SET "
                            "completed_at = excluded.completed_at",
                            (session_id, operation_id[:256], timestamp),
                        )
                    continue
                if role == "assistant":
                    calls = message.get("tool_calls") or []
                    if calls:
                        for index, call in reversed(list(enumerate(calls))):
                            count = int(
                                conn.execute(
                                    "SELECT COUNT(*) FROM backfill_operations "
                                    "WHERE session_id = ?",
                                    (session_id,),
                                ).fetchone()[0]
                            )
                            if count >= MAX_BACKFILL_OPERATIONS_PER_TURN:
                                conn.execute(
                                    "UPDATE backfill_state SET pending_overflow = 1 "
                                    "WHERE session_id = ?",
                                    (session_id,),
                                )
                                continue
                            operation_id = _tool_id(call, origin_id=origin_id, index=index)
                            name = _tool_name(call)
                            category, label = _safe_tool_metadata(name)
                            result = conn.execute(
                                "SELECT completed_at FROM backfill_results "
                                "WHERE session_id = ? AND operation_id = ?",
                                (session_id, operation_id),
                            ).fetchone()
                            reverse_ordinal = int(
                                conn.execute(
                                    "SELECT COALESCE(MAX(reverse_ordinal), -1) + 1 "
                                    "FROM backfill_operations WHERE session_id = ?",
                                    (session_id,),
                                ).fetchone()[0]
                            )
                            conn.execute(
                                "INSERT OR IGNORE INTO backfill_operations "
                                "(session_id, reverse_ordinal, operation_id, tool_name, "
                                " category, safe_label, state, started_at, completed_at) "
                                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                                (
                                    session_id,
                                    reverse_ordinal,
                                    operation_id,
                                    name,
                                    category,
                                    label,
                                    "completed" if result is not None else "interrupted",
                                    timestamp,
                                    float(result[0]) if result is not None else None,
                                ),
                            )
                    elif _has_visible_content(message.get("content")):
                        conn.execute(
                            "UPDATE backfill_state SET "
                            "pending_final_origin_id = COALESCE("
                            "pending_final_origin_id, ?), "
                            "pending_final_at = COALESCE(pending_final_at, ?) "
                            "WHERE session_id = ?",
                            (origin_id, timestamp, session_id),
                        )
                    continue
                if role != "user":
                    continue

                current = conn.execute(
                    "SELECT pending_final_origin_id, pending_final_at, "
                    "pending_overflow FROM backfill_state WHERE session_id = ?",
                    (session_id,),
                ).fetchone()
                if current["pending_final_origin_id"] is not None and not bool(
                    current["pending_overflow"]
                ):
                    historical_turn_id = f"turn_hist_{origin_id}"
                    db.import_historical_turn(
                        session_id,
                        historical_turn_id,
                        user_origin_id=origin_id,
                        user_content=message.get("content"),
                        accepted_at=timestamp,
                        terminal_origin_id=int(current["pending_final_origin_id"]),
                        terminal_at=float(current["pending_final_at"] or timestamp),
                        operations=_pending_operations(conn, session_id),
                    )
                _clear_pending_boundary(conn, session_id)

            scan_complete = not bool(page["has_older"])
            conn.execute(
                "UPDATE backfill_state SET before_origin_id = ?, scan_complete = ?, "
                "updated_at = ? WHERE session_id = ?",
                (
                    page["previous_cursor"],
                    int(scan_complete),
                    time.time(),
                    session_id,
                ),
            )
            conn.commit()
            coverage = db.refresh_turn_ledger_coverage(session_id)
            return {
                "rows_scanned": len(page["messages"]),
                "scan_complete": scan_complete,
                **coverage,
            }
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()


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


def build_operation_header_page(
    db: Any,
    *,
    session_id: str,
    turn_id: str,
    group_id: str,
    cursor: Optional[str] = None,
    limit: int = 50,
) -> dict[str, Any]:
    """Return one bounded page of safe headers for a deterministic group."""
    safe_limit = max(1, min(int(limit), 100))
    status = db.get_turn_ledger_status(session_id)
    operations = db.get_turn_operations(
        session_id,
        turn_id,
        limit=MAX_OPERATIONS_PER_TURN + 1,
    )
    if len(operations) > MAX_OPERATIONS_PER_TURN:
        raise TurnProjectionError("turn operation count exceeds detail bound")
    selected: list[dict[str, Any]] = []
    current_group_id = None
    current_category = None
    for operation in operations:
        category = str(operation["category"])
        if current_group_id is None or current_category != category:
            digest = hashlib.sha256(
                f"{turn_id}\0{category}\0{operation['operation_id']}".encode("utf-8")
            ).hexdigest()[:24]
            current_group_id = f"group_{digest}"
            current_category = category
        if current_group_id == group_id:
            selected.append(operation)
    offset = 0
    if cursor:
        try:
            padded = cursor + "=" * (-len(cursor) % 4)
            payload = json.loads(base64.urlsafe_b64decode(padded).decode("utf-8"))
            if (
                payload.get("v") != 1
                or payload.get("s") != session_id
                or payload.get("t") != turn_id
                or payload.get("g") != group_id
                or int(payload.get("r")) != int(status["display_revision"])
            ):
                raise ValueError
            offset = int(payload["o"])
        except (KeyError, TypeError, ValueError, UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise TurnProjectionError("invalid operation cursor") from exc
    page = selected[offset : offset + safe_limit]
    next_cursor = None
    next_offset = offset + len(page)
    if next_offset < len(selected):
        raw = json.dumps(
            {
                "v": 1,
                "s": session_id,
                "t": turn_id,
                "g": group_id,
                "r": int(status["display_revision"]),
                "o": next_offset,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        next_cursor = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return {
        "schema_version": 1,
        "stored_session_id": session_id,
        "turn_id": turn_id,
        "group_id": group_id,
        "source_head_id": int(status["display_revision"]),
        "operations": [
            {
                "operation_id": str(item["operation_id"]),
                "group_id": group_id,
                "ordinal": int(item["ordinal"]),
                "kind": str(item["category"]),
                "safe_label": str(item["safe_label"]),
                "state": str(item["state"]),
                "started_at": item.get("started_at"),
                "completed_at": item.get("completed_at"),
                # Raw detail stays disabled until the upstream observer seam
                # can prove bounded, redacted retrieval without private access.
                "detail_available": False,
            }
            for item in page
        ],
        "next_cursor": next_cursor,
    }


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
