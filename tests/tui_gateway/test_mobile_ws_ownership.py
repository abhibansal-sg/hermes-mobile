"""Authorization guards for device-authenticated gateway RPCs."""

from __future__ import annotations

import threading

from tui_gateway import server


def _device(*, scopes=("chat", "approve")) -> dict:
    return {"device_id": "dev-owner", "scopes": list(scopes)}


def test_prompt_response_rejects_non_owner_before_unblocking(monkeypatch):
    event = threading.Event()
    server._pending["prompt-1"] = ("session-1", event)
    monkeypatch.setattr(server, "_ws_device_identity", lambda: _device())
    monkeypatch.setattr(server, "_ws_device_owns_session", lambda *_args: False)

    try:
        result = server._respond(
            "rpc-1", {"request_id": "prompt-1", "value": "secret"}, "value"
        )
    finally:
        server._pending.pop("prompt-1", None)
        server._answers.pop("prompt-1", None)

    assert result["error"]["code"] == 4030
    assert not event.is_set()


def test_approval_respond_rejects_missing_scope_before_resolution(monkeypatch):
    monkeypatch.setattr(server, "_sess", lambda _params, _rid: ({"session_key": "key-1"}, None))
    monkeypatch.setattr(server, "_ws_device_identity", lambda: _device(scopes=("chat",)))
    resolved = []

    import tools.approval as approval

    monkeypatch.setattr(
        approval,
        "resolve_gateway_approval",
        lambda *_args, **_kwargs: resolved.append(True),
    )
    result = server._methods["approval.respond"](
        "rpc-2", {"session_id": "session-1", "choice": "approve"}
    )

    assert result["error"]["code"] == 4030
    assert resolved == []


def test_session_branch_rejects_non_owner_before_agent_build(monkeypatch):
    session_id = "branch-owner-check"
    server._sessions[session_id] = {"session_key": "key-1"}
    monkeypatch.setattr(server, "_ws_device_identity", lambda: _device())
    monkeypatch.setattr(server, "_ws_device_owns_session", lambda *_args: False)
    builds = []
    monkeypatch.setattr(server, "_start_agent_build", lambda *_args: builds.append(True))

    try:
        result = server._methods["session.branch"](
            "rpc-3", {"session_id": session_id}
        )
    finally:
        server._sessions.pop(session_id, None)

    assert result["error"]["code"] == 4030
    assert builds == []


def test_gateway_runtime_snapshot_is_content_free_and_mutation_safe():
    session_id = "runtime-snapshot"
    secret_agent = object()
    with server._sessions_lock:
        previous = dict(server._sessions)
        server._sessions.clear()
        server._sessions[session_id] = {
            "session_key": "stored-snapshot",
            "agent": secret_agent,
            "transport": object(),
            "history": [{"role": "user", "content": "must not leak"}],
            "running": True,
            "created_at": 10.0,
            "last_active": 11.0,
            "turn_started_at": 12.0,
            "profile_home": "/profiles/default",
        }
    try:
        first = server.gateway_runtime_snapshot()
        first["sessions"][0]["running"] = False
        first["sessions"].append({"session_id": "forged"})
        second = server.gateway_runtime_snapshot()
    finally:
        with server._sessions_lock:
            server._sessions.clear()
            server._sessions.update(previous)

    assert second["runtime_instance_id"].startswith("gri_")
    assert second["sequence"] == first["sequence"] + 1
    assert second["sessions"] == [{
        "session_id": session_id,
        "stored_session_id": "stored-snapshot",
        "running": True,
        "created_at": 10.0,
        "last_active": 11.0,
        "turn_started_at": 12.0,
        "profile_name": "default",
    }]
    serialized = repr(second)
    assert "must not leak" not in serialized
    assert "transport" not in serialized
    assert "agent" not in serialized
