"""Relay subprocess manager — start / SIGTERM / restart against a durable HOME.

Generalized from ``tests/e2e_daily_driver/conftest.py::RelayProc``. The relay
runs as a REAL subprocess so a kill is a real process signal (the deployment
failure mode T4 tortures). Key properties:

* own process group (``start_new_session=True``) so SIGTERM hits ONLY the relay;
* SIGTERM, NEVER kill -9 (spec hard rule — the graceful-shutdown contract);
* a STABLE per-scenario ``HERMES_HOME`` so ``DurableState``'s ``state.sqlite3``
  (owned sessions, attention, push outbox) PERSISTS across a relay restart —
  this is exactly what I5 (owned-session lifecycle) re-resumes from;
* downstream port fixed for the scenario so phones know where to reconnect
  after a restart.

The relay binary is ``<venv>/bin/python -m hermes_relay`` (run_soak.sh installs
the relay-under-test into that venv from the given SOURCE tree). This module
never touches the primary tree or a live relay.
"""

from __future__ import annotations

import logging
import os
import signal
import socket
import subprocess
import time
from pathlib import Path
from typing import Optional

_log = logging.getLogger("soak.relay_manager")


def wait_for_port(host: str, port: int, timeout: float = 45.0) -> None:
    """Block until ``host:port`` accepts a TCP connection (relay is listening)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"port {host}:{port} never opened (relay failed to bind?)")


def wait_for_port_gone(host: str, port: int, timeout: float = 10.0) -> None:
    """Block until ``host:port`` STOPS accepting (relay has released the port)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection((host, port), timeout=0.3):
                time.sleep(0.05)  # still up
        except OSError:
            return  # connection refused → port released
    raise RuntimeError(f"port {host}:{port} still open after {timeout}s")


class RelayManager:
    """Manage one relay subprocess across start/term/restart cycles.

    ``home`` is the durable HERMES_HOME (kept stable across restarts). ``cmd``
    is the full ``[python, -m hermes_relay, …]`` argv; ``env`` carries the
    gateway/downstream wiring. ``downstream_port`` is fixed for the scenario.
    """

    def __init__(
        self,
        *,
        cmd: list[str],
        env: dict[str, str],
        home: Path,
        log_dir: Path,
        downstream_port: int,
        host: str = "127.0.0.1",
    ) -> None:
        self.cmd = cmd
        self.env = env
        self.home = Path(home)
        self.log_dir = Path(log_dir)
        self.downstream_port = downstream_port
        self.host = host
        self.proc: Optional[subprocess.Popen] = None
        self.start_count = 0
        self.restart_log: list[dict] = []  # {t, pid, event} for evidence
        self._log_fp = None

    # -- lifecycle --------------------------------------------------------
    def start(self, *, wait_ready: bool = True) -> None:
        """Start the relay (or restart after a term). Waits for the port."""
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.home.mkdir(parents=True, exist_ok=True)
        (self.home / "relay").mkdir(exist_ok=True)
        log_path = self.log_dir / f"relay-start{self.start_count:03d}.log"
        self._log_fp = open(log_path, "ab", buffering=0)
        self.proc = subprocess.Popen(
            self.cmd,
            env=self.env,
            stdout=self._log_fp,
            stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL,
            start_new_session=True,  # own pgroup → SIGTERM the relay only
        )
        self.start_count += 1
        self.restart_log.append(
            {"t": time.time(), "pid": self.proc.pid, "event": "start",
             "log": str(log_path)}
        )
        if wait_ready:
            # Generous: python import + bind can be slow when the QA-3 swarm
            # pins the box (everything here runs niced).
            wait_for_port(self.host, self.downstream_port, timeout=45.0)
        _log.info("relay up (pid=%s, start#%d) downstream=%d home=%s",
                  self.proc.pid, self.start_count, self.downstream_port, self.home)

    def term(self, *, timeout: float = 10.0) -> int:
        """SIGTERM the relay's process group. NEVER kill -9 (spec hard rule)."""
        if self.proc is None:
            return -1
        pid = self.proc.pid
        try:
            os.killpg(os.getpgid(pid), signal.SIGTERM)
        except ProcessLookupError:
            self._close_log()
            self.proc = None
            return -1
        try:
            rc = self.proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            # Spec forbids kill -9. Surface loudly — a relay that ignores
            # SIGTERM is itself a defect worth failing on.
            raise RuntimeError(
                f"relay pid={pid} did not exit on SIGTERM within {timeout}s — "
                "investigate (graceful-shutdown contract violated)"
            )
        finally:
            self._close_log()
        self.restart_log.append({"t": time.time(), "pid": pid, "event": "term", "rc": rc})
        self.proc = None
        return rc

    def restart(self, *, settle_s: float = 0.3) -> int:
        """SIGTERM then start again against the SAME durable home (T4 kill loop)."""
        rc = self.term()
        # Wait for the port to release so the fresh bind never races the old
        # process's TIME_WAIT (SO_REUSEADDR handles most of it; this is belt).
        try:
            wait_for_port_gone(self.host, self.downstream_port, timeout=8.0)
        except RuntimeError:
            _log.warning("relay port still bound after term; restarting anyway")
        time.sleep(settle_s)
        self.start()
        return rc

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    @property
    def pid(self) -> Optional[int]:
        return self.proc.pid if self.proc is not None else None

    def stop(self) -> None:
        """Idempotent teardown for fixture cleanup."""
        if self.is_alive():
            try:
                self.term()
            except RuntimeError:
                _log.exception("relay would not term on cleanup")

    def _close_log(self) -> None:
        if self._log_fp is not None:
            try:
                self._log_fp.close()
            except Exception:
                pass
            self._log_fp = None
