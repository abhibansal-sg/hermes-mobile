from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
import time
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture
def sync(monkeypatch, tmp_path):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path))
    name = f"sync_manifest_test_{id(tmp_path)}"
    spec = importlib.util.spec_from_file_location(name, Path(__file__).parents[1] / "sync_manifest.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    assert spec.loader
    spec.loader.exec_module(mod)
    mod._real_capture_runtime = mod.capture_runtime
    authority = SimpleNamespace(
        profile_id="pf_AAAAAAAAAAAAAAAAAAAAAA",
        profile_name="default",
        authority_epoch="ae_BBBBBBBBBBBBBBBBBBBBBB",
    )
    context = SimpleNamespace(
        gateway_id="gw_CCCCCCCCCCCCCCCCCCCCCC",
        profiles=(authority,),
    )
    monkeypatch.setattr(mod, "_resolve_authority_scope", lambda scope: (context, ((authority, tmp_path),)))
    monkeypatch.setattr(
        mod,
        "capture_runtime",
        lambda: (
            [], [], set(),
            {"runtime_instance_id": "gri_test", "sequence": 1, "captured_at": 1.0},
        ),
    )
    return mod


def _row(sid: str, *, archived: bool = False, profile: str = "default"):
    return {
        "id": sid, "profile": profile, "title": sid, "preview": "hello",
        "started_at": 1.0, "message_count": 1, "source": "cli",
        "last_active": 2.0, "cwd": "/tmp", "archived": archived,
        "profile_id": "pf_AAAAAAAAAAAAAAAAAAAAAA",
        "authority_epoch": "ae_BBBBBBBBBBBBBBBBBBBBBB",
        "is_active": False,
    }


def _install_universe(monkeypatch, sync, rows):
    universe = list(rows)
    monkeypatch.setattr(
        sync, "_session_rows",
        lambda homes, active: (list(universe), [
            {"session_id": x["id"], "profile": x["profile"],
             "profile_id": x["profile_id"], "authority_epoch": x["authority_epoch"], "max_message_id": 1,
             "message_count": 1, "last_message_at": 2.0} for x in universe
        ]),
    )
    return universe


def _build(sync, *, resume=None, continuation=None, limit=500, scope="all", visibility="shared", owns=lambda _profile, _session: True, registered=False):
    return sync.build_manifest(
        scope=scope,
        resume_cursor=resume,
        continuation_cursor=continuation,
        limit=limit,
        visibility=visibility,
        visibility_check=owns,
        device_registered=registered,
    )


@pytest.mark.parametrize("scope", ["", "profile:", "profile:all", "wat", "profile:%ZZ", "profile:a\x01"])
def test_scope_schema_rejects_malformed_values(sync, scope):
    with pytest.raises(sync.ManifestError) as exc:
        sync.normalize_scope(scope)
    assert (exc.value.status, exc.value.code) == (400, "invalid_scope")


def test_cold_seed_no_change_delta_and_restart_persistence(sync, monkeypatch):
    universe = _install_universe(monkeypatch, sync, [_row("a")])
    first = _build(sync)
    assert first["reset"] and first["complete"]
    assert [x["id"] for x in first["sessions"]["upserts"]] == ["a"]
    assert first["resume_cursor"] and first["widget_summary"]["open_session_count"] == 1

    second = _build(sync, resume=first["resume_cursor"])
    assert not second["reset"] and second["sessions"] == {"upserts": [], "tombstones": []}
    assert second["transcript_heads"] == []
    assert second["revision"] == first["revision"]

    # A fresh module/process view reopens the durable SQLite journal.
    assert sync._path().exists()
    assert sync._connect().execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    assert stat_mode(sync._path()) == 0o600

    universe.clear()
    third = _build(sync, resume=second["resume_cursor"])
    assert third["revision"] > second["revision"]
    assert third["sessions"]["tombstones"][0]["reason"] == "deleted"


def test_journal_epoch_is_stable_and_binds_cursors(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row("a")])
    seed = _build(sync)
    assert seed["journal_epoch"].startswith("je_")
    again = _build(sync, resume=seed["resume_cursor"])
    assert again["journal_epoch"] == seed["journal_epoch"]

    conn = sync._connect()
    conn.execute(
        "UPDATE meta SET value=? WHERE key='journal_epoch'",
        ("je_" + "Z" * 22,),
    )
    conn.close()
    with pytest.raises(sync.ManifestError) as rebuilt:
        _build(sync, resume=seed["resume_cursor"])
    assert rebuilt.value.code == "journal_rebuilt"
    assert rebuilt.value.reset


def stat_mode(path: Path) -> int:
    return os.stat(path).st_mode & 0o777


def test_archived_and_filtered_tombstones_are_monotonic(sync, monkeypatch):
    universe = _install_universe(monkeypatch, sync, [_row("a"), _row("b")])
    seed = _build(sync)
    universe[0]["archived"] = True
    delta = _build(sync, resume=seed["resume_cursor"])
    tomb = delta["sessions"]["tombstones"]
    assert tomb == [pytest.approx({
        "session_id": "a",
        "profile": "default",
        "profile_id": "pf_AAAAAAAAAAAAAAAAAAAAAA",
        "authority_epoch": "ae_BBBBBBBBBBBBBBBBBBBBBB",
        "entity_revision": delta["revision"],
        "deleted_at": tomb[0]["deleted_at"],
        "reason": "archived",
    })]
    assert delta["revision"] > seed["revision"]


def test_device_auth_filters_entities_heads_and_counts(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row("mine"), _row("foreign")])
    monkeypatch.setattr(sync, "capture_runtime", lambda: (
        [{"id": "p1", "session_id": "r1", "stored_session_id": "foreign", "profile": "default", "kind": "approval", "safe_title": "Approval required", "detail": {"prompt": None, "description": None, "target": None, "choices": [], "request_id": "p1"}, "destructive": False, "created_at": 1.0, "expires_at": None, "status": "pending"}],
        [{"session_id": "r1", "stored_session_id": "foreign", "profile": "default", "started_at": 1.0, "state": "running"}],
        {("default", "foreign")},
        {"runtime_instance_id": "gri_test", "sequence": 2, "captured_at": 2.0},
    ))
    out = _build(
        sync,
        visibility="device:d1",
        owns=lambda _profile, sid: sid == "mine",
        registered=True,
    )
    assert [x["id"] for x in out["sessions"]["upserts"]] == ["mine"]
    assert out["pending_attention"] == []
    assert out["runtime_snapshot"]["active_turns"] == []
    assert [x["session_id"] for x in out["transcript_heads"]] == ["mine"]
    assert out["widget_summary"]["open_session_count"] == 1
    assert out["widget_summary"]["pending_attention_count"] == 0
    assert out["push_registry"]["device_registered"] is True


def test_cursor_scope_owner_expiration_and_retention(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row("a")])
    seed = _build(sync, visibility="device:d1")
    with pytest.raises(sync.ManifestError) as mismatch:
        _build(sync, scope="profile:pf_AAAAAAAAAAAAAAAAAAAAAA", resume=seed["resume_cursor"], visibility="device:d1")
    assert mismatch.value.code == "cursor_scope_mismatch"
    with pytest.raises(sync.ManifestError) as owner:
        _build(sync, resume=seed["resume_cursor"], visibility="device:d2")
    assert owner.value.code == "cursor_scope_mismatch"
    conn = sync._connect()
    conn.execute("UPDATE meta SET value=? WHERE key='revision'", (sync.MIN_REVISIONS_RETAINED + 1,))
    conn.execute("UPDATE cursors SET expires_at=? WHERE token=?", (time.time() - 1, seed["resume_cursor"]))
    conn.close()
    with pytest.raises(sync.ManifestError) as expired:
        _build(sync, resume=seed["resume_cursor"], visibility="device:d1")
    assert expired.value.code == "cursor_expired" and expired.value.reset


def test_pagination_replay_is_immutable_during_concurrent_mutation(sync, monkeypatch):
    universe = _install_universe(monkeypatch, sync, [_row(str(i)) for i in range(5)])
    page1 = _build(sync, limit=2)
    universe.append(_row("later"))
    page2a = _build(sync, continuation=page1["continuation_cursor"], limit=2)
    page2b = _build(sync, continuation=page1["continuation_cursor"], limit=2)
    assert page2a == page2b
    assert page2a["revision"] == page1["revision"] and all(x["id"] != "later" for x in page2a["sessions"]["upserts"])


def test_cursor_kind_and_page_contract_are_not_interchangeable(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row(str(i)) for i in range(3)])
    first = _build(sync, limit=1)

    with pytest.raises(sync.ManifestError) as wrong_kind:
        _build(sync, resume=first["continuation_cursor"], limit=1)
    assert wrong_kind.value.code == "cursor_kind_mismatch"

    with pytest.raises(sync.ManifestError) as changed_limit:
        _build(sync, continuation=first["continuation_cursor"], limit=2)
    assert changed_limit.value.code == "cursor_contract_mismatch"


def test_continuation_pages_omit_final_only_state(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row(str(i)) for i in range(3)])
    first = _build(sync, limit=1)
    assert first["complete"] is False
    assert first["resume_cursor"] is None
    for key in (
        "pending_attention", "runtime_snapshot", "transcript_heads",
        "widget_summary", "push_registry",
    ):
        assert key not in first

    second = _build(sync, continuation=first["continuation_cursor"], limit=1)
    final = _build(sync, continuation=second["continuation_cursor"], limit=1)
    assert final["complete"] is True
    assert final["continuation_cursor"] is None
    assert final["resume_cursor"].startswith(f"m2.{final['journal_epoch']}.")
    for key in (
        "pending_attention", "runtime_snapshot", "transcript_heads",
        "widget_summary", "push_registry",
    ):
        assert key in final


def test_usage_null_and_device_registration_binding(sync):
    assert sync.device_is_registered("d1", [{"device_id": "d1"}])
    assert not sync.device_is_registered("d1", [{"token": "legacy"}])
    assert not sync.device_is_registered(None, [{"device_id": "d1"}])


def test_pending_prompt_and_active_turn_capture_uses_gateway_state(sync):
    from tui_gateway import server

    event = threading.Event()
    with server._sessions_lock:
        old_sessions = dict(server._sessions)
        server._sessions.clear()
        server._sessions["runtime-1"] = {
            "session_key": "stored-1", "running": True,
            "created_at": 10.0, "profile_home": None,
        }
    with server._prompt_lock:
        old_pending = dict(server._pending)
        old_payloads = dict(server._pending_prompt_payloads)
        server._pending.clear()
        server._pending_prompt_payloads.clear()
        server._pending["req-1"] = ("runtime-1", event)
        server._pending_prompt_payloads["req-1"] = (
            "clarify.request", {"question": "Choose safely", "choices": ["A"]},
        )
    try:
        attention, active, keys, runtime = sync._real_capture_runtime()
        assert attention[0]["kind"] == "clarify"
        assert attention[0]["detail"]["prompt"] == "Choose safely"
        assert active[0]["state"] == "waiting_for_attention"
        assert keys == {("default", "stored-1")}
        assert runtime["runtime_instance_id"].startswith("gri_")
    finally:
        with server._sessions_lock:
            server._sessions.clear()
            server._sessions.update(old_sessions)
        with server._prompt_lock:
            server._pending.clear()
            server._pending.update(old_pending)
            server._pending_prompt_payloads.clear()
            server._pending_prompt_payloads.update(old_payloads)
