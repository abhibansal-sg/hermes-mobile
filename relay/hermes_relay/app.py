"""Composition root — wires the four lanes onto one bus + shared state.

This is the ONLY place the lanes are connected; each lane depends on the shared
:mod:`hermes_relay.bus` and :mod:`hermes_relay.types` and never on a sibling
lane's internals. The dataflow the wiring establishes:

    GatewayClient --(GatewayEvent)--> TOPIC_GATEWAY_EVENTS
                                            |
                                         Reframer --(Frame, seq=None)--> TOPIC_RELAY_FRAMES
                                            |                                 |
                                     SessionStore.apply                 DownstreamServer (stamp seq
                                     (snapshot truth)                    + ring + send to phone)
                                            |                                 |
                                            +------------- Notifier (owned + not-foregrounded -> APNs)

Run order: build shared singletons (bus, SessionStore), construct each lane with
its config, then run all four coroutines under one asyncio supervisor. The
GatewayClient's durable reconnect loop and the DownstreamServer's accept loop are
the two long-lived tasks; the Reframer and Notifier are pumps over the bus.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Optional

from .bus import TOPIC_GATEWAY_EVENTS, TOPIC_RELAY_FRAMES, EventBus
from .downstream import DownstreamConfig, DownstreamServer
from .durable_state import DurableState
from .gateway_client import GatewayClient, GatewayConfig
from .notifier import Notifier, NotifierConfig
from .reframer import Reframer
from .session_state import SessionStore

_log = logging.getLogger("hermes_relay.app")


@dataclass
class RelayConfig:
    """Top-level relay configuration aggregating each lane's config."""

    gateway: GatewayConfig
    downstream: DownstreamConfig
    notifier: NotifierConfig


class RelayApp:
    """Owns the shared singletons and the four lanes; runs the supervisor."""

    def __init__(self, config: RelayConfig) -> None:
        self._cfg = config
        self.bus = EventBus()
        self.store = SessionStore()
        self.durable = DurableState()
        self._tasks: dict[str, asyncio.Task] = {}
        self._closing = False

        self.gateway = GatewayClient(config.gateway, self.bus)
        self.reframer = Reframer(self.bus, self.store)
        self.downstream = DownstreamServer(
            config.downstream, self.bus, self.gateway, self.store, self.durable
        )
        self.notifier = Notifier(
            config.notifier,
            self.bus,
            self.gateway,
            is_foregrounded=self.downstream.session_has_live_phone,
            durable=self.durable,
        )

    async def run(self) -> None:
        """Start all four lanes under one supervisor; run until stopped.

        Supervises: ``gateway.run()`` (durable reconnect), ``downstream.serve()``
        (phone accept + frame fan-out), ``reframer.run()`` (event pump),
        ``notifier.run()`` (push observer). A failure in any long-lived task
        should tear the group down for a clean restart.
        """
        self._closing = False
        # Build the reused replay ring before any frame can be fanned out.
        await self.downstream.start()

        # Start the three bus consumers FIRST. Subscriptions only receive
        # messages published after subscribe() (see bus.py), so the reframer,
        # notifier and downstream must be on their topics before the gateway
        # begins publishing — otherwise the opening events of a live session
        # would be dropped on the floor.
        self._tasks = {
            "reframer": asyncio.create_task(self.reframer.run(), name="relay.reframer"),
            "notifier": asyncio.create_task(self.notifier.run(), name="relay.notifier"),
            "downstream": asyncio.create_task(
                self.downstream.serve(), name="relay.downstream"
            ),
        }

        # Deterministic startup barrier: yield until the consumers have actually
        # registered their subscriptions (reframer -> gateway.events;
        # downstream + notifier -> relay.frames). Bounded so a consumer that
        # dies before subscribing can never spin us forever.
        for _ in range(10_000):
            if (
                self.bus.subscriber_count(TOPIC_GATEWAY_EVENTS) >= 1
                and self.bus.subscriber_count(TOPIC_RELAY_FRAMES) >= 2
            ):
                break
            if any(t.done() for t in self._tasks.values()):
                break  # a consumer failed during startup; fall through to reap
            await asyncio.sleep(0)

        # Only now attach the upstream producer.
        self._tasks["gateway"] = asyncio.create_task(
            self.gateway.run(), name="relay.gateway"
        )

        # Supervise: the first task to exit (cleanly or by raising) tears the
        # whole group down so the outer process can restart from a clean slate.
        try:
            done, _pending = await asyncio.wait(
                self._tasks.values(), return_when=asyncio.FIRST_COMPLETED
            )
        finally:
            await self.close()

        # Surface the first real failure so the supervisor above sees it.
        for task in done:
            if task.cancelled():
                continue
            exc = task.exception()
            if exc is not None:
                raise exc

    def status(self) -> dict:
        """A JSON-serialisable snapshot of the whole relay (health surface)."""
        from . import __version__

        return {
            "service": "hermes_relay",
            "version": __version__,
            "gateway": {
                "url": self._cfg.gateway.ws_url("REDACTED"),
                "owned_sessions": sorted(self.gateway.owned_sessions),
            },
            "downstream": self.downstream.status(),
            "closing": self._closing,
        }

    async def close(self) -> None:
        """Idempotent teardown: stop the long-lived lanes, cancel the pumps."""
        if self._closing and not self._tasks:
            return
        self._closing = True

        # Stop the producer and the phone-facing server via their own graceful
        # paths (unblocks gateway.run() and downstream.serve()).
        for name, closer in (
            ("gateway", self.gateway.close),
            ("downstream", self.downstream.close),
        ):
            try:
                await closer()
            except Exception:  # pragma: no cover - defensive teardown
                _log.debug("error closing %s", name, exc_info=True)

        # Cancel every supervised task (the reframer/notifier pumps park on
        # bus.get() forever, so they need an explicit cancel).
        for task in self._tasks.values():
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        self._tasks = {}


def build_default_config(
    *,
    gateway_token: str,
    gateway_host: str = "127.0.0.1",
    gateway_port: int = 9133,
    downstream_host: str = "127.0.0.1",
    downstream_port: int = 8765,
    health_path: Optional[str] = "/healthz",
) -> RelayConfig:
    """Convenience defaults for a local isolated run; deployment can override."""
    return RelayConfig(
        gateway=GatewayConfig(host=gateway_host, token=gateway_token, port=gateway_port),
        downstream=DownstreamConfig(
            host=downstream_host,
            port=downstream_port,
            health_path=health_path,
            auth_token=gateway_token,
        ),
        notifier=NotifierConfig(),
    )
