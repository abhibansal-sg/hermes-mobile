from __future__ import annotations

import base64
import hashlib
import json
import re
import struct
import time
from dataclasses import dataclass
from typing import Iterable, Mapping

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


class AuthorizationError(ValueError):
    pass


_ACTIVATION_KEY_ID = re.compile(r"^[A-Za-z0-9._~-]{1,64}$")


def b64url_decode(value: str, *, field: str, exact: int | None = None, maximum: int | None = None) -> bytes:
    if not value or "=" in value:
        raise ValueError(f"{field} must be unpadded base64url")
    try:
        raw = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4))
    except Exception as exc:
        raise ValueError(f"{field} must be base64url") from exc
    if base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=") != value:
        raise ValueError(f"{field} must use canonical base64url")
    if exact is not None and len(raw) != exact:
        raise ValueError(f"{field} must decode to {exact} bytes")
    if maximum is not None and len(raw) > maximum:
        raise ValueError(f"{field} exceeds {maximum} bytes")
    return raw


def b64url_encode(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


def _lp(value: bytes) -> bytes:
    return struct.pack(">I", len(value)) + value


def _parts(values: Iterable[str | bytes | int | None]) -> bytes:
    encoded = bytearray()
    for value in values:
        if value is None:
            raw = b""
        elif isinstance(value, bytes):
            raw = value
        else:
            raw = str(value).encode("utf-8")
        encoded.extend(_lp(raw))
    return bytes(encoded)


def envelope_signature_input(envelope: object) -> bytes:
    enc = b64url_decode(getattr(envelope, "enc"), field="enc", exact=32)
    ct = b64url_decode(getattr(envelope, "ct"), field="ct", maximum=256 * 1024)
    digest = hashlib.sha256(enc + ct).digest()
    # Integer widths are frozen by the Agent/Swift fixture: u16 protocol
    # version, u64 expiry, u32 recipient generation, all big-endian and each
    # still wrapped in LP. Collapse is an opaque UTF-8 token, not decoded.
    return b"HRH2" + _parts(
        (
            struct.pack(">H", getattr(envelope, "v")),
            getattr(envelope, "src"),
            getattr(envelope, "dst"),
            getattr(envelope, "mid"),
            str(getattr(envelope, "message_class")),
            struct.pack(">Q", getattr(envelope, "expires_at_ms")),
            struct.pack(">I", getattr(envelope, "recipient_key_generation")),
            getattr(envelope, "collapse"),
            digest,
        )
    )


def envelope_hash(envelope: object) -> bytes:
    signature = b64url_decode(getattr(envelope, "sig"), field="sig", exact=64)
    return hashlib.sha256(envelope_signature_input(envelope) + _lp(signature)).digest()


def verify_envelope_signature(envelope: object, public_key: bytes) -> None:
    signature = b64url_decode(getattr(envelope, "sig"), field="sig", exact=64)
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, envelope_signature_input(envelope))
    except (InvalidSignature, ValueError) as exc:
        raise AuthorizationError("invalid envelope authorization signature") from exc


def request_signature_input(
    *, method: str, path: str, route_id: str, timestamp_ms: int, nonce: bytes, body: bytes
) -> bytes:
    return b"HRH2REQ" + _parts(
        (method.upper(), path, route_id, timestamp_ms, nonce, hashlib.sha256(body).digest())
    )


def verify_request_signature(
    *,
    public_key: bytes,
    signature: bytes,
    method: str,
    path: str,
    route_id: str,
    timestamp_ms: int,
    nonce: bytes,
    body: bytes,
) -> None:
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(
            signature,
            request_signature_input(
                method=method,
                path=path,
                route_id=route_id,
                timestamp_ms=timestamp_ms,
                nonce=nonce,
                body=body,
            ),
        )
    except (InvalidSignature, ValueError) as exc:
        raise AuthorizationError("invalid route authorization signature") from exc


def grant_signature_input(grant: object) -> bytes:
    permissions = ",".join(sorted(getattr(grant, "permissions")))
    return b"HRH2GRANT" + _parts(
        (
            getattr(grant, "grant_id"),
            getattr(grant, "issuer_route"),
            getattr(grant, "source_route"),
            getattr(grant, "destination_route"),
            permissions,
            getattr(grant, "expires_at_ms"),
        )
    )


def verify_grant_signature(grant: object, public_key: bytes) -> None:
    signature = b64url_decode(getattr(grant, "issuer_signature"), field="issuer_signature", exact=64)
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, grant_signature_input(grant))
    except (InvalidSignature, ValueError) as exc:
        raise AuthorizationError("invalid grant issuer signature") from exc


@dataclass(frozen=True)
class ActivationClaims:
    route_id: str
    expires_at_ms: int
    token_id: str
    key_id: str | None = None


def verify_activation_token(
    token: str,
    public_key: bytes,
    *,
    expected_route: str,
    now_ms: int,
) -> ActivationClaims:
    return verify_activation_token_keyring(
        token,
        {"legacy": public_key},
        expected_route=expected_route,
        now_ms=now_ms,
    )


def verify_activation_token_keyring(
    token: str,
    public_keys: Mapping[str, bytes],
    *,
    expected_route: str,
    now_ms: int,
) -> ActivationClaims:
    if not 1 <= len(public_keys) <= 8:
        raise AuthorizationError("invalid activation verifier keyring")
    parts = token.split(".")
    if len(parts) != 2:
        raise AuthorizationError("malformed activation token")
    payload_raw = b64url_decode(parts[0], field="activation payload", maximum=2048)
    signature = b64url_decode(parts[1], field="activation signature", exact=64)
    try:
        payload = json.loads(payload_raw)
        if not isinstance(payload, dict):
            raise TypeError("activation payload must be an object")
        key_id_value = payload.get("kid")
        if key_id_value is not None and (
            not isinstance(key_id_value, str)
            or not _ACTIVATION_KEY_ID.fullmatch(key_id_value)
        ):
            raise ValueError("invalid activation key ID")
        if key_id_value is None:
            candidates = tuple(public_keys.values())
        else:
            selected = public_keys.get(key_id_value)
            if selected is None:
                raise ValueError("unknown activation key ID")
            candidates = (selected,)
        transcript = b"HRH2ACT" + _lp(payload_raw)
        for public_key in candidates:
            try:
                Ed25519PublicKey.from_public_bytes(public_key).verify(
                    signature,
                    transcript,
                )
                break
            except (InvalidSignature, ValueError):
                continue
        else:
            raise InvalidSignature
        claims = ActivationClaims(
            route_id=str(payload["route_id"]),
            expires_at_ms=int(payload["expires_at_ms"]),
            token_id=str(payload["token_id"]),
            key_id=key_id_value,
        )
    except (InvalidSignature, ValueError, KeyError, TypeError, json.JSONDecodeError) as exc:
        raise AuthorizationError("invalid activation token") from exc
    if claims.route_id != expected_route:
        raise AuthorizationError("activation token route mismatch")
    if claims.expires_at_ms <= now_ms:
        raise AuthorizationError("activation token expired")
    if claims.expires_at_ms > now_ms + 15 * 60 * 1000:
        raise AuthorizationError("activation token lifetime is too long")
    if not claims.token_id or len(claims.token_id) > 128:
        raise AuthorizationError("invalid activation token identifier")
    return claims


def now_milliseconds() -> int:
    return time.time_ns() // 1_000_000
