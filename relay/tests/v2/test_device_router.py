from __future__ import annotations

import asyncio

from hermes_relay.v2.crypto import (
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
    open_authenticated_envelope,
)
from hermes_relay.v2.device_router import (
    DeviceRouter,
    DeviceSender,
    frame_transport_class,
)
from hermes_relay.v2.identity import load_or_create_identity
from hermes_relay.v2.protocol import (
    HPKEDirection,
    HPKEPurpose,
    OuterEnvelope,
    ReceiveContext,
    SecureMessageKind,
    TransportClass,
    b64url_encode,
)
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.storage import RelayStorage


class Hub:
    def __init__(self) -> None:
        self.slow_route = "rte_slow"
        self.release = asyncio.Event()
        self.delivered: list[str] = []

    async def send_envelope(self, envelope: OuterEnvelope):
        if envelope.dst == self.slow_route:
            await self.release.wait()
        self.delivered.append(envelope.dst)
        return {"accepted": True, "mid": envelope.mid}


class FlakyHub:
    def __init__(self, failures: int) -> None:
        self.failures = failures
        self.calls = 0
        self.delivered = []

    async def send_envelope(self, envelope: OuterEnvelope):
        self.calls += 1
        if self.calls <= self.failures:
            raise ConnectionError("Hub unavailable")
        self.delivered.append(envelope.mid)
        return {"accepted": True, "mid": envelope.mid}


class LaneHub:
    def __init__(self, *, available: bool) -> None:
        self.available = available
        self.envelopes = []

    async def send_envelope(self, envelope: OuterEnvelope):
        self.envelopes.append(envelope)
        if not self.available:
            raise ConnectionError("offline")
        return {
            "accepted": True,
            "deduplicated": False,
            "stored": envelope.message_class != TransportClass.REALTIME,
            "mid": envelope.mid,
        }


class CollapseHub:
    def __init__(self) -> None:
        self.mailbox = {}

    async def send_envelope(self, envelope: OuterEnvelope):
        key = (
            envelope.dst,
            envelope.message_class.value,
            envelope.collapse or envelope.mid,
        )
        self.mailbox[key] = envelope
        return {
            "accepted": True,
            "deduplicated": False,
            "stored": True,
            "mid": envelope.mid,
        }


class ReceiptHub:
    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.attempt = 0

    async def send_envelope(self, envelope: OuterEnvelope):
        self.calls.append(envelope.to_dict())
        self.attempt += 1
        if self.attempt == 1:
            raise ConnectionError("offline before acceptance")
        if self.attempt == 2:
            return {
                "accepted": True,
                "deduplicated": False,
                "stored": True,
                "mid": envelope.mid,
            }
        return {
            "accepted": True,
            "deduplicated": True,
            "stored": False,
            "mid": envelope.mid,
        }


class DormantSender:
    def start(self) -> None:
        return None

    def offer(self, _message_id: str) -> bool:
        return True


def _register(store: RelayStorage, name: str, route: str):
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    device = store.register_device(
        device_id=f"dev_{name}",
        name=name,
        route=route,
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    store.activate_device(device.device_id)
    store.set_subscription(device.device_id, "session", active=True)
    return store.get_device(device.device_id), kem


async def test_slow_device_never_blocks_fast_device_and_ciphertext_is_durable(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path, credential_protector=FilePermissionFallbackProtector()
    )
    identity = load_or_create_identity(store)
    slow, slow_kem = _register(store, "slow", "rte_slow")
    fast, fast_kem = _register(store, "fast", "rte_fast")
    hub = Hub()
    router = DeviceRouter(
        store,
        identity,
        hub,
        relay_route="rte_agent",
        clock_ms=lambda: 1_000_000,
    )
    assert (
        router.publish_frames(
            "session",
            [{"sid": "session", "turn": "turn", "kind": "status", "body": {}}],
        )
        == 2
    )

    for _ in range(100):
        if "rte_fast" in hub.delivered:
            break
        await asyncio.sleep(0)
    assert hub.delivered == ["rte_fast"]
    assert len(store.pending_outbox(slow.device_id)) == 1

    hub.release.set()
    for _ in range(100):
        if "rte_slow" in hub.delivered:
            break
        await asyncio.sleep(0)
    assert set(hub.delivered) == {"rte_fast", "rte_slow"}

    # Exact persisted envelope remains independently decryptable and carries no
    # plaintext fields at the Hub boundary.
    row = store.pending_outbox(fast.device_id)[0]
    assert "session" not in str(row.envelope)
    envelope = OuterEnvelope.from_dict(row.envelope)
    inner = open_authenticated_envelope(
        envelope,
        recipient_private_keys={1: fast_kem.private_key},
        sender_public_keys={identity.kem_generation: identity.kem_public},
        signing_public_key=identity.sign_public,
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination=fast.route,
            expected_source="rte_agent",
            now_ms=1_000_001,
        ),
    )
    assert inner.body["stream_id"] == store.get_stream(fast.device_id).stream_id
    await router.close()


async def test_startup_outbox_retries_on_timer_without_new_wake(tmp_path) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, _kem = _register(store, "restart", "rte_restart")
    staging = DeviceRouter(
        store,
        identity,
        FlakyHub(0),
        relay_route="rte_agent",
        clock_ms=lambda: 1_000,
    )
    durable = staging._enqueue_frame_batch(
        device,
        [{"sid": "session", "turn": "turn", "kind": "status", "body": {}}],
    )
    store.close()

    reopened = RelayStorage(
        tmp_path, clock=lambda: 1_000, credential_protector=protector
    )
    restarted_identity = load_or_create_identity(reopened, protector=protector)
    hub = FlakyHub(2)
    router = DeviceRouter(
        reopened,
        restarted_identity,
        hub,
        relay_route="rte_agent",
        clock_ms=lambda: 1_000,
        retry_initial_s=0.001,
        retry_max_s=0.002,
        retry_jitter=lambda delay: delay,
    )
    router.start()
    for _ in range(100):
        if hub.delivered:
            break
        await asyncio.sleep(0.001)
    assert hub.calls == 3
    assert hub.delivered == [durable.message_id]
    assert reopened.pending_outbox(device.device_id)[0].state == "hub_accepted"
    await asyncio.sleep(0.005)
    assert hub.calls == 3  # accepted rows do not busy-loop or resend
    await router.close()


async def test_agent_receipt_retries_exactly_and_completes_on_hub_storage_or_dedup(
    tmp_path, monkeypatch
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    device, _kem = _register(store, "receipt", "rte_receipt")
    hub = ReceiptHub()
    router = DeviceRouter(
        store, identity, hub, relay_route="rte_agent", clock_ms=lambda: 1_000
    )
    router._sender = lambda _device_id: DormantSender()
    inbound_mid = b64url_encode(b"i" * 16)
    outbound_mid = router.send_delivery_receipt(device.device_id, inbound_mid)
    row = store.outbox_record(device.device_id, outbound_mid)
    assert row is not None and row.completion_policy == "hub_accept"
    assert store.acknowledge_delivery(device.device_id, outbound_mid) is False

    sender = DeviceSender(
        device.device_id,
        store,
        hub,
        clock_ms=lambda: 1_000,
        jitter=lambda delay: delay,
    )
    assert await sender.flush_once() == 0
    assert store.outbox_record(device.device_id, outbound_mid) is not None

    complete = store.complete_hub_accept_delivery_receipt

    def crash_after_hub_accept(*_args, **_kwargs):
        raise RuntimeError("crash before local completion")

    monkeypatch.setattr(
        store, "complete_hub_accept_delivery_receipt", crash_after_hub_accept
    )
    assert await sender.flush_once() == 0
    assert store.outbox_record(device.device_id, outbound_mid) is not None
    assert (
        store.inbound_delivery_receipt(device.device_id, inbound_mid).state == "pending"
    )

    monkeypatch.setattr(store, "complete_hub_accept_delivery_receipt", complete)
    assert await sender.flush_once() == 1
    assert hub.calls[0] == hub.calls[1] == hub.calls[2]
    assert store.outbox_record(device.device_id, outbound_mid) is None
    assert (
        store.inbound_delivery_receipt(device.device_id, inbound_mid).state
        == "hub_accepted"
    )

    # Completed semantic replay returns the original MID without recreating an
    # outbox row.  No inner receipt is required or accepted for this envelope.
    assert router.send_delivery_receipt(device.device_id, inbound_mid) == outbound_mid
    assert store.outbox_record(device.device_id, outbound_mid) is None


async def test_normal_turn_gap_recovers_with_unsequenced_authoritative_checkpoint(
    tmp_path,
) -> None:
    """A missing normal event must not prevent the recovery message itself."""

    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, device_kem = _register(store, "gap", "rte_gap")
    router = DeviceRouter(
        store,
        identity,
        FlakyHub(0),
        relay_route="rte_agent",
    )
    source_frames = [
        {"sid": "session", "turn": "turn_1", "kind": "turn.started", "body": {}},
        {
            "sid": "session",
            "turn": "turn_1",
            "kind": "item.started",
            "body": {
                "item_id": "gateway_item",
                "type": "agentMessage",
                "status": "in_progress",
                "ord": 0,
                "summary": "",
                "body": {"text": ""},
            },
        },
        {
            "sid": "session",
            "turn": "turn_1",
            "kind": "status",
            "body": {"kind": "thinking", "text": "working"},
        },
        {
            "sid": "session",
            "turn": "turn_1",
            "kind": "approval.request",
            "body": {"request_id": "approval_1"},
        },
        {
            "sid": "session",
            "turn": "turn_1",
            "kind": "clarify.request",
            "body": {"request_id": "clarify_1"},
        },
        {
            "sid": "session",
            "turn": "turn_1",
            "kind": "item.delta",
            "body": {"item_id": "gateway_item", "patch": {"text": "hello"}},
        },
        {
            "sid": "session",
            "turn": "turn_1",
            "kind": "item.completed",
            "body": {
                "item_id": "gateway_item",
                "type": "agentMessage",
                "status": "completed",
                "ord": 0,
                "summary": "hello",
                "body": {"text": "hello"},
            },
        },
        {
            "sid": "session",
            "turn": "turn_1",
            "kind": "title",
            "body": {"title": "Recovered turn"},
        },
        {"sid": "session", "turn": "turn_1", "kind": "turn.completed", "body": {}},
    ]
    records = []
    for source in source_frames:
        projected = router.projection.apply(source)
        assert projected is not None
        records.append(router._enqueue_frame_batch(device, [projected]))

    assert [row.first_seq for row in records] == list(range(1, 10))
    # Model the phone receiving 1..2, losing status at 3, then observing 4.
    assert records[3].first_seq > records[1].last_seq + 1

    checkpoint_record = router.enqueue_checkpoint(device.device_id, "session")
    assert checkpoint_record.first_seq == checkpoint_record.last_seq == 9
    assert store.get_stream(device.device_id).next_seq == 10
    checkpoint = open_authenticated_envelope(
        OuterEnvelope.from_dict(checkpoint_record.envelope),
        recipient_private_keys={1: device_kem.private_key},
        sender_public_keys={identity.kem_generation: identity.kem_public},
        signing_public_key=identity.sign_public,
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination=device.route,
            expected_source="rte_agent",
            now_ms=store.current_time_ms(),
        ),
    )
    assert checkpoint.kind is SecureMessageKind.CHECKPOINT
    assert checkpoint.body["through_seq"] == 9
    assert checkpoint.body["stream_id"] == store.get_stream(device.device_id).stream_id
    assert [item["body"]["text"] for item in checkpoint.body["items"]] == ["hello"]

    after = router._enqueue_frame_batch(
        device,
        [
            {
                "sid": "session",
                "turn": None,
                "kind": "status",
                "body": {"kind": "idle"},
            }
        ],
    )
    assert after.first_seq == checkpoint.body["through_seq"] + 1
    assert store.acknowledge_stream(device.device_id, 9) == 10
    assert [row.message_id for row in store.pending_outbox(device.device_id)] == [
        after.message_id
    ]
    await router.close()


async def test_initial_checkpoint_is_removed_by_boundary_zero_stream_ack(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, _device_kem = _register(store, "initial", "rte_initial")
    router = DeviceRouter(store, identity, FlakyHub(0), relay_route="rte_agent")
    checkpoint = router.enqueue_checkpoint(device.device_id, "session")
    assert checkpoint.first_seq == checkpoint.last_seq == 0
    assert store.acknowledge_stream(device.device_id, 0) == 1
    assert store.pending_outbox(device.device_id) == []
    await router.close()


async def test_reordered_checkpoints_have_strictly_monotonic_revisions(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, device_kem = _register(store, "checkpoint-order", "rte_checkpoint_order")
    router = DeviceRouter(store, identity, FlakyHub(0), relay_route="rte_agent")

    older_row = router.enqueue_checkpoint(device.device_id, "session")
    assert (
        router.publish({
            "sid": "session",
            "turn": "turn_checkpoint",
            "kind": "item.completed",
            "body": {
                "item_id": "source_checkpoint",
                "type": "agentMessage",
                "status": "completed",
                "ord": 0,
                "summary": "new",
                "body": {"text": "new"},
            },
        })
        == 1
    )
    newer_row = router.enqueue_checkpoint(device.device_id, "session")

    def decrypt(row):
        return open_authenticated_envelope(
            OuterEnvelope.from_dict(row.envelope),
            recipient_private_keys={1: device_kem.private_key},
            sender_public_keys={identity.kem_generation: identity.kem_public},
            signing_public_key=identity.sign_public,
            purpose=HPKEPurpose.CHAT,
            direction=HPKEDirection.AGENT_TO_DEVICE,
            receive=ReceiveContext(
                expected_destination=device.route,
                expected_source="rte_agent",
                now_ms=store.current_time_ms(),
            ),
        )

    older = decrypt(older_row)
    newer = decrypt(newer_row)
    assert older.kind is newer.kind is SecureMessageKind.CHECKPOINT
    assert older.body["snapshot_revision"] == 1
    assert newer.body["snapshot_revision"] == 2
    assert older.body["items"] == []
    assert [item["body"]["text"] for item in newer.body["items"]] == ["new"]
    # Delivering B then delayed A cannot roll a client back: A is strictly old.
    assert older.body["snapshot_revision"] < newer.body["snapshot_revision"]
    await router.close()


async def test_repeated_checkpoints_use_opaque_hub_collapse_replacement(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, _device_kem = _register(store, "collapse", "rte_collapse")
    hub = CollapseHub()
    router = DeviceRouter(store, identity, hub, relay_route="rte_agent")
    first = router.enqueue_checkpoint(device.device_id, "session-secret")
    second = router.enqueue_checkpoint(device.device_id, "session-secret")
    first_outer = OuterEnvelope.from_dict(first.envelope)
    second_outer = OuterEnvelope.from_dict(second.envelope)
    assert first_outer.collapse == second_outer.collapse
    assert first_outer.collapse is not None
    assert "session-secret" not in first_outer.collapse
    for _ in range(100):
        if len(hub.mailbox) == 1 and second_outer.mid in {
            envelope.mid for envelope in hub.mailbox.values()
        }:
            break
        await asyncio.sleep(0)
    assert len(hub.mailbox) == 1
    assert next(iter(hub.mailbox.values())).mid == second_outer.mid
    await router.close()


def test_frame_delivery_lanes_keep_only_transient_lifecycle_realtime() -> None:
    for kind in ("turn.started", "item.started", "item.delta"):
        assert frame_transport_class({"kind": kind}) is TransportClass.REALTIME
    assert (
        frame_transport_class({
            "kind": "status",
            "body": {"kind": "thinking", "text": "chunk"},
        })
        is TransportClass.REALTIME
    )
    for kind in (
        "item.completed",
        "turn.completed",
        "approval.request",
        "clarify.request",
        "status",
        "title",
        "snapshot",
        "checkpoint",
        "future.authoritative",
    ):
        assert frame_transport_class({"kind": kind}) is TransportClass.STATE


async def test_offline_thinking_chunks_are_dropped_without_displacing_state(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, _device_kem = _register(store, "thinking", "rte_thinking")
    hub = LaneHub(available=False)
    router = DeviceRouter(
        store,
        identity,
        hub,
        relay_route="rte_agent",
        max_pending_per_device=1,
    )
    # A terminal state row is the convergence authority.  A long reasoning
    # stream may allocate gaps, but none of its token-like status chunks may
    # survive an offline delivery attempt or consume the durable state lane.
    for index in range(300):
        assert (
            router.publish({
                "sid": "session",
                "turn": "turn_thinking",
                "kind": "status",
                "body": {"kind": "thinking", "text": f"token-{index}"},
            })
            == 1
        )
    assert (
        router.publish({
            "sid": "session",
            "turn": "turn_thinking",
            "kind": "item.completed",
            "body": {
                "item_id": "answer",
                "type": "agentMessage",
                "status": "completed",
                "ord": 0,
                "summary": "done",
                "body": {"text": "done"},
            },
        })
        == 1
    )
    await router.close()

    worker = DeviceSender(device.device_id, store, hub)
    assert await worker.flush_once() == 0
    assert await worker.flush_once() == 0
    pending = store.pending_outbox(device.device_id, limit=1_000)
    assert len(pending) == 1
    assert pending[0].message_class == TransportClass.STATE.value
    assert pending[0].state == "pending"
    assert (
        sum(
            envelope.message_class is TransportClass.REALTIME
            for envelope in hub.envelopes
        )
        == 300
    )
    assert any(
        envelope.message_class is TransportClass.STATE for envelope in hub.envelopes
    )


async def test_offline_realtime_overflow_drops_transients_then_checkpoint_converges(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, device_kem = _register(store, "lanes", "rte_lanes")
    hub = LaneHub(available=False)
    router = DeviceRouter(
        store,
        identity,
        hub,
        relay_route="rte_agent",
        max_pending_per_device=1,
    )
    started = {
        "sid": "session",
        "turn": "turn_lanes",
        "kind": "item.started",
        "body": {
            "item_id": "source_lanes",
            "type": "agentMessage",
            "status": "in_progress",
            "ord": 0,
            "summary": "",
            "body": {"text": ""},
        },
    }
    delta = {
        "sid": "session",
        "turn": "turn_lanes",
        "kind": "item.delta",
        "body": {"item_id": "source_lanes", "patch": {"text": "complete"}},
    }
    completed = {
        "sid": "session",
        "turn": "turn_lanes",
        "kind": "item.completed",
        "body": {
            "item_id": "source_lanes",
            "type": "agentMessage",
            "status": "completed",
            "ord": 0,
            "summary": "complete",
            "body": {"text": "complete"},
        },
    }
    assert router.publish(started) == 1
    assert router.publish(delta) == 1
    assert router.publish(completed) == 1
    checkpoint_record = router.enqueue_checkpoint(device.device_id, "session")
    sender = router._senders[device.device_id]
    # Four durable hints coalesce in a one-slot wake queue without blocking.
    assert sender.queue.qsize() == 1
    await router.close()

    worker = DeviceSender(device.device_id, store, hub)
    assert await worker.flush_once() == 0
    pending = store.pending_outbox(device.device_id)
    assert [row.message_class for row in pending] == ["state", "state"]
    assert {envelope.message_class for envelope in hub.envelopes[:2]} == {
        TransportClass.REALTIME
    }

    hub.available = True
    assert await worker.flush_once() == 2
    assert [row.state for row in store.pending_outbox(device.device_id)] == [
        "hub_accepted",
        "hub_accepted",
    ]
    assert all(
        envelope.message_class == TransportClass.STATE
        for envelope in hub.envelopes[-2:]
    )
    checkpoint = open_authenticated_envelope(
        OuterEnvelope.from_dict(checkpoint_record.envelope),
        recipient_private_keys={1: device_kem.private_key},
        sender_public_keys={identity.kem_generation: identity.kem_public},
        signing_public_key=identity.sign_public,
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination=device.route,
            expected_source="rte_agent",
            now_ms=store.current_time_ms(),
        ),
    )
    assert checkpoint.body["through_seq"] == 3
    assert [item["body"]["text"] for item in checkpoint.body["items"]] == ["complete"]
