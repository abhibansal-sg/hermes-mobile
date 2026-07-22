"""The stock relay lane authenticates and copies; it never interprets frames."""

from __future__ import annotations

import asyncio
from unittest.mock import MagicMock

import httpx
import pytest
import websockets
from aiohttp import web

from hermes_relay.bus import EventBus
from hermes_relay.downstream import DownstreamConfig, DownstreamServer
from hermes_relay.gateway_client import GatewayConfig
from hermes_relay.session_state import SessionStore


async def _bound_port(server) -> int:
    for _ in range(200):
        if server._server is not None:
            return server._server.sockets[0].getsockname()[1]
        await asyncio.sleep(0.01)
    raise AssertionError("server never bound")


@pytest.fixture
async def transparent_pair():
    observed: dict[str, object] = {}
    event_wire = '{"jsonrpc":"2.0", "method":"event", "params":{"type":"gateway.ready"}}'

    async def upstream_ws(request):
        socket = web.WebSocketResponse()
        await socket.prepare(request)
        observed["ws_token"] = request.query.get("token")
        await socket.send_str(event_wire)
        async for message in socket:
            observed["ws_in"] = message.data
            await socket.send_str(message.data)
        return socket

    async def upstream_http(request):
        observed["http_method"] = request.method
        observed["http_path"] = request.raw_path
        observed["http_token"] = request.headers.get("X-Hermes-Session-Token")
        observed["http_authorization"] = request.headers.get("Authorization")
        observed["http_body"] = await request.read()
        return web.Response(status=207, body=b"\x00stock-body", headers={"X-Stock": "yes"})

    upstream_app = web.Application()
    upstream_app.router.add_get("/api/ws", upstream_ws)
    upstream_app.router.add_route("*", "/{path:.*}", upstream_http)
    upstream_runner = web.AppRunner(upstream_app)
    await upstream_runner.setup()
    upstream_site = web.TCPSite(upstream_runner, "127.0.0.1", 0)
    await upstream_site.start()
    upstream_port = upstream_site._server.sockets[0].getsockname()[1]

    gateway = MagicMock()
    gateway.owned_sessions = frozenset()
    relay = DownstreamServer(
        DownstreamConfig(port=0, auth_token="phone-secret"),
        EventBus(),
        gateway,
        SessionStore(),
        upstream=GatewayConfig(port=upstream_port, token="gateway-secret"),
    )
    relay_task = asyncio.create_task(relay.serve())
    relay_port = await _bound_port(relay)
    try:
        yield relay_port, observed, event_wire
    finally:
        await relay.close()
        await relay_task
        await upstream_runner.cleanup()


async def test_stock_ws_frames_are_byte_identical(transparent_pair):
    port, observed, event_wire = transparent_pair
    request_wire = '{"jsonrpc": "2.0", "id": 7, "method": "session.active_list", "params": {}}'
    async with websockets.connect(
        f"ws://127.0.0.1:{port}/api/ws?token=phone-secret"
    ) as phone:
        assert await phone.recv() == event_wire
        await phone.send(request_wire)
        assert await phone.recv() == request_wire

    assert observed["ws_in"] == request_wire
    assert observed["ws_token"] == "gateway-secret"


async def test_stock_http_method_path_and_body_are_unchanged(transparent_pair):
    port, observed, _event_wire = transparent_pair
    async with httpx.AsyncClient() as client:
        response = await client.post(
            f"http://127.0.0.1:{port}/api/upload?kind=file",
            headers={
                "X-Hermes-Session-Token": "phone-secret",
                "Authorization": "Bearer phone-secret",
            },
            content=b"request-body",
        )

    assert response.status_code == 207
    assert response.content == b"\x00stock-body"
    assert response.headers["X-Stock"] == "yes"
    assert observed == {
        "http_method": "POST",
        "http_path": "/api/upload?kind=file",
        "http_token": "gateway-secret",
        "http_authorization": None,
        "http_body": b"request-body",
    }


async def test_stock_proxy_rejects_bad_phone_credentials(transparent_pair):
    port, _observed, _event_wire = transparent_pair
    async with httpx.AsyncClient() as client:
        response = await client.get(
            f"http://127.0.0.1:{port}/api/status",
            headers={"X-Hermes-Session-Token": "wrong"},
        )
    assert response.status_code == 401

    with pytest.raises(websockets.exceptions.InvalidStatus) as exc:
        async with websockets.connect(f"ws://127.0.0.1:{port}/api/ws?token=wrong"):
            pass
    assert exc.value.response.status_code == 401
