"""Composition root for the authenticated transparent relay."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional

from .downstream import DownstreamConfig, DownstreamServer
from .gateway_client import GatewayConfig
from .notifications import StockEventNotifications


@dataclass
class RelayConfig:
    gateway: GatewayConfig
    downstream: DownstreamConfig


class RelayApp:
    def __init__(self, config: RelayConfig) -> None:
        self._cfg = config
        self.downstream = DownstreamServer(config.downstream, config.gateway)
        self.notifications = StockEventNotifications(config.gateway)
        self.downstream.extend_status(self.notifications.status)

    async def run(self) -> None:
        import asyncio

        await asyncio.gather(
            self.downstream.serve(),
            self.notifications.run(),
        )

    def status(self) -> dict:
        return self.downstream.status()

    async def close(self) -> None:
        await self.notifications.close()
        await self.downstream.close()


def build_default_config(
    *,
    gateway_token: str,
    gateway_host: str = "127.0.0.1",
    gateway_port: int = 9126,
    downstream_host: str = "127.0.0.1",
    downstream_port: int = 8765,
    health_path: Optional[str] = "/healthz",
) -> RelayConfig:
    return RelayConfig(
        gateway=GatewayConfig(host=gateway_host, token=gateway_token, port=gateway_port),
        downstream=DownstreamConfig(
            host=downstream_host,
            port=downstream_port,
            health_path=health_path,
            auth_token=gateway_token,
        ),
    )
