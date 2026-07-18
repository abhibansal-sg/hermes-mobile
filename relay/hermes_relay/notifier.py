"""Lane 4 — Notifier: owned-session APNs pushes via existing plumbing.

Observes the relay's frame stream (``TOPIC_RELAY_FRAMES``) and, for sessions the
:class:`~hermes_relay.gateway_client.GatewayClient` OWNS, fires an APNs push on
the three push-worthy signals (protocol §6):

* ``item.completed`` of an ``agentMessage`` -> ``turn_complete`` push
* ``approval.request``                      -> ``approval`` push
* ``error`` item / frame                    -> error push

It fires by REUSING the existing ``plugins/hermes-mobile/push_engine.notify()``
plumbing (device-token registry + direct HTTP/2 APNs or relay-mode delivery) —
NO gateway code, NO new push path. The gate (protocol §6): SKIP the push when a
live phone WS currently holds that session foregrounded, i.e.
``DownstreamServer.session_has_live_phone(sid)`` is True — the user is already
watching, so a notification would be noise.

Scope: OWNED sessions only. Foreign-session notifications are PARKED (they need
the broadcast/co-watch track; the relay as a pure client never receives a
foreign session's live stream).

INTERFACE THE LANE IMPLEMENTS: :meth:`run` (the observer pump) + :meth:`observe`
(the per-frame decision, unit-testable without a socket). Push delivery is
delegated to the injected ``push_engine`` module (via plugin_bridge), so tests
inject a fake.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Optional

from .bus import EventBus
from .gateway_client import GatewayClient
from .types import Frame


@dataclass
class NotifierConfig:
    """Notifier tuning. ``enabled`` lets the lane be dark in dev/tests."""

    enabled: bool = True
    # Map relay signal -> push_engine event_type / category. Defaults match the
    # existing push_engine PUSH_EVENT_KINDS + iOS action categories.
    turn_complete_event: str = "turn_complete"
    approval_event: str = "approval"
    error_event: str = "error"


class Notifier:
    """Fires owned-session APNs pushes, gated on live-phone foreground."""

    def __init__(
        self,
        config: NotifierConfig,
        bus: EventBus,
        gateway: GatewayClient,
        *,
        is_foregrounded: Callable[[str], bool],
        push_engine: Any = None,
    ) -> None:
        self._cfg = config
        self._bus = bus
        self._gateway = gateway
        # Injected DownstreamServer.session_has_live_phone (the §6 gate).
        self._is_foregrounded = is_foregrounded
        # Injected push_engine module (plugin_bridge.import_push_engine()); a
        # fake is injected in tests. Resolved lazily in run() if None.
        self._push = push_engine

    async def run(self) -> None:
        """Pump: subscribe ``TOPIC_RELAY_FRAMES`` and call :meth:`observe`.

        Lazily resolves the reused ``push_engine`` module (via plugin_bridge)
        when not injected. Runs until cancelled.
        """
        raise NotImplementedError

    def observe(self, frame: Frame) -> Optional[dict[str, Any]]:
        """Decide whether ``frame`` warrants a push; fire it if so.

        Returns the push descriptor that was sent (event_type/title/body/sid) or
        ``None`` when no push was warranted (not owned, gated by foreground, or
        not a push-worthy signal). Pure-decision + delegated send, so a unit test
        asserts on the return value with a fake push_engine.
        """
        raise NotImplementedError

    def _should_push(self, frame: Frame) -> Optional[str]:
        """Return the push event_type for a push-worthy frame, else ``None``.

        Push-worthy: agentMessage ``item.completed``, ``approval.request``, or an
        ``error``. Returns ``None`` unless the frame's session is OWNED and NOT
        currently foregrounded on a live phone (the protocol §6 gate).
        """
        raise NotImplementedError

    def _fire(self, event_type: str, frame: Frame) -> dict[str, Any]:
        """Build the alert text and call ``push_engine.notify(...)``.

        Reuses the existing signature:
        ``notify(event_type, title, body, payload=..., category=...)``. No new
        APNs code — this is the whole point of the reuse.
        """
        raise NotImplementedError
