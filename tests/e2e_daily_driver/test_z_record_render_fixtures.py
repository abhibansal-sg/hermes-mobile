"""QA-1 A9 — record the render-conformance fixtures (wire + render gated together).

The structural gap QA-1 closes: every E2E scenario drove the relay protocol
with this Python phone-driver — nothing exercised the iOS render lane
(RelayItemStore -> ChatStore -> view state). The render gate
(apps/ios/HermesMobileTests/RenderConformanceTests.swift) replays REAL relay
frame streams through the iOS render lane and asserts render-model
invariants. THIS scenario records those frame streams — it reuses the exact
same harness (mock gateway + real relay subprocess + phone driver), driving
the same deterministic scripts as scenarios (a)-(d) and dumping the phone's
verbatim downstream frame log as committed fixtures under
``tests/render_conformance/fixtures/``.

Byte-stability: fixed session ids, fixed gate request ids, deterministic
mock scripts, and a fresh relay process per test (dense seqs from 1). The
tasklist script's one random id (``todo-<hex>``) is normalized on write.
Re-running this scenario refreshes the recording (e.g. after the relay gains
the relay-synthesized ``userMessage`` item — the fixture then carries it and
the XCTest echo-reconciliation invariant exercises the full path).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from phone_driver import render_fixture, write_render_fixture

pytestmark = pytest.mark.asyncio

_HERE = Path(__file__).resolve().parent
FIXTURE_DIR = _HERE.parent / "render_conformance" / "fixtures"

# Fixed session ids so reframer-derived item ids are deterministic.
SID_STREAM = "render-sess-stream"
SID_APPROVAL = "render-sess-approval"
SID_CLARIFY = "render-sess-clarify"
SID_TASKLIST = "render-sess-tasklist"


def _seed_session(gw, *, sid: str, script: str, history=None, **kwargs):
    """Create a session with a FIXED sid directly on the in-process mock
    gateway (create_scripted_session mints a random sid, which would churn
    every recorded item_id)."""
    from mock_gateway.server import MockSession, Script

    sess = MockSession(sid=sid, title=script, script=Script(name=script, kwargs=dict(kwargs)))
    sess.history = list(history or [])
    gw.sessions[sid] = sess
    return sess


async def test_record_submit_stream_fixture(mock_gateway, phone_factory, evidence):
    """Scenario (a) shape: submit -> stream -> completed, on top of a cached
    two-turn history (the B6/B7 history-preservation fixture)."""
    cached = [
        {"role": "user", "content": "Earlier question, first turn."},
        {"role": "assistant", "content": "Earlier answer, first turn."},
        {"role": "user", "content": "Earlier question, second turn."},
        {"role": "assistant", "content": "Earlier answer, second turn."},
    ]
    _seed_session(
        mock_gateway, sid=SID_STREAM, script="simple", history=cached,
        text="Paris is the capital of France.",
    )
    phone = await phone_factory()

    # The relay `open` RPC returns the REST history in its RESULT — record it
    # (qa1/base discards it; the contract says the relay path seeds from it).
    opened = await phone.open_session(SID_STREAM)
    open_messages = (opened.get("result") or {}).get("messages") or []

    prompt = "What is the capital of France?"
    res = await phone.submit(text=prompt, session_id=SID_STREAM,
                         client_message_id="render-cmid-stream")
    assert "result" in res, f"submit failed: {res}"
    await phone.wait_for(
        "item.completed", sid=SID_STREAM, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "agentMessage",
    )
    await phone.wait_for("turn.completed", sid=SID_STREAM, timeout=5.0)

    agent_text = "Paris is the capital of France."
    fixture = render_fixture(
        phone,
        name="render_submit_stream",
        session_id=SID_STREAM,
        description=(
            "Existing-session turn on top of a cached two-turn history: "
            "submit -> turn.started -> agentMessage started/delta*/completed "
            "-> usage/turn.completed. The render lane must keep the cached "
            "history painted, echo the user prompt, and stream the reply "
            "below it (spec B5/B6/B7, A2)."
        ),
        submit={"text": prompt, "session_id": SID_STREAM,
                "client_message_id": "render-cmid-stream"},
        cached_history=cached,
        open_result_messages=open_messages,
        settled={"agent_text": agent_text, "user_prompt": prompt},
    )
    write_render_fixture(fixture, FIXTURE_DIR / "render_submit_stream.json")
    evidence("z-fixture-submit-stream", {
        "frames": len(fixture["frames"]),
        "kinds": sorted({f["kind"] for f in fixture["frames"]}),
        "open_result_messages": len(open_messages),
    })


async def test_record_approval_gate_fixture(mock_gateway, phone_factory, evidence):
    """Scenario (b) shape: tool run blocks on approval.request; the phone
    answers over the relay; the turn completes (spec B10, A3)."""
    cached = [
        {"role": "user", "content": "Please run the build cleanup."},
        {"role": "assistant", "content": "On it."},
    ]
    _seed_session(
        mock_gateway, sid=SID_APPROVAL, script="approval", history=cached,
        request_id="appr-render-1",
        title="Run tool?",
        description="Proceed with the build cleanup?",
    )
    phone = await phone_factory()
    prompt = "Run the cleanup now."
    res = await phone.submit(text=prompt, session_id=SID_APPROVAL,
                         client_message_id="render-cmid-approval")
    assert "result" in res, f"submit failed: {res}"

    gate = await phone.wait_for("approval.request", sid=SID_APPROVAL, timeout=15.0)
    assert gate.body.get("request_id") == "appr-render-1"
    ans = await phone.approve(
        session_id=SID_APPROVAL, request_id="appr-render-1", decision="once",
    )
    assert "result" in ans, f"approve failed: {ans}"
    await phone.wait_for("turn.completed", sid=SID_APPROVAL, timeout=15.0)

    fixture = render_fixture(
        phone,
        name="render_approval_gate",
        session_id=SID_APPROVAL,
        description=(
            "Mid-turn approval gate: agent streams, approval.request lands "
            "(request_id appr-render-1), the phone answers once over the "
            "relay, the turn completes. The render lane must produce the "
            "interactive approval card model (pendingApproval + dock "
            ".approval) and round-trip the answer over the relay transport "
            "(spec B10, A3)."
        ),
        submit={"text": prompt, "session_id": SID_APPROVAL,
                "client_message_id": "render-cmid-approval"},
        cached_history=cached,
        settled={"user_prompt": prompt, "answer": "once",
                 "request_id": "appr-render-1"},
    )
    write_render_fixture(fixture, FIXTURE_DIR / "render_approval_gate.json")
    evidence("z-fixture-approval", {
        "frames": len(fixture["frames"]),
        "kinds": sorted({f["kind"] for f in fixture["frames"]}),
    })


async def test_record_clarify_gate_fixture(mock_gateway, phone_factory, evidence):
    """Scenario (c) shape: clarify.request with choices; the phone answers
    over the relay; the agent echoes the choice and completes (spec B10, A3)."""
    _seed_session(
        mock_gateway, sid=SID_CLARIFY, script="clarify",
        request_id="clar-render-1",
        question="Do you like the clarifications UI?",
        choices=["yes", "no", "later"],
    )
    phone = await phone_factory()
    prompt = "Set up the deploy."
    res = await phone.submit(text=prompt, session_id=SID_CLARIFY,
                         client_message_id="render-cmid-clarify")
    assert "result" in res, f"submit failed: {res}"

    gate = await phone.wait_for("clarify.request", sid=SID_CLARIFY, timeout=15.0)
    assert gate.body.get("request_id") == "clar-render-1"
    assert gate.body.get("choices") == ["yes", "no", "later"]
    ans = await phone.clarify(
        session_id=SID_CLARIFY, request_id="clar-render-1", text="yes",
    )
    assert "result" in ans, f"clarify failed: {ans}"
    await phone.wait_for("turn.completed", sid=SID_CLARIFY, timeout=15.0)

    fixture = render_fixture(
        phone,
        name="render_clarify_gate",
        session_id=SID_CLARIFY,
        description=(
            "Mid-turn clarify gate: clarify.request lands with question + "
            "choices (request_id clar-render-1), the phone answers over the "
            "relay, the turn settles. The render lane must produce the "
            "interactive clarification card model (pendingClarification + "
            "dock .clarify) and round-trip the answer over the relay "
            "transport (spec B10, A3)."
        ),
        submit={"text": prompt, "session_id": SID_CLARIFY,
                "client_message_id": "render-cmid-clarify"},
        cached_history=[],
        settled={"user_prompt": prompt, "answer": "yes",
                 "request_id": "clar-render-1"},
    )
    write_render_fixture(fixture, FIXTURE_DIR / "render_clarify_gate.json")
    evidence("z-fixture-clarify", {
        "frames": len(fixture["frames"]),
        "kinds": sorted({f["kind"] for f in fixture["frames"]}),
    })


async def test_record_tasklist_fixture(mock_gateway, phone_factory, evidence):
    """Scenario (d) shape: the todo tool's taskList lifecycle (started ->
    delta-replace -> completed) — the dock task-box accessor (spec A3/A4)."""
    _seed_session(mock_gateway, sid=SID_TASKLIST, script="tasklist")
    phone = await phone_factory()
    prompt = "Do the three things."
    res = await phone.submit(text=prompt, session_id=SID_TASKLIST,
                         client_message_id="render-cmid-tasklist")
    assert "result" in res, f"submit failed: {res}"
    await phone.wait_for(
        "item.completed", sid=SID_TASKLIST, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "taskList",
    )
    await phone.wait_for("turn.completed", sid=SID_TASKLIST, timeout=15.0)

    fixture = render_fixture(
        phone,
        name="render_tasklist",
        session_id=SID_TASKLIST,
        description=(
            "Task-list lifecycle: the todo tool projects to the dedicated "
            "taskList item (started -> full-list-replace delta -> completed). "
            "The render lane must surface it on the SAME dock accessor the "
            "Turn Dock's task box reads (latestTodoList) and resolve the dock "
            "to .tasks (spec A3/A4)."
        ),
        submit={"text": prompt, "session_id": SID_TASKLIST,
                "client_message_id": "render-cmid-tasklist"},
        cached_history=[],
        settled={"user_prompt": prompt, "tasks": 3},
    )
    # The tasklist script mints one random tool id (todo-<hex>); normalize it
    # so the committed fixture is byte-stable across recordings.
    write_render_fixture(
        fixture, FIXTURE_DIR / "render_tasklist.json",
        sanitize=lambda text: re.sub(r"todo-[0-9a-f]{6}", "todo-fixture1", text),
    )
    evidence("z-fixture-tasklist", {
        "frames": len(fixture["frames"]),
        "kinds": sorted({f["kind"] for f in fixture["frames"]}),
        "tasklist_items": [
            f["seq"] for f in fixture["frames"]
            if (f.get("body") or {}).get("type") == "taskList"
        ],
    })
