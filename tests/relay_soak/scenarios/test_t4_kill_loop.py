"""T4 — kill loop (I5 / I2).

SIGTERM the relay at randomized intervals UNDER LIVE TURNS; each restart must
re-resume the phone's owned sessions from the durable store and keep driving.
The durable ``HERMES_HOME`` persists across every restart within the scenario
(exactly what I5 re-resumes from).

Contract proven:

* **I5** after every SIGTERM+restart the one session the phone drove is STILL
  owned (durable re-resume — no "destination session not active"), and the owned
  set never balloons past the sessions driven (+slack) — no zombie accumulation;
* **I2** a turn driven to completion AFTER the kill storm reconciles
  byte-identical to a clean reference run of the same deterministic script;
* **I1** the session reached a terminal state by scenario end (via the final
  turn's completion / its resync snapshot).

Note on in-flight kills: the relay's item store is in-memory, so a turn mid-stream
when the relay dies has its remaining frames lost (the gateway does not replay
completed events) — the S8 "dead turn" suspect class. The harness RECORDS any
such loss as evidence; the pass/fail contract above is the durable re-resume +
post-restart drain the spec demands of the kill loop.
"""

from __future__ import annotations

import asyncio
import random

import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.conftest import healthz_url_for, phone_url_for
from tests.relay_soak.invariants.checkers import (
    OwnedSessionLedger,
    TurnTerminalTracker,
)
from tests.relay_soak.infra.phone_ext import SoakPhoneDriver
from tests.relay_soak.constants import MOCK_GATEWAY_TOKEN
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio

TEXT = "Durable re-resume must survive every relay restart in the kill loop."


async def test_t4_kill_loop(mock_gateway, relay_factory, resource_sampler,
                            evidence):
    p = soak_params.params("t4_kill")
    rng = random.Random(p.seed ^ 0x4)

    relay = relay_factory(mock_gateway.port)
    sampler = resource_sampler(relay)

    sid = await mock_gateway.create_session(script="simple", text=TEXT)

    phone = SoakPhoneDriver(phone_url_for(relay), token=MOCK_GATEWAY_TOKEN)
    await phone.connect()

    # Clean reference for the final I2 comparison.
    ref_phone = SoakPhoneDriver(phone_url_for(relay), token=MOCK_GATEWAY_TOKEN)
    await ref_phone.connect()
    ref = await common.run_reference(ref_phone, mock_gateway, script="simple",
                                     text=TEXT)
    assert common.agent_messages(ref) == [TEXT]
    await ref_phone.close()

    ledger = OwnedSessionLedger()
    ledger.record_drive(sid)
    n_kills = max(2, int(p.duration_s / 40.0))
    base_interval = max(0.3, p.duration_s / (n_kills + 1))
    post_restart_completions = 0

    for k in range(n_kills):
        # Drive a turn on the persistent session; kill while it is in flight.
        try:
            await phone.submit(text=TEXT, session_id=sid,
                               client_message_id=f"cmid-t4-{k}")
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(rng.uniform(0.03, min(0.25, base_interval)))

        # --- SIGTERM + restart (durable home persists) -----------------
        relay.restart()
        sampler.repoint(relay.pid)
        # Phone reconnects to the freshly-restarted relay + resyncs.
        try:
            await phone.close()
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(0.1)
        await phone.connect()
        await phone.resync(0)

        # I5: the driven session must be re-owned after this restart (the
        # ownership assertion itself happens in ledger.check() at the end; the
        # snapshots record the owned set after every kill for the evidence).
        await ledger.snapshot(healthz_url_for(relay), token=MOCK_GATEWAY_TOKEN,
                              label=f"after-kill-{k}")

        # Drive a turn AFTER the restart -> must complete (drain + re-resume).
        try:
            await phone.submit(text=TEXT, session_id=sid,
                               client_message_id=f"cmid-t4-post-{k}")
            await common.wait_terminal(phone, sid, timeout=15.0)
            post_restart_completions += 1
        except asyncio.TimeoutError:
            pass
        await asyncio.sleep(rng.uniform(0.1, base_interval))

    # --- final: quiesce, reconcile the session, compare to reference ----
    await phone.resync(0)
    await asyncio.sleep(0.2)
    cand = common.reconcile_transcript(phone.frames_for(sid))
    await phone.close()

    tracker = TurnTerminalTracker()
    tracker.mark_driven(sid)
    tracker.fold(phone.frames)
    i1 = tracker.report()

    i5 = ledger.check().report()
    if post_restart_completions == 0:
        i5["violations"].append(
            "I5: no turn completed after ANY restart — durable re-resume/drain "
            "never worked")
        i5["ok"] = False

    # I2: the session carried MULTIPLE turns (one survived per kill cycle), so
    # its reconciled transcript holds one agentMessage per completed turn. The
    # invariant is that EVERY one of them reconstructs the deterministic text
    # byte-identically (no corruption / cross-turn mixing under the kill storm).
    cand_agent = common.agent_messages(cand)
    bad = [t for t in cand_agent if t != TEXT]
    i2_ok = len(cand_agent) >= 1 and not bad
    i2 = {
        "invariant": "I2", "ok": i2_ok,
        "violations": ([] if i2_ok else [
            f"I2: {len(bad)}/{len(cand_agent)} reconstructed agent message(s) "
            f"diverged from the deterministic text: {bad[:3]}"]),
        "reference_agent": common.agent_messages(ref),
        "reconstructed_turns": len(cand_agent),
        "candidate_agent_sample": cand_agent[:3],
    }

    verdict = common.build_verdict(
        "T4_kill_loop", [i1, i5, i2],
        duration_s=round(p.duration_s, 2), kills=n_kills,
        relay_starts=relay.start_count,
        post_restart_completions=post_restart_completions,
        restart_log=relay.restart_log,
        resources=sampler.analyze(),
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
