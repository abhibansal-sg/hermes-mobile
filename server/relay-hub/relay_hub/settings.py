from __future__ import annotations

import base64
import json
import os
import re
from dataclasses import dataclass
from pathlib import Path


_KEY_ID = re.compile(r"^[A-Za-z0-9._~-]{1,64}$")


def _bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _public_key(encoded: str, *, setting: str) -> bytes:
    try:
        key = base64.b64decode(encoded, validate=True)
    except Exception as exc:
        raise ValueError(f"{setting} values must be standard base64") from exc
    if len(key) != 32:
        raise ValueError(f"{setting} values must decode to 32 bytes")
    return key


def _activation_keyring_from_env() -> tuple[tuple[str, bytes], ...]:
    inline = os.getenv("HRH_ACTIVATION_PUBLIC_KEYS_JSON")
    filename = os.getenv("HRH_ACTIVATION_PUBLIC_KEYS_FILE")
    if inline and filename:
        raise ValueError(
            "HRH_ACTIVATION_PUBLIC_KEYS_JSON and HRH_ACTIVATION_PUBLIC_KEYS_FILE "
            "are mutually exclusive"
        )
    if filename:
        try:
            inline = Path(filename).read_text(encoding="utf-8")
        except OSError as exc:
            raise ValueError("unable to read HRH_ACTIVATION_PUBLIC_KEYS_FILE") from exc
    if not inline:
        return ()
    try:
        values = json.loads(inline)
    except json.JSONDecodeError as exc:
        raise ValueError("activation public keyring must be valid JSON") from exc
    if not isinstance(values, dict) or not values:
        raise ValueError("activation public keyring must be a non-empty JSON object")
    if len(values) > 8:
        raise ValueError("activation public keyring must contain at most 8 keys")
    result: list[tuple[str, bytes]] = []
    for key_id, encoded in values.items():
        if not isinstance(key_id, str) or not _KEY_ID.fullmatch(key_id):
            raise ValueError("activation public key IDs must use 1-64 safe characters")
        if not isinstance(encoded, str):
            raise ValueError("activation public keyring values must be base64 strings")
        result.append(
            (
                key_id,
                _public_key(encoded, setting="activation public keyring"),
            )
        )
    return tuple(result)


@dataclass(frozen=True)
class Settings:
    production_mode: bool = False
    database_url: str = "sqlite:///./data/relay-hub.db"
    operator_enrollment_token: str | None = None
    development_activation_token: str | None = None
    activation_public_key: bytes | None = None
    activation_public_keys: tuple[tuple[str, bytes], ...] = ()
    provisional_ttl_seconds: int = 600
    maximum_retention_seconds: int = 86_400
    request_clock_skew_seconds: int = 300
    mailbox_records: int = 256
    mailbox_bytes: int = 4 * 1024 * 1024
    reserved_records: int = 64
    reserved_bytes: int = 512 * 1024
    receipt_records_per_route: int = 4096
    receipt_reserved_records: int = 64
    accepted_messages_per_route_per_minute: int = 600
    accepted_message_rate_reserve: int = 60
    maximum_request_body_bytes: int = 400_000
    database_max_concurrency: int = 8
    database_acquire_timeout_seconds: float = 1.0
    socket_queue_depth: int = 512
    socket_queue_max_bytes: int | None = None
    socket_queue_total_max_bytes: int = 64 * 1024 * 1024
    maximum_socket_connections: int = 512
    maximum_socket_connections_per_route: int = 4
    provisional_per_source_per_hour: int = 20
    maximum_provisional_rate_limit_sources: int = 20_000
    maximum_live_provisional_routes: int = 10_000
    maximum_live_pair_offers_per_route: int = 8
    pair_confirmation_receipt_ttl_seconds: int = 86_400
    auto_create_schema: bool = True

    @classmethod
    def from_env(cls) -> "Settings":
        activation_key: bytes | None = None
        encoded_key = os.getenv("HRH_ACTIVATION_PUBLIC_KEY_B64")
        if encoded_key:
            activation_key = _public_key(
                encoded_key,
                setting="HRH_ACTIVATION_PUBLIC_KEY_B64",
            )
        settings = cls(
            production_mode=_bool("HRH_PRODUCTION", False),
            database_url=os.getenv("HRH_DATABASE_URL", cls.database_url),
            operator_enrollment_token=os.getenv("HRH_OPERATOR_ENROLLMENT_TOKEN"),
            development_activation_token=os.getenv("HRH_DEVELOPMENT_ACTIVATION_TOKEN"),
            activation_public_key=activation_key,
            activation_public_keys=_activation_keyring_from_env(),
            provisional_ttl_seconds=int(os.getenv("HRH_PROVISIONAL_TTL_SECONDS", "600")),
            maximum_retention_seconds=int(os.getenv("HRH_MAXIMUM_RETENTION_SECONDS", "86400")),
            request_clock_skew_seconds=int(os.getenv("HRH_REQUEST_CLOCK_SKEW_SECONDS", "300")),
            socket_queue_depth=int(os.getenv("HRH_SOCKET_QUEUE_DEPTH", "512")),
            socket_queue_max_bytes=(
                int(os.environ["HRH_SOCKET_QUEUE_MAX_BYTES"])
                if os.getenv("HRH_SOCKET_QUEUE_MAX_BYTES")
                else None
            ),
            socket_queue_total_max_bytes=int(
                os.getenv("HRH_SOCKET_QUEUE_TOTAL_MAX_BYTES", str(64 * 1024 * 1024))
            ),
            receipt_records_per_route=int(
                os.getenv("HRH_RECEIPT_RECORDS_PER_ROUTE", "4096")
            ),
            receipt_reserved_records=int(
                os.getenv("HRH_RECEIPT_RESERVED_RECORDS", "64")
            ),
            accepted_messages_per_route_per_minute=int(
                os.getenv("HRH_ACCEPTED_MESSAGES_PER_ROUTE_PER_MINUTE", "600")
            ),
            accepted_message_rate_reserve=int(
                os.getenv("HRH_ACCEPTED_MESSAGE_RATE_RESERVE", "60")
            ),
            maximum_request_body_bytes=int(
                os.getenv("HRH_MAXIMUM_REQUEST_BODY_BYTES", "400000")
            ),
            database_max_concurrency=int(
                os.getenv("HRH_DATABASE_MAX_CONCURRENCY", "8")
            ),
            database_acquire_timeout_seconds=float(
                os.getenv("HRH_DATABASE_ACQUIRE_TIMEOUT_SECONDS", "1.0")
            ),
            maximum_socket_connections=int(
                os.getenv("HRH_MAXIMUM_SOCKET_CONNECTIONS", "512")
            ),
            maximum_socket_connections_per_route=int(
                os.getenv("HRH_MAXIMUM_SOCKET_CONNECTIONS_PER_ROUTE", "4")
            ),
            provisional_per_source_per_hour=int(
                os.getenv("HRH_PROVISIONAL_PER_SOURCE_PER_HOUR", "20")
            ),
            maximum_provisional_rate_limit_sources=int(
                os.getenv("HRH_MAXIMUM_PROVISIONAL_RATE_LIMIT_SOURCES", "20000")
            ),
            maximum_live_provisional_routes=int(
                os.getenv("HRH_MAXIMUM_LIVE_PROVISIONAL_ROUTES", "10000")
            ),
            maximum_live_pair_offers_per_route=int(
                os.getenv("HRH_MAXIMUM_LIVE_PAIR_OFFERS_PER_ROUTE", "8")
            ),
            pair_confirmation_receipt_ttl_seconds=int(
                os.getenv("HRH_PAIR_CONFIRMATION_RECEIPT_TTL_SECONDS", "86400")
            ),
            auto_create_schema=_bool("HRH_AUTO_CREATE_SCHEMA", True),
        )
        settings.validate()
        return settings

    def validate(self) -> None:
        if self.production_mode:
            if self.database_url.startswith("sqlite"):
                raise ValueError("production Relay Hub requires PostgreSQL")
            if self.auto_create_schema:
                raise ValueError("production Relay Hub requires explicit migrations")
            if not (self.operator_enrollment_token or self.activation_verification_keys):
                raise ValueError("production Relay Hub requires an enrollment authority")
            if self.development_activation_token:
                raise ValueError("development activation must be disabled in production")
        keys = self.activation_verification_keys
        if len(keys) > 8:
            raise ValueError("activation public keyring must contain at most 8 keys")
        for key_id, public_key in keys:
            if (
                not isinstance(key_id, str)
                or not _KEY_ID.fullmatch(key_id)
                or not isinstance(public_key, bytes)
                or len(public_key) != 32
            ):
                raise ValueError("invalid activation public keyring")
        if self.provisional_ttl_seconds < 60 or self.provisional_ttl_seconds > 3600:
            raise ValueError("provisional TTL must be between 60 and 3600 seconds")
        if self.maximum_retention_seconds < 60 or self.maximum_retention_seconds > 86_400:
            raise ValueError("maximum retention must not exceed 24 hours")
        if not 0 < self.reserved_records < self.mailbox_records:
            raise ValueError("reserved record capacity must be smaller than mailbox capacity")
        if not 0 < self.reserved_bytes < self.mailbox_bytes:
            raise ValueError("reserved byte capacity must be smaller than mailbox capacity")
        if (
            self.provisional_per_source_per_hour <= 0
            or self.maximum_provisional_rate_limit_sources <= 0
            or self.maximum_live_provisional_routes <= 0
            or self.maximum_live_pair_offers_per_route <= 0
        ):
            raise ValueError("provisional enrollment limits must be positive")
        if not 1 <= self.database_max_concurrency <= 128:
            raise ValueError("database concurrency must be between 1 and 128")
        if not 0.001 <= self.database_acquire_timeout_seconds <= 30:
            raise ValueError("database acquire timeout must be between 1ms and 30 seconds")
        if not 1 <= self.socket_queue_depth <= 4096:
            raise ValueError("socket queue depth must be between 1 and 4096")
        if not 1 <= self.maximum_socket_connections <= 100_000:
            raise ValueError("maximum socket connections must be between 1 and 100000")
        if not (
            1
            <= self.maximum_socket_connections_per_route
            <= self.maximum_socket_connections
        ):
            raise ValueError("per-route socket limit must not exceed the global limit")
        if not 128 <= self.effective_socket_queue_max_bytes <= self.mailbox_bytes:
            raise ValueError(
                "per-socket queue bytes must be between 128 and the mailbox byte limit"
            )
        minimum_total_socket_bytes = (
            self.effective_socket_queue_max_bytes
            + self.maximum_socket_connections * 128
        )
        if not (
            minimum_total_socket_bytes
            <= self.socket_queue_total_max_bytes
            <= 1024 * 1024 * 1024
        ):
            raise ValueError(
                "total socket queue bytes must cover one full queue and all control reserves"
            )
        if self.maximum_provisional_rate_limit_sources > 1_000_000:
            raise ValueError("provisional rate-limit source capacity must not exceed 1000000")
        if not 600 <= self.pair_confirmation_receipt_ttl_seconds <= 604_800:
            raise ValueError("pair confirmation receipt TTL must be between 10 minutes and 7 days")
        if (
            self.receipt_records_per_route < self.mailbox_records
            or self.accepted_messages_per_route_per_minute <= 0
            or self.maximum_request_body_bytes < 64 * 1024
        ):
            raise ValueError("invalid message admission or request body limits")
        if not 0 < self.receipt_reserved_records < self.receipt_records_per_route:
            raise ValueError("invalid receipt reserve")
        if not 0 < self.accepted_message_rate_reserve < self.accepted_messages_per_route_per_minute:
            raise ValueError("invalid accepted-message rate reserve")

    @property
    def activation_verification_keys(self) -> tuple[tuple[str, bytes], ...]:
        if len(self.activation_public_keys) > 8:
            raise ValueError("activation public keyring must contain at most 8 keys")
        keys: dict[str, bytes] = {}
        for key_id, public_key in self.activation_public_keys:
            if not isinstance(key_id, str):
                raise ValueError("invalid activation public keyring")
            if key_id in keys:
                raise ValueError("activation public key IDs must be unique")
            keys[key_id] = public_key
        if self.activation_public_key is not None:
            configured = keys.get("legacy")
            if configured is not None and configured != self.activation_public_key:
                raise ValueError("legacy activation public keys disagree")
            keys["legacy"] = self.activation_public_key
        return tuple(keys.items())

    @property
    def effective_socket_queue_max_bytes(self) -> int:
        return (
            self.mailbox_bytes
            if self.socket_queue_max_bytes is None
            else self.socket_queue_max_bytes
        )
