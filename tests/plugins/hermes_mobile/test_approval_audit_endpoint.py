"""Approval-audit REST surface under /api/plugins/hermes-mobile/.

Moved from ``tests/hermes_cli/test_approval_audit.py`` in the ABH-88 de-patch
(W1): the REST routes moved verbatim to
``plugins/hermes-mobile/dashboard/api.py``, mounted at
``/api/plugins/hermes-mobile/`` by ``web_server._mount_plugin_api_routes()``.
Covered here:

* ``GET  .../approvals/audit``    — read endpoint (auth, filters, clamping)
* ``POST .../approvals/respond``  — audit ATTRIBUTION (shared vs device
  credential) written through the real resolve path. The respond endpoint's
  own semantics (choice mapping, moot approvals, 404s) live in
  ``test_approvals_respond_endpoint.py``.

ABH-88 de-patch (W2c): ``audit_log`` and ``device_tokens`` moved into the
plugin (``plugins/hermes-mobile/``), and the inline audit write in
``resolve_gateway_approval`` became the plugin's ``_audit_resolution``
observer on the ``tools.approval._RESOLVE_OBSERVERS`` seam. Tests that assert
a record is WRITTEN after a REST respond therefore use the
``wired_approval_audit`` fixture; tests that authenticate WITH a device token
use ``wired_token_auth`` (the S5 token-auth seam). The audit_log unit tests
live in ``test_audit_log.py``; the seam contract itself in
``tests/hermes_cli/test_approval_audit.py``.

All in-process via TestClient + a throwaway HERMES_HOME so approval_audit.jsonl
never touches ~/.hermes.
"""

from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from hermes_cli import web_server
import tools.approval as approval
from tui_gateway import server as gateway

from tests.plugins.hermes_mobile.conftest import load_plugin_module

audit_log = load_plugin_module("audit_log")
device_tokens = load_plugin_module("device_tokens")

# Mutates web_server.app.state — share the dashboard app-state xdist group so it
# doesn't race other app-state files (per the repo convention).
pytestmark = pytest.mark.xdist_group("dashboard_auth_app_state")

_PREFIX = "/api/plugins/hermes-mobile"

_SHARED_HEADER = {"X-Hermes-Session-Token": web_server._SESSION_TOKEN}


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    device_tokens._reset_for_tests()
    yield tmp_path
    device_tokens._reset_for_tests()


@pytest.fixture
def client():
    prev_host = getattr(web_server.app.state, "bound_host", None)
    prev_required = getattr(web_server.app.state, "auth_required", None)
    web_server.app.state.bound_host = "127.0.0.1"
    web_server.app.state.bound_port = 8080
    web_server.app.state.auth_required = False
    c = TestClient(web_server.app, base_url="http://127.0.0.1:8080")
    yield c
    web_server.app.state.bound_host = prev_host
    web_server.app.state.auth_required = prev_required


@pytest.fixture
def pending_session():
    """Register a runtime session + enqueue one pending approval entry."""
    sid = "audit-sid-1"
    skey = "audit-key-1"
    gateway._sessions[sid] = {"session_key": skey}
    entry = approval._ApprovalEntry(
        {"command": "rm -rf /tmp/x", "description": "delete temp dir"}
    )
    with approval._lock:
        approval._gateway_queues.setdefault(skey, []).append(entry)
    yield sid, skey
    gateway._sessions.pop(sid, None)
    with approval._lock:
        approval._gateway_queues.pop(skey, None)


class _Transport:
    def __init__(self, ws: object) -> None:
        self._ws = ws


def _own_existing_session(session_id: str, device_id: str) -> None:
    ws = object()
    transport = _Transport(ws)
    device_tokens.register_ws_socket(device_id, ws)
    gateway._sessions[session_id]["transport"] = transport
    device_tokens.record_session_transport(session_id, transport)


# ===========================================================================
# REST respond path → audit attribution: shared vs device
# ===========================================================================


def test_rest_respond_shared_token_writes_shared_credential(
    client, home, pending_session, wired_approval_audit
):
    sid, skey = pending_session
    r = client.post(
        f"{_PREFIX}/approvals/respond",
        json={"session_id": sid, "choice": "approve"},
        headers=_SHARED_HEADER,
    )
    assert r.status_code == 200
    assert r.json()["resolved"] is True
    recs = audit_log.read()
    assert len(recs) == 1
    assert recs[0]["credential"] == "shared"
    assert recs[0]["device_id"] is None
    assert recs[0]["choice"] == "once"
    assert recs[0]["session_id"] == sid
    assert recs[0]["command_preview"] == "delete temp dir"  # prefers description


def test_rest_respond_device_token_writes_device_attribution(
    client, home, pending_session, wired_token_auth, wired_approval_audit
):
    sid, skey = pending_session
    issued = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "Audit Phone"},
        headers=_SHARED_HEADER,
    ).json()
    _own_existing_session(sid, issued["device_id"])
    r = client.post(
        f"{_PREFIX}/approvals/respond",
        json={"session_id": sid, "choice": "approve"},
        headers={"X-Hermes-Session-Token": issued["token"]},
    )
    assert r.status_code == 200
    recs = audit_log.read()
    assert len(recs) == 1
    rec = recs[0]
    assert rec["credential"] == "device"
    assert rec["device_id"] == issued["device_id"]
    assert rec["device_name"] == "Audit Phone"
    assert rec["token_prefix"] == issued["token"][:8]
    assert len(rec["token_prefix"]) == 8


def test_rest_respond_device_token_without_approve_scope_403(
    client, home, pending_session, wired_token_auth, wired_approval_audit
):
    sid, _skey = pending_session
    issued = device_tokens.issue(device_name="Chat Only")
    registry_path = home / "device_tokens.json"
    registry = json.loads(registry_path.read_text())
    registry[issued["device_id"]]["scopes"] = ["chat"]
    registry_path.write_text(json.dumps(registry), encoding="utf-8")

    r = client.post(
        f"{_PREFIX}/approvals/respond",
        json={"session_id": sid, "choice": "approve"},
        headers={"X-Hermes-Session-Token": issued["token"]},
    )

    assert r.status_code == 403
    assert audit_log.read() == []


def test_audit_file_never_contains_a_full_token(
    client, home, pending_session, wired_token_auth, wired_approval_audit
):
    sid, skey = pending_session
    issued = client.post(
        f"{_PREFIX}/devices/issue", json={"device_name": "x"}, headers=_SHARED_HEADER
    ).json()
    _own_existing_session(sid, issued["device_id"])
    client.post(
        f"{_PREFIX}/approvals/respond",
        json={"session_id": sid, "choice": "approve"},
        headers={"X-Hermes-Session-Token": issued["token"]},
    )
    raw = (home / "approval_audit.jsonl").read_text()
    assert issued["token"] not in raw
    assert web_server._SESSION_TOKEN not in raw


# ===========================================================================
# APPROVAL ROUND-TRIP GATE — pending approval registered → REST respond
# approve → resolve_gateway_approval unblocks the waiting entry → the wired
# observer writes one audit record with the resolver's credential fields.
# ===========================================================================


def test_round_trip_pending_approval_to_unblock_to_audit_record(
    client, home, wired_token_auth, wired_approval_audit
):
    sid = "rt-sid-1"
    skey = "rt-key-1"
    gateway._sessions[sid] = {"session_key": skey}
    entry = approval._ApprovalEntry(
        {"command": "rm -rf /tmp/rt", "description": "round trip"}
    )
    with approval._lock:
        approval._gateway_queues.setdefault(skey, []).append(entry)
    try:
        issued = client.post(
            f"{_PREFIX}/devices/issue", json={"device_name": "RT Phone"},
            headers=_SHARED_HEADER,
        ).json()
        _own_existing_session(sid, issued["device_id"])

        r = client.post(
            f"{_PREFIX}/approvals/respond",
            json={"session_id": sid, "choice": "approve"},
            headers={"X-Hermes-Session-Token": issued["token"]},
        )
        assert r.status_code == 200
        assert r.json() == {"resolved": True}

        # The waiting agent thread was unblocked with the normalized decision.
        assert entry.event.is_set()
        assert entry.result == "once"
        assert not approval.has_blocking_approval(skey)

        # One audit record, attributed to the resolving device.
        recs = audit_log.read()
        assert len(recs) == 1
        rec = recs[0]
        assert rec["session_id"] == sid
        assert rec["choice"] == "once"
        assert rec["credential"] == "device"
        assert rec["device_id"] == issued["device_id"]
        assert rec["device_name"] == "RT Phone"
        assert rec["token_prefix"] == issued["token"][:8]
        assert rec["command_preview"] == "round trip"
    finally:
        gateway._sessions.pop(sid, None)
        with approval._lock:
            approval._gateway_queues.pop(skey, None)


# ===========================================================================
# GET /api/plugins/hermes-mobile/approvals/audit read endpoint
# ===========================================================================


def test_audit_endpoint_requires_token(client, home):
    assert client.get(f"{_PREFIX}/approvals/audit").status_code == 401


def test_audit_endpoint_reads_and_filters(client, home):
    audit_log.append(session_id="s-a", choice="once", credential="shared")
    audit_log.append(session_id="s-b", choice="deny", credential="shared")
    all_e = client.get(f"{_PREFIX}/approvals/audit", headers=_SHARED_HEADER).json()
    assert len(all_e["entries"]) == 2
    filtered = client.get(
        f"{_PREFIX}/approvals/audit?session_id=s-a", headers=_SHARED_HEADER
    ).json()
    assert len(filtered["entries"]) == 1
    assert filtered["entries"][0]["session_id"] == "s-a"


def test_audit_endpoint_missing_log_is_empty_not_500(client, home):
    r = client.get(f"{_PREFIX}/approvals/audit", headers=_SHARED_HEADER)
    assert r.status_code == 200
    assert r.json() == {"entries": []}


def test_audit_endpoint_limit_param_clamped(client, home):
    for i in range(5):
        audit_log.append(session_id=f"s{i}", choice="once")
    r = client.get(f"{_PREFIX}/approvals/audit?limit=2", headers=_SHARED_HEADER)
    assert len(r.json()["entries"]) == 2
    # Out-of-range limit clamps, never errors.
    r2 = client.get(f"{_PREFIX}/approvals/audit?limit=999999", headers=_SHARED_HEADER)
    assert r2.status_code == 200
