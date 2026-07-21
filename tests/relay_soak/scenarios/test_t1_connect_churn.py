"""T1 — connect churn (I1 / I2 / I3).

The phone connects/disconnects at randomized 0.1-5 s intervals while turns
stream. After the churn window the harness stops, force-resyncs every driven
session (cold snapshot — heals any gap), and requires:

* **I2** every driven session's reconciled transcript is byte-identical to a
  clean reference run of the SAME deterministic script;
* **I1** every driven session reached a terminal turn (no eternal-working turn
  lost to a flap);
* **I3** every connection generation received a CONTIGUOUS seq coverage
  ``[1..head]`` (a permanently dropped downstream frame leaves a hole).

This is the reconnect-reliability spine (seq/ack/replay + completed-authoritative)
under sustained hostile connect churn.
"""

from __future__ import annotations

import asyncio
import random

import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.infra.phone_ext import churn_loop
from tests.relay_soak.invariants.checkers import (
    SeqCoverageChecker,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio

TEXT = "The quick brown fox jumps over the lazy dog near the river bank."


async def test_t1_connect_churn(mock_gateway, relay, phone_factory, evidence):
    p = soak_params.params("t1_churn")
    rng = random.Random(p.seed ^ 0x1)

    phone = await phone_factory()

    # --- clean reference ------------------------------------------------
    ref = await common.run_reference(phone, mock_gateway, script="simple",
                                     text=TEXT)
    ref_agent = common.agent_messages(ref)
    assert ref_agent == [TEXT], f"reference run not canonical: {ref_agent}"

    # --- churn + drive turns for the duration --------------------------
    stop = asyncio.Event()
    hi = min(5.0, max(0.3, p.duration_s / 6.0))

    async def _resync_last(d):
        last = max((f.seq for f in d.frames), default=0)
        await d.resync(last)

    churn_task = asyncio.create_task(churn_loop(
        phone_factory, phone, stop=stop, rng=rng, lo_s=0.1, hi_s=hi,
        on_reconnect=_resync_last,
    ))

    driven: list[str] = []
    deadline = asyncio.get_event_loop().time() + p.duration_s
    while asyncio.get_event_loop().time() < deadline:
        sid = await mock_gateway.create_session(
            script="simple", text=TEXT, delta_delay_s=0.02)
        # Submit retries across flaps (the socket may be mid-close).
        for _ in range(25):
            try:
                await phone.submit(text=TEXT, session_id=sid,
                                   client_message_id=f"cmid-t1-{len(driven)}")
                break
            except Exception:  # noqa: BLE001
                await asyncio.sleep(0.05)
        driven.append(sid)
        try:
            await common.wait_terminal(phone, sid, timeout=10.0)
        except asyncio.TimeoutError:
            pass  # final resync(0) below heals; I1 checks the terminal state

    stop.set()
    try:
        cycles = await asyncio.wait_for(churn_task, timeout=10.0)
    except asyncio.TimeoutError:
        churn_task.cancel()
        cycles = -1

    # --- quiesce: force-resync + reconcile every driven session ---------
    tracker = TurnTerminalTracker()
    seq = SeqCoverageChecker()
    i2_mismatches: list[dict] = []
    for sid in driven:
        await phone.resync(0)  # cold snapshot heals any gap
        await asyncio.sleep(0.1)
        cand = common.reconcile_transcript(phone.frames_for(sid))
        diff = common.diff_transcripts(ref, cand)
        if not diff["identical"]:
            i2_mismatches.append({"sid": sid, **diff})
        tracker.mark_driven(sid)
    tracker.fold(phone.frames)
    seq.fold_segments(phone.generation_segments())

    i1 = tracker.report()
    i3 = seq.report()
    i2 = {
        "invariant": "I2", "ok": not i2_mismatches,
        "violations": [f"I2: session {m['sid']} transcript diverged "
                       f"(missing_types={m['missing_types']}, "
                       f"cand_agent={m['cand_agent']})" for m in i2_mismatches],
        "driven_sessions": len(driven), "mismatches": len(i2_mismatches),
        "reference_agent": ref_agent,
    }

    verdict = common.build_verdict(
        "T1_connect_churn", [i1, i2, i3],
        duration_s=round(p.duration_s, 2), churn_cycles=cycles,
        turns_driven=len(driven), generations=phone.generation,
        dropped_frames_by_shim=len(phone.dropped),
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
