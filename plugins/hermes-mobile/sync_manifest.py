"""Durable, authorization-scoped sync manifest journal for Hermes Mobile.

The journal is deliberately separate from ``state.db``: SessionDB remains the
read-only authority while this plugin records observations, revisions,
tombstones, and opaque cursors needed for reliable reconciliation.
"""

from __future__ import annotations

import json
import importlib.util
import hashlib
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

SCHEMA_VERSION = 2
DEFAULT_PAGE_SIZE = 500
MAX_PAGE_SIZE = 500
CURSOR_RETENTION_SECONDS = 90 * 24 * 3600
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
    if (
        profile == "all"
        or not profile.startswith("pf_")
        or not 6 <= len(profile.encode("utf-8")) <= 128
        or any(ord(c) < 32 or ord(c) == 127 for c in profile)
    ):
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
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
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
        created_at REAL NOT NULL, expires_at REAL NOT NULL,
        journal_epoch TEXT, cursor_kind TEXT, snapshot_id TEXT,
        gateway_id TEXT, authority_digest TEXT, page_size INTEGER);
      CREATE INDEX IF NOT EXISTS changes_lookup ON changes(scope,visibility,revision);
      CREATE TABLE IF NOT EXISTS dirty_reasons(
        revision INTEGER NOT NULL, reason TEXT NOT NULL, created_at REAL NOT NULL);
      CREATE TABLE IF NOT EXISTS state_snapshots(
        scope TEXT NOT NULL, visibility TEXT NOT NULL, payload TEXT NOT NULL,
        revision INTEGER NOT NULL, PRIMARY KEY(scope,visibility));
    """)
    conn.execute(
        "INSERT OR IGNORE INTO meta(key,value) VALUES('journal_epoch',?)",
        ("je_" + secrets.token_urlsafe(16),),
    )
    cursor_columns = {
        str(row[1]) for row in conn.execute("PRAGMA table_info(cursors)").fetchall()
    }
    if "journal_epoch" not in cursor_columns:
        conn.execute("ALTER TABLE cursors ADD COLUMN journal_epoch TEXT")
    for name, sql_type in (
        ("cursor_kind", "TEXT"),
        ("snapshot_id", "TEXT"),
        ("gateway_id", "TEXT"),
        ("authority_digest", "TEXT"),
        ("page_size", "INTEGER"),
    ):
        if name not in cursor_columns:
            conn.execute(f"ALTER TABLE cursors ADD COLUMN {name} {sql_type}")
    schema_row = conn.execute(
        "SELECT value FROM meta WHERE key='schema_version'"
    ).fetchone()
    if schema_row is None or str(schema_row[0]) != str(SCHEMA_VERSION):
        # v1 and v2 cursors/snapshots are intentionally incompatible. Rotate
        # only the plugin journal identity; SessionDB authority is untouched.
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("DELETE FROM snapshots")
            conn.execute("DELETE FROM changes")
            conn.execute("DELETE FROM dirty_reasons")
            conn.execute("DELETE FROM state_snapshots")
            conn.execute("UPDATE meta SET value='0' WHERE key='revision'")
            conn.execute(
                "UPDATE meta SET value=? WHERE key='journal_epoch'",
                ("je_" + secrets.token_urlsafe(16),),
            )
            conn.execute(
                "INSERT INTO meta(key,value) VALUES('schema_version',?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (str(SCHEMA_VERSION),),
            )
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
    try:
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(path) + suffix)
            if sidecar.exists():
                os.chmod(sidecar, stat.S_IRUSR | stat.S_IWUSR)
    except OSError:
        pass
    return conn


def _journal_epoch(conn: sqlite3.Connection) -> str:
    row = conn.execute(
        "SELECT value FROM meta WHERE key='journal_epoch'"
    ).fetchone()
    value = str(row[0]) if row is not None else ""
    if not value.startswith("je_"):
        raise ManifestError(503, "journal_identity_invalid", "Manifest journal identity is invalid")
    return value


def _profile_for_home(home: Path) -> str:
    return home.name if home.parent.name == "profiles" else "default"


def _candidate_homes() -> tuple[tuple[str, Path], ...]:
    current = get_hermes_home()
    root = current.parent.parent if current.parent.name == "profiles" else current
    candidates: list[tuple[str, Path]] = []
    yielded: set[Path] = set()
    if (root / "state.db").exists():
        yielded.add(root)
        candidates.append(("default", root))
    profiles = root / "profiles"
    if profiles.is_dir():
        for candidate in sorted(profiles.iterdir()):
            if candidate not in yielded and (candidate / "state.db").exists():
                yielded.add(candidate)
                candidates.append((candidate.name, candidate))
    if current not in yielded and (current / "state.db").exists():
        candidates.append((_profile_for_home(current), current))
    return tuple(candidates)


def _authority_module():
    """Load the sibling identity module in package and direct-test modes."""
    if __package__:
        from importlib import import_module

        return import_module(f"{__package__}.authority_identity")
    path = Path(__file__).with_name("authority_identity.py")
    name = f"hermes_mobile_authority_identity_{id(path)}"
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:  # pragma: no cover - defensive
        raise ImportError("cannot load authority identity module")
    module = importlib.util.module_from_spec(spec)
    import sys

    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _resolve_authority_scope(scope: str):
    """Resolve one v2 authority scope without writing inactive profiles."""
    try:
        homes = _candidate_homes()
        if not homes:
            raise AuthorityError("no profile databases in requested scope")
        identity = _authority_module()
        current = get_hermes_home()
        current_name = _profile_for_home(current)
        if any(home == current for _, home in homes):
            identity.ensure_profile_authority(current_name, current)
        if scope == "all":
            selected = homes
        else:
            wanted = scope[8:]
            selected = tuple(
                (name, home)
                for name, home in homes
                if identity.read_profile_meta(home).get("profile_id") == wanted
            )
            if len(selected) != 1:
                raise AuthorityError("requested profile identity is unavailable")
        context = identity.read_profile_authorities(selected)
        by_name = {item.profile_name: item for item in context.profiles}
        resolved = tuple((by_name[name], home) for name, home in selected)
        return context, resolved
    except ManifestError:
        raise
    except Exception as exc:
        raise ManifestError(
            503,
            "identity_pending",
            f"Authority identity unavailable: {exc}",
        ) from exc


class AuthorityError(RuntimeError):
    pass


def _session_rows(
    homes: tuple[tuple[Any, Path], ...],
    active_keys: set[tuple[str, str]],
) -> tuple[list[dict], list[dict]]:
    sessions: list[dict] = []
    heads: list[dict] = []
    for authority, home in homes:
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
            head_rows = {
                row["session_id"]: row
                for row in db.list_active_message_heads(limit=100_000)
            }
            for row in rows:
                sid = str(row["id"])
                archived = bool(row.get("archived"))
                item = {
                    "id": sid,
                    "profile": authority.profile_name,
                    "profile_id": authority.profile_id,
                    "authority_epoch": authority.authority_epoch,
                    "title": str(row.get("title") or ""),
                    "preview": row.get("preview"), "started_at": row.get("started_at"),
                    "message_count": int(row.get("message_count") or 0),
                    "source": row.get("source"), "last_active": row.get("last_active"),
                    "cwd": row.get("cwd"), "archived": archived,
                    "is_active": (authority.profile_id, sid) in active_keys,
                }
                sessions.append(item)
                h = head_rows.get(sid)
                heads.append({
                    "session_id": sid,
                    "profile": authority.profile_name,
                    "profile_id": authority.profile_id,
                    "authority_epoch": authority.authority_epoch,
                    "max_message_id": int(h["max_message_id"]) if h and h["max_message_id"] is not None else None,
                    "message_count": int(h["message_count"]) if h else 0,
                    "last_message_at": float(h["last_message_at"]) if h and h["last_message_at"] is not None else None,
                })
        finally:
            db.close()
    return sessions, heads


def capture_runtime() -> tuple[list[dict], list[dict], set[tuple[str, str]], dict]:
    try:
        from tools.approval import pending_approval_snapshot
        from tui_gateway.server import (
            attention_session_identities,
            gateway_runtime_snapshot,
            pending_prompt_snapshot,
        )
    except Exception as exc:
        raise ManifestError(503, "state_unavailable", f"Gateway state unavailable: {exc}")
    runtime_snapshot = gateway_runtime_snapshot()
    copied_sessions = [
        (str(item["session_id"]), dict(item))
        for item in runtime_snapshot["sessions"]
    ]
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
        stored = rec.get("stored_session_id")
        profile = str(rec.get("profile_name") or "default")
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
        stored = item.get("stored_session_id") or rec.get("stored_session_id")
        profile = str(rec.get("profile_name") or "default")
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
    return attention, active, keys, {
        "runtime_instance_id": runtime_snapshot["runtime_instance_id"],
        "sequence": runtime_snapshot["sequence"],
        "captured_at": runtime_snapshot["captured_at"],
    }


def _key(item: dict) -> str:
    return f"session:{item['profile_id']}:{item['id']}"


def _filtered(
    homes: tuple[tuple[Any, Path], ...],
    visibility_check: Callable[[str, str], bool],
) -> tuple[list[dict], list[dict], list[dict], list[dict], dict[str, str], dict]:
    attention, active, name_keys, runtime_meta = capture_runtime()
    authority_by_name = {item.profile_name: item for item, _ in homes}
    active_keys = {
        (authority_by_name[name].profile_id, session_id)
        for name, session_id in name_keys
        if name in authority_by_name
    }
    sessions, heads = _session_rows(homes, active_keys)
    def eligible(s: dict) -> bool:
        return (
            not s["archived"]
            and int(s.get("message_count") or 0) >= 1
            and str(s.get("source") or "").lower() not in {"cron", "subagent", "tool"}
        )
    reasons = {
        _key(s): ("archived" if s["archived"] else "filtered")
        for s in sessions
    }
    sessions = [
        s for s in sessions
        if eligible(s) and visibility_check(s["profile"], s["id"])
    ]
    allowed = {(s["profile_id"], s["id"]) for s in sessions}

    def stamp_runtime(item: dict) -> dict | None:
        authority = authority_by_name.get(str(item.get("profile") or "default"))
        if authority is None:
            return None
        return dict(
            item,
            profile_id=authority.profile_id,
            authority_epoch=authority.authority_epoch,
        )

    attention = [stamped for item in attention if (stamped := stamp_runtime(item)) is not None]
    active = [stamped for item in active if (stamped := stamp_runtime(item)) is not None]

    def runtime_ok(x: dict) -> bool:
        stored = x.get("stored_session_id")
        return bool(
            stored
            and (x["profile_id"], stored) in allowed
            and visibility_check(x["profile"], stored)
        )
    attention = [x for x in attention if runtime_ok(x)]
    active = [x for x in active if runtime_ok(x)]
    heads = [
        h for h in heads
        if (h["profile_id"], h["session_id"]) in allowed
        and visibility_check(h["profile"], h["session_id"])
    ]
    return sessions, attention, active, heads, reasons, runtime_meta


def _authority_wire(context: Any) -> dict:
    return {
        "gateway_id": context.gateway_id,
        "profile_authorities": [
            {
                "profile_id": item.profile_id,
                "profile_name": item.profile_name,
                "authority_epoch": item.authority_epoch,
            }
            for item in context.profiles
        ],
    }


def _authority_digest(payload: dict) -> str:
    canonical = json.dumps(payload, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _page_size(value: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= MAX_PAGE_SIZE:
        raise ManifestError(400, "invalid_limit", f"Manifest limit must be 1...{MAX_PAGE_SIZE}")
    return value


def _new_cursor(conn: sqlite3.Connection, **values: Any) -> str:
    now = time.time()
    journal_epoch = _journal_epoch(conn)
    existing = conn.execute(
        "SELECT token FROM cursors WHERE scope=? AND visibility=? AND base_revision=? "
        "AND target_revision=? AND position=? AND is_full=? AND snapshot IS ? "
        "AND journal_epoch=? AND cursor_kind=? AND snapshot_id=? AND gateway_id=? "
        "AND authority_digest=? AND page_size=? AND expires_at>=? "
        "ORDER BY created_at LIMIT 1",
        (
            values["scope"], values["visibility"], values["base_revision"],
            values["target_revision"], values["position"], int(values["is_full"]),
            values.get("snapshot"), journal_epoch, values["cursor_kind"],
            values["snapshot_id"], values["gateway_id"], values["authority_digest"],
            values["page_size"], now,
        ),
    ).fetchone()
    if existing is not None:
        return str(existing["token"])
    token = f"m2.{journal_epoch}." + secrets.token_urlsafe(32)
    conn.execute(
        "INSERT INTO cursors(token,scope,visibility,base_revision,target_revision,position,is_full,snapshot,created_at,expires_at,journal_epoch,cursor_kind,snapshot_id,gateway_id,authority_digest,page_size) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            token, values["scope"], values["visibility"], values["base_revision"],
            values["target_revision"], values["position"], int(values["is_full"]),
            values.get("snapshot"), now, now + CURSOR_RETENTION_SECONDS,
            journal_epoch, values["cursor_kind"], values["snapshot_id"],
            values["gateway_id"], values["authority_digest"], values["page_size"],
        ),
    )
    return token


def _error_cursor(
    conn: sqlite3.Connection,
    token: str,
    *,
    scope: str,
    visibility: str,
    cursor_kind: str,
    gateway_id: str,
    authority_digest: str,
    page_size: int,
) -> sqlite3.Row:
    if len(token.encode("utf-8")) > 1024 or not token.startswith("m2.je_"):
        raise ManifestError(400, "invalid_cursor", "Invalid manifest cursor")
    row = conn.execute("SELECT * FROM cursors WHERE token=?", (token,)).fetchone()
    journal_epoch = _journal_epoch(conn)
    if row is None:
        token_parts = token.split(".", 2)
        if len(token_parts) == 3 and token_parts[1] != journal_epoch:
            raise ManifestError(410, "journal_rebuilt", "Manifest journal was rebuilt", reset=True)
        raise ManifestError(400, "invalid_cursor", "Invalid manifest cursor")
    if row["journal_epoch"] != journal_epoch:
        raise ManifestError(410, "journal_rebuilt", "Manifest journal was rebuilt", reset=True)
    if row["scope"] != scope or row["visibility"] != visibility:
        raise ManifestError(409, "cursor_scope_mismatch", "Manifest cursor belongs to another scope or owner")
    if row["cursor_kind"] != cursor_kind:
        raise ManifestError(400, "cursor_kind_mismatch", "Wrong manifest cursor kind")
    if row["gateway_id"] != gateway_id or row["authority_digest"] != authority_digest:
        raise ManifestError(409, "authority_changed", "Gateway authority changed")
    if int(row["page_size"] or 0) != page_size:
        raise ManifestError(409, "cursor_contract_mismatch", "Manifest page contract changed")
    current_revision = int(conn.execute("SELECT value FROM meta WHERE key='revision'").fetchone()[0])
    if row["expires_at"] < time.time() and current_revision - int(row["base_revision"]) >= MIN_REVISIONS_RETAINED:
        raise ManifestError(410, "cursor_expired", "Manifest cursor is no longer retained", reset=True)
    return row


def build_manifest(
    *,
    scope: str,
    resume_cursor: str | None,
    continuation_cursor: str | None,
    limit: int = DEFAULT_PAGE_SIZE,
    visibility: str,
    visibility_check: Callable[[str, str], bool],
    device_registered: bool,
    full_snapshot_reason: str | None = "full_snapshot",
) -> dict:
    scope = normalize_scope(scope)
    limit = _page_size(limit)
    if resume_cursor and continuation_cursor:
        raise ManifestError(400, "ambiguous_cursor", "Provide only one manifest cursor")
    context, homes = _resolve_authority_scope(scope)
    authority = _authority_wire(context)
    authority_digest = _authority_digest(authority)
    cursor = continuation_cursor or resume_cursor
    cursor_kind = "continuation" if continuation_cursor else "resume"

    with _lock, _connect() as conn:
        conn.execute("BEGIN IMMEDIATE")
        try:
            cursor_row = None
            if cursor:
                cursor_row = _error_cursor(
                    conn,
                    cursor,
                    scope=scope,
                    visibility=visibility,
                    cursor_kind=cursor_kind,
                    gateway_id=context.gateway_id,
                    authority_digest=authority_digest,
                    page_size=limit,
                )
            if continuation_cursor:
                if cursor_row is None or cursor_row["snapshot"] is None:
                    raise ManifestError(400, "invalid_cursor", "Continuation snapshot is unavailable")
                frozen = json.loads(cursor_row["snapshot"])
                return _page(
                    conn,
                    frozen,
                    int(cursor_row["position"]),
                    scope,
                    visibility,
                    int(cursor_row["base_revision"]),
                    bool(cursor_row["is_full"]),
                )

            sessions, attention, active, heads, absence_reasons, runtime_meta = _filtered(
                homes, visibility_check
            )
            now = time.time()
            old_rows = {
                row["entity_key"]: row
                for row in conn.execute(
                    "SELECT * FROM snapshots WHERE scope=? AND visibility=?",
                    (scope, visibility),
                )
            }
            current = {_key(session): session for session in sessions}
            changed: list[tuple[str, str, dict]] = []
            for key, item in current.items():
                payload = json.dumps(item, sort_keys=True, separators=(",", ":"))
                if key not in old_rows or old_rows[key]["payload"] != payload:
                    changed.append((key, "upsert", item))
            for key, row in old_rows.items():
                if key not in current:
                    old = json.loads(row["payload"])
                    changed.append(
                        (
                            key,
                            "tombstone",
                            {
                                "session_id": old["id"],
                                "profile": old["profile"],
                                "profile_id": old["profile_id"],
                                "authority_epoch": old["authority_epoch"],
                                "deleted_at": now,
                                "reason": absence_reasons.get(key, "deleted"),
                            },
                        )
                    )
            aux_payload = json.dumps(
                {
                    "attention": attention,
                    "heads": heads,
                    "device_registered": bool(device_registered),
                },
                sort_keys=True,
                separators=(",", ":"),
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
                    revisioned = dict(item, entity_revision=revision)
                    conn.execute(
                        "INSERT OR REPLACE INTO changes VALUES(?,?,?,?,?,?,?)",
                        (
                            scope, visibility, revision, key, kind,
                            json.dumps(revisioned, separators=(",", ":")), now,
                        ),
                    )
                conn.execute("DELETE FROM snapshots WHERE scope=? AND visibility=?", (scope, visibility))
                conn.executemany(
                    "INSERT INTO snapshots VALUES(?,?,?,?,?)",
                    [
                        (
                            scope,
                            visibility,
                            key,
                            json.dumps(value, sort_keys=True, separators=(",", ":")),
                            revision,
                        )
                        for key, value in current.items()
                    ],
                )
            if aux_changed:
                conn.execute(
                    "INSERT OR REPLACE INTO state_snapshots VALUES(?,?,?,?)",
                    (scope, visibility, aux_payload, revision),
                )
                conn.execute("INSERT INTO dirty_reasons VALUES(?,?,?)", (revision, "coalesced", now))

            if cursor_row:
                logical = [
                    (row["kind"], json.loads(row["payload"]))
                    for row in conn.execute(
                        "SELECT kind,payload FROM changes "
                        "WHERE scope=? AND visibility=? AND revision>? AND revision<=? "
                        "ORDER BY revision,entity_key",
                        (scope, visibility, base, revision),
                    )
                ]
                is_full = False
            else:
                logical = [
                    ("upsert", dict(item, entity_revision=revision))
                    for item in sessions
                ]
                is_full = True

            response_heads = heads
            if not is_full:
                prior_aux = json.loads(old_aux["payload"]) if old_aux is not None else {}
                prior_heads = {
                    (head["profile_id"], head["session_id"]): head
                    for head in prior_aux.get("heads", [])
                }
                needed = {
                    (item["profile_id"], item["stored_session_id"])
                    for item in attention + active
                    if item.get("stored_session_id")
                }
                needed.update(
                    (payload["profile_id"], payload["id"])
                    for kind, payload in logical
                    if kind == "upsert"
                )
                response_heads = [
                    head
                    for head in heads
                    if (head["profile_id"], head["session_id"]) in needed
                    or prior_heads.get((head["profile_id"], head["session_id"])) != head
                ]
            snapshot_id = "ms_" + secrets.token_urlsafe(16)
            frozen = {
                "schema_version": SCHEMA_VERSION,
                "authority": authority,
                "authority_digest": authority_digest,
                "journal_epoch": _journal_epoch(conn),
                "server_time": now,
                "revision": revision,
                "snapshot_id": snapshot_id,
                "page_size": limit,
                "items": logical,
                "attention": [dict(item, entity_revision=int(item.get("revision") or 0)) for item in attention],
                "runtime": dict(runtime_meta, active_turns=active),
                "heads": [dict(head, entity_revision=revision) for head in response_heads],
                "widget": {
                    "open_session_count": len(sessions),
                    "active_turn_count": len(active),
                    "pending_attention_count": sum(
                        item["status"] in ("pending", "failed_retry") for item in attention
                    ),
                    "tokens_today": None,
                    "estimated_cost_today": None,
                },
                "push": {"device_registered": bool(device_registered)},
                "reset": bool(is_full and full_snapshot_reason),
                "reset_reason": full_snapshot_reason if is_full else None,
            }
            return _page(conn, frozen, 0, scope, visibility, base, is_full)
        except Exception:
            conn.execute("ROLLBACK")
            raise


def _page(
    conn: sqlite3.Connection,
    frozen: dict,
    position: int,
    scope: str,
    visibility: str,
    base: int,
    is_full: bool,
) -> dict:
    items = frozen["items"]
    page_size = int(frozen["page_size"])
    chunk = items[position:position + page_size]
    end = position + len(chunk)
    complete = end >= len(items)
    serialized = json.dumps(frozen, separators=(",", ":"))
    cursor_kind = "resume" if complete else "continuation"
    next_cursor = _new_cursor(
        conn,
        scope=scope,
        visibility=visibility,
        base_revision=base,
        target_revision=frozen["revision"],
        position=0 if complete else end,
        is_full=is_full,
        snapshot=None if complete else serialized,
        cursor_kind=cursor_kind,
        snapshot_id=frozen["snapshot_id"],
        gateway_id=frozen["authority"]["gateway_id"],
        authority_digest=frozen["authority_digest"],
        page_size=page_size,
    )
    result = {
        "schema_version": frozen["schema_version"],
        **frozen["authority"],
        "journal_epoch": frozen["journal_epoch"],
        "complete": complete,
        "revision": frozen["revision"],
        "snapshot_id": frozen["snapshot_id"],
        "page_size": page_size,
        "scope": scope,
        "continuation_cursor": None if complete else next_cursor,
        "resume_cursor": next_cursor if complete else None,
        "reset": frozen["reset"],
        "reset_reason": frozen["reset_reason"],
        "server_time": frozen["server_time"],
        "sessions": {
            "upserts": [value for kind, value in chunk if kind == "upsert"],
            "tombstones": [value for kind, value in chunk if kind == "tombstone"],
        },
    }
    if complete:
        result.update(
            pending_attention=frozen["attention"],
            runtime_snapshot=frozen["runtime"],
            transcript_heads=frozen["heads"],
            widget_summary=frozen["widget"],
            push_registry=frozen["push"],
        )
    conn.execute("COMMIT")
    return result


def device_is_registered(device_id: str | None, registry_entries: Iterable[dict]) -> bool:
    return bool(device_id) and any(entry.get("device_id") == device_id for entry in registry_entries)
