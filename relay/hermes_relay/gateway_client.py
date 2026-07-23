"""Address helpers for the relay's stock gateway upstream."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class GatewayConfig:
    host: str = "127.0.0.1"
    port: int = 9126
    token: str = ""

    def ws_url(self, token: Optional[str] = None) -> str:
        credential = token if token is not None else self.token
        return f"ws://{self.host}:{self.port}/api/ws?token={credential}"

    @property
    def http_base(self) -> str:
        return f"http://{self.host}:{self.port}"

    def rest_headers(self, token: Optional[str] = None) -> dict[str, str]:
        credential = token if token is not None else self.token
        return {"X-Hermes-Session-Token": credential}
