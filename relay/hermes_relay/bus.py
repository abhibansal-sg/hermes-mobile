"""In-process async event bus — the seam between the four relay lanes.

The lanes do not call each other directly; they publish to and subscribe from
named topics on one :class:`EventBus`. This keeps the four build lanes
decoupled so they can be developed and tested in isolation (each lane's test
drives the bus with fabricated messages and asserts on what the lane publishes).

Topic conventions (the wiring the composition root establishes):

* ``TOPIC_GATEWAY_EVENTS`` — :class:`~hermes_relay.types.GatewayEvent`.
  Producer: GatewayClient. Consumers: Reframer, (Notifier may observe raw too).
* ``TOPIC_RELAY_FRAMES`` — :class:`~hermes_relay.types.Frame` (seq unstamped).
  Producer: Reframer. Consumers: DownstreamServer (stamps + sends), Notifier
  (observes item.completed/approval/error for owned sessions).

The bus is deliberately minimal: bounded per-subscriber queues with a
drop-oldest overflow discipline (same philosophy as the broadcast mirror
backlog), fan-out delivery, and no cross-topic ordering guarantees beyond
per-topic FIFO to a given subscriber. It carries only in-process Python
objects; nothing is serialized here.
"""

from __future__ import annotations

import asyncio
from typing import Any, AsyncIterator

TOPIC_GATEWAY_EVENTS = "gateway.events"
TOPIC_RELAY_FRAMES = "relay.frames"

_DEFAULT_MAXSIZE = 1024


class Subscription:
    """A single consumer's view of a topic: an async iterator of messages.

    Backed by a bounded :class:`asyncio.Queue`. On overflow the OLDEST queued
    message is dropped (a slow consumer must never stall the publisher or the
    other consumers) — the same bounded-backlog discipline the mirror path
    uses. Reliability for the phone is the ReplayRing's job downstream, not the
    bus's.
    """

    def __init__(self, topic: str, maxsize: int = _DEFAULT_MAXSIZE) -> None:
        self.topic = topic
        self._q: "asyncio.Queue[Any]" = asyncio.Queue(maxsize=maxsize)
        self.dropped = 0
        self._closed = False

    def _offer(self, msg: Any) -> None:
        """Non-blocking publish-side enqueue with drop-oldest overflow."""
        if self._closed:
            return
        try:
            self._q.put_nowait(msg)
        except asyncio.QueueFull:
            try:
                self._q.get_nowait()
                self.dropped += 1
                self._q.put_nowait(msg)
            except asyncio.QueueEmpty:  # pragma: no cover - race guard
                pass

    async def _put(self, msg: Any) -> None:
        """Losslessly enqueue with bounded producer backpressure."""

        if self._closed:
            return
        await self._q.put(msg)

    async def get(self) -> Any:
        """Await the next message on this subscription."""
        return await self._q.get()

    def close(self) -> None:
        self._closed = True

    def __aiter__(self) -> AsyncIterator[Any]:
        return self

    async def __anext__(self) -> Any:
        if self._closed and self._q.empty():
            raise StopAsyncIteration
        return await self._q.get()


class EventBus:
    """Fan-out pub/sub over named topics. One instance per relay process."""

    def __init__(self) -> None:
        self._subs: dict[str, list[Subscription]] = {}

    def subscribe(self, topic: str, maxsize: int = _DEFAULT_MAXSIZE) -> Subscription:
        """Register and return a new :class:`Subscription` on ``topic``."""
        sub = Subscription(topic, maxsize=maxsize)
        self._subs.setdefault(topic, []).append(sub)
        return sub

    def unsubscribe(self, sub: Subscription) -> None:
        subs = self._subs.get(sub.topic)
        if subs and sub in subs:
            subs.remove(sub)
        sub.close()

    def publish(self, topic: str, msg: Any) -> int:
        """Deliver ``msg`` to every current subscriber of ``topic``.

        Returns the number of subscribers the message was offered to. Never
        blocks and never raises on a full subscriber (drop-oldest applies).
        """
        subs = self._subs.get(topic) or ()
        for sub in subs:
            sub._offer(msg)
        return len(subs)

    async def publish_wait(self, topic: str, msg: Any) -> int:
        """Losslessly publish, awaiting bounded subscriber capacity.

        This is reserved for authoritative trusted-local pipelines whose
        producers are async and can safely propagate backpressure. Legacy
        best-effort observers continue to use :meth:`publish`.
        """

        subs = tuple(self._subs.get(topic) or ())
        for sub in subs:
            await sub._put(msg)
        return len(subs)

    def subscriber_count(self, topic: str) -> int:
        return len(self._subs.get(topic) or ())
