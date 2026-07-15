"""Fast-mode config changes stay scoped to the selected gateway session."""

from __future__ import annotations

from tui_gateway import server


def test_lazy_session_fast_override_does_not_write_profile(monkeypatch):
    session_id = "lazy-fast"
    session = {"agent": None, "create_service_tier_override": None}
    server._sessions[session_id] = session
    writes = []
    monkeypatch.setattr(server, "_write_config_key", lambda *args: writes.append(args))
    monkeypatch.setattr(server, "_load_service_tier", lambda: None)
    monkeypatch.setattr(server, "_resolve_model", lambda: "openai/gpt-test")

    from hermes_cli import models

    monkeypatch.setattr(models, "resolve_fast_mode_overrides", lambda _model: {})
    try:
        enabled = server._methods["config.set"](
            "rpc-1", {"session_id": session_id, "key": "fast", "value": "fast"}
        )
        status = server._methods["config.get"](
            "rpc-2", {"session_id": session_id, "key": "fast"}
        )
        disabled = server._methods["config.set"](
            "rpc-3", {"session_id": session_id, "key": "fast", "value": "normal"}
        )
    finally:
        server._sessions.pop(session_id, None)

    assert enabled["result"]["value"] == "fast"
    assert status["result"]["value"] == "fast"
    assert disabled["result"]["value"] == "normal"
    assert session["create_service_tier_override"] == ""
    assert writes == []
