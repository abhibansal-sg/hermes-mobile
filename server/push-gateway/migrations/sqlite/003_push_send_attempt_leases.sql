PRAGMA foreign_keys = OFF;

BEGIN IMMEDIATE;

-- SQLite has no portable ADD COLUMN IF NOT EXISTS. Rebuilding from the stable
-- v1 columns makes this migration idempotent and deliberately clears any
-- pre-restart in-flight lease: no APNs request can survive the process that is
-- applying this migration.
CREATE TABLE IF NOT EXISTS push_receipts_v3 (
    binding_id TEXT NOT NULL REFERENCES bindings(binding_id),
    notification_id_hash BLOB NOT NULL CHECK (length(notification_id_hash) = 32),
    request_hash BLOB NOT NULL CHECK (length(request_hash) = 32),
    status TEXT NOT NULL CHECK (status IN ('reserved', 'ambiguous', 'retryable', 'sent', 'permanent_rejected')),
    provider_status INTEGER,
    apns_id TEXT NOT NULL,
    collapse_id TEXT NOT NULL,
    attempt_count INTEGER NOT NULL CHECK (attempt_count > 0),
    last_attempt_at_ms INTEGER NOT NULL,
    provider_retry_not_before_ms INTEGER,
    created_at_ms INTEGER NOT NULL,
    expires_at_ms INTEGER NOT NULL,
    completed_at_ms INTEGER,
    attempt_token BLOB CHECK (attempt_token IS NULL OR length(attempt_token) = 32),
    lease_expires_at_ms INTEGER,
    PRIMARY KEY (binding_id, notification_id_hash)
);

INSERT OR REPLACE INTO push_receipts_v3 (
    binding_id,notification_id_hash,request_hash,status,provider_status,
    apns_id,collapse_id,attempt_count,last_attempt_at_ms,
    provider_retry_not_before_ms,created_at_ms,
    expires_at_ms,completed_at_ms,attempt_token,lease_expires_at_ms
)
SELECT
    binding_id,notification_id_hash,request_hash,status,provider_status,
    apns_id,collapse_id,attempt_count,last_attempt_at_ms,
    provider_retry_not_before_ms,created_at_ms,
    expires_at_ms,completed_at_ms,NULL,NULL
FROM push_receipts;

DROP TABLE push_receipts;
ALTER TABLE push_receipts_v3 RENAME TO push_receipts;
CREATE INDEX IF NOT EXISTS push_receipts_rate
    ON push_receipts(binding_id, created_at_ms);
CREATE INDEX IF NOT EXISTS push_receipts_expiry
    ON push_receipts(expires_at_ms);

INSERT OR IGNORE INTO push_schema_migrations(version) VALUES (3);

COMMIT;

PRAGMA foreign_keys = ON;
