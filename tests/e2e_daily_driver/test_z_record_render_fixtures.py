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

import asyncio
import re
import time
from pathlib import Path
from typing import Any

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


# ---------------------------------------------------------------------------
# QA-3 (round-3 device QA, build 116) incident fixtures — S2/S4/S6/S8/S11.
#
# The round-3 bugs are ORDERING / LIVENESS / SCOPING shaped — they live in the
# frames' ARRIVAL TIMES and the driver's local actions (session switches, a
# New-Chat entry that has NO wire frame), which the QA-1/QA-2 fixtures (raw
# arrival-ordered envelopes) discarded. These recordings extend the SAME
# harness (mock gateway + real relay subprocess + phone driver) with:
#
#   * per-frame ``t_ms`` (arrival time on a shared clock) —
#     ``render_fixture(..., timing=True)``;
#   * a ``script`` of the driver's local actions (``switch_to`` / ``resync`` /
#     ``enter_draft``) with ``at_t_ms``;
#   * ``extra_sessions`` for the switched-to session's stream (S6).
#
# All extensions are ADDITIVE: the five QA-1/QA-2 fixtures above re-record
# byte-identically (no new keys), and the XCTest loader ignores absent keys —
# the format stays backward-compatible with the existing render_conformance.
# The ordering lane (S4/S6/S7), the liveness lane (S8) and the working lane's
# own S2 test consume these; see tests/render_conformance/README.md.
# ---------------------------------------------------------------------------

SID_QA3_DELAY = "render-sess-qa3-delay"
SID_QA3_REORDER = "render-sess-qa3-reorder"
SID_QA3_SWITCH_A = "render-sess-qa3-switch-a"
SID_QA3_SWITCH_B = "render-sess-qa3-switch-b"
SID_QA3_DEAD = "render-sess-qa3-dead"
SID_QA3_INTERLEAVE = "render-sess-qa3-interleave"


async def test_record_qa3_delayed_start_fixture(mock_gateway, phone_factory, evidence):
    """S2 (P0): submit, then SILENCE until the first agent frame ~1.5 s later
    (deterministic stand-in for the ~35 s model time-to-first-item of
    IMG_2578). The relay synthesizes the userMessage item at SUBMIT, so the
    phone sees the echoed user item instantly and nothing else until
    turn.started lands — the recorded ``t_ms`` gap is the incident. The
    XCTest side replays this with the frames artificially WITHHELD (an
    infinite delay — the stronger A1 assertion): the merged labeled+timed
    working line must render at send from local state."""
    cached = [
        {"role": "user", "content": "Earlier question about the proxy."},
        {"role": "assistant", "content": "Earlier answer about the proxy."},
    ]
    _seed_session(
        mock_gateway, sid=SID_QA3_DELAY, script="delayed_first", history=cached,
        first_item_delay_s=1.5,
        text="The proxy transform is optimal given its inputs.",
    )
    phone = await phone_factory()
    opened = await phone.open_session(SID_QA3_DELAY)
    open_messages = (opened.get("result") or {}).get("messages") or []

    prompt = "Review how the proxy transforms messages."
    res = await phone.submit(text=prompt, session_id=SID_QA3_DELAY,
                             client_message_id="render-cmid-qa3-delay")
    assert "result" in res, f"submit failed: {res}"
    await phone.wait_for("turn.completed", sid=SID_QA3_DELAY, timeout=20.0)

    fixture = render_fixture(
        phone,
        name="render_qa3_delayed_start",
        session_id=SID_QA3_DELAY,
        description=(
            "S2 incident: submit -> userMessage item (synthesized at submit) "
            "-> ~1.5 s of SILENCE -> turn.started -> agentMessage stream -> "
            "turn.completed. The labeled working affordance must render at "
            "SEND (local state), not with the late first frame (build 116 "
            "showed it already reading 35s — IMG_2578). Per-frame t_ms "
            "captures the gap; the XCTest withholds the frames entirely."
        ),
        submit={"text": prompt, "session_id": SID_QA3_DELAY,
                "client_message_id": "render-cmid-qa3-delay"},
        cached_history=cached,
        open_result_messages=open_messages,
        settled={"agent_text": "The proxy transform is optimal given its inputs.",
                 "user_prompt": prompt},
        timing=True,
    )
    # The incident shape: userMessage FIRST, then a real silence gap before
    # turn.started (the harness slept 1.5 s; assert the recording captured it).
    kinds = [f["kind"] for f in fixture["frames"]]
    first_item = next(f for f in fixture["frames"] if f["kind"].startswith("item."))
    assert (first_item.get("body") or {}).get("type") == "userMessage", \
        "the relay synthesizes the userMessage item at submit, before turn.started"
    started = next(f for f in fixture["frames"] if f["kind"] == "turn.started")
    gap_ms = started["t_ms"] - first_item["t_ms"]
    assert gap_ms >= 900, f"the recording must capture the late-first-item silence (got {gap_ms}ms)"
    write_render_fixture(fixture, FIXTURE_DIR / "render_qa3_delayed_start.json")
    evidence("z-fixture-qa3-delayed-start", {
        "frames": len(fixture["frames"]),
        "kinds": sorted(set(kinds)),
        "usermessage_to_turnstarted_gap_ms": gap_ms,
    })


async def test_record_qa3_reconnect_reorder_fixture(mock_gateway, phone_factory, evidence):
    """S4 (P0): two settled turns observed by the relay, then a RECONNECT —
    a fresh socket whose ``resync(last_seq=0)`` makes the relay re-deliver a
    snapshot/replay of ALL accumulated items (U1,A1,U2,A2) at once. On device
    (relay.log WS re-opens 10:46:31/10:47:18), that cumulative re-projection
    landed on top of GRDB-cache-painted UNTAGGED assistant rows the merge
    never consumed → the answer-above-its-prompt duplicate of IMG_2579-2582.
    The fixture records what the reconnected phone actually sees: the
    cumulative redelivery PLUS a live third turn submitted on the new socket.
    The ordering lane replays it over an untagged cache paint and asserts
    single-copy strict chronology."""
    cached = [
        {"role": "user", "content": "First question, first turn."},
        {"role": "assistant", "content": "First answer, first turn."},
        {"role": "user", "content": "Second question, second turn."},
        {"role": "assistant", "content": "Second answer, second turn."},
    ]
    _seed_session(
        mock_gateway, sid=SID_QA3_REORDER, script="simple", history=cached,
        text="Third answer, third turn.",
    )
    phone1 = await phone_factory()
    r1 = await phone1.submit(text="First question, first turn.",
                             session_id=SID_QA3_REORDER,
                             client_message_id="render-cmid-qa3-reorder-1")
    assert "result" in r1, f"submit t1 failed: {r1}"
    await phone1.wait_for("turn.completed", sid=SID_QA3_REORDER, timeout=15.0)
    r2 = await phone1.submit(text="Second question, second turn.",
                             session_id=SID_QA3_REORDER,
                             client_message_id="render-cmid-qa3-reorder-2")
    assert "result" in r2, f"submit t2 failed: {r2}"
    await phone1.wait_for("turn.completed", sid=SID_QA3_REORDER, timeout=15.0,
                          predicate=lambda f: f.seq > phone1.frames_of_kind(
                              "turn.completed", sid=SID_QA3_REORDER)[0].seq)

    # RECONNECT: a brand-new socket (the IMG_2579 flap). The phone persists
    # its acked watermark across sockets, so it resyncs with last_seq=5 — a
    # seq THIS connection never stamped (its head is 0). The relay's per-
    # connection seq spine cannot replay a foreign watermark, so it takes the
    # reconnect path: a fresh per-session SNAPSHOT of every accumulated item
    # the store observed (U1,A1,U2,A2) — the exact cumulative re-projection
    # that landed on the device. Then the phone drives turn 3 on the socket.
    phone2 = await phone_factory()
    opened = await phone2.open_session(SID_QA3_REORDER)
    open_messages = (opened.get("result") or {}).get("messages") or []
    await phone2.resync(5)
    # The redelivery arrives as a `snapshot` frame (accumulated items), not
    # as the original item.* stream.
    await phone2.wait_for("snapshot", sid=SID_QA3_REORDER, timeout=10.0)
    r3 = await phone2.submit(text="Third question, third turn.",
                             session_id=SID_QA3_REORDER,
                             client_message_id="render-cmid-qa3-reorder-3")
    assert "result" in r3, f"submit t3 failed: {r3}"
    await phone2.wait_for("turn.completed", sid=SID_QA3_REORDER, timeout=15.0)

    prompt = "Third question, third turn."
    fixture = render_fixture(
        phone2,
        name="render_qa3_reconnect_reorder",
        session_id=SID_QA3_REORDER,
        description=(
            "S4 incident: a RECONNECTED socket resyncs and the relay "
            "re-delivers ALL accumulated items (two settled turns: U1,A1,"
            "U2,A2) cumulatively, then the phone drives a third turn. On "
            "device this cumulative re-projection landed on top of "
            "GRDB-cache-painted untagged assistant rows the merge never "
            "consumed -> the duplicated answer ABOVE its prompt "
            "(IMG_2579-2582). The ordering lane seeds the untagged cache "
            "paint (cached_history), replays the redelivery + live turn, and "
            "asserts single-copy strict chronological order. Per-frame t_ms "
            "separates the redelivery burst from the live turn."
        ),
        submit={"text": prompt, "session_id": SID_QA3_REORDER,
                "client_message_id": "render-cmid-qa3-reorder-3"},
        cached_history=cached,
        open_result_messages=open_messages,
        settled={"agent_text": "Third answer, third turn.",
                 "user_prompt": prompt,
                 "turns_redelivered": 2},
        timing=True,
        script_steps=[
            {"action": "open", "session_id": SID_QA3_REORDER, "at_t_ms": 0},
            {"action": "resync", "last_seq": 5},
            {"action": "submit", "session_id": SID_QA3_REORDER,
             "client_message_id": "render-cmid-qa3-reorder-3"},
        ],
    )
    kinds = sorted({f["kind"] for f in fixture["frames"]})
    write_render_fixture(fixture, FIXTURE_DIR / "render_qa3_reconnect_reorder.json")
    evidence("z-fixture-qa3-reconnect-reorder", {
        "frames": len(fixture["frames"]),
        "kinds": kinds,
        "usermessage_items": sum(
            1 for f in fixture["frames"]
            if (f.get("body") or {}).get("type") == "userMessage"),
    })


async def test_record_qa3_session_switch_fixture(mock_gateway, phone_factory, evidence):
    """S6 (P0): a turn goes live in session A, the user switches to session B
    mid-turn, then returns to A while it is still streaming (relay.log
    11:25:28 WS open inside a 5 s-young turn — IMG_2585's vanished prompt).
    The frames for A keep flowing across the switch (the relay fans out by
    sid; only push suppression keys off foreground), and the ``script``
    records the switch-away/return instants on the shared t_ms clock so the
    ordering lane can replay: seed echo -> frames -> switch (store reseeds
    for B) -> return -> remaining frames, asserting the prompt is durable
    across the switch + store rebuild. ``extra_sessions`` carries B's paint
    metadata (an idle session: zero frames)."""
    _seed_session(
        mock_gateway, sid=SID_QA3_SWITCH_A, script="simple",
        delta_delay_s=0.25,
        text="One two three four five six seven eight.",
    )
    cached_b = [
        {"role": "user", "content": "A question in session B."},
        {"role": "assistant", "content": "An answer in session B."},
    ]
    _seed_session(mock_gateway, sid=SID_QA3_SWITCH_B, script="simple",
                  history=cached_b, text="Unused.")
    phone = await phone_factory()
    opened_a = await phone.open_session(SID_QA3_SWITCH_A)
    open_a = (opened_a.get("result") or {}).get("messages") or []

    prompt = "Switch mid-turn prompt."
    res = await phone.submit(text=prompt, session_id=SID_QA3_SWITCH_A,
                             client_message_id="render-cmid-qa3-switch")
    assert "result" in res, f"submit failed: {res}"
    # Mid-stream: three deltas in (~0.75 s), then switch away.
    await phone.wait_for_n("item.delta", 3, sid=SID_QA3_SWITCH_A, timeout=15.0)
    t0 = phone.frames_for(SID_QA3_SWITCH_A)[0].t

    def _ms() -> int:
        return int(round((time.monotonic() - t0) * 1000))

    steps: list[dict[str, Any]] = [{"action": "submit",
                                    "session_id": SID_QA3_SWITCH_A, "at_t_ms": 0}]
    opened_b = await phone.open_session(SID_QA3_SWITCH_B)
    open_b = (opened_b.get("result") or {}).get("messages") or []
    steps.append({"action": "switch_to", "session_id": SID_QA3_SWITCH_B,
                  "at_t_ms": _ms()})
    await asyncio.sleep(0.4)                       # the user reads B a moment
    await phone.open_session(SID_QA3_SWITCH_A)     # return mid-turn
    steps.append({"action": "switch_to", "session_id": SID_QA3_SWITCH_A,
                  "at_t_ms": _ms()})
    await phone.wait_for("turn.completed", sid=SID_QA3_SWITCH_A, timeout=20.0)

    fixture = render_fixture(
        phone,
        name="render_qa3_session_switch",
        session_id=SID_QA3_SWITCH_A,
        description=(
            "S6 incident: turn live in A -> switch to B mid-stream (script "
            "marker) -> 0.4 s -> return to A while still streaming (script "
            "marker) -> turn completes. A's frames flow continuously across "
            "the switch (relay fans out by sid); the markers tell the replay "
            "when the store reseeded for B and back. The ordering lane "
            "asserts the optimistic prompt survives the switch + rebuild "
            "(IMG_2585: prompt vanished, working rows painted without it). "
            "extra_sessions carries B's idle paint (zero frames)."
        ),
        submit={"text": prompt, "session_id": SID_QA3_SWITCH_A,
                "client_message_id": "render-cmid-qa3-switch"},
        cached_history=[],
        open_result_messages=open_a,
        settled={"agent_text": "One two three four five six seven eight.",
                 "user_prompt": prompt},
        timing=True, t0=t0,
        script_steps=steps,
        extra_sessions={
            SID_QA3_SWITCH_B: {
                "cached_history": cached_b,
                "open_result_messages": open_b,
                "submit": None,
            },
        },
    )
    write_render_fixture(fixture, FIXTURE_DIR / "render_qa3_session_switch.json")
    evidence("z-fixture-qa3-session-switch", {
        "frames_a": len(fixture["frames"]),
        "frames_b": len(fixture["extra_sessions"][SID_QA3_SWITCH_B]["frames"]),
        "steps": steps,
    })


async def test_record_qa3_dead_turn_fixture(mock_gateway, phone_factory, evidence):
    """S8 (P0): the turn emits message.start + ONE tool.start and then DIES —
    no tool.complete, no message.complete, ever (the gateway turn died / the
    relay lost the terminal frame after the flap; IMG_2591's eternal double-
    working). The recorder holds through the silence window, then resyncs —
    the relay re-delivers the SAME in-progress items (its store never saw a
    terminal frame), which is exactly the re-arm-by-unrelated-frames trap
    that kept build 116's working rows alive forever. Per-frame t_ms records
    the silence; the fixture carries NO turn.completed (asserted). The
    liveness lane replays it against the per-turn watchdog and asserts a
    silent self-heal within N s."""
    _seed_session(mock_gateway, sid=SID_QA3_DEAD, script="hang_mid_turn",
                  hang_s=2.5)
    phone = await phone_factory()
    await phone.open_session(SID_QA3_DEAD)
    prompt = "Run the test suite."
    res = await phone.submit(text=prompt, session_id=SID_QA3_DEAD,
                             client_message_id="render-cmid-qa3-dead")
    assert "result" in res, f"submit failed: {res}"
    # The tool item starts…
    await phone.wait_for(
        "item.started", sid=SID_QA3_DEAD, timeout=15.0,
        predicate=lambda f: phone.item_type(f) == "toolCall",
    )
    # …and then nothing. Hold past the script's death (2.5 s) so the silence
    # window is part of the recording, then resync like a reconnect would.
    await asyncio.sleep(2.8)
    await phone.resync(0)
    await asyncio.sleep(0.5)                       # let the redelivery land

    fixture = render_fixture(
        phone,
        name="render_qa3_dead_turn",
        session_id=SID_QA3_DEAD,
        description=(
            "S8 incident: submit -> userMessage -> turn.started -> toolCall "
            "item.started -> SILENCE (the turn dies mid-tool; no "
            "tool.complete, no message.complete — none in this fixture, "
            "asserted) -> resync redelivers the SAME in-progress items (the "
            "relay store never saw a terminal frame). This is the eternal "
            "double-working of IMG_2591: per-row isStreaming derives from "
            "item terminality, and the per-store watchdog re-arms on every "
            "redelivery. The liveness lane asserts a per-turn watchdog "
            "self-heals within N s (silent resync + settle, never an error "
            "banner — C3)."
        ),
        submit={"text": prompt, "session_id": SID_QA3_DEAD,
                "client_message_id": "render-cmid-qa3-dead"},
        cached_history=[],
        settled={"completed": False, "user_prompt": prompt},
        timing=True,
        script_steps=[{"action": "resync", "last_seq": 0}],
    )
    assert not any(f["kind"] == "turn.completed" for f in fixture["frames"]), \
        "the dead-turn fixture must carry NO turn.completed — that is the incident"
    write_render_fixture(fixture, FIXTURE_DIR / "render_qa3_dead_turn.json")
    evidence("z-fixture-qa3-dead-turn", {
        "frames": len(fixture["frames"]),
        "kinds": sorted({f["kind"] for f in fixture["frames"]}),
        "last_t_ms": fixture["frames"][-1].get("t_ms"),
    })


async def test_record_qa3_draft_interleave_fixture(mock_gateway, phone_factory, evidence):
    """S11 (P0): session A streams while the user taps New Chat and starts
    typing a DRAFT — which has NO wire frame (startDraft is a local store
    call; that is the bug: it never parks the relay projection, so A's
    frames kept painting into the new-chat view — IMG_2594). The ``script``
    records the draft-entry instant on the t_ms clock; the S11 lane replays
    A's frames, calls the local startDraft at the marker, keeps delivering,
    and asserts the draft timeline stays empty (zero relayProjected rows)
    while A's turn streams on."""
    _seed_session(
        mock_gateway, sid=SID_QA3_INTERLEAVE, script="simple",
        delta_delay_s=0.3,
        text="alpha beta gamma delta epsilon zeta.",
    )
    phone = await phone_factory()
    await phone.open_session(SID_QA3_INTERLEAVE)
    prompt = "Stream while I draft."
    res = await phone.submit(text=prompt, session_id=SID_QA3_INTERLEAVE,
                             client_message_id="render-cmid-qa3-interleave")
    assert "result" in res, f"submit failed: {res}"
    await phone.wait_for_n("item.delta", 2, sid=SID_QA3_INTERLEAVE, timeout=15.0)
    t0 = phone.frames_for(SID_QA3_INTERLEAVE)[0].t
    draft_at = int(round((time.monotonic() - t0) * 1000))
    # The user is now in New Chat typing; A's stream continues to the end.
    await phone.wait_for("turn.completed", sid=SID_QA3_INTERLEAVE, timeout=20.0)

    fixture = render_fixture(
        phone,
        name="render_qa3_draft_interleave",
        session_id=SID_QA3_INTERLEAVE,
        description=(
            "S11 incident: session A streams (per-frame t_ms) while the user "
            "enters New Chat mid-stream (script marker enter_draft — NO wire "
            "frame; startDraft is a local store call that failed to park the "
            " projection) and A's frames keep arriving (IMG_2594: another "
            "session's Working/ToolCall rows painted into the empty new "
            "chat). The S11 lane replays frames to the marker, calls local "
            "startDraft, delivers the rest, and asserts the draft shows zero "
            "relayProjected rows."
        ),
        submit={"text": prompt, "session_id": SID_QA3_INTERLEAVE,
                "client_message_id": "render-cmid-qa3-interleave"},
        cached_history=[],
        settled={"agent_text": "alpha beta gamma delta epsilon zeta.",
                 "user_prompt": prompt},
        timing=True, t0=t0,
        script_steps=[
            {"action": "submit", "session_id": SID_QA3_INTERLEAVE, "at_t_ms": 0},
            {"action": "enter_draft", "at_t_ms": draft_at},
        ],
    )
    write_render_fixture(fixture, FIXTURE_DIR / "render_qa3_draft_interleave.json")
    evidence("z-fixture-qa3-draft-interleave", {
        "frames": len(fixture["frames"]),
        "kinds": sorted({f["kind"] for f in fixture["frames"]}),
        "enter_draft_at_t_ms": draft_at,
    })
