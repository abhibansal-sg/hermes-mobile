from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import secrets
import threading
from concurrent.futures import ThreadPoolExecutor

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from relay_hub.app import (
    SocketCapacityExhausted,
    SocketManager,
    create_app,
    enrollment_source_hash,
)
from relay_hub.crypto import (
    AuthorizationError,
    b64url_encode,
    grant_signature_input,
    now_milliseconds,
    verify_activation_token_keyring,
)
from relay_hub.database_work import DatabaseBusy, DatabaseWorkPool
from relay_hub.models import GrantRequest
from relay_hub.settings import Settings
from relay_hub.storage import (
    DatabaseStore,
    EnrollmentRateLimited,
    ProvisionalCapacityExhausted,
)


def _provisional_body(*, enrollment_id: str | None = None) -> dict[str, str]:
    key = Ed25519PrivateKey.generate()
    return {
        "enrollment_id": enrollment_id
        or "enr_" + b64url_encode(secrets.token_bytes(16)),
        "route_type": "agent",
        "auth_public_key": b64url_encode(key.public_key().public_bytes_raw()),
    }


def _activation_token(
    key: Ed25519PrivateKey,
    *,
    route_id: str,
    key_id: str | None,
) -> str:
    payload = {
        "route_id": route_id,
        "expires_at_ms": now_milliseconds() + 60_000,
        "token_id": "act_" + b64url_encode(secrets.token_bytes(16)),
    }
    if key_id is not None:
        payload["kid"] = key_id
    raw = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    signature = key.sign(b"HRH2ACT" + len(raw).to_bytes(4, "big") + raw)
    return f"{b64url_encode(raw)}.{b64url_encode(signature)}"


def test_database_work_pool_offloads_bounds_and_retains_cancelled_permit() -> None:
    async def scenario() -> None:
        pool = DatabaseWorkPool(
            max_concurrency=1,
            acquire_timeout_seconds=0.02,
        )
        started = threading.Event()
        release = threading.Event()
        loop_thread = threading.get_ident()

        def blocked() -> int:
            assert threading.get_ident() != loop_thread
            started.set()
            assert release.wait(timeout=2)
            return 7

        task = asyncio.create_task(pool.run(blocked))
        try:
            for _ in range(100):
                if started.is_set():
                    break
                await asyncio.sleep(0.001)
            assert started.is_set()
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            # Cancellation of the request must not release capacity while its
            # synchronous transaction is still running in the worker.
            with pytest.raises(DatabaseBusy):
                await pool.run(lambda: None)
            release.set()
            for _ in range(100):
                try:
                    assert await pool.run(lambda: 9) == 9
                    break
                except DatabaseBusy:
                    await asyncio.sleep(0.001)
            else:
                pytest.fail("database worker permit was not released on completion")
        finally:
            release.set()
            await pool.shutdown()

    asyncio.run(scenario())


def test_http_database_backpressure_returns_deterministic_503() -> None:
    settings = Settings(
        database_url="sqlite:///:memory:",
        operator_enrollment_token="operator-test-token",
        database_max_concurrency=1,
        database_acquire_timeout_seconds=0.02,
    )
    store = DatabaseStore(settings)
    original = store.create_provisional
    started = threading.Event()
    release = threading.Event()
    first_call = True

    def blocked_create(**kwargs):
        nonlocal first_call
        if first_call:
            first_call = False
            started.set()
            assert release.wait(timeout=2)
        return original(**kwargs)

    store.create_provisional = blocked_create  # type: ignore[method-assign]
    with TestClient(create_app(settings=settings, store=store)) as client:
        with ThreadPoolExecutor(max_workers=1) as requests:
            first = requests.submit(
                client.post,
                "/v2/enroll/provisional",
                json=_provisional_body(),
            )
            assert started.wait(timeout=1)
            overloaded = client.post(
                "/v2/enroll/provisional",
                json=_provisional_body(),
            )
            assert overloaded.status_code == 503
            assert overloaded.json() == {
                "error": {"code": "database_busy", "message": "database busy"}
            }
            assert overloaded.headers["retry-after"] == "1"
            release.set()
            assert first.result(timeout=2).status_code == 201


def test_enrollment_rate_is_shared_and_exact_retry_bypasses_limit(tmp_path) -> None:
    settings = Settings(
        database_url=f"sqlite:///{tmp_path / 'shared-rate.sqlite3'}",
        operator_enrollment_token="shared-authority",
        provisional_per_source_per_hour=1,
    )
    first_store = DatabaseStore(settings)
    second_store = DatabaseStore(settings)
    app_one = create_app(settings=settings, store=first_store)
    app_two = create_app(settings=settings, store=second_store)
    body = _provisional_body()

    with TestClient(app_one) as first_client, TestClient(app_two) as second_client:
        created = first_client.post("/v2/enroll/provisional", json=body)
        assert created.status_code == 201
        retry = second_client.post("/v2/enroll/provisional", json=body)
        assert retry.status_code == 200
        assert retry.json() == created.json()
        limited = second_client.post(
            "/v2/enroll/provisional",
            json=_provisional_body(),
        )
        assert limited.status_code == 429
        assert limited.json()["error"]["code"] == "provisional_enrollment_rate_limited"


def test_enrollment_source_capacity_and_global_quota_fail_closed() -> None:
    settings = Settings(
        database_url="sqlite:///:memory:",
        maximum_provisional_rate_limit_sources=1,
        maximum_live_provisional_routes=1,
        provisional_per_source_per_hour=10,
    )
    store = DatabaseStore(settings)
    now_ms = now_milliseconds()

    first = store.create_provisional(
        enrollment_id="enr_" + b64url_encode(secrets.token_bytes(16)),
        route_id="rte_" + b64url_encode(secrets.token_bytes(24)),
        public_key=secrets.token_bytes(32),
        route_type="agent",
        source_hash=hashlib.sha256(b"source-one").digest(),
        now_ms=now_ms,
        expires_at_ms=now_ms + 600_000,
    )
    assert first.created is True
    with pytest.raises(EnrollmentRateLimited):
        store.create_provisional(
            enrollment_id="enr_" + b64url_encode(secrets.token_bytes(16)),
            route_id="rte_" + b64url_encode(secrets.token_bytes(24)),
            public_key=secrets.token_bytes(32),
            route_type="agent",
            source_hash=hashlib.sha256(b"source-two").digest(),
            now_ms=now_ms,
            expires_at_ms=now_ms + 600_000,
        )
    # The already-tracked source reaches the independently enforced global
    # route cap, and the failed capacity probe still consumes its rate event.
    with pytest.raises(ProvisionalCapacityExhausted):
        store.create_provisional(
            enrollment_id="enr_" + b64url_encode(secrets.token_bytes(16)),
            route_id="rte_" + b64url_encode(secrets.token_bytes(24)),
            public_key=secrets.token_bytes(32),
            route_type="agent",
            source_hash=hashlib.sha256(b"source-one").digest(),
            now_ms=now_ms,
            expires_at_ms=now_ms + 600_000,
        )


def test_ipv6_enrollment_sources_are_aggregated_by_prefix() -> None:
    key = secrets.token_bytes(32)
    assert enrollment_source_hash("2001:db8:1234:5678::1", key=key) == (
        enrollment_source_hash("2001:db8:1234:5678:ffff::2", key=key)
    )
    assert enrollment_source_hash("2001:db8:1234:5678::1", key=key) != (
        enrollment_source_hash("2001:db8:1234:5679::1", key=key)
    )
    assert enrollment_source_hash(None, key=key) is None


def test_socket_byte_budget_settings_are_bounded_and_environment_configurable(
    monkeypatch,
) -> None:
    defaults = Settings()
    assert defaults.effective_socket_queue_max_bytes == defaults.mailbox_bytes
    defaults.validate()

    with pytest.raises(ValueError, match="per-socket queue bytes"):
        Settings(socket_queue_max_bytes=defaults.mailbox_bytes + 1).validate()
    with pytest.raises(ValueError, match="total socket queue bytes"):
        Settings(socket_queue_total_max_bytes=1024).validate()

    monkeypatch.setenv("HRH_PRODUCTION", "false")
    monkeypatch.setenv("HRH_DATABASE_URL", "sqlite:///:memory:")
    monkeypatch.setenv("HRH_SOCKET_QUEUE_MAX_BYTES", "4096")
    monkeypatch.setenv("HRH_SOCKET_QUEUE_TOTAL_MAX_BYTES", "131072")
    configured = Settings.from_env()
    assert configured.effective_socket_queue_max_bytes == 4096
    assert configured.socket_queue_total_max_bytes == 131072


def test_socket_manager_enforces_per_route_and_global_caps() -> None:
    async def scenario() -> None:
        manager = SocketManager(
            queue_depth=1,
            maximum_queue_bytes=1024 * 1024,
            maximum_total_queue_bytes=4 * 1024 * 1024,
            maximum_connections=2,
            maximum_connections_per_route=1,
        )
        first = await manager.add("rte_one")
        with pytest.raises(SocketCapacityExhausted, match="route"):
            await manager.add("rte_one")
        second = await manager.add("rte_two")
        with pytest.raises(SocketCapacityExhausted, match="global"):
            await manager.add("rte_three")
        await manager.remove("rte_one", first)
        third = await manager.add("rte_three")
        await manager.remove("rte_two", second)
        await manager.remove("rte_three", third)

    asyncio.run(scenario())


def test_socket_queue_large_frame_byte_limit_overflows_and_recovers() -> None:
    async def scenario() -> None:
        large = {
            "type": "message",
            "envelope": {"class": "realtime", "ct": "A" * 300_000},
        }
        overflow = {"type": "overflow", "code": "reconnect_required"}
        large_bytes = len(
            json.dumps(large, separators=(",", ":"), ensure_ascii=False).encode(
                "utf-8"
            )
        )
        overflow_bytes = len(
            json.dumps(overflow, separators=(",", ":"), ensure_ascii=False).encode(
                "utf-8"
            )
        )
        manager = SocketManager(
            queue_depth=10,
            maximum_queue_bytes=large_bytes + overflow_bytes,
            maximum_total_queue_bytes=2 * large_bytes,
            maximum_connections=1,
            maximum_connections_per_route=1,
        )
        queue = await manager.add("rte_large")
        assert await manager.publish_frame("rte_large", large, durable=False) == 1
        assert await manager.queued_bytes(queue) == large_bytes
        assert await manager.queued_bytes() == large_bytes

        # The record queue still has room, but the second frame exceeds the
        # byte budget. Even realtime overflow forces reconnect rather than
        # retaining an attacker-controlled large object.
        assert await manager.publish_frame("rte_large", large, durable=False) == 0
        assert await manager.queued_bytes(queue) == overflow_bytes
        assert await queue.get() == overflow
        assert await manager.queued_bytes() == 0

        await manager.remove("rte_large", queue)
        replacement = await manager.add("rte_large")
        assert await manager.publish_frame("rte_large", large) == 1
        assert await manager.queued_bytes() == large_bytes
        # Disconnect cleanup releases queued data and the control reserve.
        await manager.remove("rte_large", replacement)
        assert await manager.queued_bytes() == 0
        final = await manager.add("rte_large")
        waiting = asyncio.create_task(final.get())
        await asyncio.sleep(0)
        await manager.remove("rte_large", final)
        with pytest.raises(RuntimeError, match="no longer registered"):
            await waiting

    asyncio.run(scenario())


def test_socket_queue_process_byte_limit_is_atomic_across_connections() -> None:
    async def scenario() -> None:
        large = {
            "type": "message",
            "envelope": {"class": "state", "ct": "B" * 300_000},
        }
        overflow = {"type": "overflow", "code": "reconnect_required"}
        large_bytes = len(
            json.dumps(large, separators=(",", ":"), ensure_ascii=False).encode(
                "utf-8"
            )
        )
        overflow_bytes = len(
            json.dumps(overflow, separators=(",", ":"), ensure_ascii=False).encode(
                "utf-8"
            )
        )
        manager = SocketManager(
            queue_depth=10,
            maximum_queue_bytes=2 * large_bytes,
            maximum_total_queue_bytes=large_bytes + 2 * overflow_bytes,
            maximum_connections=2,
            maximum_connections_per_route=2,
        )
        first = await manager.add("rte_shared")
        second = await manager.add("rte_shared")

        # One lock covers global reservation for every recipient. Exactly one
        # queue receives the data; the other consumes its reserved overflow
        # signal without exceeding the configured process budget.
        assert await manager.publish_frame("rte_shared", large) == 1
        assert await manager.queued_bytes() == large_bytes + overflow_bytes
        frames = [await first.get(), await second.get()]
        assert sorted(frame["type"] for frame in frames) == ["message", "overflow"]
        assert await manager.queued_bytes() == 0

        await manager.remove("rte_shared", first)
        await manager.remove("rte_shared", second)
        replacement = await manager.add("rte_shared")
        assert await manager.publish_frame("rte_shared", large) == 1
        await manager.remove("rte_shared", replacement)
        assert await manager.queued_bytes() == 0

    asyncio.run(scenario())


def test_websocket_route_capacity_closes_with_retryable_1013() -> None:
    from conftest import HubHarness

    settings = Settings(
        database_url="sqlite:///:memory:",
        operator_enrollment_token="operator-test-token",
        maximum_socket_connections=2,
        maximum_socket_connections_per_route=1,
    )
    store = DatabaseStore(settings)
    with TestClient(create_app(settings=settings, store=store)) as client:
        harness = HubHarness(client, store, settings)
        route_id, route_key = harness.enroll("agent")
        first_headers = harness.signed_headers(
            route_id,
            route_key,
            method="GET",
            path="/v2/socket",
        )
        second_headers = harness.signed_headers(
            route_id,
            route_key,
            method="GET",
            path="/v2/socket",
        )
        with client.websocket_connect("/v2/socket", headers=first_headers):
            with client.websocket_connect(
                "/v2/socket", headers=second_headers
            ) as second:
                with pytest.raises(WebSocketDisconnect) as closed:
                    second.receive_json()
                assert closed.value.code == 1013


def test_activation_keyring_accepts_overlap_and_never_falls_back_unknown_kid() -> None:
    old = Ed25519PrivateKey.generate()
    current = Ed25519PrivateKey.generate()
    route_id = "rte_rotation"
    keys = {
        "old": old.public_key().public_bytes_raw(),
        "current": current.public_key().public_bytes_raw(),
    }

    legacy_token = _activation_token(old, route_id=route_id, key_id=None)
    assert (
        verify_activation_token_keyring(
            legacy_token,
            keys,
            expected_route=route_id,
            now_ms=now_milliseconds(),
        ).key_id
        is None
    )
    current_token = _activation_token(
        current,
        route_id=route_id,
        key_id="current",
    )
    assert (
        verify_activation_token_keyring(
            current_token,
            keys,
            expected_route=route_id,
            now_ms=now_milliseconds(),
        ).key_id
        == "current"
    )
    unknown = _activation_token(current, route_id=route_id, key_id="unknown")
    with pytest.raises(AuthorizationError):
        verify_activation_token_keyring(
            unknown,
            keys,
            expected_route=route_id,
            now_ms=now_milliseconds(),
        )


def test_activation_keyring_config_and_hub_endpoint_support_rotation(
    monkeypatch,
) -> None:
    old = Ed25519PrivateKey.generate()
    current = Ed25519PrivateKey.generate()
    encoded = {
        "old~2026": base64.b64encode(old.public_key().public_bytes_raw()).decode(
            "ascii"
        ),
        "current": base64.b64encode(current.public_key().public_bytes_raw()).decode(
            "ascii"
        ),
    }
    monkeypatch.setenv("HRH_PRODUCTION", "false")
    monkeypatch.setenv("HRH_AUTO_CREATE_SCHEMA", "true")
    monkeypatch.setenv("HRH_DATABASE_URL", "sqlite:///:memory:")
    monkeypatch.setenv("HRH_ACTIVATION_PUBLIC_KEYS_JSON", json.dumps(encoded))
    monkeypatch.delenv("HRH_ACTIVATION_PUBLIC_KEYS_FILE", raising=False)
    monkeypatch.delenv("HRH_ACTIVATION_PUBLIC_KEY_B64", raising=False)
    monkeypatch.delenv("HRH_OPERATOR_ENROLLMENT_TOKEN", raising=False)
    monkeypatch.delenv("HRH_DEVELOPMENT_ACTIVATION_TOKEN", raising=False)
    settings = Settings.from_env()
    assert dict(settings.activation_verification_keys) == {
        "old~2026": old.public_key().public_bytes_raw(),
        "current": current.public_key().public_bytes_raw(),
    }

    store = DatabaseStore(settings)
    with TestClient(create_app(settings=settings, store=store)) as client:
        enrolled = client.post(
            "/v2/enroll/provisional",
            json=_provisional_body(),
        )
        assert enrolled.status_code == 201
        route_id = enrolled.json()["route_id"]
        activated = client.post(
            "/v2/enroll/activate",
            json={
                "route_id": route_id,
                "activation_token": _activation_token(
                    old,
                    route_id=route_id,
                    key_id="old~2026",
                ),
            },
        )
        assert activated.status_code == 200
        assert activated.json()["status"] == "active"


def test_cross_owner_and_agent_to_agent_grants_are_rejected(harness) -> None:
    owner, owner_key = harness.enroll("agent")
    other_agent, _other_key = harness.enroll("agent")
    other_device, _device_key = harness.enroll(
        "device",
        owner_route=other_agent,
    )

    def submit(destination: str):
        unsigned = GrantRequest(
            grant_id="grt_" + b64url_encode(secrets.token_bytes(24)),
            issuer_route=owner,
            source_route=owner,
            destination_route=destination,
            permissions=["send"],
            issuer_signature=b64url_encode(bytes(64)),
        )
        grant = unsigned.model_copy(
            update={
                "issuer_signature": b64url_encode(
                    owner_key.sign(grant_signature_input(unsigned))
                )
            }
        )
        return harness.signed_request(
            "POST",
            "/v2/grants",
            owner,
            owner_key,
            grant.model_dump(),
        )

    for destination in (other_device, other_agent):
        rejected = submit(destination)
        assert rejected.status_code == 403
        assert rejected.json()["error"]["code"] == "grant_requires_owned_device"
