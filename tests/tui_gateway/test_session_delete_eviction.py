"""Live-session eviction contract for ``session.delete``."""

from __future__ import annotations

from tui_gateway import server


class _DB:
    def __init__(self, deleted=True):
        self.deleted = deleted
        self.calls = []

    def delete_session(self, session_id, sessions_dir=None):
        self.calls.append((session_id, sessions_dir))
        return self.deleted


def test_session_delete_evicts_non_running_live_session(monkeypatch):
    db = _DB()
    torn = []
    session = {"session_key": "stored-1", "running": False}
    server._sessions["runtime-1"] = session
    monkeypatch.setattr(server, "_get_db", lambda: db)
    monkeypatch.setattr(server, "_teardown_session", lambda value: torn.append(value))
    monkeypatch.setattr(server, "_emit", lambda *_args: None)
    try:
        result = server._methods["session.delete"](
            "rpc-1", {"session_id": "stored-1"}
        )
    finally:
        server._sessions.pop("runtime-1", None)

    assert result["result"] == {"deleted": "stored-1", "evicted": True}
    assert "runtime-1" not in server._sessions
    assert torn == [session]
    assert [call[0] for call in db.calls] == ["stored-1"]


def test_session_delete_interrupts_running_live_session(monkeypatch):
    db = _DB()
    calls = []

    class _Agent:
        session_id = "stored-2"

        def interrupt(self):
            calls.append("interrupt")

    session = {"agent": _Agent(), "session_key": "stored-2", "running": True}
    server._sessions["runtime-2"] = session
    monkeypatch.setattr(server, "_get_db", lambda: db)
    monkeypatch.setattr(server, "_clear_pending", lambda sid=None: calls.append(("clear", sid)))
    monkeypatch.setattr(server, "_teardown_session", lambda _value: calls.append("teardown"))
    monkeypatch.setattr(server, "_emit", lambda *_args: None)

    import tools.approval as approval

    monkeypatch.setattr(
        approval,
        "resolve_gateway_approval",
        lambda key, choice, resolve_all=False: calls.append(
            ("approval", key, choice, resolve_all)
        ),
    )
    try:
        result = server._methods["session.delete"](
            "rpc-2", {"session_id": "stored-2"}
        )
    finally:
        server._sessions.pop("runtime-2", None)

    assert result["result"]["evicted"] is True
    assert calls == [
        "interrupt",
        ("clear", "runtime-2"),
        ("approval", "stored-2", "deny", True),
        "teardown",
    ]


def test_session_delete_stored_only_and_eviction_failure(monkeypatch):
    db = _DB()
    monkeypatch.setattr(server, "_get_db", lambda: db)
    monkeypatch.setattr(server, "_emit", lambda *_args: None)
    stored = server._methods["session.delete"](
        "rpc-3", {"session_id": "stored-only"}
    )
    assert stored["result"] == {"deleted": "stored-only", "evicted": False}

    session = {"session_key": "stored-fail", "running": False}
    server._sessions["runtime-fail"] = session
    monkeypatch.setattr(
        server,
        "_teardown_session",
        lambda _value: (_ for _ in ()).throw(RuntimeError("teardown failed")),
    )
    try:
        failed = server._methods["session.delete"](
            "rpc-4", {"session_id": "stored-fail"}
        )
    finally:
        server._sessions.pop("runtime-fail", None)

    assert failed["error"]["code"] == 4023
    assert [call[0] for call in db.calls] == ["stored-only"]
