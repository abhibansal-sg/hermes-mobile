from __future__ import annotations

import json
import secrets
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Barrier

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from pydantic import ValidationError

from relay_hub.crypto import b64url_encode, now_milliseconds, verify_envelope_signature
from relay_hub.models import (
    MAX_WIRE_INTEGER,
    GrantRequest,
    OuterEnvelope,
    PairOfferCreate,
)
from relay_hub.storage import Forbidden


def test_shared_authenticated_envelope_fixture_is_accepted_by_hub_model() -> None:
    root = Path(__file__).resolve().parents[3]
    fixture = json.loads((root / "protocol/hrp2/fixtures/auth-envelope.json").read_text())
    envelope = OuterEnvelope.model_validate(fixture["outer_envelope"])
    verify_envelope_signature(envelope, bytes.fromhex(fixture["signing_public_key_hex"]))


def test_self_route_delete_retry_survives_lost_success_response(harness) -> None:
    route_id, route_key = harness.enroll("agent")
    first = harness.signed_request(
        "DELETE", f"/v2/routes/{route_id}", route_id, route_key
    )
    assert first.status_code == 200
    assert first.json() == {
        "route_id": route_id,
        "status": "revoked",
        "grant_ids": [],
        "already_revoked": False,
    }

    # Model a lost first response: retry with a fresh signed nonce after the
    # actor route is already tombstoned.
    retry = harness.signed_request(
        "DELETE", f"/v2/routes/{route_id}", route_id, route_key
    )
    assert retry.status_code == 200
    assert retry.json() == {**first.json(), "already_revoked": True}

    other_route, _other_key = harness.enroll("agent")
    forbidden = harness.signed_request(
        "DELETE", f"/v2/routes/{other_route}", route_id, route_key
    )
    assert forbidden.status_code == 401
    assert forbidden.json()["error"]["code"] == "route_not_active"


def test_route_proof_authenticates_provisional_and_active_but_not_revoked(
    harness,
) -> None:
    key = Ed25519PrivateKey.generate()
    enrolled = harness.client.post(
        "/v2/enroll/provisional",
        json={
            "enrollment_id": "enr_" + b64url_encode(secrets.token_bytes(16)),
            "route_type": "agent",
            "auth_public_key": b64url_encode(key.public_key().public_bytes_raw()),
        },
    )
    assert enrolled.status_code == 201
    route_id = enrolled.json()["route_id"]

    provisional = harness.signed_request(
        "GET", "/v2/route-proof", route_id, key
    )
    assert provisional.status_code == 200
    assert provisional.json() == {"route_id": route_id, "status": "provisional"}

    wrong_key = harness.signed_request(
        "GET", "/v2/route-proof", route_id, Ed25519PrivateKey.generate()
    )
    assert wrong_key.status_code == 401
    assert wrong_key.json()["error"]["code"] == "invalid_route_auth"

    activated = harness.client.post(
        "/v2/enroll/activate",
        headers={"X-Hermes-Enrollment-Token": "operator-test-token"},
        json={"route_id": route_id, "activation_token": None},
    )
    assert activated.status_code == 200
    active = harness.signed_request("GET", "/v2/route-proof", route_id, key)
    assert active.json() == {"route_id": route_id, "status": "active"}

    revoked = harness.signed_request(
        "DELETE", f"/v2/routes/{route_id}", route_id, key
    )
    assert revoked.status_code == 200
    rejected = harness.signed_request("GET", "/v2/route-proof", route_id, key)
    assert rejected.status_code == 401
    assert rejected.json()["error"]["code"] == "route_not_active"


def test_strict_envelope_rejects_malformed_enc_unknown_and_noncanonical_collapse() -> None:
    base = {
        "v": 2,
        "src": "rte_agent",
        "dst": "rte_device",
        "mid": b64url_encode(bytes(16)),
        "class": "state",
        "expires_at_ms": 100,
        "recipient_key_generation": 1,
        "collapse": None,
        "enc": b64url_encode(bytes(32)),
        "ct": b64url_encode(bytes(16)),
        "sig": b64url_encode(bytes(64)),
    }
    with pytest.raises(ValidationError):
        OuterEnvelope.model_validate({**base, "enc": b64url_encode(bytes(31))})
    with pytest.raises(ValidationError):
        OuterEnvelope.model_validate({**base, "plaintext": "forbidden"})
    with pytest.raises(ValidationError):
        OuterEnvelope.model_validate({**base, "collapse": "has spaces"})
    with pytest.raises(ValidationError):
        missing = dict(base)
        missing.pop("collapse")
        OuterEnvelope.model_validate(missing)


def test_every_hub_wire_timestamp_rejects_values_above_exact_json_integer() -> None:
    envelope = {
        "v": 2,
        "src": "rte_agent",
        "dst": "rte_device",
        "mid": b64url_encode(bytes(16)),
        "class": "state",
        "expires_at_ms": MAX_WIRE_INTEGER,
        "recipient_key_generation": 1,
        "collapse": None,
        "enc": b64url_encode(bytes(32)),
        "ct": b64url_encode(bytes(16)),
        "sig": b64url_encode(bytes(64)),
    }
    grant = {
        "grant_id": "grt_" + b64url_encode(bytes(24)),
        "issuer_route": "rte_agent",
        "source_route": "rte_agent",
        "destination_route": "rte_device",
        "permissions": ["send"],
        "expires_at_ms": MAX_WIRE_INTEGER,
        "issuer_signature": b64url_encode(bytes(64)),
    }
    offer = {
        "offer_id": "ofr_timestamp-boundary",
        "offer_route": "off_timestamp-boundary",
        "transport_token_hash": b64url_encode(bytes(32)),
        "owner_route": "rte_agent",
        "expires_at_ms": MAX_WIRE_INTEGER,
    }

    for model, payload in (
        (OuterEnvelope, envelope),
        (GrantRequest, grant),
        (PairOfferCreate, offer),
    ):
        model.model_validate(payload)
        with pytest.raises(ValidationError):
            model.model_validate({**payload, "expires_at_ms": MAX_WIRE_INTEGER + 1})


def test_message_duplicate_conflict_ack_and_post_ack_deduplication(harness) -> None:
    agent, agent_key = harness.enroll("agent")
    device, device_key = harness.enroll("device", owner_route=agent)
    harness.grant(
        issuer_route=agent,
        issuer_key=agent_key,
        source_route=agent,
        destination_route=device,
    )
    envelope = harness.envelope(
        source_route=agent,
        destination_route=device,
        source_key=agent_key,
    )
    first = harness.client.post("/v2/messages", json=envelope.model_dump(by_alias=True))
    assert first.status_code == 202
    assert first.json()["deduplicated"] is False
    duplicate = harness.client.post("/v2/messages", json=envelope.model_dump(by_alias=True))
    assert duplicate.status_code == 200
    assert duplicate.json()["deduplicated"] is True

    conflicting = harness.envelope(
        source_route=agent,
        destination_route=device,
        source_key=agent_key,
        mid=envelope.mid,
        ciphertext=b"different encrypted bytes",
    )
    assert harness.client.post(
        "/v2/messages", json=conflicting.model_dump(by_alias=True)
    ).status_code == 409

    ack = harness.signed_request(
        "POST", "/v2/acks", device, device_key, {"message_ids": [envelope.mid]}
    )
    assert ack.status_code == 200 and ack.json()["acknowledged"] == 1
    after_ack = harness.client.post("/v2/messages", json=envelope.model_dump(by_alias=True))
    assert after_ack.status_code == 200
    assert after_ack.json()["deduplicated"] is True
    assert harness.store.counts(device)[0] == 0


def test_tamper_expiry_grant_and_realtime_rules(harness) -> None:
    agent, agent_key = harness.enroll("agent")
    device, _device_key = harness.enroll("device", owner_route=agent)
    no_grant = harness.envelope(
        source_route=agent, destination_route=device, source_key=agent_key
    )
    assert harness.client.post("/v2/messages", json=no_grant.model_dump(by_alias=True)).status_code == 403
    harness.grant(
        issuer_route=agent,
        issuer_key=agent_key,
        source_route=agent,
        destination_route=device,
    )
    tampered = no_grant.model_dump(by_alias=True)
    tampered["ct"] = b64url_encode(b"tampered-ciphertext")
    assert harness.client.post("/v2/messages", json=tampered).status_code == 401
    expired = harness.envelope(
        source_route=agent,
        destination_route=device,
        source_key=agent_key,
        expires_at_ms=now_milliseconds() - 1,
    )
    assert harness.client.post("/v2/messages", json=expired.model_dump(by_alias=True)).status_code == 422
    realtime = harness.envelope(
        source_route=agent,
        destination_route=device,
        source_key=agent_key,
        message_class="realtime",
    )
    accepted = harness.client.post("/v2/messages", json=realtime.model_dump(by_alias=True))
    assert accepted.status_code == 202 and accepted.json()["stored"] is False
    assert harness.store.counts(device)[0] == 0


def test_signed_auth_replay_revocation_and_socket_delivery(harness) -> None:
    agent, agent_key = harness.enroll("agent")
    device, device_key = harness.enroll("device", owner_route=agent)
    harness.grant(
        issuer_route=agent,
        issuer_key=agent_key,
        source_route=device,
        destination_route=agent,
    )
    body = json.dumps({"message_ids": [b64url_encode(secrets.token_bytes(16))]}, sort_keys=True, separators=(",", ":")).encode()
    nonce = secrets.token_bytes(16)
    headers = harness.signed_headers(
        device, device_key, method="POST", path="/v2/acks", body=body, nonce=nonce
    )
    headers["Content-Type"] = "application/json"
    assert harness.client.post("/v2/acks", headers=headers, content=body).status_code == 200
    assert harness.client.post("/v2/acks", headers=headers, content=body).status_code == 409

    ws_headers = harness.signed_headers(
        device, device_key, method="GET", path="/v2/socket", body=b""
    )
    with harness.client.websocket_connect("/v2/socket", headers=ws_headers) as socket:
        envelope = harness.envelope(
            source_route=device,
            destination_route=agent,
            source_key=device_key,
            message_class="command",
        )
        socket.send_json({"type": "message", "envelope": envelope.model_dump(by_alias=True)})
        accepted = socket.receive_json()
        assert accepted["type"] == "accepted" and accepted["accepted"] is True

    revoke = harness.signed_request("DELETE", f"/v2/routes/{device}", device, device_key)
    assert revoke.status_code == 200
    rejected = harness.client.post("/v2/messages", json=envelope.model_dump(by_alias=True))
    assert rejected.status_code == 403


def test_revoke_and_send_are_one_transaction_invariant(harness) -> None:
    agent, agent_key = harness.enroll("agent")
    device, _device_key = harness.enroll("device", owner_route=agent)
    harness.grant(
        issuer_route=agent,
        issuer_key=agent_key,
        source_route=agent,
        destination_route=device,
    )
    envelope = harness.envelope(
        source_route=agent,
        destination_route=device,
        source_key=agent_key,
        message_class="command",
    )
    start = Barrier(3)

    def send() -> str:
        start.wait()
        try:
            harness.store.accept_envelope(envelope, now_ms=now_milliseconds())
            return "accepted"
        except Forbidden:
            return "forbidden"

    def revoke() -> str:
        start.wait()
        harness.store.revoke_route(
            route_id=device, actor_route=device, now_ms=now_milliseconds()
        )
        return "revoked"

    with ThreadPoolExecutor(max_workers=2) as pool:
        send_future = pool.submit(send)
        revoke_future = pool.submit(revoke)
        start.wait()
        outcomes = {send_future.result(), revoke_future.result()}
    assert "revoked" in outcomes
    assert harness.store.get_route(device).status == "revoked"
    # If send won first, revoke deleted it. If revoke won first, send failed.
    assert harness.store.counts(device)[0] == 0
