from __future__ import annotations

import sqlite3
from pathlib import Path

from relay_hub.settings import Settings
from relay_hub.storage import DatabaseStore, metadata


def test_checked_in_sqlite_migration_matches_runtime_schema_and_is_idempotent(
    tmp_path,
) -> None:
    root = Path(__file__).resolve().parents[1]
    database = tmp_path / "hub.sqlite3"
    store = DatabaseStore(
        Settings(database_url=f"sqlite:///{database}", auto_create_schema=False)
    )
    assert store.ready() is False

    connection = sqlite3.connect(database)
    migration = (root / "migrations/sqlite/001_hrp2.sql").read_text()
    connection.executescript(migration)
    connection.executescript(migration)

    actual_tables = {
        row[0]
        for row in connection.execute(
            "SELECT name FROM sqlite_master "
            "WHERE type='table' AND name NOT LIKE 'sqlite_%'"
        )
    }
    assert actual_tables == set(metadata.tables)
    for table in metadata.sorted_tables:
        actual_columns = {
            row[1] for row in connection.execute(f'PRAGMA table_info("{table.name}")')
        }
        assert actual_columns == set(table.c.keys()), table.name

    assert store.ready() is True
    store.engine.dispose()
    connection.close()
