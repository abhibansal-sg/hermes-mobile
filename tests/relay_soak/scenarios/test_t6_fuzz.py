"""T6 — property-based fuzz (I8), via hypothesis.

Fuzzes the relay's two input edges and requires it to NEVER crash:

* **phone -> relay (upstream JSON-RPC):** malformed / truncated / non-JSON
  bytes, UNKNOWN methods, and OVERSIZED (>8 MiB) frames sent straight at the
  relay's downstream WS. Malformed input is dropped silently; unknown methods
  must come back as a CLEAN JSON-RPC ``error`` (not a crash / hang); an oversized
  frame may tear down THAT connection but must not take down the relay.
* **gateway -> relay (events):** mutated / unknown-type events injected into the
  relay via the controllable gateway's ``/control/inject_event``. The reframer
  must absorb them without dying.

After every batch the relay's ``/healthz`` is probed; I8 holds iff the relay is
alive through the whole storm and every unknown method returned a clean error.

The relay + an isolated subprocess gateway (event injection needs a signal-able
gateway) are started ONCE (module fixture) and reused across all hypothesis
examples, so the fuzz is cheap per case. NEVER the live gateway.

Two phases (soak mode runs BOTH; short mode runs only the hypothesis phase so the
CI gate stays seconds-fast):

* ``test_t6_fuzz`` — the hypothesis ``@given`` phase: 40 derandomized cases drawn
  from the same corpus strategy below.
* ``test_t6_sustain`` — a wall-clock soak phase: keeps drawing from the SAME
  strategy and firing cases for the full ``duration_s`` budget (the spec's
  "15 min budget" / 30 min soak), liveness-probing every ~50 cases. This is what
  makes the soak-mode duration real — hypothesis's ``max_examples`` alone caps at
  40 cases and ignores ``duration_s``, which would make a soak run finish in
  seconds rather than minutes.
"""

from __future__ import annotations

import asyncio
import json
import random
import socket
import time

import pytest
import websockets
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

import tests.relay_soak.soak_params as soak_params
from tests.relay_soak.constants import MOCK_GATEWAY_TOKEN, assert_isolated_port
from tests.relay_soak.conftest import (
    RELAY_PYTHON,
    build_relay_manager,
    healthz_url_for,
    phone_url_for,
)
from tests.relay_soak.infra.gateway import SoakGatewayProc, alloc_isolated_port
from tests.relay_soak.invariants.checkers import RobustnessChecker
from tests.relay_soak.scenarios import common

# ---------------------------------------------------------------------------
# Module-scoped env: one relay + one signal-able gateway, reused across cases.
# ---------------------------------------------------------------------------

_RESERVED: set[int] = set()


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


@pytest.fixture(scope="module")
def fuzz_env(run_dir):
    port = alloc_isolated_port(_RESERVED)
    assert_isolated_port(port)
    base = run_dir / "test_t6_fuzz"
    gw = SoakGatewayProc(python=RELAY_PYTHON, port=port,
                         home=base / "gateway-home", log_dir=base / "gw-logs")
    gw.start()
    relay = build_relay_manager(
        gateway_port=gw.port, token=gw.token,
        downstream_port=_free_port(),
        home=base / "relay-home", log_dir=base / "relay-logs",
    )
    relay.start()
    checker = RobustnessChecker(healthz_url_for(relay), token=MOCK_GATEWAY_TOKEN)
    env = {
        "gw": gw, "relay": relay, "checker": checker,
        "url": phone_url_for(relay), "healthz": healthz_url_for(relay),
        "token": MOCK_GATEWAY_TOKEN,
    }
    try:
        yield env
    finally:
        relay.stop()
        gw.stop()


# ---------------------------------------------------------------------------
# Fuzz strategies — (kind, payload) cases.
# ---------------------------------------------------------------------------

_TRUNCATED = [
    '{"jsonrpc":"2.0","id":1,"meth', '{"params":', "not json at all",
    '{"jsonrpc":"2.0","id":2,"method":"submit","params":{"text":', "[]",
    "null", '"bare-string"', "12345", "{{{{", "", "\x00\x01\x02",
]
_UNKNOWN_METHODS = [
    "explode", "rm", "..", "submit;DROP", "__proto__", "ack2", "resync!",
    "nonsense", "session.delete_everything", "",
]


def _case_strategy():
    raw = st.sampled_from(_TRUNCATED) | st.text(min_size=0, max_size=120)
    raw_case = raw.map(lambda s: ("RAW", s))
    unknown_case = st.builds(
        lambda m, i: ("UNKNOWN",
                      json.dumps({"jsonrpc": "2.0", "id": i, "method": m,
                                  "params": {}})),
        st.sampled_from(_UNKNOWN_METHODS), st.integers(1000, 999999))
    oversize_case = st.just(("OVERSIZE", "X" * (9 * 1024 * 1024)))  # > 8 MiB
    event_case = st.builds(
        lambda t: ("EVENT", t),
        st.sampled_from([
            "message.delta", "tool.complete", "bogus.unknown.type",
            "item.started", "", "message.complete", "error",
            "approval.request", "weird::type",
        ]))
    return raw_case | unknown_case | oversize_case | event_case


# ---------------------------------------------------------------------------
# Case application.
# ---------------------------------------------------------------------------


async def _send_raw(url: str, token: str, data: str) -> None:
    headers = {"Authorization": f"Bearer {token}"}
    try:
        async with websockets.connect(url, max_size=16 * 1024 * 1024,
                                      additional_headers=headers,
                                      open_timeout=5) as ws:
            await ws.send(data)
            await asyncio.sleep(0.01)
    except Exception:  # noqa: BLE001  (a dropped conn is fine; a dead relay is not)
        pass


async def _send_unknown(url: str, token: str, frame: str,
                        checker: RobustnessChecker) -> None:
    headers = {"Authorization": f"Bearer {token}"}
    try:
        async with websockets.connect(url, max_size=16 * 1024 * 1024,
                                      additional_headers=headers,
                                      open_timeout=5) as ws:
            await ws.send(frame)
            try:
                resp = json.loads(await asyncio.wait_for(ws.recv(), timeout=3.0))
            except (asyncio.TimeoutError, json.JSONDecodeError, Exception):
                resp = {}
            checker.record_unknown_method(resp)
    except Exception:  # noqa: BLE001
        pass


async def _inject_event(gw, etype: str) -> None:
    try:
        await gw.inject_event("sess-fuzz", etype,
                              {"text": "fuzz", "payload": {"x": 1},
                               "weird": [1, 2, 3], "n": None})
    except Exception:  # noqa: BLE001
        pass


async def _fire_case(env: dict, case: tuple) -> None:
    """Apply one (kind, payload) fuzz case to the relay-under-test."""
    kind, payload = case
    url, token = env["url"], env["token"]
    if kind in ("RAW", "OVERSIZE"):
        await _send_raw(url, token, payload)
    elif kind == "UNKNOWN":
        await _send_unknown(url, token, payload, env["checker"])
    elif kind == "EVENT":
        await _inject_event(env["gw"], payload)


# Mirror _case_strategy's union with a plain Random so the soak phase draws from
# the SAME corpus (seeded by SOAK_SEED) without going through hypothesis.
def _draw_case(rng: random.Random) -> tuple:
    arm = rng.choice(["RAW", "UNKNOWN", "OVERSIZE", "EVENT"])
    if arm == "RAW":
        if rng.random() < 0.5:
            return ("RAW", rng.choice(_TRUNCATED))
        return ("RAW", "".join(rng.choice("abc {}\x00\t\"\\") for _ in range(rng.randint(0, 120))))
    if arm == "UNKNOWN":
        return ("UNKNOWN", json.dumps({
            "jsonrpc": "2.0", "id": rng.randint(1000, 999999),
            "method": rng.choice(_UNKNOWN_METHODS), "params": {},
        }))
    if arm == "OVERSIZE":
        return ("OVERSIZE", "X" * (9 * 1024 * 1024))
    return ("EVENT", rng.choice([
        "message.delta", "tool.complete", "bogus.unknown.type",
        "item.started", "", "message.complete", "error",
        "approval.request", "weird::type",
    ]))


_CASES_SEEN = {"n": 0}


def _apply_case_sync(env: dict, case: tuple) -> None:
    _CASES_SEEN["n"] += 1
    asyncio.run(_fire_case(env, case))
    if _CASES_SEEN["n"] % 5 == 0:
        asyncio.run(env["checker"].probe_alive(f"after-{_CASES_SEEN['n']}"))


@settings(max_examples=40, deadline=None, derandomize=True,
          suppress_health_check=list(HealthCheck))
@given(case=_case_strategy())
def test_t6_fuzz(case, fuzz_env):
    """Phase 1 — hypothesis ``@given`` phase: 40 corpus cases (always runs)."""
    _apply_case_sync(fuzz_env, case)


@pytest.mark.asyncio
@pytest.mark.skipif(soak_params.mode() != "soak",
                    reason="sustained fuzz budget is the soak-mode contract")
async def test_t6_sustain(fuzz_env):
    """Phase 2 — sustained soak: fire the corpus for the full ``duration_s``.

    Hypothesis's ``max_examples`` caps the @given phase at 40 cases and ignores
    ``duration_s`` — without this loop a soak run would finish in seconds. The
    spec's "T6 fuzz (15 min budget)" is realized HERE: we draw from the same
    corpus strategy and hammer the relay for the resolved soak duration, probing
    liveness every ~50 cases so a crash is localized to a narrow window.
    """
    p = soak_params.params("t6_fuzz")
    rng = random.Random(p.seed ^ 0xF6)
    checker = fuzz_env["checker"]
    deadline = time.monotonic() + p.duration_s
    while time.monotonic() < deadline:
        # Fire a burst of ~50 cases per liveness probe so the storm is dense but
        # a dead relay is caught within one burst.
        for _ in range(50):
            await _fire_case(fuzz_env, _draw_case(rng))
            _CASES_SEEN["n"] += 1
        await checker.probe_alive(f"sustain-{_CASES_SEEN['n']}")


def test_t6_verdict(fuzz_env, evidence):
    """Final liveness + clean-error assertion after the whole fuzz storm."""
    p = soak_params.params("t6_fuzz")
    checker = fuzz_env["checker"]
    asyncio.run(checker.probe_alive("final"))
    i8 = checker.report()
    if _CASES_SEEN["n"] == 0:
        i8["violations"].append("I8: no fuzz cases were applied")
        i8["ok"] = False

    verdict = common.build_verdict(
        "T6_fuzz", [i8],
        duration_s=round(p.duration_s, 2), cases_applied=_CASES_SEEN["n"],
    )
    evidence("verdict", verdict)
    common.assert_verdict(verdict)
