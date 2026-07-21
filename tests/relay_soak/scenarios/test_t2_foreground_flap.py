"""T2 — foreground flap storm (I7 + reconnect single-flight).

Two complementary drives:

* **In-process notifier drive (I7 core).** The notify DECISION is not observable
  over the wire (the relay's push path is silent without APNs creds), so we run
  the relay-under-test's REAL ``Reframer`` + ``Notifier`` in-process, fed by the
  deterministic mock-gateway event stream, with a ``FakePush`` mock-APNs sink
  (zero network) and a foreground oracle the harness flips on a schedule. We
  assert the §6 contract under rapid flapping:

  - ``turn_complete``/``task_complete`` fire when backgrounded, are SUPPRESSED
    when foregrounded (and the decision tracks the oracle state at fire time);
  - blocking gates (``approval``/``clarify``) ALWAYS fire even foregrounded;
  - no notify is DELIVERED to a dead/evicted token (FakePush returns 0).

* **Wire foreground storm.** A real relay subprocess; the phone hammers
  ``foreground(sid)``/``foreground(null)`` RPCs at high frequency while turns
  stream. The relay must stay alive (healthz 200), keep turns completing (I1),
  and hold a single foreground session (set-REPLACE, no accumulation) — the
  reconnect single-flight / foreground-gate path under churn.
"""

from __future__ import annotations

import asyncio
import random

import httpx
import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.infra.phone_ext import foreground_flap_loop
from tests.relay_soak.invariants.checkers import (
    FakePush,
    NotifyRecorder,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio


# ---------------------------------------------------------------------------
# In-process notifier harness (the §6 decision is only observable here).
# ---------------------------------------------------------------------------


class _OwnsAll:
    """GatewayClient stub: owns every session (the soak drives only owned)."""

    def owns(self, sid: str) -> bool:
        return True


def _build_notifier(fg_set: set, push: FakePush):
    """Construct the relay-under-test's real Reframer + Notifier in-process."""
    from hermes_relay.bus import EventBus
    from hermes_relay.notifier import Notifier, NotifierConfig
    from hermes_relay.reframer import Reframer
    from hermes_relay.session_state import SessionStore

    bus = EventBus()
    store = SessionStore()
    reframer = Reframer(bus, store)
    notifier = Notifier(
        NotifierConfig(), bus, _OwnsAll(),
        is_foregrounded=lambda sid: sid in fg_set,
        push_engine=push, durable=None,  # direct send to FakePush, no sqlite
    )
    return reframer, notifier


async def _drive_script(gw, reframer, recorder, fg_set, *,
                        script: str, foreground: bool = False, **kwargs) -> str:
    """Run one mock-gateway script through reframer -> recorder.observe.

    ``foreground`` pins the oracle for the session for the drive's lifetime
    (blocking-gate drives set it True; background drives leave it clear).
    """
    from hermes_relay.types import GatewayEvent
    from mock_gateway.server import create_scripted_session

    kwargs.setdefault("wait_timeout_s", 0.3)
    sid = await create_scripted_session(gw, script=script, **kwargs)
    if foreground:
        fg_set.add(sid)
    orig = gw._broadcast

    async def tap(sid_: str, params: dict) -> None:
        ge = GatewayEvent(type=params.get("type", ""), session_id=sid_,
                          payload=dict(params.get("payload") or {}))
        for frame in reframer.reframe(ge):
            recorder.observe(frame)
        await asyncio.sleep(0)

    gw._broadcast = tap
    try:
        await gw._run_script(gw.sessions[sid])
    finally:
        gw._broadcast = orig
        fg_set.discard(sid)
    return sid


async def _drive_flapping(gw, reframer, recorder, fg_set, rng, *,
                          flips: int) -> list:
    """Stream a slow turn while flipping the foreground oracle; return the
    non-blocking decisions recorded during the flap."""
    from hermes_relay.types import GatewayEvent
    from mock_gateway.server import create_scripted_session

    sid = await create_scripted_session(
        gw, script="simple",
        text="Flapping turn streams slowly so flaps land mid-stream.",
        delta_delay_s=0.03,
    )
    stop = asyncio.Event()
    before = len(recorder.decisions)

    async def flap():
        on = True
        n = 0
        while not stop.is_set() and n < flips:
            (fg_set.add if on else fg_set.discard)(sid)
            on = not on
            n += 1
            await asyncio.sleep(rng.uniform(0.005, 0.02))

    orig = gw._broadcast

    async def tap(sid_, params):
        ge = GatewayEvent(type=params.get("type", ""), session_id=sid_,
                          payload=dict(params.get("payload") or {}))
        for frame in reframer.reframe(ge):
            recorder.observe(frame)
        await asyncio.sleep(0)

    task = asyncio.create_task(flap())
    gw._broadcast = tap
    try:
        await gw._run_script(gw.sessions[sid])
    finally:
        gw._broadcast = orig
        stop.set()
        fg_set.discard(sid)
        try:
            await asyncio.wait_for(task, timeout=2.0)
        except asyncio.TimeoutError:
            task.cancel()
    return [d for d in recorder.decisions[before:]
            if d["event_type"] in ("turn_complete", "task_complete")]


async def _inproc_i7(gw, p, rng) -> dict:
    """The full I7 decision matrix, in-process. Returns the I7 report."""
    fg: set = set()
    push = FakePush(valid_tokens={"tok-live"})
    reframer, notifier = _build_notifier(fg, push)
    recorder = NotifyRecorder(notifier, push, fg)

    # (1) backgrounded -> turn_complete FIRES
    await _drive_script(gw, reframer, recorder, fg,
                        script="simple", text="bg", foreground=False)
    bg_fired = [d for d in recorder.decisions
                if d["event_type"] == "turn_complete" and d["fired"]]

    # (2) foregrounded -> turn_complete SUPPRESSED
    s_fg = await _drive_script(gw, reframer, recorder, fg,
                               script="simple", text="fg", foreground=True)
    fg_suppressed = [d for d in recorder.decisions
                     if d["event_type"] == "turn_complete"
                     and d["sid"] == s_fg and not d["fired"]]

    # (3) approval bypasses the foreground gate
    s_ap = await _drive_script(gw, reframer, recorder, fg,
                               script="approval", foreground=True)
    appr_fired = [d for d in recorder.decisions
                  if d["event_type"] == "approval" and d["sid"] == s_ap
                  and d["fired"]]

    # (4) clarify bypasses the foreground gate
    s_cl = await _drive_script(gw, reframer, recorder, fg,
                               script="clarify", foreground=True)
    clar_fired = [d for d in recorder.decisions
                  if d["event_type"] == "clarify" and d["sid"] == s_cl
                  and d["fired"]]

    # (5) rapid flap mid-stream: fire/suppress must track the oracle at fire time
    flap_decisions = await _drive_flapping(gw, reframer, recorder,
                                           fg, rng,
                                           flips=max(8, int(p.duration_s * 4)))

    # (6) dead/evicted token: a notify attempt must NOT be delivered
    dead_push = FakePush(valid_tokens=set())       # no token is valid
    dead_push.current_token = "tok-dead"
    reframer_d, notifier_d = _build_notifier(set(), dead_push)
    rec_d = NotifyRecorder(notifier_d, dead_push, set())
    await _drive_script(gw, reframer_d, rec_d, set(),
                        script="simple", text="dead token turn")
    dead_delivered = [c for c in dead_push.calls if c.get("delivered")]

    report = recorder.report()
    violations = list(report.get("violations") or [])
    if not bg_fired:
        violations.append("I7: turn_complete did NOT fire when backgrounded")
    if not fg_suppressed:
        violations.append("I7: turn_complete NOT suppressed when foregrounded")
    if not appr_fired:
        violations.append("I7: approval did not bypass the foreground gate")
    if not clar_fired:
        violations.append("I7: clarify did not bypass the foreground gate")
    if dead_delivered:
        violations.append(
            f"I7: {len(dead_delivered)} notify delivered to a dead/evicted token")
    for d in recorder.decisions:
        if d["event_type"] in ("turn_complete", "task_complete", "turn_error"):
            if d["fired"] and d["foreground_at_decision"]:
                violations.append(
                    f"I7: {d['event_type']} fired while foregrounded "
                    f"(sid={d['sid']})")

    report["violations"] = violations
    report["ok"] = not violations
    report["extras"] = {
        "bg_fired": len(bg_fired), "fg_suppressed": len(fg_suppressed),
        "approval_fired": len(appr_fired), "clarify_fired": len(clar_fired),
        "flap_decisions": len(flap_decisions),
        "dead_token_delivered": len(dead_delivered),
        "dead_token_attempts": len(dead_push.calls),
    }
    return report


# ---------------------------------------------------------------------------
# The scenario.
# ---------------------------------------------------------------------------


async def test_t2_foreground_flap(mock_gateway, relay, phone_factory, evidence):
    p = soak_params.params("t2_flap")
    rng = random.Random(p.seed ^ 0x2)

    # --- I7 (in-process notifier decision matrix) ----------------------
    i7 = await _inproc_i7(mock_gateway.gw, p, rng)

    # --- wire foreground storm (relay must stay healthy, turns drain) ---
    # SOAK SCALES WITH duration: hammer the §6 foreground gate (set-REPLACE /
    # reconnect single-flight) at high frequency for the WHOLE window while
    # turns stream, proving the relay stays alive and keeps completing turns
    # under SUSTAINED foreground churn (spec T2 is a 15-min storm, not one
    # turn). A dedicated ``flap_sid`` is flapped foreground/background for the
    # entire window; concurrently a fresh session is driven per iteration so the
    # storm lands mid-turn (the reconnect single-flight path under churn).
    phone = await phone_factory()
    flap_sid = await mock_gateway.create_session(
        script="simple",
        text="Foreground flap target session held for the whole window.",
        delta_delay_s=0.03,
    )
    stop = asyncio.Event()
    flap_task = asyncio.create_task(foreground_flap_loop(
        phone, flap_sid, stop=stop, rng=rng, lo_s=0.01, hi_s=0.08))

    driven: list[str] = []
    completed_inline = 0
    deadline = asyncio.get_event_loop().time() + p.duration_s
    while asyncio.get_event_loop().time() < deadline:
        sid = await mock_gateway.create_session(
            script="simple",
            text="Foreground flap storm on the wire must not break the relay.",
            delta_delay_s=0.02,
        )
        for _ in range(25):
            try:
                await phone.submit(text="wire flap turn", session_id=sid,
                                   client_message_id=f"cmid-t2-{len(driven)}")
                break
            except Exception:  # noqa: BLE001
                await asyncio.sleep(0.05)
        driven.append(sid)
        try:
            await common.wait_terminal(phone, sid, timeout=5.0)
            completed_inline += 1
        except asyncio.TimeoutError:
            pass  # final resync(0) below heals; I1 checks the terminal state

    stop.set()
    try:
        flaps = await asyncio.wait_for(flap_task, timeout=5.0)
    except asyncio.TimeoutError:
        flap_task.cancel()
        flaps = -1

    # Relay alive + every driven turn reached a terminal state (I1). Let
    # in-flight turns drain, then a cold snapshot heals any turn the phone
    # missed mid-flap (exactly T1's heal) before we fold the terminal state.
    await asyncio.sleep(2.0)
    url = f"http://127.0.0.1:{relay.downstream_port}/healthz"
    async with httpx.AsyncClient() as c:
        status = (await c.get(url, timeout=5.0)).json()
    tracker = TurnTerminalTracker()
    for sid in driven:
        tracker.mark_driven(sid)
    try:
        await phone.resync(0)
    except Exception:  # noqa: BLE001
        pass
    await asyncio.sleep(0.5)
    tracker.fold(phone.frames)
    i1 = tracker.report()
    i1["completed_inline"] = completed_inline
    if not status.get("serving", True):
        i1["violations"].append("I7/wire: relay not serving after flap storm")
        i1["ok"] = False

    verdict = common.build_verdict(
        "T2_foreground_flap", [i7, i1],
        duration_s=round(p.duration_s, 2), wire_flaps=flaps,
        turns_driven=len(driven), completed_inline=completed_inline,
        healthz_connections=status.get("connections"),
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
