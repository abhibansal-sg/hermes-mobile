"""Tests for the tui-gateway plugin observer hooks (de-patch, 2026-07-11).

Covers the three first-class hooks that replace the hermes-mobile plugin's
private observer-list seams:

  - ``post_emit_event``        (replaces S2  ``server._EMIT_OBSERVERS``)
  - ``post_frame_write``       (replaces S1a ``server._EVENT_FANOUT_SUBSCRIBERS``)
  - ``on_ws_transport_change`` (replaces S1  ``ws.TRANSPORT_OBSERVERS``)

Behavior contracts (not snapshots):
  1. The hooks are VALID_HOOKS members (a plugin registering them gets no
     unknown-hook warning).
  2. The gateway call sites actually invoke them with the documented kwargs.
  3. A raising hook callback never breaks the gateway path (isolation).
  4. The legacy observer-list seams still work (back-compat: older plugin
     versions must keep functioning against a core that ships the hooks).
"""

import sys
import types
from unittest import mock

import pytest

from hermes_cli import plugins as plugins_mod
from hermes_cli.plugins import VALID_HOOKS, get_plugin_manager


@pytest.fixture(autouse=True)
def _fresh_hooks():
    """Isolate hook registrations per test."""
    mgr = get_plugin_manager()
    before = {k: list(v) for k, v in mgr._hooks.items()}
    yield mgr
    mgr._hooks.clear()
    mgr._hooks.update(before)


def test_gateway_observer_hooks_are_valid():
    for hook in ("post_emit_event", "post_frame_write", "on_ws_transport_change"):
        assert hook in VALID_HOOKS, f"{hook} missing from VALID_HOOKS"


def test_post_emit_event_fired_with_documented_kwargs(_fresh_hooks):
    from tui_gateway import server

    seen = []
    _fresh_hooks._hooks.setdefault("post_emit_event", []).append(
        lambda event=None, session_id=None, payload=None, **kw: seen.append(
            (event, session_id, payload)
        )
    )
    server._notify_emit_observers("turn.complete", "sess-1", {"ok": True})
    assert seen == [("turn.complete", "sess-1", {"ok": True})]


def test_post_emit_event_raising_callback_is_isolated(_fresh_hooks):
    from tui_gateway import server

    def _boom(**kw):
        raise RuntimeError("plugin bug")

    _fresh_hooks._hooks.setdefault("post_emit_event", []).append(_boom)
    # Must not raise.
    server._notify_emit_observers("turn.complete", "sess-1", None)


def test_legacy_emit_observer_seam_still_fires(_fresh_hooks):
    from tui_gateway import server

    seen = []
    server._EMIT_OBSERVERS.append(lambda e, s, p: seen.append((e, s)))
    try:
        server._notify_emit_observers("x", "sid", None)
    finally:
        server._EMIT_OBSERVERS.pop()
    assert seen == [("x", "sid")]


def test_on_ws_transport_change_fired_and_isolated(_fresh_hooks):
    from tui_gateway import ws

    seen = []
    _fresh_hooks._hooks.setdefault("on_ws_transport_change", []).append(
        lambda action=None, transport=None, **kw: seen.append(action)
    )
    _fresh_hooks._hooks.setdefault("on_ws_transport_change", []).append(
        lambda **kw: (_ for _ in ()).throw(RuntimeError("bad plugin"))
    )
    fake_transport = object()
    ws._notify_transport_observers("connect", fake_transport)  # must not raise
    assert seen == ["connect"]


def test_post_frame_write_fired_for_owned_session_frames(_fresh_hooks):
    from tui_gateway import server

    seen = []
    _fresh_hooks._hooks.setdefault("post_frame_write", []).append(
        lambda frame=None, session_id=None, owner_transport=None, **kw: seen.append(
            (frame.get("method"), session_id)
        )
    )

    class _T:
        def write(self, obj):
            return None

    t = _T()
    with mock.patch.dict(server._sessions, {"sid-9": {"transport": t}}, clear=False):
        server.write_json({"method": "event", "params": {"session_id": "sid-9"}})
    assert seen == [("event", "sid-9")]
