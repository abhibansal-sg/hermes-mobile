"""Durable, authorization-scoped sync manifest journal for Hermes Mobile.

The journal is deliberately separate from ``state.db``: SessionDB remains the
read-only authority while this plugin records observations, revisions,
tombstones, and opaque cursors needed for reliable reconciliation.
"""

from __future__ import annotations

import json
import os
import secrets
import sqlite3
import stat
import threading
import time
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable

from hermes_constants import get_hermes_home
from hermes_state import SessionDB

CAPABILITIES_VERSION = 1
PAGE_SIZE = 500
CURSOR_RETENTION_SECONDS = 30 * 24 * 3600
MIN_REVISIONS_RETAINED = 10_000
_lock = threading.RLock()


class ManifestError(Exception):
    def __init__(self, status: int, code: str, message: str, *, reset: bool = False):
        super().__init__(message)
        self.status, self.code, self.message, self.reset = status, code, message, reset


def normalize_scope(raw: str) -> str:
    if not isinstance(raw, str) or not raw or len(raw.encode("utf-8")) > 256:
        raise ManifestError(400, "invalid_scope", "Invalid manifest scope")
    if raw == "all":
        return raw
    if not raw.startswith("profile:"):
        raise ManifestError(400, "invalid_scope", "Invalid manifest scope")
    encoded = raw[8:]
    if not encoded or "%" in encoded and any(
        encoded[i] == "%" and (i + 2 >= len(encoded) or any(c not in "0123456789abcdefABCDEF" for c in encoded[i + 1:i + 3]))
        for i in range(len(encoded))
    ):
        raise ManifestError(400, "invalid_scope", "Invalid manifest scope")
    try:
        profile = urllib.parse.unquote(encoded, errors="strict")
    except (UnicodeDecodeError, ValueError):
        raise ManifestError(400, "invalid_scope", "Invalid manifest scope")
    if profile == "all" or not 1 <= len(profile.encode("utf-8")) <= 128 or any(ord(c) < 32 or ord(c) == 127 for c in profile):
        raise ManifestError(400, "invalid_scope", "Invalid manifest scope")
    return "profile:" + profile


def _path() -> Path:
    path = get_hermes_home() / "mobile" / "sync-manifest.sqlite3"
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    return path


def _connect() -> sqlite3.Connection:
    path = _path()
    conn = sqlite3.connect(str(path), timeout=10, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    conn.executescript("""
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
      INSERT OR IGNORE INTO meta(key,value) VALUES('revision',0);
      CREATE TABLE IF NOT EXISTS snapshots(
        scope TEXT NOT NULL, visibility TEXT NOT NULL, entity_key TEXT NOT NULL,
        payload TEXT NOT NULL, revision INTEGER NOT NULL,
        PRIMARY KEY(scope,visibility,entity_key));
      CREATE TABLE IF NOT EXISTS changes(
        scope TEXT NOT NULL, visibility TEXT NOT NULL, revision INTEGER NOT NULL,
        entity_key TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL,
        created_at REAL NOT NULL, PRIMARY KEY(scope,visibility,revision,entity_key));
      CREATE TABLE IF NOT EXISTS cursors(
        token TEXT PRIMARY KEY, scope TEXT NOT NULL, visibility TEXT NOT NULL,
        base_revision INTEGER NOT NULL, target_revision INTEGER NOT NULL,
        position INTEGER NOT NULL, is_full INTEGER NOT NULL, snapshot TEXT,
        created_at REAL NOT NULL, expires_at REAL NOT NULL);
      CREATE INDEX IF NOT EXISTS changes_lookup ON changes(scope,visibility,revision);
      CREATE TABLE IF NOT EXISTS dirty_reasons(
        revision INTEGER NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS state_snapshots(
        scope TEXT NOT NULL, visibility TEXT NOT NULL, payload TEXT NOT NULL,
        revision INTEGER NOT NULL, PRIMARY KEY(scope,visibility));
    """)
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(path) + suffix)
            if sidecar.exists():
                os.chmod(sidecar, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass
    return conn


def _profile_for_home(home: Path) -> str:
    return home.name if home.parent.name == "profiles" else "default"


def _homes(scope: str) -> Iterable[tuple[str, Path]]:
    current = get_hermes_home()
    current_profile = _profile_for_home(current)
    if scope != "all":
        wanted = scope[8:]
        if wanted == current_profile:
            yield wanted, current
            return
        root = current.parent.parent if current.parent.name == "profiles" else current
        candidate = root / "profiles" / wanted
        if (candidate / "state.db").exists():
            yield wanted, candidate
        return
    yielded: set[Path] = set()
    if (current / "state.db").exists():
        yielded.add(current)
        yield current_profile, current
    root = current.parent.parent if current.parent.name == "profiles" else current
    profiles = root / "profiles"
    if profiles.is_dir():
        for candidate in sorted(profiles.iterdir()):
            if candidate not in yielded and (candidate / "state.db").exists():
                yield candidate.name, candidate


def _session_rows(scope: str, active_keys: set[tuple[str, str]]) -> tuple[list[dict], list[dict]]:
    sessions: list[dict] = []
    heads: list[dict] = []
    for profile, home in _homes(scope):
        path = home / "state.db"
        if not path.exists():
            continue
        db = SessionDB(path, read_only=True)
        try:
            rows = db.list_sessions_rich(
                source=None, exclude_sources=None, limit=100_000,
                min_message_count=0, order_by_last_active=True,
                include_archived=True, compact_rows=True,
            )
            conn = db._conn
            head_rows = {
                r["session_id"]: r for r in conn.execute(
                    "SELECT session_id, MAX(id) max_id, COUNT(*) n, MAX(timestamp) last_at "
                    "FROM messages WHERE active=1 GROUP BY session_id"
                )
            }
            for row in rows:
                sid = str(row["id"])
                archived = bool(row.get("archived"))
                item = {
                    "id": sid, "profile": profile, "title": str(row.get("title") or ""),
                    "preview": row.get("preview"), "started_at": row.get("started_at"),
                    "message_count": int(row.get("message_count") or 0),
                    "source": row.get("source"), "last_active": row.get("last_active"),
                    "cwd": row.get("cwd"), "archived": archived,
                    "is_active": (profile, sid) in active_keys,
                }
                sessions.append(item)
                h = head_rows.get(sid)
                heads.append({
                    "session_id": sid, "profile": profile,
                    "max_message_id": int(h["max_id"]) if h and h["max_id"] is not None else None,
                    "message_count": int(h["n"]) if h else 0,
                    "last_message_at": float(h["last_at"]) if h and h["last_at"] is not None else None,
                })
        finally:
            db.close()
    return sessions, heads


def capture_runtime() -> tuple[list[dict], list[dict], set[tuple[str, str]]]:
    try:
        from tools.approval import pending_approval_snapshot
        from tui_gateway.server import (
            _sessions,
            _sessions_lock,
            attention_session_identities,
            pending_prompt_snapshot,
        )
    except Exception as exc:
        raise ManifestError(503, "state_unavailable", f"Gateway state unavailable: {exc}")
    with _sessions_lock:
        copied_sessions = [(str(sid), dict(rec)) for sid, rec in _sessions.items()]
    runtime_by_stored = {
        str(item.get("stored_session_id") or ""): str(item.get("session_id") or "")
        for item in attention_session_identities()
        if item.get("stored_session_id") and item.get("session_id")
    }
    copied_attention = []
    for source in pending_approval_snapshot():
        item = dict(source)
        stored_id = str(item.get("stored_session_id") or "")
        item["session_id"] = runtime_by_stored.get(stored_id, stored_id)
        copied_attention.append(item)
    copied_attention.extend(pending_prompt_snapshot())
    by_runtime = {sid: rec for sid, rec in copied_sessions}
    active: list[dict] = []
    keys: set[tuple[str, str]] = set()
    pending_owners = {
        str(item.get("session_id") or "")
        for item in copied_attention
        if item.get("status") in {"pending", "failed_retry", "responding"}
    }
    for sid, rec in copied_sessions:
        if not rec.get("running") and sid not in pending_owners:
            continue
        stored = rec.get("session_key")
        profile = _profile_for_home(Path(rec["profile_home"])) if rec.get("profile_home") else "default"
        if stored:
            keys.add((profile, str(stored)))
        active.append({
            "session_id": sid, "stored_session_id": str(stored) if stored else None,
            "profile": profile, "started_at": rec.get("turn_started_at") or rec.get("last_active") or rec.get("created_at"),
            "state": "waiting_for_attention" if sid in pending_owners else "running",
        })
    attention: list[dict] = []
    for source in copied_attention:
        item = dict(source)
        owner = str(item.get("session_id") or "")
        rec = by_runtime.get(owner, {})
        stored = item.get("stored_session_id") or rec.get("session_key")
        profile = _profile_for_home(Path(rec["profile_home"])) if rec.get("profile_home") else "default"
        if item.get("kind") == "clarify":
            detail = dict(item.get("detail") or {})
            detail.setdefault("prompt", detail.get("question"))
            item["detail"] = detail
        item.update(
            session_id=owner,
            stored_session_id=str(stored) if stored else None,
            profile=profile,
        )
        attention.append(item)
    return attention, active, keys


def _key(item: dict) -> str:
    return f"session:{item['profile']}:{item['id']}"


def _filtered(scope: str, visibility_check: Callable[[str], bool]) -> tuple[list[dict], list[dict], list[dict], list[dict], dict[str, str]]:
    attention, active, active_keys = capture_runtime()
    sessions, heads = _session_rows(scope, active_keys)
    profile = None if scope == "all" else scope[8:]
    def eligible(s: dict) -> bool:
        return (
            not s["archived"]
            and int(s.get("message_count") or 0) >= 1
            and str(s.get("source") or "").lower() not in {"cron", "subagent", "tool"}
        )
    reasons = {
        _key(s): ("archived" if s["archived"] else "filtered")
        for s in sessions
        if (profile is None or s["profile"] == profile)
    }
    sessions = [s for s in sessions if eligible(s) and (profile is None or s["profile"] == profile) and visibility_check(s["id"])]
    allowed = {(s["profile"], s["id"]) for s in sessions}
    def runtime_ok(x: dict) -> bool:
        stored = x.get("stored_session_id")
        return bool(stored and (x["profile"], stored) in allowed and visibility_check(stored))
    attention = [x for x in attention if runtime_ok(x)]
    active = [x for x in active if runtime_ok(x)]
    heads = [h for h in heads if (h["profile"], h["session_id"]) in allowed and visibility_check(h["session_id"])]
    return sessions, attention, active, heads, reasons


def _new_cursor(conn: sqlite3.Connection, **values: Any) -> str:
    now = time.time()
    existing = conn.execute(
        "SELECT token FROM cursors WHERE scope=? AND visibility=? AND base_revision=? "
        "AND target_revision=? AND position=? AND is_full=? AND snapshot IS ? "
        "AND expires_at>=? ORDER BY created_at LIMIT 1",
        (values["scope"], values["visibility"], values["base_revision"],
         values["target_revision"], values["position"], int(values["is_full"]),
         values.get("snapshot"), now),
    ).fetchone()
    if existing is not None:
        return str(existing["token"])
    token = "m1." + secrets.token_urlsafe(32)
    conn.execute(
        "INSERT INTO cursors(token,scope,visibility,base_revision,target_revision,position,is_full,snapshot,created_at,expires_at) VALUES(?,?,?,?,?,?,?,?,?,?)",
        (token, values["scope"], values["visibility"], values["base_revision"], values["target_revision"], values["position"], int(values["is_full"]), values.get("snapshot"), now, now + CURSOR_RETENTION_SECONDS),
    )
    return token


def _error_cursor(conn: sqlite3.Connection, token: str, scope: str, visibility: str) -> sqlite3.Row:
    if len(token.encode("utf-8")) > 1024 or not token.startswith("m1."):
        raise ManifestError(400, "invalid_cursor", "Invalid manifest cursor")
    row = conn.execute("SELECT * FROM cursors WHERE token=?", (token,)).fetchone()
    if row is None:
        raise ManifestError(400, "invalid_cursor", "Invalid manifest cursor")
    if row["scope"] != scope or row["visibility"] != visibility:
        raise ManifestError(409, "cursor_scope_mismatch", "Manifest cursor belongs to another scope or owner")
    current_revision = int(conn.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0])
    if row["expires_at"] < time.time() and current_revision - int(row["base_revision"]) >= MIN_REVISIONS_RETAINED:
        raise ManifestError(410, "cursor_expired", "Manifest cursor is no longer retained", reset=True)
    return row


def build_manifest(
    *, scope: str, cursor: str | None, visibility: str,
    visibility_check: Callable[[str], bool], device_registered: bool,
) -> dict:
    scope = normalize_scope(scope)
    with _lock, _connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            cursor_row = _error_cursor(conn, cursor, scope, visibility) if cursor else None
            # Continuation tokens replay their immutable serialized logical response.
            if cursor_row is not None and cursor_row["snapshot"] is not None:
                frozen = json.loads(cursor_row["snapshot"])
                return _page(conn, frozen, int(cursor_row["position"]), scope, visibility, int(cursor_row["base_revision"]), bool(cursor_row["is_full"]))

            sessions, attention, active, heads, absence_reasons = _filtered(scope, visibility_check)
            now = time.time()
            old_rows = {r["entity_key"]: r for r in conn.execute("SELECT * FROM snapshots WHERE scope=? AND visibility=?", (scope, visibility))}
            current = {_key(s): s for s in sessions}
            changed: list[tuple[str, str, dict]] = []
            for key, item in current.items():
                payload = json.dumps(item, sort_keys=True, separators=(",", ":"))
                if key not in old_rows or old_rows[key]["payload"] != payload:
                    changed.append((key, "upsert", item))
            for key, row in old_rows.items():
                if key not in current:
                    old = json.loads(row["payload"])
                    changed.append((key, "tombstone", {"session_id": old["id"], "profile": old["profile"], "deleted_at": now, "reason": absence_reasons.get(key, "deleted")}))
            aux_payload = json.dumps(
                {"attention": attention, "active": active, "heads": heads,
                 "device_registered": bool(device_registered)},
                sort_keys=True, separators=(",", ":"),
            )
            old_aux = conn.execute(
                "SELECT payload FROM state_snapshots WHERE scope=? AND visibility=?",
                (scope, visibility),
            ).fetchone()
            aux_changed = old_aux is None or old_aux["payload"] != aux_payload
            base = int(cursor_row["target_revision"]) if cursor_row else 0
            if changed or aux_changed or not old_rows:
                conn.execute("UPDATE meta SET value=value+1 WHERE key='revision'")
            revision = int(conn.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0])
            if changed:
                conn.execute("INSERT INTO dirty_reasons VALUES(?,?,?)", (revision, "sessions", now))
                for key, kind, item in changed:
                    item = dict(item, revision=revision)
                    conn.execute("INSERT OR REPLACE INTO changes VALUES(?,?,?,?,?,?,?)", (scope, visibility, revision, key, kind, json.dumps(item, separators=(",", ":")), now))
                conn.execute("DELETE FROM snapshots WHERE scope=? AND visibility=?", (scope, visibility))
                conn.executemany("INSERT INTO snapshots VALUES(?,?,?,?,?)", [(scope, visibility, k, json.dumps(v, sort_keys=True, separators=(",", ":")), revision) for k, v in current.items()])
            if aux_changed:
                conn.execute(
                    "INSERT OR REPLACE INTO state_snapshots VALUES(?,?,?,?)",
                    (scope, visibility, aux_payload, revision),
                )
                conn.execute("INSERT INTO dirty_reasons VALUES(?,?,?)", (revision, "coalesced", now))

            if cursor_row:
                logical = [(r["kind"], json.loads(r["payload"])) for r in conn.execute("SELECT kind,payload FROM changes WHERE scope=? AND visibility=? AND revision>? AND revision<=? ORDER BY revision,entity_key", (scope, visibility, base, revision))]
                is_full = False
            else:
                logical = [("upsert", dict(item, revision=revision)) for item in sessions]
                is_full = True
            response_heads = heads
            if not is_full:
                prior_aux = json.loads(old_aux["payload"]) if old_aux is not None else {}
                prior_heads = {
                    (h["profile"], h["session_id"]): h
                    for h in prior_aux.get("heads", [])
                }
                needed = {
                    (x["profile"], x["stored_session_id"])
                    for x in attention + active if x.get("stored_session_id")
                }
                needed.update(
                    (payload["profile"], payload["id"])
                    for kind, payload in logical if kind == "upsert"
                )
                response_heads = [
                    h for h in heads
                    if (h["profile"], h["session_id"]) in needed
                    or prior_heads.get((h["profile"], h["session_id"])) != h
                ]
            revisionize = lambda xs: [dict(x, revision=revision) for x in xs]
            frozen = {
                "server_time": now, "revision": revision,
                "items": logical, "attention": revisionize(attention),
                "active": revisionize(active), "heads": revisionize(response_heads),
                "widget": {
                    "open_session_count": len(sessions), "active_turn_count": len(active),
                    "pending_attention_count": sum(x["status"] in ("pending", "failed_retry") for x in attention),
                    "tokens_today": None, "estimated_cost_today": None,
                },
                "push": {"device_registered": bool(device_registered)},
            }
            return _page(conn, frozen, 0, scope, visibility, base, is_full)
        except Exception:
            conn.execute("ROLLBACK")
            raise


def _page(conn: sqlite3.Connection, frozen: dict, position: int, scope: str, visibility: str, base: int, is_full: bool) -> dict:
    items = frozen["items"]
    chunk = items[position:position + PAGE_SIZE]
    end = position + len(chunk)
    complete = end >= len(items)
    serialized = json.dumps(frozen, separators=(",", ":"))
    next_cursor = _new_cursor(
        conn, scope=scope, visibility=visibility, base_revision=base,
        target_revision=frozen["revision"], position=0 if complete else end,
        is_full=is_full, snapshot=None if complete else serialized,
    )
    upserts = [v for kind, v in chunk if kind == "upsert"]
    tombstones = [v for kind, v in chunk if kind == "tombstone"]
    page_keys = {(x["profile"], x["id"]) for x in upserts}
    heads = frozen["heads"] if complete and not items else [h for h in frozen["heads"] if (h["profile"], h["session_id"]) in page_keys]
    result = {
        "server_time": frozen["server_time"], "revision": frozen["revision"], "scope": scope,
        "is_full_sync": is_full, "complete": complete, "next_cursor": next_cursor,
        "capabilities_version": CAPABILITIES_VERSION,
        "sessions": {"upserts": upserts, "tombstones": tombstones},
        "pending_attention": frozen["attention"], "active_turns": frozen["active"],
        "transcript_heads": heads, "widget_summary": frozen["widget"], "push_registry": frozen["push"],
    }
    conn.execute("COMMIT")
    return result


def device_is_registered(device_id: str | None, registry_entries: Iterable[dict]) -> bool:
    return bool(device_id) and any(entry.get("device_id") == device_id for entry in registry_entries)
