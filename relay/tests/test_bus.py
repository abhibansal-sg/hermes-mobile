"""Tests for the in-process fan-out event bus."""

from __future__ import annotations

import asyncio

import pytest

from hermes_relay.bus import TOPIC_RELAY_FRAMES, EventBus


async def test_fanout_delivers_to_all_subscribers():
    bus = EventBus()
    a = bus.subscribe(TOPIC_RELAY_FRAMES)
    b = bus.subscribe(TOPIC_RELAY_FRAMES)
    n = bus.publish(TOPIC_RELAY_FRAMES, "hello")
    assert n == 2
    assert await asyncio.wait_for(a.get(), 1) == "hello"
    assert await asyncio.wait_for(b.get(), 1) == "hello"


async def test_publish_with_no_subscribers_is_noop():
    bus = EventBus()
    assert bus.publish("nobody.listening", 1) == 0


async def test_drop_oldest_overflow():
    bus = EventBus()
    sub = bus.subscribe(TOPIC_RELAY_FRAMES, maxsize=2)
    for i in range(5):
        bus.publish(TOPIC_RELAY_FRAMES, i)
    # queue holds the 2 newest; 3 were dropped-oldest
    assert sub.dropped == 3
    first = await asyncio.wait_for(sub.get(), 1)
    second = await asyncio.wait_for(sub.get(), 1)
    assert (first, second) == (3, 4)


async def test_unsubscribe_stops_delivery():
    bus = EventBus()
    sub = bus.subscribe(TOPIC_RELAY_FRAMES)
    bus.unsubscribe(sub)
    assert bus.publish(TOPIC_RELAY_FRAMES, "x") == 0
    assert bus.subscriber_count(TOPIC_RELAY_FRAMES) == 0
