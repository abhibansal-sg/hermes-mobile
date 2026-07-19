from __future__ import annotations

import pytest

from hermes_relay.v2.crypto import generate_ed25519_key_pair, generate_x25519_key_pair
from hermes_relay.v2.identity import load_or_create_identity
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.revocation import DeviceRevoker
from hermes_relay.v2.storage import RelayStorage


class LossyHub:
    def __init__(self, grant_ids):
        self.grant_ids = sorted(grant_ids)
        self.calls = []

    async def delete_route(self, route_id):
        self.calls.append(route_id)
        if len(self.calls) == 1:
            raise ConnectionError("route revoke response lost after commit")
        return {
            "route_id": route_id,
            "status": "revoked",
            "grant_ids": self.grant_ids,
            "already_revoked": True,
        }


class Notifications:
    def __init__(self, store):
        self.store = store
        self.calls = 0

    async def reconcile_device_revocation(self, device_id):
        self.calls += 1
        confirmed = 0
        for record in self.store.pending_push_binding_revocations():
            if record.device_id != device_id:
                continue
            self.store.push_binding_revocation_capability(record.binding_id)
            confirmed += self.store.confirm_push_binding_remote_revocation(
                record.binding_id
            )
        self.store.finish_confirmed_remote_credential_cleanup()
        return confirmed


async def test_owner_revoke_recovers_exactly_after_hub_response_loss(tmp_path) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, credential_protector=protector)
    load_or_create_identity(store, protector=protector)
    kem = generate_x25519_key_pair()
    sign = generate_ed25519_key_pair()
    preview = generate_x25519_key_pair()
    device = store.register_device(
        device_id="dev_revoke",
        name="Phone",
        route="rte_revoke",
        kem_public=kem.public_key,
        sign_public=sign.public_key,
        preview_public=preview.public_key,
    )
    store.activate_device(device.device_id)
    store.store_hub_route(route_id=device.route, kind="device", status="active")
    grants = ["grt_agent_to_phone", "grt_phone_to_agent"]
    for grant_id, source, destination in (
        (grants[0], "rte_agent", device.route),
        (grants[1], device.route, "rte_agent"),
    ):
        store.store_hub_grant(
            grant_id=grant_id,
            device_id=device.device_id,
            source_route=source,
            destination_route=destination,
            permissions=["send", "receive"],
            issuer_signature=b"s" * 64,
            status="active",
        )
    store.store_push_binding(
        device_id=device.device_id,
        binding_id="pb_revoke",
        send_capability=b"c" * 32,
        allowed_classes=["approval", "error", "update"],
    )
    hub = LossyHub(grants)
    notifications = Notifications(store)
    revoker = DeviceRevoker(store, hub, notifications)

    with pytest.raises(ConnectionError, match="response lost"):
        await revoker.revoke(device.device_id)
    assert store.get_device(device.device_id, include_inactive=True).status == "revoked"
    assert store.re_pair_hub_revocation_pending() == 1
    assert store.push_binding(device.device_id) is None

    result = await revoker.revoke(device.device_id)
    assert result["already_revoked"] is True
    assert hub.calls == [device.route, device.route]
    assert store.get_device(device.device_id, include_inactive=True).status == "revoked"
    assert store.hub_route(device.route)["status"] == "revoked"
    assert {g["status"] for g in store.hub_grants_for_device(device.device_id)} == {
        "revoked"
    }
    assert notifications.calls == 2
