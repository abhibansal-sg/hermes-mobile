"""Durable ``prompt.submit`` idempotency receipts for hermes-mobile.

The gateway core exposes only a structural provider seam.  This module owns
the SQLite schema, profile-home placement, process-liveness interpretation,
and the frozen 30-day retention policy required by the mobile outbox protocol.
"""

from __future__ import annotations

import hashlib
import json
import os
import sqlite3
import time
import uuid
from pathlib import Path
from typing import Any, Callable

RETENTION_SECONDS = 30 * 24 * 60 * 60
_DB_RELATIVE_PATH = Path("plugins") / "hermes-mobile" / "prompt_receipts.sqlite3"


class SQLitePromptReceiptProvider:
    """Atomic, process-aware prompt receipt registry.

    A reservation owned by this provider instance is live.  The same durable
    row observed by a new provider instance (the gateway restarted after the
    claim but before recording a disposition) is permanently marked
    ``indeterminate`` and is never automatically re-executed.
    """

    provider_name = "hermes-mobile.sqlite-prompt-receipts"

    def __init__(
        self,
        *,
        owner_id: str | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.owner_id = owner_id or uuid.uuid4().hex
        self._clock = clock

    @staticmethod
    def database_path(profile_home: str | os.PathLike[str]) -> Path:
        return Path(profile_home) / _DB_RELATIVE_PATH

    @staticmethod
    def _fingerprint(
        *,
        session_id: Any,
        text: Any,
        truncate_before_user_ordinal: int | None,
        asset_references: list[dict[str, Any]] | None = None,
    ) -> str:
        encoded = json.dumps(
            {
                "session_id": session_id,
                "text": text,
                "truncate_before_user_ordinal": truncate_before_user_ordinal,
                "asset_references": asset_references or [],
            },
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    def _connect(self, profile_home: str | os.PathLike[str]) -> sqlite3.Connection:
        path = self.database_path(profile_home)
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(str(path), timeout=30.0, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 30000")
        conn.execute("PRAGMA journal_mode = WAL")
        conn.execute("PRAGMA synchronous = FULL")
        conn.execute("PRAGMA foreign_keys = ON")
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS prompt_receipts (
                client_message_id TEXT PRIMARY KEY,
                request_fingerprint TEXT NOT NULL,
                state TEXT NOT NULL,
                owner_id TEXT,
                disposition_json TEXT,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """
        )
        conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS stable_assets (
                asset_id TEXT PRIMARY KEY,
                content_version TEXT NOT NULL,
                path TEXT NOT NULL UNIQUE,
                media_type TEXT NOT NULL,
                byte_count INTEGER NOT NULL,
                owner_device_id TEXT,
                thumbnail_path TEXT,
                server_state TEXT NOT NULL DEFAULT 'available',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS stable_asset_associations (
                operation_id TEXT NOT NULL,
                asset_id TEXT NOT NULL REFERENCES stable_assets(asset_id),
                content_version TEXT NOT NULL,
                session_id TEXT NOT NULL,
                turn_id TEXT NOT NULL,
                role TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (operation_id, asset_id, role)
            );
            CREATE INDEX IF NOT EXISTS idx_stable_asset_assoc_session
            ON stable_asset_associations(session_id, asset_id);
            CREATE TABLE IF NOT EXISTS stable_asset_pending_refs (
                operation_id TEXT NOT NULL
                    REFERENCES prompt_receipts(client_message_id) ON DELETE CASCADE,
                asset_id TEXT NOT NULL REFERENCES stable_assets(asset_id),
                content_version TEXT NOT NULL,
                role TEXT NOT NULL,
                ordinal INTEGER NOT NULL,
                created_at REAL NOT NULL,
                PRIMARY KEY (operation_id, asset_id, role)
            );
            """
        )
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return conn

    @staticmethod
    def _reservation(
        *,
        profile_home: Path,
        path: Path,
        client_message_id: str,
        fingerprint: str,
        owner_id: str,
        session_id: Any,
    ) -> dict[str, Any]:
        return {
            "profile_home": str(profile_home),
            "path": str(path),
            "client_message_id": client_message_id,
            "fingerprint": fingerprint,
            "owner_id": owner_id,
            "session_id": str(session_id or ""),
        }

    def reserve(
        self,
        *,
        profile_home: str | os.PathLike[str],
        client_message_id: str,
        session_id: Any,
        text: Any,
        truncate_before_user_ordinal: int | None,
        asset_references: list[dict[str, Any]] | None = None,
    ) -> dict[str, Any]:
        normalized_assets = self._normalize_asset_references(asset_references)
        profile_home = Path(profile_home)
        fingerprint = self._fingerprint(
            session_id=session_id,
            text=text,
            truncate_before_user_ordinal=truncate_before_user_ordinal,
            asset_references=normalized_assets,
        )
        path = self.database_path(profile_home)
        now = float(self._clock())
        conn = self._connect(profile_home)
        try:
            conn.execute("BEGIN IMMEDIATE")
            # Strictly older than 30 days: a receipt at the boundary is still
            # retained, matching the protocol's minimum retention guarantee.
            conn.execute(
                "DELETE FROM prompt_receipts "
                "WHERE state = 'accepted' AND created_at < ?",
                (now - RETENTION_SECONDS,),
            )
            row = conn.execute(
                "SELECT * FROM prompt_receipts WHERE client_message_id = ?",
                (client_message_id,),
            ).fetchone()
            if row is None:
                conn.execute(
                    """
                    INSERT INTO prompt_receipts (
                        client_message_id, request_fingerprint, state, owner_id,
                        disposition_json, created_at, updated_at
                    ) VALUES (?, ?, 'reserved', ?, NULL, ?, ?)
                    """,
                    (client_message_id, fingerprint, self.owner_id, now, now),
                )
                for ordinal, asset in enumerate(normalized_assets):
                    asset_row = conn.execute(
                        "SELECT content_version, server_state FROM stable_assets "
                        "WHERE asset_id = ?",
                        (asset["asset_id"],),
                    ).fetchone()
                    if (
                        asset_row is None
                        or asset_row["server_state"] != "available"
                        or asset_row["content_version"] != asset["content_version"]
                    ):
                        raise ValueError("prompt asset reference is unavailable")
                    conn.execute(
                        "INSERT INTO stable_asset_pending_refs "
                        "(operation_id, asset_id, content_version, role, ordinal, "
                        " created_at) VALUES (?, ?, ?, ?, ?, ?)",
                        (
                            client_message_id,
                            asset["asset_id"],
                            asset["content_version"],
                            asset["role"],
                            ordinal,
                            now,
                        ),
                    )
                conn.commit()
                return {
                    "state": "claimed",
                    "reservation": self._reservation(
                        profile_home=profile_home,
                        path=path,
                        client_message_id=client_message_id,
                        fingerprint=fingerprint,
                        owner_id=self.owner_id,
                        session_id=session_id,
                    ) | {"asset_references": normalized_assets},
                }

            if row["request_fingerprint"] != fingerprint:
                conn.commit()
                return {"state": "conflict"}

            if row["state"] == "accepted" and row["disposition_json"]:
                try:
                    disposition = json.loads(row["disposition_json"])
                except (TypeError, ValueError, json.JSONDecodeError):
                    disposition = None
                if isinstance(disposition, dict):
                    conn.commit()
                    return {"state": "replay", "disposition": disposition}

            if row["state"] == "reserved" and row["owner_id"] == self.owner_id:
                conn.commit()
                return {"state": "in_progress"}

            if row["state"] != "indeterminate":
                conn.execute(
                    """
                    UPDATE prompt_receipts
                       SET state = 'indeterminate', owner_id = NULL, updated_at = ?
                     WHERE client_message_id = ?
                    """,
                    (now, client_message_id),
                )
            conn.commit()
            return {"state": "indeterminate"}
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()

    def complete(self, reservation: dict[str, str], disposition: dict) -> None:
        payload = json.dumps(
            disposition,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
        now = float(self._clock())
        conn = self._connect(reservation["profile_home"])
        try:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                """
                UPDATE prompt_receipts
                   SET state = 'accepted', disposition_json = ?, updated_at = ?
                 WHERE client_message_id = ?
                   AND request_fingerprint = ?
                   AND state = 'reserved'
                   AND owner_id = ?
                """,
                (
                    payload,
                    now,
                    reservation["client_message_id"],
                    reservation["fingerprint"],
                    reservation["owner_id"],
                ),
            )
            if cursor.rowcount != 1:
                raise RuntimeError("prompt receipt reservation is no longer owned")
            turn_id = str(disposition.get("turn_id") or "").strip()
            session_id = str(disposition.get("stored_session_id") or "").strip()
            if not session_id:
                session_id = str(disposition.get("session_id") or "").strip()
            if not session_id:
                # The reservation session is the runtime ID on the TUI path;
                # preserving it is still safer than creating an unscoped ref.
                session_id = str(reservation.get("session_id") or "").strip()
            if reservation.get("asset_references") and (not turn_id or not session_id):
                raise RuntimeError("accepted prompt asset identity is incomplete")
            for ordinal, asset in enumerate(reservation.get("asset_references") or []):
                row = conn.execute(
                    "SELECT content_version, server_state FROM stable_assets "
                    "WHERE asset_id = ?",
                    (asset["asset_id"],),
                ).fetchone()
                if (
                    row is None
                    or row["server_state"] != "available"
                    or row["content_version"] != asset["content_version"]
                ):
                    raise RuntimeError("prompt asset reference is unavailable")
                conn.execute(
                    "INSERT INTO stable_asset_associations "
                    "(operation_id, asset_id, content_version, session_id, turn_id, "
                    " role, ordinal, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                    "ON CONFLICT(operation_id, asset_id, role) DO NOTHING",
                    (
                        reservation["client_message_id"],
                        asset["asset_id"],
                        asset["content_version"],
                        session_id,
                        turn_id,
                        asset["role"],
                        ordinal,
                        now,
                    ),
                )
            conn.execute(
                "DELETE FROM stable_asset_pending_refs WHERE operation_id = ?",
                (reservation["client_message_id"],),
            )
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()

    @staticmethod
    def _normalize_asset_references(
        references: list[dict[str, Any]] | None,
    ) -> list[dict[str, str]]:
        if references is None:
            return []
        if not isinstance(references, list) or len(references) > 20:
            raise ValueError("asset_references must be a bounded list")
        normalized: list[dict[str, str]] = []
        for item in references:
            if not isinstance(item, dict):
                raise ValueError("asset reference must be an object")
            asset_id = str(item.get("asset_id") or "").strip()
            version = str(item.get("content_version") or "").strip()
            role = str(item.get("role") or "input").strip()
            if not asset_id.startswith("asset_") or not version or role != "input":
                raise ValueError("invalid asset reference")
            normalized.append(
                {
                    "asset_id": asset_id[:128],
                    "content_version": version[:160],
                    "role": role,
                }
            )
        return normalized

    def register_asset(
        self,
        *,
        profile_home: str | os.PathLike[str],
        asset_id: str,
        content_version: str,
        path: str,
        media_type: str,
        byte_count: int,
        owner_device_id: str | None,
    ) -> None:
        now = float(self._clock())
        conn = self._connect(profile_home)
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                "INSERT INTO stable_assets "
                "(asset_id, content_version, path, media_type, byte_count, "
                " owner_device_id, created_at, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    asset_id,
                    content_version,
                    path,
                    media_type,
                    int(byte_count),
                    owner_device_id,
                    now,
                    now,
                ),
            )
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()

    def asset(
        self, *, profile_home: str | os.PathLike[str], asset_id: str
    ) -> dict[str, Any] | None:
        conn = self._connect(profile_home)
        try:
            row = conn.execute(
                "SELECT * FROM stable_assets WHERE asset_id = ?", (asset_id,)
            ).fetchone()
            return dict(row) if row is not None else None
        finally:
            conn.close()

    def asset_sessions(
        self, *, profile_home: str | os.PathLike[str], asset_id: str
    ) -> list[str]:
        conn = self._connect(profile_home)
        try:
            return [
                str(row[0])
                for row in conn.execute(
                    "SELECT DISTINCT session_id FROM stable_asset_associations "
                    "WHERE asset_id = ?",
                    (asset_id,),
                ).fetchall()
            ]
        finally:
            conn.close()

    def set_asset_thumbnail(
        self,
        *,
        profile_home: str | os.PathLike[str],
        asset_id: str,
        thumbnail_path: str,
    ) -> None:
        conn = self._connect(profile_home)
        try:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                "UPDATE stable_assets SET thumbnail_path = ?, updated_at = ? "
                "WHERE asset_id = ? AND server_state = 'available'",
                (thumbnail_path, float(self._clock()), asset_id),
            )
            if cursor.rowcount != 1:
                raise ValueError("asset unavailable")
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()

    def is_referenced_path(
        self, *, profile_home: str | os.PathLike[str], path: str
    ) -> bool:
        conn = self._connect(profile_home)
        try:
            return conn.execute(
                "SELECT 1 FROM stable_assets a WHERE a.path = ? AND ("
                "EXISTS (SELECT 1 FROM stable_asset_associations x "
                "        WHERE x.asset_id = a.asset_id) OR "
                "EXISTS (SELECT 1 FROM stable_asset_pending_refs p "
                "        WHERE p.asset_id = a.asset_id)) LIMIT 1",
                (path,),
            ).fetchone() is not None
        finally:
            conn.close()

    def mark_unreferenced_asset_deleted(
        self, *, profile_home: str | os.PathLike[str], path: str
    ) -> bool:
        """Tombstone one byte object only when no accepted reference exists."""
        conn = self._connect(profile_home)
        try:
            conn.execute("BEGIN IMMEDIATE")
            cursor = conn.execute(
                "UPDATE stable_assets SET server_state = 'deleted', updated_at = ? "
                "WHERE path = ? AND server_state = 'available' AND NOT EXISTS ("
                "  SELECT 1 FROM stable_asset_associations x "
                "  WHERE x.asset_id = stable_assets.asset_id"
                ") AND NOT EXISTS ("
                "  SELECT 1 FROM stable_asset_pending_refs p "
                "  WHERE p.asset_id = stable_assets.asset_id"
                ")",
                (float(self._clock()), path),
            )
            conn.commit()
            return cursor.rowcount == 1
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()

    def release(self, reservation: dict[str, str]) -> None:
        """Delete an unaccepted reservation after a mutation-free rejection."""
        conn = self._connect(reservation["profile_home"])
        try:
            conn.execute("BEGIN IMMEDIATE")
            conn.execute(
                """
                DELETE FROM prompt_receipts
                 WHERE client_message_id = ?
                   AND request_fingerprint = ?
                   AND state = 'reserved'
                   AND owner_id = ?
                """,
                (
                    reservation["client_message_id"],
                    reservation["fingerprint"],
                    reservation["owner_id"],
                ),
            )
            conn.commit()
        except Exception:
            if conn.in_transaction:
                conn.rollback()
            raise
        finally:
            conn.close()


PROVIDER = SQLitePromptReceiptProvider()
