"""Lane 1 — GatewayClient: the durable WS client to the stock gateway.

A single, persistent JSON-RPC-2.0 WebSocket connection to
``ws://<host>:<port>/api/ws?token=…`` (the stock gateway's sidecar) that
multiplexes ALL of the relay's sessions. It:

* authenticates via the ``?token=`` query param (loopback / co-located host);
* survives disconnects with reconnect + exponential backoff, re-minting the URL
  and re-establishing owned sessions (the desktop ``use-gateway-boot`` pattern);
* issues id-matched RPCs and awaits their results;
* demuxes inbound ``event`` frames by ``session_id`` and republishes each as a
  :class:`~hermes_relay.types.GatewayEvent` on ``TOPIC_GATEWAY_EVENTS``.

Session-op mapping it implements (protocol §5), with the R0 correction that
foreign/idle history is a REST store-read, NOT the ``session.history`` RPC:

* :meth:`session_list`      -> ``session.list``            (read, no ownership)
* :meth:`session_create`    -> ``session.create``          (own)
* :meth:`session_resume`    -> ``session.resume``          (own idle/foreign)
* :meth:`rest_history`      -> ``GET /api/sessions/{id}/messages`` (store-read)
* :meth:`prompt_submit`     -> ``prompt.submit``           (become owner + drive)
* :meth:`approval_respond`  -> ``approval.respond``
* :meth:`clarify_respond`   -> ``clarify.respond``
* :meth:`session_interrupt` -> ``session.interrupt``

This lane is proven by the R0 spike (``r0-relay-spike/relay_client.py``); this is
its productionized, multiplexing, reconnecting form. It publishes; it never
reframes (that is Lane 2).

INTERFACE THE LANE IMPLEMENTS: the public methods below. Everything else
(reader loop, backoff schedule, credential handling) is internal.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Optional

from .bus import EventBus


@dataclass
class GatewayConfig:
    """Connection parameters for the gateway WS + REST surface."""

    host: str = "127.0.0.1"
    port: int = 9126  # isolated test gateway range (NEVER 9119 live)
    token: str = ""
    max_message_bytes: int = 8 * 1024 * 1024
    connect_timeout_s: float = 10.0
    rpc_timeout_s: float = 30.0
    backoff_initial_s: float = 0.5
    backoff_max_s: float = 30.0

    @property
    def ws_url(self) -> str:
        return f"ws://{self.host}:{self.port}/api/ws?token={self.token}"

    @property
    def http_base(self) -> str:
        return f"http://{self.host}:{self.port}"

    @property
    def rest_headers(self) -> dict[str, str]:
        return {"X-Hermes-Session-Token": self.token}


class GatewayClient:
    """Durable multiplexing JSON-RPC client to one stock gateway."""

    def __init__(self, config: GatewayConfig, bus: EventBus) -> None:
        self._cfg = config
        self._bus = bus
        # Sessions this relay OWNS (created/resumed here) — re-established on
        # reconnect and observed by the Notifier for owned-session pushes.
        self._owned: set[str] = set()

    # -- lifecycle --------------------------------------------------------
    async def connect(self) -> None:
        """Open the WS, authenticate, await ``gateway.ready``, start the reader.

        Idempotent-ish: safe to call once at startup. Reconnection is handled
        internally by :meth:`run`; callers use :meth:`run` for the durable loop.
        """
        raise NotImplementedError

    async def run(self) -> None:
        """Durable connect/serve/reconnect loop with exponential backoff.

        On each drop: back off (capped), reconnect, re-mint the URL, re-resume
        owned sessions, and resume publishing events. Runs until :meth:`close`.
        """
        raise NotImplementedError

    async def close(self) -> None:
        """Tear down the reader task and close the socket."""
        raise NotImplementedError

    # -- RPC core ---------------------------------------------------------
    async def call(
        self, method: str, params: Optional[dict[str, Any]] = None, timeout: Optional[float] = None
    ) -> dict[str, Any]:
        """Issue an id-matched JSON-RPC call, return the raw response dict.

        Raises on timeout; the caller inspects ``result``/``error``. Used by the
        typed convenience methods below and directly for pass-through RPCs.
        """
        raise NotImplementedError

    # -- session ops (protocol §5) ---------------------------------------
    async def session_list(self, limit: int = 200) -> list[dict[str, Any]]:
        """``session.list`` — all sessions, every origin (no ownership)."""
        raise NotImplementedError

    async def session_create(
        self, *, title: str, model: Optional[str] = None, provider: Optional[str] = None, cols: int = 80
    ) -> str:
        """``session.create`` — new owned session; returns its session_id."""
        raise NotImplementedError

    async def session_resume(self, session_id: str, *, cols: int = 80) -> dict[str, Any]:
        """``session.resume`` — own an idle/foreign session (REACTIVATES it).

        Only call for a session the relay intends to OWN and drive; for a pure
        read use :meth:`rest_history` (store-read, no reactivation).
        """
        raise NotImplementedError

    async def rest_history(self, session_id: str) -> list[dict[str, Any]]:
        """``GET /api/sessions/{id}/messages`` — foreign/idle history store-read.

        R0 CORRECTION: this REST path (not the ``session.history`` RPC) is the
        true store-read; it does NOT reactivate the session. Uses httpx off the
        WS loop.
        """
        raise NotImplementedError

    async def prompt_submit(self, session_id: str, text: str) -> dict[str, Any]:
        """``prompt.submit`` — become owner of ``session_id`` and drive a turn.

        Marks the session owned so reconnect re-establishes it and the Notifier
        treats its completion/approval/error events as push-worthy.
        """
        raise NotImplementedError

    async def approval_respond(self, session_id: str, request_id: str, decision: str) -> dict[str, Any]:
        """``approval.respond`` — answer an approval gate (pass-through)."""
        raise NotImplementedError

    async def clarify_respond(self, session_id: str, request_id: str, text: str) -> dict[str, Any]:
        """``clarify.respond`` — answer a clarify gate (pass-through)."""
        raise NotImplementedError

    async def session_interrupt(self, session_id: str) -> dict[str, Any]:
        """``session.interrupt`` — stop the active turn (pass-through)."""
        raise NotImplementedError

    # -- ownership introspection -----------------------------------------
    def owns(self, session_id: str) -> bool:
        """True iff the relay owns (submitted/resumed-to-drive) this session."""
        return session_id in self._owned

    @property
    def owned_sessions(self) -> frozenset[str]:
        return frozenset(self._owned)
