"""Pytest fixtures for the relay soak harness.

Brings up, per scenario:

* a deterministic upstream gateway (in-process scripted MockGateway by default;
  a signal-able subprocess gateway for T5/T6);
* the REAL relay as a subprocess (so SIGTERM/kill are real signals) against a
  temp, per-scenario HERMES_HOME whose ``state.sqlite3`` persists across a relay
  restart (I5 durable re-resume);
* a phone-driver factory (the extended ``SoakPhoneDriver``);
* a resource sampler (I6) and an evidence writer.

The relay-under-test is whatever relay the run's venv resolves ``hermes_relay``
to. ``run_soak.sh`` installs it from the given SOURCE tree; ``SOAK_RELAY_SOURCE``
points this conftest at that tree for PYTHONPATH + plugin resolution. This
conftest never imports the relay under test and never touches the primary tree,
a live gateway (9119), or a live relay (8788).

Port discipline: subprocess gateways allocate 9140-9160 (NEVER 9119/8788 or the
QA-3 band 9130-9139); the in-process mock and the relay's downstream use
OS-assigned ephemeral loopback ports (cannot collide with any reserved band).
"""

from __future__ import annotations

import asyncio
import datetime as _dt
import json
import logging
import os
import socket
import sys
import time
from pathlib import Path
from typing import Any, Callable, Optional

import pytest
import pytest_asyncio

# --- import wiring ---------------------------------------------------------
# Worktree root on sys.path so ``tests.relay_soak.*`` imports resolve; the e2e
# dir on sys.path so the reused ``phone_driver`` / ``mock_gateway`` import bare.
_HERE = Path(__file__).resolve().parent                  # tests/relay_soak
_ROOT = _HERE.parent.parent                              # worktree root
_E2E = _HERE.parent / "e2e_daily_driver"                 # tests/e2e_daily_driver
for _p in (str(_ROOT), str(_E2E), str(_E2E / "mock_gateway")):
    if _p not in sys.path:
        sys.path.insert(0, _p)

from tests.relay_soak.constants import EVIDENCE_ROOT, MOCK_GATEWAY_TOKEN  # noqa: E402
from tests.relay_soak.infra.gateway import (  # noqa: E402
    InProcGateway,
    SoakGatewayProc,
    alloc_isolated_port,
)
from tests.relay_soak.infra.relay_manager import RelayManager  # noqa: E402
from tests.relay_soak.infra.phone_ext import SoakPhoneDriver  # noqa: E402
from tests.relay_soak.infra.resources import ResourceSampler  # noqa: E402
import tests.relay_soak.soak_params as soak_params  # noqa: E402

_log = logging.getLogger("soak.conftest")

# Relay-under-test resolution. RELAY_PYTHON runs the relay subprocess (the venv
# python run_soak.sh built). SOAK_RELAY_SOURCE, when set, points PYTHONPATH +
# the plugin dir at the relay tree under test (else the venv install is used).
RELAY_PYTHON = os.environ.get("SOAK_PYTHON", sys.executable)
RELAY_SOURCE = Path(os.environ.get("SOAK_RELAY_SOURCE", str(_ROOT))).resolve()


# ---------------------------------------------------------------------------
# Session-scoped run context.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def reserved_ports() -> set[int]:
    """Process-global set of isolated ports already handed out this run."""
    return set()


@pytest.fixture(scope="session")
def run_dir() -> Path:
    """Unique evidence dir for this soak run."""
    stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    d = EVIDENCE_ROOT / (
        f"run-{stamp}-{soak_params.mode()}-seed{soak_params.seed()}"
    )
    d.mkdir(parents=True, exist_ok=True)
    (d / "META.json").write_text(json.dumps({
        "started": time.time(), "mode": soak_params.mode(),
        "scale": soak_params.scale(), "seed": soak_params.seed(),
        "relay_python": RELAY_PYTHON, "relay_source": str(RELAY_SOURCE),
    }, indent=2), encoding="utf-8")
    _log.info("soak run evidence dir: %s", d)
    return d


@pytest.fixture(scope="session")
def event_loop():
    """One loop for the whole session so fixtures share async state."""
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()


# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------


def _free_port() -> int:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
    finally:
        s.close()


def build_relay_manager(
    *,
    gateway_port: int,
    token: str,
    downstream_port: int,
    home: Path,
    log_dir: Path,
) -> RelayManager:
    """Construct (not start) a RelayManager wired to a gateway port."""
    home = Path(home)
    # Wipe stale durable state so the scenario starts clean; within the scenario
    # this dir PERSISTS across relay restarts (I5 durable re-resume).
    (home / "relay").mkdir(parents=True, exist_ok=True)
    for stale in (home / "relay").glob("state.sqlite3*"):
        stale.unlink(missing_ok=True)

    env = os.environ.copy()
    env["HOME"] = str(home)
    env["HERMES_HOME"] = str(home)
    env["HERMES_RELAY_GATEWAY_TOKEN"] = token
    env["HERMES_RELAY_GATEWAY_HOST"] = "127.0.0.1"
    env["HERMES_RELAY_GATEWAY_PORT"] = str(gateway_port)
    env["HERMES_RELAY_DOWNSTREAM_HOST"] = "127.0.0.1"
    env["HERMES_RELAY_DOWNSTREAM_PORT"] = str(downstream_port)
    env["HERMES_RELAY_HEALTH_PATH"] = "/healthz"
    env["HERMES_RELAY_LOG_LEVEL"] = os.environ.get("SOAK_RELAY_LOG_LEVEL", "INFO")
    # Resolve the relay + its reused plugins from the source under test.
    env["HERMES_RELAY_PLUGIN_DIR"] = str(RELAY_SOURCE / "plugins" / "hermes-mobile")
    relay_pkg = str(RELAY_SOURCE / "relay")
    env["PYTHONPATH"] = relay_pkg + os.pathsep + env.get("PYTHONPATH", "")

    cmd = [
        RELAY_PYTHON, "-m", "hermes_relay",
        "--gateway-host", "127.0.0.1", "--gateway-port", str(gateway_port),
        "--listen", f"127.0.0.1:{downstream_port}",
        "--health-path", "/healthz",
    ]
    return RelayManager(
        cmd=cmd, env=env, home=home, log_dir=log_dir,
        downstream_port=downstream_port,
    )


# ---------------------------------------------------------------------------
# Gateway fixtures.
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def mock_gateway():
    """In-process scripted gateway (default deterministic upstream)."""
    gw = InProcGateway()
    await gw.start()
    try:
        yield gw
    finally:
        await gw.stop()


@pytest.fixture
def gateway_proc_factory(reserved_ports, run_dir, request):
    """Factory: a signal-able subprocess gateway on an isolated 9140+ port."""
    created: list[SoakGatewayProc] = []

    def _make() -> SoakGatewayProc:
        port = alloc_isolated_port(reserved_ports)
        safe = "".join(c if c.isalnum() or c in "-_." else "_"
                       for c in request.node.name)
        home = run_dir / safe / "gateway-home"
        log_dir = run_dir / safe / "logs"
        gp = SoakGatewayProc(python=RELAY_PYTHON, port=port, home=home,
                             log_dir=log_dir)
        gp.start()
        created.append(gp)
        return gp

    yield _make
    for gp in created:
        gp.stop()


# ---------------------------------------------------------------------------
# Relay fixtures.
# ---------------------------------------------------------------------------


@pytest.fixture
def relay_factory(run_dir, request):
    """Factory: build+start a relay against an arbitrary gateway port."""
    created: list[RelayManager] = []

    def _make(gateway_port: int, *, token: str = MOCK_GATEWAY_TOKEN,
              downstream_port: Optional[int] = None) -> RelayManager:
        ds_port = downstream_port or _free_port()
        safe = "".join(c if c.isalnum() or c in "-_." else "_"
                       for c in request.node.name)
        base = run_dir / safe / f"relay{len(created)}"
        rm = build_relay_manager(
            gateway_port=gateway_port, token=token, downstream_port=ds_port,
            home=base / "home", log_dir=base / "logs",
        )
        rm.start()
        created.append(rm)
        return rm

    yield _make
    for rm in created:
        rm.stop()


@pytest.fixture
def relay(mock_gateway, relay_factory) -> RelayManager:
    """A relay running against the in-process mock gateway."""
    return relay_factory(mock_gateway.port)


@pytest.fixture
def resource_sampler(request) -> Callable[[RelayManager], ResourceSampler]:
    """Start an RSS/FD sampler on a relay; stopped at teardown."""
    samplers: list[ResourceSampler] = []
    interval = float(os.environ.get("SOAK_SAMPLE_INTERVAL_S", "5.0"))

    def _make(rm: RelayManager) -> ResourceSampler:
        s = ResourceSampler(rm.pid, interval_s=interval)
        s.start()
        samplers.append(s)
        return s

    yield _make
    for s in samplers:
        s.stop()


# ---------------------------------------------------------------------------
# Phone factory.
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def phone_factory(relay):
    """Factory: a connected SoakPhoneDriver against the relay's downstream."""
    url = f"ws://127.0.0.1:{relay.downstream_port}"
    created: list[SoakPhoneDriver] = []

    async def _make(*, drop_if=None) -> SoakPhoneDriver:
        d = SoakPhoneDriver(url, token=MOCK_GATEWAY_TOKEN, drop_if=drop_if)
        await d.connect()
        created.append(d)
        return d

    try:
        yield _make
    finally:
        for d in created:
            try:
                await d.close()
            except Exception:  # noqa: BLE001
                pass


def phone_url_for(rm: RelayManager) -> str:
    return f"ws://127.0.0.1:{rm.downstream_port}"


def healthz_url_for(rm: RelayManager) -> str:
    return f"http://127.0.0.1:{rm.downstream_port}/healthz"


# ---------------------------------------------------------------------------
# Evidence writer.
# ---------------------------------------------------------------------------


@pytest.fixture
def evidence(request, run_dir):
    """Per-test evidence writer into the run dir: ``write(name, obj) -> Path``."""
    safe = "".join(c if c.isalnum() or c in "-_." else "_"
                   for c in request.node.name)
    subdir = run_dir / safe
    subdir.mkdir(parents=True, exist_ok=True)

    def _write(name: str, obj: Any) -> Path:
        path = subdir / f"{name}.json"
        path.write_text(
            json.dumps(obj, indent=2, default=str, ensure_ascii=False),
            encoding="utf-8",
        )
        return path

    return _write
