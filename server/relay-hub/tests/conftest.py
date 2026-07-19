from __future__ import annotations

import json
import secrets
from dataclasses import dataclass

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient
from sqlalchemy import update

from relay_hub.app import create_app
from relay_hub.crypto import (
    b64url_encode,
    envelope_signature_input,
    grant_signature_input,
    now_milliseconds,
    request_signature_input,
)
from relay_hub.models import GrantRequest, OuterEnvelope
from relay_hub.settings import Settings
from relay_hub.storage import DatabaseStore, routes


@dataclass
class HubHarness:
    client: TestClient
    store: DatabaseStore
    settings: Settings

    def enroll(
        self,
        route_type: str = "agent",
        *,
        owner_route: str | None = None,
    ) -> tuple[str, Ed25519PrivateKey]:
        key = Ed25519PrivateKey.generate()
        response = self.client.post(
            "/v2/enroll/provisional",
            json={
                "enrollment_id": "enr_" + b64url_encode(secrets.token_bytes(16)),
                "route_type": route_type,
                "auth_public_key": b64url_encode(key.public_key().public_bytes_raw()),
            },
        )
        assert response.status_code == 201, response.text
        route_id = response.json()["route_id"]
        activated = self.client.post(
            "/v2/enroll/activate",
            headers={"X-Hermes-Enrollment-Token": "operator-test-token"},
            json={"route_id": route_id, "activation_token": None},
        )
        assert activated.status_code == 200, activated.text
        if owner_route is not None:
            assert route_type == "device"
            # Basic mailbox tests use an already-paired device fixture. The
            # pairing suite independently proves the public pending-route flow.
            with self.store.engine.begin() as connection:
                connection.execute(
                    update(routes)
                    .where(routes.c.route_id == route_id)
                    .values(owner_route=owner_route)
                )
        return route_id, key

    @staticmethod
    def signed_headers(
        route_id: str,
        key: Ed25519PrivateKey,
        *,
        method: str,
        path: str,
        body: bytes = b"",
        nonce: bytes | None = None,
    ) -> dict[str, str]:
        timestamp = now_milliseconds()
        nonce = nonce or secrets.token_bytes(16)
        signature = key.sign(
            request_signature_input(
                method=method,
                path=path,
                route_id=route_id,
                timestamp_ms=timestamp,
                nonce=nonce,
                body=body,
            )
        )
        return {
            "X-Hermes-Route": route_id,
            "X-Hermes-Timestamp": str(timestamp),
            "X-Hermes-Nonce": b64url_encode(nonce),
            "X-Hermes-Signature": b64url_encode(signature),
        }

    def signed_request(
        self,
        method: str,
        path: str,
        route_id: str,
        key: Ed25519PrivateKey,
        payload: dict | None = None,
        *,
        nonce: bytes | None = None,
    ):
        body = (
            json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
            if payload is not None
            else b""
        )
        headers = self.signed_headers(
            route_id, key, method=method, path=path, body=body, nonce=nonce
        )
        if payload is not None:
            headers["Content-Type"] = "application/json"
        return self.client.request(method, path, headers=headers, content=body)

    def grant(
        self,
        *,
        issuer_route: str,
        issuer_key: Ed25519PrivateKey,
        source_route: str,
        destination_route: str,
    ) -> GrantRequest:
        placeholder = GrantRequest(
            grant_id="grt_" + b64url_encode(secrets.token_bytes(24)),
            issuer_route=issuer_route,
            source_route=source_route,
            destination_route=destination_route,
            permissions=["send", "receive"],
            expires_at_ms=None,
            issuer_signature=b64url_encode(bytes(64)),
        )
        grant = placeholder.model_copy(
            update={"issuer_signature": b64url_encode(issuer_key.sign(grant_signature_input(placeholder)))}
        )
        response = self.signed_request(
            "POST",
            "/v2/grants",
            issuer_route,
            issuer_key,
            grant.model_dump(),
        )
        assert response.status_code == 201, response.text
        return grant

    @staticmethod
    def envelope(
        *,
        source_route: str,
        destination_route: str,
        source_key: Ed25519PrivateKey,
        message_class: str = "state",
        mid: str | None = None,
        ciphertext: bytes | None = None,
        collapse: str | None = None,
        expires_at_ms: int | None = None,
    ) -> OuterEnvelope:
        placeholder = OuterEnvelope.model_validate(
            {
                "v": 2,
                "src": source_route,
                "dst": destination_route,
                "mid": mid or b64url_encode(secrets.token_bytes(16)),
                "class": message_class,
                "expires_at_ms": expires_at_ms or now_milliseconds() + 60_000,
                "recipient_key_generation": 1,
                "collapse": collapse,
                "enc": b64url_encode(secrets.token_bytes(32)),
                "ct": b64url_encode(ciphertext or secrets.token_bytes(32)),
                "sig": b64url_encode(bytes(64)),
            }
        )
        return placeholder.model_copy(
            update={"sig": b64url_encode(source_key.sign(envelope_signature_input(placeholder)))}
        )


@pytest.fixture
def harness() -> HubHarness:
    settings = Settings(
        database_url="sqlite:///:memory:",
        operator_enrollment_token="operator-test-token",
    )
    store = DatabaseStore(settings)
    with TestClient(create_app(settings=settings, store=store)) as client:
        yield HubHarness(client, store, settings)
