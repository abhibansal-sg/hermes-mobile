"""Local, content-canary evidence for the HRP/2 trust boundaries.

These tests use only loopback/in-process transports and the existing fake App
Attest/APNs boundaries. They exercise Python Agent Relay, Hub, and Push Gateway
runtime APIs; they deliberately do not claim that Swift executed here.
"""

from __future__ import annotations

import base64
import json
import logging
import secrets
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

import httpx
import pytest
from sqlalchemy import update


pytest.importorskip("pyhpke")
pytest.importorskip("sqlalchemy")
pytest.importorskip("fastapi")

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "relay"))
sys.path.insert(0, str(ROOT / "server" / "relay-hub"))
sys.path.insert(0, str(ROOT / "server" / "push-gateway"))

from cryptography.hazmat.primitives.asymmetric.ed25519 import (  # noqa: E402
    Ed25519PrivateKey,
)
from fastapi.testclient import TestClient  # noqa: E402
from hermes_relay.v2.crypto import (  # noqa: E402
    decrypt_notification_preview,
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
)
from hermes_relay.v2.identity import load_or_create_identity  # noqa: E402
from hermes_relay.v2.notification_sender import NotificationSender  # noqa: E402
from hermes_relay.v2.protection import FilePermissionFallbackProtector  # noqa: E402
from hermes_relay.v2.protocol import (  # noqa: E402
    NotificationClass,
    NotificationPreview,
    NotificationSendDescriptor,
    b64url_encode,
)
from hermes_relay.v2.push_client import (  # noqa: E402
    PushGatewayClient,
    PushGatewayConfig,
)
from hermes_relay.v2.storage import RelayStorage  # noqa: E402
from push_gateway.apns import APNsResult  # noqa: E402
from push_gateway.app import create_app as create_push_app  # noqa: E402
from push_gateway.attestation import AttestationIdentity  # noqa: E402
from push_gateway.settings import Settings as PushSettings  # noqa: E402
from push_gateway.storage import DatabaseStore as PushStore  # noqa: E402
from relay_hub.app import create_app as create_hub_app  # noqa: E402
from relay_hub.crypto import (  # noqa: E402
    b64url_encode as hub_b64url_encode,
    envelope_signature_input,
    grant_signature_input,
    now_milliseconds,
    request_signature_input,
)
from relay_hub.models import GrantRequest, OuterEnvelope  # noqa: E402
from relay_hub.settings import Settings as HubSettings  # noqa: E402
from relay_hub.storage import DatabaseStore as HubStore, routes  # noqa: E402


PROMPT_CANARY = "PROMPT_CANARY_71c9b8a63f844829"
PREVIEW_CANARY = "PREVIEW_CANARY_b6a0cb2cce2a4d81"
SESSION_CANARY = "SESSION_CANARY_397e4bcd938a4cd0"
PROVIDER_CANARY = "PROVIDER_CANARY_723b37e8ff8b482a"


def _assert_file_omits(path: Path, *values: str) -> None:
    persisted = path.read_bytes()
    for value in values:
        assert value.encode("utf-8") not in persisted, path


def _assert_files_omit(directory: Path, *values: str) -> None:
    for path in directory.rglob("*"):
        if path.is_file():
            _assert_file_omits(path, *values)


class _FailingAgentPush:
    async def send(self, _descriptor, *, send_capability):
        assert len(send_capability) == 32
        raise ConnectionError(f"{PROMPT_CANARY}|{PREVIEW_CANARY}")


@pytest.mark.asyncio
async def test_agent_relay_failure_keeps_content_canaries_out_of_logs(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    store = RelayStorage(
        tmp_path / "agent-log-canary",
        credential_protector=FilePermissionFallbackProtector(),
    )
    try:
        identity = load_or_create_identity(store)
        kem = generate_x25519_key_pair()
        signing = generate_ed25519_key_pair()
        preview_keys = generate_x25519_key_pair()
        device = store.register_device(
            device_id="dev_agent_log_canary",
            name="Canary phone",
            route="rte_agent_log_canary",
            kem_public=kem.public_key,
            sign_public=signing.public_key,
            preview_public=preview_keys.public_key,
        )
        store.activate_device(device.device_id)
        store.store_push_binding(
            device_id=device.device_id,
            binding_id="pb_agent_log_canary",
            send_capability=b"c" * 32,
            allowed_classes=["update"],
        )
        preview = NotificationPreview(
            notification_id="nid_agent_log_canary",
            notification_class=NotificationClass.UPDATE,
            title=PROMPT_CANARY,
            body=PREVIEW_CANARY,
            thread_token="thr_agent_log_canary",
            expires_at_ms=time.time_ns() // 1_000_000 + 60_000,
        )
        caplog.set_level(logging.DEBUG)

        result = await NotificationSender(
            store, identity, _FailingAgentPush()
        ).send_to_device(
            device.device_id,
            preview,
            session_id=SESSION_CANARY,
        )

        assert result == {
            "suppressed": False,
            "accepted": False,
            "queued": True,
            "error": "push_request_ambiguous",
        }
        row = store.notification_outbox(device_id=device.device_id)[0]
        assert row.state == "pending"
        assert all(
            canary not in str(row.descriptor)
            for canary in (PROMPT_CANARY, PREVIEW_CANARY, SESSION_CANARY)
        )
        assert all(
            canary not in caplog.text
            for canary in (PROMPT_CANARY, PREVIEW_CANARY, SESSION_CANARY)
        )
        _assert_files_omit(
            tmp_path / "agent-log-canary",
            PROMPT_CANARY,
            PREVIEW_CANARY,
        )
    finally:
        store.close()


def _hub_enroll(
    client: TestClient, route_type: str
) -> tuple[str, Ed25519PrivateKey]:
    key = Ed25519PrivateKey.generate()
    response = client.post(
        "/v2/enroll/provisional",
        json={
            "enrollment_id": "enr_" + hub_b64url_encode(secrets.token_bytes(16)),
            "route_type": route_type,
            "auth_public_key": hub_b64url_encode(
                key.public_key().public_bytes_raw()
            ),
        },
    )
    assert response.status_code == 201, response.text
    route = response.json()["route_id"]
    activated = client.post(
        "/v2/enroll/activate",
        headers={"X-Hermes-Enrollment-Token": "operator-test-token"},
        json={"route_id": route, "activation_token": None},
    )
    assert activated.status_code == 200, activated.text
    return route, key


def _hub_signed_headers(
    route: str,
    key: Ed25519PrivateKey,
    *,
    method: str,
    path: str,
    body: bytes,
) -> dict[str, str]:
    timestamp = now_milliseconds()
    nonce = secrets.token_bytes(16)
    signature = key.sign(
        request_signature_input(
            method=method,
            path=path,
            route_id=route,
            timestamp_ms=timestamp,
            nonce=nonce,
            body=body,
        )
    )
    return {
        "Content-Type": "application/json",
        "X-Hermes-Route": route,
        "X-Hermes-Timestamp": str(timestamp),
        "X-Hermes-Nonce": hub_b64url_encode(nonce),
        "X-Hermes-Signature": hub_b64url_encode(signature),
    }


def test_relay_hub_accept_log_is_content_blind(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    settings = HubSettings(
        database_url=f"sqlite:///{tmp_path / 'hub-canary.sqlite3'}",
        operator_enrollment_token="operator-test-token",
    )
    store = HubStore(settings)
    with TestClient(create_hub_app(settings=settings, store=store)) as client:
        agent_route, agent_key = _hub_enroll(client, "agent")
        device_route, _device_key = _hub_enroll(client, "device")
        # This content-blindness test starts from an already-paired device.
        # The public offer/confirmation flow is exercised independently by
        # the Agent-to-Hub E2E and Hub pairing suites.
        with store.engine.begin() as connection:
            connection.execute(
                update(routes)
                .where(routes.c.route_id == device_route)
                .values(owner_route=agent_route)
            )
        unsigned_grant = GrantRequest(
            grant_id="grt_" + hub_b64url_encode(secrets.token_bytes(24)),
            issuer_route=agent_route,
            source_route=agent_route,
            destination_route=device_route,
            permissions=["send", "receive"],
            expires_at_ms=None,
            issuer_signature=hub_b64url_encode(bytes(64)),
        )
        grant = unsigned_grant.model_copy(
            update={
                "issuer_signature": hub_b64url_encode(
                    agent_key.sign(grant_signature_input(unsigned_grant))
                )
            }
        )
        grant_body = json.dumps(
            grant.model_dump(), sort_keys=True, separators=(",", ":")
        ).encode("utf-8")
        grant_response = client.post(
            "/v2/grants",
            headers=_hub_signed_headers(
                agent_route,
                agent_key,
                method="POST",
                path="/v2/grants",
                body=grant_body,
            ),
            content=grant_body,
        )
        assert grant_response.status_code == 201, grant_response.text

        ciphertext_canary = hub_b64url_encode(
            (PROMPT_CANARY + "|" + PREVIEW_CANARY).encode("utf-8")
        )
        unsigned_envelope = OuterEnvelope.model_validate(
            {
                "v": 2,
                "src": agent_route,
                "dst": device_route,
                "mid": hub_b64url_encode(secrets.token_bytes(16)),
                "class": "state",
                "expires_at_ms": now_milliseconds() + 60_000,
                "recipient_key_generation": 1,
                # This identifier is deliberately present as raw request JSON.
                "collapse": SESSION_CANARY,
                "enc": hub_b64url_encode(secrets.token_bytes(32)),
                # The Hub decodes these content-canary bytes to size them but
                # must never include them in a runtime log record.
                "ct": ciphertext_canary,
                "sig": hub_b64url_encode(bytes(64)),
            }
        )
        envelope = unsigned_envelope.model_copy(
            update={
                "sig": hub_b64url_encode(
                    agent_key.sign(envelope_signature_input(unsigned_envelope))
                )
            }
        )
        caplog.set_level(logging.INFO, logger="relay_hub")
        accepted = client.post(
            "/v2/messages", json=envelope.model_dump(by_alias=True)
        )
        assert accepted.status_code == 202, accepted.text
        assert "opaque envelope accepted" in caplog.text
        assert all(
            canary not in caplog.text
            for canary in (
                PROMPT_CANARY,
                PREVIEW_CANARY,
                SESSION_CANARY,
                ciphertext_canary,
            )
        )


@dataclass
class _FakeAppAttest:
    calls: list[dict] = field(default_factory=list)

    def verify(self, **kwargs) -> AttestationIdentity:
        self.calls.append(kwargs)
        return AttestationIdentity(
            public_key_der=kwargs["existing_public_key_der"]
            or b"fake-app-attest-public-key",
            counter=len(self.calls),
        )


@dataclass
class _FakeAPNs:
    token: str
    sent: list[dict] = field(default_factory=list)
    fail_with_canary: bool = False

    async def send(self, **kwargs) -> APNsResult:
        self.sent.append(kwargs)
        if self.fail_with_canary:
            raise RuntimeError(
                f"https://api.push.apple/3/device/{self.token}/{PROVIDER_CANARY}"
            )
        return APNsResult(True, 200)


@pytest.mark.asyncio
async def test_real_local_agent_to_push_notification_path_and_log_canaries(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """Exercise encrypted Agent storage/send through the real Push ASGI API."""

    apns_token = "ab" * 32
    verifier = _FakeAppAttest()
    fake_apns = _FakeAPNs(apns_token)
    push_settings = PushSettings(
        database_url=f"sqlite:///{tmp_path / 'push-canary.sqlite3'}",
        token_master_key=b"m" * 32,
        capability_pepper=b"p" * 32,
        apple_app_id="TEAM.ai.hermes.app",
        require_apns=False,
    )
    push_store = PushStore(push_settings)
    push_app = create_push_app(
        settings=push_settings,
        store=push_store,
        verifier=verifier,
        apns_sender=fake_apns,
    )
    transport = httpx.ASGITransport(app=push_app)
    http = httpx.AsyncClient(transport=transport, base_url="http://push.local")
    agent_store = RelayStorage(
        tmp_path / "agent-push-e2e",
        credential_protector=FilePermissionFallbackProtector(),
    )
    try:
        caplog.set_level(logging.INFO)
        identity = load_or_create_identity(agent_store)
        device_kem = generate_x25519_key_pair()
        device_signing = generate_ed25519_key_pair()
        preview_keys = generate_x25519_key_pair()
        device = agent_store.register_device(
            device_id="dev_local_push_e2e",
            name="Local integration phone",
            route="rte_local_push_e2e",
            kem_public=device_kem.public_key,
            sign_public=device_signing.public_key,
            preview_public=preview_keys.public_key,
        )

        challenge = await http.get("/v2/attest/challenge")
        assert challenge.status_code == 200
        registration = await http.post(
            "/v2/endpoints/register",
            json={
                "challenge": challenge.json()["challenge"],
                "app_attest_key_id": base64.b64encode(b"k" * 32).decode("ascii"),
                "assertion": "fake-assertion-payload",
                "attestation": "fake-attestation-data",
                "apns_token": apns_token,
                "environment": "production",
                "bundle_id": "ai.hermes.app",
                "preview_kem_pub": b64url_encode(preview_keys.public_key),
                "installation_nonce": b64url_encode(b"local-installation-nonce"),
            },
        )
        assert registration.status_code == 201, registration.text
        assert len(verifier.calls) == 1

        push_client = PushGatewayClient(
            PushGatewayConfig(
                "http://127.0.0.1",
                allow_insecure_local=True,
            ),
            http_client=http,
        )
        sender = NotificationSender(agent_store, identity, push_client)
        binding_id = await sender.bind_device(
            device.device_id, registration.json()["bind_token"]
        )
        assert binding_id.startswith("pb_")
        agent_store.activate_device(device.device_id)

        preview = NotificationPreview(
            notification_id="nid_local_push_e2e",
            notification_class=NotificationClass.UPDATE,
            title=PROMPT_CANARY,
            body=PREVIEW_CANARY,
            thread_token="thr_local_push_e2e",
            expires_at_ms=time.time_ns() // 1_000_000 + 60_000,
        )
        delivered = await sender.send_to_device(
            device.device_id,
            preview,
            session_id=SESSION_CANARY,
            collapse_id="collapse_local_push_e2e",
            dedupe_key="local-push-e2e-success",
        )
        assert delivered["accepted"] is True
        assert delivered["state"] == "sent"
        assert len(fake_apns.sent) == 1

        row = agent_store.notification_outbox_record(
            device.device_id, preview.notification_id
        )
        assert row is not None and row.state == "sent"
        descriptor = NotificationSendDescriptor.from_dict(row.descriptor)
        assert (
            decrypt_notification_preview(
                descriptor,
                recipient_private_key=preview_keys.private_key,
                sender_public_key=identity.kem_public,
                now_ms=time.time_ns() // 1_000_000,
            )
            == preview
        )
        apns_payload = fake_apns.sent[0]["payload"]
        assert all(
            canary.encode("utf-8") not in apns_payload
            for canary in (PROMPT_CANARY, PREVIEW_CANARY, SESSION_CANARY)
        )
        assert "opaque push attempted" in caplog.text

        # The provider exception deliberately contains both the APNs token and
        # a raw canary. Push logs only a typed, content-free failure record.
        fake_apns.fail_with_canary = True
        failed_preview = NotificationPreview(
            notification_id="nid_local_push_failure",
            notification_class=NotificationClass.UPDATE,
            title=PROMPT_CANARY,
            body=PROVIDER_CANARY,
            thread_token="thr_local_push_failure",
            expires_at_ms=time.time_ns() // 1_000_000 + 60_000,
        )
        queued = await sender.send_to_device(
            device.device_id,
            failed_preview,
            session_id=SESSION_CANARY,
            dedupe_key="local-push-e2e-failure",
        )
        assert queued["queued"] is True
        assert "opaque push delivery failed before provider response" in caplog.text
        assert all(
            value not in caplog.text
            for value in (
                PROMPT_CANARY,
                PREVIEW_CANARY,
                SESSION_CANARY,
                PROVIDER_CANARY,
                apns_token,
            )
        )

        # The Push database stores hashes/ciphertext/metadata, never the inner
        # preview. This query covers actual persisted values rather than schema
        # names alone.
        for database_path in tmp_path.glob("push-canary.sqlite3*"):
            if database_path.is_file():
                _assert_file_omits(
                    database_path,
                    PROMPT_CANARY,
                    PREVIEW_CANARY,
                    SESSION_CANARY,
                    PROVIDER_CANARY,
                    apns_token,
                )
        _assert_files_omit(
            tmp_path / "agent-push-e2e",
            PROMPT_CANARY,
            PREVIEW_CANARY,
            PROVIDER_CANARY,
        )
    finally:
        agent_store.close()
        await http.aclose()
