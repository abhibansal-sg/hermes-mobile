"""Scenario (i) — turn control over the relay: interrupt / steer / queue (QA-2 R11, A5).

Build 115 routed every turn-control action through the gateway-DIRECT socket —
idle in relay mode — so stop and steer failed with "Not connected to the Hermes
gateway", and a queue-mode send vanished (the relay submit's busy reject
deleted the echo instead of queueing). This scenario proves all three work OVER
THE RELAY against a live relay subprocess + scripted mock gateway:

* **interrupt** mid-turn stops the live turn early (the turn completes with
  status ``interrupted`` — fewer deltas than the full script), via the relay
  `interrupt` upstream method;
* **steer** mid-turn returns the gateway's ``queued`` disposition VERBATIM and
  the text lands on the running session (no new turn); a steer when idle is
  ``rejected`` so the phone keeps the text and offers queueing;
* **queue**: a second submit into a mid-turn session is rejected BUSY by the
  gateway (the 4009 the iOS outbox fallback keys on — it enqueues + shows the
  pill instead of deleting the echo), and the SAME prompt submitted after the
  turn completes runs normally — the drain-after-turn semantics.
"""

from __future__ import annotations

import asyncio

import pytest

pytestmark = pytest.mark.asyncio


async def test_interrupt_over_relay_stops_the_live_turn(mock_gateway, phone_factory, evidence):
    from mock_gateway.server import create_scripted_session

    # A ~40-word turn at 50ms/word ≈ 2s — plenty of window to interrupt.
    sid = await create_scripted_session(
        mock_gateway, script="longturn",
        text=" ".join(f"word{i:02d}" for i in range(40)),
        delta_delay_s=0.05,
    )
    phone = await phone_factory()
    res = await phone.submit(text="start the long turn", session_id=sid)
    assert "result" in res, f"submit failed: {res}"
    driven = res["result"]["session_id"]

    # Wait until the turn is live (the agentMessage item has started; delta
    # bodies carry no item type, so liveness is asserted off item.started).
    first = await phone.wait_for(
        "item.started", sid=driven, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    assert first is not None

    # STOP over the relay — the build-115 failure was "Not connected" here.
    interrupt_res = await phone.interrupt(driven)
    assert "result" in interrupt_res, f"relay interrupt failed: {interrupt_res}"

    # The turn ends EARLY with status "interrupted" (not the full 40 words).
    completed = await phone.wait_for(
        "item.completed", sid=driven, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    final_text = phone.item_body(completed).get("text", "")
    streamed_words = len(final_text.split())
    assert streamed_words < 40, (
        f"interrupt did not stop the turn early: streamed all {streamed_words} words"
    )
    # The gateway saw the interrupt forwarded by the relay.
    assert mock_gateway.sessions[driven].interrupts, "the relay never forwarded session.interrupt"
    # The relay upstream was the phone's `interrupt` method (not a gateway rpc).
    assert any(s["method"] == "interrupt" for s in phone.sent)
    assert not any(s["method"] == "session.interrupt" for s in phone.sent), (
        "session.interrupt is the gateway rpc — the phone must send `interrupt` to the relay"
    )

    evidence("i-interrupt", {
        "session_id": driven,
        "streamed_words_before_interrupt": streamed_words,
        "total_words": 40,
        "interrupts_forwarded": len(mock_gateway.sessions[driven].interrupts),
    })


async def test_steer_over_relay_injects_into_live_turn_and_rejects_when_idle(
    mock_gateway, phone_factory, evidence
):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(
        mock_gateway, script="longturn",
        text=" ".join(f"w{i:02d}" for i in range(30)),
        delta_delay_s=0.05,
    )
    phone = await phone_factory()
    res = await phone.submit(text="start the turn", session_id=sid)
    driven = res["result"]["session_id"]

    # Wait until the turn is live, then steer — queued, verbatim disposition.
    await phone.wait_for(
        "item.started", sid=driven, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    steer_res = await phone.steer(driven, "also check the staging env")
    assert "result" in steer_res, f"relay steer failed: {steer_res}"
    assert steer_res["result"]["status"] == "queued", (
        f"live-turn steer must be queued, got {steer_res['result']}"
    )
    assert steer_res["result"]["text"] == "also check the staging env", (
        "the gateway disposition must pass through the relay VERBATIM"
    )
    # The steering text landed on the RUNNING session (no new turn driven).
    steers = mock_gateway.sessions[driven].steers
    assert [s["text"] for s in steers] == ["also check the staging env"]
    submits = [s for s in phone.sent if s["method"] == "submit"]
    assert len(submits) == 1, "a steer must NOT drive a second turn"
    assert any(s["method"] == "steer" for s in phone.sent)

    # Let the turn finish cleanly.
    await phone.wait_for("turn.completed", sid=driven, timeout=15.0)

    # Steer while IDLE (turn done) — the gateway rejects, the phone keeps its
    # text so the composer can offer queueing instead (the steer→queue chain).
    idle_steer = await phone.steer(driven, "too late")
    assert idle_steer["result"]["status"] == "rejected", (
        f"steer after the turn must be rejected, got {idle_steer}"
    )

    evidence("i-steer", {
        "session_id": driven,
        "live_disposition": steer_res["result"]["status"],
        "idle_disposition": idle_steer["result"]["status"],
        "steers_received": [s["text"] for s in steers],
    })


async def test_busy_reject_surfaces_over_relay_then_drains_after_turn(
    mock_gateway, phone_factory, evidence
):
    """QUEUE semantics at the relay edge: a second prompt into a mid-turn
    session is rejected BUSY (the gateway's 4009, propagated by the relay as a
    JSON-RPC error) — this is the exact trigger the iOS app's durable outbox
    keys its enqueue+pill fallback on (R11 fix), replacing the build-115
    echo-deletion. After the turn completes, the SAME prompt drains normally —
    the queue-and-send-after-turn behavior the outbox drain implements."""
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(
        mock_gateway, script="longturn",
        text=" ".join(f"x{i:02d}" for i in range(30)),
        delta_delay_s=0.05,
    )
    phone = await phone_factory()
    res = await phone.submit(text="first prompt", session_id=sid)
    driven = res["result"]["session_id"]

    # Wait until the turn is live.
    await phone.wait_for(
        "item.started", sid=driven, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )

    # Second prompt mid-turn → BUSY reject travels back over the relay (not a
    # silent success, not a hang). The relay maps the gateway error onto a
    # JSON-RPC error frame.
    busy = await phone.submit(text="queued prompt", session_id=driven)
    assert "error" in busy, (
        f"a mid-turn submit must be rejected busy, got {busy}"
    )
    assert "busy" in busy["error"]["message"].lower(), (
        f"the busy disposition must carry the gateway's reason: {busy['error']}"
    )

    # The first turn was NOT disturbed by the rejected second prompt.
    completed = await phone.wait_for(
        "item.completed", sid=driven, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    assert phone.item_body(completed).get("text", "").split()[0] == "x00"
    await phone.wait_for("turn.completed", sid=driven, timeout=15.0)

    # AFTER the turn: the same prompt drains (the outbox wake-on-completion
    # path). The mock gateway serializes per session, so the retry lands once
    # the prior turn released its run.
    drained = None
    for _ in range(20):
        retry = await phone.submit(text="queued prompt", session_id=driven)
        if "result" in retry:
            drained = retry
            break
        await asyncio.sleep(0.1)
    assert drained is not None, "the queued prompt never drained after the turn ended"

    # The second turn ran to completion on the same session.
    second = await phone.wait_for(
        "turn.completed", sid=driven, timeout=15.0,
        predicate=lambda f: f.seq > completed.seq,
    )
    assert second is not None

    evidence("i-queue-busy-drain", {
        "session_id": driven,
        "busy_error": busy["error"],
        "drained_after_turn": True,
    })
