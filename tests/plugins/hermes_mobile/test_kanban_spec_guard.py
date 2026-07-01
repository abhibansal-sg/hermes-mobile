"""Tests for the hermes-mobile kanban spec guard pre-tool hook."""

from __future__ import annotations

from tests.plugins.hermes_mobile.conftest import load_plugin_module

AGENT_KWARGS = {
    "task_id": "t_parent",
    "session_id": "session-1",
    "tool_call_id": "call_123",
    "turn_id": "turn-1",
    "api_request_id": "req-1",
}


def _guard():
    return load_plugin_module("kanban_spec_guard")


def test_agent_kanban_create_with_empty_body_is_blocked():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={"title": "do thing", "assignee": "engineer", "body": ""},
        **AGENT_KWARGS,
    )

    assert result is not None
    assert result["action"] == "block"
    message = result["message"]
    assert "real spec" in message
    assert "goal" in message.lower()
    assert "scope" in message.lower()
    assert "acceptance" in message.lower()


def test_agent_kanban_create_with_too_short_body_is_blocked():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={"title": "do thing", "assignee": "engineer", "body": "too vague"},
        **AGENT_KWARGS,
    )

    assert result is not None
    assert result["action"] == "block"
    assert "too short" in result["message"].lower()


def test_agent_kanban_create_title_only_without_thin_body_marker_is_blocked():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={"title": "do thing", "assignee": "engineer"},
        **AGENT_KWARGS,
    )

    assert result is not None
    assert result["action"] == "block"


def test_agent_kanban_create_with_good_body_is_allowed():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={
            "title": "do thing",
            "assignee": "engineer",
            "body": "Goal: build the thing. Scope: only this module. Acceptance: tests pass and reviewer can reproduce.",
        },
        **AGENT_KWARGS,
    )

    assert result is None


def test_agent_kanban_create_with_triage_true_and_thin_body_is_allowed():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={"title": "triage idea", "assignee": "specifier", "triage": True},
        **AGENT_KWARGS,
    )

    assert result is None


def test_agent_kanban_create_with_blocked_initial_status_and_thin_body_is_allowed():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={
            "title": "urgent human escalation",
            "assignee": "ops",
            "initial_status": "blocked",
        },
        **AGENT_KWARGS,
    )

    assert result is None


def test_agent_kanban_create_with_idempotency_key_and_thin_body_is_allowed():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={
            "title": "retry-safe automation card",
            "assignee": "engineer",
            "idempotency_key": "retry-safe-card",
        },
        **AGENT_KWARGS,
    )

    assert result is None


def test_non_kanban_create_tool_is_allowed():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_comment",
        args={"task_id": "t_parent", "body": "short comment"},
        **AGENT_KWARGS,
    )

    assert result is None


def test_human_initiated_kanban_create_is_allowed_without_agent_context():
    guard = _guard()

    result = guard._on_pre_tool_call(
        tool_name="kanban_create",
        args={"title": "human title-only card", "assignee": "engineer", "body": ""},
    )

    assert result is None


def test_activate_registers_pre_tool_call_hook():
    from hermes_cli.plugins import PluginContext, PluginManager, PluginManifest

    guard = _guard()
    manager = PluginManager()
    manifest = PluginManifest(name="hermes-mobile", key="hermes-mobile")
    ctx = PluginContext(manifest, manager)

    guard.activate(ctx)

    assert guard._on_pre_tool_call in manager._hooks["pre_tool_call"]


def test_plugin_register_wires_kanban_spec_guard_hook():
    from hermes_cli.plugins import PluginContext, PluginManager, PluginManifest
    from tests.plugins.hermes_mobile.conftest import _PLUGIN_PKG
    import sys

    guard = _guard()
    plugin = sys.modules[_PLUGIN_PKG]
    manager = PluginManager()
    manifest = PluginManifest(name="hermes-mobile", key="hermes-mobile")
    ctx = PluginContext(manifest, manager)

    plugin.register(ctx)

    assert guard._on_pre_tool_call in manager._hooks["pre_tool_call"]
