PRAGMA foreign_keys = OFF;

BEGIN IMMEDIATE;

-- Rebuild so the migration remains idempotent on SQLite. Reservations are
-- process leases; a stopped process cannot still be doing verification, so
-- clearing them during migration is safe and leaves the challenge reusable.
CREATE TABLE IF NOT EXISTS attest_challenges_v4 (
    challenge_hash BLOB PRIMARY KEY CHECK (length(challenge_hash) = 32),
    created_at_ms INTEGER NOT NULL,
    source_hash BLOB NOT NULL CHECK (length(source_hash) = 32),
    expires_at_ms INTEGER NOT NULL,
    used_at_ms INTEGER,
    bound_request_hash BLOB,
    validation_request_hash BLOB CHECK (
        validation_request_hash IS NULL OR length(validation_request_hash) = 32
    ),
    validation_owner_token BLOB CHECK (
        validation_owner_token IS NULL OR length(validation_owner_token) = 32
    ),
    validation_expires_at_ms INTEGER
);

INSERT OR REPLACE INTO attest_challenges_v4 (
    challenge_hash,created_at_ms,source_hash,expires_at_ms,used_at_ms,
    bound_request_hash,validation_request_hash,validation_owner_token,
    validation_expires_at_ms
)
SELECT
    challenge_hash,created_at_ms,source_hash,expires_at_ms,used_at_ms,
    bound_request_hash,NULL,NULL,NULL
FROM attest_challenges;

DROP TABLE attest_challenges;
ALTER TABLE attest_challenges_v4 RENAME TO attest_challenges;
CREATE INDEX IF NOT EXISTS attest_challenges_expiry
    ON attest_challenges(expires_at_ms);

-- One row is one provider call. The composite identity is already retained in
-- the receipt and avoids introducing a database-generated secret or sequence.
CREATE TABLE IF NOT EXISTS push_send_attempts (
    binding_id TEXT NOT NULL REFERENCES bindings(binding_id),
    notification_id_hash BLOB NOT NULL CHECK (length(notification_id_hash) = 32),
    attempt_number INTEGER NOT NULL CHECK (attempt_number > 0),
    attempted_at_ms INTEGER NOT NULL,
    PRIMARY KEY (binding_id, notification_id_hash, attempt_number)
);
CREATE INDEX IF NOT EXISTS push_send_attempts_rate
    ON push_send_attempts(binding_id, attempted_at_ms);
CREATE INDEX IF NOT EXISTS push_send_attempts_expiry
    ON push_send_attempts(attempted_at_ms);

-- Preserve fail-closed quota accounting across the upgrade. Exact historical
-- attempt times are unavailable in v3, so conservatively place every retained
-- attempt at its receipt's last-attempt time.
WITH RECURSIVE attempt_numbers(value) AS (
    VALUES (1)
    UNION ALL
    SELECT value + 1
    FROM attempt_numbers
    WHERE value < (SELECT COALESCE(MAX(attempt_count), 0) FROM push_receipts)
)
INSERT OR IGNORE INTO push_send_attempts (
    binding_id,notification_id_hash,attempt_number,attempted_at_ms
)
SELECT
    receipt.binding_id,
    receipt.notification_id_hash,
    attempt_numbers.value,
    receipt.last_attempt_at_ms
FROM push_receipts AS receipt
JOIN attempt_numbers ON attempt_numbers.value <= receipt.attempt_count;

INSERT OR IGNORE INTO push_schema_migrations(version) VALUES (4);

COMMIT;

PRAGMA foreign_keys = ON;
