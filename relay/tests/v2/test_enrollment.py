from __future__ import annotations

import pytest

from hermes_relay.v2.enrollment import AgentEnrollmentManager
from hermes_relay.v2.errors import Expired
from hermes_relay.v2.identity import load_or_create_identity
from hermes_relay.v2.protection import FilePermissionFallbackProtector
from hermes_relay.v2.storage import RelayStorage


class EnrollmentHub:
    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.lose_first_response = True

    async def enroll_provisional_agent(self, **request):
        self.requests.append(dict(request))
        if len(self.requests) > 1:
            assert request == self.requests[0]
        if self.lose_first_response:
            self.lose_first_response = False
            raise ConnectionError("response lost after enrollment commit")
        return {
            "enrollment_id": request["enrollment_id"],
            "route_id": "rte_same_provisional",
            "status": "provisional",
            "expires_at_ms": 50_000,
        }


async def test_provisional_enrollment_response_loss_reuses_identity_and_request(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    hub = EnrollmentHub()
    manager = AgentEnrollmentManager(store, identity, hub)

    with pytest.raises(ConnectionError, match="response lost"):
        await manager.ensure_provisional()
    pending = store._conn.execute("SELECT * FROM agent_enrollments").fetchone()
    assert pending["state"] == "requested"
    enrollment_id = pending["enrollment_id"]
    identity_public = identity.sign_public

    store.close()
    reopened = RelayStorage(
        tmp_path, clock=lambda: 1_000, credential_protector=protector
    )
    restarted_identity = load_or_create_identity(reopened, protector=protector)
    assert restarted_identity.sign_public == identity_public
    enrolled = await AgentEnrollmentManager(
        reopened, restarted_identity, hub
    ).ensure_provisional()
    assert enrolled.enrollment_id == enrollment_id
    assert enrolled.route_id == "rte_same_provisional"
    assert len(hub.requests) == 2
    assert reopened.hub_route("rte_same_provisional")["status"] == "provisional"

    # Once the exact receipt is durable, startup does not create or call again.
    same = await AgentEnrollmentManager(
        reopened, restarted_identity, hub
    ).ensure_provisional()
    assert same == enrolled
    assert len(hub.requests) == 2


class ExpiredThenReadyHub:
    def __init__(self) -> None:
        self.ids: list[str] = []

    async def enroll_provisional_agent(self, **request):
        self.ids.append(request["enrollment_id"])
        if len(self.ids) == 1:
            raise Expired()
        return {
            "enrollment_id": request["enrollment_id"],
            "route_id": "rte_fresh",
            "status": "provisional",
            "expires_at_ms": 60_000,
        }


async def test_only_explicit_terminal_receipt_mints_fresh_enrollment_id(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    hub = ExpiredThenReadyHub()
    result = await AgentEnrollmentManager(store, identity, hub).ensure_provisional()
    assert result.route_id == "rte_fresh"
    assert len(hub.ids) == 2 and hub.ids[0] != hub.ids[1]
    states = [
        row["state"]
        for row in store._conn.execute(
            "SELECT state FROM agent_enrollments ORDER BY created_at_ms,rowid"
        )
    ]
    assert states == ["expired", "provisional"]


class ActivationHub:
    def __init__(self) -> None:
        self.calls: list[str] = []
        self.lose_first = True

    async def activate_agent_route(self, *, operator_enrollment_token: str):
        self.calls.append(operator_enrollment_token)
        if self.lose_first:
            self.lose_first = False
            raise ConnectionError("activation response lost")
        return {
            "route_id": "rte_self_hosted",
            "status": "active",
            "already_active": True,
        }


async def test_self_host_operator_activation_response_loss_retries_exact_token(
    tmp_path,
) -> None:
    protector = FilePermissionFallbackProtector()
    store = RelayStorage(tmp_path, clock=lambda: 1_000, credential_protector=protector)
    identity = load_or_create_identity(store, protector=protector)
    record = store.prepare_agent_enrollment(
        identity.sign_public, enrollment_id="enr_self"
    )
    record = store.record_provisional_agent_enrollment(
        enrollment_id=record.enrollment_id,
        auth_public_key=identity.sign_public,
        route_id="rte_self_hosted",
        expires_at_ms=60_000,
    )
    hub = ActivationHub()
    manager = AgentEnrollmentManager(store, identity, hub)

    with pytest.raises(ConnectionError, match="response lost"):
        await manager.activate_with_operator_token(record, "operator-file-secret")
    assert store.agent_enrollment(record.enrollment_id).state == "provisional"

    active = await manager.activate_with_operator_token(
        store.agent_enrollment(record.enrollment_id), "operator-file-secret"
    )
    assert active.state == "active"
    assert hub.calls == ["operator-file-secret", "operator-file-secret"]
    # Hosted/phone-token flow remains unchanged when no operator activation is invoked.
    same = await manager.ensure_provisional()
    assert same.state == "active"
