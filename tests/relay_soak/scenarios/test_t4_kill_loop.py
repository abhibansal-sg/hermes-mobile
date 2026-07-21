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
import os
import random
import time

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


def _env_float(name: str):
    raw = os.environ.get(name)
    if raw is None or not raw.strip():
        return None
    try:
        return float(raw)
    except ValueError:
        return None


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

    # Kill schedule. Spec: "kill -TERM every 30-120s (randomized)". The lane
    # runner pins the literal interval via SOAK_T4_KILL_MIN_S / MAX_S (real
    # seconds, NOT scaled — the scenario's DURATION scales with SOAK_SCALE,
    # the kill cadence is the parameter under test). Without the env knobs the
    # original denser derived schedule runs (short-mode / CI behavior).
    kill_min = _env_float("SOAK_T4_KILL_MIN_S")
    kill_max = _env_float("SOAK_T4_KILL_MAX_S")
    interval_mode = kill_min is not None or kill_max is not None
    kill_min = kill_min if kill_min is not None else 30.0
    kill_max = kill_max if kill_max is not None else 120.0
    if kill_max < kill_min:
        kill_min, kill_max = kill_max, kill_min

    if interval_mode:
        mean_interval = (kill_min + kill_max) / 2.0
        n_kills = max(2, int(p.duration_s / mean_interval) + 2)
        base_interval = mean_interval
    else:
        n_kills = max(2, int(p.duration_s / 40.0))
        base_interval = max(0.3, p.duration_s / (n_kills + 1))
    post_restart_completions = 0
    interrupted: list[dict] = []
    kills_done = 0
    t0 = time.monotonic()

    for k in range(n_kills):
        cycle_t0 = time.monotonic()
        if interval_mode and (cycle_t0 - t0) >= p.duration_s:
            break
        # Drive a turn on the persistent session; kill while it is in flight.
        wm_pre = len(phone.frames)
        try:
            await phone.submit(text=TEXT, session_id=sid,
                               client_message_id=f"cmid-t4-{k}")
        except Exception:  # noqa: BLE001
            pass
        await asyncio.sleep(
            rng.uniform(0.03, 0.25) if interval_mode
            else rng.uniform(0.03, min(0.25, base_interval)))

        # --- SIGTERM + restart (durable home persists) -----------------
        relay.restart()
        kills_done += 1
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

        # Evidence: did the PRE-kill turn's terminal survive the kill? (The
        # relay's item store is in-memory; a turn mid-stream when the relay
        # dies is the S8 "dead turn" class — recorded, not a kill-loop failure.)
        pre_terminal = phone.count_kind_after("turn.completed", wm_pre,
                                              sid=sid) > 0

        # Drive a turn AFTER the restart -> must complete (drain + re-resume).
        # Watermark the wait so the PREVIOUS cycle's terminal frame can't
        # satisfy it (multi-turn log — a stale match made this check vacuous).
        wm_post = len(phone.frames)
        post_ok = False
        try:
            await phone.submit(text=TEXT, session_id=sid,
                               client_message_id=f"cmid-t4-post-{k}")
            await common.wait_terminal(phone, sid, timeout=15.0,
                                       after_index=wm_post)
            post_ok = True
            post_restart_completions += 1
        except asyncio.TimeoutError:
            pass
        interrupted.append({
            "kill": k, "t": round(cycle_t0 - t0, 2),
            "pre_turn_survived_kill": pre_terminal,
            "post_restart_turn_completed": post_ok,
        })
        if interval_mode:
            # Kill-to-kill interval ≈ uniform(kill_min, kill_max) (the cycle's
            # own work eats part of the budget; never shorter than target).
            target = rng.uniform(kill_min, kill_max)
            elapsed = time.monotonic() - cycle_t0
            await asyncio.sleep(max(0.0, target - elapsed))
        else:
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
    # invariant is that EVERY COMPLETED one reconstructs the deterministic text
    # byte-identically (no corruption / cross-turn mixing under the kill
    # storm). NON-completed agentMessage skeletons belong to turns that were
    # mid-stream when a SIGTERM landed (the S8 in-flight-loss class the
    # docstring above declares out of kill-loop contract) — counted as evidence
    # (``partial_agent_items``), not as an I2 violation.
    cand_agent = common.agent_messages(cand, completed_only=True)
    cand_agent_all = common.agent_messages(cand)
    partial = len(cand_agent_all) - len(cand_agent)
    bad = [t for t in cand_agent if t != TEXT]
    i2_ok = len(cand_agent) >= 1 and not bad
    i2 = {
        "invariant": "I2", "ok": i2_ok,
        "violations": ([] if i2_ok else [
            f"I2: {len(bad)}/{len(cand_agent)} reconstructed COMPLETED agent "
            f"message(s) diverged from the deterministic text: {bad[:3]}"]),
        "reference_agent": common.agent_messages(ref),
        "reconstructed_turns": len(cand_agent),
        "partial_agent_items": partial,
        "candidate_agent_sample": cand_agent[:3],
    }

    verdict = common.build_verdict(
        "T4_kill_loop", [i1, i5, i2],
        duration_s=round(p.duration_s, 2),
        wall_s=round(time.monotonic() - t0, 1),
        kills=kills_done,
        kill_schedule=(f"uniform({kill_min},{kill_max})s"
                       if interval_mode else "derived-dense"),
        relay_starts=relay.start_count,
        post_restart_completions=post_restart_completions,
        restart_log=relay.restart_log,
        kill_cycles=interrupted,
        pre_turns_lost_to_kill=sum(
            1 for c in interrupted if not c["pre_turn_survived_kill"]),
        resources=sampler.analyze(),
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
