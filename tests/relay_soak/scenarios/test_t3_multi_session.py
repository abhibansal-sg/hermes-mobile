"""T3 — multi-session interleave (I1 / I2 / I4 per session).

5-10 sessions stream CONCURRENTLY over ONE multiplexed phone connection (a
single per-connection seq spine carrying every session's frames), with random
foreground switching between them and a submit into each. The relay must demux
each session's stream correctly so that:

* **I2** each session's reconciled transcript is byte-identical to a clean
  reference run of ITS OWN deterministic script (no cross-session bleed);
* **I4** each session's prompt lands on exactly ONE userMessage item_id and no
  session's frames double-apply onto another (per-session dedup holds under
  interleave);
* **I1** every driven session reached a terminal turn.

The single shared spine also gets an I3 seq-coverage check (contiguous coverage
across the interleaved frames of all sessions).
"""

from __future__ import annotations

import asyncio
import random

import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.invariants.checkers import (
    DedupChecker,
    SeqCoverageChecker,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio


def _text(i: int) -> str:
    return (f"Session number {i} reports its own deterministic status "
            f"message clearly and distinctly from all the others.")


async def test_t3_multi_session(mock_gateway, relay, phone_factory, evidence):
    p = soak_params.params("t3_multi", n_sessions=6)
    rng = random.Random(p.seed ^ 0x3)
    n = max(5, min(10, p.n_sessions))

    texts = [_text(i) for i in range(n)]

    # --- clean references (one per distinct text) ----------------------
    ref_phone = await phone_factory()
    refs: list[dict] = []
    for t in texts:
        ref = await common.run_reference(ref_phone, mock_gateway,
                                         script="simple", text=t)
        refs.append(ref)
        assert common.agent_messages(ref) == [t], f"reference {t!r} not canonical"
    await ref_phone.close()

    # --- interleaved torture drive on ONE shared phone ------------------
    phone = await phone_factory()
    sids: list[str] = []
    cmids: list[str] = []
    for i, t in enumerate(texts):
        sid = await mock_gateway.create_session(script="simple", text=t,
                                                delta_delay_s=0.02)
        sids.append(sid)
        cmids.append(f"cmid-t3-{i}")

    dedup = DedupChecker()

    async def drive_one(i: int) -> None:
        resp = await phone.submit(text=texts[i], session_id=sids[i],
                                  client_message_id=cmids[i])
        dedup.record_submit(cmids[i], (resp or {}).get("result") or {})
        try:
            await common.wait_terminal(phone, sids[i], timeout=25.0)
        except asyncio.TimeoutError:
            pass

    # Random foreground switching while the turns stream concurrently.
    stop = asyncio.Event()

    async def switch_loop():
        while not stop.is_set():
            try:
                await phone.foreground(rng.choice(sids))
            except Exception:  # noqa: BLE001
                pass
            await asyncio.sleep(rng.uniform(0.02, 0.15))

    switch_task = asyncio.create_task(switch_loop())
    await asyncio.gather(*(drive_one(i) for i in range(n)))
    stop.set()
    try:
        await asyncio.wait_for(switch_task, timeout=5.0)
    except asyncio.TimeoutError:
        switch_task.cancel()

    # --- reconcile + compare each session to its own reference ----------
    tracker = TurnTerminalTracker()
    i2_mismatches: list[dict] = []
    for i, sid in enumerate(sids):
        await phone.resync(0)
        await asyncio.sleep(0.05)
        cand = common.reconcile_transcript(phone.frames_for(sid))
        diff = common.diff_transcripts(refs[i], cand)
        if not diff["identical"]:
            i2_mismatches.append({"sid": sid, "text": texts[i], **diff})
        tracker.mark_driven(sid)
        # Cross-session bleed guard: this session's agent text must be ITS OWN.
        agent = common.agent_messages(cand)
        if agent and agent != [texts[i]]:
            i2_mismatches.append({
                "sid": sid, "text": texts[i],
                "identical": False, "cand_agent": agent,
                "missing_types": [], "note": "cross-session bleed"})
    tracker.fold(phone.frames)
    dedup.fold_frames(phone.frames)
    seq = SeqCoverageChecker().fold_segments(phone.generation_segments())

    i1 = tracker.report()
    i4 = dedup.report()
    i3 = seq.report()
    i2 = {
        "invariant": "I2", "ok": not i2_mismatches,
        "violations": [
            f"I2: session {m['sid']} diverged (cand_agent={m.get('cand_agent')}, "
            f"missing_types={m.get('missing_types')}, {m.get('note', 'transcript')})"
            for m in i2_mismatches],
        "sessions": n, "mismatches": len(i2_mismatches),
    }

    verdict = common.build_verdict(
        "T3_multi_session", [i1, i2, i4, i3],
        duration_s=round(p.duration_s, 2), n_sessions=n,
        frames=len(phone.frames),
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
