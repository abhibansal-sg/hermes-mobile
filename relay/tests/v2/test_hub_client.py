from __future__ import annotations

import json
from pathlib import Path

import pytest

from hermes_relay.v2.errors import (
    Conflict,
    Expired,
    MailboxFull,
    NotFound,
    RateLimited,
    Revoked,
    Unauthenticated,
)
from hermes_relay.v2.hub_client import HubClient, HubConfig, HubUnavailable
from hermes_relay.v2.protocol import OuterEnvelope


ROOT = Path(__file__).resolve().parents[3]
ENVELOPE = OuterEnvelope.from_dict(
    json.loads((ROOT / "protocol/hrp2/fixtures/auth-envelope.json").read_text())[
        "outer_envelope"
    ]
)


class Response:
    def __init__(self, status_code: int, payload=None) -> None:
        self.status_code = status_code
        self._payload = payload
        self.content = b"" if payload is None else json.dumps(payload).encode()

    def json(self):
        if self._payload is None:
            raise ValueError
        return self._payload


class HTTP:
    def __init__(self, responses) -> None:
        self.responses = list(responses)
        self.requests = []

    async def request(self, method, url, **kwargs):
        self.requests.append((method, url, kwargs))
        return self.responses.pop(0)


def auth(_method, _path, _body):
    return {"X-Hermes-Route": "rte_agent", "X-Hermes-Signature": "test"}


class ProbeSocket:
    def __init__(self, frames) -> None:
        self.frames = list(frames)
        self.sent = []
        self.closed = False

    async def send(self, value):
        self.sent.append(value)

    async def recv(self):
        return self.frames.pop(0)

    async def close(self):
        self.closed = True


async def test_hub_acceptance_is_strict_and_mid_bound() -> None:
    good = {
        "accepted": True,
        "deduplicated": False,
        "stored": True,
        "mid": ENVELOPE.mid,
    }
    for bad in (
        {},
        {**good, "mid": "wrong"},
        {**good, "accepted": False},
        {**good, "deduplicated": 0},
        {**good, "stored": "yes"},
    ):
        client = HubClient(
            HubConfig("https://relay.example", "rte_agent"),
            authenticator=auth,
            http_client=HTTP([Response(200, bad)]),
        )
        with pytest.raises(HubUnavailable):
            await client.send_envelope(ENVELOPE)
    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"),
        authenticator=auth,
        http_client=HTTP([Response(202, good)]),
    )
    assert (await client.send_envelope(ENVELOPE))["mid"] == ENVELOPE.mid


@pytest.mark.parametrize(
    ("status", "code", "error_type"),
    [
        (401, "UNAUTHENTICATED", Unauthenticated),
        (410, "REVOKED", Revoked),
        (400, "EXPIRED", Expired),
        (404, "NOT_FOUND", NotFound),
        (409, "CONFLICT", Conflict),
        (429, "MAILBOX_FULL", MailboxFull),
        (429, "RATE_LIMITED", RateLimited),
    ],
)
async def test_nested_fastapi_error_contract_maps_to_typed_error(
    status, code, error_type
) -> None:
    response = Response(status, {"detail": {"error": {"code": code}}})
    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"),
        authenticator=auth,
        http_client=HTTP([response]),
    )
    with pytest.raises(error_type):
        await client.acknowledge([ENVELOPE.mid])


async def test_signed_surfaces_fail_locally_without_authenticator() -> None:
    http = HTTP([Response(200, {"acknowledged": 1})])
    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"), http_client=http
    )
    with pytest.raises(Unauthenticated):
        await client.acknowledge([ENVELOPE.mid])
    assert http.requests == []


async def test_receive_readiness_probe_uses_authenticated_ping_pong() -> None:
    socket = ProbeSocket(
        [
            json.dumps({"type": "message", "envelope": ENVELOPE.to_dict()}),
            json.dumps({"type": "pong"}),
        ]
    )
    connected = []

    async def connect(url, **kwargs):
        connected.append((url, kwargs))
        return socket

    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"),
        authenticator=auth,
        websocket_connector=connect,
    )
    await client.probe_receive_ready()
    assert socket.sent == ['{"type":"ping"}']
    assert socket.closed is True
    assert connected[0][0] == "wss://relay.example/v2/socket"
    headers = connected[0][1].get("additional_headers") or connected[0][1].get(
        "extra_headers"
    )
    assert headers["X-Hermes-Route"] == "rte_agent"


@pytest.mark.parametrize("state", ["provisional", "active"])
async def test_route_proof_is_signed_and_bound_to_configured_route(state) -> None:
    http = HTTP(
        [Response(200, {"route_id": "rte_agent", "status": state})]
    )
    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"),
        authenticator=auth,
        http_client=http,
    )
    assert await client.prove_route() == {
        "route_id": "rte_agent",
        "status": state,
    }
    method, url, request = http.requests[0]
    assert (method, url) == (
        "GET",
        "https://relay.example/v2/route-proof",
    )
    assert request["headers"]["X-Hermes-Route"] == "rte_agent"


def test_remote_plaintext_hub_is_rejected_and_loopback_requires_opt_in() -> None:
    with pytest.raises(ValueError):
        HubConfig("http://relay.example", "rte_agent")
    with pytest.raises(ValueError):
        HubConfig("http://127.0.0.1:9999", "rte_agent")
    assert HubConfig(
        "http://127.0.0.1:9999", "rte_agent", allow_insecure_local=True
    ).base_url.startswith("http://")


@pytest.mark.parametrize(
    "url",
    [
        "https://user:secret@relay.example",
        "https://relay.example/v2",
        "https://relay.example?token=secret",
        "https://relay.example#secret",
    ],
)
def test_hub_origin_rejects_persistable_credentials_and_non_origins(url: str) -> None:
    with pytest.raises(ValueError):
        HubConfig(url, "rte_agent")


def test_hub_origin_is_canonicalized() -> None:
    assert HubConfig("HTTPS://Relay.Example:443/", "rte_agent").base_url == (
        "https://relay.example"
    )


async def test_pair_offer_registration_sends_hash_not_raw_token() -> None:
    token = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE"
    expected = {
        "offer_id": "ofr_1",
        "offer_route": "off_1",
        "expires_at_ms": 123,
    }
    http = HTTP([Response(201, expected)])
    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"),
        authenticator=auth,
        http_client=http,
    )
    assert (
        await client.register_pair_offer(
            offer_id="ofr_1",
            offer_route="off_1",
            transport_token=token,
            owner_route="rte_agent",
            expires_at_ms=123,
        )
        == expected
    )
    body = http.requests[0][2]["content"].decode()
    assert token not in body
    assert "transport_token_hash" in body


async def test_provisional_enrollment_and_waiting_pair_accept_are_exact() -> None:
    enrollment = {
        "enrollment_id": "enr_exact_retry_123",
        "route_id": "rte_provisional",
        "status": "provisional",
        "expires_at_ms": 50_000,
    }
    waiting = {"status": "waiting", "offer_id": "ofr_waiting"}
    http = HTTP([Response(201, enrollment), Response(200, waiting)])
    client = HubClient(
        HubConfig("https://relay.example", "rte_bootstrap"),
        authenticator=auth,
        http_client=http,
    )
    assert (
        await client.enroll_provisional_agent(
            enrollment_id="enr_exact_retry_123", auth_public_key=b"a" * 32
        )
        == enrollment
    )
    enrollment_body = json.loads(http.requests[0][2]["content"])
    assert set(enrollment_body) == {
        "enrollment_id",
        "route_type",
        "auth_public_key",
    }
    assert enrollment_body["route_type"] == "agent"
    assert (
        await client.get_pair_accept(
            offer_route="off_waiting",
            transport_token="AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE",
            offer_id="ofr_waiting",
        )
        == waiting
    )


async def test_owner_route_revocation_response_is_strict_and_sorted() -> None:
    good = {
        "route_id": "rte_phone",
        "status": "revoked",
        "grant_ids": ["grt_a", "grt_b"],
        "already_revoked": False,
    }
    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"),
        authenticator=auth,
        http_client=HTTP([Response(200, good)]),
    )
    assert await client.delete_route("rte_phone") == good

    bad = {**good, "grant_ids": ["grt_b", "grt_a"]}
    client = HubClient(
        HubConfig("https://relay.example", "rte_agent"),
        authenticator=auth,
        http_client=HTTP([Response(200, bad)]),
    )
    with pytest.raises(HubUnavailable):
        await client.delete_route("rte_phone")
