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
"""

from __future__ import annotations

import asyncio
import json
import socket

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


_CASES_SEEN = {"n": 0}


@settings(max_examples=40, deadline=None, derandomize=True,
          suppress_health_check=list(HealthCheck))
@given(case=_case_strategy())
def test_t6_fuzz(case, fuzz_env):
    """Fire one fuzz case at the relay; it must stay alive throughout."""
    kind, payload = case
    _CASES_SEEN["n"] += 1
    checker = fuzz_env["checker"]
    url, token = fuzz_env["url"], fuzz_env["token"]

    if kind == "RAW":
        asyncio.run(_send_raw(url, token, payload))
    elif kind == "OVERSIZE":
        asyncio.run(_send_raw(url, token, payload))
    elif kind == "UNKNOWN":
        asyncio.run(_send_unknown(url, token, payload, checker))
    elif kind == "EVENT":
        asyncio.run(_inject_event(fuzz_env["gw"], payload))

    # Probe liveness every few cases so a crash is localized quickly.
    if _CASES_SEEN["n"] % 5 == 0:
        asyncio.run(checker.probe_alive(f"after-{_CASES_SEEN['n']}"))


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
