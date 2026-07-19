"""Crash-consistent local authority for the HRP/2 Agent Relay.

The Relay Hub is deliberately content blind.  Consequently all authority for
device enrollment, streams, replay protection, idempotent operations and the
session projection lives in this profile-scoped SQLite database.  Each method
which crosses an application invariant uses ``BEGIN IMMEDIATE`` so a process
crash can leave either the old state or the new state, never a half-applied
stream/message transition.
"""

from __future__ import annotations

import contextlib
import getpass
import hashlib
import json
import logging
import os
import secrets
import sqlite3
import stat
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping, Sequence

from .protection import CredentialProtectionError
from .protocol import MAX_WIRE_INTEGER, b64url_decode, b64url_encode, canonical_json


_log = logging.getLogger(__name__)

SCHEMA_VERSION = 16
DEFAULT_MAILBOX_TTL_MS = 24 * 60 * 60 * 1000
PRESENCE_LEASE_MS = 90 * 1_000


class StorageError(RuntimeError):
    """Base class for local state invariant failures."""


class StorageNotFound(StorageError):
    pass


class StorageConflict(StorageError):
    pass


class StorageExpired(StorageError):
    pass


class StreamGap(StorageConflict):
    def __init__(self, expected: int, received: int) -> None:
        self.expected = expected
        self.received = received
        super().__init__(f"stream gap: expected {expected}, received {received}")


@dataclass(frozen=True)
class RelayIdentityRecord:
    relay_instance_id: str
    relay_epoch: str
    kem_generation: int
    kem_private: bytes
    kem_public: bytes
    sign_private: bytes
    sign_public: bytes
    created_at_ms: int


@dataclass(frozen=True)
class RelayKEMKeyRecord:
    generation: int
    private_key: bytes
    public_key: bytes
    status: str
    not_after_ms: int | None
    created_at_ms: int
    message_count: int
    retirement_started_at_ms: int | None = None


@dataclass(frozen=True)
class PairOfferRecord:
    offer_id: str
    offer_route: str
    relay_route: str
    pair_secret: bytes
    transport_token: str
    expires_at_ms: int
    state: str
    device_key_hash: bytes | None
    device_id: str | None
    auto_approve: bool
    hub_message_hash: str | None = None
    hub_response_hash: str | None = None
    accept_enc: bytes | None = None
    accept_ct: bytes | None = None
    accept_mid: str | None = None
    hub_registered: bool = False


@dataclass(frozen=True)
class DeviceRecord:
    device_id: str
    name: str
    route: str
    status: str
    kem_generation: int
    kem_public: bytes
    sign_public: bytes
    preview_generation: int
    preview_public: bytes
    relay_kem_generation: int
    created_at_ms: int
    confirmed_at_ms: int | None
    revoked_at_ms: int | None
    re_pair_required: bool = False
    status_reason: str | None = None
    hub_revocation_state: str = "not_required"
    hub_revocation_attempts: int = 0
    hub_revocation_last_error: str | None = None


@dataclass(frozen=True)
class HubRevocationRecord:
    device_id: str
    route_id: str
    grant_ids: tuple[str, ...]
    attempts: int


@dataclass(frozen=True)
class PushBindingRevocationRecord:
    device_id: str
    binding_id: str
    attempts: int


@dataclass(frozen=True)
class StreamRecord:
    device_id: str
    stream_id: str
    next_seq: int
    acked_through: int
    received_through: int
    checkpoint_revision: int


@dataclass(frozen=True)
class OutboxRecord:
    device_id: str
    message_id: str
    first_seq: int
    last_seq: int
    message_class: str
    envelope: dict[str, Any]
    state: str
    created_at_ms: int
    expires_at_ms: int
    attempts: int
    receipt_kind: str = "stream"
    completion_policy: str = "stream_ack"
    activates_relay_kem_generation: int | None = None


@dataclass(frozen=True)
class OperationRecord:
    device_id: str
    op_id: str
    request_hash: bytes
    method: str
    state: str
    response: dict[str, Any] | None
    error_code: str | None
    created_at_ms: int
    updated_at_ms: int


@dataclass(frozen=True)
class AgentEnrollmentRecord:
    enrollment_id: str
    auth_public_key: bytes
    state: str
    route_id: str | None
    expires_at_ms: int | None


@dataclass(frozen=True)
class PushBindingExchangeRecord:
    device_id: str
    exchange_id: str
    bind_token: str
    requested_classes: tuple[str, ...]
    state: str
    binding_id: str | None
    remote_revoke_state: str
    revoke_attempts: int
    last_error_code: str | None


@dataclass(frozen=True)
class NotificationOutboxRecord:
    device_id: str
    notification_id: str
    binding_id: str
    session_id: str | None
    dedupe_hash: bytes
    notification_class: str
    collapse_id: str | None
    descriptor: dict[str, Any]
    state: str
    attempts: int
    last_error_code: str | None
    created_at_ms: int
    updated_at_ms: int
    next_attempt_at_ms: int
    expires_at_ms: int


@dataclass(frozen=True)
class InboundDeliveryReceiptRecord:
    device_id: str
    inbound_message_id: str
    outbound_message_id: str
    state: str
    created_at_ms: int
    updated_at_ms: int
    expires_at_ms: int


def now_ms() -> int:
    return time.time_ns() // 1_000_000


def random_id(prefix: str) -> str:
    return f"{prefix}_{secrets.token_urlsafe(16)}"


def _int64(
    value: Any,
    *,
    field: str,
    minimum: int = 0,
    maximum: int = MAX_WIRE_INTEGER,
) -> int:
    """Validate an integer before it crosses SQLite's signed boundary."""

    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not minimum <= value <= maximum
    ):
        raise StorageConflict(f"{field} is outside the exact JSON integer range")
    return value


def resolve_state_directory(
    hermes_home: str | os.PathLike[str] | None = None,
) -> Path:
    """Return ``$HERMES_HOME/mobile-relay`` without hard-coding one profile.

    ``HERMES_HOME`` is intentionally read at call time so profile-switching
    launchers can set it before constructing the relay.  The fallback mirrors
    Hermes' default profile only when no explicit profile is configured.
    """

    if hermes_home is None:
        configured = os.environ.get("HERMES_HOME", "").strip()
        base = Path(configured).expanduser() if configured else Path.home() / ".hermes"
    else:
        base = Path(hermes_home).expanduser()
    return base / "mobile-relay"


def canonical_request_hash(method: str, params: Mapping[str, Any]) -> bytes:
    payload = canonical_json({"method": method, "params": dict(params)})
    return hashlib.sha256(payload).digest()


class RelayStorage:
    """One profile's durable HRP/2 state.

    A storage object owns one SQLite connection.  The lock protects callers
    using independent per-device asyncio workers via ``asyncio.to_thread`` as
    well as ordinary single-loop callers.
    """

    def __init__(
        self,
        state_directory: str | os.PathLike[str] | None = None,
        *,
        hermes_home: str | os.PathLike[str] | None = None,
        clock: Callable[[], int] = now_ms,
        credential_protector: Any = None,
    ) -> None:
        if state_directory is not None and hermes_home is not None:
            raise ValueError("pass state_directory or hermes_home, not both")
        self.directory = (
            Path(state_directory).expanduser()
            if state_directory is not None
            else resolve_state_directory(hermes_home)
        )
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._secure_path(self.directory, 0o700, is_directory=True)
        self.path = self.directory / "relay.sqlite3"
        self._clock = clock
        self.credential_protector = credential_protector
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(
            str(self.path),
            timeout=30.0,
            isolation_level=None,
            check_same_thread=False,
        )
        self._conn.row_factory = sqlite3.Row
        self._configure()
        self._migrate()
        self._harden_state_files()
        # A side effect may have reached the gateway immediately before the
        # previous process died.  Such rows are never blindly retried.
        with self.transaction() as conn:
            conn.execute(
                "UPDATE operations SET state='ambiguous', updated_at_ms=? "
                "WHERE state='executing'",
                (self._clock(),),
            )
            conn.execute(
                """UPDATE approval_capabilities SET state='failed_retryable',updated_at_ms=?
                   WHERE state='claimed'""",
                (self._clock(),),
            )

    @classmethod
    def _secure_path(cls, path: Path, mode: int, *, is_directory: bool) -> None:
        """Apply and verify minimum authority permissions, failing closed."""

        if os.name == "posix":
            os.chmod(path, mode)
            actual = stat.S_IMODE(path.stat().st_mode)
            if actual != mode:
                raise PermissionError(
                    f"mobile relay state permission mismatch for {path}: {oct(actual)}"
                )
            return
        if os.name == "nt":
            cls._secure_windows_acl(path, is_directory=is_directory)

    @staticmethod
    def _secure_windows_acl(path: Path, *, is_directory: bool) -> None:
        principal = getpass.getuser()
        user_grant = f"{principal}:(OI)(CI)F" if is_directory else f"{principal}:F"
        system_grant = "SYSTEM:(OI)(CI)F" if is_directory else "SYSTEM:F"
        result = subprocess.run(
            [
                "icacls",
                str(path),
                "/inheritance:r",
                "/grant:r",
                user_grant,
                system_grant,
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if result.returncode != 0:
            raise PermissionError(f"failed to restrict mobile relay ACL for {path}")

    def _harden_state_files(self) -> None:
        self._secure_path(self.directory, 0o700, is_directory=True)
        for path in (
            self.path,
            Path(str(self.path) + "-wal"),
            Path(str(self.path) + "-shm"),
        ):
            if path.exists():
                self._secure_path(path, 0o600, is_directory=False)

    def _configure(self) -> None:
        self._conn.execute("PRAGMA busy_timeout=30000")
        self._conn.execute("PRAGMA journal_mode=WAL")
        self._conn.execute("PRAGMA synchronous=FULL")
        self._conn.execute("PRAGMA foreign_keys=ON")
        self._conn.execute("PRAGMA secure_delete=ON")

    def _migrate(self) -> None:
        with self._lock:
            self._conn.executescript(
                """
                CREATE TABLE IF NOT EXISTS meta (
                    key TEXT PRIMARY KEY,
                    value BLOB NOT NULL
                );

                CREATE TABLE IF NOT EXISTS relay_identity (
                    singleton INTEGER PRIMARY KEY CHECK (singleton=1),
                    relay_instance_id TEXT NOT NULL UNIQUE,
                    relay_epoch TEXT NOT NULL,
                    kem_generation INTEGER NOT NULL CHECK (kem_generation > 0),
                    kem_private BLOB NOT NULL,
                    kem_public BLOB NOT NULL,
                    sign_private BLOB NOT NULL,
                    sign_public BLOB NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS relay_kem_keys (
                    generation INTEGER PRIMARY KEY CHECK (generation > 0),
                    private_key BLOB NOT NULL,
                    public_key BLOB NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('current','previous','revoked')),
                    not_after_ms INTEGER,
                    created_at_ms INTEGER NOT NULL,
                    message_count INTEGER NOT NULL DEFAULT 0,
                    retirement_started_at_ms INTEGER
                );

                CREATE TABLE IF NOT EXISTS devices (
                    device_id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    route TEXT NOT NULL UNIQUE,
                    status TEXT NOT NULL CHECK (status IN ('pending','active','revoked')),
                    kem_generation INTEGER NOT NULL CHECK (kem_generation > 0),
                    kem_public BLOB NOT NULL,
                    sign_public BLOB NOT NULL,
                    preview_generation INTEGER NOT NULL CHECK (preview_generation > 0),
                    preview_public BLOB NOT NULL,
                    relay_kem_generation INTEGER NOT NULL DEFAULT 1
                        CHECK (relay_kem_generation > 0),
                    created_at_ms INTEGER NOT NULL,
                    confirmed_at_ms INTEGER,
                    revoked_at_ms INTEGER,
                    re_pair_required INTEGER NOT NULL DEFAULT 0
                        CHECK (re_pair_required IN (0,1)),
                    status_reason TEXT,
                    hub_revocation_state TEXT NOT NULL DEFAULT 'not_required'
                        CHECK (hub_revocation_state IN
                            ('not_required','pending','confirmed')),
                    hub_revocation_attempts INTEGER NOT NULL DEFAULT 0,
                    hub_revocation_last_error TEXT
                );

                CREATE TABLE IF NOT EXISTS device_keys (
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    purpose TEXT NOT NULL CHECK (purpose IN ('kem','sign','preview')),
                    generation INTEGER NOT NULL CHECK (generation > 0),
                    public_key BLOB NOT NULL,
                    status TEXT NOT NULL CHECK (status IN ('current','previous','revoked')),
                    not_after_ms INTEGER,
                    created_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (device_id,purpose,generation)
                );

                CREATE TABLE IF NOT EXISTS pair_offers (
                    offer_id TEXT PRIMARY KEY,
                    offer_route TEXT NOT NULL UNIQUE,
                    relay_route TEXT NOT NULL,
                    pair_secret BLOB NOT NULL,
                    transport_token TEXT NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK (state IN
                        ('pending','claimed','confirmed','consumed','expired','cancelled')),
                    device_key_hash BLOB,
                    device_id TEXT,
                    hub_message_hash TEXT,
                    hub_response_hash TEXT,
                    accept_enc BLOB,
                    accept_ct BLOB,
                    accept_mid TEXT,
                    accept_owner TEXT,
                    accept_lease_expires_at_ms INTEGER,
                    hub_registered INTEGER NOT NULL DEFAULT 0,
                    auto_approve INTEGER NOT NULL DEFAULT 0,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS hub_routes (
                    route_id TEXT PRIMARY KEY,
                    kind TEXT NOT NULL,
                    status TEXT NOT NULL,
                    credential BLOB,
                    expires_at_ms INTEGER,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS agent_enrollments (
                    enrollment_id TEXT PRIMARY KEY,
                    route_type TEXT NOT NULL CHECK (route_type='agent'),
                    auth_public_key BLOB NOT NULL,
                    state TEXT NOT NULL CHECK (state IN
                        ('requested','provisional','active','expired','revoked')),
                    route_id TEXT UNIQUE,
                    expires_at_ms INTEGER,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS hub_grants (
                    grant_id TEXT PRIMARY KEY,
                    device_id TEXT REFERENCES devices(device_id) ON DELETE CASCADE,
                    source_route TEXT NOT NULL,
                    destination_route TEXT NOT NULL,
                    permissions_json BLOB NOT NULL,
                    issuer_signature BLOB NOT NULL,
                    status TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS streams (
                    device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
                    stream_id TEXT NOT NULL UNIQUE,
                    next_seq INTEGER NOT NULL DEFAULT 1 CHECK (next_seq > 0),
                    acked_through INTEGER NOT NULL DEFAULT 0 CHECK (acked_through >= 0),
                    received_through INTEGER NOT NULL DEFAULT 0 CHECK (received_through >= 0),
                    checkpoint_revision INTEGER NOT NULL DEFAULT 0,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS outbox (
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    message_id TEXT NOT NULL,
                    first_seq INTEGER NOT NULL,
                    last_seq INTEGER NOT NULL,
                    message_class TEXT NOT NULL,
                    envelope_json BLOB NOT NULL,
                    state TEXT NOT NULL CHECK (state IN
                        ('pending','hub_accepted','delivered','failed')),
                    created_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error_code TEXT,
                    receipt_kind TEXT NOT NULL DEFAULT 'stream'
                        CHECK (receipt_kind IN ('stream','delivery')),
                    completion_policy TEXT NOT NULL DEFAULT 'stream_ack'
                        CHECK (completion_policy IN
                            ('stream_ack','inner_receipt','hub_accept')),
                    activates_relay_kem_generation INTEGER
                        CHECK (activates_relay_kem_generation > 0),
                    PRIMARY KEY (device_id,message_id)
                );
                CREATE INDEX IF NOT EXISTS outbox_pending
                    ON outbox(device_id,state,created_at_ms);

                CREATE TABLE IF NOT EXISTS seen_messages (
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    message_id TEXT NOT NULL,
                    received_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (device_id,message_id)
                );

                CREATE TABLE IF NOT EXISTS inbound_delivery_receipts (
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    inbound_message_id TEXT NOT NULL,
                    outbound_message_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending','hub_accepted','failed')),
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (device_id,inbound_message_id),
                    UNIQUE (device_id,outbound_message_id)
                );

                CREATE TABLE IF NOT EXISTS operations (
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    op_id TEXT NOT NULL,
                    request_hash BLOB NOT NULL,
                    method TEXT NOT NULL,
                    state TEXT NOT NULL CHECK (state IN
                        ('received','executing','succeeded','failed','ambiguous')),
                    response_json BLOB,
                    error_code TEXT,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (device_id,op_id)
                );

                CREATE TABLE IF NOT EXISTS session_aliases (
                    origin_session_id TEXT PRIMARY KEY,
                    live_session_id TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS owned_sessions (
                    origin_session_id TEXT PRIMARY KEY,
                    live_session_id TEXT NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS subscriptions (
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    session_id TEXT NOT NULL,
                    active INTEGER NOT NULL DEFAULT 1,
                    foreground INTEGER NOT NULL DEFAULT 0,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (device_id,session_id)
                );

                CREATE TABLE IF NOT EXISTS session_items (
                    session_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    source_item_id TEXT,
                    turn_id TEXT,
                    type TEXT NOT NULL,
                    status TEXT NOT NULL,
                    ord INTEGER NOT NULL,
                    revision INTEGER NOT NULL,
                    summary TEXT NOT NULL,
                    body_json BLOB NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (session_id,item_id),
                    UNIQUE (session_id,source_item_id)
                );

                CREATE TABLE IF NOT EXISTS item_aliases (
                    session_id TEXT NOT NULL,
                    source_item_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    created_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (session_id,source_item_id),
                    UNIQUE (session_id,item_id)
                );

                CREATE TABLE IF NOT EXISTS item_revision_hashes (
                    session_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    content_hash BLOB NOT NULL,
                    PRIMARY KEY (session_id,item_id,revision)
                );

                CREATE TABLE IF NOT EXISTS session_tombstones (
                    session_id TEXT NOT NULL,
                    item_id TEXT NOT NULL,
                    deleted_at_revision INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (session_id,item_id)
                );

                CREATE TABLE IF NOT EXISTS session_checkpoints (
                    session_id TEXT PRIMARY KEY,
                    snapshot_revision INTEGER NOT NULL,
                    through_seq INTEGER NOT NULL,
                    content_hash BLOB,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS approval_requests (
                    request_id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    state TEXT NOT NULL,
                    claimed_device_id TEXT,
                    claimed_decision TEXT,
                    op_id TEXT,
                    expires_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS approval_capabilities (
                    capability_hash BLOB PRIMARY KEY,
                    capability_secret BLOB,
                    request_id TEXT NOT NULL REFERENCES approval_requests(request_id) ON DELETE CASCADE,
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    device_generation INTEGER NOT NULL,
                    allowed_decisions_json BLOB NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK (state IN
                        ('pending','claimed','succeeded','failed_retryable','expired','revoked','superseded')),
                    claimed_decision TEXT,
                    op_id TEXT,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS push_bindings (
                    binding_id TEXT PRIMARY KEY,
                    device_id TEXT NOT NULL UNIQUE REFERENCES devices(device_id) ON DELETE CASCADE,
                    send_capability BLOB NOT NULL,
                    allowed_classes_json BLOB NOT NULL,
                    status TEXT NOT NULL,
                    revoke_attempts INTEGER NOT NULL DEFAULT 0,
                    last_error_code TEXT,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );

                CREATE TABLE IF NOT EXISTS notification_outbox (
                    device_id TEXT NOT NULL REFERENCES devices(device_id) ON DELETE CASCADE,
                    notification_id TEXT NOT NULL,
                    binding_id TEXT NOT NULL,
                    session_id TEXT,
                    dedupe_hash BLOB NOT NULL,
                    notification_class TEXT NOT NULL CHECK
                        (notification_class IN ('approval','error','update')),
                    collapse_id TEXT,
                    descriptor_json BLOB NOT NULL,
                    state TEXT NOT NULL CHECK
                        (state IN ('pending','sent','failed','expired')),
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error_code TEXT,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL,
                    next_attempt_at_ms INTEGER NOT NULL,
                    expires_at_ms INTEGER NOT NULL,
                    PRIMARY KEY (device_id,notification_id),
                    UNIQUE (device_id,dedupe_hash)
                );
                CREATE INDEX IF NOT EXISTS notification_outbox_pending
                    ON notification_outbox(state,created_at_ms);

                CREATE TABLE IF NOT EXISTS push_binding_exchanges (
                    device_id TEXT PRIMARY KEY REFERENCES devices(device_id) ON DELETE CASCADE,
                    exchange_id TEXT NOT NULL UNIQUE,
                    bind_token BLOB NOT NULL,
                    requested_classes_json BLOB NOT NULL,
                    state TEXT NOT NULL CHECK (state IN ('pending','completed','revoked')),
                    binding_id TEXT,
                    remote_revoke_state TEXT NOT NULL DEFAULT 'not_required'
                        CHECK (remote_revoke_state IN
                            ('not_required','pending','confirmed')),
                    revoke_attempts INTEGER NOT NULL DEFAULT 0,
                    last_error_code TEXT,
                    created_at_ms INTEGER NOT NULL,
                    updated_at_ms INTEGER NOT NULL
                );
                """
            )
            outbox_columns = {
                row[1]
                for row in self._conn.execute("PRAGMA table_info(outbox)").fetchall()
            }
            if "receipt_kind" not in outbox_columns:
                self._conn.execute(
                    "ALTER TABLE outbox ADD COLUMN receipt_kind TEXT NOT NULL DEFAULT 'stream'"
                )
            if "completion_policy" not in outbox_columns:
                self._conn.execute(
                    """ALTER TABLE outbox ADD COLUMN completion_policy TEXT NOT NULL
                       DEFAULT 'stream_ack' CHECK (completion_policy IN
                       ('stream_ack','inner_receipt','hub_accept'))"""
                )
                self._conn.execute(
                    """UPDATE outbox SET completion_policy='inner_receipt'
                       WHERE receipt_kind='delivery'"""
                )
            if "activates_relay_kem_generation" not in outbox_columns:
                self._conn.execute(
                    """ALTER TABLE outbox ADD COLUMN activates_relay_kem_generation
                       INTEGER CHECK (activates_relay_kem_generation > 0)"""
                )
            relay_key_columns = {
                row[1]
                for row in self._conn.execute(
                    "PRAGMA table_info(relay_kem_keys)"
                ).fetchall()
            }
            if "retirement_started_at_ms" not in relay_key_columns:
                self._conn.execute(
                    "ALTER TABLE relay_kem_keys ADD COLUMN retirement_started_at_ms INTEGER"
                )
            device_columns = {
                row[1]
                for row in self._conn.execute("PRAGMA table_info(devices)").fetchall()
            }
            if "relay_kem_generation" not in device_columns:
                self._conn.execute(
                    """ALTER TABLE devices ADD COLUMN relay_kem_generation INTEGER
                       NOT NULL DEFAULT 1 CHECK (relay_kem_generation > 0)"""
                )
                # A paired device learned the Agent generation current when
                # its durable device row was created.  Reconstruct that value
                # conservatively instead of assigning the possibly newer
                # global generation from an unacknowledged rotation.
                self._conn.execute(
                    """UPDATE devices SET relay_kem_generation=COALESCE(
                           (SELECT MAX(k.generation) FROM relay_kem_keys AS k
                            WHERE k.created_at_ms<=devices.created_at_ms),
                           (SELECT MIN(k.generation) FROM relay_kem_keys AS k
                            WHERE k.status!='revoked'),
                           1
                       )"""
                )
            if "re_pair_required" not in device_columns:
                self._conn.execute(
                    """ALTER TABLE devices ADD COLUMN re_pair_required INTEGER
                       NOT NULL DEFAULT 0 CHECK (re_pair_required IN (0,1))"""
                )
            if "status_reason" not in device_columns:
                self._conn.execute("ALTER TABLE devices ADD COLUMN status_reason TEXT")
            if "hub_revocation_state" not in device_columns:
                self._conn.execute(
                    """ALTER TABLE devices ADD COLUMN hub_revocation_state TEXT
                       NOT NULL DEFAULT 'not_required' CHECK (hub_revocation_state IN
                       ('not_required','pending','confirmed'))"""
                )
            if "hub_revocation_attempts" not in device_columns:
                self._conn.execute(
                    """ALTER TABLE devices ADD COLUMN hub_revocation_attempts INTEGER
                       NOT NULL DEFAULT 0"""
                )
            if "hub_revocation_last_error" not in device_columns:
                self._conn.execute(
                    "ALTER TABLE devices ADD COLUMN hub_revocation_last_error TEXT"
                )
            checkpoint_columns = {
                row[1]
                for row in self._conn.execute(
                    "PRAGMA table_info(session_checkpoints)"
                ).fetchall()
            }
            if "content_hash" not in checkpoint_columns:
                self._conn.execute(
                    "ALTER TABLE session_checkpoints ADD COLUMN content_hash BLOB"
                )
            offer_columns = {
                row[1]
                for row in self._conn.execute(
                    "PRAGMA table_info(pair_offers)"
                ).fetchall()
            }
            if "hub_message_hash" not in offer_columns:
                self._conn.execute(
                    "ALTER TABLE pair_offers ADD COLUMN hub_message_hash TEXT"
                )
            if "hub_response_hash" not in offer_columns:
                self._conn.execute(
                    "ALTER TABLE pair_offers ADD COLUMN hub_response_hash TEXT"
                )
            if "accept_enc" not in offer_columns:
                self._conn.execute("ALTER TABLE pair_offers ADD COLUMN accept_enc BLOB")
            if "accept_ct" not in offer_columns:
                self._conn.execute("ALTER TABLE pair_offers ADD COLUMN accept_ct BLOB")
            if "accept_mid" not in offer_columns:
                self._conn.execute("ALTER TABLE pair_offers ADD COLUMN accept_mid TEXT")
            if "accept_owner" not in offer_columns:
                self._conn.execute(
                    "ALTER TABLE pair_offers ADD COLUMN accept_owner TEXT"
                )
            if "accept_lease_expires_at_ms" not in offer_columns:
                self._conn.execute(
                    "ALTER TABLE pair_offers ADD COLUMN accept_lease_expires_at_ms INTEGER"
                )
            if "hub_registered" not in offer_columns:
                self._conn.execute(
                    "ALTER TABLE pair_offers ADD COLUMN hub_registered INTEGER NOT NULL DEFAULT 0"
                )
            approval_columns = {
                row[1]
                for row in self._conn.execute(
                    "PRAGMA table_info(approval_capabilities)"
                ).fetchall()
            }
            if "capability_secret" not in approval_columns:
                self._conn.execute(
                    "ALTER TABLE approval_capabilities ADD COLUMN capability_secret BLOB"
                )
            push_binding_columns = {
                row[1]
                for row in self._conn.execute(
                    "PRAGMA table_info(push_bindings)"
                ).fetchall()
            }
            if "revoke_attempts" not in push_binding_columns:
                self._conn.execute(
                    """ALTER TABLE push_bindings ADD COLUMN revoke_attempts INTEGER
                       NOT NULL DEFAULT 0"""
                )
            if "last_error_code" not in push_binding_columns:
                self._conn.execute(
                    "ALTER TABLE push_bindings ADD COLUMN last_error_code TEXT"
                )
            push_exchange_columns = {
                row[1]
                for row in self._conn.execute(
                    "PRAGMA table_info(push_binding_exchanges)"
                ).fetchall()
            }
            if (
                push_exchange_columns
                and "remote_revoke_state" not in push_exchange_columns
            ):
                self._conn.execute(
                    """ALTER TABLE push_binding_exchanges
                       ADD COLUMN remote_revoke_state TEXT NOT NULL DEFAULT 'not_required'
                       CHECK (remote_revoke_state IN
                       ('not_required','pending','confirmed'))"""
                )
            if push_exchange_columns and "revoke_attempts" not in push_exchange_columns:
                self._conn.execute(
                    """ALTER TABLE push_binding_exchanges ADD COLUMN revoke_attempts INTEGER
                       NOT NULL DEFAULT 0"""
                )
            if push_exchange_columns and "last_error_code" not in push_exchange_columns:
                self._conn.execute(
                    "ALTER TABLE push_binding_exchanges ADD COLUMN last_error_code TEXT"
                )
            notification_columns = {
                row[1]
                for row in self._conn.execute(
                    "PRAGMA table_info(notification_outbox)"
                ).fetchall()
            }
            if notification_columns and "session_id" not in notification_columns:
                self._conn.execute(
                    "ALTER TABLE notification_outbox ADD COLUMN session_id TEXT"
                )
            if (
                notification_columns
                and "next_attempt_at_ms" not in notification_columns
            ):
                self._conn.execute(
                    """ALTER TABLE notification_outbox
                       ADD COLUMN next_attempt_at_ms INTEGER NOT NULL DEFAULT 0"""
                )
            self._conn.execute(
                """INSERT OR IGNORE INTO relay_kem_keys
                   (generation,private_key,public_key,status,created_at_ms,message_count)
                   SELECT kem_generation,kem_private,kem_public,'current',created_at_ms,0
                   FROM relay_identity WHERE singleton=1"""
            )
            self._conn.execute(f"PRAGMA user_version={SCHEMA_VERSION}")

    @contextlib.contextmanager
    def transaction(self) -> Iterator[sqlite3.Connection]:
        with self._lock:
            self._conn.execute("BEGIN IMMEDIATE")
            try:
                yield self._conn
            except BaseException:
                if self._conn.in_transaction:
                    self._conn.rollback()
                raise
            else:
                self._conn.commit()
                self._harden_state_files()

    def close(self) -> None:
        with self._lock:
            self._harden_state_files()
            self._conn.close()
            if self.path.exists():
                self._secure_path(self.path, 0o600, is_directory=False)

    def current_time_ms(self) -> int:
        """Expose the injected clock for protocol timestamps and tests."""

        return self._clock()

    def __enter__(self) -> "RelayStorage":
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    # -- identity -----------------------------------------------------
    def set_meta(self, key: str, value: str | bytes) -> None:
        encoded = value.encode("utf-8") if isinstance(value, str) else value
        with self.transaction() as conn:
            conn.execute(
                "INSERT INTO meta(key,value) VALUES (?,?) "
                "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                (key, encoded),
            )

    def get_meta(self, key: str) -> bytes | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT value FROM meta WHERE key=?", (key,)
            ).fetchone()
        return bytes(row["value"]) if row else None

    def load_identity(self) -> RelayIdentityRecord | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM relay_identity WHERE singleton=1"
            ).fetchone()
        return self._identity_row(row) if row else None

    def store_identity(
        self,
        *,
        kem_private: bytes,
        kem_public: bytes,
        sign_private: bytes,
        sign_public: bytes,
        kem_generation: int = 1,
        relay_instance_id: str | None = None,
        relay_epoch: str | None = None,
    ) -> RelayIdentityRecord:
        created = self._clock()
        instance = relay_instance_id or random_id("rly")
        epoch = relay_epoch or random_id("epc")
        with self.transaction() as conn:
            existing = conn.execute(
                "SELECT * FROM relay_identity WHERE singleton=1"
            ).fetchone()
            if existing:
                return self._identity_row(existing)
            conn.execute(
                """INSERT INTO relay_identity
                   (singleton,relay_instance_id,relay_epoch,kem_generation,kem_private,
                    kem_public,sign_private,sign_public,created_at_ms)
                   VALUES (1,?,?,?,?,?,?,?,?)""",
                (
                    instance,
                    epoch,
                    kem_generation,
                    kem_private,
                    kem_public,
                    sign_private,
                    sign_public,
                    created,
                ),
            )
            conn.execute(
                """INSERT INTO relay_kem_keys
                   (generation,private_key,public_key,status,created_at_ms,message_count)
                   VALUES (?,?,?,'current',?,0)""",
                (kem_generation, kem_private, kem_public, created),
            )
        return RelayIdentityRecord(
            instance,
            epoch,
            kem_generation,
            kem_private,
            kem_public,
            sign_private,
            sign_public,
            created,
        )

    @staticmethod
    def _identity_row(row: sqlite3.Row) -> RelayIdentityRecord:
        return RelayIdentityRecord(
            relay_instance_id=row["relay_instance_id"],
            relay_epoch=row["relay_epoch"],
            kem_generation=row["kem_generation"],
            kem_private=bytes(row["kem_private"]),
            kem_public=bytes(row["kem_public"]),
            sign_private=bytes(row["sign_private"]),
            sign_public=bytes(row["sign_public"]),
            created_at_ms=row["created_at_ms"],
        )

    def relay_kem_keys(
        self, *, include_revoked: bool = False
    ) -> list[RelayKEMKeyRecord]:
        query = "SELECT * FROM relay_kem_keys"
        if not include_revoked:
            # A retirement marker is an immediate cryptographic boundary.  It
            # is committed before external credential deletion, so no send or
            # receive path may reveal the handle while cleanup is in flight.
            query += " WHERE status!='revoked' AND retirement_started_at_ms IS NULL"
        query += " ORDER BY generation"
        with self._lock:
            rows = self._conn.execute(query).fetchall()
        return [
            RelayKEMKeyRecord(
                generation=row["generation"],
                private_key=bytes(row["private_key"]),
                public_key=bytes(row["public_key"]),
                status=row["status"],
                not_after_ms=row["not_after_ms"],
                created_at_ms=row["created_at_ms"],
                message_count=row["message_count"],
                retirement_started_at_ms=row["retirement_started_at_ms"],
            )
            for row in rows
        ]

    def rotate_relay_kem(
        self,
        *,
        new_generation: int,
        new_private_key: bytes,
        new_public_key: bytes,
        previous_not_after_ms: int,
    ) -> RelayKEMKeyRecord:
        at = self._clock()
        with self.transaction() as conn:
            current = conn.execute(
                "SELECT * FROM relay_kem_keys WHERE status='current'"
            ).fetchone()
            if current is None:
                raise StorageNotFound("current relay KEM key not found")
            if new_generation != current["generation"] + 1:
                raise StorageConflict(
                    "relay KEM generation must increase by exactly one"
                )
            conn.execute(
                """UPDATE relay_kem_keys SET status='previous',not_after_ms=?
                   WHERE generation=? AND status='current'""",
                (previous_not_after_ms, current["generation"]),
            )
            conn.execute(
                """INSERT INTO relay_kem_keys
                   (generation,private_key,public_key,status,created_at_ms,message_count)
                   VALUES (?,?,?,'current',?,0)""",
                (new_generation, new_private_key, new_public_key, at),
            )
            conn.execute(
                """UPDATE relay_identity SET kem_generation=?,kem_private=?,kem_public=?
                   WHERE singleton=1""",
                (new_generation, new_private_key, new_public_key),
            )
        return RelayKEMKeyRecord(
            new_generation,
            new_private_key,
            new_public_key,
            "current",
            None,
            at,
            0,
            None,
        )

    def rotate_relay_kem_with_notices(
        self,
        *,
        new_generation: int,
        new_private_key: bytes,
        new_public_key: bytes,
        previous_not_after_ms: int,
        notice_expires_at_ms: int,
        envelope_factory: Callable[[DeviceRecord], Mapping[str, Any]],
    ) -> tuple[RelayKEMKeyRecord, list[OutboxRecord]]:
        """Atomically rotate the Agent KEM and queue every device notice.

        The envelopes are sealed by ``envelope_factory`` with the still-current
        old key while this transaction is open.  Either all active devices get
        the exact durable ``key_rotate`` ciphertext and the identity advances,
        or neither change commits.  This closes the crash window that would
        otherwise generate a different key for the same generation on restart.
        """

        at = self._clock()
        notices: list[OutboxRecord] = []
        with self.transaction() as conn:
            current = conn.execute(
                "SELECT * FROM relay_kem_keys WHERE status='current'"
            ).fetchone()
            if current is None:
                raise StorageNotFound("current relay KEM key not found")
            if new_generation != int(current["generation"]) + 1:
                raise StorageConflict(
                    "relay KEM generation must increase by exactly one"
                )
            if previous_not_after_ms <= at or notice_expires_at_ms <= at:
                raise StorageExpired("key rotation deadline is not in the future")
            device_rows = conn.execute(
                "SELECT * FROM devices WHERE status='active' ORDER BY device_id"
            ).fetchall()
            for row in device_rows:
                device = self._device_row(row)
                envelope = dict(envelope_factory(device))
                mid = envelope.get("mid")
                if not isinstance(mid, str) or not mid:
                    raise ValueError("envelope_factory must return a non-empty mid")
                encoded = json.dumps(
                    envelope,
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ).encode("utf-8")
                conn.execute(
                    """INSERT INTO outbox
                       (device_id,message_id,first_seq,last_seq,message_class,envelope_json,
                        state,created_at_ms,expires_at_ms,receipt_kind,completion_policy,
                        activates_relay_kem_generation)
                       VALUES (?,?,0,0,'control',?,'pending',?,?,'delivery',
                               'inner_receipt',?)""",
                    (
                        device.device_id,
                        mid,
                        encoded,
                        at,
                        notice_expires_at_ms,
                        new_generation,
                    ),
                )
                notices.append(
                    OutboxRecord(
                        device.device_id,
                        mid,
                        0,
                        0,
                        "control",
                        envelope,
                        "pending",
                        at,
                        notice_expires_at_ms,
                        0,
                        "delivery",
                        "inner_receipt",
                        new_generation,
                    )
                )
            conn.execute(
                """UPDATE relay_kem_keys SET status='previous',not_after_ms=?
                   WHERE generation=? AND status='current'""",
                (previous_not_after_ms, current["generation"]),
            )
            conn.execute(
                """INSERT INTO relay_kem_keys
                   (generation,private_key,public_key,status,created_at_ms,message_count)
                   VALUES (?,?,?,'current',?,0)""",
                (new_generation, new_private_key, new_public_key, at),
            )
            conn.execute(
                """UPDATE relay_identity SET kem_generation=?,kem_private=?,kem_public=?
                   WHERE singleton=1""",
                (new_generation, new_private_key, new_public_key),
            )
        return (
            RelayKEMKeyRecord(
                new_generation,
                new_private_key,
                new_public_key,
                "current",
                None,
                at,
                0,
                None,
            ),
            notices,
        )

    def record_relay_encryption(self, generation: int) -> int:
        def increment(conn: sqlite3.Connection) -> int:
            cursor = conn.execute(
                """UPDATE relay_kem_keys SET message_count=message_count+1
                   WHERE generation=? AND status IN ('current','previous')""",
                (generation,),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("relay KEM generation is unavailable")
            return int(
                conn.execute(
                    "SELECT message_count FROM relay_kem_keys WHERE generation=?",
                    (generation,),
                ).fetchone()[0]
            )

        # Envelope factories run inside the outbox transaction so sequence
        # allocation, ciphertext persistence, and rotation accounting commit
        # together.  Reuse that transaction instead of attempting a nested
        # BEGIN on SQLite's single connection.
        with self._lock:
            if self._conn.in_transaction:
                return increment(self._conn)
        with self.transaction() as conn:
            return increment(conn)

    def relay_rotation_due(
        self,
        *,
        max_age_ms: int = 7 * 24 * 60 * 60 * 1000,
        max_messages: int = 10_000,
    ) -> bool:
        with self._lock:
            row = self._conn.execute(
                "SELECT created_at_ms,message_count FROM relay_kem_keys WHERE status='current'"
            ).fetchone()
        if row is None:
            return True
        return (
            self._clock() - row["created_at_ms"] >= max_age_ms
            or row["message_count"] >= max_messages
        )

    def relay_rotation_awaiting_device_receipts(self) -> bool:
        """Return whether another rotation would skip an active peer's generation."""

        with self._lock:
            row = self._conn.execute(
                """SELECT 1 FROM devices AS d
                   JOIN relay_kem_keys AS k ON k.status='current'
                   WHERE d.status='active'
                     AND d.relay_kem_generation!=k.generation
                   LIMIT 1"""
            ).fetchone()
        return row is not None

    @staticmethod
    def _queue_device_fail_closed(
        conn: sqlite3.Connection,
        *,
        device_id: str,
        reason: str,
        at: int,
    ) -> None:
        """Atomically remove local authority and queue remote cleanup."""

        device = conn.execute(
            "SELECT route,hub_revocation_state FROM devices WHERE device_id=?",
            (device_id,),
        ).fetchone()
        if device is None:
            return
        conn.execute(
            """UPDATE devices
               SET status='revoked',revoked_at_ms=COALESCE(revoked_at_ms,?),
                   re_pair_required=1,status_reason=COALESCE(status_reason,?),
                   hub_revocation_state=CASE
                       WHEN hub_revocation_state='confirmed' THEN 'confirmed'
                       ELSE 'pending'
                   END,
                   hub_revocation_last_error=CASE
                       WHEN hub_revocation_state='confirmed' THEN hub_revocation_last_error
                       ELSE NULL
                   END
               WHERE device_id=?""",
            (at, reason, device_id),
        )
        conn.execute(
            "UPDATE device_keys SET status='revoked' WHERE device_id=?",
            (device_id,),
        )
        conn.execute(
            """UPDATE hub_routes SET status='revoking',updated_at_ms=?
               WHERE route_id=? AND status!='revoked'""",
            (at, device["route"]),
        )
        conn.execute(
            """UPDATE hub_grants SET status='revoking'
               WHERE device_id=? AND status!='revoked'""",
            (device_id,),
        )
        conn.execute(
            """UPDATE approval_capabilities
               SET state='revoked',updated_at_ms=?
               WHERE device_id=?
                 AND state IN ('pending','claimed','failed_retryable')""",
            (at, device_id),
        )
        # Protected Push secrets remain until their corresponding remote
        # revocation/absence response is durably confirmed.
        conn.execute(
            """UPDATE push_bindings
               SET status='remote_revoke_pending',revoke_attempts=0,
                   last_error_code=NULL,updated_at_ms=?
               WHERE device_id=? AND status='active'""",
            (at, device_id),
        )
        conn.execute(
            """UPDATE push_binding_exchanges
               SET remote_revoke_state='pending',revoke_attempts=0,
                   last_error_code=NULL,updated_at_ms=?
               WHERE device_id=? AND state='pending'
                 AND remote_revoke_state='not_required'""",
            (at, device_id),
        )
        conn.execute(
            """UPDATE notification_outbox
               SET state='failed',last_error_code='device_re_pair_required',
                   updated_at_ms=?
               WHERE device_id=? AND state='pending'""",
            (at, device_id),
        )
        conn.execute(
            """UPDATE inbound_delivery_receipts
               SET state='failed',updated_at_ms=?
               WHERE device_id=? AND state='pending'""",
            (at, device_id),
        )
        conn.execute(
            """UPDATE outbox
               SET state='failed',last_error_code='device_re_pair_required'
               WHERE device_id=? AND state IN ('pending','hub_accepted')""",
            (device_id,),
        )
        conn.execute(
            """UPDATE subscriptions SET active=0,foreground=0,updated_at_ms=?
               WHERE device_id=?""",
            (at, device_id),
        )

    def retire_relay_kem_keys(self) -> int:
        """Quarantine expired laggards and crash-safely erase old Agent keys.

        The first transaction is the security boundary: lagging devices lose
        every local authority and expired keys receive a durable retirement
        marker.  Only then are opaque Keychain/keyring handles deleted.  A
        crash after external deletion leaves the handle for an exact retry,
        while normal key reads exclude the retirement marker immediately.
        """

        at = self._clock()
        with self.transaction() as conn:
            laggards = conn.execute(
                """SELECT d.device_id,d.route
                   FROM devices AS d
                   JOIN relay_kem_keys AS current_key
                     ON current_key.status='current'
                   LEFT JOIN relay_kem_keys AS pinned_key
                     ON pinned_key.generation=d.relay_kem_generation
                   WHERE d.status='active'
                     AND d.relay_kem_generation!=current_key.generation
                     AND (
                         pinned_key.generation IS NULL
                         OR pinned_key.status='revoked'
                         OR pinned_key.retirement_started_at_ms IS NOT NULL
                         OR (
                             pinned_key.status='previous'
                             AND pinned_key.not_after_ms IS NOT NULL
                             AND pinned_key.not_after_ms<=?
                         )
                     )
                   ORDER BY d.device_id""",
                (at,),
            ).fetchall()
            for row in laggards:
                device_id = str(row["device_id"])
                self._queue_device_fail_closed(
                    conn,
                    device_id=device_id,
                    reason="relay_kem_overlap_expired",
                    at=at,
                )

            conn.execute(
                """UPDATE relay_kem_keys
                   SET retirement_started_at_ms=COALESCE(retirement_started_at_ms,?)
                   WHERE status='previous' AND not_after_ms IS NOT NULL
                     AND not_after_ms<=?""",
                (at, at),
            )

        self._finish_re_pair_credential_cleanup()

        with self._lock:
            retiring = self._conn.execute(
                """SELECT generation,private_key FROM relay_kem_keys
                   WHERE status='previous' AND retirement_started_at_ms IS NOT NULL
                   ORDER BY generation"""
            ).fetchall()
        finalized = 0
        cleanup_errors: list[Exception] = []
        for row in retiring:
            generation = int(row["generation"])
            wrapped = bytes(row["private_key"])
            try:
                if wrapped and self.credential_protector is not None:
                    self.credential_protector.delete(wrapped)
            except Exception as exc:
                cleanup_errors.append(exc)
                continue
            # Only credential-backend failures are retryable at startup.  A
            # SQLite/finalization failure must retain its original type so it
            # cannot be mistaken for successful durable maintenance.
            with self.transaction() as conn:
                cursor = conn.execute(
                    """UPDATE relay_kem_keys
                       SET status='revoked',private_key=X''
                       WHERE generation=? AND status='previous'
                         AND retirement_started_at_ms IS NOT NULL""",
                    (generation,),
                )
                finalized += cursor.rowcount
        if cleanup_errors:
            first = cleanup_errors[0]
            error = CredentialProtectionError(
                "Agent KEM retirement credential cleanup failed"
            )
            if len(cleanup_errors) > 1:
                error.add_note(
                    f"{len(cleanup_errors) - 1} additional credential cleanup "
                    "operation(s) also failed"
                )
            raise error from first
        return finalized

    def _finish_re_pair_credential_cleanup(self) -> None:
        """Attempt retryable device cleanup without starving Agent rotation."""

        with self._lock:
            bindings = self._conn.execute(
                """SELECT binding_id,send_capability FROM push_bindings
                   WHERE status='remote_revoked' ORDER BY binding_id"""
            ).fetchall()
            exchanges = self._conn.execute(
                """SELECT e.device_id,e.bind_token,e.state,e.remote_revoke_state
                   FROM push_binding_exchanges AS e
                   LEFT JOIN push_bindings AS p ON p.device_id=e.device_id
                   LEFT JOIN devices AS d ON d.device_id=e.device_id
                   WHERE length(e.bind_token)>0 AND (
                       (e.state='pending' AND e.remote_revoke_state='confirmed')
                       OR
                       (e.state='completed' AND d.re_pair_required=1
                        AND p.status IN ('remote_revoked','revoked'))
                   )
                   ORDER BY e.device_id"""
            ).fetchall()
        for row in bindings:
            wrapped = bytes(row["send_capability"])
            try:
                if wrapped and self.credential_protector is not None:
                    self.credential_protector.delete(wrapped)
                with self.transaction() as conn:
                    conn.execute(
                        """UPDATE push_bindings
                           SET status='revoked',send_capability=X'',updated_at_ms=?
                           WHERE binding_id=? AND status='remote_revoked'""",
                        (self._clock(), row["binding_id"]),
                    )
            except Exception as exc:
                _log.warning(
                    "re-pair Push binding cleanup remains pending for %s: %s",
                    row["binding_id"],
                    exc,
                    exc_info=True,
                )
        for row in exchanges:
            wrapped = bytes(row["bind_token"])
            try:
                if wrapped and self.credential_protector is not None:
                    self.credential_protector.delete(wrapped)
                with self.transaction() as conn:
                    conn.execute(
                        """UPDATE push_binding_exchanges
                           SET bind_token=X'',
                               state=CASE
                                   WHEN state='pending'
                                        AND remote_revoke_state='confirmed'
                                   THEN 'revoked'
                                   ELSE state
                               END,
                               updated_at_ms=?
                           WHERE device_id=? AND bind_token=?""",
                        (self._clock(), row["device_id"], wrapped),
                    )
            except Exception as exc:
                _log.warning(
                    "re-pair bind-token cleanup remains pending for %s: %s",
                    row["device_id"],
                    exc,
                    exc_info=True,
                )

    def re_pair_credential_cleanup_pending(self) -> int:
        """Return content-free count of quarantined credentials awaiting erasure."""

        with self._lock:
            row = self._conn.execute(
                """SELECT
                       (SELECT COUNT(*) FROM push_bindings
                        WHERE status IN ('remote_revoke_pending','remote_revoked'))
                       +
                       (SELECT COUNT(*)
                        FROM push_binding_exchanges AS e
                        JOIN devices AS d ON d.device_id=e.device_id
                        LEFT JOIN push_bindings AS p ON p.device_id=e.device_id
                        WHERE (
                            e.remote_revoke_state='pending'
                            OR
                            (e.remote_revoke_state='confirmed'
                             AND length(e.bind_token)>0)
                            OR
                            (e.state='completed' AND d.re_pair_required=1
                             AND length(e.bind_token)>0
                             AND p.status IN ('remote_revoke_pending','remote_revoked'))
                        )) AS pending"""
            ).fetchone()
        return int(row["pending"])

    def re_pair_hub_revocation_pending(self) -> int:
        with self._lock:
            row = self._conn.execute(
                """SELECT COUNT(*) AS pending FROM devices
                   WHERE re_pair_required=1 AND hub_revocation_state='pending'"""
            ).fetchone()
        return int(row["pending"])

    def finish_confirmed_remote_credential_cleanup(self) -> None:
        """Erase only credentials whose remote revocation is already durable."""

        self._finish_re_pair_credential_cleanup()

    def pending_hub_device_revocations(self) -> list[HubRevocationRecord]:
        """Return durable Hub route deletions required by re-pair quarantine."""

        with self._lock:
            rows = self._conn.execute(
                """SELECT device_id,route,hub_revocation_attempts
                   FROM devices
                   WHERE re_pair_required=1 AND hub_revocation_state='pending'
                   ORDER BY device_id"""
            ).fetchall()
            result: list[HubRevocationRecord] = []
            for row in rows:
                grants = self._conn.execute(
                    "SELECT grant_id FROM hub_grants WHERE device_id=? ORDER BY grant_id",
                    (row["device_id"],),
                ).fetchall()
                result.append(
                    HubRevocationRecord(
                        device_id=row["device_id"],
                        route_id=row["route"],
                        grant_ids=tuple(grant["grant_id"] for grant in grants),
                        attempts=int(row["hub_revocation_attempts"]),
                    )
                )
        return result

    def queue_device_revocation(
        self,
        device_id: str,
        *,
        inbound_message_id: str | None = None,
        inbound_expires_at_ms: int | None = None,
    ) -> bool:
        """Remove local authority before any best-effort remote cleanup.

        The optional inbound marker is committed in the same transaction as
        the tombstone.  A DEVICE_REVOKE whose remote cleanup response is lost
        can therefore be ACKed on replay without ever reactivating the peer.
        Protected Hub/Push cleanup credentials intentionally remain available
        until their respective remote tombstones are durably confirmed.
        """

        if (inbound_message_id is None) != (inbound_expires_at_ms is None):
            raise ValueError("inbound revoke receipt fields must be supplied together")
        at = self._clock()
        with self.transaction() as conn:
            device = conn.execute(
                "SELECT status,re_pair_required FROM devices WHERE device_id=?",
                (device_id,),
            ).fetchone()
            if device is None:
                raise StorageNotFound("device not found")
            changed = device["status"] != "revoked" or not bool(
                device["re_pair_required"]
            )
            self._queue_device_fail_closed(
                conn,
                device_id=device_id,
                reason="device_revoked",
                at=at,
            )
            if inbound_message_id is not None:
                conn.execute(
                    """INSERT OR IGNORE INTO seen_messages
                       (device_id,message_id,received_at_ms,expires_at_ms)
                       VALUES (?,?,?,?)""",
                    (device_id, inbound_message_id, at, inbound_expires_at_ms),
                )
            return changed

    def confirm_hub_device_revocation(
        self, device_id: str, *, route_id: str, grant_ids: Sequence[str]
    ) -> bool:
        """Persist a strict, idempotent Hub route-deletion response."""

        at = self._clock()
        with self.transaction() as conn:
            device = conn.execute(
                """SELECT route,hub_revocation_state FROM devices
                   WHERE device_id=? AND re_pair_required=1""",
                (device_id,),
            ).fetchone()
            if device is None or device["route"] != route_id:
                raise StorageConflict("Hub revocation route changed")
            expected = {
                row["grant_id"]
                for row in conn.execute(
                    "SELECT grant_id FROM hub_grants WHERE device_id=?",
                    (device_id,),
                ).fetchall()
            }
            if set(grant_ids) != expected:
                raise StorageConflict("Hub revoked an unexpected device grant set")
            if device["hub_revocation_state"] == "confirmed":
                return False
            if device["hub_revocation_state"] != "pending":
                raise StorageConflict("Hub revocation is not pending")
            conn.execute(
                """UPDATE devices
                   SET hub_revocation_state='confirmed',
                       hub_revocation_attempts=hub_revocation_attempts+1,
                       hub_revocation_last_error=NULL
                   WHERE device_id=?""",
                (device_id,),
            )
            conn.execute(
                "UPDATE hub_routes SET status='revoked',updated_at_ms=? WHERE route_id=?",
                (at, route_id),
            )
            conn.execute(
                "UPDATE hub_grants SET status='revoked' WHERE device_id=?",
                (device_id,),
            )
            return True

    def mark_hub_device_revocation_failed(
        self, device_id: str, error_code: str
    ) -> None:
        with self.transaction() as conn:
            conn.execute(
                """UPDATE devices
                   SET hub_revocation_attempts=hub_revocation_attempts+1,
                       hub_revocation_last_error=?
                   WHERE device_id=? AND hub_revocation_state='pending'""",
                (error_code[:128], device_id),
            )

    def pending_push_binding_revocations(
        self,
    ) -> list[PushBindingRevocationRecord]:
        with self._lock:
            rows = self._conn.execute(
                """SELECT device_id,binding_id,revoke_attempts FROM push_bindings
                   WHERE status='remote_revoke_pending' ORDER BY binding_id"""
            ).fetchall()
        return [
            PushBindingRevocationRecord(
                device_id=row["device_id"],
                binding_id=row["binding_id"],
                attempts=int(row["revoke_attempts"]),
            )
            for row in rows
        ]

    def queue_all_push_authority_revocation(self) -> tuple[str, ...]:
        """Disable Push locally and durably queue every remote tombstone.

        This is the notification opt-out boundary.  It deliberately leaves
        device keys, Hub routes, and Hub grants untouched.  Binding and
        exchange secrets remain protected at rest until the Push Gateway has
        confirmed the corresponding revoke/absence operation.
        """

        at = self._clock()
        with self.transaction() as conn:
            rows = conn.execute(
                """SELECT device_id FROM push_bindings WHERE status='active'
                   UNION
                   SELECT device_id FROM push_binding_exchanges
                   WHERE state='pending' AND remote_revoke_state='not_required'
                   ORDER BY device_id"""
            ).fetchall()
            device_ids = tuple(str(row["device_id"]) for row in rows)
            conn.execute(
                """UPDATE push_bindings
                   SET status='remote_revoke_pending',revoke_attempts=0,
                       last_error_code=NULL,updated_at_ms=?
                   WHERE status='active'""",
                (at,),
            )
            conn.execute(
                """UPDATE push_binding_exchanges
                   SET remote_revoke_state='pending',revoke_attempts=0,
                       last_error_code=NULL,updated_at_ms=?
                   WHERE state='pending'
                     AND remote_revoke_state='not_required'""",
                (at,),
            )
            conn.execute(
                """UPDATE notification_outbox
                   SET state='failed',last_error_code='push_opt_out',updated_at_ms=?
                   WHERE state='pending'""",
                (at,),
            )
        return device_ids

    def re_pair_push_revocation_status(self) -> list[dict[str, Any]]:
        """Return content-free state for remote/local Push cleanup."""

        with self._lock:
            rows = self._conn.execute(
                """SELECT p.device_id,p.status,p.revoke_attempts,p.last_error_code
                   FROM push_bindings AS p
                   JOIN devices AS d ON d.device_id=p.device_id
                   WHERE d.re_pair_required=1
                     AND p.status IN ('remote_revoke_pending','remote_revoked')
                   ORDER BY p.device_id"""
            ).fetchall()
            exchanges = self._conn.execute(
                """SELECT device_id,remote_revoke_state,revoke_attempts,last_error_code
                   FROM push_binding_exchanges
                   WHERE remote_revoke_state='pending'
                      OR (remote_revoke_state='confirmed' AND length(bind_token)>0)
                   ORDER BY device_id"""
            ).fetchall()
        result = [
            {
                "device_id": row["device_id"],
                "state": row["status"],
                "attempts": int(row["revoke_attempts"]),
                "last_error_code": row["last_error_code"],
            }
            for row in rows
        ]
        result.extend(
            {
                "device_id": row["device_id"],
                "state": f"exchange_remote_{row['remote_revoke_state']}",
                "attempts": int(row["revoke_attempts"]),
                "last_error_code": row["last_error_code"],
            }
            for row in exchanges
        )
        return sorted(result, key=lambda item: (item["device_id"], item["state"]))

    def push_binding_revocation_capability(self, binding_id: str) -> bytes:
        with self._lock:
            row = self._conn.execute(
                """SELECT send_capability FROM push_bindings
                   WHERE binding_id=? AND status='remote_revoke_pending'""",
                (binding_id,),
            ).fetchone()
        if row is None:
            raise StorageNotFound("Push binding revocation is not pending")
        wrapped = bytes(row["send_capability"])
        return (
            self.credential_protector.reveal(wrapped)
            if self.credential_protector is not None
            else wrapped
        )

    def confirm_push_binding_remote_revocation(self, binding_id: str) -> bool:
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE push_bindings
                   SET status='remote_revoked',revoke_attempts=revoke_attempts+1,
                       last_error_code=NULL,updated_at_ms=?
                   WHERE binding_id=? AND status='remote_revoke_pending'""",
                (self._clock(), binding_id),
            )
            return cursor.rowcount == 1

    def mark_push_binding_revocation_failed(
        self, binding_id: str, error_code: str
    ) -> None:
        with self.transaction() as conn:
            conn.execute(
                """UPDATE push_bindings
                   SET revoke_attempts=revoke_attempts+1,last_error_code=?,updated_at_ms=?
                   WHERE binding_id=? AND status='remote_revoke_pending'""",
                (error_code[:128], self._clock(), binding_id),
            )

    def pending_push_exchange_revocations(self) -> list[PushBindingExchangeRecord]:
        with self._lock:
            rows = self._conn.execute(
                """SELECT * FROM push_binding_exchanges
                   WHERE state='pending' AND remote_revoke_state='pending'
                   ORDER BY device_id"""
            ).fetchall()
        return [self._push_exchange_row(row) for row in rows]

    def confirm_push_exchange_remote_revocation(
        self, device_id: str, exchange_id: str
    ) -> bool:
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE push_binding_exchanges
                   SET remote_revoke_state='confirmed',
                       revoke_attempts=revoke_attempts+1,last_error_code=NULL,
                       updated_at_ms=?
                   WHERE device_id=? AND exchange_id=? AND state='pending'
                     AND remote_revoke_state='pending'""",
                (self._clock(), device_id, exchange_id),
            )
            return cursor.rowcount == 1

    def mark_push_exchange_revocation_failed(
        self, device_id: str, exchange_id: str, error_code: str
    ) -> None:
        with self.transaction() as conn:
            conn.execute(
                """UPDATE push_binding_exchanges
                   SET revoke_attempts=revoke_attempts+1,last_error_code=?,updated_at_ms=?
                   WHERE device_id=? AND exchange_id=? AND state='pending'
                     AND remote_revoke_state='pending'""",
                (
                    error_code[:128],
                    self._clock(),
                    device_id,
                    exchange_id,
                ),
            )

    # -- pairing + device registry -----------------------------------
    def create_pair_offer(
        self,
        *,
        relay_route: str,
        ttl_seconds: int = 300,
        auto_approve: bool = False,
        offer_id: str | None = None,
        offer_route: str | None = None,
        pair_secret: bytes | None = None,
        transport_token: str | None = None,
    ) -> PairOfferRecord:
        if ttl_seconds < 1 or ttl_seconds > 3600:
            raise ValueError("pairing TTL must be between 1 and 3600 seconds")
        created = self._clock()
        record = PairOfferRecord(
            offer_id=offer_id or random_id("ofr"),
            offer_route=offer_route or random_id("off"),
            relay_route=relay_route,
            pair_secret=pair_secret or secrets.token_bytes(32),
            transport_token=transport_token or secrets.token_urlsafe(32),
            expires_at_ms=created + ttl_seconds * 1000,
            state="pending",
            device_key_hash=None,
            device_id=None,
            auto_approve=auto_approve,
            hub_message_hash=None,
            hub_response_hash=None,
            accept_enc=None,
            accept_ct=None,
            accept_mid=None,
            hub_registered=False,
        )
        with self.transaction() as conn:
            conn.execute(
                """INSERT INTO pair_offers
                   (offer_id,offer_route,relay_route,pair_secret,transport_token,
                    expires_at_ms,state,auto_approve,created_at_ms,updated_at_ms)
                   VALUES (?,?,?,?,?,?,'pending',?,?,?)""",
                (
                    record.offer_id,
                    record.offer_route,
                    record.relay_route,
                    record.pair_secret,
                    record.transport_token,
                    record.expires_at_ms,
                    int(record.auto_approve),
                    created,
                    created,
                ),
            )
        return record

    def get_pair_offer(self, offer_id: str) -> PairOfferRecord | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
            ).fetchone()
        return self._offer_row(row) if row else None

    def pair_offers(
        self, *, states: Sequence[str] = ("pending", "claimed", "confirmed")
    ) -> list[PairOfferRecord]:
        requested = tuple(dict.fromkeys(states))
        if not requested:
            return []
        placeholders = ",".join("?" for _ in requested)
        with self._lock:
            rows = self._conn.execute(
                f"""SELECT * FROM pair_offers WHERE state IN ({placeholders})
                    ORDER BY created_at_ms""",
                requested,
            ).fetchall()
        return [self._offer_row(row) for row in rows]

    def claim_pair_offer(
        self, offer_id: str, device_key_hash: bytes
    ) -> PairOfferRecord:
        at = self._clock()
        expired = False
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
            ).fetchone()
            if row is None:
                raise StorageNotFound("pairing offer not found")
            if row["expires_at_ms"] <= at and row["state"] in ("pending", "claimed"):
                self._terminalize_pair_offer_in_tx(
                    conn, row=row, terminal_state="expired", at=at
                )
                expired = True
            if expired:
                result = None
            else:
                state = row["state"]
                if state == "claimed":
                    if secrets.compare_digest(
                        bytes(row["device_key_hash"]), device_key_hash
                    ):
                        result = self._offer_row(row)
                    else:
                        raise StorageConflict("pairing offer claimed by another device")
                elif state != "pending":
                    raise StorageConflict(f"pairing offer is {state}")
                else:
                    changed = conn.execute(
                        """UPDATE pair_offers
                           SET state='claimed',device_key_hash=?,updated_at_ms=?
                           WHERE offer_id=? AND state='pending'""",
                        (device_key_hash, at, offer_id),
                    )
                    if changed.rowcount != 1:
                        raise StorageConflict("pairing claim lost compare-and-set race")
                    row = conn.execute(
                        "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
                    ).fetchone()
                    result = self._offer_row(row)
        if expired:
            raise StorageExpired("pairing offer expired")
        return result  # type: ignore[return-value]

    def associate_pair_offer_device(self, offer_id: str, device_id: str) -> None:
        """Persist cleanup ownership before any Push exchange can be sent."""

        at = self._clock()
        expired = False
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
            ).fetchone()
            if row is None:
                raise StorageNotFound("pairing offer not found")
            if row["expires_at_ms"] <= at and row["state"] in {
                "pending",
                "claimed",
                "confirmed",
            }:
                if row["device_id"] not in {None, device_id}:
                    raise StorageConflict(
                        "pairing offer is associated with another device"
                    )
                if row["device_id"] is None:
                    conn.execute(
                        "UPDATE pair_offers SET device_id=? WHERE offer_id=?",
                        (device_id, offer_id),
                    )
                    row = conn.execute(
                        "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
                    ).fetchone()
                self._terminalize_pair_offer_in_tx(
                    conn, row=row, terminal_state="expired", at=at
                )
                expired = True
            elif row["state"] != "claimed":
                raise StorageConflict("pairing offer is not awaiting a device")
            elif row["device_id"] not in {None, device_id}:
                raise StorageConflict("pairing offer is associated with another device")
            else:
                conn.execute(
                    """UPDATE pair_offers SET device_id=?,updated_at_ms=?
                       WHERE offer_id=? AND state='claimed'
                         AND (device_id IS NULL OR device_id=?)""",
                    (device_id, at, offer_id, device_id),
                )
        if expired:
            raise StorageExpired("pairing offer expired")

    def acquire_pair_acceptance(
        self, offer_id: str, owner: str, *, lease_ms: int = 120_000
    ) -> bool:
        """Acquire the cross-process right to build one PairAccept."""

        if not owner or len(owner) > 128 or lease_ms < 1:
            raise ValueError("invalid PairAccept lease")
        at = self._clock()
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE pair_offers
                   SET accept_owner=?,accept_lease_expires_at_ms=?,updated_at_ms=?
                   WHERE offer_id=? AND state='claimed' AND expires_at_ms>?
                     AND (
                         accept_owner IS NULL
                         OR accept_owner=?
                         OR accept_lease_expires_at_ms IS NULL
                         OR accept_lease_expires_at_ms<=?
                     )""",
                (owner, at + lease_ms, at, offer_id, at, owner, at),
            )
            return cursor.rowcount == 1

    def renew_pair_acceptance(
        self, offer_id: str, owner: str, *, lease_ms: int = 120_000
    ) -> bool:
        at = self._clock()
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE pair_offers
                   SET accept_lease_expires_at_ms=?,updated_at_ms=?
                   WHERE offer_id=? AND state='claimed' AND accept_owner=?
                     AND expires_at_ms>?""",
                (at + lease_ms, at, offer_id, owner, at),
            )
            return cursor.rowcount == 1

    def release_pair_acceptance(self, offer_id: str, owner: str) -> bool:
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE pair_offers
                   SET accept_owner=NULL,accept_lease_expires_at_ms=NULL,
                       updated_at_ms=?
                   WHERE offer_id=? AND state='claimed' AND accept_owner=?""",
                (self._clock(), offer_id, owner),
            )
            return cursor.rowcount == 1

    def _terminalize_pair_offer_in_tx(
        self,
        conn: sqlite3.Connection,
        *,
        row: sqlite3.Row,
        terminal_state: str,
        at: int,
    ) -> bool:
        if terminal_state not in {"expired", "cancelled"}:
            raise ValueError("invalid terminal pairing state")
        if row["state"] not in {"pending", "claimed", "confirmed"}:
            return False
        cursor = conn.execute(
            """UPDATE pair_offers SET state=?,updated_at_ms=?,
               pair_secret=X'',transport_token=''
               WHERE offer_id=? AND state=?""",
            (terminal_state, at, row["offer_id"], row["state"]),
        )
        if cursor.rowcount != 1:
            raise StorageConflict(
                "pairing terminal transition lost compare-and-set race"
            )
        if row["device_id"] is not None:
            self._queue_device_fail_closed(
                conn,
                device_id=str(row["device_id"]),
                reason=f"pair_offer_{terminal_state}",
                at=at,
            )
        return True

    def transition_pair_offer(
        self,
        offer_id: str,
        *,
        expected: str,
        new_state: str,
        device_id: str | None = None,
    ) -> PairOfferRecord:
        allowed = {
            ("claimed", "confirmed"),
            ("confirmed", "consumed"),
            ("pending", "cancelled"),
            ("claimed", "cancelled"),
            ("confirmed", "cancelled"),
        }
        if (expected, new_state) not in allowed:
            raise ValueError("invalid pairing transition")
        at = self._clock()
        expired = False
        with self.transaction() as conn:
            erase = new_state in {"consumed", "cancelled"}
            cursor = conn.execute(
                """UPDATE pair_offers SET state=?,device_id=COALESCE(?,device_id),updated_at_ms=?,
                   pair_secret=CASE WHEN ? THEN X'' ELSE pair_secret END,
                   transport_token=CASE WHEN ? THEN '' ELSE transport_token END
                   WHERE offer_id=? AND state=? AND expires_at_ms>?""",
                (
                    new_state,
                    device_id,
                    at,
                    int(erase),
                    int(erase),
                    offer_id,
                    expected,
                    at,
                ),
            )
            if cursor.rowcount != 1:
                row = conn.execute(
                    "SELECT * FROM pair_offers WHERE offer_id=?",
                    (offer_id,),
                ).fetchone()
                if row is None:
                    raise StorageNotFound("pairing offer not found")
                if row["expires_at_ms"] <= at:
                    self._terminalize_pair_offer_in_tx(
                        conn, row=row, terminal_state="expired", at=at
                    )
                    expired = True
                else:
                    raise StorageConflict(f"pairing offer is {row['state']}")
            row = conn.execute(
                "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
            ).fetchone()
            if (
                not expired
                and new_state == "cancelled"
                and row["device_id"] is not None
            ):
                self._queue_device_fail_closed(
                    conn,
                    device_id=str(row["device_id"]),
                    reason="pair_offer_cancelled",
                    at=at,
                )
        if expired:
            raise StorageExpired("pairing offer expired")
        return self._offer_row(row)

    def expire_pair_offers(self) -> int:
        at = self._clock()
        with self.transaction() as conn:
            rows = conn.execute(
                """SELECT * FROM pair_offers WHERE expires_at_ms<=?
                   AND state IN ('pending','claimed','confirmed')
                   ORDER BY offer_id""",
                (at,),
            ).fetchall()
            for row in rows:
                self._terminalize_pair_offer_in_tx(
                    conn, row=row, terminal_state="expired", at=at
                )
            return len(rows)

    def erase_pair_offer_secrets(self, offer_id: str) -> bool:
        """Idempotently erase one-time pairing authority after any terminal path."""

        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE pair_offers SET pair_secret=X'',transport_token='',updated_at_ms=?
                   WHERE offer_id=? AND (length(pair_secret)>0 OR length(transport_token)>0)""",
                (self._clock(), offer_id),
            )
            return cursor.rowcount == 1

    @staticmethod
    def _offer_row(row: sqlite3.Row) -> PairOfferRecord:
        return PairOfferRecord(
            offer_id=row["offer_id"],
            offer_route=row["offer_route"],
            relay_route=row["relay_route"],
            pair_secret=bytes(row["pair_secret"]),
            transport_token=row["transport_token"],
            expires_at_ms=row["expires_at_ms"],
            state=row["state"],
            device_key_hash=(
                bytes(row["device_key_hash"])
                if row["device_key_hash"] is not None
                else None
            ),
            device_id=row["device_id"],
            auto_approve=bool(row["auto_approve"]),
            hub_message_hash=row["hub_message_hash"],
            hub_response_hash=row["hub_response_hash"],
            accept_enc=bytes(row["accept_enc"])
            if row["accept_enc"] is not None
            else None,
            accept_ct=bytes(row["accept_ct"]) if row["accept_ct"] is not None else None,
            accept_mid=row["accept_mid"],
            hub_registered=bool(row["hub_registered"]),
        )

    def set_pair_offer_message_hash(self, offer_id: str, message_hash: str) -> None:
        with self.transaction() as conn:
            cursor = conn.execute(
                "UPDATE pair_offers SET hub_message_hash=?,updated_at_ms=? WHERE offer_id=?",
                (message_hash, self._clock(), offer_id),
            )
            if cursor.rowcount != 1:
                raise StorageNotFound("pairing offer not found")

    def mark_pair_offer_registered(self, offer_id: str) -> None:
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE pair_offers SET hub_registered=1,updated_at_ms=?
                   WHERE offer_id=? AND state='pending'""",
                (self._clock(), offer_id),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("pairing offer is not pending")

    def set_pair_offer_response_hash(self, offer_id: str, response_hash: str) -> None:
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE pair_offers SET hub_response_hash=?,updated_at_ms=?
                   WHERE offer_id=? AND state='confirmed'""",
                (response_hash, self._clock(), offer_id),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("pairing offer is not awaiting PairConfirm")

    def record_pair_accept(
        self,
        *,
        offer_id: str,
        device_id: str,
        enc: bytes,
        ciphertext: bytes,
        response_hash: str,
        accept_mid: str,
        accept_owner: str,
    ) -> PairOfferRecord:
        """Persist the exact PairAccept before publishing it to the Hub."""

        at = self._clock()
        expired = False
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
            ).fetchone()
            if row is None:
                raise StorageNotFound("pairing offer not found")
            if row["expires_at_ms"] <= at and row["state"] in {
                "pending",
                "claimed",
                "confirmed",
            }:
                self._terminalize_pair_offer_in_tx(
                    conn, row=row, terminal_state="expired", at=at
                )
                expired = True
            elif row["state"] == "confirmed":
                if (
                    row["device_id"] == device_id
                    and bytes(row["accept_enc"] or b"") == enc
                    and bytes(row["accept_ct"] or b"") == ciphertext
                    and row["hub_response_hash"] == response_hash
                    and row["accept_mid"] == accept_mid
                ):
                    return self._offer_row(row)
                raise StorageConflict(
                    "PairAccept retry differs from durable ciphertext"
                )
            elif row["state"] != "claimed":
                raise StorageConflict("pairing offer is not claimable")
            elif row["accept_owner"] != accept_owner:
                raise StorageConflict("PairAccept acceptance lease was lost")
            elif row["device_id"] != device_id:
                raise StorageConflict(
                    "PairAccept device differs from durable association"
                )
            if not expired:
                changed = conn.execute(
                    """UPDATE pair_offers SET state='confirmed',accept_enc=?,accept_ct=?,
                       hub_response_hash=?,accept_mid=?,accept_owner=NULL,
                       accept_lease_expires_at_ms=NULL,updated_at_ms=?
                       WHERE offer_id=? AND state='claimed' AND device_id=?
                         AND accept_owner=?""",
                    (
                        enc,
                        ciphertext,
                        response_hash,
                        accept_mid,
                        at,
                        offer_id,
                        device_id,
                        accept_owner,
                    ),
                )
                if changed.rowcount != 1:
                    raise StorageConflict("PairAccept acceptance lease was lost")
            updated = conn.execute(
                "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
            ).fetchone()
        if expired:
            raise StorageExpired("pairing offer expired")
        return self._offer_row(updated)

    def register_device(
        self,
        *,
        name: str,
        route: str,
        kem_public: bytes,
        sign_public: bytes,
        preview_public: bytes,
        device_id: str | None = None,
        kem_generation: int = 1,
        preview_generation: int = 1,
    ) -> DeviceRecord:
        device = device_id or random_id("dev")
        at = self._clock()
        with self.transaction() as conn:
            relay_key = conn.execute(
                "SELECT generation FROM relay_kem_keys WHERE status='current'"
            ).fetchone()
            relay_generation = int(relay_key["generation"]) if relay_key else 1
            conn.execute(
                """INSERT INTO devices
                   (device_id,name,route,status,kem_generation,kem_public,sign_public,
                    preview_generation,preview_public,relay_kem_generation,created_at_ms)
                   VALUES (?,?,?,'pending',?,?,?,?,?,?,?)""",
                (
                    device,
                    name,
                    route,
                    kem_generation,
                    kem_public,
                    sign_public,
                    preview_generation,
                    preview_public,
                    relay_generation,
                    at,
                ),
            )
            for purpose, generation, public in (
                ("kem", kem_generation, kem_public),
                ("sign", 1, sign_public),
                ("preview", preview_generation, preview_public),
            ):
                conn.execute(
                    """INSERT INTO device_keys
                       (device_id,purpose,generation,public_key,status,created_at_ms)
                       VALUES (?,?,?,?,'current',?)""",
                    (device, purpose, generation, public, at),
                )
            conn.execute(
                """INSERT INTO streams
                   (device_id,stream_id,next_seq,acked_through,received_through,
                    checkpoint_revision,created_at_ms,updated_at_ms)
                   VALUES (?,?,1,0,0,0,?,?)""",
                (device, random_id("str"), at, at),
            )
        return self.get_device(device, include_inactive=True)  # type: ignore[return-value]

    def activate_device(self, device_id: str) -> DeviceRecord:
        at = self._clock()
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE devices SET status='active',confirmed_at_ms=?
                   WHERE device_id=? AND status='pending'""",
                (at, device_id),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("device is not pending")
        return self.get_device(device_id)  # type: ignore[return-value]

    def get_device(
        self, device_id: str, *, include_inactive: bool = False
    ) -> DeviceRecord | None:
        query = "SELECT * FROM devices WHERE device_id=?"
        params: tuple[Any, ...] = (device_id,)
        if not include_inactive:
            query += " AND status='active'"
        with self._lock:
            row = self._conn.execute(query, params).fetchone()
        return self._device_row(row) if row else None

    def get_device_by_route(
        self, route: str, *, include_inactive: bool = False
    ) -> DeviceRecord | None:
        query = "SELECT * FROM devices WHERE route=?"
        if not include_inactive:
            query += " AND status='active'"
        with self._lock:
            row = self._conn.execute(query, (route,)).fetchone()
        return self._device_row(row) if row else None

    def active_devices(self) -> list[DeviceRecord]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM devices WHERE status='active' ORDER BY created_at_ms"
            ).fetchall()
        return [self._device_row(row) for row in rows]

    def devices(self) -> list[DeviceRecord]:
        """Return every enrolled device, including pending/revoked tombstones.

        This is an operator/status surface only.  Callers which route content
        must continue to use :meth:`active_devices` so a revoked row can never
        accidentally regain transport authority.
        """

        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM devices ORDER BY created_at_ms,device_id"
            ).fetchall()
        return [self._device_row(row) for row in rows]

    def latest_agent_enrollment(self) -> AgentEnrollmentRecord | None:
        """Return the newest durable Agent enrollment without creating one."""

        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM agent_enrollments ORDER BY created_at_ms DESC LIMIT 1"
            ).fetchone()
        return self._agent_enrollment_row(row) if row else None

    def operational_summary(self) -> dict[str, Any]:
        """Return content-free queue and stream health for ``hermes mobile``.

        No session, prompt, ciphertext, capability, or route identifiers are
        exposed.  The summary is safe for a local status command and keeps the
        CLI out of RelayStorage's private SQLite connection.
        """

        at = self._clock()
        with self._lock:
            outbox_rows = self._conn.execute(
                """SELECT state,COUNT(*) AS count,MIN(created_at_ms) AS oldest
                   FROM outbox GROUP BY state ORDER BY state"""
            ).fetchall()
            stream_rows = self._conn.execute(
                """SELECT d.device_id,s.stream_id,s.next_seq,s.acked_through,
                          s.received_through,s.checkpoint_revision
                   FROM streams s JOIN devices d USING(device_id)
                   ORDER BY d.created_at_ms,d.device_id"""
            ).fetchall()
            last_error = self._conn.execute(
                """SELECT last_error_code FROM outbox
                   WHERE last_error_code IS NOT NULL
                   ORDER BY created_at_ms DESC LIMIT 1"""
            ).fetchone()
        outbox: dict[str, dict[str, int | None]] = {}
        for row in outbox_rows:
            oldest = row["oldest"]
            outbox[row["state"]] = {
                "count": int(row["count"]),
                "oldest_age_ms": max(0, at - int(oldest))
                if oldest is not None
                else None,
            }
        return {
            "outbox": outbox,
            "streams": [
                {
                    "device_id": row["device_id"],
                    "stream_id": row["stream_id"],
                    "next_seq": int(row["next_seq"]),
                    "acked_through": int(row["acked_through"]),
                    "received_through": int(row["received_through"]),
                    "checkpoint_revision": int(row["checkpoint_revision"]),
                }
                for row in stream_rows
            ],
            "last_error_code": last_error["last_error_code"] if last_error else None,
        }

    # -- Agent route enrollment --------------------------------------
    def prepare_agent_enrollment(
        self, auth_public_key: bytes, *, enrollment_id: str | None = None
    ) -> AgentEnrollmentRecord:
        """Persist the exact unauthenticated enrollment request before send.

        A transport error can mean the Hub committed the request.  Reusing the
        newest non-terminal row is therefore mandatory: a fresh identifier
        would create an orphan provisional route.
        """

        if not isinstance(auth_public_key, bytes) or len(auth_public_key) != 32:
            raise ValueError("auth_public_key must be 32 bytes")
        with self._lock:
            row = self._conn.execute(
                """SELECT * FROM agent_enrollments
                   WHERE state IN ('requested','provisional','active')
                   ORDER BY created_at_ms DESC LIMIT 1"""
            ).fetchone()
        if row is not None:
            if bytes(row["auth_public_key"]) != auth_public_key:
                raise StorageConflict("pending enrollment uses a different Agent key")
            return self._agent_enrollment_row(row)
        requested_id = enrollment_id or random_id("enr")
        if not requested_id.startswith("enr_"):
            raise ValueError("enrollment_id must start with enr_")
        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                """INSERT INTO agent_enrollments
                   (enrollment_id,route_type,auth_public_key,state,route_id,
                    expires_at_ms,created_at_ms,updated_at_ms)
                   VALUES (?,'agent',?,'requested',NULL,NULL,?,?)""",
                (requested_id, auth_public_key, at, at),
            )
        return self.agent_enrollment(requested_id)  # type: ignore[return-value]

    def agent_enrollment(self, enrollment_id: str) -> AgentEnrollmentRecord | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM agent_enrollments WHERE enrollment_id=?",
                (enrollment_id,),
            ).fetchone()
        return self._agent_enrollment_row(row) if row else None

    def record_provisional_agent_enrollment(
        self,
        *,
        enrollment_id: str,
        auth_public_key: bytes,
        route_id: str,
        expires_at_ms: int,
    ) -> AgentEnrollmentRecord:
        at = self._clock()
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT * FROM agent_enrollments WHERE enrollment_id=?",
                (enrollment_id,),
            ).fetchone()
            if row is None or bytes(row["auth_public_key"]) != auth_public_key:
                raise StorageConflict("provisional enrollment response changed request")
            if row["state"] not in {"requested", "provisional"}:
                raise StorageConflict("provisional enrollment is terminal")
            if row["route_id"] not in {None, route_id}:
                raise StorageConflict("provisional enrollment route changed")
            conn.execute(
                """UPDATE agent_enrollments SET state='provisional',route_id=?,
                   expires_at_ms=?,updated_at_ms=? WHERE enrollment_id=?""",
                (route_id, expires_at_ms, at, enrollment_id),
            )
            conn.execute(
                """INSERT INTO hub_routes
                   (route_id,kind,status,credential,expires_at_ms,created_at_ms,updated_at_ms)
                   VALUES (?,'agent','provisional',NULL,?,?,?)
                   ON CONFLICT(route_id) DO UPDATE SET status='provisional',
                   expires_at_ms=excluded.expires_at_ms,updated_at_ms=excluded.updated_at_ms""",
                (route_id, expires_at_ms, at, at),
            )
        return self.agent_enrollment(enrollment_id)  # type: ignore[return-value]

    def mark_agent_enrollment(
        self, enrollment_id: str, *, state: str
    ) -> AgentEnrollmentRecord:
        if state not in {"active", "expired", "revoked"}:
            raise ValueError("invalid terminal enrollment state")
        at = self._clock()
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT route_id,state FROM agent_enrollments WHERE enrollment_id=?",
                (enrollment_id,),
            ).fetchone()
            if row is None:
                raise StorageNotFound("Agent enrollment not found")
            if row["state"] == state:
                return self.agent_enrollment(enrollment_id)  # type: ignore[return-value]
            if row["state"] not in {"requested", "provisional"}:
                raise StorageConflict("Agent enrollment is already terminal")
            conn.execute(
                "UPDATE agent_enrollments SET state=?,updated_at_ms=? WHERE enrollment_id=?",
                (state, at, enrollment_id),
            )
            if row["route_id"] is not None:
                conn.execute(
                    "UPDATE hub_routes SET status=?,updated_at_ms=? WHERE route_id=?",
                    (state, at, row["route_id"]),
                )
        return self.agent_enrollment(enrollment_id)  # type: ignore[return-value]

    def mark_agent_route_active(self, route_id: str) -> None:
        """Record successful activation without requiring caller-held nonce."""

        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                """UPDATE agent_enrollments SET state='active',updated_at_ms=?
                   WHERE route_id=? AND state IN ('requested','provisional','active')""",
                (at, route_id),
            )
            conn.execute(
                "UPDATE hub_routes SET status='active',updated_at_ms=? WHERE route_id=?",
                (at, route_id),
            )

    @staticmethod
    def _agent_enrollment_row(row: sqlite3.Row) -> AgentEnrollmentRecord:
        return AgentEnrollmentRecord(
            enrollment_id=row["enrollment_id"],
            auth_public_key=bytes(row["auth_public_key"]),
            state=row["state"],
            route_id=row["route_id"],
            expires_at_ms=row["expires_at_ms"],
        )

    def store_hub_route(
        self,
        *,
        route_id: str,
        kind: str,
        status: str,
        credential: bytes | None = None,
        expires_at_ms: int | None = None,
    ) -> None:
        at = self._clock()
        protected = credential
        if credential is not None and self.credential_protector is not None:
            protected = self.credential_protector.protect(
                f"hub-route:{route_id}", credential
            )
        with self.transaction() as conn:
            conn.execute(
                """INSERT INTO hub_routes
                   (route_id,kind,status,credential,expires_at_ms,created_at_ms,updated_at_ms)
                   VALUES (?,?,?,?,?,?,?) ON CONFLICT(route_id) DO UPDATE SET
                   kind=excluded.kind,status=excluded.status,credential=excluded.credential,
                   expires_at_ms=excluded.expires_at_ms,updated_at_ms=excluded.updated_at_ms""",
                (route_id, kind, status, protected, expires_at_ms, at, at),
            )

    def hub_route(self, route_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM hub_routes WHERE route_id=?", (route_id,)
            ).fetchone()
        if row is None:
            return None
        credential = bytes(row["credential"]) if row["credential"] is not None else None
        if credential is not None and self.credential_protector is not None:
            credential = self.credential_protector.reveal(credential)
        return {
            "route_id": row["route_id"],
            "kind": row["kind"],
            "status": row["status"],
            "credential": credential,
            "expires_at_ms": row["expires_at_ms"],
        }

    def store_hub_grant(
        self,
        *,
        grant_id: str,
        device_id: str,
        source_route: str,
        destination_route: str,
        permissions: Sequence[str],
        issuer_signature: bytes,
        status: str,
    ) -> None:
        if status not in {"pending", "active", "revoked"}:
            raise ValueError("invalid grant status")
        encoded_permissions = canonical_json(list(permissions))
        with self.transaction() as conn:
            conn.execute(
                """INSERT INTO hub_grants
                   (grant_id,device_id,source_route,destination_route,permissions_json,
                    issuer_signature,status,created_at_ms)
                   VALUES (?,?,?,?,?,?,?,?) ON CONFLICT(grant_id) DO UPDATE SET
                   status=excluded.status""",
                (
                    grant_id,
                    device_id,
                    source_route,
                    destination_route,
                    encoded_permissions,
                    issuer_signature,
                    status,
                    self._clock(),
                ),
            )

    def hub_grants_for_device(self, device_id: str) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM hub_grants WHERE device_id=? ORDER BY grant_id",
                (device_id,),
            ).fetchall()
        return [
            {
                "grant_id": row["grant_id"],
                "source_route": row["source_route"],
                "destination_route": row["destination_route"],
                "permissions": json.loads(bytes(row["permissions_json"])),
                "issuer_signature": bytes(row["issuer_signature"]),
                "status": row["status"],
            }
            for row in rows
        ]

    def commit_pair_confirm(
        self,
        *,
        offer_id: str,
        device_id: str,
        response_hash: str,
        grant_ids: Sequence[str],
    ) -> DeviceRecord:
        """Atomically activate all local enrollment authority after Hub CAS."""

        if len(grant_ids) != 2 or len(set(grant_ids)) != 2:
            raise StorageConflict("PairConfirm must activate two grants")
        at = self._clock()
        with self.transaction() as conn:
            offer = conn.execute(
                "SELECT * FROM pair_offers WHERE offer_id=?", (offer_id,)
            ).fetchone()
            if offer is None:
                raise StorageNotFound("pairing offer not found")
            if (
                offer["state"] != "confirmed"
                or offer["device_id"] != device_id
                or offer["hub_response_hash"] != response_hash
            ):
                raise StorageConflict("PairConfirm does not match PairAccept")
            device = conn.execute(
                "SELECT route,status FROM devices WHERE device_id=?", (device_id,)
            ).fetchone()
            if device is None or device["status"] != "pending":
                raise StorageConflict("device is not pending")
            rows = conn.execute(
                "SELECT grant_id,status FROM hub_grants WHERE device_id=?", (device_id,)
            ).fetchall()
            found = {row["grant_id"] for row in rows if row["status"] == "pending"}
            if found != set(grant_ids):
                raise StorageConflict(
                    "Hub grant set does not match local pending grants"
                )
            conn.execute(
                "UPDATE devices SET status='active',confirmed_at_ms=? WHERE device_id=?",
                (at, device_id),
            )
            conn.execute(
                "UPDATE hub_routes SET status='active',updated_at_ms=? WHERE route_id=?",
                (at, device["route"]),
            )
            conn.execute(
                "UPDATE hub_grants SET status='active' WHERE device_id=?",
                (device_id,),
            )
            conn.execute(
                """UPDATE pair_offers SET state='consumed',pair_secret=X'',transport_token='',
                   updated_at_ms=? WHERE offer_id=?""",
                (at, offer_id),
            )
        return self.get_device(device_id)  # type: ignore[return-value]

    def revoke_device(
        self,
        device_id: str,
        *,
        inbound_message_id: str | None = None,
        inbound_expires_at_ms: int | None = None,
    ) -> bool:
        if (inbound_message_id is None) != (inbound_expires_at_ms is None):
            raise ValueError("inbound revoke receipt fields must be supplied together")
        at = self._clock()
        with self._lock:
            binding = self._conn.execute(
                "SELECT send_capability FROM push_bindings WHERE device_id=? AND status='active'",
                (device_id,),
            ).fetchone()
        if binding is not None and self.credential_protector is not None:
            self.credential_protector.delete(bytes(binding["send_capability"]))
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE devices SET status='revoked',revoked_at_ms=?
                   WHERE device_id=? AND status!='revoked'""",
                (at, device_id),
            )
            conn.execute(
                "UPDATE device_keys SET status='revoked' WHERE device_id=?",
                (device_id,),
            )
            conn.execute(
                "UPDATE hub_routes SET status='revoked',updated_at_ms=? "
                "WHERE route_id=(SELECT route FROM devices WHERE device_id=?)",
                (at, device_id),
            )
            conn.execute(
                "UPDATE hub_grants SET status='revoked' WHERE device_id=?",
                (device_id,),
            )
            conn.execute(
                "UPDATE approval_capabilities SET state='revoked',updated_at_ms=? "
                "WHERE device_id=? AND state IN ('pending','claimed','failed_retryable')",
                (at, device_id),
            )
            conn.execute(
                """UPDATE push_bindings SET status='revoked',send_capability=X'',updated_at_ms=?
                   WHERE device_id=?""",
                (at, device_id),
            )
            conn.execute(
                """UPDATE notification_outbox
                   SET state='failed',last_error_code='device_revoked',updated_at_ms=?
                   WHERE device_id=? AND state='pending'""",
                (at, device_id),
            )
            conn.execute(
                """UPDATE inbound_delivery_receipts SET state='failed',updated_at_ms=?
                   WHERE device_id=? AND state='pending'""",
                (at, device_id),
            )
            conn.execute(
                """UPDATE push_binding_exchanges SET state='revoked',bind_token=X'',
                   updated_at_ms=? WHERE device_id=?""",
                (at, device_id),
            )
            if inbound_message_id is not None:
                conn.execute(
                    """INSERT OR IGNORE INTO seen_messages
                       (device_id,message_id,received_at_ms,expires_at_ms)
                       VALUES (?,?,?,?)""",
                    (device_id, inbound_message_id, at, inbound_expires_at_ms),
                )
            return cursor.rowcount == 1

    def rotate_device_key(
        self,
        device_id: str,
        *,
        purpose: str,
        generation: int,
        public_key: bytes,
        previous_not_after_ms: int,
    ) -> None:
        if purpose not in {"kem", "preview"}:
            raise ValueError("only KEM keys rotate by generation")
        column = "kem" if purpose == "kem" else "preview"
        at = self._clock()
        with self.transaction() as conn:
            row = conn.execute(
                f"SELECT {column}_generation,{column}_public,status FROM devices WHERE device_id=?",
                (device_id,),
            ).fetchone()
            if row is None:
                raise StorageNotFound("device not found")
            if row["status"] != "active":
                raise StorageConflict("device is not active")
            current_generation = int(row[f"{column}_generation"])
            if generation == current_generation:
                previous = conn.execute(
                    """SELECT not_after_ms FROM device_keys
                       WHERE device_id=? AND purpose=? AND generation=?""",
                    (device_id, purpose, generation - 1),
                ).fetchone()
                if (
                    bytes(row[f"{column}_public"]) == public_key
                    and previous is not None
                    and previous["not_after_ms"] == previous_not_after_ms
                ):
                    return
                raise StorageConflict("key rotation retry changed request")
            if generation != current_generation + 1:
                raise StorageConflict("key generation must increase by exactly one")
            conn.execute(
                """UPDATE device_keys SET status='previous',not_after_ms=?
                   WHERE device_id=? AND purpose=? AND status='current'""",
                (previous_not_after_ms, device_id, purpose),
            )
            conn.execute(
                """INSERT INTO device_keys
                   (device_id,purpose,generation,public_key,status,created_at_ms)
                   VALUES (?,?,?,?,'current',?)""",
                (device_id, purpose, generation, public_key, at),
            )
            conn.execute(
                f"UPDATE devices SET {column}_generation=?,{column}_public=? WHERE device_id=?",
                (generation, public_key, device_id),
            )
            if purpose == "kem":
                conn.execute(
                    """UPDATE approval_capabilities SET state='revoked',updated_at_ms=?
                       WHERE device_id=? AND device_generation<?
                       AND state IN ('pending','claimed','failed_retryable')""",
                    (at, device_id, generation),
                )

    def device_public_kem_generations(self, device_id: str) -> dict[int, bytes]:
        with self._lock:
            rows = self._conn.execute(
                """SELECT generation,public_key FROM device_keys
                   WHERE device_id=? AND purpose='kem' AND status IN ('current','previous')
                   ORDER BY generation""",
                (device_id,),
            ).fetchall()
        return {int(row["generation"]): bytes(row["public_key"]) for row in rows}

    @staticmethod
    def _device_row(row: sqlite3.Row) -> DeviceRecord:
        return DeviceRecord(
            device_id=row["device_id"],
            name=row["name"],
            route=row["route"],
            status=row["status"],
            kem_generation=row["kem_generation"],
            kem_public=bytes(row["kem_public"]),
            sign_public=bytes(row["sign_public"]),
            preview_generation=row["preview_generation"],
            preview_public=bytes(row["preview_public"]),
            relay_kem_generation=row["relay_kem_generation"],
            created_at_ms=row["created_at_ms"],
            confirmed_at_ms=row["confirmed_at_ms"],
            revoked_at_ms=row["revoked_at_ms"],
            re_pair_required=bool(row["re_pair_required"]),
            status_reason=row["status_reason"],
            hub_revocation_state=row["hub_revocation_state"],
            hub_revocation_attempts=int(row["hub_revocation_attempts"]),
            hub_revocation_last_error=row["hub_revocation_last_error"],
        )

    # -- durable per-device streams/outbox -----------------------------
    def get_stream(self, device_id: str) -> StreamRecord:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM streams WHERE device_id=?", (device_id,)
            ).fetchone()
        if row is None:
            raise StorageNotFound("device stream not found")
        return self._stream_row(row)

    @staticmethod
    def _stream_row(row: sqlite3.Row) -> StreamRecord:
        return StreamRecord(
            device_id=row["device_id"],
            stream_id=row["stream_id"],
            next_seq=row["next_seq"],
            acked_through=row["acked_through"],
            received_through=row["received_through"],
            checkpoint_revision=row["checkpoint_revision"],
        )

    def enqueue_frames(
        self,
        device_id: str,
        frames: Sequence[Mapping[str, Any]],
        envelope_factory: Callable[
            [str, int, Sequence[Mapping[str, Any]]], Mapping[str, Any]
        ],
        *,
        message_class: str = "state",
        expires_at_ms: int | None = None,
    ) -> OutboxRecord:
        """Allocate sequence numbers and persist the exact ciphertext atomically.

        ``envelope_factory`` is invoked once, inside the transaction, with the
        durable stream ID and first sequence.  Retries read ``envelope_json``;
        they never re-encrypt or allocate a new message ID.
        """

        if not frames:
            raise ValueError("cannot enqueue an empty frame batch")
        at = self._clock()
        expiry = expires_at_ms or at + DEFAULT_MAILBOX_TTL_MS
        _int64(expiry, field="expires_at_ms")
        with self.transaction() as conn:
            stream = conn.execute(
                "SELECT * FROM streams WHERE device_id=?", (device_id,)
            ).fetchone()
            if stream is None:
                raise StorageNotFound("device stream not found")
            device = conn.execute(
                "SELECT status FROM devices WHERE device_id=?", (device_id,)
            ).fetchone()
            if device is None or device["status"] != "active":
                raise StorageConflict("device is not active")
            first = int(stream["next_seq"])
            _int64(first, field="first_seq", minimum=1)
            last = first + len(frames) - 1
            # ``next_seq`` itself is persisted and later sent on the wire, so
            # allocating the maximum would require an unsafe JSON max + 1.
            if last >= MAX_WIRE_INTEGER:
                raise StorageConflict("stream sequence space is exhausted")
            envelope = dict(envelope_factory(stream["stream_id"], first, frames))
            mid = envelope.get("mid")
            if not isinstance(mid, str) or not mid:
                raise ValueError("envelope_factory must return a non-empty mid")
            encoded = json.dumps(
                envelope, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ).encode("utf-8")
            conn.execute(
                "UPDATE streams SET next_seq=?,updated_at_ms=? WHERE device_id=?",
                (last + 1, at, device_id),
            )
            conn.execute(
                """INSERT INTO outbox
                   (device_id,message_id,first_seq,last_seq,message_class,envelope_json,
                    state,created_at_ms,expires_at_ms,receipt_kind,completion_policy)
                   VALUES (?,?,?,?,?,?,'pending',?,?,'stream','stream_ack')""",
                (device_id, mid, first, last, message_class, encoded, at, expiry),
            )
        return OutboxRecord(
            device_id,
            mid,
            first,
            last,
            message_class,
            envelope,
            "pending",
            at,
            expiry,
            0,
            "stream",
            "stream_ack",
        )

    def enqueue_stream_checkpoint(
        self,
        device_id: str,
        envelope_factory: Callable[[str, int, int], Mapping[str, Any]],
        *,
        message_class: str = "state",
        expires_at_ms: int | None = None,
    ) -> OutboxRecord:
        """Persist an authoritative checkpoint at the current stream boundary.

        A checkpoint is deliberately *not* assigned a new sequence number.  A
        device requesting recovery is already unable to consume a sequenced
        batch beyond its gap; the standalone checkpoint advances it through
        the last allocated sequence and the next live frame remains exactly
        ``through_seq + 1``.  The factory runs inside the same transaction as
        the boundary read so projection, ciphertext, and ACK semantics cannot
        be paired with a later sequence allocation.
        """

        at = self._clock()
        expiry = expires_at_ms or at + DEFAULT_MAILBOX_TTL_MS
        _int64(expiry, field="expires_at_ms")
        with self.transaction() as conn:
            stream = conn.execute(
                "SELECT * FROM streams WHERE device_id=?", (device_id,)
            ).fetchone()
            if stream is None:
                raise StorageNotFound("device stream not found")
            device = conn.execute(
                "SELECT status FROM devices WHERE device_id=?", (device_id,)
            ).fetchone()
            if device is None or device["status"] != "active":
                raise StorageConflict("device is not active")
            through = int(stream["next_seq"]) - 1
            _int64(through, field="through_seq")
            if int(stream["checkpoint_revision"]) >= MAX_WIRE_INTEGER:
                raise StorageConflict("checkpoint revision space is exhausted")
            checkpoint_revision = int(stream["checkpoint_revision"]) + 1
            envelope = dict(
                envelope_factory(stream["stream_id"], through, checkpoint_revision)
            )
            mid = envelope.get("mid")
            if not isinstance(mid, str) or not mid:
                raise ValueError("envelope_factory must return a non-empty mid")
            encoded = json.dumps(
                envelope, ensure_ascii=False, separators=(",", ":"), sort_keys=True
            ).encode("utf-8")
            conn.execute(
                "UPDATE streams SET checkpoint_revision=?,updated_at_ms=? WHERE device_id=?",
                (checkpoint_revision, at, device_id),
            )
            conn.execute(
                """INSERT INTO outbox
                   (device_id,message_id,first_seq,last_seq,message_class,envelope_json,
                    state,created_at_ms,expires_at_ms,receipt_kind,completion_policy)
                   VALUES (?,?,?,?,?,?,'pending',?,?,'stream','stream_ack')""",
                (device_id, mid, through, through, message_class, encoded, at, expiry),
            )
        return OutboxRecord(
            device_id,
            mid,
            through,
            through,
            message_class,
            envelope,
            "pending",
            at,
            expiry,
            0,
            "stream",
            "stream_ack",
        )

    def enqueue_envelope(
        self,
        device_id: str,
        envelope: Mapping[str, Any],
        *,
        message_class: str,
        expires_at_ms: int,
    ) -> OutboxRecord:
        """Persist a non-stream secure message until its E2EE receipt."""

        mid = envelope.get("mid")
        if not isinstance(mid, str) or not mid:
            raise ValueError("envelope must contain a message ID")
        encoded = json.dumps(
            dict(envelope), ensure_ascii=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        at = self._clock()
        _int64(expires_at_ms, field="expires_at_ms")
        with self.transaction() as conn:
            device = conn.execute(
                "SELECT status FROM devices WHERE device_id=?", (device_id,)
            ).fetchone()
            if device is None or device["status"] != "active":
                raise StorageConflict("device is not active")
            conn.execute(
                """INSERT INTO outbox
                   (device_id,message_id,first_seq,last_seq,message_class,envelope_json,
                    state,created_at_ms,expires_at_ms,receipt_kind,completion_policy)
                   VALUES (?,?,0,0,?,?,'pending',?,?,'delivery','inner_receipt')""",
                (device_id, mid, message_class, encoded, at, expires_at_ms),
            )
        return OutboxRecord(
            device_id,
            mid,
            0,
            0,
            message_class,
            dict(envelope),
            "pending",
            at,
            expires_at_ms,
            0,
            "delivery",
            "inner_receipt",
        )

    def enqueue_inbound_delivery_receipt(
        self,
        device_id: str,
        inbound_message_id: str,
        envelope: Mapping[str, Any],
        *,
        message_class: str,
        expires_at_ms: int,
    ) -> tuple[InboundDeliveryReceiptRecord, OutboxRecord | None, bool]:
        """Atomically bind one inbound message to its exact outbound receipt.

        The semantic binding survives deletion of the ciphertext after the Hub
        has durably stored it.  A replay therefore either re-offers the exact
        pending envelope or observes the completed binding; it can never mint
        a second authenticated receipt for the same inbound message.
        """

        mid = envelope.get("mid")
        if not isinstance(inbound_message_id, str) or not inbound_message_id:
            raise ValueError("inbound_message_id must be non-empty")
        if not isinstance(mid, str) or not mid:
            raise ValueError("envelope must contain a message ID")
        encoded = json.dumps(
            dict(envelope), ensure_ascii=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        at = self._clock()
        _int64(expires_at_ms, field="expires_at_ms")
        with self.transaction() as conn:
            existing = conn.execute(
                """SELECT * FROM inbound_delivery_receipts
                   WHERE device_id=? AND inbound_message_id=?""",
                (device_id, inbound_message_id),
            ).fetchone()
            if existing is not None:
                link = self._inbound_delivery_receipt_row(existing)
                if link.state != "pending":
                    return link, None, False
                row = conn.execute(
                    "SELECT * FROM outbox WHERE device_id=? AND message_id=?",
                    (device_id, link.outbound_message_id),
                ).fetchone()
                if row is None:
                    raise StorageConflict(
                        "pending delivery receipt lost its outbox row"
                    )
                return link, self._outbox_row(row), False
            device = conn.execute(
                "SELECT status FROM devices WHERE device_id=?", (device_id,)
            ).fetchone()
            if device is None or device["status"] != "active":
                raise StorageConflict("device is not active")
            conn.execute(
                """INSERT INTO outbox
                   (device_id,message_id,first_seq,last_seq,message_class,envelope_json,
                    state,created_at_ms,expires_at_ms,receipt_kind,completion_policy)
                   VALUES (?,?,0,0,?,?,'pending',?,?,'delivery','hub_accept')""",
                (device_id, mid, message_class, encoded, at, expires_at_ms),
            )
            conn.execute(
                """INSERT INTO inbound_delivery_receipts
                   (device_id,inbound_message_id,outbound_message_id,state,
                    created_at_ms,updated_at_ms,expires_at_ms)
                   VALUES (?,?,?,'pending',?,?,?)""",
                (
                    device_id,
                    inbound_message_id,
                    mid,
                    at,
                    at,
                    expires_at_ms,
                ),
            )
            link_row = conn.execute(
                """SELECT * FROM inbound_delivery_receipts
                   WHERE device_id=? AND inbound_message_id=?""",
                (device_id, inbound_message_id),
            ).fetchone()
            outbox_row = conn.execute(
                "SELECT * FROM outbox WHERE device_id=? AND message_id=?",
                (device_id, mid),
            ).fetchone()
        return (
            self._inbound_delivery_receipt_row(link_row),
            self._outbox_row(outbox_row),
            True,
        )

    def inbound_delivery_receipt(
        self, device_id: str, inbound_message_id: str
    ) -> InboundDeliveryReceiptRecord | None:
        with self._lock:
            row = self._conn.execute(
                """SELECT * FROM inbound_delivery_receipts
                   WHERE device_id=? AND inbound_message_id=?""",
                (device_id, inbound_message_id),
            ).fetchone()
        return self._inbound_delivery_receipt_row(row) if row is not None else None

    @staticmethod
    def _inbound_delivery_receipt_row(
        row: sqlite3.Row,
    ) -> InboundDeliveryReceiptRecord:
        return InboundDeliveryReceiptRecord(
            device_id=row["device_id"],
            inbound_message_id=row["inbound_message_id"],
            outbound_message_id=row["outbound_message_id"],
            state=row["state"],
            created_at_ms=row["created_at_ms"],
            updated_at_ms=row["updated_at_ms"],
            expires_at_ms=row["expires_at_ms"],
        )

    def outbox_record(self, device_id: str, message_id: str) -> OutboxRecord | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM outbox WHERE device_id=? AND message_id=?",
                (device_id, message_id),
            ).fetchone()
        return self._outbox_row(row) if row is not None else None

    def complete_hub_accept_delivery_receipt(
        self, device_id: str, outbound_message_id: str
    ) -> bool:
        """Commit Hub storage and delete only the transport-complete receipt."""

        at = self._clock()
        with self.transaction() as conn:
            link = conn.execute(
                """SELECT state FROM inbound_delivery_receipts
                   WHERE device_id=? AND outbound_message_id=?""",
                (device_id, outbound_message_id),
            ).fetchone()
            if link is None:
                raise StorageConflict("delivery receipt has no semantic binding")
            if link["state"] == "hub_accepted":
                conn.execute(
                    """DELETE FROM outbox WHERE device_id=? AND message_id=?
                       AND completion_policy='hub_accept'""",
                    (device_id, outbound_message_id),
                )
                return False
            if link["state"] != "pending":
                raise StorageConflict("delivery receipt is terminal")
            row = conn.execute(
                """SELECT 1 FROM outbox WHERE device_id=? AND message_id=?
                   AND completion_policy='hub_accept'""",
                (device_id, outbound_message_id),
            ).fetchone()
            if row is None:
                raise StorageConflict("pending delivery receipt lost its outbox row")
            conn.execute(
                """UPDATE inbound_delivery_receipts
                   SET state='hub_accepted',updated_at_ms=?
                   WHERE device_id=? AND outbound_message_id=? AND state='pending'""",
                (at, device_id, outbound_message_id),
            )
            conn.execute(
                """DELETE FROM outbox WHERE device_id=? AND message_id=?
                   AND completion_policy='hub_accept'""",
                (device_id, outbound_message_id),
            )
            return True

    def pending_outbox(self, device_id: str, *, limit: int = 256) -> list[OutboxRecord]:
        with self._lock:
            rows = self._conn.execute(
                """SELECT * FROM outbox WHERE device_id=?
                   AND state IN ('pending','hub_accepted')
                   ORDER BY created_at_ms,rowid LIMIT ?""",
                (device_id, limit),
            ).fetchall()
        return [self._outbox_row(row) for row in rows]

    @staticmethod
    def _outbox_row(row: sqlite3.Row) -> OutboxRecord:
        return OutboxRecord(
            device_id=row["device_id"],
            message_id=row["message_id"],
            first_seq=row["first_seq"],
            last_seq=row["last_seq"],
            message_class=row["message_class"],
            envelope=json.loads(bytes(row["envelope_json"])),
            state=row["state"],
            created_at_ms=row["created_at_ms"],
            expires_at_ms=row["expires_at_ms"],
            attempts=row["attempts"],
            receipt_kind=row["receipt_kind"],
            completion_policy=row["completion_policy"],
            activates_relay_kem_generation=row["activates_relay_kem_generation"],
        )

    def mark_hub_accepted(self, device_id: str, message_id: str) -> None:
        with self.transaction() as conn:
            conn.execute(
                """UPDATE outbox SET state='hub_accepted',attempts=attempts+1,last_error_code=NULL
                   WHERE device_id=? AND message_id=? AND state='pending'""",
                (device_id, message_id),
            )

    def mark_send_failed(
        self, device_id: str, message_id: str, error_code: str
    ) -> None:
        with self.transaction() as conn:
            conn.execute(
                """UPDATE outbox SET attempts=attempts+1,last_error_code=?
                   WHERE device_id=? AND message_id=?
                     AND state IN ('pending','hub_accepted')""",
                (error_code, device_id, message_id),
            )

    def mark_send_terminal(
        self, device_id: str, message_id: str, error_code: str
    ) -> None:
        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                """UPDATE outbox SET state='failed',attempts=attempts+1,last_error_code=?
                   WHERE device_id=? AND message_id=?
                   AND state IN ('pending','hub_accepted')""",
                (error_code, device_id, message_id),
            )
            conn.execute(
                """UPDATE inbound_delivery_receipts SET state='failed',updated_at_ms=?
                   WHERE device_id=? AND outbound_message_id=? AND state='pending'""",
                (at, device_id, message_id),
            )

    def discard_realtime(self, device_id: str, message_id: str) -> bool:
        """Remove a best-effort realtime row after dispatch or lane failure.

        Realtime ciphertext is never an offline mailbox source of truth.  Its
        allocated sequence remains durable in ``streams`` so a later state
        frame exposes the gap and forces convergence through a checkpoint.
        """

        with self.transaction() as conn:
            cursor = conn.execute(
                """DELETE FROM outbox WHERE device_id=? AND message_id=?
                   AND message_class='realtime' AND receipt_kind='stream'""",
                (device_id, message_id),
            )
            return cursor.rowcount == 1

    def acknowledge_stream(self, device_id: str, through_seq: int) -> int:
        through_seq = _int64(through_seq, field="through_seq")
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT acked_through,next_seq FROM streams WHERE device_id=?",
                (device_id,),
            ).fetchone()
            if row is None:
                raise StorageNotFound("device stream not found")
            if through_seq >= row["next_seq"]:
                raise StorageConflict("acknowledgement is beyond allocated stream")
            if through_seq > row["acked_through"]:
                conn.execute(
                    "UPDATE streams SET acked_through=?,updated_at_ms=? WHERE device_id=?",
                    (through_seq, self._clock(), device_id),
                )
            # Delete even for an idempotent/boundary-zero ACK: a standalone
            # checkpoint can be persisted after the watermark already reached
            # its through_seq, and it uses the stream receipt contract.
            cursor = conn.execute(
                """DELETE FROM outbox WHERE device_id=? AND receipt_kind='stream'
                   AND completion_policy='stream_ack' AND last_seq<=?""",
                (device_id, through_seq),
            )
            return cursor.rowcount

    def acknowledge_delivery(self, device_id: str, message_id: str) -> bool:
        """Durably retain a content-free exact-receipt tombstone.

        The inbound replay ledger is committed immediately afterwards by its
        caller.  If the process dies in that narrow gap, replaying the same
        receipt still succeeds instead of pinning an un-ACKable Hub message.
        """

        with self.transaction() as conn:
            row = conn.execute(
                """SELECT state,activates_relay_kem_generation FROM outbox
                   WHERE device_id=? AND message_id=? AND receipt_kind='delivery'
                   AND completion_policy='inner_receipt'""",
                (device_id, message_id),
            ).fetchone()
            if row is None:
                return False
            activates_generation = row["activates_relay_kem_generation"]
            if activates_generation is not None:
                device = conn.execute(
                    "SELECT relay_kem_generation,status FROM devices WHERE device_id=?",
                    (device_id,),
                ).fetchone()
                if device is None or device["status"] != "active":
                    raise StorageConflict("device is not active")
                current = int(device["relay_kem_generation"])
                target = int(activates_generation)
                if target > current + 1:
                    raise StorageConflict(
                        "relay KEM acknowledgement skipped a generation"
                    )
                if target > current:
                    conn.execute(
                        "UPDATE devices SET relay_kem_generation=? WHERE device_id=?",
                        (target, device_id),
                    )
            if row["state"] != "delivered":
                conn.execute(
                    """UPDATE outbox SET state='delivered',envelope_json=X'7B7D',
                       last_error_code=NULL WHERE device_id=? AND message_id=?""",
                    (device_id, message_id),
                )
            return True

    def has_seen_message(self, device_id: str, message_id: str) -> bool:
        with self._lock:
            return (
                self._conn.execute(
                    "SELECT 1 FROM seen_messages WHERE device_id=? AND message_id=?",
                    (device_id, message_id),
                ).fetchone()
                is not None
            )

    def mark_seen_message(
        self, device_id: str, message_id: str, *, expires_at_ms: int
    ) -> bool:
        at = self._clock()
        with self.transaction() as conn:
            cursor = conn.execute(
                """INSERT OR IGNORE INTO seen_messages
                   (device_id,message_id,received_at_ms,expires_at_ms) VALUES (?,?,?,?)""",
                (device_id, message_id, at, expires_at_ms),
            )
            return cursor.rowcount == 1

    def commit_inbound_batch(
        self,
        device_id: str,
        message_id: str,
        *,
        stream_id: str,
        first_seq: int,
        frame_count: int,
        expires_at_ms: int,
        apply: Callable[[sqlite3.Connection], None] | None = None,
    ) -> bool:
        """Commit replay admission, frames and watermark in one transaction.

        Returns ``False`` for an already committed message.  It never calls
        ``apply`` for duplicates or gaps.
        """

        if (
            isinstance(frame_count, bool)
            or not isinstance(frame_count, int)
            or frame_count < 1
        ):
            raise ValueError("frame_count must be positive")
        first_seq = _int64(first_seq, field="first_seq", minimum=1)
        at = self._clock()
        _int64(expires_at_ms, field="expires_at_ms")
        if expires_at_ms <= at:
            raise StorageExpired("message expired")
        with self.transaction() as conn:
            if conn.execute(
                "SELECT 1 FROM seen_messages WHERE device_id=? AND message_id=?",
                (device_id, message_id),
            ).fetchone():
                return False
            row = conn.execute(
                "SELECT stream_id,received_through FROM streams WHERE device_id=?",
                (device_id,),
            ).fetchone()
            if row is None:
                raise StorageNotFound("device stream not found")
            if row["stream_id"] != stream_id:
                raise StorageConflict("stream_id mismatch")
            expected = row["received_through"] + 1
            if first_seq != expected:
                raise StreamGap(expected, first_seq)
            if apply is not None:
                apply(conn)
            through = first_seq + frame_count - 1
            _int64(through, field="through_seq")
            conn.execute(
                "UPDATE streams SET received_through=?,updated_at_ms=? WHERE device_id=?",
                (through, at, device_id),
            )
            conn.execute(
                """INSERT INTO seen_messages
                   (device_id,message_id,received_at_ms,expires_at_ms) VALUES (?,?,?,?)""",
                (device_id, message_id, at, expires_at_ms),
            )
            return True

    def prune_seen_messages(self) -> int:
        with self.transaction() as conn:
            cursor = conn.execute(
                "DELETE FROM seen_messages WHERE expires_at_ms<=?", (self._clock(),)
            )
            return cursor.rowcount

    # -- operation ledger ---------------------------------------------
    def begin_operation(
        self,
        device_id: str,
        op_id: str,
        method: str,
        params: Mapping[str, Any],
    ) -> OperationRecord:
        request_hash = canonical_request_hash(method, params)
        at = self._clock()
        with self.transaction() as conn:
            row = conn.execute(
                "SELECT * FROM operations WHERE device_id=? AND op_id=?",
                (device_id, op_id),
            ).fetchone()
            if row:
                if not secrets.compare_digest(bytes(row["request_hash"]), request_hash):
                    raise StorageConflict("op_id reused with different request")
                return self._operation_row(row)
            conn.execute(
                """INSERT INTO operations
                   (device_id,op_id,request_hash,method,state,created_at_ms,updated_at_ms)
                   VALUES (?,?,?,?,'received',?,?)""",
                (device_id, op_id, request_hash, method, at, at),
            )
        return OperationRecord(
            device_id, op_id, request_hash, method, "received", None, None, at, at
        )

    def mark_operation_executing(self, device_id: str, op_id: str) -> None:
        self._transition_operation(device_id, op_id, "received", "executing")

    def complete_operation(
        self,
        device_id: str,
        op_id: str,
        response: Mapping[str, Any],
    ) -> None:
        payload = json.dumps(
            dict(response), ensure_ascii=False, separators=(",", ":"), sort_keys=True
        ).encode("utf-8")
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE operations SET state='succeeded',response_json=?,error_code=NULL,
                   updated_at_ms=? WHERE device_id=? AND op_id=? AND state='executing'""",
                (payload, self._clock(), device_id, op_id),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("operation is not executing")

    def fail_operation(
        self,
        device_id: str,
        op_id: str,
        error_code: str,
        *,
        ambiguous: bool = False,
    ) -> None:
        new_state = "ambiguous" if ambiguous else "failed"
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE operations SET state=?,error_code=?,updated_at_ms=?
                   WHERE device_id=? AND op_id=? AND state IN ('received','executing')""",
                (new_state, error_code, self._clock(), device_id, op_id),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("operation is already terminal")

    def get_operation(self, device_id: str, op_id: str) -> OperationRecord | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM operations WHERE device_id=? AND op_id=?",
                (device_id, op_id),
            ).fetchone()
        return self._operation_row(row) if row else None

    def retry_ambiguous_operation(self, device_id: str, op_id: str) -> None:
        self._transition_operation(device_id, op_id, "ambiguous", "received")

    # -- approval capabilities ----------------------------------------
    def create_approval_capabilities(
        self,
        *,
        request_id: str,
        session_id: str,
        expires_at_ms: int,
        device_ids: Sequence[str] | None = None,
        allowed_decisions: Sequence[str] = ("approve_once", "deny"),
    ) -> dict[str, str]:
        allowed = sorted(set(allowed_decisions))
        if not allowed or not set(allowed).issubset({"approve_once", "deny"}):
            raise ValueError("approval capability has invalid decisions")
        at = self._clock()
        if expires_at_ms <= at:
            raise StorageExpired("approval request already expired")
        requested = set(device_ids) if device_ids is not None else None
        protected_tokens: list[bytes] = []
        try:
            with self.transaction() as conn:
                existing = conn.execute(
                    "SELECT session_id,state,expires_at_ms FROM approval_requests WHERE request_id=?",
                    (request_id,),
                ).fetchone()
                if existing is not None:
                    if (
                        existing["session_id"] != session_id
                        or int(existing["expires_at_ms"]) != expires_at_ms
                        or existing["state"] != "pending"
                    ):
                        raise StorageConflict("approval request already registered")
                    capability_rows = conn.execute(
                        """SELECT device_id,capability_secret,allowed_decisions_json
                           FROM approval_capabilities WHERE request_id=?
                           ORDER BY device_id""",
                        (request_id,),
                    ).fetchall()
                    existing_ids = {row["device_id"] for row in capability_rows}
                    if requested is not None and existing_ids != requested:
                        raise StorageConflict("approval request targets changed")
                    tokens: dict[str, str] = {}
                    for row in capability_rows:
                        if json.loads(bytes(row["allowed_decisions_json"])) != allowed:
                            raise StorageConflict("approval request decisions changed")
                        if row["capability_secret"] is None:
                            raise StorageConflict(
                                "approval capability is not recoverable"
                            )
                        wrapped = bytes(row["capability_secret"])
                        raw = (
                            self.credential_protector.reveal(wrapped)
                            if self.credential_protector is not None
                            else wrapped
                        )
                        tokens[row["device_id"]] = b64url_encode(raw)
                    return tokens
                rows = conn.execute(
                    """SELECT device_id,kem_generation FROM devices
                       WHERE status='active' ORDER BY device_id"""
                ).fetchall()
                selected = [
                    row
                    for row in rows
                    if requested is None or row["device_id"] in requested
                ]
                if (
                    requested is not None
                    and {row["device_id"] for row in selected} != requested
                ):
                    raise StorageNotFound("approval target device not active")
                conn.execute(
                    """INSERT INTO approval_requests
                       (request_id,session_id,state,expires_at_ms,updated_at_ms)
                       VALUES (?,?,'pending',?,?)""",
                    (request_id, session_id, expires_at_ms, at),
                )
                tokens = {}
                for row in selected:
                    raw = secrets.token_bytes(32)
                    token = b64url_encode(raw)
                    protected = raw
                    if self.credential_protector is not None:
                        protected = self.credential_protector.protect(
                            f"approval:{request_id}:{row['device_id']}", raw
                        )
                        protected_tokens.append(protected)
                    conn.execute(
                        """INSERT INTO approval_capabilities
                           (capability_hash,capability_secret,request_id,device_id,
                            device_generation,allowed_decisions_json,expires_at_ms,state,
                            created_at_ms,updated_at_ms)
                           VALUES (?,?,?,?,?,?,?,'pending',?,?)""",
                        (
                            hashlib.sha256(raw).digest(),
                            protected,
                            request_id,
                            row["device_id"],
                            row["kem_generation"],
                            canonical_json(allowed),
                            expires_at_ms,
                            at,
                            at,
                        ),
                    )
                    tokens[row["device_id"]] = token
                return tokens
        except Exception:
            if self.credential_protector is not None:
                for protected in protected_tokens:
                    try:
                        self.credential_protector.delete(protected)
                    except Exception:
                        pass
            raise

    def claim_approval_capability(
        self,
        *,
        capability: str,
        device_id: str,
        device_generation: int,
        request_id: str,
        session_id: str,
        decision: str,
        op_id: str,
    ) -> dict[str, Any]:
        if decision not in {"approve_once", "deny"}:
            raise StorageConflict("approval decision is not allowed")
        raw = b64url_decode(capability, field="capability", exact_bytes=32)
        digest = hashlib.sha256(raw).digest()
        at = self._clock()
        with self.transaction() as conn:
            cap = conn.execute(
                "SELECT * FROM approval_capabilities WHERE capability_hash=?",
                (digest,),
            ).fetchone()
            if cap is None:
                raise StorageNotFound("approval capability not found")
            request = conn.execute(
                "SELECT * FROM approval_requests WHERE request_id=?",
                (request_id,),
            ).fetchone()
            device = conn.execute(
                "SELECT status,kem_generation FROM devices WHERE device_id=?",
                (device_id,),
            ).fetchone()
            if (
                request is None
                or cap["request_id"] != request_id
                or request["session_id"] != session_id
                or cap["device_id"] != device_id
            ):
                raise StorageConflict("approval capability scope mismatch")
            if (
                device is None
                or device["status"] != "active"
                or device["kem_generation"] != device_generation
                or cap["device_generation"] != device_generation
            ):
                raise StorageConflict("approval device generation is not active")
            if cap["expires_at_ms"] <= at or request["expires_at_ms"] <= at:
                conn.execute(
                    "UPDATE approval_capabilities SET state='expired',updated_at_ms=? "
                    "WHERE capability_hash=? AND state IN ('pending','claimed','failed_retryable')",
                    (at, digest),
                )
                if request["state"] == "pending":
                    conn.execute(
                        "UPDATE approval_requests SET state='expired',updated_at_ms=? WHERE request_id=?",
                        (at, request_id),
                    )
                raise StorageExpired("approval capability expired")
            allowed = json.loads(bytes(cap["allowed_decisions_json"]))
            if decision not in allowed:
                raise StorageConflict("approval decision is not allowed")
            state = cap["state"]
            same_claim = cap["claimed_decision"] == decision and cap["op_id"] == op_id
            if state == "succeeded" and same_claim:
                return {"state": state, "retryable": False, "already_succeeded": True}
            if state == "failed_retryable":
                if not same_claim:
                    raise StorageConflict("approval retry changed decision or op_id")
                conn.execute(
                    "UPDATE approval_capabilities SET state='claimed',updated_at_ms=? "
                    "WHERE capability_hash=? AND state='failed_retryable'",
                    (at, digest),
                )
                return {
                    "state": "claimed",
                    "retryable": True,
                    "already_succeeded": False,
                }
            if state != "pending":
                raise StorageConflict(f"approval capability is {state}")
            if request["state"] != "pending":
                raise StorageConflict("approval request already resolved or claimed")
            conn.execute(
                """UPDATE approval_requests SET state='claimed',claimed_device_id=?,
                   claimed_decision=?,op_id=?,updated_at_ms=? WHERE request_id=? AND state='pending'""",
                (device_id, decision, op_id, at, request_id),
            )
            conn.execute(
                """UPDATE approval_capabilities SET state='claimed',claimed_decision=?,op_id=?,
                   updated_at_ms=? WHERE capability_hash=? AND state='pending'""",
                (decision, op_id, at, digest),
            )
            conn.execute(
                """UPDATE approval_capabilities SET state='superseded',updated_at_ms=?
                   WHERE request_id=? AND capability_hash<>? AND state='pending'""",
                (at, request_id, digest),
            )
            return {"state": "claimed", "retryable": False, "already_succeeded": False}

    def mark_approval_retryable(
        self, *, capability: str, device_id: str, op_id: str
    ) -> None:
        digest = hashlib.sha256(
            b64url_decode(capability, field="capability", exact_bytes=32)
        ).digest()
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE approval_capabilities SET state='failed_retryable',updated_at_ms=?
                   WHERE capability_hash=? AND device_id=? AND op_id=? AND state='claimed'""",
                (self._clock(), digest, device_id, op_id),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("approval capability is not claimed")

    def fail_approval_capability(
        self, *, capability: str, device_id: str, op_id: str
    ) -> None:
        """Terminally reject one claimed response without claiming it resolved."""

        digest = hashlib.sha256(
            b64url_decode(capability, field="capability", exact_bytes=32)
        ).digest()
        at = self._clock()
        with self.transaction() as conn:
            row = conn.execute(
                """SELECT request_id,state FROM approval_capabilities
                   WHERE capability_hash=? AND device_id=? AND op_id=?""",
                (digest, device_id, op_id),
            ).fetchone()
            if row is None or row["state"] != "claimed":
                raise StorageConflict("approval capability is not claimed")
            conn.execute(
                """UPDATE approval_capabilities SET state='revoked',updated_at_ms=?
                   WHERE capability_hash=?""",
                (at, digest),
            )
            conn.execute(
                """UPDATE approval_requests SET state='failed',updated_at_ms=?
                   WHERE request_id=?""",
                (at, row["request_id"]),
            )

    def complete_approval_capability(
        self, *, capability: str, device_id: str, op_id: str
    ) -> None:
        digest = hashlib.sha256(
            b64url_decode(capability, field="capability", exact_bytes=32)
        ).digest()
        at = self._clock()
        with self.transaction() as conn:
            cap = conn.execute(
                "SELECT request_id FROM approval_capabilities WHERE capability_hash=?",
                (digest,),
            ).fetchone()
            if cap is None:
                raise StorageNotFound("approval capability not found")
            cursor = conn.execute(
                """UPDATE approval_capabilities SET state='succeeded',updated_at_ms=?
                   WHERE capability_hash=? AND device_id=? AND op_id=?
                   AND state IN ('claimed','failed_retryable')""",
                (at, digest, device_id, op_id),
            )
            if cursor.rowcount != 1:
                raise StorageConflict("approval capability cannot complete")
            conn.execute(
                "UPDATE approval_requests SET state='succeeded',updated_at_ms=? WHERE request_id=?",
                (at, cap["request_id"]),
            )

    def resolve_approval_elsewhere(self, *, request_id: str) -> None:
        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                """UPDATE approval_requests SET state='resolved_elsewhere',updated_at_ms=?
                   WHERE request_id=?""",
                (at, request_id),
            )
            conn.execute(
                """UPDATE approval_capabilities SET state='superseded',updated_at_ms=?
                   WHERE request_id=? AND state IN ('pending','claimed','failed_retryable')""",
                (at, request_id),
            )

    def approval_capability_state(self, capability: str) -> str | None:
        digest = hashlib.sha256(
            b64url_decode(capability, field="capability", exact_bytes=32)
        ).digest()
        with self._lock:
            row = self._conn.execute(
                "SELECT state FROM approval_capabilities WHERE capability_hash=?",
                (digest,),
            ).fetchone()
        return row["state"] if row else None

    def _transition_operation(
        self, device_id: str, op_id: str, old_state: str, new_state: str
    ) -> None:
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE operations SET state=?,updated_at_ms=?
                   WHERE device_id=? AND op_id=? AND state=?""",
                (new_state, self._clock(), device_id, op_id, old_state),
            )
            if cursor.rowcount != 1:
                raise StorageConflict(f"operation is not {old_state}")

    @staticmethod
    def _operation_row(row: sqlite3.Row) -> OperationRecord:
        response = (
            json.loads(bytes(row["response_json"]))
            if row["response_json"] is not None
            else None
        )
        return OperationRecord(
            device_id=row["device_id"],
            op_id=row["op_id"],
            request_hash=bytes(row["request_hash"]),
            method=row["method"],
            state=row["state"],
            response=response,
            error_code=row["error_code"],
            created_at_ms=row["created_at_ms"],
            updated_at_ms=row["updated_at_ms"],
        )

    # -- session alias/ownership/presence ------------------------------
    def set_session_alias(self, origin_session_id: str, live_session_id: str) -> None:
        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                """INSERT INTO session_aliases(origin_session_id,live_session_id,updated_at_ms)
                   VALUES (?,?,?) ON CONFLICT(origin_session_id) DO UPDATE SET
                   live_session_id=excluded.live_session_id,updated_at_ms=excluded.updated_at_ms""",
                (origin_session_id, live_session_id, at),
            )

    def live_session_id(self, origin_session_id: str) -> str:
        with self._lock:
            row = self._conn.execute(
                "SELECT live_session_id FROM session_aliases WHERE origin_session_id=?",
                (origin_session_id,),
            ).fetchone()
        return row["live_session_id"] if row else origin_session_id

    def origin_session_id(self, session_id: str) -> str:
        """Resolve either coordinate to the canonical phone-facing origin."""

        with self._lock:
            row = self._conn.execute(
                """SELECT origin_session_id FROM session_aliases
                   WHERE live_session_id=? ORDER BY updated_at_ms DESC LIMIT 1""",
                (session_id,),
            ).fetchone()
        return row["origin_session_id"] if row else session_id

    def own_session(
        self, origin_session_id: str, live_session_id: str | None = None
    ) -> None:
        live = live_session_id or origin_session_id
        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                """INSERT INTO owned_sessions(origin_session_id,live_session_id,updated_at_ms)
                   VALUES (?,?,?) ON CONFLICT(origin_session_id) DO UPDATE SET
                   live_session_id=excluded.live_session_id,updated_at_ms=excluded.updated_at_ms""",
                (origin_session_id, live, at),
            )
            conn.execute(
                """INSERT INTO session_aliases(origin_session_id,live_session_id,updated_at_ms)
                   VALUES (?,?,?) ON CONFLICT(origin_session_id) DO UPDATE SET
                   live_session_id=excluded.live_session_id,updated_at_ms=excluded.updated_at_ms""",
                (origin_session_id, live, at),
            )

    def owned_sessions(self) -> dict[str, str]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT origin_session_id,live_session_id FROM owned_sessions"
            ).fetchall()
        return {row["origin_session_id"]: row["live_session_id"] for row in rows}

    def active_subscriptions(self) -> list[tuple[str, str]]:
        """Return durable active ``(device_id, session_id)`` recovery targets."""

        with self._lock:
            rows = self._conn.execute(
                """SELECT s.device_id,s.session_id FROM subscriptions s
                   JOIN devices d ON d.device_id=s.device_id
                   WHERE s.active=1 AND d.status='active'
                   ORDER BY s.device_id,s.session_id"""
            ).fetchall()
        return [(row["device_id"], row["session_id"]) for row in rows]

    def set_subscription(
        self,
        device_id: str,
        session_id: str,
        *,
        active: bool = True,
        foreground: bool = False,
    ) -> None:
        at = self._clock()
        with self.transaction() as conn:
            if foreground:
                conn.execute(
                    "UPDATE subscriptions SET foreground=0,updated_at_ms=? WHERE device_id=?",
                    (at, device_id),
                )
            conn.execute(
                """INSERT INTO subscriptions(device_id,session_id,active,foreground,updated_at_ms)
                   VALUES (?,?,?,?,?) ON CONFLICT(device_id,session_id) DO UPDATE SET
                   active=excluded.active,foreground=excluded.foreground,
                   updated_at_ms=excluded.updated_at_ms""",
                (device_id, session_id, int(active), int(foreground), at),
            )
            if not active:
                conn.execute(
                    """UPDATE notification_outbox SET state='failed',
                       last_error_code='subscription_inactive',updated_at_ms=?
                       WHERE device_id=? AND session_id=? AND state='pending'""",
                    (at, device_id, session_id),
                )
            elif not foreground:
                conn.execute(
                    """UPDATE notification_outbox SET next_attempt_at_ms=?,updated_at_ms=?
                       WHERE device_id=? AND session_id=? AND state='pending'""",
                    (at, at, device_id, session_id),
                )

    def clear_presence(self, device_id: str) -> None:
        with self.transaction() as conn:
            at = self._clock()
            conn.execute(
                "UPDATE subscriptions SET foreground=0,updated_at_ms=? WHERE device_id=?",
                (at, device_id),
            )
            conn.execute(
                """UPDATE notification_outbox SET next_attempt_at_ms=?,updated_at_ms=?
                   WHERE device_id=? AND state='pending'""",
                (at, at, device_id),
            )

    def clear_all_presence(self) -> int:
        """Conservatively expire foreground leases after Relay restart."""

        with self.transaction() as conn:
            at = self._clock()
            cursor = conn.execute(
                "UPDATE subscriptions SET foreground=0,updated_at_ms=? WHERE foreground=1",
                (at,),
            )
            conn.execute(
                """UPDATE notification_outbox SET next_attempt_at_ms=?,updated_at_ms=?
                   WHERE state='pending'""",
                (at, at),
            )
            return cursor.rowcount

    def session_has_foreground_device(self, session_id: str) -> bool:
        with self._lock:
            row = self._conn.execute(
                """SELECT 1 FROM subscriptions s JOIN devices d ON d.device_id=s.device_id
                   WHERE s.session_id=? AND s.active=1 AND s.foreground=1
                   AND s.updated_at_ms>=? AND d.status='active' LIMIT 1""",
                (session_id, self._clock() - PRESENCE_LEASE_MS),
            ).fetchone()
        return row is not None

    def device_is_foreground(self, device_id: str, session_id: str) -> bool:
        return self.foreground_lease_expires_at(device_id, session_id) is not None

    def foreground_lease_expires_at(
        self, device_id: str, session_id: str
    ) -> int | None:
        with self._lock:
            row = self._conn.execute(
                """SELECT s.updated_at_ms FROM subscriptions s
                   JOIN devices d ON d.device_id=s.device_id
                   WHERE s.device_id=? AND s.session_id=? AND s.active=1 AND s.foreground=1
                   AND s.updated_at_ms>=? AND d.status='active' LIMIT 1""",
                (device_id, session_id, self._clock() - PRESENCE_LEASE_MS),
            ).fetchone()
        if row is None:
            return None
        return min(
            MAX_WIRE_INTEGER,
            int(row["updated_at_ms"]) + PRESENCE_LEASE_MS + 1,
        )

    def subscribed_devices(self, session_id: str) -> list[str]:
        with self._lock:
            rows = self._conn.execute(
                """SELECT s.device_id FROM subscriptions s JOIN devices d ON d.device_id=s.device_id
                   WHERE s.session_id=? AND s.active=1 AND d.status='active'""",
                (session_id,),
            ).fetchall()
        return [row["device_id"] for row in rows]

    # -- revisioned projection/checkpoints -----------------------------
    def retire_in_progress_items(self, session_id: str) -> int:
        """Tombstone live items whose in-memory correlation died on restart.

        Reframer turn/source correlation is intentionally process-local.  A
        restarted process cannot safely attach a later delta/completion to an
        old projected item, so the old item must not remain a permanent
        ``in_progress`` phantom.  Aliases are removed so a completion carrying
        the same Gateway source ID creates a fresh terminal item rather than
        being dominated by the tombstone.
        """

        with self.transaction() as conn:
            rows = conn.execute(
                """SELECT item_id,revision FROM session_items
                   WHERE session_id=? AND status='in_progress'""",
                (session_id,),
            ).fetchall()
            for row in rows:
                item_id = row["item_id"]
                deleted_revision = min(MAX_WIRE_INTEGER, int(row["revision"]) + 1)
                conn.execute(
                    "DELETE FROM session_items WHERE session_id=? AND item_id=?",
                    (session_id, item_id),
                )
                conn.execute(
                    "DELETE FROM item_aliases WHERE session_id=? AND item_id=?",
                    (session_id, item_id),
                )
                conn.execute(
                    """INSERT INTO session_tombstones
                       (session_id,item_id,deleted_at_revision,updated_at_ms)
                       VALUES (?,?,?,?) ON CONFLICT(session_id,item_id) DO UPDATE SET
                       deleted_at_revision=MAX(deleted_at_revision,excluded.deleted_at_revision),
                       updated_at_ms=excluded.updated_at_ms""",
                    (session_id, item_id, deleted_revision, self._clock()),
                )
            return len(rows)

    def resolve_item_id(self, session_id: str, source_item_id: str) -> str | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT item_id FROM item_aliases WHERE session_id=? AND source_item_id=?",
                (session_id, source_item_id),
            ).fetchone()
        return row["item_id"] if row else None

    def session_item(self, session_id: str, item_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM session_items WHERE session_id=? AND item_id=?",
                (session_id, item_id),
            ).fetchone()
        if row is None:
            return None
        return {
            "item_id": row["item_id"],
            "session_id": session_id,
            "turn_id": row["turn_id"],
            "type": row["type"],
            "status": row["status"],
            "ord": row["ord"],
            "rev": row["revision"],
            "summary": row["summary"],
            "body": json.loads(bytes(row["body_json"])),
        }

    def put_full_item(
        self,
        session_id: str,
        item: Mapping[str, Any],
        *,
        source_item_id: str | None = None,
    ) -> str:
        with self.transaction() as conn:
            return self._put_full_item(
                conn, session_id, item, source_item_id=source_item_id
            )

    def _put_full_item(
        self,
        conn: sqlite3.Connection,
        session_id: str,
        item: Mapping[str, Any],
        *,
        source_item_id: str | None = None,
    ) -> str:
        item_id = str(item.get("item_id") or random_id("itm"))
        revision = _int64(item.get("rev", 1), field="item revision", minimum=1)
        normalized = {
            "item_id": item_id,
            "session_id": session_id,
            "turn_id": item.get("turn_id"),
            "type": str(item.get("type", "unknown")),
            "status": str(item.get("status", "in_progress")),
            "ord": int(item.get("ord", 0)),
            "rev": revision,
            "summary": str(item.get("summary", "")),
            "body": dict(item.get("body") or {}),
        }
        content_hash = hashlib.sha256(canonical_json(normalized)).digest()
        tombstone = conn.execute(
            "SELECT deleted_at_revision FROM session_tombstones WHERE session_id=? AND item_id=?",
            (session_id, item_id),
        ).fetchone()
        if tombstone and tombstone["deleted_at_revision"] >= revision:
            return "tombstoned"
        existing = conn.execute(
            "SELECT * FROM session_items WHERE session_id=? AND item_id=?",
            (session_id, item_id),
        ).fetchone()
        if existing and revision < existing["revision"]:
            return "duplicate"
        if existing and revision == existing["revision"]:
            prior_hash = conn.execute(
                """SELECT content_hash FROM item_revision_hashes
                   WHERE session_id=? AND item_id=? AND revision=?""",
                (session_id, item_id, revision),
            ).fetchone()
            if prior_hash and secrets.compare_digest(
                bytes(prior_hash["content_hash"]), content_hash
            ):
                return "duplicate"
            raise StorageConflict("same item revision has divergent content")
        body = item.get("body") or {}
        if not isinstance(body, Mapping):
            raise ValueError("item body must be an object")
        conn.execute(
            """INSERT INTO session_items
               (session_id,item_id,source_item_id,turn_id,type,status,ord,revision,
                summary,body_json,updated_at_ms)
               VALUES (?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(session_id,item_id) DO UPDATE SET
               source_item_id=COALESCE(excluded.source_item_id,session_items.source_item_id),
               turn_id=excluded.turn_id,type=excluded.type,status=excluded.status,
               ord=excluded.ord,revision=excluded.revision,summary=excluded.summary,
               body_json=excluded.body_json,updated_at_ms=excluded.updated_at_ms""",
            (
                session_id,
                item_id,
                source_item_id,
                item.get("turn_id"),
                str(item.get("type", "unknown")),
                str(item.get("status", "in_progress")),
                int(item.get("ord", 0)),
                revision,
                str(item.get("summary", "")),
                json.dumps(
                    dict(body), ensure_ascii=False, separators=(",", ":")
                ).encode("utf-8"),
                self._clock(),
            ),
        )
        if source_item_id is not None:
            conn.execute(
                """INSERT INTO item_aliases(session_id,source_item_id,item_id,created_at_ms)
                   VALUES (?,?,?,?) ON CONFLICT(session_id,source_item_id) DO UPDATE SET
                   item_id=excluded.item_id""",
                (session_id, source_item_id, item_id, self._clock()),
            )
        conn.execute(
            """INSERT INTO item_revision_hashes(session_id,item_id,revision,content_hash)
               VALUES (?,?,?,?)""",
            (session_id, item_id, revision, content_hash),
        )
        conn.execute(
            "DELETE FROM session_tombstones WHERE session_id=? AND item_id=?",
            (session_id, item_id),
        )
        return "applied"

    def apply_item_delta(self, session_id: str, delta: Mapping[str, Any]) -> str:
        with self.transaction() as conn:
            return self._apply_item_delta(conn, session_id, delta)

    def _apply_item_delta(
        self, conn: sqlite3.Connection, session_id: str, delta: Mapping[str, Any]
    ) -> str:
        item_id = str(delta.get("item_id", ""))
        to_rev = _int64(delta.get("to_rev", -1), field="to_rev", minimum=1)
        _int64(delta.get("from_rev", -1), field="from_rev", minimum=1)
        delta_hash = hashlib.sha256(canonical_json(dict(delta))).digest()
        tombstone = conn.execute(
            "SELECT deleted_at_revision FROM session_tombstones WHERE session_id=? AND item_id=?",
            (session_id, item_id),
        ).fetchone()
        if tombstone and tombstone["deleted_at_revision"] >= to_rev:
            return "tombstoned"
        row = conn.execute(
            "SELECT * FROM session_items WHERE session_id=? AND item_id=?",
            (session_id, item_id),
        ).fetchone()
        if row is None:
            return "gap"
        current = int(row["revision"])
        from_rev = int(delta.get("from_rev", -1))
        if to_rev <= current:
            prior_hash = conn.execute(
                """SELECT content_hash FROM item_revision_hashes
                   WHERE session_id=? AND item_id=? AND revision=?""",
                (session_id, item_id, to_rev),
            ).fetchone()
            if prior_hash and secrets.compare_digest(
                bytes(prior_hash["content_hash"]), delta_hash
            ):
                return "duplicate"
            if to_rev < current:
                return "duplicate"
            raise StorageConflict("same delta revision has divergent content")
        if from_rev > current:
            return "gap"
        if from_rev < current < to_rev:
            return "conflict"
        if from_rev != current or to_rev <= from_rev:
            return "conflict"
        body = json.loads(bytes(row["body_json"]))
        for op in delta.get("ops") or []:
            if not isinstance(op, Mapping) or op.get("op") != "append_utf8":
                return "conflict"
            path = op.get("path")
            if path != "/body/text":
                return "conflict"
            old = body.get("text", "")
            data = op.get("data")
            if not isinstance(old, str) or not isinstance(data, str):
                return "conflict"
            actual = len(old.encode("utf-8"))
            if int(op.get("offset", -1)) != actual:
                return "conflict"
            body["text"] = old + data
        conn.execute(
            """UPDATE session_items SET revision=?,body_json=?,updated_at_ms=?
               WHERE session_id=? AND item_id=?""",
            (
                to_rev,
                json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode(
                    "utf-8"
                ),
                self._clock(),
                session_id,
                item_id,
            ),
        )
        conn.execute(
            """INSERT INTO item_revision_hashes(session_id,item_id,revision,content_hash)
               VALUES (?,?,?,?)""",
            (session_id, item_id, to_rev, delta_hash),
        )
        return "applied"

    def apply_checkpoint(
        self,
        session_id: str,
        *,
        snapshot_revision: int,
        through_seq: int,
        replace: bool,
        items: Sequence[Mapping[str, Any]],
        tombstones: Sequence[Mapping[str, Any]],
    ) -> str:
        snapshot_revision = _int64(snapshot_revision, field="snapshot_revision")
        through_seq = _int64(through_seq, field="through_seq")
        checkpoint_hash = hashlib.sha256(
            canonical_json({
                "session_id": session_id,
                "snapshot_revision": snapshot_revision,
                "through_seq": through_seq,
                "replace": replace,
                "items": [dict(item) for item in items],
                "tombstones": [dict(item) for item in tombstones],
            })
        ).digest()
        with self.transaction() as conn:
            existing = conn.execute(
                "SELECT snapshot_revision,content_hash FROM session_checkpoints WHERE session_id=?",
                (session_id,),
            ).fetchone()
            if existing and snapshot_revision < existing["snapshot_revision"]:
                return "duplicate"
            if existing and snapshot_revision == existing["snapshot_revision"]:
                if existing["content_hash"] is not None and secrets.compare_digest(
                    bytes(existing["content_hash"]), checkpoint_hash
                ):
                    return "duplicate"
                raise StorageConflict("same checkpoint revision has divergent content")
            present: set[str] = set()
            for item in items:
                item_id = str(item.get("item_id", ""))
                if not item_id:
                    raise ValueError("checkpoint item lacks item_id")
                present.add(item_id)
                self._put_full_item(conn, session_id, item)
            for tombstone in tombstones:
                item_id = str(tombstone.get("item_id", ""))
                deleted_rev = int(
                    tombstone.get("deleted_at_revision", snapshot_revision)
                )
                if not item_id:
                    raise ValueError("checkpoint tombstone lacks item_id")
                conn.execute(
                    "DELETE FROM session_items WHERE session_id=? AND item_id=?",
                    (session_id, item_id),
                )
                conn.execute(
                    """INSERT INTO session_tombstones
                       (session_id,item_id,deleted_at_revision,updated_at_ms) VALUES (?,?,?,?)
                       ON CONFLICT(session_id,item_id) DO UPDATE SET
                       deleted_at_revision=MAX(deleted_at_revision,excluded.deleted_at_revision),
                       updated_at_ms=excluded.updated_at_ms""",
                    (session_id, item_id, deleted_rev, self._clock()),
                )
            if replace:
                rows = conn.execute(
                    "SELECT item_id,revision FROM session_items WHERE session_id=?",
                    (session_id,),
                ).fetchall()
                for row in rows:
                    if (
                        row["item_id"] not in present
                        and row["revision"] <= snapshot_revision
                    ):
                        conn.execute(
                            "DELETE FROM session_items WHERE session_id=? AND item_id=?",
                            (session_id, row["item_id"]),
                        )
                        conn.execute(
                            """INSERT INTO session_tombstones
                               (session_id,item_id,deleted_at_revision,updated_at_ms)
                               VALUES (?,?,?,?) ON CONFLICT(session_id,item_id) DO UPDATE SET
                               deleted_at_revision=MAX(deleted_at_revision,excluded.deleted_at_revision),
                               updated_at_ms=excluded.updated_at_ms""",
                            (
                                session_id,
                                row["item_id"],
                                snapshot_revision,
                                self._clock(),
                            ),
                        )
            conn.execute(
                """INSERT INTO session_checkpoints
                   (session_id,snapshot_revision,through_seq,content_hash,updated_at_ms)
                   VALUES (?,?,?,?,?)
                   ON CONFLICT(session_id) DO UPDATE SET
                   snapshot_revision=excluded.snapshot_revision,
                   through_seq=excluded.through_seq,content_hash=excluded.content_hash,
                   updated_at_ms=excluded.updated_at_ms""",
                (
                    session_id,
                    snapshot_revision,
                    through_seq,
                    checkpoint_hash,
                    self._clock(),
                ),
            )
            return "applied"

    def session_checkpoint(self, session_id: str) -> dict[str, Any]:
        with self._lock:
            rows = self._conn.execute(
                """SELECT * FROM session_items WHERE session_id=?
                   ORDER BY ord,item_id""",
                (session_id,),
            ).fetchall()
            tombs = self._conn.execute(
                """SELECT item_id,deleted_at_revision FROM session_tombstones
                   WHERE session_id=? ORDER BY item_id""",
                (session_id,),
            ).fetchall()
            checkpoint = self._conn.execute(
                "SELECT snapshot_revision,through_seq FROM session_checkpoints WHERE session_id=?",
                (session_id,),
            ).fetchone()
        items = [
            {
                "item_id": row["item_id"],
                "session_id": session_id,
                "turn_id": row["turn_id"],
                "type": row["type"],
                "status": row["status"],
                "ord": row["ord"],
                "rev": row["revision"],
                "summary": row["summary"],
                "body": json.loads(bytes(row["body_json"])),
            }
            for row in rows
        ]
        return {
            "session_id": session_id,
            "snapshot_revision": checkpoint["snapshot_revision"] if checkpoint else 0,
            "through_seq": checkpoint["through_seq"] if checkpoint else 0,
            "replace": True,
            "items": items,
            "tombstones": [
                {
                    "item_id": row["item_id"],
                    "deleted_at_revision": row["deleted_at_revision"],
                }
                for row in tombs
            ],
        }

    # -- push bindings -------------------------------------------------
    def prepare_push_binding_exchange(
        self,
        *,
        device_id: str,
        bind_token: str,
        requested_classes: Sequence[str],
    ) -> PushBindingExchangeRecord:
        """Persist one exact Push exchange request before network use."""

        classes = tuple(sorted(set(requested_classes)))
        if not bind_token or not classes or len(classes) != len(requested_classes):
            raise ValueError("binding exchange fields are invalid")
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM push_binding_exchanges WHERE device_id=?",
                (device_id,),
            ).fetchone()
        if row is not None:
            record = self._push_exchange_row(row)
            if record.bind_token != bind_token or record.requested_classes != classes:
                raise StorageConflict("binding exchange retry changed request")
            return record
        exchange_id = random_id("exg")
        token_bytes = bind_token.encode("utf-8")
        protected = token_bytes
        if self.credential_protector is not None:
            protected = self.credential_protector.protect(
                f"push-exchange:{exchange_id}", token_bytes
            )
        at = self._clock()
        try:
            with self.transaction() as conn:
                device = conn.execute(
                    "SELECT status FROM devices WHERE device_id=?", (device_id,)
                ).fetchone()
                if device is None or device["status"] != "pending":
                    raise StorageConflict("push exchange requires a pending device")
                conn.execute(
                    """INSERT INTO push_binding_exchanges
                       (device_id,exchange_id,bind_token,requested_classes_json,state,
                        binding_id,created_at_ms,updated_at_ms)
                       VALUES (?,?,?,?, 'pending',NULL,?,?)""",
                    (
                        device_id,
                        exchange_id,
                        protected,
                        canonical_json(list(classes)),
                        at,
                        at,
                    ),
                )
        except Exception:
            if self.credential_protector is not None:
                try:
                    self.credential_protector.delete(protected)
                except Exception:
                    pass
            raise
        return self.push_binding_exchange(device_id)  # type: ignore[return-value]

    def push_binding_exchange(self, device_id: str) -> PushBindingExchangeRecord | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM push_binding_exchanges WHERE device_id=?",
                (device_id,),
            ).fetchone()
        return self._push_exchange_row(row) if row else None

    def _push_exchange_row(self, row: sqlite3.Row) -> PushBindingExchangeRecord:
        wrapped = bytes(row["bind_token"])
        if not wrapped:
            token = ""
        elif self.credential_protector is not None:
            token = self.credential_protector.reveal(wrapped).decode("utf-8")
        else:
            token = wrapped.decode("utf-8")
        return PushBindingExchangeRecord(
            device_id=row["device_id"],
            exchange_id=row["exchange_id"],
            bind_token=token,
            requested_classes=tuple(json.loads(bytes(row["requested_classes_json"]))),
            state=row["state"],
            binding_id=row["binding_id"],
            remote_revoke_state=row["remote_revoke_state"],
            revoke_attempts=int(row["revoke_attempts"]),
            last_error_code=row["last_error_code"],
        )

    def complete_push_binding_exchange(
        self,
        *,
        device_id: str,
        exchange_id: str,
        binding_id: str,
        send_capability: bytes,
        allowed_classes: Sequence[str],
    ) -> None:
        at = self._clock()
        requested_classes = sorted(set(allowed_classes))
        with self._lock:
            prior_exchange = self._conn.execute(
                "SELECT * FROM push_binding_exchanges WHERE device_id=?",
                (device_id,),
            ).fetchone()
            prior_binding = self._conn.execute(
                "SELECT * FROM push_bindings WHERE device_id=?",
                (device_id,),
            ).fetchone()
        if (
            prior_exchange is not None
            and prior_exchange["remote_revoke_state"] != "not_required"
        ):
            raise StorageConflict("binding exchange is queued for revocation")
        if prior_exchange is not None and prior_exchange["state"] == "completed":
            if (
                prior_exchange["exchange_id"] != exchange_id
                or prior_exchange["binding_id"] != binding_id
                or prior_binding is None
                or prior_binding["binding_id"] != binding_id
                or json.loads(bytes(prior_binding["allowed_classes_json"]))
                != requested_classes
            ):
                raise StorageConflict("binding exchange response changed binding")
            existing_capability = bytes(prior_binding["send_capability"])
            if self.credential_protector is not None:
                existing_capability = self.credential_protector.reveal(
                    existing_capability
                )
            if not secrets.compare_digest(existing_capability, send_capability):
                raise StorageConflict("binding exchange response changed capability")
            self._erase_completed_push_exchange_token(
                device_id, bytes(prior_exchange["bind_token"])
            )
            return
        protected_capability = send_capability
        if self.credential_protector is not None:
            protected_capability = self.credential_protector.protect(
                f"push-binding:{binding_id}", send_capability
            )
        wrapped_bind_token = b""
        try:
            with self.transaction() as conn:
                exchange = conn.execute(
                    "SELECT * FROM push_binding_exchanges WHERE device_id=?",
                    (device_id,),
                ).fetchone()
                if exchange is None or exchange["exchange_id"] != exchange_id:
                    raise StorageConflict("binding exchange response changed request")
                if exchange["remote_revoke_state"] != "not_required":
                    raise StorageConflict("binding exchange is queued for revocation")
                if exchange["state"] == "completed":
                    raise StorageConflict(
                        "binding exchange completed concurrently; retry"
                    )
                device = conn.execute(
                    "SELECT status,re_pair_required FROM devices WHERE device_id=?",
                    (device_id,),
                ).fetchone()
                if device is None:
                    raise StorageConflict("binding exchange device disappeared")
                binding_status = (
                    "remote_revoke_pending"
                    if bool(device["re_pair_required"])
                    else "active"
                )
                wrapped_bind_token = bytes(exchange["bind_token"])
                conn.execute(
                    """INSERT INTO push_bindings
                       (binding_id,device_id,send_capability,allowed_classes_json,status,
                        created_at_ms,updated_at_ms) VALUES (?,?,?,?,?,?,?)
                       ON CONFLICT(device_id) DO UPDATE SET binding_id=excluded.binding_id,
                       send_capability=excluded.send_capability,
                       allowed_classes_json=excluded.allowed_classes_json,
                       status=excluded.status,revoke_attempts=0,last_error_code=NULL,
                       updated_at_ms=excluded.updated_at_ms""",
                    (
                        binding_id,
                        device_id,
                        protected_capability,
                        canonical_json(requested_classes),
                        binding_status,
                        at,
                        at,
                    ),
                )
                conn.execute(
                    """UPDATE push_binding_exchanges SET state='completed',binding_id=?,
                       updated_at_ms=? WHERE device_id=? AND exchange_id=?""",
                    (binding_id, at, device_id, exchange_id),
                )
        except Exception:
            if self.credential_protector is not None:
                try:
                    self.credential_protector.delete(protected_capability)
                except Exception:
                    pass
            raise
        self._erase_completed_push_exchange_token(device_id, wrapped_bind_token)

    def _erase_completed_push_exchange_token(
        self, device_id: str, wrapped_bind_token: bytes
    ) -> None:
        """Erase a consumed one-time bind token after its response is durable."""

        if wrapped_bind_token and self.credential_protector is not None:
            self.credential_protector.delete(wrapped_bind_token)
        with self.transaction() as conn:
            conn.execute(
                """UPDATE push_binding_exchanges SET bind_token=X'',updated_at_ms=?
                   WHERE device_id=? AND state='completed'""",
                (self._clock(), device_id),
            )

    def store_push_binding(
        self,
        *,
        device_id: str,
        binding_id: str,
        send_capability: bytes,
        allowed_classes: Sequence[str],
    ) -> None:
        at = self._clock()
        payload = json.dumps(
            sorted(set(allowed_classes)), separators=(",", ":")
        ).encode()
        protected_capability = send_capability
        if self.credential_protector is not None:
            protected_capability = self.credential_protector.protect(
                f"push-binding:{binding_id}", send_capability
            )
        with self.transaction() as conn:
            conn.execute(
                """INSERT INTO push_bindings
                   (binding_id,device_id,send_capability,allowed_classes_json,status,
                    created_at_ms,updated_at_ms) VALUES (?,?,?,?, 'active',?,?)
                   ON CONFLICT(device_id) DO UPDATE SET binding_id=excluded.binding_id,
                   send_capability=excluded.send_capability,
                   allowed_classes_json=excluded.allowed_classes_json,status='active',
                   revoke_attempts=0,last_error_code=NULL,
                   updated_at_ms=excluded.updated_at_ms""",
                (binding_id, device_id, protected_capability, payload, at, at),
            )

    def push_binding(self, device_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM push_bindings WHERE device_id=? AND status='active'",
                (device_id,),
            ).fetchone()
        if row is None:
            return None
        capability = bytes(row["send_capability"])
        if self.credential_protector is not None:
            capability = self.credential_protector.reveal(capability)
        return {
            "binding_id": row["binding_id"],
            "send_capability": capability,
            "allowed_classes": json.loads(bytes(row["allowed_classes_json"])),
        }

    # -- durable notification delivery ------------------------------
    @staticmethod
    def _notification_dedupe_hash(dedupe_key: str) -> bytes:
        if not isinstance(dedupe_key, str) or not dedupe_key or len(dedupe_key) > 1_024:
            raise ValueError("notification dedupe_key is invalid")
        return hashlib.sha256(dedupe_key.encode("utf-8")).digest()

    @staticmethod
    def _notification_outbox_row(row: sqlite3.Row) -> NotificationOutboxRecord:
        return NotificationOutboxRecord(
            device_id=row["device_id"],
            notification_id=row["notification_id"],
            binding_id=row["binding_id"],
            session_id=row["session_id"],
            dedupe_hash=bytes(row["dedupe_hash"]),
            notification_class=row["notification_class"],
            collapse_id=row["collapse_id"],
            descriptor=json.loads(bytes(row["descriptor_json"])),
            state=row["state"],
            attempts=row["attempts"],
            last_error_code=row["last_error_code"],
            created_at_ms=row["created_at_ms"],
            updated_at_ms=row["updated_at_ms"],
            next_attempt_at_ms=row["next_attempt_at_ms"],
            expires_at_ms=row["expires_at_ms"],
        )

    def notification_by_dedupe(
        self, device_id: str, dedupe_key: str
    ) -> NotificationOutboxRecord | None:
        digest = self._notification_dedupe_hash(dedupe_key)
        with self._lock:
            row = self._conn.execute(
                """SELECT * FROM notification_outbox
                   WHERE device_id=? AND dedupe_hash=?""",
                (device_id, digest),
            ).fetchone()
        return self._notification_outbox_row(row) if row else None

    def has_notification_dedupe(self, dedupe_key: str) -> bool:
        """Return whether any device ledger contains this logical event."""

        digest = self._notification_dedupe_hash(dedupe_key)
        with self._lock:
            row = self._conn.execute(
                "SELECT 1 FROM notification_outbox WHERE dedupe_hash=? LIMIT 1",
                (digest,),
            ).fetchone()
        return row is not None

    def notification_outbox_record(
        self, device_id: str, notification_id: str
    ) -> NotificationOutboxRecord | None:
        with self._lock:
            row = self._conn.execute(
                """SELECT * FROM notification_outbox
                   WHERE device_id=? AND notification_id=?""",
                (device_id, notification_id),
            ).fetchone()
        return self._notification_outbox_row(row) if row else None

    def enqueue_notification(
        self,
        *,
        device_id: str,
        binding_id: str,
        session_id: str | None,
        dedupe_key: str,
        descriptor: Mapping[str, Any],
    ) -> tuple[NotificationOutboxRecord, bool]:
        """Commit one exact encrypted Push descriptor before network use.

        The logical dedupe key is stored only as a digest.  A replay of the
        same logical notification always receives the first committed row, so
        neither a restart nor a changed process-local nonce can mint a second
        APNs identity.
        """

        digest = self._notification_dedupe_hash(dedupe_key)
        value = dict(descriptor)
        notification_id = value.get("notification_id")
        notification_class = value.get("class")
        collapse_id = value.get("collapse_id")
        expires_at_ms = value.get("expires_at_ms")
        if not isinstance(notification_id, str) or not notification_id:
            raise ValueError("notification descriptor lacks notification_id")
        if session_id is not None and (
            not isinstance(session_id, str) or not session_id
        ):
            raise ValueError("notification session_id is invalid")
        if notification_class not in {"approval", "error", "update"}:
            raise ValueError("notification descriptor class is invalid")
        if collapse_id is not None and not isinstance(collapse_id, str):
            raise ValueError("notification descriptor collapse_id is invalid")
        expires_at_ms = _int64(expires_at_ms, field="notification expires_at_ms")
        encoded = canonical_json(value)
        at = self._clock()
        with self.transaction() as conn:
            prior = conn.execute(
                """SELECT * FROM notification_outbox
                   WHERE device_id=? AND dedupe_hash=?""",
                (device_id, digest),
            ).fetchone()
            if prior is not None:
                return self._notification_outbox_row(prior), False
            device = conn.execute(
                "SELECT status FROM devices WHERE device_id=?", (device_id,)
            ).fetchone()
            binding = conn.execute(
                """SELECT status FROM push_bindings
                   WHERE device_id=? AND binding_id=?""",
                (device_id, binding_id),
            ).fetchone()
            if device is None or device["status"] != "active":
                raise StorageConflict("notification device is not active")
            if binding is None or binding["status"] != "active":
                raise StorageConflict("notification binding is not active")
            try:
                conn.execute(
                    """INSERT INTO notification_outbox
                       (device_id,notification_id,binding_id,dedupe_hash,
                        session_id,notification_class,collapse_id,descriptor_json,state,
                        attempts,last_error_code,created_at_ms,updated_at_ms,
                        next_attempt_at_ms,expires_at_ms)
                       VALUES (?,?,?,?,?,?,?,?,'pending',0,NULL,?,?,?,?)""",
                    (
                        device_id,
                        notification_id,
                        binding_id,
                        digest,
                        session_id,
                        notification_class,
                        collapse_id,
                        encoded,
                        at,
                        at,
                        at,
                        expires_at_ms,
                    ),
                )
            except sqlite3.IntegrityError as exc:
                raise StorageConflict(
                    "notification identity was reused with different content"
                ) from exc
            row = conn.execute(
                """SELECT * FROM notification_outbox
                   WHERE device_id=? AND notification_id=?""",
                (device_id, notification_id),
            ).fetchone()
            return self._notification_outbox_row(row), True

    def pending_notifications(
        self, *, limit: int = 256
    ) -> list[NotificationOutboxRecord]:
        self.expire_notifications()
        self.prune_notifications()
        with self._lock:
            rows = self._conn.execute(
                """SELECT * FROM notification_outbox
                   WHERE state='pending' AND next_attempt_at_ms<=?
                   ORDER BY created_at_ms,rowid LIMIT ?""",
                (self._clock(), limit),
            ).fetchall()
        return [self._notification_outbox_row(row) for row in rows]

    def notification_outbox(
        self, *, device_id: str | None = None
    ) -> list[NotificationOutboxRecord]:
        query = "SELECT * FROM notification_outbox"
        params: tuple[Any, ...] = ()
        if device_id is not None:
            query += " WHERE device_id=?"
            params = (device_id,)
        query += " ORDER BY created_at_ms,rowid"
        with self._lock:
            rows = self._conn.execute(query, params).fetchall()
        return [self._notification_outbox_row(row) for row in rows]

    def expire_notifications(self) -> int:
        at = self._clock()
        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE notification_outbox
                   SET state='expired',last_error_code='notification_expired',updated_at_ms=?
                   WHERE state='pending' AND expires_at_ms<=?""",
                (at, at),
            )
            return cursor.rowcount

    def prune_notifications(self, *, retention_ms: int = DEFAULT_MAILBOX_TTL_MS) -> int:
        """Bound terminal dedupe rows while retaining a full retry-grace day."""

        retention_ms = _int64(retention_ms, field="notification retention")
        cutoff = max(0, self._clock() - retention_ms)
        with self.transaction() as conn:
            cursor = conn.execute(
                """DELETE FROM notification_outbox
                   WHERE state!='pending' AND expires_at_ms<=?""",
                (cutoff,),
            )
            return cursor.rowcount

    def mark_notification_retry(
        self, device_id: str, notification_id: str, error_code: str
    ) -> None:
        with self._lock:
            row = self._conn.execute(
                """SELECT attempts FROM notification_outbox
                   WHERE device_id=? AND notification_id=? AND state='pending'""",
                (device_id, notification_id),
            ).fetchone()
        if row is None:
            return
        delay_ms = min(60_000, 1_000 * (2 ** min(int(row["attempts"]), 6)))
        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                """UPDATE notification_outbox
                   SET attempts=attempts+1,last_error_code=?,updated_at_ms=?,
                       next_attempt_at_ms=?
                   WHERE device_id=? AND notification_id=? AND state='pending'""",
                (
                    error_code[:128],
                    at,
                    min(MAX_WIRE_INTEGER, at + delay_ms),
                    device_id,
                    notification_id,
                ),
            )

    def defer_notification(
        self, device_id: str, notification_id: str, *, until_ms: int
    ) -> None:
        until_ms = _int64(until_ms, field="notification retry time")
        with self.transaction() as conn:
            conn.execute(
                """UPDATE notification_outbox SET next_attempt_at_ms=?,updated_at_ms=?
                   WHERE device_id=? AND notification_id=? AND state='pending'""",
                (until_ms, self._clock(), device_id, notification_id),
            )

    def mark_notification_sent(self, device_id: str, notification_id: str) -> None:
        with self.transaction() as conn:
            conn.execute(
                """UPDATE notification_outbox
                   SET state='sent',attempts=attempts+1,last_error_code=NULL,updated_at_ms=?
                   WHERE device_id=? AND notification_id=? AND state='pending'""",
                (self._clock(), device_id, notification_id),
            )

    def mark_notification_failed(
        self,
        device_id: str,
        notification_id: str,
        error_code: str,
        *,
        attempted: bool = True,
    ) -> None:
        with self.transaction() as conn:
            conn.execute(
                """UPDATE notification_outbox
                   SET state='failed',attempts=attempts+?,last_error_code=?,updated_at_ms=?
                   WHERE device_id=? AND notification_id=? AND state='pending'""",
                (
                    1 if attempted else 0,
                    error_code[:128],
                    self._clock(),
                    device_id,
                    notification_id,
                ),
            )

    def revoke_push_binding(self, device_id: str) -> bool:
        """Phase local erasure after remote Push revocation is confirmed."""

        with self.transaction() as conn:
            cursor = conn.execute(
                """UPDATE push_bindings
                   SET status='remote_revoked',last_error_code=NULL,updated_at_ms=?
                   WHERE device_id=? AND status='active'""",
                (self._clock(), device_id),
            )
            conn.execute(
                """UPDATE notification_outbox
                   SET state='failed',last_error_code='binding_revoked',updated_at_ms=?
                   WHERE device_id=? AND state='pending'""",
                (self._clock(), device_id),
            )
            changed = cursor.rowcount == 1
        self._finish_re_pair_credential_cleanup()
        return changed

    def destroy_local_authority(self) -> None:
        """Irreversibly erase local private/capability material after purge.

        Remote route and Push revocation is deliberately *not* performed here;
        the operator orchestrator must prove those attempts first.  This method
        then removes OS credential-store handles before zeroing their SQLite
        references so a partially failed purge remains retryable rather than
        silently orphaning a usable Keychain secret.
        """

        with self._lock:
            rows = self._conn.execute(
                """SELECT kem_private AS secret FROM relay_identity
                   UNION ALL SELECT sign_private FROM relay_identity
                   UNION ALL SELECT private_key FROM relay_kem_keys
                   UNION ALL SELECT credential FROM hub_routes WHERE credential IS NOT NULL
                   UNION ALL SELECT send_capability FROM push_bindings
                   UNION ALL SELECT bind_token FROM push_binding_exchanges"""
            ).fetchall()
        secrets_to_delete = {
            bytes(row["secret"])
            for row in rows
            if row["secret"] is not None and bytes(row["secret"])
        }
        if self.credential_protector is not None:
            for wrapped in secrets_to_delete:
                # Early v2 databases stored raw 32-byte keys.  They have no
                # external handle; SQLite zeroing below is their erasure path.
                if len(wrapped) == 32 and b":" not in wrapped:
                    continue
                self.credential_protector.delete(wrapped)
        at = self._clock()
        with self.transaction() as conn:
            conn.execute(
                "UPDATE relay_identity SET kem_private=X'',sign_private=X'' WHERE singleton=1"
            )
            conn.execute(
                "UPDATE relay_kem_keys SET private_key=X'',status='revoked',not_after_ms=?",
                (at,),
            )
            conn.execute(
                "UPDATE hub_routes SET credential=NULL,status='revoked',updated_at_ms=?",
                (at,),
            )
            conn.execute(
                "UPDATE push_bindings SET send_capability=X'',status='revoked',updated_at_ms=?",
                (at,),
            )
            conn.execute(
                "UPDATE push_binding_exchanges SET bind_token=X'',state='revoked',updated_at_ms=?",
                (at,),
            )
            conn.execute(
                """UPDATE pair_offers SET pair_secret=X'',transport_token='',
                   state=CASE WHEN state='consumed' THEN state ELSE 'cancelled' END,
                   updated_at_ms=?""",
                (at,),
            )
            conn.execute(
                "UPDATE devices SET status='revoked',revoked_at_ms=COALESCE(revoked_at_ms,?)",
                (at,),
            )
            conn.execute("UPDATE device_keys SET status='revoked'")
            conn.execute("UPDATE hub_grants SET status='revoked'")
            conn.execute(
                """UPDATE approval_capabilities SET state='revoked',updated_at_ms=?
                   WHERE state IN ('pending','claimed','failed_retryable')""",
                (at,),
            )
            conn.execute(
                """UPDATE notification_outbox SET state='failed',
                   last_error_code='local_authority_destroyed',updated_at_ms=?
                   WHERE state='pending'""",
                (at,),
            )

    # -- diagnostics ---------------------------------------------------
    def journal_mode(self) -> str:
        with self._lock:
            return str(self._conn.execute("PRAGMA journal_mode").fetchone()[0]).lower()

    def table_names(self) -> set[str]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        return {row[0] for row in rows}
