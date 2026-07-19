from __future__ import annotations

import hashlib
import secrets
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from relay_hub.crypto import b64url_encode, now_milliseconds


def _start_offer(harness):
    owner_route, owner_key = harness.enroll("agent")
    token = secrets.token_bytes(32)
    offer_id = "ofr_" + b64url_encode(secrets.token_bytes(12))
    offer_route = "off_" + b64url_encode(secrets.token_bytes(12))
    expires_at_ms = now_milliseconds() + 120_000
    payload = {
        "offer_id": offer_id,
        "offer_route": offer_route,
        "transport_token_hash": b64url_encode(hashlib.sha256(token).digest()),
        "owner_route": owner_route,
        "expires_at_ms": expires_at_ms,
    }
    create = harness.signed_request(
        "POST",
        "/v2/offers",
        owner_route,
        owner_key,
        payload,
    )
    assert create.status_code == 201, create.text
    assert create.headers["cache-control"] == "no-store"
    assert create.headers["pragma"] == "no-cache"
    retry = harness.signed_request(
        "POST", "/v2/offers", owner_route, owner_key, payload
    )
    assert retry.status_code == 200
    assert retry.json() == create.json()
    return owner_route, owner_key, token, offer_id, offer_route, expires_at_ms


def _submit_pair_init(harness, *, token, offer_id, offer_route):
    enc = secrets.token_bytes(32)
    ciphertext = secrets.token_bytes(64)
    payload = {
        "v": 2,
        "offer_id": offer_id,
        "enc": b64url_encode(enc),
        "ct": b64url_encode(ciphertext),
    }
    headers = {"Authorization": "Bearer " + b64url_encode(token)}
    response = harness.client.post(
        f"/v2/offers/{offer_route}/messages",
        headers=headers,
        json=payload,
    )
    assert response.status_code == 202, response.text
    assert response.headers["cache-control"] == "no-store"
    duplicate = harness.client.post(
        f"/v2/offers/{offer_route}/messages", headers=headers, json=payload
    )
    assert duplicate.status_code == 200
    assert duplicate.json()["deduplicated"] is True
    return enc, ciphertext, hashlib.sha256(enc + ciphertext).digest()


def _create_pending_pair(
    harness, *, owner_route, owner_key, offer_id
):
    device_key = Ed25519PrivateKey.generate()
    payload = {
        "route_type": "device",
        "auth_public_key": b64url_encode(device_key.public_key().public_bytes_raw()),
        "offer_id": offer_id,
    }
    route = harness.signed_request(
        "POST",
        "/v2/routes",
        owner_route,
        owner_key,
        payload,
    )
    assert route.status_code == 201, route.text
    assert route.headers["cache-control"] == "no-store"
    assert route.json()["offer_id"] == offer_id
    device_route = route.json()["route_id"]
    retry = harness.signed_request(
        "POST", "/v2/routes", owner_route, owner_key, payload
    )
    assert retry.status_code == 200
    assert retry.json() == route.json()
    forward = harness.grant(
        issuer_route=owner_route,
        issuer_key=owner_key,
        source_route=owner_route,
        destination_route=device_route,
    )
    reverse = harness.grant(
        issuer_route=owner_route,
        issuer_key=owner_key,
        source_route=device_route,
        destination_route=owner_route,
    )
    assert harness.store.get_grant_status(forward.grant_id) == "pending"
    assert harness.store.get_grant_status(reverse.grant_id) == "pending"
    grant_retry = harness.signed_request(
        "POST",
        "/v2/grants",
        owner_route,
        owner_key,
        forward.model_dump(),
    )
    assert grant_retry.status_code == 200
    assert grant_retry.json() == {
        "grant_id": forward.grant_id,
        "created": False,
        "status": "pending",
    }
    return device_route, device_key, forward.grant_id, reverse.grant_id


def _accept_pair(
    harness,
    *,
    owner_route,
    owner_key,
    offer_id,
    device_route,
    message_hash,
):
    enc = secrets.token_bytes(32)
    ciphertext = secrets.token_bytes(64)
    payload = {
        "message_hash": b64url_encode(message_hash),
        "device_route": device_route,
        "enc": b64url_encode(enc),
        "ct": b64url_encode(ciphertext),
    }
    response = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/accept",
        owner_route,
        owner_key,
        payload,
    )
    assert response.status_code == 200, response.text
    response_hash = hashlib.sha256(enc + ciphertext).digest()
    assert response.json() == {
        "status": "accepted",
        "offer_id": offer_id,
        "device_route": device_route,
        "response_hash": b64url_encode(response_hash),
    }
    assert response.headers["cache-control"] == "no-store"
    duplicate = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/accept",
        owner_route,
        owner_key,
        payload,
    )
    assert duplicate.status_code == 200
    conflict = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/accept",
        owner_route,
        owner_key,
        {**payload, "ct": b64url_encode(secrets.token_bytes(64))},
    )
    assert conflict.status_code == 409
    return response_hash


def test_pairing_is_duplex_atomic_and_pending_route_is_one_control_only(harness) -> None:
    owner, owner_key, token, offer_id, offer_route, offer_expiry = _start_offer(harness)

    waiting = harness.signed_request(
        "GET", f"/v2/offers/{offer_id}", owner, owner_key
    )
    assert waiting.status_code == 200
    assert waiting.json() == {"status": "waiting", "offer_id": offer_id}
    _, _, message_hash = _submit_pair_init(
        harness, token=token, offer_id=offer_id, offer_route=offer_route
    )
    ready = harness.signed_request(
        "GET", f"/v2/offers/{offer_id}", owner, owner_key
    )
    assert ready.status_code == 200
    assert ready.json()["message_hash"] == b64url_encode(message_hash)

    device, device_key, forward_grant, reverse_grant = _create_pending_pair(
        harness, owner_route=owner, owner_key=owner_key, offer_id=offer_id
    )
    second_route = harness.signed_request(
        "POST",
        "/v2/routes",
        owner,
        owner_key,
        {
            "route_type": "device",
            "auth_public_key": b64url_encode(
                Ed25519PrivateKey.generate().public_key().public_bytes_raw()
            ),
            "offer_id": offer_id,
        },
    )
    assert second_route.status_code == 409

    # Neither the operator activation path nor an ordinary envelope can bypass
    # the encrypted PairAccept/PairConfirm lifecycle.
    bypass = harness.client.post(
        "/v2/enroll/activate",
        headers={"X-Hermes-Enrollment-Token": "operator-test-token"},
        json={"route_id": device, "activation_token": None},
    )
    assert bypass.status_code == 403
    pre_accept_control = harness.envelope(
        source_route=device,
        destination_route=owner,
        source_key=device_key,
        message_class="control",
        expires_at_ms=offer_expiry,
    )
    assert harness.client.post(
        "/v2/messages", json=pre_accept_control.model_dump(by_alias=True)
    ).status_code == 403

    response_hash = _accept_pair(
        harness,
        owner_route=owner,
        owner_key=owner_key,
        offer_id=offer_id,
        device_route=device,
        message_hash=message_hash,
    )
    phone_accept = harness.client.get(
        f"/v2/offers/{offer_route}/accept",
        headers={"Authorization": "Bearer " + b64url_encode(token)},
    )
    assert phone_accept.status_code == 200
    assert phone_accept.json()["response_hash"] == b64url_encode(response_hash)
    assert set(phone_accept.json()) == {
        "v", "offer_id", "device_route", "enc", "ct", "response_hash"
    }
    assert phone_accept.headers["cache-control"] == "no-store"

    confirm_payload = {
        "message_hash": b64url_encode(message_hash),
        "response_hash": b64url_encode(response_hash),
        "device_route": device,
    }
    too_early = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/confirm",
        owner,
        owner_key,
        confirm_payload,
    )
    assert too_early.status_code == 409
    assert too_early.json()["error"]["code"] == "pair_confirm_control_missing"

    state = harness.envelope(
        source_route=device,
        destination_route=owner,
        source_key=device_key,
        message_class="state",
        expires_at_ms=offer_expiry,
    )
    assert harness.client.post(
        "/v2/messages", json=state.model_dump(by_alias=True)
    ).status_code == 403
    too_long = harness.envelope(
        source_route=device,
        destination_route=owner,
        source_key=device_key,
        message_class="control",
        expires_at_ms=offer_expiry + 1,
    )
    assert harness.client.post(
        "/v2/messages", json=too_long.model_dump(by_alias=True)
    ).status_code == 403

    control = harness.envelope(
        source_route=device,
        destination_route=owner,
        source_key=device_key,
        message_class="control",
        expires_at_ms=offer_expiry,
    )
    first = harness.client.post("/v2/messages", json=control.model_dump(by_alias=True))
    assert first.status_code == 202
    duplicate = harness.client.post("/v2/messages", json=control.model_dump(by_alias=True))
    assert duplicate.status_code == 200 and duplicate.json()["deduplicated"] is True
    second_control = harness.envelope(
        source_route=device,
        destination_route=owner,
        source_key=device_key,
        message_class="control",
        expires_at_ms=offer_expiry,
    )
    rejected = harness.client.post(
        "/v2/messages", json=second_control.model_dump(by_alias=True)
    )
    assert rejected.status_code == 403
    assert rejected.json()["error"]["code"] == "pending_pair_control_already_used"

    confirmed = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/confirm",
        owner,
        owner_key,
        confirm_payload,
    )
    assert confirmed.status_code == 200, confirmed.text
    assert confirmed.json() == {
        "device_route": device,
        "status": "active",
        "grant_ids": sorted([forward_grant, reverse_grant]),
    }
    assert harness.store.get_route(device).status == "active"
    assert harness.store.get_grant_status(forward_grant) == "active"
    assert harness.store.get_grant_status(reverse_grant) == "active"
    assert harness.signed_request(
        "GET", f"/v2/offers/{offer_id}", owner, owner_key
    ).status_code == 404
    # A lost HTTP response after the atomic commit is recoverable for the
    # bounded confirmation-receipt TTL.
    retried = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/confirm",
        owner,
        owner_key,
        confirm_payload,
    )
    assert retried.status_code == 200
    assert retried.json() == confirmed.json()
    mismatch = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/confirm",
        owner,
        owner_key,
        {**confirm_payload, "response_hash": b64url_encode(secrets.token_bytes(32))},
    )
    assert mismatch.status_code == 409
    assert mismatch.json()["error"]["code"] == "pair_confirm_receipt_mismatch"

    ordinary = harness.envelope(
        source_route=device,
        destination_route=owner,
        source_key=device_key,
        message_class="state",
    )
    assert harness.client.post(
        "/v2/messages", json=ordinary.model_dump(by_alias=True)
    ).status_code == 202

    unrelated, unrelated_key = harness.enroll("agent")
    forbidden_revoke = harness.signed_request(
        "DELETE", f"/v2/routes/{device}", unrelated, unrelated_key
    )
    assert forbidden_revoke.status_code == 403
    revoked = harness.signed_request(
        "DELETE", f"/v2/routes/{device}", owner, owner_key
    )
    assert revoked.status_code == 200
    assert revoked.json() == {
        "route_id": device,
        "status": "revoked",
        "grant_ids": sorted([forward_grant, reverse_grant]),
        "already_revoked": False,
    }
    assert harness.store.counts(owner)[0] == 0
    retry_revoke = harness.signed_request(
        "DELETE", f"/v2/routes/{device}", owner, owner_key
    )
    assert retry_revoke.status_code == 200
    assert retry_revoke.json()["grant_ids"] == revoked.json()["grant_ids"]
    assert retry_revoke.json()["already_revoked"] is True


def test_pair_init_compare_and_swap_rejects_replay_with_different_bytes(harness) -> None:
    owner, owner_key, token, offer_id, offer_route, _ = _start_offer(harness)
    first_enc = secrets.token_bytes(32)
    first_ct = secrets.token_bytes(32)
    start = Barrier(3)

    def submit(enc: bytes, ciphertext: bytes) -> int:
        start.wait()
        return harness.client.post(
            f"/v2/offers/{offer_route}/messages",
            headers={"Authorization": "Bearer " + b64url_encode(token)},
            json={
                "v": 2,
                "offer_id": offer_id,
                "enc": b64url_encode(enc),
                "ct": b64url_encode(ciphertext),
            },
        ).status_code

    with ThreadPoolExecutor(max_workers=2) as pool:
        one = pool.submit(submit, first_enc, first_ct)
        two = pool.submit(submit, secrets.token_bytes(32), secrets.token_bytes(32))
        start.wait()
        outcomes = sorted([one.result(), two.result()])
    assert outcomes == [202, 409]
    ready = harness.signed_request(
        "GET", f"/v2/offers/{offer_id}", owner, owner_key
    )
    assert ready.status_code == 200 and ready.json()["status"] == "ready"


def test_expired_or_cancelled_offer_revokes_pending_route_and_grants(harness) -> None:
    owner, owner_key, token, offer_id, offer_route, expires_at = _start_offer(harness)
    _submit_pair_init(harness, token=token, offer_id=offer_id, offer_route=offer_route)
    device, _key, forward, reverse = _create_pending_pair(
        harness, owner_route=owner, owner_key=owner_key, offer_id=offer_id
    )
    purged = harness.store.purge(expires_at + 1)
    assert purged["pair_offers"] == 1
    assert harness.store.get_route(device).status == "revoked"
    assert harness.store.get_grant_status(forward) == "revoked"
    assert harness.store.get_grant_status(reverse) == "revoked"

    owner2, owner_key2, token2, offer_id2, offer_route2, _ = _start_offer(harness)
    _submit_pair_init(harness, token=token2, offer_id=offer_id2, offer_route=offer_route2)
    device2, _key2, forward2, reverse2 = _create_pending_pair(
        harness, owner_route=owner2, owner_key=owner_key2, offer_id=offer_id2
    )
    cancelled = harness.signed_request(
        "DELETE", f"/v2/offers/{offer_id2}/cancel", owner2, owner_key2
    )
    assert cancelled.status_code == 200 and cancelled.json()["deleted"] is True
    assert cancelled.headers["cache-control"] == "no-store"
    assert harness.store.get_route(device2).status == "revoked"
    assert harness.store.get_grant_status(forward2) == "revoked"
    assert harness.store.get_grant_status(reverse2) == "revoked"


def test_first_device_can_deliver_activation_inside_pair_init_without_opening_other_access(
    harness,
) -> None:
    owner_key = Ed25519PrivateKey.generate()
    enrollment_id = "enr_" + b64url_encode(secrets.token_bytes(16))
    enrolled = harness.client.post(
        "/v2/enroll/provisional",
        json={
            "enrollment_id": enrollment_id,
            "route_type": "agent",
            "auth_public_key": b64url_encode(owner_key.public_key().public_bytes_raw()),
        },
    )
    assert enrolled.status_code == 201
    owner = enrolled.json()["route_id"]
    token = secrets.token_bytes(32)
    offer_id = "ofr_" + b64url_encode(secrets.token_bytes(12))
    offer_route = "off_" + b64url_encode(secrets.token_bytes(12))
    offer_expiry = min(
        enrolled.json()["expires_at_ms"], now_milliseconds() + 120_000
    )
    offer = harness.signed_request(
        "POST",
        "/v2/offers",
        owner,
        owner_key,
        {
            "offer_id": offer_id,
            "offer_route": offer_route,
            "transport_token_hash": b64url_encode(hashlib.sha256(token).digest()),
            "owner_route": owner,
            "expires_at_ms": offer_expiry,
        },
    )
    assert offer.status_code == 201, offer.text
    assert harness.signed_request(
        "GET", f"/v2/offers/{offer_id}", owner, owner_key
    ).status_code == 200

    # The provisional signature is valid but pairing is its only authority.
    blocked_ack = harness.signed_request(
        "POST",
        "/v2/acks",
        owner,
        owner_key,
        {"message_ids": [b64url_encode(secrets.token_bytes(16))]},
    )
    assert blocked_ack.status_code == 401
    _, _, message_hash = _submit_pair_init(
        harness, token=token, offer_id=offer_id, offer_route=offer_route
    )

    # PairInit is opaque to the Hub; in production its decrypted inner payload
    # carries the App-Attested activation token. Redeeming it changes only the
    # Agent route, after which normal duplex pairing can proceed.
    activated = harness.client.post(
        "/v2/enroll/activate",
        headers={"X-Hermes-Enrollment-Token": "operator-test-token"},
        json={"route_id": owner, "activation_token": None},
    )
    assert activated.status_code == 200
    device, device_key, forward, reverse = _create_pending_pair(
        harness, owner_route=owner, owner_key=owner_key, offer_id=offer_id
    )
    response_hash = _accept_pair(
        harness,
        owner_route=owner,
        owner_key=owner_key,
        offer_id=offer_id,
        device_route=device,
        message_hash=message_hash,
    )
    control = harness.envelope(
        source_route=device,
        destination_route=owner,
        source_key=device_key,
        message_class="control",
        expires_at_ms=offer_expiry,
    )
    assert harness.client.post(
        "/v2/messages", json=control.model_dump(by_alias=True)
    ).status_code == 202
    confirmed = harness.signed_request(
        "POST",
        f"/v2/offers/{offer_id}/confirm",
        owner,
        owner_key,
        {
            "message_hash": b64url_encode(message_hash),
            "response_hash": b64url_encode(response_hash),
            "device_route": device,
        },
    )
    assert confirmed.status_code == 200
    assert confirmed.json()["grant_ids"] == sorted([forward, reverse])
