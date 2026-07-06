"""Best-effort retention helpers for cron-created agent sessions."""

from __future__ import annotations

from pathlib import Path

from hermes_constants import get_hermes_home
from hermes_state import SessionDB


DEFAULT_CRON_SESSION_KEEP_LATEST = 20
_BATCH_SIZE = 1000


def purge_cron_job_sessions(
    job_id: str,
    *,
    keep_latest: int = 0,
    db_path: Path | None = None,
    sessions_dir: Path | None = None,
) -> int:
    """Delete cron sessions for one job, optionally preserving newest runs.

    SessionDB.list_cron_job_runs() supplies the safety boundary: it only returns
    rows with source='cron' and ids in the exact cron_<job_id>_ prefix range.
    """
    if keep_latest < 0:
        raise ValueError("keep_latest must be >= 0")

    db = SessionDB(db_path or (get_hermes_home() / "state.db"))
    try:
        session_root = sessions_dir or (get_hermes_home() / "sessions")
        deleted = 0
        while True:
            runs = db.list_cron_job_runs(
                job_id,
                limit=_BATCH_SIZE,
                offset=keep_latest,
            )
            session_ids = [run["id"] for run in runs]
            if not session_ids:
                return deleted
            deleted += db.delete_sessions(session_ids, sessions_dir=session_root)
            if len(session_ids) < _BATCH_SIZE:
                return deleted
    finally:
        db.close()
