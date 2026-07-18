"""Lane 3 — DownstreamServer + ReplayRing: the relay<->phone WS server.

This is the phone-facing side. It:

* accepts phone WS connections (and an HTTP fallback for cold reads, §1);
* subscribes ``TOPIC_RELAY_FRAMES``, stamps each :class:`Frame` with the next
  monotonic **per-connection** ``seq`` (protocol §4), appends it to the bounded
  :class:`ReplayRingManager` (reused verbatim from
  ``plugins/hermes-mobile/replay_ring.py``), and sends it to the phone;
* handles upstream JSON-RPC (protocol §1/§5) by translating to
  :class:`~hermes_relay.gateway_client.GatewayClient` calls;
* handles the reliability control frames locally: ``ack{through}`` drops acked
  frames from the ring; ``resync{last_seq}`` runs :meth:`ReplayRingManager.decide`
  and either replays ``[n+1..head]`` or sends a fresh ``snapshot`` (from
  :class:`SessionStore`) then resumes live.

Two seq facts from the protocol that shape this lane:
* ``seq`` is monotonic **per phone-connection**, NOT per session — so the ring
  key is the connection, and every session's frames share one seq spine.
* ``completed``-is-authoritative means a dropped delta is self-healing; the ring
  only needs to cover the reconnect window, and a ring miss falls back to a
  SessionStore snapshot the phone reconciles by ``item_id``.

INTERFACE THE LANE IMPLEMENTS: :meth:`serve` (accept loop), the per-connection
:class:`PhoneConnection` send/replay path, and :meth:`handle_upstream` (the §5
RPC translation). It OWNS the ring; the Reframer/GatewayClient never touch it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

from .bus import EventBus
from .gateway_client import GatewayClient
from .session_state import SessionStore
from .types import Frame, UpstreamRequest


@dataclass
class DownstreamConfig:
    """Phone-facing server bind + ring parameters."""

    host: str = "127.0.0.1"
    port: int = 8765
    # Ring caps are passed through to ReplayRingConfig; defaults there mirror
    # the resumable-stream spec (512 frames / 4 MiB / 128 MiB aggregate).
    ring_frames: Optional[int] = None
    ring_session_bytes: Optional[int] = None
    ring_total_bytes: Optional[int] = None
    ack_interval_hint_s: float = 5.0


class PhoneConnection:
    """One connected phone: the seq spine + replay ring for this socket.

    ``seq`` is per-connection, so each PhoneConnection owns its own head
    counter and a ring key. The ring itself is the reused ReplayRingManager
    (one manager may back many connections, keyed by connection id).
    """

    def __init__(self, conn_id: str, ws: Any, ring: Any) -> None:
        self.conn_id = conn_id
        self._ws = ws
        self._ring = ring  # plugins/hermes-mobile replay_ring.ReplayRingManager
        self._head_seq = 0
        # Sessions this phone currently holds foregrounded (gates Notifier §6).
        self.foreground_sessions: set[str] = set()

    def next_seq(self) -> int:
        """Allocate the next monotonic per-connection seq."""
        self._head_seq += 1
        return self._head_seq

    async def send_frame(self, frame: Frame) -> None:
        """Stamp seq, append to the ring, and write the frame to the socket."""
        raise NotImplementedError

    async def replay(self, last_seq: int, store: SessionStore) -> None:
        """Handle ``resync``: ring.decide(last_seq) -> replay or snapshot.

        REPLAY -> resend the ring's ``[last_seq+1 .. head]`` frames verbatim.
        FALLBACK -> build a per-session ``snapshot`` from ``store`` and send it,
        then resume live. CURRENT -> nothing to replay.
        """
        raise NotImplementedError

    def ack(self, through_seq: int) -> None:
        """Handle ``ack{through}``: drop ring frames at/below ``through_seq``."""
        raise NotImplementedError


class DownstreamServer:
    """The relay<->phone WS server + upstream RPC translator."""

    def __init__(
        self,
        config: DownstreamConfig,
        bus: EventBus,
        gateway: GatewayClient,
        store: SessionStore,
    ) -> None:
        self._cfg = config
        self._bus = bus
        self._gateway = gateway
        self._store = store
        self._ring = None  # set in start(): reused ReplayRingManager
        self._conns: dict[str, PhoneConnection] = {}

    async def start(self) -> None:
        """Build the reused replay ring and bind the phone-facing WS server."""
        raise NotImplementedError

    async def serve(self) -> None:
        """Accept loop: register each phone connection, pump frames to it.

        Also starts the fan-out task that reads ``TOPIC_RELAY_FRAMES`` and
        forwards each frame to every connection's :meth:`PhoneConnection.send_frame`.
        """
        raise NotImplementedError

    async def close(self) -> None:
        raise NotImplementedError

    # -- upstream (phone -> relay -> gateway), protocol §5 ---------------
    async def handle_upstream(self, conn: PhoneConnection, req: UpstreamRequest) -> Any:
        """Translate one phone JSON-RPC request and return its JSON-RPC result.

        * ``list``      -> gateway.session_list
        * ``open``/``history`` -> gateway.rest_history (store-read; R0 correction)
        * ``submit``    -> session_create/resume (+own) -> prompt_submit
        * ``resume``    -> session_resume (own idle/foreign)
        * ``approve``   -> approval_respond
        * ``clarify``   -> clarify_respond
        * ``interrupt`` -> session_interrupt
        * ``ack``       -> conn.ack (LOCAL, no gateway hop)
        * ``resync``    -> conn.replay (LOCAL, no gateway hop)
        """
        raise NotImplementedError

    # -- foreground tracking (feeds Notifier §6 gate) --------------------
    def session_has_live_phone(self, session_id: str) -> bool:
        """True iff any connected phone holds ``session_id`` foregrounded.

        The Notifier calls this to skip a push when the user is already watching
        (protocol §6): a foregrounded session on a live WS suppresses APNs.
        """
        return any(session_id in c.foreground_sessions for c in self._conns.values())
