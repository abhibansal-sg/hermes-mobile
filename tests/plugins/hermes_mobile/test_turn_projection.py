from __future__ import annotations

import sqlite3

import pytest

from hermes_state import SessionDB
from tests.plugins.hermes_mobile.conftest import load_plugin_module


projection = load_plugin_module("turn_projection")


def _completed_turn(
    db: SessionDB,
    session_id: str,
    turn_id: str,
    *,
    accepted_at: float,
    client_message_id: str,
) -> int:
    db.start_turn(
        session_id,
        turn_id,
        content=f"prompt {turn_id}",
        client_message_id=client_message_id,
        accepted_at=accepted_at,
    )
    user_origin = db.append_message(session_id, "user", f"prompt {turn_id}")
    db.bind_turn_input_origin(
        session_id,
        turn_id,
        client_message_id,
        user_origin,
    )
    final_origin = db.append_message(
        session_id,
        "assistant",
        f"answer {turn_id}",
        timestamp=accepted_at + 2,
    )
    db.finish_turn(
        session_id,
        turn_id,
        state="completed",
        terminal_at=accepted_at + 2,
        terminal_message_origin_id=final_origin,
    )
    return final_origin


def test_new_authoritative_session_projects_complete_turn_without_raw_detail(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s1", source="tui")
    _completed_turn(db, "s1", "turn_1", accepted_at=10, client_message_id="cm_1")

    page = projection.build_turn_page(db, session_id="s1", limit=30)

    assert page["coverage_complete"] is True
    assert page["projection_pending"] is False
    assert len(page["turns"]) == 1
    turn = page["turns"][0]
    assert turn["turn_id"] == "turn_1"
    assert turn["client_message_id"] == "cm_1"
    assert turn["final"]["content"] == "answer turn_1"
    assert turn["timing_quality"] == "exact"
    assert turn["elapsed_ms"] == 2000
    assert "reasoning" not in turn
    assert turn["activity_groups"] == []


def test_existing_history_stays_honestly_partial(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("legacy", source="tui")
    db.append_message("legacy", "user", "old prompt")
    _completed_turn(
        db,
        "legacy",
        "turn_new",
        accepted_at=20,
        client_message_id="cm_new",
    )

    page = projection.build_turn_page(db, session_id="legacy")

    assert page["coverage_complete"] is False
    assert page["projection_pending"] is True
    assert [turn["turn_id"] for turn in page["turns"]] == ["turn_new"]


def test_turn_cursor_pages_equal_timestamps_without_skip_and_rejects_stale_head(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s1", source="tui")
    for index in range(4):
        _completed_turn(
            db,
            "s1",
            f"turn_{index}",
            accepted_at=10,
            client_message_id=f"cm_{index}",
        )

    newest = projection.build_turn_page(db, session_id="s1", limit=2)
    older = projection.build_turn_page(
        db,
        session_id="s1",
        before=newest["previous_cursor"],
        limit=2,
    )
    ids = [turn["turn_id"] for turn in newest["turns"] + older["turns"]]
    assert len(ids) == len(set(ids)) == 4

    db.append_message("s1", "assistant", "new display head")
    with pytest.raises(projection.TurnProjectionError, match="display revision changed"):
        projection.build_turn_page(
            db,
            session_id="s1",
            before=newest["previous_cursor"],
            limit=2,
        )


def test_terminal_tool_call_row_is_not_misrepresented_as_final(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s1", source="tui")
    db.start_turn("s1", "turn_1", content="go", accepted_at=1)
    origin = db.append_message(
        "s1",
        "assistant",
        "intermediate plan",
        tool_calls=[{"id": "call_1", "function": {"name": "terminal"}}],
    )
    db.finish_turn(
        "s1",
        "turn_1",
        state="interrupted",
        terminal_message_origin_id=origin,
    )

    turn = projection.build_turn_page(db, session_id="s1")["turns"][0]
    assert turn["final"] is None


def test_rewind_emits_revisioned_turn_tombstone(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s1", source="tui")
    _completed_turn(db, "s1", "turn_1", accepted_at=1, client_message_id="cm_1")
    _completed_turn(db, "s1", "turn_2", accepted_at=2, client_message_id="cm_2")

    user_origin = db.get_turn_inputs("s1", "turn_2")[0]["message_origin_id"]
    target_message = db.get_display_message_by_origin("s1", user_origin)
    db.rewind_to_message("s1", target_message["id"])
    page = projection.build_turn_page(db, session_id="s1", after_revision=0)

    assert [item["turn_id"] for item in page["tombstones"]] == ["turn_2"]
    assert page["tombstones"][0]["server_revision"] == page["source_head_id"]


def test_adjacent_safe_operations_group_without_persisting_payloads(tmp_path):
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("s1", source="tui")
    db.start_turn("s1", "turn_1", content="work", accepted_at=1)
    for operation_id, category, label in (
        ("a", "files", "Inspected files"),
        ("b", "files", "Inspected files"),
        ("c", "shell", "Ran terminal operations"),
    ):
        db.start_turn_operation(
            "s1",
            "turn_1",
            operation_id,
            tool_name="opaque-tool-name",
            category=category,
            safe_label=label,
        )
        db.finish_turn_operation(
            "s1", "turn_1", operation_id, state="completed"
        )
    db.finish_turn("s1", "turn_1", state="completed")

    groups = projection.build_turn_page(db, session_id="s1")["turns"][0][
        "activity_groups"
    ]
    assert [(item["category"], item["operation_count"]) for item in groups] == [
        ("files", 2),
        ("shell", 1),
    ]
    assert all("args" not in item and "result" not in item for item in groups)


def test_historical_backfill_is_bounded_restartable_and_safe(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("legacy", source="tui")
    db.append_message("legacy", "user", "inspect the project", timestamp=1)
    for index in range(4):
        call_id = f"call_{index}"
        db.append_message(
            "legacy",
            "assistant",
            None,
            tool_calls=[
                {
                    "id": call_id,
                    "function": {
                        "name": "terminal",
                        "arguments": '{"command":"secret command"}',
                    },
                }
            ],
            timestamp=2 + index * 2,
        )
        db.append_message(
            "legacy",
            "tool",
            "sensitive raw result",
            tool_call_id=call_id,
            timestamp=3 + index * 2,
        )
    db.append_message("legacy", "assistant", "done", timestamp=20)

    scanned = []
    while True:
        result = projection.advance_historical_backfill(
            db, session_id="legacy", max_rows=2
        )
        scanned.append(result["rows_scanned"])
        if result.get("scan_complete") or result.get("coverage_complete"):
            break
    assert scanned and max(scanned) <= 2
    assert len(scanned) > 1

    page = projection.build_turn_page(db, session_id="legacy")
    assert page["coverage_complete"] is True
    assert page["projection_pending"] is False
    assert len(page["turns"]) == 1
    assert page["turns"][0]["final"]["content"] == "done"
    assert page["turns"][0]["activity_groups"][0]["operation_count"] == 4

    checkpoint = (
        tmp_path / "home" / "mobile" / "turn-projection-backfill.sqlite3"
    ).read_bytes()
    assert b"secret command" not in checkpoint
    assert b"sensitive raw result" not in checkpoint


def test_historical_backfill_resets_checkpoint_when_display_revision_changes(
    tmp_path, monkeypatch
):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("legacy", source="tui")
    db.append_message("legacy", "user", "first", timestamp=1)
    db.append_message("legacy", "assistant", "first answer", timestamp=2)
    db.append_message("legacy", "user", "second", timestamp=3)
    db.append_message("legacy", "assistant", "second answer", timestamp=4)

    first = projection.advance_historical_backfill(
        db, session_id="legacy", max_rows=1
    )
    assert first["rows_scanned"] == 1
    db.append_message("legacy", "assistant", "newer display row", timestamp=5)

    second = projection.advance_historical_backfill(
        db, session_id="legacy", max_rows=1
    )
    assert second["rows_scanned"] == 1
    with sqlite3.connect(
        tmp_path / "home" / "mobile" / "turn-projection-backfill.sqlite3"
    ) as checkpoint:
        revision = checkpoint.execute(
            "SELECT display_revision FROM backfill_state WHERE session_id = 'legacy'"
        ).fetchone()[0]
    assert revision == db.get_turn_ledger_status("legacy")["display_revision"]


def test_historical_turn_without_proven_terminal_remains_partial(tmp_path, monkeypatch):
    monkeypatch.setenv("HERMES_HOME", str(tmp_path / "home"))
    db = SessionDB(db_path=tmp_path / "state.db")
    db.create_session("legacy", source="tui")
    db.append_message("legacy", "user", "unfinished", timestamp=1)
    result = projection.advance_historical_backfill(db, session_id="legacy")

    assert result["scan_complete"] is True
    page = projection.build_turn_page(db, session_id="legacy")
    assert page["coverage_complete"] is False
    assert page["projection_pending"] is True
    assert page["turns"] == []
