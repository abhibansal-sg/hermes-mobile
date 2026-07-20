"""Scenario (b) — approval round-trip proceeds, never silent-deny (A5).

The Wave-2.5 protocol bug that drove this acceptance: a relay that sent
``decision`` to a gateway that read ``choice`` silently denied EVERY phone
approval. The ratified fix (RELAY-PHONE-PROTOCOL.md §5) maps
``decision``→``choice`` at the relay, so an approve answer actually proceeds.

This test asserts the round-trip end-to-end:

* gateway emits ``approval.request`` mid-turn;
* the relay forwards it as a ``approval.request`` frame to the phone;
* the phone answers ``approve(decision=once)``;
* the gateway unblocks and the turn STREAMS AGAIN (more deltas + completed).

If the relay regressed to the silent-deny shape, the second delta batch would
never arrive and the test would time out — exactly the failure mode A5 closes.
"""

from __future__ import annotations

import asyncio

import pytest

pytestmark = pytest.mark.asyncio


async def test_approval_roundtrip_proceeds(mock_gateway, phone_factory, evidence):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(mock_gateway, script="approval")
    phone = await phone_factory()

    res = await phone.submit(text="Run the build step", session_id=sid)
    driven_sid = res["result"]["session_id"]

    # The approval frame must reach the phone (the reframer passes it through).
    approval = await phone.wait_for(
        "approval.request", sid=driven_sid, timeout=15.0,
    )
    request_id = approval.body.get("request_id")
    assert request_id, f"approval.request missing request_id: {approval.body}"

    # Before the answer, only the first delta has streamed.
    pre_deltas = phone.frames_of_kind("item.delta", sid=driven_sid)
    assert pre_deltas, "expected at least one pre-approval delta"

    # Phone answers — decision=once (the iOS RelayUpstreamMethod.approve shape).
    # The relay maps decision->choice per §5. The mock gateway records the
    # resolved choice and unblocks the script.
    answer = await phone.approve(
        session_id=driven_sid, request_id=request_id, decision="once",
    )
    assert "result" in answer, f"approve failed: {answer}"

    # The turn must RESUME — more deltas + completed arrive. This is the
    # behavior that breaks under silent-deny: the gateway drops the turn on a
    # default-deny and no further frames ever arrive.
    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    completed_text = phone.item_body(completed).get("text", "")
    assert "Done" in completed_text or "run the tool" in completed_text, (
        f"approval did not proceed: completed_text={completed_text!r}"
    )

    # White-box: the mock gateway saw the relay forward choice=once (NOT a
    # default-deny). This is the structurally-impossible-to-silent-deny check.
    rsp = next(
        (r for r in mock_gateway.respond_log
         if r["kind"] == "approval" and r["session_id"] == driven_sid),
        None,
    )
    assert rsp is not None, "gateway never saw an approval.respond"
    assert rsp["choice"] == "once", (
        f"relay forwarded choice={rsp['choice']!r} — silent-deny regression"
    )

    evidence("b-approval-roundtrip", {
        "session_id": driven_sid,
        "request_id": request_id,
        "gateway_saw_choice": rsp["choice"],
        "completed_text": completed_text,
        "post_approval_delta_count": (
            len(phone.frames_of_kind("item.delta", sid=driven_sid)) - len(pre_deltas)
        ),
    })
