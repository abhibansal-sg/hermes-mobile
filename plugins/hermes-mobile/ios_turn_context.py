"""Per-turn iOS/mobile output guidance for hermes-mobile sessions."""

from __future__ import annotations

from typing import Any, Dict, Optional

MOBILE_OUTPUT_CONTEXT = (
    "This is a mobile (iOS) session: keep output phone-native. Prefer concise Markdown. "
    "Avoid ASCII tables/charts, Mermaid, raw SVG, and HTML artifacts that do "
    "not render well in the app."
)

_MOBILE_PLATFORMS = frozenset({"ios", "mobile", "hermes-mobile"})


def _normalized_platform(platform: Any) -> str:
    return platform.strip().lower() if isinstance(platform, str) else ""


def _device_identity_for_tui_session(session_id: Any) -> Optional[dict]:
    """Return a mobile device identity for a live TUI runtime session, if any.

    Current WS-backed iOS turns build ``AIAgent(platform="tui")`` (see
    ``tui_gateway.server._make_agent``), so the hook's primary platform kwarg is
    not distinct from desktop/dashboard TUI. The reliable plugin-owned signal is
    the composition of (a) the gateway session's serving transport and (b) the
    hermes-mobile device-token socket index. Desktop/CLI/shared-token sessions
    are not indexed as device sockets; if anything is missing or ambiguous, fail
    closed and inject nothing.
    """
    sid = session_id.strip() if isinstance(session_id, str) else ""
    if not sid:
        return None

    try:
        from tui_gateway import server as _server
        from . import device_tokens
    except Exception:
        return None

    try:
        session = _server._sessions.get(sid)
    except Exception:
        return None
    if not isinstance(session, dict):
        return None

    transport = session.get("transport")
    device = device_tokens.record_session_transport(sid, transport)
    if device is not None:
        return device
    return device_tokens.device_identity_for_session(sid)


def _should_inject(*, platform: Any = "", session_id: Any = "", **_: Any) -> bool:
    plat = _normalized_platform(platform)
    if plat in _MOBILE_PLATFORMS:
        return True
    if plat == "tui" and _device_identity_for_tui_session(session_id):
        return True
    return False


def _on_pre_llm_call(**kwargs: Any) -> Optional[Dict[str, str]]:
    """Inject short output-format guidance only for iOS/mobile turns."""
    if not _should_inject(**kwargs):
        return None
    return {"context": MOBILE_OUTPUT_CONTEXT}


def activate(ctx: Any) -> None:
    """Register the pre_llm_call hook, idempotently for forced reloads."""
    hooks = getattr(getattr(ctx, "_manager", None), "_hooks", None)
    if isinstance(hooks, dict) and _on_pre_llm_call in hooks.get("pre_llm_call", []):
        return
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
