"""Tests for per-turn iOS/mobile output guidance injection."""

from __future__ import annotations

import sys
from contextlib import contextmanager

from tests.plugins.hermes_mobile.conftest import _PLUGIN_PKG, load_plugin_module


def _ios_turn_context():
    return load_plugin_module("ios_turn_context")


def _device_tokens():
    return load_plugin_module("device_tokens")


class _FakeTransport:
    def __init__(self, ws):
        self._ws = ws


@contextmanager
def _with_tui_session(session_id: str, transport):
    from tui_gateway import server as _server

    with _server._sessions_lock:
        previous_exists = session_id in _server._sessions
        previous = _server._sessions.get(session_id) or {}
        _server._sessions[session_id] = {"transport": transport}
    try:
        yield
    finally:
        with _server._sessions_lock:
            if not previous_exists:
                _server._sessions.pop(session_id, None)
            else:
                _server._sessions[session_id] = previous


def test_ios_platform_injects_short_mobile_formatting_context():
    ios = _ios_turn_context()

    result = ios._on_pre_llm_call(
        session_id="session-1",
        user_message="show me options",
        conversation_history=[],
        platform="ios",
    )

    assert result is not None
    context = result["context"]
    assert "mobile (iOS)" in context
    assert "concise Markdown" in context
    assert "card JSON" not in context
    assert "structured UI" not in context
    assert "Avoid ASCII" in context
    assert "Mermaid" in context
    assert "HTML" in context
    assert len(context) < 500


def test_mobile_platform_alias_injects_same_context():
    ios = _ios_turn_context()

    result = ios._on_pre_llm_call(session_id="session-1", platform="mobile")

    assert result == {"context": ios.MOBILE_OUTPUT_CONTEXT}


def test_tui_session_with_device_token_transport_injects_context(monkeypatch, tmp_path):
    ios = _ios_turn_context()
    device_tokens = _device_tokens()
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()

    issued = device_tokens.issue(device_name="Abhi's iPhone")
    ws = object()
    device_tokens.register_ws_socket(issued["device_id"], ws)

    with _with_tui_session("runtime-sid", _FakeTransport(ws)):
        result = ios._on_pre_llm_call(session_id="runtime-sid", platform="tui")

    assert result == {"context": ios.MOBILE_OUTPUT_CONTEXT}


def test_tui_shared_token_session_does_not_inject(monkeypatch, tmp_path):
    ios = _ios_turn_context()
    device_tokens = _device_tokens()
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()

    with _with_tui_session("runtime-sid", _FakeTransport(object())):
        assert ios._on_pre_llm_call(session_id="runtime-sid", platform="tui") is None


def test_tui_missing_or_ambiguous_device_signal_fails_closed(monkeypatch, tmp_path):
    ios = _ios_turn_context()
    device_tokens = _device_tokens()
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()

    assert ios._on_pre_llm_call(session_id="missing-runtime-sid", platform="tui") is None

    first = device_tokens.issue(device_name="First iPhone")
    second = device_tokens.issue(device_name="Second iPhone")
    ws = object()
    device_tokens.register_ws_socket(first["device_id"], ws)
    device_tokens.register_ws_socket(second["device_id"], ws)

    with _with_tui_session("ambiguous-runtime-sid", _FakeTransport(ws)):
        assert ios._on_pre_llm_call(session_id="ambiguous-runtime-sid", platform="tui") is None


def test_non_ios_platforms_do_not_inject(monkeypatch):
    ios = _ios_turn_context()
    monkeypatch.setattr(ios, "_device_identity_for_tui_session", lambda session_id: None)

    for platform in ("", None, "cli", "desktop", "telegram", "tui", "cron"):
        assert ios._on_pre_llm_call(session_id="session-1", platform=platform) is None


def test_activate_registers_pre_llm_call_hook():
    from hermes_cli.plugins import PluginContext, PluginManager, PluginManifest

    ios = _ios_turn_context()
    manager = PluginManager()
    manifest = PluginManifest(name="hermes-mobile", key="hermes-mobile")
    ctx = PluginContext(manifest, manager)

    ios.activate(ctx)

    assert ios._on_pre_llm_call in manager._hooks["pre_llm_call"]


def test_plugin_register_wires_ios_turn_context_hook():
    from hermes_cli.plugins import PluginContext, PluginManager, PluginManifest

    ios = _ios_turn_context()
    plugin = sys.modules[_PLUGIN_PKG]
    manager = PluginManager()
    manifest = PluginManifest(name="hermes-mobile", key="hermes-mobile")
    ctx = PluginContext(manifest, manager)

    plugin.register(ctx)

    assert ios._on_pre_llm_call in manager._hooks["pre_llm_call"]
