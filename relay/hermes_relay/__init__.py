"""hermes_relay — the mobile relay-client service (Wave 2 linchpin).

A ZERO-CORE-PATCH, co-located process that makes the phone a first-class client
of the STOCK Hermes gateway. It reframes the gateway's raw event stream into the
ratified item-lifecycle envelope (``docs/RELAY-PHONE-PROTOCOL.md``) and serves it
to the iOS app over a reliable seq/ack/replay WS, firing APNs for owned sessions.

Four decoupled lanes over one in-process bus (see :mod:`hermes_relay.app`):

1. :mod:`hermes_relay.gateway_client` — durable multiplexing WS client (§5).
2. :mod:`hermes_relay.reframer`       — raw -> item envelope mapping (§2/§3).
3. :mod:`hermes_relay.downstream`     — phone WS server + replay ring (§1/§4).
4. :mod:`hermes_relay.notifier`       — owned-session APNs observer (§6).

Shared contract: :mod:`hermes_relay.types` (envelope/item/events),
:mod:`hermes_relay.bus` (fan-out), :mod:`hermes_relay.session_state`
(resume-as-items accumulator). Plumbing reuse: :mod:`hermes_relay.plugin_bridge`.
"""

from __future__ import annotations

from .bus import TOPIC_GATEWAY_EVENTS, TOPIC_RELAY_FRAMES, EventBus
from .session_state import SessionState, SessionStore
from .types import (
    Frame,
    FrameKind,
    GatewayEvent,
    Item,
    ItemStatus,
    ItemType,
    RawEvent,
    UpstreamMethod,
    UpstreamRequest,
)

__version__ = "0.2.0"

__all__ = [
    "EventBus",
    "TOPIC_GATEWAY_EVENTS",
    "TOPIC_RELAY_FRAMES",
    "SessionState",
    "SessionStore",
    "Frame",
    "FrameKind",
    "GatewayEvent",
    "Item",
    "ItemStatus",
    "ItemType",
    "RawEvent",
    "UpstreamMethod",
    "UpstreamRequest",
    "__version__",
]
