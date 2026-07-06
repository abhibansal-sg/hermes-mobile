"""Test that start_server configures ws-ping keepalive.

The server now uses uvicorn.Server directly (not uvicorn.run) so we stub
Config + Server + asyncio.run to capture kwargs without starting an event loop.
"""

import asyncio
import contextlib
import threading
import time

import uvicorn

from hermes_cli import web_server


def _stub_uvicorn(monkeypatch):
    """Replace uvicorn.Config/Server with fakes so start_server returns
    immediately.  Returns a dict with captured Config kwargs."""
    captured: dict = {}

    class _FakeConfig:
        loaded = True
        host = "127.0.0.1"
        port = 8000
        _loop_factory = None

        def __init__(self, *args, **kwargs):
            captured.update(kwargs)

        def load(self):
            pass

        def get_loop_factory(self):
            return self._loop_factory

        class lifespan_class:
            should_exit = False
            state: dict = {}

            def __init__(self, *a, **kw):
                pass

            async def startup(self):
                pass

            async def shutdown(self):
                pass

    class _FakeServer:
        should_exit = False
        started = True
        servers: list = []
        lifespan = None

        @staticmethod
        def capture_signals():
            return contextlib.nullcontext()

        async def startup(self, sockets=None):
            pass

        async def main_loop(self):
            pass

        async def shutdown(self, sockets=None):
            pass

    monkeypatch.setattr(uvicorn, "Config", _FakeConfig)
    monkeypatch.setattr(uvicorn, "Server", lambda config: _FakeServer())
    return captured


def test_start_server_disables_ws_ping_on_loopback(monkeypatch):
    """Loopback binds (the Desktop case) MUST disable uvicorn's protocol-level
    keepalive ping so an event-loop stall can never trigger a false disconnect.

    uvicorn's ws ping runs on the same event loop as agent turns. A single
    synchronous GIL-holding call on a worker thread can starve that loop for
    minutes, so the loop can't process the pong and uvicorn kills an
    otherwise-healthy local connection (#53773 "event loop stalled 226.3s",
    #48445/#50005). On loopback there is no network/proxy path where a
    half-open connection can occur — a dead local client tears the socket down
    with a real FIN/RST that surfaces as WebSocketDisconnect regardless — so
    the ping provides no liveness value and only harms. Assert it is disabled.
    """
    captured = _stub_uvicorn(monkeypatch)

    # Loopback bind => no auth gate, so this reaches the Config constructor.
    web_server.start_server(host="127.0.0.1", port=0, open_browser=False)

    assert captured["ws_ping_interval"] is None
    assert captured["ws_ping_timeout"] is None


def test_start_server_enables_ws_ping_for_half_open_detection(monkeypatch):
    """Non-loopback (public) binds MUST keep the ws ping enabled so half-open
    connections (reverse-proxy 524, dropped Cloudflare Tunnel) raise
    WebSocketDisconnect into the reaping path (#32377).

    The invariant asserted here is that ping stays enabled (non-None, positive)
    and the timeout is never shorter than the interval — not a frozen literal,
    which churns every time the window is retuned. Loopback disables the ping
    (see test_start_server_disables_ws_ping_on_loopback); this covers the
    public-bind half-open case, so the auth gate is active here.
    """
    captured = _stub_uvicorn(monkeypatch)

    # Non-loopback bind so the _is_loopback branch selects the enabled-ping
    # window. Neutralize the auth gate so start_server reaches uvicorn.Config
    # without requiring a registered provider (a real public bind would raise
    # SystemExit here). The ping window keys off the host, not the auth flag.
    monkeypatch.setattr(web_server, "should_require_auth", lambda *a, **k: False)
    web_server.start_server(host="0.0.0.0", port=0, open_browser=False)

    assert captured["ws_ping_interval"] and captured["ws_ping_interval"] > 0
    assert captured["ws_ping_timeout"] and captured["ws_ping_timeout"] > 0
    assert captured["ws_ping_timeout"] >= captured["ws_ping_interval"]


def test_start_server_runs_on_uvicorns_loop_factory(monkeypatch):
    """The dashboard/desktop backend must serve uvicorn on the loop *uvicorn*
    selects, not the interpreter default.

    On Windows ``asyncio.run`` defaults to a ProactorEventLoop, but uvicorn's
    socket-serving stack forces a SelectorEventLoop on win32
    (``uvicorn/loops/asyncio.py``). Serving on the proactor loop binds a socket
    that never accepts — the backend prints "Skipping web UI build" and hangs
    forever with the port LISTENING but no TCP handshake (#50641). We fix that
    by routing the serve call through ``uvicorn._compat.asyncio_run`` with
    ``config.get_loop_factory()`` — exactly what ``uvicorn.Server.run`` does.

    This asserts the behavioral contract: on Windows the loop factory the runner
    receives is the one uvicorn's own Config produced, and bare ``asyncio.run``
    is never the serve path when the loop-factory runner exists.
    """
    _stub_uvicorn(monkeypatch)

    # The fix only changes behavior on win32; simulate it so the Windows branch
    # is actually exercised on a POSIX CI host.
    monkeypatch.setattr(web_server.sys, "platform", "win32")

    # The fake Config (installed by _stub_uvicorn) returns its ``_loop_factory``
    # from get_loop_factory(). Pin a sentinel so we can assert it is threaded
    # through to the runner unchanged.
    sentinel_factory = object()
    monkeypatch.setattr(uvicorn.Config, "_loop_factory", sentinel_factory, raising=False)

    seen: dict = {}

    def _fake_runner(coro, *, loop_factory=None):
        seen["loop_factory"] = loop_factory
        coro.close()  # drain without an event loop

    monkeypatch.setattr("uvicorn._compat.asyncio_run", _fake_runner, raising=False)

    # Bare asyncio.run must NOT be the serve path on Windows when the
    # loop-factory runner is importable.
    called_bare = {"hit": False}

    def _guard_asyncio_run(coro):
        called_bare["hit"] = True
        coro.close()
        return None

    monkeypatch.setattr(asyncio, "run", _guard_asyncio_run)

    web_server.start_server(host="127.0.0.1", port=0, open_browser=False)

    assert seen.get("loop_factory") is sentinel_factory, (
        "start_server must pass uvicorn's get_loop_factory() result to the "
        "runner so Windows serves on a SelectorEventLoop"
    )
    assert called_bare["hit"] is False, (
        "start_server must not fall back to bare asyncio.run when uvicorn's "
        "loop-factory runner is available"
    )


def test_start_server_keeps_bare_asyncio_run_on_posix(monkeypatch):
    """POSIX behavior must be byte-for-byte unchanged: serve via the plain
    ``asyncio.run(_serve())`` path, never the Windows loop-factory branch.

    The #50641 fix is intentionally win32-scoped to keep the blast radius
    minimal — Python's default loop on POSIX is already a SelectorEventLoop
    (or uvloop), which is what uvicorn serves on, so there is nothing to fix.
    """
    _stub_uvicorn(monkeypatch)
    monkeypatch.setattr(web_server.sys, "platform", "linux")

    # If the Windows branch were taken, the loop-factory runner would fire.
    runner_called = {"hit": False}

    def _fake_runner(coro, *, loop_factory=None):
        runner_called["hit"] = True
        coro.close()

    monkeypatch.setattr("uvicorn._compat.asyncio_run", _fake_runner, raising=False)

    bare_called = {"hit": False}

    def _fake_asyncio_run(coro):
        bare_called["hit"] = True
        coro.close()
        return None

    monkeypatch.setattr(asyncio, "run", _fake_asyncio_run)

    web_server.start_server(host="127.0.0.1", port=0, open_browser=False)

    assert bare_called["hit"] is True, "POSIX must serve via bare asyncio.run"
    assert runner_called["hit"] is False, (
        "POSIX must not take the Windows loop-factory branch"
    )


# ── Off-loop stall watchdog (STR-12 / ABH-370) ───────────────────────────


def _wait_until(predicate, timeout=2.0, interval=0.01) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


def test_stall_watchdog_trips_and_restarts_exactly_once():
    """A heartbeat that never advances past the threshold must trip the
    watchdog and fire the injected restart callback -- exactly once, even
    if the watchdog thread lives on for further poll cycles afterward."""
    restart_calls = []
    stale_beat = time.monotonic() - 1000.0  # already ancient, never updates

    wd = web_server._LoopStallWatchdog(
        get_last_beat=lambda: stale_beat,
        restart_callback=lambda: restart_calls.append(1),
        stall_threshold=0.05,
        poll_interval=0.02,
    )
    wd.start()
    try:
        assert _wait_until(lambda: wd.tripped, timeout=2.0), (
            "watchdog never tripped on a stale heartbeat"
        )
        # Give it several more poll cycles worth of time to prove it
        # doesn't spin/re-trip/re-restart.
        time.sleep(wd._poll_interval * 5)
        assert restart_calls == [1], (
            f"restart callback must fire exactly once, got {restart_calls!r}"
        )
        assert _wait_until(lambda: not wd._thread.is_alive(), timeout=2.0), (
            "watchdog thread must exit after tripping, not keep polling"
        )
    finally:
        wd.stop()


def test_stall_watchdog_normal_stop_does_not_restart():
    """Stopping the watchdog (the server.main_loop() returned normally path)
    before the heartbeat ever goes stale must never invoke the restart
    callback, and must leave no thread running behind."""
    restart_calls = []
    fresh_beat = time.monotonic()

    wd = web_server._LoopStallWatchdog(
        get_last_beat=lambda: fresh_beat,
        restart_callback=lambda: restart_calls.append(1),
        stall_threshold=10.0,
        poll_interval=0.02,
    )
    assert wd._thread.daemon is True, "watchdog thread must not block interpreter exit"

    wd.start()
    time.sleep(wd._poll_interval * 5)  # let it poll harmlessly a few times
    wd.stop()

    assert restart_calls == [], "restart must not fire on a clean shutdown"
    assert wd.tripped is False
    assert not wd._thread.is_alive(), "stop() must leave no watchdog thread running"


def test_format_stall_forensics_includes_loop_thread_and_stack_frame():
    """The forensics dump must identify the (suspected-wedged) loop thread
    by name and id, and include at least one real stack frame so the next
    incident is diagnosable from the log alone."""
    current = threading.current_thread()

    report = web_server._format_stall_forensics(
        age=123.4, threshold=75.0, loop_thread=current,
    )

    assert "123.4" in report
    assert "75.0" in report
    assert current.name in report
    assert str(current.ident) in report
    assert "[event loop]" in report
    # traceback.format_stack of this thread's live frame must include this
    # very test function somewhere in the call chain.
    assert (
        "test_format_stall_forensics_includes_loop_thread_and_stack_frame"
        in report
    )


def test_dump_stall_forensics_logs_via_module_logger(caplog):
    """_dump_stall_forensics (the production entry point _trip() calls)
    must actually emit the report through the module logger, not just
    build a string nobody sees."""
    current = threading.current_thread()
    with caplog.at_level("ERROR", logger="hermes_cli.web_server"):
        web_server._dump_stall_forensics(42.0, 75.0, current)

    assert "42.0" in caplog.text
    assert current.name in caplog.text
