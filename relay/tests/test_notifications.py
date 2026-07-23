import asyncio
import json

from aiohttp import web

from hermes_relay import plugin_bridge
from hermes_relay.app import RelayApp, RelayConfig
from hermes_relay.downstream import DownstreamConfig
from hermes_relay.gateway_client import GatewayConfig
from hermes_relay.notifications import StockEventNotifications


async def test_stock_completion_uses_stored_identity_and_active_device_gate(
    monkeypatch,
):
    calls = []

    class PushEngine:
        @staticmethod
        def _process_push_event(event, sid, payload, **kwargs):
            calls.append((event, sid, payload, kwargs))

    monkeypatch.setattr(plugin_bridge, "import_push_engine", lambda: PushEngine)
    observer = StockEventNotifications(GatewayConfig(token="secret"))
    observer._foreground_devices = {"stored-1": {"phone-1"}}
    observer.claimed = True
    worker = asyncio.create_task(observer._deliver(PushEngine))
    observer._observe_wire(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "method": "event",
                "params": {
                    "type": "message.complete",
                    "session_id": "runtime-1",
                    "stored_session_id": "stored-1",
                    "payload": {"text": "done", "event_id": "evt-1"},
                },
            }
        )
    )
    await asyncio.wait_for(observer._queue.join(), timeout=1)
    worker.cancel()
    await asyncio.gather(worker, return_exceptions=True)

    event, sid, payload, kwargs = calls[0]
    assert (event, sid) == ("message.complete", "stored-1")
    assert payload["stored_session_id"] == "stored-1"
    assert kwargs["excluded_devices_override"] == {"phone-1"}


def test_unclaimed_observer_never_competes_with_plugin_fallback():
    observer = StockEventNotifications(GatewayConfig(token="secret"))
    observer._observe_wire(
        json.dumps(
            {
                "jsonrpc": "2.0",
                "method": "event",
                "params": {
                    "type": "message.complete",
                    "session_id": "runtime-1",
                    "payload": {"text": "done"},
                },
            }
        )
    )

    assert observer.events_seen == 1
    assert observer._queue.empty()


async def test_missing_apns_engine_leaves_gateway_fallback_owner(monkeypatch):
    def unavailable():
        raise ImportError("adapter unavailable")

    monkeypatch.setattr(plugin_bridge, "import_push_engine", unavailable)
    observer = StockEventNotifications(GatewayConfig(token="secret"))

    await observer.run()

    assert observer.connected is False
    assert observer.claimed is False


async def test_relay_becomes_ready_then_delivers_one_stock_event(monkeypatch):
    delivered = []
    observer_connected = asyncio.Event()
    sockets = []

    class PushEngine:
        @staticmethod
        def _process_push_event(event, sid, payload, **kwargs):
            delivered.append((event, sid, payload, kwargs))

    monkeypatch.setattr(plugin_bridge, "import_push_engine", lambda: PushEngine)

    async def gateway_ws(request):
        socket = web.WebSocketResponse()
        await socket.prepare(request)
        sockets.append(socket)
        observer_connected.set()
        async for _message in socket:
            pass
        return socket

    async def claim(_request):
        return web.json_response(
            {
                "owner": "relay",
                "ttl_seconds": 15,
                "foreground_devices": {"stored-1": ["phone-1"]},
            }
        )

    gateway_app = web.Application()
    gateway_app.router.add_get("/api/ws", gateway_ws)
    gateway_app.router.add_post(
        "/api/plugins/hermes-mobile/notifications/claim",
        claim,
    )
    gateway_runner = web.AppRunner(gateway_app)
    await gateway_runner.setup()
    gateway_site = web.TCPSite(gateway_runner, "127.0.0.1", 0)
    await gateway_site.start()
    gateway_port = gateway_site._server.sockets[0].getsockname()[1]

    app = RelayApp(
        RelayConfig(
            gateway=GatewayConfig(port=gateway_port, token="host-secret"),
            downstream=DownstreamConfig(port=0, auth_token="phone-secret"),
        )
    )
    task = asyncio.create_task(app.run())
    try:
        await asyncio.wait_for(observer_connected.wait(), timeout=1)
        for _ in range(100):
            if app.notifications.claimed:
                break
            await asyncio.sleep(0.01)
        assert app.status()["notifications"]["claimed"] is True

        await sockets[0].send_json(
            {
                "jsonrpc": "2.0",
                "method": "event",
                "params": {
                    "type": "message.complete",
                    "session_id": "runtime-1",
                    "stored_session_id": "stored-1",
                    "payload": {"text": "done", "event_id": "evt-1"},
                },
            }
        )
        for _ in range(100):
            if delivered:
                break
            await asyncio.sleep(0.01)

        assert len(delivered) == 1
        event, sid, _payload, kwargs = delivered[0]
        assert (event, sid) == ("message.complete", "stored-1")
        assert kwargs["excluded_devices_override"] == {"phone-1"}
    finally:
        await app.close()
        await task
        await gateway_runner.cleanup()
