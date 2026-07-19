from __future__ import annotations

import base64
import hashlib
import secrets
import struct
from dataclasses import dataclass
from typing import Any, Protocol

from cbor2 import loads as cbor_decode
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import (
    Encoding,
    PublicFormat,
    load_der_public_key,
)
from cryptography.x509 import verification
from cryptography.x509.oid import ObjectIdentifier


_APPLE_APP_ATTEST_NONCE_OID = ObjectIdentifier("1.2.840.113635.100.8.2")
_PRODUCTION_AAGUID = b"appattest" + bytes(7)
_DEVELOPMENT_AAGUIDS = frozenset({
    b"appattestdevelop",
    # Apple's current documentation calls the development environment
    # sandbox. Accept both identifiers so existing development keys keep
    # working while production remains pinned to the production AAGUID.
    b"appattestsandbox",
    _PRODUCTION_AAGUID,
})
_APPLE_APP_ATTEST_ROOT_CA_PEM = b"""-----BEGIN CERTIFICATE-----
MIICITCCAaegAwIBAgIQC/O+DvHN0uD7jG5yH2IXmDAKBggqhkjOPQQDAzBSMSYw
JAYDVQQDDB1BcHBsZSBBcHAgQXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwK
QXBwbGUgSW5jLjETMBEGA1UECAwKQ2FsaWZvcm5pYTAeFw0yMDAzMTgxODMyNTNa
Fw00NTAzMTUwMDAwMDBaMFIxJjAkBgNVBAMMHUFwcGxlIEFwcCBBdHRlc3RhdGlv
biBSb290IENBMRMwEQYDVQQKDApBcHBsZSBJbmMuMRMwEQYDVQQIDApDYWxpZm9y
bmlhMHYwEAYHKoZIzj0CAQYFK4EEACIDYgAERTHhmLW07ATaFQIEVwTtT4dyctdh
NbJhFs/Ii2FdCgAHGbpphY3+d8qjuDngIN3WVhQUBHAoMeQ/cLiP1sOUtgjqK9au
Yen1mMEvRq9Sk3Jm5X8U62H+xTD3FE9TgS41o0IwQDAPBgNVHRMBAf8EBTADAQH/
MB0GA1UdDgQWBBSskRBTM72+aEH/pwyp5frq5eWKoTAOBgNVHQ8BAf8EBAMCAQYw
CgYIKoZIzj0EAwMDaAAwZQIwQgFGnByvsiVbpTKwSga0kP0e8EeDS4+sQmTvb7vn
53O5+FRXgeLhpJ06ysC5PrOyAjEAp5U4xDgEgllF7En3VcE3iexZZtKeYnpqtijV
oyFraWVIyd/dganmrduC1bmTBGwD
-----END CERTIFICATE-----
"""


class AttestationError(ValueError):
    pass


@dataclass(frozen=True)
class AttestationIdentity:
    public_key_der: bytes
    counter: int


class AttestationVerifier(Protocol):
    def verify(
        self,
        *,
        key_id: str,
        assertion: str,
        attestation: str | None,
        request_transcript: bytes,
        request_hash: bytes,
        bundle_id: str,
        environment: str,
        existing_public_key_der: bytes | None,
    ) -> AttestationIdentity: ...


class AppleAppAttestVerifier:
    """Verify Apple App Attest without a general-purpose JOSE dependency.

    Initial registration validates the Apple certificate path, credential
    certificate nonce, App ID, environment AAGUID, zero counter, credential
    identifier and key identifier. Every request then validates the assertion
    signature, RP ID and positive counter against that retained public key.
    """

    def __init__(
        self,
        *,
        app_id: str,
        production: bool,
        allow_development: bool = False,
        root_ca: bytes | None = None,
    ) -> None:
        self._app_id = app_id
        self._production = production
        self._allow_development = allow_development
        self._trust_roots = self._load_roots(
            root_ca if root_ca is not None else _APPLE_APP_ATTEST_ROOT_CA_PEM
        )

    @staticmethod
    def _load_roots(value: bytes) -> tuple[x509.Certificate, ...]:
        try:
            if b"-----BEGIN CERTIFICATE-----" in value:
                roots = tuple(x509.load_pem_x509_certificates(value))
            else:
                roots = (x509.load_der_x509_certificate(value),)
        except Exception as exc:
            raise ValueError("invalid App Attest trust root") from exc
        if not roots:
            raise ValueError("at least one App Attest trust root is required")
        for certificate in roots:
            try:
                constraints = certificate.extensions.get_extension_for_class(
                    x509.BasicConstraints
                )
            except x509.ExtensionNotFound as exc:
                raise ValueError(
                    "App Attest trust root lacks basic constraints"
                ) from exc
            if not constraints.critical or not constraints.value.ca:
                raise ValueError("App Attest trust root is not a critical CA")
        return roots

    @staticmethod
    def _standard_b64(value: str, field: str, maximum: int) -> bytes:
        try:
            raw = base64.b64decode(value, validate=True)
        except Exception as exc:
            raise AttestationError(f"malformed {field}") from exc
        if not raw or len(raw) > maximum:
            raise AttestationError(f"invalid {field} length")
        if base64.b64encode(raw).decode("ascii") != value:
            raise AttestationError(f"non-canonical {field}")
        return raw

    @staticmethod
    def _decode_map(raw: bytes, field: str) -> dict[str, Any]:
        try:
            value = cbor_decode(raw)
        except Exception as exc:
            raise AttestationError(f"malformed {field}") from exc
        if not isinstance(value, dict) or any(
            not isinstance(key, str) for key in value
        ):
            raise AttestationError(f"invalid {field}")
        return value

    @staticmethod
    def _public_key_id(public_key: ec.EllipticCurvePublicKey) -> bytes:
        point = public_key.public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
        return hashlib.sha256(point).digest()

    @staticmethod
    def _p256_public_key(value: Any) -> ec.EllipticCurvePublicKey:
        if not isinstance(value, ec.EllipticCurvePublicKey) or not isinstance(
            value.curve, ec.SECP256R1
        ):
            raise AttestationError("App Attest credential key must be P-256")
        return value

    @staticmethod
    def _reject_unknown_critical_extensions(certificate: x509.Certificate) -> None:
        for extension in certificate.extensions:
            if extension.critical and isinstance(
                extension.value, x509.UnrecognizedExtension
            ):
                raise AttestationError(
                    "certificate contains an unknown critical extension"
                )

    def _verify_certificate_path(
        self, certificates: list[x509.Certificate]
    ) -> x509.Certificate:
        if not certificates or len(certificates) > 5:
            raise AttestationError("invalid App Attest certificate chain length")
        leaf = certificates[0]
        for certificate in certificates:
            self._reject_unknown_critical_extensions(certificate)
        try:
            leaf_constraints = leaf.extensions.get_extension_for_class(
                x509.BasicConstraints
            )
            leaf_usage = leaf.extensions.get_extension_for_class(x509.KeyUsage)
        except x509.ExtensionNotFound as exc:
            raise AttestationError(
                "credential certificate lacks required constraints"
            ) from exc
        if (
            not leaf_constraints.critical
            or leaf_constraints.value.ca
            or not leaf_usage.critical
            or not leaf_usage.value.digital_signature
        ):
            raise AttestationError("credential certificate constraints are invalid")
        self._p256_public_key(leaf.public_key())
        for intermediate in certificates[1:]:
            try:
                constraints = intermediate.extensions.get_extension_for_class(
                    x509.BasicConstraints
                )
            except x509.ExtensionNotFound as exc:
                raise AttestationError(
                    "intermediate certificate lacks constraints"
                ) from exc
            if not constraints.critical or not constraints.value.ca:
                raise AttestationError("intermediate certificate is not a CA")

        # App Attest leaves intentionally do not carry the web-PKI SAN/AKI set,
        # so use a minimal certificate policy while retaining cryptography's
        # path building, signature, validity, trust-anchor and CA-constraint
        # checks. Critical proprietary extensions are rejected above.
        ca_policy = verification.ExtensionPolicy.permit_all().require_present(
            x509.BasicConstraints,
            verification.Criticality.CRITICAL,
            None,
        )
        ee_policy = verification.ExtensionPolicy.permit_all().require_present(
            x509.BasicConstraints,
            verification.Criticality.CRITICAL,
            None,
        )
        try:
            verifier = (
                verification
                .PolicyBuilder()
                .store(verification.Store(list(self._trust_roots)))
                .max_chain_depth(3)
                .extension_policies(ca_policy=ca_policy, ee_policy=ee_policy)
                .build_client_verifier()
            )
            verifier.verify(leaf, certificates[1:])
        except (ValueError, verification.VerificationError) as exc:
            raise AttestationError("App Attest certificate chain is untrusted") from exc
        return leaf

    @staticmethod
    def _attestation_fields(raw: bytes) -> tuple[bytes, list[x509.Certificate]]:
        decoded = AppleAppAttestVerifier._decode_map(raw, "App Attest object")
        if decoded.get("fmt") != "apple-appattest":
            raise AttestationError("unexpected App Attest format")
        auth_data = decoded.get("authData")
        attestation_statement = decoded.get("attStmt")
        if not isinstance(auth_data, bytes) or not isinstance(
            attestation_statement, dict
        ):
            raise AttestationError("invalid App Attest object")
        chain = attestation_statement.get("x5c")
        if (
            not isinstance(chain, list)
            or not chain
            or len(chain) > 5
            or any(not isinstance(item, bytes) or not item for item in chain)
        ):
            raise AttestationError("invalid App Attest certificate chain")
        try:
            certificates = [x509.load_der_x509_certificate(item) for item in chain]
        except Exception as exc:
            raise AttestationError("malformed App Attest certificate") from exc
        return auth_data, certificates

    def _verify_initial_attestation(
        self,
        *,
        raw: bytes,
        key_id: bytes,
        request_transcript: bytes,
        use_production: bool,
    ) -> bytes:
        auth_data, certificates = self._attestation_fields(raw)
        if len(auth_data) < 37 + 18:
            raise AttestationError("App Attest authenticator data is truncated")
        rp_id = auth_data[:32]
        counter = struct.unpack("!I", auth_data[33:37])[0]
        credential_data = auth_data[37:]
        aaguid = credential_data[:16]
        credential_length = struct.unpack("!H", credential_data[16:18])[0]
        if credential_length == 0 or len(credential_data) < 18 + credential_length:
            raise AttestationError("App Attest credential identifier is truncated")
        credential_id = credential_data[18 : 18 + credential_length]
        expected_rp_id = hashlib.sha256(self._app_id.encode()).digest()
        if not secrets.compare_digest(rp_id, expected_rp_id):
            raise AttestationError("attestation App ID mismatch")
        if counter != 0:
            raise AttestationError("initial attestation counter must be zero")
        if use_production:
            if aaguid != _PRODUCTION_AAGUID:
                raise AttestationError("production App Attest AAGUID mismatch")
        elif aaguid not in _DEVELOPMENT_AAGUIDS:
            raise AttestationError("development App Attest AAGUID mismatch")

        leaf = self._verify_certificate_path(certificates)
        public_key = self._p256_public_key(leaf.public_key())
        certificate_key_id = self._public_key_id(public_key)
        if not secrets.compare_digest(certificate_key_id, key_id):
            raise AttestationError("App Attest key identifier mismatch")
        if not secrets.compare_digest(credential_id, key_id):
            raise AttestationError("App Attest credential identifier mismatch")

        try:
            extension = leaf.extensions.get_extension_for_oid(
                _APPLE_APP_ATTEST_NONCE_OID
            )
        except x509.ExtensionNotFound as exc:
            raise AttestationError("App Attest nonce extension is missing") from exc
        if not isinstance(extension.value, x509.UnrecognizedExtension):
            raise AttestationError("App Attest nonce extension is invalid")
        expected_nonce = hashlib.sha256(
            auth_data + hashlib.sha256(request_transcript).digest()
        ).digest()
        # Apple encodes the nonce as SEQUENCE { [1] OCTET STRING (32) }.
        expected_der = b"\x30\x24\xa1\x22\x04\x20" + expected_nonce
        if not secrets.compare_digest(extension.value.value, expected_der):
            raise AttestationError("App Attest nonce mismatch")
        return public_key.public_bytes(Encoding.DER, PublicFormat.SubjectPublicKeyInfo)

    def _verify_assertion(
        self,
        *,
        raw: bytes,
        request_hash: bytes,
        public_key_der: bytes,
        key_id: bytes,
    ) -> int:
        decoded = self._decode_map(raw, "App Attest assertion")
        if set(decoded) != {"authenticatorData", "signature"}:
            raise AttestationError("invalid App Attest assertion fields")
        auth_data = decoded["authenticatorData"]
        signature = decoded["signature"]
        if (
            not isinstance(auth_data, bytes)
            or len(auth_data) < 37
            or len(auth_data) > 4096
            or not isinstance(signature, bytes)
            or not signature
            or len(signature) > 256
        ):
            raise AttestationError("invalid App Attest assertion")
        try:
            public_key = self._p256_public_key(load_der_public_key(public_key_der))
        except AttestationError:
            raise
        except Exception as exc:
            raise AttestationError("stored App Attest public key is invalid") from exc
        if not secrets.compare_digest(self._public_key_id(public_key), key_id):
            raise AttestationError("assertion key identifier mismatch")
        expected_rp_id = hashlib.sha256(self._app_id.encode()).digest()
        if not secrets.compare_digest(auth_data[:32], expected_rp_id):
            raise AttestationError("assertion App ID mismatch")
        counter = struct.unpack("!I", auth_data[33:37])[0]
        if counter <= 0:
            raise AttestationError("assertion counter did not advance")
        nonce = hashlib.sha256(auth_data + request_hash).digest()
        try:
            public_key.verify(signature, nonce, ec.ECDSA(hashes.SHA256()))
        except InvalidSignature as exc:
            raise AttestationError("App Attest assertion signature is invalid") from exc
        return counter

    def verify(
        self,
        *,
        key_id: str,
        assertion: str,
        attestation: str | None,
        request_transcript: bytes,
        request_hash: bytes,
        bundle_id: str,
        environment: str,
        existing_public_key_der: bytes | None,
    ) -> AttestationIdentity:
        if not self._app_id.endswith("." + bundle_id):
            raise AttestationError("bundle does not match configured App ID")
        if environment not in {"production", "sandbox"}:
            raise AttestationError("invalid App Attest environment")
        if environment == "sandbox" and not self._allow_development:
            raise AttestationError("development attestation is disabled")
        if len(request_hash) != 32 or not secrets.compare_digest(
            request_hash, hashlib.sha256(request_transcript).digest()
        ):
            raise AttestationError("App Attest request hash mismatch")
        key_id_raw = self._standard_b64(key_id, "App Attest key identifier", 64)
        if len(key_id_raw) != 32:
            raise AttestationError("App Attest key identifier must be 32 bytes")
        assertion_raw = self._standard_b64(assertion, "App Attest assertion", 16_384)

        public_key_der = existing_public_key_der
        if public_key_der is None:
            if attestation is None:
                raise AttestationError("initial App Attest object is required")
            attestation_raw = self._standard_b64(
                attestation, "App Attest object", 32_768
            )
            use_production = self._production if environment == "production" else False
            public_key_der = self._verify_initial_attestation(
                raw=attestation_raw,
                key_id=key_id_raw,
                request_transcript=request_transcript,
                use_production=use_production,
            )
        counter = self._verify_assertion(
            raw=assertion_raw,
            request_hash=request_hash,
            public_key_der=public_key_der,
            key_id=key_id_raw,
        )
        return AttestationIdentity(public_key_der=public_key_der, counter=counter)
