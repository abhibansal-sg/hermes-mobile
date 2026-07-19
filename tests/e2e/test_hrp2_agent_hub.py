"""End-to-end proof for the HRP/2 Agent Relay and opaque Relay Hub.

This test deliberately crosses the real HTTP and WebSocket boundaries.  It is
skipped in the lightweight core test environment when the optional relay/Hub
dependencies are absent, and is run explicitly by the HRP/2 verification job.
"""

from __future__ import annotations

import asyncio
import socket
import sys
import time
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

import pytest


pytest.importorskip("fastapi")
pytest.importorskip("httpx")
pytest.importorskip("pyhpke")
pytest.importorskip("sqlalchemy")
uvicorn = pytest.importorskip("uvicorn")

_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_ROOT / "relay"))
sys.path.insert(0, str(_ROOT / "server" / "relay-hub"))

from hermes_relay.v2.crypto import (  # noqa: E402
    generate_ed25519_key_pair,
    generate_x25519_key_pair,
    open_authenticated_envelope,
    open_authenticated_message,
    seal_authenticated_envelope,
    seal_base_message,
)
from hermes_relay.v2.device_router import DeviceRouter  # noqa: E402
from hermes_relay.v2.enrollment import AgentEnrollmentManager  # noqa: E402
from hermes_relay.v2.hub_client import (  # noqa: E402
    Ed25519RequestAuthenticator,
    HubClient,
    HubConfig,
)
from hermes_relay.v2.identity import load_or_create_identity  # noqa: E402
from hermes_relay.v2.inbound import InboundProcessor  # noqa: E402
from hermes_relay.v2.pairing import (  # noqa: E402
    PAIR_ACCEPT_INFO,
    PAIR_INIT_INFO,
    PairInit,
    PairingManager,
)
from hermes_relay.v2.protection import FilePermissionFallbackProtector  # noqa: E402
from hermes_relay.v2.protocol import (  # noqa: E402
    HPKEDirection,
    HPKEPurpose,
    OuterHeader,
    ReceiveContext,
    SecureMessage,
    SecureMessageKind,
    TransportClass,
    b64url_decode,
    b64url_encode,
    canonical_json,
    decode_strict_json,
)
from hermes_relay.v2.storage import RelayStorage  # noqa: E402
from relay_hub.app import create_app  # noqa: E402
from relay_hub.settings import Settings  # noqa: E402
from relay_hub.storage import DatabaseStore  # noqa: E402


async def _wait_for_server(server) -> None:
    for _ in range(200):
        if server.started:
            return
        await asyncio.sleep(0.01)
    raise AssertionError("Relay Hub did not start")


async def _next_envelope(client: HubClient):
    stream = client.receive()
    try:
        return await asyncio.wait_for(anext(stream), timeout=5)
    finally:
        await stream.aclose()


@pytest.mark.asyncio
async def test_real_agent_hub_pairing_activation_and_encrypted_delivery(
    tmp_path: Path,
) -> None:
    settings = Settings(
        database_url=f"sqlite:///{tmp_path / 'hub.sqlite3'}",
        operator_enrollment_token="operator-test-token",
    )
    hub_store = DatabaseStore(settings)
    app = create_app(settings=settings, store=hub_store)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(128)
    port = listener.getsockname()[1]
    server = uvicorn.Server(
        uvicorn.Config(app, host="127.0.0.1", port=port, log_level="error")
    )
    server_task = asyncio.create_task(server.serve(sockets=[listener]))
    await _wait_for_server(server)

    relay_store = RelayStorage(
        tmp_path / "agent",
        credential_protector=FilePermissionFallbackProtector(),
    )
    identity = load_or_create_identity(relay_store)
    base_url = f"http://127.0.0.1:{port}"
    bootstrap = HubClient(
        HubConfig(
            base_url=base_url,
            route_id="pending",
            allow_insecure_local=True,
        )
    )
    agent_hub: HubClient | None = None
    phone_hub: HubClient | None = None
    router: DeviceRouter | None = None
    try:
        enrollment = await AgentEnrollmentManager(
            relay_store, identity, bootstrap
        ).ensure_provisional()
        assert enrollment.route_id is not None
        agent_route = enrollment.route_id
        await bootstrap.close()

        agent_hub = HubClient(
            HubConfig(
                base_url=base_url,
                route_id=agent_route,
                allow_insecure_local=True,
            ),
            authenticator=Ed25519RequestAuthenticator(
                agent_route, identity.sign_private
            ),
        )
        activated = await agent_hub.activate_agent_route(
            operator_enrollment_token="operator-test-token"
        )
        assert activated == {
            "route_id": agent_route,
            "status": "active",
            "already_active": False,
        }
        relay_store.mark_agent_route_active(agent_route)

        pairing = PairingManager(
            relay_store,
            identity,
            hub_url=base_url,
            relay_route=agent_route,
            hub_client=agent_hub,
        )
        qr = await pairing.create_registered_offer()
        offer = relay_store.get_pair_offer(qr["offer_id"])
        assert offer is not None

        device_kem = generate_x25519_key_pair()
        device_sign = generate_ed25519_key_pair()
        preview_kem = generate_x25519_key_pair()
        unsigned_init = PairInit(
            offer_id=offer.offer_id,
            device_name="Integration iPhone",
            device_kem_public=device_kem.public_key,
            device_sign_public=device_sign.public_key,
            preview_kem_public=preview_kem.public_key,
            device_nonce=b"integration-phone",
            push_bind_token=None,
            hub_activation_token=None,
            pair_mac=bytes(32),
        )
        pair_init = replace(
            unsigned_init,
            pair_mac=pairing.pair_mac(
                offer.pair_secret, unsigned_init.transcript_dict()
            ),
        )
        pair_init_enc, pair_init_ct = seal_base_message(
            canonical_json(pair_init.to_dict()),
            recipient_public_key=identity.kem_public,
            info=PAIR_INIT_INFO,
            aad=pairing.offer_aad(offer),
        )
        submitted = await agent_hub.submit_pair_init(
            offer_route=offer.offer_route,
            transport_token=offer.transport_token,
            offer_id=offer.offer_id,
            enc=pair_init_enc,
            ciphertext=pair_init_ct,
        )
        assert submitted["accepted"] is True

        claim = await pairing.claim_ready_offer(offer.offer_id)
        assert claim is not None
        accepted = await pairing.accept_claim(claim)
        assert accepted["resumed"] is False

        pair_accept = await agent_hub.get_pair_accept(
            offer_route=offer.offer_route,
            transport_token=offer.transport_token,
            offer_id=offer.offer_id,
        )
        pair_accept_plaintext = open_authenticated_message(
            b64url_decode(pair_accept["enc"], field="enc", exact_bytes=32),
            b64url_decode(pair_accept["ct"], field="ct", min_bytes=16),
            recipient_private_key=device_kem.private_key,
            sender_public_key=identity.kem_public,
            info=PAIR_ACCEPT_INFO,
            aad=pairing.pair_accept_aad(
                offer_id=offer.offer_id,
                device_route=accepted["device_route"],
                message_hash=relay_store.get_pair_offer(offer.offer_id).hub_message_hash,
            ),
        )
        pair_accept_message = SecureMessage.from_dict(
            decode_strict_json(pair_accept_plaintext)
        )
        assert pair_accept_message.kind == SecureMessageKind.PAIR_ACCEPT
        assert pair_accept_message.body["device_id"] == accepted["device_id"]

        confirm_mid = b64url_encode(b"pair-confirm-e2e")
        expires_at_ms = min(
            offer.expires_at_ms,
            time.time_ns() // 1_000_000 + 60_000,
        )
        confirm_header = OuterHeader(
            src=accepted["device_route"],
            dst=agent_route,
            mid=confirm_mid,
            message_class=TransportClass.CONTROL,
            expires_at_ms=expires_at_ms,
            recipient_key_generation=identity.kem_generation,
        )
        confirm_message = SecureMessage(
            mid=confirm_mid,
            kind=SecureMessageKind.PAIR_CONFIRM,
            sender_key_generation=1,
            created_at_ms=time.time_ns() // 1_000_000,
            expires_at_ms=expires_at_ms,
            body={
                "offer_id": offer.offer_id,
                "device_id": accepted["device_id"],
                "response_hash": accepted["response_hash"],
                "pair_accept_mid": accepted["pair_accept_mid"],
            },
        )
        confirm_envelope = seal_authenticated_envelope(
            confirm_header,
            confirm_message,
            recipient_public_key=identity.kem_public,
            sender_private_key=device_kem.private_key,
            signing_private_key=device_sign.private_key,
            purpose=HPKEPurpose.CONTROL,
            direction=HPKEDirection.DEVICE_TO_AGENT,
        )
        assert (await agent_hub.send_envelope(confirm_envelope))["accepted"] is True
        received_confirm = await _next_envelope(agent_hub)

        dispatcher = SimpleNamespace(router=SimpleNamespace())
        inbound = InboundProcessor(
            relay_store,
            agent_hub,
            dispatcher,
            relay_route=agent_route,
            pairing=pairing,
        )
        assert await inbound.process(received_confirm) is True
        device = relay_store.get_device(accepted["device_id"])
        assert device is not None and device.status == "active"
        assert relay_store.get_pair_offer(offer.offer_id).state == "consumed"
        assert hub_store.get_route(device.route).status == "active"

        phone_hub = HubClient(
            HubConfig(
                base_url=base_url,
                route_id=device.route,
                allow_insecure_local=True,
            ),
            authenticator=Ed25519RequestAuthenticator(
                device.route, device_sign.private_key
            ),
        )
        router = DeviceRouter(
            relay_store,
            identity,
            agent_hub,
            relay_route=agent_route,
            retry_initial_s=0.01,
            retry_max_s=0.05,
            retry_jitter=lambda delay: delay,
        )
        response_mid = router.send_secure_message(
            device.device_id,
            SecureMessageKind.RPC_RESPONSE,
            {"jsonrpc": "2.0", "id": "e2e", "result": {"paired": True}},
        )
        delivered = await _next_envelope(phone_hub)
        assert delivered.mid == response_mid
        opened = open_authenticated_envelope(
            delivered,
            recipient_private_keys={1: device_kem.private_key},
            sender_public_keys={identity.kem_generation: identity.kem_public},
            signing_public_key=identity.sign_public,
            purpose=HPKEPurpose.CONTROL,
            direction=HPKEDirection.AGENT_TO_DEVICE,
            receive=ReceiveContext(
                expected_destination=device.route,
                expected_source=agent_route,
                now_ms=time.time_ns() // 1_000_000,
                seen_message_ids=set(),
            ),
        )
        assert opened.kind == SecureMessageKind.RPC_RESPONSE
        assert opened.body["result"] == {"paired": True}
        assert (await phone_hub.acknowledge([delivered.mid]))["acknowledged"] == 1
    finally:
        if router is not None:
            await router.close()
        if phone_hub is not None:
            await phone_hub.close()
        if agent_hub is not None:
            await agent_hub.close()
        await bootstrap.close()
        relay_store.close()
        server.should_exit = True
        await asyncio.wait_for(server_task, timeout=5)
        listener.close()
