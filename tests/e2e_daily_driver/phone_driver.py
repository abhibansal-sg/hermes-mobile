"""Minimal stock JSON-RPC phone driver for the transparent-proxy gate."""

from __future__ import annotations

import asyncio
import json
import time
from typing import Any

import websockets


class PhoneDriver:
    """Record stock RPC responses and unchanged ``method:event`` frames."""

    def __init__(self, url: str) -> None:
        self._url = url
        self._ws: Any = None
        self._reader: asyncio.Task | None = None
        self._next_id = 0
        self._pending: dict[int, asyncio.Future[dict[str, Any]]] = {}
        self.sent: list[dict[str, Any]] = []
        self.events: list[dict[str, Any]] = []
        self.raw_received: list[str] = []
        self.legacy_frames_seen = 0

    async def connect(self) -> None:
        self._ws = await websockets.connect(self._url, max_size=8 * 1024 * 1024)
        self._reader = asyncio.create_task(self._read_loop())

    async def close(self) -> None:
        if self._reader is not None:
            self._reader.cancel()
        if self._ws is not None:
            await self._ws.close()
            self._ws = None

    async def _read_loop(self) -> None:
        try:
            async for raw in self._ws:
                message = json.loads(raw)
                self.raw_received.append(raw)
                if "id" in message:
                    pending = self._pending.pop(message["id"], None)
                    if pending is not None and not pending.done():
                        pending.set_result(message)
                elif message.get("method") == "event":
                    self.events.append(message)
                elif "kind" in message:
                    self.legacy_frames_seen += 1
        except asyncio.CancelledError:
            pass

    async def call(
        self, method: str, params: dict[str, Any], *, timeout: float = 30
    ) -> dict[str, Any]:
        self._next_id += 1
        request_id = self._next_id
        request = {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": method,
            "params": params,
        }
        response = asyncio.get_running_loop().create_future()
        self._pending[request_id] = response
        self.sent.append(request)
        await self._ws.send(json.dumps(request))
        return await asyncio.wait_for(response, timeout=timeout)

    async def wait_for_event(
        self, event_type: str, *, timeout: float = 30
    ) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for event in reversed(self.events):
                if (event.get("params") or {}).get("type") == event_type:
                    return event
            await asyncio.sleep(0.02)
        raise asyncio.TimeoutError(f"no stock event type={event_type}")
