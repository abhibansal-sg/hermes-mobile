"""W3A-S — approval audit log: append-only 0600 JSONL writer/reader, plus the
audit records written through ``resolve_gateway_approval(audit=...)`` and the
WS ``approval.respond`` path.

Moved from ``tests/hermes_cli/test_approval_audit.py`` in the ABH-88 de-patch
(W2c): ``hermes_cli/audit_log.py`` moved verbatim to
``plugins/hermes-mobile/audit_log.py``, and the inline audit write inside
``tools.approval.resolve_gateway_approval`` became a plugin observer on the
``tools.approval._RESOLVE_OBSERVERS`` seam (wired by
``hermes_plugins.hermes_mobile._wire_approval_audit``). Tests that assert
records are actually WRITTEN therefore use the ``wired_approval_audit``
fixture — without it the resolve still succeeds but writes nothing (that
seam contract is covered in ``tests/hermes_cli/test_approval_audit.py``).

All with a throwaway HERMES_HOME so approval_audit.jsonl never touches
~/.hermes.
"""

from __future__ import annotations

import os
import stat

import pytest

import tools.approval as approval
from tui_gateway import server as gateway

from tests.plugins.hermes_mobile.conftest import load_plugin_module

audit_log = load_plugin_module("audit_log")


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    yield tmp_path


# ===========================================================================
# audit_log unit
# ===========================================================================


def test_append_creates_0600_file_and_read_round_trip(home):
    assert audit_log.append(
        session_id="s1", session_key="k1", choice="once",
        credential="shared", command_preview="ls -la",
    )
    path = home / "approval_audit.jsonl"
    assert path.exists()
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    recs = audit_log.read()
    assert len(recs) == 1
    r = recs[0]
    assert r["session_id"] == "s1"
    assert r["choice"] == "once"
    assert r["credential"] == "shared"
    assert r["device_id"] is None
    assert r["command_preview"] == "ls -la"
    assert "ts" in r


def test_append_creates_file_with_0600_mode_argument(home, monkeypatch):
    calls = []
    real_open = os.open

    def spy(path, flags, mode=0o777, *args, **kwargs):
        calls.append((path, flags, mode))
        return real_open(path, flags, mode, *args, **kwargs)

    monkeypatch.setattr(audit_log.os, "open", spy)

    assert audit_log.append(session_id="s1", choice="once")

    assert calls
    assert calls[0][0] == home / "approval_audit.jsonl"
    assert calls[0][2] == 0o600


def test_append_is_append_only_most_recent_first(home):
    for i in range(3):
        audit_log.append(session_id=f"s{i}", choice="once")
    raw = (home / "approval_audit.jsonl").read_text()
    assert raw.count("\n") == 3  # one line per record, grows
    recs = audit_log.read()
    # Most-recent first.
    assert [r["session_id"] for r in recs] == ["s2", "s1", "s0"]


def test_audit_log_prunes_oldest_records_to_byte_cap(home, monkeypatch):
    monkeypatch.setattr(audit_log, "_MAX_LOG_BYTES", 1200)

    for i in range(30):
        audit_log.append(session_id=f"s{i}", choice="once")

    path = home / "approval_audit.jsonl"
    assert path.stat().st_size <= 1200
    recs = audit_log.read(limit=500)
    assert recs[0]["session_id"] == "s29"
    assert "s0" not in {r["session_id"] for r in recs}


def test_read_limit_clamped_and_session_filter(home):
    for i in range(10):
        audit_log.append(session_id="a" if i % 2 == 0 else "b", choice="once")
    assert len(audit_log.read(limit=3)) == 3
    assert len(audit_log.read(limit=99999)) == 10  # clamp ≤500, only 10 exist
    only_a = audit_log.read(session_id="a")
    assert all(r["session_id"] == "a" for r in only_a)
    assert len(only_a) == 5


def test_read_missing_or_corrupt_file_is_empty(home):
    assert audit_log.read() == []
    (home / "approval_audit.jsonl").write_text("not json\n{bad\n")
    assert audit_log.read() == []


def test_token_prefix_is_truncated_never_full(home):
    audit_log.append(
        choice="once", credential="device",
        device_id="dev_1", token_prefix="abcdefghIJKLMNOP",  # 16 chars
    )
    r = audit_log.read()[0]
    assert r["token_prefix"] == "abcdefgh"  # 8 chars only
    assert len(r["token_prefix"]) == 8


def test_command_preview_prefers_description_and_truncates(home):
    long = "x" * 500
    assert audit_log._build_command_preview(
        {"command": long, "description": "short desc"}
    ) == "short desc"
    only_cmd = audit_log._build_command_preview({"command": long})
    assert len(only_cmd) == 120


# ===========================================================================
# resolve_gateway_approval(audit=...) + the WIRED plugin observer writes one
# record per resolved entry
# ===========================================================================


def test_resolve_with_audit_writes_record(home, wired_approval_audit):
    skey = "rk-1"
    entry = approval._ApprovalEntry({"description": "do a thing"})
    with approval._lock:
        approval._gateway_queues.setdefault(skey, []).append(entry)
    try:
        n = approval.resolve_gateway_approval(
            skey, "once", audit={
                "credential": "device", "device_id": "dev_9",
                "device_name": "Phone", "token_prefix": "pfx12345",
                "session_id": "sid-9", "session_key": skey,
            },
        )
        assert n == 1
        r = audit_log.read()[0]
        assert r["credential"] == "device"
        assert r["device_id"] == "dev_9"
        assert r["device_name"] == "Phone"
        assert r["token_prefix"] == "pfx12345"
        assert r["command_preview"] == "do a thing"
    finally:
        with approval._lock:
            approval._gateway_queues.pop(skey, None)


def test_resolve_without_audit_writes_nothing(home, wired_approval_audit):
    # Even WITH the observer wired, no audit= context → no record.
    skey = "rk-2"
    entry = approval._ApprovalEntry({"description": "x"})
    with approval._lock:
        approval._gateway_queues.setdefault(skey, []).append(entry)
    try:
        approval.resolve_gateway_approval(skey, "deny")  # no audit=
        assert audit_log.read() == []
    finally:
        with approval._lock:
            approval._gateway_queues.pop(skey, None)


# ===========================================================================
# WS approval.respond end-to-end → audit record (stock WS path + wired plugin
# observer). The _ws_resolve_audit BUILDER itself is stock and stays covered
# in tests/hermes_cli/test_approval_audit.py.
# ===========================================================================


def test_ws_approval_respond_normalizes_approve_to_once(
    home, wired_approval_audit
):
    sid = "ws-normalize-sid"
    skey = "ws-normalize-key"
    gateway._sessions[sid] = {"session_key": skey}
    entry = approval._ApprovalEntry({"description": "ws approve"})
    with approval._lock:
        approval._gateway_queues.setdefault(skey, []).append(entry)
    try:
        out = gateway._methods["approval.respond"](
            "rid-2", {"session_id": sid, "choice": "approve"}
        )
        assert out["result"]["resolved"] == 1
        rec = audit_log.read()[0]
        assert rec["choice"] == "once"
        assert rec["command_preview"] == "ws approve"
    finally:
        gateway._sessions.pop(sid, None)
        with approval._lock:
            approval._gateway_queues.pop(skey, None)
