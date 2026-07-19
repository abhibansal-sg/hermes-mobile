from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

from hermes_relay.gateway_client import GatewayConfig
from hermes_relay.v2.app import (
    KEY_ROTATION_GRACE_MS,
    KEY_ROTATION_MAX_AGE_MS,
    KEY_ROTATION_MAX_MESSAGES,
    V2RelayApp,
    V2RelayConfig,
)
from hermes_relay.v2.crypto import (
    decrypt_notification_preview,
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
    open_authenticated_envelope,
)
from hermes_relay.v2.notification_sender import NotificationSender
from hermes_relay.v2.identity import (
    load_or_create_identity,
    relay_private_kem_generations,
    rotate_relay_kem,
)
from hermes_relay.v2.protocol import (
    HPKEDirection,
    HPKEPurpose,
    NotificationClass,
    NotificationPreview,
    OuterEnvelope,
    ReceiveContext,
    SecureMessageKind,
    TransportClass,
    b64url_decode,
    b64url_encode,
)
from hermes_relay.v2.protection import (
    CredentialProtectionError,
    FilePermissionFallbackProtector,
    KeyringProtector,
    MacOSKeychainProtector,
)
from hermes_relay.v2.storage import RelayStorage


class Clock:
    def __init__(self, value: int = 100) -> None:
        self.value = value

    def __call__(self) -> int:
        return self.value


class MemoryProtector:
    mode = "memory-test-protector"

    def __init__(self) -> None:
        self.values: dict[bytes, bytes] = {}
        self.deleted: list[bytes] = []
        self.counter = 0

    def protect(self, label: str, secret: bytes) -> bytes:
        self.counter += 1
        handle = f"handle:{self.counter}:{label}".encode()
        self.values[handle] = secret
        return handle

    def reveal(self, wrapped: bytes) -> bytes:
        return self.values[wrapped]

    def delete(self, wrapped: bytes) -> None:
        self.deleted.append(wrapped)
        del self.values[wrapped]


class SimulatedCrash(BaseException):
    pass


class CrashAfterDeleteProtector(MemoryProtector):
    """Model a process death after keyring deletion but before DB finalize."""

    def __init__(self) -> None:
        super().__init__()
        self.crash_once = True

    def delete(self, wrapped: bytes) -> None:
        if wrapped not in self.values:
            # Keychain/keyring deletion is idempotent when the secret is gone.
            return
        self.deleted.append(wrapped)
        del self.values[wrapped]
        if self.crash_once:
            self.crash_once = False
            raise SimulatedCrash("crash after external credential deletion")


class PushDeleteFailureProtector(MemoryProtector):
    def delete(self, wrapped: bytes) -> None:
        if b"push-binding:" in wrapped:
            raise CredentialProtectionError("Push credential backend unavailable")
        super().delete(wrapped)


class Hub:
    async def close(self):
        return None


class LossyRevocationHub(Hub):
    def __init__(self, grant_ids) -> None:
        self.grant_ids = sorted(grant_ids)
        self.calls = []
        self.route_active = True

    async def delete_route(self, route_id):
        self.calls.append(route_id)
        if self.route_active:
            self.route_active = False
            raise ConnectionError("Hub response lost after route deletion")
        return {
            "route_id": route_id,
            "status": "revoked",
            "grant_ids": self.grant_ids,
            "already_revoked": True,
        }


class LossyRevocationPush:
    def __init__(self) -> None:
        self.calls = []
        self.binding_active = True

    async def revoke_binding(self, binding_id, *, send_capability):
        self.calls.append((binding_id, send_capability))
        if self.binding_active:
            self.binding_active = False
            raise ConnectionError("Push response lost after binding deletion")
        return {
            "binding_id": binding_id,
            "revoked": True,
            "already_revoked": True,
        }

    async def close(self):
        return None


class Push:
    def __init__(self) -> None:
        self.descriptors = []

    async def send(self, descriptor, *, send_capability):
        assert len(send_capability) == 32
        self.descriptors.append(descriptor)
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
    record = store.register_device(
        device_id=f"dev_{suffix}",
        name=suffix,
        route=f"rte_{suffix}",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    store.activate_device(record.device_id)
    return store.get_device(record.device_id), kem


def _app(store, identity, *, hub=None, push=None):
    return V2RelayApp(
        V2RelayConfig(
            gateway=GatewayConfig(token="test"),
            hub_url="https://hub.example",
            state_directory=store.directory,
        ),
        storage=store,
        identity=identity,
        relay_route="rte_agent",
        hub=hub or Hub(),
        push=push,
    )


def test_identity_capabilities_are_wrapped_and_rotation_retains_then_erases_old_key(
    tmp_path,
) -> None:
    clock = Clock()
    protector = MemoryProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    assert identity.protection_mode == protector.mode
    assert store.credential_protector is protector
    raw_private = identity.kem_private

    device = store.register_device(
        name="Phone",
        route="rte_phone",
        kem_public=b"k" * 32,
        sign_public=b"s" * 32,
        preview_public=b"p" * 32,
    )
    store.activate_device(device.device_id)
    hub_secret = b"hub-secret-material"
    push_secret = b"push-secret-material"
    store.store_hub_route(
        route_id="rte_agent", kind="agent", status="active", credential=hub_secret
    )
    store.store_push_binding(
        device_id=device.device_id,
        binding_id="pb_1",
        send_capability=push_secret,
        allowed_classes=["approval"],
    )
    assert store.hub_route("rte_agent")["credential"] == hub_secret
    assert store.push_binding(device.device_id)["send_capability"] == push_secret
    row = store._conn.execute(
        "SELECT kem_private,sign_private FROM relay_identity"
    ).fetchone()
    assert raw_private not in {bytes(row[0]), bytes(row[1])}
    assert (
        bytes(store._conn.execute("SELECT credential FROM hub_routes").fetchone()[0])
        != hub_secret
    )
    assert (
        bytes(
            store._conn.execute("SELECT send_capability FROM push_bindings").fetchone()[
                0
            ]
        )
        != push_secret
    )

    rotated = rotate_relay_kem(
        store,
        identity,
        previous_not_after_ms=200,
        protector=protector,
    )
    assert set(relay_private_kem_generations(store, protector=protector)) == {1, 2}
    for _ in range(10_000):
        store.record_relay_encryption(rotated.kem_generation)
    assert store.relay_rotation_due()
    old_handle = store.relay_kem_keys()[0].private_key
    clock.value = 201
    assert store.retire_relay_kem_keys() == 1
    assert old_handle in protector.deleted
    rows = store.relay_kem_keys(include_revoked=True)
    assert rows[0].status == "revoked" and rows[0].private_key == b""
    assert rows[1].status == "current"


def test_relay_kem_retirement_is_crash_idempotent_and_never_reveals_retiring_key(
    tmp_path,
) -> None:
    clock = Clock(100)
    protector = CrashAfterDeleteProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    rotate_relay_kem(
        store,
        identity,
        previous_not_after_ms=200,
        protector=protector,
    )
    old_handle = store.relay_kem_keys()[0].private_key
    clock.value = 200

    with pytest.raises(SimulatedCrash, match="after external credential deletion"):
        store.retire_relay_kem_keys()

    phased = store.relay_kem_keys(include_revoked=True)[0]
    assert phased.status == "previous"
    assert phased.retirement_started_at_ms == 200
    assert phased.private_key == old_handle
    assert old_handle not in protector.values
    store.close()

    # Reopen the real SQLite state to model process startup.  Identity loading
    # needs only the current generation; the missing retiring handle must
    # never be touched before maintenance retries its deletion.
    reopened = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    restarted_identity = load_or_create_identity(reopened, protector=protector)
    assert restarted_identity.kem_generation == 2
    # The durable phase, not successful external cleanup, controls visibility.
    assert set(relay_private_kem_generations(reopened, protector=protector)) == {2}
    assert [key.generation for key in reopened.relay_kem_keys()] == [2]

    assert reopened.retire_relay_kem_keys() == 1
    retired = reopened.relay_kem_keys(include_revoked=True)[0]
    assert retired.status == "revoked"
    assert retired.retirement_started_at_ms == 200
    assert retired.private_key == b""
    assert reopened.retire_relay_kem_keys() == 0
    reopened.close()


def test_relay_kem_retirement_does_not_misclassify_database_failure(
    tmp_path, monkeypatch
) -> None:
    clock = Clock(100)
    protector = MemoryProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    rotate_relay_kem(
        store,
        identity,
        previous_not_after_ms=200,
        protector=protector,
    )
    old_handle = store.relay_kem_keys()[0].private_key
    clock.value = 200

    original_delete = protector.delete

    def delete_then_break_finalize(wrapped: bytes) -> None:
        original_delete(wrapped)

        def fail_transaction():
            raise RuntimeError("SQLite finalize unavailable")

        monkeypatch.setattr(store, "transaction", fail_transaction)

    monkeypatch.setattr(protector, "delete", delete_then_break_finalize)
    with pytest.raises(RuntimeError, match="SQLite finalize unavailable"):
        store.retire_relay_kem_keys()

    phased = store.relay_kem_keys(include_revoked=True)[0]
    assert phased.status == "previous"
    assert phased.retirement_started_at_ms == 200
    assert phased.private_key == old_handle
    assert old_handle not in protector.values


def test_fallback_mode_is_explicit(tmp_path) -> None:
    fallback = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=fallback)
    identity = load_or_create_identity(store, protector=fallback)
    assert identity.protection_mode == "file-permissions-fallback"
    assert store.get_meta("credential_protection_mode") == b"file-permissions-fallback"


def test_macos_keychain_backend_never_puts_secret_in_subprocess_argv(
    monkeypatch,
) -> None:
    values: dict[tuple[str, str], str] = {}
    fake = SimpleNamespace(
        get_keyring=lambda: SimpleNamespace(priority=1),
        set_password=lambda service, account, value: values.__setitem__(
            (service, account), value
        ),
        get_password=lambda service, account: values.get((service, account)),
        delete_password=lambda service, account: values.pop((service, account)),
    )
    monkeypatch.setitem(sys.modules, "keyring", fake)
    calls: list[tuple] = []
    monkeypatch.setattr(subprocess, "run", lambda *args, **kwargs: calls.append(args))
    protector = MacOSKeychainProtector()
    secret = b"private-key-material"
    wrapped = protector.protect("identity", secret)
    assert protector.reveal(wrapped) == secret
    protector.delete(wrapped)
    protector.delete(wrapped)
    assert calls == []


@pytest.mark.parametrize("protector_type", [MacOSKeychainProtector, KeyringProtector])
def test_keyring_deletion_treats_only_a_missing_credential_as_success(
    monkeypatch, protector_type
) -> None:
    values: dict[tuple[str, str], str] = {}
    fail_delete = False

    def delete_password(service: str, account: str) -> None:
        if fail_delete:
            raise RuntimeError("backend unavailable")
        values.pop((service, account))

    fake = SimpleNamespace(
        get_keyring=lambda: SimpleNamespace(priority=1),
        set_password=lambda service, account, value: values.__setitem__(
            (service, account), value
        ),
        get_password=lambda service, account: values.get((service, account)),
        delete_password=delete_password,
    )
    monkeypatch.setitem(sys.modules, "keyring", fake)
    protector = protector_type()
    wrapped = protector.protect("retirement", b"secret")
    protector.delete(wrapped)
    protector.delete(wrapped)

    wrapped = protector.protect("backend-error", b"secret")
    fail_delete = True
    with pytest.raises(CredentialProtectionError, match="delete failed"):
        protector.delete(wrapped)
    assert protector.reveal(wrapped) == b"secret"


def test_windows_acl_command_removes_inheritance_and_grants_only_user_system(
    tmp_path, monkeypatch
) -> None:
    from hermes_relay.v2 import storage as storage_module

    captured: list[str] = []
    monkeypatch.setattr(storage_module.getpass, "getuser", lambda: "Alice")
    monkeypatch.setattr(
        storage_module.subprocess,
        "run",
        lambda argv, **_kwargs: captured.extend(argv) or SimpleNamespace(returncode=0),
    )
    RelayStorage._secure_windows_acl(Path(tmp_path), is_directory=True)
    assert "/inheritance:r" in captured
    assert "Alice:(OI)(CI)F" in captured
    assert "SYSTEM:(OI)(CI)F" in captured


async def test_production_rotation_is_per_device_restart_safe_and_bounded(
    tmp_path,
) -> None:
    clock = Clock(100)
    protector = MemoryProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    original = load_or_create_identity(store, protector=protector)
    first, first_kem = _device(store, "first")
    second, second_kem = _device(store, "second")
    clock.value += KEY_ROTATION_MAX_AGE_MS
    app = _app(store, original)

    assert app.maintain_relay_keys() is True
    assert app.identity.kem_generation == 2
    assert app.router.identity == app.identity
    assert app.pairing.identity == app.identity
    keys = store.relay_kem_keys()
    expected_not_after = clock.value + 24 * 60 * 60 * 1_000 + KEY_ROTATION_GRACE_MS
    assert [(key.generation, key.status) for key in keys] == [
        (1, "previous"),
        (2, "current"),
    ]
    assert keys[0].not_after_ms == expected_not_after

    for device, kem in ((first, first_kem), (second, second_kem)):
        rows = store.pending_outbox(device.device_id)
        assert len(rows) == 1
        assert rows[0].message_class == "control"
        assert rows[0].receipt_kind == "delivery"
        message = open_authenticated_envelope(
            OuterEnvelope.from_dict(rows[0].envelope),
            recipient_private_keys={1: kem.private_key},
            sender_public_keys={1: original.kem_public},
            signing_public_key=original.sign_public,
            purpose=HPKEPurpose.CONTROL,
            direction=HPKEDirection.AGENT_TO_DEVICE,
            receive=ReceiveContext(
                expected_destination=device.route,
                expected_source="rte_agent",
                now_ms=clock.value,
            ),
        )
        assert message.kind is SecureMessageKind.KEY_ROTATE
        assert message.sender_key_generation == 1
        assert message.body["generation"] == 2
        assert message.body["previous_not_after_ms"] == expected_not_after
        assert (
            b64url_decode(
                message.body["public_key"], field="public_key", exact_bytes=32
            )
            == app.identity.kem_public
        )

    # Exact retry in-process and after restart never generates generation 2
    # again or duplicates a per-device delivery.
    assert app.maintain_relay_keys() is False
    await app.close()
    reopened = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    restarted_identity = load_or_create_identity(reopened, protector=protector)
    restarted = _app(reopened, restarted_identity)
    assert restarted.maintain_relay_keys() is False
    assert restarted.identity.kem_generation == 2
    assert len(reopened.pending_outbox(first.device_id)) == 1
    assert len(reopened.pending_outbox(second.device_id)) == 1

    # Old private authority is erased exactly at mailbox TTL + 24h overlap.
    old_handle = reopened.relay_kem_keys()[0].private_key
    clock.value = expected_not_after
    assert restarted.maintain_relay_keys() is False
    retired = reopened.relay_kem_keys(include_revoked=True)[0]
    assert retired.status == "revoked" and retired.private_key == b""
    assert old_handle in protector.deleted
    await restarted.close()


async def test_key_maintenance_pump_runs_without_waiting_for_restart() -> None:
    app = object.__new__(V2RelayApp)
    app._closing = False
    calls = []

    def maintain():
        calls.append("maintain")
        app._closing = True
        return False

    app.maintain_relay_keys = maintain
    await app._key_maintenance_pump()
    assert calls == ["maintain"]


async def test_key_maintenance_pump_retries_transient_retirement_failure(
    monkeypatch,
) -> None:
    from hermes_relay.v2 import app as app_module

    app = object.__new__(V2RelayApp)
    app._closing = False
    calls = []

    def maintain():
        calls.append("maintain")
        if len(calls) == 1:
            raise CredentialProtectionError("credential backend unavailable")
        app._closing = True
        return False

    app.maintain_relay_keys = maintain
    monkeypatch.setattr(app_module, "KEY_MAINTENANCE_INTERVAL_S", 0)
    await app._key_maintenance_pump()
    assert calls == ["maintain", "maintain"]


async def test_startup_reconciles_remote_authority_when_key_erasure_is_pending() -> (
    None
):
    app = object.__new__(V2RelayApp)
    calls = []

    def expire():
        calls.append("expire")
        return 0

    def maintain():
        calls.append("maintain")
        raise CredentialProtectionError("credential backend unavailable")

    async def reconcile():
        calls.append("reconcile")
        return 0

    app.maintain_relay_keys = maintain
    app.reconcile_remote_revocations = reconcile
    app.storage = SimpleNamespace(expire_pair_offers=expire)
    await app.prepare_startup_maintenance()
    assert calls == ["expire", "maintain", "reconcile"]


async def test_remote_revocation_pump_retries_unexpected_reconciliation_failure(
    monkeypatch,
) -> None:
    from hermes_relay.v2 import app as app_module

    app = object.__new__(V2RelayApp)
    app._closing = False
    calls = []

    async def reconcile():
        calls.append("reconcile")
        if len(calls) == 1:
            raise RuntimeError("transient reconciliation failure")
        app._closing = True
        return 0

    app.reconcile_remote_revocations = reconcile
    monkeypatch.setattr(app_module, "KEY_MAINTENANCE_INTERVAL_S", 0)
    await app._remote_revocation_pump()
    assert calls == ["reconcile", "reconcile"]


async def test_offline_device_messages_and_notifications_stay_on_acknowledged_agent_key(
    tmp_path, monkeypatch
) -> None:
    from hermes_relay.v2 import device_router as router_module

    clock = Clock(100)
    protector = MemoryProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    original = load_or_create_identity(store, protector=protector)
    device_kem = generate_x25519_key_pair()
    device_sign = generate_ed25519_key_pair()
    preview_kem = generate_x25519_key_pair()
    pending = store.register_device(
        device_id="dev_offline",
        name="offline",
        route="rte_offline",
        kem_public=device_kem.public_key,
        sign_public=device_sign.public_key,
        preview_public=preview_kem.public_key,
    )
    store.activate_device(pending.device_id)
    store.store_push_binding(
        device_id=pending.device_id,
        binding_id="pb_offline",
        send_capability=b"c" * 32,
        allowed_classes=["approval", "error", "update"],
    )
    store.set_subscription(pending.device_id, "session", active=True)
    app = _app(store, original)
    clock.value += KEY_ROTATION_MAX_AGE_MS

    # Force the same-timestamp state MID to sort before the rotation MID, the
    # worst mailbox tie order.  Cryptographic causal safety must not depend on
    # which ciphertext the content-blind Hub returns first.
    mids = iter([b"\xff" * 16, b"\x00" * 16])
    real_token_bytes = router_module.secrets.token_bytes
    monkeypatch.setattr(router_module.secrets, "token_bytes", lambda _size: next(mids))
    assert app.maintain_relay_keys() is True
    offline = store.get_device(pending.device_id)
    assert offline.relay_kem_generation == original.kem_generation
    frame = app.router._enqueue_frame_batch(
        offline,
        [{"sid": "session", "turn": "turn", "kind": "status", "body": {}}],
        message_class=TransportClass.STATE,
    )
    monkeypatch.setattr(router_module.secrets, "token_bytes", real_token_bytes)
    rotation = next(
        row
        for row in store.pending_outbox(pending.device_id)
        if row.activates_relay_kem_generation == 2
    )
    assert frame.created_at_ms == rotation.created_at_ms == clock.value
    assert frame.message_id < rotation.message_id
    opened = open_authenticated_envelope(
        OuterEnvelope.from_dict(frame.envelope),
        recipient_private_keys={1: device_kem.private_key},
        sender_public_keys={1: original.kem_public},
        signing_public_key=original.sign_public,
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination=offline.route,
            expected_source="rte_agent",
            now_ms=clock.value,
        ),
    )
    assert opened.sender_key_generation == 1

    preview = NotificationPreview(
        notification_id="nid_offline_rotation",
        notification_class=NotificationClass.UPDATE,
        title="Update",
        body="Ready",
        thread_token="thread_offline",
        expires_at_ms=clock.value + 10_000,
    )
    push = Push()
    notifications = NotificationSender(store, app.identity, push)
    result = await notifications.send_to_device(offline.device_id, preview)
    assert result["accepted"] is True
    assert (
        decrypt_notification_preview(
            push.descriptors[0],
            recipient_private_key=preview_kem.private_key,
            sender_public_key=original.kem_public,
            now_ms=clock.value,
        )
        == preview
    )

    store._conn.execute(
        "UPDATE relay_kem_keys SET message_count=? WHERE status='current'",
        (KEY_ROTATION_MAX_MESSAGES,),
    )
    assert app.maintain_relay_keys() is False
    assert app.identity.kem_generation == 2

    # A device paired after the global rotation learns generation 2 directly;
    # it must not be initialized to the conservative generation of older peers.
    new_kem = generate_x25519_key_pair()
    new_sign = generate_ed25519_key_pair()
    new_preview = generate_x25519_key_pair()
    new_pending = store.register_device(
        device_id="dev_new",
        name="new",
        route="rte_new",
        kem_public=new_kem.public_key,
        sign_public=new_sign.public_key,
        preview_public=new_preview.public_key,
    )
    store.activate_device(new_pending.device_id)
    new_device = store.get_device(new_pending.device_id)
    assert new_device.relay_kem_generation == app.identity.kem_generation == 2
    new_frame = app.router._enqueue_frame_batch(
        new_device,
        [{"sid": "new_session", "turn": "turn", "kind": "status", "body": {}}],
    )
    new_opened = open_authenticated_envelope(
        OuterEnvelope.from_dict(new_frame.envelope),
        recipient_private_keys={1: new_kem.private_key},
        sender_public_keys={2: app.identity.kem_public},
        signing_public_key=app.identity.sign_public,
        purpose=HPKEPurpose.CHAT,
        direction=HPKEDirection.AGENT_TO_DEVICE,
        receive=ReceiveContext(
            expected_destination=new_device.route,
            expected_source="rte_agent",
            now_ms=clock.value,
        ),
    )
    assert new_opened.sender_key_generation == 2

    # Only the authenticated inner receipt promotes the offline peer.  Hub
    # acceptance of the rotation row alone leaves it on generation 1.
    store.mark_hub_accepted(offline.device_id, rotation.message_id)
    assert store.get_device(offline.device_id).relay_kem_generation == 1
    assert store.acknowledge_delivery(offline.device_id, rotation.message_id) is True
    promoted = store.get_device(offline.device_id)
    assert promoted.relay_kem_generation == 2
    promoted_frame = app.router._enqueue_frame_batch(
        promoted,
        [{"sid": "session", "turn": "after", "kind": "status", "body": {}}],
    )
    assert (
        open_authenticated_envelope(
            OuterEnvelope.from_dict(promoted_frame.envelope),
            recipient_private_keys={1: device_kem.private_key},
            sender_public_keys={2: app.identity.kem_public},
            signing_public_key=app.identity.sign_public,
            purpose=HPKEPurpose.CHAT,
            direction=HPKEDirection.AGENT_TO_DEVICE,
            receive=ReceiveContext(
                expected_destination=promoted.route,
                expected_source="rte_agent",
                now_ms=clock.value,
            ),
        ).sender_key_generation
        == 2
    )
    promoted_preview = NotificationPreview(
        notification_id="nid_promoted_rotation",
        notification_class=NotificationClass.UPDATE,
        title="Promoted",
        body="Ready",
        thread_token="thread_promoted",
        expires_at_ms=clock.value + 10_000,
    )
    await notifications.send_to_device(promoted.device_id, promoted_preview)
    assert (
        decrypt_notification_preview(
            push.descriptors[-1],
            recipient_private_key=preview_kem.private_key,
            sender_public_key=app.identity.kem_public,
            now_ms=clock.value,
        )
        == promoted_preview
    )
    await app.close()


async def test_agent_rotation_receipts_advance_two_devices_independently(
    tmp_path,
) -> None:
    clock = Clock(100)
    protector = MemoryProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    original = load_or_create_identity(store, protector=protector)
    first, _first_kem = _device(store, "independent_first")
    second, _second_kem = _device(store, "independent_second")
    clock.value += KEY_ROTATION_MAX_AGE_MS
    app = _app(store, original)
    assert app.maintain_relay_keys() is True

    notices = {
        device.device_id: next(
            row
            for row in store.pending_outbox(device.device_id)
            if row.activates_relay_kem_generation == 2
        )
        for device in (first, second)
    }
    for notice in notices.values():
        store.mark_hub_accepted(notice.device_id, notice.message_id)
    assert store.get_device(first.device_id).relay_kem_generation == 1
    assert store.get_device(second.device_id).relay_kem_generation == 1

    assert store.acknowledge_delivery(
        first.device_id, notices[first.device_id].message_id
    )
    assert store.get_device(first.device_id).relay_kem_generation == 2
    assert store.get_device(second.device_id).relay_kem_generation == 1
    assert store.relay_rotation_awaiting_device_receipts() is True

    assert store.acknowledge_delivery(
        second.device_id, notices[second.device_id].message_id
    )
    assert store.get_device(second.device_id).relay_kem_generation == 2
    assert store.relay_rotation_awaiting_device_receipts() is False
    await app.close()


async def test_expired_laggard_requires_re_pair_without_blocking_healthy_rotation(
    tmp_path,
) -> None:
    clock = Clock(100)
    protector = PushDeleteFailureProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    original = load_or_create_identity(store, protector=protector)
    healthy, _healthy_kem = _device(store, "healthy")
    laggard, _laggard_kem = _device(store, "laggard")
    store.store_hub_route(
        route_id=laggard.route,
        kind="device",
        status="active",
    )
    store.store_hub_grant(
        grant_id="grt_laggard",
        device_id=laggard.device_id,
        source_route=laggard.route,
        destination_route="rte_agent",
        permissions=["send"],
        issuer_signature=b"signature",
        status="active",
    )
    store.store_push_binding(
        device_id=laggard.device_id,
        binding_id="pb_laggard",
        send_capability=b"p" * 32,
        allowed_classes=["approval", "error", "update"],
    )
    store.set_subscription(laggard.device_id, "session", active=True, foreground=True)

    hub = LossyRevocationHub(["grt_laggard"])
    push = LossyRevocationPush()
    # Push is intentionally unconfigured for the first process.  Quarantine
    # must retain the only remote-revocation capability for a later restart.
    app = _app(store, original, hub=hub, push=None)
    clock.value += KEY_ROTATION_MAX_AGE_MS
    assert app.maintain_relay_keys() is True
    generation_one = next(key for key in store.relay_kem_keys() if key.generation == 1)
    healthy_notice = next(
        row
        for row in store.pending_outbox(healthy.device_id)
        if row.activates_relay_kem_generation == 2
    )
    laggard_notice = next(
        row
        for row in store.pending_outbox(laggard.device_id)
        if row.activates_relay_kem_generation == 2
    )
    store.mark_hub_accepted(healthy.device_id, healthy_notice.message_id)
    assert store.acknowledge_delivery(healthy.device_id, healthy_notice.message_id)
    assert store.get_device(healthy.device_id).relay_kem_generation == 2
    assert store.get_device(laggard.device_id).relay_kem_generation == 1
    assert store.relay_rotation_awaiting_device_receipts() is True

    store._conn.execute(
        "UPDATE relay_kem_keys SET message_count=? WHERE status='current'",
        (KEY_ROTATION_MAX_MESSAGES,),
    )
    clock.value = generation_one.not_after_ms
    assert app.maintain_relay_keys() is True
    assert app.identity.kem_generation == 3

    tombstone = store.get_device(laggard.device_id, include_inactive=True)
    assert tombstone is not None
    assert tombstone.status == "revoked"
    assert tombstone.re_pair_required is True
    assert tombstone.status_reason == "relay_kem_overlap_expired"
    assert store.get_device(laggard.device_id) is None
    assert [device.device_id for device in store.active_devices()] == [
        healthy.device_id
    ]
    assert store.device_public_kem_generations(laggard.device_id) == {}
    assert store.pending_outbox(laggard.device_id) == []
    failed_notice = store._conn.execute(
        "SELECT state,last_error_code FROM outbox WHERE device_id=? AND message_id=?",
        (laggard.device_id, laggard_notice.message_id),
    ).fetchone()
    assert tuple(failed_notice) == ("failed", "device_re_pair_required")
    # A send which was already in flight when quarantine committed cannot
    # resurrect terminal outbox authority when its Hub response arrives late.
    store.mark_hub_accepted(laggard.device_id, laggard_notice.message_id)
    store.mark_send_failed(
        laggard.device_id, laggard_notice.message_id, "TRANSPORT_UNAVAILABLE"
    )
    failed_notice = store._conn.execute(
        "SELECT state,last_error_code FROM outbox WHERE device_id=? AND message_id=?",
        (laggard.device_id, laggard_notice.message_id),
    ).fetchone()
    assert tuple(failed_notice) == ("failed", "device_re_pair_required")
    assert store.active_subscriptions() == []
    assert store.hub_route(laggard.route)["status"] == "revoking"
    assert store.hub_grants_for_device(laggard.device_id)[0]["status"] == "revoking"
    assert store.push_binding(laggard.device_id) is None

    binding = store._conn.execute(
        "SELECT status,send_capability FROM push_bindings WHERE device_id=?",
        (laggard.device_id,),
    ).fetchone()
    assert binding["status"] == "remote_revoke_pending"
    assert bytes(binding["send_capability"]) in protector.values
    assert store.re_pair_credential_cleanup_pending() == 1
    assert store.re_pair_hub_revocation_pending() == 1
    retired = next(
        key for key in store.relay_kem_keys(include_revoked=True) if key.generation == 1
    )
    assert retired.status == "revoked" and retired.private_key == b""
    assert generation_one.private_key in protector.deleted
    assert any(
        row.activates_relay_kem_generation == 3
        for row in store.pending_outbox(healthy.device_id)
    )
    # The Hub commits but its response is lost.  With no Push client, the Push
    # authority is not erased or guessed at; both durable jobs remain visible.
    assert await app.reconcile_remote_revocations() == 0
    assert hub.route_active is False
    assert hub.calls == [laggard.route]
    assert push.calls == []
    status = app.status()
    laggard_status = next(
        item for item in status["devices"] if item["device_id"] == laggard.device_id
    )
    assert laggard_status["re_pair_required"] is True
    assert laggard_status["status_reason"] == "relay_kem_overlap_expired"
    assert laggard_status["hub_revocation_state"] == "pending"
    assert laggard_status["hub_revocation_attempts"] == 1
    assert laggard_status["hub_revocation_last_error"] == "ConnectionError"
    assert status["re_pair_credential_cleanup_pending"] == 1
    assert status["re_pair_hub_revocation_pending"] == 1
    assert status["re_pair_push_revocations"] == [
        {
            "device_id": laggard.device_id,
            "state": "remote_revoke_pending",
            "attempts": 0,
            "last_error_code": None,
        }
    ]
    await app.close()

    # Restart recovers the idempotent Hub response.  The first Push revoke is
    # likewise committed remotely with its response lost, so its capability
    # remains present and pending for one more restart.
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    restarted_identity = load_or_create_identity(store, protector=protector)
    app = _app(store, restarted_identity, hub=hub, push=push)
    assert await app.reconcile_remote_revocations() == 1
    tombstone = store.get_device(laggard.device_id, include_inactive=True)
    assert tombstone.hub_revocation_state == "confirmed"
    assert store.hub_route(laggard.route)["status"] == "revoked"
    assert store.hub_grants_for_device(laggard.device_id)[0]["status"] == "revoked"
    assert push.binding_active is False
    assert len(push.calls) == 1
    binding = store._conn.execute(
        "SELECT status,send_capability,revoke_attempts FROM push_bindings "
        "WHERE device_id=?",
        (laggard.device_id,),
    ).fetchone()
    assert binding["status"] == "remote_revoke_pending"
    assert binding["revoke_attempts"] == 1
    assert bytes(binding["send_capability"]) in protector.values
    await app.close()

    # The final retry receives the Push tombstone.  A separate local keyring
    # outage remains observable after remote confirmation; it cannot resurrect
    # authority or block healthy Agent rotation.
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    restarted_identity = load_or_create_identity(store, protector=protector)
    app = _app(store, restarted_identity, hub=hub, push=push)
    assert await app.reconcile_remote_revocations() == 1
    assert hub.calls == [laggard.route, laggard.route]
    assert len(push.calls) == 2
    binding = store._conn.execute(
        "SELECT status,send_capability FROM push_bindings WHERE device_id=?",
        (laggard.device_id,),
    ).fetchone()
    assert binding["status"] == "remote_revoked"
    assert bytes(binding["send_capability"]) in protector.values
    assert store.re_pair_hub_revocation_pending() == 0
    assert store.re_pair_credential_cleanup_pending() == 1
    assert any(
        row.activates_relay_kem_generation == 3
        for row in store.pending_outbox(healthy.device_id)
    )
    await app.close()


async def test_quarantine_revokes_ambiguous_push_exchange_without_recovering_capability(
    tmp_path,
) -> None:
    class SuccessfulHub(Hub):
        async def delete_route(self, route_id):
            return {
                "route_id": route_id,
                "status": "revoked",
                "grant_ids": [],
                "already_revoked": False,
            }

    class ExchangePush:
        def __init__(self) -> None:
            self.revoke_calls = 0

        async def revoke_binding_exchange(self, bind_token, *, exchange_id):
            self.revoke_calls += 1
            assert bind_token == "bind-token"
            assert exchange_id == exchange.exchange_id
            return {"revoked": True}

        async def close(self):
            return None

    clock = Clock(100)
    protector = MemoryProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    original = load_or_create_identity(store, protector=protector)
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    pending = store.register_device(
        device_id="dev_exchange_laggard",
        name="exchange laggard",
        route="rte_exchange_laggard",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    exchange = store.prepare_push_binding_exchange(
        device_id=pending.device_id,
        bind_token="bind-token",
        requested_classes=["approval", "error", "update"],
    )
    store.activate_device(pending.device_id)
    rotated = rotate_relay_kem(
        store,
        original,
        previous_not_after_ms=200,
        protector=protector,
    )
    clock.value = 200
    assert store.retire_relay_kem_keys() == 1
    assert store.push_binding_exchange(pending.device_id).state == "pending"

    push = ExchangePush()
    app = _app(store, rotated, hub=SuccessfulHub(), push=push)
    assert await app.reconcile_remote_revocations() == 2
    revoked = store.push_binding_exchange(pending.device_id)
    assert revoked.state == "revoked"
    assert revoked.binding_id is None
    assert revoked.bind_token == ""
    assert (
        store._conn.execute(
            "SELECT 1 FROM push_bindings WHERE device_id=?", (pending.device_id,)
        ).fetchone()
        is None
    )
    assert push.revoke_calls == 1
    assert store.re_pair_credential_cleanup_pending() == 0
    assert exchange.exchange_id == revoked.exchange_id
    await app.close()
