"""Lane 2 — Reframer: raw gateway events -> ratified item envelope.

The single mapping layer (protocol §2/§3). It consumes
:class:`~hermes_relay.types.GatewayEvent` off ``TOPIC_GATEWAY_EVENTS`` and emits
zero or more :class:`~hermes_relay.types.Frame` objects (seq unstamped) onto
``TOPIC_RELAY_FRAMES``. It holds per-session bookkeeping (via
:class:`~hermes_relay.session_state.SessionStore`) to assign stable ``item_id``
and monotonic ``ord``, and to know which in-progress item a delta belongs to.

The raw -> item mapping (R0-confirmed field names, protocol §2 catalog):

| raw event (``type``)              | -> item type / frame                              |
|-----------------------------------|---------------------------------------------------|
| ``message.start``                 | ``item.started`` agentMessage                     |
| ``message.delta`` (``.text``)     | ``item.delta`` {patch:{text}}                     |
| ``message.complete`` (``.usage``) | ``item.completed`` agentMessage + turn usage      |
| ``reasoning.delta``               | ``item.started``/``item.delta`` reasoning         |
| ``reasoning.available``           | ``item.completed`` reasoning                      |
| ``tool.start`` (``.name,.args``)  | ``item.started`` toolCall (name-keyed)            |
| ``tool.complete`` (``.name,       | ``item.completed`` toolCall — OR ``fileChange``   |
|   .result,.duration_s,            |   when ``inline_diff`` present; ``browser`` for   |
|   .inline_diff``)                 |   ``browser_*`` names; ``image`` for image tools  |
| ``error``                         | ``item.completed`` error (status=failed)          |
| ``status.update``                 | ``status`` frame (non-item chatter)               |

Type-selection rule (protocol §2 forward-compat): EVERY tool maps to a generic
``toolCall`` keyed by ``name``; the special types (``fileChange``/``image``/
``browser``) are refinements chosen from the tool ``name`` / result shape. An
unrecognized tool still yields a valid ``toolCall`` — the phone never breaks on
a new Hermes tool.

INTERFACE THE LANE IMPLEMENTS: :meth:`reframe` (pure per-event mapping) plus the
:meth:`run` pump. All state lives in the injected :class:`SessionStore`.
"""

from __future__ import annotations

from typing import Optional

from .bus import EventBus
from .session_state import SessionStore
from .types import Frame, GatewayEvent


# Tool name families that get a special render (protocol §2). Everything else is
# a generic toolCall. Kept as data so the mapping stays declarative.
_BROWSER_PREFIX = "browser_"
_IMAGE_TOOLS = frozenset({"image_generate"})


class Reframer:
    """Maps one gateway stream into the item-lifecycle envelope."""

    def __init__(self, bus: EventBus, store: SessionStore) -> None:
        self._bus = bus
        self._store = store

    async def run(self) -> None:
        """Pump: subscribe ``TOPIC_GATEWAY_EVENTS``, reframe, publish frames.

        For each inbound event, call :meth:`reframe`, then publish every emitted
        frame to ``TOPIC_RELAY_FRAMES`` and fold it into the SessionStore (so the
        snapshot/resync path stays current). Runs until cancelled.
        """
        raise NotImplementedError

    def reframe(self, event: GatewayEvent) -> list[Frame]:
        """Map ONE raw gateway event to zero+ downstream frames (seq unstamped).

        Pure w.r.t. the bus (does not publish) but reads/writes per-session
        bookkeeping in the SessionStore (item_id + ord allocation, in-progress
        item tracking). This is the function every mapping unit test drives.
        """
        raise NotImplementedError

    # -- per-family mappers (internal; declarative split so the table above is
    #    one-to-one with code and new tools slot in without touching others) --

    def _reframe_message(self, event: GatewayEvent) -> list[Frame]:
        """message.start/delta/complete -> agentMessage item lifecycle."""
        raise NotImplementedError

    def _reframe_reasoning(self, event: GatewayEvent) -> list[Frame]:
        """reasoning.delta/available -> reasoning item lifecycle."""
        raise NotImplementedError

    def _reframe_tool(self, event: GatewayEvent) -> list[Frame]:
        """tool.start/complete -> generic toolCall (or special type)."""
        raise NotImplementedError

    def _reframe_error(self, event: GatewayEvent) -> list[Frame]:
        """error -> error item (never hidden in a collapse, protocol §2)."""
        raise NotImplementedError

    def _reframe_status(self, event: GatewayEvent) -> list[Frame]:
        """status.update -> status frame (non-item chatter)."""
        raise NotImplementedError

    @staticmethod
    def _tool_item_type(name: str, payload: dict) -> str:
        """Select the item type for a tool by name/result (protocol §2 rule).

        ``inline_diff`` present -> fileChange; ``browser_*`` -> browser; known
        image tool -> image; otherwise the generic toolCall. Never raises on an
        unknown name.
        """
        raise NotImplementedError
