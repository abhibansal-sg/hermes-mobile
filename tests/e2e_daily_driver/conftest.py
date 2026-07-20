"""Pytest fixtures for the device-shaped E2E gate.

Brings up:

* a mock scripted-echo gateway (in-process, OS-assigned port);
* the REAL consolidated relay as a subprocess (so SIGTERM in scenario e is a
  real process signal, exactly the deployment failure mode);
* a phone-driver factory;
* an evidence writer that drops per-test JSON into
  /Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/e2e/.

The relay subprocess loads the relay package FROM THIS WORKTREE via
PYTHONPATH — never the primary tree. The mock gateway is the default upstream
(deterministic). When ``E2E_USE_LIVE_GATEWAY=1`` the harness instead launches
the stock gateway via launch_gateway.sh; in that mode the byte-identical chaos
assertion is informational-only because live-model output is non-deterministic.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Optional

import pytest
import pytest_asyncio

# Make the e2e package + the mock gateway importable when pytest runs from the
# worktree root. The relay subprocess gets its own PYTHONPATH below.
_HERE = Path(__file__).resolve().parent
_BRANCH_ROOT = _HERE.parent.parent  # .../worktrees/dd-e2egate
_RELAY_DIR = _BRANCH_ROOT / "relay"
sys.path.insert(0, str(_HERE))
sys.path.insert(0, str(_HERE / "mock_gateway"))

from mock_gateway.server import E2E_TOKEN, MockGateway  # noqa: E402
from phone_driver import PhoneDriver  # noqa: E402

EVIDENCE_DIR = Path("/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/e2e")
EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)

RELAY_PYTHON = os.environ.get(
    "E2E_PYTHON", "/Volumes/MainData/Developer/hermes-tmp/e2e-venv/bin/python"
)
USE_LIVE_GATEWAY = os.environ.get("E2E_USE_LIVE_GATEWAY", "0") == "1"

_log = logging.getLogger("e2e.conftest")


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


def _wait_for_port(host: str, port: int, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"port {host}:{port} never opened (relay subprocess failed to bind?)")


async def _http_get_json(url: str, *, headers: Optional[dict] = None, timeout: float = 10.0) -> dict:
    import httpx
    async with httpx.AsyncClient() as c:
        r = await c.get(url, headers=headers or {}, timeout=timeout)
        r.raise_for_status()
        return r.json()


# ---------------------------------------------------------------------------
# Mock gateway fixture.
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def mock_gateway():
    """In-process scripted-echo gateway on an OS-assigned loopback port."""
    gw = MockGateway()
    await gw.start()
    try:
        yield gw
    finally:
        await gw.stop()


# ---------------------------------------------------------------------------
# Relay subprocess fixture.
# ---------------------------------------------------------------------------


class RelayProc:
    """The relay as a real subprocess (so SIGTERM/chaos are real signals)."""

    def __init__(self, cmd: list[str], env: dict[str, str], log_path: Path,
                 downstream_port: int) -> None:
        self.cmd = cmd
        self.env = env
        self.log_path = log_path
        self.downstream_port = downstream_port
        self.proc: Optional[subprocess.Popen] = None
        self.start_count = 0

    def start(self) -> None:
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self.log_fp = open(self.log_path, "ab", buffering=0)
        self.proc = subprocess.Popen(
            self.cmd,
            env=self.env,
            stdout=self.log_fp,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            start_new_session=True,  # own process group → SIGTERM the relay only
        )
        self.start_count += 1
        _wait_for_port("127.0.0.1", self.downstream_port, timeout=20.0)
        _log.info("relay up (pid=%s) on downstream %d; logs=%s",
                  self.proc.pid, self.downstream_port, self.log_path)

    def term(self, *, timeout: float = 8.0) -> int:
        """SIGTERM the relay's process group (spec: SIGTERM never kill-9)."""
        if self.proc is None:
            return -1
        import signal
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            return -1
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Spec forbids kill-9. Surface loudly instead.
            raise RuntimeError("relay did not exit on SIGTERM — investigate")
        finally:
            try:
                self.log_fp.close()
            except Exception:
                pass
        self.proc = None
        return rc

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None


@pytest_asyncio.fixture
async def relay_subprocess(mock_gateway: MockGateway, request: pytest.FixtureRequest):
    """Start the real relay against the mock gateway. Yields the RelayProc.

    The downstream port is fixed per-test (random free) so the phone driver
    knows where to reconnect after a SIGTERM/restart (scenario e).
    """
    downstream_port = _free_port()
    # Per-test HOME on /Volumes/MainData so DurableState()'s default
    # ``~/relay/state.sqlite3`` lands here: persists across the relay restart
    # within scenario (e) AND stays isolated from the test user's real HOME.
    # (DurableState does not read an env path; HOME is the only knob — keep the
    # relay source FROZEN.)
    relay_home = EVIDENCE_DIR / f"{request.node.name}-relay-home"
    relay_home.mkdir(parents=True, exist_ok=True)
    (relay_home / "relay").mkdir(exist_ok=True)
    # Wipe stale durable state so each test starts clean.
    for stale in (relay_home / "relay").glob("state.sqlite3*"):
        stale.unlink(missing_ok=True)
    log_path = EVIDENCE_DIR / f"{request.node.name}-relay.log"

    env = os.environ.copy()
    env["PYTHONPATH"] = str(_RELAY_DIR) + os.pathsep + env.get("PYTHONPATH", "")
    env["HOME"] = str(relay_home)  # isolates durable state + config discovery
    env["HERMES_RELAY_GATEWAY_TOKEN"] = mock_gateway.token
    env["HERMES_RELAY_GATEWAY_HOST"] = "127.0.0.1"
    env["HERMES_RELAY_GATEWAY_PORT"] = str(mock_gateway.port)
    env["HERMES_RELAY_DOWNSTREAM_HOST"] = "127.0.0.1"
    env["HERMES_RELAY_DOWNSTREAM_PORT"] = str(downstream_port)
    env["HERMES_RELAY_HEALTH_PATH"] = "/healthz"
    env["HERMES_RELAY_LOG_LEVEL"] = "INFO"
    # Plugin dir so hermes_relay.plugin_bridge finds replay_ring/push_engine.
    env["HERMES_RELAY_PLUGIN_DIR"] = str(_BRANCH_ROOT / "plugins" / "hermes-mobile")

    cmd = [RELAY_PYTHON, "-m", "hermes_relay",
           "--gateway-host", "127.0.0.1", "--gateway-port", str(mock_gateway.port),
           "--listen", f"127.0.0.1:{downstream_port}",
           "--health-path", "/healthz"]
    rp = RelayProc(cmd, env, log_path, downstream_port)
    rp.start()
    try:
        yield rp
    finally:
        if rp.is_alive():
            rp.term()


# ---------------------------------------------------------------------------
# Phone driver factory.
# ---------------------------------------------------------------------------


@pytest_asyncio.fixture
async def phone_factory(relay_subprocess: RelayProc):
    """Factory: open a phone driver connected to the relay downstream WS."""
    port = relay_subprocess.downstream_port
    url = f"ws://127.0.0.1:{port}"
    created: list[PhoneDriver] = []

    async def _make() -> PhoneDriver:
        d = PhoneDriver(url, token=E2E_TOKEN)
        await d.connect()
        created.append(d)
        return d

    try:
        yield _make
    finally:
        for d in created:
            await d.close()


# ---------------------------------------------------------------------------
# Evidence writer.
# ---------------------------------------------------------------------------


@pytest.fixture
def evidence(request: pytest.FixtureRequest):
    """Per-test evidence writer. Returns a function ``write(name, obj)``."""
    test_name = request.node.name

    def _write(name: str, obj: Any) -> Path:
        # Sanitize the test name for the filesystem.
        safe = "".join(c if c.isalnum() or c in "-_." else "_" for c in test_name)
        path = EVIDENCE_DIR / f"{safe}-{name}.json"
        text = json.dumps(obj, indent=2, default=str, ensure_ascii=False)
        path.write_text(text, encoding="utf-8")
        return path

    return _write


# ---------------------------------------------------------------------------
# Asyncio config.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def event_loop():
    """One event loop for the whole session so fixtures share async state."""
    loop = asyncio.new_event_loop()
    yield loop
    loop.close()
