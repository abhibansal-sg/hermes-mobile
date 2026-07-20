"""Scenario (h) — QA-1 B10 / A3: clarify + approval interactive gates, full
round-trip driven with the EXACT iOS wire shapes, asserting the turn SETTLES.

Build 114 device QA (B10): the agent asked a clarify question; the phone showed
only a spinner row forever — no interactive card. The wire always decoded
(conformance proved it); the gap was render-side on the phone. This scenario is
the wire-half of the A3 regression gate, complementary to the render-level
XCTest (`RelayGateBridgeTests` + `tests/render_conformance`): it proves that the
frames the phone's card view-models bind to (a) arrive with EVERY field the iOS
`ClarifyRequestPayload` / `ApprovalRequestPayload` initializers read, (b) an
answer sent with the byte-exact iOS `RelayClient` params unblocks the agent, and
(c) the turn then SETTLES (`turn.completed`) — the owner's "Still thinking
forever" cannot recur silently.

Extends scenarios (b)/(c): those assert the round-trip proceeds; this one
additionally pins the downstream body contract the SwiftUI cards render, drives
the upstream with the precise iOS param sets (approve omits ``all`` when false;
clarify sends ``session_id``+``text``+``request_id``), waits for
``turn.completed``, and RECORDS the gate frames for the render-conformance
fixture set (QA1 evidence dir).

Isolated gateway only (mock scripted gateway + real relay subprocess via the
harness fixtures) — never the live 9119.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import pytest

pytestmark = pytest.mark.asyncio

QA1_EVIDENCE = Path("/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver-qa1/b10-cards")
RECORDED_FRAMES = QA1_EVIDENCE / "recorded_frames.json"


def _record_frame(name: str, frame: Any) -> None:
    """Append one recorded downstream frame to the QA1 render-fixture set."""
    QA1_EVIDENCE.mkdir(parents=True, exist_ok=True)
    recorded: dict[str, Any] = {}
    if RECORDED_FRAMES.exists():
        try:
            recorded = json.loads(RECORDED_FRAMES.read_text())
        except (ValueError, OSError):
            recorded = {}
    recorded[name] = {
        "seq": frame.seq, "sid": frame.sid, "turn": frame.turn,
        "kind": frame.kind, "body": frame.body,
    }
    RECORDED_FRAMES.write_text(json.dumps(recorded, indent=2, sort_keys=True))


async def test_clarify_gate_ios_shape_round_trip_settles_turn(
    mock_gateway, phone_factory, evidence
):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(
        mock_gateway, script="clarify",
        question="Do you like the clarifications UI?",
        choices=["yes", "no", "later"],
        request_id="qa1-clar-1",
    )
    phone = await phone_factory()
    res = await phone.submit(text="hello", session_id=sid)
    driven_sid = res["result"]["session_id"]

    # (a) The frame body carries EVERY field the iOS ClarifyRequestPayload reads —
    # these are the card view-model inputs that rendered nothing in build 114.
    clarify = await phone.wait_for("clarify.request", sid=driven_sid, timeout=15.0)
    _record_frame("clarify.request", clarify)
    assert clarify.body.get("question") == "Do you like the clarifications UI?"
    assert clarify.body.get("choices") == ["yes", "no", "later"]
    assert clarify.body.get("request_id") == "qa1-clar-1"
    assert clarify.sid == driven_sid, "the card binds to the frame's session id"

    # (b) Answer with the byte-exact iOS RelayClient.clarify params
    # ({session_id, text} + request_id when non-empty — no other keys).
    answer = await phone._call("clarify", {
        "session_id": driven_sid,
        "text": "yes",
        "request_id": "qa1-clar-1",
    })
    assert "result" in answer, f"clarify failed: {answer}"

    # The agent unblocks and echoes the answer back (non-empty-answer guard,
    # mirrors scenario c).
    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    completed_text = phone.item_body(completed).get("text", "")
    assert "yes" in completed_text, f"answer did not arrive: {completed_text!r}"

    # (c) The turn SETTLES — the owner's "Still thinking forever" was a turn
    # that never completed after the unanswered gate. turn.completed is also the
    # frame the iOS bridge uses to expire the card (stale-card guard).
    settled = await phone.wait_for("turn.completed", sid=driven_sid, timeout=15.0)
    _record_frame("turn.completed", settled)

    # White-box: the gateway saw answer="yes" routed by request_id.
    rsp = next(
        (r for r in mock_gateway.respond_log
         if r["kind"] == "clarify" and r["session_id"] == driven_sid),
        None,
    )
    assert rsp is not None, "gateway never saw a clarify.respond"
    assert rsp["answer"] == "yes"
    assert rsp["request_id"] == "qa1-clar-1"

    evidence("h-clarify-ios-shape-roundtrip", {
        "session_id": driven_sid,
        "request_id": "qa1-clar-1",
        "gateway_saw_answer": rsp["answer"],
        "completed_text": completed_text,
        "turn_completed_seq": settled.seq,
    })


async def test_approval_gate_ios_shape_round_trip_settles_turn(
    mock_gateway, phone_factory, evidence
):
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(
        mock_gateway, script="approval",
        title="Run tool?",
        description="rm -rf build/",
        request_id="qa1-appr-1",
    )
    phone = await phone_factory()
    res = await phone.submit(text="Run the build step", session_id=sid)
    driven_sid = res["result"]["session_id"]

    # (a) The frame body carries the fields the iOS ApprovalRequestPayload reads
    # (command → card title fallback, description, request_id, choices).
    approval = await phone.wait_for("approval.request", sid=driven_sid, timeout=15.0)
    _record_frame("approval.request", approval)
    assert approval.body.get("command"), f"missing command: {approval.body}"
    assert approval.body.get("description") == "rm -rf build/"
    assert approval.body.get("request_id") == "qa1-appr-1"
    assert approval.body.get("choices"), f"missing choices: {approval.body}"
    assert approval.sid == driven_sid

    pre_deltas = phone.frames_of_kind("item.delta", sid=driven_sid)
    assert pre_deltas, "expected the pre-gate delta"

    # (b) Answer with the byte-exact iOS RelayClient.approve params: session_id
    # + decision (+ request_id when non-empty). `all` is OMITTED when false —
    # exactly as the iOS builder does (RelayClient.approve resolveAll: false).
    answer = await phone._call("approve", {
        "session_id": driven_sid,
        "decision": "once",
        "request_id": "qa1-appr-1",
    })
    assert "result" in answer, f"approve failed: {answer}"

    # The turn RESUMES past the gate (the silent-deny failure mode: no frames
    # after the answer).
    completed = await phone.wait_for(
        "item.completed", sid=driven_sid, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    _record_frame("approval.item.completed", completed)

    # (c) Turn settles.
    settled = await phone.wait_for("turn.completed", sid=driven_sid, timeout=15.0)
    _record_frame("approval.turn.completed", settled)

    # White-box: the relay mapped decision→choice (the silent-deny bug was the
    # relay forwarding the wrong key; the gateway defaults choice to DENY).
    rsp = next(
        (r for r in mock_gateway.respond_log
         if r["kind"] == "approval" and r["session_id"] == driven_sid),
        None,
    )
    assert rsp is not None, "gateway never saw an approval.respond"
    assert rsp["choice"] == "once", f"relay forwarded choice={rsp['choice']!r}"
    assert rsp["request_id"] == "qa1-appr-1"

    evidence("h-approval-ios-shape-roundtrip", {
        "session_id": driven_sid,
        "request_id": "qa1-appr-1",
        "gateway_saw_choice": rsp["choice"],
        "turn_completed_seq": settled.seq,
    })
