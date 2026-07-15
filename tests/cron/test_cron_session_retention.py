import pytest

from cron.session_retention import purge_cron_job_sessions
from hermes_state import SessionDB


@pytest.fixture
def session_db(tmp_path):
    db = SessionDB(tmp_path / "state.db")
    try:
        yield db
    finally:
        db.close()


def _create_session(
    db: SessionDB,
    session_id: str,
    *,
    source: str = "cron",
    started_at: float,
) -> None:
    db.create_session(session_id, source=source)
    db._conn.execute(
        "UPDATE sessions SET started_at = ? WHERE id = ?",
        (started_at, session_id),
    )
    db._conn.execute(
        "INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)",
        (session_id, "user", f"message for {session_id}", started_at),
    )
    db._conn.commit()


def _session_ids(db: SessionDB) -> set[str]:
    rows = db._conn.execute("SELECT id FROM sessions").fetchall()
    return {row["id"] for row in rows}


def _message_session_ids(db: SessionDB) -> set[str]:
    rows = db._conn.execute("SELECT DISTINCT session_id FROM messages").fetchall()
    return {row["session_id"] for row in rows}


def _prune_cron_sessions(
    db: SessionDB,
    active_job_ids: list[str],
    *,
    per_job_limit: int = 20,
) -> int:
    deleted = 0
    active = set(active_job_ids)
    cron_rows = db._conn.execute(
        "SELECT id FROM sessions WHERE source = 'cron' AND id >= 'cron_' AND id < 'cron`'"
    ).fetchall()
    job_ids = {
        row["id"][len("cron_"):].rsplit("_", 1)[0]
        for row in cron_rows
        if row["id"].startswith("cron_") and "_" in row["id"][len("cron_"):]
    }
    for job_id in job_ids:
        keep_latest = per_job_limit if job_id in active else 0
        deleted += purge_cron_job_sessions(
            job_id,
            keep_latest=keep_latest,
            db_path=db.db_path,
            sessions_dir=db.db_path.parent / "sessions",
        )
    return deleted


def test_deleted_job_purge_removes_cron_sessions_and_messages(session_db):
    _create_session(session_db, "cron_deadjob_1000", started_at=1000)
    _create_session(session_db, "cron_deadjob_1001", started_at=1001)
    _create_session(session_db, "cron_livejob_2000", started_at=2000)

    deleted = _prune_cron_sessions(session_db, ["livejob"])

    assert deleted == 2
    assert _session_ids(session_db) == {"cron_livejob_2000"}
    assert _message_session_ids(session_db) == {"cron_livejob_2000"}


def test_active_job_retention_cap_keeps_newest_twenty_by_started_at(session_db):
    for index in range(23):
        _create_session(
            session_db,
            f"cron_livejob_{index:02d}",
            started_at=float(index),
        )

    deleted = _prune_cron_sessions(session_db, ["livejob"])

    expected_kept = {f"cron_livejob_{index:02d}" for index in range(3, 23)}
    assert deleted == 3
    assert _session_ids(session_db) == expected_kept
    assert _message_session_ids(session_db) == expected_kept


def test_retention_safety_preserves_non_cron_source_and_other_active_job(session_db):
    _create_session(session_db, "cron_livejob_1000", source="cli", started_at=1000)
    _create_session(session_db, "cron_livejob_1001", source="cron", started_at=1001)
    _create_session(session_db, "cron_otherjob_2000", source="cron", started_at=2000)
    _create_session(session_db, "cron_deadjob_3000", source="cron", started_at=3000)

    deleted = _prune_cron_sessions(session_db, ["livejob", "otherjob"])

    assert deleted == 1
    assert _session_ids(session_db) == {
        "cron_livejob_1000",
        "cron_livejob_1001",
        "cron_otherjob_2000",
    }
    assert _message_session_ids(session_db) == {
        "cron_livejob_1000",
        "cron_livejob_1001",
        "cron_otherjob_2000",
    }


def test_purge_uses_exact_job_id_prefix_range(session_db):
    _create_session(session_db, "cron_alpha_1000", source="cron", started_at=1000)
    _create_session(session_db, "cron_xalpha_1001", source="cron", started_at=1001)
    _create_session(session_db, "cron_alpha2_1002", source="cron", started_at=1002)

    deleted = purge_cron_job_sessions(
        "alpha",
        db_path=session_db.db_path,
        sessions_dir=session_db.db_path.parent / "sessions",
    )

    assert deleted == 1
    assert _session_ids(session_db) == {"cron_xalpha_1001", "cron_alpha2_1002"}
    assert _message_session_ids(session_db) == {"cron_xalpha_1001", "cron_alpha2_1002"}
