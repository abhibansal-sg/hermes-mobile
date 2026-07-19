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
        migrator.registerMigration("work-v3-relay-v2-command-outbox") { db in
            try db.execute(sql: """
                CREATE TABLE relay_v2_commands (
                    op_id TEXT PRIMARY KEY NOT NULL,
                    client_message_id TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    session_id TEXT,
                    kind TEXT NOT NULL CHECK(kind IN ('prompt','approval','interrupt')),
                    payload_json BLOB NOT NULL,
                    payload_hash TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN (
                        'queued','sending','accepted','retry_wait','ambiguous','completed','expired'
                    )),
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    next_attempt_at REAL,
                    lease_owner TEXT,
                    lease_expires_at REAL,
                    last_error_code TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL
                );
                CREATE UNIQUE INDEX relay_v2_commands_client_message
                    ON relay_v2_commands(account_id, client_message_id);
                CREATE INDEX relay_v2_commands_drain
                    ON relay_v2_commands(account_id, state, next_attempt_at, created_at);
                """)
        }
        migrator.registerMigration("work-v4-relay-v2-stable-envelope") { db in
            try db.alter(table: "relay_v2_commands") { table in
                table.add(column: "fixed_expires_at", .double)
                table.add(column: "envelope_json", .blob)
            }
            try db.execute(sql: """
                UPDATE relay_v2_commands
                SET fixed_expires_at = created_at + 86400
                WHERE fixed_expires_at IS NULL
                """)
        }
        migrator.registerMigration("work-v5-relay-v2-command-kinds") { db in
            // SQLite cannot widen a CHECK constraint in place. Rebuild the
            // outbox so existing installs keep every durable command while
            // gaining the complete HRP/2 RPC surface.
            try db.execute(sql: """
                CREATE TABLE relay_v2_commands_v5 (
                    op_id TEXT PRIMARY KEY NOT NULL,
                    client_message_id TEXT NOT NULL,
                    account_id TEXT NOT NULL,
                    session_id TEXT,
                    kind TEXT NOT NULL CHECK(kind IN (
                        'prompt','approval','interrupt','session_list','session_history',
                        'session_open','session_resume','clarify','presence_set'
                    )),
                    payload_json BLOB NOT NULL,
                    payload_hash TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN (
                        'queued','sending','accepted','retry_wait','ambiguous','completed','expired'
                    )),
                    attempt_count INTEGER NOT NULL DEFAULT 0,
                    next_attempt_at REAL,
                    lease_owner TEXT,
                    lease_expires_at REAL,
                    last_error_code TEXT,
                    created_at REAL NOT NULL,
                    updated_at REAL NOT NULL,
                    completed_at REAL,
                    fixed_expires_at REAL,
                    envelope_json BLOB
                );
                INSERT INTO relay_v2_commands_v5(
                    op_id,client_message_id,account_id,session_id,kind,payload_json,payload_hash,
                    state,attempt_count,next_attempt_at,lease_owner,lease_expires_at,last_error_code,
                    created_at,updated_at,completed_at,fixed_expires_at,envelope_json
                )
                SELECT
                    op_id,client_message_id,account_id,session_id,kind,payload_json,payload_hash,
                    state,attempt_count,next_attempt_at,lease_owner,lease_expires_at,last_error_code,
                    created_at,updated_at,completed_at,fixed_expires_at,envelope_json
                FROM relay_v2_commands ORDER BY rowid;
                DROP TABLE relay_v2_commands;
                ALTER TABLE relay_v2_commands_v5 RENAME TO relay_v2_commands;
                CREATE UNIQUE INDEX relay_v2_commands_client_message
                    ON relay_v2_commands(account_id, client_message_id);
                CREATE INDEX relay_v2_commands_drain
                    ON relay_v2_commands(account_id, state, next_attempt_at, created_at);
                """)
        }
        return migrator
    }
}
