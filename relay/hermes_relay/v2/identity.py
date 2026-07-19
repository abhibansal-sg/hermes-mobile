"""Persistent Agent Relay identity and KEM-generation rollover."""

from __future__ import annotations

from dataclasses import dataclass

from .crypto import generate_ed25519_key_pair, generate_x25519_key_pair
from .protection import (
    CredentialProtectionError,
    CredentialProtector,
    FilePermissionFallbackProtector,
    KeyringProtector,
    MacOSKeychainProtector,
    WindowsDPAPIProtector,
    platform_credential_protector,
)
from .storage import RelayIdentityRecord, RelayStorage, random_id


@dataclass(frozen=True, slots=True)
class RelayIdentity:
    relay_instance_id: str
    relay_epoch: str
    kem_generation: int
    kem_private: bytes
    kem_public: bytes
    sign_private: bytes
    sign_public: bytes
    protection_mode: str

    @classmethod
    def from_record(
        cls,
        record: RelayIdentityRecord,
        *,
        kem_private: bytes,
        sign_private: bytes,
        protection_mode: str,
    ) -> "RelayIdentity":
        return cls(
            relay_instance_id=record.relay_instance_id,
            relay_epoch=record.relay_epoch,
            kem_generation=record.kem_generation,
            kem_private=kem_private,
            kem_public=record.kem_public,
            sign_private=sign_private,
            sign_public=record.sign_public,
            protection_mode=protection_mode,
        )


def _protector_for_wrapped(
    wrapped: bytes, preferred: CredentialProtector
) -> tuple[CredentialProtector | None, str]:
    if wrapped.startswith(b"plain-v1:"):
        return FilePermissionFallbackProtector(), FilePermissionFallbackProtector.mode
    if wrapped.startswith(b"keychain-v1:"):
        protector = (
            preferred
            if isinstance(preferred, MacOSKeychainProtector)
            else MacOSKeychainProtector()
        )
        return protector, protector.mode
    if wrapped.startswith(b"dpapi-v1:"):
        protector = (
            preferred
            if isinstance(preferred, WindowsDPAPIProtector)
            else WindowsDPAPIProtector()
        )
        return protector, protector.mode
    if wrapped.startswith(b"keyring-v1:"):
        protector = (
            preferred if isinstance(preferred, KeyringProtector) else KeyringProtector()
        )
        return protector, protector.mode
    # Migration for an early v2 database which predated the protector seam.
    if len(wrapped) == 32:
        return None, "legacy-file-permissions-fallback"
    # Explicitly injected/vetted protectors may define their own opaque handle
    # prefix; let that protector validate and reveal it.
    return preferred, preferred.mode


def _reveal(
    wrapped: bytes, preferred: CredentialProtector
) -> tuple[bytes, str, CredentialProtector | None]:
    protector, mode = _protector_for_wrapped(wrapped, preferred)
    return (
        (wrapped if protector is None else protector.reveal(wrapped)),
        mode,
        protector,
    )


def load_or_create_identity(
    storage: RelayStorage,
    *,
    protector: CredentialProtector | None = None,
) -> RelayIdentity:
    """Return the stable identity, atomically creating it on first boot."""

    chosen = (
        protector or storage.credential_protector or platform_credential_protector()
    )
    record = storage.load_identity()
    if record is None:
        kem = generate_x25519_key_pair()
        sign = generate_ed25519_key_pair()
        instance = random_id("rly")
        epoch = random_id("epc")
        actual = chosen
        wrapped_kem: bytes | None = None
        try:
            wrapped_kem = actual.protect(f"{instance}:relay-kem:1", kem.private_key)
            wrapped_sign = actual.protect(f"{instance}:relay-sign", sign.private_key)
        except CredentialProtectionError:
            if wrapped_kem is not None:
                try:
                    actual.delete(wrapped_kem)
                except Exception:
                    pass
            actual = FilePermissionFallbackProtector()
            wrapped_kem = actual.protect(f"{instance}:relay-kem:1", kem.private_key)
            wrapped_sign = actual.protect(f"{instance}:relay-sign", sign.private_key)
        record = storage.store_identity(
            kem_private=wrapped_kem,
            kem_public=kem.public_key,
            sign_private=wrapped_sign,
            sign_public=sign.public_key,
            relay_instance_id=instance,
            relay_epoch=epoch,
        )
        storage.set_meta("credential_protection_mode", actual.mode)
        storage.credential_protector = actual
        return RelayIdentity.from_record(
            record,
            kem_private=kem.private_key,
            sign_private=sign.private_key,
            protection_mode=actual.mode,
        )
    kem_private, kem_mode, kem_protector = _reveal(record.kem_private, chosen)
    sign_private, sign_mode, sign_protector = _reveal(record.sign_private, chosen)
    mode = kem_mode if kem_mode == sign_mode else f"mixed:{kem_mode},{sign_mode}"
    storage.credential_protector = (
        kem_protector
        if kem_protector is not None and type(kem_protector) is type(sign_protector)
        else FilePermissionFallbackProtector()
    )
    storage.set_meta("credential_protection_mode", mode)
    return RelayIdentity.from_record(
        record,
        kem_private=kem_private,
        sign_private=sign_private,
        protection_mode=mode,
    )


def relay_private_kem_generations(
    storage: RelayStorage,
    *,
    protector: CredentialProtector | None = None,
) -> dict[int, bytes]:
    chosen = (
        protector or storage.credential_protector or platform_credential_protector()
    )
    result: dict[int, bytes] = {}
    for key in storage.relay_kem_keys():
        private, _mode, _actual = _reveal(key.private_key, chosen)
        result[key.generation] = private
    return result


def rotate_relay_kem(
    storage: RelayStorage,
    identity: RelayIdentity,
    *,
    previous_not_after_ms: int,
    protector: CredentialProtector | None = None,
) -> RelayIdentity:
    chosen = (
        protector or storage.credential_protector or platform_credential_protector()
    )
    pair = generate_x25519_key_pair()
    generation = identity.kem_generation + 1
    wrapped = chosen.protect(
        f"{identity.relay_instance_id}:relay-kem:{generation}", pair.private_key
    )
    storage.rotate_relay_kem(
        new_generation=generation,
        new_private_key=wrapped,
        new_public_key=pair.public_key,
        previous_not_after_ms=previous_not_after_ms,
    )
    return RelayIdentity(
        relay_instance_id=identity.relay_instance_id,
        relay_epoch=identity.relay_epoch,
        kem_generation=generation,
        kem_private=pair.private_key,
        kem_public=pair.public_key,
        sign_private=identity.sign_private,
        sign_public=identity.sign_public,
        protection_mode=chosen.mode,
    )


__all__ = [
    "RelayIdentity",
    "load_or_create_identity",
    "relay_private_kem_generations",
    "rotate_relay_kem",
]
