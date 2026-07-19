#!/bin/sh
set -eu

# Use only during a maintenance window with the SQLite Hub stopped.
sqlite3 "${HRH_SQLITE_PATH:?set HRH_SQLITE_PATH}" \
  "PRAGMA secure_delete=ON; PRAGMA wal_checkpoint(TRUNCATE); VACUUM;"
