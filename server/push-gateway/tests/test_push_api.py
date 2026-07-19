from __future__ import annotations

import asyncio
import base64
import datetime
import hashlib
import json
import secrets
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import replace
from email.utils import format_datetime

import httpx
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from conftest import FakeAPNs, FakeVerifier, PushHarness
from push_gateway.apns import (
    MAX_APNS_RETRY_AFTER_MS,
    APNsClient,
    APNsEndpoint,
    APNsResult,
    _retry_after_ms,
)
from push_gateway.app import create_app
from push_gateway.crypto import (
    b64url_encode,
    delivery_identifiers,
    opaque_hash,
    secret_hash,
)
from push_gateway.models import SendRequest
from push_gateway.storage import (
    SEND_ATTEMPT_LEASE_MS,
    bind_tokens,
    binding_exchange_authorities,
    binding_exchange_receipts,
    bindings,
    endpoints,
    push_receipts,
    push_send_attempts,
)
from push_gateway.storage import DatabaseStore


def test_registration_binding_send_and_complete_hrn2_payload(harness) -> None:
    registration, body = harness.register()
    binding = harness.bind(registration["bind_token"], ["update"])
    send_body = harness.send_body()
    response = harness.client.post(
        "/v2/send",
        headers={"Authorization": f"Bearer {binding['send_capability']}"},
        json=send_body,
    )
    assert response.status_code == 200, response.text
    assert response.json()["accepted"] is True
    assert len(harness.apns.sent) == 1
    sent = harness.apns.sent[0]
    assert sent["endpoint"].token == body["apns_token"]
    payload = json.loads(sent["payload"])
    assert set(payload) == {
        "aps",
        "h_v",
        "class",
        "nid",
        "enc",
        "ct",
        "exp",
        "collapse",
        "sound",
    }
    assert payload["h_v"] == 2
    assert payload["exp"] == send_body["expires_at_ms"]
    assert payload["collapse"] is None
    assert payload["sound"] is True
    assert payload["aps"]["alert"] == {
        "title": "Hermes",
        "body": "Hermes needs your attention.",
    }
    assert "category" not in payload["aps"]
    assert not ({"session_id", "request_id"} & payload.keys())

    # The App Attest client-data digest is exactly the supplied transcript hash,
    # and the raw APNs token itself is not part of that transcript.
    call = harness.verifier.calls[0]
    assert call["request_hash"] == hashlib.sha256(call["request_transcript"]).digest()
    assert body["apns_token"].encode() not in call["request_transcript"]


def test_challenge_and_bind_tokens_are_one_time_and_counter_is_monotonic(
    harness,
) -> None:
    challenge = harness.challenge()
    body = harness.registration_body(challenge=challenge)
    first = harness.client.post("/v2/endpoints/register", json=body)
    assert first.status_code == 201
    replay = harness.client.post("/v2/endpoints/register", json=body)
    assert replay.status_code == 200
    assert replay.json() == first.json()
    assert replay.headers["cache-control"] == "no-store"
    assert len(harness.verifier.calls) == 1
    changed = dict(body, apns_token="ac" * 32)
    conflict = harness.client.post("/v2/endpoints/register", json=changed)
    assert conflict.status_code == 409

    bind_token = first.json()["bind_token"]
    exchange_body = {
        "bind_token": bind_token,
        "exchange_id": "xch_one-time-0001",
    }
    exchanged = harness.client.post(
        "/v2/bindings/exchange",
        json=exchange_body,
    )
    assert exchanged.status_code == 201
    exchange_retry = harness.client.post("/v2/bindings/exchange", json=exchange_body)
    assert exchange_retry.status_code == 200
    assert exchange_retry.json() == exchanged.json()
    assert exchange_retry.headers["cache-control"] == "no-store"
    reused = harness.client.post(
        "/v2/bindings/exchange",
        json={"bind_token": bind_token, "exchange_id": "xch_different-0002"},
    )
    assert reused.status_code == 409

    refresh_challenge = harness.challenge()
    harness.verifier.next_counter = 1
    refresh = {
        "endpoint_id": first.json()["endpoint_id"],
        "challenge": refresh_challenge,
        "app_attest_key_id": body["app_attest_key_id"],
        "assertion": "refresh-assertion-0001",
        "apns_token": "cd" * 32,
        "environment": body["environment"],
        "bundle_id": body["bundle_id"],
        "preview_kem_pub": body["preview_kem_pub"],
        "installation_nonce": body["installation_nonce"],
    }
    rollback = harness.client.post("/v2/endpoints/token-refresh", json=refresh)
    assert rollback.status_code == 409
    assert rollback.json()["error"]["code"] == "attest_counter_rollback"


def test_revoke_before_delayed_exchange_commit_is_idempotent_and_cannot_resurrect(
    harness,
) -> None:
    registration, _ = harness.register()
    body = {
        "bind_token": registration["bind_token"],
        "exchange_id": "xch_cancel-before-commit",
    }

    first = harness.client.post("/v2/bindings/exchange/revoke", json=body)
    retry = harness.client.post("/v2/bindings/exchange/revoke", json=body)
    assert first.status_code == retry.status_code == 200
    assert first.json() == retry.json() == {"revoked": True}
    assert first.headers["cache-control"] == "no-store"
    assert "binding_id" not in first.json() and "send_capability" not in first.json()

    delayed = harness.client.post("/v2/bindings/exchange", json=body)
    assert delayed.status_code == 403
    assert delayed.json()["error"]["code"] == "binding_exchange_revoked"
    with harness.store.engine.connect() as conn:
        assert (
            conn.execute(select(func.count()).select_from(bindings)).scalar_one() == 0
        )
        assert (
            conn.execute(
                select(func.count()).select_from(binding_exchange_authorities)
            ).scalar_one()
            == 1
        )


def test_revoke_by_exchange_survives_receipt_and_bind_token_purge(harness) -> None:
    registration, _ = harness.register(installation=b"exchange-revoke-after-purge")
    body = {
        "bind_token": registration["bind_token"],
        "exchange_id": "xch_revoke-after-receipt-purge",
        "requested_classes": ["update"],
    }
    exchanged = harness.client.post("/v2/bindings/exchange", json=body)
    assert exchanged.status_code == 201
    capability = exchanged.json()["send_capability"]
    revoke_body = {
        "bind_token": body["bind_token"],
        "exchange_id": body["exchange_id"],
    }

    harness.store.purge(registration["bind_token_expires_at_ms"] + 86_400_001)
    with harness.store.engine.connect() as conn:
        assert (
            conn.execute(select(func.count()).select_from(bind_tokens)).scalar_one()
            == 0
        )
        assert (
            conn.execute(
                select(func.count()).select_from(binding_exchange_receipts)
            ).scalar_one()
            == 0
        )
        assert (
            conn.execute(
                select(func.count()).select_from(binding_exchange_authorities)
            ).scalar_one()
            == 1
        )

    first = harness.client.post("/v2/bindings/exchange/revoke", json=revoke_body)
    retry = harness.client.post("/v2/bindings/exchange/revoke", json=revoke_body)
    assert first.status_code == retry.status_code == 200
    assert first.json() == retry.json() == {"revoked": True}
    assert set(first.json()) == {"revoked"}
    assert (
        harness.store.authenticate_binding(
            secret_hash(capability, harness.settings.capability_pepper)
        )
        is None
    )


def test_class_escalation_duplicate_conflict_quota_and_revocation(harness) -> None:
    registration, _ = harness.register()
    binding = harness.bind(registration["bind_token"], ["update"])
    headers = {"Authorization": f"Bearer {binding['send_capability']}"}
    escalated = harness.client.post(
        "/v2/send",
        headers=headers,
        json=harness.send_body(
            notification_id="nid_escalate", notification_class="approval"
        ),
    )
    assert escalated.status_code == 403
    original = harness.send_body(notification_id="nid_idempotent")
    assert (
        harness.client.post("/v2/send", headers=headers, json=original).status_code
        == 200
    )
    duplicate = harness.client.post("/v2/send", headers=headers, json=original)
    assert duplicate.status_code == 200 and duplicate.json()["deduplicated"] is True
    assert len(harness.apns.sent) == 1
    conflicting = dict(
        original, preview_ct=b64url_encode(b"different-authenticated-ciphertext")
    )
    assert (
        harness.client.post("/v2/send", headers=headers, json=conflicting).status_code
        == 409
    )
    revoked = harness.client.delete(
        f"/v2/bindings/{binding['binding_id']}", headers=headers
    )
    assert revoked.status_code == 200
    assert (
        harness.client.post(
            "/v2/send",
            headers=headers,
            json=harness.send_body(notification_id="nid_after_revoke"),
        ).status_code
        == 401
    )


def test_apns_410_prunes_and_attested_token_refresh_reactivates(harness) -> None:
    registration, body = harness.register()
    binding = harness.bind(registration["bind_token"])
    headers = {"Authorization": f"Bearer {binding['send_capability']}"}
    harness.apns.result = APNsResult(False, 410, should_prune=True)
    prune_body = harness.send_body(notification_id="nid_prune")
    rejected = harness.client.post("/v2/send", headers=headers, json=prune_body)
    assert rejected.status_code == 502 and rejected.json()["endpoint_pruned"] is True
    assert harness.store.get_endpoint(registration["endpoint_id"]).status == "disabled"

    harness.verifier.next_counter = 2
    refresh = {
        "endpoint_id": registration["endpoint_id"],
        "challenge": harness.challenge(),
        "app_attest_key_id": body["app_attest_key_id"],
        "assertion": "refresh-assertion-0002",
        "apns_token": "ef" * 20,
        "environment": body["environment"],
        "bundle_id": body["bundle_id"],
        "preview_kem_pub": body["preview_kem_pub"],
        "installation_nonce": body["installation_nonce"],
    }
    assert (
        harness.client.post("/v2/endpoints/token-refresh", json=refresh).status_code
        == 200
    )
    assert harness.store.get_endpoint(registration["endpoint_id"]).status == "active"
    harness.apns.result = APNsResult(True, 200)
    assert (
        harness.client.post(
            "/v2/send",
            headers=headers,
            json=harness.send_body(notification_id="nid_after_refresh"),
        ).status_code
        == 200
    )
    assert harness.apns.sent[-1]["endpoint"].token == "ef" * 20
    retried_410 = harness.client.post("/v2/send", headers=headers, json=prune_body)
    assert retried_410.status_code == 502
    assert retried_410.json()["accepted"] is False
    assert retried_410.json()["deduplicated"] is True


def test_expiration_bundle_and_unknown_sensitive_input_fail_closed(harness) -> None:
    wrong_bundle = harness.registration_body()
    wrong_bundle["bundle_id"] = "attacker.example"
    assert (
        harness.client.post("/v2/endpoints/register", json=wrong_bundle).status_code
        == 403
    )

    registration, _ = harness.register(installation=b"installation-0002")
    binding = harness.bind(registration["bind_token"])
    headers = {"Authorization": f"Bearer {binding['send_capability']}"}
    expired = harness.send_body(notification_id="nid_expired")
    expired["expires_at_ms"] = time.time_ns() // 1_000_000 - 1
    assert (
        harness.client.post("/v2/send", headers=headers, json=expired).status_code
        == 422
    )
    sensitive = harness.send_body(notification_id="nid_bad_input")
    sensitive["title"] = "must never be accepted"
    response = harness.client.post("/v2/send", headers=headers, json=sensitive)
    assert response.status_code == 422
    assert response.json() == {
        "error": {"code": "invalid_request", "message": "invalid request"}
    }


def test_registration_recovers_same_installation_after_response_receipt_expiry(
    harness,
) -> None:
    first, body = harness.register(
        token="ab" * 17, installation=b"installation-recovery"
    )
    harness.store.purge(first["bind_token_expires_at_ms"] + 1)
    recovered_body = harness.registration_body(
        challenge=harness.challenge(),
        token="cd" * 19,
        installation=b"installation-recovery",
    )
    recovered_body["app_attest_key_id"] = body["app_attest_key_id"]
    recovered_body["attestation"] = None
    recovered = harness.client.post("/v2/endpoints/register", json=recovered_body)
    assert recovered.status_code == 201, recovered.text
    assert recovered.json()["endpoint_id"] == first["endpoint_id"]
    assert recovered.json()["bind_token"] != first["bind_token"]
    stale_exchange = harness.client.post(
        "/v2/bindings/exchange",
        json={
            "bind_token": first["bind_token"],
            "exchange_id": "xch_stale-after-recovery",
        },
    )
    assert stale_exchange.status_code == 409
    assert stale_exchange.json()["error"]["code"] == "bind_token_reused"
    replacement_exchange = harness.client.post(
        "/v2/bindings/exchange",
        json={
            "bind_token": recovered.json()["bind_token"],
            "exchange_id": "xch_replacement-after-recovery",
        },
    )
    assert replacement_exchange.status_code == 201
    endpoint = harness.store.get_endpoint(first["endpoint_id"])
    assert endpoint is not None
    assert (
        harness.client.app.state.token_vault.decrypt(
            endpoint.token,
            endpoint_id=endpoint.endpoint_id,
            bundle_id=endpoint.bundle_id,
            environment=endpoint.environment,
        )
        == "cd" * 19
    )

    unknown_key = dict(recovered_body)
    unknown_key["challenge"] = harness.challenge()
    unknown_key["app_attest_key_id"] = base64.b64encode(b"u" * 32).decode("ascii")
    unknown = harness.client.post("/v2/endpoints/register", json=unknown_key)
    assert unknown.status_code == 409
    assert unknown.json()["error"]["code"] == "app_attest_initial_required"

    # Commit a second valid App Attest identity on another installation, then
    # prove it cannot claim this installation during recovery.
    other_key = base64.b64encode(b"z" * 32).decode("ascii")
    other_body = harness.registration_body(installation=b"installation-other-key")
    other_body["app_attest_key_id"] = other_key
    assert (
        harness.client.post("/v2/endpoints/register", json=other_body).status_code
        == 201
    )
    wrong_key = dict(recovered_body)
    wrong_key["challenge"] = harness.challenge()
    wrong_key["app_attest_key_id"] = other_key
    mismatch = harness.client.post("/v2/endpoints/register", json=wrong_key)
    assert mismatch.status_code == 409
    assert mismatch.json()["error"]["code"] == "installation_key_mismatch"


def test_attested_hub_activation_has_no_apns_endpoint_or_binding_artifact(
    harness,
) -> None:
    body = {
        "challenge": harness.challenge(),
        "app_attest_key_id": base64.b64encode(b"a" * 32).decode("ascii"),
        "assertion": "activation-assertion-data",
        "attestation": "activation-attestation-data",
        "bundle_id": "ai.hermes.app",
        "environment": "production",
        "installation_nonce": b64url_encode(b"activation-installation"),
        "hub_route_id": "rte_" + b64url_encode(secrets.token_bytes(24)),
    }
    first = harness.client.post("/v2/hub-activations", json=body)
    assert first.status_code == 201, first.text
    assert set(first.json()) == {
        "hub_activation_token",
        "hub_activation_token_expires_at_ms",
    }
    assert first.headers["cache-control"] == "no-store"
    verifier_calls = len(harness.verifier.calls)
    retry = harness.client.post("/v2/hub-activations", json=body)
    assert retry.status_code == 200 and retry.json() == first.json()
    assert len(harness.verifier.calls) == verifier_calls
    harness.store.purge(first.json()["hub_activation_token_expires_at_ms"] + 1)
    recovered_body = dict(body)
    recovered_body["challenge"] = harness.challenge()
    recovered_body["assertion"] = "activation-recovery-assertion"
    recovered_body["attestation"] = None
    recovered = harness.client.post("/v2/hub-activations", json=recovered_body)
    assert recovered.status_code == 201, recovered.text
    assert set(recovered.json()) == {
        "hub_activation_token",
        "hub_activation_token_expires_at_ms",
    }
    assert (
        recovered.json()["hub_activation_token"] != first.json()["hub_activation_token"]
    )

    unknown = dict(recovered_body)
    unknown["challenge"] = harness.challenge()
    unknown["app_attest_key_id"] = base64.b64encode(b"n" * 32).decode("ascii")
    unknown_response = harness.client.post("/v2/hub-activations", json=unknown)
    assert unknown_response.status_code == 409
    assert unknown_response.json()["error"]["code"] == "app_attest_initial_required"
    with harness.store.engine.connect() as conn:
        assert (
            conn.execute(select(func.count()).select_from(endpoints)).scalar_one() == 0
        )
        assert (
            conn.execute(select(func.count()).select_from(bind_tokens)).scalar_one()
            == 0
        )


def test_refresh_unknown_or_different_committed_key_has_frozen_terminal_error(
    harness,
) -> None:
    first, body = harness.register(installation=b"refresh-original-install")
    other_key = base64.b64encode(b"d" * 32).decode("ascii")
    other_body = harness.registration_body(installation=b"refresh-other-install")
    other_body["app_attest_key_id"] = other_key
    assert (
        harness.client.post("/v2/endpoints/register", json=other_body).status_code
        == 201
    )

    refresh = {
        "endpoint_id": first["endpoint_id"],
        "challenge": harness.challenge(),
        "app_attest_key_id": base64.b64encode(b"x" * 32).decode("ascii"),
        "assertion": "refresh-assertion-unknown",
        "apns_token": "cd" * 32,
        "environment": body["environment"],
        "bundle_id": body["bundle_id"],
        "preview_kem_pub": body["preview_kem_pub"],
        "installation_nonce": body["installation_nonce"],
    }
    unknown = harness.client.post("/v2/endpoints/token-refresh", json=refresh)
    assert unknown.status_code == 409
    assert unknown.json()["error"]["code"] == "app_attest_initial_required"

    refresh["challenge"] = harness.challenge()
    refresh["app_attest_key_id"] = other_key
    mismatch = harness.client.post("/v2/endpoints/token-refresh", json=refresh)
    assert mismatch.status_code == 409
    assert mismatch.json()["error"]["code"] == "installation_key_mismatch"


def test_ambiguous_and_transient_send_retries_use_stable_apns_identity(
    harness, monkeypatch
) -> None:
    clock = [time.time_ns() // 1_000_000]
    monkeypatch.setattr("push_gateway.app._now_ms", lambda: clock[0])
    registration, _ = harness.register()
    binding = harness.bind(registration["bind_token"])
    headers = {"Authorization": f"Bearer {binding['send_capability']}"}
    body = harness.send_body(notification_id="nid_retry_stable")

    # Simulate a process crash immediately after the reservation commit and
    # before any provider call. The next exact request resumes that receipt.
    crash_body = harness.send_body(notification_id="nid_crash_before_send")
    model = SendRequest.model_validate(crash_body)
    binding_record = harness.store.authenticate_binding(
        secret_hash(binding["send_capability"], harness.settings.capability_pepper)
    )
    assert binding_record is not None
    apns_id, fallback_collapse = delivery_identifiers(
        binding_id=binding_record.binding_id,
        notification_id=model.notification_id,
        pepper=harness.settings.capability_pepper,
    )
    canonical = json.dumps(
        model.model_dump(by_alias=True), sort_keys=True, separators=(",", ":")
    ).encode()
    harness.store.reserve_send(
        binding_id=binding_record.binding_id,
        notification_id_hash=opaque_hash(
            model.notification_id, harness.settings.capability_pepper
        ),
        request_hash=hashlib.sha256(canonical).digest(),
        apns_id=apns_id,
        collapse_id=fallback_collapse,
        now_ms=clock[0] - SEND_ATTEMPT_LEASE_MS - 1,
        expires_at_ms=model.expires_at_ms,
    )
    resumed = harness.client.post("/v2/send", headers=headers, json=crash_body)
    assert resumed.status_code == 200
    assert harness.apns.sent[-1]["apns_id"] == apns_id
    assert harness.apns.sent[-1]["collapse_id"] == fallback_collapse

    class FlakyAPNs:
        def __init__(self):
            self.calls = []
            self.outcomes = [RuntimeError("response lost"), APNsResult(True, 200)]

        async def send(self, **kwargs):
            self.calls.append(kwargs)
            outcome = self.outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome

    flaky = FlakyAPNs()
    harness.client.app.state  # keep the app reference alive for the monkeypatch below
    # The closure holds the original fake; mutate its method to emulate an
    # APNs-accepted/request-response-loss window, then a successful exact retry.
    original_send = harness.apns.send
    harness.apns.send = flaky.send
    try:
        first = harness.client.post("/v2/send", headers=headers, json=body)
        assert first.status_code == 502
        backed_off = harness.client.post("/v2/send", headers=headers, json=body)
        assert backed_off.status_code == 429
        assert backed_off.json()["error"]["code"] == "send_retry_backoff"
        assert backed_off.headers["retry-after"] == str(
            harness.settings.send_retry_base_seconds
        )
        clock[0] += harness.settings.send_retry_base_seconds * 1000
        second = harness.client.post("/v2/send", headers=headers, json=body)
        assert second.status_code == 200 and second.json()["accepted"] is True
    finally:
        harness.apns.send = original_send
    assert len(flaky.calls) == 2
    assert flaky.calls[0]["apns_id"] == flaky.calls[1]["apns_id"]
    assert flaky.calls[0]["collapse_id"] == flaky.calls[1]["collapse_id"]
    assert flaky.calls[0]["expires_at_ms"] == flaky.calls[1]["expires_at_ms"]
    assert flaky.calls[0]["payload"] == flaky.calls[1]["payload"]

    transient = harness.send_body(notification_id="nid_transient_500")
    harness.apns.result = APNsResult(False, 500)
    rejected = harness.client.post("/v2/send", headers=headers, json=transient)
    assert rejected.status_code == 502 and rejected.json()["accepted"] is False
    before_retry = len(harness.apns.sent)
    harness.apns.result = APNsResult(True, 200)
    backed_off = harness.client.post("/v2/send", headers=headers, json=transient)
    assert backed_off.status_code == 429
    assert len(harness.apns.sent) == before_retry
    clock[0] += harness.settings.send_retry_base_seconds * 1000
    accepted = harness.client.post("/v2/send", headers=headers, json=transient)
    assert accepted.status_code == 200 and accepted.json()["accepted"] is True
    assert len(harness.apns.sent) == before_retry + 1
    assert harness.apns.sent[-2]["apns_id"] == harness.apns.sent[-1]["apns_id"]
    assert harness.apns.sent[-2]["collapse_id"] == harness.apns.sent[-1]["collapse_id"]


def test_concurrent_exact_send_has_one_apns_attempt_and_terminal_receipt(
    harness,
) -> None:
    registration, _ = harness.register()
    binding = harness.bind(registration["bind_token"])
    headers = {"Authorization": f"Bearer {binding['send_capability']}"}
    body = harness.send_body(notification_id="nid_concurrent_exact")
    started = threading.Event()
    release = threading.Event()

    class BlockingAPNs:
        def __init__(self) -> None:
            self.calls = 0

        async def send(self, **_kwargs):
            self.calls += 1
            started.set()
            await asyncio.to_thread(release.wait, 5)
            return APNsResult(True, 200)

    blocker = BlockingAPNs()
    original_send = harness.apns.send
    harness.apns.send = blocker.send
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            first_future = pool.submit(
                harness.client.post, "/v2/send", headers=headers, json=body
            )
            assert started.wait(2)
            overlapping = harness.client.post("/v2/send", headers=headers, json=body)
            assert overlapping.status_code == 425
            assert overlapping.json()["error"]["code"] == "push_delivery_in_progress"
            release.set()
            first = first_future.result(timeout=5)
    finally:
        release.set()
        harness.apns.send = original_send

    assert first.status_code == 200 and first.json()["accepted"] is True
    assert blocker.calls == 1
    exact_retry = harness.client.post("/v2/send", headers=headers, json=body)
    assert exact_retry.status_code == 200
    assert exact_retry.json()["deduplicated"] is True
    assert exact_retry.json()["status"] == "sent"
    assert blocker.calls == 1


def test_retry_attempts_obey_backoff_and_durable_attempt_quotas(
    harness, monkeypatch
) -> None:
    settings = replace(
        harness.settings,
        max_sends_per_hour=2,
        max_sends_per_day=10,
        send_retry_base_seconds=1,
        send_retry_max_seconds=4,
    )
    store = DatabaseStore(settings)
    verifier = FakeVerifier()
    apns = FakeAPNs(APNsResult(False, 500, retryable=True))
    clock = [time.time_ns() // 1_000_000]
    monkeypatch.setattr("push_gateway.app._now_ms", lambda: clock[0])
    with TestClient(
        create_app(
            settings=settings,
            store=store,
            verifier=verifier,
            apns_sender=apns,
        )
    ) as client:
        local = PushHarness(client, store, verifier, apns, settings)
        registration, _ = local.register(installation=b"attempt-quota-install")
        binding = local.bind(registration["bind_token"])
        headers = {"Authorization": f"Bearer {binding['send_capability']}"}
        body = local.send_body(notification_id="nid_attempt_quota")
        body["expires_at_ms"] = clock[0] + 2 * 3_600_000

        first = client.post("/v2/send", headers=headers, json=body)
        assert first.status_code == 502
        immediate = client.post("/v2/send", headers=headers, json=body)
        assert immediate.status_code == 429
        assert immediate.json()["error"]["code"] == "send_retry_backoff"
        assert len(apns.sent) == 1

        clock[0] += 1_000
        second = client.post("/v2/send", headers=headers, json=body)
        assert second.status_code == 502
        clock[0] += 2_000
        exhausted = client.post("/v2/send", headers=headers, json=body)
        assert exhausted.status_code == 429
        assert exhausted.json()["error"]["code"] == "send_attempt_quota_exhausted"
        assert len(apns.sent) == 2
        with store.engine.connect() as conn:
            assert (
                conn.execute(
                    select(func.count()).select_from(push_send_attempts)
                ).scalar_one()
                == 2
            )

        # The hourly window can reopen without minting a new notification or
        # changing the APNs/collapse identities used for loss-safe retry.
        clock[0] += 3_600_001
        apns.result = APNsResult(True, 200)
        accepted = client.post("/v2/send", headers=headers, json=body)
        assert accepted.status_code == 200
        assert len(apns.sent) == 3
        assert len({call["apns_id"] for call in apns.sent}) == 1
        assert len({call["collapse_id"] for call in apns.sent}) == 1


def test_provider_retry_after_is_persisted_and_dominates_local_backoff(
    harness, monkeypatch
) -> None:
    settings = replace(
        harness.settings,
        send_retry_base_seconds=1,
        send_retry_max_seconds=4,
    )
    store = DatabaseStore(settings)
    verifier = FakeVerifier()
    apns = FakeAPNs(APNsResult(False, 503, retryable=True, retry_after_ms=5_000))
    clock = [time.time_ns() // 1_000_000]
    monkeypatch.setattr("push_gateway.app._now_ms", lambda: clock[0])
    with TestClient(
        create_app(
            settings=settings,
            store=store,
            verifier=verifier,
            apns_sender=apns,
        )
    ) as client:
        local = PushHarness(client, store, verifier, apns, settings)
        registration, _ = local.register(installation=b"provider-retry-after")
        binding = local.bind(registration["bind_token"])
        headers = {"Authorization": f"Bearer {binding['send_capability']}"}
        body = local.send_body(notification_id="nid_provider_retry_after")

        first = client.post("/v2/send", headers=headers, json=body)
        assert first.status_code == 502
        assert first.headers["retry-after"] == "5"
        with store.engine.connect() as conn:
            persisted = conn.execute(
                select(push_receipts.c.provider_retry_not_before_ms).where(
                    push_receipts.c.binding_id == binding["binding_id"]
                )
            ).scalar_one()
        assert persisted == clock[0] + 5_000

        clock[0] += 1_000
        early = client.post("/v2/send", headers=headers, json=body)
        assert early.status_code == 429
        assert early.json()["error"]["code"] == "send_retry_backoff"
        assert early.headers["retry-after"] == "4"
        assert len(apns.sent) == 1

        clock[0] += 4_000
        apns.result = APNsResult(True, 200)
        accepted = client.post("/v2/send", headers=headers, json=body)
        assert accepted.status_code == 200
        assert len(apns.sent) == 2


def test_retry_after_parser_accepts_seconds_and_http_date_with_safe_cap() -> None:
    assert (
        _retry_after_ms(
            httpx.Response(503, headers={"Retry-After": "120"}), now_seconds=1
        )
        == 120_000
    )
    assert (
        _retry_after_ms(
            httpx.Response(429, headers={"Retry-After": "999999999999999999999"}),
            now_seconds=1,
        )
        == MAX_APNS_RETRY_AFTER_MS
    )

    now = 1_700_000_000.0
    retry_at = datetime.datetime.fromtimestamp(now + 90, tz=datetime.timezone.utc)
    assert (
        _retry_after_ms(
            httpx.Response(
                503,
                headers={"Retry-After": format_datetime(retry_at, usegmt=True)},
            ),
            now_seconds=now,
        )
        == 90_000
    )
    past = datetime.datetime.fromtimestamp(now - 1, tz=datetime.timezone.utc)
    assert (
        _retry_after_ms(
            httpx.Response(
                503,
                headers={"Retry-After": format_datetime(past, usegmt=True)},
            ),
            now_seconds=now,
        )
        == 0
    )
    assert (
        _retry_after_ms(
            httpx.Response(503, headers={"Retry-After": "not-a-delay"}),
            now_seconds=now,
        )
        is None
    )


def test_apns_client_makes_one_provider_call_per_durable_attempt(harness) -> None:
    calls = 0

    def handler(_request: httpx.Request) -> httpx.Response:
        nonlocal calls
        calls += 1
        return httpx.Response(
            503,
            headers={"Retry-After": "17"},
            json={"reason": "ServiceUnavailable"},
        )

    async def scenario() -> APNsResult:
        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
            sender = APNsClient(
                replace(
                    harness.settings,
                    apns_key_pem="unused-in-test",
                    apns_key_id="KEYID",
                    apns_team_id="TEAMID",
                ),
                client=client,
            )
            sender._provider_token = "precomputed-test-token"
            sender._issued_at = time.time()
            return await sender.send(
                endpoint=APNsEndpoint(
                    token="ab" * 32,
                    environment="production",
                    bundle_id="ai.hermes.app",
                ),
                payload=b"{}",
                collapse_id="collapse",
                apns_id="00000000-0000-0000-0000-000000000001",
                expires_at_ms=time.time_ns() // 1_000_000 + 60_000,
            )

    result = asyncio.run(scenario())
    assert result.retryable is True and result.status == 503
    assert result.retry_after_ms == 17_000
    assert calls == 1


def test_expired_attempt_lease_is_fenced_from_overwriting_newer_success(
    harness,
) -> None:
    registration, _ = harness.register()
    binding = harness.bind(registration["bind_token"])
    binding_record = harness.store.authenticate_binding(
        secret_hash(binding["send_capability"], harness.settings.capability_pepper)
    )
    assert binding_record is not None
    notification_hash = b"n" * 32
    request_hash = b"r" * 32
    first = harness.store.reserve_send(
        binding_id=binding_record.binding_id,
        notification_id_hash=notification_hash,
        request_hash=request_hash,
        apns_id="00000000-0000-0000-0000-000000000001",
        collapse_id="stable-collapse",
        now_ms=1_000,
        expires_at_ms=1_000_000,
    )
    assert first.attempt_token is not None
    replacement = harness.store.reserve_send(
        binding_id=binding_record.binding_id,
        notification_id_hash=notification_hash,
        request_hash=request_hash,
        apns_id="00000000-0000-0000-0000-000000000001",
        collapse_id="stable-collapse",
        now_ms=1_000 + SEND_ATTEMPT_LEASE_MS + 1,
        expires_at_ms=1_000_000,
    )
    assert replacement.attempt_token is not None
    assert replacement.attempt_token != first.attempt_token
    assert harness.store.complete_send(
        binding_id=binding_record.binding_id,
        notification_id_hash=notification_hash,
        delivery_status="sent",
        provider_status=200,
        prune_endpoint=False,
        now_ms=1_000 + SEND_ATTEMPT_LEASE_MS + 2,
        attempt_token=replacement.attempt_token,
    )
    assert not harness.store.complete_send(
        binding_id=binding_record.binding_id,
        notification_id_hash=notification_hash,
        delivery_status="retryable",
        provider_status=503,
        prune_endpoint=False,
        now_ms=1_000 + SEND_ATTEMPT_LEASE_MS + 3,
        attempt_token=first.attempt_token,
    )
    with harness.store.engine.connect() as conn:
        row = conn.execute(
            select(push_receipts.c.status, push_receipts.c.provider_status).where(
                push_receipts.c.binding_id == binding_record.binding_id,
                push_receipts.c.notification_id_hash == notification_hash,
            )
        ).one()
    assert row == ("sent", 200)
