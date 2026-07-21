"""Self-proof — the invariant checkers DETECT an injected frame loss.

A harness whose invariants always pass is worthless. This meta-scenario
deliberately corrupts the phone's recorded stream via the ``drop_if`` wire-loss
shim (frames the phone "never receives") and asserts the checkers go RED exactly
where they should — and stay GREEN on an uncorrupted control run:

* **control** — clean turn → I1 + I2 green (the checkers are not always-red);
* **I2/I1 fault** — drop the authoritative ``agentMessage`` ``item.completed``
  AND its ``turn.completed`` (and never resync, so no snapshot heals it) → the
  reconciled transcript loses the agent message (I2 RED) and the turn never
  reaches a terminal state (I1 RED);
* **I3 fault** — drop ONE mid-stream frame (seq 2) → a hole in the per-connection
  seq coverage (I3 RED).

This is the "drop a frame in a test shim and show I2 fails" proof the harness
spec requires. The relay under test is NOT modified — the corruption is purely
on the observation path, which is what the checkers inspect.
"""

from __future__ import annotations

import asyncio

import pytest

from tests.relay_soak.infra.phone_ext import SoakPhoneDriver
from tests.relay_soak.constants import MOCK_GATEWAY_TOKEN
from tests.relay_soak.conftest import phone_url_for
from tests.relay_soak.invariants.checkers import (
    SeqCoverageChecker,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio

TEXT = "The invariant checkers must detect a deliberately dropped frame."


def _i2_report(ref, cand) -> dict:
    diff = common.diff_transcripts(ref, cand)
    return {
        "invariant": "I2", "ok": diff["identical"],
        "violations": [] if diff["identical"] else [
            f"I2: transcript diverged (ref_agent={diff['ref_agent']}, "
            f"cand_agent={diff['cand_agent']})"],
        **diff,
    }


async def test_z_injected_fault_detected(mock_gateway, relay, evidence):
    url = phone_url_for(relay)

    # --- control: clean run, checkers GREEN -----------------------------
    ctrl = SoakPhoneDriver(url, token=MOCK_GATEWAY_TOKEN)
    await ctrl.connect()
    ref = await common.run_reference(ctrl, mock_gateway, script="simple",
                                     text=TEXT)
    sid_c = await mock_gateway.create_session(script="simple", text=TEXT)
    await ctrl.submit(text=TEXT, session_id=sid_c, client_message_id="cmid-ctrl")
    await common.wait_terminal(ctrl, sid_c, timeout=15.0)
    cand_ctrl = common.reconcile_transcript(ctrl.frames_for(sid_c))
    ctrl_i2 = _i2_report(ref, cand_ctrl)
    ctrl_tracker = TurnTerminalTracker()
    ctrl_tracker.mark_driven(sid_c)
    ctrl_tracker.fold(ctrl.frames)
    ctrl_i1 = ctrl_tracker.report()
    await ctrl.close()
    assert ctrl_i1["ok"], f"control I1 should be green: {ctrl_i1['violations']}"
    assert ctrl_i2["ok"], f"control I2 should be green: {ctrl_i2['violations']}"

    # --- I2/I1 fault: drop agentMessage completion + turn.completed -----
    def drop_terminal(f):
        if f.kind == "turn.completed":
            return True
        if f.kind == "item.completed" and (f.body or {}).get("type") == "agentMessage":
            return True
        return False

    fault = SoakPhoneDriver(url, token=MOCK_GATEWAY_TOKEN, drop_if=drop_terminal)
    await fault.connect()
    sid_f = await mock_gateway.create_session(script="simple", text=TEXT)
    await fault.submit(text=TEXT, session_id=sid_f, client_message_id="cmid-fault")
    await asyncio.sleep(1.5)  # let the (dropped) terminal frames "arrive"
    # Deliberately NO resync: no snapshot may heal the injected loss.
    cand_fault = common.reconcile_transcript(fault.frames_for(sid_f))
    fault_i2 = _i2_report(ref, cand_fault)
    fault_tracker = TurnTerminalTracker()
    fault_tracker.mark_driven(sid_f)
    fault_tracker.fold(fault.frames)
    fault_i1 = fault_tracker.report()
    await fault.close()

    assert len(fault.dropped) >= 1, "shim did not drop any frame — proof invalid"
    assert not fault_i2["ok"], (
        "I2 checker FAILED to detect the dropped agentMessage completion "
        "(transcript should have diverged)")
    assert not fault_i1["ok"], (
        "I1 checker FAILED to detect the dropped turn.completed "
        "(turn should look non-terminal)")

    # --- I3 fault: drop one mid-stream frame -> seq hole ----------------
    def drop_seq2(f):
        return f.seq == 2

    hole = SoakPhoneDriver(url, token=MOCK_GATEWAY_TOKEN, drop_if=drop_seq2)
    await hole.connect()
    sid_h = await mock_gateway.create_session(script="simple", text=TEXT)
    await hole.submit(text=TEXT, session_id=sid_h, client_message_id="cmid-hole")
    await common.wait_terminal(hole, sid_h, timeout=15.0)
    await asyncio.sleep(0.2)
    hole_i3 = SeqCoverageChecker().fold_segments(
        hole.generation_segments()).report()
    await hole.close()

    assert len(hole.dropped) >= 1, "shim did not drop seq 2 — proof invalid"
    assert not hole_i3["ok"], (
        "I3 checker FAILED to detect the seq-2 hole (coverage should have a gap)")

    evidence("verdict", {
        "scenario": "Z_injected_fault_self_proof",
        "ok": True,  # this test passes when the checkers correctly go RED
        "control": {"I1": ctrl_i1["ok"], "I2": ctrl_i2["ok"]},
        "fault_I2_I1": {
            "dropped_frames": len(fault.dropped),
            "I2_detected": not fault_i2["ok"],
            "I1_detected": not fault_i1["ok"],
            "I2_violations": fault_i2["violations"],
            "I1_violations": fault_i1["violations"],
            "cand_agent": common.agent_messages(cand_fault),
        },
        "fault_I3": {
            "dropped_frames": len(hole.dropped),
            "I3_detected": not hole_i3["ok"],
            "I3_violations": hole_i3["violations"],
        },
    })
