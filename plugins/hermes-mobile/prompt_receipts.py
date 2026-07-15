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
    ) -> str:
        encoded = json.dumps(
            {
                "session_id": session_id,
                "text": text,
                "truncate_before_user_ordinal": truncate_before_user_ordinal,
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
    ) -> dict[str, str]:
        return {
            "profile_home": str(profile_home),
            "path": str(path),
            "client_message_id": client_message_id,
            "fingerprint": fingerprint,
            "owner_id": owner_id,
        }

    def reserve(
        self,
        *,
        profile_home: str | os.PathLike[str],
        client_message_id: str,
        session_id: Any,
        text: Any,
        truncate_before_user_ordinal: int | None,
    ) -> dict[str, Any]:
        profile_home = Path(profile_home)
        fingerprint = self._fingerprint(
            session_id=session_id,
            text=text,
            truncate_before_user_ordinal=truncate_before_user_ordinal,
        )
        path = self.database_path(profile_home)
        now = float(self._clock())
        conn = self._connect(profile_home)
        try:
            conn.execute("BEGIN IMMEDIATE")
            # Strictly older than 30 days: a receipt at the boundary is still
            # retained, matching the protocol's minimum retention guarantee.
            conn.execute(
                "DELETE FROM prompt_receipts WHERE created_at < ?",
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
                conn.commit()
                return {
                    "state": "claimed",
                    "reservation": self._reservation(
                        profile_home=profile_home,
                        path=path,
                        client_message_id=client_message_id,
                        fingerprint=fingerprint,
                        owner_id=self.owner_id,
                    ),
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
            conn.commit()
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
