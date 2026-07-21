"""Smoke — prove the harness pipeline end-to-end before the torture matrix.

Not a spec scenario: a fast sanity gate that the isolated gateway + relay
subprocess + phone-driver + invariant checkers + evidence writer all work
together on the happy path (one clean turn, reconciled, all invariants green).
If this fails, nothing else in the matrix is meaningful.
"""

from __future__ import annotations

import pytest

from tests.relay_soak.invariants.checkers import (
    SeqCoverageChecker,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio


async def test_smoke_clean_turn(mock_gateway, relay, phone_factory, evidence):
    phone = await phone_factory()

    ref = await common.run_reference(phone, mock_gateway, script="simple",
                                     text="Smoke turn is deterministic.")
    agent = common.agent_messages(ref)
    assert agent == ["Smoke turn is deterministic."], f"clean run wrong: {ref}"

    # Drive a second, tortured-free turn on a fresh session and reconcile it.
    info = await common.drive(phone, mock_gateway, script="simple",
                              text="Second smoke turn.")
    cand = await common.reconcile_after_settle(phone, info["sid"],
                                               resync_from=None)
    assert common.agent_messages(cand) == ["Second smoke turn."]

    # I1: every driven session reached a terminal turn.
    tracker = TurnTerminalTracker()
    tracker.mark_driven(next(iter(ref)) and info["sid"])
    tracker.mark_driven(info["sid"])
    # fold frames for both driven sessions
    sids = {f.sid for f in phone.frames}
    for sid in sids:
        tracker.mark_driven(sid)
    tracker.fold(phone.frames)
    i1 = tracker.report()

    # I3: per-connection seq coverage (single generation here).
    seq = SeqCoverageChecker().fold_segments(phone.generation_segments())
    i3 = seq.report()

    assert i1["ok"], f"I1 failed: {i1['violations']}"
    assert i3["ok"], f"I3 failed: {i3['violations']}"

    evidence("smoke", {
        "reference_agent": agent,
        "candidate_agent": common.agent_messages(cand),
        "I1": i1, "I3": i3,
        "frames": len(phone.frames),
        "generations": phone.generation,
    })
