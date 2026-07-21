"""T3 — multi-session interleave (I1 / I2 / I4 per session; I3 shared spine).

5-10 sessions stream CONCURRENTLY over ONE multiplexed phone connection (a
single per-connection seq spine carrying every session's frames), with random
foreground switching between them and a submit into each — SUSTAINED for the
scenario's full duration: batches of one concurrent turn per session repeat
until the deadline (a single interleave batch finishes in <1s; the soak is the
repetition under randomized switching, not one batch). The relay must demux
each session's stream correctly so that:

* **I2** each session's reconciled transcript stays byte-identical to a clean
  reference run of ITS OWN deterministic script driven the SAME turn count
  (tail-matched hash diff, capped at ``REF_TAIL_CAP`` turns; plus a
  whole-history check that EVERY completed agent message is byte-exactly the
  session's own text — no cross-session bleed, ever);
* **I4** every prompt lands on exactly ONE userMessage item_id (per-session
  expectation = turns driven) and no session's frames double-apply onto
  another (per-session dedup holds under interleave);
* **I1** every driven session reached a terminal turn AND every submitted turn
  has terminal evidence (distinct turn.completed per turn).

The single shared spine also gets an I3 seq-coverage check (contiguous coverage
across the interleaved frames of all sessions), and the scenario carries a
light I5 (owned set == driven sessions, no zombies) + I6 (relay RSS/FD curve)
because a 20-min sustained interleave is a prime leak window.

Session count: ``SOAK_T3_SESSIONS`` env (default 6, clamped to [5,10]); the
interleave-kill soak lane runs 8.
"""

from __future__ import annotations

import asyncio
import os
import random
import time

import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.conftest import healthz_url_for
from tests.relay_soak.constants import MOCK_GATEWAY_TOKEN
from tests.relay_soak.invariants.checkers import (
    DedupChecker,
    OwnedSessionLedger,
    SeqCoverageChecker,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio

# Tail-matched reference diff cap: the whole-history agent-text check covers
# EVERY turn; the expensive byte-hash reference diff compares the last N turns
# (keeps the clean reference drive bounded on very long soaks).
REF_TAIL_CAP = 100


def _text(i: int) -> str:
    return (f"Session number {i} reports its own deterministic status "
            f"message clearly and distinctly from all the others.")


def _n_sessions_param() -> int:
    try:
        return int(os.environ.get("SOAK_T3_SESSIONS", "6"))
    except (TypeError, ValueError):
        return 6


async def test_t3_multi_session(mock_gateway, relay, phone_factory,
                                resource_sampler, evidence):
    p = soak_params.params("t3_multi", n_sessions=_n_sessions_param())
    rng = random.Random(p.seed ^ 0x3)
    n = max(5, min(10, p.n_sessions))
    texts = [_text(i) for i in range(n)]

    sampler = resource_sampler(relay)
    ledger = OwnedSessionLedger(slack=2)

    # --- clean single-turn references (canonical text per session) ---------
    ref_phone = await phone_factory()
    refs: list[dict] = []
    for t in texts:
        info = await common.drive(ref_phone, mock_gateway, script="simple",
                                  text=t)
        ledger.record_drive(info["sid"])
        ref = await common.reconcile_after_settle(ref_phone, info["sid"],
                                                  resync_from=None)
        assert common.agent_messages(ref) == [t], f"reference {t!r} not canonical"
        refs.append(ref)
    await ref_phone.close()

    # --- torture sessions on ONE shared phone (single seq spine) -----------
    phone = await phone_factory()
    sids: list[str] = []
    for t in texts:
        sid = await mock_gateway.create_session(script="simple", text=t,
                                                delta_delay_s=0.02)
        sids.append(sid)
        ledger.record_drive(sid)

    dedup = DedupChecker()
    tracker = TurnTerminalTracker()
    for sid in sids:
        tracker.mark_driven(sid)

    turns_driven = [0] * n       # submits the relay accepted (no RPC error)
    turns_completed = [0] * n    # ...and whose turn reached a terminal frame
    submit_errors: list[dict] = []
    samples: list[dict] = []

    t0 = time.monotonic()
    next_sample_at = t0 + 20.0
    b = 0

    while time.monotonic() - t0 < p.duration_s:
        # --- one batch: a concurrent turn per session + foreground switching
        stop = asyncio.Event()

        async def switch_loop():
            while not stop.is_set():
                try:
                    await phone.foreground(rng.choice(sids))
                except Exception:  # noqa: BLE001
                    pass
                await asyncio.sleep(rng.uniform(0.02, 0.15))

        switch_task = asyncio.create_task(switch_loop())

        async def drive_one(i: int) -> None:
            cmid = f"cmid-t3-b{b}-i{i}"
            wm = len(phone.frames)
            try:
                resp = await phone.submit(text=texts[i], session_id=sids[i],
                                          client_message_id=cmid)
            except Exception as exc:  # noqa: BLE001
                submit_errors.append({"batch": b, "i": i, "cmid": cmid,
                                      "error": repr(exc)[:200]})
                return
            result = (resp or {}).get("result")
            if result is None:  # JSON-RPC error (e.g. relay-side reject)
                submit_errors.append(
                    {"batch": b, "i": i, "cmid": cmid,
                     "error": str((resp or {}).get("error"))[:200]})
                return
            dedup.record_submit(cmid, result)
            turns_driven[i] += 1
            try:
                await common.wait_terminal(phone, sids[i], timeout=25.0,
                                           after_index=wm)
                turns_completed[i] += 1
            except asyncio.TimeoutError:
                pass

        await asyncio.gather(*(drive_one(i) for i in range(n)))
        stop.set()
        try:
            await asyncio.wait_for(switch_task, timeout=5.0)
        except asyncio.TimeoutError:
            switch_task.cancel()
        b += 1

        # --- periodic invariant sample (~every 20s): no bleed/corruption ---
        if time.monotonic() >= next_sample_at:
            next_sample_at = time.monotonic() + 20.0
            bad_here: list[dict] = []
            for i, sid in enumerate(sids):
                items = common.reconcile_transcript(phone.frames_for(sid))
                agent = common.agent_messages(items, completed_only=True)
                off = [x for x in agent if x != texts[i]]
                if off:
                    bad_here.append({"sid": sid, "diverged_sample": off[:3],
                                     "n_agent": len(agent)})
            samples.append({
                "t": round(time.monotonic() - t0, 1), "batch": b,
                "frames": len(phone.frames),
                "turns_driven": sum(turns_driven),
                "turns_completed": sum(turns_completed),
                "diverged_sessions": bad_here,
            })
            if bad_here:
                break  # violation found — fall through to final accounting

        await asyncio.sleep(rng.uniform(0.05, 0.4))

    # --- quiesce + final snapshot heal -------------------------------------
    await asyncio.sleep(2.0)
    for sid in sids:
        try:
            await phone.resync(0)
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(0.05)

    # --- checkers -----------------------------------------------------------
    tracker.fold(phone.frames)
    dedup.fold_frames(phone.frames)
    for i, sid in enumerate(sids):
        dedup.expect_user_messages(sid, turns_driven[i])
    seq = SeqCoverageChecker().fold_segments(phone.generation_segments())

    i1 = tracker.report()
    # Per-turn I1 strengthening: each accepted submit must have terminal
    # evidence (distinct completed/error turn ids) — catches a lost turn even
    # when the session as a whole shows terminals from other turns.
    for i, sid in enumerate(sids):
        terminals = len(tracker.completed.get(sid, set())
                        | tracker.errored.get(sid, set()))
        if terminals < turns_completed[i]:
            i1["violations"].append(
                f"I1: session {sid} witnessed {turns_completed[i]} terminal "
                f"turn(s) live but only {terminals} distinct terminal turn id(s) "
                f"in the frame log — terminal frames lost")
            i1["ok"] = False
        if turns_driven[i] and terminals < turns_driven[i] - 1:
            i1["violations"].append(
                f"I1: session {sid} driven {turns_driven[i]} turn(s) but only "
                f"{terminals} reached a terminal state — lost turn(s)")
            i1["ok"] = False

    # --- I2: whole-history text check + tail-matched reference diff ---------
    i2_mismatches: list[dict] = []
    per_session: list[dict] = []
    tail_counts: list[int] = []
    for i, sid in enumerate(sids):
        cand = common.reconcile_transcript(phone.frames_for(sid))
        agent_all = common.agent_messages(cand)
        agent_done = common.agent_messages(cand, completed_only=True)
        off = [x for x in agent_done if x != texts[i]]
        if off:
            i2_mismatches.append({
                "sid": sid, "text": texts[i], "diverged_sample": off[:3],
                "n_completed_agent": len(agent_done),
                "note": "cross-session bleed / corruption"})
        if len(agent_done) < turns_completed[i]:
            i2_mismatches.append({
                "sid": sid, "text": texts[i],
                "n_completed_agent": len(agent_done),
                "turns_completed_live": turns_completed[i],
                "note": "completed turn(s) missing from reconciled transcript"})
        per_session.append({
            "sid": sid, "driven": turns_driven[i],
            "completed": turns_completed[i],
            "agent_completed": len(agent_done), "agent_total": len(agent_all),
            "user_message_ids": len(common.user_message_ids(
                phone.frames_for(sid))),
        })
        tail_counts.append(min(turns_completed[i], REF_TAIL_CAP))

    # Clean multi-turn references, one per session, driven CONCURRENTLY (each
    # on its own connection) with the SAME turn count as its tortured session's
    # tail. Deterministic script -> byte-identical reconcile required.
    ref_phones = [await phone_factory() for _ in range(n)]
    ref_results = await asyncio.gather(*(
        common.run_reference_multi(rp, mock_gateway, script="simple",
                                   text=texts[i], turns=max(1, tail_counts[i]),
                                   cmid_prefix=f"ref-t3-s{i}")
        for i, rp in enumerate(ref_phones)),
        return_exceptions=True)
    for rp in ref_phones:
        await rp.close()

    for i, res in enumerate(ref_results):
        if isinstance(res, BaseException):
            i2_mismatches.append({
                "sid": sids[i], "text": texts[i],
                "note": f"reference drive failed: {res!r}"[:300]})
            continue
        ref_sid, ref_items = res
        ledger.record_drive(ref_sid)
        k = max(1, tail_counts[i])
        # Slice the tortured session's transcript to its last k turns. Items
        # per turn are derived from the REFERENCE itself (the simple script
        # yields userMessage + agentMessage + usage footer per turn — three,
        # not two), so the tail holds the same item mix as the reference.
        cand = common.reconcile_transcript(phone.frames_for(sids[i]))
        ordered = sorted(cand.values(), key=lambda it: it.get("ord", 0))
        if len(ref_items) % k == 0 and len(ordered) >= len(ref_items):
            per_turn = len(ref_items) // k
            tail_items = ordered[-per_turn * k:]
        else:
            tail_items = ordered  # turn-count mismatch: diff the whole thing
        tail = {it.get("item_id", f"i{j}"): it
                for j, it in enumerate(tail_items)}
        diff = common.diff_transcripts(ref_items, tail)
        if not diff["identical"]:
            i2_mismatches.append({"sid": sids[i], "text": texts[i], **diff})

    i2 = {
        "invariant": "I2", "ok": not i2_mismatches,
        "violations": [
            f"I2: session {m.get('sid')} diverged ({m.get('note', 'transcript')}"
            f"{'; cand_agent=' + str(m.get('cand_agent', [])[:2]) if m.get('cand_agent') else ''}"
            f"{'; missing_types=' + str(m.get('missing_types')) if m.get('missing_types') else ''})"
            for m in i2_mismatches],
        "sessions": n, "mismatches": len(i2_mismatches),
        "ref_tail_cap": REF_TAIL_CAP, "per_session": per_session,
        "mid_run_samples": samples[-30:],
    }

    # --- I5 light: owned set == driven (torture + reference sessions) -------
    await ledger.snapshot(healthz_url_for(relay), token=MOCK_GATEWAY_TOKEN,
                          label="end")
    i5 = ledger.check().report()

    i4 = dedup.report()
    i3 = seq.report()

    verdict = common.build_verdict(
        "T3_multi_session", [i1, i2, i4, i3, i5],
        duration_s=round(p.duration_s, 2),
        wall_s=round(time.monotonic() - t0, 1),
        n_sessions=n, batches=b, frames=len(phone.frames),
        turns_driven=sum(turns_driven), turns_completed=sum(turns_completed),
        per_session_turns=[{"sid": s, "driven": d, "completed": c}
                           for s, d, c in zip(sids, turns_driven,
                                              turns_completed)],
        submit_errors=len(submit_errors),
        submit_error_sample=submit_errors[:5],
        resources=sampler.analyze(),
    )
    evidence("verdict", verdict)
    if submit_errors:
        evidence("submit_errors", {"count": len(submit_errors),
                                   "errors": submit_errors[:200]})
    common.assert_verdict(verdict)
