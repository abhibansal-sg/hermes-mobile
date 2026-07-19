"""Single-use HRP/2 device enrollment state machine.

The QR secret authenticates only the short-lived ``PairInit`` transcript.  It
never becomes a device credential.  A successfully claimed offer still
requires human confirmation (unless the operator explicitly chose
``--auto-approve``), then authenticated HPKE ``PairAccept``/``PairConfirm``.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import secrets
import struct
from dataclasses import dataclass
from typing import Any, Mapping

from cryptography.hazmat.primitives.asymmetric import ed25519

from .crypto import open_base_message, seal_authenticated_message
from .errors import Conflict, Expired, InvalidArgument, NotFound, Unauthenticated
from .hub_client import HubClient, HubUnavailable
from .identity import RelayIdentity
from .protocol import (
    HPKEDirection,
    HPKEPurpose,
    SecureMessage,
    SecureMessageKind,
    b64url_decode,
    b64url_encode,
    canonical_json,
    decode_strict_json,
    hpke_info,
)
from .storage import (
    PairOfferRecord,
    RelayStorage,
    StorageConflict,
    StorageExpired,
    StorageNotFound,
    random_id,
)


class _PairAcceptanceLeaseLost(Conflict):
    pass


PAIR_INIT_INFO = b"hermes-mobile/hrp2/pair/init"
PAIR_ACCEPT_INFO = hpke_info(HPKEPurpose.CONTROL, HPKEDirection.AGENT_TO_DEVICE)


def _grant_signature_payload(grant: Mapping[str, Any]) -> bytes:
    permissions = ",".join(sorted(grant["permissions"]))
    values = (
        grant["grant_id"],
        grant["issuer_route"],
        grant["source_route"],
        grant["destination_route"],
        permissions,
        grant["expires_at_ms"],
    )
    encoded = bytearray(b"HRH2GRANT")
    for value in values:
        raw = b"" if value is None else str(value).encode("utf-8")
        encoded.extend(struct.pack(">I", len(raw)))
        encoded.extend(raw)
    return bytes(encoded)


def _strict(value: Mapping[str, Any], fields: set[str]) -> None:
    if not isinstance(value, Mapping):
        raise InvalidArgument("Expected a pairing object")
    missing = fields - set(value)
    extra = set(value) - fields
    if missing or extra:
        raise InvalidArgument(
            "Invalid pairing fields",
            details={"field": sorted(missing or extra)[0]},
        )


def _text(value: Any, field: str, maximum: int = 512) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > maximum:
        raise InvalidArgument(details={"field": field})
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
        raise InvalidArgument(details={"field": field})
    return value


@dataclass(frozen=True, slots=True)
class PairInit:
    offer_id: str
    device_name: str
    device_kem_public: bytes
    device_sign_public: bytes
    preview_kem_public: bytes
    device_nonce: bytes
    push_bind_token: str | None
    hub_activation_token: str | None
    pair_mac: bytes
    v: int = 2

    def __post_init__(self) -> None:
        if self.v != 2:
            raise InvalidArgument(details={"field": "v"})
        _text(self.offer_id, "offer_id", 256)
        _text(self.device_name, "device_name", 200)
        for field, value in (
            ("device_kem_pub", self.device_kem_public),
            ("device_sign_pub", self.device_sign_public),
            ("preview_kem_pub", self.preview_kem_public),
        ):
            if not isinstance(value, bytes) or len(value) != 32:
                raise InvalidArgument(details={"field": field})
        if (
            not isinstance(self.device_nonce, bytes)
            or not 16 <= len(self.device_nonce) <= 64
        ):
            raise InvalidArgument(details={"field": "device_nonce"})
        if self.push_bind_token is not None:
            _text(self.push_bind_token, "push_bind_token", 512)
        if self.hub_activation_token is not None:
            _text(self.hub_activation_token, "hub_activation_token", 1024)
        if not isinstance(self.pair_mac, bytes) or len(self.pair_mac) != 32:
            raise InvalidArgument(details={"field": "pair_mac"})

    def transcript_dict(self) -> dict[str, Any]:
        return {
            "v": self.v,
            "offer_id": self.offer_id,
            "device_name": self.device_name,
            "device_kem_pub": b64url_encode(self.device_kem_public),
            "device_sign_pub": b64url_encode(self.device_sign_public),
            "preview_kem_pub": b64url_encode(self.preview_kem_public),
            "device_nonce": b64url_encode(self.device_nonce),
            "push_bind_token": self.push_bind_token,
            "hub_activation_token": self.hub_activation_token,
        }

    def to_dict(self) -> dict[str, Any]:
        return {**self.transcript_dict(), "pair_mac": b64url_encode(self.pair_mac)}

    @classmethod
    def from_dict(cls, value: Mapping[str, Any]) -> "PairInit":
        fields = {
            "v",
            "offer_id",
            "device_name",
            "device_kem_pub",
            "device_sign_pub",
            "preview_kem_pub",
            "device_nonce",
            "push_bind_token",
            "hub_activation_token",
            "pair_mac",
        }
        _strict(value, fields)
        return cls(
            v=value["v"],
            offer_id=value["offer_id"],
            device_name=value["device_name"],
            device_kem_public=b64url_decode(
                value["device_kem_pub"], field="device_kem_pub", exact_bytes=32
            ),
            device_sign_public=b64url_decode(
                value["device_sign_pub"], field="device_sign_pub", exact_bytes=32
            ),
            preview_kem_public=b64url_decode(
                value["preview_kem_pub"], field="preview_kem_pub", exact_bytes=32
            ),
            device_nonce=b64url_decode(
                value["device_nonce"], field="device_nonce", min_bytes=16, max_bytes=64
            ),
            push_bind_token=value["push_bind_token"],
            hub_activation_token=value["hub_activation_token"],
            pair_mac=b64url_decode(value["pair_mac"], field="pair_mac", exact_bytes=32),
        )


@dataclass(frozen=True, slots=True)
class PairingClaim:
    offer: PairOfferRecord
    pair_init: PairInit
    device_key_hash: bytes
    verification_code: str


class PairingManager:
    def __init__(
        self,
        storage: RelayStorage,
        identity: RelayIdentity,
        *,
        hub_url: str,
        relay_route: str,
        hub_client: HubClient | None = None,
        notification_sender: Any = None,
    ) -> None:
        self.storage = storage
        self.identity = identity
        self.hub_url = hub_url.rstrip("/")
        self.relay_route = relay_route
        self.hub_client = hub_client
        self.notification_sender = notification_sender

    def create_offer(
        self, *, ttl_seconds: int = 300, auto_approve: bool = False
    ) -> dict[str, Any]:
        offer = self.storage.create_pair_offer(
            relay_route=self.relay_route,
            ttl_seconds=ttl_seconds,
            auto_approve=auto_approve,
        )
        return self._qr_payload(offer)

    def _qr_payload(self, offer: PairOfferRecord) -> dict[str, Any]:
        # This is compact JSON/CBOR input for the QR, never a URL query string.
        return {
            "v": 2,
            "hub": self.hub_url,
            "relay_route": offer.relay_route,
            "offer_route": offer.offer_route,
            "offer_id": offer.offer_id,
            "offer_transport_token": offer.transport_token,
            "expires_at_ms": offer.expires_at_ms,
            "relay_kem_pub": b64url_encode(self.identity.kem_public),
            "relay_sign_pub": b64url_encode(self.identity.sign_public),
            "pair_secret": b64url_encode(offer.pair_secret),
        }

    async def create_registered_offer(
        self, *, ttl_seconds: int = 300, auto_approve: bool = False
    ) -> dict[str, Any]:
        if self.hub_client is None:
            raise RuntimeError("Hub client is required for hosted pairing")
        qr = self.create_offer(ttl_seconds=ttl_seconds, auto_approve=auto_approve)
        offer = self.storage.get_pair_offer(qr["offer_id"])
        assert offer is not None
        try:
            await self.hub_client.register_pair_offer(
                offer_id=offer.offer_id,
                offer_route=offer.offer_route,
                transport_token=offer.transport_token,
                owner_route=offer.relay_route,
                expires_at_ms=offer.expires_at_ms,
            )
        except Exception:
            # The Hub may have committed the exact idempotent offer while its
            # response was lost.  Keep all local authority and retry the same
            # persisted body; only explicit cancel/expiry erases it.
            raise
        self.storage.mark_pair_offer_registered(offer.offer_id)
        return qr

    async def register_existing_offer(self, offer_id: str) -> dict[str, Any]:
        if self.hub_client is None:
            raise RuntimeError("Hub client is required for hosted pairing")
        offer = self.storage.get_pair_offer(offer_id)
        if offer is None:
            raise NotFound()
        if offer.state != "pending":
            raise Conflict("Pairing offer is not pending")
        if not offer.hub_registered:
            await self.hub_client.register_pair_offer(
                offer_id=offer.offer_id,
                offer_route=offer.offer_route,
                transport_token=offer.transport_token,
                owner_route=offer.relay_route,
                expires_at_ms=offer.expires_at_ms,
            )
            self.storage.mark_pair_offer_registered(offer.offer_id)
            offer = self.storage.get_pair_offer(offer_id) or offer
        return self._qr_payload(offer)

    async def claim_ready_offer(self, offer_id: str) -> PairingClaim | None:
        if self.hub_client is None:
            raise RuntimeError("Hub client is required for hosted pairing")
        ready = await self.hub_client.get_pair_offer(offer_id)
        if ready.get("status") == "waiting":
            return None
        claim = self.decrypt_and_claim(
            offer_id,
            enc=b64url_decode(ready["enc"], field="enc", exact_bytes=32),
            ciphertext=b64url_decode(
                ready["ct"], field="ct", min_bytes=16, max_bytes=32768
            ),
        )
        # Keep the duplex offer alive: PairAccept still has to reach the phone.
        # The hash binds that response and the eventual atomic confirm/consume
        # to this exact PairInit ciphertext.
        self.storage.set_pair_offer_message_hash(offer_id, ready["message_hash"])
        return claim

    @staticmethod
    def offer_aad(offer: PairOfferRecord) -> bytes:
        return canonical_json({
            "v": 2,
            "offer_id": offer.offer_id,
            "offer_route": offer.offer_route,
            "relay_route": offer.relay_route,
            "expires_at_ms": offer.expires_at_ms,
        })

    @staticmethod
    def pair_mac(pair_secret: bytes, pair_init_without_mac: Mapping[str, Any]) -> bytes:
        return hmac.digest(
            pair_secret, canonical_json(dict(pair_init_without_mac)), "sha256"
        )

    def verification_transcript(
        self, offer: PairOfferRecord, pair_init: PairInit
    ) -> bytes:
        """Complete human-comparison transcript, excluding only ``pair_mac``."""

        return b"hermes-mobile/hrp2/pair/verification-code\x00" + canonical_json({
            "offer": {
                "v": 2,
                "offer_id": offer.offer_id,
                "offer_route": offer.offer_route,
                "relay_route": offer.relay_route,
                "expires_at_ms": offer.expires_at_ms,
                "relay_kem_pub": b64url_encode(self.identity.kem_public),
                "relay_sign_pub": b64url_encode(self.identity.sign_public),
            },
            "pair_init": pair_init.transcript_dict(),
        })

    def verification_code(self, offer: PairOfferRecord, pair_init: PairInit) -> str:
        code_int = (
            int.from_bytes(
                hmac.digest(
                    offer.pair_secret,
                    self.verification_transcript(offer, pair_init),
                    "sha256",
                )[:4],
                "big",
            )
            % 1_000_000
        )
        code = f"{code_int:06d}"
        return f"{code[:3]} {code[3:]}"

    def decrypt_and_claim(
        self, offer_id: str, *, enc: bytes, ciphertext: bytes
    ) -> PairingClaim:
        offer = self.storage.get_pair_offer(offer_id)
        if offer is None:
            raise NotFound()
        try:
            plaintext = open_base_message(
                enc,
                ciphertext,
                recipient_private_key=self.identity.kem_private,
                info=PAIR_INIT_INFO,
                aad=self.offer_aad(offer),
            )
            decoded = decode_strict_json(plaintext)
            if not isinstance(decoded, dict):
                raise InvalidArgument("Expected PairInit object")
            pair_init = PairInit.from_dict(decoded)
        except (InvalidArgument, Unauthenticated):
            raise
        if pair_init.offer_id != offer.offer_id:
            raise Unauthenticated("Pairing offer mismatch")
        expected = self.pair_mac(offer.pair_secret, pair_init.transcript_dict())
        if not hmac.compare_digest(expected, pair_init.pair_mac):
            raise Unauthenticated("Pairing transcript MAC failed")
        key_hash = hashlib.sha256(
            pair_init.device_kem_public
            + pair_init.device_sign_public
            + pair_init.preview_kem_public
        ).digest()
        try:
            claimed = self.storage.claim_pair_offer(offer_id, key_hash)
        except StorageNotFound as exc:
            raise NotFound() from exc
        except StorageExpired as exc:
            raise Expired() from exc
        except StorageConflict as exc:
            raise Conflict("Pairing offer already claimed") from exc
        return PairingClaim(
            claimed,
            pair_init,
            key_hash,
            self.verification_code(offer, pair_init),
        )

    def confirm_claim(
        self,
        claim: PairingClaim,
        *,
        device_route: str | None = None,
        push_binding_id: str | None = None,
    ) -> dict[str, Any]:
        offer = self.storage.get_pair_offer(claim.offer.offer_id)
        if offer is None:
            raise NotFound()
        if offer.device_key_hash != claim.device_key_hash:
            raise Conflict("Pairing claim changed")
        device = self.storage.register_device(
            name=claim.pair_init.device_name,
            route=device_route or random_id("rte"),
            kem_public=claim.pair_init.device_kem_public,
            sign_public=claim.pair_init.device_sign_public,
            preview_public=claim.pair_init.preview_kem_public,
        )
        self.storage.transition_pair_offer(
            offer.offer_id,
            expected="claimed",
            new_state="confirmed",
            device_id=device.device_id,
        )
        stream = self.storage.get_stream(device.device_id)
        capabilities = ["chat", "history", "approve_once", "deny"]
        if push_binding_id is not None:
            capabilities.append("notifications")
        return {
            "device_id": device.device_id,
            "relay_instance_id": self.identity.relay_instance_id,
            "device_route": device.route,
            "stream_id": stream.stream_id,
            "relay_key_generation": self.identity.kem_generation,
            "push_binding_id": push_binding_id,
            "capabilities": capabilities,
        }

    @staticmethod
    def pair_accept_aad(
        *, offer_id: str, device_route: str, message_hash: str
    ) -> bytes:
        return canonical_json({
            "v": 2,
            "offer_id": offer_id,
            "device_route": device_route,
            "message_hash": message_hash,
        })

    def _signed_grant(
        self, *, source_route: str, destination_route: str
    ) -> dict[str, Any]:
        grant: dict[str, Any] = {
            "grant_id": random_id("grt"),
            "issuer_route": self.relay_route,
            "source_route": source_route,
            "destination_route": destination_route,
            "permissions": ["send", "receive"],
            "expires_at_ms": None,
        }
        signature = ed25519.Ed25519PrivateKey.from_private_bytes(
            self.identity.sign_private
        ).sign(_grant_signature_payload(grant))
        grant["issuer_signature"] = b64url_encode(signature)
        return grant

    async def accept_claim(
        self,
        claim: PairingClaim,
    ) -> dict[str, Any]:
        """Create pending Hub authority and durably publish PairAccept.

        Route and grants stay pending.  The local device stays pending.  The
        offer secret/token remain available until a committed PairConfirm.
        """

        if self.hub_client is None:
            raise RuntimeError("Hub client is required for hosted pairing")
        offer = self.storage.get_pair_offer(claim.offer.offer_id)
        if offer is None:
            raise NotFound()
        if offer.device_key_hash != claim.device_key_hash:
            raise Conflict("Pairing claim changed")
        if (
            offer.state in {"pending", "claimed", "confirmed"}
            and offer.expires_at_ms <= self.storage.current_time_ms()
        ):
            self.storage.expire_pair_offers()
            raise Expired("Pairing offer expired")

        # A lost HTTP response retries the exact persisted PairAccept bytes.
        if offer.state == "confirmed":
            if not offer.device_id or not offer.accept_enc or not offer.accept_ct:
                raise Conflict("Incomplete durable PairAccept")
            device = self.storage.get_device(offer.device_id, include_inactive=True)
            if (
                device is None
                or not offer.hub_message_hash
                or not offer.hub_response_hash
            ):
                raise Conflict("Incomplete durable pairing authority")
            response = await self.hub_client.accept_pair_offer(
                offer_id=offer.offer_id,
                message_hash=offer.hub_message_hash,
                device_route=device.route,
                enc=offer.accept_enc,
                ciphertext=offer.accept_ct,
            )
            if response["response_hash"] != offer.hub_response_hash:
                raise Conflict("PairAccept retry hash changed")
            return {
                "device_id": device.device_id,
                "device_route": device.route,
                "response_hash": offer.hub_response_hash,
                "pair_accept_mid": offer.accept_mid,
                "resumed": True,
            }

        if offer.state != "claimed" or not offer.hub_message_hash:
            raise Conflict("PairInit is not ready for confirmation")
        acceptance_owner = secrets.token_urlsafe(24)
        if not self.storage.acquire_pair_acceptance(
            offer.offer_id, acceptance_owner
        ):
            # Another local process (normally the supervised relay or the
            # interactive CLI) owns acceptance. Never cancel its authority.
            for _ in range(40):
                await asyncio.sleep(0.05)
                current = self.storage.get_pair_offer(offer.offer_id)
                if current is not None and current.state == "confirmed":
                    return await self.accept_claim(claim)
                if current is None or current.state not in {"claimed", "confirmed"}:
                    raise Conflict("PairAccept is no longer claimable")
            raise Conflict("PairAccept is already being processed")

        def renew_acceptance() -> None:
            if not self.storage.renew_pair_acceptance(
                offer.offer_id, acceptance_owner
            ):
                raise _PairAcceptanceLeaseLost(
                    "PairAccept acceptance lease was lost"
                )

        try:
            relay_route = self.storage.hub_route(self.relay_route)
            if relay_route is None:
                raise Unauthenticated("Hub route enrollment state is unavailable")
            if relay_route["status"] != "active":
                token = claim.pair_init.hub_activation_token
                if not token:
                    raise Unauthenticated("Hub activation token is required")
                # Activation is exact-idempotent. A lost response leaves the
                # local route provisional so the same token/body is retried;
                # it must never cancel the independently persisted offer.
                renew_acceptance()
                await self.hub_client.activate_agent_route(activation_token=token)
                self.storage.store_hub_route(
                    route_id=self.relay_route,
                    kind="agent",
                    status="active",
                )
                self.storage.mark_agent_route_active(self.relay_route)
        except Exception:
            self.storage.release_pair_acceptance(
                offer.offer_id, acceptance_owner
            )
            raise
        durable_accept = False
        try:
            renew_acceptance()
            route = await self.hub_client.create_pending_device_route(
                auth_public_key=claim.pair_init.device_sign_public,
                offer_id=offer.offer_id,
            )
            device = self.storage.get_device_by_route(
                route["route_id"], include_inactive=True
            )
            if device is None:
                device = self.storage.register_device(
                    name=claim.pair_init.device_name,
                    route=route["route_id"],
                    kem_public=claim.pair_init.device_kem_public,
                    sign_public=claim.pair_init.device_sign_public,
                    preview_public=claim.pair_init.preview_kem_public,
                )
            elif (
                device.kem_public != claim.pair_init.device_kem_public
                or device.sign_public != claim.pair_init.device_sign_public
                or device.preview_public != claim.pair_init.preview_kem_public
                or device.status != "pending"
            ):
                raise Conflict("Pending route is bound to different device keys")
            # This association is the durable cleanup root.  It must precede
            # grants and especially the Push exchange so expiry/cancellation
            # can always find and fail-close every pending authority.
            self.storage.associate_pair_offer_device(offer.offer_id, device.device_id)
            self.storage.store_hub_route(
                route_id=device.route,
                kind="device",
                status="pending",
                expires_at_ms=offer.expires_at_ms,
            )
            stored_grants = self.storage.hub_grants_for_device(device.device_id)
            if stored_grants:
                grants = [
                    {
                        "grant_id": grant["grant_id"],
                        "issuer_route": self.relay_route,
                        "source_route": grant["source_route"],
                        "destination_route": grant["destination_route"],
                        "permissions": grant["permissions"],
                        "expires_at_ms": None,
                        "issuer_signature": b64url_encode(grant["issuer_signature"]),
                    }
                    for grant in stored_grants
                ]
            else:
                grants = [
                    self._signed_grant(
                        source_route=self.relay_route, destination_route=device.route
                    ),
                    self._signed_grant(
                        source_route=device.route, destination_route=self.relay_route
                    ),
                ]
            for grant in grants:
                self.storage.store_hub_grant(
                    grant_id=grant["grant_id"],
                    device_id=device.device_id,
                    source_route=grant["source_route"],
                    destination_route=grant["destination_route"],
                    permissions=grant["permissions"],
                    issuer_signature=b64url_decode(
                        grant["issuer_signature"],
                        field="issuer_signature",
                        exact_bytes=64,
                    ),
                    status="pending",
                )
                renew_acceptance()
                grant_response = await self.hub_client.create_grant(grant)
                if grant_response["status"] != "pending":
                    raise Conflict("Pairing grant activated before PairConfirm")
            stream = self.storage.get_stream(device.device_id)
            push_binding_id: str | None = None
            if claim.pair_init.push_bind_token is not None:
                if self.notification_sender is None:
                    raise RuntimeError(
                        "Push Gateway is required when PairInit includes push_bind_token"
                    )
                renew_acceptance()
                push_binding_id = await self.notification_sender.bind_device(
                    device.device_id, claim.pair_init.push_bind_token
                )
            capabilities = [
                "chat",
                "history",
                "approve_once",
                "deny",
            ]
            if claim.pair_init.push_bind_token is not None:
                capabilities.append("notifications")
            accept_body = {
                "device_id": device.device_id,
                "relay_instance_id": self.identity.relay_instance_id,
                "device_route": device.route,
                "stream_id": stream.stream_id,
                "relay_key_generation": self.identity.kem_generation,
                "push_binding_id": push_binding_id,
                "capabilities": capabilities,
            }
            accept_mid = b64url_encode(secrets.token_bytes(16))
            accept_message = SecureMessage(
                mid=accept_mid,
                kind=SecureMessageKind.PAIR_ACCEPT,
                sender_key_generation=self.identity.kem_generation,
                created_at_ms=min(
                    self.storage.current_time_ms(), offer.expires_at_ms - 1
                ),
                expires_at_ms=offer.expires_at_ms,
                body=accept_body,
            )
            enc, ciphertext = seal_authenticated_message(
                accept_message.to_bytes(),
                recipient_public_key=device.kem_public,
                sender_private_key=self.identity.kem_private,
                info=PAIR_ACCEPT_INFO,
                aad=self.pair_accept_aad(
                    offer_id=offer.offer_id,
                    device_route=device.route,
                    message_hash=offer.hub_message_hash,
                ),
            )
            self.storage.record_relay_encryption(self.identity.kem_generation)
            response_hash = b64url_encode(hashlib.sha256(enc + ciphertext).digest())
            self.storage.record_pair_accept(
                offer_id=offer.offer_id,
                device_id=device.device_id,
                enc=enc,
                ciphertext=ciphertext,
                response_hash=response_hash,
                accept_mid=accept_mid,
                accept_owner=acceptance_owner,
            )
            durable_accept = True
            # record_pair_accept atomically retires the acceptance lease.
            response = await self.hub_client.accept_pair_offer(
                offer_id=offer.offer_id,
                message_hash=offer.hub_message_hash,
                device_route=device.route,
                enc=enc,
                ciphertext=ciphertext,
            )
            if response["response_hash"] != response_hash:
                raise Conflict("PairAccept response hash changed")
            return {
                **accept_body,
                "grant_ids": [grant["grant_id"] for grant in grants],
                "response_hash": response_hash,
                "pair_accept_mid": accept_mid,
                "resumed": False,
            }
        except (HubUnavailable, ConnectionError, TimeoutError):
            # Every network mutation above is exact-idempotent and its request
            # material is persisted before send.  Preserve the claim/resources
            # so restart retries the same route, grants, binding, or accept.
            if not durable_accept:
                self.storage.release_pair_acceptance(
                    offer.offer_id, acceptance_owner
                )
            raise
        except _PairAcceptanceLeaseLost:
            # A newer process owns the right to continue; never cancel it.
            raise
        except Exception:
            if durable_accept:
                # The exact enc/ct is durable and can be retried safely after a
                # lost Hub response.  Never cancel a possibly-delivered accept.
                raise
            # The offer is the aggregate authority root for pending route and
            # grants.  Hub cancellation cascades those resources.  Local state
            # remains auditable/revocable and no credential is activated.
            try:
                await self.cancel_offer(offer.offer_id)
            except Exception:
                pass
            raise

    async def finalize_pair_confirm(
        self,
        *,
        offer_id: str,
        device_id: str,
        response_hash: str | None = None,
    ) -> None:
        offer = self.storage.get_pair_offer(offer_id)
        if offer is None:
            raise NotFound()
        if offer.device_id != device_id or offer.state not in {"confirmed", "consumed"}:
            raise Conflict("PairConfirm does not match the confirmed offer")
        if offer.state == "consumed":
            device = self.storage.get_device(device_id)
            if device is None or response_hash not in {None, offer.hub_response_hash}:
                raise Conflict("Consumed PairConfirm receipt mismatch")
            return
        if self.hub_client is None:
            if offer.state == "confirmed":
                self.storage.activate_device(device_id)
                self.storage.transition_pair_offer(
                    offer_id,
                    expected="confirmed",
                    new_state="consumed",
                    device_id=device_id,
                )
            self.storage.erase_pair_offer_secrets(offer_id)
            return
        device = self.storage.get_device(device_id, include_inactive=True)
        if (
            device is None
            or not offer.hub_message_hash
            or not offer.hub_response_hash
            or response_hash != offer.hub_response_hash
        ):
            raise Conflict("PairConfirm hashes do not match PairAccept")
        grants = self.storage.hub_grants_for_device(device_id)
        result = await self.hub_client.confirm_pair_offer(
            offer_id=offer_id,
            message_hash=offer.hub_message_hash,
            response_hash=offer.hub_response_hash,
            device_route=device.route,
        )
        expected_grants = {grant["grant_id"] for grant in grants}
        if set(result["grant_ids"]) != expected_grants:
            raise Conflict("Hub activated an unexpected grant set")
        self.storage.commit_pair_confirm(
            offer_id=offer_id,
            device_id=device_id,
            response_hash=offer.hub_response_hash,
            grant_ids=result["grant_ids"],
        )

    async def cancel_offer(self, offer_id: str) -> None:
        offer = self.storage.get_pair_offer(offer_id)
        if offer is None:
            return
        if offer.state in {"pending", "claimed", "confirmed"}:
            self.storage.transition_pair_offer(
                offer_id, expected=offer.state, new_state="cancelled"
            )
        self.storage.erase_pair_offer_secrets(offer_id)
        if self.hub_client is not None:
            try:
                await self.hub_client.cancel_pair_offer(offer_id)
            except NotFound:
                pass
        if offer.device_id and self.notification_sender is not None:
            try:
                await self.notification_sender.revoke_device_binding(offer.device_id)
            except Exception:
                # Cancellation remains durable locally; a later revoke sweep
                # retries remote capability deletion without retaining offer
                # authority.
                pass


__all__ = [
    "PAIR_ACCEPT_INFO",
    "PAIR_INIT_INFO",
    "PairInit",
    "PairingClaim",
    "PairingManager",
]
