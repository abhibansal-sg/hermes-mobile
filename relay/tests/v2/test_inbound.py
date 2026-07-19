from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from hermes_relay.v2.crypto import (
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
    open_authenticated_envelope,
    seal_authenticated_envelope,
)
from hermes_relay.v2.device_router import DeviceRouter
from hermes_relay.v2.identity import load_or_create_identity
from hermes_relay.v2.inbound import InboundProcessor
from hermes_relay.v2.errors import InvalidArgument, Revoked
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.protocol import (
    HPKEDirection,
    HPKEPurpose,
    OuterEnvelope,
    OuterHeader,
    ReceiveContext,
    SecureMessage,
    SecureMessageKind,
    TransportClass,
    b64url_encode,
)
from hermes_relay.v2.rpc import RPCDispatcher
from hermes_relay.v2.storage import RelayStorage


class Hub:
    def __init__(self):
        self.acks = []

    async def acknowledge(self, mids):
        self.acks.append(list(mids))
        return {"acknowledged": len(mids)}


class DormantSender:
    """Collect wake hints without starting a background send task."""

    def __init__(self) -> None:
        self.offers: list[str] = []

    def start(self) -> None:
        return None

    def offer(self, message_id: str) -> bool:
        self.offers.append(message_id)
        return True


def _active_device(store):
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    device = store.register_device(
        device_id="dev_inbound",
        name="Phone",
        route="rte_phone",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    store.activate_device(device.device_id)
    return store.get_device(device.device_id), kem, sign


def _envelope(
    identity,
    device,
    kem,
    sign,
    *,
    mid,
    kind,
    body,
    expiry=2_000,
    message_class=TransportClass.CONTROL,
    purpose=HPKEPurpose.CONTROL,
):
    header = OuterHeader(
        src=device.route,
        dst="rte_agent",
        mid=mid,
        message_class=message_class,
        expires_at_ms=expiry,
        recipient_key_generation=identity.kem_generation,
    )
    message = SecureMessage(
        mid=mid,
        kind=kind,
        sender_key_generation=device.kem_generation,
        created_at_ms=900,
        expires_at_ms=expiry,
        body=body,
    )
    return seal_authenticated_envelope(
        header,
        message,
        recipient_public_key=identity.kem_public,
        sender_private_key=kem.private_key,
        signing_private_key=sign.private_key,
        purpose=purpose,
        direction=HPKEDirection.DEVICE_TO_AGENT,
    )


async def test_rpc_commits_response_before_hub_ack_and_replay_is_not_reexecuted(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    device, kem, sign = _active_device(store)
    gateway = MagicMock()
    gateway.session_list = AsyncMock(return_value=[{"session_id": "sess"}])
    router = MagicMock()
    router.send_secure_message.return_value = "response_mid"
    dispatcher = RPCDispatcher(gateway, store, router)
    hub = Hub()
    processor = InboundProcessor(store, hub, dispatcher, relay_route="rte_agent")
    mid = b64url_encode(b"i" * 16)
    envelope = _envelope(
        identity,
        device,
        kem,
        sign,
        mid=mid,
        kind=SecureMessageKind.RPC_REQUEST,
        body={
            "jsonrpc": "2.0",
            "id": "rpc_inbound",
            "method": "session.list",
            "params": {},
        },
        message_class=TransportClass.COMMAND,
        purpose=HPKEPurpose.CHAT,
    )
    assert await processor.process(envelope) is True
    gateway.session_list.assert_awaited_once()
    router.send_secure_message.assert_called_once()
    assert store.has_seen_message(device.device_id, mid)
    assert hub.acks == [[mid]]

    assert await processor.process(envelope) is False
    gateway.session_list.assert_awaited_once()
    router.send_secure_message.assert_called_once()
    assert hub.acks == [[mid], [mid]]


async def test_pending_device_can_commit_only_exact_pair_confirm(tmp_path) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    device = store.register_device(
        device_id="dev_pending",
        name="Phone",
        route="rte_pending",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    offer = store.create_pair_offer(relay_route="rte_agent")
    store.claim_pair_offer(offer.offer_id, b"h" * 32)
    assert store.acquire_pair_acceptance(offer.offer_id, "inbound-test-owner")
    store.associate_pair_offer_device(offer.offer_id, device.device_id)
    store.set_pair_offer_message_hash(offer.offer_id, b64url_encode(b"m" * 32))
    response_hash = b64url_encode(b"r" * 32)
    accept_mid = b64url_encode(b"a" * 16)
    store.record_pair_accept(
        offer_id=offer.offer_id,
        device_id=device.device_id,
        enc=b"e" * 32,
        ciphertext=b"c" * 32,
        response_hash=response_hash,
        accept_mid=accept_mid,
        accept_owner="inbound-test-owner",
    )

    pairing = MagicMock()

    async def finalize(**kwargs):
        assert kwargs == {
            "offer_id": offer.offer_id,
            "device_id": device.device_id,
            "response_hash": response_hash,
        }
        store.activate_device(device.device_id)
        store.transition_pair_offer(
            offer.offer_id,
            expected="confirmed",
            new_state="consumed",
            device_id=device.device_id,
        )

    pairing.finalize_pair_confirm = finalize
    dispatcher = MagicMock()
    dispatcher.router = MagicMock()
    hub = Hub()
    processor = InboundProcessor(
        store,
        hub,
        dispatcher,
        relay_route="rte_agent",
        pairing=pairing,
    )
    mid = b64url_encode(b"p" * 16)
    envelope = _envelope(
        identity,
        store.get_device(device.device_id, include_inactive=True),
        kem,
        sign,
        mid=mid,
        kind=SecureMessageKind.PAIR_CONFIRM,
        body={
            "offer_id": offer.offer_id,
            "device_id": device.device_id,
            "response_hash": response_hash,
            "pair_accept_mid": accept_mid,
        },
    )
    assert await processor.process(envelope) is True
    assert store.get_device(device.device_id).status == "active"
    assert store.get_pair_offer(offer.offer_id).state == "consumed"
    assert hub.acks == [[mid]]


async def test_command_outer_class_rejects_non_rpc_kind_after_authentication(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    device, kem, sign = _active_device(store)
    dispatcher = MagicMock()
    dispatcher.router = MagicMock()
    hub = Hub()
    processor = InboundProcessor(store, hub, dispatcher, relay_route="rte_agent")
    envelope = _envelope(
        identity,
        device,
        kem,
        sign,
        mid=b64url_encode(b"x" * 16),
        kind=SecureMessageKind.STREAM_ACK,
        body={
            "stream_id": store.get_stream(device.device_id).stream_id,
            "through_seq": 0,
        },
        message_class=TransportClass.COMMAND,
        purpose=HPKEPurpose.CHAT,
    )
    with pytest.raises(InvalidArgument, match="invalid for outer class"):
        await processor.process(envelope)
    assert hub.acks == []


async def test_delivery_receipt_crash_window_replays_tombstone_and_reacks(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    device, kem, sign = _active_device(store)
    target_mid = b64url_encode(b"t" * 16)
    store.enqueue_envelope(
        device.device_id,
        {"mid": target_mid},
        message_class=TransportClass.CONTROL.value,
        expires_at_ms=2_000,
    )
    dispatcher = MagicMock()
    dispatcher.router = MagicMock()
    hub = Hub()
    processor = InboundProcessor(store, hub, dispatcher, relay_route="rte_agent")
    receipt_mid = b64url_encode(b"d" * 16)
    envelope = _envelope(
        identity,
        device,
        kem,
        sign,
        mid=receipt_mid,
        kind=SecureMessageKind.DELIVERY_RECEIPT,
        body={"mid": target_mid},
    )

    original_mark_seen = store.mark_seen_message

    def crash_before_seen(*_args, **_kwargs):
        raise RuntimeError("simulated process death")

    store.mark_seen_message = crash_before_seen
    with pytest.raises(RuntimeError, match="process death"):
        await processor.process(envelope)
    assert hub.acks == []
    tombstone = store._conn.execute(
        "SELECT state,envelope_json FROM outbox WHERE device_id=? AND message_id=?",
        (device.device_id, target_mid),
    ).fetchone()
    assert (
        tombstone["state"] == "delivered" and bytes(tombstone["envelope_json"]) == b"{}"
    )

    store.mark_seen_message = original_mark_seen
    assert await processor.process(envelope) is True
    assert hub.acks == [[receipt_mid]]


async def test_self_revoke_commits_replay_receipt_with_local_revocation(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    device, kem, sign = _active_device(store)
    dispatcher = MagicMock()
    dispatcher.router = MagicMock()
    hub = Hub()
    processor = InboundProcessor(store, hub, dispatcher, relay_route="rte_agent")
    mid = b64url_encode(b"v" * 16)
    envelope = _envelope(
        identity,
        device,
        kem,
        sign,
        mid=mid,
        kind=SecureMessageKind.DEVICE_REVOKE,
        body={"device_id": device.device_id},
    )
    # The local revoke and seen marker are one SQLite transaction.  The normal
    # post-apply marker therefore reports duplicate, while Hub ACK still fires.
    assert await processor.process(envelope) is False
    assert store.get_device(device.device_id, include_inactive=True).status == "revoked"
    assert store.has_seen_message(device.device_id, mid)
    assert await processor.process(envelope) is False
    assert hub.acks == [[mid], [mid]]


@pytest.mark.parametrize("purpose", ["kem", "preview"])
async def test_device_rotation_commits_exact_authenticated_receipt_before_hub_ack(
    tmp_path, purpose
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=protector,
    )
    identity = load_or_create_identity(store, protector=protector)
    device, kem, sign = _active_device(store)
    candidate = generate_x25519_key_pair()
    hub = Hub()
    router = DeviceRouter(
        store, identity, hub, relay_route="rte_agent", clock_ms=lambda: 1_000
    )
    dormant = DormantSender()
    router._sender = lambda _device_id: dormant
    dispatcher = RPCDispatcher(MagicMock(), store, router)
    processor = InboundProcessor(store, hub, dispatcher, relay_route="rte_agent")
    inbound_mid = b64url_encode((b"k" if purpose == "kem" else b"p") * 16)
    envelope = _envelope(
        identity,
        device,
        kem,
        sign,
        mid=inbound_mid,
        kind=SecureMessageKind.KEY_ROTATE,
        body={
            "purpose": purpose,
            "generation": 2,
            "public_key": b64url_encode(candidate.public_key),
            "previous_not_after_ms": 5_000,
        },
    )

    original_mark_seen = store.mark_seen_message

    def crash_before_seen(*_args, **_kwargs):
        raise RuntimeError("simulated process death")

    store.mark_seen_message = crash_before_seen
    with pytest.raises(RuntimeError, match="process death"):
        await processor.process(envelope)
    assert hub.acks == []
    link = store.inbound_delivery_receipt(device.device_id, inbound_mid)
    assert link is not None and link.state == "pending"
    receipt = store.outbox_record(device.device_id, link.outbound_message_id)
    assert receipt is not None
    assert receipt.completion_policy == "hub_accept"
    exact_envelope = receipt.envelope

    rotated_device = store.get_device(device.device_id)
    recipient_private_keys = {
        rotated_device.kem_generation: (
            candidate.private_key if purpose == "kem" else kem.private_key
        )
    }
    opened = open_authenticated_envelope(
        OuterEnvelope.from_dict(exact_envelope),
        recipient_private_keys=recipient_private_keys,
        sender_public_keys={identity.kem_generation: identity.kem_public},
        signing_public_key=identity.sign_public,
        purpose=HPKEPurpose.CONTROL,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination=device.route,
            expected_source="rte_agent",
            now_ms=1_000,
        ),
    )
    assert opened.kind is SecureMessageKind.DELIVERY_RECEIPT
    assert opened.body == {"mid": inbound_mid}

    # Reopen after the post-apply crash.  Idempotent key application must wake
    # the same ciphertext, and the subsequent seen replay must only re-offer it.
    store.mark_seen_message = original_mark_seen
    store.close()
    reopened = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=protector,
    )
    restarted_identity = load_or_create_identity(reopened, protector=protector)
    restarted_router = DeviceRouter(
        reopened,
        restarted_identity,
        hub,
        relay_route="rte_agent",
        clock_ms=lambda: 1_000,
    )
    restarted_dormant = DormantSender()
    restarted_router._sender = lambda _device_id: restarted_dormant
    restarted = InboundProcessor(
        reopened,
        hub,
        RPCDispatcher(MagicMock(), reopened, restarted_router),
        relay_route="rte_agent",
    )
    assert await restarted.process(envelope) is True
    assert await restarted.process(envelope) is False
    recovered_link = reopened.inbound_delivery_receipt(device.device_id, inbound_mid)
    assert recovered_link == link
    recovered = reopened.outbox_record(device.device_id, link.outbound_message_id)
    assert recovered is not None and recovered.envelope == exact_envelope
    assert restarted_dormant.offers == [link.outbound_message_id] * 2
    assert hub.acks == [[inbound_mid], [inbound_mid]]


async def test_revoked_device_rotation_never_creates_agent_receipt(tmp_path) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    device, kem, sign = _active_device(store)
    candidate = generate_x25519_key_pair()
    store.revoke_device(device.device_id)
    hub = Hub()
    router = DeviceRouter(store, identity, hub, relay_route="rte_agent")
    router._sender = lambda _device_id: DormantSender()
    processor = InboundProcessor(
        store,
        hub,
        RPCDispatcher(MagicMock(), store, router),
        relay_route="rte_agent",
    )
    inbound_mid = b64url_encode(b"r" * 16)
    envelope = _envelope(
        identity,
        device,
        kem,
        sign,
        mid=inbound_mid,
        kind=SecureMessageKind.KEY_ROTATE,
        body={
            "purpose": "kem",
            "generation": 2,
            "public_key": b64url_encode(candidate.public_key),
            "previous_not_after_ms": 5_000,
        },
    )
    with pytest.raises(Revoked):
        await processor.process(envelope)
    assert store.inbound_delivery_receipt(device.device_id, inbound_mid) is None
    assert store.pending_outbox(device.device_id) == []
    assert hub.acks == []
