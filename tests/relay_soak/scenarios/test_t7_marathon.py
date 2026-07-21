"""T7 — marathon (I6 + spot I1/I2).

The full mix at LOW intensity for the whole duration, with resource sampling
every ~30 s (shorter in compressed runs): periodic turns, occasional connect
churn, occasional foreground flap, periodic acks — all gentle, so the run is
CPU-``nice``-friendly (the QA-3 swarm shares this machine). The point is
DURATION, not throughput: RSS / FD / thread count must NOT climb monotonically
over hours (no leak), and turns must keep completing with correct transcripts.

Asserted:

* **I6** least-squares growth on RSS and FD over the run is below threshold
  (a bounded relay oscillates around a steady state — ring eviction, connection
  churn — it does not climb); the full resource curve is recorded as evidence;
* **I1 / I2** spot check — the turns driven during the marathon reach terminal
  and reconcile their deterministic text.
"""

from __future__ import annotations

import asyncio
import os
import random

import pytest

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.invariants.checkers import TurnTerminalTracker
from tests.relay_soak.infra.resources import ResourceSampler
from tests.relay_soak.scenarios import common

pytestmark = pytest.mark.asyncio

TEXT = "Marathon turns must keep completing correctly for the whole run."


async def test_t7_marathon(mock_gateway, relay, phone_factory, evidence):
    p = soak_params.params("t7_marathon")
    rng = random.Random(p.seed ^ 0x7)

    # Sampling interval: 30 s in soak; compress with the run so short mode still
    # yields several samples. Overridable via SOAK_SAMPLE_INTERVAL_S.
    interval = float(os.environ.get(
        "SOAK_SAMPLE_INTERVAL_S", str(min(30.0, max(2.0, p.duration_s / 8.0)))))
    sampler = ResourceSampler(relay.pid, interval_s=interval)
    sampler.start()

    phone = await phone_factory()

    # Clean reference.
    ref = await common.run_reference(phone, mock_gateway, script="simple",
                                     text=TEXT)
    assert common.agent_messages(ref) == [TEXT]

    driven: list[str] = []
    churns = 0
    flaps = 0
    acks = 0
    turns_completed = 0
    deadline = asyncio.get_event_loop().time() + p.duration_s
    i = 0
    try:
        while asyncio.get_event_loop().time() < deadline:
            sid = await mock_gateway.create_session(
                script="simple", text=TEXT, delta_delay_s=0.01)
            try:
                await phone.submit(text=TEXT, session_id=sid,
                                   client_message_id=f"cmid-t7-{i}")
                await common.wait_terminal(phone, sid, timeout=15.0)
                driven.append(sid)
                turns_completed += 1
            except asyncio.TimeoutError:
                driven.append(sid)
            except Exception:  # noqa: BLE001  (transient flap mid-submit)
                pass

            # Low-intensity mix: occasional churn / flap / ack.
            r = rng.random()
            if r < 0.25:
                try:
                    await phone.close()
                    await phone.connect()
                    await phone.resync(max((f.seq for f in phone.frames),
                                           default=0))
                    churns += 1
                except Exception:  # noqa: BLE001
                    pass
            elif r < 0.5:
                for _ in range(rng.randint(2, 5)):
                    try:
                        await phone.foreground(sid if rng.random() < 0.5 else None)
                        flaps += 1
                    except Exception:  # noqa: BLE001
                        break
            else:
                try:
                    await phone.ack(max((f.seq for f in phone.frames), default=0))
                    acks += 1
                except Exception:  # noqa: BLE001
                    pass

            i += 1
            await asyncio.sleep(rng.uniform(0.05, 0.3))  # keep it gentle

            # H8 (soak consolidation): keep the driver's frame log BOUNDED.
            # The log is append-only; at marathon intensity it grew ~100 MiB/min
            # (2.9 GiB in 28 min on the first 3 h run — an OOM risk to the QA-3
            # swarm sharing this 36 GiB box; the run was killed on that basis).
            # Everything the checkers below read is tail-local: the last 5
            # driven sessions' frames (driven[-5:]), the live tail for max-seq
            # ack/churn, and wait_terminal on UNIQUE sids. Compact to: frames
            # of the last 64 driven sessions + the last 2048 frames. The relay
            # under test is untouched — I6 measures the relay's OWN RSS, which
            # the external sampler tracked flat (30-33 MiB) on the killed run.
            if i % 300 == 0 and len(phone.frames) > 4096:
                keep_sids = set(driven[-64:])
                n = len(phone.frames)
                tail_from = max(0, n - 2048)
                keep = [j for j in range(n)
                        if j >= tail_from or phone.frames[j].sid in keep_sids]
                phone.frames[:] = [phone.frames[j] for j in keep]
                # Keep SoakPhoneDriver's parallel generation tag list in sync
                # (index-aligned with frames); absent on a plain PhoneDriver.
                gens = getattr(phone, "_frame_gen", None)
                if isinstance(gens, list) and len(gens) == n:
                    gens[:] = [gens[j] for j in keep]
    finally:
        sampler.stop()

    # Spot reconcile the last few driven sessions.
    tracker = TurnTerminalTracker()
    i2_bad = 0
    for sid in driven[-5:]:
        await phone.resync(0)
        await asyncio.sleep(0.05)
        cand = common.reconcile_transcript(phone.frames_for(sid))
        if common.agent_messages(cand) != [TEXT]:
            i2_bad += 1
        tracker.mark_driven(sid)
    tracker.fold(phone.frames)
    i1 = tracker.report()

    analysis = sampler.analyze()
    i6 = {
        "invariant": "I6", "ok": not analysis["leaked"],
        "violations": [
            f"I6: {m['metric']} shows monotonic growth "
            f"(slope={m['slope_per_s']}/s, total={m['total_growth']}, "
            f"first={m['first']}, last={m['last']})"
            for m in (analysis["rss"], analysis["fd"]) if m["leaked"]],
        "rss": analysis["rss"], "fd": analysis["fd"],
        "n_samples": analysis["n_samples"], "interval_s": interval,
        "curve": analysis["curve"],
    }
    i2 = {
        "invariant": "I2", "ok": i2_bad == 0,
        "violations": [f"I2: {i2_bad} spot-checked marathon session(s) diverged"]
        if i2_bad else [],
        "spot_checked": min(5, len(driven)),
    }

    verdict = common.build_verdict(
        "T7_marathon", [i6, i1, i2],
        duration_s=round(p.duration_s, 2), turns_completed=turns_completed,
        churns=churns, flaps=flaps, acks=acks, driven=len(driven),
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
