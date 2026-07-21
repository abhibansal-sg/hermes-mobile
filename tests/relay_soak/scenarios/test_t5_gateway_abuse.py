"""T5 — gateway abuse (I1 / I3, + I2-lite) — the S8 suspect class.

While turns stream CONTINUOUSLY through the relay, the upstream ISOLATED
gateway (a real subprocess in the lane's 9140+ slice) is abused on THREE
rotating axes:

* **pause** — SIGSTOP the gateway mid-stream, hold briefly, SIGCONT. The
  relay's gateway subscription must survive the stall; the in-flight turn
  completes once the gateway resumes (frames resume gap-free);
* **restart** — SIGTERM the gateway mid-turn and bring it back on the SAME
  port. The in-flight turn is lost to the dead gateway (EXPECTED — the
  gateway does not replay completed events), but the relay must RE-ESTABLISH
  its gateway connection and a FRESH turn right after must complete. This is
  exactly the "relay's gateway sub dies and never comes back" S8 dead-turn
  failure;
* **slow** — the spec's "made slow" axis: a slow-drip stream (large per-delta
  delay) interrupted mid-stream by a LONG SIGSTOP stall (seconds, not
  tenths). The turn must still complete after SIGCONT — the relay must not
  mistake a slow/stalled gateway for a dead one and wedge the turn.

Pacing: in ``soak`` mode abuse cycles rotate until ``duration_s`` (30 min) of
WALL CLOCK has elapsed, with normal turns streaming in the 20-40 s gaps
between abuses (the "while turns stream" half of the spec). In ``short`` mode
a bounded cycle count keeps CI fast.

Asserted:

* **I1** the relay survives every abuse (healthz 200 throughout) and every
  turn that SHOULD complete (pause/slow-cycle turns, post-restart fresh
  turns, background turns, the final turn) reaches a terminal state — the
  subscription never wedges. A timed-out turn first gets the production
  recovery path (resync(0) cold snapshot) before being called dead;
* **I3** the phone's per-connection seq coverage stays contiguous across the
  whole abuse run (no dropped downstream frame);
* **I2-lite** every COMPLETED turn reconciles to EXACTLY the deterministic
  scripted text (the gateway is scripted, so the bytes are known in advance).

Turns in flight when their gateway is SIGTERMed are recorded as
``abandoned_inflight`` — an expected loss, never marked driven. NEVER the
live gateway — an isolated subprocess only (lane slice via SOAK_PORT_LO/HI).
"""

from __future__ import annotations

import asyncio
import os
import random
import time

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
from tests.relay_soak.invariants.transcript import (
    agent_messages,
    reconcile_transcript,
)
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio

AXES = ("pause", "restart", "slow")


def _text(tag: str, k: int) -> str:
    return f"Gateway abuse {tag} turn {k} must still deliver this exact sentence."


async def test_t5_gateway_abuse(gateway_proc_factory, relay_factory,
                                resource_sampler, evidence):
    p = soak_params.params("t5_gateway")
    rng = random.Random(p.seed ^ 0x5)
    soak = soak_params.mode() == "soak"

    gw = gateway_proc_factory()                 # isolated subprocess, lane slice
    relay = relay_factory(gw.port, token=gw.token)
    sampler = resource_sampler(relay)
    phone = SoakPhoneDriver(phone_url_for(relay), token=MOCK_GATEWAY_TOKEN)
    await phone.connect()

    healthz = healthz_url_for(relay)
    tracker = TurnTerminalTracker()
    abuse_log: list[dict] = []
    load_samples: list[dict] = []
    text_mismatches: list[dict] = []
    n_text_checked = 0
    counters = {a: 0 for a in ("pause_ok", "pause_fail", "restart_ok",
                               "restart_fail", "slow_ok", "slow_fail",
                               "bg_ok", "bg_fail", "final_ok",
                               "alive_fail", "abandoned_inflight")}
    alive_checks = 0

    # Timeouts: soak gets headroom because the QA-3 swarm shares this machine
    # (a scheduling stall must not masquerade as a dead turn); short stays snappy.
    T_BG = 30.0 if soak else 15.0
    T_PAUSE = 40.0 if soak else 20.0
    T_SLOW = 60.0 if soak else 25.0
    T_FRESH = 40.0 if soak else 20.0
    ALIVE_TO = 10.0 if soak else 5.0

    t0 = time.monotonic()

    # -- intensity knobs per mode ---------------------------------------
    if soak:
        pause_hold = (0.3, 1.5)        # brief freeze (pause axis)
        slow_hold = (2.5, 6.0)         # LONG stall (slow axis — "made slow")
        slow_delta = (0.25, 0.60)      # slow-drip per-word delay
        restart_settle = (0.8, 2.0)    # let the relay re-establish
        gap_s = (20.0, 40.0)           # background traffic between abuses
        bg_pause = (0.05, 0.40)
    else:
        pause_hold = (0.2, 0.6)
        slow_hold = (1.0, 2.0)
        slow_delta = (0.08, 0.15)
        restart_settle = (0.3, 0.8)
        gap_s = (0.6, 1.5)
        bg_pause = (0.02, 0.15)

    def note_load(label: str) -> None:
        try:
            load1 = os.getloadavg()[0]
        except OSError:
            load1 = -1.0
        load_samples.append({"t": round(time.monotonic() - t0, 1),
                             "label": label, "load1": round(load1, 2)})

    async def alive(label: str) -> bool:
        nonlocal alive_checks
        alive_checks += 1
        try:
            async with httpx.AsyncClient() as c:
                r = await c.get(healthz, timeout=ALIVE_TO)
                ok = r.status_code == 200
        except Exception:  # noqa: BLE001
            ok = False
        if not ok:
            counters["alive_fail"] += 1
            abuse_log.append({"t": round(time.monotonic() - t0, 1),
                              "event": "relay_not_alive", "label": label})
        return ok

    def has_terminal_evidence(sid: str) -> bool:
        """Terminal evidence for ``sid`` in the phone's frame log (per-sid fold)."""
        probe = TurnTerminalTracker()
        probe.mark_driven(sid)
        probe.fold(phone.frames_for(sid))
        return probe.report()["ok"]

    async def await_terminal_healed(sid: str, timeout: float) -> bool:
        """Wait for terminal; on timeout, run the production recovery path
        (resync(0) cold snapshot) and re-check before declaring the turn dead."""
        try:
            await common.wait_terminal(phone, sid, timeout=timeout)
            return True
        except asyncio.TimeoutError:
            pass
        try:
            await phone.resync(0)
            await asyncio.sleep(0.5)
        except Exception:  # noqa: BLE001
            pass
        return has_terminal_evidence(sid)

    def check_text(sid: str, expected: str) -> None:
        """I2-lite: a completed turn must reconcile to exactly the scripted text."""
        nonlocal n_text_checked
        n_text_checked += 1
        items = reconcile_transcript(phone.frames_for(sid))
        got = agent_messages(items)
        if got != [expected]:
            text_mismatches.append({"sid": sid, "expected": expected, "got": got})

    async def drive_turn(tag: str, k: int, timeout: float, *,
                         delta_delay: float = 0.02) -> tuple[str, bool, str]:
        """Create a fresh session on the CURRENT gateway, submit, await terminal.

        Strict I1: the session is marked DRIVEN as soon as the submit succeeds —
        any submitted turn with no terminal evidence (after the resync heal) is
        a dead turn and MUST surface as an I1 violation. A create_session
        failure is gateway-side (harness timing), not a relay fault, and is
        NOT marked driven.
        """
        text = _text(tag, k)
        try:
            sid = await gw.create_session(script="simple", text=text,
                                          delta_delay_s=delta_delay)
        except Exception as exc:  # noqa: BLE001
            return "", False, f"create_session failed: {exc}"
        try:
            await phone.submit(text=text, session_id=sid,
                               client_message_id=f"cmid-t5-{tag}-{k}")
        except Exception as exc:  # noqa: BLE001
            tracker.mark_driven(sid)   # the relay took the session; no terminal = dead
            return sid, False, f"submit failed: {exc}"
        tracker.mark_driven(sid)
        ok = await await_terminal_healed(sid, timeout)
        if ok:
            check_text(sid, text)
        return sid, ok, "" if ok else "no terminal (timeout + resync heal)"

    async def start_turn(tag: str, k: int, *, delta_delay: float = 0.03,
                         mark: bool = True) -> tuple[str, bool]:
        """Create + submit WITHOUT awaiting completion. Returns (sid, ok).

        ``mark`` (default True) marks the session driven once submitted — the
        pause/slow axes EXPECT that turn to complete. The restart axis passes
        ``mark=False``: its in-flight turn is deliberately killed with the
        gateway (expected loss, never driven).
        """
        text = _text(tag, k)
        try:
            sid = await gw.create_session(script="simple", text=text,
                                          delta_delay_s=delta_delay)
        except Exception:  # noqa: BLE001
            return "", False
        try:
            await phone.submit(text=text, session_id=sid,
                               client_message_id=f"cmid-t5-{tag}-{k}")
        except Exception:  # noqa: BLE001
            if mark:
                tracker.mark_driven(sid)
            return sid, False
        if mark:
            tracker.mark_driven(sid)
        return sid, True

    async def bg_stream(until: float, start_idx: int) -> int:
        """Stream normal turns until ``until`` (monotonic). Returns next index."""
        k = start_idx
        while time.monotonic() < until:
            sid, ok, why = await drive_turn("bg", k, T_BG)
            counters["bg_ok" if ok else "bg_fail"] += 1
            if not ok:
                note_load(f"bg-fail-{k}")
                abuse_log.append({"t": round(time.monotonic() - t0, 1),
                                  "event": "bg_turn_failed", "sid": sid,
                                  "k": k, "why": why,
                                  "load1": load_samples[-1]["load1"]
                                  if load_samples else None})
            if k % 25 == 0:
                note_load(f"bg-{k}")
            k += 1
            await asyncio.sleep(rng.uniform(*bg_pause))
        return k

    # -- main abuse loop ---------------------------------------------------
    deadline = t0 + p.duration_s
    if soak:
        n_cycles = None                     # run the clock, not a counter
    else:
        n_cycles = max(3, int(p.duration_s / 30.0))
    cycle = 0
    bg_idx = 0

    while (time.monotonic() < deadline) if soak else (cycle < n_cycles):
        axis = AXES[cycle % 3]              # rotate: all 3 axes every run
        note_load(f"cycle-{cycle}-{axis}")
        cyc: dict = {"cycle": cycle, "axis": axis,
                     "t": round(time.monotonic() - t0, 1)}

        if axis == "pause":
            sid, _ = await start_turn("pause", cycle)   # marked driven on submit
            await asyncio.sleep(rng.uniform(0.05, 0.2))
            gw.sigstop()
            hold = rng.uniform(*pause_hold)
            await asyncio.sleep(hold)
            gw.sigcont()
            ok = await await_terminal_healed(sid, T_PAUSE) if sid else False
            if ok:
                check_text(sid, _text("pause", cycle))
            counters["pause_ok" if ok else "pause_fail"] += 1
            cyc.update({"sid": sid, "hold_s": round(hold, 2), "completed": ok})

        elif axis == "restart":
            # In-flight turn dies WITH the gateway (expected loss → mark=False).
            sid_dead, _ = await start_turn("restart", cycle, mark=False)
            await asyncio.sleep(rng.uniform(0.05, 0.2))
            await asyncio.to_thread(gw.restart)   # non-blocking relay/phone
            await asyncio.sleep(rng.uniform(*restart_settle))
            # The FRESH turn after restart MUST complete (strict I1 — this is
            # the S8 "gateway sub never comes back" signal).
            sid_new, ok, why = await drive_turn("fresh", cycle + 1000, T_FRESH)
            counters["restart_ok" if ok else "restart_fail"] += 1
            counters["abandoned_inflight"] += 1
            cyc.update({"dead_sid": sid_dead, "fresh_sid": sid_new,
                        "fresh_completed": ok, "why": why,
                        "gateway_starts": gw.start_count})

        else:  # slow — the "made slow" axis: slow drip + LONG mid-stream stall
            dd = rng.uniform(*slow_delta)
            sid, _ = await start_turn("slow", cycle, delta_delay=dd)
            await asyncio.sleep(rng.uniform(0.4, 1.2))  # a few deltas in
            gw.sigstop()
            hold = rng.uniform(*slow_hold)
            await asyncio.sleep(hold)
            gw.sigcont()
            ok = await await_terminal_healed(sid, T_SLOW) if sid else False
            if ok:
                check_text(sid, _text("slow", cycle))
            counters["slow_ok" if ok else "slow_fail"] += 1
            cyc.update({"sid": sid, "delta_delay_s": round(dd, 3),
                        "hold_s": round(hold, 2), "completed": ok})

        abuse_log.append(cyc)
        await alive(f"after-{axis}-{cycle}")
        cycle += 1

        # Normal turns stream between abuses (the "while turns stream" half).
        gap = rng.uniform(*gap_s)
        bg_idx = await bg_stream(min(deadline, time.monotonic() + gap), bg_idx)

    # --- final turn after ALL abuse: must complete -------------------------
    sid_final, final_ok, final_why = await drive_turn("final", 999999, T_FRESH)
    if final_ok:
        counters["final_ok"] = 1
    else:
        abuse_log.append({"event": "final_turn_failed", "sid": sid_final,
                          "why": final_why})
    await phone.resync(0)
    await asyncio.sleep(0.2)
    tracker.fold(phone.frames)
    await phone.close()
    duration_actual = round(time.monotonic() - t0, 1)

    # -- verdicts -----------------------------------------------------------
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

    # I2-lite: completed turns reconcile to exactly the deterministic text.
    i2lite = {
        "invariant": "I2",
        "ok": not text_mismatches,
        "violations": [
            f"I2: completed turn {m['sid']} reconciled to {m['got']!r}, "
            f"expected exactly [{m['expected']!r}]"
            for m in text_mismatches[:10]
        ],
        "turns_checked": n_text_checked,
        "mismatches": len(text_mismatches),
    }

    loads = [s["load1"] for s in load_samples if s["load1"] >= 0]
    resources = sampler.analyze()
    sampler.stop()

    verdict = common.build_verdict(
        "T5_gateway_abuse", [i1, i3, i2lite],
        duration_s=round(p.duration_s, 2),
        duration_actual_s=duration_actual,
        mode_pacing="wall-clock" if soak else f"{cycle}-cycles",
        n_cycles=cycle, counters=counters,
        gateway_starts=gw.start_count, gateway_port=gw.port,
        alive_checks=alive_checks, relay_alive_end=relay_alive_end,
        phone_generations=i3.get("generations"),
        load1={"min": min(loads) if loads else None,
               "max": max(loads) if loads else None,
               "last": loads[-1] if loads else None},
        load_samples=load_samples,
        resources=resources,
        relay_logs=str(relay.log_dir), gateway_logs=str(gw.log_dir),
        abuse_log=abuse_log,
    )
    evidence("verdict", verdict)
    evidence("abuse_log", abuse_log)
    evidence("resources", resources)
    common.assert_verdict(verdict)
