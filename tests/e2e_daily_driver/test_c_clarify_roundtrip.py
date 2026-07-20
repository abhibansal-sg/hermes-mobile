"""Scenario (c) — clarify round-trip non-empty (A5).

The mirror of the Wave-2.5 silent-bug for clarify: a relay that sent ``text``
to a gateway that read ``answer`` delivered an EMPTY answer to the blocked
agent. The ratified fix (RELAY-PHONE-PROTOCOL.md §5) maps ``text``→``answer``
at the relay, so the user's choice actually reaches the agent.

This test asserts the round-trip end-to-end:

* gateway emits ``clarify.request`` mid-turn;
* the relay forwards it as a ``clarify.request`` frame to the phone;
* the phone answers ``clarify(text="green")``;
* the gateway unblocks and the turn completes with the answer echoed back.

If the relay regressed to the empty-answer shape, the completed text would NOT
contain "green" — exactly the failure mode A5 closes.
"""

from __future__ import annotations

import pytest

pytestmark = pytest.mark.asyncio


async def test_clarify_roundtrip_non_empty(mock_gateway, phone_factory, evidence):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(mock_gateway, script="clarify")
    phone = await phone_factory()

    res = await phone.submit(text="Pick a color", session_id=sid)
    driven_sid = res["result"]["session_id"]

    clarify = await phone.wait_for("clarify.request", sid=driven_sid, timeout=15.0)
    request_id = clarify.body.get("request_id")
    assert request_id, f"clarify.request missing request_id: {clarify.body}"

    # Phone answers — text="green" (the iOS RelayUpstreamMethod.clarify shape).
    # The relay maps text->answer per §5.
    answer = await phone.clarify(
        session_id=driven_sid, request_id=request_id, text="green",
    )
    assert "result" in answer, f"clarify failed: {answer}"

    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    completed_text = phone.item_body(completed).get("text", "")

    # The agent echoed the answer back — proves the answer was NOT empty.
    assert "green" in completed_text, (
        f"clarify answer did not arrive: completed_text={completed_text!r}"
    )

    # White-box: the mock gateway saw the relay forward answer="green" (NOT an
    # empty string). This is the structurally-impossible-to-empty-deliver check.
    rsp = next(
        (r for r in mock_gateway.respond_log
         if r["kind"] == "clarify" and r["session_id"] == driven_sid),
        None,
    )
    assert rsp is not None, "gateway never saw a clarify.respond"
    assert rsp["answer"] == "green", (
        f"relay forwarded answer={rsp['answer']!r} — empty-answer regression"
    )

    evidence("c-clarify-roundtrip", {
        "session_id": driven_sid,
        "request_id": request_id,
        "gateway_saw_answer": rsp["answer"],
        "completed_text": completed_text,
    })
