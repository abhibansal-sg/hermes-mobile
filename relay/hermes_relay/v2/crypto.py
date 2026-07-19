"""HRP/2 authenticated one-shot HPKE and Ed25519 envelope primitives.

Suite: DHKEM(X25519, HKDF-SHA256), HKDF-SHA256, ChaCha20-Poly1305.
Every call creates a fresh HPKE context.  Production callers leave
``ephemeral_ikm`` unset; that argument exists solely for reproducible
cross-language fixtures.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric import ed25519, x25519
from pyhpke import AEADId, CipherSuite, KDFId, KEMId, PyHPKEError

from .errors import (
    Expired,
    InvalidArgument,
    KeyGenerationUnavailable,
    ReplayDetected,
    Unauthenticated,
)
from .protocol import (
    HPKEDirection,
    HPKEPurpose,
    NotificationPreview,
    NotificationSendDescriptor,
    OuterEnvelope,
    OuterHeader,
    ReceiveContext,
    SecureMessage,
    hpke_info,
)


@dataclass(frozen=True, slots=True)
class RawKeyPair:
    """A 32-byte raw private/public key pair."""

    private_key: bytes
    public_key: bytes


def generate_x25519_key_pair() -> RawKeyPair:
    private = x25519.X25519PrivateKey.generate()
    return RawKeyPair(
        private.private_bytes_raw(), private.public_key().public_bytes_raw()
    )


def generate_ed25519_key_pair() -> RawKeyPair:
    private = ed25519.Ed25519PrivateKey.generate()
    return RawKeyPair(
        private.private_bytes_raw(), private.public_key().public_bytes_raw()
    )


def x25519_public_from_private(private_key: bytes) -> bytes:
    return _x25519_private(private_key).public_key().public_bytes_raw()


def ed25519_public_from_private(private_key: bytes) -> bytes:
    return _ed25519_private(private_key).public_key().public_bytes_raw()


def seal_base_message(
    plaintext: bytes,
    *,
    recipient_public_key: bytes,
    info: bytes,
    aad: bytes,
    ephemeral_ikm: bytes | None = None,
) -> tuple[bytes, bytes]:
    """HPKE Base-mode seal for the one-time, secret-MACed ``PairInit``.

    Base mode is intentionally limited to pairing.  Established traffic must
    use :func:`seal_authenticated_envelope`.
    """

    if (
        not isinstance(plaintext, bytes)
        or not isinstance(info, bytes)
        or not isinstance(aad, bytes)
    ):
        raise InvalidArgument(details={"field": "pairing_plaintext"})
    suite = _suite()
    ephemeral = None
    if ephemeral_ikm is not None:
        if not isinstance(ephemeral_ikm, bytes) or len(ephemeral_ikm) < 32:
            raise InvalidArgument(details={"field": "ephemeral_ikm"})
        ephemeral = suite.kem.derive_key_pair(ephemeral_ikm)
    try:
        enc, sender = suite.create_sender_context(
            _hpke_public(suite, recipient_public_key), info=info, eks=ephemeral
        )
        return enc, sender.seal(plaintext, aad)
    except (PyHPKEError, ValueError) as exc:
        raise Unauthenticated() from exc


def open_base_message(
    enc: bytes,
    ciphertext: bytes,
    *,
    recipient_private_key: bytes,
    info: bytes,
    aad: bytes,
) -> bytes:
    """Open the pairing-only HPKE Base-mode ciphertext."""

    suite = _suite()
    try:
        recipient = suite.create_recipient_context(
            enc,
            _hpke_private(suite, recipient_private_key),
            info=info,
        )
        return recipient.open(ciphertext, aad)
    except (PyHPKEError, ValueError) as exc:
        raise Unauthenticated() from exc


def seal_authenticated_message(
    plaintext: bytes,
    *,
    recipient_public_key: bytes,
    sender_private_key: bytes,
    info: bytes,
    aad: bytes,
    ephemeral_ikm: bytes | None = None,
) -> tuple[bytes, bytes]:
    """Seal a raw Auth-mode HPKE message outside the established envelope.

    This narrow primitive exists for the encrypted ``PairAccept`` mailbox,
    whose Hub contract transports only ``enc``/``ct``.  Established route
    traffic must continue to use :func:`seal_authenticated_envelope`.
    """

    if (
        not isinstance(plaintext, bytes)
        or not isinstance(info, bytes)
        or not isinstance(aad, bytes)
    ):
        raise InvalidArgument(details={"field": "plaintext"})
    suite = _suite()
    ephemeral = None
    if ephemeral_ikm is not None:
        if not isinstance(ephemeral_ikm, bytes) or len(ephemeral_ikm) < 32:
            raise InvalidArgument(details={"field": "ephemeral_ikm"})
        ephemeral = suite.kem.derive_key_pair(ephemeral_ikm)
    try:
        enc, sender = suite.create_sender_context(
            _hpke_public(suite, recipient_public_key),
            info=info,
            sks=_hpke_private(suite, sender_private_key),
            eks=ephemeral,
        )
        return enc, sender.seal(plaintext, aad)
    except (PyHPKEError, ValueError) as exc:
        raise Unauthenticated() from exc


def open_authenticated_message(
    enc: bytes,
    ciphertext: bytes,
    *,
    recipient_private_key: bytes,
    sender_public_key: bytes,
    info: bytes,
    aad: bytes,
) -> bytes:
    """Open the pairing-only raw Auth-mode HPKE response."""

    suite = _suite()
    try:
        recipient = suite.create_recipient_context(
            enc,
            _hpke_private(suite, recipient_private_key),
            info=info,
            pks=_hpke_public(suite, sender_public_key),
        )
        return recipient.open(ciphertext, aad)
    except (PyHPKEError, ValueError) as exc:
        raise Unauthenticated() from exc


def sign_outer_envelope(
    header: OuterHeader,
    enc: bytes,
    ct: bytes,
    signing_private_key: bytes,
) -> bytes:
    return _ed25519_private(signing_private_key).sign(header.signature_payload(enc, ct))


def verify_outer_envelope_signature(
    envelope: OuterEnvelope,
    signing_public_key: bytes,
) -> None:
    try:
        _ed25519_public(signing_public_key).verify(
            envelope.sig,
            envelope.header.signature_payload(envelope.enc, envelope.ct),
        )
    except (InvalidSignature, ValueError) as exc:
        raise Unauthenticated() from exc


def seal_authenticated_envelope(
    header: OuterHeader,
    message: SecureMessage,
    *,
    recipient_public_key: bytes,
    sender_private_key: bytes,
    signing_private_key: bytes,
    purpose: HPKEPurpose,
    direction: HPKEDirection,
    ephemeral_ikm: bytes | None = None,
) -> OuterEnvelope:
    """Encrypt and authorize one immutable HRP/2 outer envelope."""

    if message.mid != header.mid:
        raise InvalidArgument(
            "Outer and inner message IDs differ", details={"field": "mid"}
        )
    if message.expires_at_ms != header.expires_at_ms:
        raise InvalidArgument(
            "Outer and inner expiries differ",
            details={"field": "expires_at_ms"},
        )

    suite = _suite()
    pkr = _hpke_public(suite, recipient_public_key)
    sks = _hpke_private(suite, sender_private_key)
    ephemeral = None
    if ephemeral_ikm is not None:
        if not isinstance(ephemeral_ikm, bytes) or len(ephemeral_ikm) < 32:
            raise InvalidArgument(details={"field": "ephemeral_ikm"})
        ephemeral = suite.kem.derive_key_pair(ephemeral_ikm)
    try:
        enc, sender = suite.create_sender_context(
            pkr,
            info=hpke_info(purpose, direction),
            sks=sks,
            eks=ephemeral,
        )
        ct = sender.seal(message.to_bytes(), header.aad())
    except (PyHPKEError, ValueError) as exc:
        raise Unauthenticated() from exc
    sig = sign_outer_envelope(header, enc, ct, signing_private_key)
    return OuterEnvelope(
        v=header.v,
        src=header.src,
        dst=header.dst,
        mid=header.mid,
        message_class=header.message_class,
        expires_at_ms=header.expires_at_ms,
        recipient_key_generation=header.recipient_key_generation,
        collapse=header.collapse,
        enc=enc,
        ct=ct,
        sig=sig,
    )


def open_authenticated_envelope(
    envelope: OuterEnvelope,
    *,
    recipient_private_keys: Mapping[int, bytes],
    sender_public_keys: Mapping[int, bytes],
    signing_public_key: bytes,
    purpose: HPKEPurpose,
    direction: HPKEDirection,
    receive: ReceiveContext,
) -> SecureMessage:
    """Authenticate, decrypt, and validate an envelope without mutating replay state.

    ``recipient_private_keys`` is the current/rollover generation map.  The
    caller adds ``mid`` to its durable replay ledger in the same transaction as
    application state; this function intentionally performs no commit.
    """

    verify_outer_envelope_signature(envelope, signing_public_key)
    recipient_private_key = recipient_private_keys.get(
        envelope.recipient_key_generation
    )
    if recipient_private_key is None:
        raise KeyGenerationUnavailable(
            details={"recipient_key_generation": envelope.recipient_key_generation}
        )

    if not sender_public_keys:
        raise KeyGenerationUnavailable(details={"sender_key_generation": None})

    suite = _suite()
    message: SecureMessage | None = None
    selected_sender_generation: int | None = None
    last_error: BaseException | None = None
    # The sender generation is inside the authenticated plaintext, so try only
    # the caller's bounded current/previous key set.  Revoked/retired keys must
    # not be included by the lookup layer.  Auth mode means a wrong sender key
    # fails before any plaintext is returned.
    for generation, sender_public_key in sorted(sender_public_keys.items()):
        try:
            recipient = suite.create_recipient_context(
                envelope.enc,
                _hpke_private(suite, recipient_private_key),
                info=hpke_info(purpose, direction),
                pks=_hpke_public(suite, sender_public_key),
            )
            plaintext = recipient.open(envelope.ct, envelope.header.aad())
            message = SecureMessage.from_bytes(plaintext)
            selected_sender_generation = generation
            break
        except (PyHPKEError, ValueError, InvalidArgument) as exc:
            last_error = exc
    if message is None or selected_sender_generation is None:
        raise Unauthenticated() from last_error
    if message.sender_key_generation != selected_sender_generation:
        raise Unauthenticated("Declared sender key generation mismatch")
    if envelope.dst != receive.expected_destination:
        raise Unauthenticated("Envelope destination mismatch")
    if receive.expected_source is not None and envelope.src != receive.expected_source:
        raise Unauthenticated("Envelope source mismatch")
    if envelope.expires_at_ms <= receive.now_ms:
        raise Expired(details={"mid": envelope.mid})
    if message.mid != envelope.mid:
        raise Unauthenticated("Outer and inner message IDs differ")
    if message.expires_at_ms != envelope.expires_at_ms:
        raise Unauthenticated("Outer and inner expiries differ")
    if envelope.mid in receive.seen_message_ids:
        raise ReplayDetected(details={"mid": envelope.mid})
    return message


def encrypt_notification_preview(
    preview: NotificationPreview,
    *,
    recipient_public_key: bytes,
    sender_private_key: bytes,
    collapse_id: str | None = None,
    sound: bool = True,
    ephemeral_ikm: bytes | None = None,
) -> NotificationSendDescriptor:
    """Create a content-blind Push Gateway descriptor with Auth-mode HPKE."""

    placeholder = NotificationSendDescriptor(
        notification_id=preview.notification_id,
        notification_class=preview.notification_class,
        preview_enc=b"\0" * 32,
        preview_ct=b"\0" * 16,
        expires_at_ms=preview.expires_at_ms,
        collapse_id=collapse_id,
        sound=sound,
    )
    suite = _suite()
    ephemeral = None
    if ephemeral_ikm is not None:
        if not isinstance(ephemeral_ikm, bytes) or len(ephemeral_ikm) < 32:
            raise InvalidArgument(details={"field": "ephemeral_ikm"})
        ephemeral = suite.kem.derive_key_pair(ephemeral_ikm)
    try:
        enc, sender = suite.create_sender_context(
            _hpke_public(suite, recipient_public_key),
            info=hpke_info(HPKEPurpose.NOTIFICATION, HPKEDirection.AGENT_TO_DEVICE),
            sks=_hpke_private(suite, sender_private_key),
            eks=ephemeral,
        )
        ct = sender.seal(preview.to_bytes(), placeholder.aad())
    except (PyHPKEError, ValueError) as exc:
        raise Unauthenticated() from exc
    return NotificationSendDescriptor(
        notification_id=preview.notification_id,
        notification_class=preview.notification_class,
        preview_enc=enc,
        preview_ct=ct,
        expires_at_ms=preview.expires_at_ms,
        collapse_id=collapse_id,
        sound=sound,
    )


def decrypt_notification_preview(
    descriptor: NotificationSendDescriptor,
    *,
    recipient_private_key: bytes,
    sender_public_key: bytes,
    now_ms: int,
) -> NotificationPreview:
    """Authenticate and decrypt a Push Gateway descriptor for the NSE/app."""

    if descriptor.expires_at_ms <= now_ms:
        raise Expired(details={"notification_id": descriptor.notification_id})
    suite = _suite()
    try:
        recipient = suite.create_recipient_context(
            descriptor.preview_enc,
            _hpke_private(suite, recipient_private_key),
            info=hpke_info(HPKEPurpose.NOTIFICATION, HPKEDirection.AGENT_TO_DEVICE),
            pks=_hpke_public(suite, sender_public_key),
        )
        plaintext = recipient.open(descriptor.preview_ct, descriptor.aad())
    except (PyHPKEError, ValueError) as exc:
        raise Unauthenticated() from exc
    preview = NotificationPreview.from_bytes(plaintext)
    if preview.notification_id != descriptor.notification_id:
        raise Unauthenticated("Outer and inner notification IDs differ")
    if preview.notification_class != descriptor.notification_class:
        raise Unauthenticated("Outer and inner notification classes differ")
    if preview.expires_at_ms != descriptor.expires_at_ms:
        raise Unauthenticated("Outer and inner notification expiries differ")
    return preview


def _suite() -> CipherSuite:
    return CipherSuite.new(
        KEMId.DHKEM_X25519_HKDF_SHA256,
        KDFId.HKDF_SHA256,
        AEADId.CHACHA20_POLY1305,
    )


def _hpke_private(suite: CipherSuite, value: bytes):
    _require_key_bytes(value, "private_key")
    try:
        return suite.kem.deserialize_private_key(value)
    except ValueError as exc:
        raise InvalidArgument(details={"field": "private_key"}) from exc


def _hpke_public(suite: CipherSuite, value: bytes):
    _require_key_bytes(value, "public_key")
    try:
        return suite.kem.deserialize_public_key(value)
    except ValueError as exc:
        raise InvalidArgument(details={"field": "public_key"}) from exc


def _x25519_private(value: bytes) -> x25519.X25519PrivateKey:
    _require_key_bytes(value, "private_key")
    return x25519.X25519PrivateKey.from_private_bytes(value)


def _ed25519_private(value: bytes) -> ed25519.Ed25519PrivateKey:
    _require_key_bytes(value, "signing_private_key")
    return ed25519.Ed25519PrivateKey.from_private_bytes(value)


def _ed25519_public(value: bytes) -> ed25519.Ed25519PublicKey:
    _require_key_bytes(value, "signing_public_key")
    return ed25519.Ed25519PublicKey.from_public_bytes(value)


def _require_key_bytes(value: bytes, field: str) -> None:
    if not isinstance(value, bytes) or len(value) != 32:
        raise InvalidArgument(details={"field": field})


__all__ = [
    "RawKeyPair",
    "decrypt_notification_preview",
    "ed25519_public_from_private",
    "encrypt_notification_preview",
    "generate_ed25519_key_pair",
    "generate_x25519_key_pair",
    "open_authenticated_envelope",
    "open_authenticated_message",
    "open_base_message",
    "seal_authenticated_envelope",
    "seal_authenticated_message",
    "seal_base_message",
    "sign_outer_envelope",
    "verify_outer_envelope_signature",
    "x25519_public_from_private",
]
