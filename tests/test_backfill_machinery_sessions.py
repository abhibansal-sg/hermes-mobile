"""Tests for one-time machinery session source backfill."""

from __future__ import annotations

import sqlite3
import subprocess
import sys
from pathlib import Path

from hermes_state import SessionDB


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "backfill-machinery-sessions.py"


def _set_session_fields(db_path: Path, session_id: str, *, source: str, title: str = "", cwd: str | None = None) -> None:
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            "UPDATE sessions SET source = ?, title = ?, cwd = ? WHERE id = ?",
            (source, title, cwd, session_id),
        )


def _source_counts(db_path: Path) -> dict[str, int]:
    with sqlite3.connect(db_path) as conn:
        rows = conn.execute("SELECT source, COUNT(*) FROM sessions GROUP BY source").fetchall()
    return {source: count for source, count in rows}


def test_backfill_dry_run_counts_machinery_rows_without_writing(tmp_path):
    db_path = tmp_path / "state.db"
    db = SessionDB(db_path=db_path)
    try:
        db.create_session("kanban-cli", source="cli")
        db.create_session("loop-unknown", source="unknown")
        db.create_session("human-cli", source="cli")
    finally:
        db.close()

    _set_session_fields(
        db_path,
        "kanban-cli",
        source="cli",
        title="ordinary",
        cwd="/Users/abhi/.hermes/kanban/boards/hermes-mobile/workspaces/t_12345678",
    )
    _set_session_fields(db_path, "loop-unknown", source="unknown", title="Loop Plan: sweep", cwd="/tmp")
    _set_session_fields(db_path, "human-cli", source="cli", title="human chat", cwd="/Users/abhi/project")

    result = subprocess.run(
        [sys.executable, str(SCRIPT), "--db", str(db_path)],
        check=False,
        text=True,
        capture_output=True,
    )

    assert result.returncode == 0, result.stderr
    assert "dry_run=True" in result.stdout
    assert "candidates=2" in result.stdout
    assert _source_counts(db_path) == {"cli": 2, "unknown": 1}


def test_backfill_apply_marks_only_machinery_rows_idempotently(tmp_path):
    db_path = tmp_path / "state.db"
    db = SessionDB(db_path=db_path)
    try:
        db.create_session("kanban-cli", source="cli")
        db.create_session("loop-worker", source="unknown")
        db.create_session("telegram-loop-title", source="telegram")
        db.create_session("human-cli", source="cli")
    finally:
        db.close()

    _set_session_fields(
        db_path,
        "kanban-cli",
        source="cli",
        title="ordinary",
        cwd="/Users/abhi/Developer/worktrees/wt/t_35cf0f27",
    )
    _set_session_fields(db_path, "loop-worker", source="unknown", title="loop-worker: ABH-403", cwd="/tmp")
    _set_session_fields(db_path, "telegram-loop-title", source="telegram", title="Loop Plan: human", cwd="/tmp")
    _set_session_fields(db_path, "human-cli", source="cli", title="human chat", cwd="/Users/abhi/project")

    first = subprocess.run(
        [sys.executable, str(SCRIPT), "--db", str(db_path), "--apply"],
        check=False,
        text=True,
        capture_output=True,
    )
    second = subprocess.run(
        [sys.executable, str(SCRIPT), "--db", str(db_path), "--apply"],
        check=False,
        text=True,
        capture_output=True,
    )

    assert first.returncode == 0, first.stderr
    assert "dry_run=False" in first.stdout
    assert "updated=2" in first.stdout
    assert second.returncode == 0, second.stderr
    assert "candidates=0" in second.stdout
    assert _source_counts(db_path) == {"cli": 1, "machinery": 2, "telegram": 1}
