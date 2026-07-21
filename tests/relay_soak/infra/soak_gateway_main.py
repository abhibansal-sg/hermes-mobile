"""Controllable mock gateway + subprocess entry point (for T5 gateway abuse).

T5 (the S8 suspect class) needs a gateway the harness can SIGSTOP / SIGCONT /
SIGTERM / restart WHILE the relay serves it. An in-process gateway cannot be
signaled, so this module runs the deterministic scripted
:class:`~mock_gateway.server.MockGateway` as its OWN process on a fixed port in
the isolated 9140+ band, and adds a tiny ``/control`` HTTP surface the harness
uses to (a) create scripted sessions over the wire and (b) inject raw gateway
events (for fuzzing the relay's reframer).

Determinism is preserved: the upstream is still the scripted echo gateway, so
I2 byte-identical reconciliation stays meaningful even while the gateway is
paused/restarted.

This file is run as a script (``python soak_gateway_main.py --port 9140 …``);
it is NOT imported by the scenarios. It adds ``tests/e2e_daily_driver`` to
``sys.path`` to reuse the ratified MockGateway verbatim.
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import sys
import uuid
from http import HTTPStatus
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import websockets

# Reuse the ratified scripted gateway verbatim (never fork it).
_E2E_DIR = Path(__file__).resolve().parents[2] / "e2e_daily_driver"
sys.path.insert(0, str(_E2E_DIR))
sys.path.insert(0, str(_E2E_DIR / "mock_gateway"))

from mock_gateway.server import MockGateway, MockSession, Script  # noqa: E402

_log = logging.getLogger("soak.gateway_main")

# Query-param keys we forward into a Script's kwargs, and their coercions.
_KWARG_COERCIONS = {
    "text": str,
    "title": str,
    "description": str,
    "question": str,
    "request_id": str,
    "delta_delay_s": float,
    "wait_timeout_s": float,
}


class ControllableMockGateway(MockGateway):
    """Scripted mock gateway + a ``/control`` HTTP surface for the harness.

    ``/control`` is served on the SAME port (websockets calls process_request
    before the WS upgrade). Every control route is a plain GET that returns
    JSON and never upgrades — the relay's WS traffic is unaffected.
    """

    async def start(self, *, port: int = 0) -> None:  # type: ignore[override]
        """Like MockGateway.start but binds an EXPLICIT port (fixed for T5)."""
        self._server = await websockets.serve(
            self._handle, "127.0.0.1", port,
            max_size=8 * 1024 * 1024,
            process_request=self._process_request,
        )
        socks = self._server.sockets or self._server.server.sockets  # type: ignore[attr-defined]
        self._port = socks[0].getsockname()[1]
        _log.info("soak controllable gateway on 127.0.0.1:%s", self._port)

    async def _process_request(self, conn, request):  # noqa: N802
        path = (getattr(request, "path", "") or "")
        url = urlsplit(path)
        if url.path.startswith("/control/"):
            return await self._handle_control(conn, url.path, parse_qs(url.query))
        # Everything else (REST history, healthz, WS upgrade) → stock behavior.
        return await super()._process_request(conn, request)

    async def _handle_control(self, conn, path: str, qs: dict):
        def respond(obj, status=HTTPStatus.OK):
            return conn.respond(status, json.dumps(obj) + "\n")

        if path == "/control/healthz":
            return respond({"ok": True, "sessions": len(self.sessions)})

        if path == "/control/create_session":
            script = (qs.get("script") or ["simple"])[0]
            kwargs = {}
            for key, coerce in _KWARG_COERCIONS.items():
                if key in qs:
                    try:
                        kwargs[key] = coerce(qs[key][0])
                    except (ValueError, TypeError):
                        return respond({"ok": False, "error": f"bad {key}"},
                                       HTTPStatus.BAD_REQUEST)
            sid = f"sess-{uuid.uuid4().hex[:8]}"
            self.sessions[sid] = MockSession(
                sid=sid, title=script,
                script=Script(name=script, kwargs=kwargs),
            )
            return respond({"ok": True, "session_id": sid})

        if path == "/control/inject_event":
            sid = (qs.get("session_id") or [""])[0]
            etype = (qs.get("type") or [""])[0]
            payload_b64 = (qs.get("payload_b64") or ["e30="])[0]  # default "{}"
            try:
                payload = json.loads(base64.b64decode(payload_b64).decode("utf-8"))
            except Exception as exc:  # noqa: BLE001
                return respond({"ok": False, "error": f"bad payload: {exc}"},
                               HTTPStatus.BAD_REQUEST)
            # Broadcast a raw gateway event to every connected relay. This is
            # the seam T6 uses to mutate upstream events at the relay.
            await self._broadcast(sid, {"type": etype, "payload": payload})
            return respond({"ok": True})

        return respond({"ok": False, "error": f"unknown control {path}"},
                       HTTPStatus.NOT_FOUND)


async def _amain(port: int) -> None:
    gw = ControllableMockGateway()
    await gw.start(port=port)
    # Serve until the harness SIGTERMs us (graceful — the relay must observe a
    # clean close, exactly the T5 restart failure mode).
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in ("SIGTERM", "SIGINT"):
        try:
            loop.add_signal_handler(getattr(__import__("signal"), sig), stop.set)
        except (NotImplementedError, RuntimeError):
            pass
    _log.info("gateway ready; awaiting stop")
    await stop.wait()
    await gw.stop()
    _log.info("gateway stopped")


def main() -> None:
    import argparse

    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--log-level", default="INFO")
    args = p.parse_args()
    logging.basicConfig(level=getattr(logging, args.log_level.upper(), logging.INFO),
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # HERMES_HOME is set by the launcher for isolation hygiene; the mock does
    # not read it, but we assert it is NOT the user's real home (defensive).
    home = os.environ.get("HERMES_HOME", "")
    if home and home == str(Path.home()):
        raise SystemExit("soak gateway refuses to run with the real HERMES_HOME")
    asyncio.run(_amain(args.port))


if __name__ == "__main__":
    main()
