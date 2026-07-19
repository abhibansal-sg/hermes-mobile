from __future__ import annotations

import base64
import json
import os
import re
from dataclasses import dataclass, field
from typing import Mapping

from .secure_files import read_secure_text


MAX_TOKEN_MASTER_KEYS = 16
MAX_TOKEN_KEY_VERSION = (1 << 32) - 1
MAX_ACTIVATION_SIGNING_KEYS = 8
_KEY_ID = re.compile(r"^[A-Za-z0-9._~-]{1,64}$")


def _decode_key(name: str, *, required: bool) -> bytes | None:
    value = os.getenv(name)
    if not value:
        if required:
            raise ValueError(f"{name} is required")
        return None
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ValueError(f"{name} must be standard base64") from exc
    if len(decoded) != 32:
        raise ValueError(f"{name} must decode to 32 bytes")
    return decoded


def _decode_key_value(value: object, *, label: str) -> bytes:
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a non-empty base64 string")
    try:
        decoded = base64.b64decode(value, validate=True)
    except Exception as exc:
        raise ValueError(f"{label} must be standard base64") from exc
    if len(decoded) != 32:
        raise ValueError(f"{label} must decode to 32 bytes")
    return decoded


def _parse_token_keyring(value: str, *, source: str) -> tuple[tuple[int, bytes], ...]:
    if len(value.encode("utf-8")) > 16 * 1024:
        raise ValueError(f"{source} exceeds the token keyring size limit")
    try:
        pairs = json.loads(value, object_pairs_hook=lambda items: items)
    except Exception as exc:
        raise ValueError(f"{source} must contain a JSON object") from exc
    if not isinstance(pairs, list) or any(
        not isinstance(item, tuple) or len(item) != 2 for item in pairs
    ):
        raise ValueError(f"{source} must contain a JSON object")
    if not pairs or len(pairs) > MAX_TOKEN_MASTER_KEYS:
        raise ValueError(
            f"{source} must contain between 1 and {MAX_TOKEN_MASTER_KEYS} keys"
        )

    result: list[tuple[int, bytes]] = []
    versions: set[int] = set()
    key_values: set[bytes] = set()
    for raw_version, raw_key in pairs:
        if (
            not isinstance(raw_version, str)
            or not raw_version.isascii()
            or not raw_version.isdecimal()
            or str(int(raw_version)) != raw_version
        ):
            raise ValueError(f"{source} token key versions must be canonical integers")
        version = int(raw_version)
        if version <= 0 or version > MAX_TOKEN_KEY_VERSION:
            raise ValueError(
                f"{source} token key versions must be between 1 and {MAX_TOKEN_KEY_VERSION}"
            )
        if version in versions:
            raise ValueError(f"{source} contains duplicate token key version {version}")
        key = _decode_key_value(raw_key, label=f"{source} version {version}")
        if key in key_values:
            raise ValueError(f"{source} must use a distinct key for every version")
        versions.add(version)
        key_values.add(key)
        result.append((version, key))
    return tuple(sorted(result))


def _load_token_keys() -> tuple[bytes, tuple[tuple[int, bytes], ...], int]:
    inline = os.getenv("HPG_TOKEN_MASTER_KEYS_JSON")
    keyring_path = os.getenv("HPG_TOKEN_MASTER_KEYS_FILE")
    legacy = os.getenv("HPG_TOKEN_MASTER_KEY_B64")
    configured = sum(bool(value) for value in (inline, keyring_path, legacy))
    if configured == 0:
        raise ValueError(
            "HPG_TOKEN_MASTER_KEY_B64, HPG_TOKEN_MASTER_KEYS_JSON, or "
            "HPG_TOKEN_MASTER_KEYS_FILE is required"
        )
    if configured > 1:
        raise ValueError("configure exactly one token master-key source")

    raw_version = os.getenv("HPG_TOKEN_KEY_VERSION", "1")
    try:
        current_version = int(raw_version)
    except ValueError as exc:
        raise ValueError("HPG_TOKEN_KEY_VERSION must be an integer") from exc

    if keyring_path:
        serialized = read_secure_text(
            keyring_path,
            label="HPG_TOKEN_MASTER_KEYS_FILE",
            max_bytes=16 * 1024,
        )
        entries = _parse_token_keyring(serialized, source="HPG_TOKEN_MASTER_KEYS_FILE")
    elif inline:
        entries = _parse_token_keyring(inline, source="HPG_TOKEN_MASTER_KEYS_JSON")
    else:
        assert legacy is not None
        key = _decode_key_value(legacy, label="HPG_TOKEN_MASTER_KEY_B64")
        entries = ((current_version, key),)

    keys = dict(entries)
    if current_version not in keys:
        raise ValueError("HPG_TOKEN_KEY_VERSION is not present in the token keyring")
    return keys[current_version], entries, current_version


def _parse_activation_keyring(
    value: str, *, source: str
) -> tuple[tuple[str, bytes], ...]:
    if len(value.encode("utf-8")) > 16 * 1024:
        raise ValueError(f"{source} exceeds the activation keyring size limit")
    try:
        pairs = json.loads(value, object_pairs_hook=lambda items: items)
    except Exception as exc:
        raise ValueError(f"{source} must contain a JSON object") from exc
    if not isinstance(pairs, list) or any(
        not isinstance(item, tuple) or len(item) != 2 for item in pairs
    ):
        raise ValueError(f"{source} must contain a JSON object")
    if not pairs or len(pairs) > MAX_ACTIVATION_SIGNING_KEYS:
        raise ValueError(
            f"{source} must contain between 1 and {MAX_ACTIVATION_SIGNING_KEYS} keys"
        )
    result: list[tuple[str, bytes]] = []
    key_ids: set[str] = set()
    seeds: set[bytes] = set()
    for key_id, raw_key in pairs:
        if not isinstance(key_id, str) or not _KEY_ID.fullmatch(key_id):
            raise ValueError(f"{source} contains an invalid activation key ID")
        if key_id in key_ids:
            raise ValueError(f"{source} contains duplicate activation key ID {key_id}")
        seed = _decode_key_value(raw_key, label=f"{source} key {key_id}")
        if seed in seeds:
            raise ValueError(f"{source} must use a distinct seed for every key ID")
        key_ids.add(key_id)
        seeds.add(seed)
        result.append((key_id, seed))
    return tuple(result)


def _load_activation_keys() -> tuple[
    bytes | None, str | None, tuple[tuple[str, bytes], ...]
]:
    inline = os.getenv("HPG_HUB_ACTIVATION_PRIVATE_KEYS_JSON")
    keyring_path = os.getenv("HPG_HUB_ACTIVATION_PRIVATE_KEYS_FILE")
    legacy = os.getenv("HPG_HUB_ACTIVATION_PRIVATE_KEY_B64")
    requested_key_id = os.getenv("HPG_HUB_ACTIVATION_KEY_ID")
    configured = sum(bool(value) for value in (inline, keyring_path, legacy))
    if configured > 1:
        raise ValueError("configure exactly one Hub activation private-key source")
    if configured == 0:
        if requested_key_id:
            raise ValueError("HPG_HUB_ACTIVATION_KEY_ID requires an activation keyring")
        return None, None, ()
    if legacy:
        if requested_key_id:
            raise ValueError(
                "HPG_HUB_ACTIVATION_KEY_ID is only valid with an activation keyring"
            )
        return (
            _decode_key_value(legacy, label="HPG_HUB_ACTIVATION_PRIVATE_KEY_B64"),
            None,
            (),
        )

    if keyring_path:
        serialized = read_secure_text(
            keyring_path,
            label="HPG_HUB_ACTIVATION_PRIVATE_KEYS_FILE",
            max_bytes=16 * 1024,
        )
        entries = _parse_activation_keyring(
            serialized, source="HPG_HUB_ACTIVATION_PRIVATE_KEYS_FILE"
        )
    else:
        assert inline is not None
        entries = _parse_activation_keyring(
            inline, source="HPG_HUB_ACTIVATION_PRIVATE_KEYS_JSON"
        )
    current_id = requested_key_id
    if current_id is None or not _KEY_ID.fullmatch(current_id):
        raise ValueError(
            "HPG_HUB_ACTIVATION_KEY_ID is required and must be a valid key ID"
        )
    keys = dict(entries)
    if current_id not in keys:
        raise ValueError(
            "HPG_HUB_ACTIVATION_KEY_ID is not present in the activation keyring"
        )
    return keys[current_id], current_id, entries


def _bool(name: str, default: bool) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    database_url: str = field(repr=False)
    token_master_key: bytes = field(repr=False)
    capability_pepper: bytes = field(repr=False)
    production_mode: bool = False
    token_key_version: int = 1
    token_master_keys: tuple[tuple[int, bytes], ...] | Mapping[int, bytes] = field(
        default_factory=tuple, repr=False
    )
    allowed_bundle_ids: frozenset[str] = field(
        default_factory=lambda: frozenset({"ai.hermes.app"})
    )
    apple_team_id: str | None = None
    apple_app_id: str | None = None
    app_attest_production: bool = True
    allow_development_attestation: bool = False
    development_registration_token: str | None = field(default=None, repr=False)
    challenge_ttl_seconds: int = 300
    challenge_per_source_per_hour: int = 60
    maximum_live_challenges: int = 10_000
    attestation_max_concurrency: int = 4
    database_max_concurrency: int = 8
    bind_token_ttl_seconds: int = 600
    response_receipt_ttl_seconds: int = 86_400
    max_sends_per_hour: int = 120
    max_sends_per_day: int = 1000
    send_retry_base_seconds: int = 2
    send_retry_max_seconds: int = 60
    apns_key_pem: str | None = field(default=None, repr=False)
    apns_key_id: str | None = None
    apns_team_id: str | None = None
    require_apns: bool = True
    hub_activation_private_key: bytes | None = field(default=None, repr=False)
    hub_activation_key_id: str | None = None
    hub_activation_private_keys: tuple[tuple[str, bytes], ...] | Mapping[str, bytes] = (
        field(default_factory=tuple, repr=False)
    )
    auto_create_schema: bool = True

    @classmethod
    def from_env(cls) -> "Settings":
        master, master_keys, key_version = _load_token_keys()
        activation_key, activation_key_id, activation_keys = _load_activation_keys()
        pepper = _decode_key("HPG_CAPABILITY_PEPPER_B64", required=True)
        assert master is not None and pepper is not None
        apns_key = os.getenv("HPG_APNS_KEY_PEM")
        key_path = os.getenv("HPG_APNS_KEY_PATH")
        if apns_key is None and key_path:
            apns_key = read_secure_text(
                key_path,
                label="HPG_APNS_KEY_PATH",
                max_bytes=64 * 1024,
            )
        bundles = frozenset(
            value.strip()
            for value in os.getenv("HPG_ALLOWED_BUNDLE_IDS", "ai.hermes.app").split(",")
            if value.strip()
        )
        settings = cls(
            database_url=os.getenv(
                "HPG_DATABASE_URL", "sqlite:///./data/push-gateway.db"
            ),
            token_master_key=master,
            capability_pepper=pepper,
            production_mode=_bool("HPG_PRODUCTION", False),
            token_key_version=key_version,
            token_master_keys=master_keys,
            allowed_bundle_ids=bundles,
            apple_team_id=os.getenv("HPG_APPLE_TEAM_ID"),
            apple_app_id=os.getenv("HPG_APPLE_APP_ID"),
            app_attest_production=_bool("HPG_APP_ATTEST_PRODUCTION", True),
            allow_development_attestation=_bool(
                "HPG_ALLOW_DEVELOPMENT_ATTESTATION", False
            ),
            development_registration_token=os.getenv(
                "HPG_DEVELOPMENT_REGISTRATION_TOKEN"
            ),
            challenge_ttl_seconds=int(os.getenv("HPG_CHALLENGE_TTL_SECONDS", "300")),
            challenge_per_source_per_hour=int(
                os.getenv("HPG_CHALLENGE_PER_SOURCE_PER_HOUR", "60")
            ),
            maximum_live_challenges=int(
                os.getenv("HPG_MAXIMUM_LIVE_CHALLENGES", "10000")
            ),
            attestation_max_concurrency=int(
                os.getenv("HPG_ATTESTATION_MAX_CONCURRENCY", "4")
            ),
            database_max_concurrency=int(
                os.getenv("HPG_DATABASE_MAX_CONCURRENCY", "8")
            ),
            bind_token_ttl_seconds=int(os.getenv("HPG_BIND_TOKEN_TTL_SECONDS", "600")),
            response_receipt_ttl_seconds=int(
                os.getenv("HPG_RESPONSE_RECEIPT_TTL_SECONDS", "86400")
            ),
            max_sends_per_hour=int(os.getenv("HPG_MAX_SENDS_PER_HOUR", "120")),
            max_sends_per_day=int(os.getenv("HPG_MAX_SENDS_PER_DAY", "1000")),
            send_retry_base_seconds=int(os.getenv("HPG_SEND_RETRY_BASE_SECONDS", "2")),
            send_retry_max_seconds=int(os.getenv("HPG_SEND_RETRY_MAX_SECONDS", "60")),
            apns_key_pem=apns_key,
            apns_key_id=os.getenv("HPG_APNS_KEY_ID"),
            apns_team_id=os.getenv("HPG_APNS_TEAM_ID"),
            require_apns=_bool("HPG_REQUIRE_APNS", True),
            hub_activation_private_key=activation_key,
            hub_activation_key_id=activation_key_id,
            hub_activation_private_keys=activation_keys,
            auto_create_schema=_bool("HPG_AUTO_CREATE_SCHEMA", True),
        )
        settings.validate()
        return settings

    @property
    def apns_configured(self) -> bool:
        return bool(self.apns_key_pem and self.apns_key_id and self.apns_team_id)

    @property
    def token_keyring(self) -> dict[int, bytes]:
        if isinstance(self.token_master_keys, Mapping):
            items = tuple(self.token_master_keys.items())
        else:
            items = tuple(self.token_master_keys)
        if not items:
            return {self.token_key_version: self.token_master_key}
        return dict(items)

    def validate(self) -> None:
        if self.production_mode:
            if self.database_url.startswith("sqlite"):
                raise ValueError("production Push Gateway requires PostgreSQL")
            if self.auto_create_schema:
                raise ValueError("production Push Gateway requires explicit migrations")
            if not self.require_apns or not self.apns_configured:
                raise ValueError("production Push Gateway requires APNs")
            if not self.apple_app_id:
                raise ValueError("production Push Gateway requires App Attest")
            if (
                self.development_registration_token
                or self.allow_development_attestation
            ):
                raise ValueError(
                    "development attestation must be disabled in production"
                )
        if (
            not isinstance(self.token_master_key, bytes)
            or len(self.token_master_key) != 32
            or not isinstance(self.capability_pepper, bytes)
            or len(self.capability_pepper) != 32
        ):
            raise ValueError("master key and capability pepper must each be 32 bytes")
        if not 1 <= self.token_key_version <= MAX_TOKEN_KEY_VERSION:
            raise ValueError("token key version must be a positive 32-bit integer")
        if isinstance(self.token_master_keys, Mapping):
            key_items = tuple(self.token_master_keys.items())
        else:
            key_items = tuple(self.token_master_keys)
        if not key_items:
            key_items = ((self.token_key_version, self.token_master_key),)
        if not 1 <= len(key_items) <= MAX_TOKEN_MASTER_KEYS:
            raise ValueError("token keyring contains too many keys")
        versions = [version for version, _key in key_items]
        keys = [key for _version, key in key_items]
        if len(set(versions)) != len(versions) or any(
            not isinstance(version, int)
            or isinstance(version, bool)
            or version <= 0
            or version > MAX_TOKEN_KEY_VERSION
            for version in versions
        ):
            raise ValueError("token keyring versions must be unique positive integers")
        if any(not isinstance(key, bytes) or len(key) != 32 for key in keys):
            raise ValueError("token master keys must each be 32 bytes")
        if len(set(keys)) != len(keys):
            raise ValueError("token keyring keys must be unique")
        keyring = dict(key_items)
        if keyring.get(self.token_key_version) != self.token_master_key:
            raise ValueError(
                "current token master key does not match its keyring entry"
            )
        if not self.allowed_bundle_ids:
            raise ValueError("at least one allowed bundle ID is required")
        if isinstance(self.hub_activation_private_keys, Mapping):
            activation_items = tuple(self.hub_activation_private_keys.items())
        else:
            activation_items = tuple(self.hub_activation_private_keys)
        if activation_items:
            if not 1 <= len(activation_items) <= MAX_ACTIVATION_SIGNING_KEYS:
                raise ValueError("activation signing keyring contains too many keys")
            key_ids = [key_id for key_id, _seed in activation_items]
            seeds = [seed for _key_id, seed in activation_items]
            if len(set(key_ids)) != len(key_ids) or any(
                not isinstance(key_id, str) or not _KEY_ID.fullmatch(key_id)
                for key_id in key_ids
            ):
                raise ValueError("activation signing key IDs must be unique and valid")
            if len(set(seeds)) != len(seeds) or any(
                not isinstance(seed, bytes) or len(seed) != 32 for seed in seeds
            ):
                raise ValueError(
                    "activation signing seeds must be unique 32-byte values"
                )
            activation_keyring = dict(activation_items)
            if (
                self.hub_activation_key_id not in activation_keyring
                or activation_keyring[self.hub_activation_key_id]
                != self.hub_activation_private_key
            ):
                raise ValueError(
                    "current activation signing key does not match its keyring entry"
                )
        elif self.hub_activation_key_id is not None:
            raise ValueError("legacy activation signing key must not declare a key ID")
        if self.hub_activation_private_key is not None and (
            not isinstance(self.hub_activation_private_key, bytes)
            or len(self.hub_activation_private_key) != 32
        ):
            raise ValueError("Hub activation private key must be 32 bytes")
        if self.challenge_ttl_seconds < 30 or self.challenge_ttl_seconds > 600:
            raise ValueError("challenge TTL must be between 30 and 600 seconds")
        if self.bind_token_ttl_seconds < 60 or self.bind_token_ttl_seconds > 1800:
            raise ValueError("bind token TTL must be between 60 and 1800 seconds")
        if self.challenge_per_source_per_hour <= 0 or self.maximum_live_challenges <= 0:
            raise ValueError("challenge issuance limits must be positive")
        if not 1 <= self.attestation_max_concurrency <= 64:
            raise ValueError("attestation concurrency must be between 1 and 64")
        if not 1 <= self.database_max_concurrency <= 64:
            raise ValueError("database concurrency must be between 1 and 64")
        if not 600 <= self.response_receipt_ttl_seconds <= 604_800:
            raise ValueError(
                "response receipt TTL must be between 10 minutes and 7 days"
            )
        if (
            self.max_sends_per_hour <= 0
            or self.max_sends_per_day < self.max_sends_per_hour
        ):
            raise ValueError("invalid per-binding send limits")
        if (
            self.send_retry_base_seconds <= 0
            or self.send_retry_max_seconds < self.send_retry_base_seconds
            or self.send_retry_max_seconds > 3600
        ):
            raise ValueError("invalid send retry backoff")
        if self.require_apns and not self.apns_configured:
            raise ValueError("APNs credentials are required")
        if not self.apple_app_id and not self.development_registration_token:
            raise ValueError(
                "App Attest configuration or an explicit development token is required"
            )
