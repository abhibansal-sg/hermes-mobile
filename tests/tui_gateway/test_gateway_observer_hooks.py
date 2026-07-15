"""Behavior contracts for the plugin-facing TUI gateway observer hooks."""

from __future__ import annotations

import asyncio
from unittest import mock

import pytest

from hermes_cli.plugins import VALID_HOOKS, get_plugin_manager


@pytest.fixture
def hook_manager():
    manager = get_plugin_manager()
    before = {name: list(callbacks) for name, callbacks in manager._hooks.items()}
    yield manager
    manager._hooks.clear()
    manager._hooks.update(before)


def test_gateway_observer_hooks_are_valid():
    assert {
        "post_emit_event",
        "post_frame_write",
        "on_ws_transport_change",
    } <= VALID_HOOKS


def test_post_emit_event_receives_documented_kwargs(hook_manager):
    from tui_gateway import server

    seen = []
    hook_manager._hooks.setdefault("post_emit_event", []).append(
        lambda **kwargs: seen.append(kwargs)
    )
    server._emit("turn.complete", "sess-1", {"ok": True})
    assert len(seen) == 1
    assert seen[0]["event"] == "turn.complete"
    assert seen[0]["session_id"] == "sess-1"
    assert seen[0]["payload"] == {"ok": True}


def test_post_frame_write_is_after_owner_write_and_preserves_result(hook_manager):
    from tui_gateway import server

    order = []
    hook_manager._hooks.setdefault("post_frame_write", []).append(
        lambda **kwargs: order.append(("hook", kwargs["session_id"]))
    )

    class Transport:
        def write(self, _obj):
            order.append(("write", "sess-1"))
            return False

    transport = Transport()
    with mock.patch.dict(
        server._sessions,
        {"sess-1": {"transport": transport}},
        clear=False,
    ):
        result = server.write_json(
            {"method": "event", "params": {"session_id": "sess-1"}}
        )

    assert result is False
    assert order == [("write", "sess-1"), ("hook", "sess-1")]


def test_raising_observer_does_not_break_gateway_io(hook_manager):
    from tui_gateway import server

    def boom(**_kwargs):
        raise RuntimeError("plugin bug")

    hook_manager._hooks.setdefault("post_emit_event", []).append(boom)
    server._emit("turn.complete", "sess-1", None)


def test_handle_ws_notifies_connect_and_disconnect(hook_manager, monkeypatch):
    from hermes_cli import mcp_startup
    from tui_gateway import server
    from tui_gateway import ws as ws_module

    monkeypatch.setattr(
        mcp_startup,
        "start_background_mcp_discovery",
        lambda **_kwargs: None,
    )
    seen = []
    hook_manager._hooks.setdefault("on_ws_transport_change", []).append(
        lambda **kwargs: seen.append(kwargs["action"])
    )

    class FakeWS:
        scope = {}

        async def accept(self):
            return None

        async def send_text(self, _line):
            return None

        async def receive_text(self):
            raise ws_module._WebSocketDisconnect()

        async def close(self):
            return None

    asyncio.run(ws_module.handle_ws(FakeWS()))
    if server._OBSERVER_POOL is not None:
        server._OBSERVER_POOL.submit(lambda: None).result(timeout=5)
    assert seen == ["connect", "disconnect"]
