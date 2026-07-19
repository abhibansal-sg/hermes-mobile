from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import struct
import uuid
from dataclasses import dataclass

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM


def b64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def b64url_decode(
    value: str, *, field: str, exact: int | None = None, maximum: int | None = None
) -> bytes:
    if not value or "=" in value:
        raise ValueError(f"{field} must be unpadded base64url")
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except Exception as exc:
        raise ValueError(f"{field} must be base64url") from exc
    if b64url_encode(raw) != value:
        raise ValueError(f"{field} must use canonical base64url")
    if exact is not None and len(raw) != exact:
        raise ValueError(f"{field} must decode to {exact} bytes")
    if maximum is not None and len(raw) > maximum:
        raise ValueError(f"{field} exceeds {maximum} bytes")
    return raw


def secret_hash(secret: str, pepper: bytes) -> bytes:
    return hmac.new(pepper, secret.encode("utf-8"), hashlib.sha256).digest()


def opaque_hash(value: str, pepper: bytes) -> bytes:
    return hmac.new(pepper, value.encode("utf-8"), hashlib.sha256).digest()


def app_attest_key_hash(key_id: str, pepper: bytes) -> bytes:
    """Hash the decoded Apple key identity, never its textual base64 spelling."""

    raw = base64.b64decode(key_id, validate=True)
    if len(raw) != 32 or base64.b64encode(raw).decode("ascii") != key_id:
        raise ValueError("App Attest key identifier is not canonical")
    return hmac.new(
        pepper,
        b"HPG2APPATTESTKEY\x00" + raw,
        hashlib.sha256,
    ).digest()


def delivery_identifiers(
    *, binding_id: str, notification_id: str, pepper: bytes
) -> tuple[str, str]:
    material = binding_id.encode("utf-8") + b"\x00" + notification_id.encode("utf-8")
    apns_digest = hmac.new(
        pepper, b"HPG2APNSID\x00" + material, hashlib.sha256
    ).digest()
    collapse_digest = hmac.new(
        pepper, b"HPG2COLLAPSE\x00" + material, hashlib.sha256
    ).digest()
    return str(uuid.UUID(bytes=apns_digest[:16])), "h2_" + b64url_encode(
        collapse_digest
    )


def _lp(value: bytes) -> bytes:
    return struct.pack(">I", len(value)) + value


def registration_transcript(
    *,
    challenge: str,
    apns_token: str,
    bundle_id: str,
    environment: str,
    preview_kem_pub: str,
    installation_nonce: str,
    operation: str,
    hub_route_id: str | None = None,
) -> bytes:
    fields = (
        challenge.encode(),
        hashlib.sha256(apns_token.encode()).digest(),
        bundle_id.encode(),
        environment.encode(),
        preview_kem_pub.encode(),
        installation_nonce.encode(),
        operation.encode(),
        (hub_route_id or "").encode(),
    )
    return b"HPG2ATTEST" + b"".join(_lp(value) for value in fields)


def hub_activation_transcript(
    *,
    challenge: str,
    hub_route_id: str,
    bundle_id: str,
    environment: str,
    installation_nonce: str,
) -> bytes:
    fields = (
        challenge.encode(),
        bundle_id.encode(),
        environment.encode(),
        installation_nonce.encode(),
        b"hub-activate",
        hub_route_id.encode(),
    )
    return b"HPG2ACTIVATE" + b"".join(_lp(value) for value in fields)


@dataclass(frozen=True)
class EncryptedToken:
    ciphertext: bytes
    nonce: bytes
    wrapped_key: bytes
    wrap_nonce: bytes
    key_version: int


class TokenVault:
    def __init__(self, master_keys: dict[int, bytes], *, current_version: int) -> None:
        if not master_keys or len(master_keys) > 16:
            raise ValueError("token keyring must contain between 1 and 16 keys")
        if current_version not in master_keys:
            raise ValueError("current token key version is unavailable")
        if any(
            not isinstance(version, int)
            or isinstance(version, bool)
            or version <= 0
            or version > (1 << 32) - 1
            for version in master_keys
        ):
            raise ValueError("token key versions must be positive 32-bit integers")
        if any(
            not isinstance(key, bytes) or len(key) != 32 for key in master_keys.values()
        ):
            raise ValueError("token master keys must be 32 bytes")
        if len(set(master_keys.values())) != len(master_keys):
            raise ValueError("token master keys must be unique")
        self._keys = dict(master_keys)
        self.current_version = current_version

    @property
    def available_versions(self) -> frozenset[int]:
        return frozenset(self._keys)

    @staticmethod
    def _token_aad(endpoint_id: str, bundle_id: str, environment: str) -> bytes:
        return (
            b"HPG2TOKEN"
            + _lp(endpoint_id.encode())
            + _lp(bundle_id.encode())
            + _lp(environment.encode())
        )

    @staticmethod
    def _wrap_aad(endpoint_id: str, version: int) -> bytes:
        return b"HPG2DEK" + _lp(endpoint_id.encode()) + struct.pack(">I", version)

    def encrypt(
        self, token: str, *, endpoint_id: str, bundle_id: str, environment: str
    ) -> EncryptedToken:
        data_key = secrets.token_bytes(32)
        nonce = secrets.token_bytes(12)
        wrap_nonce = secrets.token_bytes(12)
        ciphertext = AESGCM(data_key).encrypt(
            nonce,
            token.encode("ascii"),
            self._token_aad(endpoint_id, bundle_id, environment),
        )
        wrapped = AESGCM(self._keys[self.current_version]).encrypt(
            wrap_nonce,
            data_key,
            self._wrap_aad(endpoint_id, self.current_version),
        )
        return EncryptedToken(
            ciphertext, nonce, wrapped, wrap_nonce, self.current_version
        )

    def decrypt(
        self,
        encrypted: EncryptedToken,
        *,
        endpoint_id: str,
        bundle_id: str,
        environment: str,
    ) -> str:
        master = self._keys.get(encrypted.key_version)
        if master is None:
            raise ValueError("token key version is unavailable")
        data_key = AESGCM(master).decrypt(
            encrypted.wrap_nonce,
            encrypted.wrapped_key,
            self._wrap_aad(endpoint_id, encrypted.key_version),
        )
        plaintext = AESGCM(data_key).decrypt(
            encrypted.nonce,
            encrypted.ciphertext,
            self._token_aad(endpoint_id, bundle_id, environment),
        )
        return plaintext.decode("ascii")

    def rewrap(self, encrypted: EncryptedToken, *, endpoint_id: str) -> EncryptedToken:
        """Re-encrypt only an envelope data key under the current master key.

        The token/capability ciphertext and its nonce remain untouched. A
        caller can therefore rotate large tables atomically without exposing
        their plaintexts or changing the payload AAD contract.
        """

        master = self._keys.get(encrypted.key_version)
        if master is None:
            raise ValueError("token key version is unavailable")
        if encrypted.key_version == self.current_version:
            return encrypted
        data_key = AESGCM(master).decrypt(
            encrypted.wrap_nonce,
            encrypted.wrapped_key,
            self._wrap_aad(endpoint_id, encrypted.key_version),
        )
        wrap_nonce = secrets.token_bytes(12)
        wrapped_key = AESGCM(self._keys[self.current_version]).encrypt(
            wrap_nonce,
            data_key,
            self._wrap_aad(endpoint_id, self.current_version),
        )
        return EncryptedToken(
            ciphertext=encrypted.ciphertext,
            nonce=encrypted.nonce,
            wrapped_key=wrapped_key,
            wrap_nonce=wrap_nonce,
            key_version=self.current_version,
        )


def mint_hub_activation_token(
    private_key: bytes,
    *,
    route_id: str,
    expires_at_ms: int,
    token_id: str,
    key_id: str | None = None,
) -> str:
    claims: dict[str, str | int] = {
        "expires_at_ms": expires_at_ms,
        "route_id": route_id,
        "token_id": token_id,
    }
    if key_id is not None:
        claims["kid"] = key_id
    payload = json.dumps(
        claims,
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    signature = Ed25519PrivateKey.from_private_bytes(private_key).sign(
        b"HRH2ACT" + _lp(payload)
    )
    return b64url_encode(payload) + "." + b64url_encode(signature)
