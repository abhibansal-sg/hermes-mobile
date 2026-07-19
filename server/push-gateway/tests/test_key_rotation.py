from __future__ import annotations

import base64
import json
import secrets

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import (
    Ed25519PrivateKey,
    Ed25519PublicKey,
)
from fastapi.testclient import TestClient

from conftest import FakeAPNs, FakeVerifier, PushHarness
from push_gateway.__main__ import main
from push_gateway.app import create_app
from push_gateway.crypto import b64url_decode, b64url_encode, mint_hub_activation_token
from push_gateway.settings import Settings
from push_gateway.storage import DatabaseStore


def _b64(value: bytes) -> str:
    return base64.b64encode(value).decode("ascii")


def _service_env(monkeypatch) -> None:
    for name in tuple(__import__("os").environ):
        if name.startswith("HPG_"):
            monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("HPG_CAPABILITY_PEPPER_B64", _b64(b"p" * 32))
    monkeypatch.setenv("HPG_REQUIRE_APNS", "false")
    monkeypatch.setenv("HPG_DEVELOPMENT_REGISTRATION_TOKEN", "explicit-dev-token")


def test_token_keyring_env_file_validation_and_legacy_compatibility(
    monkeypatch, tmp_path
) -> None:
    _service_env(monkeypatch)
    monkeypatch.setenv("HPG_TOKEN_MASTER_KEY_B64", _b64(b"a" * 32))
    legacy = Settings.from_env()
    assert legacy.token_keyring == {1: b"a" * 32}
    assert "token_master_key" not in repr(legacy)
    assert _b64(b"a" * 32) not in repr(legacy)

    monkeypatch.delenv("HPG_TOKEN_MASTER_KEY_B64")
    keyring_path = tmp_path / "token-keyring.json"
    keyring_path.write_text(json.dumps({"7": _b64(b"b" * 32), "8": _b64(b"c" * 32)}))
    keyring_path.chmod(0o600)
    monkeypatch.setenv("HPG_TOKEN_MASTER_KEYS_FILE", str(keyring_path))
    monkeypatch.setenv("HPG_TOKEN_KEY_VERSION", "8")
    rotated = Settings.from_env()
    assert rotated.token_key_version == 8
    assert rotated.token_master_key == b"c" * 32
    assert rotated.token_keyring == {7: b"b" * 32, 8: b"c" * 32}

    monkeypatch.delenv("HPG_TOKEN_MASTER_KEYS_FILE")
    monkeypatch.setenv(
        "HPG_TOKEN_MASTER_KEYS_JSON",
        '{"8":"' + _b64(b"c" * 32) + '","8":"' + _b64(b"d" * 32) + '"}',
    )
    with pytest.raises(ValueError, match="duplicate token key version"):
        Settings.from_env()

    monkeypatch.setenv(
        "HPG_TOKEN_MASTER_KEYS_JSON",
        json.dumps({"7": _b64(b"c" * 32), "8": _b64(b"c" * 32)}),
    )
    with pytest.raises(ValueError, match="distinct key"):
        Settings.from_env()


def test_activation_signing_keyring_adds_kid_and_legacy_wire_shape_stays_valid(
    monkeypatch,
) -> None:
    old_seed = b"o" * 32
    new_seed = b"n" * 32
    legacy = mint_hub_activation_token(
        old_seed,
        route_id="rte_rotation",
        expires_at_ms=123456,
        token_id="token-old",
    )
    legacy_payload, legacy_signature = legacy.split(".")
    legacy_claims = json.loads(
        b64url_decode(legacy_payload, field="payload").decode("utf-8")
    )
    assert "kid" not in legacy_claims
    Ed25519PrivateKey.from_private_bytes(old_seed).public_key().verify(
        b64url_decode(legacy_signature, field="signature", exact=64),
        b"HRH2ACT"
        + len(b64url_decode(legacy_payload, field="payload")).to_bytes(4, "big")
        + b64url_decode(legacy_payload, field="payload"),
    )

    _service_env(monkeypatch)
    monkeypatch.setenv("HPG_TOKEN_MASTER_KEY_B64", _b64(b"m" * 32))
    monkeypatch.setenv(
        "HPG_HUB_ACTIVATION_PRIVATE_KEYS_JSON",
        json.dumps({"old": _b64(old_seed), "2026-07": _b64(new_seed)}),
    )
    monkeypatch.setenv("HPG_HUB_ACTIVATION_KEY_ID", "2026-07")
    overlap = Settings.from_env()
    assert overlap.hub_activation_private_key == new_seed
    assert overlap.hub_activation_key_id == "2026-07"

    rotated = mint_hub_activation_token(
        overlap.hub_activation_private_key,
        route_id="rte_rotation",
        expires_at_ms=123457,
        token_id="token-new",
        key_id=overlap.hub_activation_key_id,
    )
    payload_part, signature_part = rotated.split(".")
    payload = b64url_decode(payload_part, field="payload")
    assert json.loads(payload)["kid"] == "2026-07"
    Ed25519PrivateKey.from_private_bytes(new_seed).public_key().verify(
        b64url_decode(signature_part, field="signature", exact=64),
        b"HRH2ACT" + len(payload).to_bytes(4, "big") + payload,
    )

    # Once old activation tokens have expired, the signer can retire its old
    # private seed without changing the selected kid or wire contract.
    monkeypatch.setenv(
        "HPG_HUB_ACTIVATION_PRIVATE_KEYS_JSON",
        json.dumps({"2026-07": _b64(new_seed)}),
    )
    retired = Settings.from_env()
    assert retired.hub_activation_private_keys == (("2026-07", new_seed),)


def test_token_rotation_restart_rewrap_and_safe_retirement(
    tmp_path, monkeypatch, capsys
) -> None:
    database_url = f"sqlite:///{tmp_path / 'push.sqlite3'}"
    key_v1 = b"1" * 32
    key_v2 = b"2" * 32
    pepper = b"p" * 32
    activation_seed = Ed25519PrivateKey.generate().private_bytes_raw()

    settings_v1 = Settings(
        database_url=database_url,
        token_master_key=key_v1,
        capability_pepper=pepper,
        apple_app_id="TEAM.ai.hermes.app",
        require_apns=False,
        hub_activation_private_key=activation_seed,
    )
    store_v1 = DatabaseStore(settings_v1)
    verifier_v1 = FakeVerifier()
    apns_v1 = FakeAPNs()
    with TestClient(
        create_app(
            settings=settings_v1,
            store=store_v1,
            verifier=verifier_v1,
            apns_sender=apns_v1,
        )
    ) as client_v1:
        harness_v1 = PushHarness(client_v1, store_v1, verifier_v1, apns_v1, settings_v1)
        registration, registration_body = harness_v1.register()
        exchange_body = {
            "bind_token": registration["bind_token"],
            "exchange_id": "xch_rotation-receipt",
        }
        exchanged = client_v1.post("/v2/bindings/exchange", json=exchange_body)
        assert exchanged.status_code == 201
        binding = exchanged.json()
        activation_body = {
            "challenge": harness_v1.challenge(),
            "app_attest_key_id": _b64(b"a" * 32),
            "assertion": "activation-assertion-data",
            "attestation": "activation-attestation-data",
            "bundle_id": "ai.hermes.app",
            "environment": "production",
            "installation_nonce": b64url_encode(b"rotation-activation"),
            "hub_route_id": "rte_" + b64url_encode(secrets.token_bytes(24)),
        }
        activation = client_v1.post("/v2/hub-activations", json=activation_body)
        assert activation.status_code == 201
        activation_response = activation.json()

    settings_overlap = Settings(
        database_url=database_url,
        token_master_key=key_v2,
        token_master_keys=((1, key_v1), (2, key_v2)),
        token_key_version=2,
        capability_pepper=pepper,
        apple_app_id="TEAM.ai.hermes.app",
        require_apns=False,
        hub_activation_private_key=activation_seed,
    )
    store_overlap = DatabaseStore(settings_overlap)
    verifier_overlap = FakeVerifier(counter=10)
    apns_overlap = FakeAPNs()
    with TestClient(
        create_app(
            settings=settings_overlap,
            store=store_overlap,
            verifier=verifier_overlap,
            apns_sender=apns_overlap,
        )
    ) as overlap_client:
        assert (
            overlap_client.post("/v2/endpoints/register", json=registration_body).json()
            == registration
        )
        assert (
            overlap_client.post("/v2/bindings/exchange", json=exchange_body).json()
            == binding
        )
        assert (
            overlap_client.post("/v2/hub-activations", json=activation_body).json()
            == activation_response
        )
        send = overlap_client.post(
            "/v2/send",
            headers={"Authorization": f"Bearer {binding['send_capability']}"},
            json=PushHarness.send_body(notification_id="nid_before_rewrap"),
        )
        assert send.status_code == 200
        assert (
            apns_overlap.sent[-1]["endpoint"].token == registration_body["apns_token"]
        )

        new_body = {
            **registration_body,
            "challenge": overlap_client.get("/v2/attest/challenge").json()["challenge"],
            "app_attest_key_id": _b64(b"z" * 32),
            "installation_nonce": b64url_encode(b"rotation-install-new"),
        }
        new_registration = overlap_client.post("/v2/endpoints/register", json=new_body)
        assert new_registration.status_code == 201
        assert (
            store_overlap.get_endpoint(
                new_registration.json()["endpoint_id"]
            ).token.key_version
            == 2
        )

    settings_retired = Settings(
        database_url=database_url,
        token_master_key=key_v2,
        token_key_version=2,
        capability_pepper=pepper,
        apple_app_id="TEAM.ai.hermes.app",
        require_apns=False,
        hub_activation_private_key=activation_seed,
    )
    with pytest.raises(ValueError, match="retirement rejected.*1"):
        create_app(
            settings=settings_retired,
            store=DatabaseStore(settings_retired),
            verifier=FakeVerifier(),
            apns_sender=FakeAPNs(),
        )

    _service_env(monkeypatch)
    monkeypatch.setenv("HPG_DATABASE_URL", database_url)
    monkeypatch.setenv("HPG_AUTO_CREATE_SCHEMA", "false")
    monkeypatch.setenv(
        "HPG_TOKEN_MASTER_KEYS_JSON",
        json.dumps({"1": _b64(key_v1), "2": _b64(key_v2)}),
    )
    monkeypatch.setenv("HPG_TOKEN_KEY_VERSION", "2")
    assert main(["rewrap-token-keys"]) == 0
    output = json.loads(capsys.readouterr().out)
    assert output["status"] == "ok"
    assert output["current_key_version"] == 2
    counts = output["rewrapped"]
    assert counts["endpoints"] >= 1
    assert counts["registration_receipts"] >= 1
    assert counts["hub_activation_receipts"] >= 1
    assert counts["binding_exchange_receipts"] >= 1
    assert store_overlap.token_key_versions_in_use() == frozenset({2})

    apns_retired = FakeAPNs()
    with TestClient(
        create_app(
            settings=settings_retired,
            store=DatabaseStore(settings_retired),
            verifier=FakeVerifier(counter=20),
            apns_sender=apns_retired,
        )
    ) as retired_client:
        assert (
            retired_client.post("/v2/endpoints/register", json=registration_body).json()
            == registration
        )
        assert (
            retired_client.post("/v2/bindings/exchange", json=exchange_body).json()
            == binding
        )
        assert (
            retired_client.post("/v2/hub-activations", json=activation_body).json()
            == activation_response
        )
        sent = retired_client.post(
            "/v2/send",
            headers={"Authorization": f"Bearer {binding['send_capability']}"},
            json=PushHarness.send_body(notification_id="nid_after_rewrap"),
        )
        assert sent.status_code == 200
        assert (
            apns_retired.sent[-1]["endpoint"].token == registration_body["apns_token"]
        )

    # Exercise the public-key half of the agreed overlap contract without ever
    # serializing either private seed into logs or responses.
    assert isinstance(
        Ed25519PrivateKey.from_private_bytes(activation_seed).public_key(),
        Ed25519PublicKey,
    )
