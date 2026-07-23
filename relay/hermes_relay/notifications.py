"""Stock gateway event observation and APNs delivery.

The phone proxy remains byte-transparent. This separate observer consumes the
same stock event frames as Desktop through the existing gateway fan-out hook,
then reuses the existing APNs implementation.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import Any

from . import plugin_bridge
from .gateway_client import GatewayConfig

_log = logging.getLogger(__name__)
_CLAIM_PATH = "/api/plugins/hermes-mobile/notifications/claim"
_CLAIM_TTL_SECONDS = 15.0
_CLAIM_INTERVAL_SECONDS = 5.0
_ALERT_EVENTS = frozenset(
    {
        "approval.request",
        "clarify.request",
        "message.complete",
        "error",
        "background.complete",
    }
)
_STATE_EVENTS = frozenset(
    {
        "message.start",
        "tool.start",
        "tool.complete",
        "status.update",
        *_ALERT_EVENTS,
    }
)


class StockEventNotifications:
    """Observe gateway-wide stock events and deliver notification-worthy ones."""

    def __init__(
        self,
        gateway: GatewayConfig,
    ) -> None:
        self._gateway = gateway
        self._stop = asyncio.Event()
        self._queue: asyncio.Queue[tuple[str, str, dict[str, Any]]] = asyncio.Queue(
            maxsize=256
        )
        self._session_state: dict[str, dict[str, Any]] = {}
        self._foreground_devices: dict[str, set[str]] = {}
        self._claim_until = 0.0
        self._socket: Any = None
        self.connected = False
        self.claimed = False
        self.events_seen = 0

    async def run(self) -> None:
        """Reconnect forever; notification failures never affect proxy traffic."""
        import aiohttp

        self._stop.clear()
        try:
            push_engine = plugin_bridge.import_push_engine()
        except Exception:
            _log.error(
                "APNs engine unavailable; gateway fallback retains ownership",
                exc_info=True,
            )
            return
        worker = asyncio.create_task(self._deliver(push_engine))
        try:
            connector = aiohttp.TCPConnector(force_close=True)
            async with aiohttp.ClientSession(connector=connector) as client:
                while not self._stop.is_set():
                    try:
                        await self._observe_once(client)
                    except asyncio.CancelledError:
                        raise
                    except Exception:
                        _log.warning(
                            "stock event observer disconnected; retrying",
                            exc_info=True,
                        )
                    self.connected = False
                    self.claimed = False
                    if not self._stop.is_set():
                        try:
                            await asyncio.wait_for(self._stop.wait(), timeout=1.0)
                        except TimeoutError:
                            pass
        finally:
            worker.cancel()
            await asyncio.gather(worker, return_exceptions=True)

    async def _observe_once(self, client: Any) -> None:
        import aiohttp

        async with client.ws_connect(self._gateway.ws_url()) as socket:
            self._socket = socket
            self.connected = True
            claim = asyncio.create_task(self._claim_loop(client))
            try:
                async for message in socket:
                    if message.type == aiohttp.WSMsgType.TEXT:
                        self._observe_wire(message.data)
                    elif message.type in {
                        aiohttp.WSMsgType.CLOSE,
                        aiohttp.WSMsgType.CLOSED,
                        aiohttp.WSMsgType.ERROR,
                    }:
                        break
            finally:
                self._socket = None
                claim.cancel()
                await asyncio.gather(claim, return_exceptions=True)

    async def _claim_loop(self, client: Any) -> None:
        while not self._stop.is_set():
            try:
                async with client.post(
                    f"{self._gateway.http_base}{_CLAIM_PATH}",
                    headers=self._gateway.rest_headers(),
                    json={"ttl_seconds": _CLAIM_TTL_SECONDS},
                ) as response:
                    if response.status == 200:
                        body = await response.json()
                        foreground = body.get("foreground_devices")
                        if isinstance(foreground, dict):
                            self._foreground_devices = {
                                str(session_id): {
                                    str(device_id)
                                    for device_id in device_ids
                                    if isinstance(device_id, str)
                                }
                                for session_id, device_ids in foreground.items()
                                if isinstance(device_ids, list)
                            }
                        self._claim_until = (
                            time.monotonic() + _CLAIM_TTL_SECONDS
                        )
                        self.claimed = True
                    else:
                        self.claimed = False
                        _log.warning(
                            "relay notification claim rejected: HTTP %s",
                            response.status,
                        )
            except Exception:
                self.claimed = time.monotonic() < self._claim_until
                _log.warning("relay notification claim failed", exc_info=True)
            try:
                await asyncio.wait_for(
                    self._stop.wait(), timeout=_CLAIM_INTERVAL_SECONDS
                )
            except TimeoutError:
                pass

    def _observe_wire(self, wire: str) -> None:
        try:
            frame = json.loads(wire)
        except (TypeError, ValueError):
            return
        if frame.get("method") != "event":
            return
        params = frame.get("params")
        if not isinstance(params, dict):
            return
        event = params.get("type")
        runtime_id = params.get("session_id")
        if not isinstance(event, str) or not isinstance(runtime_id, str):
            return
        self.events_seen += 1
        if event not in _STATE_EVENTS or not self.claimed:
            return
        payload = params.get("payload")
        data = dict(payload) if isinstance(payload, dict) else {}
        stored_id = str(params.get("stored_session_id") or runtime_id)
        data.setdefault("stored_session_id", stored_id)
        try:
            self._queue.put_nowait((event, stored_id, data))
        except asyncio.QueueFull:
            _log.warning("relay notification queue full; dropping %s", event)

    async def _deliver(self, push_engine: Any) -> None:
        while True:
            event, stored_id, payload = await self._queue.get()
            try:
                state = self._session_state.setdefault(stored_id, {})
                now = time.time()
                if event == "message.start":
                    state["_push_turn_started"] = now
                started = state.get("_push_turn_started")
                excluded = (
                    self._foreground_devices.get(stored_id, set())
                    if event in {"message.complete", "error"}
                    else set()
                )
                await asyncio.to_thread(
                    push_engine._process_push_event,
                    event,
                    stored_id,
                    payload,
                    event_time=now,
                    turn_started=started,
                    session_override=state,
                    excluded_devices_override=excluded,
                )
                if event in {"message.complete", "error"}:
                    self._session_state.pop(stored_id, None)
            except Exception:
                _log.warning(
                    "relay notification delivery failed event=%s session=%s",
                    event,
                    stored_id,
                    exc_info=True,
                )
            finally:
                self._queue.task_done()

    async def close(self) -> None:
        self._stop.set()
        if self._socket is not None:
            await self._socket.close()

    def status(self) -> dict[str, Any]:
        return {
            "connected": self.connected,
            "claimed": self.claimed,
            "events_seen": self.events_seen,
            "tracked_sessions": len(self._session_state),
        }
