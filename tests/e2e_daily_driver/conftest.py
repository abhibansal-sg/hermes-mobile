"""Hermetic fixtures for the transparent stock-proxy phone driver."""

from __future__ import annotations

import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import pytest
import pytest_asyncio

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))

from mock_gateway.server import MockGateway  # noqa: E402

EVIDENCE_DIR = Path(
    "/Volumes/MainData/Developer/hermes-tmp/evidence/daily-driver/e2e"
)


def _free_port() -> int:
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def _wait_for_port(port: int, timeout: float = 15) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.5):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"transparent relay never opened port {port}")


@pytest_asyncio.fixture
async def mock_gateway():
    gateway = MockGateway()
    await gateway.start()
    try:
        yield gateway
    finally:
        await gateway.stop()


class RelayProc:
    def __init__(self, process: subprocess.Popen, port: int) -> None:
        self.process = process
        self.downstream_port = port

    def stop(self) -> None:
        if self.process.poll() is not None:
            return
        os.killpg(os.getpgid(self.process.pid), signal.SIGTERM)
        self.process.wait(timeout=8)


@pytest_asyncio.fixture
async def relay_subprocess(mock_gateway: MockGateway, request: pytest.FixtureRequest):
    port = _free_port()
    EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
    log_path = EVIDENCE_DIR / f"{request.node.name}-relay.log"
    log_handle = log_path.open("wb")
    command = [
        os.environ.get("E2E_PYTHON", sys.executable),
        "-m", "hermes_relay",
        "--gateway-host", "127.0.0.1",
        "--gateway-port", str(mock_gateway.port),
        "--token", mock_gateway.token,
        "--listen", f"127.0.0.1:{port}",
        "--log-level", "INFO",
    ]
    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(ROOT / "relay")
    process = subprocess.Popen(
        command,
        cwd=ROOT,
        env=environment,
        stdout=log_handle,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
    relay = RelayProc(process, port)
    _wait_for_port(port)
    try:
        yield relay
    finally:
        relay.stop()
        log_handle.close()


@pytest.fixture
def evidence(request: pytest.FixtureRequest):
    def write(name: str, value: Any) -> Path:
        EVIDENCE_DIR.mkdir(parents=True, exist_ok=True)
        path = EVIDENCE_DIR / f"{request.node.name}-{name}.json"
        path.write_text(json.dumps(value, indent=2, default=str), encoding="utf-8")
        return path

    return write
