import GRDB

enum WorkSchema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("work-v1") { db in
            try db.execute(sql: """
                CREATE TABLE drafts (
                    draft_id TEXT PRIMARY KEY NOT NULL,
                    server_id TEXT NOT NULL,
                    profile_id TEXT NOT NULL,
                    context_key TEXT NOT NULL,
                    stored_session_id TEXT,
                    text TEXT NOT NULL DEFAULT '',
                    cwd TEXT,
                    model_selection_json TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    CHECK (length(context_key) > 0),
                    UNIQUE (server_id, profile_id, context_key)
                );
                CREATE INDEX drafts_scope_updated
                    ON drafts(server_id, profile_id, updated_at DESC);

                CREATE TABLE work_jobs (
                    job_id TEXT PRIMARY KEY NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('prompt', 'share', 'app_intent')),
                    client_message_id TEXT NOT NULL,
                    server_id TEXT,
                    profile_id TEXT,
                    state TEXT NOT NULL CHECK (state IN (
                        'waiting_for_scope', 'queued', 'creating_destination', 'uploading',
                        'submitting', 'accepted', 'retry_wait', 'failed', 'completed',
                        'cancelled', 'expired'
                    )),
                    intent_kind TEXT CHECK (
                        intent_kind IS NULL OR
                        intent_kind IN ('ask_hermes', 'open_sessions', 'new_session')
                    ),
                    text TEXT,
                    source_url TEXT,
                    comment TEXT,
                    stored_session_id TEXT,
                    destination_session_id TEXT,
                    payload_hash TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
                    next_attempt_at REAL,
                    last_error_code TEXT,
                    last_error_message TEXT,
                    lease_owner TEXT,
                    lease_expires_at REAL,
                    expires_at REAL,
                    legacy_import_key TEXT UNIQUE,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    accepted_at REAL,
                    completed_at REAL,
                    CHECK ((server_id IS NULL) = (profile_id IS NULL))
                );
                CREATE UNIQUE INDEX work_jobs_scoped_client_message
                    ON work_jobs(server_id, profile_id, client_message_id)
                    WHERE server_id IS NOT NULL AND profile_id IS NOT NULL;
                CREATE INDEX work_jobs_drain
                    ON work_jobs(state, next_attempt_at, created_at);
                CREATE INDEX work_jobs_scope_state
                    ON work_jobs(server_id, profile_id, state, created_at);

                CREATE TABLE work_assets (
                    asset_id TEXT PRIMARY KEY NOT NULL,
                    relative_path TEXT NOT NULL UNIQUE,
                    mime_type TEXT NOT NULL,
                    byte_count INTEGER NOT NULL CHECK (byte_count >= 0),
                    sha256 TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    last_accessed_at REAL NOT NULL
                );

                CREATE TABLE job_assets (
                    job_id TEXT NOT NULL REFERENCES work_jobs(job_id) ON DELETE CASCADE,
                    asset_id TEXT NOT NULL REFERENCES work_assets(asset_id) ON DELETE RESTRICT,
                    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                    transfer_id TEXT,
                    remote_path TEXT,
                    state TEXT NOT NULL CHECK (state IN ('local', 'transferring', 'uploaded', 'failed')),
                    PRIMARY KEY (job_id, ordinal),
                    UNIQUE (job_id, asset_id)
                );

                CREATE TABLE draft_assets (
                    draft_id TEXT NOT NULL REFERENCES drafts(draft_id) ON DELETE CASCADE,
                    asset_id TEXT NOT NULL REFERENCES work_assets(asset_id) ON DELETE RESTRICT,
                    ordinal INTEGER NOT NULL CHECK (ordinal >= 0),
                    PRIMARY KEY (draft_id, ordinal),
                    UNIQUE (draft_id, asset_id)
                );

                CREATE TABLE transfers (
                    transfer_id TEXT PRIMARY KEY NOT NULL,
                    background_session_id TEXT NOT NULL,
                    task_identifier INTEGER,
                    direction TEXT NOT NULL CHECK (direction IN ('upload', 'download')),
                    purpose TEXT NOT NULL CHECK (purpose IN ('prompt_asset', 'share_asset', 'attachment', 'export')),
                    server_id TEXT NOT NULL,
                    profile_id TEXT NOT NULL,
                    owner_job_id TEXT REFERENCES work_jobs(job_id) ON DELETE SET NULL,
                    source_relative_path TEXT,
                    destination_relative_path TEXT,
                    request_url TEXT NOT NULL,
                    request_method TEXT NOT NULL,
                    mime_type TEXT,
                    expected_bytes INTEGER,
                    transferred_bytes INTEGER NOT NULL DEFAULT 0,
                    resume_data BLOB,
                    state TEXT NOT NULL CHECK (state IN (
                        'prepared', 'running', 'suspended', 'retry_wait', 'succeeded',
                        'failed', 'cancelled'
                    )),
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    next_attempt_at REAL,
                    last_error_code TEXT,
                    last_error_message TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL
                );
                CREATE UNIQUE INDEX transfers_background_task
                    ON transfers(background_session_id, task_identifier)
                    WHERE task_identifier IS NOT NULL;
                CREATE INDEX transfers_resume
                    ON transfers(state, next_attempt_at, created_at);
                """)
        }
        migrator.registerMigration("work-v2-draft-revisions") { db in
            try db.alter(table: "drafts") { table in
                table.add(column: "revision", .integer).notNull().defaults(to: 1)
            }
        }
        migrator.registerMigration("work-v3-authority-scope") { db in
            try db.alter(table: "drafts") { table in
                table.add(column: "gateway_id", .text)
                table.add(column: "authority_epoch", .text)
                table.add(column: "authority_state", .text)
                    .notNull().defaults(to: WorkAuthorityState.legacyUnverified.rawValue)
            }
            try db.alter(table: "work_jobs") { table in
                table.add(column: "gateway_id", .text)
                table.add(column: "authority_epoch", .text)
                table.add(column: "authority_state", .text)
                    .notNull().defaults(to: WorkAuthorityState.legacyUnverified.rawValue)
            }
            try db.alter(table: "transfers") { table in
                table.add(column: "gateway_id", .text)
                table.add(column: "authority_epoch", .text)
                table.add(column: "authority_state", .text)
                    .notNull().defaults(to: WorkAuthorityState.legacyUnverified.rawValue)
            }
            try db.execute(
                sql: """
                    UPDATE work_jobs SET authority_state = ?
                    WHERE server_id IS NULL AND profile_id IS NULL
                    """,
                arguments: [WorkAuthorityState.unbound.rawValue]
            )
        }
        migrator.registerMigration("work-v4-authoritative-receipt") { db in
            try db.alter(table: "work_jobs") { table in
                table.add(column: "authoritative_turn_id", .text)
                table.add(column: "accepted_entity_revision", .integer)
            }
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS work_jobs_authoritative_turn
                ON work_jobs(gateway_id, profile_id, authority_epoch, authoritative_turn_id)
                WHERE authoritative_turn_id IS NOT NULL
                """)
        }
        return migrator
    }
}
