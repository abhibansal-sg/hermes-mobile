#!/usr/bin/env python3
"""Backfill existing autonomous machinery session rows to source='machinery'.

Dry-run by default. Use --apply to update the selected DB. The matcher is
intentionally conservative: only legacy source values ('cli'/'unknown') can be
retagged, and only when the row carries a known machinery cwd/title signature.
"""

from __future__ import annotations

import argparse
import sqlite3
from pathlib import Path
from typing import Any, Iterable


def _default_db_path() -> Path:
    from hermes_state import DEFAULT_DB_PATH

    return Path(DEFAULT_DB_PATH)


def _is_machinery_candidate(row: sqlite3.Row) -> bool:
    source = str(row["source"] or "").strip().lower()
    if source not in {"cli", "unknown"}:
        return False

    title = str(row["title"] or "").strip().lower()
    cwd = str(row["cwd"] or "").strip().lower()

    if title.startswith("loop plan") or "loop-worker" in title:
        return True

    cwd_markers = (
        "/.hermes/kanban/",
        "/kanban/boards/",
        "/workspaces/t_",
        "/worktrees/wt/t_",
    )
    return any(marker in cwd for marker in cwd_markers)


def _candidate_ids(conn: sqlite3.Connection) -> list[str]:
    conn.row_factory = sqlite3.Row
    rows = conn.execute(
        """
        SELECT id, source, title, cwd
        FROM sessions
        WHERE COALESCE(source, '') IN ('cli', 'unknown')
        ORDER BY started_at ASC, id ASC
        """
    ).fetchall()
    return [str(row["id"]) for row in rows if _is_machinery_candidate(row)]


def _source_counts(conn: sqlite3.Connection) -> dict[str, int]:
    rows = conn.execute(
        "SELECT COALESCE(source, '') AS source, COUNT(*) FROM sessions GROUP BY COALESCE(source, '')"
    ).fetchall()
    return {str(source): int(count) for source, count in rows}


def backfill(db_path: Path, *, apply: bool = False) -> dict[str, Any]:
    db_path = Path(db_path).expanduser()
    if not db_path.exists():
        raise FileNotFoundError(f"state DB does not exist: {db_path}")

    with sqlite3.connect(db_path) as conn:
        before_counts = _source_counts(conn)
        ids = _candidate_ids(conn)
        updated = 0
        if apply and ids:
            conn.executemany(
                "UPDATE sessions SET source = 'machinery' WHERE id = ? AND source IN ('cli', 'unknown')",
                [(sid,) for sid in ids],
            )
            updated = int(conn.total_changes)
        after_counts = _source_counts(conn)

    return {
        "db": str(db_path),
        "dry_run": not apply,
        "candidates": len(ids),
        "updated": updated,
        "before_counts": before_counts,
        "after_counts": after_counts,
    }


def _format_counts(counts: dict[str, int]) -> str:
    if not counts:
        return "{}"
    return "{" + ", ".join(f"{key or '<empty>'}:{counts[key]}" for key in sorted(counts)) + "}"


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, default=None, help="Path to state.db (defaults to Hermes DEFAULT_DB_PATH)")
    parser.add_argument("--apply", action="store_true", help="Write source='machinery' for matching rows")
    args = parser.parse_args(list(argv) if argv is not None else None)

    report = backfill(args.db or _default_db_path(), apply=args.apply)
    print(
        "machinery backfill "
        f"db={report['db']} "
        f"dry_run={report['dry_run']} "
        f"candidates={report['candidates']} "
        f"updated={report['updated']}"
    )
    print(f"before_counts={_format_counts(report['before_counts'])}")
    print(f"after_counts={_format_counts(report['after_counts'])}")
    if report["dry_run"] and report["candidates"]:
        print("dry run only; re-run with --apply to write source='machinery'")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
