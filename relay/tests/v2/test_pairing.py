from __future__ import annotations

import asyncio
from dataclasses import replace

import pytest

from hermes_relay.v2.app import V2RelayApp
from hermes_relay.v2.crypto import (
    ed25519_public_from_private,
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
    open_authenticated_message,
    seal_base_message,
    x25519_public_from_private,
)
from hermes_relay.v2.identity import RelayIdentity, load_or_create_identity
from hermes_relay.v2.enrollment import AgentEnrollmentManager
from hermes_relay.v2.pairing import (
    PAIR_ACCEPT_INFO,
    PAIR_INIT_INFO,
    PairInit,
    PairingManager,
)
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.protocol import SecureMessage, b64url_encode, canonical_json
from hermes_relay.v2.storage import RelayStorage, StorageConflict


class Clock:
    def __init__(self, value: int = 100) -> None:
        self.value = value

    def __call__(self) -> int:
        return self.value


def test_pairing_offer_claim_confirmation_and_restart(tmp_path) -> None:
    store = RelayStorage(
        tmp_path, credential_protector=FilePermissionFallbackProtector()
    )
    identity = load_or_create_identity(store)
    manager = PairingManager(
        store, identity, hub_url="https://relay.example", relay_route="rte_agent"
    )
    qr = manager.create_offer()
    assert qr["v"] == 2
    assert "?" not in str(qr)
    offer = store.get_pair_offer(qr["offer_id"])

    device_kem = generate_x25519_key_pair()
    device_sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    provisional = PairInit(
        offer_id=offer.offer_id,
        device_name="Test iPhone",
        device_kem_public=device_kem.public_key,
        device_sign_public=device_sign.public_key,
        preview_kem_public=preview.public_key,
        device_nonce=b"n" * 16,
        push_bind_token="push_bind_once",
        hub_activation_token="hub_activate_once",
        pair_mac=b"0" * 32,
    )
    pair_init = replace(
        provisional,
        pair_mac=manager.pair_mac(offer.pair_secret, provisional.transcript_dict()),
    )
    changed_nonce = replace(pair_init, device_nonce=b"o" + pair_init.device_nonce[1:])
    assert manager.verification_code(offer, pair_init) != manager.verification_code(
        offer, changed_nonce
    )
    enc, ct = seal_base_message(
        canonical_json(pair_init.to_dict()),
        recipient_public_key=identity.kem_public,
        info=PAIR_INIT_INFO,
        aad=manager.offer_aad(offer),
    )
    claim = manager.decrypt_and_claim(offer.offer_id, enc=enc, ciphertext=ct)
    assert len(claim.verification_code) == 7
    # Same exact device can resume the claimed offer after process restart.
    store.close()
    reopened = RelayStorage(
        tmp_path, credential_protector=FilePermissionFallbackProtector()
    )
    manager = PairingManager(
        reopened,
        load_or_create_identity(reopened),
        hub_url="https://relay.example",
        relay_route="rte_agent",
    )
    resumed = manager.decrypt_and_claim(offer.offer_id, enc=enc, ciphertext=ct)
    assert resumed.verification_code == claim.verification_code
    accept = manager.confirm_claim(resumed, device_route="rte_device")
    assert (
        reopened.get_device(accept["device_id"], include_inactive=True).status
        == "pending"
    )
    import asyncio

    asyncio.run(
        manager.finalize_pair_confirm(
            offer_id=offer.offer_id, device_id=accept["device_id"]
        )
    )
    assert reopened.get_device(accept["device_id"]).status == "active"
    consumed = reopened.get_pair_offer(offer.offer_id)
    assert consumed.state == "consumed"
    assert consumed.pair_secret == b"" and consumed.transport_token == ""


def test_human_code_binds_every_offer_key_route_and_pairinit_field(tmp_path) -> None:
    store = RelayStorage(tmp_path, clock=lambda: 1_000)
    identity = RelayIdentity(
        relay_instance_id="rly_fixed",
        relay_epoch="epc_fixed",
        kem_generation=1,
        kem_private=b"r" * 32,
        kem_public=x25519_public_from_private(b"r" * 32),
        sign_private=b"s" * 32,
        sign_public=ed25519_public_from_private(b"s" * 32),
        protection_mode="test",
    )
    manager = PairingManager(
        store, identity, hub_url="https://relay.example", relay_route="rte_agent"
    )
    offer = store.create_pair_offer(
        relay_route="rte_agent",
        offer_id="ofr_fixed",
        offer_route="off_fixed",
        pair_secret=b"p" * 32,
        transport_token=b64url_encode(b"t" * 32),
    )
    base = PairInit(
        offer_id=offer.offer_id,
        device_name="Phone",
        device_kem_public=x25519_public_from_private(b"d" * 32),
        device_sign_public=ed25519_public_from_private(b"e" * 32),
        preview_kem_public=x25519_public_from_private(b"f" * 32),
        device_nonce=b"n" * 16,
        push_bind_token="push-one-time",
        hub_activation_token="activate-one-time",
        pair_mac=b"m" * 32,
    )
    expected = manager.verification_code(offer, base)
    mutations = [
        (replace(offer, offer_id="ofr_changed"), base),
        (replace(offer, offer_route="off_changed"), base),
        (replace(offer, relay_route="rte_changed"), base),
        (replace(offer, expires_at_ms=offer.expires_at_ms + 1), base),
        (offer, replace(base, offer_id="ofr_changed")),
        (offer, replace(base, device_name="Other Phone")),
        (offer, replace(base, device_kem_public=x25519_public_from_private(b"g" * 32))),
        (
            offer,
            replace(base, device_sign_public=ed25519_public_from_private(b"h" * 32)),
        ),
        (
            offer,
            replace(base, preview_kem_public=x25519_public_from_private(b"i" * 32)),
        ),
        (offer, replace(base, device_nonce=b"o" * 16)),
        (offer, replace(base, push_bind_token="other-push")),
        (offer, replace(base, hub_activation_token="other-activation")),
    ]
    for changed_offer, changed_init in mutations:
        assert manager.verification_code(changed_offer, changed_init) != expected

    changed_kem = replace(
        identity,
        kem_private=b"j" * 32,
        kem_public=x25519_public_from_private(b"j" * 32),
    )
    changed_sign = replace(
        identity,
        sign_private=b"k" * 32,
        sign_public=ed25519_public_from_private(b"k" * 32),
    )
    assert (
        PairingManager(
            store, changed_kem, hub_url="https://relay.example", relay_route="rte_agent"
        ).verification_code(offer, base)
        != expected
    )
    assert (
        PairingManager(
            store,
            changed_sign,
            hub_url="https://relay.example",
            relay_route="rte_agent",
        ).verification_code(offer, base)
        != expected
    )


class DuplexHub:
    def __init__(self) -> None:
        self.grants = []
        self.accepted = None
        self.confirmed = None
        self.fail_accept_response_once = True
        self.fail_confirm_response_once = True

    async def create_pending_device_route(self, *, auth_public_key, offer_id):
        assert len(auth_public_key) == 32
        return {
            "route_id": "rte_phone",
            "status": "pending",
            "owner_route": "rte_agent",
            "offer_id": offer_id,
        }

    async def create_grant(self, grant):
        assert set(grant) == {
            "grant_id",
            "issuer_route",
            "source_route",
            "destination_route",
            "permissions",
            "expires_at_ms",
            "issuer_signature",
        }
        self.grants.append(grant)
        return {"grant_id": grant["grant_id"], "created": True, "status": "pending"}

    async def accept_pair_offer(self, **body):
        exact = dict(body)
        if self.accepted is None:
            self.accepted = exact
        else:
            assert exact == self.accepted
        if self.fail_accept_response_once:
            self.fail_accept_response_once = False
            raise ConnectionError("response lost after commit")
        import hashlib

        return {
            "status": "accepted",
            "offer_id": body["offer_id"],
            "device_route": body["device_route"],
            "response_hash": b64url_encode(
                hashlib.sha256(body["enc"] + body["ciphertext"]).digest()
            ),
        }

    async def confirm_pair_offer(self, **body):
        exact = dict(body)
        if self.confirmed is None:
            self.confirmed = exact
        else:
            assert exact == self.confirmed
        if self.fail_confirm_response_once:
            self.fail_confirm_response_once = False
            raise ConnectionError("response lost after atomic activation")
        return {
            "device_route": body["device_route"],
            "status": "active",
            "grant_ids": [grant["grant_id"] for grant in self.grants],
        }

    async def cancel_pair_offer(self, _offer_id):
        raise AssertionError("loss-safe retry must not cancel the offer")


class CleanupPairingHub(DuplexHub):
    def __init__(self) -> None:
        super().__init__()
        self.fail_accept_response_once = False
        self.route_active = True
        self.cancel_calls = 0
        self.delete_calls = 0

    async def cancel_pair_offer(self, _offer_id):
        self.cancel_calls += 1
        self.route_active = False

    async def delete_route(self, route_id):
        self.delete_calls += 1
        active = self.route_active
        self.route_active = False
        return {
            "route_id": route_id,
            "status": "revoked",
            "grant_ids": sorted(grant["grant_id"] for grant in self.grants),
            "already_revoked": not active,
        }


class ConcurrentAcceptHub(DuplexHub):
    def __init__(self) -> None:
        super().__init__()
        self.fail_accept_response_once = False
        self.route_entered = asyncio.Event()
        self.release_route = asyncio.Event()

    async def create_pending_device_route(self, *, auth_public_key, offer_id):
        self.route_entered.set()
        await self.release_route.wait()
        return await super().create_pending_device_route(
            auth_public_key=auth_public_key, offer_id=offer_id
        )


async def test_concurrent_local_acceptors_share_one_durable_pair_accept(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path, credential_protector=FilePermissionFallbackProtector()
    )
    identity = load_or_create_identity(store)
    hub = ConcurrentAcceptHub()
    store.store_hub_route(route_id="rte_agent", kind="agent", status="active")
    first_manager = PairingManager(
        store,
        identity,
        hub_url="https://relay.example",
        relay_route="rte_agent",
        hub_client=hub,
    )
    second_manager = PairingManager(
        store,
        identity,
        hub_url="https://relay.example",
        relay_route="rte_agent",
        hub_client=hub,
    )
    offer = store.create_pair_offer(relay_route="rte_agent", auto_approve=True)
    device_kem = generate_x25519_key_pair()
    device_sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    unsigned = PairInit(
        offer_id=offer.offer_id,
        device_name="Concurrent Phone",
        device_kem_public=device_kem.public_key,
        device_sign_public=device_sign.public_key,
        preview_kem_public=preview.public_key,
        device_nonce=b"q" * 16,
        push_bind_token=None,
        hub_activation_token="unused",
        pair_mac=b"0" * 32,
    )
    pair_init = replace(
        unsigned,
        pair_mac=first_manager.pair_mac(
            offer.pair_secret, unsigned.transcript_dict()
        ),
    )
    enc, ciphertext = seal_base_message(
        canonical_json(pair_init.to_dict()),
        recipient_public_key=identity.kem_public,
        info=PAIR_INIT_INFO,
        aad=first_manager.offer_aad(offer),
    )
    claim = first_manager.decrypt_and_claim(
        offer.offer_id, enc=enc, ciphertext=ciphertext
    )
    store.set_pair_offer_message_hash(offer.offer_id, b64url_encode(b"m" * 32))

    first = asyncio.create_task(first_manager.accept_claim(claim))
    await hub.route_entered.wait()
    second = asyncio.create_task(second_manager.accept_claim(claim))
    await asyncio.sleep(0)
    hub.release_route.set()
    results = await asyncio.gather(first, second)

    assert sorted(result["resumed"] for result in results) == [False, True]
    durable = store.get_pair_offer(offer.offer_id)
    assert durable.state == "confirmed"
    device = store.get_device(durable.device_id, include_inactive=True)
    assert device is not None and device.status == "pending"
    assert len(hub.grants) == 2


class AmbiguousPairingPush:
    def __init__(self, store: RelayStorage, offer_id: str) -> None:
        self.store = store
        self.offer_id = offer_id
        self.remote_binding_active = False
        self.exchange = None
        self.revoke_calls = 0
        self.lose_revoke_response_once = False

    async def bind_device(self, device_id: str, bind_token: str) -> str:
        # The regression boundary: cleanup ownership must be durable before
        # the first network mutation that can create a Push binding.
        assert self.store.get_pair_offer(self.offer_id).device_id == device_id
        self.exchange = self.store.prepare_push_binding_exchange(
            device_id=device_id,
            bind_token=bind_token,
            requested_classes=["approval", "error", "update"],
        )
        self.remote_binding_active = True
        raise ConnectionError("Push exchange response lost after commit")

    async def revoke_device_binding(self, _device_id: str) -> bool:
        return False

    async def revoke_binding_exchange(self, bind_token: str, *, exchange_id: str):
        self.revoke_calls += 1
        assert self.exchange is not None
        assert bind_token == self.exchange.bind_token
        assert exchange_id == self.exchange.exchange_id
        was_active = self.remote_binding_active
        self.remote_binding_active = False
        if self.lose_revoke_response_once:
            self.lose_revoke_response_once = False
            raise ConnectionError("Push revoke response lost after commit")
        return {"revoked": True, "was_active": was_active}


def _claimed_push_offer(
    store: RelayStorage,
    identity: RelayIdentity,
    manager: PairingManager,
) -> tuple[object, object]:
    qr = manager.create_offer()
    offer = store.get_pair_offer(qr["offer_id"])
    device_kem = generate_x25519_key_pair()
    device_sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    unsigned = PairInit(
        offer_id=offer.offer_id,
        device_name="Ambiguous Push iPhone",
        device_kem_public=device_kem.public_key,
        device_sign_public=device_sign.public_key,
        preview_kem_public=preview.public_key,
        device_nonce=b"a" * 16,
        push_bind_token="push-bind-token-retained-for-revoke",
        hub_activation_token="attestation-only",
        pair_mac=b"0" * 32,
    )
    pair_init = replace(
        unsigned,
        pair_mac=manager.pair_mac(offer.pair_secret, unsigned.transcript_dict()),
    )
    enc, ciphertext = seal_base_message(
        canonical_json(pair_init.to_dict()),
        recipient_public_key=identity.kem_public,
        info=PAIR_INIT_INFO,
        aad=manager.offer_aad(offer),
    )
    claim = manager.decrypt_and_claim(offer.offer_id, enc=enc, ciphertext=ciphertext)
    store.set_pair_offer_message_hash(offer.offer_id, b64url_encode(b"m" * 32))
    return offer, claim


async def test_lost_push_exchange_response_then_offer_expiry_revokes_after_restart(
    tmp_path,
) -> None:
    clock = Clock()
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    hub = CleanupPairingHub()
    store.store_hub_route(route_id="rte_agent", kind="agent", status="active")
    manager = PairingManager(
        store,
        identity,
        hub_url="https://relay.example",
        relay_route="rte_agent",
        hub_client=hub,
    )
    offer, claim = _claimed_push_offer(store, identity, manager)
    push = AmbiguousPairingPush(store, offer.offer_id)
    manager.notification_sender = push

    with pytest.raises(ConnectionError, match="response lost after commit"):
        await manager.accept_claim(claim)
    durable = store.get_pair_offer(offer.offer_id)
    assert durable.state == "claimed" and durable.device_id is not None
    exchange = store.push_binding_exchange(durable.device_id)
    assert exchange.state == "pending"
    assert exchange.remote_revoke_state == "not_required"
    assert push.remote_binding_active is True

    clock.value = offer.expires_at_ms
    assert store.expire_pair_offers() == 1
    terminal = store.get_pair_offer(offer.offer_id)
    device = store.get_device(durable.device_id, include_inactive=True)
    exchange = store.push_binding_exchange(durable.device_id)
    assert terminal.state == "expired"
    assert terminal.pair_secret == b"" and terminal.transport_token == ""
    assert device.status == "revoked"
    assert device.status_reason == "pair_offer_expired"
    assert device.hub_revocation_state == "pending"
    assert {
        grant["status"] for grant in store.hub_grants_for_device(device.device_id)
    } == {"revoking"}
    assert exchange.remote_revoke_state == "pending"
    assert exchange.bind_token == "push-bind-token-retained-for-revoke"
    with pytest.raises(StorageConflict, match="queued for revocation"):
        store.complete_push_binding_exchange(
            device_id=device.device_id,
            exchange_id=exchange.exchange_id,
            binding_id="pb_must_not_be_recovered",
            send_capability=b"c" * 32,
            allowed_classes=["approval", "error", "update"],
        )
    assert store.push_binding(device.device_id) is None
    store.close()

    reopened = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    push.store = reopened
    app = object.__new__(V2RelayApp)
    app.storage = reopened
    app.hub = hub
    app.push = push
    assert await app.reconcile_remote_revocations() == 2
    assert push.remote_binding_active is False
    revoked_exchange = reopened.push_binding_exchange(device.device_id)
    assert revoked_exchange.state == "revoked"
    assert revoked_exchange.bind_token == ""
    assert (
        reopened.get_device(
            device.device_id, include_inactive=True
        ).hub_revocation_state
        == "confirmed"
    )


async def test_manual_pair_cancel_retries_lost_remote_revoke_after_restart(
    tmp_path,
) -> None:
    clock = Clock()
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    hub = CleanupPairingHub()
    store.store_hub_route(route_id="rte_agent", kind="agent", status="active")
    manager = PairingManager(
        store,
        identity,
        hub_url="https://relay.example",
        relay_route="rte_agent",
        hub_client=hub,
    )
    offer, claim = _claimed_push_offer(store, identity, manager)
    push = AmbiguousPairingPush(store, offer.offer_id)
    manager.notification_sender = push
    with pytest.raises(ConnectionError, match="response lost after commit"):
        await manager.accept_claim(claim)

    await manager.cancel_offer(offer.offer_id)
    cancelled = store.get_pair_offer(offer.offer_id)
    device = store.get_device(cancelled.device_id, include_inactive=True)
    exchange = store.push_binding_exchange(device.device_id)
    assert cancelled.state == "cancelled"
    assert device.status_reason == "pair_offer_cancelled"
    assert exchange.remote_revoke_state == "pending"
    assert exchange.bind_token
    assert hub.cancel_calls == 1
    store.close()

    push.lose_revoke_response_once = True
    reopened = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    push.store = reopened
    app = object.__new__(V2RelayApp)
    app.storage = reopened
    app.hub = hub
    app.push = push
    # Hub cleanup confirms; Push cleanup committed remotely but its response
    # was lost, so the local bind secret remains for an exact restart retry.
    assert await app.reconcile_remote_revocations() == 1
    pending = reopened.push_binding_exchange(device.device_id)
    assert pending.remote_revoke_state == "pending"
    assert pending.revoke_attempts == 1
    assert pending.bind_token
    assert push.remote_binding_active is False
    reopened.close()

    restarted = RelayStorage(tmp_path, clock=clock, credential_protector=protector)
    push.store = restarted
    app.storage = restarted
    assert await app.reconcile_remote_revocations() == 1
    revoked = restarted.push_binding_exchange(device.device_id)
    assert revoked.state == "revoked"
    assert revoked.bind_token == ""
    assert push.revoke_calls == 2
    assert restarted.re_pair_credential_cleanup_pending() == 0


class OfferRegistrationHub:
    def __init__(self):
        self.body = None
        self.calls = 0

    async def register_pair_offer(self, **body):
        self.calls += 1
        if self.body is None:
            self.body = dict(body)
        else:
            assert body == self.body
        if self.calls == 1:
            raise ConnectionError("registration response lost after commit")
        return {
            "offer_id": body["offer_id"],
            "offer_route": body["offer_route"],
            "expires_at_ms": body["expires_at_ms"],
        }

    async def cancel_pair_offer(self, _offer_id):
        raise AssertionError("registration loss must not cancel")


class FirstDeviceHub(DuplexHub):
    def __init__(self) -> None:
        super().__init__()
        self.fail_accept_response_once = False
        self.fail_confirm_response_once = False
        self.events = []

    async def enroll_provisional_agent(self, **request):
        self.events.append(("enroll", dict(request)))
        return {
            "enrollment_id": request["enrollment_id"],
            "route_id": "rte_agent",
            "status": "provisional",
            "expires_at_ms": 100_000,
        }

    async def register_pair_offer(self, **body):
        assert self.events[0][0] == "enroll"
        self.events.append(("offer", dict(body)))
        return {
            "offer_id": body["offer_id"],
            "offer_route": body["offer_route"],
            "expires_at_ms": body["expires_at_ms"],
        }

    async def activate_agent_route(self, **body):
        assert body == {"activation_token": "phone-attested-activation"}
        self.events.append(("activate", dict(body)))
        return {"route_id": "rte_agent", "status": "active", "already_active": False}

    async def create_pending_device_route(self, *, auth_public_key, offer_id):
        assert any(event[0] == "activate" for event in self.events)
        self.events.append(("device-route", {"offer_id": offer_id}))
        return await super().create_pending_device_route(
            auth_public_key=auth_public_key, offer_id=offer_id
        )


async def test_offer_registration_response_loss_retries_same_persisted_authority(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path, credential_protector=FilePermissionFallbackProtector()
    )
    identity = load_or_create_identity(store)
    hub = OfferRegistrationHub()
    manager = PairingManager(
        store,
        identity,
        hub_url="https://relay.example",
        relay_route="rte_agent",
        hub_client=hub,
    )
    import pytest

    with pytest.raises(ConnectionError, match="response lost"):
        await manager.create_registered_offer()
    rows = store._conn.execute("SELECT offer_id FROM pair_offers").fetchall()
    assert len(rows) == 1
    offer_id = rows[0]["offer_id"]
    pending = store.get_pair_offer(offer_id)
    assert pending.state == "pending"
    assert (
        pending.pair_secret and pending.transport_token and not pending.hub_registered
    )
    qr = await manager.register_existing_offer(offer_id)
    assert qr["offer_id"] == offer_id
    assert store.get_pair_offer(offer_id).hub_registered is True


async def test_first_device_activates_provisional_agent_before_pending_authority(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    hub = FirstDeviceHub()
    enrollment = await AgentEnrollmentManager(store, identity, hub).ensure_provisional()
    assert enrollment.route_id == "rte_agent"
    manager = PairingManager(
        store,
        identity,
        hub_url="https://relay.example",
        relay_route=enrollment.route_id,
        hub_client=hub,
    )
    qr = await manager.create_registered_offer()
    offer = store.get_pair_offer(qr["offer_id"])
    device_kem = generate_x25519_key_pair()
    device_sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    unsigned = PairInit(
        offer_id=offer.offer_id,
        device_name="First Phone",
        device_kem_public=device_kem.public_key,
        device_sign_public=device_sign.public_key,
        preview_kem_public=preview.public_key,
        device_nonce=b"f" * 16,
        push_bind_token=None,
        hub_activation_token="phone-attested-activation",
        pair_mac=b"0" * 32,
    )
    pair_init = replace(
        unsigned,
        pair_mac=manager.pair_mac(offer.pair_secret, unsigned.transcript_dict()),
    )
    enc, ciphertext = seal_base_message(
        canonical_json(pair_init.to_dict()),
        recipient_public_key=identity.kem_public,
        info=PAIR_INIT_INFO,
        aad=manager.offer_aad(offer),
    )
    claim = manager.decrypt_and_claim(offer.offer_id, enc=enc, ciphertext=ciphertext)
    store.set_pair_offer_message_hash(offer.offer_id, b64url_encode(b"m" * 32))
    accepted = await manager.accept_claim(claim)
    assert [event[0] for event in hub.events[:4]] == [
        "enroll",
        "offer",
        "activate",
        "device-route",
    ]
    assert store.hub_route("rte_agent")["status"] == "active"
    await manager.finalize_pair_confirm(
        offer_id=offer.offer_id,
        device_id=accepted["device_id"],
        response_hash=accepted["response_hash"],
    )
    assert store.get_device(accepted["device_id"]).status == "active"


async def test_duplex_pairing_retries_exact_ciphertext_and_confirm_receipt(
    tmp_path,
) -> None:
    store = RelayStorage(
        tmp_path, credential_protector=FilePermissionFallbackProtector()
    )
    identity = load_or_create_identity(store)
    hub = DuplexHub()
    manager = PairingManager(
        store,
        identity,
        hub_url="https://relay.example",
        relay_route="rte_agent",
        hub_client=hub,
    )
    store.store_hub_route(route_id="rte_agent", kind="agent", status="active")
    qr = manager.create_offer()
    offer = store.get_pair_offer(qr["offer_id"])
    device_kem = generate_x25519_key_pair()
    device_sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    unsigned = PairInit(
        offer_id=offer.offer_id,
        device_name="No Push iPhone",
        device_kem_public=device_kem.public_key,
        device_sign_public=device_sign.public_key,
        preview_kem_public=preview.public_key,
        device_nonce=b"d" * 16,
        push_bind_token=None,
        hub_activation_token="attestation_only",
        pair_mac=b"0" * 32,
    )
    pair_init = replace(
        unsigned,
        pair_mac=manager.pair_mac(offer.pair_secret, unsigned.transcript_dict()),
    )
    enc, ciphertext = seal_base_message(
        canonical_json(pair_init.to_dict()),
        recipient_public_key=identity.kem_public,
        info=PAIR_INIT_INFO,
        aad=manager.offer_aad(offer),
    )
    claim = manager.decrypt_and_claim(offer.offer_id, enc=enc, ciphertext=ciphertext)
    store.set_pair_offer_message_hash(offer.offer_id, b64url_encode(b"m" * 32))

    import pytest

    with pytest.raises(ConnectionError, match="after commit"):
        await manager.accept_claim(claim)
    durable = store.get_pair_offer(offer.offer_id)
    assert durable.state == "confirmed"
    assert durable.pair_secret and durable.transport_token
    accepted = await manager.accept_claim(claim)
    assert accepted["resumed"] is True
    assert len(hub.grants) == 2
    assert {
        grant["status"] for grant in store.hub_grants_for_device(accepted["device_id"])
    } == {"pending"}

    plaintext = open_authenticated_message(
        durable.accept_enc,
        durable.accept_ct,
        recipient_private_key=device_kem.private_key,
        sender_public_key=identity.kem_public,
        info=PAIR_ACCEPT_INFO,
        aad=manager.pair_accept_aad(
            offer_id=offer.offer_id,
            device_route="rte_phone",
            message_hash=durable.hub_message_hash,
        ),
    )
    secure = SecureMessage.from_bytes(plaintext)
    assert secure.kind.value == "pair.accept"
    assert secure.mid == durable.accept_mid
    assert "notifications" not in secure.body["capabilities"]
    assert secure.body["push_binding_id"] is None

    with pytest.raises(ConnectionError, match="atomic activation"):
        await manager.finalize_pair_confirm(
            offer_id=offer.offer_id,
            device_id=accepted["device_id"],
            response_hash=durable.hub_response_hash,
        )
    assert (
        store.get_device(accepted["device_id"], include_inactive=True).status
        == "pending"
    )
    await manager.finalize_pair_confirm(
        offer_id=offer.offer_id,
        device_id=accepted["device_id"],
        response_hash=durable.hub_response_hash,
    )
    assert store.get_device(accepted["device_id"]).status == "active"
    consumed = store.get_pair_offer(offer.offer_id)
    assert consumed.state == "consumed"
    assert consumed.pair_secret == b"" and consumed.transport_token == ""
    assert {
        grant["status"] for grant in store.hub_grants_for_device(accepted["device_id"])
    } == {"active"}
