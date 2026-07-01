"""Tests for per-turn iOS/mobile output guidance injection."""

from __future__ import annotations

import sys

from tests.plugins.hermes_mobile.conftest import _PLUGIN_PKG, load_plugin_module


def _ios_turn_context():
    return load_plugin_module("ios_turn_context")


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
    assert "Markdown" in context
    assert "fenced card JSON" in context
    assert "ASCII" in context
    assert "Mermaid" in context
    assert "HTML" in context
    assert len(context) < 500


def test_mobile_platform_alias_injects_same_context():
    ios = _ios_turn_context()

    result = ios._on_pre_llm_call(session_id="session-1", platform="mobile")

    assert result == {"context": ios.MOBILE_OUTPUT_CONTEXT}


def test_tui_session_with_device_token_transport_injects_context(monkeypatch):
    ios = _ios_turn_context()
    monkeypatch.setattr(
        ios,
        "_device_identity_for_tui_session",
        lambda session_id: {"device_id": "dev_ios", "device_name": "Abhi's iPhone"},
    )

    result = ios._on_pre_llm_call(session_id="runtime-sid", platform="tui")

    assert result == {"context": ios.MOBILE_OUTPUT_CONTEXT}


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
