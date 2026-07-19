from __future__ import annotations

import asyncio
import importlib
import pkgutil
import secrets
import sys
from pathlib import Path

import pytest
import yaml
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient
from sqlalchemy import func, select

import relay_hub
from relay_hub.app import SocketManager, create_app
from relay_hub.crypto import b64url_encode
from relay_hub.models import OuterEnvelope
from relay_hub.settings import Settings
from relay_hub.storage import Conflict, DatabaseStore, metadata, routes


def test_state_collapse_reserve_and_never_evict_command_control() -> None:
    settings = Settings(
        database_url="sqlite:///:memory:",
        operator_enrollment_token="operator-test-token",
        mailbox_records=5,
        mailbox_bytes=10_000,
        reserved_records=2,
        reserved_bytes=1_000,
    )
    store = DatabaseStore(settings)
    from conftest import HubHarness

    with TestClient(create_app(settings=settings, store=store)) as client:
        harness = HubHarness(client, store, settings)
        agent, agent_key = harness.enroll("agent")
        device, _ = harness.enroll("device", owner_route=agent)
        harness.grant(
            issuer_route=agent,
            issuer_key=agent_key,
            source_route=agent,
            destination_route=device,
        )
        first = harness.envelope(
            source_route=agent,
            destination_route=device,
            source_key=agent_key,
            collapse="same-state",
        )
        second = harness.envelope(
            source_route=agent,
            destination_route=device,
            source_key=agent_key,
            collapse="same-state",
        )
        assert client.post("/v2/messages", json=first.model_dump(by_alias=True)).status_code == 202
        assert client.post("/v2/messages", json=second.model_dump(by_alias=True)).status_code == 202
        assert store.counts(device)[0] == 1

        # Reset by ACKing the current state, then fill the three non-reserved slots.
        assert harness.signed_request(
            "POST", "/v2/acks", device, _, {"message_ids": [second.mid]}
        ).status_code == 200
        for _index in range(3):
            state_envelope = harness.envelope(
                source_route=agent, destination_route=device, source_key=agent_key
            )
            assert client.post(
                "/v2/messages", json=state_envelope.model_dump(by_alias=True)
            ).status_code == 202
        assert store.counts(device)[2] == 3
        # Commands consume reserved capacity, then evict only state. Five commands
        # survive; the sixth cannot evict any command/control record.
        for _index in range(5):
            command = harness.envelope(
                source_route=agent,
                destination_route=device,
                source_key=agent_key,
                message_class="command",
            )
            assert client.post("/v2/messages", json=command.model_dump(by_alias=True)).status_code == 202
        assert store.counts(device) == (5, store.counts(device)[1], 0)
        overflow = harness.envelope(
            source_route=agent,
            destination_route=device,
            source_key=agent_key,
            message_class="control",
        )
        assert client.post("/v2/messages", json=overflow.model_dump(by_alias=True)).status_code == 429


def test_provisional_enrollment_is_bounded_and_activation_fails_closed() -> None:
    settings = Settings(
        database_url="sqlite:///:memory:",
        provisional_per_source_per_hour=1,
        maximum_live_provisional_routes=2,
    )
    store = DatabaseStore(settings)
    with TestClient(create_app(settings=settings, store=store)) as client:
        key = b64url_encode(Ed25519PrivateKey.generate().public_key().public_bytes_raw())
        first = client.post(
            "/v2/enroll/provisional",
            json={
                "enrollment_id": "enr_" + b64url_encode(secrets.token_bytes(16)),
                "route_type": "agent",
                "auth_public_key": key,
            },
        )
        assert first.status_code == 201
        assert client.post(
            "/v2/enroll/activate",
            json={"route_id": first.json()["route_id"], "activation_token": None},
        ).status_code == 401
        assert client.post(
            "/v2/enroll/provisional",
            json={
                "enrollment_id": "enr_" + b64url_encode(secrets.token_bytes(16)),
                "route_type": "device",
                "auth_public_key": key,
            },
        ).status_code == 429


def test_expired_provisional_is_revoked_and_cannot_create_grant(harness) -> None:
    key = Ed25519PrivateKey.generate()
    response = harness.client.post(
        "/v2/enroll/provisional",
        json={
            "enrollment_id": "enr_" + b64url_encode(secrets.token_bytes(16)),
            "route_type": "agent",
            "auth_public_key": b64url_encode(key.public_key().public_bytes_raw()),
        },
    )
    route = response.json()["route_id"]
    harness.store.purge(response.json()["expires_at_ms"] + 1)
    assert harness.store.get_route(route).status == "revoked"
    # Route-auth rejects provisional/revoked actors before grant parsing.
    valid_shape = {
        "grant_id": "grt_" + b64url_encode(secrets.token_bytes(24)),
        "issuer_route": route,
        "source_route": route,
        "destination_route": route,
        "permissions": ["send"],
        "expires_at_ms": None,
        "issuer_signature": b64url_encode(bytes(64)),
    }
    signed = harness.signed_request("POST", "/v2/grants", route, key, valid_shape)
    assert signed.status_code == 401


def test_provisional_enrollment_exact_retry_recovers_route_and_conflicts_safely(harness) -> None:
    enrollment_id = "enr_" + b64url_encode(secrets.token_bytes(16))
    key = Ed25519PrivateKey.generate()
    body = {
        "enrollment_id": enrollment_id,
        "route_type": "agent",
        "auth_public_key": b64url_encode(key.public_key().public_bytes_raw()),
    }
    first = harness.client.post("/v2/enroll/provisional", json=body)
    assert first.status_code == 201
    retry = harness.client.post("/v2/enroll/provisional", json=body)
    assert retry.status_code == 200 and retry.json() == first.json()

    changed = dict(
        body,
        auth_public_key=b64url_encode(
            Ed25519PrivateKey.generate().public_key().public_bytes_raw()
        ),
    )
    conflict = harness.client.post("/v2/enroll/provisional", json=changed)
    assert conflict.status_code == 409
    assert conflict.json()["error"]["code"] == "enrollment_id_conflict"

    with pytest.raises(Conflict, match="provisional_enrollment_expired"):
        harness.store.get_provisional_enrollment(
            enrollment_id=enrollment_id,
            public_key=key.public_key().public_bytes_raw(),
            route_type="agent",
            now_ms=first.json()["expires_at_ms"] + 1,
        )


def test_hub_schema_and_imports_are_content_blind() -> None:
    prohibited = {
        "session_id",
        "turn_id",
        "item_id",
        "prompt",
        "title",
        "body",
        "tool_args",
        "tool_result",
    }
    columns = {column.name for table in metadata.tables.values() for column in table.columns}
    assert not (prohibited & columns)
    assert set(OuterEnvelope.model_fields) == {
        "v",
        "src",
        "dst",
        "mid",
        "message_class",
        "expires_at_ms",
        "recipient_key_generation",
        "collapse",
        "enc",
        "ct",
        "sig",
    }
    # Exercise the actual import boundary instead of parsing source text. A
    # content-blind Hub runtime must not load the Push package or any APNs
    # provider module when its complete shipped package is imported.
    for module in pkgutil.walk_packages(
        relay_hub.__path__, prefix=f"{relay_hub.__name__}."
    ):
        importlib.import_module(module.name)
    loaded = {name.lower() for name in sys.modules}
    assert not any(name.startswith("push_gateway") for name in loaded)
    assert not any("apns" in name for name in loaded)


def test_realtime_receipts_are_bounded_without_consuming_priority_reserve() -> None:
    settings = Settings(
        database_url="sqlite:///:memory:",
        operator_enrollment_token="operator-test-token",
        mailbox_records=3,
        reserved_records=1,
        receipt_records_per_route=4,
        receipt_reserved_records=1,
        accepted_messages_per_route_per_minute=10,
        accepted_message_rate_reserve=1,
    )
    store = DatabaseStore(settings)
    from conftest import HubHarness

    with TestClient(create_app(settings=settings, store=store)) as client:
        harness = HubHarness(client, store, settings)
        agent, key = harness.enroll("agent")
        device, _ = harness.enroll("device", owner_route=agent)
        harness.grant(
            issuer_route=agent,
            issuer_key=key,
            source_route=agent,
            destination_route=device,
        )
        realtime = []
        for _index in range(3):
            envelope = harness.envelope(
                source_route=agent,
                destination_route=device,
                source_key=key,
                message_class="realtime",
            )
            realtime.append(envelope)
            assert client.post(
                "/v2/messages", json=envelope.model_dump(by_alias=True)
            ).status_code == 202
        assert store.counts(device)[0] == 0
        overflow = harness.envelope(
            source_route=agent,
            destination_route=device,
            source_key=key,
            message_class="realtime",
        )
        assert client.post(
            "/v2/messages", json=overflow.model_dump(by_alias=True)
        ).status_code == 429
        # Exact replay is checked before quota and the reserved priority slot
        # remains available to a durable command/control message.
        assert client.post(
            "/v2/messages", json=realtime[0].model_dump(by_alias=True)
        ).status_code == 200
        command = harness.envelope(
            source_route=agent,
            destination_route=device,
            source_key=key,
            message_class="command",
        )
        assert client.post(
            "/v2/messages", json=command.model_dump(by_alias=True)
        ).status_code == 202
        assert store.counts(device)[0] == 1


def test_socket_overflow_forces_only_slow_consumer_to_reconnect() -> None:
    async def scenario() -> None:
        manager = SocketManager(
            queue_depth=1,
            maximum_queue_bytes=1024 * 1024,
            maximum_total_queue_bytes=4 * 1024 * 1024,
            maximum_connections=4,
            maximum_connections_per_route=4,
        )
        slow = await manager.add("rte_device")
        fast = await manager.add("rte_device")
        first = {"v": 2, "class": "state", "mid": "first"}
        second = {"v": 2, "class": "state", "mid": "second"}
        assert await manager.publish("rte_device", first) == 2
        assert (await fast.get())["envelope"]["mid"] == "first"
        assert await manager.publish("rte_device", second) == 1
        assert (await slow.get()) == {
            "type": "overflow",
            "code": "reconnect_required",
        }
        assert (await fast.get())["envelope"]["mid"] == "second"
        await manager.remove("rte_device", slow)
        replacement = await manager.add("rte_device")
        third = {"v": 2, "class": "state", "mid": "replayed"}
        await manager.publish("rte_device", third)
        assert (await replacement.get())["envelope"]["mid"] == "replayed"

    asyncio.run(scenario())


def test_hub_request_body_limit_rejects_declared_and_streamed_overflow() -> None:
    settings = Settings(
        database_url="sqlite:///:memory:",
        operator_enrollment_token="operator-test-token",
    )
    store = DatabaseStore(settings)
    with TestClient(create_app(settings=settings, store=store)) as client:
        oversized = b"x" * (settings.maximum_request_body_bytes + 1)
        assert client.post(
            "/v2/enroll/provisional",
            content=oversized,
            headers={"Content-Type": "application/json"},
        ).status_code == 413
        assert client.post(
            "/v2/enroll/provisional",
            content=iter([b"x" * 250_000, b"y" * 250_000]),
            headers={"Content-Type": "application/json"},
        ).status_code == 413
        with store.engine.connect() as conn:
            assert conn.execute(select(func.count()).select_from(routes)).scalar_one() == 0


def test_hub_production_configuration_fails_closed() -> None:
    with pytest.raises(ValueError, match="requires PostgreSQL"):
        Settings(
            production_mode=True,
            database_url="sqlite:///relay-hub.db",
            operator_enrollment_token="operator-token",
            auto_create_schema=False,
        ).validate()
    with pytest.raises(ValueError, match="explicit migrations"):
        Settings(
            production_mode=True,
            database_url="postgresql+psycopg://relay_hub@db/relay_hub",
            operator_enrollment_token="operator-token",
            auto_create_schema=True,
        ).validate()
    with pytest.raises(ValueError, match="enrollment authority"):
        Settings(
            production_mode=True,
            database_url="postgresql+psycopg://relay_hub@db/relay_hub",
            auto_create_schema=False,
        ).validate()
    Settings(
        production_mode=True,
        database_url="postgresql+psycopg://relay_hub@db/relay_hub",
        operator_enrollment_token="operator-token",
        auto_create_schema=False,
    ).validate()


def test_compose_trusts_only_fixed_caddy_addresses_for_forwarded_identity() -> None:
    server_dir = Path(__file__).resolve().parents[2]
    compose = yaml.safe_load((server_dir / "compose.hrp2.yml").read_text())
    services = compose["services"]

    hub_proxy = services["relay-hub"]["environment"]["FORWARDED_ALLOW_IPS"]
    push_proxy = services["push-gateway"]["environment"]["FORWARDED_ALLOW_IPS"]
    assert hub_proxy == services["caddy"]["networks"]["hub-ingress"]["ipv4_address"]
    assert push_proxy == services["caddy"]["networks"]["push-ingress"]["ipv4_address"]
    assert hub_proxy != "*" and push_proxy != "*"
    assert "ports" not in services["relay-hub"]
    assert "ports" not in services["push-gateway"]

    networks = compose["networks"]
    assert networks["hub-ingress"]["ipam"]["config"][0]["subnet"] == "172.31.250.0/24"
    assert networks["push-ingress"]["ipam"]["config"][0]["subnet"] == "172.31.251.0/24"

    caddy = (server_dir / "relay-hub" / "deploy" / "Caddyfile").read_text()
    assert caddy.count("header_up X-Forwarded-For {remote_host}") == 3
    for path in (
        "/v2/attest/challenge",
        "/v2/hub-activations",
        "/v2/endpoints/register",
        "/v2/endpoints/token-refresh",
    ):
        assert path in caddy
    phone_matcher = caddy.split("@phone_push {", 1)[1].split("route {", 1)[0]
    assert "/v2/bindings" not in phone_matcher
    assert "/v2/send" not in phone_matcher
    assert "reverse_proxy @phone_push push-gateway:8081" in caddy


def test_hub_only_compose_is_push_free_and_keeps_private_services_private() -> None:
    server_dir = Path(__file__).resolve().parents[2]
    compose_path = server_dir / "compose.hub-only.yml"
    raw_compose = compose_path.read_text()
    compose = yaml.safe_load(raw_compose)
    services = compose["services"]

    assert set(services) == {
        "relay-hub-db",
        "relay-hub-migrate",
        "relay-hub",
        "caddy",
    }
    lowered = raw_compose.lower()
    assert "hpg_" not in lowered
    assert "push-gateway" not in lowered
    assert "apns" not in lowered
    assert "secrets" not in compose

    hub_proxy = services["relay-hub"]["environment"]["FORWARDED_ALLOW_IPS"]
    assert hub_proxy == services["caddy"]["networks"]["hub-ingress"]["ipv4_address"]
    assert hub_proxy == "172.31.250.2"
    assert "ports" not in services["relay-hub"]
    assert "ports" not in services["relay-hub-db"]
    assert compose["networks"]["hub-db"]["internal"] is True
    assert compose["networks"]["hub-ingress"]["ipam"]["config"][0]["subnet"] == "172.31.250.0/24"

    for service_name in ("relay-hub-migrate", "relay-hub", "caddy"):
        service = services[service_name]
        assert service["read_only"] is True
        assert service["cap_drop"] == ["ALL"]
        assert service["security_opt"] == ["no-new-privileges:true"]

    caddy_path = server_dir / "relay-hub" / "deploy" / "Caddyfile.hub-only"
    caddy = caddy_path.read_text()
    lowered_caddy = caddy.lower()
    assert caddy.count("reverse_proxy relay-hub:8080") == 1
    assert caddy.count("header_up X-Forwarded-For {remote_host}") == 1
    assert "push-gateway" not in lowered_caddy
    assert "apns" not in lowered_caddy
    for path in (
        "/v2/attest/challenge",
        "/v2/hub-activations",
        "/v2/endpoints/register",
        "/v2/endpoints/token-refresh",
        "/v2/bindings",
        "/v2/send",
    ):
        assert path not in caddy
