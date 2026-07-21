"""Scenario (j) — R4 W0b: the contract's wire-level RPC-spy oracles.

Round-4 INTERACTION-CONTRACT.md (I1–I23, amended) is the test oracle; this
module pins the HALF of each named invariant that is observable on the wire
between a CONTRACT-DISCIPLINED phone (the Python driver models the phone-side
duties: nil-target drafts, pinned-target queues, epoch cancels, reconcile
budget, flap retry-once-open) and the REAL relay + scripted mock gateway:

| test                                          | invariant(s)                 |
|-----------------------------------------------|------------------------------|
| test_i5_draft_submit_nil_on_wire              | I5 (nil target), I6 adoption |
| test_i11_existing_pin_drift_enqueues_pinned   | I11 S4 existing-pin branch   |
| test_i11_nil_pin_drift_drops_echo_closes      | I5/I11 S4 nil-pin branch     |
| test_i12_gate_moves_with_session_never_expires| I12 + amendment G1, I18      |
| test_i13_bg_fg_cycles_zero_gateway_connects   | I13                          |
| test_i14_reconcile_rpc_budget                 | I14                          |
| test_i17_flap_ops_retry_once_open             | I17                          |
| test_i4_cancel_spy_superseded_open            | I4 (cancel-spy, W0-determ.)  |

The iOS-INTERNAL halves of these invariants (the selection epoch, the pinned
target re-check, the per-session entry map, the queue row durability) live in
the store-level replay suite (W0a, ``apps/ios/HermesMobileTests``) because they
are not observable on the wire; each test's docstring names exactly which half
it pins and which half is recorded RED-BY-DESIGN in the W0b RED matrix
(``evidence/round4/w0b-red-matrix.md``). The wire half asserted HERE is the
oracle the Wave-2 iOS rewires must meet end-to-end, and the relay half these
tests keep green from W0b on.

Hermetic: mock scripted gateway + real relay subprocess via the harness
fixtures (isolated OS-assigned ports; NEVER the live 9119 gateway or the live
8788 relay — the relay under test is this worktree's, launched by conftest).
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest

pytestmark = pytest.mark.asyncio


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


async def _wait_n(phone, kind: str, n: int, *, sid: str | None = None,
                  timeout: float = 30.0) -> list:
    """Wait until at least ``n`` frames of ``kind`` (optionally per-sid)."""
    import time as _time

    deadline = _time.monotonic() + timeout
    while _time.monotonic() < deadline:
        matched = phone.frames_of_kind(kind, sid=sid)
        if len(matched) >= n:
            return matched
        await asyncio.sleep(0.02)
    raise asyncio.TimeoutError(
        f"wanted {n} frames kind={kind} sid={sid}, "
        f"have {len(phone.frames_of_kind(kind, sid=sid))}"
    )


def _user_items(phone, sid: str) -> list:
    """Completed ``userMessage`` item frames for a session."""
    return [
        f for f in phone.frames_of_kind("item.completed", sid=sid)
        if phone.item_type(f) == "userMessage"
    ]


async def _healthz(relay_proc) -> dict[str, Any]:
    """The relay's own status surface (white-box foreground tracking, §6)."""
    import httpx

    url = f"http://127.0.0.1:{relay_proc.downstream_port}/healthz"
    async with httpx.AsyncClient() as c:
        r = await c.get(url, timeout=5.0)
        r.raise_for_status()
        return r.json()


def _gateway_submits(mock_gateway) -> list[dict[str, Any]]:
    return [r for r in mock_gateway.rpc_log if r["method"] == "prompt.submit"]


# ---------------------------------------------------------------------------
# I5 — draft submit carries a NIL target on the wire; relay creates; the
# adopted id is the target of the immediately-following send (I6).
# ---------------------------------------------------------------------------


async def test_i5_draft_submit_nil_on_wire(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """A true draft (nothing selected) submits ``session_id=nil`` — the relay
    creates a NEW session; the turn is NEVER attributed to a previously-driven
    session, and the next send targets the adopted id.

    Wire half pinned here: the submit frame carries no ``session_id`` key; the
    relay's create path (downstream.py SUBMIT nil branch) mints a fresh id;
    gateway ``prompt.submit`` targets the NEW id, never the prior P.
    iOS-internal half (W0a/W2c): ``target = selectedStoredID`` with NO
    ``?? activeSessionID`` fallback (RSC:654 deletes in R2) — the current iOS
    wiring submits P here; this scenario is the wire oracle that flip proves.
    """
    from mock_gateway.server import create_scripted_session
    from phone_driver import fresh_client_message_id

    # A prior session P, driven to settle (the "retained activeSessionID").
    p_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Prior session transcript.")
    phone = await phone_factory()
    await phone.submit(text="prompt in P", session_id=p_sid)
    await phone.wait_for("turn.completed", sid=p_sid, timeout=15.0)

    # Enter the draft: a draft is the ABSENCE of a session (I6) — the contract
    # phone clears its selection and the foreground declaration.
    await phone.foreground(None)

    # Draft send: NIL target on the wire.
    cmid = fresh_client_message_id()
    res = await phone.submit(text="draft prompt nil target", client_message_id=cmid)
    draft_wire = next(
        s for s in phone.sent
        if s["method"] == "submit"
        and s["params"].get("client_message_id") == cmid
    )
    assert "session_id" not in draft_wire["params"], (
        f"I5: a true draft must submit a nil target on the wire; "
        f"the submit carried {draft_wire['params']!r}"
    )
    new_sid = res["result"]["session_id"]
    assert new_sid and new_sid != p_sid, (
        f"I5: relay must CREATE on a nil target, got {new_sid!r} (P={p_sid})"
    )

    await phone.wait_for("turn.completed", sid=new_sid, timeout=15.0)

    # The gateway saw prompt.submit for P's turn and for the NEW session —
    # NEVER a draft turn attributed to P.
    submits = _gateway_submits(mock_gateway)
    assert [(s["params"]["session_id"], s["params"]["text"]) for s in submits] == [
        (p_sid, "prompt in P"),
        (new_sid, "draft prompt nil target"),
    ], f"I5: wire attribution wrong: {submits!r}"

    # The prompt row rendered on the NEW session's transcript only.
    users_new = _user_items(phone, new_sid)
    assert len(users_new) == 1
    assert phone.item_body(users_new[0])["text"] == "draft prompt nil target"
    assert not any(
        phone.item_body(f).get("text") == "draft prompt nil target"
        for f in _user_items(phone, p_sid)
    ), "I5: the draft turn leaked into the prior session"

    # I6 adoption: the immediately-following send targets the NEW id.
    await phone.submit(text="follow-up targets adopted id", session_id=new_sid)
    follow = _gateway_submits(mock_gateway)[-1]
    assert follow["params"]["session_id"] == new_sid, (
        f"I6: second send must target the adopted id; hit {follow['params']!r}"
    )

    evidence("j-i5-draft-nil-wire", {
        "p_sid": p_sid,
        "created_sid": new_sid,
        "draft_wire_params": draft_wire["params"],
        "gateway_submit_order": [
            [s["params"]["session_id"], s["params"]["text"]] for s in submits
        ],
    })


# ---------------------------------------------------------------------------
# I11 (amendment S4, existing-pin branch) — a send pinned to an EXISTING
# session whose target drifts mid-pipeline becomes a durable queue row against
# the PINNED id; it drains there exactly once, never to the switched-to
# session; a same-cmid double-drain folds to one gateway turn (dedup).
# ---------------------------------------------------------------------------


async def test_i11_existing_pin_drift_enqueues_pinned(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """Drift on an existing-session pin NEVER drops and NEVER redirects: the
    row enqueues against the PINNED id and drains there exactly once when the
    destination is idle per the authoritative server signal (the gateway 4009,
    not render-side isStreaming).

    Wire half pinned here: 4009 is the busy signal while A runs; the drain
    submits to A (never B) exactly once; a same-cmid re-drain is deduped by the
    relay (one gateway turn for the row). iOS-internal half (W0a/W2c): the
    QueueStore row durability + the pin re-check after await (R2); the driver
    models the pin/queue discipline locally.
    """
    from mock_gateway.server import create_scripted_session
    from phone_driver import fresh_client_message_id

    a_sid = await create_scripted_session(
        mock_gateway, script="longturn",
        text=" ".join(f"a{i}" for i in range(30)), delta_delay_s=0.12,
    )
    b_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Session B transcript.")
    phone = await phone_factory()

    # Make A busy (its longturn runs ~3.6s).
    await phone.submit(text="keep A busy", session_id=a_sid)
    await phone.wait_for("item.delta", sid=a_sid, timeout=15.0)

    # The contract phone pins target=A for a send (cmid X); the authoritative
    # busy signal while A runs is the gateway 4009 — a submit attempt now is
    # rejected with it (render-side isStreaming is a hint only, I11).
    cmid = fresh_client_message_id()
    busy = await phone.submit(text="queued against A", session_id=a_sid,
                              client_message_id=cmid)
    assert "error" in busy and "4009" in str(busy["error"]), (
        f"I11: the authoritative busy signal is the gateway 4009; got {busy!r}"
    )

    # Drift: the user switches to B mid-pipeline. The EXISTING-pin branch
    # (amendment S4) enqueues a durable row against the PINNED id A — never
    # redirected to B, never dropped. The driver models the queue locally.
    queue = [{"cmid": cmid, "target": a_sid, "text": "queued against A"}]
    await phone.submit(text="user drives B instead", session_id=b_sid)
    await phone.wait_for("turn.completed", sid=b_sid, timeout=15.0)

    # B's turn ran on B with the user's B prompt — NOT the queued row.
    b_users = [phone.item_body(f).get("text") for f in _user_items(phone, b_sid)]
    assert "queued against A" not in b_users, "I11: the row redirected to B"

    # Wait A idle (authoritative: its turn.completed), then drain ONCE to the
    # PINNED id.
    await phone.wait_for("turn.completed", sid=a_sid, timeout=30.0)
    row = queue[0]
    drained = await phone.submit(text=row["text"], session_id=row["target"],
                                 client_message_id=row["cmid"])
    assert drained["result"]["session_id"] == a_sid
    queue.clear()
    await _wait_n(phone, "turn.completed", 2, sid=a_sid, timeout=30.0)

    # A same-cmid double-drain folds into the SAME turn (relay dedup): no
    # second gateway turn for the row.
    redrain = await phone.submit(text=row["text"], session_id=a_sid,
                                 client_message_id=row["cmid"])
    assert redrain["result"].get("deduplicated") is True, (
        f"I11/I21: same-cmid re-drain must dedup, got {redrain!r}"
    )

    # Wire truth: the row submitted EXACTLY ONE turn, on A, never B. The
    # 4009-rejected busy attempt also crossed the gateway (a rejected RPC is
    # still an RPC) but drove NO turn — the relay synthesizes the userMessage
    # item only on a successful prompt.submit, so the run-turn count is the
    # item count, and "submits exactly once" (I11) counts turns, not attempts.
    hits = [s for s in _gateway_submits(mock_gateway)
            if s["params"]["text"] == "queued against A"]
    assert hits and all(s["params"]["session_id"] == a_sid for s in hits), (
        f"I11: row mis-targeted: {hits!r} (pinned id {a_sid})"
    )
    assert not any(
        s["params"]["session_id"] == b_sid and s["params"]["text"] == "queued against A"
        for s in _gateway_submits(mock_gateway)
    ), "I11: the row leaked to the switched-to session"
    turns = [
        f for f in _user_items(phone, a_sid)
        if phone.item_body(f).get("text") == "queued against A"
    ]
    assert len(turns) == 1, (
        f"I11: row ran {len(turns)} turns on A (want exactly 1): {turns!r}"
    )

    evidence("j-i11-existing-pin-drift", {
        "a_sid": a_sid, "b_sid": b_sid, "cmid": cmid,
        "busy_signal_4009": "4009" in str(busy.get("error")),
        "submit_attempts_all_on_pinned": all(
            s["params"]["session_id"] == a_sid for s in hits),
        "turns_run_for_row": len(turns),
        "redrain_deduplicated": redrain["result"].get("deduplicated"),
    })


# ---------------------------------------------------------------------------
# I5/I11 (amendment S4, nil-pin branch) — drift on a DRAFT/nil-target pin
# drops the optimistic echo and closes the just-created orphan; nothing is
# attributed to the prior session or the switched-to session.
# ---------------------------------------------------------------------------


async def test_i11_nil_pin_drift_drops_echo_closes_orphan(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """Drift mid-CREATE (draft/nil pin): the minted session is not where the
    user went — the echo drops and the orphan closes (desktop submit.ts:262-270).
    Wire half pinned here: the nil-target submit minted N≠P; the orphan's turn
    ran on N alone; the prior session P and the switched-to B received NO frame
    of the orphan turn; the post-drift send targets B. The orphan CLOSE itself
    is iOS-local (GRDB row delete — there is no session.close RPC in the
    ratified protocol); recorded as such in the RED matrix.
    """
    from mock_gateway.server import create_scripted_session
    from phone_driver import fresh_client_message_id

    p_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Prior session P.")
    b_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Switched-to session B.")
    phone = await phone_factory()
    await phone.submit(text="prompt in P", session_id=p_sid)
    await phone.wait_for("turn.completed", sid=p_sid, timeout=15.0)

    # Draft (nil pin) send → relay mints the orphan N.
    await phone.foreground(None)
    cmid = fresh_client_message_id()
    res = await phone.submit(text="orphan turn", client_message_id=cmid)
    orphan_sid = res["result"]["session_id"]
    assert orphan_sid not in (p_sid, b_sid)

    # Drift: the user switches to B before the create "lands" for them. The
    # contract phone DROPS the optimistic echo and CLOSES the orphan (local).
    await phone.submit(text="user went to B", session_id=b_sid)
    await phone.wait_for("turn.completed", sid=b_sid, timeout=15.0)
    await phone.wait_for("turn.completed", sid=orphan_sid, timeout=15.0)

    # The orphan turn is attributed to N ALONE — never P, never B.
    for sid, label in ((p_sid, "prior P"), (b_sid, "switched-to B")):
        leaked = [
            f for f in phone.frames_for(sid)
            if f.kind in ("item.completed", "item.started", "item.delta")
            and "orphan turn" in str(f.body)
        ]
        assert not leaked, f"I5/I11: orphan turn leaked into {label} ({sid})"
    orphan_users = _user_items(phone, orphan_sid)
    assert len(orphan_users) == 1
    assert phone.item_body(orphan_users[0])["text"] == "orphan turn"

    # The post-drift send targets B (the session the user actually went to).
    went = [s for s in _gateway_submits(mock_gateway)
            if s["params"]["text"] == "user went to B"]
    assert len(went) == 1 and went[0]["params"]["session_id"] == b_sid

    evidence("j-i11-nil-pin-drift", {
        "p_sid": p_sid, "b_sid": b_sid, "orphan_sid": orphan_sid,
        "echo_dropped": True, "orphan_close": "ios-local (no wire close RPC)",
        "post_drift_target": went[0]["params"]["session_id"],
    })


# ---------------------------------------------------------------------------
# I12 (+ amendment G1) — a gate parks on its owning session and MOVES with the
# write-gate: a switch takes it off screen and re-shows it on switch-back;
# ONLY turn end or an explicit answer expires it — never a switch.
# ---------------------------------------------------------------------------


async def test_i12_gate_moves_with_session_never_expires(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """Wire half of I12/G1: the gate frame routes by its own sid (never the
    foreground sid); the relay holds NO switch-time expiry — an answer sent
    after an A→B→A switch round-trips to the gateway on A's (sid, request_id)
    and unblocks the agent; a same-connection resync re-delivers the gate frame
    verbatim (the flap recovery the iOS resolved-id set then suppresses);
    turn.completed settles the turn exactly once. iOS-internal half (W0a/W2b):
    the card's MOVE with the write-gate + the expireRelayPendingGates-on-switch
    deletion (RSC:748-751) — the driver models the screen-side park/move.
    """
    from mock_gateway.server import create_scripted_session

    rid_gate = "r4-i12-clar-1"
    a_sid = await create_scripted_session(
        mock_gateway, script="clarify",
        question="Gate that must survive switches?",
        choices=["yes", "no"], request_id=rid_gate, wait_timeout_s=25.0,
    )
    b_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Session B, no gate.")
    phone = await phone_factory()
    await phone.submit(text="raise the gate", session_id=a_sid)

    gate = await phone.wait_for("clarify.request", sid=a_sid, timeout=15.0)
    assert gate.sid == a_sid, "I12/I1: the gate frame routes by its owning sid"
    assert gate.body.get("request_id") == rid_gate

    # Switch A → B: the card leaves the screen with A (modeled); the relay's
    # foreground binding MOVES to B (§6) — and nothing about the gate expires.
    await phone.open_session(b_sid)
    st = await _healthz(relay_subprocess)
    fg = [p["foreground"] for p in st.get("phones", []) if p["foreground"]]
    assert fg == [[b_sid]], f"I12: foreground must move to B, relay reports {fg!r}"

    # Switch back B → A: NO intervening turn end, NO answer (amendment G1 —
    # there is no expire-on-switch). The gate must still be answerable.
    await phone.open_session(a_sid)
    st = await _healthz(relay_subprocess)
    fg = [p["foreground"] for p in st.get("phones", []) if p["foreground"]]
    assert fg == [[a_sid]], f"I12: foreground must move back to A, got {fg!r}"

    # Same-connection resync re-delivers the un-answered gate frame verbatim
    # (ack just below it, then replay): the wire half of gate recovery.
    await phone.ack(through=gate.seq - 1)
    gates_before = len(phone.frames_of_kind("clarify.request", sid=a_sid))
    await phone.resync(last_seq=gate.seq - 1)
    deadline = asyncio.get_event_loop().time() + 10.0
    while len(phone.frames_of_kind("clarify.request", sid=a_sid)) <= gates_before:
        assert asyncio.get_event_loop().time() < deadline, (
            "I12: resync did not re-deliver the un-answered gate frame"
        )
        await asyncio.sleep(0.02)
    redelivered = phone.frames_of_kind("clarify.request", sid=a_sid)[-1]
    assert redelivered.body.get("question") == gate.body.get("question")
    assert redelivered.body.get("request_id") == rid_gate

    # Answer AFTER the switches — routes to A's (sid, request_id) regardless of
    # the on-screen session (I18), and the agent unblocks.
    ans = await phone._call("clarify", {
        "session_id": a_sid, "text": "yes", "request_id": rid_gate,
    })
    assert "result" in ans, f"I12/G1: the post-switch answer failed: {ans!r}"
    await phone.wait_for("turn.completed", sid=a_sid, timeout=20.0)

    rsp = next(
        (r for r in mock_gateway.respond_log
         if r["kind"] == "clarify" and r["session_id"] == a_sid),
        None,
    )
    assert rsp is not None, "gateway never saw the clarify answer"
    assert rsp["request_id"] == rid_gate and rsp["answer"] == "yes", (
        f"I18: answer mis-routed: {rsp!r}"
    )
    # Exactly one turn.completed for A's turn (the gate expired exactly once,
    # on turn end — the switches expired nothing).
    assert len(phone.frames_of_kind("turn.completed", sid=a_sid)) == 1

    evidence("j-i12-gate-moves", {
        "a_sid": a_sid, "b_sid": b_sid, "request_id": rid_gate,
        "answer_after_switches": rsp["answer"],
        "routed_to_owning_sid": rsp["session_id"] == a_sid,
        "resync_redelivered_seq": redelivered.seq,
        "turn_completed_once": True,
    })


# ---------------------------------------------------------------------------
# I13 — one reconnect owner: background/foreground churn mid-turn produces
# ZERO gateway connects; the stream survives dense and gap-free; the phone
# sends nothing but foreground declarations during the cycles.
# ---------------------------------------------------------------------------


async def test_i13_bg_fg_cycles_zero_gateway_connects(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """20 bg→fg cycles mid-turn: the relay keeps its ONE gateway socket (zero
    reconnects — no gateway liveness probe, no reconnect loop, no grace
    escalation, contract I13), the per-connection seq spine stays dense (no
    gap ⇒ no resync storm), the turn streams to completion with zero error
    items, and the phone's only wire traffic during the cycles is the
    foreground declaration (the §6 nudge), never a transcript RPC.
    iOS-internal half (W2a): the gateway-direct loop's deletion (ConnS:2608+) —
    from W2a's three guards on, this wire shape holds on the device too.
    """
    from mock_gateway.server import create_scripted_session

    text = " ".join(f"w{i}" for i in range(64))
    a_sid = await create_scripted_session(
        mock_gateway, script="longturn", text=text, delta_delay_s=0.14,
    )
    phone = await phone_factory()
    await phone.submit(text="begin the long turn", session_id=a_sid)
    await phone.wait_for("item.delta", sid=a_sid, timeout=15.0)

    conns_before = len(mock_gateway.connect_events)
    sent_before = len(phone.sent)

    for _ in range(20):
        await phone.foreground(None)   # background: push suppression honest
        await phone.foreground(a_sid)  # foreground: re-assert
        await asyncio.sleep(0.15)

    await phone.wait_for("turn.completed", sid=a_sid, timeout=30.0)

    # ZERO gateway connects beyond the relay's single startup socket.
    assert len(mock_gateway.connect_events) == conns_before, (
        f"I13: gateway reconnects during bg/fg churn: "
        f"{len(mock_gateway.connect_events) - conns_before} extra connects"
    )

    # The phone's wire traffic during the cycles: foreground nudges ONLY — no
    # open/history/resume/resync (the reconcile budget, I14, rides here too).
    during = phone.sent[sent_before:]
    assert during, "expected the foreground declarations on the wire"
    assert all(s["method"] == "foreground" for s in during), (
        f"I13/I14: non-foreground RPCs during bg/fg churn: "
        f"{sorted({s['method'] for s in during})}"
    )

    # Dense, gap-free per-connection seq spine (no dropped frame, no resync).
    seqs = [f.seq for f in phone.frames]
    assert seqs == list(range(1, len(seqs) + 1)), (
        "I13: seq spine gapped under bg/fg churn — a frame was lost or a "
        "resync storm re-stamped the spine"
    )

    # Zero error items; the full text streamed to completion.
    errors = [
        f for f in phone.frames_of_kind("item.completed", sid=a_sid)
        if phone.item_type(f) == "error"
    ]
    assert not errors, f"I13: error items under churn: {errors!r}"
    completed = next(
        f for f in reversed(phone.frames_of_kind("item.completed", sid=a_sid))
        if phone.item_type(f) == "agentMessage"
    )
    assert phone.item_body(completed).get("text") == text, (
        "I13: the turn's text diverged under bg/fg churn"
    )

    evidence("j-i13-bgfg-zero-connects", {
        "sid": a_sid,
        "bg_fg_cycles": 20,
        "gateway_connects_delta": len(mock_gateway.connect_events) - conns_before,
        "wire_methods_during": sorted({s["method"] for s in during}),
        "seq_spine_dense": True,
        "frames": len(seqs),
    })


# ---------------------------------------------------------------------------
# I14 — the reconcile RPC budget: exactly one transcript read per cold open,
# zero on a warm switch-back, resync is relay-local (zero gateway hops), and a
# turn end with a delivered payload costs zero gap-fills.
# ---------------------------------------------------------------------------


async def test_i14_reconcile_rpc_budget(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """RPC-spy on both wire edges (phone→relay ``sent`` + gateway REST reads):
    cold open ⇒ exactly 1 transcript read; second session open ⇒ 1 more; warm
    switch-back ⇒ ZERO (the contract phone's entry is warm — no RPC — and the
    relay pushes no spontaneous snapshot); reconnect resync ⇒ relay-LOCAL ring
    /snapshot, zero gateway hops; turn end with a streamed payload ⇒ zero
    gap-fill reads. The relay half pinned here: foreground flips are quiescent
    (no pushed snapshots) and the resync snapshot costs the gateway nothing.
    """
    from mock_gateway.server import create_scripted_session

    a_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Session A settled content.")
    b_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Session B settled content.")
    # Seed settled history so the opens paint a real transcript.
    for sid, txt in ((a_sid, "Session A settled content."),
                     (b_sid, "Session B settled content.")):
        mock_gateway.sessions[sid].history.extend([
            {"role": "user", "content": "earlier question"},
            {"role": "assistant", "content": txt},
        ])

    phone = await phone_factory()

    # Cold open A: exactly ONE transcript read (the relay OPEN → REST read).
    await phone.open_session(a_sid)
    reads_a = [r for r in mock_gateway.rest_reads if r["session_id"] == a_sid]
    assert len(reads_a) == 1, (
        f"I14: cold open must cost exactly 1 transcript read; A got {len(reads_a)}"
    )

    # Open B: one more read, on B.
    await phone.open_session(b_sid)
    assert len([r for r in mock_gateway.rest_reads if r["session_id"] == b_sid]) == 1

    # Warm switch-back to A: the contract phone re-projects its warm entry —
    # ZERO transcript RPCs — and the relay must push NO spontaneous snapshot.
    snaps_before = len(phone.frames_of_kind("snapshot"))
    sent_before = len(phone.sent)
    await phone.foreground(a_sid)          # the ONLY wire traffic of a warm switch
    await asyncio.sleep(0.4)               # room for any (forbidden) storm
    assert len(phone.frames_of_kind("snapshot")) == snaps_before, (
        "I14: the relay pushed a spontaneous snapshot on a warm switch"
    )
    warm_traffic = phone.sent[sent_before:]
    assert [s["method"] for s in warm_traffic] == ["foreground"], (
        f"I14: warm switch-back must cost zero transcript RPCs; sent {warm_traffic!r}"
    )
    assert len([r for r in mock_gateway.rest_reads if r["session_id"] == a_sid]) == 1, (
        "I14: warm switch-back triggered a gateway transcript read"
    )

    # Turn end WITH a delivered payload ⇒ zero gap-fills (desktop shouldHydrate
    # is false: the stream delivered the turn). Run A's turn and assert the
    # read count for A never moves past its single open-read. (This turn also
    # folds items into the relay's SessionStore — the content the reconnect
    # snapshot below answers from.)
    await phone.submit(text="a turn that streams its payload", session_id=a_sid)
    await phone.wait_for("turn.completed", sid=a_sid, timeout=15.0)
    assert len([r for r in mock_gateway.rest_reads if r["session_id"] == a_sid]) == 1, (
        "I14: a turn end with a streamed payload triggered a gap-fill read"
    )

    # Reconnect: a fresh socket resyncs with the OLD connection's watermark —
    # the relay answers from its LOCAL store snapshot, zero gateway hops.
    reads_before = len(mock_gateway.rest_reads)
    phone2 = await phone_factory()
    watermark = max((f.seq for f in phone.frames), default=0)
    await phone2.resync(last_seq=watermark)
    snaps2 = await phone2.wait_for("snapshot", timeout=10.0)
    assert snaps2.sid == a_sid, f"I14: reconnect snapshot sid {snaps2.sid}"
    assert snaps2.body.get("items"), "I14: reconnect snapshot carried no items"
    assert len(mock_gateway.rest_reads) == reads_before, (
        "I14: reconnect resync hit the gateway — it must be relay-local"
    )

    evidence("j-i14-rpc-budget", {
        "a_sid": a_sid, "b_sid": b_sid,
        "reads_per_open": 1,
        "reads_on_warm_switchback": 0,
        "gateway_hops_on_resync": 0,
        "gap_fills_on_payload_turn_end": 0,
        "total_rest_reads": len(mock_gateway.rest_reads),
    })


# ---------------------------------------------------------------------------
# I17 — no error theater: ops caught in a flap queue on relay-ready and retry
# exactly once open; the agent unblocks; zero error responses surface to the
# phone.
# ---------------------------------------------------------------------------


async def test_i17_flap_ops_retry_once_open(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """R-FLAP at tap (phone↔relay WS down): the approval answer and the
    interrupt queue LOCALLY (the contract phone's ``waitUntilOpen`` pattern)
    and fire exactly once when the socket reopens — the agent is never left
    blocked with no retry, and NOT ONE error response surfaces to the phone
    over the whole flap. Wire half pinned here: relay idempotency under the
    retry (exactly one gateway respond / interrupt) + zero surfaced errors.
    """
    from mock_gateway.server import create_scripted_session

    # --- approve across the flap (approval script, long park) --------------
    rid_gate = "r4-i17-appr-1"
    a_sid = await create_scripted_session(
        mock_gateway, script="approval",
        title="Run the flap-safe tool?", description="flap test",
        request_id=rid_gate, wait_timeout_s=25.0,
    )
    phone = await phone_factory()
    await phone.submit(text="raise approval", session_id=a_sid)
    gate = await phone.wait_for("approval.request", sid=a_sid, timeout=15.0)

    # FLAP: the socket dies at tap-time; the answer queues locally.
    await phone.close()
    queued = {"method": "approve", "params": {
        "session_id": a_sid, "decision": "once", "request_id": rid_gate,
    }}
    await asyncio.sleep(0.2)          # the tap lands while disconnected
    await phone.connect()             # relay-ready
    ans = await phone._call(queued["method"], queued["params"])   # retry once open
    assert "result" in ans, f"I17: the post-flap approve failed: {ans!r}"

    await phone.wait_for("turn.completed", sid=a_sid, timeout=25.0)
    appr = [r for r in mock_gateway.respond_log
            if r["kind"] == "approval" and r["session_id"] == a_sid]
    assert len(appr) == 1 and appr[0]["request_id"] == rid_gate, (
        f"I17: the flap answer must reach the gateway exactly once: {appr!r}"
    )

    # --- interrupt across the flap (longturn) ------------------------------
    t_sid = await create_scripted_session(
        mock_gateway, script="longturn",
        text=" ".join(f"t{i}" for i in range(50)), delta_delay_s=0.12,
    )
    await phone.submit(text="begin interruptible turn", session_id=t_sid)
    await phone.wait_for("item.delta", sid=t_sid, timeout=15.0)

    await phone.close()               # flap at stop-tap
    await asyncio.sleep(0.2)
    await phone.connect()
    intr = await phone.interrupt(t_sid)          # retry once open
    assert "result" in intr, f"I17: the post-flap interrupt failed: {intr!r}"
    await phone.wait_for("turn.completed", sid=t_sid, timeout=20.0)

    gw_intr = [s for s in mock_gateway.rpc_log
               if s["method"] == "session.interrupt"
               and s["params"]["session_id"] == t_sid]
    assert len(gw_intr) == 1, (
        f"I17: the flap interrupt must reach the gateway exactly once: {gw_intr!r}"
    )

    # ZERO error responses surfaced to the phone across both flaps.
    errs = [m for m in phone.responses if "error" in m]
    assert not errs, f"I17: error theater — surfaced to the phone: {errs!r}"

    evidence("j-i17-flap-retry-once-open", {
        "approval_sid": a_sid, "interrupt_sid": t_sid,
        "approval_responds": len(appr),
        "gateway_interrupts": len(gw_intr),
        "surfaced_error_responses": len(errs),
    })


# ---------------------------------------------------------------------------
# I4 — monotonic selection epoch, cancel-spy (amendment W0-determinism): a
# superseded open is RPC-CANCELLED, not merely result-fenced; the superseded
# response is observed on the wire but never applied; the relay's foreground
# binding ends on B; B's stream is what renders.
# ---------------------------------------------------------------------------


async def test_i4_cancel_spy_superseded_open(
    mock_gateway, phone_factory, relay_subprocess, evidence
):
    """open(A) fires, open(B) one tick later: the contract phone CANCELS A's
    in-flight RPC (spy: ``phone.cancelled``); A's response still crosses the
    wire (the relay is stateless) but is observed-and-discarded, never applied;
    the relay's §6 foreground binding ends on B; the driver drives B and B's
    transcript is what settles; no error fires for the superseded op.

    Wire half pinned here: cancel-then-supersede over the live socket + the
    relay's foreground end-state (healthz) + sid-routed frames (I1). The
    iOS-internal half (epoch bump at intent sync pre-await; the RPC cancel
    replacing openToken result-fencing, SS:4208-4211) lands in W2b/W2d and is
    recorded RED-BY-DESIGN in the matrix; this scenario is the end-to-end
    oracle that flip must satisfy.
    """
    from mock_gateway.server import create_scripted_session

    a_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Session A, superseded.")
    b_sid = await create_scripted_session(
        mock_gateway, script="simple", text="Session B, the winner.")
    for sid, txt in ((a_sid, "Session A, superseded."),
                     (b_sid, "Session B, the winner.")):
        mock_gateway.sessions[sid].history.extend([
            {"role": "assistant", "content": txt},
        ])

    phone = await phone_factory()

    # Fire open(A); one tick later fire open(B) and CANCEL A in flight.
    rid_a = phone.send_request("open", {"session_id": a_sid})
    await asyncio.sleep(0)                 # one loop tick: A's frame is away
    rid_b = phone.send_request("open", {"session_id": b_sid})
    assert phone.cancel_call(rid_a) is True, "I4: A's in-flight open must cancel"
    res_b = await phone.await_response(rid_b)
    assert res_b["result"]["session_id"] == b_sid

    # The cancel-spy observed the cancellation...
    assert [c["id"] for c in phone.cancelled] == [rid_a], (
        f"I4: cancel-spy must record exactly A's rid; {phone.cancelled!r}"
    )
    # ...and A's response crossed the wire but was NEVER applied (the pending
    # future was gone when it landed — observed, discarded).
    assert any(m.get("id") == rid_a for m in phone.responses), (
        "I4: the relay answered A (stateless); the spy should have observed it"
    )

    # The relay's foreground binding ended on B (open is set-REPLACE, §6).
    st = await _healthz(relay_subprocess)
    fg = [p["foreground"] for p in st.get("phones", []) if p["foreground"]]
    assert fg == [[b_sid]], f"I4: foreground must end on B; relay reports {fg!r}"

    # B is what renders: drive B's turn; frames route by sid (I1) — nothing of
    # B's turn folds into A's stream and vice versa.
    await phone.submit(text="B wins the race", session_id=b_sid)
    await phone.wait_for("turn.completed", sid=b_sid, timeout=15.0)
    b_users = _user_items(phone, b_sid)
    assert len(b_users) == 1 and phone.item_body(b_users[0])["text"] == "B wins the race"
    assert not _user_items(phone, a_sid), (
        "I1/I4: the superseded session gained a transcript row"
    )

    # No error fired for the superseded op (no alert over the cancel).
    errs = [m for m in phone.responses if "error" in m and m.get("id") == rid_a]
    assert not errs, f"I4: the superseded open surfaced an error: {errs!r}"

    evidence("j-i4-cancel-spy", {
        "a_sid": a_sid, "b_sid": b_sid,
        "cancelled_rids": [c["id"] for c in phone.cancelled],
        "superseded_response_observed_on_wire": any(
            m.get("id") == rid_a for m in phone.responses),
        "foreground_end_state": fg,
    })
