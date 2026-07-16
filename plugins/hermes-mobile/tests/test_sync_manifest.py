from __future__ import annotations

import importlib.util
import json
import os
import sys
import threading
import time
from pathlib import Path

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
    monkeypatch.setattr(mod, "capture_runtime", lambda: ([], [], set()))
    return mod


def _row(sid: str, *, archived: bool = False, profile: str = "default"):
    return {
        "id": sid, "profile": profile, "title": sid, "preview": "hello",
        "started_at": 1.0, "message_count": 1, "source": "cli",
        "last_active": 2.0, "cwd": "/tmp", "archived": archived,
        "is_active": False,
    }


def _install_universe(monkeypatch, sync, rows):
    universe = list(rows)
    monkeypatch.setattr(
        sync, "_session_rows",
        lambda scope, active: (list(universe), [
            {"session_id": x["id"], "profile": x["profile"], "max_message_id": 1,
             "message_count": 1, "last_message_at": 2.0} for x in universe
        ]),
    )
    return universe


@pytest.mark.parametrize("scope", ["", "profile:", "profile:all", "wat", "profile:%ZZ", "profile:a\x01"])
def test_scope_schema_rejects_malformed_values(sync, scope):
    with pytest.raises(sync.ManifestError) as exc:
        sync.normalize_scope(scope)
    assert (exc.value.status, exc.value.code) == (400, "invalid_scope")


def test_cold_seed_no_change_delta_and_restart_persistence(sync, monkeypatch):
    universe = _install_universe(monkeypatch, sync, [_row("a")])
    first = sync.build_manifest(scope="all", cursor=None, visibility="shared", visibility_check=lambda _: True, device_registered=False)
    assert first["is_full_sync"] and first["complete"]
    assert [x["id"] for x in first["sessions"]["upserts"]] == ["a"]
    assert first["next_cursor"] and first["widget_summary"]["open_session_count"] == 1

    second = sync.build_manifest(scope="all", cursor=first["next_cursor"], visibility="shared", visibility_check=lambda _: True, device_registered=False)
    assert not second["is_full_sync"] and second["sessions"] == {"upserts": [], "tombstones": []}
    assert second["transcript_heads"] == []
    assert second["revision"] == first["revision"]

    # A fresh module/process view reopens the durable SQLite journal.
    assert sync._path().exists()
    assert sync._connect().execute("PRAGMA journal_mode").fetchone()[0].lower() == "wal"
    assert stat_mode(sync._path()) == 0o600

    universe.clear()
    third = sync.build_manifest(scope="all", cursor=second["next_cursor"], visibility="shared", visibility_check=lambda _: True, device_registered=False)
    assert third["revision"] > second["revision"]
    assert third["sessions"]["tombstones"][0]["reason"] == "deleted"


def test_journal_epoch_is_stable_and_binds_cursors(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row("a")])
    seed = sync.build_manifest(
        scope="all", cursor=None, visibility="shared",
        visibility_check=lambda _: True, device_registered=False,
    )
    assert seed["journal_epoch"].startswith("je_")
    again = sync.build_manifest(
        scope="all", cursor=seed["next_cursor"], visibility="shared",
        visibility_check=lambda _: True, device_registered=False,
    )
    assert again["journal_epoch"] == seed["journal_epoch"]

    conn = sync._connect()
    conn.execute(
        "UPDATE meta SET value=? WHERE key='journal_epoch'",
        ("je_" + "Z" * 22,),
    )
    conn.close()
    with pytest.raises(sync.ManifestError) as rebuilt:
        sync.build_manifest(
            scope="all", cursor=seed["next_cursor"], visibility="shared",
            visibility_check=lambda _: True, device_registered=False,
        )
    assert rebuilt.value.code == "journal_rebuilt"
    assert rebuilt.value.reset


def stat_mode(path: Path) -> int:
    return os.stat(path).st_mode & 0o777


def test_archived_and_filtered_tombstones_are_monotonic(sync, monkeypatch):
    universe = _install_universe(monkeypatch, sync, [_row("a"), _row("b")])
    seed = sync.build_manifest(scope="all", cursor=None, visibility="shared", visibility_check=lambda _: True, device_registered=False)
    universe[0]["archived"] = True
    delta = sync.build_manifest(scope="all", cursor=seed["next_cursor"], visibility="shared", visibility_check=lambda _: True, device_registered=False)
    tomb = delta["sessions"]["tombstones"]
    assert tomb == [pytest.approx({"session_id": "a", "profile": "default", "revision": delta["revision"], "deleted_at": tomb[0]["deleted_at"], "reason": "archived"})]
    assert delta["revision"] > seed["revision"]


def test_device_auth_filters_entities_heads_and_counts(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row("mine"), _row("foreign")])
    monkeypatch.setattr(sync, "capture_runtime", lambda: (
        [{"id": "p1", "session_id": "r1", "stored_session_id": "foreign", "profile": "default", "kind": "approval", "safe_title": "Approval required", "detail": {"prompt": None, "description": None, "target": None, "choices": [], "request_id": "p1"}, "destructive": False, "created_at": 1.0, "expires_at": None, "status": "pending"}],
        [{"session_id": "r1", "stored_session_id": "foreign", "profile": "default", "started_at": 1.0, "state": "running"}],
        {("default", "foreign")},
    ))
    out = sync.build_manifest(scope="all", cursor=None, visibility="device:d1", visibility_check=lambda sid: sid == "mine", device_registered=True)
    assert [x["id"] for x in out["sessions"]["upserts"]] == ["mine"]
    assert out["pending_attention"] == [] and out["active_turns"] == []
    assert [x["session_id"] for x in out["transcript_heads"]] == ["mine"]
    assert out["widget_summary"]["open_session_count"] == 1
    assert out["widget_summary"]["pending_attention_count"] == 0
    assert out["push_registry"]["device_registered"] is True


def test_cursor_scope_owner_expiration_and_retention(sync, monkeypatch):
    _install_universe(monkeypatch, sync, [_row("a")])
    seed = sync.build_manifest(scope="all", cursor=None, visibility="device:d1", visibility_check=lambda _: True, device_registered=False)
    with pytest.raises(sync.ManifestError) as mismatch:
        sync.build_manifest(scope="profile:default", cursor=seed["next_cursor"], visibility="device:d1", visibility_check=lambda _: True, device_registered=False)
    assert mismatch.value.code == "cursor_scope_mismatch"
    with pytest.raises(sync.ManifestError) as owner:
        sync.build_manifest(scope="all", cursor=seed["next_cursor"], visibility="device:d2", visibility_check=lambda _: True, device_registered=False)
    assert owner.value.code == "cursor_scope_mismatch"
    conn = sync._connect()
    conn.execute("UPDATE meta SET value=? WHERE key='revision'", (sync.MIN_REVISIONS_RETAINED + 1,))
    conn.execute("UPDATE cursors SET expires_at=? WHERE token=?", (time.time() - 1, seed["next_cursor"]))
    conn.close()
    with pytest.raises(sync.ManifestError) as expired:
        sync.build_manifest(scope="all", cursor=seed["next_cursor"], visibility="device:d1", visibility_check=lambda _: True, device_registered=False)
    assert expired.value.code == "cursor_expired" and expired.value.reset


def test_pagination_replay_is_immutable_during_concurrent_mutation(sync, monkeypatch):
    monkeypatch.setattr(sync, "PAGE_SIZE", 2)
    universe = _install_universe(monkeypatch, sync, [_row(str(i)) for i in range(5)])
    page1 = sync.build_manifest(scope="all", cursor=None, visibility="shared", visibility_check=lambda _: True, device_registered=False)
    universe.append(_row("later"))
    page2a = sync.build_manifest(scope="all", cursor=page1["next_cursor"], visibility="shared", visibility_check=lambda _: True, device_registered=False)
    page2b = sync.build_manifest(scope="all", cursor=page1["next_cursor"], visibility="shared", visibility_check=lambda _: True, device_registered=False)
    assert page2a == page2b
    assert page2a["revision"] == page1["revision"] and all(x["id"] != "later" for x in page2a["sessions"]["upserts"])


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
        attention, active, keys = sync._real_capture_runtime()
        assert attention[0]["kind"] == "clarify"
        assert attention[0]["detail"]["prompt"] == "Choose safely"
        assert active[0]["state"] == "waiting_for_attention"
        assert keys == {("default", "stored-1")}
    finally:
        with server._sessions_lock:
            server._sessions.clear()
            server._sessions.update(old_sessions)
        with server._prompt_lock:
            server._pending.clear()
            server._pending.update(old_pending)
            server._pending_prompt_payloads.clear()
            server._pending_prompt_payloads.update(old_payloads)
