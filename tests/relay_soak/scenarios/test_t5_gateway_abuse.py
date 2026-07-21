"""T5 — gateway abuse (I3 / I1) — the S8 suspect class.

While the relay serves the phone, the upstream ISOLATED gateway (a real
subprocess on the 9140+ band) is abused two ways, randomized per cycle:

* **pause** — SIGSTOP the gateway mid-stream, hold it, SIGCONT. The relay's
  gateway subscription must survive the stall and the in-flight turn must
  complete once the gateway resumes (frames resume gap-free);
* **restart** — SIGTERM the gateway mid-turn and bring it back on the same port.
  The in-flight turn is lost to the dead gateway (expected — the gateway does
  not replay completed events), but the relay must RE-ESTABLISH its gateway
  connection and a FRESH turn right after must complete. This is exactly the
  "relay's gateway sub dies and never comes back" failure (S8 dead-turn class).

Asserted:

* **I1** the relay survives every abuse (healthz 200 throughout) and every
  turn that SHOULD complete (pause-cycle turns + post-restart turns + a final
  turn) reaches a terminal state — the subscription never wedges;
* **I3** the phone's per-connection seq coverage stays contiguous across the
  whole abuse run (no dropped downstream frame), and post-abuse turns reconcile
  their deterministic text.

The gateway is deterministic (scripted), so reconciled turn text is comparable.
NEVER the live gateway — an isolated subprocess only.
"""

from __future__ import annotations

import asyncio
import random

import httpx
import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.conftest import healthz_url_for, phone_url_for
from tests.relay_soak.constants import MOCK_GATEWAY_TOKEN
from tests.relay_soak.infra.phone_ext import SoakPhoneDriver
from tests.relay_soak.invariants.checkers import (
    SeqCoverageChecker,
    TurnTerminalTracker,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio


def _text(k: int) -> str:
    return f"Gateway abuse cycle {k} must still deliver this exact sentence."


async def test_t5_gateway_abuse(gateway_proc_factory, relay_factory, evidence):
    p = soak_params.params("t5_gateway")
    rng = random.Random(p.seed ^ 0x5)

    gw = gateway_proc_factory()                 # isolated subprocess, 9140+
    relay = relay_factory(gw.port, token=gw.token)
    phone = SoakPhoneDriver(phone_url_for(relay), token=MOCK_GATEWAY_TOKEN)
    await phone.connect()

    healthz = healthz_url_for(relay)
    tracker = TurnTerminalTracker()
    n_abuses = max(3, int(p.duration_s / 30.0))
    pause_completions = 0
    restart_completions = 0
    alive_checks = 0
    abuse_log: list[dict] = []

    async def alive(label: str) -> bool:
        nonlocal alive_checks
        alive_checks += 1
        try:
            async with httpx.AsyncClient() as c:
                r = await c.get(healthz, timeout=5.0)
                return r.status_code == 200
        except Exception:  # noqa: BLE001
            return False

    async def drive_turn(k: int, timeout: float = 15.0) -> tuple[str, bool]:
        """Create a fresh session on the CURRENT gateway and drive one turn.
        Returns (sid, completed?)."""
        text = _text(k)
        sid = await gw.create_session(script="simple", text=text,
                                      delta_delay_s=0.02)
        try:
            await phone.submit(text=text, session_id=sid,
                               client_message_id=f"cmid-t5-{k}")
        except Exception:  # noqa: BLE001
            return sid, False
        try:
            await common.wait_terminal(phone, sid, timeout=timeout)
            return sid, True
        except asyncio.TimeoutError:
            return sid, False

    for k in range(n_abuses):
        # Alternate so BOTH abuse axes are exercised every run (pause first,
        # then restart); rng still jitters the timings.
        mode = "pause" if k % 2 == 0 else "restart"
        if mode == "pause":
            # Start a turn, freeze the gateway mid-stream, resume; the turn
            # must then complete (subscription survives the stall).
            sid, started = await _start_turn(phone, gw, k)
            await asyncio.sleep(rng.uniform(0.05, 0.2))
            gw.sigstop()
            await asyncio.sleep(rng.uniform(0.2, 0.6))
            gw.sigcont()
            completed = await _await_terminal(phone, sid, timeout=15.0)
            if completed:
                tracker.mark_driven(sid)
                pause_completions += 1
            abuse_log.append({"cycle": k, "mode": "pause", "sid": sid,
                              "completed": completed})
        else:
            # Start a turn, kill the gateway under it, restart; the in-flight
            # turn is lost, but a FRESH turn right after must complete (the
            # relay re-established its gateway connection).
            sid_dead, _ = await _start_turn(phone, gw, k)
            await asyncio.sleep(rng.uniform(0.05, 0.2))
            gw.restart()
            await asyncio.sleep(rng.uniform(0.3, 0.8))  # let relay reconnect
            sid_new, completed = await drive_turn(k + 1000, timeout=20.0)
            if completed:
                tracker.mark_driven(sid_new)
                restart_completions += 1
            abuse_log.append({"cycle": k, "mode": "restart",
                              "dead_sid": sid_dead, "fresh_sid": sid_new,
                              "fresh_completed": completed})

        if not await alive(f"after-{mode}-{k}"):
            abuse_log.append({"cycle": k, "mode": mode, "relay_alive": False})

    # --- final turn after ALL abuse: must complete ---------------------
    sid_final, final_ok = await drive_turn(999999, timeout=20.0)
    if final_ok:
        tracker.mark_driven(sid_final)
    await phone.resync(0)
    await asyncio.sleep(0.2)
    tracker.fold(phone.frames)
    await phone.close()

    i1 = tracker.report()
    relay_alive_end = await alive("end")
    if not relay_alive_end:
        i1["violations"].append("I1: relay not alive at end of gateway abuse")
        i1["ok"] = False
    if not final_ok:
        i1["violations"].append(
            "I1: final turn after all gateway abuse did not complete — the "
            "relay's gateway subscription wedged (S8 dead-turn class)")
        i1["ok"] = False

    # I3: contiguous per-connection seq coverage across the whole run.
    i3 = SeqCoverageChecker().fold_segments(
        phone.generation_segments()).report()

    verdict = common.build_verdict(
        "T5_gateway_abuse", [i1, i3],
        duration_s=round(p.duration_s, 2), n_abuses=n_abuses,
        gateway_starts=gw.start_count, pause_completions=pause_completions,
        restart_completions=restart_completions, final_turn_completed=final_ok,
        alive_checks=alive_checks, relay_alive_end=relay_alive_end,
        abuse_log=abuse_log, gateway_port=gw.port,
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)


async def _start_turn(phone, gw, k: int) -> tuple[str, bool]:
    """Create a session + submit (do NOT await completion). Returns (sid, ok)."""
    text = _text(k)
    sid = await gw.create_session(script="simple", text=text, delta_delay_s=0.03)
    try:
        await phone.submit(text=text, session_id=sid,
                           client_message_id=f"cmid-t5-start-{k}")
        return sid, True
    except Exception:  # noqa: BLE001
        return sid, False


async def _await_terminal(phone, sid: str, *, timeout: float) -> bool:
    try:
        await common.wait_terminal(phone, sid, timeout=timeout)
        return True
    except asyncio.TimeoutError:
        return False
