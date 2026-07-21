"""Gateway infra for the soak harness.

Two backends, both deterministic (the scripted echo gateway — I2 stays
meaningful):

* :class:`InProcGateway` — the ratified ``MockGateway`` in-process on an
  OS-assigned ephemeral loopback port. Default upstream for scenarios that do
  not need to SIGNAL the gateway (T1/T2/T3/T4/T6/T7/T8). Scripted sessions are
  created directly via the in-process helper.

* :class:`SoakGatewayProc` — the same scripted gateway as a SUBPROCESS on a
  fixed port in the isolated 9140-9160 band with a temp HERMES_HOME under the
  evidence dir. Used by T5 (gateway abuse: SIGSTOP/SIGCONT/SIGTERM/restart) and
  any scenario that needs to inject raw gateway events over the wire. Scripted
  sessions + event injection go through the ``/control`` HTTP surface.

NEVER the live gateway (9119) or the QA-3 band (9130-9139). The allocator
refuses those ports defensively.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import signal
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Optional

import httpx

from ..constants import (
    ISOLATED_PORT_BASE,
    ISOLATED_PORT_MAX,
    MOCK_GATEWAY_TOKEN,
    assert_isolated_port,
)

_log = logging.getLogger("soak.gateway")

# The e2e mock gateway package (reused verbatim).
_E2E_DIR = Path(__file__).resolve().parents[2] / "e2e_daily_driver"
_GATEWAY_MAIN = Path(__file__).resolve().parent / "soak_gateway_main.py"


def _port_free(port: int) -> bool:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        s.bind(("127.0.0.1", port))
        return True
    except OSError:
        return False
    finally:
        s.close()


def alloc_isolated_port(reserved: set[int]) -> int:
    """Pick a free port in 9140-9160 not in ``reserved`` (process-global)."""
    for port in range(ISOLATED_PORT_BASE, ISOLATED_PORT_MAX + 1):
        assert_isolated_port(port)
        if port in reserved:
            continue
        if _port_free(port):
            reserved.add(port)
            return port
    raise RuntimeError(
        f"no free isolated port in {ISOLATED_PORT_BASE}-{ISOLATED_PORT_MAX} "
        f"(reserved={sorted(reserved)})"
    )


def _wait_port(host: str, port: int, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.4):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"gateway port {host}:{port} never opened")


# ---------------------------------------------------------------------------
# In-process gateway (default upstream).
# ---------------------------------------------------------------------------


class InProcGateway:
    """The ratified MockGateway, in-process, ephemeral loopback port."""

    def __init__(self) -> None:
        # Imported lazily so importing this module never requires websockets.
        from mock_gateway.server import MockGateway  # noqa: WPS433

        self.gw = MockGateway()

    async def start(self) -> None:
        await self.gw.start()

    async def stop(self) -> None:
        await self.gw.stop()

    @property
    def port(self) -> int:
        return self.gw.port

    @property
    def token(self) -> str:
        return MOCK_GATEWAY_TOKEN

    async def create_session(self, *, script: str, **kwargs: Any) -> str:
        from mock_gateway.server import create_scripted_session  # noqa: WPS433

        return await create_scripted_session(self.gw, script=script, **kwargs)


# ---------------------------------------------------------------------------
# Subprocess gateway (T5: signal-able) + control channel.
# ---------------------------------------------------------------------------


class SoakGatewayProc:
    """Run the scripted gateway as a subprocess on a fixed isolated port.

    Supports SIGSTOP/SIGCONT (pause/resume — the "made slow" axis), SIGTERM +
    restart (the "gateway restarted" axis), and raw-event injection via the
    ``/control`` HTTP surface (T6 fuzzing). ``home`` is a temp HERMES_HOME
    under the evidence dir.
    """

    def __init__(
        self,
        *,
        python: str,
        port: int,
        home: Path,
        log_dir: Path,
    ) -> None:
        assert_isolated_port(port)
        self.python = python
        self.port = port
        self.home = Path(home)
        self.log_dir = Path(log_dir)
        self.token = MOCK_GATEWAY_TOKEN
        self.proc: Optional[subprocess.Popen] = None
        self.start_count = 0
        self._log_fp = None
        self.events: list[dict] = []

    @property
    def ws_url(self) -> str:
        return f"ws://127.0.0.1:{self.port}/api/ws?token={self.token}"

    @property
    def pid(self) -> Optional[int]:
        return self.proc.pid if self.proc is not None else None

    def start(self) -> None:
        self.home.mkdir(parents=True, exist_ok=True)
        self.log_dir.mkdir(parents=True, exist_ok=True)
        log_path = self.log_dir / f"gateway-start{self.start_count:03d}.log"
        self._log_fp = open(log_path, "ab", buffering=0)
        env = os.environ.copy()
        env["HERMES_HOME"] = str(self.home)  # isolation hygiene (mock ignores)
        self.proc = subprocess.Popen(
            [self.python, str(_GATEWAY_MAIN), "--port", str(self.port)],
            env=env, stdout=self._log_fp, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, start_new_session=True,
        )
        self.start_count += 1
        _wait_port("127.0.0.1", self.port, timeout=20.0)
        _log.info("soak gateway up (pid=%s) port=%d home=%s",
                  self.proc.pid, self.port, self.home)

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    # -- signals (the T5 torture axes) -----------------------------------
    def sigstop(self) -> None:
        """SIGSTOP — freeze the gateway (the 'made slow/paused' axis)."""
        if self.proc:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGSTOP)

    def sigcont(self) -> None:
        """SIGCONT — resume a stopped gateway."""
        if self.proc:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGCONT)

    def term(self, *, timeout: float = 8.0) -> int:
        if self.proc is None:
            return -1
        # A stopped process can't handle SIGTERM until continued.
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGCONT)
        except ProcessLookupError:
            pass
        try:
            os.killpg(os.getpgid(self.proc.pid), signal.SIGTERM)
        except ProcessLookupError:
            self._close_log()
            self.proc = None
            return -1
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            raise RuntimeError("soak gateway ignored SIGTERM")
        finally:
            self._close_log()
        self.proc = None
        return rc

    def restart(self, *, settle_s: float = 0.3) -> int:
        rc = self.term()
        time.sleep(settle_s)
        self.start()
        return rc

    def stop(self) -> None:
        if self.is_alive():
            try:
                self.term()
            except RuntimeError:
                _log.exception("gateway would not term on cleanup")

    # -- control channel (over the wire) ---------------------------------
    async def create_session(self, *, script: str, **kwargs: Any) -> str:
        params: dict[str, str] = {"script": script}
        for k, v in kwargs.items():
            params[k] = str(v)
        async with httpx.AsyncClient() as c:
            r = await c.get(f"http://127.0.0.1:{self.port}/control/create_session",
                            params=params, timeout=10.0)
            r.raise_for_status()
            data = r.json()
        if not data.get("ok"):
            raise RuntimeError(f"create_session failed: {data}")
        return data["session_id"]

    async def inject_event(self, session_id: str, etype: str, payload: dict) -> None:
        """Broadcast a raw gateway event to the connected relay (T6 fuzzing)."""
        payload_b64 = base64.b64encode(
            json.dumps(payload).encode("utf-8")
        ).decode("ascii")
        self.events.append({"session_id": session_id, "type": etype, "payload": payload})
        async with httpx.AsyncClient() as c:
            r = await c.get(
                f"http://127.0.0.1:{self.port}/control/inject_event",
                params={"session_id": session_id, "type": etype,
                        "payload_b64": payload_b64},
                timeout=10.0,
            )
            r.raise_for_status()

    async def healthz(self) -> dict:
        async with httpx.AsyncClient() as c:
            r = await c.get(f"http://127.0.0.1:{self.port}/control/healthz",
                            timeout=5.0)
            return r.json()

    def _close_log(self) -> None:
        if self._log_fp is not None:
            try:
                self._log_fp.close()
            except Exception:
                pass
            self._log_fp = None
