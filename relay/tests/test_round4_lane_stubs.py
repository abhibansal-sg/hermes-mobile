"""R4 W0b — RED-BY-DESIGN stubs for the Wave-1 relay lanes (L1–L4 + L6).

ROUND4-LEAN-PLAN.md Wave 1 lands five additive relay lanes in one deploy; each
stub here is the failing test that lane turns green. Every stub is marked
``xfail(strict=True)``: the suite stays green about itself NOW (the RED state
is expected), and the instant a lane implements the parameter the test XPASSes
— strict mode fails the suite until the implementer REMOVES the marker, making
the red→green flip explicit and unmissable.

Run the RED matrix (real failures exposed) with ``--runxfail``:

    PYTHONPATH=relay pytest relay/tests/test_round4_lane_stubs.py --runxfail

Lane map (plan §b table):

* **L1** — ``LIST`` gains ``order=recent`` / ``cwd_prefix`` / ``exclude_source``
  / ``min_messages`` / ``limit`` pass-through to gateway ``session.list``
  (today: bare ``session_list(limit)``, downstream.py:698-699).
* **L2** — ``SUBMIT`` passes ``truncate_before_user_ordinal`` through (relay
  drops unknown params, DS:720-724); the create branch accepts ``cwd`` (B10
  projects gap); new ``branch`` method = seeded create (B13 dead features).
* **L3** — reframer stamps ``reason: completed|interrupted|error`` on
  ``turn.completed`` (contract I9; today the body carries usage/duration only,
  reframer.py:310-323, and the interrupted status the gateway emits on
  ``session.interrupt`` is unread).
* **L4** — relay HTTP control sibling (phone-facing port) gains one-shot
  ``POST /approve`` + ``POST /clarify`` → gateway ``approval.respond`` /
  ``clarify.respond`` (cold notification answer on GW-UNREACH, B6/B7).
* **L6** — reframer/downstream emits a ``userMessage`` item for NON-phone
  turns: from the gateway ``message.start`` prompt text (live turns) and from
  the ``rest_history`` user rows on OPEN/HISTORY seed (amendment G2 — the wire
  half that makes X5's foreign-mirror deletion possible).

**L5 is deliberately absent** (amendment L5-lean): projects stay on the
gateway REST control plane PERMANENTLY — a relay projects pass-through is the
duplicate-transport anti-pattern the lean mandate forbids. No stub exists;
this note is the record. The one surviving projects fix (``cwd`` on
SUBMIT-create) rides L2 above.

Hermetic: stdlib + pytest + unittest.mock only (the suite's house style); the
fakes are the canonical ones from ``test_downstream.py`` (reuse, never fork).
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock

import pytest

from hermes_relay.bus import EventBus
from hermes_relay.downstream import DownstreamConfig, DownstreamServer
from hermes_relay.reframer import Reframer
from hermes_relay.session_state import SessionStore
from hermes_relay.types import (
    FrameKind,
    GatewayEvent,
    ItemType,
    UpstreamMethod,
    UpstreamRequest,
)

# Reuse the canonical fakes (house rule: extend, never fork the harness).
from test_downstream import FakeWS, _handle, _server  # noqa: E402

L1 = "R4 L1 RED-BY-DESIGN: "
L2 = "R4 L2 RED-BY-DESIGN: "
L3 = "R4 L3 RED-BY-DESIGN: "
L4 = "R4 L4 RED-BY-DESIGN: "
L6 = "R4 L6 RED-BY-DESIGN: "


# ---------------------------------------------------------------------------
# L1 — LIST filter pass-through (GAP-1 session LIST parity, the central blocker)
# ---------------------------------------------------------------------------


async def test_l1_list_filter_params_pass_through():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, UpstreamMethod.LIST, {
        "limit": 50,
        "order": "recent",
        "cwd_prefix": "/repo/hermes",
        "exclude_source": "cron",
        "min_messages": 2,
    })
    gw.session_list.assert_awaited_once()
    call = gw.session_list.await_args
    # The filters must reach the gateway call. Today the call is
    # session_list(50) — limit forwarded positionally, FILTERS dropped — so
    # the order/cwd_prefix/... assertions fail (RED).
    flat = dict(call.kwargs)
    if call.args:
        flat.setdefault("limit", call.args[0])
    assert flat.get("limit") == 50, f"limit not forwarded: {call!r}"
    assert flat.get("order") == "recent", f"order dropped: {call!r}"
    assert flat.get("cwd_prefix") == "/repo/hermes", f"cwd_prefix dropped: {call!r}"
    assert flat.get("exclude_source") == "cron", f"exclude_source dropped: {call!r}"
    assert flat.get("min_messages") == 2, f"min_messages dropped: {call!r}"
    assert "sessions" in res


# ---------------------------------------------------------------------------
# L2 — truncate pass-through, cwd on create, seeded branch (§13 dead features)
# ---------------------------------------------------------------------------


async def test_l2_submit_passes_truncate_before_user_ordinal():
    srv, gw = _server()
    gw.owns = MagicMock(return_value=True)
    await srv.start()
    await _handle(srv, UpstreamMethod.SUBMIT, {
        "text": "regenerate from here",
        "session_id": "s5",
        "truncate_before_user_ordinal": 7,
    })
    gw.prompt_submit.assert_awaited_once()
    call = gw.prompt_submit.await_args
    # The gateway already accepts truncate_before_user_ordinal; the relay must
    # forward it. Today prompt_submit(sid, text) drops it — RED.
    assert call.kwargs.get("truncate_before_user_ordinal") == 7, (
        f"truncate_before_user_ordinal dropped by the relay: {call!r}"
    )


async def test_l2_create_branch_accepts_cwd():
    srv, gw = _server()
    await srv.start()
    await _handle(srv, UpstreamMethod.SUBMIT, {
        "text": "new session in a project",
        "title": "proj session",
        "cwd": "/repo/hermes",
    })
    gw.session_create.assert_awaited_once()
    call = gw.session_create.await_args
    assert call.kwargs.get("cwd") == "/repo/hermes", (
        f"cwd not threaded into session.create: {call!r}"
    )


async def test_l2_branch_method_seeds_new_session():
    srv, gw = _server()
    await srv.start()
    res = await _handle(srv, "branch", {
        "session_id": "s5",
        "text": "fork the conversation here",
    })
    # A seeded create: gateway session.create ran, the seed prompt was
    # submitted to the NEW id, and the phone gets the new session_id back.
    gw.session_create.assert_awaited_once()
    gw.prompt_submit.assert_awaited_once()
    new_sid = gw.session_create.await_args  # created id per the _server() mock
    assert res["session_id"] == "sNew", f"branch result: {res!r}"
    submit_call = gw.prompt_submit.await_args
    assert submit_call.args[0] == "sNew" and submit_call.args[1] == "fork the conversation here"
    assert new_sid is not None


# ---------------------------------------------------------------------------
# L3 — turn.completed `reason` (contract I9: stopped ≠ completed)
# ---------------------------------------------------------------------------


def _reframe_turn(payload_extra: dict | None = None) -> list:
    """Reframe message.start → message.complete; return the emitted frames."""
    r = Reframer(EventBus(), SessionStore())
    r.reframe(GatewayEvent(type="message.start", session_id="s1", payload={}))
    payload = {"text": "turn body", "usage": {"total": 3}}
    if payload_extra:
        payload.update(payload_extra)
    return r.reframe(GatewayEvent(
        type="message.complete", session_id="s1", payload=payload))


@pytest.mark.xfail(strict=True, reason=L3 + "turn.completed must stamp "
                   "reason='completed' on normal completion (reframer.py:"
                   "310-323 emits usage/duration only). Wave-1 L3 flips this; "
                   "remove when green.")
async def test_l3_turn_completed_reason_completed():
    frames = _reframe_turn()
    tc = [f for f in frames if f.kind == FrameKind.TURN_COMPLETED]
    assert len(tc) == 1
    assert tc[0].body.get("reason") == "completed", (
        f"turn.completed lacks reason=completed: {tc[0].body!r}"
    )


@pytest.mark.xfail(strict=True, reason=L3 + "turn.completed must stamp "
                   "reason='interrupted' when the gateway completes the turn "
                   "with status=interrupted (the shape session.interrupt "
                   "earns; the reframer never reads payload.status). Wave-1 "
                   "L3 flips this; remove when green.")
async def test_l3_turn_completed_reason_interrupted():
    frames = _reframe_turn({"status": "interrupted"})
    tc = [f for f in frames if f.kind == FrameKind.TURN_COMPLETED]
    assert len(tc) == 1
    assert tc[0].body.get("reason") == "interrupted", (
        f"interrupted turn lacks reason=interrupted: {tc[0].body!r}"
    )


@pytest.mark.xfail(strict=True, reason=L3 + "a gateway `error` event ending "
                   "the turn must yield turn.completed with reason='error' "
                   "(today _reframe_error emits the error item only — no "
                   "turn.completed at all, so the phone's settle edge never "
                   "fires off the wire truth). Wave-1 L3 flips this; remove "
                   "when green.")
async def test_l3_turn_completed_reason_error():
    r = Reframer(EventBus(), SessionStore())
    r.reframe(GatewayEvent(type="message.start", session_id="s1", payload={}))
    frames = r.reframe(GatewayEvent(
        type="error", session_id="s1", payload={"message": "model blew up"}))
    tc = [f for f in frames if f.kind == FrameKind.TURN_COMPLETED]
    assert tc, "an error-ended turn emitted no turn.completed at all"
    assert tc[0].body.get("reason") == "error", (
        f"error-ended turn lacks reason=error: {tc[0].body!r}"
    )


# ---------------------------------------------------------------------------
# L4 — relay HTTP control sibling: one-shot POST /approve + /clarify (B6/B7
# cold notification answer on GW-UNREACH, the daily-driver topology)
# ---------------------------------------------------------------------------


class _FakeHTTPConnection:
    """The `connection.respond(status, body)` surface _process_request uses."""

    def __init__(self) -> None:
        self.responded: list[tuple] = []

    async def respond(self, status, body: str):
        self.responded.append((status, body))


class _FakeHTTPRequest:
    """A POST request on the phone-facing port.

    Exposes the surface the existing _process_request reads (``path``,
    ``headers``) plus a JSON ``body``. The L4 implementer defines the exact
    body-read mechanism the websockets version permits and adapts this fake
    when turning the stub green — the pinned BEHAVIOR is: POST /approve (or
    /clarify) on the downstream port answers 200 and forwards the answer to
    the gateway.
    """

    def __init__(self, path: str, body: str) -> None:
        self.path = path
        self.headers = {"Content-Type": "application/json"}
        self.body = body.encode("utf-8")


@pytest.mark.xfail(strict=True, reason=L4 + "the phone-facing port must serve "
                   "one-shot POST /approve → gateway approval.respond "
                   "(downstream._process_request serves healthz/attention/"
                   "manifest only and returns None for /approve today). "
                   "Wave-1 L4 flips this; remove when green.")
async def test_l4_http_approve_one_shot():
    import json

    srv, gw = _server()
    await srv.start()
    conn = _FakeHTTPConnection()
    req = _FakeHTTPRequest(
        "/approve",
        json.dumps({"session_id": "sA", "request_id": "req-1", "decision": "once"}),
    )
    await srv._process_request(conn, req)
    assert conn.responded, "POST /approve fell through to the WS handshake (no HTTP answer)"
    status, body = conn.responded[0]
    assert int(status) == 200, f"POST /approve status {status}"
    assert json.loads(body).get("ok") is True, f"POST /approve body {body!r}"
    gw.approval_respond.assert_awaited_once()
    call = gw.approval_respond.await_args
    assert call.args[0] == "sA" and call.args[1] == "req-1" and call.args[2] == "once"


@pytest.mark.xfail(strict=True, reason=L4 + "the phone-facing port must serve "
                   "one-shot POST /clarify → gateway clarify.respond (absent "
                   "today — cold-tap answers are dead on GW-UNREACH). Wave-1 "
                   "L4 flips this; remove when green.")
async def test_l4_http_clarify_one_shot():
    import json

    srv, gw = _server()
    await srv.start()
    conn = _FakeHTTPConnection()
    req = _FakeHTTPRequest(
        "/clarify",
        json.dumps({"session_id": "sC", "request_id": "req-2", "text": "red"}),
    )
    await srv._process_request(conn, req)
    assert conn.responded, "POST /clarify fell through to the WS handshake (no HTTP answer)"
    status, body = conn.responded[0]
    assert int(status) == 200, f"POST /clarify status {status}"
    assert json.loads(body).get("ok") is True, f"POST /clarify body {body!r}"
    gw.clarify_respond.assert_awaited_once_with("sC", "req-2", "red")


# ---------------------------------------------------------------------------
# L6 — foreign turns gain a relay-emitted userMessage item (amendment G2: the
# wire half of the X5 foreign-mirror deletion)
# ---------------------------------------------------------------------------


@pytest.mark.xfail(strict=True, reason=L6 + "a non-phone turn's "
                   "message.start prompt text must emit a completed "
                   "userMessage item (reframer MESSAGE_START emits turn."
                   "started only — desktop-originated prompts have no user "
                   "row on the wire, D11's render half). Wave-1 L6 flips "
                   "this; remove when green.")
async def test_l6_message_start_prompt_emits_user_message_item():
    r = Reframer(EventBus(), SessionStore())
    frames = r.reframe(GatewayEvent(
        type="message.start", session_id="s1",
        payload={"prompt": "prompt from the desktop client"},
    ))
    users = [
        f for f in frames
        if f.kind == FrameKind.ITEM_COMPLETED and f.body.get("type") == ItemType.USER_MESSAGE
    ]
    assert users, (
        f"message.start with a prompt emitted no userMessage item: "
        f"{[(f.kind, f.body.get('type')) for f in frames]!r}"
    )
    assert users[0].body["body"].get("text") == "prompt from the desktop client"
    # Same item shape as the SUBMIT-synthesized one: completed, ord allocated.
    assert users[0].body.get("status") == "completed"


@pytest.mark.xfail(strict=True, reason=L6 + "OPEN/HISTORY seed must fold the "
                   "rest_history USER rows into the SessionStore as "
                   "userMessage items (so a resync snapshot carries the "
                   "foreign prompt; today OPEN returns the rows to the phone "
                   "and folds nothing — a snapshot fallback drops them). "
                   "Wave-1 L6 flips this; remove when green.")
async def test_l6_open_history_seed_folds_user_rows_into_store():
    srv, gw = _server()
    gw.rest_history = AsyncMock(return_value=[
        {"role": "user", "content": "desktop-originated prompt"},
        {"role": "assistant", "content": "the reply"},
    ])
    await srv.start()
    await _handle(srv, UpstreamMethod.OPEN, {"session_id": "s9"})
    snap = srv._store.snapshot("s9")
    users = [it for it in snap["items"] if it["type"] == ItemType.USER_MESSAGE]
    assert users, (
        f"OPEN seeded no userMessage item into the store; snapshot items: "
        f"{[it['type'] for it in snap['items']]!r}"
    )
    assert users[0]["body"].get("text") == "desktop-originated prompt"
