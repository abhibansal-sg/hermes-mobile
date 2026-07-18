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

from dataclasses import dataclass
from typing import Optional

from .bus import EventBus
from .downstream import DownstreamConfig, DownstreamServer
from .gateway_client import GatewayClient, GatewayConfig
from .notifier import Notifier, NotifierConfig
from .reframer import Reframer
from .session_state import SessionStore


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

        self.gateway = GatewayClient(config.gateway, self.bus)
        self.reframer = Reframer(self.bus, self.store)
        self.downstream = DownstreamServer(
            config.downstream, self.bus, self.gateway, self.store
        )
        self.notifier = Notifier(
            config.notifier,
            self.bus,
            self.gateway,
            is_foregrounded=self.downstream.session_has_live_phone,
        )

    async def run(self) -> None:
        """Start all four lanes under one supervisor; run until stopped.

        Supervises: ``gateway.run()`` (durable reconnect), ``downstream.serve()``
        (phone accept + frame fan-out), ``reframer.run()`` (event pump),
        ``notifier.run()`` (push observer). A failure in any long-lived task
        should tear the group down for a clean restart.
        """
        raise NotImplementedError

    async def close(self) -> None:
        raise NotImplementedError


def build_default_config(
    *, gateway_token: str, gateway_port: int = 9126, downstream_port: int = 8765
) -> RelayConfig:
    """Convenience default config for local/isolated runs (NEVER port 9119)."""
    return RelayConfig(
        gateway=GatewayConfig(token=gateway_token, port=gateway_port),
        downstream=DownstreamConfig(port=downstream_port),
        notifier=NotifierConfig(),
    )
