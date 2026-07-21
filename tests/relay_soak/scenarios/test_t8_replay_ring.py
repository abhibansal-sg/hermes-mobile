"""T8 — replay-ring boundaries (I2 / I4, with I3 coverage).

Hammer the per-connection seq/ack/replay ring at its edges on ONE long-lived
connection (no reconnects — seq spine stays single):

* **ack storm** — ``ack{through}`` at/around the head at high frequency, plus
  stale/ancient watermarks the ring must ignore;
* **cursor manipulation** — ``resync`` from adversarial cursors: ``0`` (cold
  snapshot), ``head`` (attach live), small gaps (replay), and a FAR-FUTURE seq
  (must trigger the snapshot-all-sessions heal, downstream.py:192-203, not a
  crash or silent no-catch-up);
* **ring overflow** — drive enough turns that the connection emits more than
  the ring's 512-frame cap, so an ancient ``resync`` falls BELOW the floor and
  must FALL BACK to a snapshot (the one sanctioned full-refetch).

After the storm, a cold ``resync(0)`` snapshot must reconcile every driven
session byte-identically (I2), each prompt must have landed on exactly one
userMessage item_id (I4), and the per-connection seq coverage must be contiguous
(I3). The scripted gateway keeps every turn's text deterministic.
"""

from __future__ import annotations

import asyncio
import random

import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.infra.phone_ext import (
    ack_storm_loop,
    cursor_manipulation_loop,
)
from tests.relay_soak.invariants.checkers import (
    DedupChecker,
    SeqCoverageChecker,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio

TEXT = "Replay ring boundary turns must reconcile byte-identical after the storm."
RING_FRAMES_CAP = 512  # replay_ring default; overflow forces a snapshot fallback


async def test_t8_replay_ring(mock_gateway, relay, phone_factory, evidence):
    p = soak_params.params("t8_ring")
    rng = random.Random(p.seed ^ 0x8)

    phone = await phone_factory()

    # Clean reference.
    ref = await common.run_reference(phone, mock_gateway, script="simple",
                                     text=TEXT)
    assert common.agent_messages(ref) == [TEXT]

    stop = asyncio.Event()
    ack_task = asyncio.create_task(ack_storm_loop(
        phone, stop=stop, rng=rng, lo_s=0.005, hi_s=0.05))
    cursor_task = asyncio.create_task(cursor_manipulation_loop(
        phone, stop=stop, rng=rng, lo_s=0.02, hi_s=0.15))

    dedup = DedupChecker()
    driven: list[str] = []
    deadline = asyncio.get_event_loop().time() + p.duration_s
    i = 0
    # Drive turns until we both overflow the ring AND hit the duration bound.
    while (asyncio.get_event_loop().time() < deadline
           and len(phone.frames) < RING_FRAMES_CAP + 120):
        sid = await mock_gateway.create_session(
            script="simple", text=TEXT, delta_delay_s=0.005)
        cmid = f"cmid-t8-{i}"
        try:
            resp = await phone.submit(text=TEXT, session_id=sid,
                                      client_message_id=cmid)
            dedup.record_submit(cmid, (resp or {}).get("result") or {})
            await common.wait_terminal(phone, sid, timeout=12.0)
            driven.append(sid)
        except (asyncio.TimeoutError, Exception):  # noqa: BLE001
            driven.append(sid)
        i += 1

    stop.set()
    try:
        acks = await asyncio.wait_for(ack_task, timeout=5.0)
    except asyncio.TimeoutError:
        ack_task.cancel()
        acks = -1
    try:
        resyncs = await asyncio.wait_for(cursor_task, timeout=5.0)
    except asyncio.TimeoutError:
        cursor_task.cancel()
        resyncs = -1

    # --- quiesce: cold snapshot + reconcile every driven session ----------
    tracker = TurnTerminalTracker()
    i2_bad = 0
    for sid in driven:
        await phone.resync(0)   # cold: forces snapshot (floor already passed)
        await asyncio.sleep(0.03)
        cand = common.reconcile_transcript(phone.frames_for(sid))
        if common.agent_messages(cand) != [TEXT]:
            i2_bad += 1
        tracker.mark_driven(sid)
    tracker.fold(phone.frames)
    dedup.fold_frames(phone.frames)
    seq = SeqCoverageChecker().fold_segments(phone.generation_segments())

    i1 = tracker.report()
    i4 = dedup.report()
    i3 = seq.report()
    i2 = {
        "invariant": "I2", "ok": i2_bad == 0,
        "violations": [f"I2: {i2_bad}/{len(driven)} ring-boundary session(s) "
                       f"diverged after the ack/cursor storm"] if i2_bad else [],
        "driven_sessions": len(driven),
        "ring_overflow": len(phone.frames) > RING_FRAMES_CAP,
        "reference_agent": common.agent_messages(ref),
    }

    verdict = common.build_verdict(
        "T8_replay_ring", [i1, i2, i4, i3],
        duration_s=round(p.duration_s, 2), turns_driven=len(driven),
        total_frames=len(phone.frames), ring_cap=RING_FRAMES_CAP,
        acks_sent=acks, resyncs_sent=resyncs, generations=phone.generation,
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
