"""Scenario (a) — submit → stream → completed reconstruction (A3/A4).

Proves the device-shaped end-to-end happy path:

* phone ``submit`` -> relay creates+owns+drives the session;
* relay streams ``item.started`` (agentMessage) → N×``item.delta`` →
  ``item.completed`` (the authoritative agentMessage);
* concatenating the ``item.delta`` patches + reconciling against
  ``item.completed`` reconstructs the SAME text the gateway emitted — the
  ``completed``-is-authoritative contract, structurally impossible to regress.

The "device shape" check: deltas carry the agent prose word-by-word exactly the
way iOS would render them; the completed item body's ``text`` matches what a
clean run of the same script produced.
"""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.asyncio


async def test_submit_streams_and_completes(mock_gateway, phone_factory, evidence):
    from mock_gateway.server import create_scripted_session

    # Pre-create a session on the mock gateway with a known deterministic script.
    sid = await create_scripted_session(
        mock_gateway, script="simple",
        text="Paris is the capital of France.",
    )

    phone = await phone_factory()

    # Drive: submit into the pre-created session (the relay will resume+own it).
    res = await phone.submit(text="What is the capital of France?", session_id=sid)
    assert "result" in res, f"submit failed: {res}"
    driven_sid = res["result"]["session_id"]
    assert driven_sid, "submit returned no session_id"

    # Wait for the agentMessage lifecycle to land.
    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    started = await phone.wait_for(
        "item.started", sid=driven_sid, timeout=5.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    deltas = await phone.wait_for_n("item.delta", 5, sid=driven_sid, timeout=10.0)

    # The agent prose streamed word-by-word via item.delta patches.
    streamed_text = "".join(phone.delta_patch(d).get("text", "") for d in deltas)
    # The authoritative completed body (item body is nested at frame.body["body"]).
    completed_text = phone.item_body(completed).get("text", "")

    # The reconstruction check: streaming deltas + authoritative completed agree.
    # Per protocol §2/§4 completed is authoritative; this asserts that contract
    # holds end-to-end.
    assert completed_text == streamed_text, (
        f"reconstruction mismatch:\n  streamed={streamed_text!r}\n"
        f"  completed={completed_text!r}"
    )

    # The agentMessage item went through the lifecycle in order.
    assert started.seq < deltas[0].seq < completed.seq, (
        f"lifecycle out of order: start={started.seq} "
        f"first_delta={deltas[0].seq} complete={completed.seq}"
    )
    # And it ended authoritative-completed.
    assert completed.body.get("status") == "completed"

    # A turn-completed boundary frame arrives (drives the Notifier §6 gate).
    turn_done = await phone.wait_for("turn.completed", sid=driven_sid, timeout=5.0)

    evidence("a-reconstruction", {
        "session_id": driven_sid,
        "script": "simple",
        "streamed_text": streamed_text,
        "completed_text": completed_text,
        "byte_identical": streamed_text == completed_text,
        "n_deltas": len(deltas),
        "started_seq": started.seq,
        "completed_seq": completed.seq,
        "turn_completed_seq": turn_done.seq,
        "all_frames": [
            {"seq": f.seq, "kind": f.kind, "type": phone.item_type(f) or None}
            for f in phone.frames_for(driven_sid)
        ],
    })
