"""Authenticated, byte-transparent phone proxy for the stock Hermes gateway."""

from __future__ import annotations

import asyncio
import hmac
import json
import logging
from dataclasses import dataclass
from typing import Any, Callable, Optional

from . import plugin_bridge
from .gateway_client import GatewayConfig

_log = logging.getLogger(__name__)

_HOP_BY_HOP_HEADERS = frozenset(
    {
        "connection",
        "keep-alive",
        "proxy-authenticate",
        "proxy-authorization",
        "te",
        "trailer",
        "transfer-encoding",
        "upgrade",
    }
)


@dataclass
class DownstreamConfig:
    """Phone-facing bind, health route, and authentication credential."""

    host: str = "127.0.0.1"
    port: int = 8765
    max_message_bytes: int = 8 * 1024 * 1024
    health_path: Optional[str] = "/healthz"
    auth_token: str = ""


class DownstreamServer:
    """Authenticate locally and forward stock WS/HTTP traffic unchanged."""

    def __init__(self, config: DownstreamConfig, upstream: GatewayConfig) -> None:
        self._cfg = config
        self._upstream = upstream
        self._server = None
        self._runner = None
        self._proxy_client = None
        self._stop = asyncio.Event()
        self._status_extension: Optional[Callable[[], dict[str, Any]]] = None

    async def serve(self) -> None:
        from aiohttp import ClientSession, web

        self._stop.clear()
        self._proxy_client = ClientSession(auto_decompress=False)
        try:
            app = web.Application(client_max_size=self._cfg.max_message_bytes)
            app.router.add_route("*", "/{path:.*}", self._serve_request)
            self._runner = web.AppRunner(app, access_log=None)
            await self._runner.setup()
            site = web.TCPSite(
                self._runner, self._cfg.host, self._cfg.port
            )
            await site.start()
            self._server = site._server
            await self._stop.wait()
        finally:
            await self.close()

    async def _serve_request(self, request: Any) -> Any:
        from aiohttp import web

        upstream_token = self._authorized_upstream_token(
            request.raw_path, request
        )
        if self._cfg.auth_token and upstream_token is None:
            return web.Response(status=401, text="Unauthorized\n")
        if self._cfg.health_path and request.path == self._cfg.health_path:
            return web.json_response(self.status())
        if request.path == "/api/ws":
            return await self._serve_stock_ws(request, upstream_token)
        return await self._proxy_stock_http(request, upstream_token)

    async def _serve_stock_ws(
        self,
        request: Any,
        upstream_token: Optional[str],
    ) -> Any:
        """Copy stock WebSocket messages in both directions without decoding."""
        from aiohttp import WSMsgType, web

        if self._proxy_client is None:
            return web.Response(status=503, text="Upstream unavailable\n")

        phone = web.WebSocketResponse(max_msg_size=self._cfg.max_message_bytes)
        await phone.prepare(request)
        try:
            gateway = await self._proxy_client.ws_connect(
                self._upstream.ws_url(upstream_token or self._upstream.token),
                max_msg_size=self._cfg.max_message_bytes,
            )
        except Exception:
            await phone.close(code=1011, message=b"upstream unavailable")
            return phone

        async def copy(source: Any, target: Any) -> None:
            async for message in source:
                if message.type == WSMsgType.TEXT:
                    await target.send_str(message.data)
                elif message.type == WSMsgType.BINARY:
                    await target.send_bytes(message.data)
                elif message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR):
                    break

        tasks = {
            asyncio.create_task(copy(phone, gateway)),
            asyncio.create_task(copy(gateway, phone)),
        }
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await gateway.close()
            await phone.close()
        return phone

    async def _proxy_stock_http(
        self, request: Any, upstream_token: Optional[str]
    ) -> Any:
        """Forward one HTTP request and response body without interpreting it."""
        from aiohttp import web

        if self._proxy_client is None:
            return web.Response(status=503, text="Upstream unavailable\n")
        request_headers = {
            name: value
            for name, value in request.headers.items()
            if name.lower() not in _HOP_BY_HOP_HEADERS
            and name.lower() not in {"host", "authorization", "x-hermes-session-token"}
        }
        request_headers.update(
            self._upstream.rest_headers(upstream_token or self._upstream.token)
        )
        async with self._proxy_client.request(
            request.method,
            f"{self._upstream.http_base}{request.raw_path}",
            headers=request_headers,
            data=(await request.read()) or None,
            allow_redirects=False,
        ) as upstream:
            response_headers = [
                (name.decode("latin-1"), value.decode("latin-1"))
                for name, value in upstream.raw_headers
                if name.decode("latin-1").lower() not in _HOP_BY_HOP_HEADERS
            ]
            response = web.StreamResponse(
                status=upstream.status,
                reason=upstream.reason,
                headers=response_headers,
            )
            await response.prepare(request)
            async for chunk in upstream.content.iter_chunked(64 * 1024):
                await response.write(chunk)
            await response.write_eof()
            return response

    def _authorized_upstream_token(
        self, raw_path: str, request: Any
    ) -> Optional[str]:
        """Authenticate locally and select the matching upstream credential."""
        from urllib.parse import parse_qs, urlsplit

        headers = getattr(request, "headers", {}) or {}
        parsed = urlsplit(raw_path)
        supplied = [
            headers.get("Authorization", "").removeprefix("Bearer "),
            headers.get("X-Hermes-Session-Token", ""),
            parse_qs(parsed.query).get("token", [""])[0]
            if parsed.path == "/api/ws"
            else "",
        ]
        if any(
            value and hmac.compare_digest(value, self._cfg.auth_token)
            for value in supplied
        ):
            return self._upstream.token
        try:
            device_tokens = plugin_bridge.import_device_tokens()
            for value in supplied:
                if value and device_tokens.match(value) is not None:
                    return value
        except Exception:
            _log.debug("device-token proxy auth unavailable", exc_info=True)
        return None

    def status(self) -> dict[str, Any]:
        from . import __version__

        status: dict[str, Any] = {
            "service": "hermes_relay",
            "version": __version__,
            "mode": "transparent_proxy",
            "connections": 0,
        }
        if self._status_extension is not None:
            status["notifications"] = self._status_extension()
        return status

    def extend_status(self, provider: Callable[[], dict[str, Any]]) -> None:
        self._status_extension = provider

    async def close(self) -> None:
        self._stop.set()
        if self._runner is not None:
            runner, self._runner = self._runner, None
            await runner.cleanup()
        self._server = None
        if self._proxy_client is not None:
            client, self._proxy_client = self._proxy_client, None
            await client.close()
