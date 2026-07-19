from __future__ import annotations

import asyncio
from unittest.mock import AsyncMock

from hermes_relay.bus import TOPIC_RELAY_FRAMES
from hermes_relay.gateway_client import GatewayConfig
from hermes_relay.types import Frame, FrameKind, GatewayEvent, RawEvent
from hermes_relay.v2.app import (
    FRAME_BATCH_MAX_BYTES,
    V2RelayApp,
    V2RelayConfig,
    frame_batch_plaintext_size,
    read_protected_token_file,
)
from hermes_relay.v2.crypto import (
    decrypt_notification_preview,
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
    open_authenticated_envelope,
)
from hermes_relay.v2.identity import load_or_create_identity
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.projection import V2Projection
from hermes_relay.v2.protocol import (
    HPKEDirection,
    HPKEPurpose,
    OuterEnvelope,
    ReceiveContext,
    SecureMessageKind,
    TransportClass,
    canonical_json,
)
from hermes_relay.v2.rpc import RPCRequest
from hermes_relay.v2.storage import RelayStorage


class Hub:
    def __init__(self):
        self.envelopes = []

    async def send_envelope(self, envelope):
        self.envelopes.append(envelope)
        return {"accepted": True, "stored": True, "deduplicated": False}

    async def close(self):
        return None


class Push:
    def __init__(self):
        self.descriptors = []

    async def send(self, descriptor, *, send_capability):
        self.descriptors.append(descriptor)
        return {
            "accepted": True,
            "deduplicated": False,
            "provider_status": 200,
            "endpoint_pruned": False,
        }

    async def close(self):
        return None


def _active_push_device(store, suffix):
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    device = store.register_device(
        device_id=f"dev_{suffix}",
        name=suffix,
        route=f"rte_{suffix}",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    store.activate_device(device.device_id)
    store.store_push_binding(
        device_id=device.device_id,
        binding_id=f"pb_{suffix}",
        send_capability=(suffix.encode() * 32)[:32],
        allowed_classes=["approval", "error", "update"],
    )
    return device, kem, preview


async def test_live_gateway_approval_frame_invokes_v2_capability_push_path(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    first, first_kem, _first_preview = _active_push_device(store, "one")
    second, second_kem, _second_preview = _active_push_device(store, "two")
    unsubscribed, _third_kem, _third_preview = _active_push_device(
        store, "unsubscribed"
    )
    store.own_session("sess_live")
    store.set_subscription(first.device_id, "sess_live", foreground=True)
    store.set_subscription(second.device_id, "sess_live", foreground=False)
    push = Push()
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            push_url="https://push.example",
            state_directory=tmp_path,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=push,
    )
    pump = asyncio.create_task(app._frame_pump())
    for _ in range(100):
        if app.bus.subscriber_count(TOPIC_RELAY_FRAMES):
            break
        await asyncio.sleep(0)
    assert app.bus._subs[TOPIC_RELAY_FRAMES][0]._q.maxsize > 0
    assert app.gateway._reliable_events is True
    assert app.reframer._reliable_output is True
    app.bus.publish(
        TOPIC_RELAY_FRAMES,
        Frame(
            sid="sess_live",
            kind=FrameKind.APPROVAL_REQUEST,
            body={
                "request_id": "req_live",
                "title": "Approval required",
                "description": "Run deployment?",
                "destructive": True,
                "expires_at_ms": 2_000,
            },
        ),
    )
    for _ in range(100):
        if len(store.notification_outbox()) == 2:
            break
        await asyncio.sleep(0)
    # Gateway projection commits both encrypted previews and both in-app
    # capabilities without waiting on the Push network.
    assert push.descriptors == []
    await app.notifications.flush_pending()
    # Foreground suppresses APNs only for that exact device.  Both devices
    # still receive their independently encrypted actionable in-app frame.
    assert len(push.descriptors) == 1
    rows = store._conn.execute(
        "SELECT device_id,state FROM approval_capabilities WHERE request_id='req_live'"
    ).fetchall()
    assert {(row["device_id"], row["state"]) for row in rows} == {
        (first.device_id, "pending"),
        (second.device_id, "pending"),
    }
    assert unsubscribed.device_id not in {row["device_id"] for row in rows}
    capabilities = {}
    for device, kem in ((first, first_kem), (second, second_kem)):
        rows = store.pending_outbox(device.device_id)
        assert len(rows) == 1
        message = open_authenticated_envelope(
            OuterEnvelope.from_dict(rows[0].envelope),
            recipient_private_keys={1: kem.private_key},
            sender_public_keys={identity.kem_generation: identity.kem_public},
            signing_public_key=identity.sign_public,
            purpose=HPKEPurpose.CHAT,
            direction=HPKEDirection.AGENT_TO_DEVICE,
            receive=ReceiveContext(
                expected_destination=device.route,
                expected_source="rte_agent",
                now_ms=1_001,
            ),
        )
        assert message.kind is SecureMessageKind.FRAME_BATCH
        action = message.body["frames"][0]["body"]
        assert action["device_id"] == device.device_id
        assert action["device_generation"] == device.kem_generation
        assert action["allowed_decisions"] == ["approve_once", "deny"]
        capabilities[device.device_id] = action["capability"]
    assert capabilities[first.device_id] != capabilities[second.device_id]

    app.gateway.approval_respond = AsyncMock(return_value={"ok": True})
    request = RPCRequest.from_dict(
        {
            "jsonrpc": "2.0",
            "id": "rpc_foreground_approval",
            "method": "approval.respond",
            "params": {
                "session_id": "sess_live",
                "request_id": "req_live",
                "decision": "approve_once",
                "capability": capabilities[first.device_id],
            },
            "op_id": "op_foreground_approval",
        },
        now_ms=1_001,
    )
    response = await app.dispatcher.dispatch(first.device_id, request)
    assert response.error is None
    assert response.result == {"ok": True}
    pump.cancel()
    await asyncio.gather(pump, return_exceptions=True)
    await app.router.close()
    store.close()


async def test_terminal_push_is_per_device_presence_leased_and_content_blind(
    tmp_path,
) -> None:
    now = [1_000]
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: now[0], credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    foreground, _foreground_kem, foreground_preview = _active_push_device(
        store, "foreground"
    )
    background, _background_kem, background_preview = _active_push_device(
        store, "background"
    )
    store.own_session("origin")
    store.set_subscription(foreground.device_id, "origin", foreground=True)
    store.set_subscription(background.device_id, "origin", foreground=False)
    push = Push()
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            push_url="https://push.example",
            state_directory=tmp_path,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=push,
    )
    terminal = Frame(
        sid="origin",
        turn="turn_one",
        kind=FrameKind.ITEM_COMPLETED,
        body={
            "type": "agentMessage",
            "status": "completed",
            "summary": "private completion text",
            "body": {"text": "private completion text"},
        },
    )
    await app._notify_terminal_frame(terminal)
    assert push.descriptors == []
    assert len(store.notification_outbox()) == 2
    await app.notifications.flush_pending()
    assert len(push.descriptors) == 1
    await app._notify_terminal_frame(
        Frame(
            sid="origin",
            turn="turn_one",
            kind=FrameKind.TURN_COMPLETED,
            body={},
        )
    )
    assert len(push.descriptors) == 1
    assert len(store.notification_outbox()) == 2
    opaque = str(push.descriptors[0].to_dict())
    assert "origin" not in opaque
    assert "private completion text" not in opaque
    decoded = decrypt_notification_preview(
        push.descriptors[0],
        recipient_private_key=background_preview.private_key,
        sender_public_key=identity.kem_public,
        now_ms=now[0],
    )
    assert decoded.body == "private completion text"

    # A phone killed without sending background=false cannot poison push
    # suppression forever; the 90-second lease expires conservatively.
    now[0] += 90_001
    await app.notifications.flush_pending()
    assert len(push.descriptors) == 2
    await app._notify_terminal_frame(
        Frame(
            sid="origin",
            turn="turn_two",
            kind=FrameKind.TURN_COMPLETED,
            body={},
        )
    )
    await app.notifications.flush_pending()
    assert len(push.descriptors) == 4
    decoded_titles = []
    remaining = list(push.descriptors[-2:])
    for key in (foreground_preview.private_key, background_preview.private_key):
        for descriptor in list(remaining):
            try:
                preview = decrypt_notification_preview(
                    descriptor,
                    recipient_private_key=key,
                    sender_public_key=identity.kem_public,
                    now_ms=now[0],
                )
            except Exception:
                continue
            decoded_titles.append(preview.title)
            remaining.remove(descriptor)
            break
    assert decoded_titles == ["Hermes finished", "Hermes finished"]
    assert remaining == []
    await app.router.close()
    store.close()


async def test_foreign_gateway_events_never_mint_or_push_notifications(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, _kem, _preview = _active_push_device(store, "foreign")
    store.set_subscription(device.device_id, "foreign", foreground=False)
    push = Push()
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            push_url="https://push.example",
            state_directory=tmp_path,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=push,
    )
    await app._notify_terminal_frame(
        Frame(
            sid="foreign",
            turn="turn_foreign",
            kind=FrameKind.ITEM_COMPLETED,
            body={
                "type": "agentMessage",
                "status": "completed",
                "body": {"text": "must not push"},
            },
        )
    )
    await app._deliver_approval(
        Frame(
            sid="foreign",
            kind=FrameKind.APPROVAL_REQUEST,
            body={"request_id": "req_foreign", "expires_at_ms": 2_000},
        )
    )
    assert push.descriptors == []
    assert store.notification_outbox() == []
    assert (
        store._conn.execute(
            "SELECT COUNT(*) FROM approval_requests WHERE request_id='req_foreign'"
        ).fetchone()[0]
        == 0
    )
    await app.router.close()
    store.close()


async def test_terminal_error_is_not_hidden_by_completion_and_dominates_fallback(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, _kem, _preview = _active_push_device(store, "error-order")
    store.own_session("owned")
    store.set_subscription(device.device_id, "owned", foreground=False)
    push = Push()
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            push_url="https://push.example",
            state_directory=tmp_path,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=push,
    )
    await app._notify_terminal_frame(
        Frame(
            sid="owned",
            turn="turn_order",
            kind=FrameKind.ITEM_COMPLETED,
            body={"type": "agentMessage", "status": "completed", "body": {}},
        )
    )
    await app._notify_terminal_frame(
        Frame(
            sid="owned",
            turn="turn_order",
            kind=FrameKind.ITEM_COMPLETED,
            body={
                "type": "error",
                "status": "failed",
                "summary": "failure after partial completion",
                "body": {},
            },
        )
    )
    assert push.descriptors == []
    await app.notifications.flush_pending()
    assert len(push.descriptors) == 2
    assert [row.notification_class for row in store.notification_outbox()] == [
        "update",
        "error",
    ]
    await app._notify_terminal_frame(
        Frame(
            sid="owned",
            turn="turn_order",
            kind=FrameKind.TURN_COMPLETED,
            body={},
        )
    )
    assert len(push.descriptors) == 2
    await app.router.close()
    store.close()


async def test_max_unicode_terminal_preview_is_fitted_and_durably_enqueued(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, _kem, preview_key = _active_push_device(store, "unicode-terminal")
    store.own_session("unicode-owned")
    store.set_subscription(device.device_id, "unicode-owned", foreground=False)
    push = Push()
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            push_url="https://push.example",
            state_directory=tmp_path,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=push,
    )
    maximum_body = "😀" * 300  # exactly 1,200 UTF-8 bytes before JSON overhead
    await app._notify_terminal_frame(
        Frame(
            sid="unicode-owned",
            turn="turn_unicode",
            kind=FrameKind.ITEM_COMPLETED,
            body={
                "type": "agentMessage",
                "status": "completed",
                "summary": maximum_body,
                "body": {"text": maximum_body},
            },
        )
    )
    assert push.descriptors == []
    assert store.notification_outbox(device_id=device.device_id)[0].state == "pending"
    await app.notifications.flush_pending()
    assert len(push.descriptors) == 1
    row = store.notification_outbox(device_id=device.device_id)[0]
    assert row.state == "sent"
    assert row.descriptor == push.descriptors[0].to_dict()
    decoded = decrypt_notification_preview(
        push.descriptors[0],
        recipient_private_key=preview_key.private_key,
        sender_public_key=identity.kem_public,
        now_ms=1_001,
    )
    assert len(decoded.to_bytes()) <= 1_200
    assert decoded.body.endswith("…")
    assert maximum_body.startswith(decoded.body[:-1])
    await app.router.close()
    store.close()


async def test_frame_pump_batches_50ms_caps_32k_and_flushes_terminal(tmp_path) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, device_kem, _preview = _active_push_device(store, "batch")
    store.set_subscription(device.device_id, "small", foreground=False)
    store.set_subscription(device.device_id, "bulk", foreground=False)
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            state_directory=tmp_path,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=None,
    )
    pump = asyncio.create_task(app._frame_pump())
    for _ in range(100):
        if app.bus.subscriber_count(TOPIC_RELAY_FRAMES):
            break
        await asyncio.sleep(0)

    app.bus.publish(
        TOPIC_RELAY_FRAMES,
        Frame(
            sid="small",
            turn="turn_small",
            kind=FrameKind.ITEM_STARTED,
            body={
                "item_id": "small_source",
                "type": "agentMessage",
                "status": "in_progress",
                "ord": 0,
                "summary": "",
                "body": {"text": ""},
            },
        ),
    )
    for text in ("hello", " world"):
        app.bus.publish(
            TOPIC_RELAY_FRAMES,
            Frame(
                sid="small",
                turn="turn_small",
                kind=FrameKind.ITEM_DELTA,
                body={"item_id": "small_source", "patch": {"text": text}},
            ),
        )
    await asyncio.sleep(0.060)
    small_rows = store.pending_outbox(device.device_id, limit=100)
    assert len(small_rows) == 1

    chunk = "x" * 20_000
    app.bus.publish(
        TOPIC_RELAY_FRAMES,
        Frame(
            sid="bulk",
            turn="turn_bulk",
            kind=FrameKind.ITEM_STARTED,
            body={
                "item_id": "bulk_source",
                "type": "agentMessage",
                "status": "in_progress",
                "ord": 0,
                "summary": "",
                "body": {"text": ""},
            },
        ),
    )
    for _ in range(2):
        app.bus.publish(
            TOPIC_RELAY_FRAMES,
            Frame(
                sid="bulk",
                turn="turn_bulk",
                kind=FrameKind.ITEM_DELTA,
                body={"item_id": "bulk_source", "patch": {"text": chunk}},
            ),
        )
    app.bus.publish(
        TOPIC_RELAY_FRAMES,
        Frame(
            sid="bulk",
            turn="turn_bulk",
            kind=FrameKind.ITEM_COMPLETED,
            body={
                "item_id": "bulk_source",
                "type": "agentMessage",
                "status": "completed",
                "ord": 0,
                "summary": "bulk complete",
                "body": {"text": chunk + chunk},
            },
        ),
    )
    for _ in range(100):
        if len(store.pending_outbox(device.device_id, limit=100)) == 4:
            break
        await asyncio.sleep(0)

    decrypted = []
    for row in store.pending_outbox(device.device_id, limit=100):
        message = open_authenticated_envelope(
            OuterEnvelope.from_dict(row.envelope),
            recipient_private_keys={1: device_kem.private_key},
            sender_public_keys={identity.kem_generation: identity.kem_public},
            signing_public_key=identity.sign_public,
            purpose=HPKEPurpose.CHAT,
            direction=HPKEDirection.AGENT_TO_DEVICE,
            receive=ReceiveContext(
                expected_destination=device.route,
                expected_source="rte_agent",
                now_ms=1_001,
            ),
        )
        decrypted.append((
            row.message_class,
            message.body["frames"],
            len(message.to_bytes()),
        ))
    assert [len(frames) for _lane, frames, _size in decrypted] == [3, 2, 1, 1]
    assert [lane for lane, _frames, _size in decrypted] == [
        TransportClass.REALTIME.value,
        TransportClass.REALTIME.value,
        TransportClass.REALTIME.value,
        TransportClass.STATE.value,
    ]
    assert all(
        size <= FRAME_BATCH_MAX_BYTES
        for lane, _frames, size in decrypted
        if lane == TransportClass.REALTIME.value
    )
    pump.cancel()
    await asyncio.gather(pump, return_exceptions=True)
    await app.router.close()
    store.close()


async def test_frame_batch_cap_includes_canonical_secure_message_wrapper(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            state_directory=tmp_path,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=None,
    )
    template = {
        "sid": "boundary",
        "turn": "turn_boundary",
        "kind": "item.delta",
        "body": {"item_id": "item_boundary", "patch": {"text": ""}},
    }
    static_sum = 2 * len(canonical_json(template))
    payload_total = FRAME_BATCH_MAX_BYTES - static_sum - 1
    first = {
        **template,
        "body": {
            "item_id": "item_boundary",
            "patch": {"text": "x" * (payload_total // 2)},
        },
    }
    second = {
        **template,
        "body": {
            "item_id": "item_boundary",
            "patch": {"text": "x" * (payload_total - payload_total // 2)},
        },
    }
    # A frame-only sum would accept this pair, while the canonical inner
    # SecureMessage + frame_batch body correctly crosses the 32 KiB boundary.
    assert sum(len(canonical_json(frame)) for frame in (first, second)) < (
        FRAME_BATCH_MAX_BYTES
    )
    assert frame_batch_plaintext_size([first, second]) > FRAME_BATCH_MAX_BYTES
    assert frame_batch_plaintext_size([first]) < FRAME_BATCH_MAX_BYTES
    assert frame_batch_plaintext_size([second]) < FRAME_BATCH_MAX_BYTES

    published = []
    app.router.project = lambda frame: frame
    app.router.publish_frames = lambda sid, frames, *, message_class: (
        published.append((sid, list(frames), message_class)) or 1
    )
    pump = asyncio.create_task(app._frame_pump())
    for _ in range(100):
        if app.bus.subscriber_count(TOPIC_RELAY_FRAMES):
            break
        await asyncio.sleep(0)
    app.bus.publish(TOPIC_RELAY_FRAMES, first)
    app.bus.publish(TOPIC_RELAY_FRAMES, second)
    await asyncio.sleep(0.060)
    assert [len(frames) for _sid, frames, _lane in published] == [1, 1]
    assert all(
        frame_batch_plaintext_size(frames) <= FRAME_BATCH_MAX_BYTES
        for _sid, frames, _lane in published
    )
    pump.cancel()
    await asyncio.gather(pump, return_exceptions=True)
    await app.router.close()
    store.close()


def test_operator_enrollment_token_file_is_owner_only_and_never_echoed(
    tmp_path,
) -> None:
    token_file = tmp_path / "operator.token"
    token_file.write_text("self-host-secret", encoding="utf-8")
    token_file.chmod(0o644)
    try:
        read_protected_token_file(token_file, label="Hub operator enrollment token")
    except PermissionError as exc:
        assert "self-host-secret" not in str(exc)
    else:
        raise AssertionError("weak operator-token permissions accepted")
    token_file.chmod(0o600)
    assert (
        read_protected_token_file(token_file, label="Hub operator enrollment token")
        == "self-host-secret"
    )


def test_protected_token_file_refuses_links(tmp_path) -> None:
    token_file = tmp_path / "operator.token"
    token_file.write_text("self-host-secret", encoding="utf-8")
    token_file.chmod(0o600)
    symlink = tmp_path / "operator-link.token"
    symlink.symlink_to(token_file)
    try:
        read_protected_token_file(symlink, label="Hub operator enrollment token")
    except PermissionError:
        pass
    else:
        raise AssertionError("symlinked operator token accepted")
    hardlink = tmp_path / "operator-hardlink.token"
    hardlink.hardlink_to(token_file)
    try:
        read_protected_token_file(hardlink, label="Hub operator enrollment token")
    except PermissionError:
        pass
    else:
        raise AssertionError("hard-linked operator token accepted")


async def test_restart_hydrates_alias_recovers_crash_window_and_retires_partial_item(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device, device_kem, _device_preview = _active_push_device(store, "restart")
    store.own_session("origin", "live")
    store.set_subscription(device.device_id, "origin", foreground=True)
    projection = V2Projection(store)
    projection.import_gateway_history(
        "origin",
        [
            {"id": "history_user", "role": "user", "content": "history prompt"},
            {"id": "history_agent", "role": "assistant", "content": "durable"},
        ],
    )
    partial = projection.apply({
        "sid": "origin",
        "turn": "turn_before_crash",
        "kind": "item.started",
        "body": {
            "item_id": "partial_source",
            "type": "agentMessage",
            "status": "in_progress",
            "ord": 1,
            "summary": "",
            "body": {"text": ""},
        },
    })
    assert partial is not None
    assert (
        projection.apply({
            "sid": "origin",
            "turn": "turn_before_crash",
            "kind": "item.delta",
            "body": {"item_id": "partial_source", "patch": {"text": "part"}},
        })
        is not None
    )
    partial_id = partial["body"]["item_id"]
    # Crash injection: projection committed, but no sequence/outbox row exists.
    assert store.pending_outbox(device.device_id) == []
    store.close()

    reopened = RelayStorage(
        tmp_path, clock=lambda: 1_000, credential_protector=protector
    )
    restarted_identity = load_or_create_identity(reopened, protector=protector)
    app = V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            state_directory=tmp_path,
        ),
        storage=reopened,
        identity=restarted_identity,
        relay_route="rte_agent",
        hub=Hub(),
        push=None,
    )
    # Durable aliases are hydrated, but never advertised as command-safe until
    # the new Gateway connection has resumed them.
    assert not app.gateway.owns("origin")
    assert not app.gateway.owns("live")
    assert app.gateway.live_id_for("origin") == "live"
    app.gateway._call_connected = AsyncMock(
        return_value={"result": {"session_id": "newlive", "resumed": "origin"}}
    )
    await app.gateway._reestablish_owned()
    app.gateway._operational.set()
    resumed_ids = {
        call.args[1]["session_id"]
        for call in app.gateway._call_connected.await_args_list
    }
    assert resumed_ids == {"origin"}
    assert app.gateway.live_id_for("origin") == "newlive"
    assert reopened.live_session_id("origin") == "newlive"
    assert not app.gateway.owns("live")

    app._recover_restart_projection()
    assert not app._restart_recovery_pending
    recovery_row = reopened.pending_outbox(device.device_id)[0]
    recovery = open_authenticated_envelope(
        OuterEnvelope.from_dict(recovery_row.envelope),
        recipient_private_keys={1: device_kem.private_key},
        sender_public_keys={
            restarted_identity.kem_generation: restarted_identity.kem_public
        },
        signing_public_key=restarted_identity.sign_public,
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination=device.route,
            expected_source="rte_agent",
            now_ms=1_001,
        ),
    )
    assert recovery.kind is SecureMessageKind.CHECKPOINT
    assert [item["body"]["text"] for item in recovery.body["items"]] == [
        "history prompt",
        "durable",
    ]
    assert recovery.body["tombstones"] == [
        {"item_id": partial_id, "deleted_at_revision": 3}
    ]

    # The resumed Gateway addresses the distinct live ID.  Router canonicalizes
    # it back to origin, and the new completion cannot resurrect the orphan.
    frames = app.reframer.reframe(
        GatewayEvent(
            type=RawEvent.MESSAGE_COMPLETE,
            session_id="newlive",
            payload={"text": "after restart"},
        )
    )
    for frame in frames:
        app.router.publish(frame)
    checkpoint = reopened.session_checkpoint("origin")
    assert all(item["status"] != "in_progress" for item in checkpoint["items"])
    assert [
        item["body"]["text"]
        for item in checkpoint["items"]
        if item["type"] == "agentMessage"
    ] == ["durable", "after restart"]
    assert reopened.session_checkpoint("live")["items"] == []
    await app.router.close()
    reopened.close()
