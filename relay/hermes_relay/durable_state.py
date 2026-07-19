"""Small durable control-plane state for the phone-facing relay."""

from __future__ import annotations

import json
import hashlib
import os
import sqlite3
import time
import uuid
from pathlib import Path
from threading import RLock
from typing import Any, Optional

from .types import Frame, FrameKind


class DurableState:
    """Persists attention deltas and push work across relay restarts."""

    def __init__(self, path: Optional[Path] = None) -> None:
        home = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
        self.path = path or home / "relay" / "state.sqlite3"
        self._lock = RLock()

    def _connect(self) -> sqlite3.Connection:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        db.executescript(
            """
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS attention (
              id TEXT PRIMARY KEY, payload TEXT NOT NULL, deleted INTEGER NOT NULL,
              revision INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS push_outbox (
              event_id TEXT PRIMARY KEY, payload TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
              next_attempt REAL NOT NULL, expires_at REAL NOT NULL, status TEXT NOT NULL DEFAULT 'pending'
            );
            CREATE TABLE IF NOT EXISTS manifest_sessions (
              scope TEXT NOT NULL, id TEXT NOT NULL, payload TEXT NOT NULL,
              deleted INTEGER NOT NULL, revision INTEGER NOT NULL,
              PRIMARY KEY(scope,id)
            );
            CREATE TABLE IF NOT EXISTS active_turns (
              session_id TEXT PRIMARY KEY, turn_id TEXT, started_at REAL NOT NULL
            );
            """
        )
        db.execute(
            "INSERT OR IGNORE INTO meta(key,value) VALUES('instance_id',?)",
            (uuid.uuid4().hex,),
        )
        db.execute("INSERT OR IGNORE INTO meta(key,value) VALUES('revision','0')")
        db.commit()
        return db

    def current_revision(self) -> int:
        with self._lock, self._connect() as db:
            return int(db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0])

    @staticmethod
    def _next_revision(db: sqlite3.Connection) -> int:
        revision = int(db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0]) + 1
        db.execute("UPDATE meta SET value=? WHERE key='revision'", (str(revision),))
        return revision

    def observe_frame(self, frame: Frame, now: Optional[float] = None) -> None:
        if frame.kind in (FrameKind.APPROVAL_REQUEST, FrameKind.CLARIFY_REQUEST):
            self._upsert_attention(frame, now or time.time())
        elif frame.kind == FrameKind.TURN_COMPLETED and frame.sid:
            self.resolve_attention(session_id=frame.sid, status="expired", now=now)
            self._set_active_turn(frame, active=False, now=now)
        elif frame.kind == FrameKind.TURN_STARTED and frame.sid:
            self._set_active_turn(frame, active=True, now=now)

    def _set_active_turn(self, frame: Frame, *, active: bool, now: Optional[float]) -> None:
        with self._lock, self._connect() as db:
            exists = db.execute(
                "SELECT 1 FROM active_turns WHERE session_id=?", (frame.sid,)
            ).fetchone()
            if active:
                db.execute(
                    "INSERT OR REPLACE INTO active_turns VALUES(?,?,?)",
                    (frame.sid, frame.turn, now or time.time()),
                )
            else:
                db.execute("DELETE FROM active_turns WHERE session_id=?", (frame.sid,))
            if bool(exists) != active:
                self._next_revision(db)

    def _upsert_attention(self, frame: Frame, now: float) -> None:
        body = frame.body or {}
        kind = "clarify" if frame.kind == FrameKind.CLARIFY_REQUEST else "approval"
        request_id = str(
            body.get("approval_id") or body.get("request_id") or body.get("id")
            or frame.turn or frame.sid
        )
        record_id = request_id if request_id.startswith(f"{kind}:") else f"{kind}:{request_id}"
        detail = {
            "description": str(body.get("description") or body.get("target") or "")[:500]
                if kind == "approval" else None,
            "question": str(body.get("question") or body.get("prompt") or "")[:500]
                if kind == "clarify" else None,
            "choices": [str(x)[:100] for x in (body.get("choices") or [])[:20]],
        }
        record = {
            "id": record_id, "request_id": request_id, "kind": kind,
            "session_id": frame.sid, "stored_session_id": body.get("stored_session_id"),
            "safe_title": "Clarification required" if kind == "clarify" else "Approval required",
            "detail": detail, "destructive": bool(body.get("destructive")),
            "created_at": float(body.get("created_at") or now),
            "expires_at": body.get("expires_at"), "status": "pending",
        }
        with self._lock, self._connect() as db:
            previous = db.execute("SELECT payload,deleted FROM attention WHERE id=?", (record_id,)).fetchone()
            if previous and not previous["deleted"]:
                previous_record = json.loads(previous["payload"])
                previous_record.pop("revision", None)
                if previous_record == record:
                    return
            revision = self._next_revision(db)
            record["revision"] = revision
            db.execute(
                "INSERT OR REPLACE INTO attention(id,payload,deleted,revision) VALUES(?,?,0,?)",
                (record_id, json.dumps(record), revision),
            )

    def resolve_attention(
        self, *, request_id: Optional[str] = None, session_id: Optional[str] = None,
        kind: Optional[str] = None, status: str = "resolved_elsewhere",
        now: Optional[float] = None,
    ) -> None:
        with self._lock, self._connect() as db:
            rows = db.execute("SELECT * FROM attention WHERE deleted=0").fetchall()
            for row in rows:
                record = json.loads(row["payload"])
                if request_id and record["request_id"] != request_id:
                    continue
                if session_id and record["session_id"] != session_id:
                    continue
                if kind and record["kind"] != kind:
                    continue
                revision = self._next_revision(db)
                tombstone = {
                    key: record.get(key) for key in
                    ("id", "request_id", "kind", "session_id", "stored_session_id")
                }
                tombstone.update(status=status, deleted_at=now or time.time(), revision=revision)
                db.execute(
                    "UPDATE attention SET payload=?,deleted=1,revision=? WHERE id=?",
                    (json.dumps(tombstone), revision, row["id"]),
                )

    def pending_attention(self, cursor: Optional[str]) -> dict[str, Any]:
        with self._lock, self._connect() as db:
            instance = db.execute("SELECT value FROM meta WHERE key='instance_id'").fetchone()[0]
            revision = int(db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0])
            requested: Optional[int] = None
            reason: Optional[str] = "initial_snapshot" if not cursor else None
            if cursor:
                parts = cursor.split(".")
                try:
                    if len(parts) != 3 or parts[0] != "pa1":
                        raise ValueError
                    if parts[1] != instance:
                        reason = "foreign_instance"
                    else:
                        requested = int(parts[2])
                        if requested < 0 or requested > revision:
                            reason = "cursor_ahead"
                except ValueError:
                    reason = "invalid_cursor"
            rows = db.execute(
                "SELECT * FROM attention WHERE ? IS NULL OR revision>? ORDER BY revision,id",
                (requested if reason is None else None, requested or 0),
            ).fetchall()
            if reason is not None:
                rows = db.execute(
                    "SELECT * FROM attention WHERE deleted=0 ORDER BY revision,id"
                ).fetchall()
            upserts, tombstones = [], []
            for row in rows:
                (tombstones if row["deleted"] else upserts).append(json.loads(row["payload"]))
            return {
                "server_instance_id": instance, "cursor": f"pa1.{instance}.{revision}",
                "reset": reason is not None, "reset_reason": reason,
                "upserts": upserts, "tombstones": tombstones,
            }

    def sync_manifest(
        self, scope: str, cursor: Optional[str], sessions: list[dict[str, Any]]
    ) -> dict[str, Any]:
        """Reconcile the stock gateway's session list into one delta page."""
        scope = scope or "all"
        normalized: dict[str, dict[str, Any]] = {}
        for source in sessions:
            profile = str(source.get("profile") or "default")
            if scope != "all" and profile != scope:
                continue
            sid = str(source.get("id") or "")
            if not sid:
                continue
            normalized[sid] = {
                key: source.get(key) for key in (
                    "id", "title", "preview", "started_at", "message_count",
                    "source", "last_active", "cwd", "profile",
                ) if source.get(key) is not None
            }
        with self._lock, self._connect() as db:
            previous_rows = db.execute(
                "SELECT * FROM manifest_sessions WHERE scope=?", (scope,)
            ).fetchall()
            previous = {row["id"]: row for row in previous_rows if not row["deleted"]}
            changed = [sid for sid, item in normalized.items()
                       if sid not in previous or json.loads(previous[sid]["payload"]) != item]
            removed = sorted(set(previous) - set(normalized))
            if changed or removed:
                revision = self._next_revision(db)
                for sid in changed:
                    db.execute(
                        "INSERT OR REPLACE INTO manifest_sessions VALUES(?,?,?,0,?)",
                        (scope, sid, json.dumps(normalized[sid]), revision),
                    )
                for sid in removed:
                    db.execute(
                        "UPDATE manifest_sessions SET payload=?,deleted=1,revision=? WHERE scope=? AND id=?",
                        (json.dumps({"id": sid}), revision, scope, sid),
                    )
            instance = db.execute("SELECT value FROM meta WHERE key='instance_id'").fetchone()[0]
            revision = int(db.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0])
            scope_id = hashlib.sha256(scope.encode()).hexdigest()[:12]
            requested, reset = None, cursor is None
            if cursor:
                parts = cursor.split(".")
                try:
                    if (len(parts) != 4 or parts[0] != "sm1"
                            or parts[1] != instance or parts[2] != scope_id):
                        raise ValueError
                    requested = int(parts[3])
                    reset = requested < 0 or requested > revision
                except ValueError:
                    reset = True
            if reset:
                rows = db.execute(
                    "SELECT * FROM manifest_sessions WHERE scope=? AND deleted=0 ORDER BY id",
                    (scope,),
                ).fetchall()
            else:
                rows = db.execute(
                    "SELECT * FROM manifest_sessions WHERE scope=? AND revision>? ORDER BY revision,id",
                    (scope, requested),
                ).fetchall()
            upserts = [json.loads(row["payload"]) for row in rows if not row["deleted"]]
            tombstones = [json.loads(row["payload"]) for row in rows if row["deleted"]]
            attention_rows = db.execute(
                "SELECT payload FROM attention WHERE deleted=0 ORDER BY revision,id"
            ).fetchall()
            attention = []
            for row in attention_rows:
                item = json.loads(row["payload"])
                attention.append({
                    "id": item["id"], "session_id": item["session_id"],
                    "kind": item["kind"], "title": item.get("safe_title"),
                })
            active = [
                {"id": f"turn:{row['session_id']}", "session_id": row["session_id"], "state": "running"}
                for row in db.execute("SELECT session_id FROM active_turns ORDER BY session_id")
            ]
            heads = {
                str(item["id"]): int(item.get("message_count") or 0)
                for item in normalized.values()
            }
            return {
                "revision": revision, "cursor": f"sm1.{instance}.{scope_id}.{revision}",
                "next_cursor": None, "has_more": False, "reset": reset,
                "sessions": upserts, "tombstones": tombstones,
                "attention": attention, "active_turns": active,
                "transcript_heads": heads, "device_registered": None,
                "capabilities": ["relay_attention", "relay_sync_manifest"],
                "server_time": time.time(),
            }

    def enqueue_push(self, descriptor: dict[str, Any], now: Optional[float] = None) -> bool:
        timestamp = now or time.time()
        event_id = descriptor["collapse_id"]
        ttl = max(int(descriptor.get("expiration") or 0), 15 * 60)
        with self._lock, self._connect() as db:
            changed = db.execute(
                "INSERT OR IGNORE INTO push_outbox(event_id,payload,next_attempt,expires_at) VALUES(?,?,?,?)",
                (event_id, json.dumps(descriptor), timestamp, timestamp + ttl),
            ).rowcount
            return changed == 1

    def due_pushes(self, now: Optional[float] = None) -> list[dict[str, Any]]:
        timestamp = now or time.time()
        with self._lock, self._connect() as db:
            db.execute("UPDATE push_outbox SET status='expired' WHERE status='pending' AND expires_at<=?", (timestamp,))
            rows = db.execute(
                "SELECT event_id,payload,attempts FROM push_outbox "
                "WHERE status='pending' AND next_attempt<=? ORDER BY next_attempt LIMIT 32",
                (timestamp,),
            ).fetchall()
            return [dict(json.loads(row["payload"]), _event_id=row["event_id"], _attempts=row["attempts"]) for row in rows]

    def finish_push(self, event_id: str, delivered: bool, attempts: int, now: Optional[float] = None) -> None:
        with self._lock, self._connect() as db:
            if delivered:
                db.execute("UPDATE push_outbox SET status='delivered' WHERE event_id=?", (event_id,))
            else:
                delay = min(2 ** min(attempts + 1, 8), 300)
                db.execute(
                    "UPDATE push_outbox SET attempts=?,next_attempt=? WHERE event_id=?",
                    (attempts + 1, (now or time.time()) + delay, event_id),
                )
