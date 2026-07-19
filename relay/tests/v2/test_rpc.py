from __future__ import annotations

from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock

import pytest

from hermes_relay.gateway_client import GatewayRPCError
from hermes_relay.v2.crypto import (
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
    open_authenticated_envelope,
)
from hermes_relay.v2.device_router import DeviceRouter
from hermes_relay.v2.errors import InvalidArgument
from hermes_relay.v2.identity import load_or_create_identity
from hermes_relay.v2.protocol import (
    HPKEDirection,
    HPKEPurpose,
    MAX_WIRE_INTEGER,
    OuterEnvelope,
    ReceiveContext,
    SecureMessageKind,
)
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.rpc import RPCDispatcher, RPCRequest
from hermes_relay.v2.storage import RelayStorage


CLIENT_MESSAGE_ID = "550e8400-e29b-41d4-a716-446655440000"


def _device(store: RelayStorage) -> str:
    record = store.register_device(
        device_id="dev_rpc",
        name="Phone",
        route="rte_phone",
        kem_public=b"k" * 32,
        sign_public=b"s" * 32,
        preview_public=b"p" * 32,
    )
    store.activate_device(record.device_id)
    return record.device_id


def _second_device(store: RelayStorage) -> str:
    record = store.register_device(
        device_id="dev_rpc_2",
        name="Tablet",
        route="rte_tablet",
        kem_public=b"2" * 32,
        sign_public=b"3" * 32,
        preview_public=b"4" * 32,
    )
    store.activate_device(record.device_id)
    return record.device_id


def _gateway():
    gateway = MagicMock()
    gateway.session_list = AsyncMock(return_value=[])
    gateway.rest_history = AsyncMock(return_value=[])
    gateway.session_resume = AsyncMock(
        return_value={"session_id": "live", "resumed": "origin"}
    )
    gateway.session_create = AsyncMock(return_value="created")
    gateway.prompt_submit = AsyncMock(return_value={"accepted": True})
    gateway.session_interrupt = AsyncMock(return_value={"ok": True})
    gateway.approval_respond = AsyncMock(return_value={"ok": True})
    gateway.clarify_respond = AsyncMock(return_value={"ok": True})
    gateway.owns = MagicMock(return_value=False)
    return gateway


def _request(method, params, *, op_id=None, rid="rpc_12345678"):
    payload = {"jsonrpc": "2.0", "id": rid, "method": method, "params": params}
    if op_id:
        payload["op_id"] = op_id
    return RPCRequest.from_dict(payload, now_ms=100)


def test_strict_rpc_rejects_unknown_missing_and_expired_fields() -> None:
    with pytest.raises(InvalidArgument):
        RPCRequest.from_dict({
            "jsonrpc": "2.0",
            "id": "rpc_12345678",
            "method": "prompt.submit",
            "params": {"text": "x", "client_message_id": CLIENT_MESSAGE_ID},
            "unexpected": True,
        })
    with pytest.raises(InvalidArgument):
        _request("prompt.submit", {"text": "x", "client_message_id": CLIENT_MESSAGE_ID})
    from hermes_relay.v2.errors import Expired

    with pytest.raises(Expired):
        RPCRequest.from_dict(
            {
                "jsonrpc": "2.0",
                "id": "rpc_12345678",
                "method": "session.list",
                "params": {},
                "deadline_ms": 99,
            },
            now_ms=100,
        )
    with pytest.raises(InvalidArgument) as unsafe_integer:
        _request(
            "sync.request",
            {"session_id": "session", "last_seq": MAX_WIRE_INTEGER + 1},
        )
    assert unsafe_integer.value.details == {"field": "last_seq"}


@pytest.mark.parametrize(
    "client_message_id",
    [
        "msg_ABEiM0RVZneImaq7zN3u_w",
        "550E8400-E29B-41D4-A716-446655440000",
        "550e8400e29b41d4a716446655440000",
        "not-a-uuid-but-long-enough-000000000",
    ],
)
def test_prompt_requires_lowercase_canonical_uuid(client_message_id) -> None:
    with pytest.raises(InvalidArgument) as raised:
        _request(
            "prompt.submit",
            {"text": "hello", "client_message_id": client_message_id},
            op_id="op_uuid_contract",
        )
    assert raised.value.details == {"field": "client_message_id"}


async def test_prompt_forwards_receipt_id_persists_alias_and_deduplicates_op(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    gateway = _gateway()
    router = MagicMock()
    dispatcher = RPCDispatcher(gateway, store, router)
    params = {
        "session_id": "origin",
        "text": "hello",
        "client_message_id": CLIENT_MESSAGE_ID,
    }
    request = _request("prompt.submit", params, op_id="op_12345678")
    response = await dispatcher.dispatch(device, request)
    assert response.error is None
    assert response.result["live_session_id"] == "live"
    gateway.prompt_submit.assert_awaited_once_with(
        "live", "hello", client_message_id=CLIENT_MESSAGE_ID
    )
    assert store.live_session_id("origin") == "live"
    user = store.session_item("origin", CLIENT_MESSAGE_ID)
    assert user == {
        "item_id": CLIENT_MESSAGE_ID,
        "session_id": "origin",
        "turn_id": None,
        "type": "userMessage",
        "status": "completed",
        "ord": 0,
        "rev": 1,
        "summary": "hello",
        "body": {"text": "hello"},
    }
    router.publish_frames.assert_called_once()
    replay = await dispatcher.dispatch(device, request)
    assert replay.result == response.result
    assert gateway.prompt_submit.await_count == 1

    conflict = await dispatcher.dispatch(
        device,
        _request(
            "prompt.submit",
            {**params, "text": "different"},
            op_id="op_12345678",
            rid="rpc_different",
        ),
    )
    assert conflict.error.code.value == "CONFLICT"


async def test_prompt_subscribes_live_session_before_fast_gateway_events(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    gateway = _gateway()

    class RaceRouter:
        projection = None

        def __init__(self) -> None:
            self.deliveries = []

        def publish(self, frame) -> None:
            canonical = store.origin_session_id(frame["sid"])
            self.deliveries.append((frame["kind"], store.subscribed_devices(canonical)))

        def publish_frames(self, session_id, frames, *, message_class) -> None:
            self.deliveries.extend(
                (frame["kind"], store.subscribed_devices(session_id))
                for frame in frames
            )

    router = RaceRouter()

    async def submit_before_response(session_id, _text, *, client_message_id):
        assert session_id == "live"
        assert client_message_id == CLIENT_MESSAGE_ID
        for kind in ("turn.started", "item.delta", "turn.completed"):
            router.publish({"sid": session_id, "kind": kind})
        return {"accepted": True}

    gateway.prompt_submit.side_effect = submit_before_response
    response = await RPCDispatcher(gateway, store, router).dispatch(
        device,
        _request(
            "prompt.submit",
            {
                "session_id": "origin",
                "text": "hello",
                "client_message_id": CLIENT_MESSAGE_ID,
            },
            op_id="op_fast_stream",
        ),
    )
    assert response.error is None
    assert router.deliveries == [
        ("item.completed", [device]),
        ("turn.started", [device]),
        ("item.delta", [device]),
        ("turn.completed", [device]),
    ]
    assert store.subscribed_devices("origin") == [device]
    assert store.subscribed_devices("live") == []
    assert store.session_checkpoint("origin")["items"] == [
        {
            "item_id": CLIENT_MESSAGE_ID,
            "session_id": "origin",
            "turn_id": None,
            "type": "userMessage",
            "status": "completed",
            "ord": 0,
            "rev": 1,
            "summary": "hello",
            "body": {"text": "hello"},
        }
    ]


async def test_accepted_prompt_emits_and_checkpoints_authoritative_user_item(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    device_kem = generate_x25519_key_pair()
    device_sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    device = store.register_device(
        device_id="dev_prompt_e2e",
        name="Phone",
        route="rte_prompt_e2e",
        kem_public=device_kem.public_key,
        sign_public=device_sign.public_key,
        preview_public=preview.public_key,
    )
    store.activate_device(device.device_id)
    hub = MagicMock()
    hub.send_envelope = AsyncMock(
        return_value={"accepted": True, "stored": True, "deduplicated": False}
    )
    router = DeviceRouter(
        store,
        identity,
        hub,
        relay_route="rte_agent",
        clock_ms=store.current_time_ms,
    )
    gateway = _gateway()

    async def fast_completed_answer(session_id, _text, *, client_message_id):
        assert client_message_id == CLIENT_MESSAGE_ID
        router.publish({
            "sid": session_id,
            "turn": "turn_fast",
            "kind": "turn.started",
            "body": {},
        })
        router.publish({
            "sid": session_id,
            "turn": "turn_fast",
            "kind": "item.completed",
            "body": {
                "item_id": "gateway_answer",
                "type": "agentMessage",
                "status": "completed",
                "ord": 0,
                "summary": "answer",
                "body": {"text": "answer"},
            },
        })
        return {"accepted": True}

    gateway.prompt_submit.side_effect = fast_completed_answer
    response = await RPCDispatcher(gateway, store, router).dispatch(
        device.device_id,
        _request(
            "prompt.submit",
            {
                "session_id": "origin",
                "text": "hello",
                "client_message_id": CLIENT_MESSAGE_ID,
            },
            op_id="op_prompt_e2e",
        ),
    )
    assert response.error is None

    user_rows = []
    user_seqs = []
    for row in store.pending_outbox(device.device_id):
        inner = open_authenticated_envelope(
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
        if inner.kind is SecureMessageKind.FRAME_BATCH:
            for frame in inner.body["frames"]:
                if frame.get("body", {}).get("type") == "userMessage":
                    user_rows.append(frame)
                    user_seqs.append(row.first_seq)
    assert len(user_rows) == 1
    authoritative = user_rows[0]["body"]
    assert set(authoritative) == {
        "item_id",
        "session_id",
        "turn_id",
        "type",
        "status",
        "ord",
        "rev",
        "summary",
        "body",
    }
    assert authoritative["item_id"] == CLIENT_MESSAGE_ID
    assert authoritative["body"] == {"text": "hello"}
    assert user_seqs == [1]

    checkpoint_row = router.enqueue_checkpoint(device.device_id, "origin")
    checkpoint = open_authenticated_envelope(
        OuterEnvelope.from_dict(checkpoint_row.envelope),
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
    checkpoint_user = next(
        item for item in checkpoint.body["items"] if item["type"] == "userMessage"
    )
    assert checkpoint_user == authoritative
    assert [item["type"] for item in checkpoint.body["items"]] == [
        "userMessage",
        "agentMessage",
    ]
    await router.close()


async def test_gateway_receipt_conflict_is_content_safe(tmp_path) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    gateway = _gateway()
    gateway.prompt_submit.side_effect = GatewayRPCError(
        "prompt.submit",
        {"code": 4091, "message": "different secret prompt"},
    )
    response = await RPCDispatcher(gateway, store, MagicMock()).dispatch(
        device,
        _request(
            "prompt.submit",
            {"text": "hello", "client_message_id": CLIENT_MESSAGE_ID},
            op_id="op_receipt_conflict",
        ),
    )
    assert response.error.code.value == "CONFLICT"
    assert response.error.message == "client_message_id request conflict"
    assert "different secret prompt" not in str(response.to_dict())


async def test_open_subscribes_and_emits_authoritative_checkpoint(tmp_path) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    gateway = _gateway()
    gateway.rest_history.return_value = [
        {"id": "msg_user", "role": "user", "content": "hello"},
        {"id": "msg_agent", "role": "assistant", "content": "hi there"},
    ]
    router = MagicMock()
    router.enqueue_checkpoint.return_value = SimpleNamespace(last_seq=7)
    response = await RPCDispatcher(gateway, store, router).dispatch(
        device, _request("session.open", {"session_id": "origin"})
    )
    assert response.result["checkpoint_through_seq"] == 7
    router.enqueue_checkpoint.assert_called_once_with(device, "origin")
    assert store.subscribed_devices("origin") == [device]
    checkpoint = store.session_checkpoint("origin")
    assert [item["type"] for item in checkpoint["items"]] == [
        "userMessage",
        "agentMessage",
    ]
    assert [item["body"]["text"] for item in checkpoint["items"]] == [
        "hello",
        "hi there",
    ]


async def test_side_effect_transport_failure_becomes_ambiguous_without_secret_text(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    gateway = _gateway()
    gateway.session_interrupt.side_effect = ConnectionError("secret gateway detail")
    response = await RPCDispatcher(gateway, store, MagicMock()).dispatch(
        device,
        _request(
            "session.interrupt",
            {"session_id": "origin"},
            op_id="op_interrupt_1",
        ),
    )
    encoded = str(response.to_dict())
    assert response.error.code.value == "GATEWAY_AMBIGUOUS"
    assert "secret gateway detail" not in encoded
    assert store.get_operation(device, "op_interrupt_1").state == "ambiguous"


async def test_unexpected_side_effect_failure_returns_ambiguous_not_internal(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path)
    device = _device(store)
    gateway = _gateway()
    gateway.session_interrupt.side_effect = RuntimeError("private internal detail")
    response = await RPCDispatcher(gateway, store, MagicMock()).dispatch(
        device,
        _request(
            "session.interrupt",
            {"session_id": "origin"},
            op_id="op_interrupt_unknown",
        ),
    )
    assert response.error.code.value == "GATEWAY_AMBIGUOUS"
    assert "private internal detail" not in str(response.to_dict())
    assert store.get_operation(device, "op_interrupt_unknown").state == "ambiguous"


async def test_approval_capability_first_device_wins_and_exact_ambiguous_retry(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path, clock=lambda: 100)
    phone = _device(store)
    tablet = _second_device(store)
    caps = store.create_approval_capabilities(
        request_id="req_approval",
        session_id="origin",
        expires_at_ms=1_000,
    )
    gateway = _gateway()
    gateway.approval_respond.side_effect = [ConnectionError("lost"), {"ok": True}]
    dispatcher = RPCDispatcher(gateway, store, MagicMock())
    params = {
        "session_id": "origin",
        "request_id": "req_approval",
        "decision": "approve_once",
        "capability": caps[phone],
    }
    request = _request("approval.respond", params, op_id="op_approval_1")
    first = await dispatcher.dispatch(phone, request)
    assert first.error.code.value == "GATEWAY_AMBIGUOUS"
    assert store.approval_capability_state(caps[phone]) == "failed_retryable"
    assert store.approval_capability_state(caps[tablet]) == "superseded"

    sibling = await dispatcher.dispatch(
        tablet,
        _request(
            "approval.respond",
            {**params, "capability": caps[tablet]},
            op_id="op_tablet_1",
            rid="rpc_tablet_1",
        ),
    )
    assert sibling.error.code.value == "CONFLICT"
    assert gateway.approval_respond.await_count == 1

    opposite = await dispatcher.dispatch(
        phone,
        _request(
            "approval.respond",
            {**params, "decision": "deny"},
            op_id="op_approval_1",
            rid="rpc_opposite",
        ),
    )
    assert opposite.error.code.value == "CONFLICT"
    assert gateway.approval_respond.await_count == 1

    retry = await dispatcher.dispatch(phone, request)
    assert retry.result == {"ok": True}
    assert store.approval_capability_state(caps[phone]) == "succeeded"
    gateway.approval_respond.assert_awaited_with(
        "origin", "req_approval", "once", resolve_all=False
    )


async def test_approval_rejects_missing_unknown_expired_and_rotated_capabilities(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path, clock=lambda: 100)
    phone = _device(store)
    with pytest.raises(InvalidArgument):
        _request(
            "approval.respond",
            {
                "session_id": "origin",
                "request_id": "req",
                "decision": "deny",
            },
            op_id="op_missing_1",
        )
    caps = store.create_approval_capabilities(
        request_id="req_expiry", session_id="origin", expires_at_ms=101
    )
    gateway = _gateway()
    request = _request(
        "approval.respond",
        {
            "session_id": "origin",
            "request_id": "req_expiry",
            "decision": "deny",
            "capability": caps[phone],
        },
        op_id="op_expiry_1",
    )
    store._clock = lambda: 102
    expired = await RPCDispatcher(gateway, store, MagicMock()).dispatch(phone, request)
    assert expired.error.code.value == "EXPIRED"
    gateway.approval_respond.assert_not_awaited()


async def test_non_resolved_gateway_rejection_does_not_mark_approval_resolved(
    tmp_path,
) -> None:
    store = RelayStorage(tmp_path, clock=lambda: 100)
    phone = _device(store)
    caps = store.create_approval_capabilities(
        request_id="req_rejected", session_id="origin", expires_at_ms=1_000
    )
    gateway = _gateway()
    gateway.approval_respond.side_effect = GatewayRPCError(
        "approval.respond", {"code": 4003, "message": "rejected"}
    )
    response = await RPCDispatcher(gateway, store, MagicMock()).dispatch(
        phone,
        _request(
            "approval.respond",
            {
                "session_id": "origin",
                "request_id": "req_rejected",
                "decision": "deny",
                "capability": caps[phone],
            },
            op_id="op_rejected",
        ),
    )
    assert response.error.code.value == "CONFLICT"
    assert store.approval_capability_state(caps[phone]) == "revoked"
    state = store._conn.execute(
        "SELECT state FROM approval_requests WHERE request_id='req_rejected'"
    ).fetchone()["state"]
    assert state == "failed"
