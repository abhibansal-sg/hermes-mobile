"""Regression tests for STR-1101: exception-safe Chrome-debug-process reaper.

See ``tests/conftest.py::_reap_leaked_chrome_debug_processes``. STR-860
commit ab6ddd611 called ``psutil.process_iter(["pid", "name"])``, which
makes psutil eagerly resolve ``name`` while building each ``Process``
inside the generator. On macOS, resolving ``name`` can fall back to
``cmdline()``, which raises PermissionError/SystemError for processes
owned by other users — and that raise surfaces from the generator's
``__next__`` *before* the per-process try/except in the loop body ever
runs, crashing the whole finalizer (and its ``atexit`` twin) and failing
the current test file.
"""

import sys
import types

import pytest

from tests.conftest import _reap_leaked_chrome_debug_processes


def _install_fake_psutil(monkeypatch, process_iter):
    fake = types.ModuleType("psutil")
    fake.process_iter = process_iter
    monkeypatch.setitem(sys.modules, "psutil", fake)


class _FakeProc:
    def __init__(self, cmdline_result=None, cmdline_exc=None):
        self._cmdline_result = cmdline_result
        self._cmdline_exc = cmdline_exc
        self.terminated = False
        self.waited = False

    def cmdline(self):
        if self._cmdline_exc is not None:
            raise self._cmdline_exc
        return self._cmdline_result

    def terminate(self):
        self.terminated = True

    def wait(self, timeout=None):
        self.waited = True


def _leaked_chrome_proc(tmp_path):
    user_data_dir = tmp_path / "chrome-debug-leak"
    user_data_dir.mkdir()
    return _FakeProc(
        cmdline_result=[
            "/fake/chrome",
            "--remote-debugging-port=9222",
            f"--user-data-dir={user_data_dir}",
        ]
    )


@pytest.mark.parametrize("exc_type", [PermissionError, SystemError])
def test_reaper_survives_process_iter_raising_from_next(monkeypatch, exc_type):
    """A raise from process_iter's generator __next__ must not propagate.

    This reproduces the exact STR-860 crash: psutil's generator raises
    while resolving a later process's attrs, mid-iteration, before any
    per-process try/except in the reaper's loop body can catch it.
    """

    def process_iter(*args, **kwargs):
        def gen():
            raise exc_type("denied mid-iteration")
            yield  # pragma: no cover - unreachable; makes this a generator

        return gen()

    _install_fake_psutil(monkeypatch, process_iter)

    # Must return quietly, not raise/crash the finalizer.
    _reap_leaked_chrome_debug_processes()


@pytest.mark.parametrize("exc_type", [PermissionError, SystemError])
def test_reaper_survives_process_iter_raising_on_call(monkeypatch, exc_type):
    """A raise from calling process_iter() itself must not propagate."""

    def process_iter(*args, **kwargs):
        raise exc_type("denied")

    _install_fake_psutil(monkeypatch, process_iter)

    _reap_leaked_chrome_debug_processes()


def test_reaper_skips_broken_process_and_still_reaps_genuine_leak(monkeypatch, tmp_path):
    """A process whose .cmdline() raises must not block a later genuine leak.

    Proves exception-safety at the per-item level AND that a mid-stream
    raise does not cause the reaper to skip processes that come after it.
    """

    broken = _FakeProc(cmdline_exc=PermissionError("no access"))
    leaked = _leaked_chrome_proc(tmp_path)

    def process_iter(*args, **kwargs):
        return iter([broken, leaked])

    _install_fake_psutil(monkeypatch, process_iter)

    _reap_leaked_chrome_debug_processes()

    assert leaked.terminated is True
    assert leaked.waited is True
    assert broken.terminated is False
