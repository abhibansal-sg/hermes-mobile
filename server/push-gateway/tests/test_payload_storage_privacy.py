from __future__ import annotations

import importlib
import json
import pkgutil
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError

import push_gateway
from push_gateway.apns import PayloadTooLarge, build_payload
from push_gateway.crypto import b64url_encode
from push_gateway.models import MAX_WIRE_INTEGER, EndpointRegistration, SendRequest
from push_gateway.storage import metadata


def _serialized_size(body: SendRequest) -> int:
    aps = {
        "alert": {"title": "Hermes", "body": "Hermes needs your attention."},
        "mutable-content": 1,
    }
    if body.sound:
        aps["sound"] = "default"
    value = {
        "aps": aps,
        "h_v": body.v,
        "class": body.notification_class,
        "nid": body.notification_id,
        "enc": body.preview_enc,
        "ct": body.preview_ct,
        "exp": body.expires_at_ms,
        "collapse": body.collapse_id,
        "sound": body.sound,
    }
    return len(json.dumps(value, sort_keys=True, separators=(",", ":")).encode())


def _sized_model(target: int) -> SendRequest:
    for ciphertext_bytes in range(2400, 3300):
        for nid_length in range(1, 129):
            candidate = SendRequest.model_validate({
                "v": 2,
                "class": "approval",
                "notification_id": "n" * nid_length,
                "preview_enc": b64url_encode(bytes(32)),
                "preview_ct": b64url_encode(b"x" * ciphertext_bytes),
                "collapse_id": None,
                "expires_at_ms": 1784450000000,
                "sound": True,
            })
            if _serialized_size(candidate) == target:
                return candidate
    raise AssertionError(f"could not construct {target}-byte APNs payload")


def test_shared_notification_fixture_maps_to_complete_apns_aad_fields() -> None:
    root = Path(__file__).resolve().parents[3]
    fixture = json.loads(
        (root / "protocol/hrp2/fixtures/notification-preview.json").read_text()
    )
    descriptor = SendRequest.model_validate(fixture["descriptor"])
    payload, serialized = build_payload(descriptor)
    assert len(serialized) <= 3900
    assert {
        "h_v": payload["h_v"],
        "class": payload["class"],
        "nid": payload["nid"],
        "enc": payload["enc"],
        "ct": payload["ct"],
        "exp": payload["exp"],
        "collapse": payload["collapse"],
        "sound": payload["sound"],
    } == {
        "h_v": descriptor.v,
        "class": descriptor.notification_class,
        "nid": descriptor.notification_id,
        "enc": descriptor.preview_enc,
        "ct": descriptor.preview_ct,
        "exp": descriptor.expires_at_ms,
        "collapse": descriptor.collapse_id,
        "sound": descriptor.sound,
    }


def test_payload_exactly_3900_is_allowed_and_4097_is_rejected() -> None:
    exact = _sized_model(3900)
    assert len(build_payload(exact)[1]) == 3900
    too_large = _sized_model(4097)
    with pytest.raises(PayloadTooLarge) as exc:
        build_payload(too_large)
    assert exc.value.size == 4097


def test_preview_enc_is_exact_and_descriptor_requires_explicit_aad_fields() -> None:
    valid = {
        "v": 2,
        "class": "update",
        "notification_id": "nid",
        "preview_enc": b64url_encode(bytes(32)),
        "preview_ct": b64url_encode(bytes(16)),
        "collapse_id": None,
        "expires_at_ms": 100,
        "sound": False,
    }
    with pytest.raises(ValidationError):
        SendRequest.model_validate({**valid, "preview_enc": b64url_encode(bytes(31))})
    for required in ("collapse_id", "sound", "v"):
        missing = dict(valid)
        missing.pop(required)
        with pytest.raises(ValidationError):
            SendRequest.model_validate(missing)


def test_send_expiry_accepts_exact_js_safe_boundary_and_rejects_next_integer() -> None:
    body = {
        "v": 2,
        "class": "update",
        "notification_id": "nid_boundary",
        "preview_enc": b64url_encode(bytes(32)),
        "preview_ct": b64url_encode(bytes(16)),
        "collapse_id": None,
        "expires_at_ms": MAX_WIRE_INTEGER,
        "sound": False,
    }
    assert SendRequest.model_validate(body).expires_at_ms == MAX_WIRE_INTEGER
    with pytest.raises(ValidationError):
        SendRequest.model_validate({**body, "expires_at_ms": MAX_WIRE_INTEGER + 1})


def test_token_is_envelope_encrypted_at_rest(harness) -> None:
    registration, body = harness.register()
    endpoint = harness.store.get_endpoint(registration["endpoint_id"])
    assert endpoint is not None
    assert body["apns_token"].encode() not in endpoint.token.ciphertext
    assert len(endpoint.token.nonce) == 12 and len(endpoint.token.wrap_nonce) == 12
    assert (
        harness.client.app.state.token_vault.decrypt(
            endpoint.token,
            endpoint_id=endpoint.endpoint_id,
            bundle_id=endpoint.bundle_id,
            environment=endpoint.environment,
        )
        == body["apns_token"]
    )


def test_push_schema_has_no_sensitive_preview_or_identifier_columns() -> None:
    prohibited = {
        "session_id",
        "turn_id",
        "item_id",
        "request_id",
        "title",
        "body",
        "tool_args",
        "tool_result",
        "apns_token",
    }
    columns = {
        column.name for table in metadata.tables.values() for column in table.columns
    }
    assert not (prohibited & columns)
    assert not (prohibited & set(SendRequest.model_fields))
    assert not (
        {"title", "body", "session_id", "request_id"}
        & set(EndpointRegistration.model_fields)
    )

    # Import the shipped package surface for real. The Push process may load
    # its own APNs adapter, but it must never load the Hub package or mailbox
    # storage into the runtime boundary.
    for module in pkgutil.walk_packages(
        push_gateway.__path__, prefix=f"{push_gateway.__name__}."
    ):
        importlib.import_module(module.name)
    assert not any(name.startswith("relay_hub") for name in sys.modules)
