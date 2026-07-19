"""Authenticated HRP/2 inbound envelope processor."""

from __future__ import annotations

from collections.abc import Awaitable, Callable, Mapping
from typing import Any

from .crypto import open_authenticated_envelope
from .errors import Conflict, InvalidArgument, ProtocolError, ReplayDetected, Revoked
from .hub_client import HubClient
from .identity import relay_private_kem_generations
from .pairing import PairingManager
from .protocol import (
    HPKEDirection,
    HPKEPurpose,
    OuterEnvelope,
    ReceiveContext,
    SecureMessage,
    SecureMessageKind,
    TransportClass,
    b64url_decode,
)
from .rpc import RPCDispatcher, RPCRequest, RPCResponse
from .storage import RelayStorage, StorageConflict


def _strict(value: Mapping[str, Any], fields: set[str]) -> dict[str, Any]:
    if not isinstance(value, Mapping) or set(value) != fields:
        missing_or_extra = fields.symmetric_difference(
            set(value) if isinstance(value, Mapping) else set()
        )
        raise InvalidArgument(
            details={
                "field": sorted(missing_or_extra)[0] if missing_or_extra else "body"
            }
        )
    return dict(value)


class InboundProcessor:
    def __init__(
        self,
        storage: RelayStorage,
        hub: HubClient,
        dispatcher: RPCDispatcher,
        *,
        relay_route: str,
        pairing: PairingManager | None = None,
        revoke_device: Callable[..., Awaitable[None]] | None = None,
    ) -> None:
        self.storage = storage
        self.hub = hub
        self.dispatcher = dispatcher
        self.router = dispatcher.router
        self.relay_route = relay_route
        self.pairing = pairing
        self._revoke_device = revoke_device

    async def run(self) -> None:
        async for envelope in self.hub.receive():
            try:
                await self.process(envelope)
            except Exception:
                # Authentication/validation failures are intentionally not
                # acknowledged.  The Hub sees no decrypted error detail.
                continue

    async def process(self, envelope: OuterEnvelope) -> bool:
        device = self.storage.get_device_by_route(envelope.src, include_inactive=True)
        if device is None:
            raise Revoked()
        if device.status == "revoked":
            if self.storage.has_seen_message(device.device_id, envelope.mid):
                await self.hub.acknowledge([envelope.mid])
                return False
            raise Revoked()
        if envelope.dst != self.relay_route:
            raise InvalidArgument(details={"field": "dst"})
        if (
            device.status == "pending"
            and envelope.message_class != TransportClass.CONTROL
        ):
            raise Revoked("Pending devices may send only PairConfirm control")
        if envelope.message_class == TransportClass.COMMAND:
            purpose = HPKEPurpose.CHAT
        elif envelope.message_class == TransportClass.CONTROL:
            purpose = HPKEPurpose.CONTROL
        else:
            raise InvalidArgument(details={"field": "class"})
        seen = (
            {envelope.mid}
            if self.storage.has_seen_message(device.device_id, envelope.mid)
            else set()
        )
        try:
            message = open_authenticated_envelope(
                envelope,
                recipient_private_keys=relay_private_kem_generations(self.storage),
                sender_public_keys=self.storage.device_public_kem_generations(
                    device.device_id
                ),
                signing_public_key=device.sign_public,
                purpose=purpose,
                direction=HPKEDirection.DEVICE_TO_AGENT,
                receive=ReceiveContext(
                    expected_destination=self.relay_route,
                    expected_source=device.route,
                    now_ms=self.storage.current_time_ms(),
                    seen_message_ids=seen,
                ),
            )
        except ReplayDetected:
            # It was previously authenticated and committed.  Re-ACK so a lost
            # delivery-ACK cannot pin it in the mailbox forever.  A committed
            # device rotation may also have an exact Agent receipt awaiting
            # transport; wake that row without ever minting a receipt for an
            # unrelated replay (especially a receipt-of-receipt).
            reoffer = getattr(self.router, "reoffer_delivery_receipt", None)
            if callable(reoffer):
                reoffer(device.device_id, envelope.mid)
            await self.hub.acknowledge([envelope.mid])
            return False

        self._validate_kind_class(envelope.message_class, message.kind)
        await self._apply(device.device_id, device.status, envelope, message)
        committed = self.storage.mark_seen_message(
            device.device_id, envelope.mid, expires_at_ms=envelope.expires_at_ms
        )
        await self.hub.acknowledge([envelope.mid])
        return committed

    @staticmethod
    def _validate_kind_class(
        message_class: TransportClass, kind: SecureMessageKind
    ) -> None:
        allowed = {
            TransportClass.COMMAND: {SecureMessageKind.RPC_REQUEST},
            TransportClass.CONTROL: {
                SecureMessageKind.PAIR_CONFIRM,
                SecureMessageKind.STREAM_ACK,
                SecureMessageKind.SYNC_REQUEST,
                SecureMessageKind.KEY_ROTATE,
                SecureMessageKind.DEVICE_REVOKE,
                SecureMessageKind.DELIVERY_RECEIPT,
            },
        }
        if kind not in allowed.get(message_class, set()):
            raise InvalidArgument(
                "Secure-message kind is invalid for outer class",
                details={"field": "kind"},
            )

    async def _apply(
        self,
        device_id: str,
        device_status: str,
        envelope: OuterEnvelope,
        message: SecureMessage,
    ) -> None:
        kind = message.kind
        body = message.body
        if device_status == "pending" and kind != SecureMessageKind.PAIR_CONFIRM:
            raise Revoked("Pending device sent non-pairing control")
        if kind == SecureMessageKind.PAIR_CONFIRM:
            if self.pairing is None:
                raise Conflict("Pairing manager is unavailable")
            values = _strict(
                body,
                {"offer_id", "device_id", "response_hash", "pair_accept_mid"},
            )
            if values["device_id"] != device_id:
                raise Conflict("PairConfirm device mismatch")
            offer = self.storage.get_pair_offer(str(values["offer_id"]))
            if (
                offer is None
                or offer.device_id != device_id
                or offer.accept_mid != values["pair_accept_mid"]
                or offer.hub_response_hash != values["response_hash"]
            ):
                raise Conflict("PairConfirm transcript mismatch")
            await self.pairing.finalize_pair_confirm(
                offer_id=offer.offer_id,
                device_id=device_id,
                response_hash=values["response_hash"],
            )
            return
        if kind == SecureMessageKind.RPC_REQUEST:
            await self._rpc(device_id, body)
            return
        if kind == SecureMessageKind.STREAM_ACK:
            values = _strict(body, {"stream_id", "through_seq"})
            stream = self.storage.get_stream(device_id)
            if values["stream_id"] != stream.stream_id:
                raise Conflict("stream_id mismatch")
            through = values["through_seq"]
            if isinstance(through, bool) or not isinstance(through, int) or through < 0:
                raise InvalidArgument(details={"field": "through_seq"})
            self.storage.acknowledge_stream(device_id, through)
            return
        if kind == SecureMessageKind.DELIVERY_RECEIPT:
            values = _strict(body, {"mid"})
            if not isinstance(values["mid"], str):
                raise InvalidArgument(details={"field": "mid"})
            if not self.storage.acknowledge_delivery(device_id, values["mid"]):
                raise Conflict("delivery receipt does not match outbox")
            return
        if kind == SecureMessageKind.SYNC_REQUEST:
            values = _strict(body, {"session_id", "stream_id", "last_seq"})
            stream = self.storage.get_stream(device_id)
            if values["stream_id"] != stream.stream_id:
                raise Conflict("stream_id mismatch")
            self.router.enqueue_checkpoint(device_id, str(values["session_id"]))
            return
        if kind == SecureMessageKind.KEY_ROTATE:
            values = _strict(
                body, {"purpose", "generation", "public_key", "previous_not_after_ms"}
            )
            if values["purpose"] not in {"kem", "preview"}:
                raise InvalidArgument(details={"field": "purpose"})
            public = b64url_decode(
                values["public_key"], field="public_key", exact_bytes=32
            )
            self.storage.rotate_device_key(
                device_id,
                purpose=values["purpose"],
                generation=values["generation"],
                public_key=public,
                previous_not_after_ms=values["previous_not_after_ms"],
            )
            self.router.send_delivery_receipt(device_id, envelope.mid)
            return
        if kind == SecureMessageKind.DEVICE_REVOKE:
            values = _strict(body, {"device_id"})
            if values["device_id"] != device_id:
                raise Conflict("device revoke scope mismatch")
            if self._revoke_device is not None:
                await self._revoke_device(
                    device_id,
                    inbound_message_id=envelope.mid,
                    inbound_expires_at_ms=envelope.expires_at_ms,
                )
            else:
                self.storage.queue_device_revocation(
                    device_id,
                    inbound_message_id=envelope.mid,
                    inbound_expires_at_ms=envelope.expires_at_ms,
                )
            return
        raise InvalidArgument(
            "Unsupported secure-message kind", details={"kind": kind.value}
        )

    async def _rpc(self, device_id: str, body: Mapping[str, Any]) -> None:
        request_id = body.get("id") if isinstance(body, Mapping) else None
        try:
            request = RPCRequest.from_dict(body, now_ms=self.storage.current_time_ms())
            response = await self.dispatcher.dispatch(device_id, request)
        except ProtocolError as exc:
            if not isinstance(request_id, str) or not request_id:
                raise
            response = RPCResponse(request_id, error=exc)
        self.router.send_secure_message(
            device_id,
            SecureMessageKind.RPC_RESPONSE,
            response.to_dict(),
            message_class=TransportClass.CONTROL,
        )


__all__ = ["InboundProcessor"]
