"""Kanban spec guard for agent-created cards.

This plugin hook blocks under-specified kanban_create calls from the agent loop
while leaving human-created cards alone. The pre_tool_call seam only gives us
call context, so the guard requires agent execution markers (tool_call_id,
turn_id, or api_request_id) before enforcing policy.
"""

from __future__ import annotations

from typing import Any, Dict, Optional

MIN_BODY_CHARS = 40


def _is_agent_initiated(
    *,
    tool_call_id: str = "",
    turn_id: str = "",
    api_request_id: str = "",
    **_: Any,
) -> bool:
    """Return True when the hook context came from an agent tool call.

    Agent executors pass LLM/tool-loop identifiers into the pre_tool_call seam.
    Human/CLI/dashboard creates do not have those markers, and must not be
    blocked by this guard.
    """
    return any(
        isinstance(value, str) and bool(value.strip())
        for value in (tool_call_id, turn_id, api_request_id)
    )


def _card_body(args: Any) -> str:
    """Extract the kanban card spec body from tool args."""
    if not isinstance(args, dict):
        return ""
    value = args.get("body")
    if value is None:
        # The kanban_create schema calls this field body, but accept
        # description defensively for older callers / tests.
        value = args.get("description")
    return value if isinstance(value, str) else ""


def _allows_thin_body(args: Any) -> bool:
    """Return True for documented kanban_create shapes with thin bodies."""
    if not isinstance(args, dict):
        return False

    triage = args.get("triage")
    if triage is True:
        return True
    if isinstance(triage, str) and triage.strip().lower() in {"true", "1", "yes"}:
        return True

    if args.get("initial_status") == "blocked":
        return True

    idempotency_key = args.get("idempotency_key")
    return isinstance(idempotency_key, str) and bool(idempotency_key.strip())


def _block_message(body: str) -> str:
    stripped = body.strip()
    if not stripped:
        problem = "missing"
    else:
        problem = f"too short ({len(stripped)} chars; minimum {MIN_BODY_CHARS})"
    return (
        f"kanban_create blocked: card body is {problem}. "
        "Agents must include a real spec in the body before creating a card: "
        "goal, scope, and acceptance criteria. Re-issue kanban_create with "
        "those details instead of a title-only card."
    )


def _on_pre_tool_call(
    tool_name: str = "",
    args: Any = None,
    **context: Any,
) -> Optional[Dict[str, str]]:
    """Block agent-created kanban cards whose body is missing/too short."""
    if tool_name != "kanban_create":
        return None
    if not _is_agent_initiated(**context):
        return None
    if _allows_thin_body(args):
        return None

    body = _card_body(args)
    if len(body.strip()) >= MIN_BODY_CHARS:
        return None
    return {"action": "block", "message": _block_message(body)}


def activate(ctx: Any) -> None:
    """Register the pre_tool_call hook, idempotently for forced reloads."""
    hooks = getattr(getattr(ctx, "_manager", None), "_hooks", None)
    if isinstance(hooks, dict) and _on_pre_tool_call in hooks.get("pre_tool_call", []):
        return
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
