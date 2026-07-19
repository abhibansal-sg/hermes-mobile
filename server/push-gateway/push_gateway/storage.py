from __future__ import annotations

import secrets
import threading
from dataclasses import dataclass
from pathlib import Path

from sqlalchemy import (
    BigInteger,
    Column,
    ForeignKey,
    Integer,
    LargeBinary,
    MetaData,
    String,
    Table,
    and_,
    create_engine,
    delete,
    func,
    insert,
    or_,
    select,
    text,
    update,
)
from sqlalchemy.engine import Engine
from sqlalchemy.exc import IntegrityError
from sqlalchemy.pool import StaticPool

from .crypto import EncryptedToken, TokenVault
from .settings import Settings


class StorageError(RuntimeError):
    pass


class NotFound(StorageError):
    pass


class Conflict(StorageError):
    pass


class Forbidden(StorageError):
    pass


class RateLimited(StorageError):
    def __init__(self, code: str, *, retry_after_ms: int | None = None) -> None:
        super().__init__(code)
        self.retry_after_ms = retry_after_ms


@dataclass(frozen=True)
class AttestKeyRecord:
    public_key_der: bytes
    counter: int
    bundle_id: str
    environment: str


@dataclass(frozen=True)
class EndpointRecord:
    endpoint_id: str
    token: EncryptedToken
    environment: str
    bundle_id: str
    status: str
    preview_kem_pub: bytes
    installation_nonce_hash: bytes
    attest_key_hash: bytes


@dataclass(frozen=True)
class BindingRecord:
    binding_id: str
    endpoint_id: str
    allowed_classes: frozenset[str]


@dataclass(frozen=True)
class SendReservation:
    deduplicated: bool
    in_flight: bool = False
    previous_status: str | None = None
    provider_status: int | None = None
    apns_id: str | None = None
    collapse_id: str | None = None
    attempt_token: bytes | None = None


@dataclass(frozen=True)
class AttestationReservation:
    status: str
    owner_token: bytes | None = None


@dataclass(frozen=True)
class RegistrationReceipt:
    endpoint_id: str
    bundle_id: str
    environment: str
    encrypted_response: EncryptedToken
    expires_at_ms: int


@dataclass(frozen=True)
class BindingExchangeReceipt:
    binding_id: str
    endpoint_id: str
    allowed_classes: frozenset[str]
    encrypted_capability: EncryptedToken
    expires_at_ms: int


@dataclass(frozen=True)
class HubActivationReceipt:
    route_id: str
    bundle_id: str
    environment: str
    encrypted_response: EncryptedToken
    expires_at_ms: int


metadata = MetaData()
PUSH_SCHEMA_VERSION = 4
SEND_ATTEMPT_LEASE_MS = 120_000
MAX_PROVIDER_RETRY_AFTER_MS = 3_600_000
_CHALLENGE_ADMISSION_LOCK_ID = 0x4850474348414C4C

schema_migrations = Table(
    "push_schema_migrations",
    metadata,
    Column("version", Integer, primary_key=True),
)

challenges = Table(
    "attest_challenges",
    metadata,
    Column("challenge_hash", LargeBinary, primary_key=True),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("source_hash", LargeBinary, nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
    Column("used_at_ms", BigInteger),
    Column("bound_request_hash", LargeBinary),
    Column("validation_request_hash", LargeBinary),
    Column("validation_owner_token", LargeBinary),
    Column("validation_expires_at_ms", BigInteger),
)

registration_receipts = Table(
    "registration_receipts",
    metadata,
    Column("challenge_hash", LargeBinary, primary_key=True),
    Column("request_hash", LargeBinary, nullable=False),
    Column("key_id_hash", LargeBinary, nullable=False),
    Column("endpoint_id", String(96), nullable=False),
    Column("bundle_id", String(160), nullable=False),
    Column("environment", String(16), nullable=False),
    Column("response_ciphertext", LargeBinary, nullable=False),
    Column("response_nonce", LargeBinary, nullable=False),
    Column("wrapped_data_key", LargeBinary, nullable=False),
    Column("wrap_nonce", LargeBinary, nullable=False),
    Column("key_version", Integer, nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
)

hub_activation_receipts = Table(
    "hub_activation_receipts",
    metadata,
    Column("challenge_hash", LargeBinary, primary_key=True),
    Column("request_hash", LargeBinary, nullable=False),
    Column("key_id_hash", LargeBinary, nullable=False),
    Column("route_id", String(256), nullable=False),
    Column("bundle_id", String(160), nullable=False),
    Column("environment", String(16), nullable=False),
    Column("response_ciphertext", LargeBinary, nullable=False),
    Column("response_nonce", LargeBinary, nullable=False),
    Column("wrapped_data_key", LargeBinary, nullable=False),
    Column("wrap_nonce", LargeBinary, nullable=False),
    Column("key_version", Integer, nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
)

attest_keys = Table(
    "attest_keys",
    metadata,
    Column("key_id_hash", LargeBinary, primary_key=True),
    Column("public_key_der", LargeBinary, nullable=False),
    Column("counter", BigInteger, nullable=False),
    Column("bundle_id", String(160), nullable=False),
    Column("environment", String(16), nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("updated_at_ms", BigInteger, nullable=False),
)

endpoints = Table(
    "endpoints",
    metadata,
    Column("endpoint_id", String(96), primary_key=True),
    Column("token_ciphertext", LargeBinary, nullable=False),
    Column("token_nonce", LargeBinary, nullable=False),
    Column("wrapped_data_key", LargeBinary, nullable=False),
    Column("wrap_nonce", LargeBinary, nullable=False),
    Column("key_version", Integer, nullable=False),
    Column("environment", String(16), nullable=False),
    Column("bundle_id", String(160), nullable=False),
    Column("preview_kem_pub", LargeBinary, nullable=False),
    Column("installation_nonce_hash", LargeBinary, nullable=False, unique=True),
    Column(
        "attest_key_hash",
        LargeBinary,
        ForeignKey("attest_keys.key_id_hash"),
        nullable=False,
    ),
    Column("status", String(16), nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("updated_at_ms", BigInteger, nullable=False),
    Column("disabled_at_ms", BigInteger),
)

bind_tokens = Table(
    "bind_tokens",
    metadata,
    Column("token_hash", LargeBinary, primary_key=True),
    Column(
        "endpoint_id", String(96), ForeignKey("endpoints.endpoint_id"), nullable=False
    ),
    Column("expires_at_ms", BigInteger, nullable=False),
    Column("used_at_ms", BigInteger),
    Column("created_at_ms", BigInteger, nullable=False),
)

bindings = Table(
    "bindings",
    metadata,
    Column("binding_id", String(96), primary_key=True),
    Column(
        "endpoint_id", String(96), ForeignKey("endpoints.endpoint_id"), nullable=False
    ),
    Column("capability_hash", LargeBinary, nullable=False, unique=True),
    Column("allowed_classes", Integer, nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("revoked_at_ms", BigInteger),
)

binding_exchange_authorities = Table(
    "binding_exchange_authorities",
    metadata,
    Column("exchange_id_hash", LargeBinary, primary_key=True),
    Column("bind_token_hash", LargeBinary, nullable=False, unique=True),
    Column(
        "endpoint_id",
        String(96),
        ForeignKey("endpoints.endpoint_id"),
        nullable=False,
    ),
    Column(
        "binding_id",
        String(96),
        ForeignKey("bindings.binding_id"),
        nullable=True,
        unique=True,
    ),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("revoked_at_ms", BigInteger),
)

binding_exchange_receipts = Table(
    "binding_exchange_receipts",
    metadata,
    Column("exchange_id_hash", LargeBinary, primary_key=True),
    Column("bind_token_hash", LargeBinary, nullable=False, unique=True),
    Column("request_hash", LargeBinary, nullable=False),
    Column("binding_id", String(96), nullable=False),
    Column("endpoint_id", String(96), nullable=False),
    Column("allowed_classes", Integer, nullable=False),
    Column("capability_ciphertext", LargeBinary, nullable=False),
    Column("capability_nonce", LargeBinary, nullable=False),
    Column("wrapped_data_key", LargeBinary, nullable=False),
    Column("wrap_nonce", LargeBinary, nullable=False),
    Column("key_version", Integer, nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
)

push_receipts = Table(
    "push_receipts",
    metadata,
    Column(
        "binding_id", String(96), ForeignKey("bindings.binding_id"), primary_key=True
    ),
    Column("notification_id_hash", LargeBinary, primary_key=True),
    Column("request_hash", LargeBinary, nullable=False),
    Column("status", String(24), nullable=False),
    Column("provider_status", Integer),
    Column("apns_id", String(36), nullable=False),
    Column("collapse_id", String(64), nullable=False),
    Column("attempt_count", Integer, nullable=False),
    Column("last_attempt_at_ms", BigInteger, nullable=False),
    Column("provider_retry_not_before_ms", BigInteger),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
    Column("completed_at_ms", BigInteger),
    Column("attempt_token", LargeBinary),
    Column("lease_expires_at_ms", BigInteger),
)

push_send_attempts = Table(
    "push_send_attempts",
    metadata,
    Column(
        "binding_id", String(96), ForeignKey("bindings.binding_id"), primary_key=True
    ),
    Column("notification_id_hash", LargeBinary, primary_key=True),
    Column("attempt_number", Integer, primary_key=True),
    Column("attempted_at_ms", BigInteger, nullable=False),
)

_CLASS_BITS = {"update": 1, "approval": 2, "error": 4}


def class_mask(values: set[str] | frozenset[str] | list[str]) -> int:
    mask = 0
    for value in values:
        mask |= _CLASS_BITS[value]
    return mask


def classes_from_mask(mask: int) -> frozenset[str]:
    return frozenset(name for name, bit in _CLASS_BITS.items() if mask & bit)


class DatabaseStore:
    def __init__(self, settings: Settings, *, engine: Engine | None = None) -> None:
        self.settings = settings
        if engine is None:
            options: dict = {"pool_pre_ping": True}
            if settings.database_url.startswith("sqlite"):
                options["connect_args"] = {"check_same_thread": False}
                if settings.database_url.endswith(":memory:"):
                    options["poolclass"] = StaticPool
                elif settings.database_url.startswith("sqlite:///"):
                    Path(settings.database_url.removeprefix("sqlite:///")).parent.mkdir(
                        parents=True, exist_ok=True
                    )
            engine = create_engine(settings.database_url, **options)
        self.engine = engine
        self._lock = threading.RLock()
        if settings.auto_create_schema:
            metadata.create_all(self.engine)
            with self.engine.begin() as conn:
                existing = conn.execute(
                    select(schema_migrations.c.version).where(
                        schema_migrations.c.version == PUSH_SCHEMA_VERSION
                    )
                ).first()
                if existing is None:
                    conn.execute(
                        insert(schema_migrations).values(version=PUSH_SCHEMA_VERSION)
                    )

    def ready(self) -> bool:
        try:
            with self.engine.connect() as conn:
                version = conn.execute(
                    select(schema_migrations.c.version).where(
                        schema_migrations.c.version == PUSH_SCHEMA_VERSION
                    )
                ).scalar_one_or_none()
                # Selecting the load-bearing columns prevents a stale or
                # partially applied migration from false-greening readiness.
                conn.execute(
                    select(
                        binding_exchange_authorities.c.exchange_id_hash,
                        binding_exchange_authorities.c.bind_token_hash,
                        binding_exchange_authorities.c.binding_id,
                        binding_exchange_authorities.c.revoked_at_ms,
                    ).limit(1)
                ).first()
                conn.execute(
                    select(
                        push_receipts.c.attempt_token,
                        push_receipts.c.lease_expires_at_ms,
                        push_receipts.c.provider_retry_not_before_ms,
                    ).limit(1)
                ).first()
                conn.execute(
                    select(
                        challenges.c.validation_request_hash,
                        challenges.c.validation_owner_token,
                        challenges.c.validation_expires_at_ms,
                    ).limit(1)
                ).first()
                conn.execute(
                    select(
                        push_send_attempts.c.binding_id,
                        push_send_attempts.c.attempt_number,
                        push_send_attempts.c.attempted_at_ms,
                    ).limit(1)
                ).first()
            return version == PUSH_SCHEMA_VERSION
        except Exception:
            return False

    def issue_challenge(
        self,
        *,
        challenge_hash: bytes,
        source_hash: bytes,
        now_ms: int,
        expires_at_ms: int,
    ) -> None:
        with self._lock, self.engine.begin() as conn:
            if conn.dialect.name == "postgresql":
                # Count-and-insert must be one cluster-wide admission decision,
                # not merely process-local.  A try-lock fails closed instead of
                # allowing public requests to queue behind an unbounded DB lock.
                admitted = conn.execute(
                    text("SELECT pg_try_advisory_xact_lock(:lock_id)"),
                    {"lock_id": _CHALLENGE_ADMISSION_LOCK_ID},
                ).scalar_one()
                if not admitted:
                    raise RateLimited(
                        "attest_challenge_admission_busy", retry_after_ms=1000
                    )
            conn.execute(
                delete(challenges).where(
                    and_(
                        challenges.c.expires_at_ms <= now_ms,
                        challenges.c.used_at_ms.is_(None),
                    )
                )
            )
            source_count = conn.execute(
                select(func.count())
                .select_from(challenges)
                .where(
                    and_(
                        challenges.c.source_hash == source_hash,
                        challenges.c.created_at_ms > now_ms - 3_600_000,
                    )
                )
            ).scalar_one()
            if int(source_count) >= self.settings.challenge_per_source_per_hour:
                raise RateLimited("attest_challenge_rate_limited")
            live_count = conn.execute(
                select(func.count())
                .select_from(challenges)
                .where(
                    and_(
                        challenges.c.used_at_ms.is_(None),
                        challenges.c.expires_at_ms > now_ms,
                    )
                )
            ).scalar_one()
            if int(live_count) >= self.settings.maximum_live_challenges:
                raise RateLimited("attest_challenge_capacity_exhausted")
            conn.execute(
                insert(challenges).values(
                    challenge_hash=challenge_hash,
                    source_hash=source_hash,
                    created_at_ms=now_ms,
                    expires_at_ms=expires_at_ms,
                )
            )

    def reserve_attestation_validation(
        self,
        *,
        challenge_hash: bytes,
        request_hash: bytes,
        now_ms: int,
    ) -> AttestationReservation:
        """Cheaply fence one live challenge before any App Attest crypto.

        Reservations last no longer than the challenge itself. Failed
        verification explicitly releases the owner token, while a crashed
        worker cannot cause concurrent validation or permanently consume the
        challenge.
        """

        with self._lock, self.engine.begin() as conn:
            row = (
                conn
                .execute(
                    select(challenges)
                    .where(challenges.c.challenge_hash == challenge_hash)
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if row is None:
                raise Forbidden("attest_challenge_unknown")
            if row["used_at_ms"] is not None:
                if (
                    row["bound_request_hash"] is not None
                    and bytes(row["bound_request_hash"]) == request_hash
                ):
                    return AttestationReservation("completed")
                raise Conflict("attest_challenge_reused")
            if int(row["expires_at_ms"]) <= now_ms:
                raise Forbidden("attest_challenge_expired")

            owner = row["validation_owner_token"]
            reservation_expiry = row["validation_expires_at_ms"]
            if (
                owner is not None
                and reservation_expiry is not None
                and int(reservation_expiry) > now_ms
            ):
                if (
                    row["validation_request_hash"] is not None
                    and bytes(row["validation_request_hash"]) == request_hash
                ):
                    return AttestationReservation("in_progress")
                raise Conflict("attest_challenge_request_conflict")

            owner_token = secrets.token_bytes(32)
            conn.execute(
                update(challenges)
                .where(challenges.c.challenge_hash == challenge_hash)
                .values(
                    validation_request_hash=request_hash,
                    validation_owner_token=owner_token,
                    validation_expires_at_ms=int(row["expires_at_ms"]),
                )
            )
            return AttestationReservation("acquired", owner_token)

    def release_attestation_validation(
        self, *, challenge_hash: bytes, owner_token: bytes
    ) -> bool:
        if not isinstance(owner_token, bytes) or len(owner_token) != 32:
            raise ValueError("attestation reservation owner token must be 32 bytes")
        with self._lock, self.engine.begin() as conn:
            result = conn.execute(
                update(challenges)
                .where(
                    and_(
                        challenges.c.challenge_hash == challenge_hash,
                        challenges.c.used_at_ms.is_(None),
                        challenges.c.validation_owner_token == owner_token,
                    )
                )
                .values(
                    validation_request_hash=None,
                    validation_owner_token=None,
                    validation_expires_at_ms=None,
                )
            )
            return result.rowcount == 1

    def get_attest_key(self, key_id_hash: bytes) -> AttestKeyRecord | None:
        with self.engine.connect() as conn:
            row = (
                conn
                .execute(
                    select(attest_keys).where(attest_keys.c.key_id_hash == key_id_hash)
                )
                .mappings()
                .first()
            )
        if row is None:
            return None
        return AttestKeyRecord(
            public_key_der=bytes(row["public_key_der"]),
            counter=int(row["counter"]),
            bundle_id=row["bundle_id"],
            environment=row["environment"],
        )

    @staticmethod
    def _consume_attestation(
        conn,
        *,
        challenge_hash: bytes,
        request_hash: bytes,
        key_id_hash: bytes,
        public_key_der: bytes,
        counter: int,
        bundle_id: str,
        environment: str,
        reservation_token: bytes,
        now_ms: int,
    ) -> bool:
        challenge = (
            conn
            .execute(
                select(challenges)
                .where(challenges.c.challenge_hash == challenge_hash)
                .with_for_update()
            )
            .mappings()
            .first()
        )
        if challenge is None:
            raise Forbidden("attest_challenge_unknown")
        if challenge["used_at_ms"] is not None:
            if (
                challenge["bound_request_hash"] is not None
                and bytes(challenge["bound_request_hash"]) == request_hash
            ):
                return False
            raise Conflict("attest_challenge_reused")
        if int(challenge["expires_at_ms"]) <= now_ms:
            raise Forbidden("attest_challenge_expired")
        if (
            challenge["validation_owner_token"] is None
            or not secrets.compare_digest(
                bytes(challenge["validation_owner_token"]), reservation_token
            )
            or challenge["validation_request_hash"] is None
            or not secrets.compare_digest(
                bytes(challenge["validation_request_hash"]), request_hash
            )
        ):
            raise Conflict("attest_validation_reservation_lost")
        key = (
            conn
            .execute(
                select(attest_keys)
                .where(attest_keys.c.key_id_hash == key_id_hash)
                .with_for_update()
            )
            .mappings()
            .first()
        )
        if key is None:
            conn.execute(
                insert(attest_keys).values(
                    key_id_hash=key_id_hash,
                    public_key_der=public_key_der,
                    counter=counter,
                    bundle_id=bundle_id,
                    environment=environment,
                    created_at_ms=now_ms,
                    updated_at_ms=now_ms,
                )
            )
        else:
            if (
                bytes(key["public_key_der"]) != public_key_der
                or key["bundle_id"] != bundle_id
                or key["environment"] != environment
            ):
                raise Forbidden("attest_key_binding_mismatch")
            if counter <= int(key["counter"]):
                raise Conflict("attest_counter_rollback")
            conn.execute(
                update(attest_keys)
                .where(attest_keys.c.key_id_hash == key_id_hash)
                .values(counter=counter, updated_at_ms=now_ms)
            )
        conn.execute(
            update(challenges)
            .where(challenges.c.challenge_hash == challenge_hash)
            .values(
                used_at_ms=now_ms,
                bound_request_hash=request_hash,
                validation_request_hash=None,
                validation_owner_token=None,
                validation_expires_at_ms=None,
            )
        )
        return True

    @staticmethod
    def _registration_receipt(row) -> RegistrationReceipt:
        return RegistrationReceipt(
            endpoint_id=str(row["endpoint_id"]),
            bundle_id=str(row["bundle_id"]),
            environment=str(row["environment"]),
            encrypted_response=EncryptedToken(
                ciphertext=bytes(row["response_ciphertext"]),
                nonce=bytes(row["response_nonce"]),
                wrapped_key=bytes(row["wrapped_data_key"]),
                wrap_nonce=bytes(row["wrap_nonce"]),
                key_version=int(row["key_version"]),
            ),
            expires_at_ms=int(row["expires_at_ms"]),
        )

    def get_registration_receipt(
        self,
        *,
        challenge_hash: bytes,
        request_hash: bytes,
        key_id_hash: bytes,
        now_ms: int,
    ) -> RegistrationReceipt | None:
        with self._lock, self.engine.connect() as conn:
            row = (
                conn
                .execute(
                    select(registration_receipts).where(
                        registration_receipts.c.challenge_hash == challenge_hash
                    )
                )
                .mappings()
                .first()
            )
        if row is None:
            return None
        if (
            int(row["expires_at_ms"]) <= now_ms
            or bytes(row["request_hash"]) != request_hash
            or bytes(row["key_id_hash"]) != key_id_hash
        ):
            raise Conflict("registration_retry_conflict")
        return self._registration_receipt(row)

    @staticmethod
    def _hub_activation_receipt(row) -> HubActivationReceipt:
        return HubActivationReceipt(
            route_id=str(row["route_id"]),
            bundle_id=str(row["bundle_id"]),
            environment=str(row["environment"]),
            encrypted_response=EncryptedToken(
                ciphertext=bytes(row["response_ciphertext"]),
                nonce=bytes(row["response_nonce"]),
                wrapped_key=bytes(row["wrapped_data_key"]),
                wrap_nonce=bytes(row["wrap_nonce"]),
                key_version=int(row["key_version"]),
            ),
            expires_at_ms=int(row["expires_at_ms"]),
        )

    def get_hub_activation_receipt(
        self,
        *,
        challenge_hash: bytes,
        request_hash: bytes,
        key_id_hash: bytes,
        now_ms: int,
    ) -> HubActivationReceipt | None:
        with self._lock, self.engine.connect() as conn:
            row = (
                conn
                .execute(
                    select(hub_activation_receipts).where(
                        hub_activation_receipts.c.challenge_hash == challenge_hash
                    )
                )
                .mappings()
                .first()
            )
        if row is None:
            return None
        if (
            int(row["expires_at_ms"]) <= now_ms
            or bytes(row["request_hash"]) != request_hash
            or bytes(row["key_id_hash"]) != key_id_hash
        ):
            raise Conflict("hub_activation_retry_conflict")
        return self._hub_activation_receipt(row)

    def consume_hub_activation(
        self,
        *,
        challenge_hash: bytes,
        request_hash: bytes,
        key_id_hash: bytes,
        public_key_der: bytes,
        counter: int,
        route_id: str,
        bundle_id: str,
        environment: str,
        encrypted_response: EncryptedToken,
        response_expires_at_ms: int,
        reservation_token: bytes,
        now_ms: int,
    ) -> tuple[HubActivationReceipt, bool]:
        with self._lock, self.engine.begin() as conn:
            conn.execute(
                select(challenges.c.challenge_hash)
                .where(challenges.c.challenge_hash == challenge_hash)
                .with_for_update()
            ).first()
            prior = (
                conn
                .execute(
                    select(hub_activation_receipts).where(
                        hub_activation_receipts.c.challenge_hash == challenge_hash
                    )
                )
                .mappings()
                .first()
            )
            if prior is not None:
                if (
                    int(prior["expires_at_ms"]) <= now_ms
                    or bytes(prior["request_hash"]) != request_hash
                    or bytes(prior["key_id_hash"]) != key_id_hash
                ):
                    raise Conflict("hub_activation_retry_conflict")
                return self._hub_activation_receipt(prior), False
            consumed = self._consume_attestation(
                conn,
                challenge_hash=challenge_hash,
                request_hash=request_hash,
                key_id_hash=key_id_hash,
                public_key_der=public_key_der,
                counter=counter,
                bundle_id=bundle_id,
                environment=environment,
                reservation_token=reservation_token,
                now_ms=now_ms,
            )
            if not consumed:
                raise Conflict("hub_activation_receipt_unavailable")
            conn.execute(
                insert(hub_activation_receipts).values(
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    key_id_hash=key_id_hash,
                    route_id=route_id,
                    bundle_id=bundle_id,
                    environment=environment,
                    response_ciphertext=encrypted_response.ciphertext,
                    response_nonce=encrypted_response.nonce,
                    wrapped_data_key=encrypted_response.wrapped_key,
                    wrap_nonce=encrypted_response.wrap_nonce,
                    key_version=encrypted_response.key_version,
                    expires_at_ms=response_expires_at_ms,
                )
            )
            return self._hub_activation_receipt({
                "route_id": route_id,
                "bundle_id": bundle_id,
                "environment": environment,
                "response_ciphertext": encrypted_response.ciphertext,
                "response_nonce": encrypted_response.nonce,
                "wrapped_data_key": encrypted_response.wrapped_key,
                "wrap_nonce": encrypted_response.wrap_nonce,
                "key_version": encrypted_response.key_version,
                "expires_at_ms": response_expires_at_ms,
            }), True

    def register_endpoint(
        self,
        *,
        challenge_hash: bytes,
        request_hash: bytes,
        key_id_hash: bytes,
        public_key_der: bytes,
        counter: int,
        endpoint_id: str,
        encrypted_token: EncryptedToken,
        environment: str,
        bundle_id: str,
        preview_kem_pub: bytes,
        installation_nonce_hash: bytes,
        bind_token_hash: bytes,
        bind_expires_at_ms: int,
        encrypted_response: EncryptedToken,
        response_expires_at_ms: int,
        reservation_token: bytes,
        now_ms: int,
    ) -> tuple[RegistrationReceipt, bool]:
        with self._lock, self.engine.begin() as conn:
            challenge = (
                conn
                .execute(
                    select(challenges)
                    .where(challenges.c.challenge_hash == challenge_hash)
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if challenge is None:
                raise Forbidden("attest_challenge_unknown")
            receipt = (
                conn
                .execute(
                    select(registration_receipts).where(
                        registration_receipts.c.challenge_hash == challenge_hash
                    )
                )
                .mappings()
                .first()
            )
            if receipt is not None:
                if (
                    int(receipt["expires_at_ms"]) <= now_ms
                    or bytes(receipt["request_hash"]) != request_hash
                    or bytes(receipt["key_id_hash"]) != key_id_hash
                ):
                    raise Conflict("registration_retry_conflict")
                return self._registration_receipt(receipt), False
            consumed = self._consume_attestation(
                conn,
                challenge_hash=challenge_hash,
                request_hash=request_hash,
                key_id_hash=key_id_hash,
                public_key_der=public_key_der,
                counter=counter,
                bundle_id=bundle_id,
                environment=environment,
                reservation_token=reservation_token,
                now_ms=now_ms,
            )
            if not consumed:
                raise Conflict("registration_receipt_unavailable")
            existing = (
                conn
                .execute(
                    select(endpoints)
                    .where(
                        endpoints.c.installation_nonce_hash == installation_nonce_hash
                    )
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if existing is not None:
                if bytes(existing["attest_key_hash"]) != key_id_hash:
                    raise Conflict("installation_key_mismatch")
                if (
                    existing["endpoint_id"] != endpoint_id
                    or existing["bundle_id"] != bundle_id
                    or existing["environment"] != environment
                    or bytes(existing["preview_kem_pub"]) != preview_kem_pub
                    or existing["status"] == "revoked"
                ):
                    raise Forbidden("installation_recovery_binding_mismatch")
                # A successful, newly attested recovery rotates enrollment
                # authority as well as the APNs token. Retain old rows as
                # durable one-time tombstones, but make every earlier unused
                # bind token unexchangeable before inserting the replacement.
                conn.execute(
                    update(bind_tokens)
                    .where(
                        and_(
                            bind_tokens.c.endpoint_id == endpoint_id,
                            bind_tokens.c.used_at_ms.is_(None),
                        )
                    )
                    .values(used_at_ms=now_ms)
                )
                conn.execute(
                    update(endpoints)
                    .where(endpoints.c.endpoint_id == endpoint_id)
                    .values(
                        token_ciphertext=encrypted_token.ciphertext,
                        token_nonce=encrypted_token.nonce,
                        wrapped_data_key=encrypted_token.wrapped_key,
                        wrap_nonce=encrypted_token.wrap_nonce,
                        key_version=encrypted_token.key_version,
                        status="active",
                        updated_at_ms=now_ms,
                        disabled_at_ms=None,
                    )
                )
            else:
                conn.execute(
                    insert(endpoints).values(
                        endpoint_id=endpoint_id,
                        token_ciphertext=encrypted_token.ciphertext,
                        token_nonce=encrypted_token.nonce,
                        wrapped_data_key=encrypted_token.wrapped_key,
                        wrap_nonce=encrypted_token.wrap_nonce,
                        key_version=encrypted_token.key_version,
                        environment=environment,
                        bundle_id=bundle_id,
                        preview_kem_pub=preview_kem_pub,
                        installation_nonce_hash=installation_nonce_hash,
                        attest_key_hash=key_id_hash,
                        status="active",
                        created_at_ms=now_ms,
                        updated_at_ms=now_ms,
                    )
                )
            conn.execute(
                insert(bind_tokens).values(
                    token_hash=bind_token_hash,
                    endpoint_id=endpoint_id,
                    expires_at_ms=bind_expires_at_ms,
                    created_at_ms=now_ms,
                )
            )
            conn.execute(
                insert(registration_receipts).values(
                    challenge_hash=challenge_hash,
                    request_hash=request_hash,
                    key_id_hash=key_id_hash,
                    endpoint_id=endpoint_id,
                    bundle_id=bundle_id,
                    environment=environment,
                    response_ciphertext=encrypted_response.ciphertext,
                    response_nonce=encrypted_response.nonce,
                    wrapped_data_key=encrypted_response.wrapped_key,
                    wrap_nonce=encrypted_response.wrap_nonce,
                    key_version=encrypted_response.key_version,
                    expires_at_ms=response_expires_at_ms,
                )
            )
            return self._registration_receipt({
                "endpoint_id": endpoint_id,
                "bundle_id": bundle_id,
                "environment": environment,
                "response_ciphertext": encrypted_response.ciphertext,
                "response_nonce": encrypted_response.nonce,
                "wrapped_data_key": encrypted_response.wrapped_key,
                "wrap_nonce": encrypted_response.wrap_nonce,
                "key_version": encrypted_response.key_version,
                "expires_at_ms": response_expires_at_ms,
            }), True

    def refresh_endpoint(
        self,
        *,
        endpoint_id: str,
        challenge_hash: bytes,
        request_hash: bytes,
        key_id_hash: bytes,
        public_key_der: bytes,
        counter: int,
        encrypted_token: EncryptedToken,
        reservation_token: bytes,
        now_ms: int,
    ) -> None:
        with self._lock, self.engine.begin() as conn:
            endpoint = (
                conn
                .execute(
                    select(endpoints)
                    .where(endpoints.c.endpoint_id == endpoint_id)
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if endpoint is None:
                raise NotFound("endpoint_not_found")
            if endpoint["status"] == "revoked":
                raise Forbidden("endpoint_revoked")
            if bytes(endpoint["attest_key_hash"]) != key_id_hash:
                raise Conflict("installation_key_mismatch")
            self._consume_attestation(
                conn,
                challenge_hash=challenge_hash,
                request_hash=request_hash,
                key_id_hash=key_id_hash,
                public_key_der=public_key_der,
                counter=counter,
                bundle_id=endpoint["bundle_id"],
                environment=endpoint["environment"],
                reservation_token=reservation_token,
                now_ms=now_ms,
            )
            conn.execute(
                update(endpoints)
                .where(endpoints.c.endpoint_id == endpoint_id)
                .values(
                    token_ciphertext=encrypted_token.ciphertext,
                    token_nonce=encrypted_token.nonce,
                    wrapped_data_key=encrypted_token.wrapped_key,
                    wrap_nonce=encrypted_token.wrap_nonce,
                    key_version=encrypted_token.key_version,
                    status="active",
                    updated_at_ms=now_ms,
                    disabled_at_ms=None,
                )
            )

    def exchange_binding(
        self,
        *,
        bind_token_hash: bytes,
        exchange_id_hash: bytes,
        request_hash: bytes,
        binding_id: str,
        capability_hash: bytes,
        encrypted_capability: EncryptedToken,
        allowed_classes: frozenset[str],
        receipt_expires_at_ms: int,
        now_ms: int,
    ) -> tuple[BindingExchangeReceipt, bool]:
        with self._lock, self.engine.begin() as conn:
            authority = (
                conn
                .execute(
                    select(binding_exchange_authorities)
                    .where(
                        or_(
                            binding_exchange_authorities.c.exchange_id_hash
                            == exchange_id_hash,
                            binding_exchange_authorities.c.bind_token_hash
                            == bind_token_hash,
                        )
                    )
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if authority is not None:
                if (
                    bytes(authority["exchange_id_hash"]) != exchange_id_hash
                    or bytes(authority["bind_token_hash"]) != bind_token_hash
                ):
                    raise Conflict("binding_exchange_retry_conflict")
                if authority["revoked_at_ms"] is not None:
                    raise Forbidden("binding_exchange_revoked")
            receipt = (
                conn
                .execute(
                    select(binding_exchange_receipts)
                    .where(
                        or_(
                            binding_exchange_receipts.c.exchange_id_hash
                            == exchange_id_hash,
                            binding_exchange_receipts.c.bind_token_hash
                            == bind_token_hash,
                        )
                    )
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if receipt is not None:
                if (
                    int(receipt["expires_at_ms"]) <= now_ms
                    or bytes(receipt["exchange_id_hash"]) != exchange_id_hash
                    or bytes(receipt["bind_token_hash"]) != bind_token_hash
                    or bytes(receipt["request_hash"]) != request_hash
                ):
                    raise Conflict("binding_exchange_retry_conflict")
                if authority is None:
                    # Backfill a durable association for databases upgraded
                    # while a bounded response receipt is still live.
                    conn.execute(
                        insert(binding_exchange_authorities).values(
                            exchange_id_hash=exchange_id_hash,
                            bind_token_hash=bind_token_hash,
                            endpoint_id=receipt["endpoint_id"],
                            binding_id=receipt["binding_id"],
                            created_at_ms=now_ms,
                        )
                    )
                return self._binding_exchange_receipt(receipt), False
            if authority is not None:
                # The bounded capability response is gone.  Never mint or
                # reveal a replacement, but retain the authority row so the
                # original exchange secrets can still revoke the binding.
                raise Conflict("binding_exchange_receipt_expired")
            token = (
                conn
                .execute(
                    select(bind_tokens.c.endpoint_id).where(
                        bind_tokens.c.token_hash == bind_token_hash
                    )
                )
                .mappings()
                .first()
            )
            if token is None:
                raise Forbidden("bind_token_invalid")
            # Recovery takes the endpoint lock before tombstoning unused bind
            # tokens. Match that order so an old exchange either commits fully
            # before recovery, or observes the durable tombstone afterward.
            endpoint = conn.execute(
                select(endpoints.c.status)
                .where(endpoints.c.endpoint_id == token["endpoint_id"])
                .with_for_update()
            ).first()
            token = (
                conn
                .execute(
                    select(bind_tokens)
                    .where(bind_tokens.c.token_hash == bind_token_hash)
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if token is None:
                raise Forbidden("bind_token_invalid")
            if token["used_at_ms"] is not None:
                # Another worker may have committed the same exchange while
                # this transaction waited for the one-time token lock.
                late_authority = (
                    conn
                    .execute(
                        select(binding_exchange_authorities).where(
                            binding_exchange_authorities.c.bind_token_hash
                            == bind_token_hash
                        )
                    )
                    .mappings()
                    .first()
                )
                late_receipt = (
                    conn
                    .execute(
                        select(binding_exchange_receipts).where(
                            binding_exchange_receipts.c.bind_token_hash
                            == bind_token_hash
                        )
                    )
                    .mappings()
                    .first()
                )
                if (
                    late_authority is not None
                    and late_authority["revoked_at_ms"] is not None
                    and bytes(late_authority["exchange_id_hash"]) == exchange_id_hash
                ):
                    raise Forbidden("binding_exchange_revoked")
                if (
                    late_authority is None
                    or late_receipt is None
                    or bytes(late_authority["exchange_id_hash"]) != exchange_id_hash
                    or bytes(late_receipt["request_hash"]) != request_hash
                    or int(late_receipt["expires_at_ms"]) <= now_ms
                ):
                    raise Conflict("bind_token_reused")
                return self._binding_exchange_receipt(late_receipt), False
            if int(token["expires_at_ms"]) <= now_ms:
                raise Forbidden("bind_token_expired")
            if endpoint is None or endpoint.status != "active":
                raise Forbidden("endpoint_not_active")
            conn.execute(
                insert(bindings).values(
                    binding_id=binding_id,
                    endpoint_id=token["endpoint_id"],
                    capability_hash=capability_hash,
                    allowed_classes=class_mask(allowed_classes),
                    created_at_ms=now_ms,
                )
            )
            conn.execute(
                insert(binding_exchange_authorities).values(
                    exchange_id_hash=exchange_id_hash,
                    bind_token_hash=bind_token_hash,
                    endpoint_id=token["endpoint_id"],
                    binding_id=binding_id,
                    created_at_ms=now_ms,
                )
            )
            conn.execute(
                update(bind_tokens)
                .where(bind_tokens.c.token_hash == bind_token_hash)
                .values(used_at_ms=now_ms)
            )
            conn.execute(
                insert(binding_exchange_receipts).values(
                    exchange_id_hash=exchange_id_hash,
                    bind_token_hash=bind_token_hash,
                    request_hash=request_hash,
                    binding_id=binding_id,
                    endpoint_id=token["endpoint_id"],
                    allowed_classes=class_mask(allowed_classes),
                    capability_ciphertext=encrypted_capability.ciphertext,
                    capability_nonce=encrypted_capability.nonce,
                    wrapped_data_key=encrypted_capability.wrapped_key,
                    wrap_nonce=encrypted_capability.wrap_nonce,
                    key_version=encrypted_capability.key_version,
                    expires_at_ms=receipt_expires_at_ms,
                )
            )
            return self._binding_exchange_receipt({
                "binding_id": binding_id,
                "endpoint_id": token["endpoint_id"],
                "allowed_classes": class_mask(allowed_classes),
                "capability_ciphertext": encrypted_capability.ciphertext,
                "capability_nonce": encrypted_capability.nonce,
                "wrapped_data_key": encrypted_capability.wrapped_key,
                "wrap_nonce": encrypted_capability.wrap_nonce,
                "key_version": encrypted_capability.key_version,
                "expires_at_ms": receipt_expires_at_ms,
            }), True

    def revoke_binding_exchange(
        self,
        *,
        bind_token_hash: bytes,
        exchange_id_hash: bytes,
        now_ms: int,
    ) -> None:
        """Consume an exchange and revoke its binding without revealing it.

        The durable authority row is intentionally not purged: it contains
        only keyed hashes and is bounded to one row per one-time bind token,
        matching the lifetime of the endpoint/binding records it protects.
        A pre-commit tombstone also prevents a delayed exchange request from
        creating authority after cancellation.
        """

        with self._lock, self.engine.begin() as conn:
            authority = (
                conn
                .execute(
                    select(binding_exchange_authorities)
                    .where(
                        or_(
                            binding_exchange_authorities.c.exchange_id_hash
                            == exchange_id_hash,
                            binding_exchange_authorities.c.bind_token_hash
                            == bind_token_hash,
                        )
                    )
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if authority is not None:
                if (
                    bytes(authority["exchange_id_hash"]) != exchange_id_hash
                    or bytes(authority["bind_token_hash"]) != bind_token_hash
                ):
                    raise Forbidden("binding_exchange_auth_mismatch")
            else:
                token = (
                    conn
                    .execute(
                        select(bind_tokens)
                        .where(bind_tokens.c.token_hash == bind_token_hash)
                        .with_for_update()
                    )
                    .mappings()
                    .first()
                )
                if token is None or token["used_at_ms"] is not None:
                    # Preserve identical concurrent retry semantics after
                    # waiting for another worker's token transaction.
                    authority = (
                        conn
                        .execute(
                            select(binding_exchange_authorities).where(
                                binding_exchange_authorities.c.bind_token_hash
                                == bind_token_hash
                            )
                        )
                        .mappings()
                        .first()
                    )
                    if (
                        authority is None
                        or bytes(authority["exchange_id_hash"]) != exchange_id_hash
                    ):
                        raise Forbidden("binding_exchange_auth_mismatch")
                else:
                    conn.execute(
                        insert(binding_exchange_authorities).values(
                            exchange_id_hash=exchange_id_hash,
                            bind_token_hash=bind_token_hash,
                            endpoint_id=token["endpoint_id"],
                            binding_id=None,
                            created_at_ms=now_ms,
                            revoked_at_ms=now_ms,
                        )
                    )
                    conn.execute(
                        update(bind_tokens)
                        .where(bind_tokens.c.token_hash == bind_token_hash)
                        .values(used_at_ms=now_ms)
                    )
                    return

            binding_id = authority["binding_id"]
            if binding_id is not None:
                conn.execute(
                    update(bindings)
                    .where(
                        and_(
                            bindings.c.binding_id == binding_id,
                            bindings.c.revoked_at_ms.is_(None),
                        )
                    )
                    .values(revoked_at_ms=now_ms)
                )
            conn.execute(
                update(binding_exchange_authorities)
                .where(
                    binding_exchange_authorities.c.exchange_id_hash == exchange_id_hash
                )
                .values(
                    revoked_at_ms=func.coalesce(
                        binding_exchange_authorities.c.revoked_at_ms, now_ms
                    )
                )
            )
            conn.execute(
                update(bind_tokens)
                .where(bind_tokens.c.token_hash == bind_token_hash)
                .values(used_at_ms=func.coalesce(bind_tokens.c.used_at_ms, now_ms))
            )

    @staticmethod
    def _binding_exchange_receipt(row) -> BindingExchangeReceipt:
        return BindingExchangeReceipt(
            binding_id=str(row["binding_id"]),
            endpoint_id=str(row["endpoint_id"]),
            allowed_classes=classes_from_mask(int(row["allowed_classes"])),
            encrypted_capability=EncryptedToken(
                ciphertext=bytes(row["capability_ciphertext"]),
                nonce=bytes(row["capability_nonce"]),
                wrapped_key=bytes(row["wrapped_data_key"]),
                wrap_nonce=bytes(row["wrap_nonce"]),
                key_version=int(row["key_version"]),
            ),
            expires_at_ms=int(row["expires_at_ms"]),
        )

    def authenticate_binding(self, capability_hash: bytes) -> BindingRecord | None:
        with self.engine.connect() as conn:
            row = (
                conn
                .execute(
                    select(
                        bindings.c.binding_id,
                        bindings.c.endpoint_id,
                        bindings.c.allowed_classes,
                        endpoints.c.status.label("endpoint_status"),
                    )
                    .select_from(
                        bindings.join(
                            endpoints, bindings.c.endpoint_id == endpoints.c.endpoint_id
                        )
                    )
                    .where(
                        and_(
                            bindings.c.capability_hash == capability_hash,
                            bindings.c.revoked_at_ms.is_(None),
                        )
                    )
                )
                .mappings()
                .first()
            )
        if row is None or row["endpoint_status"] != "active":
            return None
        return BindingRecord(
            binding_id=row["binding_id"],
            endpoint_id=row["endpoint_id"],
            allowed_classes=classes_from_mask(int(row["allowed_classes"])),
        )

    def revoke_binding(
        self, *, binding_id: str, capability_hash: bytes, now_ms: int
    ) -> bool:
        with self._lock, self.engine.begin() as conn:
            row = (
                conn
                .execute(
                    select(bindings)
                    .where(bindings.c.binding_id == binding_id)
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if row is None:
                raise NotFound("binding_not_found")
            if bytes(row["capability_hash"]) != capability_hash:
                raise Forbidden("binding_auth_mismatch")
            if row["revoked_at_ms"] is not None:
                return False
            conn.execute(
                update(bindings)
                .where(bindings.c.binding_id == binding_id)
                .values(revoked_at_ms=now_ms)
            )
            return True

    def get_endpoint(self, endpoint_id: str) -> EndpointRecord | None:
        with self.engine.connect() as conn:
            row = (
                conn
                .execute(
                    select(endpoints).where(endpoints.c.endpoint_id == endpoint_id)
                )
                .mappings()
                .first()
            )
        if row is None:
            return None
        return EndpointRecord(
            endpoint_id=row["endpoint_id"],
            token=EncryptedToken(
                ciphertext=bytes(row["token_ciphertext"]),
                nonce=bytes(row["token_nonce"]),
                wrapped_key=bytes(row["wrapped_data_key"]),
                wrap_nonce=bytes(row["wrap_nonce"]),
                key_version=int(row["key_version"]),
            ),
            environment=row["environment"],
            bundle_id=row["bundle_id"],
            status=row["status"],
            preview_kem_pub=bytes(row["preview_kem_pub"]),
            installation_nonce_hash=bytes(row["installation_nonce_hash"]),
            attest_key_hash=bytes(row["attest_key_hash"]),
        )

    def get_endpoint_by_installation(
        self, installation_nonce_hash: bytes
    ) -> EndpointRecord | None:
        with self.engine.connect() as conn:
            endpoint_id = conn.execute(
                select(endpoints.c.endpoint_id).where(
                    endpoints.c.installation_nonce_hash == installation_nonce_hash
                )
            ).scalar_one_or_none()
        return self.get_endpoint(str(endpoint_id)) if endpoint_id is not None else None

    def token_key_versions_in_use(self) -> frozenset[int]:
        versions: set[int] = set()
        with self.engine.connect() as conn:
            for table in (
                endpoints,
                registration_receipts,
                hub_activation_receipts,
                binding_exchange_receipts,
            ):
                versions.update(
                    int(value)
                    for value in conn.execute(
                        select(table.c.key_version).distinct()
                    ).scalars()
                )
        return frozenset(versions)

    def assert_token_keys_available(self, available_versions: frozenset[int]) -> None:
        missing = self.token_key_versions_in_use() - available_versions
        if missing:
            rendered = ", ".join(str(version) for version in sorted(missing))
            raise ValueError(
                "token key retirement rejected; encrypted rows still require "
                f"version(s): {rendered}"
            )

    @staticmethod
    def _encrypted_from_row(
        row,
        *,
        ciphertext_column: str,
        nonce_column: str,
    ) -> EncryptedToken:
        return EncryptedToken(
            ciphertext=bytes(row[ciphertext_column]),
            nonce=bytes(row[nonce_column]),
            wrapped_key=bytes(row["wrapped_data_key"]),
            wrap_nonce=bytes(row["wrap_nonce"]),
            key_version=int(row["key_version"]),
        )

    def rewrap_token_keys(self, vault: TokenVault) -> dict[str, int]:
        """Atomically move every retained envelope to the current key version."""

        counts = {
            "endpoints": 0,
            "registration_receipts": 0,
            "hub_activation_receipts": 0,
            "binding_exchange_receipts": 0,
        }
        self.assert_token_keys_available(vault.available_versions)
        with self._lock, self.engine.begin() as conn:
            endpoint_rows = (
                conn.execute(select(endpoints).with_for_update()).mappings().all()
            )
            for row in endpoint_rows:
                encrypted = self._encrypted_from_row(
                    row,
                    ciphertext_column="token_ciphertext",
                    nonce_column="token_nonce",
                )
                if encrypted.key_version == vault.current_version:
                    continue
                rotated = vault.rewrap(encrypted, endpoint_id=str(row["endpoint_id"]))
                conn.execute(
                    update(endpoints)
                    .where(endpoints.c.endpoint_id == row["endpoint_id"])
                    .values(
                        wrapped_data_key=rotated.wrapped_key,
                        wrap_nonce=rotated.wrap_nonce,
                        key_version=rotated.key_version,
                    )
                )
                counts["endpoints"] += 1

            registration_rows = (
                conn
                .execute(select(registration_receipts).with_for_update())
                .mappings()
                .all()
            )
            for row in registration_rows:
                encrypted = self._encrypted_from_row(
                    row,
                    ciphertext_column="response_ciphertext",
                    nonce_column="response_nonce",
                )
                if encrypted.key_version == vault.current_version:
                    continue
                rotated = vault.rewrap(encrypted, endpoint_id=str(row["endpoint_id"]))
                conn.execute(
                    update(registration_receipts)
                    .where(
                        registration_receipts.c.challenge_hash == row["challenge_hash"]
                    )
                    .values(
                        wrapped_data_key=rotated.wrapped_key,
                        wrap_nonce=rotated.wrap_nonce,
                        key_version=rotated.key_version,
                    )
                )
                counts["registration_receipts"] += 1

            activation_rows = (
                conn
                .execute(select(hub_activation_receipts).with_for_update())
                .mappings()
                .all()
            )
            for row in activation_rows:
                encrypted = self._encrypted_from_row(
                    row,
                    ciphertext_column="response_ciphertext",
                    nonce_column="response_nonce",
                )
                if encrypted.key_version == vault.current_version:
                    continue
                rotated = vault.rewrap(encrypted, endpoint_id=str(row["route_id"]))
                conn.execute(
                    update(hub_activation_receipts)
                    .where(
                        hub_activation_receipts.c.challenge_hash
                        == row["challenge_hash"]
                    )
                    .values(
                        wrapped_data_key=rotated.wrapped_key,
                        wrap_nonce=rotated.wrap_nonce,
                        key_version=rotated.key_version,
                    )
                )
                counts["hub_activation_receipts"] += 1

            binding_rows = (
                conn
                .execute(select(binding_exchange_receipts).with_for_update())
                .mappings()
                .all()
            )
            for row in binding_rows:
                encrypted = self._encrypted_from_row(
                    row,
                    ciphertext_column="capability_ciphertext",
                    nonce_column="capability_nonce",
                )
                if encrypted.key_version == vault.current_version:
                    continue
                rotated = vault.rewrap(encrypted, endpoint_id=str(row["binding_id"]))
                conn.execute(
                    update(binding_exchange_receipts)
                    .where(
                        binding_exchange_receipts.c.exchange_id_hash
                        == row["exchange_id_hash"]
                    )
                    .values(
                        wrapped_data_key=rotated.wrapped_key,
                        wrap_nonce=rotated.wrap_nonce,
                        key_version=rotated.key_version,
                    )
                )
                counts["binding_exchange_receipts"] += 1
        counts["total"] = sum(counts.values())
        return counts

    def reserve_send(
        self,
        *,
        binding_id: str,
        notification_id_hash: bytes,
        request_hash: bytes,
        apns_id: str,
        collapse_id: str,
        now_ms: int,
        expires_at_ms: int,
    ) -> SendReservation:
        with self._lock, self.engine.begin() as conn:
            binding = conn.execute(
                select(bindings.c.binding_id)
                .where(
                    and_(
                        bindings.c.binding_id == binding_id,
                        bindings.c.revoked_at_ms.is_(None),
                    )
                )
                .with_for_update()
            ).first()
            if binding is None:
                raise Forbidden("binding_revoked")

            def enforce_attempt_quota() -> None:
                hour_count = conn.execute(
                    select(func.count())
                    .select_from(push_send_attempts)
                    .where(
                        and_(
                            push_send_attempts.c.binding_id == binding_id,
                            push_send_attempts.c.attempted_at_ms > now_ms - 3_600_000,
                        )
                    )
                ).scalar_one()
                day_count = conn.execute(
                    select(func.count())
                    .select_from(push_send_attempts)
                    .where(
                        and_(
                            push_send_attempts.c.binding_id == binding_id,
                            push_send_attempts.c.attempted_at_ms > now_ms - 86_400_000,
                        )
                    )
                ).scalar_one()
                if (
                    int(hour_count) >= self.settings.max_sends_per_hour
                    or int(day_count) >= self.settings.max_sends_per_day
                ):
                    raise RateLimited("send_attempt_quota_exhausted")

            def record_attempt(attempt_number: int) -> None:
                conn.execute(
                    insert(push_send_attempts).values(
                        binding_id=binding_id,
                        notification_id_hash=notification_id_hash,
                        attempt_number=attempt_number,
                        attempted_at_ms=now_ms,
                    )
                )

            existing = (
                conn
                .execute(
                    select(push_receipts)
                    .where(
                        and_(
                            push_receipts.c.binding_id == binding_id,
                            push_receipts.c.notification_id_hash
                            == notification_id_hash,
                        )
                    )
                    .with_for_update()
                )
                .mappings()
                .first()
            )
            if existing is not None:
                if bytes(existing["request_hash"]) != request_hash:
                    raise Conflict("notification_id_conflict")
                if (
                    existing["apns_id"] != apns_id
                    or existing["collapse_id"] != collapse_id
                ):
                    raise Conflict("notification_delivery_identity_conflict")
                terminal = existing["status"] in {"sent", "permanent_rejected"}
                if terminal:
                    return SendReservation(
                        True,
                        False,
                        str(existing["status"]),
                        existing["provider_status"],
                        str(existing["apns_id"]),
                        str(existing["collapse_id"]),
                        None,
                    )
                lease_expires_at_ms = existing["lease_expires_at_ms"]
                if (
                    existing["status"] == "reserved"
                    and existing["attempt_token"] is not None
                    and lease_expires_at_ms is not None
                    and int(lease_expires_at_ms) > now_ms
                ):
                    return SendReservation(
                        False,
                        True,
                        str(existing["status"]),
                        existing["provider_status"],
                        str(existing["apns_id"]),
                        str(existing["collapse_id"]),
                        None,
                    )
                if existing["status"] in {"ambiguous", "retryable"}:
                    exponent = min(max(int(existing["attempt_count"]) - 1, 0), 30)
                    retry_delay_ms = min(
                        self.settings.send_retry_base_seconds * 1000 * (2**exponent),
                        self.settings.send_retry_max_seconds * 1000,
                    )
                    retry_at_ms = int(existing["last_attempt_at_ms"]) + retry_delay_ms
                    provider_retry_at = existing["provider_retry_not_before_ms"]
                    if provider_retry_at is not None:
                        retry_at_ms = max(retry_at_ms, int(provider_retry_at))
                    if retry_at_ms > now_ms:
                        raise RateLimited(
                            "send_retry_backoff",
                            retry_after_ms=retry_at_ms - now_ms,
                        )
                enforce_attempt_quota()
                attempt_token = secrets.token_bytes(32)
                attempt_number = int(existing["attempt_count"]) + 1
                conn.execute(
                    update(push_receipts)
                    .where(
                        and_(
                            push_receipts.c.binding_id == binding_id,
                            push_receipts.c.notification_id_hash
                            == notification_id_hash,
                        )
                    )
                    .values(
                        status="reserved",
                        provider_status=None,
                        completed_at_ms=None,
                        attempt_count=attempt_number,
                        last_attempt_at_ms=now_ms,
                        provider_retry_not_before_ms=None,
                        attempt_token=attempt_token,
                        lease_expires_at_ms=now_ms + SEND_ATTEMPT_LEASE_MS,
                    )
                )
                record_attempt(attempt_number)
                return SendReservation(
                    False,
                    False,
                    str(existing["status"]),
                    existing["provider_status"],
                    str(existing["apns_id"]),
                    str(existing["collapse_id"]),
                    attempt_token,
                )
            enforce_attempt_quota()
            attempt_token = secrets.token_bytes(32)
            conn.execute(
                insert(push_receipts).values(
                    binding_id=binding_id,
                    notification_id_hash=notification_id_hash,
                    request_hash=request_hash,
                    status="reserved",
                    apns_id=apns_id,
                    collapse_id=collapse_id,
                    attempt_count=1,
                    last_attempt_at_ms=now_ms,
                    created_at_ms=now_ms,
                    expires_at_ms=expires_at_ms,
                    attempt_token=attempt_token,
                    lease_expires_at_ms=now_ms + SEND_ATTEMPT_LEASE_MS,
                )
            )
            record_attempt(1)
            return SendReservation(
                False, False, None, None, apns_id, collapse_id, attempt_token
            )

    def complete_send(
        self,
        *,
        binding_id: str,
        notification_id_hash: bytes,
        delivery_status: str,
        provider_status: int,
        prune_endpoint: bool,
        now_ms: int,
        attempt_token: bytes,
        provider_retry_after_ms: int | None = None,
    ) -> bool:
        if not isinstance(attempt_token, bytes) or len(attempt_token) != 32:
            raise ValueError("attempt_token must be 32 bytes")
        if provider_retry_after_ms is not None and (
            not isinstance(provider_retry_after_ms, int)
            or isinstance(provider_retry_after_ms, bool)
            or provider_retry_after_ms < 0
            or provider_retry_after_ms > MAX_PROVIDER_RETRY_AFTER_MS
        ):
            raise ValueError("provider_retry_after_ms is outside the safe bound")
        retry_not_before_ms = (
            now_ms + provider_retry_after_ms
            if delivery_status in {"ambiguous", "retryable"}
            and provider_retry_after_ms is not None
            else None
        )
        with self._lock, self.engine.begin() as conn:
            completed = conn.execute(
                update(push_receipts)
                .where(
                    and_(
                        push_receipts.c.binding_id == binding_id,
                        push_receipts.c.notification_id_hash == notification_id_hash,
                        push_receipts.c.status == "reserved",
                        push_receipts.c.attempt_token == attempt_token,
                    )
                )
                .values(
                    status=delivery_status,
                    provider_status=provider_status,
                    completed_at_ms=now_ms,
                    last_attempt_at_ms=now_ms,
                    provider_retry_not_before_ms=retry_not_before_ms,
                    attempt_token=None,
                    lease_expires_at_ms=None,
                )
            )
            if completed.rowcount != 1:
                return False
            if prune_endpoint:
                endpoint_id = conn.execute(
                    select(bindings.c.endpoint_id).where(
                        bindings.c.binding_id == binding_id
                    )
                ).scalar_one()
                conn.execute(
                    update(endpoints)
                    .where(endpoints.c.endpoint_id == endpoint_id)
                    .values(
                        status="disabled", disabled_at_ms=now_ms, updated_at_ms=now_ms
                    )
                )
            return True

    def purge(self, now_ms: int) -> dict[str, int]:
        with self._lock, self.engine.begin() as conn:
            challenge_count = (
                conn.execute(
                    delete(challenges).where(
                        or_(
                            and_(
                                challenges.c.used_at_ms.is_(None),
                                challenges.c.expires_at_ms <= now_ms,
                            ),
                            and_(
                                challenges.c.used_at_ms.is_not(None),
                                challenges.c.used_at_ms <= now_ms - 86_400_000,
                            ),
                        )
                    )
                ).rowcount
                or 0
            )
            bind_count = (
                conn.execute(
                    delete(bind_tokens).where(
                        or_(
                            bind_tokens.c.expires_at_ms <= now_ms - 86_400_000,
                            and_(
                                bind_tokens.c.used_at_ms.is_not(None),
                                bind_tokens.c.used_at_ms <= now_ms - 86_400_000,
                            ),
                        )
                    )
                ).rowcount
                or 0
            )
            registration_receipt_count = (
                conn.execute(
                    delete(registration_receipts).where(
                        registration_receipts.c.expires_at_ms <= now_ms
                    )
                ).rowcount
                or 0
            )
            activation_receipt_count = (
                conn.execute(
                    delete(hub_activation_receipts).where(
                        hub_activation_receipts.c.expires_at_ms <= now_ms
                    )
                ).rowcount
                or 0
            )
            binding_receipt_count = (
                conn.execute(
                    delete(binding_exchange_receipts).where(
                        binding_exchange_receipts.c.expires_at_ms <= now_ms
                    )
                ).rowcount
                or 0
            )
            receipt_count = (
                conn.execute(
                    delete(push_receipts).where(push_receipts.c.expires_at_ms <= now_ms)
                ).rowcount
                or 0
            )
            send_attempt_count = (
                conn.execute(
                    delete(push_send_attempts).where(
                        push_send_attempts.c.attempted_at_ms <= now_ms - 86_400_000
                    )
                ).rowcount
                or 0
            )
        return {
            "challenges": int(challenge_count),
            "bind_tokens": int(bind_count),
            "registration_receipts": int(registration_receipt_count),
            "hub_activation_receipts": int(activation_receipt_count),
            "binding_exchange_receipts": int(binding_receipt_count),
            "push_receipts": int(receipt_count),
            "push_send_attempts": int(send_attempt_count),
        }
