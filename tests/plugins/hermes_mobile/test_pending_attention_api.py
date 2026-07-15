"""ABH-445 pending-attention snapshot/delta REST contract."""

from __future__ import annotations

import json
import threading

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
from tests.plugins.hermes_mobile.conftest import load_plugin_module
from tui_gateway import server as gateway

pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

PREFIX = "/api/plugins/hermes-mobile/attention/pending"
SHARED = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}


def _record(record_id: str, session_id: str, *, expires_at=200.0, kind="approval"):
    return {
        "id": f"{kind}:{record_id}",
        "request_id": record_id,
        "kind": kind,
        "session_id": session_id,
        "stored_session_id": f"stored-{session_id}",
        "safe_title": (
            "Approval required" if kind == "approval" else "Clarification required"
        ),
        "detail": {
            "description": "Review safely" if kind == "approval" else None,
            "question": "Choose safely" if kind == "clarify" else None,
            "choices": ["once", "deny"],
        },
        "destructive": kind == "approval",
        "created_at": 100.0,
        "expires_at": expires_at,
        "status": "pending",
        "revision": 1,
        "command": "RAW_COMMAND_MUST_NOT_LEAK",
        "answer": "RESPONSE_TEXT_MUST_NOT_LEAK",
        "token": "CREDENTIAL_MUST_NOT_LEAK",
    }


@pytest.fixture
def client():
    previous = (
        getattr(web_server.app.state, "bound_host", None),
        getattr(web_server.app.state, "bound_port", None),
        getattr(web_server.app.state, "auth_required", None),
    )
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    with TestClient(web_server.app, base_url="http://127.0.0.1:8080") as value:
        yield value
    (
        web_server.app.state.bound_host,
        web_server.app.state.bound_port,
        web_server.app.state.auth_required,
    ) = previous


@pytest.fixture
def attention(monkeypatch):
    module = load_plugin_module("pending_attention")
    module._reset_for_tests(server_instance_id="instance-a")
    monkeypatch.setattr(module, "MAX_CHANGES", 512)
    yield module
    module._reset_for_tests()


def test_pending_attention_requires_authentication(client):
    response = client.get(PREFIX)
    assert response.status_code == 401


def test_pending_attention_full_snapshot_and_valid_cursor_delta(
    client, attention, monkeypatch
):
    records = [
        _record("a1", "runtime-a"),
        _record("q1", "runtime-q", kind="clarify"),
    ]
    monkeypatch.setattr(attention, "capture_pending_attention", lambda: list(records))

    full = client.get(PREFIX, headers=SHARED).json()
    assert full["server_instance_id"] == "instance-a"
    assert full["reset"] is True
    assert full["reset_reason"] == "initial_snapshot"
    assert {item["kind"] for item in full["upserts"]} == {"approval", "clarify"}
    assert full["tombstones"] == []

    unchanged = client.get(
        PREFIX, params={"cursor": full["cursor"]}, headers=SHARED
    ).json()
    assert unchanged["reset"] is False
    assert unchanged["upserts"] == []
    assert unchanged["tombstones"] == []

    records.append(_record("a2", "runtime-a"))
    delta = client.get(
        PREFIX, params={"cursor": unchanged["cursor"]}, headers=SHARED
    ).json()
    assert [item["request_id"] for item in delta["upserts"]] == ["a2"]
    assert delta["upserts"][0]["revision"] > max(
        item["revision"] for item in full["upserts"]
    )


def test_pending_attention_resolution_and_expiry_emit_tombstones(
    client, attention, monkeypatch
):
    records = [
        _record("resolved", "runtime-a"),
        _record("expired", "runtime-a", expires_at=1.0),
    ]
    monkeypatch.setattr(attention, "capture_pending_attention", lambda: list(records))
    monkeypatch.setattr(attention.time, "time", lambda: 100.0)
    first = client.get(PREFIX, headers=SHARED).json()

    records.clear()
    delta = client.get(
        PREFIX, params={"cursor": first["cursor"]}, headers=SHARED
    ).json()
    statuses = {item["request_id"]: item["status"] for item in delta["tombstones"]}
    assert statuses == {"resolved": "resolved_elsewhere", "expired": "expired"}
    assert all(item["revision"] > 0 for item in delta["tombstones"])


def test_pending_attention_old_and_foreign_cursors_force_full_reset(
    client, attention, monkeypatch
):
    records = [_record("a", "runtime-a")]
    monkeypatch.setattr(attention, "capture_pending_attention", lambda: list(records))
    monkeypatch.setattr(attention, "MAX_CHANGES", 2)
    old = client.get(PREFIX, headers=SHARED).json()["cursor"]
    for suffix in ("b", "c", "d"):
        records[:] = [_record(suffix, "runtime-a")]
        client.get(PREFIX, headers=SHARED)

    reset = client.get(PREFIX, params={"cursor": old}, headers=SHARED).json()
    assert reset["reset"] is True
    assert reset["reset_reason"] == "cursor_too_old"
    assert [item["request_id"] for item in reset["upserts"]] == ["d"]

    foreign_cursor = reset["cursor"]
    attention._reset_for_tests(server_instance_id="instance-b")
    foreign = client.get(PREFIX, params={"cursor": foreign_cursor}, headers=SHARED).json()
    assert foreign["reset"] is True
    assert foreign["reset_reason"] == "foreign_instance"
    assert foreign["server_instance_id"] == "instance-b"


def test_pending_attention_history_is_bounded_under_concurrent_fetches(
    attention, monkeypatch
):
    records = [_record("seed", "runtime-a")]
    monkeypatch.setattr(attention, "capture_pending_attention", lambda: list(records))
    monkeypatch.setattr(attention, "MAX_CHANGES", 4)
    errors = []

    def fetch(index: int):
        try:
            records[:] = [_record(str(index), "runtime-a")]
            attention.build_pending_attention(
                cursor=None,
                visibility="shared",
                visibility_check=lambda _sid: True,
            )
        except Exception as exc:  # pragma: no cover - asserted below
            errors.append(exc)

    threads = [threading.Thread(target=fetch, args=(index,)) for index in range(12)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    assert errors == []
    assert len(attention._states["shared"].changes) <= 4


def test_pending_attention_device_scope_and_redaction(
    client, attention, monkeypatch, tmp_path, wired_token_auth
):
    device_tokens = load_plugin_module("device_tokens")
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    owner = device_tokens.issue(device_name="Owner")
    other = device_tokens.issue(device_name="Other")

    class Transport:
        def __init__(self, ws):
            self._ws = ws

    ws = object()
    transport = Transport(ws)
    device_tokens.register_ws_socket(owner["device_id"], ws)
    gateway._sessions["owned"] = {"session_key": "stored-owned", "transport": transport}
    device_tokens.record_session_transport("owned", transport)
    monkeypatch.setattr(
        attention,
        "capture_pending_attention",
        lambda: [_record("mine", "owned"), _record("theirs", "foreign")],
    )
    try:
        response = client.get(
            PREFIX,
            headers={"X-Hermes-Session-Token": owner["token"]},
        )
        assert response.status_code == 200
        body = response.json()
        assert [item["request_id"] for item in body["upserts"]] == ["mine"]
        serialized = json.dumps(body)
        assert "foreign" not in serialized
        assert "RAW_COMMAND_MUST_NOT_LEAK" not in serialized
        assert "RESPONSE_TEXT_MUST_NOT_LEAK" not in serialized
        assert "CREDENTIAL_MUST_NOT_LEAK" not in serialized

        denied = client.get(
            PREFIX,
            headers={"X-Hermes-Session-Token": other["token"]},
        )
        assert denied.status_code == 200
        assert denied.json()["upserts"] == []
    finally:
        gateway._sessions.pop("owned", None)
        device_tokens._reset_for_tests()
