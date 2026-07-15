"""/approvals/reply audits the real clarify-resolution path."""

from __future__ import annotations

import threading
import sys

import pytest

from tests.plugins.hermes_mobile.conftest import load_plugin_module

_API_MODULE_NAME = "hermes_dashboard_plugin_hermes-mobile"


@pytest.fixture
def api_module(monkeypatch, tmp_path):
    """Mounted plugin API module with hermetic HERMES_HOME."""
    hermes_home = tmp_path / ".hermes"
    hermes_home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(hermes_home))

    from hermes_cli import web_server

    if _API_MODULE_NAME not in sys.modules:
        web_server._get_dashboard_plugins(force_rescan=True)
        web_server._mount_plugin_api_routes()
    return sys.modules[_API_MODULE_NAME]


@pytest.fixture
def client(api_module):
    try:
        from starlette.testclient import TestClient
    except ImportError:
        pytest.skip("fastapi/starlette not installed")

    from hermes_cli.web_server import app, _SESSION_HEADER_NAME, _SESSION_TOKEN

    c = TestClient(app)
    c.headers[_SESSION_HEADER_NAME] = _SESSION_TOKEN
    return c


def _install_pending_clarify(server, session_id, session_key, request_id, event):
    server._sessions[session_id] = {"session_key": session_key}
    with server._prompt_lock:
        server._pending[request_id] = (session_id, event)
        server._pending_prompt_payloads[request_id] = (
            "clarify.request",
            {"request_id": request_id, "question": "Which target?"},
        )


def _cleanup_pending_clarify(server, session_id, request_id):
    server._sessions.pop(session_id, None)
    with server._prompt_lock:
        server._pending.pop(request_id, None)
        server._pending_prompt_payloads.pop(request_id, None)
        server._answers.pop(request_id, None)


def test_reply_to_clarify_approval_writes_audit_record_without_command_queue(
    client, api_module
):
    from tui_gateway import server

    audit_log = load_plugin_module("audit_log")

    session_id = "runtime-clarify-audit"
    session_key = "stored-clarify-audit"
    request_id = "clarifyabc123"
    answer = "Use the safe option"
    event = threading.Event()

    try:
        _install_pending_clarify(server, session_id, session_key, request_id, event)

        resp = client.post(
            "/api/plugins/hermes-mobile/approvals/reply",
            json={
                "session_id": session_id,
                "approval_id": request_id,
                "answer": answer,
            },
        )

        assert resp.status_code == 200, resp.text
        assert resp.json() == {"resolved": True}
        assert event.is_set()
        assert server._answers[request_id] == answer

        records = audit_log.read(session_id=session_id)
        assert len(records) == 1
        assert records[0]["session_id"] == session_id
        assert records[0]["session_key"] == session_key
        assert records[0]["choice"] == "once"
        assert records[0]["resolve_all"] is False
        assert records[0]["credential"] == "shared"
        assert records[0]["device_id"] is None
        assert records[0]["command_preview"] == "Which target?"
    finally:
        _cleanup_pending_clarify(server, session_id, request_id)


def test_reply_to_clarify_approval_leaves_command_approval_queue_untouched(
    client, api_module
):
    from tools import approval
    from tui_gateway import server

    load_plugin_module("audit_log")

    session_id = "runtime-clarify-with-command"
    session_key = "stored-clarify-with-command"
    request_id = "clarifywithcommand123"
    answer = "Use staging"
    event = threading.Event()
    entry = approval._ApprovalEntry({"description": "Run production deploy"})

    try:
        _install_pending_clarify(server, session_id, session_key, request_id, event)
        with approval._lock:
            approval._gateway_queues[session_key] = [entry]

        resp = client.post(
            "/api/plugins/hermes-mobile/approvals/reply",
            json={
                "session_id": session_id,
                "approval_id": request_id,
                "answer": answer,
            },
        )

        assert resp.status_code == 200, resp.text
        assert resp.json() == {"resolved": True}
        assert event.is_set()
        assert server._answers[request_id] == answer
        with approval._lock:
            assert approval._gateway_queues[session_key] == [entry]
        assert entry.result is None
        assert not entry.event.is_set()
    finally:
        with approval._lock:
            approval._gateway_queues.pop(session_key, None)
        _cleanup_pending_clarify(server, session_id, request_id)
