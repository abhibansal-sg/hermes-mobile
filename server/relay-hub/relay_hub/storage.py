from __future__ import annotations

import hashlib
import hmac
import secrets
import threading
from contextlib import nullcontext
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from sqlalchemy import (
    BigInteger,
    Column,
    ForeignKey,
    Index,
    Integer,
    LargeBinary,
    MetaData,
    String,
    Table,
    and_,
    case,
    create_engine,
    delete,
    func,
    insert,
    or_,
    select,
    update,
)
from sqlalchemy.engine import Connection, Engine, RowMapping
from sqlalchemy.exc import IntegrityError
from sqlalchemy.pool import StaticPool

from .crypto import b64url_decode, b64url_encode, envelope_hash
from .models import GrantRequest, OuterEnvelope
from .settings import Settings


class StorageError(RuntimeError):
    pass


class NotFound(StorageError):
    pass


class Conflict(StorageError):
    pass


class MailboxFull(StorageError):
    pass


class Forbidden(StorageError):
    pass


class EnrollmentRateLimited(StorageError):
    pass


class ProvisionalCapacityExhausted(StorageError):
    pass


@dataclass(frozen=True)
class RouteRecord:
    route_id: str
    auth_public_key: bytes
    route_type: str
    status: str
    expires_at_ms: int | None
    owner_route: str | None = None
    pair_offer_id: str | None = None


@dataclass(frozen=True)
class AcceptResult:
    deduplicated: bool
    stored: bool
    evicted_state_records: int = 0


@dataclass(frozen=True)
class ProvisionalResult:
    route_id: str
    expires_at_ms: int
    created: bool


class HubStorage(Protocol):
    def ready(self) -> bool: ...
    def purge(self, now_ms: int) -> dict[str, int]: ...


metadata = MetaData()

routes = Table(
    "routes",
    metadata,
    Column("route_id", String(256), primary_key=True),
    Column("enrollment_id", String(96), unique=True),
    Column("auth_public_key", LargeBinary, nullable=False),
    Column("route_type", String(16), nullable=False),
    Column("status", String(16), nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("expires_at_ms", BigInteger),
    Column("activated_at_ms", BigInteger),
    Column("revoked_at_ms", BigInteger),
    Column("owner_route", String(256)),
    Column("pair_offer_id", String(96)),
    Column("pending_control_used_at_ms", BigInteger),
)

provisional_enrollment_events = Table(
    "provisional_enrollment_events",
    metadata,
    Column("source_hash", LargeBinary, primary_key=True),
    Column("event_id", LargeBinary, primary_key=True),
    Column("expires_at_ms", BigInteger, nullable=False),
)
Index(
    "provisional_enrollment_events_expiry",
    provisional_enrollment_events.c.expires_at_ms,
)

grants = Table(
    "grants",
    metadata,
    Column("grant_id", String(96), primary_key=True),
    Column("issuer_route", String(256), ForeignKey("routes.route_id"), nullable=False),
    Column("source_route", String(256), ForeignKey("routes.route_id"), nullable=False),
    Column("destination_route", String(256), ForeignKey("routes.route_id"), nullable=False),
    Column("permissions", Integer, nullable=False),
    Column("status", String(16), nullable=False),
    Column("issuer_signature", LargeBinary, nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("expires_at_ms", BigInteger),
    Column("revoked_at_ms", BigInteger),
)

messages = Table(
    "messages",
    metadata,
    Column("destination_route", String(256), ForeignKey("routes.route_id"), primary_key=True),
    Column("message_id", LargeBinary, primary_key=True),
    Column("source_route", String(256), ForeignKey("routes.route_id"), nullable=False),
    Column("message_class", String(16), nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
    Column("collapse_id", LargeBinary),
    Column("key_generation", Integer, nullable=False),
    Column("hpke_enc", LargeBinary, nullable=False),
    Column("ciphertext", LargeBinary, nullable=False),
    Column("sender_signature", LargeBinary, nullable=False),
    Column("size_bytes", Integer, nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("delivered_at_ms", BigInteger),
)

message_receipts = Table(
    "message_receipts",
    metadata,
    Column("destination_route", String(256), primary_key=True),
    Column("message_id", LargeBinary, primary_key=True),
    Column("envelope_hash", LargeBinary, nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
)

request_nonces = Table(
    "request_nonces",
    metadata,
    Column("route_id", String(256), primary_key=True),
    Column("nonce", LargeBinary, primary_key=True),
    Column("expires_at_ms", BigInteger, nullable=False),
)

activation_receipts = Table(
    "activation_receipts",
    metadata,
    Column("token_hash", LargeBinary, primary_key=True),
    Column("route_id", String(256), nullable=False),
    Column("used_at_ms", BigInteger, nullable=False),
)

pair_offers = Table(
    "pair_offers",
    metadata,
    Column("offer_id", String(96), primary_key=True),
    Column("offer_route", String(96), nullable=False, unique=True),
    Column("owner_route", String(256), ForeignKey("routes.route_id"), nullable=False),
    Column("transport_token_hash", LargeBinary, nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
    Column("created_at_ms", BigInteger, nullable=False),
    Column("hpke_enc", LargeBinary),
    Column("ciphertext", LargeBinary),
    Column("message_hash", LargeBinary),
    Column("claimed_at_ms", BigInteger),
    Column("device_route", String(256)),
    Column("response_enc", LargeBinary),
    Column("response_ciphertext", LargeBinary),
    Column("response_hash", LargeBinary),
    Column("accepted_at_ms", BigInteger),
)

pair_confirm_receipts = Table(
    "pair_confirm_receipts",
    metadata,
    Column("offer_id_hash", LargeBinary, primary_key=True),
    Column("owner_route", String(256), nullable=False),
    Column("device_route", String(256), nullable=False),
    Column("message_hash", LargeBinary, nullable=False),
    Column("response_hash", LargeBinary, nullable=False),
    Column("grant_id_1", String(96), nullable=False),
    Column("grant_id_2", String(96), nullable=False),
    Column("expires_at_ms", BigInteger, nullable=False),
)


_PERMISSION_BITS = {"send": 1, "receive": 2}
_PROVISIONAL_ADVISORY_LOCK = int.from_bytes(b"HRH2PROV", "big", signed=True)


def _permission_mask(values: list[str]) -> int:
    mask = 0
    for value in values:
        mask |= _PERMISSION_BITS[value]
    return mask


class DatabaseStore:
    """SQLAlchemy-backed store supporting SQLite development and PostgreSQL hosting.

    Mailbox admission locks the destination route row on PostgreSQL. SQLite is
    additionally guarded by a process lock; its single-writer transaction model
    handles cross-process serialization for self-hosted development deployments.
    """

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
        # SQLite needs in-process writer serialization. PostgreSQL transaction
        # and row locks provide the corresponding coordination without forcing
        # every remote write through one Python thread.
        self._write_lock = (
            threading.RLock()
            if self.engine.dialect.name == "sqlite"
            else nullcontext()
        )
        if settings.auto_create_schema:
            metadata.create_all(self.engine)

    def ready(self) -> bool:
        try:
            with self.engine.connect() as conn:
                for table in metadata.sorted_tables:
                    conn.execute(select(*table.c).limit(0))
            return True
        except Exception:
            return False

    def create_provisional(
        self,
        *,
        enrollment_id: str,
        route_id: str,
        public_key: bytes,
        route_type: str,
        source_hash: bytes,
        now_ms: int,
        expires_at_ms: int,
    ) -> ProvisionalResult:
        """Atomically enforce idempotency, source rate, and global capacity."""

        if len(source_hash) != 32:
            raise ValueError("source_hash must be 32 bytes")
        capacity_exhausted = False
        with self._write_lock, self.engine.begin() as conn:
            if conn.dialect.name == "postgresql":
                # Enrollment is low-volume and globally bounded. A transaction
                # advisory lock prevents count/insert phantoms across Hub
                # workers and replicas without adding a singleton lock table.
                conn.execute(
                    select(func.pg_advisory_xact_lock(_PROVISIONAL_ADVISORY_LOCK))
                ).scalar_one()
            existing = conn.execute(
                select(routes).where(routes.c.enrollment_id == enrollment_id).with_for_update()
            ).mappings().first()
            if existing is not None:
                if (
                    bytes(existing["auth_public_key"]) != public_key
                    or existing["route_type"] != route_type
                ):
                    raise Conflict("enrollment_id_conflict")
                if existing["expires_at_ms"] is None:
                    raise Conflict("provisional_enrollment_already_activated")
                if int(existing["expires_at_ms"]) <= now_ms:
                    raise Conflict("provisional_enrollment_expired")
                if existing["status"] == "revoked":
                    raise Conflict("provisional_enrollment_revoked")
                if existing["status"] != "provisional":
                    raise Conflict("provisional_enrollment_already_activated")
                return ProvisionalResult(
                    route_id=str(existing["route_id"]),
                    expires_at_ms=int(existing["expires_at_ms"]),
                    created=False,
                )

            conn.execute(
                delete(provisional_enrollment_events).where(
                    provisional_enrollment_events.c.expires_at_ms <= now_ms
                )
            )
            source_events = int(
                conn.execute(
                    select(func.count())
                    .select_from(provisional_enrollment_events)
                    .where(provisional_enrollment_events.c.source_hash == source_hash)
                ).scalar_one()
            )
            if source_events == 0:
                tracked_sources = int(
                    conn.execute(
                        select(
                            func.count(
                                func.distinct(
                                    provisional_enrollment_events.c.source_hash
                                )
                            )
                        )
                    ).scalar_one()
                )
                if (
                    tracked_sources
                    >= self.settings.maximum_provisional_rate_limit_sources
                ):
                    raise EnrollmentRateLimited(
                        "provisional_enrollment_rate_limited"
                    )
            if source_events >= self.settings.provisional_per_source_per_hour:
                raise EnrollmentRateLimited("provisional_enrollment_rate_limited")

            conn.execute(
                insert(provisional_enrollment_events).values(
                    source_hash=source_hash,
                    event_id=secrets.token_bytes(16),
                    expires_at_ms=now_ms + 3_600_000,
                )
            )
            live_provisional = int(
                conn.execute(
                    select(func.count())
                    .select_from(routes)
                    .where(
                        and_(
                            routes.c.status == "provisional",
                            routes.c.expires_at_ms > now_ms,
                        )
                    )
                ).scalar_one()
            )
            if live_provisional >= self.settings.maximum_live_provisional_routes:
                # The source event deliberately commits so repeatedly probing a
                # full public service remains rate-limited.
                capacity_exhausted = True
            else:
                try:
                    with conn.begin_nested():
                        conn.execute(
                            insert(routes).values(
                                enrollment_id=enrollment_id,
                                route_id=route_id,
                                auth_public_key=public_key,
                                route_type=route_type,
                                status="provisional",
                                created_at_ms=now_ms,
                                expires_at_ms=expires_at_ms,
                            )
                        )
                except IntegrityError as exc:
                    raise Conflict("enrollment_already_exists") from exc
        if capacity_exhausted:
            raise ProvisionalCapacityExhausted("provisional_capacity_exhausted")
        return ProvisionalResult(
            route_id=route_id,
            expires_at_ms=expires_at_ms,
            created=True,
        )

    def get_provisional_enrollment(
        self,
        *,
        enrollment_id: str,
        public_key: bytes,
        route_type: str,
        now_ms: int,
    ) -> dict | None:
        with self.engine.connect() as conn:
            row = conn.execute(
                select(routes).where(routes.c.enrollment_id == enrollment_id)
            ).mappings().first()
        if row is None:
            return None
        if bytes(row["auth_public_key"]) != public_key or row["route_type"] != route_type:
            raise Conflict("enrollment_id_conflict")
        if row["expires_at_ms"] is None or int(row["expires_at_ms"]) <= now_ms:
            if row["expires_at_ms"] is not None:
                raise Conflict("provisional_enrollment_expired")
        if row["status"] == "revoked":
            raise Conflict("provisional_enrollment_revoked")
        if row["status"] != "provisional":
            raise Conflict("provisional_enrollment_already_activated")
        return {
            "enrollment_id": enrollment_id,
            "route_id": row["route_id"],
            "status": "provisional",
            "expires_at_ms": int(row["expires_at_ms"]),
        }

    def count_live_provisional(self, now_ms: int) -> int:
        with self.engine.connect() as conn:
            return int(
                conn.execute(
                    select(func.count())
                    .select_from(routes)
                    .where(
                        and_(
                            routes.c.status == "provisional",
                            routes.c.expires_at_ms > now_ms,
                        )
                    )
                ).scalar_one()
            )

    def get_route(self, route_id: str) -> RouteRecord | None:
        with self.engine.connect() as conn:
            row = conn.execute(select(routes).where(routes.c.route_id == route_id)).mappings().first()
        if row is None:
            return None
        return RouteRecord(
            route_id=row["route_id"],
            auth_public_key=bytes(row["auth_public_key"]),
            route_type=row["route_type"],
            status=row["status"],
            expires_at_ms=row["expires_at_ms"],
            owner_route=row["owner_route"],
            pair_offer_id=row["pair_offer_id"],
        )

    def create_pending_device(
        self,
        *,
        route_id: str,
        public_key: bytes,
        owner_route: str,
        offer_id: str,
        now_ms: int,
    ) -> tuple[str, bool]:
        with self._write_lock, self.engine.begin() as conn:
            owner = conn.execute(
                select(routes.c.status, routes.c.route_type)
                .where(routes.c.route_id == owner_route)
                .with_for_update()
            ).first()
            if owner is None or owner.status != "active" or owner.route_type != "agent":
                raise Forbidden("device_owner_not_active")
            offer = conn.execute(
                select(pair_offers)
                .where(pair_offers.c.offer_id == offer_id)
                .with_for_update()
            ).mappings().first()
            if offer is None:
                raise NotFound("pair_offer_not_found")
            if offer["owner_route"] != owner_route:
                raise Forbidden("pair_offer_owner_mismatch")
            if int(offer["expires_at_ms"]) <= now_ms:
                raise Forbidden("pair_offer_expired")
            if offer["message_hash"] is None:
                raise Conflict("pair_offer_not_ready")
            if offer["device_route"] is not None:
                existing = conn.execute(
                    select(routes).where(
                        routes.c.route_id == offer["device_route"]
                    )
                ).mappings().first()
                if (
                    existing is not None
                    and bytes(existing["auth_public_key"]) == public_key
                    and existing["route_type"] == "device"
                    and existing["status"] == "pending"
                    and existing["owner_route"] == owner_route
                    and existing["pair_offer_id"] == offer_id
                ):
                    return str(existing["route_id"]), False
                raise Conflict("pair_offer_device_already_created")
            conn.execute(
                insert(routes).values(
                    route_id=route_id,
                    auth_public_key=public_key,
                    route_type="device",
                    status="pending",
                    owner_route=owner_route,
                    pair_offer_id=offer_id,
                    created_at_ms=now_ms,
                    expires_at_ms=offer["expires_at_ms"],
                )
            )
            conn.execute(
                update(pair_offers)
                .where(pair_offers.c.offer_id == offer_id)
                .values(device_route=route_id)
            )
            return route_id, True

    def activate_route(self, *, route_id: str, token_hash: bytes, now_ms: int) -> bool:
        with self._write_lock, self.engine.begin() as conn:
            route = conn.execute(
                select(routes).where(routes.c.route_id == route_id).with_for_update()
            ).mappings().first()
            if route is None:
                raise NotFound("route_not_found")
            if route["status"] == "revoked":
                raise Forbidden("route_revoked")
            if route["status"] == "active":
                return False
            if route["status"] != "provisional":
                raise Forbidden("route_not_provisional")
            if route["expires_at_ms"] is not None and route["expires_at_ms"] <= now_ms:
                raise Forbidden("provisional_route_expired")
            try:
                conn.execute(
                    insert(activation_receipts).values(
                        token_hash=token_hash,
                        route_id=route_id,
                        used_at_ms=now_ms,
                    )
                )
            except IntegrityError as exc:
                raise Conflict("activation_token_reused") from exc
            conn.execute(
                update(routes)
                .where(routes.c.route_id == route_id)
                .values(status="active", expires_at_ms=None, activated_at_ms=now_ms)
            )
            return True

    def consume_request_nonce(self, *, route_id: str, nonce: bytes, expires_at_ms: int) -> bool:
        with self._write_lock, self.engine.begin() as conn:
            conn.execute(delete(request_nonces).where(request_nonces.c.expires_at_ms <= expires_at_ms - 600_000))
            try:
                conn.execute(
                    insert(request_nonces).values(
                        route_id=route_id,
                        nonce=nonce,
                        expires_at_ms=expires_at_ms,
                    )
                )
            except IntegrityError:
                return False
        return True

    def create_grant(self, grant: GrantRequest, *, now_ms: int) -> bool:
        with self._write_lock, self.engine.begin() as conn:
            route_ids = sorted({grant.issuer_route, grant.source_route, grant.destination_route})
            route_rows = conn.execute(
                select(routes.c.route_id, routes.c.status, routes.c.route_type, routes.c.owner_route)
                .where(routes.c.route_id.in_(route_ids))
                .order_by(routes.c.route_id)
                .with_for_update()
            ).all()
            route_state = {row.route_id: row for row in route_rows}
            if len(route_state) != len(route_ids):
                raise NotFound("route_not_found")
            issuer = route_state[grant.issuer_route]
            if issuer.status != "active" or issuer.route_type != "agent":
                raise Forbidden("grant_issuer_must_be_active_agent")
            if grant.source_route == grant.issuer_route:
                device_route = grant.destination_route
            elif grant.destination_route == grant.issuer_route:
                device_route = grant.source_route
            else:
                raise Forbidden("grant_issuer_not_party")
            if device_route == grant.issuer_route:
                raise Forbidden("grant_requires_owned_device")
            device = route_state[device_route]
            if (
                device.route_type != "device"
                or device.owner_route != grant.issuer_route
                or device.status not in {"pending", "active"}
            ):
                raise Forbidden("grant_requires_owned_device")
            grant_status = (
                "pending"
                if device.status == "pending"
                else "active"
            )
            values = dict(
                grant_id=grant.grant_id,
                issuer_route=grant.issuer_route,
                source_route=grant.source_route,
                destination_route=grant.destination_route,
                permissions=_permission_mask(grant.permissions),
                status=grant_status,
                issuer_signature=b64url_decode(
                    grant.issuer_signature, field="issuer_signature", exact=64
                ),
                created_at_ms=now_ms,
                expires_at_ms=grant.expires_at_ms,
            )
            existing = conn.execute(
                select(grants).where(grants.c.grant_id == grant.grant_id)
            ).mappings().first()
            if existing is not None:
                same = all(existing[key] == value for key, value in values.items() if key != "created_at_ms")
                if not same:
                    raise Conflict("grant_id_conflict")
                return False
            duplicate = conn.execute(
                select(grants.c.grant_id).where(
                    and_(
                        grants.c.source_route == grant.source_route,
                        grants.c.destination_route == grant.destination_route,
                        grants.c.revoked_at_ms.is_(None),
                    )
                )
            ).first()
            if duplicate is not None:
                raise Conflict("grant_route_conflict")
            conn.execute(insert(grants).values(**values))
            return True

    def get_grant_status(self, grant_id: str) -> str:
        with self.engine.connect() as conn:
            value = conn.execute(
                select(grants.c.status).where(grants.c.grant_id == grant_id)
            ).scalar_one_or_none()
        if value is None:
            raise NotFound("grant_not_found")
        return str(value)

    def revoke_grant(self, *, grant_id: str, actor_route: str, now_ms: int) -> bool:
        with self._write_lock, self.engine.begin() as conn:
            row = conn.execute(
                select(grants).where(grants.c.grant_id == grant_id).with_for_update()
            ).mappings().first()
            if row is None:
                raise NotFound("grant_not_found")
            if actor_route not in {row["issuer_route"], row["source_route"], row["destination_route"]}:
                raise Forbidden("grant_revoke_forbidden")
            if row["revoked_at_ms"] is not None:
                return False
            conn.execute(
                update(grants)
                .where(grants.c.grant_id == grant_id)
                .values(status="revoked", revoked_at_ms=now_ms)
            )
            return True

    def revoke_route(
        self, *, route_id: str, actor_route: str, now_ms: int
    ) -> tuple[bool, list[str]]:
        with self._write_lock, self.engine.begin() as conn:
            route_rows = conn.execute(
                select(routes)
                .where(routes.c.route_id.in_(sorted({route_id, actor_route})))
                .order_by(routes.c.route_id)
                .with_for_update()
            ).mappings().all()
            route_state = {row["route_id"]: row for row in route_rows}
            target = route_state.get(route_id)
            actor = route_state.get(actor_route)
            if target is None:
                raise NotFound("route_not_found")
            owner_authorized = (
                actor is not None
                and actor["status"] == "active"
                and actor["route_type"] == "agent"
                and target["route_type"] == "device"
                and target["owner_route"] == actor_route
            )
            if route_id != actor_route and not owner_authorized:
                raise Forbidden("route_revoke_forbidden")
            grant_ids = [
                str(value)
                for value in conn.execute(
                    select(grants.c.grant_id)
                    .where(
                        or_(
                            grants.c.issuer_route == route_id,
                            grants.c.source_route == route_id,
                            grants.c.destination_route == route_id,
                        )
                    )
                    .order_by(grants.c.grant_id)
                    .with_for_update()
                ).scalars()
            ]
            if target["status"] == "revoked":
                return False, grant_ids
            conn.execute(
                update(routes)
                .where(routes.c.route_id == route_id)
                .values(status="revoked", revoked_at_ms=now_ms, expires_at_ms=None)
            )
            conn.execute(
                update(grants)
                .where(
                    and_(
                        grants.c.revoked_at_ms.is_(None),
                        or_(
                            grants.c.issuer_route == route_id,
                            grants.c.source_route == route_id,
                            grants.c.destination_route == route_id,
                        ),
                    )
                )
                .values(status="revoked", revoked_at_ms=now_ms)
            )
            doomed_messages = conn.execute(
                select(messages.c.destination_route, messages.c.message_id).where(
                    or_(messages.c.destination_route == route_id, messages.c.source_route == route_id)
                )
            ).all()
            for doomed in doomed_messages:
                conn.execute(
                    delete(message_receipts).where(
                        and_(
                            message_receipts.c.destination_route == doomed.destination_route,
                            message_receipts.c.message_id == doomed.message_id,
                        )
                    )
                )
            conn.execute(
                delete(messages).where(
                    or_(messages.c.destination_route == route_id, messages.c.source_route == route_id)
                )
            )
            conn.execute(delete(message_receipts).where(message_receipts.c.destination_route == route_id))
            if target["pair_offer_id"] is not None:
                conn.execute(
                    delete(pair_offers).where(
                        pair_offers.c.offer_id == target["pair_offer_id"]
                    )
                )
            owned_offers = conn.execute(
                select(pair_offers.c.device_route)
                .where(pair_offers.c.owner_route == route_id)
                .with_for_update()
            ).all()
            for offer in owned_offers:
                self._revoke_pending_device(
                    conn, device_route=offer.device_route, now_ms=now_ms
                )
            conn.execute(delete(pair_offers).where(pair_offers.c.owner_route == route_id))
            return True, grant_ids

    def create_pair_offer(
        self,
        *,
        offer_id: str,
        offer_route: str,
        owner_route: str,
        token_hash: bytes,
        expires_at_ms: int,
        now_ms: int,
    ) -> bool:
        with self._write_lock, self.engine.begin() as conn:
            owner = conn.execute(
                select(routes.c.status, routes.c.route_type, routes.c.expires_at_ms)
                .where(routes.c.route_id == owner_route)
                .with_for_update()
            ).first()
            if owner is None or owner.route_type != "agent":
                raise Forbidden("offer_owner_not_active")
            if owner.status == "provisional":
                if owner.expires_at_ms is None or int(owner.expires_at_ms) <= now_ms:
                    raise Forbidden("provisional_route_expired")
                if expires_at_ms > int(owner.expires_at_ms):
                    raise Forbidden("pair_offer_exceeds_provisional_expiry")
            elif owner.status != "active":
                raise Forbidden("offer_owner_not_active")
            existing = conn.execute(
                select(pair_offers).where(
                    or_(
                        pair_offers.c.offer_id == offer_id,
                        pair_offers.c.offer_route == offer_route,
                    )
                )
            ).mappings().first()
            if existing is not None:
                same = (
                    existing["offer_id"] == offer_id
                    and existing["offer_route"] == offer_route
                    and existing["owner_route"] == owner_route
                    and hmac.compare_digest(
                        bytes(existing["transport_token_hash"]), token_hash
                    )
                    and int(existing["expires_at_ms"]) == expires_at_ms
                )
                if same:
                    return False
                raise Conflict("pair_offer_conflict")
            live = conn.execute(
                select(func.count())
                .select_from(pair_offers)
                .where(
                    and_(
                        pair_offers.c.owner_route == owner_route,
                        pair_offers.c.expires_at_ms > now_ms,
                    )
                )
            ).scalar_one()
            if int(live) >= self.settings.maximum_live_pair_offers_per_route:
                raise MailboxFull("pair_offer_limit")
            try:
                conn.execute(
                    insert(pair_offers).values(
                        offer_id=offer_id,
                        offer_route=offer_route,
                        owner_route=owner_route,
                        transport_token_hash=token_hash,
                        expires_at_ms=expires_at_ms,
                        created_at_ms=now_ms,
                    )
                )
            except IntegrityError as exc:
                raise Conflict("pair_offer_conflict") from exc
            return True

    def submit_pair_message(
        self,
        *,
        offer_route: str,
        offer_id: str,
        token_hash: bytes,
        enc: bytes,
        ciphertext: bytes,
        now_ms: int,
    ) -> tuple[bool, str, dict]:
        digest = hashlib.sha256(enc + ciphertext).digest()
        with self._write_lock, self.engine.begin() as conn:
            row = conn.execute(
                select(pair_offers).where(pair_offers.c.offer_route == offer_route).with_for_update()
            ).mappings().first()
            if row is None or row["offer_id"] != offer_id:
                raise NotFound("pair_offer_not_found")
            if int(row["expires_at_ms"]) <= now_ms:
                self._revoke_pending_device(
                    conn, device_route=row["device_route"], now_ms=now_ms
                )
                conn.execute(delete(pair_offers).where(pair_offers.c.offer_id == row["offer_id"]))
                raise Forbidden("pair_offer_expired")
            if not hmac.compare_digest(bytes(row["transport_token_hash"]), token_hash):
                raise Forbidden("pair_transport_token_invalid")
            if row["message_hash"] is not None:
                if bytes(row["message_hash"]) != digest:
                    raise Conflict("pair_offer_message_conflict")
                return True, row["owner_route"], self._pair_offer_wire(row)
            conn.execute(
                update(pair_offers)
                .where(pair_offers.c.offer_id == offer_id)
                .values(
                    hpke_enc=enc,
                    ciphertext=ciphertext,
                    message_hash=digest,
                    claimed_at_ms=now_ms,
                )
            )
            wire = {
                "status": "ready",
                "v": 2,
                "offer_id": offer_id,
                "enc": b64url_encode(enc),
                "ct": b64url_encode(ciphertext),
                "message_hash": b64url_encode(digest),
            }
            return False, row["owner_route"], wire

    @staticmethod
    def _pair_offer_wire(row) -> dict:
        if row["message_hash"] is None:
            return {"status": "waiting", "offer_id": row["offer_id"]}
        return {
            "status": "ready",
            "v": 2,
            "offer_id": row["offer_id"],
            "enc": b64url_encode(bytes(row["hpke_enc"])),
            "ct": b64url_encode(bytes(row["ciphertext"])),
            "message_hash": b64url_encode(bytes(row["message_hash"])),
        }

    def get_pair_offer(self, *, offer_id: str, owner_route: str, now_ms: int) -> dict:
        with self.engine.connect() as conn:
            row = conn.execute(select(pair_offers).where(pair_offers.c.offer_id == offer_id)).mappings().first()
        if row is None:
            raise NotFound("pair_offer_not_found")
        if row["owner_route"] != owner_route:
            raise Forbidden("pair_offer_owner_mismatch")
        if int(row["expires_at_ms"]) <= now_ms:
            raise Forbidden("pair_offer_expired")
        return self._pair_offer_wire(row)

    @staticmethod
    def _pair_grant_ids(
        conn: Connection, *, owner_route: str, device_route: str, now_ms: int
    ) -> list[str]:
        rows = conn.execute(
            select(
                grants.c.grant_id,
                grants.c.source_route,
                grants.c.destination_route,
                grants.c.permissions,
            )
            .where(
                and_(
                    grants.c.status == "pending",
                    grants.c.revoked_at_ms.is_(None),
                    or_(grants.c.expires_at_ms.is_(None), grants.c.expires_at_ms > now_ms),
                    grants.c.source_route.in_([owner_route, device_route]),
                    grants.c.destination_route.in_([owner_route, device_route]),
                )
            )
            .order_by(grants.c.grant_id)
            .with_for_update()
        ).all()
        directions = {(row.source_route, row.destination_route) for row in rows}
        expected = {(owner_route, device_route), (device_route, owner_route)}
        if len(rows) != 2 or directions != expected:
            raise Conflict("pair_grants_incomplete")
        if any(not (int(row.permissions) & _PERMISSION_BITS["send"]) for row in rows):
            raise Conflict("pair_grants_send_permission_missing")
        return [str(row.grant_id) for row in rows]

    def accept_pair_offer(
        self,
        *,
        offer_id: str,
        owner_route: str,
        message_hash: bytes,
        device_route: str,
        enc: bytes,
        ciphertext: bytes,
        now_ms: int,
    ) -> tuple[bool, bytes]:
        response_hash = hashlib.sha256(enc + ciphertext).digest()
        with self._write_lock, self.engine.begin() as conn:
            offer = conn.execute(
                select(pair_offers).where(pair_offers.c.offer_id == offer_id).with_for_update()
            ).mappings().first()
            if offer is None:
                raise NotFound("pair_offer_not_found")
            if offer["owner_route"] != owner_route:
                raise Forbidden("pair_offer_owner_mismatch")
            if int(offer["expires_at_ms"]) <= now_ms:
                raise Forbidden("pair_offer_expired")
            if offer["message_hash"] is None or not hmac.compare_digest(
                bytes(offer["message_hash"]), message_hash
            ):
                raise Conflict("pair_offer_message_hash_mismatch")
            if offer["device_route"] != device_route:
                raise Conflict("pair_offer_device_mismatch")
            route = conn.execute(
                select(routes)
                .where(routes.c.route_id == device_route)
                .with_for_update()
            ).mappings().first()
            if (
                route is None
                or route["status"] != "pending"
                or route["route_type"] != "device"
                or route["owner_route"] != owner_route
                or route["pair_offer_id"] != offer_id
            ):
                raise Conflict("pair_device_not_pending")
            self._pair_grant_ids(
                conn, owner_route=owner_route, device_route=device_route, now_ms=now_ms
            )
            if offer["response_hash"] is not None:
                same = (
                    hmac.compare_digest(bytes(offer["response_hash"]), response_hash)
                    and bytes(offer["response_enc"]) == enc
                    and bytes(offer["response_ciphertext"]) == ciphertext
                )
                if not same:
                    raise Conflict("pair_offer_response_conflict")
                return True, response_hash
            conn.execute(
                update(pair_offers)
                .where(pair_offers.c.offer_id == offer_id)
                .values(
                    response_enc=enc,
                    response_ciphertext=ciphertext,
                    response_hash=response_hash,
                    accepted_at_ms=now_ms,
                )
            )
            return False, response_hash

    def get_pair_accept(
        self, *, offer_route: str, token_hash: bytes, now_ms: int
    ) -> dict:
        with self.engine.connect() as conn:
            offer = conn.execute(
                select(pair_offers).where(pair_offers.c.offer_route == offer_route)
            ).mappings().first()
        if offer is None:
            raise NotFound("pair_offer_not_found")
        if int(offer["expires_at_ms"]) <= now_ms:
            raise Forbidden("pair_offer_expired")
        if not hmac.compare_digest(bytes(offer["transport_token_hash"]), token_hash):
            raise Forbidden("pair_transport_token_invalid")
        if offer["response_hash"] is None:
            return {"status": "waiting", "offer_id": offer["offer_id"]}
        return {
            "v": 2,
            "offer_id": offer["offer_id"],
            "device_route": offer["device_route"],
            "enc": b64url_encode(bytes(offer["response_enc"])),
            "ct": b64url_encode(bytes(offer["response_ciphertext"])),
            "response_hash": b64url_encode(bytes(offer["response_hash"])),
        }

    def confirm_pair_offer(
        self,
        *,
        offer_id: str,
        owner_route: str,
        message_hash: bytes,
        response_hash: bytes,
        device_route: str,
        now_ms: int,
    ) -> list[str]:
        offer_id_hash = hashlib.sha256(offer_id.encode("utf-8")).digest()

        def validated_receipt(receipt) -> list[str] | None:
            if receipt is None:
                return None
            if int(receipt["expires_at_ms"]) <= now_ms:
                return None
            if (
                receipt["owner_route"] != owner_route
                or receipt["device_route"] != device_route
                or not hmac.compare_digest(bytes(receipt["message_hash"]), message_hash)
                or not hmac.compare_digest(bytes(receipt["response_hash"]), response_hash)
            ):
                raise Conflict("pair_confirm_receipt_mismatch")
            return sorted([str(receipt["grant_id_1"]), str(receipt["grant_id_2"])])

        with self._write_lock, self.engine.begin() as conn:
            receipt = conn.execute(
                select(pair_confirm_receipts)
                .where(pair_confirm_receipts.c.offer_id_hash == offer_id_hash)
                .with_for_update()
            ).mappings().first()
            grant_ids = validated_receipt(receipt)
            if grant_ids is not None:
                return grant_ids
            if receipt is not None:
                conn.execute(
                    delete(pair_confirm_receipts).where(
                        pair_confirm_receipts.c.offer_id_hash == offer_id_hash
                    )
                )
            offer = conn.execute(
                select(pair_offers).where(pair_offers.c.offer_id == offer_id).with_for_update()
            ).mappings().first()
            if offer is None:
                # Under PostgreSQL READ COMMITTED another confirmer can commit
                # while this transaction waits for the offer row. Re-read the
                # bounded receipt before reporting the offer missing.
                receipt = conn.execute(
                    select(pair_confirm_receipts).where(
                        pair_confirm_receipts.c.offer_id_hash == offer_id_hash
                    )
                ).mappings().first()
                grant_ids = validated_receipt(receipt)
                if grant_ids is not None:
                    return grant_ids
                raise NotFound("pair_offer_not_found")
            if offer["owner_route"] != owner_route:
                raise Forbidden("pair_offer_owner_mismatch")
            if int(offer["expires_at_ms"]) <= now_ms:
                raise Forbidden("pair_offer_expired")
            if (
                offer["message_hash"] is None
                or not hmac.compare_digest(bytes(offer["message_hash"]), message_hash)
            ):
                raise Conflict("pair_offer_message_hash_mismatch")
            if (
                offer["response_hash"] is None
                or not hmac.compare_digest(bytes(offer["response_hash"]), response_hash)
            ):
                raise Conflict("pair_offer_response_hash_mismatch")
            if offer["device_route"] != device_route:
                raise Conflict("pair_offer_device_mismatch")
            route = conn.execute(
                select(routes)
                .where(routes.c.route_id == device_route)
                .with_for_update()
            ).mappings().first()
            if (
                route is None
                or route["status"] != "pending"
                or route["owner_route"] != owner_route
                or route["pair_offer_id"] != offer_id
            ):
                raise Conflict("pair_device_not_pending")
            if route["pending_control_used_at_ms"] is None:
                raise Conflict("pair_confirm_control_missing")
            grant_ids = self._pair_grant_ids(
                conn, owner_route=owner_route, device_route=device_route, now_ms=now_ms
            )
            conn.execute(
                update(routes)
                .where(routes.c.route_id == device_route)
                .values(
                    status="active",
                    expires_at_ms=None,
                    activated_at_ms=now_ms,
                )
            )
            conn.execute(
                update(grants)
                .where(grants.c.grant_id.in_(grant_ids))
                .values(status="active")
            )
            conn.execute(
                insert(pair_confirm_receipts).values(
                    offer_id_hash=offer_id_hash,
                    owner_route=owner_route,
                    device_route=device_route,
                    message_hash=message_hash,
                    response_hash=response_hash,
                    grant_id_1=grant_ids[0],
                    grant_id_2=grant_ids[1],
                    expires_at_ms=(
                        now_ms
                        + self.settings.pair_confirmation_receipt_ttl_seconds * 1000
                    ),
                )
            )
            conn.execute(delete(pair_offers).where(pair_offers.c.offer_id == offer_id))
            return grant_ids

    @staticmethod
    def _revoke_pending_device(
        conn: Connection, *, device_route: str | None, now_ms: int
    ) -> None:
        if device_route is None:
            return
        route = conn.execute(
            select(routes.c.status).where(routes.c.route_id == device_route).with_for_update()
        ).first()
        if route is None or route.status != "pending":
            return
        pending_messages = conn.execute(
            select(messages.c.destination_route, messages.c.message_id).where(
                or_(
                    messages.c.source_route == device_route,
                    messages.c.destination_route == device_route,
                )
            )
        ).all()
        for message in pending_messages:
            conn.execute(
                delete(message_receipts).where(
                    and_(
                        message_receipts.c.destination_route == message.destination_route,
                        message_receipts.c.message_id == message.message_id,
                    )
                )
            )
        conn.execute(
            delete(messages).where(
                or_(
                    messages.c.source_route == device_route,
                    messages.c.destination_route == device_route,
                )
            )
        )
        conn.execute(
            update(grants)
            .where(
                and_(
                    grants.c.status == "pending",
                    or_(
                        grants.c.source_route == device_route,
                        grants.c.destination_route == device_route,
                    ),
                )
            )
            .values(status="revoked", revoked_at_ms=now_ms)
        )
        conn.execute(
            update(routes)
            .where(routes.c.route_id == device_route)
            .values(status="revoked", revoked_at_ms=now_ms)
        )

    def cancel_pair_offer(
        self, *, offer_id: str, owner_route: str, now_ms: int
    ) -> bool:
        with self._write_lock, self.engine.begin() as conn:
            offer = conn.execute(
                select(pair_offers).where(pair_offers.c.offer_id == offer_id).with_for_update()
            ).mappings().first()
            if offer is None:
                return False
            if offer["owner_route"] != owner_route:
                raise Forbidden("pair_offer_owner_mismatch")
            self._revoke_pending_device(
                conn, device_route=offer["device_route"], now_ms=now_ms
            )
            conn.execute(delete(pair_offers).where(pair_offers.c.offer_id == offer_id))
            return True

    def authorize_message(self, *, source_route: str, destination_route: str, now_ms: int) -> None:
        with self.engine.connect() as conn:
            route_rows = conn.execute(
                select(routes.c.route_id, routes.c.status).where(
                    routes.c.route_id.in_([source_route, destination_route])
                )
            ).all()
            statuses = {row.route_id: row.status for row in route_rows}
            if statuses.get(source_route) != "active" or statuses.get(destination_route) != "active":
                raise Forbidden("route_not_active")
            grant = conn.execute(
                select(grants.c.permissions).where(
                    and_(
                        grants.c.source_route == source_route,
                        grants.c.destination_route == destination_route,
                        grants.c.status == "active",
                        grants.c.revoked_at_ms.is_(None),
                        or_(grants.c.expires_at_ms.is_(None), grants.c.expires_at_ms > now_ms),
                    )
                )
            ).first()
            if grant is None or not (int(grant.permissions) & _PERMISSION_BITS["send"]):
                raise Forbidden("route_grant_missing")

    def accept_envelope(self, envelope: OuterEnvelope, *, now_ms: int) -> AcceptResult:
        mid = b64url_decode(envelope.mid, field="mid", exact=16)
        enc = b64url_decode(envelope.enc, field="enc", exact=32)
        ciphertext = b64url_decode(envelope.ct, field="ct", maximum=256 * 1024)
        signature = b64url_decode(envelope.sig, field="sig", exact=64)
        collapse_id = envelope.collapse.encode("utf-8") if envelope.collapse is not None else None
        digest = envelope_hash(envelope)
        size_bytes = len(enc) + len(ciphertext)
        with self._write_lock, self.engine.begin() as conn:
            route_rows = conn.execute(
                select(
                    routes.c.route_id,
                    routes.c.status,
                    routes.c.route_type,
                    routes.c.owner_route,
                    routes.c.pair_offer_id,
                    routes.c.pending_control_used_at_ms,
                )
                .where(routes.c.route_id.in_(sorted([envelope.src, envelope.dst])))
                .order_by(routes.c.route_id)
                .with_for_update()
            ).mappings().all()
            route_state = {row["route_id"]: row for row in route_rows}
            source = route_state.get(envelope.src)
            destination = route_state.get(envelope.dst)
            pending_pair_control = False
            if source is None or destination is None:
                raise Forbidden("route_not_active")
            if source["status"] == "active" and destination["status"] == "active":
                required_grant_status = "active"
            elif (
                source["status"] == "pending"
                and source["route_type"] == "device"
                and source["owner_route"] == envelope.dst
                and destination["status"] == "active"
                and destination["route_type"] == "agent"
                and source["pair_offer_id"] is not None
            ):
                if envelope.message_class != "control":
                    raise Forbidden("pending_pair_control_only")
                offer = conn.execute(
                    select(pair_offers)
                    .where(pair_offers.c.offer_id == source["pair_offer_id"])
                    .with_for_update()
                ).mappings().first()
                if offer is None or int(offer["expires_at_ms"]) <= now_ms:
                    raise Forbidden("pair_offer_expired")
                if (
                    offer["device_route"] != envelope.src
                    or offer["owner_route"] != envelope.dst
                    or offer["response_hash"] is None
                ):
                    raise Forbidden("pair_accept_not_ready")
                if envelope.expires_at_ms > int(offer["expires_at_ms"]):
                    raise Forbidden("pending_pair_control_expiry_too_long")
                required_grant_status = "pending"
                pending_pair_control = True
            else:
                raise Forbidden("route_not_active")
            grant = conn.execute(
                select(grants.c.permissions)
                .where(
                    and_(
                        grants.c.source_route == envelope.src,
                        grants.c.destination_route == envelope.dst,
                        grants.c.status == required_grant_status,
                        grants.c.revoked_at_ms.is_(None),
                        or_(grants.c.expires_at_ms.is_(None), grants.c.expires_at_ms > now_ms),
                    )
                )
                .with_for_update()
            ).first()
            if grant is None or not (int(grant.permissions) & _PERMISSION_BITS["send"]):
                raise Forbidden("route_grant_missing")
            receipt = conn.execute(
                select(message_receipts.c.envelope_hash).where(
                    and_(
                        message_receipts.c.destination_route == envelope.dst,
                        message_receipts.c.message_id == mid,
                    )
                )
            ).first()
            if receipt is not None:
                if bytes(receipt.envelope_hash) != digest:
                    raise Conflict("message_id_conflict")
                return AcceptResult(deduplicated=True, stored=envelope.message_class != "realtime")

            live_receipts = conn.execute(
                select(func.count()).select_from(message_receipts).where(
                    and_(
                        message_receipts.c.destination_route == envelope.dst,
                        message_receipts.c.expires_at_ms > now_ms,
                    )
                )
            ).scalar_one()
            priority_receipt = envelope.message_class in {"command", "control"}
            receipt_limit = self.settings.receipt_records_per_route - (
                0 if priority_receipt else self.settings.receipt_reserved_records
            )
            if int(live_receipts) >= receipt_limit:
                raise MailboxFull("receipt_capacity_full")
            recent_receipts = conn.execute(
                select(func.count()).select_from(message_receipts).where(
                    and_(
                        message_receipts.c.destination_route == envelope.dst,
                        message_receipts.c.created_at_ms > now_ms - 60_000,
                    )
                )
            ).scalar_one()
            rate_limit = self.settings.accepted_messages_per_route_per_minute - (
                0 if priority_receipt else self.settings.accepted_message_rate_reserve
            )
            if int(recent_receipts) >= rate_limit:
                raise MailboxFull("route_message_rate_limited")

            if pending_pair_control and source["pending_control_used_at_ms"] is not None:
                raise Forbidden("pending_pair_control_already_used")

            if envelope.message_class == "realtime":
                conn.execute(
                    insert(message_receipts).values(
                        destination_route=envelope.dst,
                        message_id=mid,
                        envelope_hash=digest,
                        expires_at_ms=envelope.expires_at_ms,
                        created_at_ms=now_ms,
                    )
                )
                return AcceptResult(deduplicated=False, stored=False)

            if envelope.message_class == "state" and collapse_id is not None:
                conn.execute(
                    delete(messages).where(
                        and_(
                            messages.c.destination_route == envelope.dst,
                            messages.c.message_class == "state",
                            messages.c.collapse_id == collapse_id,
                        )
                    )
                )

            evicted = self._make_room(
                conn,
                destination_route=envelope.dst,
                incoming_class=envelope.message_class,
                incoming_bytes=size_bytes,
            )
            if pending_pair_control:
                conn.execute(
                    update(routes)
                    .where(
                        and_(
                            routes.c.route_id == envelope.src,
                            routes.c.status == "pending",
                            routes.c.pending_control_used_at_ms.is_(None),
                        )
                    )
                    .values(pending_control_used_at_ms=now_ms)
                )
            conn.execute(
                insert(message_receipts).values(
                    destination_route=envelope.dst,
                    message_id=mid,
                    envelope_hash=digest,
                    expires_at_ms=envelope.expires_at_ms,
                    created_at_ms=now_ms,
                )
            )
            conn.execute(
                insert(messages).values(
                    destination_route=envelope.dst,
                    message_id=mid,
                    source_route=envelope.src,
                    message_class=envelope.message_class,
                    expires_at_ms=envelope.expires_at_ms,
                    collapse_id=collapse_id,
                    key_generation=envelope.recipient_key_generation,
                    hpke_enc=enc,
                    ciphertext=ciphertext,
                    sender_signature=signature,
                    size_bytes=size_bytes,
                    created_at_ms=now_ms,
                )
            )
            return AcceptResult(deduplicated=False, stored=True, evicted_state_records=evicted)

    def _make_room(
        self, conn: Connection, *, destination_route: str, incoming_class: str, incoming_bytes: int
    ) -> int:
        rows = conn.execute(
            select(
                messages.c.message_id,
                messages.c.message_class,
                messages.c.size_bytes,
                messages.c.created_at_ms,
            )
            .where(messages.c.destination_route == destination_route)
            .order_by(messages.c.created_at_ms, messages.c.message_id)
        ).mappings().all()
        evicted = 0
        while True:
            total_count = len(rows) + 1
            total_bytes = sum(int(row["size_bytes"]) for row in rows) + incoming_bytes
            state_count = sum(row["message_class"] == "state" for row in rows) + (incoming_class == "state")
            state_bytes = sum(
                int(row["size_bytes"]) for row in rows if row["message_class"] == "state"
            ) + (incoming_bytes if incoming_class == "state" else 0)
            limits_ok = total_count <= self.settings.mailbox_records and total_bytes <= self.settings.mailbox_bytes
            reserve_ok = (
                state_count <= self.settings.mailbox_records - self.settings.reserved_records
                and state_bytes <= self.settings.mailbox_bytes - self.settings.reserved_bytes
            )
            if limits_ok and reserve_ok:
                return evicted
            victim_index = next(
                (index for index, row in enumerate(rows) if row["message_class"] == "state"), None
            )
            if victim_index is None:
                raise MailboxFull("mailbox_full")
            victim = rows.pop(victim_index)
            conn.execute(
                delete(messages).where(
                    and_(
                        messages.c.destination_route == destination_route,
                        messages.c.message_id == victim["message_id"],
                    )
                )
            )
            evicted += 1

    def pending_envelopes(self, *, route_id: str, now_ms: int, limit: int = 256) -> list[dict]:
        with self.engine.begin() as conn:
            rows = conn.execute(
                select(messages)
                .where(
                    and_(
                        messages.c.destination_route == route_id,
                        messages.c.expires_at_ms > now_ms,
                    )
                )
                .order_by(messages.c.created_at_ms, messages.c.message_id)
                .limit(limit)
            ).mappings().all()
            if rows:
                ids = [row["message_id"] for row in rows]
                conn.execute(
                    update(messages)
                    .where(
                        and_(
                            messages.c.destination_route == route_id,
                            messages.c.message_id.in_(ids),
                        )
                    )
                    .values(delivered_at_ms=now_ms)
                )
        return [self._row_to_envelope(row) for row in rows]

    @staticmethod
    def _row_to_envelope(row: RowMapping) -> dict:
        return {
            "v": 2,
            "src": row["source_route"],
            "dst": row["destination_route"],
            "mid": b64url_encode(bytes(row["message_id"])),
            "class": row["message_class"],
            "expires_at_ms": row["expires_at_ms"],
            "recipient_key_generation": row["key_generation"],
            "collapse": bytes(row["collapse_id"]).decode("utf-8") if row["collapse_id"] is not None else None,
            "enc": b64url_encode(bytes(row["hpke_enc"])),
            "ct": b64url_encode(bytes(row["ciphertext"])),
            "sig": b64url_encode(bytes(row["sender_signature"])),
        }

    def acknowledge(self, *, route_id: str, message_ids: list[bytes]) -> int:
        with self._write_lock, self.engine.begin() as conn:
            result = conn.execute(
                delete(messages).where(
                    and_(
                        messages.c.destination_route == route_id,
                        messages.c.message_id.in_(message_ids),
                    )
                )
            )
            return int(result.rowcount or 0)

    def purge(self, now_ms: int) -> dict[str, int]:
        with self._write_lock, self.engine.begin() as conn:
            provisional_event_count = conn.execute(
                delete(provisional_enrollment_events).where(
                    provisional_enrollment_events.c.expires_at_ms <= now_ms
                )
            ).rowcount or 0
            message_count = conn.execute(delete(messages).where(messages.c.expires_at_ms <= now_ms)).rowcount or 0
            receipt_count = conn.execute(
                delete(message_receipts).where(message_receipts.c.expires_at_ms <= now_ms)
            ).rowcount or 0
            nonce_count = conn.execute(delete(request_nonces).where(request_nonces.c.expires_at_ms <= now_ms)).rowcount or 0
            confirm_receipt_count = conn.execute(
                delete(pair_confirm_receipts).where(
                    pair_confirm_receipts.c.expires_at_ms <= now_ms
                )
            ).rowcount or 0
            route_count = conn.execute(
                update(routes)
                .where(
                    and_(
                        routes.c.status == "provisional",
                        routes.c.expires_at_ms.is_not(None),
                        routes.c.expires_at_ms <= now_ms,
                    )
                )
                .values(status="revoked", revoked_at_ms=now_ms)
            ).rowcount or 0
            expired_offers = conn.execute(
                select(pair_offers.c.offer_id, pair_offers.c.device_route)
                .where(pair_offers.c.expires_at_ms <= now_ms)
                .with_for_update()
            ).all()
            for offer in expired_offers:
                self._revoke_pending_device(
                    conn, device_route=offer.device_route, now_ms=now_ms
                )
            offer_count = conn.execute(
                delete(pair_offers).where(pair_offers.c.expires_at_ms <= now_ms)
            ).rowcount or 0
        return {
            "provisional_enrollment_events": int(provisional_event_count),
            "messages": int(message_count),
            "receipts": int(receipt_count),
            "request_nonces": int(nonce_count),
            "pair_confirm_receipts": int(confirm_receipt_count),
            "routes": int(route_count),
            "pair_offers": int(offer_count),
        }

    def counts(self, route_id: str) -> tuple[int, int, int]:
        """Test/operations helper returning records, bytes, and state records."""
        with self.engine.connect() as conn:
            row = conn.execute(
                select(
                    func.count().label("records"),
                    func.coalesce(func.sum(messages.c.size_bytes), 0).label("bytes"),
                    func.coalesce(
                        func.sum(case((messages.c.message_class == "state", 1), else_=0)), 0
                    ).label("state_records"),
                ).where(messages.c.destination_route == route_id)
            ).first()
        return int(row.records), int(row.bytes), int(row.state_records)
