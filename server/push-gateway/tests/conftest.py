from __future__ import annotations

import base64
from dataclasses import dataclass, field
import secrets

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient

from push_gateway.apns import APNsResult
from push_gateway.app import create_app
from push_gateway.attestation import AttestationIdentity
from push_gateway.crypto import b64url_encode
from push_gateway.settings import Settings
from push_gateway.storage import DatabaseStore


@dataclass
class FakeVerifier:
    counter: int = 0
    next_counter: int | None = None
    calls: list[dict] = field(default_factory=list)

    def verify(self, **kwargs) -> AttestationIdentity:
        self.calls.append(kwargs)
        if self.next_counter is not None:
            counter = self.next_counter
            self.next_counter = None
        else:
            self.counter += 1
            counter = self.counter
        public = kwargs["existing_public_key_der"] or b"fake-app-attest-public-key"
        return AttestationIdentity(public_key_der=public, counter=counter)


@dataclass
class FakeAPNs:
    result: APNsResult = APNsResult(True, 200)
    sent: list[dict] = field(default_factory=list)

    async def send(self, **kwargs) -> APNsResult:
        self.sent.append(kwargs)
        return self.result


@dataclass
class PushHarness:
    client: TestClient
    store: DatabaseStore
    verifier: FakeVerifier
    apns: FakeAPNs
    settings: Settings

    def challenge(self) -> str:
        response = self.client.get("/v2/attest/challenge")
        assert response.status_code == 200
        return response.json()["challenge"]

    def registration_body(
        self,
        *,
        challenge: str | None = None,
        token: str = "ab" * 32,
        installation: bytes = b"installation-0001",
    ) -> dict:
        return {
            "challenge": challenge or self.challenge(),
            "app_attest_key_id": base64.b64encode(b"k" * 32).decode("ascii"),
            "assertion": "assertion-payload-0001",
            "attestation": "attestation-data-0001",
            "apns_token": token,
            "environment": "production",
            "bundle_id": "ai.hermes.app",
            "preview_kem_pub": b64url_encode(bytes(range(32))),
            "installation_nonce": b64url_encode(installation),
        }

    def register(self, **kwargs) -> tuple[dict, dict]:
        body = self.registration_body(**kwargs)
        response = self.client.post("/v2/endpoints/register", json=body)
        assert response.status_code == 201, response.text
        return response.json(), body

    def bind(self, bind_token: str, classes: list[str] | None = None) -> dict:
        body = {
            "bind_token": bind_token,
            "exchange_id": "xch_" + b64url_encode(secrets.token_bytes(16)),
        }
        if classes is not None:
            body["requested_classes"] = classes
        response = self.client.post("/v2/bindings/exchange", json=body)
        assert response.status_code == 201, response.text
        return response.json()

    @staticmethod
    def send_body(
        *, notification_id: str = "nid_test", notification_class: str = "update"
    ) -> dict:
        import time

        return {
            "v": 2,
            "class": notification_class,
            "notification_id": notification_id,
            "preview_enc": b64url_encode(bytes(range(32))),
            "preview_ct": b64url_encode(b"ciphertext-with-auth-tag"),
            "collapse_id": None,
            "expires_at_ms": time.time_ns() // 1_000_000 + 60_000,
            "sound": True,
        }


@pytest.fixture
def harness() -> PushHarness:
    settings = Settings(
        database_url="sqlite:///:memory:",
        token_master_key=b"m" * 32,
        capability_pepper=b"p" * 32,
        apple_app_id="TEAM.ai.hermes.app",
        require_apns=False,
        hub_activation_private_key=Ed25519PrivateKey.generate().private_bytes_raw(),
    )
    store = DatabaseStore(settings)
    verifier = FakeVerifier()
    apns = FakeAPNs()
    with TestClient(
        create_app(settings=settings, store=store, verifier=verifier, apns_sender=apns)
    ) as client:
        yield PushHarness(client, store, verifier, apns, settings)
