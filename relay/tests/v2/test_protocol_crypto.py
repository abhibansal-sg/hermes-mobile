from __future__ import annotations

import hashlib
import json
from dataclasses import replace
from pathlib import Path

import pytest

from hermes_relay.v2.crypto import (
    decrypt_notification_preview,
    encrypt_notification_preview,
    open_authenticated_envelope,
    open_authenticated_message,
    seal_authenticated_envelope,
    seal_authenticated_message,
    x25519_public_from_private,
)
from hermes_relay.v2.errors import (
    InvalidArgument,
    KeyGenerationUnavailable,
    ReplayDetected,
    Unauthenticated,
)
from hermes_relay.v2.protocol import (
    HPKEDirection,
    HPKEPurpose,
    MAX_WIRE_INTEGER,
    NotificationPreview,
    NotificationSendDescriptor,
    OuterEnvelope,
    OuterHeader,
    ReceiveContext,
    SecureMessage,
    SecureMessageKind,
    b64url_encode,
    canonical_json,
    decode_strict_json,
)

ROOT = Path(__file__).resolve().parents[3]
AUTH_FIXTURE = json.loads(
    (ROOT / "protocol/hrp2/fixtures/auth-envelope.json").read_text(encoding="utf-8")
)
NOTIFICATION_FIXTURE = json.loads(
    (ROOT / "protocol/hrp2/fixtures/notification-preview.json").read_text(
        encoding="utf-8"
    )
)
FROZEN_ENVELOPE = AUTH_FIXTURE["outer_envelope"]
RECIPIENT_SK = bytes.fromhex(AUTH_FIXTURE["recipient_private_key_hex"])
SENDER_SK = bytes.fromhex(AUTH_FIXTURE["sender_private_key_hex"])
SIGNING_SK = bytes.fromhex(AUTH_FIXTURE["signing_private_key_hex"])
MID = FROZEN_ENVELOPE["mid"]


def _fixture_envelope() -> OuterEnvelope:
    header = OuterHeader(
        src="rte_agent_fixture",
        dst="rte_device_fixture",
        mid=MID,
        message_class="state",
        expires_at_ms=1784450000000,
        recipient_key_generation=3,
        collapse="opaque_collapse",
    )
    message = SecureMessage(
        mid=MID,
        kind="checkpoint",
        sender_key_generation=4,
        created_at_ms=1784449900000,
        expires_at_ms=1784450000000,
        body={
            "stream_id": "str_fixture",
            "through_seq": 820,
            "session_id": "sess_fixture",
            "snapshot_revision": 31,
            "replace": True,
            "items": [],
            "tombstones": [],
        },
    )
    return seal_authenticated_envelope(
        header,
        message,
        recipient_public_key=x25519_public_from_private(RECIPIENT_SK),
        sender_private_key=SENDER_SK,
        signing_private_key=SIGNING_SK,
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        ephemeral_ikm=bytes.fromhex(AUTH_FIXTURE["ephemeral_ikm_hex"]),
    )


def _open(envelope: OuterEnvelope, *, seen=frozenset(), keys=None) -> SecureMessage:
    from hermes_relay.v2.crypto import ed25519_public_from_private

    return open_authenticated_envelope(
        envelope,
        recipient_private_keys={3: RECIPIENT_SK} if keys is None else keys,
        sender_public_keys={4: x25519_public_from_private(SENDER_SK)},
        signing_public_key=ed25519_public_from_private(SIGNING_SK),
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination="rte_device_fixture",
            expected_source="rte_agent_fixture",
            now_ms=1784449950000,
            seen_message_ids=seen,
        ),
    )


def test_frozen_authenticated_envelope_fixture_and_round_trip() -> None:
    envelope = _fixture_envelope()
    assert envelope.to_dict() == FROZEN_ENVELOPE
    assert envelope.header.aad().hex() == AUTH_FIXTURE["aad_hex"]
    assert (
        hashlib.sha256(envelope.to_json()).hexdigest()
        == AUTH_FIXTURE["canonical_envelope_sha256_hex"]
    )
    assert envelope.to_json() == canonical_json(FROZEN_ENVELOPE)
    assert OuterEnvelope.from_json(envelope.to_json()) == envelope
    assert _open(envelope).body == AUTH_FIXTURE["inner_message"]["body"]


def test_rfc9180_a_2_3_auth_mode_known_answer_vector() -> None:
    """Official RFC 9180 A.2.3, sequence number zero.

    Source: https://www.rfc-editor.org/rfc/rfc9180.html#appendix-A.2.3
    """

    h = bytes.fromhex
    plaintext = h("4265617574792069732074727574682c20747275746820626561757479")
    info = h("4f6465206f6e2061204772656369616e2055726e")
    aad = h("436f756e742d30")
    recipient_private = h(
        "3ca22a6d1cda1bb9480949ec5329d3bf0b080ca4c45879c95eddb55c70b80b82"
    )
    recipient_public = h(
        "1a478716d63cb2e16786ee93004486dc151e988b34b475043d3e0175bdb01c44"
    )
    sender_private = h(
        "2def0cb58ffcf83d1062dd085c8aceca7f4c0c3fd05912d847b61f3e54121f05"
    )
    sender_public = h(
        "f0f4f9e96c54aeed3f323de8534fffd7e0577e4ce269896716bcb95643c8712b"
    )
    enc, ciphertext = seal_authenticated_message(
        plaintext,
        recipient_public_key=recipient_public,
        sender_private_key=sender_private,
        info=info,
        aad=aad,
        ephemeral_ikm=h(
            "938d3daa5a8904540bc24f48ae90eed3f4f7f11839560597b55e7c9598c996c0"
        ),
    )
    assert (
        enc.hex() == "f7674cc8cd7baa5872d1f33dbaffe3314239f6197ddf5ded1746760bfc847e0e"
    )
    assert ciphertext.hex() == (
        "ab1a13c9d4f01a87ec3440dbd756e2677bd2ecf9df0ce7ed73869b98e00c09be"
        "111cb9fdf077347aeb88e61bdf"
    )
    assert (
        open_authenticated_message(
            enc,
            ciphertext,
            recipient_private_key=recipient_private,
            sender_public_key=sender_public,
            info=info,
            aad=aad,
        )
        == plaintext
    )


def test_tamper_replay_and_rotation_overlap_are_typed() -> None:
    envelope = _fixture_envelope()
    with pytest.raises(Unauthenticated):
        _open(replace(envelope, dst="rte_attacker"))
    with pytest.raises(Unauthenticated):
        _open(replace(envelope, ct=envelope.ct[:-1] + bytes([envelope.ct[-1] ^ 1])))
    with pytest.raises(ReplayDetected):
        _open(envelope, seen={MID})
    with pytest.raises(KeyGenerationUnavailable):
        _open(envelope, keys={4: bytes(reversed(RECIPIENT_SK))})
    assert (
        _open(envelope, keys={2: bytes(reversed(RECIPIENT_SK)), 3: RECIPIENT_SK}).mid
        == MID
    )


def test_sender_generation_is_bound_to_the_authenticated_key() -> None:
    envelope = _fixture_envelope()
    sender_public = x25519_public_from_private(SENDER_SK)
    from hermes_relay.v2.crypto import ed25519_public_from_private

    common = dict(
        envelope=envelope,
        recipient_private_keys={3: RECIPIENT_SK},
        signing_public_key=ed25519_public_from_private(SIGNING_SK),
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination="rte_device_fixture",
            expected_source="rte_agent_fixture",
            now_ms=1784449950000,
        ),
    )
    with pytest.raises(Unauthenticated, match="generation mismatch"):
        open_authenticated_envelope(sender_public_keys={3: sender_public}, **common)
    # Current plus previous is accepted only when the declared generation is
    # the exact key that authenticated the ciphertext.
    previous = bytes.fromhex("20" * 32)
    assert (
        open_authenticated_envelope(
            sender_public_keys={
                3: x25519_public_from_private(previous),
                4: sender_public,
            },
            **common,
        ).sender_key_generation
        == 4
    )
    # Once generation 4 is retired/revoked and omitted by lookup, it fails.
    with pytest.raises(Unauthenticated):
        open_authenticated_envelope(
            sender_public_keys={5: x25519_public_from_private(previous)}, **common
        )


@pytest.mark.parametrize(
    "value",
    [1.0, -0.0, float("nan"), float("inf")],
)
def test_canonical_json_rejects_all_floating_point_values(value) -> None:
    with pytest.raises(InvalidArgument):
        canonical_json({"number": value})


@pytest.mark.parametrize("wire", [b"1.0", b"-0", b"-0.0", b"1e3", b"NaN"])
def test_strict_json_rejects_non_integer_number_spellings(wire: bytes) -> None:
    with pytest.raises(InvalidArgument):
        decode_strict_json(wire)


def test_exact_json_integer_boundaries_and_sequence_zero_contract() -> None:
    assert canonical_json({"minimum": -MAX_WIRE_INTEGER, "maximum": MAX_WIRE_INTEGER})
    for value in (-MAX_WIRE_INTEGER - 1, MAX_WIRE_INTEGER + 1):
        with pytest.raises(InvalidArgument):
            canonical_json({"outside": value})

    common = {
        "mid": MID,
        "sender_key_generation": 1,
        "created_at_ms": 0,
        "expires_at_ms": MAX_WIRE_INTEGER,
    }
    frame = {"sid": "session", "turn": None, "kind": "turn.started", "body": {}}
    assert (
        SecureMessage(
            **common,
            kind=SecureMessageKind.FRAME_BATCH,
            body={
                "stream_id": "stream",
                "first_seq": MAX_WIRE_INTEGER,
                "frames": [frame],
            },
        ).body["first_seq"]
        == MAX_WIRE_INTEGER
    )
    with pytest.raises(InvalidArgument) as zero_batch:
        SecureMessage(
            **common,
            kind=SecureMessageKind.FRAME_BATCH,
            body={"stream_id": "stream", "first_seq": 0, "frames": [frame]},
        )
    assert zero_batch.value.details == {"field": "body.first_seq"}
    with pytest.raises(InvalidArgument):
        SecureMessage(
            **common,
            kind=SecureMessageKind.FRAME_BATCH,
            body={
                "stream_id": "stream",
                "first_seq": MAX_WIRE_INTEGER + 1,
                "frames": [frame],
            },
        )

    for kind, body in (
        (
            SecureMessageKind.CHECKPOINT,
            {
                "stream_id": "stream",
                "through_seq": 0,
                "session_id": "session",
                "snapshot_revision": 1,
                "replace": True,
                "items": [],
                "tombstones": [],
            },
        ),
        (SecureMessageKind.STREAM_ACK, {"stream_id": "stream", "through_seq": 0}),
    ):
        assert SecureMessage(**common, kind=kind, body=body).body["through_seq"] == 0


def test_encrypted_notification_descriptor_exposes_no_hermes_content() -> None:
    preview = NotificationPreview.from_dict(NOTIFICATION_FIXTURE["preview"])
    descriptor = encrypt_notification_preview(
        preview,
        recipient_public_key=x25519_public_from_private(RECIPIENT_SK),
        sender_private_key=SENDER_SK,
        collapse_id=NOTIFICATION_FIXTURE["descriptor"]["collapse_id"],
        ephemeral_ikm=bytes.fromhex(NOTIFICATION_FIXTURE["ephemeral_ikm_hex"]),
    )
    outer = descriptor.to_dict()
    assert outer == NOTIFICATION_FIXTURE["descriptor"]
    assert descriptor.aad().hex() == NOTIFICATION_FIXTURE["aad_hex"]
    assert (
        hashlib.sha256(canonical_json(outer)).hexdigest()
        == NOTIFICATION_FIXTURE["canonical_descriptor_sha256_hex"]
    )
    assert not ({"title", "body", "session_id", "request_id"} & outer.keys())
    assert "sess_fixture" not in str(outer)
    assert (
        decrypt_notification_preview(
            NotificationSendDescriptor.from_dict(NOTIFICATION_FIXTURE["descriptor"]),
            recipient_private_key=RECIPIENT_SK,
            sender_public_key=x25519_public_from_private(SENDER_SK),
            now_ms=1784449950000,
        )
        == preview
    )
    with pytest.raises(Unauthenticated):
        decrypt_notification_preview(
            replace(descriptor, sound=False),
            recipient_private_key=RECIPIENT_SK,
            sender_public_key=x25519_public_from_private(SENDER_SK),
            now_ms=1784449950000,
        )


def test_strict_models_reject_unknown_fields_and_noncanonical_base64() -> None:
    bad = dict(FROZEN_ENVELOPE, plaintext="not allowed")
    with pytest.raises(InvalidArgument):
        OuterEnvelope.from_dict(bad)
    bad = dict(FROZEN_ENVELOPE, collapse="x" * 65)
    with pytest.raises(InvalidArgument):
        OuterEnvelope.from_dict(bad)
    bad = dict(FROZEN_ENVELOPE, enc=FROZEN_ENVELOPE["enc"] + "=")
    with pytest.raises(InvalidArgument):
        OuterEnvelope.from_dict(bad)
