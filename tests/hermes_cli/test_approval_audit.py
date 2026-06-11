"""STOCK approval-audit surfaces: the ``tools.approval._RESOLVE_OBSERVERS``
seam (S5) on ``resolve_gateway_approval`` and the WS resolve-audit builder
(``tui_gateway.server._ws_resolve_audit``) + the WS approve-scope gate.

ABH-88 de-patch (W2c): ``hermes_cli/audit_log.py`` moved to
``plugins/hermes-mobile/audit_log.py`` and the inline audit write inside
``resolve_gateway_approval`` became a notification to the resolve-observer
seam — the hermes-mobile plugin registers the writer. The audit_log unit
tests and every "a record is actually written" test moved to
``tests/plugins/hermes_mobile/test_audit_log.py`` (wired via the
``wired_approval_audit`` fixture). What stays here tests ONLY stock code:

* the seam contract: with NO observers, resolve still resolves and writes
  nothing; observers receive ``(session_key, choice, resolve_all, audit,
  entries_data)``; a raising observer never breaks a resolution; observers
  fire only when ``audit=`` is provided.
* ``_ws_resolve_audit`` — building the audit context from the WS auth state.
* the WS ``approval.respond`` approve-scope 403.

All with a throwaway HERMES_HOME so nothing ever touches ~/.hermes.
"""

from __future__ import annotations

import pytest

import tools.approval as approval
from tui_gateway import server as gateway


@pytest.fixture
def home(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    yield tmp_path


@pytest.fixture
def clean_observers():
    """Run with an EMPTY resolve-observer list; restore whatever was wired."""
    before = list(approval._RESOLVE_OBSERVERS)
    approval._RESOLVE_OBSERVERS[:] = []
    yield approval._RESOLVE_OBSERVERS
    approval._RESOLVE_OBSERVERS[:] = before


def _enqueue(skey: str, data: dict) -> approval._ApprovalEntry:
    entry = approval._ApprovalEntry(data)
    with approval._lock:
        approval._gateway_queues.setdefault(skey, []).append(entry)
    return entry


def _drop_queue(skey: str) -> None:
    with approval._lock:
        approval._gateway_queues.pop(skey, None)


# ===========================================================================
# Seam S5 — tools.approval._RESOLVE_OBSERVERS
# ===========================================================================


def test_resolve_with_audit_and_no_observers_resolves_and_writes_nothing(
    home, clean_observers
):
    """Stock behaviour: audit= without any wired observer is inert."""
    skey = "seam-1"
    entry = _enqueue(skey, {"description": "do a thing"})
    try:
        n = approval.resolve_gateway_approval(
            skey, "once", audit={"credential": "shared", "session_id": "sid"},
        )
        assert n == 1
        assert entry.result == "once"
        assert entry.event.is_set()
        # No observer → nothing on disk, anywhere under HERMES_HOME.
        assert not (home / "approval_audit.jsonl").exists()
        assert list(home.rglob("approval_audit.jsonl")) == []
    finally:
        _drop_queue(skey)


def test_observer_receives_resolution_context(home, clean_observers):
    skey = "seam-2"
    data = {"command": "rm -rf /tmp/x", "description": "delete temp dir"}
    entry = _enqueue(skey, data)
    audit = {
        "credential": "device", "device_id": "dev_9", "device_name": "Phone",
        "token_prefix": "pfx12345", "session_id": "sid-9", "session_key": skey,
    }
    calls = []
    approval._RESOLVE_OBSERVERS.append(
        lambda *args: calls.append(args)
    )
    try:
        n = approval.resolve_gateway_approval(skey, "once", audit=audit)
        assert n == 1
        assert entry.event.is_set()  # observer fires AFTER the unblock
        assert calls == [(skey, "once", False, audit, [data])]
    finally:
        _drop_queue(skey)


def test_observer_not_notified_without_audit(home, clean_observers):
    skey = "seam-3"
    _enqueue(skey, {"description": "x"})
    calls = []
    approval._RESOLVE_OBSERVERS.append(lambda *args: calls.append(args))
    try:
        assert approval.resolve_gateway_approval(skey, "deny") == 1  # no audit=
        assert calls == []
    finally:
        _drop_queue(skey)


def test_raising_observer_never_breaks_resolution(home, clean_observers):
    skey = "seam-4"
    entry = _enqueue(skey, {"description": "boom"})

    def _bad(*args):
        raise RuntimeError("observer exploded")

    calls = []
    approval._RESOLVE_OBSERVERS.append(_bad)
    approval._RESOLVE_OBSERVERS.append(lambda *args: calls.append(args))
    try:
        n = approval.resolve_gateway_approval(
            skey, "once", audit={"credential": "shared"},
        )
        assert n == 1
        assert entry.result == "once"
        assert entry.event.is_set()
        # The observer AFTER the raiser still ran.
        assert len(calls) == 1
    finally:
        _drop_queue(skey)


def test_resolve_all_forwards_every_entry_data(home, clean_observers):
    skey = "seam-5"
    e1 = _enqueue(skey, {"description": "first"})
    e2 = _enqueue(skey, {"description": "second"})
    calls = []
    approval._RESOLVE_OBSERVERS.append(lambda *args: calls.append(args))
    try:
        n = approval.resolve_gateway_approval(
            skey, "once", resolve_all=True, audit={"credential": "shared"},
        )
        assert n == 2
        assert e1.event.is_set() and e2.event.is_set()
        assert len(calls) == 1
        _skey, _choice, resolve_all, _audit, entries_data = calls[0]
        assert resolve_all is True
        assert entries_data == [{"description": "first"}, {"description": "second"}]
    finally:
        _drop_queue(skey)


# ===========================================================================
# WS resolve audit builder (internal vs device vs shared)
# ===========================================================================


def test_ws_resolve_audit_internal_when_no_ws(home):
    # No transport bound → stdio child → credential=internal.
    out = gateway._ws_resolve_audit("sid", "skey")
    assert out["credential"] == "internal"
    assert out["device_id"] is None


def test_ws_resolve_audit_device_from_ws_state(home):
    from types import SimpleNamespace
    from tui_gateway.transport import bind_transport, reset_transport

    fake_ws = SimpleNamespace(
        state=SimpleNamespace(
            device={
                "device_id": "dev_x", "device_name": "P",
                "token_prefix": "pfx12345",
            }
        )
    )
    transport = SimpleNamespace(_ws=fake_ws)
    tok = bind_transport(transport)
    try:
        out = gateway._ws_resolve_audit("sid", "skey")
    finally:
        reset_transport(tok)
    assert out["credential"] == "device"
    assert out["device_id"] == "dev_x"
    assert out["device_name"] == "P"
    assert out["token_prefix"] == "pfx12345"


def test_ws_approval_respond_device_without_approve_scope_403(home):
    from types import SimpleNamespace
    from tui_gateway.transport import bind_transport, reset_transport

    sid = "ws-scope-sid"
    skey = "ws-scope-key"
    gateway._sessions[sid] = {"session_key": skey}
    fake_ws = SimpleNamespace(
        state=SimpleNamespace(
            device={
                "device_id": "dev_chat",
                "device_name": "Phone",
                "token_prefix": "abc12345",
                "scopes": ["chat"],
            }
        )
    )
    transport = SimpleNamespace(_ws=fake_ws)
    tok = bind_transport(transport)
    try:
        out = gateway._methods["approval.respond"](
            "rid-1", {"session_id": sid, "choice": "approve"}
        )
    finally:
        reset_transport(tok)
        gateway._sessions.pop(sid, None)

    assert out["error"]["code"] == 4030
    assert out["error"]["message"] == "device token lacks approve scope"
