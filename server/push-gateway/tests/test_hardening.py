from __future__ import annotations

import asyncio
import base64
import datetime
import hashlib
import struct
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from types import SimpleNamespace

import pytest
from cbor2 import dumps as cbor_encode
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.x509.oid import NameOID, ObjectIdentifier
from fastapi.testclient import TestClient
from sqlalchemy import func, select

from push_gateway.app import _canonical_source, create_app
from push_gateway.attestation import (
    AppleAppAttestVerifier,
    AttestationError,
    AttestationIdentity,
)
from push_gateway.crypto import b64url_encode, secret_hash
from push_gateway.settings import Settings
from push_gateway.storage import DatabaseStore, RateLimited, challenges, endpoints

from conftest import FakeAPNs, FakeVerifier


def _settings(**overrides) -> Settings:
    values = {
        "database_url": "sqlite:///:memory:",
        "token_master_key": b"m" * 32,
        "capability_pepper": b"p" * 32,
        "apple_app_id": "TEAM.ai.hermes.app",
        "require_apns": False,
    }
    values.update(overrides)
    return Settings(**values)


def _noncanonical_padding_alias(canonical: str) -> str:
    raw = base64.b64decode(canonical, validate=True)
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for replacement in alphabet:
        candidate = canonical[:-2] + replacement + "="
        if candidate != canonical and base64.b64decode(candidate, validate=True) == raw:
            return candidate
    raise AssertionError("could not construct a base64 pad-bit alias")


def _assertion_object(
    private_key: ec.EllipticCurvePrivateKey,
    *,
    app_id: str,
    transcript: bytes,
    counter: int,
) -> bytes:
    authenticator_data = (
        hashlib.sha256(app_id.encode()).digest() + b"\x00" + struct.pack("!I", counter)
    )
    client_data_hash = hashlib.sha256(transcript).digest()
    nonce = hashlib.sha256(authenticator_data + client_data_hash).digest()
    signature = private_key.sign(nonce, ec.ECDSA(hashes.SHA256()))
    return cbor_encode({
        "authenticatorData": authenticator_data,
        "signature": signature,
    })


def _app_attest_object(
    *, app_id: str, transcript: bytes
) -> tuple[bytes, bytes, bytes, ec.EllipticCurvePrivateKey]:
    """Build App Attest data with a fresh EC trust root and credential leaf."""

    now = datetime.datetime.now(datetime.timezone.utc)
    root_key = ec.generate_private_key(ec.SECP256R1())
    root_name = x509.Name([
        x509.NameAttribute(NameOID.COMMON_NAME, "Hermes App Attest test root")
    ])
    root_cert = (
        x509
        .CertificateBuilder()
        .subject_name(root_name)
        .issuer_name(root_name)
        .public_key(root_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=30))
        .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
        .add_extension(
            x509.KeyUsage(True, False, False, False, False, True, True, False, False),
            critical=True,
        )
        .sign(root_key, hashes.SHA256())
    )
    leaf_key = ec.generate_private_key(ec.SECP256R1())
    public_point = leaf_key.public_key().public_bytes(
        serialization.Encoding.X962,
        serialization.PublicFormat.UncompressedPoint,
    )
    key_id = hashlib.sha256(public_point).digest()
    auth_data = (
        hashlib.sha256(app_id.encode()).digest()
        + b"\x00"
        + struct.pack("!I", 0)
        + b"appattestdevelop"
        + struct.pack("!H", len(key_id))
        + key_id
    )
    nonce = hashlib.sha256(auth_data + hashlib.sha256(transcript).digest()).digest()
    leaf_cert = (
        x509
        .CertificateBuilder()
        .subject_name(
            x509.Name([
                x509.NameAttribute(NameOID.COMMON_NAME, "Hermes App Attest test leaf")
            ])
        )
        .issuer_name(root_name)
        .public_key(leaf_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=10))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(True, False, False, False, False, False, False, False, False),
            critical=True,
        )
        .add_extension(
            x509.UnrecognizedExtension(
                ObjectIdentifier("1.2.840.113635.100.8.2"),
                b"\x30\x24\xa1\x22\x04\x20" + nonce,
            ),
            critical=False,
        )
        .sign(root_key, hashes.SHA256())
    )
    attestation = cbor_encode({
        "fmt": "apple-appattest",
        "attStmt": {
            "x5c": [
                leaf_cert.public_bytes(serialization.Encoding.DER),
                root_cert.public_bytes(serialization.Encoding.DER),
            ],
            "receipt": b"",
        },
        "authData": auth_data,
    })
    return (
        attestation,
        key_id,
        root_cert.public_bytes(serialization.Encoding.PEM),
        leaf_key,
    )


def test_unauthenticated_challenge_issuance_is_source_and_capacity_bounded() -> None:
    for settings, expected_code in (
        (_settings(challenge_per_source_per_hour=1), "attest_challenge_rate_limited"),
        (
            _settings(challenge_per_source_per_hour=10, maximum_live_challenges=1),
            "attest_challenge_capacity_exhausted",
        ),
    ):
        store = DatabaseStore(settings)
        with TestClient(
            create_app(
                settings=settings,
                store=store,
                verifier=FakeVerifier(),
                apns_sender=FakeAPNs(),
            )
        ) as client:
            first = client.get("/v2/attest/challenge")
            assert first.status_code == 200
            assert first.headers["cache-control"] == "no-store"
            blocked = client.get("/v2/attest/challenge")
            assert blocked.status_code == 429
            assert blocked.json()["error"]["code"] == expected_code
            with store.engine.connect() as conn:
                rows = conn.execute(select(challenges)).mappings().all()
            assert len(rows) == 1
            assert len(bytes(rows[0]["source_hash"])) == 32


def test_challenge_source_canonicalization_aggregates_ipv6_privacy_addresses() -> None:
    assert _canonical_source("2001:db8:1234:5678::1") == "2001:db8:1234:5678::/64"
    assert _canonical_source("2001:db8:1234:5678:ffff::9") == (
        "2001:db8:1234:5678::/64"
    )
    assert _canonical_source("2001:db8:1234:5679::1") == "2001:db8:1234:5679::/64"
    assert _canonical_source("::ffff:192.0.2.17") == "192.0.2.17"
    assert _canonical_source("192.0.2.17") == "192.0.2.17"
    assert _canonical_source("attacker-controlled-hostname") == "unknown"


def test_challenge_limit_is_shared_across_store_instances(tmp_path) -> None:
    settings = _settings(
        database_url=f"sqlite:///{tmp_path / 'challenge.sqlite3'}",
        challenge_per_source_per_hour=1,
    )
    first = DatabaseStore(settings)
    second = DatabaseStore(settings)
    first.issue_challenge(
        challenge_hash=b"1" * 32,
        source_hash=b"s" * 32,
        now_ms=1_000,
        expires_at_ms=61_000,
    )
    with pytest.raises(RateLimited, match="attest_challenge_rate_limited"):
        second.issue_challenge(
            challenge_hash=b"2" * 32,
            source_hash=b"s" * 32,
            now_ms=1_001,
            expires_at_ms=61_001,
        )


def test_postgresql_challenge_admission_try_lock_fails_closed() -> None:
    class ScalarResult:
        def scalar_one(self) -> bool:
            return False

    class Connection:
        dialect = SimpleNamespace(name="postgresql")

        def __init__(self) -> None:
            self.calls: list[str] = []

        def execute(self, statement, _parameters=None):
            self.calls.append(str(statement))
            return ScalarResult()

    connection = Connection()

    class Engine:
        @contextmanager
        def begin(self):
            yield connection

    store = DatabaseStore.__new__(DatabaseStore)
    store.engine = Engine()
    store._lock = threading.RLock()
    store.settings = SimpleNamespace(
        challenge_per_source_per_hour=10,
        maximum_live_challenges=10,
    )
    with pytest.raises(RateLimited, match="attest_challenge_admission_busy") as exc:
        store.issue_challenge(
            challenge_hash=b"c" * 32,
            source_hash=b"s" * 32,
            now_ms=1_000,
            expires_at_ms=61_000,
        )
    assert exc.value.retry_after_ms == 1000
    assert len(connection.calls) == 1
    assert "pg_try_advisory_xact_lock" in connection.calls[0]


def test_unknown_challenge_is_rejected_before_registration_or_activation_crypto(
    harness,
) -> None:
    unknown = b64url_encode(b"u" * 32)
    registration = harness.registration_body(challenge=unknown)
    activation = {
        "challenge": unknown,
        "app_attest_key_id": base64.b64encode(b"a" * 32).decode("ascii"),
        "assertion": "activation-assertion-data",
        "attestation": "activation-attestation-data",
        "bundle_id": "ai.hermes.app",
        "environment": "production",
        "installation_nonce": b64url_encode(b"unknown-challenge-install"),
        "hub_route_id": "rte_" + b64url_encode(b"r" * 24),
    }
    before = len(harness.verifier.calls)
    for path, body in (
        ("/v2/endpoints/register", registration),
        ("/v2/hub-activations", activation),
    ):
        response = harness.client.post(path, json=body)
        assert response.status_code == 403
        assert response.json()["error"]["code"] == "attest_challenge_unknown"
    assert len(harness.verifier.calls) == before


def test_failed_validation_releases_durable_challenge_reservation() -> None:
    class FailOnceVerifier:
        def __init__(self) -> None:
            self.calls = 0

        def verify(self, **_kwargs) -> AttestationIdentity:
            self.calls += 1
            if self.calls == 1:
                raise AttestationError("expected test rejection")
            return AttestationIdentity(b"valid-after-retry", 1)

    settings = _settings()
    store = DatabaseStore(settings)
    verifier = FailOnceVerifier()
    with TestClient(
        create_app(
            settings=settings,
            store=store,
            verifier=verifier,
            apns_sender=FakeAPNs(),
        )
    ) as client:
        challenge = client.get("/v2/attest/challenge").json()["challenge"]
        body = {
            "challenge": challenge,
            "app_attest_key_id": base64.b64encode(b"k" * 32).decode("ascii"),
            "assertion": "assertion-payload-0001",
            "attestation": "attestation-data-0001",
            "apns_token": "ab" * 32,
            "environment": "production",
            "bundle_id": "ai.hermes.app",
            "preview_kem_pub": b64url_encode(bytes(range(32))),
            "installation_nonce": b64url_encode(b"failed-then-valid"),
        }
        rejected = client.post("/v2/endpoints/register", json=body)
        assert rejected.status_code == 403
        with store.engine.connect() as conn:
            row = (
                conn
                .execute(
                    select(challenges).where(
                        challenges.c.challenge_hash
                        == secret_hash(challenge, settings.capability_pepper)
                    )
                )
                .mappings()
                .one()
            )
        assert row["used_at_ms"] is None
        assert row["validation_request_hash"] is None
        assert row["validation_owner_token"] is None
        assert row["validation_expires_at_ms"] is None
        accepted = client.post("/v2/endpoints/register", json=body)
        assert accepted.status_code == 201
    assert verifier.calls == 2


@pytest.mark.parametrize("operation", ["registration", "activation"])
def test_concurrent_exact_attestation_validates_once_and_returns_one_receipt(
    operation: str,
) -> None:
    started = threading.Event()
    release = threading.Event()

    class BlockingVerifier:
        def __init__(self) -> None:
            self.calls = 0
            self.ran_in_event_loop = False

        def verify(self, **_kwargs) -> AttestationIdentity:
            self.calls += 1
            try:
                asyncio.get_running_loop()
            except RuntimeError:
                pass
            else:
                self.ran_in_event_loop = True
            started.set()
            assert release.wait(5)
            return AttestationIdentity(b"blocking-public-key", 1)

    settings = _settings(
        hub_activation_private_key=Ed25519PrivateKey.generate().private_bytes_raw()
    )
    store = DatabaseStore(settings)
    verifier = BlockingVerifier()
    with TestClient(
        create_app(
            settings=settings,
            store=store,
            verifier=verifier,
            apns_sender=FakeAPNs(),
        )
    ) as client:
        challenge = client.get("/v2/attest/challenge").json()["challenge"]
        if operation == "registration":
            path = "/v2/endpoints/register"
            body = {
                "challenge": challenge,
                "app_attest_key_id": base64.b64encode(b"k" * 32).decode("ascii"),
                "assertion": "assertion-payload-0001",
                "attestation": "attestation-data-0001",
                "apns_token": "ab" * 32,
                "environment": "production",
                "bundle_id": "ai.hermes.app",
                "preview_kem_pub": b64url_encode(bytes(range(32))),
                "installation_nonce": b64url_encode(b"concurrent-register"),
            }
        else:
            path = "/v2/hub-activations"
            body = {
                "challenge": challenge,
                "app_attest_key_id": base64.b64encode(b"a" * 32).decode("ascii"),
                "assertion": "activation-assertion-data",
                "attestation": "activation-attestation-data",
                "bundle_id": "ai.hermes.app",
                "environment": "production",
                "installation_nonce": b64url_encode(b"concurrent-activate"),
                "hub_route_id": "rte_" + b64url_encode(b"r" * 24),
            }
        with ThreadPoolExecutor(max_workers=3) as pool:
            first_future = pool.submit(client.post, path, json=body)
            assert started.wait(2)
            second_future = pool.submit(client.post, path, json=body)
            time.sleep(0.05)
            assert verifier.calls == 1
            # The event loop stays responsive while native x509/ECDSA work is
            # blocked in its bounded worker thread.
            health_future = pool.submit(client.get, "/healthz")
            assert health_future.result(timeout=1).status_code == 200
            release.set()
            first = first_future.result(timeout=5)
            second = second_future.result(timeout=5)
        assert sorted((first.status_code, second.status_code)) == [200, 201]
        assert first.json() == second.json()
        assert verifier.calls == 1
        assert verifier.ran_in_event_loop is False


def test_attestation_concurrency_cap_rejects_without_consuming_challenge() -> None:
    started = threading.Event()
    release = threading.Event()

    class CapacityVerifier:
        def __init__(self) -> None:
            self.calls = 0

        def verify(self, **kwargs) -> AttestationIdentity:
            self.calls += 1
            if self.calls == 1:
                started.set()
                assert release.wait(5)
            return AttestationIdentity(
                kwargs["existing_public_key_der"] or b"capacity-public-key",
                self.calls,
            )

    settings = _settings(attestation_max_concurrency=1)
    store = DatabaseStore(settings)
    verifier = CapacityVerifier()
    with TestClient(
        create_app(
            settings=settings,
            store=store,
            verifier=verifier,
            apns_sender=FakeAPNs(),
        )
    ) as client:

        def body(challenge: str, installation: bytes) -> dict:
            return {
                "challenge": challenge,
                "app_attest_key_id": base64.b64encode(b"k" * 32).decode("ascii"),
                "assertion": "assertion-payload-0001",
                "attestation": "attestation-data-0001",
                "apns_token": "ab" * 32,
                "environment": "production",
                "bundle_id": "ai.hermes.app",
                "preview_kem_pub": b64url_encode(bytes(range(32))),
                "installation_nonce": b64url_encode(installation),
            }

        first_body = body(
            client.get("/v2/attest/challenge").json()["challenge"],
            b"capacity-first-001",
        )
        second_body = body(
            client.get("/v2/attest/challenge").json()["challenge"],
            b"capacity-second-01",
        )
        with ThreadPoolExecutor(max_workers=2) as pool:
            first_future = pool.submit(
                client.post, "/v2/endpoints/register", json=first_body
            )
            assert started.wait(2)
            saturated = client.post("/v2/endpoints/register", json=second_body)
            assert saturated.status_code == 429
            assert saturated.json()["error"]["code"] == "app_attest_capacity_exhausted"
            assert saturated.headers["retry-after"] == "1"
            assert verifier.calls == 1
            release.set()
            assert first_future.result(timeout=5).status_code == 201
        retried = client.post("/v2/endpoints/register", json=second_body)
        assert retried.status_code == 201
        assert verifier.calls == 2


def test_request_body_limit_rejects_content_length_and_streamed_overflow_without_db_work() -> (
    None
):
    settings = _settings()
    store = DatabaseStore(settings)
    with TestClient(
        create_app(
            settings=settings,
            store=store,
            verifier=FakeVerifier(),
            apns_sender=FakeAPNs(),
        )
    ) as client:
        too_large = b"x" * (128 * 1024 + 1)
        declared = client.post(
            "/v2/endpoints/register",
            content=too_large,
            headers={"Content-Type": "application/json"},
        )
        assert declared.status_code == 413
        streamed = client.post(
            "/v2/endpoints/register",
            content=iter([b"x" * 70_000, b"y" * 70_000]),
            headers={"Content-Type": "application/json"},
        )
        assert streamed.status_code == 413
        with store.engine.connect() as conn:
            assert (
                conn.execute(select(func.count()).select_from(endpoints)).scalar_one()
                == 0
            )


def test_app_attest_key_id_pad_bit_alias_is_rejected_on_every_attested_api(
    harness,
) -> None:
    registration = harness.registration_body()
    alias = _noncanonical_padding_alias(registration["app_attest_key_id"])
    assert base64.b64decode(alias, validate=True) == base64.b64decode(
        registration["app_attest_key_id"], validate=True
    )

    registration["app_attest_key_id"] = alias
    activation = {
        "challenge": harness.challenge(),
        "app_attest_key_id": alias,
        "assertion": "activation-assertion-data",
        "attestation": "activation-attestation-data",
        "bundle_id": "ai.hermes.app",
        "environment": "production",
        "installation_nonce": registration["installation_nonce"],
        "hub_route_id": "rte_aaaaaaaaaaaaaaaaaaaa",
    }
    refresh = {
        "endpoint_id": "ep_aaaaaaaaaaaaaaaaaaaa",
        "challenge": harness.challenge(),
        "app_attest_key_id": alias,
        "assertion": "refresh-assertion-data",
        "apns_token": "ab" * 32,
        "environment": "production",
        "bundle_id": "ai.hermes.app",
        "preview_kem_pub": registration["preview_kem_pub"],
        "installation_nonce": registration["installation_nonce"],
    }
    calls_before = len(harness.verifier.calls)
    for path, body in (
        ("/v2/endpoints/register", registration),
        ("/v2/hub-activations", activation),
        ("/v2/endpoints/token-refresh", refresh),
    ):
        response = harness.client.post(path, json=body)
        assert response.status_code == 422
        assert response.json()["error"]["code"] == "invalid_request"
    assert len(harness.verifier.calls) == calls_before


def test_direct_assertion_verifier_uses_client_data_hash_once() -> None:
    app_id = "TEAM.ai.hermes.app"
    transcript = b"canonical HPG2 request transcript"
    client_data_hash = hashlib.sha256(transcript).digest()
    private_key = ec.generate_private_key(ec.SECP256R1())
    auth_data = (
        hashlib.sha256(app_id.encode()).digest() + b"\x00" + struct.pack("!I", 7)
    )
    nonce = hashlib.sha256(auth_data + client_data_hash).digest()
    signature = private_key.sign(nonce, ec.ECDSA(hashes.SHA256()))
    raw_assertion = cbor_encode({
        "authenticatorData": auth_data,
        "signature": signature,
    })
    public_key_der = private_key.public_key().public_bytes(
        serialization.Encoding.DER,
        serialization.PublicFormat.SubjectPublicKeyInfo,
    )
    key_id = hashlib.sha256(
        private_key.public_key().public_bytes(
            serialization.Encoding.X962,
            serialization.PublicFormat.UncompressedPoint,
        )
    ).digest()
    verifier = AppleAppAttestVerifier(app_id=app_id, production=True)
    verified = verifier.verify(
        key_id=base64.b64encode(key_id).decode("ascii"),
        assertion=base64.b64encode(raw_assertion).decode("ascii"),
        attestation=None,
        request_transcript=transcript,
        request_hash=client_data_hash,
        bundle_id="ai.hermes.app",
        environment="production",
        existing_public_key_der=public_key_der,
    )
    assert verified.counter == 7

    # Passing the raw transcript in the clientDataHash slot must fail closed.
    with pytest.raises(AttestationError, match="request hash"):
        verifier.verify(
            key_id=base64.b64encode(key_id).decode("ascii"),
            assertion=base64.b64encode(raw_assertion).decode("ascii"),
            attestation=None,
            request_transcript=transcript,
            request_hash=transcript,
            bundle_id="ai.hermes.app",
            environment="production",
            existing_public_key_der=public_key_der,
        )


def test_real_initial_app_attest_chain_key_id_nonce_and_assertion_on_python313() -> (
    None
):
    app_id = "TEAM.ai.hermes.app"
    transcript = b"canonical HPG2 initial registration transcript"
    attestation, key_id, root_pem, private_key = _app_attest_object(
        app_id=app_id,
        transcript=transcript,
    )
    verifier = AppleAppAttestVerifier(
        app_id=app_id,
        production=False,
        allow_development=True,
        root_ca=root_pem,
    )
    first = verifier.verify(
        key_id=base64.b64encode(key_id).decode("ascii"),
        assertion=base64.b64encode(
            _assertion_object(
                private_key,
                app_id=app_id,
                transcript=transcript,
                counter=1,
            )
        ).decode("ascii"),
        attestation=base64.b64encode(attestation).decode("ascii"),
        request_transcript=transcript,
        request_hash=hashlib.sha256(transcript).digest(),
        bundle_id="ai.hermes.app",
        environment="sandbox",
        existing_public_key_der=None,
    )
    assert first.counter == 1

    # Prove the public key retained from the verified leaf drives the next
    # assertion and no attestation object is needed again.
    next_transcript = b"canonical HPG2 token refresh transcript"
    second = verifier.verify(
        key_id=base64.b64encode(key_id).decode("ascii"),
        assertion=base64.b64encode(
            _assertion_object(
                private_key,
                app_id=app_id,
                transcript=next_transcript,
                counter=2,
            )
        ).decode("ascii"),
        attestation=None,
        request_transcript=next_transcript,
        request_hash=hashlib.sha256(next_transcript).digest(),
        bundle_id="ai.hermes.app",
        environment="sandbox",
        existing_public_key_der=first.public_key_der,
    )
    assert second.counter == 2


def test_initial_app_attest_rejects_untrusted_chain_nonce_key_id_and_assertion() -> (
    None
):
    app_id = "TEAM.ai.hermes.app"
    transcript = b"canonical HPG2 initial registration transcript"
    attestation, key_id, root_pem, private_key = _app_attest_object(
        app_id=app_id,
        transcript=transcript,
    )
    assertion = base64.b64encode(
        _assertion_object(
            private_key,
            app_id=app_id,
            transcript=transcript,
            counter=1,
        )
    ).decode("ascii")
    common = {
        "assertion": assertion,
        "attestation": base64.b64encode(attestation).decode("ascii"),
        "request_transcript": transcript,
        "request_hash": hashlib.sha256(transcript).digest(),
        "bundle_id": "ai.hermes.app",
        "environment": "sandbox",
        "existing_public_key_der": None,
    }
    _other, _other_id, untrusted_root, _other_key = _app_attest_object(
        app_id=app_id,
        transcript=transcript,
    )
    with pytest.raises(AttestationError, match="untrusted"):
        AppleAppAttestVerifier(
            app_id=app_id,
            production=False,
            allow_development=True,
            root_ca=untrusted_root,
        ).verify(key_id=base64.b64encode(key_id).decode("ascii"), **common)

    verifier = AppleAppAttestVerifier(
        app_id=app_id,
        production=False,
        allow_development=True,
        root_ca=root_pem,
    )
    with pytest.raises(AttestationError, match="nonce"):
        verifier.verify(
            key_id=base64.b64encode(key_id).decode("ascii"),
            **(
                common
                | {
                    "request_transcript": b"different transcript",
                    "request_hash": hashlib.sha256(b"different transcript").digest(),
                }
            ),
        )
    with pytest.raises(AttestationError, match="key identifier"):
        verifier.verify(key_id=base64.b64encode(b"z" * 32).decode("ascii"), **common)
    wrong_signer = ec.generate_private_key(ec.SECP256R1())
    with pytest.raises(AttestationError, match="signature"):
        verifier.verify(
            key_id=base64.b64encode(key_id).decode("ascii"),
            **(
                common
                | {
                    "assertion": base64.b64encode(
                        _assertion_object(
                            wrong_signer,
                            app_id=app_id,
                            transcript=transcript,
                            counter=1,
                        )
                    ).decode("ascii")
                }
            ),
        )


def test_push_production_configuration_fails_closed() -> None:
    production = {
        "production_mode": True,
        "database_url": "postgresql+psycopg://push_gateway@db/push_gateway",
        "auto_create_schema": False,
        "require_apns": True,
        "apns_key_pem": "test-private-key",
        "apns_key_id": "KEYID",
        "apns_team_id": "TEAMID",
    }
    with pytest.raises(ValueError, match="requires PostgreSQL"):
        _settings(
            **(production | {"database_url": "sqlite:///push-gateway.db"})
        ).validate()
    with pytest.raises(ValueError, match="explicit migrations"):
        _settings(**(production | {"auto_create_schema": True})).validate()
    with pytest.raises(ValueError, match="development attestation"):
        _settings(
            **production,
            development_registration_token="development-token",
        ).validate()
    _settings(**production).validate()
