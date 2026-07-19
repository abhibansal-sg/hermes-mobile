from __future__ import annotations

import asyncio
import json

import pytest

from hermes_relay.v2.crypto import (
    decrypt_notification_preview,
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
)
from hermes_relay.v2.identity import load_or_create_identity
from hermes_relay.v2.notification_sender import NotificationSender
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.protocol import (
    NotificationClass,
    NotificationPreview,
    b64url_encode,
)
from hermes_relay.v2.push_client import (
    PushGatewayClient,
    PushGatewayConfig,
    PushGatewayUnavailable,
)
from hermes_relay.v2.storage import RelayStorage


class Response:
    def __init__(self, status_code, payload):
        self.status_code = status_code
        self._payload = payload

    def json(self):
        return self._payload


class HTTP:
    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []

    async def request(self, method, url, **kwargs):
        self.requests.append((method, url, kwargs))
        return self.responses.pop(0)


class Push:
    def __init__(self):
        self.descriptors = []
        self.revoked = []

    async def send(self, descriptor, *, send_capability):
        assert len(send_capability) == 32
        self.descriptors.append(descriptor)
        return {
            "accepted": True,
            "deduplicated": False,
            "provider_status": 200,
            "endpoint_pruned": False,
        }

    async def revoke_binding(self, binding_id, *, send_capability):
        self.revoked.append((binding_id, send_capability))
        return {"binding_id": binding_id, "revoked": True, "already_revoked": False}


class LossyBindingPush(Push):
    def __init__(self):
        super().__init__()
        self.exchanges = []

    async def exchange_binding(self, bind_token, *, exchange_id, requested_classes):
        request = {
            "bind_token": bind_token,
            "exchange_id": exchange_id,
            "requested_classes": requested_classes,
        }
        self.exchanges.append(request)
        if len(self.exchanges) > 1:
            assert request == self.exchanges[0]
        if len(self.exchanges) == 1:
            raise ConnectionError("binding response lost after commit")
        return {
            "binding_id": "pb_recovered",
            "send_capability": "Y2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2M",
            "allowed_classes": ["approval", "error", "update"],
        }


@pytest.mark.parametrize(
    "url",
    [
        "https://user:secret@push.example",
        "https://push.example/v2",
        "https://push.example?token=secret",
        "https://push.example#secret",
    ],
)
def test_push_origin_rejects_persistable_credentials_and_non_origins(url: str) -> None:
    with pytest.raises(ValueError):
        PushGatewayConfig(url)


def test_push_origin_is_canonicalized() -> None:
    assert PushGatewayConfig("HTTPS://Push.Example:443/").base_url == (
        "https://push.example"
    )


class ScriptedPush(Push):
    def __init__(self, outcomes):
        super().__init__()
        self.outcomes = list(outcomes)
        self.capabilities = []

    async def send(self, descriptor, *, send_capability):
        self.descriptors.append(descriptor)
        self.capabilities.append(send_capability)
        outcome = self.outcomes.pop(0)
        if isinstance(outcome, BaseException):
            raise outcome
        return outcome


class PartitionedPush(Push):
    def __init__(self, slow_capability: bytes):
        super().__init__()
        self.slow_capability = slow_capability
        self.slow_started = asyncio.Event()
        self.release_slow = asyncio.Event()
        self.fast_sent = asyncio.Event()

    async def send(self, descriptor, *, send_capability):
        self.descriptors.append(descriptor)
        if send_capability == self.slow_capability:
            self.slow_started.set()
            await self.release_slow.wait()
        else:
            self.fast_sent.set()
        return {
            "accepted": True,
            "deduplicated": False,
            "provider_status": 200,
            "endpoint_pruned": False,
        }


def _device(store, suffix):
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
    return store.get_device(device.device_id), preview


def _pending_device(store, suffix):
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    return store.register_device(
        device_id=f"dev_{suffix}",
        name=suffix,
        route=f"rte_{suffix}",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )


async def test_push_readiness_requires_apns_health_and_ready_store() -> None:
    http = HTTP(
        [
            Response(200, {"status": "ok", "apns_configured": True}),
            Response(200, {"status": "ready"}),
        ]
    )
    client = PushGatewayClient(
        PushGatewayConfig("https://push.example"), http_client=http
    )
    await client.probe_ready()
    assert [(method, url) for method, url, _request in http.requests] == [
        ("GET", "https://push.example/healthz"),
        ("GET", "https://push.example/readyz"),
    ]

    hub_like = PushGatewayClient(
        PushGatewayConfig("https://hub.example"),
        http_client=HTTP([Response(200, {"status": "ok"})]),
    )
    with pytest.raises(PushGatewayUnavailable, match="APNs"):
        await hub_like.probe_ready()


def test_push_opt_out_atomically_queues_only_push_authority(tmp_path) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    active, _preview = _device(store, "optout_binding")
    pending = _pending_device(store, "optout_exchange")
    exchange = store.prepare_push_binding_exchange(
        device_id=pending.device_id,
        bind_token="one-time-bind-token",
        requested_classes=["approval", "error", "update"],
    )
    store.enqueue_notification(
        device_id=active.device_id,
        binding_id="pb_optout_binding",
        session_id="session_1",
        dedupe_key="optout-notification",
        descriptor={
            "notification_id": "ntf_optout",
            "class": "update",
            "collapse_id": None,
            "expires_at_ms": 2_000,
        },
    )
    before = {
        device.device_id: (device.status, device.hub_revocation_state)
        for device in store.devices()
    }

    queued = store.queue_all_push_authority_revocation()

    assert set(queued) == {active.device_id, pending.device_id}
    assert [row.binding_id for row in store.pending_push_binding_revocations()] == [
        "pb_optout_binding"
    ]
    assert [row.exchange_id for row in store.pending_push_exchange_revocations()] == [
        exchange.exchange_id
    ]
    outbox = store.notification_outbox(device_id=active.device_id)
    assert [(row.state, row.last_error_code) for row in outbox] == [
        ("failed", "push_opt_out")
    ]
    after = {
        device.device_id: (device.status, device.hub_revocation_state)
        for device in store.devices()
    }
    assert after == before
    assert store.pending_hub_device_revocations() == []


async def test_push_opt_out_retries_partial_cleanup_without_revoking_devices(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    active, _preview = _device(store, "retry_binding")
    pending = _pending_device(store, "retry_exchange")
    exchange = store.prepare_push_binding_exchange(
        device_id=pending.device_id,
        bind_token="retry-bind-token",
        requested_classes=["approval", "error", "update"],
    )

    class PartialPush(Push):
        def __init__(self):
            super().__init__()
            self.exchange_attempts = []
            self.fail_exchange = True

        async def revoke_binding_exchange(self, bind_token, *, exchange_id):
            self.exchange_attempts.append((bind_token, exchange_id))
            if self.fail_exchange:
                self.fail_exchange = False
                raise ConnectionError("temporary Push outage")
            return {"exchange_id": exchange_id, "revoked": True}

    push = PartialPush()
    sender = NotificationSender(store, identity, push)
    with pytest.raises(ConnectionError, match="temporary Push outage"):
        await sender.revoke_all_authority()

    # Independent cleanup means the healthy binding was confirmed even though
    # the exchange failed; only the exact failed tombstone remains for retry.
    assert len(push.revoked) == 1
    assert store.pending_push_binding_revocations() == []
    remaining = store.pending_push_exchange_revocations()
    assert [record.exchange_id for record in remaining] == [exchange.exchange_id]
    assert remaining[0].last_error_code == "ConnectionError"
    assert store.get_device(active.device_id).status == "active"
    assert store.get_device(pending.device_id, include_inactive=True).status == "pending"
    assert store.pending_hub_device_revocations() == []

    assert await sender.revoke_all_authority() == 1
    assert store.pending_push_binding_revocations() == []
    assert store.pending_push_exchange_revocations() == []
    assert len(push.exchange_attempts) == 2
    assert push.exchange_attempts[0] == push.exchange_attempts[1]
    assert store.get_device(active.device_id).status == "active"
    assert store.get_device(pending.device_id, include_inactive=True).status == "pending"


async def test_push_client_sends_only_frozen_opaque_descriptor() -> None:
    capability = "Y2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2NjY2M"
    http = HTTP([
        Response(
            201,
            {
                "binding_id": "pb_test",
                "send_capability": capability,
                "allowed_classes": ["approval", "error", "update"],
            },
        ),
        Response(
            200,
            {
                "accepted": True,
                "deduplicated": False,
                "provider_status": 200,
                "endpoint_pruned": False,
            },
        ),
        Response(200, {"revoked": True}),
    ])
    client = PushGatewayClient(
        PushGatewayConfig("https://push.example"), http_client=http
    )
    binding = await client.exchange_binding(
        "one-time-secret",
        exchange_id="exg_exact_retry_1234",
        requested_classes=["approval", "error", "update"],
    )
    assert binding["binding_id"] == "pb_test"
    exchange_wire = json.loads(http.requests[0][2]["content"])
    assert exchange_wire == {
        "bind_token": "one-time-secret",
        "exchange_id": "exg_exact_retry_1234",
        "requested_classes": ["approval", "error", "update"],
    }

    # Use an encrypted-looking descriptor directly: the client API cannot
    # accept notification plaintext at all.
    from hermes_relay.v2.protocol import NotificationSendDescriptor

    descriptor = NotificationSendDescriptor(
        notification_id="nid_opaque",
        notification_class="approval",
        preview_enc=b"e" * 32,
        preview_ct=b"c" * 48,
        expires_at_ms=2_000,
        collapse_id="opaque",
    )
    await client.send(descriptor, send_capability=b"c" * 32)
    wire = http.requests[1][2]["content"]
    assert json.loads(wire) == descriptor.to_dict()
    assert b"title" not in wire and b"body" not in wire
    assert b"session" not in wire and b"request" not in wire

    assert await client.revoke_binding_exchange(
        "one-time-secret", exchange_id="exg_exact_retry_1234"
    ) == {"revoked": True}
    revoke_method, revoke_url, revoke_request = http.requests[2]
    assert revoke_method == "POST"
    assert revoke_url.endswith("/v2/bindings/exchange/revoke")
    assert json.loads(revoke_request["content"]) == {
        "bind_token": "one-time-secret",
        "exchange_id": "exg_exact_retry_1234",
    }
    assert b"send_capability" not in revoke_request["content"]


async def test_push_client_accepts_exact_terminal_dedup_receipt() -> None:
    from hermes_relay.v2.protocol import NotificationSendDescriptor

    receipt = {
        "accepted": True,
        "deduplicated": True,
        "status": "sent",
        "provider_status": 200,
        "endpoint_pruned": False,
    }
    client = PushGatewayClient(
        PushGatewayConfig("https://push.example"),
        http_client=HTTP([Response(200, receipt)]),
    )
    descriptor = NotificationSendDescriptor(
        notification_id="nid_dedup",
        notification_class="approval",
        preview_enc=b"e" * 32,
        preview_ct=b"c" * 48,
        expires_at_ms=2_000,
    )
    assert await client.send(descriptor, send_capability=b"c" * 32) == receipt


async def test_presence_suppression_is_per_device_and_preview_is_auth_encrypted(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    phone_a, _preview_a = _device(store, "a")
    phone_b, preview_b = _device(store, "b")
    store.set_subscription(phone_a.device_id, "sess", foreground=True)
    store.set_subscription(phone_b.device_id, "sess", foreground=False)
    push = Push()
    sender = NotificationSender(store, identity, push)
    preview = NotificationPreview(
        notification_id="nid_approval",
        notification_class=NotificationClass.APPROVAL,
        title="Approval needed",
        body="Run sensitive command?",
        thread_token="thread_opaque",
        expires_at_ms=2_000,
        category="HERMES_APPROVAL",
        action={
            "session_id": "sess",
            "request_id": "req_secret",
            "capability": b64url_encode(b"z" * 32),
            "allowed_decisions": ["approve_once", "deny"],
            "destructive": True,
            "device_id": phone_b.device_id,
            "device_generation": phone_b.kem_generation,
        },
    )
    suppressed = await sender.send_to_device(
        phone_a.device_id, preview, session_id="sess"
    )
    delivered = await sender.send_to_device(
        phone_b.device_id, preview, session_id="sess"
    )
    assert suppressed == {
        "suppressed": True,
        "reason": "device_foreground",
        "queued": True,
    }
    assert store.notification_outbox(device_id=phone_a.device_id)[0].state == "pending"
    assert delivered["suppressed"] is False
    assert len(push.descriptors) == 1
    opaque = push.descriptors[0].to_dict()
    assert "Approval needed" not in str(opaque)
    assert "req_secret" not in str(opaque)
    assert (
        decrypt_notification_preview(
            push.descriptors[0],
            recipient_private_key=preview_b.private_key,
            sender_public_key=identity.kem_public,
            now_ms=1_001,
        )
        == preview
    )

    # A quick background transition releases the durable deferred row.  The
    # original encrypted descriptor is used; foreground suppression did not
    # discard the terminal work.
    store.clear_presence(phone_a.device_id)
    await sender.flush_pending()
    assert len(push.descriptors) == 2
    assert (
        decrypt_notification_preview(
            push.descriptors[1],
            recipient_private_key=_preview_a.private_key,
            sender_public_key=identity.kem_public,
            now_ms=1_001,
        )
        == preview
    )
    assert store.notification_outbox(device_id=phone_a.device_id)[0].state == "sent"


async def test_notification_retry_is_exact_across_failure_timeout_and_restart(
    tmp_path,
) -> None:
    now = [1_000]
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: now[0], credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    phone, preview_key = _device(store, "durable")
    preview = NotificationPreview(
        notification_id="nid_exact_restart",
        notification_class=NotificationClass.ERROR,
        title="Hermes needs attention",
        body="A terminal task failed",
        thread_token="thr_exact_restart",
        expires_at_ms=10_000,
    )
    first_push = ScriptedPush([
        ConnectionError("failed before acceptance"),
        TimeoutError("response lost after provider acceptance"),
    ])
    sender = NotificationSender(store, identity, first_push)
    queued = await sender.send_to_device(
        phone.device_id,
        preview,
        session_id="owned",
        collapse_id="collapse_exact",
        dedupe_key="terminal:owned:turn_exact",
    )
    assert queued["queued"] is True
    row = store.notification_outbox(device_id=phone.device_id)[0]
    assert row.state == "pending" and row.attempts == 1
    assert row.descriptor == first_push.descriptors[0].to_dict()
    now[0] += 1_000
    await sender.flush_pending()
    row = store.notification_outbox(device_id=phone.device_id)[0]
    assert row.state == "pending" and row.attempts == 2
    assert [value.to_dict() for value in first_push.descriptors] == [
        row.descriptor,
        row.descriptor,
    ]
    assert first_push.capabilities[0] == first_push.capabilities[1]
    store.close()

    # A new process retries the frozen notification/APNs identity and records
    # the Push Gateway's idempotent terminal receipt.
    now[0] += 2_000
    reopened = RelayStorage(
        tmp_path, clock=lambda: now[0], credential_protector=protector
    )
    restarted_identity = load_or_create_identity(reopened, protector=protector)
    recovered_push = ScriptedPush([
        {
            "accepted": True,
            "deduplicated": True,
            "status": "sent",
            "provider_status": 200,
            "endpoint_pruned": False,
        }
    ])
    restarted = NotificationSender(reopened, restarted_identity, recovered_push)
    assert (await restarted.flush_pending())[0]["state"] == "sent"
    recovered = reopened.notification_outbox(device_id=phone.device_id)[0]
    assert recovered.state == "sent" and recovered.attempts == 3
    assert recovered_push.descriptors[0].to_dict() == recovered.descriptor
    assert recovered.descriptor == first_push.descriptors[0].to_dict()
    assert recovered.notification_id == "nid_exact_restart"
    assert recovered.collapse_id == "collapse_exact"
    assert (
        decrypt_notification_preview(
            recovered_push.descriptors[0],
            recipient_private_key=preview_key.private_key,
            sender_public_key=restarted_identity.kem_public,
            now_ms=now[0],
        )
        == preview
    )

    # Replayed Gateway completion after restart resolves to the sent ledger
    # row without minting or POSTing a new notification identity.
    replay = NotificationPreview(
        notification_id="nid_process_local_replay",
        notification_class=NotificationClass.ERROR,
        title="changed local replay",
        body="must not replace frozen ciphertext",
        thread_token="different",
        expires_at_ms=10_000,
    )
    result = await restarted.send_to_device(
        phone.device_id,
        replay,
        session_id="owned",
        dedupe_key="terminal:owned:turn_exact",
    )
    assert result["deduplicated"] is True
    assert len(recovered_push.descriptors) == 1
    reopened.close()


async def test_slow_device_delivery_never_blocks_another_device(tmp_path) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    slow, _slow_preview = _device(store, "slow")
    fast, _fast_preview = _device(store, "fast")
    slow_capability = (b"slow" * 32)[:32]
    push = PartitionedPush(slow_capability)
    sender = NotificationSender(store, identity, push)

    for device, suffix in ((slow, "slow"), (fast, "fast")):
        record, result = sender.enqueue_to_device(
            device.device_id,
            NotificationPreview(
                notification_id=f"nid_{suffix}",
                notification_class=NotificationClass.UPDATE,
                title="Hermes update",
                body="Ready",
                thread_token=f"thr_{suffix}",
                expires_at_ms=10_000,
            ),
            dedupe_key=f"terminal:{suffix}",
        )
        assert record is not None and result["queued"] is True

    flush = asyncio.create_task(sender.flush_pending())
    await asyncio.wait_for(push.slow_started.wait(), timeout=1)
    # The fixed-size pool isolates device queues; the fast send completes even
    # while another device's Push request is indefinitely stalled.
    await asyncio.wait_for(push.fast_sent.wait(), timeout=1)
    assert store.notification_outbox(device_id=fast.device_id)[0].state == "sent"
    assert store.notification_outbox(device_id=slow.device_id)[0].state == "pending"
    push.release_slow.set()
    results = await asyncio.wait_for(flush, timeout=1)
    assert len(results) == 2
    assert store.notification_outbox(device_id=slow.device_id)[0].state == "sent"


async def test_binding_exchange_response_loss_retries_exact_persisted_request(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    device = store.register_device(
        device_id="dev_pending",
        name="Pending",
        route="rte_pending",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    push = LossyBindingPush()
    sender = NotificationSender(store, identity, push)
    import pytest

    with pytest.raises(ConnectionError, match="response lost"):
        await sender.bind_device(device.device_id, "one-time-bind-token")
    pending = store.push_binding_exchange(device.device_id)
    assert pending.state == "pending"
    assert pending.bind_token == "one-time-bind-token"
    binding_id = await sender.bind_device(device.device_id, "one-time-bind-token")
    assert binding_id == "pb_recovered"
    assert len(push.exchanges) == 2
    assert store.push_binding(device.device_id)["binding_id"] == binding_id


async def test_approval_request_mints_distinct_device_caps_and_ciphertexts(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    phone_a, preview_a = _device(store, "approval_a")
    phone_b, preview_b = _device(store, "approval_b")
    push = Push()
    results = await NotificationSender(store, identity, push).send_approval_request(
        session_id="sess_approval",
        request_id="req_approval",
        title="Approval required",
        body="Run deployment?",
        expires_at_ms=2_000,
        destructive=True,
    )
    assert set(results) == {phone_a.device_id, phone_b.device_id}
    assert all(not value["suppressed"] for value in results.values())
    assert len(push.descriptors) == 2

    decoded = {}
    for device, key, descriptor in zip(
        (phone_a, phone_b), (preview_a, preview_b), push.descriptors, strict=True
    ):
        preview = decrypt_notification_preview(
            descriptor,
            recipient_private_key=key.private_key,
            sender_public_key=identity.kem_public,
            now_ms=1_001,
        )
        assert preview.action["device_id"] == device.device_id
        assert preview.action["device_generation"] == device.kem_generation
        assert preview.action["allowed_decisions"] == ["approve_once", "deny"]
        decoded[device.device_id] = preview
        opaque = str(descriptor.to_dict())
        assert "req_approval" not in opaque and "sess_approval" not in opaque
        assert "Run deployment" not in opaque
    assert (
        decoded[phone_a.device_id].action["capability"]
        != decoded[phone_b.device_id].action["capability"]
    )
    assert push.descriptors[0].preview_ct != push.descriptors[1].preview_ct


async def test_max_unicode_approval_preview_fits_without_changing_authority(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path,
        clock=lambda: 1_000,
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(store)
    phone, preview_key = _device(store, "unicode_approval")
    push = Push()
    title = "界" * 66  # 198 UTF-8 bytes
    body = "😀" * 175  # 700 UTF-8 bytes before action/JSON overhead
    results = await NotificationSender(store, identity, push).send_approval_request(
        session_id="sess_unicode_approval",
        request_id="req_unicode_approval",
        title=title,
        body=body,
        expires_at_ms=2_000,
        destructive=True,
    )
    assert results[phone.device_id]["state"] == "sent"
    row = store.notification_outbox(device_id=phone.device_id)[0]
    assert row.state == "sent" and row.descriptor == push.descriptors[0].to_dict()
    decoded = decrypt_notification_preview(
        push.descriptors[0],
        recipient_private_key=preview_key.private_key,
        sender_public_key=identity.kem_public,
        now_ms=1_001,
    )
    assert len(decoded.to_bytes()) <= 1_200
    assert decoded.title == title
    assert decoded.body.endswith("…")
    assert body.startswith(decoded.body[:-1])
    assert decoded.action["request_id"] == "req_unicode_approval"
    assert decoded.action["session_id"] == "sess_unicode_approval"
    assert decoded.action["device_id"] == phone.device_id
    assert decoded.action["device_generation"] == phone.kem_generation
    assert decoded.action["allowed_decisions"] == ["approve_once", "deny"]
    store.close()
